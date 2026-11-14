import json
import os

import pytest

from chart_build import cli

from conftest import REGION_BBOX

BBOX = ",".join(str(v) for v in REGION_BBOX)


@pytest.fixture
def snap_file(tmp_path, snapshot, bumped):
    a, b = tmp_path / "old.json", tmp_path / "new.json"
    a.write_text(json.dumps(snapshot))
    b.write_text(json.dumps(bumped))
    return a, b


def run(argv, capsys):
    try:
        cli.main(argv)
        code = 0
    except SystemExit as e:
        code = e.code if isinstance(e.code, int) else 1
    out = capsys.readouterr()
    return code, out.out, out.err


def test_plan_build_update_verify_publish(tmp_path, snap_file, capsys):
    old, new = snap_file
    root = str(tmp_path / "root")
    reg = ["--bbox=" + BBOX, "--id", "t"]
    code, out, _ = run(["plan", "--root", root, *reg, "--snapshot", str(old)], capsys)
    assert code == 0
    p = json.loads(out)
    assert p["requests"] == p["metatile_requests"] > 0 and p["within_budget"]
    code, _, err = run(["build", "--root", root, *reg, "--snapshot", str(old), "--renderer", "fake",
                        "--budget", "3"], capsys)
    assert code == 2 and "over the budget" in err
    code, out, _ = run(["build", "--root", root, *reg, "--snapshot", str(old), "--renderer", "fake"], capsys)
    assert code == 0 and json.loads(out)["mode"] == "baseline"
    code, out, _ = run(["plan", "--root", root, *reg, "--snapshot", str(new), "--mode", "update"], capsys)
    up = json.loads(out)
    assert 0 < up["metatile_requests"] < p["metatile_requests"] and up["diff"]["updated"] == ["THARB"]
    code, out, _ = run(["update", "--root", root, *reg, "--snapshot", str(new), "--renderer", "fake"], capsys)
    assert code == 0 and json.loads(out)["version"] == "2026-11-18"
    code, out, _ = run(["verify", "--root", root, *reg], capsys)
    v = json.loads(out)
    assert code == 0 and v["ok"] and v["visual_diff"]["common_tiles"] > 0
    code, out, _ = run(["publish", "--root", root, "t", "--dir", str(tmp_path / "pub")], capsys)
    assert code == 0
    from chart_build.manifest import validate
    m = json.loads((tmp_path / "pub" / "manifest.json").read_text())
    validate(m)
    assert [r["id"] for r in m["regions"]] == ["t"] and m["regions"][0]["package"]["version"] == "2026-11-18"
    code, out, _ = run(["status", "--root", root], capsys)
    assert json.loads(out)["t"]["versions"][-1]["version"] == "2026-11-18"


def test_plan_all_regions_offline(snap_file, tmp_path, capsys):
    old, _ = snap_file
    code, out, _ = run(["plan", "--root", str(tmp_path), "--snapshot", str(old), "--all-regions", "ncds_13,ncds_14",
                        "--max-zoom", "12"], capsys)
    assert code == 0
    o = json.loads(out)
    assert o["regions"]["ncds_13"]["tiles"] > 0 and o["union_requests"] <= o["sum_requests"]


@pytest.mark.skipif(os.environ.get("CHART_BUILD_LIVE") != "1", reason="set CHART_BUILD_LIVE=1 to render from NOAA")
@pytest.mark.live
def test_live_single_metatile(tmp_path):
    """One real export request (Southwest Pass, z16)."""
    from chart_build.config import RenderConfig, RunPolicy
    from chart_build.grid import Metatile, lonlat_to_tile
    from chart_build.http import PoliteClient
    from chart_build.renderer import MCSRenderer
    from chart_build.tiles import is_blank, slice_metatile
    cfg = RenderConfig.load()
    client = PoliteClient(RunPolicy(budget=2), tmp_path / "req.jsonl")
    mt = Metatile.of(16, *lonlat_to_tile(-89.43544, 28.90172, 16), cfg.metatile)
    img = MCSRenderer(cfg, client).render(mt)
    tiles = slice_metatile(img, mt, cfg.tile_px, cfg.gutter_px)
    assert len(tiles) == 64 and sum(not is_blank(t) for t in tiles.values()) > 0
    assert client.used == 1
