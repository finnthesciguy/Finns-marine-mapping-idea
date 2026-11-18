"""Tiled, incremental build on synthetic chart data (offline, small tiles).

The area is 0.04 x 0.04 degrees cut into four 0.02 degree tiles. An island,
a jetty, a channel and a bridge straddle the tile edges, so the seams are
exercised. Checks: the joined mesh passes the full topology validation and a
route crosses the seams; the pack is byte-identical whatever order the tiles
are built in and whether they come from the cache; a change to one feature
rebuilds only the tiles whose inputs it touches, and gives the same pack as a
build from scratch."""
from __future__ import annotations

import datetime as dt
import hashlib
from dataclasses import replace

import geopandas as gpd
import numpy as np
import pandas as pd
import pytest
import shapely
from shapely.geometry import LineString, Point, Polygon, box

from enc_routing import packfmt as P
from enc_routing.assemble import assemble
from enc_routing.config import BuildParams, Region
from enc_routing.router import Profile, Router
from enc_routing.tiles import Source, build_tiles, load_tile, tiles_for
from enc_routing.validate import validate_pack

X0, Y0 = -82.04, 27.0          # south-west corner (multiples of the tile size)
PARAMS = BuildParams(tile_deg=0.02, coarse_grid_deg=0.01, grid_deg=0.005, fine_zone_m=300.0,
                     tile_margin_m=300.0, line_margin_m=100.0, index_cell_deg=0.005)
STAMP = dt.datetime(2026, 11, 14, 12, 0, 0, tzinfo=dt.timezone.utc)
COMMON = ["LNAM", "OBJNAM", "INFORM", "SORDAT", "SORIND", "SCAMIN"]


def frame(layer, rows, attrs=()):
    cols = {c: [r.get(c) for r in rows] for c in COMMON + list(attrs)}
    g = gpd.GeoDataFrame(cols, geometry=[r["geometry"] for r in rows], crs="EPSG:4326")
    g["cell"] = "US5TEST1"
    g["band"] = 5
    g["cscale"] = 12000
    g["isdt"] = "20261101"
    g["fkey"] = [f"US5TEST1:{r['LNAM']}" for r in rows]
    return g


def synthetic_layers(obstruction_at=(X0 + 0.031, Y0 + 0.012)):
    area = box(X0, Y0, X0 + 0.04, Y0 + 0.04)
    island = Polygon([(X0 + 0.012, Y0 + 0.015), (X0 + 0.026, Y0 + 0.016), (X0 + 0.027, Y0 + 0.026),
                      (X0 + 0.013, Y0 + 0.024)])
    channel = box(X0 + 0.0, Y0 + 0.006, X0 + 0.04, Y0 + 0.009)
    shallow = area.difference(channel)
    return {
        "DEPARE": frame("DEPARE", [
            {"LNAM": "D1", "DRVAL1": 1.8, "DRVAL2": 3.6, "geometry": shallow.difference(island)},
            {"LNAM": "D2", "DRVAL1": 5.4, "DRVAL2": 9.1, "geometry": channel}], ["DRVAL1", "DRVAL2", "QUASOU"]),
        "LNDARE": frame("LNDARE", [{"LNAM": "L1", "geometry": island}], ["CONDTN"]),
        "SLCONS": frame("SLCONS", [{"LNAM": "S1", "geometry": LineString([(X0 + 0.018, Y0 + 0.0305),
                                                                        (X0 + 0.023, Y0 + 0.0305)])}],
                        ["CATSLC", "CONDTN", "WATLEV"]),
        "OBSTRN": frame("OBSTRN", [{"LNAM": "O1", "geometry": Point(*obstruction_at)},
                                   {"LNAM": "O2", "VALSOU": 2.4, "geometry": Point(X0 + 0.005, Y0 + 0.035)}],
                        ["VALSOU", "WATLEV", "CATOBS", "QUASOU", "EXPSOU"]),
        "SOUNDG": frame("SOUNDG", [{"LNAM": f"N{k}", "DEPTH": 2.0 + 0.1 * k,
                                    "geometry": Point(X0 + 0.003 + 0.004 * (k % 9), Y0 + 0.028 + 0.002 * (k // 9))}
                                   for k in range(27)], ["DEPTH", "QUASOU", "TECSOU"]),
        "BRIDGE": frame("BRIDGE", [{"LNAM": "B1", "CATBRG": "1", "VERCLR": 19.8,
                                    "geometry": LineString([(X0 + 0.0199, Y0 + 0.004), (X0 + 0.0201, Y0 + 0.011)])}],
                        ["CATBRG", "VERCLR", "VERCCL", "VERCOP", "HORCLR"]),
        "FAIRWY": frame("FAIRWY", [{"LNAM": "F1", "OBJNAM": "Test Channel", "geometry": channel}],
                        ["ORIENT", "TRAFIC", "DRVAL1"]),
        "M_QUAL": frame("M_QUAL", [{"LNAM": "Q1", "CATZOC": 4, "SUREND": "19650101", "geometry": area}],
                        ["CATZOC", "SURSTA", "SUREND", "POSACC", "SOUACC"]),
    }


def entries_for(layers):
    meta = {"name": "US5TEST1", "edtn": "3", "updn": "1", "isdt": "20261101", "cscale": 12000}
    e = {"US5TEST1": {"path": None, "meta": meta, "excl": box(X0 - 0.01, Y0 - 0.01, X0 + 0.05, Y0 + 0.05),
                      "coverage": None, "stats": {}, "cov_source": "M_COVR", "layers": layers}}
    return e, (lambda entry: entry["layers"])


def build_pack(tmp_path, monkeypatch, layers, order=None, workers=1, name="t.pack"):
    monkeypatch.setenv("ENC_ROUTING_WORK", str(tmp_path / "work"))
    region = Region("synthtiles", (X0, Y0, X0 + 0.04, Y0 + 0.04), PARAMS)
    entries, load = entries_for(layers)
    src = Source(entries, load, {"reach": None, "line": None}, None, region.bbox, PARAMS, log=lambda *a: None)
    tiles = tiles_for(region.geometry, None, PARAMS)
    st = build_tiles(src, tiles, workers=workers, log=lambda *a: None, order=order)
    pack, rep = assemble(region, st["keys"], src, entries, load_tile, build_stamp=STAMP, log=lambda *a: None)
    path = tmp_path / name
    P.write_pack(pack, path, with_adjacency=False)
    return path, st, rep


def test_tiles_are_fixed_grid_cells():
    tiles = tiles_for(box(X0 + 0.001, Y0 + 0.001, X0 + 0.039, Y0 + 0.039), None, PARAMS)
    assert sorted(t.id for t in tiles) == ["x-4101_y1350", "x-4101_y1351", "x-4102_y1350", "x-4102_y1351"]
    assert tiles[0].rect[2] - tiles[0].rect[0] == 200_000
    # a box that only touches a tile edge does not select the tile behind it
    assert len(tiles_for(box(X0 + 0.02, Y0, X0 + 0.02 + 1e-9, Y0 + 0.01), None, PARAMS)) <= 2


def test_tiled_pack_is_valid_and_routes_across_seams(tmp_path, monkeypatch):
    path, st, rep = build_pack(tmp_path, monkeypatch, synthetic_layers())
    assert st["built"] == 4 and st["cached"] == 0
    v = validate_pack(path)
    assert v["ok"], v["errors"]
    assert rep["topology"]["ok"] and rep["topology"]["area_mismatch"] == 0
    pack = P.read_pack(path)
    # vertices on the internal tile edges are shared (the mesh is one piece across seams)
    xs = pack.vertices[:, 0]
    assert ((xs == int(round((X0 + 0.02) * 1e7)))).sum() > 4
    rt = Router(pack)
    res = rt.route((X0 + 0.004, Y0 + 0.0075), (X0 + 0.036, Y0 + 0.0365), Profile(4.5, 1.5, 20.0))
    assert res["ok"], res.get("error")
    w = np.array(res["waypoints"])
    assert w[:, 0].min() < X0 + 0.02 < w[:, 0].max() and w[:, 1].min() < Y0 + 0.02 < w[:, 1].max()


def test_pack_bytes_do_not_depend_on_build_order_or_cache(tmp_path, monkeypatch):
    a, _, _ = build_pack(tmp_path / "a", monkeypatch, synthetic_layers())
    b, _, _ = build_pack(tmp_path / "b", monkeypatch, synthetic_layers(), order=lambda n: list(range(n))[::-1])
    assert a.read_bytes() == b.read_bytes()
    # second build in the same work directory: every tile from the cache, same bytes
    c, st, _ = build_pack(tmp_path / "a", monkeypatch, synthetic_layers(), name="again.pack")
    assert st["built"] == 0 and st["cached"] == 4
    assert hashlib.sha256(a.read_bytes()).digest() == hashlib.sha256(c.read_bytes()).digest()


def test_changed_feature_rebuilds_only_its_tiles(tmp_path, monkeypatch):
    base, st0, _ = build_pack(tmp_path / "inc", monkeypatch, synthetic_layers())
    moved = synthetic_layers(obstruction_at=(X0 + 0.034, Y0 + 0.011))   # stays inside the south-east tile
    inc, st1, _ = build_pack(tmp_path / "inc", monkeypatch, moved, name="inc.pack")
    assert st1["built"] == 1 and st1["cached"] == 3
    clean, _, _ = build_pack(tmp_path / "clean", monkeypatch, moved, name="clean.pack")
    assert inc.read_bytes() == clean.read_bytes()
    assert inc.read_bytes() != base.read_bytes()


def test_issue_date_alone_does_not_rebuild_tiles(tmp_path, monkeypatch):
    build_pack(tmp_path / "re", monkeypatch, synthetic_layers())
    layers = synthetic_layers()
    for g in layers.values():
        g["isdt"] = "20261201"
    _, st, _ = build_pack(tmp_path / "re", monkeypatch, layers, name="reissued.pack")
    assert st["built"] == 0


def test_parallel_workers_give_the_same_pack(tmp_path, monkeypatch):
    a, _, _ = build_pack(tmp_path / "w1", monkeypatch, synthetic_layers(), workers=1)
    b, _, _ = build_pack(tmp_path / "w2", monkeypatch, synthetic_layers(), workers=2)
    assert a.read_bytes() == b.read_bytes()


def test_vertices_on_edges_matches_brute_force():
    from enc_routing import topology

    rng = np.random.default_rng(7)
    p = rng.integers(0, 50, size=(400, 2)).astype(np.int64)
    p = np.unique(p, axis=0)
    tris = rng.integers(0, len(p), size=(300, 3))
    tris = tris[(tris[:, 0] != tris[:, 1]) & (tris[:, 1] != tris[:, 2]) & (tris[:, 0] != tris[:, 2])]
    ti = np.repeat(np.arange(len(tris)), 3)
    ki = np.tile(np.arange(3), len(tris))
    fast = dict(topology.vertices_on_edges(p, tris, ti, ki, cell=7))
    slow = {}
    for e in range(len(ti)):
        a, c = p[tris[ti[e], ki[e]]], p[tris[ti[e], (ki[e] + 1) % 3]]
        d = c - a
        hits = []
        for v in range(len(p)):
            w = p[v] - a
            if d[0] * w[1] - d[1] * w[0] == 0 and 0 < d @ w < d @ d:
                hits.append((int(d @ w), v))
        if hits:
            slow[e] = [v for _, v in sorted(hits)]
    assert fast == slow
