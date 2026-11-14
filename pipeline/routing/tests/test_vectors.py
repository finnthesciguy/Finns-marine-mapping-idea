"""The reference router must reproduce testdata/routing/*.vectors.json from
the pack files alone, and the decoder must reproduce *.records.json."""
from __future__ import annotations

import hashlib
import json
import math

import numpy as np
import pytest

from conftest import TESTDATA
from enc_routing import packfmt as P
from enc_routing.router import Profile, Router
from enc_routing.vectors import dump_records, expected

PACKS = ["synthetic", "sarasota"]


def _close(a, b, path=""):
    if isinstance(a, dict):
        assert set(a) == set(b), (path, set(a) ^ set(b))
        for k in a:
            _close(a[k], b[k], f"{path}.{k}")
    elif isinstance(a, list):
        assert len(a) == len(b), path
        for i, (x, y) in enumerate(zip(a, b)):
            _close(x, y, f"{path}[{i}]")
    elif isinstance(a, float) or isinstance(b, float):
        if a is None or b is None:
            assert a == b, path
        else:
            assert math.isclose(a, b, rel_tol=0, abs_tol=1e-6), (path, a, b)
    else:
        assert a == b, (path, a, b)


@pytest.mark.parametrize("name", PACKS)
def test_vectors_reproduced(name):
    doc = json.loads((TESTDATA / f"{name}.vectors.json").read_text())
    pack_path = TESTDATA / doc["pack"]
    assert hashlib.sha256(pack_path.read_bytes()).hexdigest() == doc["pack_sha256"]
    rt = Router(P.read_pack(pack_path))
    for q in doc["queries"]:
        res = rt.route(tuple(q["start"]), tuple(q["goal"]), Profile(**q["profile"]), q["max_snap_m"])
        got = json.loads(json.dumps(expected(res), default=lambda o: o.item() if hasattr(o, "item") else o))
        _close(got, q["expected"], q["id"])


@pytest.mark.parametrize("name", PACKS)
def test_records_reproduced(name):
    want = json.loads((TESTDATA / f"{name}.records.json").read_text())
    got = json.loads(json.dumps(dump_records(TESTDATA / f"{name}.pack"),
                                default=lambda o: o.item() if hasattr(o, "item") else o))
    _close(got, want)


def test_synthetic_vectors_cover_the_cases():
    doc = json.loads((TESTDATA / "synthetic.vectors.json").read_text())
    exp = {q["id"]: q["expected"] for q in doc["queries"]}
    assert exp["s1_shoal_blocks"]["error"] == "NO_ROUTE"
    assert exp["s2_maintained"]["legs"][0]["reasons"] == ["MAINTAINED_DEPTH", "BRIDGE_OPENING"]
    assert exp["s4_too_deep"]["ok"] is False or all(
        l["min_depth_dm"] >= 39 for l in exp["s4_too_deep"]["legs"])
    assert exp["s6_outside_pack"]["error"] == "START_OUTSIDE_PACK"
    assert exp["s7_island_snap"]["start"]["in_mesh"] is False
    reasons = {r for q in exp.values() for l in q.get("legs", []) for r in l["reasons"]}
    assert {"MAINTAINED_DEPTH", "BRIDGE_OPENING", "UNKNOWN_CLEARANCE", "RESTRICTED_AREA",
            "HAZARD_PROXIMITY", "LOW_DATA_QUALITY", "SOUNDING_DEPTH"} <= reasons


def test_testdata_size_budget():
    total = sum(f.stat().st_size for f in TESTDATA.iterdir())
    assert total < 1.5e6, total
    assert (TESTDATA / "sarasota.pack").stat().st_size < 1e6
