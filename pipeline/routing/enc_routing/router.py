"""Reference router. Reads ONLY a routing pack (packfmt.read_pack) and
implements docs/routing-pack-format.md part B exactly. The Swift port must
reproduce its outputs (testdata/routing/*.json).
"""
from __future__ import annotations

import heapq
import math
from dataclasses import asdict, dataclass

import numpy as np

from . import packfmt as P

R_EARTH = 6371008.8
DEG = 0.017453292519943295          # pi / 180
K_M_PER_DEG = R_EARTH * DEG          # metres per degree of latitude
UNITS = 10_000_000

# --- cost constants (spec B.5)
F_HIGHWAY_FACTOR = 0.80
F_CHANNEL_FACTOR = 0.90
SHORE_FACTOR = {0: 1.5, 1: 1.15}
NEAR_HAZARD_FACTOR = 1.2
MAINTAINED_FACTOR = 3.0
SPARE_LT_3DM_FACTOR = 1.3
SPARE_LT_10DM_FACTOR = 1.1
SOUNDING_FACTOR = 1.5
RESTRICTED_FACTOR = 2.0
CAUTION_FACTOR = 1.25
FMIN = 0.8
OPENING_PENALTY_M = 1500.0
UNKNOWN_CLR_PENALTY_M = 3000.0
RESTRICTED_PENALTY_M = 1000.0
LOCK_PENALTY_M = 2000.0             # entering a lock or floodgate zone (format 1.2)
PROHIBITED_FACTOR = 3.0             # format 1.3: entry-prohibited areas are passable, at a cost
PROHIBITED_PENALTY_M = 5000.0
UNCHARTED_BRIDGE_PENALTY_M = 3000.0 # format 1.3: under a fixed bridge part without a charted clearance
BLOCKED_FACTOR = 50.0
BLOCKED_PENALTY_M = 100000.0
MAX_SNAP_M = 750.0
MAX_SNAP_LIMIT_M = 100_000.0        # spec B.13: a larger max_snap_m is an invalid request
MAX_DIMENSION_FT = 1000.0           # spec B.2: draft, margin, air draft and draft + margin must be below this
THIN_MARGIN_DM = 3
OVERHEAD_POINT_M = 1.0              # spec B.10: a point object within this distance is passed under

# block reasons (spec B.3), in precedence order
BLOCK_REASONS = ["PROHIBITED", "OPEN_GULF", "DEPTH", "CLEARANCE", "UNKNOWN_CLEARANCE"]
# yellow reasons (spec B.9), in report order
YELLOW_REASONS = ["MAINTAINED_DEPTH", "SOUNDING_DEPTH", "BRIDGE_OPENING", "LOCK", "BRIDGE_UNCHARTED",
                  "UNKNOWN_CLEARANCE", "PROHIBITED_AREA", "RESTRICTED_AREA", "CAUTION_AREA", "HAZARD_PROXIMITY", "LOW_DATA_QUALITY",
                  "THIN_MARGIN"]
LOW_QUALITY_CATZOC = (0, 5, 6)      # unknown, D, U
THIN_MARGIN_CATZOC = (0, 4, 5, 6)   # unknown, C, D, U


def req_dm(feet: float) -> int:
    """Spec B.2: round the requirement up to whole feet, convert like NOAA."""
    whole = math.ceil(feet - 1e-9)
    return (whole * 3048) // 1000


def dist_m(lon1, lat1, lon2, lat2) -> float:
    """Spec B.1: equirectangular distance about the mean latitude (degrees in)."""
    phi = (lat1 + lat2) * 0.5 * DEG
    dx = (lon2 - lon1) * DEG * math.cos(phi)
    dy = (lat2 - lat1) * DEG
    return R_EARTH * math.sqrt(dx * dx + dy * dy)


def to_units(deg: float) -> int | None:
    """Spec B.6 step 1: floor(deg * 1e7 + 0.5), or None when that is not finite."""
    v = deg * UNITS + 0.5
    if not math.isfinite(v):
        return None
    return math.floor(v)


def request_is_valid(prof: "Profile", max_snap_m: float) -> bool:
    """Spec B.13 INVALID_REQUEST: every boat dimension finite, >= 0 and below 1000 ft (draft +
    margin too), and 0 <= max_snap_m <= 100000."""
    dims = (prof.draft_ft, prof.margin_ft, prof.air_draft_ft)
    try:
        if not all(math.isfinite(v) and 0.0 <= v < MAX_DIMENSION_FT for v in dims):
            return False
        if not prof.draft_ft + prof.margin_ft < MAX_DIMENSION_FT:
            return False
        return math.isfinite(max_snap_m) and 0.0 <= max_snap_m <= MAX_SNAP_LIMIT_M
    except TypeError:
        return False


@dataclass
class Profile:
    draft_ft: float
    margin_ft: float
    air_draft_ft: float
    use_maintained: bool = False
    accept_unknown_clearance: bool = False
    avoid_open_gulf: bool = False

    @property
    def req_dm(self) -> int:
        return req_dm(self.draft_ft + self.margin_ft)

    @property
    def air_dm(self) -> int:
        return req_dm(self.air_draft_ft)


# --------------------------------------------------------------------------- per-triangle classification

class Classified:
    """Vectorised spec B.3-B.5 for one profile."""

    def __init__(self, pack: P.Pack, prof: Profile):
        a = pack.attrs
        depth = a["depth_dm"].astype(np.int64)
        band = a["band_depth_dm"].astype(np.int64)
        maint = a["maint_dm"].astype(np.int64)
        clr = a["clearance_dm"].astype(np.int64)
        fl = a["flags"].astype(np.int64)
        req, air = prof.req_dm, prof.air_dm
        has_depth = depth != P.DEPTH_NONE
        depth_ok = has_depth & (depth >= req)
        maint_ok = (prof.use_maintained & has_depth & (maint != P.DEPTH_NONE) & (maint >= req)
                    & ((fl & P.F_HAZARD_DEPTH) == 0))
        via_maint = ~depth_ok & maint_ok
        opening = (fl & P.F_OPENING) > 0
        unk = (fl & P.F_UNKNOWN_CLR) > 0
        has_ovh = clr != P.CLR_NONE
        known_ok = (clr == P.CLR_UNKNOWN) | (clr >= air)
        clr_block = has_ovh & ~opening & ~known_ok
        # Round 4 (owner decision): objects without a charted clearance (now only cables and pipes; fixed bridge
        # parts are BRIDGE_UNCHARTED) are passable with a caution. Block code 4 is no longer produced and
        # accept_unknown_clearance has no effect.
        unk_block = np.zeros(len(depth), bool)
        reason = np.full(len(depth), -1, np.int64)
        # format 1.3: PROHIBITED (code 0) is no longer a block reason; entry-prohibited areas are yellow and cost more
        conds = [np.zeros(len(depth), bool),
                 ((fl & P.F_OUTSIDE) > 0) & prof.avoid_open_gulf,
                 ~(depth_ok | maint_ok), clr_block, unk_block]
        for k in reversed(range(len(conds))):
            reason[conds[k]] = k
        self.ok = reason < 0
        self.reason = reason
        self.via_maint = via_maint & self.ok
        self.via_sound = depth_ok & ((band == P.DEPTH_NONE) | (band < req)) & self.ok
        self.needs_opening = opening & has_ovh & ((clr == P.CLR_UNKNOWN) | (clr < air))
        self.unknown_used = unk & ~opening & has_ovh
        self.restricted = (fl & P.F_RESTRICTED) > 0
        self.lock = (fl & P.F_LOCK) > 0
        self.prohibited = (fl & P.F_PROHIBITED) > 0
        self.uncharted = (fl & P.F_BRIDGE_UNCHARTED) > 0
        # spec B.9: the yellow reasons of each triangle as a bit mask (bit k = YELLOW_REASONS[k])
        cz = (a["quality"] & 7).astype(np.int64)
        conds = [self.via_maint, self.via_sound, self.needs_opening, self.lock, self.uncharted, self.unknown_used,
                 self.prohibited, self.restricted, (fl & P.F_CAUTION) > 0, (fl & P.F_HAZARD_DEPTH) > 0,
                 np.isin(cz, LOW_QUALITY_CATZOC),
                 ~self.via_maint & ((depth - req) < THIN_MARGIN_DM) & np.isin(cz, THIN_MARGIN_CATZOC)]
        bits = np.zeros(len(depth), np.int64)
        for k, c in enumerate(conds):
            bits |= np.where(c, 1 << k, 0)
        self.ybits = bits
        # cost factor, multiplied in the spec's order
        f = np.ones(len(depth))
        hw = (fl & P.F_HIGHWAY) > 0
        ch = (fl & P.F_CHANNEL) > 0
        f = np.where(hw, f * F_HIGHWAY_FACTOR, np.where(ch, f * F_CHANNEL_FACTOR, f))
        shore = (fl >> P.SHORE_SHIFT) & 3
        f = np.where(shore == 0, f * SHORE_FACTOR[0], np.where(shore == 1, f * SHORE_FACTOR[1], f))
        f = np.where((fl & P.F_NEAR_HAZARD) > 0, f * NEAR_HAZARD_FACTOR, f)
        spare = depth - req
        f = np.where(via_maint, f * MAINTAINED_FACTOR,
                     np.where(spare < 3, f * SPARE_LT_3DM_FACTOR, np.where(spare < 10, f * SPARE_LT_10DM_FACTOR, f)))
        f = np.where(self.via_sound, f * SOUNDING_FACTOR, f)
        f = np.where(self.prohibited, f * PROHIBITED_FACTOR, np.where(self.restricted, f * RESTRICTED_FACTOR, f))
        f = np.where((fl & P.F_CAUTION) > 0, f * CAUTION_FACTOR, f)
        self.factor = f
        self.req, self.air = req, air


# --------------------------------------------------------------------------- geometry helpers

def orient(ax, ay, bx, by, cx, cy) -> int:
    return (bx - ax) * (cy - ay) - (by - ay) * (cx - ax)


class Router:
    def __init__(self, pack: P.Pack):
        self.p = pack
        self.V = pack.vertices.astype(np.int64)
        self.T = pack.tris.astype(np.int64)
        self.nbr = pack.nbr
        self._nbr_l = pack.nbr.tolist()
        self._tri_l = pack.tris.tolist()
        self._vx = self.V[:, 0].tolist()
        self._vy = self.V[:, 1].tolist()
        g = pack.grid
        self.g = g
        # hazard / overhead bounding boxes (units)
        self.hz_bb = self._bboxes(pack.hazards)
        self.ov_bb = self._bboxes(pack.overhead)

    def _bboxes(self, recs):
        if len(recs) == 0:
            return np.zeros((0, 4), np.int64)
        out = np.zeros((len(recs), 4), np.int64)
        for i, r in enumerate(recs):
            c = self.p.geom[r["geom_first"]: r["geom_first"] + r["geom_count"]].astype(np.int64)
            out[i] = [c[:, 0].min(), c[:, 1].min(), c[:, 0].max(), c[:, 1].max()]
        return out

    # ----------------------------------------------------------- B.6 point location and snapping
    def cell_range(self, x, y):
        g = self.g
        j = min(max((x - g["origin_lon"]) // g["cell"], 0), g["nx"] - 1)
        i = min(max((y - g["origin_lat"]) // g["cell"], 0), g["ny"] - 1)
        return i, j

    def cell_ids(self, i, j):
        g = self.g
        c = i * g["nx"] + j
        return g["ids"][g["offsets"][c]: g["offsets"][c + 1]]

    def contains(self, t, x, y) -> bool:
        a, b, c = self._tri_l[t]
        vx, vy = self._vx, self._vy
        return (orient(vx[a], vy[a], vx[b], vy[b], x, y) >= 0 and orient(vx[b], vy[b], vx[c], vy[c], x, y) >= 0
                and orient(vx[c], vy[c], vx[a], vy[a], x, y) >= 0)

    def locate(self, x, y):
        b = self.p.bbox
        if not (b[0] <= x <= b[2] and b[1] <= y <= b[3]):
            return None
        i, j = self.cell_range(x, y)
        for t in self.cell_ids(i, j).tolist():
            if self.contains(t, x, y):
                return t
        return None

    def snap(self, lon, lat, cls: Classified, max_m=MAX_SNAP_M):
        x, y = to_units(lon), to_units(lat)
        b = self.p.bbox
        if x is None or y is None or not (b[0] <= x <= b[2] and b[1] <= y <= b[3]):
            return {"error": "OUTSIDE_PACK"}
        t = self.locate(x, y)
        if t is not None and cls.ok[t]:
            return {"triangle": int(t), "x": x, "y": y, "snap_m": 0.0, "in_mesh": True,
                    "located": int(t)}
        lat0 = y / UNITS
        lon0 = x / UNITS
        kx = K_M_PER_DEG * math.cos(lat0 * DEG)
        ky = K_M_PER_DEG
        rx = math.ceil(max_m / kx * UNITS)
        ry = math.ceil(max_m / ky * UNITS)
        i0, j0 = self.cell_range(x - rx, y - ry)
        i1, j1 = self.cell_range(x + rx, y + ry)
        g = self.g
        cand = set()
        for i in range(i0, i1 + 1):
            for j in range(j0, j1 + 1):
                cand.update(self.cell_ids(i, j).tolist())
        cand = np.array(sorted(c for c in cand if cls.ok[c]), dtype=np.int64)
        if len(cand) == 0:
            return {"error": "NO_WATER_NEARBY", "located": None if t is None else int(t)}
        P3 = self.V[self.T[cand]]  # (n,3,2)
        X = (P3[:, :, 0] / UNITS - lon0) * kx
        Y = (P3[:, :, 1] / UNITS - lat0) * ky
        best_d, best_t, best_pt = math.inf, -1, None
        for n in range(len(cand)):
            d, qx, qy = closest_on_triangle(X[n], Y[n])
            if d < best_d:
                best_d, best_t, best_pt = d, int(cand[n]), (qx, qy)
        if best_d > max_m:
            return {"error": "NO_WATER_NEARBY", "located": None if t is None else int(t),
                    "nearest_m": best_d}
        sx = to_units(lon0 + best_pt[0] / kx)
        sy = to_units(lat0 + best_pt[1] / ky)
        if not self.contains(best_t, sx, sy):
            # The rounded point fell outside the snapped triangle: take the nearest of the eight
            # surrounding whole-unit points and the triangle's vertices that the triangle contains.
            a, b_, c = self._tri_l[best_t]
            cands = [(sx + i, sy + j) for j in (-1, 0, 1) for i in (-1, 0, 1) if (i, j) != (0, 0)]
            cands += [(self._vx[v], self._vy[v]) for v in (a, b_, c)]
            pick = None
            for px, py in cands:
                if self.contains(best_t, px, py):
                    dd = math.hypot((px / UNITS - lon0) * kx, (py / UNITS - lat0) * ky)
                    if pick is None or dd < pick[0]:
                        pick = (dd, px, py)
            sx, sy = pick[1], pick[2]
        snap_m = math.hypot((sx / UNITS - lon0) * kx, (sy / UNITS - lat0) * ky)
        return {"triangle": best_t, "x": sx, "y": sy, "snap_m": snap_m, "in_mesh": t is not None,
                "located": None if t is None else int(t)}

    # ----------------------------------------------------------- B.7 A*
    def edge_mid(self, t, k):
        a = self._tri_l[t][k]
        b = self._tri_l[t][(k + 1) % 3]
        return ((self._vx[a] + self._vx[b]) / 2e7, (self._vy[a] + self._vy[b]) / 2e7)

    def penalties(self, cls):
        """Spec B.5 entry penalties, in order."""
        return [(cls.needs_opening, OPENING_PENALTY_M), (cls.unknown_used, UNKNOWN_CLR_PENALTY_M),
                (cls.restricted, RESTRICTED_PENALTY_M), (cls.lock, LOCK_PENALTY_M),
                (cls.prohibited, PROHIBITED_PENALTY_M), (cls.uncharted, UNCHARTED_BRIDGE_PENALTY_M)]

    def astar(self, s, gt, S, G, ok, factor, penalties, extra_pen=None):
        ok = ok.tolist() if isinstance(ok, np.ndarray) else ok
        factor = factor.tolist()
        pens = [(m.tolist(), v) for m, v in penalties]
        pb = extra_pen.tolist() if extra_pen is not None else None
        gx, gy = G
        gcost = {s: 0.0}
        pos = {s: S}
        came = {s: -1}
        closed = set()
        seq = 0
        heap = [(FMIN * dist_m(S[0], S[1], gx, gy), seq, s)]
        expanded = 0
        nbr = self._nbr_l
        while heap:
            _, _, t = heapq.heappop(heap)
            if t in closed:
                continue
            closed.add(t)
            expanded += 1
            if t == gt:
                break
            px, py = pos[t]
            gt_ = gcost[t]
            ft = factor[t]
            for k in range(3):
                u = nbr[t][k]
                if u < 0 or u in closed or not ok[u]:
                    continue
                mx, my = self.edge_mid(t, k)
                step = dist_m(px, py, mx, my) * ((ft + factor[u]) * 0.5)
                for m, v in pens:
                    if m[u] and not m[t]:
                        step += v
                if pb is not None and pb[u] and not pb[t]:
                    step += BLOCKED_PENALTY_M
                ng = gt_ + step
                if ng < gcost.get(u, math.inf):
                    gcost[u] = ng
                    pos[u] = (mx, my)
                    came[u] = t
                    seq += 1
                    heapq.heappush(heap, (ng + FMIN * dist_m(mx, my, gx, gy), seq, u))
        if gt not in closed:
            return None, expanded
        path = [gt]
        while came[path[-1]] != -1:
            path.append(came[path[-1]])
        return path[::-1], expanded

    # ----------------------------------------------------------- B.8 funnel
    def portals(self, corridor):
        out = []
        for t, u in zip(corridor[:-1], corridor[1:]):
            k = self._nbr_l[t].index(u)
            a = self._tri_l[t][k]
            b = self._tri_l[t][(k + 1) % 3]
            out.append(((self._vx[b], self._vy[b]), (self._vx[a], self._vy[a])))  # (left, right)
        return out

    # ----------------------------------------------------------- B.10 leg validation
    def validate_leg(self, A, B, prof: Profile):
        """Returns (violations, crossings)."""
        p = self.p
        x0, x1 = min(A[0], B[0]), max(A[0], B[0])
        y0, y1 = min(A[1], B[1]), max(A[1], B[1])
        latm = (A[1] + B[1]) / 2e7
        lonm = (A[0] + B[0]) / 2e7
        kx = K_M_PER_DEG * math.cos(latm * DEG)
        ky = K_M_PER_DEG

        def loc(c):
            return ((c[:, 0] / UNITS - lonm) * kx, (c[:, 1] / UNITS - latm) * ky)
        seg = np.array([A, B], dtype=np.int64)
        sx, sy = loc(seg)
        check_m = p.check_dm / 10.0
        mx = math.ceil((check_m + 1) / kx * UNITS)
        my = math.ceil((check_m + 1) / ky * UNITS)
        viol, cross = [], []
        req, air = prof.req_dm, prof.air_dm
        if len(self.hz_bb):
            bb = self.hz_bb
            cand = np.flatnonzero((bb[:, 0] <= x1 + mx) & (bb[:, 2] >= x0 - mx) & (bb[:, 1] <= y1 + my) & (bb[:, 3] >= y0 - my))
            for h in cand.tolist():
                r = p.hazards[h]
                v = int(r["valsou_dm"])
                if not (v == P.DEPTH_NONE or v < req):
                    continue
                c = p.geom[r["geom_first"]: r["geom_first"] + r["geom_count"]].astype(np.int64)
                hx, hy = loc(c)
                d = seg_geom_distance(sx, sy, hx, hy, int(r["geom_type"]))
                if d < check_m:
                    viol.append({"kind": "HAZARD", "record": int(h), "distance_m": d, "valsou_dm": v})
        if len(self.ov_bb):
            bb = self.ov_bb
            ox = math.ceil((OVERHEAD_POINT_M + 1) / kx * UNITS)
            oy = math.ceil((OVERHEAD_POINT_M + 1) / ky * UNITS)
            cand = np.flatnonzero((bb[:, 0] <= x1 + ox) & (bb[:, 2] >= x0 - ox) & (bb[:, 1] <= y1 + oy)
                                  & (bb[:, 3] >= y0 - oy)).tolist()
            geoms = {}
            lines = []
            for o in cand:
                r = p.overhead[o]
                c = p.geom[r["geom_first"]: r["geom_first"] + r["geom_count"]].tolist()
                gt = int(r["geom_type"])
                if gt == 2:
                    c = dedupe_consecutive(c)
                    if len(c) == 1:
                        gt = 1  # a polyline whose points are all equal is a point object
                    else:
                        lines.append((o, c))
                geoms[o] = (gt, c)
            crossed_lines = polyline_crossings(A, B, lines)
            for o in cand:
                r = p.overhead[o]
                gt, c = geoms[o]
                if gt == 2:
                    if o not in crossed_lines:
                        continue
                else:
                    hx, hy = loc(np.array(c, dtype=np.int64).reshape(-1, 2))
                    if not seg_crosses(sx, sy, hx, hy, gt):
                        continue
                clr = int(r["clearance_dm"])
                opening = bool(r["flags"] & 1)
                item = {"record": int(o), "clearance_dm": clr, "opening": opening}
                if opening:
                    item["needs_opening"] = clr == P.CLR_UNKNOWN or clr < air
                elif clr == P.CLR_UNKNOWN:
                    # no charted clearance (a fixed bridge part, a cable or a pipe): passed with a caution
                    item["uncharted"] = True
                elif clr < air:
                    viol.append({"kind": "CLEARANCE", "record": int(o), "clearance_dm": clr})
                cross.append(item)
        return viol, cross

    # ----------------------------------------------------------- full query
    def route(self, start, goal, prof: Profile, max_snap_m=MAX_SNAP_M) -> dict:
        p = self.p
        if not request_is_valid(prof, max_snap_m):
            return {"ok": False, "error": "INVALID_REQUEST", "profile": asdict(prof), "data_date": int(p.data_date)}
        cls = Classified(p, prof)
        res = {"ok": False, "profile": asdict(prof), "req_dm": cls.req, "air_dm": cls.air,
               "data_date": int(p.data_date)}
        ends = []
        for name, (lon, lat) in (("start", start), ("goal", goal)):
            sn = self.snap(lon, lat, cls, max_snap_m)
            if "error" in sn:
                res["error"] = f"{name.upper()}_{sn['error']}"
                res[name] = sn
                return res
            ends.append(sn)
            res[name] = {"lon": sn["x"] / UNITS, "lat": sn["y"] / UNITS, "x": sn["x"], "y": sn["y"],
                         "triangle": sn["triangle"], "snap_m": round(sn["snap_m"], 3), "in_mesh": sn["in_mesh"]}
        s, g = ends[0]["triangle"], ends[1]["triangle"]
        S = (ends[0]["x"] / UNITS, ends[0]["y"] / UNITS)
        G = (ends[1]["x"] / UNITS, ends[1]["y"] / UNITS)
        corridor, expanded = self.astar(s, g, S, G, cls.ok, cls.factor, self.penalties(cls))
        res["expanded"] = expanded
        if corridor is None:
            res["error"] = "NO_ROUTE"
            res.update(self.blocked_report(s, g, S, G, cls, prof))
            return res
        S_u, G_u = (ends[0]["x"], ends[0]["y"]), (ends[1]["x"], ends[1]["y"])
        if S_u == G_u:  # start equal to goal: one waypoint, no legs, the B.7 corridor
            pts, leg_tris = [(S_u, len(corridor))], []
        else:
            pts, leg_tris = self.plan_legs(S_u, G_u, corridor, cls)
            corridor = [corridor[0]]
            for lt in leg_tris:
                corridor += lt[1:]
        legs, violations = self.grade(corridor, pts, leg_tris, cls, prof)
        if violations:
            res["error"] = "LEG_VALIDATION"
            res["violations"] = violations
            res["corridor"] = corridor
            return res
        res["ok"] = True
        res["corridor"] = corridor
        res["waypoints"] = [[x / UNITS, y / UNITS] for (x, y), _ in pts]
        res["waypoints_units"] = [[x, y] for (x, y), _ in pts]
        res["legs"] = legs
        res["summary"] = self.summary(corridor, legs, cls)
        return res

    def tri_centroid(self, t):
        a, b, c = self._tri_l[t]
        return ((self._vx[a] + self._vx[b] + self._vx[c]) // 3, (self._vy[a] + self._vy[b] + self._vy[c]) // 3)

    # ----------------------------------------------------------- B.8 leg planning
    def contains_strictly(self, t, p) -> bool:
        a, b, c = self._tri_l[t]
        vx, vy = self._vx, self._vy
        x, y = p
        return (orient(vx[a], vy[a], vx[b], vy[b], x, y) > 0 and orient(vx[b], vy[b], vx[c], vy[c], x, y) > 0
                and orient(vx[c], vy[c], vx[a], vy[a], x, y) > 0)

    def walk(self, A, tA, B, tB, admissible):
        """Spec B.8 straight walk from point A in triangle tA to point B, which must end in
        triangle tB. Returns the triangles crossed, in order, or None."""
        tl, nb, vx, vy = self._tri_l, self._nbr_l, self._vx, self._vy
        t = tA
        out = [t]
        ax, ay = A
        bx, by = B
        for _ in range(len(tl)):
            if t == tB:
                return out
            if self.contains(t, bx, by):
                return None  # B reached in another triangle
            v = tl[t]
            o = [orient(ax, ay, bx, by, vx[x], vy[x]) for x in v]
            k = -1
            for e in range(3):
                if o[e] < 0 and o[(e + 1) % 3] > 0:
                    k = e
                    break
            if k < 0:
                return None  # the segment meets a vertex, or leaves backwards
            u = nb[t][k]
            if u < 0 or not admissible(u):
                return None
            out.append(u)
            t = u
        return None

    def plan_legs(self, S, G, corridor, cls: Classified):
        """Spec B.8: legs by greedy visibility over the corridor's portal midpoints (exact straight
        walks through passable triangles that add no yellow reason), with the funnel as fallback.
        Returns (waypoints [(point, portal index)], per-leg triangle lists)."""
        n = len(corridor)
        ports = self.portals(corridor)
        P_ = [(S, S)] + ports + [(G, G)]
        ok = cls.ok.tolist()
        yb = cls.ybits.tolist()

        def target(j):
            if j == n:
                return G
            (xl, yl), (xr, yr) = P_[j]
            t = corridor[j]
            o = [v for v in self._tri_l[t] if (self._vx[v], self._vy[v]) not in ((xl, yl), (xr, yr))][0]
            # barycentric (0.4, 0.4, 0.2): just inside c[j], next to the middle of the portal
            m = ((2 * xl + 2 * xr + self._vx[o]) // 5, (2 * yl + 2 * yr + self._vy[o]) // 5)
            return m if self.contains_strictly(t, m) else None

        A, ia, tA = S, 0, corridor[0]
        pts, legs = [(S, 0)], []
        while True:
            def visible(j):
                T = target(j)
                if T is None or T == A:
                    return None
                Y = 0
                for t in corridor[ia:min(j, n - 1) + 1]:
                    Y |= yb[t]
                tT = corridor[min(j, n - 1)]
                return self.walk(A, tA, T, tT, lambda u: ok[u] and (yb[u] & ~Y) == 0)
            seq = visible(ia + 1)
            if seq is not None:
                lo, step = ia + 1, 1
                while lo + step <= n:
                    w = visible(lo + step)
                    if w is None:
                        break
                    lo, seq = lo + step, w
                    step *= 2
                hi = min(lo + step, n + 1)
                while hi - lo > 1:
                    mid = (lo + hi) // 2
                    w = visible(mid)
                    if w is None:
                        hi = mid
                    else:
                        lo, seq = mid, w
                B, jb = target(lo), lo
            else:
                f = funnel(A, G, P_[ia + 1:n])
                B, k = f[1]
                jb = ia + k
                seq = list(corridor[ia:min(jb, n - 1) + 1])
            pts.append((B, jb))
            legs.append(seq)
            if jb == n:
                return pts, legs
            A, ia, tA = B, jb, corridor[jb]

    # ----------------------------------------------------------- B.9 grading
    def grade(self, corridor, pts, leg_tris, cls: Classified, prof: Profile):
        a = self.p.attrs
        legs, violations = [], []
        lo = 0
        for j, tl in enumerate(leg_tris):
            (A, _), (B, _) = pts[j], pts[j + 1]
            hi = lo + len(tl) - 1
            tt = np.array(tl, dtype=np.int64)
            bits = int(np.bitwise_or.reduce(cls.ybits[tt]))
            reasons = [r for k, r in enumerate(YELLOW_REASONS) if bits >> k & 1]
            depth = a["depth_dm"][tt].astype(int)
            charted = ~cls.via_maint[tt]
            v, cr = self.validate_leg(A, B, prof)
            for x in v:
                x["leg"] = j
            violations += v
            length = dist_m(A[0] / UNITS, A[1] / UNITS, B[0] / UNITS, B[1] / UNITS)
            legs.append({
                "from": [A[0] / UNITS, A[1] / UNITS], "to": [B[0] / UNITS, B[1] / UNITS],
                "triangles": [lo, hi], "length_m": length,
                "grade": "yellow" if reasons else "green", "reasons": reasons,
                "min_depth_dm": int(depth.min()),
                "min_spare_dm": int((depth[charted] - cls.req).min()) if charted.any() else None,
                "crossings": cr,
            })
            lo = hi
        return legs, violations

    def summary(self, corridor, legs, cls: Classified):
        p = self.p
        a = p.attrs
        tt = np.array(corridor, dtype=np.int64)
        depth = a["depth_dm"][tt].astype(int)
        k = int(np.argmin(depth))
        cx, cy = self.tri_centroid(int(tt[k]))
        clr = a["clearance_dm"][tt].astype(int)
        known = clr < P.CLR_UNKNOWN
        low = None
        if known.any():
            idx = np.flatnonzero(known)
            m = int(idx[np.argmin(clr[idx])])
            ov = int(a["overhead"][tt[m]])
            low = {"clearance_dm": int(clr[m]), "overhead": ov,
                   "name": p.string(int(p.overhead[ov]["name"])) if ov != P.ID_NONE else "",
                   "opening": bool(a["flags"][tt[m]] & P.F_OPENING)}

        def runs(mask, item):
            out, prev = [], False
            for i, t in enumerate(tt.tolist()):
                if mask[t] and not prev:
                    x, y = self.tri_centroid(t)
                    out.append({"corridor_index": i, **item(t), "lon": x / UNITS, "lat": y / UNITS})
                prev = bool(mask[t])
            return out

        def overhead_item(t):
            ov = int(a["overhead"][t])
            return {"overhead": ov, "clearance_dm": int(a["clearance_dm"][t]),
                    "name": p.string(int(p.overhead[ov]["name"])) if ov != P.ID_NONE else ""}

        def unknown_item(t):
            d = overhead_item(t)
            ov = d["overhead"]
            d["kind"] = int(p.overhead[ov]["kind"]) if ov != P.ID_NONE else 0
            return d

        def lock_item(t):
            ar = int(a["area"][t])
            return {"area": ar, "name": p.string(int(p.areas[ar]["name"])) if ar != P.ID_NONE else ""}
        adv = sorted({i for k in set(a["advisory"][tt].tolist()) for i in p.advisory_sets[k]})
        advisories = [{"area": i, "kind": int(p.areas[i]["kind"]), "source": int(p.areas[i]["source"]),
                       "name": p.string(int(p.areas[i]["name"])), "text": p.string(int(p.areas[i]["text"]))}
                      for i in adv]
        total = sum((l["length_m"] for l in legs), 0.0)
        return {
            "distance_m": total, "distance_nm": total / 1852.0, "legs": len(legs),
            "green_legs": sum(l["grade"] == "green" for l in legs),
            "yellow_legs": sum(l["grade"] == "yellow" for l in legs),
            "shallowest": {"depth_dm": int(depth[k]), "triangle": int(tt[k]), "lon": cx / UNITS, "lat": cy / UNITS,
                           "maintained": bool(cls.via_maint[tt[k]])},
            "lowest_clearance": low,
            "openings": runs(cls.needs_opening, overhead_item),
            "unknown_clearances": runs(cls.unknown_used, unknown_item),
            "locks": runs(cls.lock, lock_item),
            "uncharted_bridges": runs(cls.uncharted, overhead_item),
            "prohibited_areas": runs(cls.prohibited, lock_item),
            "advisories": advisories,
            "maintained_triangles": int(cls.via_maint[tt].sum()),
            "data_date": int(p.data_date),
        }

    # ----------------------------------------------------------- B.11 no-route report
    def blocked_report(self, s, g, S, G, cls: Classified, prof: Profile):
        ok = np.ones(len(cls.ok), bool)
        blocked = ~cls.ok
        factor = np.where(blocked, BLOCKED_FACTOR, cls.factor)
        corridor, _ = self.astar(s, g, S, G, ok, factor, self.penalties(cls), extra_pen=blocked)
        if corridor is None:
            # Disconnected water: no option can connect it, so every hint is false (no search needed).
            hints = {opt: False for opt in ("use_maintained",) if not getattr(prof, opt)}
            return {"reason": "NOT_CONNECTED", "blocked": [], "hints": hints}
        a = self.p.attrs
        out, prev = [], False
        for i, t in enumerate(corridor):
            if blocked[t] and not prev:
                x, y = self.tri_centroid(t)
                ov = int(a["overhead"][t])
                ar = int(a["area"][t])
                out.append({"corridor_index": i, "triangle": int(t), "reason": BLOCK_REASONS[int(cls.reason[t])],
                            "lon": x / UNITS, "lat": y / UNITS, "depth_dm": int(a["depth_dm"][t]),
                            "maint_dm": int(a["maint_dm"][t]), "clearance_dm": int(a["clearance_dm"][t]),
                            "overhead": self.p.string(int(self.p.overhead[ov]["name"])) if ov != P.ID_NONE else "",
                            "area": self.p.string(int(self.p.areas[ar]["name"])) if ar != P.ID_NONE else ""})
            prev = bool(blocked[t])
        hints = {}
        for opt in ("use_maintained",):   # accept_unknown_clearance can no longer open a route (round 4)
            if getattr(prof, opt):
                continue
            c2 = Classified(self.p, Profile(**{**asdict(prof), opt: True}))
            if not (c2.ok[s] and c2.ok[g]):
                hints[opt] = False
                continue
            cor2, _ = self.astar(s, g, S, G, c2.ok, c2.factor, self.penalties(c2))
            hints[opt] = cor2 is not None
        return {"reason": out[0]["reason"] if out else "NOT_CONNECTED", "blocked": out, "hints": hints}


# --------------------------------------------------------------------------- pure functions

def closest_on_triangle(X, Y):
    """Closest point of the triangle (X[3], Y[3]) to the origin, in a planar
    frame. Returns (distance, qx, qy)."""
    inside = True
    for k in range(3):
        ax, ay, bx, by = X[k], Y[k], X[(k + 1) % 3], Y[(k + 1) % 3]
        if (bx - ax) * (0 - ay) - (by - ay) * (0 - ax) < 0:
            inside = False
    if inside:
        return 0.0, 0.0, 0.0
    best = (math.inf, 0.0, 0.0)
    for k in range(3):
        ax, ay, bx, by = X[k], Y[k], X[(k + 1) % 3], Y[(k + 1) % 3]
        qx, qy = closest_on_segment(ax, ay, bx, by, 0.0, 0.0)
        d = math.hypot(qx, qy)
        if d < best[0]:
            best = (d, qx, qy)
    return best


def closest_on_segment(ax, ay, bx, by, px, py):
    dx, dy = bx - ax, by - ay
    L2 = dx * dx + dy * dy
    if L2 == 0:
        return ax, ay
    s = ((px - ax) * dx + (py - ay) * dy) / L2
    s = 0.0 if s < 0 else (1.0 if s > 1 else s)
    return ax + s * dx, ay + s * dy


def _seg_seg_dist(ax, ay, bx, by, cx, cy, dx, dy):
    def o(px, py, qx, qy, rx, ry):
        return (qx - px) * (ry - py) - (qy - py) * (rx - px)
    d1, d2 = o(ax, ay, bx, by, cx, cy), o(ax, ay, bx, by, dx, dy)
    d3, d4 = o(cx, cy, dx, dy, ax, ay), o(cx, cy, dx, dy, bx, by)
    if ((d1 > 0) != (d2 > 0)) and ((d3 > 0) != (d4 > 0)) and d1 != 0 and d2 != 0 and d3 != 0 and d4 != 0:
        return 0.0
    best = math.inf
    for (px, py), (sa, sb) in (((cx, cy), ((ax, ay), (bx, by))), ((dx, dy), ((ax, ay), (bx, by))),
                               ((ax, ay), ((cx, cy), (dx, dy))), ((bx, by), ((cx, cy), (dx, dy)))):
        qx, qy = closest_on_segment(sa[0], sa[1], sb[0], sb[1], px, py)
        best = min(best, math.hypot(px - qx, py - qy))
    return best


def seg_geom_distance(sx, sy, hx, hy, gtype) -> float:
    """Distance (metres, local frame) between segment (sx[0..1], sy) and a
    point (1), polyline (2) or polygon ring (3; 0 inside)."""
    ax, ay, bx, by = float(sx[0]), float(sy[0]), float(sx[1]), float(sy[1])
    n = len(hx)
    if gtype == 1 or n == 1:
        qx, qy = closest_on_segment(ax, ay, bx, by, float(hx[0]), float(hy[0]))
        return math.hypot(qx - hx[0], qy - hy[0])
    best = math.inf
    m = n if gtype == 3 else n - 1
    for i in range(m):
        j = (i + 1) % n
        d = _seg_seg_dist(ax, ay, bx, by, float(hx[i]), float(hy[i]), float(hx[j]), float(hy[j]))
        if d < best:
            best = d
            if d == 0.0:
                return 0.0
    if gtype == 3 and point_in_ring(ax, ay, hx, hy):
        return 0.0
    return best


def seg_crosses(sx, sy, hx, hy, gtype) -> bool:
    """Spec B.10 for point objects and rings, in the leg's local metric frame (polylines use the
    exact integer rule of polyline_crossings). Point: within 1 m. Ring: some part of the leg lies
    strictly inside the ring; merely touching its boundary (a leg along the edge of an adjacent
    bridge part) does not count."""
    ax, ay, bx, by = float(sx[0]), float(sy[0]), float(sx[1]), float(sy[1])
    if gtype == 1 or len(hx) == 1:
        return seg_geom_distance(sx, sy, hx, hy, 1) <= OVERHEAD_POINT_M
    n = len(hx)
    dx, dy = bx - ax, by - ay
    params = [0.0, 1.0]
    for i in range(n):
        j = (i + 1) % n
        cx, cy, ex, ey = float(hx[i]), float(hy[i]), float(hx[j]), float(hy[j])
        fx, fy = ex - cx, ey - cy
        den = dx * fy - dy * fx
        if den != 0.0:
            s = ((cx - ax) * fy - (cy - ay) * fx) / den
            u = ((cx - ax) * dy - (cy - ay) * dx) / den
            if 0.0 <= s <= 1.0 and 0.0 <= u <= 1.0:
                params.append(s)
        L2 = dx * dx + dy * dy
        if L2 > 0.0:  # ring vertices on (or collinear with) the leg
            for px, py in ((cx, cy), (ex, ey)):
                s = ((px - ax) * dx + (py - ay) * dy) / L2
                if 0.0 <= s <= 1.0:
                    qx, qy = ax + s * dx, ay + s * dy
                    if math.hypot(px - qx, py - qy) <= 1e-6:
                        params.append(s)
    params = sorted(set(params))
    for s0, s1 in zip(params[:-1], params[1:]):
        if s1 - s0 <= 1e-12:
            continue
        sm = 0.5 * (s0 + s1)
        mx, my = ax + sm * dx, ay + sm * dy
        if point_in_ring(mx, my, hx, hy) and ring_boundary_distance(mx, my, hx, hy) > 1e-6:
            return True
    return False


def dedupe_consecutive(pts):
    """Polyline points with consecutive duplicates removed."""
    out = [tuple(pts[0])]
    for q in pts[1:]:
        q = tuple(q)
        if q != out[-1]:
            out.append(q)
    return out


def polyline_crossings(A, B, lines) -> set:
    """Spec B.10 polyline rule, exact on integer units. `lines` is [(record, points)] with
    consecutive duplicate points removed (at least 2 points). Returns the records the leg AB
    passes under:
      1. AB properly crosses one of its segments (all four orientations non-zero, opposite pairs);
      2. AB overlaps one of its segments collinearly over a positive length;
      3. A or B lies on the polyline (closed segments);
      4. AB passes through a point V strictly between A and B where polyline vertices meet, and the
         polyline arms leaving V (the neighbouring vertices, over every polyline record with a
         vertex at V) lie strictly on both sides of AB: every record with an arm at V is crossed.
    A leg that only touches a polyline (at a vertex whose arms all lie on one side, for example the
    end of a line on the edge of its footprint) does not pass under it."""
    ax, ay = A
    bx, by = B
    dx, dy = bx - ax, by - ay
    L2 = dx * dx + dy * dy
    crossed = set()
    arms = {}

    def on_segment(px, py, c, d):
        return (orient(c[0], c[1], d[0], d[1], px, py) == 0 and min(c[0], d[0]) <= px <= max(c[0], d[0])
                and min(c[1], d[1]) <= py <= max(c[1], d[1]))

    for rec, pts in lines:
        m = len(pts)
        hit = False
        for i in range(m - 1):
            c, d = pts[i], pts[i + 1]
            o1 = orient(ax, ay, bx, by, c[0], c[1])
            o2 = orient(ax, ay, bx, by, d[0], d[1])
            o3 = orient(c[0], c[1], d[0], d[1], ax, ay)
            o4 = orient(c[0], c[1], d[0], d[1], bx, by)
            if o1 and o2 and o3 and o4 and (o1 > 0) != (o2 > 0) and (o3 > 0) != (o4 > 0):
                hit = True
            elif o1 == 0 and o2 == 0:
                tc = (c[0] - ax) * dx + (c[1] - ay) * dy
                td = (d[0] - ax) * dx + (d[1] - ay) * dy
                if max(min(tc, td), 0) < min(max(tc, td), L2):
                    hit = True
            if on_segment(ax, ay, c, d) or on_segment(bx, by, c, d):
                hit = True
        for i, (vx, vy) in enumerate(pts):
            if orient(ax, ay, bx, by, vx, vy) != 0:
                continue
            t = (vx - ax) * dx + (vy - ay) * dy
            if not 0 < t < L2:
                continue
            for k in (i - 1, i + 1):
                if 0 <= k < m:
                    side = orient(ax, ay, bx, by, pts[k][0], pts[k][1])
                    if side != 0:
                        e = arms.setdefault((vx, vy), [False, False, set()])
                        e[0 if side > 0 else 1] = True
                        e[2].add(rec)
        if hit:
            crossed.add(rec)
    for pos, neg, recs in arms.values():
        if pos and neg:
            crossed |= recs
    return crossed


def ring_boundary_distance(px, py, hx, hy) -> float:
    n = len(hx)
    best = math.inf
    for i in range(n):
        j = (i + 1) % n
        qx, qy = closest_on_segment(float(hx[i]), float(hy[i]), float(hx[j]), float(hy[j]), px, py)
        best = min(best, math.hypot(px - qx, py - qy))
    return best


def point_in_ring(px, py, hx, hy) -> bool:
    inside = False
    n = len(hx)
    j = n - 1
    for i in range(n):
        if (hy[i] > py) != (hy[j] > py):
            xin = hx[i] + (py - hy[i]) * (hx[j] - hx[i]) / (hy[j] - hy[i])
            if px < xin:
                inside = not inside
        j = i
    return inside


def tri2(a, b, c) -> int:
    return (b[0] - a[0]) * (c[1] - a[1]) - (b[1] - a[1]) * (c[0] - a[0])


def funnel(S, G, ports):
    """Spec B.8: simple stupid funnel on integer coordinates. ports are
    (left, right) per corridor portal. Returns [(point, portal index)]."""
    P_ = [(S, S)] + list(ports) + [(G, G)]
    path = [(S, 0)]
    apex, left, right = S, P_[0][0], P_[0][1]
    ai = li = ri = 0
    i = 1
    while i < len(P_):
        pl, pr = P_[i]
        if tri2(apex, right, pr) >= 0:
            if apex == right or tri2(apex, left, pr) < 0:
                right, ri = pr, i
            else:
                path.append((left, li))
                apex, ai = left, li
                left = right = apex
                li = ri = ai
                i = ai + 1
                continue
        if tri2(apex, left, pl) <= 0:
            if apex == left or tri2(apex, right, pl) > 0:
                left, li = pl, i
            else:
                path.append((right, ri))
                apex, ai = right, ri
                left = right = apex
                li = ri = ai
                i = ai + 1
                continue
        i += 1
    if path[-1][0] != G:
        path.append((G, len(P_) - 1))
    out = [path[0]]
    for q in path[1:]:
        if q[0] != out[-1][0]:
            out.append(q)
    if out[-1][1] != len(P_) - 1:  # goal coincides with the last apex
        out[-1] = (out[-1][0], len(P_) - 1)
    return out
