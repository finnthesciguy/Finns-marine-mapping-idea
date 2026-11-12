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
