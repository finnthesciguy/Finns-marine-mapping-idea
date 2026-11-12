"""Passability, cost, grading, snapping and funnel rules (format spec part B)."""
from __future__ import annotations

import numpy as np
import pytest

from enc_routing import layers, packfmt as P, synth
from enc_routing.router import Classified, Profile, Router, dist_m, funnel, req_dm, tri2


@pytest.fixture(scope="module")
def rt(synth_pack):
    return Router(P.read_pack(synth_pack))


def test_req_dm_truncation_rule():
    # NOAA writes feet converted and truncated to 0.1 m
    assert req_dm(6) == 18 and req_dm(12) == 36 and req_dm(36) == 109 and req_dm(65) == 198
    # fractional requirements round UP to whole feet first (conservative)
    assert req_dm(5.5) == 18 and req_dm(6.1) == 21 and req_dm(4.5 + 1.5) == 18
    assert layers.req_dm(9) == req_dm(9) == 27
    assert layers.ft_to_chart_dm([9, 43, np.nan]).tolist() == [27, 131, -32768]
    assert layers.to_dm([1.8, 0.0, -0.6, np.nan]).tolist() == [18, 0, -6, -32768]


def test_distance_metric():
    # 0.001 deg of latitude = 111.195 m with R = 6371008.8
    assert dist_m(-82, 27, -82, 27.001) == pytest.approx(111.19508, abs=1e-4)
    assert dist_m(-82, 27, -81.999, 27) == pytest.approx(111.19508 * np.cos(np.radians(27)), abs=1e-4)


def _tri(rt, c, r, upper=False):
    """Triangle id of grid square (c, r) of the synthetic pack."""
    x = synth.LON0 + c * synth.STEP + (3000 if upper else 7000)
    y = synth.LAT0 + r * synth.STEP + (7000 if upper else 3000)
    return rt.locate(x, y)


def test_passability_depth_and_maintained(rt):
    cls = Classified(rt.p, Profile(4, 1, 20))
    shoal = _tri(rt, 3, 1)
    assert not cls.ok[shoal] and cls.reason[shoal] == 2  # DEPTH
    cls2 = Classified(rt.p, Profile(4, 1, 20, use_maintained=True))
    assert cls2.ok[shoal] and cls2.via_maint[shoal]
    assert cls2.factor[shoal] == pytest.approx(0.8 * 3.0)  # highway, maintained


def test_maintained_never_overrides_hazard():
    pk = synth.build_synthetic()
    pk.attrs["flags"] = pk.attrs["flags"].copy()
    pk.attrs["maint_dm"] = np.full(len(pk.tris), 60)
    cls = Classified(pk, Profile(10, 1, 20, use_maintained=True))  # needs 33 dm
    hz = (pk.attrs["flags"] & P.F_HAZARD_DEPTH) > 0
    assert hz.any() and not cls.ok[hz].any()


def test_passability_clearance(rt):
    fixed = _tri(rt, 5, 2)        # fixed bridge, 30 dm
    opening = _tri(rt, 5, 1)      # opening bridge, closed 18 dm
    cable = _tri(rt, 2, 3)        # unknown clearance
    lo = Classified(rt.p, Profile(4, 1, 9))       # air 27 dm
    hi = Classified(rt.p, Profile(4, 1, 11))      # air 33 dm
    assert lo.ok[fixed] and not hi.ok[fixed] and hi.reason[fixed] == 3
    assert lo.ok[opening] and lo.needs_opening[opening] and hi.needs_opening[opening]
    low6 = Classified(rt.p, Profile(4, 1, 5))     # air 15 dm < 18: no opening needed
    assert low6.ok[opening] and not low6.needs_opening[opening]
    assert not lo.ok[cable] and lo.reason[cable] == 4
    acc = Classified(rt.p, Profile(4, 1, 9, accept_unknown_clearance=True))
    assert acc.ok[cable] and acc.unknown_used[cable]


def test_prohibited_and_outside(rt):
    pro = _tri(rt, 6, 3)
    for prof in (Profile(1, 0, 1), Profile(1, 0, 1, True, True)):
        cls = Classified(rt.p, prof)
        assert not cls.ok[pro] and cls.reason[pro] == 0


def test_cost_factor_order(rt):
    cls = Classified(rt.p, Profile(4, 1, 20))
    t = _tri(rt, 0, 0)  # 6 dm, shore class 0, caution? no (col 0)
    cls1 = Classified(rt.p, Profile(1, 0, 1))  # needs 3 dm: spare 3 -> 1.1
    assert cls1.factor[t] == pytest.approx(1.5 * 1.1)
    c = _tri(rt, 1, 0)  # caution square
    assert cls1.factor[c] == pytest.approx(1.5 * 1.1 * 1.25)
    r = _tri(rt, 6, 2)  # restricted, 21 dm, needs 18: spare 3 -> 1.1
    assert cls.factor[r] == pytest.approx(1.1 * 2.0)


def test_locate_and_snap(rt):
    cls = Classified(rt.p, Profile(1, 0.5, 5))
    # inside a triangle: exact
    s = rt.snap(-81.9995, 27.0015, cls)
    assert s["snap_m"] == 0 and s["in_mesh"]
    # inside the island (missing square col 2 row 0): snapped to the nearest edge
    s = rt.snap(-81.9975, 27.0005, cls, 200)
    assert not s["in_mesh"] and s["snap_m"] == pytest.approx(0.0005 * 111195.08 * np.cos(np.radians(27.0005)), rel=1e-3)
    assert rt.snap(-82.01, 27.0015, cls)["error"] == "OUTSIDE_PACK"
    assert rt.snap(-81.9975, 27.0005, cls, 10)["error"] == "NO_WATER_NEARBY"


def test_funnel_straight_and_corner():
    # straight corridor: two squares side by side, portal is the shared edge
    S, G = (0, 5), (20, 5)
    pts = funnel(S, G, [((10, 10), (10, 0))])
    assert [p for p, _ in pts] == [S, G]
    # L-shaped corridor A [0,10]^2 -> B [10,20]x[0,10] -> C [10,20]x[10,20]: must turn at (10, 10)
    ports = [((10, 10), (10, 0)), ((10, 10), (20, 10))]
    pts = funnel((5, 5), (12, 18), ports)
    assert pts == [((5, 5), 0), ((10, 10), 2), ((12, 18), 3)]
    # turning the other way (right turn) around (10, 0)
    ports = [((10, 10), (10, 0)), ((20, 0), (10, 0))]
    pts = funnel((5, 5), (12, -8), ports)
    assert pts == [((5, 5), 0), ((10, 0), 2), ((12, -8), 3)]


def test_funnel_stays_in_corridor(rt):
    """Every straightened leg lies inside the union of its triangles."""
    import shapely

    res = rt.route((-81.9995, 27.0015), (-81.9925, 27.0015),
                   Profile(4, 1, 8, accept_unknown_clearance=True))
    assert res["ok"]
    V = rt.p.vertices
    for leg in res["legs"]:
        lo, hi = leg["triangles"]
        tris = [res["corridor"][i] for i in range(lo, hi + 1)]
        poly = shapely.union_all([shapely.Polygon(V[rt.p.tris[t]]) for t in tris]).buffer(1)
        a = [round(v * 1e7) for v in leg["from"]]
        b = [round(v * 1e7) for v in leg["to"]]
        assert poly.covers(shapely.LineString([a, b]))


def test_grading_reasons(rt):
    res = rt.route((-81.9995, 27.0015), (-81.9925, 27.0015), Profile(4, 1, 20, use_maintained=True))
    assert res["ok"] and len(res["legs"]) == 1
    leg = res["legs"][0]
    assert leg["grade"] == "yellow" and leg["reasons"] == ["MAINTAINED_DEPTH", "BRIDGE_OPENING"]
    s = res["summary"]
    assert s["openings"][0]["name"] == "Test Opening Bridge" and s["shallowest"]["depth_dm"] == 9
    assert s["shallowest"]["maintained"] is True


def test_no_route_reports_blocked_place_and_hint(rt):
    res = rt.route((-81.9995, 27.0015), (-81.9925, 27.0015), Profile(4, 1, 20))
    assert not res["ok"] and res["error"] == "NO_ROUTE"
    assert res["blocked"][0]["reason"] == "DEPTH" and res["blocked"][0]["maint_dm"] == 27
    assert res["hints"] == {"use_maintained": True, "accept_unknown_clearance": True}


def test_leg_validation_catches_a_hazard(rt):
    prof = Profile(10, 1, 20)  # 33 dm > wreck 15 dm
    A = (synth.LON0 + 40000, synth.LAT0 + 25000)
    B = (synth.LON0 + 50000, synth.LAT0 + 25000)
    v, _ = rt.validate_leg(A, B, prof)
    assert v and v[0]["kind"] == "HAZARD"
    v, cr = rt.validate_leg((synth.LON0 + 50000, synth.LAT0 + 15000), (synth.LON0 + 60000, synth.LAT0 + 15000),
                            Profile(4, 1, 20))
    assert not v and cr[0]["needs_opening"]


def test_tri2_exact_on_large_coordinates():
    a, b, c = (-826000000, 273000000), (-825999999, 273000000), (-825999998, 273000000)
    assert tri2(a, b, c) == 0


# ------------------------------------------------------------------ B.10 polyline rule (exact)

from enc_routing.router import polyline_crossings, request_is_valid  # noqa: E402

POLY_CASES = [
    # (name, A, B, lines, crossed records)
    ("proper crossing", (0, 0), (10, 0), [(0, [(5, -5), (5, 5)])], {0}),
    ("misses", (0, 0), (10, 0), [(0, [(5, 1), (5, 5)])], set()),
    ("line ends on the leg", (0, 0), (10, 0), [(0, [(5, 0), (5, 5)])], set()),
    ("kink touches the leg", (0, 0), (10, 0), [(0, [(3, 4), (5, 0), (7, 4)])], set()),
    ("crosses through a vertex", (0, 0), (10, 0), [(0, [(3, 4), (5, 0), (7, -4)])], {0}),
    ("two parts meet on the leg, opposite sides", (0, 0), (10, 0), [(0, [(5, -5), (5, 0)]), (1, [(5, 0), (5, 5)])],
     {0, 1}),
    ("two parts meet on the leg, same side", (0, 0), (10, 0), [(0, [(4, 5), (5, 0)]), (1, [(5, 0), (6, 5)])], set()),
    ("collinear overlap", (0, 0), (10, 0), [(0, [(-5, 0), (3, 0)])], {0}),
    ("collinear, only an end point shared", (0, 0), (10, 0), [(0, [(10, 0), (20, 0)])], {0}),
    ("collinear, beyond the leg", (0, 0), (10, 0), [(0, [(11, 0), (20, 0)])], set()),
    ("leg starts on the line", (5, 0), (10, 3), [(0, [(0, 0), (10, 0)])], {0}),
    ("leg ends at the line's end", (0, 3), (5, 0), [(0, [(5, 0), (5, -5)])], {0}),
    ("collinear arm through the vertex", (0, 0), (10, 0), [(0, [(5, 5), (5, 0), (8, 0)])], {0}),
]


@pytest.mark.parametrize("case", POLY_CASES, ids=[c[0] for c in POLY_CASES])
def test_polyline_rule(case):
    name, A, B, lines, want = case
    big = [(r, [(x - 826000000, y + 273000000) for x, y in pts]) for r, pts in lines]
    sh = lambda p: (p[0] - 826000000, p[1] + 273000000)  # noqa: E731
    assert polyline_crossings(sh(A), sh(B), big) == want
    assert polyline_crossings(sh(B), sh(A), big) == want  # direction-symmetric


def test_leg_along_a_row_boundary_is_not_under_the_cable_end(rt):
    """The leg runs along the edge of the cable's footprint and touches the end of its line:
    not a crossing. The overhead point 0.44 m away (outside the leg's bounding box) is one."""
    A = (synth.LON0 + 10000, synth.LAT0 + 20000)
    B = (synth.LON0 + 70000, synth.LAT0 + 20000)
    for a, b in ((A, B), (B, A)):
        v, cr = rt.validate_leg(a, b, Profile(1, 0.5, 30))
        assert not v and [c["record"] for c in cr] == [3]
    v, cr = rt.validate_leg((synth.LON0 + 20000, synth.LAT0 + 25000), (synth.LON0 + 30000, synth.LAT0 + 25000),
                            Profile(1, 0.5, 5))
    assert [x["kind"] for x in v] == ["UNKNOWN_CLEARANCE"] and cr[0]["record"] == 2


# ------------------------------------------------------------------ B.6 snapping and B.13 inputs

def test_snapped_point_is_inside_its_triangle():
    """B.6: the whole-unit snapped point always lies in (or on) the snapped triangle."""
    from conftest import TESTDATA

    rs = Router(P.read_pack(TESTDATA / "sarasota.pack"))
    b = rs.p.bbox
    rng = np.random.default_rng(3)
    moved = 0
    for prof in (Profile(4.5, 1.5, 20), Profile(1, 0.5, 5), Profile(15, 1.5, 20)):
        cls = Classified(rs.p, prof)
        for _ in range(400):
            lon = rng.uniform(b[0], b[2]) / 1e7
            lat = rng.uniform(b[1], b[3]) / 1e7
            s = rs.snap(lon, lat, cls, 750)
            if "error" in s:
                continue
            assert rs.contains(s["triangle"], s["x"], s["y"]), (lon, lat, s)
            moved += s["snap_m"] > 0
    assert moved > 100


def test_unspecified_inputs(rt):
    nan = float("nan")
    assert rt.route((nan, 27.0015), (-81.9925, 27.0015), Profile(4, 1, 20))["error"] == "START_OUTSIDE_PACK"
    assert rt.route((-81.9995, 27.0015), (float("inf"), 27.0015), Profile(4, 1, 20))["error"] == "GOAL_OUTSIDE_PACK"
    assert rt.route((-81.9995, 1e308), (-81.9925, 27.0015), Profile(4, 1, 20))["error"] == "START_OUTSIDE_PACK"
    for prof, snap in ((Profile(nan, 1, 20), 750), (Profile(4, -0.5, 20), 750), (Profile(4, 1, 1000), 750),
                       (Profile(600, 400, 20), 750), (Profile(4, 1, 20), -1), (Profile(4, 1, 20), nan),
                       (Profile(4, 1, 20), 100001)):
        assert not request_is_valid(prof, snap)
        assert rt.route((-81.9995, 27.0015), (-81.9925, 27.0015), prof, snap)["error"] == "INVALID_REQUEST"
    assert request_is_valid(Profile(0, 0, 0), 0) and request_is_valid(Profile(999, 0, 999.9), 100000)
    same = rt.route((-81.9995, 27.0015), (-81.9995, 27.0015), Profile(4, 1, 20))
    assert same["ok"] and same["legs"] == [] and len(same["waypoints_units"]) == 1
    assert same["summary"]["distance_m"] == 0.0


# ------------------------------------------------------------------ symmetry (all pairs, both directions)

SYMMETRY_PROFILES = [Profile(1, 0.5, 5), Profile(4, 1, 20), Profile(4, 1, 20, use_maintained=True),
                     Profile(4, 1, 8, accept_unknown_clearance=True),
                     Profile(5, 1, 9, use_maintained=True, accept_unknown_clearance=True), Profile(12, 1, 20)]


def _outcome(res):
    if res["ok"]:
        return "route"
    return "validation" if res["error"] == "LEG_VALIDATION" else ("no_route" if res["error"] == "NO_ROUTE" else res["error"])


def test_synthetic_all_pairs_symmetric(rt):
    """Every ordered pair of square centres under the six property-test profiles: the outcome class is
    the same in both directions, and no leg fails validation."""
    pts = [(-82.0 + 0.001 * c + 0.0005, 27.0 + 0.001 * r + 0.0005) for r in range(4) for c in range(8)]
    counts = {}
    for prof in SYMMETRY_PROFILES:
        for i, a in enumerate(pts):
            for j, b in enumerate(pts):
                if j <= i:
                    continue
                f, g = _outcome(rt.route(a, b, prof)), _outcome(rt.route(b, a, prof))
                assert f == g, (prof, a, b, f, g)
                counts[f] = counts.get(f, 0) + 2
    assert "validation" not in counts, counts
    assert counts["route"] > 4000 and counts["no_route"] > 1000
