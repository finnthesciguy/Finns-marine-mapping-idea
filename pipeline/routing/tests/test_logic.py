"""Offline tests of the pure-logic parts, on tiny synthetic geometries."""
from __future__ import annotations

import math
import textwrap

import geopandas as gpd
import numpy as np
import pytest
import shapely
from shapely.geometry import LineString, Point, Polygon, box

from enc_routing import bridges, catalog, graph, merge, route, safewater
from enc_routing.config import BoatProfile


# ------------------------------------------------------------------ catalog

CAT = textwrap.dedent("""\
    <EncProductCatalog>
      <cell><name>US5XX1AA</name><lname>Harbour</lname><cscale>12000</cscale><status>Active</status>
        <zipfile_location>https://example.invalid/US5XX1AA.zip</zipfile_location><zipfile_size>10</zipfile_size>
        <edtn>2</edtn><updn>1</updn><uadt>2025-01-01</uadt><isdt>2026-01-01</isdt>
        <cov><panel><panel_no>1</panel_no><type>E</type>
          <vertex><lat>27.0</lat><long>-82.5</long></vertex><vertex><lat>27.0</lat><long>-82.4</long></vertex>
          <vertex><lat>27.1</lat><long>-82.4</long></vertex><vertex><lat>27.1</lat><long>-82.5</long></vertex>
        </panel>
        <panel><panel_no>2</panel_no><type>I</type>
          <vertex><lat>27.04</lat><long>-82.46</long></vertex><vertex><lat>27.04</lat><long>-82.44</long></vertex>
          <vertex><lat>27.06</lat><long>-82.44</long></vertex><vertex><lat>27.06</lat><long>-82.46</long></vertex>
        </panel></cov></cell>
      <cell><name>US4XX1BB</name><lname>Far</lname><cscale>45000</cscale><status>Active</status>
        <zipfile_location>u</zipfile_location><zipfile_size>5</zipfile_size><edtn>1</edtn><updn>0</updn>
        <uadt/><isdt>2026-01-01</isdt>
        <cov><panel><type>E</type>
          <vertex><lat>30</lat><long>-80</long></vertex><vertex><lat>30</lat><long>-79</long></vertex>
          <vertex><lat>31</lat><long>-79</long></vertex></panel></cov></cell>
      <cell><name>US3XX1CC</name><lname>Cancelled</lname><cscale>180000</cscale><status>Cancelled</status>
        <zipfile_location>u</zipfile_location><zipfile_size>5</zipfile_size><edtn>1</edtn><updn>0</updn>
        <cov><panel><type>E</type>
          <vertex><lat>26</lat><long>-83</long></vertex><vertex><lat>26</lat><long>-82</long></vertex>
          <vertex><lat>28</lat><long>-82</long></vertex></panel></cov></cell>
    </EncProductCatalog>""")


def test_catalog_parse_and_select(tmp_path):
    p = tmp_path / "cat.xml"
    p.write_text(CAT)
    cells = catalog.parse_catalog(p)
    assert [c.name for c in cells] == ["US5XX1AA", "US4XX1BB", "US3XX1CC"]
    a = cells[0]
    assert a.band == 5 and a.band_name == "harbour" and a.edtn == 2 and a.updn == 1
    # interior panel is a hole
    assert not a.coverage.contains(Point(-82.45, 27.05))
    assert a.coverage.contains(Point(-82.48, 27.02))
    sel = catalog.select_cells(cells, (-83, 26.5, -82, 27.5))
    assert [c.name for c in sel] == ["US5XX1AA"]  # far cell outside, cancelled cell dropped


# ------------------------------------------------------------------ merge

def test_priority_key_orders_band_then_scale_then_date():
    keys = sorted([("US4A", 4, 45000, "20260101"), ("US5B", 5, 22000, "20250101"),
                   ("US5C", 5, 12000, "20240101"), ("US5D", 5, 12000, "20260101")],
                  key=lambda r: merge.priority_key(r[1], r[2], r[3]))
    assert [k[0] for k in keys] == ["US5D", "US5C", "US5B", "US4A"]


def test_exclusive_regions_no_overlap_no_gap():
    # two harbour cells side by side with a 1 m hairline gap, one approach cell under both
    h1, h2 = box(0, 0, 100, 100), box(101, 0, 200, 100)
    app = box(-50, -50, 250, 150)
    excl, st = merge.exclusive_regions([("US5H1", h1), ("US5H2", h2), ("US4AP", app)], close_m=5)
    assert excl["US5H1"].equals(h1) and excl["US5H2"].equals(h2)
    # the approach cell does not get the 1 m hairline between the harbour cells
    assert not excl["US4AP"].intersects(box(100.2, 10, 100.8, 90))
    assert st["sliver_pieces"] == 1 and st["sliver_area_m2"] == pytest.approx(100, rel=0.01)
    # no double counting
    total = sum(g.area for g in excl.values())
    assert total == pytest.approx(shapely.union_all(list(excl.values())).area)


def test_is_sliver():
    assert merge.is_sliver(box(0, 0, 1000, 2))
    assert not merge.is_sliver(box(0, 0, 50, 50))


def test_clip_to_region_keeps_dimension():
    reg = box(0, 0, 10, 10)
    g = gpd.GeoDataFrame({"a": [1, 2, 3]},
                         geometry=[box(5, 5, 15, 15), box(20, 20, 30, 30), box(10, 0, 20, 10)])
    out = merge.clip_to_region(g, reg)
    # partial overlap clipped; disjoint dropped; edge-touching polygon -> empty (no stray line)
    assert list(out.a) == [1]
    assert out.geometry.iloc[0].equals(box(5, 5, 10, 10))


def test_same_dim_drops_lower_dimensions():
    gc = shapely.GeometryCollection([box(0, 0, 1, 1), LineString([(2, 2), (3, 3)]), Point(5, 5)])
    assert merge.same_dim(gc, 2).equals(box(0, 0, 1, 1))


# ------------------------------------------------------------------ safe water

def test_chart_metres_matches_noaa_rounding():
    assert safewater.chart_metres(6) == 1.8
    assert safewater.chart_metres(12) == 3.6
    assert safewater.chart_metres(3) == 0.9
    assert safewater.chart_metres(30) == 9.1
    assert safewater.chart_metres(18) == 5.4
    assert safewater.chart_metres(36) == 10.9
    assert safewater.chart_metres(9) == 2.7


def test_depth_ok_uses_rounded_feet():
    d = [1.8, 0.9, np.nan, -0.3, 2.7]
    assert list(safewater.depth_ok(d, 6)) == [True, False, False, False, True]
    assert list(safewater.depth_ok(d, 5)) == [True, False, False, False, True]


def test_hazard_blocks():
    v = [np.nan, 1.0, 3.0]
    assert list(safewater.hazard_blocks(v, [3, 3, 3], 6)) == [True, True, False]


def _toy_areas():
    # 0..100 deep (DRVAL1 3.6), 100..200 shoal (0.9), 200..300 deep again
    geoms = [box(0, 0, 100, 100), box(100, 0, 200, 100), box(200, 0, 300, 100)]
    return gpd.GeoDataFrame({"DRVAL1": [3.6, 0.9, 3.6], "cls": "DEPARE"}, geometry=geoms)


def test_safe_water_connectivity_by_threshold():
    areas = _toy_areas()
    obst = box(40, 0, 60, 30)  # a jetty
    haz = gpd.GeoDataFrame({"VALSOU": [np.nan], "WATLEV": [3]}, geometry=[Point(250, 50).buffer(10)])
    w3 = safewater.safe_water(areas, obst, haz, 3)
    w6 = safewater.safe_water(areas, obst, haz, 6)
    assert len(safewater.components(w3)) == 1
    assert len(safewater.components(w6)) == 2  # the 0.9 m band cuts the deep water in two
    assert not w6.contains(Point(250, 50))      # hazard removed
    assert not w3.contains(Point(50, 10))       # jetty removed


def test_which_component_snaps():
    parts = [box(0, 0, 10, 10), box(100, 0, 110, 10)]
    assert safewater.which_component(parts, Point(5, 5)) == 0
    assert safewater.which_component(parts, Point(95, 5)) is None
    assert safewater.which_component(parts, Point(95, 5), snap_m=6) == 1


# ------------------------------------------------------------------ bridges

def test_effective_clearance():
    assert bridges.effective_clearance("1", 6.7, None) == (6.7, False)
    assert bridges.effective_clearance("5", None, 7.6) == (7.6, True)
    assert bridges.effective_clearance("3,1", 2.0, None) == (2.0, True)
    assert bridges.effective_clearance(None, None, None) == (None, False)


# ------------------------------------------------------------------ mesh + router

def _l_corridor_mesh():
    """An L-shaped channel 20 m wide: east along y in [0,20] to x=100, then
    north along x in [80,100] to y=100. Triangulated with the real CDT path."""
    poly = Polygon([(0, 0), (100, 0), (100, 100), (80, 100), (80, 20), (0, 20)])
    faces = [poly.intersection(box(0, 0, 50, 20)), poly.intersection(box(50, 0, 100, 100))]
    coords, tris, face_of = graph.triangulate_faces(faces)
    nbr, nm = graph.triangle_adjacency(tris)
    T = len(tris)
    mesh = route.Mesh(coords, tris, nbr,
                      depth_m=np.full(T, 3.6, np.float32), proj_m=np.full(T, np.nan, np.float32),
                      clear_m=np.full(T, np.inf, np.float32), flags=np.zeros(T, np.uint8))
    return mesh, poly, nm


def test_triangulation_shares_edges_across_faces():
    mesh, poly, nm = _l_corridor_mesh()
    assert nm == 0
    tri_area = sum(shapely.polygons(mesh.coords[mesh.tris]).tolist(), start=0) if False else \
        float(np.sum(shapely.area(shapely.polygons(mesh.coords[mesh.tris]))))
    assert tri_area == pytest.approx(poly.area)
    # triangles are CCW
    p = mesh.coords[mesh.tris]
    cross = (p[:, 1, 0] - p[:, 0, 0]) * (p[:, 2, 1] - p[:, 0, 1]) - (p[:, 1, 1] - p[:, 0, 1]) * (p[:, 2, 0] - p[:, 0, 0])
    assert (cross > 0).all()
    # the two faces are connected: the graph is one component
    seen, stack = {0}, [0]
    while stack:
        t = stack.pop()
        for u in mesh.nbr[t]:
            if u >= 0 and u not in seen:
                seen.add(int(u)); stack.append(int(u))
    assert len(seen) == len(mesh.tris)


def test_route_turns_the_corner_and_stays_inside():
    mesh, poly, _ = _l_corridor_mesh()
    opt = route.Options(boat=BoatProfile(4.5, 1.5, 20))
    res, st = route.route(mesh, (5, 10), (90, 95), opt)
    assert res is not None, st
    path = LineString(res["path"])
    assert poly.buffer(1e-6).contains(path)
    # it must bend near the inner corner (80, 20), not cut across land
    assert len(res["path"]) >= 3
    corner = min(np.linalg.norm(np.asarray(res["path"][1:-1]) - [80, 20], axis=1))
    assert corner < 15
    # the corner is nudged off the land corner, into the water (x > 80, y < 20)
    assert st["corners_nudged"] >= 1
    assert all(p[0] > 80 and p[1] < 20 for p in res["path"][1:-1] if np.linalg.norm(p - [80, 20]) < 15)
    # and be close to the true shortest length through the shrunken corner
    best = math.dist((5, 10), (80, 20)) + math.dist((80, 20), (90, 95))
    assert path.length < best * 1.1


def test_route_respects_depth_and_air_draft():
    mesh, poly, _ = _l_corridor_mesh()
    cen = mesh.centroids
    # make the north leg shallow -> no route for a 6 ft requirement
    shallow = cen[:, 1] > 50
    mesh.depth_m[shallow] = 0.9
    opt = route.Options(boat=BoatProfile(4.5, 1.5, 20))
    res, st = route.route(mesh, (5, 10), (90, 95), opt, snap_m=0)
    assert res is None
    # ... unless the USACE project depth is trusted there
    mesh.proj_m[shallow] = 2.7
    res, st = route.route(mesh, (5, 10), (90, 95), route.Options(use_project_depth=True), snap_m=0)
    assert res is not None and st["corridor_triangles_relying_on_project_depth"] > 0
    # low fixed bridge on the east leg blocks a 20 ft air draft
    mesh.depth_m[:] = 3.6
    bridge = (cen[:, 1] < 20) & (cen[:, 0] > 50)
    mesh.clear_m[bridge] = 4.0
    res, st = route.route(mesh, (5, 10), (90, 95), opt, snap_m=0)
    assert res is None
    # an opening bridge with the same closed clearance can be used
    mesh.flags[bridge] |= graph.F_OPENING
    res, st = route.route(mesh, (5, 10), (90, 95), opt, snap_m=0)
    assert res is not None and st["opening_bridges_triangles"] > 0
    res, st = route.route(mesh, (5, 10), (90, 95), route.Options(allow_openings=False), snap_m=0)
    assert res is None


def test_funnel_straight_line_when_unobstructed():
    ports = [((10, 5), (10, -5)), ((20, 5), (20, -5))]
    p = route.funnel((0, 0), (30, 0), ports)
    assert p.tolist() == [[0.0, 0.0], [30.0, 0.0]]


def test_fix_degenerate_splits_t_junction():
    coords = np.array([[0, 0], [1, 0], [2, 0], [1, 1], [1, -1]], float)
    a, b, c, x, y = range(5)
    tris = np.array([[a, c, x], [a, y, b], [b, y, c], [a, b, c]])  # last one is flat
    t2, f2 = graph.fix_degenerate(coords, tris, np.arange(4))
    assert len(t2) == 4
    nbr, nm = graph.triangle_adjacency(t2)
    assert nm == 0
    assert (nbr >= 0).sum() == 2 * 4  # 4 interior edges, each seen from both sides


def test_funnel_works_at_utm_magnitudes():
    """The funnel must behave the same at UTM magnitudes (northing ~3e6 m),
    where relative float tolerances (np.allclose) become tens of metres."""
    mesh, poly, _ = _l_corridor_mesh()
    off = np.array([350000.0, 3000000.0])
    mesh.coords = mesh.coords + off
    res, st = route.route(mesh, tuple(off + (5, 10)), tuple(off + (90, 95)), route.Options())
    path = LineString(res["path"] - off)
    assert poly.buffer(1e-6).contains(path)


def test_route_zigzag_channel_stays_inside():
    poly = LineString([(0, 0), (40, 0), (40, 40), (80, 40), (80, 0), (120, 0), (120, 40)]).buffer(
        5, cap_style="flat", join_style="mitre")
    faces = [poly.intersection(box(x, -10, x + 30, 60)) for x in range(-10, 140, 30)]
    faces = [f for f in faces if not f.is_empty]
    c, t, _ = graph.triangulate_faces(faces)
    n, nm = graph.triangle_adjacency(t)
    T = len(t)
    m = route.Mesh(c, t, n, np.full(T, 3.6, np.float32), np.full(T, np.nan, np.float32),
                   np.full(T, np.inf, np.float32), np.zeros(T, np.uint8))
    res, st = route.route(m, (1, 0), (120, 39), route.Options())
    assert res is not None and nm == 0
    assert poly.buffer(0.01).contains(LineString(res["path"]))
    assert st["corners"] >= 4
