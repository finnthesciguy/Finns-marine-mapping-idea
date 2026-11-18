import copy

import pytest

from enc_catalog import diff_snapshots, make_snapshot, read_snapshot, write_snapshot
from enc_catalog.tiles import lonlat_to_tile


@pytest.fixture
def snap(catalog, selection):
    return make_snapshot(catalog, selection)


def test_snapshot_contents(snap, selection):
    assert snap["format"] == 1
    assert snap["catalog_date"] == "2026-11-11"
    assert snap["cell_count"] == len(selection.cells) == len(snap["cells"])
    e = snap["cells"]["US5PLQCI"]
    assert (e["edtn"], e["updn"], e["isdt"], e["zip_size"]) == (8, 0, "2026-09-10", 84343)
    assert e["regions"] == ["ncds_13"] and e["band"] == 5
    assert len(e["bbox"]) == 4 and e["cov"]["E"]


def test_roundtrip(tmp_path, snap):
    p = tmp_path / "s.json"
    write_snapshot(snap, p)
    assert read_snapshot(p) == snap


def test_reject_unknown_format(tmp_path):
    p = tmp_path / "s.json"
    p.write_text('{"format": 99, "cells": {}}')
    with pytest.raises(ValueError):
        read_snapshot(p)


def test_no_change(snap):
    d = diff_snapshots(snap, copy.deepcopy(snap))
    assert d.changed == []
    assert sum(len(t) for t in d.tiles().values()) == 0


def test_diff_classification(snap):
    new = copy.deepcopy(snap)
    new["cells"]["US5PLQCI"]["updn"] = 1
    new["cells"]["US5PLQCI"]["isdt"] = "2026-11-12"
    new["cells"]["US5PLQEJ"]["edtn"] += 1
    new["cells"]["US5PLQEJ"]["updn"] = 0
    gone = new["cells"].pop("US5PLQCJ")
    old = copy.deepcopy(snap)
    added = old["cells"].pop("US5BROAA")
    assert gone and added
    d = diff_snapshots(old, new)
    assert d.updated == ["US5PLQCI"]
    assert d.new_edition == ["US5PLQEJ"]
    assert d.cancelled == ["US5PLQCJ"]
    assert d.added == ["US5BROAA"]
    s = d.summary()
    assert s["download_bytes"] == sum(new["cells"][n]["zip_size"] for n in ("US5BROAA", "US5PLQEJ", "US5PLQCI"))


def test_changed_tiles_cover_the_change(snap):
    new = copy.deepcopy(snap)
    new["cells"]["US5PLQCI"]["updn"] = 1  # Southwest Pass, buoy 3A at -89.4354, 28.9017
    d = diff_snapshots(snap, new)
    t = d.tiles(max_zoom=16, dilate_tiles=0)
    assert lonlat_to_tile(-89.4354, 28.9017, 16) in t[16]
    assert lonlat_to_tile(-89.4354, 28.9017, 10) in t[10]
    # a harbour cell 0.075 deg square: a few hundred z16 tiles, not thousands
    assert 50 < len(t[16]) < 600
    t1 = d.tiles(max_zoom=16, dilate_tiles=1)
    assert t[16] < t1[16]


def test_cancelled_cell_tiles_come_from_old_coverage(snap):
    new = copy.deepcopy(snap)
    new["cells"].pop("US5PLQCJ")
    t = diff_snapshots(snap, new).tiles(max_zoom=15, dilate_tiles=0)
    w, s, e, n = snap["cells"]["US5PLQCJ"]["bbox"]
    assert lonlat_to_tile((w + e) / 2, (s + n) / 2, 15) in t[15]


def test_small_scale_cell_stops_at_its_zoom(snap):
    new = copy.deepcopy(snap)
    new["cells"]["US1GLBCF"]["updn"] += 1  # overview cell, 1:1.5M-ish
    t = diff_snapshots(snap, new).tiles(max_zoom=16, dilate_tiles=0)
    assert t[8] and not t[16] and not t[12]
