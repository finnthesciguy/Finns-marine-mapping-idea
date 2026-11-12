import copy

import pytest

from chart_build.config import RegionDef, RenderConfig, RunPolicy
from chart_build.state import BuildRoot

REGION_BBOX = (-89.5, 28.85, -89.3, 29.0)
HARBOUR = (-89.45, 28.88, -89.40, 28.93)


def _cell(bbox, cscale, updn=0, isdt="2026-10-01"):
    w, s, e, n = bbox
    return {
        "lname": "", "band": 5, "cscale": cscale, "edtn": 1, "updn": updn, "uadt": isdt, "isdt": isdt,
        "zip_datetime": "", "zip_size": 1000, "zip_url": "", "bbox": [w, s, e, n], "regions": ["t"],
        "cov": {"E": [[[w, s], [e, s], [e, n], [w, n], [w, s]]], "I": []},
    }


@pytest.fixture
def snapshot():
    return {
        "format": 1, "catalog_date": "2026-11-11", "catalog_dt_valid": "", "cell_count": 3,
        "cells": {
            "TOVER": _cell((-95.0, 25.0, -85.0, 31.0), 3_500_000),
            "TCOAST": _cell((-89.5, 28.85, -89.3, 29.0), 80_000),
            "THARB": _cell(HARBOUR, 10_000, isdt="2026-11-02"),
        },
    }


@pytest.fixture
def bumped(snapshot):
    """The same catalog a week later: the harbour cell got an update."""
    s = copy.deepcopy(snapshot)
    s["catalog_date"] = "2026-11-18"
    s["cells"]["THARB"]["updn"] = 1
    s["cells"]["THARB"]["isdt"] = "2026-11-16"
    return s


@pytest.fixture
def region():
    return RegionDef("t", "Test region", REGION_BBOX, "A small test area")


@pytest.fixture
def cfg():
    """Small tiles so the fake renderer is fast; same code paths as 256 px."""
    return RenderConfig.load().with_overrides(tile_px=64, metatile=4, gutter_px=8)


@pytest.fixture
def policy():
    return RunPolicy(budget=10_000)


@pytest.fixture
def root(tmp_path):
    return BuildRoot(tmp_path / "root")
