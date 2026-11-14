"""Regression: no route geometry (forwards or reversed) touches land, structures or
blocking hazards of the SOURCE data, and every leg keeps the safety clearance."""
from __future__ import annotations

import gzip
import json

import numpy as np
import pytest
import shapely

from conftest import TESTDATA
from enc_routing import packfmt as P
from enc_routing.router import DEG, K_M_PER_DEG, Profile, Router

import math


def _metric(lonlat, lat0):
    a = np.asarray(lonlat, float)
    return np.column_stack([a[:, 0] * K_M_PER_DEG * math.cos(lat0 * DEG), a[:, 1] * K_M_PER_DEG])


def test_sarasota_routes_clear_of_source_obstacles():
    obst = shapely.from_wkb(gzip.decompress((TESTDATA / "sarasota.obstacles.wkb.gz").read_bytes()))
    zone = shapely.from_wkb(gzip.decompress((TESTDATA / "sarasota.bridge_zone.wkb.gz").read_bytes()))
    doc = json.loads((TESTDATA / "sarasota.vectors.json").read_text())
    lat0 = 27.35
    om = shapely.transform(obst, lambda xy: _metric(xy, lat0))
    zm = shapely.transform(zone, lambda xy: _metric(xy, lat0))
    rt = Router(P.read_pack(TESTDATA / "sarasota.pack"))
    n = 0
    for q in doc["queries"]:
        e = q["expected"]
        if not e["ok"]:
            continue
        back = rt.route(tuple(q["goal"]), tuple(q["start"]), Profile(**q["profile"]), q["max_snap_m"])
        assert back["ok"], q["id"]
        for name, wpts in ((q["id"], e["waypoints"]), (q["id"] + " reversed", back["waypoints"])):
            line = shapely.LineString(_metric(wpts, lat0))
            assert not om.intersects(line), name
            # 12 m clearance outside bridge zones, 4 m inside (minus 0.5 m for rounding and the metric)
            assert om.distance(line.difference(zm)) >= 11.5, name
            assert om.distance(line) >= 3.5, name
        n += 1
    assert n >= 3
