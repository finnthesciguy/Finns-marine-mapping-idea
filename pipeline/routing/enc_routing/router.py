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
BLOCKED_FACTOR = 50.0
BLOCKED_PENALTY_M = 100000.0
MAX_SNAP_M = 750.0
THIN_MARGIN_DM = 3

# block reasons (spec B.3), in precedence order
BLOCK_REASONS = ["PROHIBITED", "OPEN_GULF", "DEPTH", "CLEARANCE", "UNKNOWN_CLEARANCE"]
# yellow reasons (spec B.9), in report order
YELLOW_REASONS = ["MAINTAINED_DEPTH", "SOUNDING_DEPTH", "BRIDGE_OPENING", "UNKNOWN_CLEARANCE",
                  "RESTRICTED_AREA", "CAUTION_AREA", "HAZARD_PROXIMITY", "LOW_DATA_QUALITY",
                  "THIN_MARGIN"]


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


def to_units(deg: float) -> int:
    return math.floor(deg * UNITS + 0.5)


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
        unk_block = has_ovh & ~opening & known_ok & unk & (not prof.accept_unknown_clearance)
        reason = np.full(len(depth), -1, np.int64)
        conds = [(fl & P.F_PROHIBITED) > 0,
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
        f = np.where(self.restricted, f * RESTRICTED_FACTOR, f)
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
        if not (b[0] <= x <= b[2] and b[1] <= y <= b[3]):
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
        return {"triangle": best_t, "x": sx, "y": sy, "snap_m": best_d, "in_mesh": t is not None,
                "located": None if t is None else int(t)}

    # ----------------------------------------------------------- B.7 A*
    def edge_mid(self, t, k):
        a = self._tri_l[t][k]
        b = self._tri_l[t][(k + 1) % 3]
        return ((self._vx[a] + self._vx[b]) / 2e7, (self._vy[a] + self._vy[b]) / 2e7)

    def astar(self, s, gt, S, G, ok, factor, pen_open, pen_unk, pen_rest, extra_pen=None):
        ok = ok.tolist() if isinstance(ok, np.ndarray) else ok
        factor = factor.tolist()
        po = pen_open.tolist()
        pu = pen_unk.tolist()
        pr = pen_rest.tolist()
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
                if po[u] and not po[t]:
                    step += OPENING_PENALTY_M
                if pu[u] and not pu[t]:
                    step += UNKNOWN_CLR_PENALTY_M
                if pr[u] and not pr[t]:
                    step += RESTRICTED_PENALTY_M
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
            cand = np.flatnonzero((bb[:, 0] <= x1) & (bb[:, 2] >= x0) & (bb[:, 1] <= y1) & (bb[:, 3] >= y0))
            for o in cand.tolist():
                r = p.overhead[o]
                c = p.geom[r["geom_first"]: r["geom_first"] + r["geom_count"]].astype(np.int64)
                hx, hy = loc(c)
                gt = int(r["geom_type"])
                if not seg_crosses(sx, sy, hx, hy, gt):
                    continue
                clr = int(r["clearance_dm"])
                opening = bool(r["flags"] & 1)
                item = {"record": int(o), "clearance_dm": clr, "opening": opening}
                if opening:
                    item["needs_opening"] = clr == P.CLR_UNKNOWN or clr < air
                elif clr == P.CLR_UNKNOWN:
                    if not prof.accept_unknown_clearance:
                        viol.append({"kind": "UNKNOWN_CLEARANCE", "record": int(o)})
                elif clr < air:
                    viol.append({"kind": "CLEARANCE", "record": int(o), "clearance_dm": clr})
                cross.append(item)
        return viol, cross

    # ----------------------------------------------------------- full query
    def route(self, start, goal, prof: Profile, max_snap_m=MAX_SNAP_M) -> dict:
        p = self.p
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
        corridor, expanded = self.astar(s, g, S, G, cls.ok, cls.factor, cls.needs_opening,
                                        cls.unknown_used, cls.restricted)
        res["expanded"] = expanded
        if corridor is None:
            res["error"] = "NO_ROUTE"
            res.update(self.blocked_report(s, g, S, G, cls, prof))
            return res
        pts = funnel((ends[0]["x"], ends[0]["y"]), (ends[1]["x"], ends[1]["y"]), self.portals(corridor))
        legs, violations = self.grade(corridor, pts, cls, prof)
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

    # ----------------------------------------------------------- B.9 grading
    def grade(self, corridor, pts, cls: Classified, prof: Profile):
        a = self.p.attrs
        legs, violations = [], []
        n = len(corridor)
        cz = (a["quality"] & 7).astype(int)
        for j in range(len(pts) - 1):
            (A, pa), (B, pb) = pts[j], pts[j + 1]
            lo, hi = pa, max(pa, pb - 1)
            hi = min(hi, n - 1)
            tl = corridor[lo: hi + 1]
            tt = np.array(tl, dtype=np.int64)
            reasons = []
            depth = a["depth_dm"][tt].astype(int)
            fl = a["flags"][tt].astype(int)
            if cls.via_maint[tt].any():
                reasons.append("MAINTAINED_DEPTH")
            if cls.via_sound[tt].any():
                reasons.append("SOUNDING_DEPTH")
            if cls.needs_opening[tt].any():
                reasons.append("BRIDGE_OPENING")
            if cls.unknown_used[tt].any():
                reasons.append("UNKNOWN_CLEARANCE")
            if (fl & P.F_RESTRICTED).any():
                reasons.append("RESTRICTED_AREA")
            if (fl & P.F_CAUTION).any():
                reasons.append("CAUTION_AREA")
            if (fl & P.F_HAZARD_DEPTH).any():
                reasons.append("HAZARD_PROXIMITY")
            q = cz[tt]
            if np.isin(q, [0, 5, 6]).any():
                reasons.append("LOW_DATA_QUALITY")
            charted = ~cls.via_maint[tt]
            thin = charted & ((depth - cls.req) < THIN_MARGIN_DM) & np.isin(q, [0, 4, 5, 6])
            if thin.any():
                reasons.append("THIN_MARGIN")
            v, cr = self.validate_leg(A, B, prof)
            for x in v:
                x["leg"] = j
            violations += v
            length = dist_m(A[0] / UNITS, A[1] / UNITS, B[0] / UNITS, B[1] / UNITS)
            mi = int(np.argmin(depth))
            legs.append({
                "from": [A[0] / UNITS, A[1] / UNITS], "to": [B[0] / UNITS, B[1] / UNITS],
                "triangles": [lo, hi], "length_m": length,
                "grade": "yellow" if reasons else "green", "reasons": reasons,
                "min_depth_dm": int(depth[mi]),
                "min_spare_dm": int((depth[charted] - cls.req).min()) if charted.any() else None,
                "crossings": cr,
            })
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

        def runs(mask):
            out, prev = [], False
            for i, t in enumerate(tt.tolist()):
                if mask[t] and not prev:
                    ov = int(a["overhead"][t])
                    x, y = self.tri_centroid(t)
                    out.append({"corridor_index": i, "overhead": ov, "clearance_dm": int(a["clearance_dm"][t]),
                                "name": p.string(int(p.overhead[ov]["name"])) if ov != P.ID_NONE else "",
                                "lon": x / UNITS, "lat": y / UNITS})
                prev = bool(mask[t])
            return out
        total = sum(l["length_m"] for l in legs)
        return {
            "distance_m": total, "distance_nm": total / 1852.0, "legs": len(legs),
            "green_legs": sum(l["grade"] == "green" for l in legs),
            "yellow_legs": sum(l["grade"] == "yellow" for l in legs),
            "shallowest": {"depth_dm": int(depth[k]), "triangle": int(tt[k]), "lon": cx / UNITS, "lat": cy / UNITS,
                           "maintained": bool(cls.via_maint[tt[k]])},
            "lowest_clearance": low,
            "openings": runs(cls.needs_opening),
            "unknown_clearances": runs(cls.unknown_used),
            "maintained_triangles": int(cls.via_maint[tt].sum()),
            "data_date": int(p.data_date),
        }

    # ----------------------------------------------------------- B.11 no-route report
    def blocked_report(self, s, g, S, G, cls: Classified, prof: Profile):
        ok = np.ones(len(cls.ok), bool)
        blocked = ~cls.ok
        factor = np.where(blocked, BLOCKED_FACTOR, cls.factor)
        corridor, _ = self.astar(s, g, S, G, ok, factor, cls.needs_opening, cls.unknown_used, cls.restricted,
                                 extra_pen=blocked)
        if corridor is None:
            return {"reason": "NOT_CONNECTED", "blocked": []}
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
        for opt in ("use_maintained", "accept_unknown_clearance"):
            if getattr(prof, opt):
                continue
            c2 = Classified(self.p, Profile(**{**asdict(prof), opt: True}))
            if not (c2.ok[s] and c2.ok[g]):
                hints[opt] = False
                continue
            cor2, _ = self.astar(s, g, S, G, c2.ok, c2.factor, c2.needs_opening, c2.unknown_used, c2.restricted)
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
    """Spec B.10: does the leg pass under an overhead object? Point: within
    1 m. Polyline: segment-segment distance 0 (touching counts). Ring: some
    part of the leg lies strictly inside the ring; merely touching its
    boundary (a leg along the edge of an adjacent bridge part) does not count."""
    ax, ay, bx, by = float(sx[0]), float(sy[0]), float(sx[1]), float(sy[1])
    if gtype == 1 or len(hx) == 1:
        return seg_geom_distance(sx, sy, hx, hy, 1) <= 1.0
    if gtype == 2:
        return seg_geom_distance(sx, sy, hx, hy, 2) == 0.0
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
