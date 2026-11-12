"""Offline tests of the pure-logic parts, on tiny synthetic geometries."""
from __future__ import annotations

import math
import textwrap

import geopandas as gpd
import numpy as np
import pytest
import shapely
from shapely.geometry import LineString, Point, Polygon, box

from enc_routing import catalog, merge


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
