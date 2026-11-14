import copy

import pytest

from chart_build.build import (BuildRefused, RendererChanged, RunStopped, execute, plan_baseline, plan_update)
from chart_build.config import RunPolicy
from chart_build.grid import metatiles_for
from chart_build.http import BudgetExceeded
from chart_build.mbtiles import open_ro, read_tile_set
from chart_build.policy import policy_tiles
from chart_build.renderer import FakeRenderer
from chart_build.verify import check_package, visual_diff

from conftest import HARBOUR, REGION_BBOX

COV = [REGION_BBOX]
# A "light" inside the harbour cell whose look depends on the data version.
FEATURE = (-89.43, 28.90, -89.425, 28.905)


def fake(cfg, version=1, style=0, fail_after=None):
    return FakeRenderer(cfg, COV, features={"light": (FEATURE, version)}, style=style, fail_after=fail_after)


def _tiles_bytes(path):
    c = open_ro(path)
    out = {(z, x, r): d for z, x, r, d in c.execute("SELECT zoom_level, tile_column, tile_row, tile_data FROM tiles")}
    c.close()
    return out


def test_policy_follows_cell_scale(snapshot, region):
    t = policy_tiles(snapshot, region)
    assert max(t) == 16
    # z16 only over the harbour cell (+ edge tiles), z11-15 over the coastal cell's box, z<=10 from the overview.
    from chart_build.grid import tile_bounds_lonlat
    for x, y in t[16]:
        w, s, e, n = tile_bounds_lonlat(16, x, y)
        assert e > HARBOUR[0] and w < HARBOUR[2] and n > HARBOUR[1] and s < HARBOUR[3]
    assert len(t[15]) > len(t[16]) / 4 * 2  # z15 spans the whole region box
    assert all(len(t[z]) >= 1 for z in range(0, 16))


def test_baseline_build_and_verify(root, region, cfg, policy, snapshot):
    r = fake(cfg)
    rec = execute(root, region, cfg, policy, r, "baseline", snapshot, canary_count=3, log=lambda m: None)
    path = root.package_path("t", rec)
    wanted = policy_tiles(snapshot, region)
    assert len(r.calls) == len(metatiles_for(wanted, cfg.metatile))
    rep = check_package(path, wanted, cfg.metatile)
    assert rep["ok"], rep["errors"]
    meta = rep["stats"]["metadata"]
    assert meta["data_date"] == "2026-11-02" and meta["catalog_date"] == "2026-11-11"
    # z0-4 come out blank here: the 0.2 degree box is smaller than one 64 px pixel.
    assert meta["format"] == "png" and int(meta["minzoom"]) <= 5 and meta["maxzoom"] == "16"
    assert rec["images"] < rec["tiles"]  # dedup of identical water tiles
    assert len(rec["canaries"]) == 3
    assert root.snapshot_path("t").exists() and root.run_record("t") is None


def test_blank_tiles_are_dropped(root, region, cfg, policy, snapshot):
    # Coverage only on the western half: the eastern tiles render fully transparent.
    r = FakeRenderer(cfg, [(-89.5, 28.85, -89.4, 29.0)])
    rec = execute(root, region, cfg, policy, r, "baseline", snapshot, log=lambda m: None)
    wanted = policy_tiles(snapshot, region)
    assert rec["tiles"] < sum(len(s) for s in wanted.values())
    rep = check_package(root.package_path("t", rec), wanted, cfg.metatile)
    assert rep["ok"], rep["errors"]
    assert rep["stats"]["coverage"]["dropped_blank"] > 0


def test_resume_after_kill_gives_identical_package(tmp_path, region, cfg, policy, snapshot):
    from chart_build.state import BuildRoot
    a, b = BuildRoot(tmp_path / "a"), BuildRoot(tmp_path / "b")
    ref = execute(a, region, cfg, policy, fake(cfg), "baseline", snapshot, log=lambda m: None)
    killer = fake(cfg, fail_after=7)
    with pytest.raises(RunStopped) as ei:
        execute(b, region, cfg, policy, killer, "baseline", snapshot, log=lambda m: None)
    assert ei.value.stats["metatiles_done"] >= 5
    run = b.run_record("t")
    assert run and run["mode"] == "baseline"
    # A fresh process: different snapshot argument is ignored, the stored one is used.
    second = fake(cfg)
    rec = execute(b, region, cfg, policy, second, "baseline", None, log=lambda m: None)
    total = len(metatiles_for(policy_tiles(snapshot, region), cfg.metatile))
    assert len(killer.calls) - 2 <= total - len(second.calls) <= len(killer.calls)  # done work is not redone
    assert _tiles_bytes(a.package_path("t", ref)) == _tiles_bytes(b.package_path("t", rec))


def test_budget_refusal_and_override(root, region, cfg, snapshot):
    small = RunPolicy(budget=5)
    with pytest.raises(BuildRefused, match="over the budget"):
        execute(root, region, cfg, small, fake(cfg), "baseline", snapshot, log=lambda m: None)
    assert root.run_record("t") is None  # nothing started


def test_client_budget_stops_run_and_resume_finishes(root, region, cfg, snapshot):
    """--allow-over-budget: render up to the budget, stop, resume next time."""

    class Budgeted(FakeRenderer):
        def __init__(self, *a, limit, **k):
            super().__init__(*a, **k)
            self.limit = limit

        def render(self, mt, gutter_px=None):
            if len(self.calls) >= self.limit:
                raise BudgetExceeded("budget used up")
            return super().render(mt, gutter_px)

    first = Budgeted(cfg, COV, limit=10)
    with pytest.raises(RunStopped) as ei:
        execute(root, region, cfg, RunPolicy(budget=10), first, "baseline", snapshot, allow_over_budget=True,
                log=lambda m: None)
    assert "BudgetExceeded" in ei.value.stats["stopped"]
    rec = execute(root, region, cfg, RunPolicy(budget=10_000), FakeRenderer(cfg, COV), "baseline", None,
                  log=lambda m: None)
    assert check_package(root.package_path("t", rec), policy_tiles(snapshot, region), cfg.metatile)["ok"]


def test_update_renders_only_affected_metatiles_and_matches_fresh_baseline(tmp_path, region, cfg, policy,
                                                                           snapshot, bumped):
    from chart_build.state import BuildRoot
    root = BuildRoot(tmp_path / "r")
    base = execute(root, region, cfg, policy, fake(cfg, version=1), "baseline", snapshot, canary_count=4,
                   log=lambda m: None)
    plan = plan_update(root, region, bumped, cfg)
    assert plan.diff_summary["updated"] == ["THARB"]
    all_mts = metatiles_for(policy_tiles(bumped, region), cfg.metatile)
    upd_mts = set(plan.metatiles(cfg.metatile))
    assert 0 < len(upd_mts) < len(all_mts)
    z15_all = [m for m in all_mts if m.z == 15]
    assert 0 < len([m for m in upd_mts if m.z == 15]) < len(z15_all)
    # Every re-rendered metatile touches the harbour cell (dilated by one tile) or is an ancestor of one that does.
    r2 = fake(cfg, version=2)
    rec = execute(root, region, cfg, policy, r2, "update", bumped, log=lambda m: None)
    canary_keys = [f"{c['z']}/{c['mx']}/{c['my']}" for c in plan.canaries]
    assert r2.calls[:len(canary_keys)] == canary_keys  # canaries first, outside the changed area
    assert not set(canary_keys) & {m.key() for m in upd_mts}
    assert sorted(r2.calls[len(canary_keys):]) == sorted(m.key() for m in upd_mts)  # each affected metatile once
    assert rec["mode"] == "update" and rec["base_version"] == "2026-11-11" and rec["version"] == "2026-11-18"
    # The incremental package equals a fresh baseline rendered from the new data.
    fresh_root = BuildRoot(tmp_path / "fresh")
    fresh = execute(fresh_root, region, cfg, policy, fake(cfg, version=2), "baseline", bumped, log=lambda m: None)
    assert _tiles_bytes(root.package_path("t", rec)) == _tiles_bytes(fresh_root.package_path("t", fresh))
    d = visual_diff(root.package_path("t", rec), root.package_path("t", base), samples=10_000)
    assert d["different"] > 0 and d["tiles_added"] == 0 and d["tiles_removed"] == 0


def test_update_includes_ancestors(root, region, cfg, policy, snapshot, bumped):
    execute(root, region, cfg, policy, fake(cfg), "baseline", snapshot, log=lambda m: None)
    plan = plan_update(root, region, bumped, cfg)
    for z in range(1, 17):
        for x, y in plan.render.get(z, ()):
            assert (x >> 1, y >> 1) in plan.render[z - 1]


def test_canary_detects_renderer_change(root, region, cfg, policy, snapshot, bumped):
    execute(root, region, cfg, policy, fake(cfg), "baseline", snapshot, canary_count=4, log=lambda m: None)
    plan = plan_update(root, region, bumped, cfg)
    assert plan.canaries, "canaries outside the changed area expected"
    with pytest.raises(RendererChanged):
        execute(root, region, cfg, policy, fake(cfg, version=2, style=1), "update", bumped, log=lambda m: None)
    assert root.run_record("t") is None  # stopped before anything was written


def test_update_refuses_config_change_and_missing_base(root, region, cfg, policy, snapshot, bumped):
    with pytest.raises(BuildRefused, match="baseline"):
        plan_update(root, region, bumped, cfg)
    execute(root, region, cfg, policy, fake(cfg), "baseline", snapshot, log=lambda m: None)
    other = cfg.with_overrides(gutter_px=16)
    with pytest.raises(BuildRefused, match="config changed"):
        plan_update(root, region, bumped, other)


def test_cancelled_cell_tiles_are_removed(root, region, cfg, policy, snapshot):
    execute(root, region, cfg, policy, fake(cfg), "baseline", snapshot, log=lambda m: None)
    gone = copy.deepcopy(snapshot)
    gone["catalog_date"] = "2026-11-25"
    del gone["cells"]["THARB"]
    plan = plan_update(root, region, gone, cfg)
    assert 16 in plan.remove and plan.remove[16]
    rec = execute(root, region, cfg, policy, fake(cfg), "update", gone, log=lambda m: None)
    c = open_ro(root.package_path("t", rec))
    assert 16 not in read_tile_set(c)
    c.close()


def test_plan_baseline_versions_do_not_collide(root, region, cfg, policy, snapshot):
    execute(root, region, cfg, policy, fake(cfg), "baseline", snapshot, log=lambda m: None)
    assert plan_baseline(root, region, snapshot, cfg).version == "2026-11-11.2"


def test_canary_tolerates_render_noise_but_not_changes(root, region, cfg, policy, snapshot):
    """Live MCS renders differ by a few isolated pixels (<= 16 levels); that must not trip the canary."""
    from chart_build.build import Plan, run_canaries
    rec = execute(root, region, cfg, policy, fake(cfg), "baseline", snapshot, canary_count=4, log=lambda m: None)

    class Noisy(FakeRenderer):
        def __init__(self, *a, delta, **k):
            super().__init__(*a, **k)
            self.delta = delta

        def render(self, mt, gutter_px=None):
            img = super().render(mt, gutter_px).copy()
            g = self.cfg.gutter_px
            tp = self.cfg.tile_px
            sl = (slice(g + 5, img.shape[0] - g, tp), slice(g + 5, img.shape[1] - g, tp), 0)  # one pixel per tile
            img[sl] = (img[sl].astype(int) - self.delta).clip(0, 255)
            return img

    plan = Plan("t", "canary", rec["version"], {}, {}, canaries=rec["canaries"])
    pkg = root.package_path("t", rec)
    res = run_canaries(plan, Noisy(cfg, COV, features={"light": (FEATURE, 1)}, delta=12), cfg, pkg)
    assert all(r["ok"] for r in res) and any(not r["exact"] for r in res)
    with pytest.raises(RendererChanged):
        run_canaries(plan, Noisy(cfg, COV, features={"light": (FEATURE, 1)}, delta=120), cfg, pkg)
