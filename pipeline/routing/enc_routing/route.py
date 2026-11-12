"""Prototype router over the triangle mesh: A* on portal edges, then
funnel (string-pulling) path straightening inside the triangle corridor.

This is deliberately the algorithm intended for the phone: it touches only
the arrays in mesh.npz, never the source polygons.
"""
from __future__ import annotations

import heapq
import json
import math
import time
from dataclasses import dataclass, field

import numpy as np

from .config import FT, BoatProfile, work
from .safewater import chart_metres
from .graph import F_CHANNEL, F_GULF, F_OPENING, F_UNKNOWN_CLR

OPENING_PENALTY_M = 1500.0   # cost of waiting for a bridge opening, metres-equivalent
UNKNOWN_CLR_PENALTY_M = 3000.0  # passing under an overhead object of unknown clearance
THIN_WATER_FACTOR = 1.25     # off-channel water with < 1 m to spare
CHANNEL_FACTOR = 0.9         # prefer marked/maintained channels
PROJECT_DEPTH_FACTOR = 3.0   # use of USACE project depth where the chart is shallower
NUDGE_M = 8.0                # push straightened-path corners off the corridor edge


@dataclass
class Mesh:
    coords: np.ndarray
    tris: np.ndarray
    nbr: np.ndarray
    depth_m: np.ndarray
    proj_m: np.ndarray
    clear_m: np.ndarray
    flags: np.ndarray
    _tree: object = field(default=None, repr=False)

    @classmethod
    def load(cls, path=None):
        z = np.load(path or work("graph", "mesh.npz"))
        return cls(z["coords"], z["tris"], z["nbr"], z["depth_m"], z["proj_m"], z["clear_m"], z["flags"])

    @property
    def centroids(self):
        return self.coords[self.tris].mean(axis=1)

    def locate(self, xy):
        """Index of the triangle containing xy (STRtree over triangles)."""
        import shapely
        if self._tree is None:
            polys = shapely.polygons(self.coords[self.tris])
            self._polys = polys
            self._tree = shapely.STRtree(polys)
        hits = self._tree.query(shapely.Point(xy), predicate="intersects")
        return int(hits[0]) if len(hits) else None


@dataclass
class Options:
    boat: BoatProfile = field(default_factory=BoatProfile)
    inside_only: bool = False          # forbid open-Gulf triangles
    allow_openings: bool = True        # opening bridges usable (with penalty)
    use_project_depth: bool = False    # trust USACE maintained depth in channel reaches
    allow_unknown_clearance: bool = False


def passable(mesh: Mesh, opt: Options) -> tuple[np.ndarray, np.ndarray]:
    """Per-triangle (ok, cost_factor)."""
    need = opt.boat.required_depth_ft
    need_m = chart_metres(need) - 1e-6      # S-57 values are feet truncated to 0.1 m
    air = opt.boat.air_draft_ft * FT
    d = np.nan_to_num(mesh.depth_m, nan=-1)
    ok_depth = d >= need_m
    proj_ok = np.nan_to_num(mesh.proj_m, nan=-1) >= need_m
    # a charted hazard (VALSOU known or not) is never overridden by project depth:
    # only depth-area shoaling is (d >= 0 means the limiting value is a depth area)
    use_proj = opt.use_project_depth & ~ok_depth & proj_ok & (d >= 0)
    ok = ok_depth | use_proj
    c = mesh.clear_m
    fixed_ok = np.where(np.isnan(c), opt.allow_unknown_clearance, c >= air)
    opening = (mesh.flags & F_OPENING) > 0
    clr_ok = fixed_ok | (opening & opt.allow_openings)
    ok &= clr_ok
    if opt.inside_only:
        ok &= (mesh.flags & F_GULF) == 0
    chan = (mesh.flags & F_CHANNEL) > 0
    factor = np.ones(len(d))
    factor[chan] = CHANNEL_FACTOR
    factor[~chan & (d < need_m + 1.0)] = THIN_WATER_FACTOR
    factor[use_proj] = PROJECT_DEPTH_FACTOR
    return ok, factor


def _edge_mid(mesh, t, k):
    a, b = mesh.tris[t, k], mesh.tris[t, (k + 1) % 3]
    return (mesh.coords[a] + mesh.coords[b]) / 2.0


def astar(mesh: Mesh, start_xy, goal_xy, ok, factor, opening=None, unknown=None):
    """A* over triangles; a node's position is the midpoint of the edge it
    was entered through (start/goal points for the end triangles).
    Returns (list of triangle ids, stats)."""
    s = mesh.locate(start_xy)
    g = mesh.locate(goal_xy)
    if s is None or g is None:
        return None, {"error": "start or goal outside mesh"}
    if not ok[s] or not ok[g]:
        return None, {"error": f"start ok={bool(ok[s])} goal ok={bool(ok[g])}"}
    goal = np.asarray(goal_xy, float)
    fmin = float(factor.min())
    # state: triangle id; position stored per state
    pos = {s: np.asarray(start_xy, float)}
    gcost = {s: 0.0}
    came = {s: -1}
    openq = [(fmin * float(np.linalg.norm(goal - pos[s])), 0, s)]
    closed = set()
    n_exp, tie = 0, 0
    while openq:
        _, _, t = heapq.heappop(openq)
        if t in closed:
            continue
        closed.add(t)
        n_exp += 1
        if t == g:
            break
        p = pos[t]
        for k in range(3):
            u = int(mesh.nbr[t, k])
            if u < 0 or u in closed or not ok[u]:
                continue
            m = _edge_mid(mesh, t, k)
            step = float(np.linalg.norm(m - p)) * 0.5 * (factor[t] + factor[u])
            if opening is not None and opening[u] and not opening[t]:
                step += OPENING_PENALTY_M
            if unknown is not None and unknown[u] and not unknown[t]:
                step += UNKNOWN_CLR_PENALTY_M
            ng = gcost[t] + step
            if ng < gcost.get(u, math.inf):
                gcost[u] = ng
                pos[u] = m
                came[u] = t
                tie += 1
                h = fmin * float(np.linalg.norm(goal - m))
                heapq.heappush(openq, (ng + h, tie, u))
    if g not in came:
        return None, {"error": "no path", "expanded": n_exp}
    path = [g]
    while came[path[-1]] != -1:
        path.append(came[path[-1]])
    return path[::-1], {"expanded": n_exp}


def portals(mesh: Mesh, corridor, shrink=0.0):
    """(left, right) portal points between consecutive corridor triangles.
    Triangles are CCW, so leaving t through edge (u -> v): left = v, right = u."""
    out = []
    for t, n in zip(corridor[:-1], corridor[1:]):
        k = int(np.where(mesh.nbr[t] == n)[0][0])
        u = mesh.coords[mesh.tris[t, k]]
        v = mesh.coords[mesh.tris[t, (k + 1) % 3]]
        L = float(np.linalg.norm(v - u))
        if L > 0 and shrink > 0:
            s = min(shrink, 0.4 * L) / L
            u, v = u + (v - u) * s, v + (u - v) * s
        out.append((v, u))
    return out


def _tri2(a, b, c):
    """Twice the signed area (positive = c is left of a->b)."""
    return (b[0] - a[0]) * (c[1] - a[1]) - (b[1] - a[1]) * (c[0] - a[0])


def _same(a, b, tol=1e-6):
    # NB: np.allclose is relative (rtol=1e-5): at UTM northings ~3e6 m that
    # is a 30 m tolerance. Use an absolute tolerance.
    return abs(a[0] - b[0]) <= tol and abs(a[1] - b[1]) <= tol


def funnel(start, goal, ports):
    """Simple stupid funnel algorithm (Mononen). ports: [(left, right)]."""
    start = np.asarray(start, float)
    goal = np.asarray(goal, float)
    ports = [(start, start)] + [(np.asarray(l), np.asarray(r)) for l, r in ports] + [(goal, goal)]
    path = [start]
    apex, left, right = start, ports[0][0], ports[0][1]
    ai = li = ri = 0
    i = 1
    while i < len(ports):
        pl, pr = ports[i]
        # tighten right side
        if _tri2(apex, right, pr) >= 0:  # pr is left of (or on) apex->right: narrows
            if _same(apex, right) or _tri2(apex, left, pr) < 0:
                right, ri = pr, i
            else:  # right crossed over left: left becomes new apex
                path.append(left)
                apex, ai = left, li
                left, right = apex, apex
                li = ri = ai
                i = ai + 1
                continue
        # tighten left side
        if _tri2(apex, left, pl) <= 0:
            if _same(apex, left) or _tri2(apex, right, pl) > 0:
                left, li = pl, i
            else:
                path.append(right)
                apex, ai = right, ri
                left, right = apex, apex
                li = ri = ai
                i = ai + 1
                continue
        i += 1
    if not _same(path[-1], goal):
        path.append(goal)
    out = [path[0]]
    for q in path[1:]:  # the funnel can emit the same apex twice
        if not _same(q, out[-1], 1e-3):
            out.append(q)
    return np.array(out)


def nudge(mesh: Mesh, corridor, path, d: float = NUDGE_M):
    """Funnel corners sit exactly on corridor vertices (a shoal or hazard
    edge). Move each corner d metres away from the inside of its turn, and
    keep the move only if both adjacent legs stay inside the corridor.
    (Shrinking the portals instead was tried and produced paths that left the
    corridor: the shrunk ends of a triangle fan around one vertex are no
    longer a shared point, which the funnel algorithm assumes.)"""
    import shapely

    if len(path) < 3:
        return path, 0
    corr = shapely.union_all(shapely.polygons(mesh.coords[mesh.tris[np.asarray(corridor)]])).buffer(0.01)
    shapely.prepare(corr)
    out = path.copy()
    n = 0
    for i in range(1, len(path) - 1):
        a, b, c = out[i - 1], path[i], path[i + 1]
        u = (a - b) / (np.linalg.norm(a - b) or 1)
        w = (c - b) / (np.linalg.norm(c - b) or 1)
        bis = u + w  # points into the angle between the legs, where the obstacle corner is
        nb = np.linalg.norm(bis)
        if nb < 1e-9:
            continue
        cand = b - bis / nb * d
        if corr.contains(shapely.LineString([a, cand])) and corr.contains(shapely.LineString([cand, c])):
            out[i] = cand
            n += 1
    return out, n


def route(mesh: Mesh, start_xy, goal_xy, opt: Options, snap_m: float = 600.0):
    """Full query. Start/goal in a too-shallow triangle (a marina at chart
    scale) are snapped to the nearest usable triangle within snap_m."""
    t0 = time.time()
    ok, factor = passable(mesh, opt)
    air = opt.boat.air_draft_ft * FT
    # only openings the boat actually needs (closed clearance below air draft)
    opening = ((mesh.flags & F_OPENING) > 0) & ~(np.nan_to_num(mesh.clear_m, nan=0) >= air)
    snaps = {}
    pts = []
    for name, xy in (("start", start_xy), ("goal", goal_xy)):
        t = mesh.locate(xy)
        if t is None or not ok[t]:
            cen = mesh.centroids
            dd = np.linalg.norm(cen - np.asarray(xy), axis=1)
            dd[~ok] = np.inf
            j = int(np.argmin(dd))
            if dd[j] > snap_m:
                return None, {"error": f"{name} not within {snap_m} m of usable water"}
            snaps[name] = round(float(dd[j]), 0)
            xy = tuple(cen[j])
        pts.append(xy)
    unknown = np.isnan(mesh.clear_m)
    corridor, st = astar(mesh, pts[0], pts[1], ok, factor, opening, unknown)
    if corridor is None:
        st["seconds"] = round(time.time() - t0, 2)
        return None, st
    t1 = time.time()
    path = funnel(pts[0], pts[1], portals(mesh, corridor))
    path, n_nudged = nudge(mesh, corridor, path)
    t2 = time.time()
    cor = np.array(corridor)
    length = float(np.sum(np.linalg.norm(np.diff(path, axis=0), axis=1)))
    use_proj = (np.nan_to_num(mesh.depth_m[cor], nan=-1) < chart_metres(opt.boat.required_depth_ft) - 1e-6)
    st.update({
        "triangles_in_corridor": int(len(cor)),
        "length_nm": round(length / 1852, 2),
        "least_charted_depth_ft": round(float(np.nanmin(mesh.depth_m[cor])) / FT, 1),
        "corridor_triangles_relying_on_project_depth": int(use_proj.sum()),
        "min_clearance_ft": (None if not np.isfinite(np.nanmin(mesh.clear_m[cor])) else
                             round(float(np.nanmin(mesh.clear_m[cor])) / FT, 1)),
        "opening_bridges_triangles": int(((mesh.flags[cor] & F_OPENING) > 0).sum()),
        "unknown_clearance_triangles": int(np.isnan(mesh.clear_m[cor]).sum()),
        "channel_share_pct": round(100 * float(((mesh.flags[cor] & F_CHANNEL) > 0).mean()), 1),
        "gulf_share_pct": round(100 * float(((mesh.flags[cor] & F_GULF) > 0).mean()), 1),
        "snapped_m": snaps,
        "corners": int(len(path) - 2), "corners_nudged": n_nudged,
        "astar_s": round(t1 - t0, 2), "funnel_s": round(t2 - t1, 3),
    })
    return {"path": path, "corridor": cor}, st


def opening_bridges_on_route(mesh: Mesh, corridor, air_m: float | None = None) -> list:
    """Group consecutive opening-bridge triangles into crossings; each gets
    needs_opening when its closed clearance is below the boat's air draft."""
    out, prev = [], False
    for t in corridor:
        o = bool(mesh.flags[t] & F_OPENING)
        if o and not prev:
            c = mesh.coords[mesh.tris[t]].mean(axis=0)
            clr = float(mesh.clear_m[t])
            out.append({"x": float(c[0]), "y": float(c[1]),
                        "closed_clearance_ft": None if not np.isfinite(clr) else round(clr / FT),
                        "needs_opening": bool(air_m is not None and not (clr >= air_m))})
        prev = o
    return out


def run_routes() -> dict:
    import geopandas as gpd
    from shapely.geometry import LineString, Point

    from .config import GEO_CRS, WORK_CRS
    from .places import ROUTES

    t0 = time.time()
    mesh = Mesh.load()
    mesh.locate((0, 0))  # build the index once
    load_s = time.time() - t0
    results, geoms = {}, []
    for key, r in ROUTES.items():
        s = gpd.GeoSeries([Point(r["start"]), Point(r["end"])], crs=GEO_CRS).to_crs(WORK_CRS)
        res_all = {}
        for mode, opt in {
            "strict": Options(inside_only=r["inside"]),
            "relaxed": Options(inside_only=r["inside"], use_project_depth=True,
                               allow_unknown_clearance=True),
        }.items():
            res, st = route(mesh, (s.iloc[0].x, s.iloc[0].y), (s.iloc[1].x, s.iloc[1].y), opt)
            if res is not None:
                ob = opening_bridges_on_route(mesh, res["corridor"], opt.boat.air_draft_ft * FT)
                ll = gpd.GeoSeries([Point(b["x"], b["y"]) for b in ob], crs=WORK_CRS).to_crs(GEO_CRS)
                st["opening_bridges"] = [{"lat": round(p.y, 4), "lon": round(p.x, 4),
                                          "closed_clearance_ft": b["closed_clearance_ft"],
                                          "needs_opening": b["needs_opening"]}
                                         for p, b in zip(ll, ob)]
                geoms.append({"route": key, "mode": mode, "geometry": LineString(res["path"])})
                np.save(work("routes", f"{key}.{mode}.corridor.npy"), res["corridor"])
            res_all[mode] = st
            print(key, mode, st)
        results[key] = {"desc": r["desc"], **res_all}
    if geoms:
        g = gpd.GeoDataFrame(geoms, crs=WORK_CRS)
        dest = work("routes", "routes.gpkg")
        if dest.exists():
            dest.unlink()
        g.to_file(dest, layer="routes", engine="pyogrio")
    results["_mesh_load_and_index_s"] = round(load_s, 2)
    work("reports", "routes.json").write_text(json.dumps(results, indent=1, default=str))
    return results
