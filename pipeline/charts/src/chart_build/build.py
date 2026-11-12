"""Baseline and incremental builds of one region package (resumable)."""
from __future__ import annotations

import hashlib
import json
import shutil
import sys
import time
from concurrent.futures import FIRST_COMPLETED, ThreadPoolExecutor, wait
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path

from shapely.geometry import box
from shapely.ops import unary_union

from enc_catalog.snapshot import cell_geometry, diff_snapshots

from . import __version__
from .config import RegionDef, RenderConfig, RunPolicy
from .grid import Metatile, metatiles_for
from .http import BudgetExceeded, ServiceFailing
from .mbtiles import MBTilesWriter, open_ro, read_tile_set
from .policy import affected_tiles, count, policy_tiles
from .renderer import pixel_hash
from .state import BuildRoot, package_id, write_json
from .tiles import encode_png, is_blank, slice_metatile

ATTRIBUTION = ("Chart imagery rendered by NOAA's Maritime Chart Service (NOAAChartDisplay) from NOAA ENC® data. "
               "Not an official NOAA product. Not for navigation.")


class BuildRefused(RuntimeError):
    """The run would break a rule (budget, config change, missing state); nothing was requested."""


class RendererChanged(RuntimeError):
    """Canary tiles over unchanged data no longer match: a new baseline is needed."""


@dataclass
class Plan:
    pkg: str
    mode: str                      # baseline | update
    version: str
    wanted: dict                   # per-zoom tile set of the new package
    render: dict                   # per-zoom tile set to (re)render
    remove: dict = field(default_factory=dict)  # tiles to delete (coverage gone)
    canaries: list = field(default_factory=list)
    base: dict | None = None       # previous version record (update)
    diff_summary: dict | None = None

    def metatiles(self, n: int) -> list[Metatile]:
        return sorted(metatiles_for(self.render, n))

    def summary(self, cfg: RenderConfig, policy: RunPolicy) -> dict:
        c = count(self.render, cfg.metatile)
        w = count(self.wanted, cfg.metatile)
        req = c["requests"] + len(self.canaries)
        return {
            "package": self.pkg, "mode": self.mode, "version": self.version, "scale": cfg.scale,
            "tile_px": cfg.tile_px, "metatile": cfg.metatile, "config_hash": cfg.config_hash,
            "package_tiles": w["tiles"], "tiles_to_render": c["tiles"],
            "tiles_to_remove": sum(len(s) for s in self.remove.values()),
            "metatile_requests": c["requests"], "canary_requests": len(self.canaries),
            "requests": req, "budget": policy.budget, "within_budget": req <= policy.budget,
            "est_hours_at_rate": round(req / policy.rate / 3600, 2),
            "per_zoom": {str(z): v for z, v in c["per_zoom"].items()},
            "diff": self.diff_summary,
        }


def data_date(snapshot: dict, region: RegionDef) -> str | None:
    rb = box(*region.bbox)
    dates = [e["isdt"] for e in snapshot["cells"].values()
             if box(*e["bbox"]).intersects(rb) and cell_geometry(e).intersects(rb) and e.get("isdt")]
    return max(dates) if dates else None


def coverage_bounds(snapshot: dict, region: RegionDef) -> tuple[float, float, float, float]:
    rb = box(*region.bbox)
    gs = [cell_geometry(e) for e in snapshot["cells"].values() if box(*e["bbox"]).intersects(rb)]
    g = unary_union(gs).intersection(rb) if gs else rb
    b = g.bounds if not g.is_empty else region.bbox
    return tuple(round(v, 6) for v in b)


def plan_baseline(root: BuildRoot, region: RegionDef, snapshot: dict, cfg: RenderConfig, max_zoom: int = 16,
                  overscale: int = 2) -> Plan:
    pkg = package_id(region.id, cfg.scale)
    wanted = policy_tiles(snapshot, region, max_zoom, overscale)
    return Plan(pkg, "baseline", root.next_version(pkg, snapshot["catalog_date"]), wanted, wanted)


def plan_update(root: BuildRoot, region: RegionDef, new_snapshot: dict, cfg: RenderConfig, old_snapshot: dict | None = None,
                max_zoom: int = 16, overscale: int = 2, dilate_tiles: int = 1) -> Plan:
    pkg = package_id(region.id, cfg.scale)
    base = root.current(pkg)
    if base is None:
        raise BuildRefused(f"{pkg}: no previous version in {root.state_dir(pkg)}; run a baseline build first")
    if base["config_hash"] != cfg.config_hash:
        raise BuildRefused(f"{pkg}: render config changed ({base['config_hash']} -> {cfg.config_hash}); "
                           "tiles would not match the existing package, so a new baseline is needed")
    prev_path = root.package_path(pkg, base)
    if not prev_path.exists():
        raise BuildRefused(f"{pkg}: previous package {prev_path} is missing (download it from the last release)")
    if old_snapshot is None:
        sp = root.snapshot_path(pkg)
        if not sp.exists():
            raise BuildRefused(f"{pkg}: no stored snapshot at {sp}")
        old_snapshot = json.loads(sp.read_text())
    d = diff_snapshots(old_snapshot, new_snapshot)
    wanted = policy_tiles(new_snapshot, region, max_zoom, overscale)
    conn = open_ro(prev_path)
    old_tiles = read_tile_set(conn)
    conn.close()
    render = affected_tiles(d, wanted, old_tiles, max_zoom, overscale, dilate_tiles)
    render = {z: s & wanted.get(z, set()) for z, s in render.items() if s & wanted.get(z, set())}
    remove = {z: s - wanted.get(z, set()) for z, s in old_tiles.items() if s - wanted.get(z, set())}
    # Canary metatiles must not touch anything this update re-renders.
    touched = {m.key() for m in metatiles_for(render, cfg.metatile)}
    canaries = [c for c in base.get("canaries", []) if f"{c['z']}/{c['mx']}/{c['my']}" not in touched]
    s = d.summary()
    return Plan(pkg, "update", root.next_version(pkg, new_snapshot["catalog_date"]), wanted, render, remove,
                canaries, base, {k: s[k] for k in ("old_catalog_date", "new_catalog_date", "added", "new_edition",
                                                   "updated", "cancelled")})


def check_budget(plan: Plan, cfg: RenderConfig, policy: RunPolicy, allow_over: bool) -> dict:
    s = plan.summary(cfg, policy)
    if not s["within_budget"] and not allow_over:
        raise BuildRefused(f"{plan.pkg}: this run needs {s['requests']} requests, over the budget of {policy.budget}. "
                           "Raise --budget, or pass --allow-over-budget to render up to the budget and resume later.")
    return s


def _now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


# The export is not perfectly deterministic: re-rendering the same metatile minutes apart
# changed 10-40 isolated pixels of a few z16 tiles along an anti-aliased line, by at most
# 16 levels per channel (measured 2026-11-12). A real renderer or data change moves
# symbols and text, which differ by far more. So canaries tolerate that noise.
CANARY_MAX_CHANNEL_DIFF = 48
CANARY_MAX_DIFF_FRACTION = 0.001


def compare_to_package(mt: Metatile, img, cfg: RenderConfig, conn) -> dict:
    """Pixels of a fresh render versus the tiles the package holds for that metatile."""
    import numpy as np
    from .mbtiles import get_tile
    from .renderer import decode_rgba
    tiles = slice_metatile(img, mt, cfg.tile_px, cfg.gutter_px)
    n_px = n_any = n_big = 0
    for (x, y), t in tiles.items():
        stored = get_tile(conn, mt.z, x, y)
        a = t.astype(np.int16).copy()
        a[a[..., 3] == 0] = 0
        if stored is None:
            continue  # outside the package's coverage policy, or blank when it was built
        b = decode_rgba(stored).astype(np.int16).copy()
        b[b[..., 3] == 0] = 0
        d = np.abs(a - b).max(axis=2)
        n_px += d.size
        n_any += int((d > 0).sum())
        n_big += int((d > CANARY_MAX_CHANNEL_DIFF).sum())
    return {"px_differing": n_any, "px_differing_strongly": n_big, "diff_fraction": n_any / max(1, n_px)}


def run_canaries(plan: Plan, renderer, cfg: RenderConfig, package_path=None) -> list[dict]:
    """Re-render the reference metatiles and compare them with what the current
    package holds (or, without a package, with the recorded pixel hash).
    Raises RendererChanged when any canary differs by more than render noise."""
    conn = open_ro(package_path) if package_path else None
    out = []
    try:
        for c in plan.canaries:
            mt = Metatile(c["z"], c["mx"], c["my"], cfg.metatile)
            img = renderer.render(mt)
            g = cfg.gutter_px
            h = pixel_hash(img[g:img.shape[0] - g, g:img.shape[1] - g])
            rec = {**c, "now": h, "exact": h == c["pixel_sha"]}
            if conn is not None:
                cmp_ = compare_to_package(mt, img, cfg, conn)
                rec.update(cmp_)
                rec["ok"] = rec["exact"] or (cmp_["px_differing_strongly"] == 0
                                             and cmp_["diff_fraction"] <= CANARY_MAX_DIFF_FRACTION)
            else:
                rec["ok"] = rec["exact"]
            out.append(rec)
    finally:
        if conn is not None:
            conn.close()
    bad = [o for o in out if not o["ok"]]
    if bad:
        raise RendererChanged(f"{len(bad)} of {len(out)} canary metatiles changed although their ENC cells did not: "
                              + ", ".join(f"{b['z']}/{b['mx']}/{b['my']}" for b in bad))
    return out


def choose_canaries(conn, k: int) -> list[dict]:
    """Deterministic spread of detailed metatiles across zooms."""
    rows = conn.execute("SELECT zoom_level, mx, my, kept, pixel_sha FROM chart_build_metatiles "
                        "WHERE kept > 0 ORDER BY zoom_level, my, mx").fetchall()
    if not rows or k <= 0:
        return []
    by_z: dict[int, list] = {}
    for r in rows:
        by_z.setdefault(r[0], []).append(r)
    zs = sorted(by_z, reverse=True)
    picked = []
    i = 0
    while len(picked) < min(k, len(rows)):
        z = zs[i % len(zs)]
        lst = by_z[z]
        j = (i // len(zs))
        if j < len(lst):
            r = lst[(j * 7919) % len(lst)]
            if r not in picked:
                picked.append(r)
        i += 1
        if i > 50 * k:
            break
    return [{"z": r[0], "mx": r[1], "my": r[2], "pixel_sha": r[4]} for r in picked]


class Builder:
    def __init__(self, root: BuildRoot, region: RegionDef, cfg: RenderConfig, policy: RunPolicy, renderer,
                 png_mode: str = "lossless-palette", canary_count: int = 20, log=print):
        self.root, self.region, self.cfg, self.policy = root, region, cfg, policy
        self.renderer, self.png_mode, self.canary_count, self.log = renderer, png_mode, canary_count, log
        self.pkg = package_id(region.id, cfg.scale)

    # -- starting a run -------------------------------------------------------------------
    def start(self, plan: Plan, snapshot: dict) -> None:
        wd = self.root.work_dir(self.pkg)
        if self.root.run_record(self.pkg):
            raise BuildRefused(f"{self.pkg}: an unfinished run exists in {wd}; resume it or pass --discard-work")
        self.root.discard_run(self.pkg)
        wd.mkdir(parents=True, exist_ok=True)
        write_json(wd / "snapshot.json", snapshot)
        work = wd / "work.mbtiles"
        if plan.mode == "update":
            src = self.root.package_path(self.pkg, plan.base)
            shutil.copyfile(src, work)
        w = MBTilesWriter(work)
        if plan.remove:
            n = w.delete_tiles(plan.remove)
            self.log(f"{self.pkg}: removed {n} tiles whose coverage is gone")
        mts = plan.metatiles(self.cfg.metatile)
        # Re-rendered metatiles get fresh ledger rows.
        w.drop_ledger_rows([(m.z, m.mx, m.my) for m in mts])
        w.add_pending(mts)
        w.close()
        write_json(wd / "run.json", {
            "package": self.pkg, "region": self.region.id, "mode": plan.mode, "version": plan.version,
            "scale": self.cfg.scale, "config_hash": self.cfg.config_hash, "started": _now(),
            "base_version": plan.base["version"] if plan.base else None,
            "requests_planned": len(mts), "diff": plan.diff_summary,
        })

    # -- rendering ----------------------------------------------------------------------------
    def _render_one(self, mt: Metatile, wanted: set):
        img = self.renderer.render(mt)
        g = self.cfg.gutter_px
        crop = img[g:img.shape[0] - g, g:img.shape[1] - g]
        tiles = slice_metatile(img, mt, self.cfg.tile_px, g)
        out = {}
        for xy, t in tiles.items():
            if xy not in wanted:
                continue
            out[xy] = None if is_blank(t) else encode_png(t, self.png_mode)
        return mt, out, pixel_hash(crop)

    def resume(self, wanted: dict) -> dict:
        """Render every pending metatile. Returns run stats; raises on a stop
        condition after committing everything that finished."""
        wd = self.root.work_dir(self.pkg)
        run = json.loads((wd / "run.json").read_text())
        w = MBTilesWriter(wd / "work.mbtiles")
        pending = [Metatile(z, mx, my, self.cfg.metatile) for z, mx, my in w.pending()]
        by_mt = metatiles_for(wanted, self.cfg.metatile)
        stats = {"metatiles_done": 0, "kept": 0, "blank": 0, "stopped": None}
        t0 = time.monotonic()
        stop_exc = None
        it = iter(pending)
        with ThreadPoolExecutor(self.policy.max_inflight) as ex:
            futs = set()

            def fill():
                while len(futs) < self.policy.max_inflight and stop_exc is None:
                    mt = next(it, None)
                    if mt is None:
                        return
                    futs.add(ex.submit(self._render_one, mt, by_mt.get(mt, set())))

            fill()
            while futs:
                done, _ = wait(futs, return_when=FIRST_COMPLETED)
                for f in done:
                    futs.discard(f)
                    try:
                        mt, out, sha = f.result()
                    except (BudgetExceeded, ServiceFailing, KeyboardInterrupt) as e:
                        stop_exc = stop_exc or e
                        continue
                    except Exception as e:  # noqa: BLE001 - a bad metatile stops the run; it stays pending
                        stop_exc = stop_exc or e
                        continue
                    w.commit_metatile(mt.z, mt.mx, mt.my, self.cfg.scale, out, sha, run["version"], _now())
                    stats["metatiles_done"] += 1
                    stats["kept"] += sum(1 for v in out.values() if v is not None)
                    stats["blank"] += sum(1 for v in out.values() if v is None)
                    if stats["metatiles_done"] % 50 == 0:
                        left = len(pending) - stats["metatiles_done"]
                        self.log(f"{self.pkg}: {stats['metatiles_done']}/{len(pending)} metatiles, "
                                 f"{left} left, {time.monotonic() - t0:.0f} s")
                fill()
        stats["seconds"] = round(time.monotonic() - t0, 1)
        stats["pending_left"] = len(w.pending())
        w.close()
        if stop_exc is not None:
            stats["stopped"] = f"{type(stop_exc).__name__}: {stop_exc}"
            raise RunStopped(stats) from stop_exc
        return stats

    # -- finishing -------------------------------------------------------------------------------
    def finalize(self, snapshot: dict, extra: dict | None = None) -> dict:
        wd = self.root.work_dir(self.pkg)
        run = json.loads((wd / "run.json").read_text())
        w = MBTilesWriter(wd / "work.mbtiles")
        if w.pending():
            raise BuildRefused(f"{self.pkg}: {len(w.pending())} metatiles still pending")
        zr = w.db.execute("SELECT MIN(zoom_level), MAX(zoom_level), COUNT(*) FROM map").fetchone()
        if not zr or zr[2] == 0:
            raise BuildRefused(f"{self.pkg}: the package has no tiles")
        bounds = coverage_bounds(snapshot, self.region)
        cx, cy = (bounds[0] + bounds[2]) / 2, (bounds[1] + bounds[3]) / 2
        dd = data_date(snapshot, self.region)
        meta = {
            "name": self.region.title + ("" if self.cfg.scale == 1 else " (@2x)"),
            "description": self.region.summary or self.region.title,
            "format": "png",
            "bounds": ",".join(f"{v:.6f}" for v in bounds),
            "center": f"{cx:.6f},{cy:.6f},{min(max(zr[0], 10), zr[1])}",
            "minzoom": zr[0], "maxzoom": zr[1],
            "type": "overlay",
            "version": run["version"],
            "attribution": ATTRIBUTION,
            "scheme": "tms",
            "tile_size": self.cfg.tile_px,
            "scale": self.cfg.scale,
            # Our own fields.
            "data_date": dd,
            "catalog_date": snapshot.get("catalog_date"),
            "build_version": run["version"],
            "build_mode": run["mode"],
            "build_base_version": run.get("base_version"),
            "build_date": _now(),
            "build_config_hash": self.cfg.config_hash,
            "build_source": "NOAA MCS NOAAChartDisplay export; ENC catalog " + str(snapshot.get("catalog_date")),
            "generator": f"gulf-chart-build {__version__}",
        }
        w.set_metadata(meta)
        canaries = choose_canaries(w.db, self.canary_count)
        file = f"{self.pkg}-{run['version']}.mbtiles"
        dest = w.finalize(self.root.package_dir(self.pkg) / file)
        w.close()
        sha = _sha256(dest)
        conn = open_ro(dest)
        n_tiles, n_images = conn.execute("SELECT (SELECT COUNT(*) FROM map), (SELECT COUNT(*) FROM images)").fetchone()
        conn.close()
        rec = {
            "package_id": self.pkg, "version": run["version"], "file": file, "mode": run["mode"], "base_version": run.get("base_version"),
            "bytes": dest.stat().st_size, "sha256": sha, "catalog_date": snapshot.get("catalog_date"),
            "data_date": dd, "config_hash": self.cfg.config_hash, "scale": self.cfg.scale,
            "tiles": n_tiles, "images": n_images, "minzoom": zr[0], "maxzoom": zr[1], "bounds": list(bounds),
            "built_at": _now(), "canaries": canaries, "diff": run.get("diff"), **(extra or {}),
        }
        self.root.add_version(self.pkg, rec)
        shutil.copyfile(wd / "snapshot.json", self.root.snapshot_path(self.pkg))
        self.root.discard_run(self.pkg)
        return rec


class RunStopped(RuntimeError):
    def __init__(self, stats: dict):
        super().__init__(stats.get("stopped"))
        self.stats = stats


def _sha256(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def execute(root: BuildRoot, region: RegionDef, cfg: RenderConfig, policy: RunPolicy, renderer, mode: str,
            snapshot: dict | None, old_snapshot: dict | None = None, allow_over_budget: bool = False,
            discard_work: bool = False, max_zoom: int = 16, overscale: int = 2, dilate_tiles: int = 1,
            canary_count: int = 20, accept_renderer_change: bool = False, log=print) -> dict:
    """Plan (or resume) and run a baseline or update to completion."""
    b = Builder(root, region, cfg, policy, renderer, canary_count=canary_count, log=log)
    pkg = b.pkg
    run = root.run_record(pkg)
    if run and discard_work:
        root.discard_run(pkg)
        run = None
    canary_results = []
    if run:
        if run["mode"] != mode or run["config_hash"] != cfg.config_hash:
            raise BuildRefused(f"{pkg}: unfinished {run['mode']} run (config {run['config_hash']}) in "
                               f"{root.work_dir(pkg)}; resume it with the same mode/config or pass --discard-work")
        snapshot = json.loads((root.work_dir(pkg) / "snapshot.json").read_text())
        w = MBTilesWriter(root.work_dir(pkg) / "work.mbtiles")
        left = len(w.pending())
        w.close()
        if left > policy.budget and not allow_over_budget:
            raise BuildRefused(f"{pkg}: resuming needs {left} requests, over the budget of {policy.budget}")
        log(f"{pkg}: resuming {mode} {run['version']}: {left} metatiles pending")
        wanted = policy_tiles(snapshot, region, max_zoom, overscale)
    else:
        if snapshot is None:
            raise BuildRefused("a catalog snapshot is required")
        if mode == "baseline":
            plan = plan_baseline(root, region, snapshot, cfg, max_zoom, overscale)
        else:
            plan = plan_update(root, region, snapshot, cfg, old_snapshot, max_zoom, overscale, dilate_tiles)
        summary = check_budget(plan, cfg, policy, allow_over_budget)
        log(f"{pkg}: {mode} {plan.version}: {summary['metatile_requests']} metatile requests "
            f"+ {summary['canary_requests']} canary, {summary['tiles_to_render']} tiles to render")
        if plan.canaries:
            try:
                canary_results = run_canaries(plan, renderer, cfg, root.package_path(pkg, plan.base))
                exact = sum(1 for c in canary_results if c["exact"])
                log(f"{pkg}: canary OK ({len(canary_results)} reference metatiles, {exact} pixel-identical, "
                    "the rest within render noise)")
            except RendererChanged as e:
                if not accept_renderer_change:
                    raise
                log(f"WARNING {pkg}: {e} (continuing: --accept-renderer-change)")
        b.start(plan, snapshot)
        wanted = plan.wanted
    stats = b.resume(wanted)
    rec = b.finalize(snapshot, {"run_stats": stats, "canary_checked": len(canary_results)})
    return rec


def eprint(*a):
    print(*a, file=sys.stderr)
