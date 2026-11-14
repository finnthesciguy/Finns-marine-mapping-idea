"""Routing regions (chart box + overlap), the open-Gulf mask on a small
synthetic raster, and the manifest command (offline)."""
from __future__ import annotations

import json
from pathlib import Path

import numpy as np
import pytest
import shapely
from shapely.geometry import Point, box

from enc_routing import manifest as MF
from enc_routing import packfmt as P
from enc_routing import synth
from enc_routing.config import BuildParams
from enc_routing.regions import GULF_REGION_IDS, OVERLAP_NM, get_region, grow_box

REPO = Path(__file__).resolve().parents[3]


def nm_north(lat, nm):
    return lat + nm / 60.0


def test_regions_share_ids_with_chart_regions_and_overlap():
    from enc_catalog import load_aoi, load_regions

    chart = {r.key: r.bbox for r in load_regions()}
    aoi = load_aoi()
    assert set(GULF_REGION_IDS) == set(chart)
    for rid in GULF_REGION_IDS:
        r = get_region(rid)
        assert r.chart_bbox == tuple(chart[rid])
        # the routing area holds the chart box's share of the AOI, grown by the overlap
        core = box(*chart[rid]).intersection(aoi)
        assert r.geometry.buffer(1e-9).contains(core)
        assert r.geometry.area > core.area
    # ncds_12 / ncds_13 split at 29.33 N across the Louisiana coast: each reaches 25 nm past it
    r12, r13 = get_region("ncds_12"), get_region("ncds_13")
    lon = -90.0
    for nm in (5, 25):
        assert r12.geometry.contains(Point(lon, nm_north(29.333333, -nm)))
        assert r13.geometry.contains(Point(lon, nm_north(29.333333, nm)))
    assert not r12.geometry.contains(Point(lon, nm_north(29.333333, -(OVERLAP_NM + 5))))
    # Gulfport (just west of the ncds_11 / ncds_12 line at 89.07 W) is in both packs' areas
    gulfport = Point(-89.09, 30.35)
    assert get_region("ncds_11").geometry.contains(gulfport) and r12.geometry.contains(gulfport)
    # the upper Keys east of 80.6 W (outside every chart box) are in ncds_10's routing area
    assert get_region("ncds_10").geometry.contains(Point(-80.45, 25.1))


def test_grow_box_is_at_least_the_distance():
    b = grow_box((-90.0, 28.0, -89.0, 29.0), 30.0)
    assert b[1] == pytest.approx(27.5) and b[3] == pytest.approx(29.5)
    # at the box's northern latitude one degree of longitude is shorter, so the growth in degrees is larger
    assert (b[2] - (-89.0)) * 60 * np.cos(np.radians(29.0)) >= 30.0 - 1e-6


def test_open_gulf_mask_seals_a_narrow_pass(tmp_path, monkeypatch):
    """Barrier island with a 1 km pass in front of a bay, open sea outside:
    the sea and the beach are OUTSIDE, the bay behind the pass is not."""
    from enc_routing import mask as M

    monkeypatch.setenv("ENC_ROUTING_WORK", str(tmp_path))
    import geopandas as gpd

    ext = (-82.6, 26.6, -81.8, 27.4)
    mainland = box(-82.6, 27.2, -81.8, 27.4)
    island_w = box(-82.6, 27.10, -82.205, 27.11)        # barrier island, pass 0.01 deg (~1 km) wide
    island_e = box(-82.195, 27.10, -81.8, 27.11)
    deep = box(-82.6, 26.6, -81.8, 26.9)
    land = gpd.GeoDataFrame({"DRVAL1": [None] * 3}, geometry=[mainland, island_w, island_e], crs="EPSG:4326")
    dep = gpd.GeoDataFrame({"DRVAL1": [18.2]}, geometry=[deep], crs="EPSG:4326")
    entries = {"US3TEST": {"path": Path("US3TEST.x.pkl"), "excl": box(*ext), "layers": {"LNDARE": land, "DEPARE": dep}}}
    p = BuildParams(mask_seal_m=3000.0, mask_seed_dist_m=5000.0)
    mk = M.build_mask(entries, lambda e: e["layers"], p, log=lambda *a: None, extent=ext)
    poly = M.window_polygon(mk, ext)
    assert poly.contains(Point(-82.2, 26.8))         # open sea
    assert poly.contains(Point(-82.4, 27.095))       # beach water, 100 m off the island
    assert not poly.contains(Point(-82.4, 27.15))    # bay behind the island
    assert not poly.contains(Point(-82.2, 27.16))    # bay just inside the pass
    # windows of neighbouring tiles share their edges exactly
    a = M.window_polygon(mk, (-82.6, 26.6, -82.2, 27.4))
    b = M.window_polygon(mk, (-82.2, 26.6, -81.8, 27.4))
    assert shapely.union_all([a, b]).equals(poly)


@pytest.fixture()
def sample_manifest(tmp_path):
    src = REPO / "Packages" / "ChartKit" / "Samples" / "gulf-manifest.sample.json"
    dst = tmp_path / "manifest.json"
    dst.write_text(src.read_text())
    return dst


def test_manifest_entries_merge_and_validate(tmp_path, sample_manifest):
    pk = tmp_path / "routing-ncds_13-20261101.pack"
    P.write_pack(synth.build_synthetic(), pk)
    e = MF.routing_entry(pk, "https://example.invalid/routing/{region}/{file}", "ncds_13")
    raw = pk.read_bytes()
    assert e["byteSize"] == len(raw) and len(e["sha256"]) == 64
    assert e["dataDate"] == "2026-11-01" and e["formatVersion"] == 1
    assert e["url"] == f"https://example.invalid/routing/ncds_13/{pk.name}"
    assert e["version"].startswith("2026-11-01.")
    m = json.loads(sample_manifest.read_text())
    out, skipped = MF.merge_into(m, {"ncds_13": e, "nowhere_99": e})
    assert skipped == ["nowhere_99"]
    r13 = next(r for r in out["regions"] if r["id"] == "ncds_13")
    assert r13["routingPack"] == e
    # everything else is untouched
    for a, b in zip(m["regions"], out["regions"]):
        assert {k: v for k, v in a.items() if k != "routingPack"} == {k: v for k, v in b.items() if k != "routingPack"}
    MF.write_manifest(out, sample_manifest)
    MF.validate(json.loads(sample_manifest.read_text()))
    # the version changes exactly when the content changes
    assert MF.routing_entry(pk)["version"] == e["version"]


@pytest.mark.parametrize("field,value", [("sha256", "abc"), ("byteSize", 0), ("url", "ftp://x/y"),
                                         ("dataDate", "2026-13-01"), ("formatVersion", "1"), ("version", "")])
def test_manifest_rejects_what_chartkit_rejects(sample_manifest, field, value):
    m = json.loads(sample_manifest.read_text())
    good = {"url": "https://example.invalid/r.pack", "byteSize": 10, "sha256": "0" * 64, "version": "v",
            "dataDate": "2026-11-01", "formatVersion": 1}
    MF.merge_into(m, {"ncds_10": good})
    with pytest.raises(MF.ManifestInvalid):
        MF.merge_into(m, {"ncds_10": dict(good, **{field: value})})


def test_manifest_cli_writes_into_existing_file(tmp_path, monkeypatch, sample_manifest):
    from enc_routing import cli
    from enc_routing.regions import get_region

    monkeypatch.setenv("ENC_ROUTING_WORK", str(tmp_path / "work"))
    reg = get_region("ncds_14")
    pk = reg.dir("routing-ncds_14-20261101.pack")
    P.write_pack(synth.build_synthetic(), pk)
    reg.dir("build.json").write_text(json.dumps({"pack": pk.name}))
    out = tmp_path / "out.json"
    cli.main(["manifest", "--manifest", str(sample_manifest), "--region", "ncds_14,ncds_10", "--out", str(out)])
    m = json.loads(out.read_text())
    r = {x["id"]: x for x in m["regions"]}
    assert r["ncds_14"]["routingPack"]["byteSize"] == pk.stat().st_size
    assert "routingPack" not in r["ncds_10"]
    MF.validate(m)
