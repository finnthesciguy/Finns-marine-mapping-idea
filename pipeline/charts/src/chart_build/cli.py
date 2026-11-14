"""chart-build command line.

  chart-build plan     what a baseline/update would render, request count, time at the rate
  chart-build build    baseline package for a region (resumes an unfinished run)
  chart-build update   re-render only tiles touched by changed ENC cells (resumes too)
  chart-build verify   integrity, coverage and a sampled visual diff against the previous version
  chart-build canary   re-render reference metatiles; warn if the renderer's output changed
  chart-build publish  copy/upload packages and write manifest.json (ChartKit schema 1)
  chart-build calibrate  determinism / pinned-parameter / extent / seam measurements (live)
  chart-build status   versions and unfinished runs

Exit codes: 0 ok, 1 verification failed, 2 refused (nothing requested), 3 renderer changed,
4 stopped early (budget used up or the service kept failing; run the same command again to resume).
"""
from __future__ import annotations

import argparse
import json
import sys
import tarfile
from pathlib import Path

from enc_catalog.aoi import select_cells
from enc_catalog.catalog import parse_catalog
from enc_catalog.snapshot import make_snapshot, read_snapshot

from .build import (BuildRefused, Plan, RendererChanged, RunStopped, execute, plan_baseline, plan_update,
                    run_canaries)
from .config import DEFAULT_BUDGET, DEFAULT_MAX_INFLIGHT, DEFAULT_RATE, RenderConfig, RunPolicy, load_regions, region_from_bbox
from .grid import Metatile, lonlat_to_tile
from .http import BadResponse, BudgetExceeded, PoliteClient, ServiceFailing, friday_reload_window
from .policy import count, policy_tiles
from .renderer import FakeRenderer, MCSRenderer, SuspectBlank
from .state import BuildRoot, package_id
from . import calibrate as cal
from . import publish as pub
from . import verify as ver


def _region(args):
    regions = load_regions(args.regions_file)
    if args.bbox:
        bb = [float(v) for v in args.bbox.split(",")]
        return region_from_bbox(args.id or "custom", bb, args.title)
    if args.region not in regions:
        sys.exit(f"unknown region {args.region!r}; known: {', '.join(regions)}")
    return regions[args.region]


def _snapshot(path_or_catalog: str | None, catalog: str | None = None) -> dict | None:
    if catalog:
        cat = parse_catalog(catalog)
        return make_snapshot(cat, select_cells(cat.cells))
    return read_snapshot(path_or_catalog) if path_or_catalog else None


def _policy(args) -> RunPolicy:
    return RunPolicy(rate=args.rate, max_inflight=args.max_inflight, budget=args.budget, allow_friday=args.allow_friday)


def _renderer(args, cfg, policy, root: BuildRoot, region=None):
    if args.renderer == "fake":
        cov = [region.bbox] if region else [(-180, -85, 180, 85)]
        return FakeRenderer(cfg, coverage=cov), None
    if friday_reload_window() and not args.allow_friday:
        raise BuildRefused("NOAA reloads ENC data on Friday afternoons (US Central) and warns of downtime; "
                           "run outside Fri 12:00 - Sat 06:00 CT or pass --allow-friday")
    client = PoliteClient(policy, root.request_log)
    return MCSRenderer(cfg, client), client


def common(sp, region=True):
    sp.add_argument("--root", required=True, help="build root (state/, work/, packages/, logs/)")
    if region:
        g = sp.add_mutually_exclusive_group()
        g.add_argument("--region", default=None, help="region id from the regions file (e.g. ncds_13, demo_swpass)")
        g.add_argument("--bbox", help="ad-hoc region w,s,e,n, written --bbox=W,S,E,N (use with --id)")
        sp.add_argument("--id", help="package id for --bbox")
        sp.add_argument("--title")
    sp.add_argument("--regions-file")
    sp.add_argument("--render-config")
    sp.add_argument("--scale", type=int, choices=[1, 2], default=1, help="2 = retina 512 px tiles at 192 dpi")
    sp.add_argument("--max-zoom", type=int, default=16)
    sp.add_argument("--overscale", type=int, default=2)


def politeness(sp):
    sp.add_argument("--renderer", choices=["mcs", "fake"], default="mcs")
    sp.add_argument("--budget", type=int, default=DEFAULT_BUDGET, help=f"max requests this run (default {DEFAULT_BUDGET})")
    sp.add_argument("--allow-over-budget", action="store_true",
                    help="start even if the run needs more than --budget; it stops at the budget and can be resumed")
    sp.add_argument("--rate", type=float, default=DEFAULT_RATE, help="requests per second (max 2)")
    sp.add_argument("--max-inflight", type=int, default=DEFAULT_MAX_INFLIGHT, choices=[1, 2])
    sp.add_argument("--allow-friday", action="store_true")


def cmd_plan(args):
    cfg = RenderConfig.load(args.render_config, args.scale)
    policy = RunPolicy(rate=args.rate, budget=args.budget)
    root = BuildRoot(args.root)
    if args.all_regions:
        snap = _snapshot(args.snapshot, args.catalog)
        regions = load_regions(args.regions_file)
        rows, union = {}, {}
        for rid in args.all_regions.split(","):
            t = policy_tiles(snap, regions[rid], args.max_zoom, args.overscale)
            c = count(t, cfg.metatile)
            rows[rid] = {"tiles": c["tiles"], "requests": c["requests"],
                         "per_zoom": {z: v["tiles"] for z, v in c["per_zoom"].items()},
                         "requests_per_zoom": {z: v["metatiles"] for z, v in c["per_zoom"].items()}}
            for z, s in t.items():
                union.setdefault(z, set()).update(s)
        cu = count(union, cfg.metatile)
        out = {"scale": cfg.scale, "metatile": cfg.metatile, "regions": rows,
               "sum_requests": sum(r["requests"] for r in rows.values()),
               "sum_tiles": sum(r["tiles"] for r in rows.values()),
               "union_tiles": cu["tiles"], "union_requests": cu["requests"],
               "hours_at_rate": round(sum(r["requests"] for r in rows.values()) / args.rate / 3600, 2)}
        print(json.dumps(out, indent=1))
        return
    region = _region(args)
    if args.mode == "baseline":
        snap = _snapshot(args.snapshot, args.catalog)
        plan = plan_baseline(root, region, snap, cfg, args.max_zoom, args.overscale)
    else:
        snap = _snapshot(args.snapshot, args.catalog)
        old = read_snapshot(args.old_snapshot) if args.old_snapshot else None
        plan = plan_update(root, region, snap, cfg, old, args.max_zoom, args.overscale, args.dilate)
    s = plan.summary(cfg, policy)
    if args.tiles_out:
        Path(args.tiles_out).write_text(json.dumps({"scheme": "xyz", "metatiles": [m.key() for m in plan.metatiles(cfg.metatile)]}))
    print(json.dumps(s, indent=1))
    if not s["within_budget"]:
        print(f"over budget: needs {s['requests']} > {policy.budget}", file=sys.stderr)


def _run(args, mode):
    cfg = RenderConfig.load(args.render_config, args.scale)
    policy = _policy(args)
    root = BuildRoot(args.root)
    region = _region(args)
    snap = _snapshot(args.snapshot, args.catalog)
    old = read_snapshot(args.old_snapshot) if getattr(args, "old_snapshot", None) else None
    renderer, client = _renderer(args, cfg, policy, root, region)
    try:
        rec = execute(root, region, cfg, policy, renderer, mode, snap, old, args.allow_over_budget, args.discard_work,
                      args.max_zoom, args.overscale, getattr(args, "dilate", 1), args.canaries,
                      getattr(args, "accept_renderer_change", False), log=lambda m: print(m, file=sys.stderr))
    except RunStopped as e:
        print(json.dumps({"stopped": e.stats, "requests_used": client.used if client else None}, indent=1))
        sys.exit(4)
    if client:
        rec["requests_used"] = client.used
        root.update_version(rec["package_id"], rec["version"], requests_used=client.used)
    print(json.dumps({k: v for k, v in rec.items() if k != "canaries"}, indent=1))


def cmd_build(args):
    _run(args, "baseline")


def cmd_update(args):
    _run(args, "update")


def _pkg_and_rec(args, root):
    region = _region(args)
    pkg = package_id(region.id, args.scale)
    vs = root.versions(pkg)
    if not vs:
        sys.exit(f"{pkg}: no versions in {root.state_dir(pkg)}")
    return region, pkg, vs


def cmd_verify(args):
    root = BuildRoot(args.root)
    cfg = RenderConfig.load(args.render_config, args.scale)
    region, pkg, vs = _pkg_and_rec(args, root)
    rec = vs[-1] if not args.version else next(v for v in vs if v["version"] == args.version)
    path = root.package_path(pkg, rec)
    wanted = None
    if not args.no_coverage:
        snap = read_snapshot(args.snapshot) if args.snapshot else json.loads(root.snapshot_path(pkg).read_text())
        if rec is vs[-1] or args.snapshot:
            wanted = policy_tiles(snap, region, args.max_zoom, args.overscale)
    rep = ver.check_package(path, wanted, cfg.metatile, decode="all" if args.deep else "sample")
    from .publish import sha256_file
    if path.stat().st_size != rec["bytes"] or sha256_file(path) != rec["sha256"]:
        rep["errors"].append("file size/sha256 differ from the build record")
        rep["ok"] = False
    out = {"package": str(path), **rep}
    prev = None
    if args.previous:
        prev = Path(args.previous)
    else:
        i = vs.index(rec)
        if i > 0:
            prev = root.package_path(pkg, vs[i - 1])
    if prev and prev.exists():
        out["visual_diff"] = {"against": str(prev), **ver.visual_diff(path, prev, args.samples, mosaic_out=args.diff_image)}
    print(json.dumps(out, indent=1, default=str))
    if not rep["ok"]:
        sys.exit(1)


def cmd_canary(args):
    root = BuildRoot(args.root)
    cfg = RenderConfig.load(args.render_config, args.scale)
    region, pkg, vs = _pkg_and_rec(args, root)
    policy = _policy(args)
    plan = Plan(pkg, "canary", vs[-1]["version"], {}, {}, canaries=vs[-1].get("canaries", [])[: args.count])
    if len(plan.canaries) > policy.budget:
        sys.exit(f"canary needs {len(plan.canaries)} requests, over the budget {policy.budget}")
    renderer, client = _renderer(args, cfg, policy, root, region)
    try:
        res = run_canaries(plan, renderer, cfg, root.package_path(pkg, vs[-1]))
        print(json.dumps({"ok": True, "checked": len(res), "exact": sum(1 for c in res if c["exact"]),
                          "results": [{k: c.get(k) for k in ("z", "mx", "my", "exact", "px_differing",
                                                             "px_differing_strongly")} for c in res],
                          "requests_used": client.used if client else None}, indent=1))
    except (BudgetExceeded, ServiceFailing, BadResponse, SuspectBlank) as e:
        print(json.dumps({"ok": None, "error": f"{type(e).__name__}: {e}", "requests_used": client.used if client else None}))
        print("canary could not complete (service problem); try again later", file=sys.stderr)
        sys.exit(4)
    except RendererChanged as e:
        print(json.dumps({"ok": False, "error": str(e)}))
        print("WARNING: renderer output changed for unchanged data; schedule a new baseline", file=sys.stderr)
        sys.exit(3)


def cmd_publish(args):
    root = BuildRoot(args.root)
    regions = load_regions(args.regions_file)
    items = []
    for spec in args.packages:
        rid, _, scale = spec.partition("@")
        scale = int(scale.rstrip("x")) if scale else 1
        pkg = package_id(rid, scale)
        rec = root.current(pkg)
        if not rec:
            sys.exit(f"{pkg}: nothing built")
        region = regions.get(rid) or region_from_bbox(rid, rec["bounds"])  # ad-hoc --bbox package
        items.append((region, rec, root.package_path(pkg, rec)))
    if args.target == "local":
        target = pub.LocalTarget(args.dir or (root.root / "publish"), args.base_url)
    else:
        target = pub.GitHubReleaseTarget(args.repo, args.tag, notes=args.notes or "")
    base = json.loads(Path(args.base_manifest).read_text()) if args.base_manifest else None
    m = pub.publish(target, items, base)
    for region, rec, _ in items:
        root.update_version(rec["package_id"], rec["version"], published_url=target.url_for(rec["file"]))
    if args.include_state:
        tar = root.root / "chart-build-state.tar.gz"
        with tarfile.open(tar, "w:gz") as t:
            t.add(root.root / "state", arcname="state")
        target.upload(tar)
    print(json.dumps(m, indent=1))


def cmd_calibrate(args):
    cfg = RenderConfig.load(args.render_config, args.scale)
    policy = _policy(args)
    root = BuildRoot(args.root)
    args.renderer = "mcs"
    r, client = _renderer(args, cfg, policy, root)
    out = {}
    lon, lat = (float(v) for v in args.at.split(","))
    zs = [int(z) for z in args.zooms.split(",")]
    whats = args.what.split(",")
    mts = [Metatile.of(z, *lonlat_to_tile(lon, lat, z), cfg.metatile) for z in zs]
    if "extent" in whats:
        out["extent"] = cal.extent_check(r, mts[0])
    if "determinism" in whats:
        out["determinism"] = cal.determinism(r, mts)
    if "pinned" in whats:
        out["pinned_vs_default"] = cal.pinned_vs_default(r, mts[-1])
    if "seams" in whats:
        gutters = [int(g) for g in args.gutters.split(",")]
        out["seams"] = []
        for z in zs:
            for vertical in ([False, True] if args.both_axes else [False]):
                img = f"{args.images}/seam_z{z}_{'v' if vertical else 'h'}.png" if args.images else None
                out["seams"].append(cal.seam_test(r, z, lon, lat, gutters, vertical, img))
    out["requests_used"] = client.used
    print(cal.dump(out))


def cmd_status(args):
    root = BuildRoot(args.root)
    out = {}
    sd = root.root / "state"
    for d in sorted(sd.iterdir()) if sd.exists() else []:
        vs = root.versions(d.name)
        out[d.name] = {"versions": [{k: v.get(k) for k in ("version", "mode", "tiles", "bytes", "data_date",
                                                           "requests_used", "published_url")} for v in vs],
                       "unfinished_run": root.run_record(d.name)}
    wd = root.root / "work"
    for d in sorted(wd.iterdir()) if wd.exists() else []:
        if d.name not in out:
            out[d.name] = {"versions": [], "unfinished_run": root.run_record(d.name)}
    print(json.dumps(out, indent=1))


def build_parser():
    p = argparse.ArgumentParser(prog="chart-build", description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)

    def snap_args(sp, required=False):
        g = sp.add_mutually_exclusive_group(required=required)
        g.add_argument("--snapshot", help="enc-catalog snapshot JSON")
        g.add_argument("--catalog", help="ENCProdCat.xml (a snapshot is made from it)")

    sp = sub.add_parser("plan", help="dry run: tiles, requests, time")
    common(sp)
    snap_args(sp, True)
    sp.add_argument("--mode", choices=["baseline", "update"], default="baseline")
    sp.add_argument("--old-snapshot")
    sp.add_argument("--dilate", type=int, default=1)
    sp.add_argument("--budget", type=int, default=DEFAULT_BUDGET)
    sp.add_argument("--rate", type=float, default=DEFAULT_RATE)
    sp.add_argument("--all-regions", help="comma list: estimate these regions together (no state needed)")
    sp.add_argument("--tiles-out")
    sp.set_defaults(func=cmd_plan)

    for name, func, help_ in (("build", cmd_build, "baseline build (resumable)"),
                              ("update", cmd_update, "incremental update (resumable)")):
        sp = sub.add_parser(name, help=help_)
        common(sp)
        politeness(sp)
        snap_args(sp)
        sp.add_argument("--discard-work", action="store_true", help="throw away an unfinished run first")
        sp.add_argument("--canaries", type=int, default=20, help="reference metatiles recorded for the canary check")
        if name == "update":
            sp.add_argument("--old-snapshot", help="override the stored previous snapshot (testing)")
            sp.add_argument("--dilate", type=int, default=1)
            sp.add_argument("--accept-renderer-change", action="store_true")
        sp.set_defaults(func=func)

    sp = sub.add_parser("verify", help="integrity, coverage, visual diff")
    common(sp)
    sp.add_argument("--version")
    sp.add_argument("--snapshot")
    sp.add_argument("--previous", help="package to diff against (default: the previous version)")
    sp.add_argument("--samples", type=int, default=200)
    sp.add_argument("--diff-image")
    sp.add_argument("--deep", action="store_true", help="decode every image (default: a sample of 500)")
    sp.add_argument("--no-coverage", action="store_true")
    sp.set_defaults(func=cmd_verify)

    sp = sub.add_parser("canary", help="renderer change check")
    common(sp)
    politeness(sp)
    sp.add_argument("--count", type=int, default=20)
    sp.set_defaults(func=cmd_canary)

    sp = sub.add_parser("publish", help="publish packages + manifest.json")
    sp.add_argument("--root", required=True)
    sp.add_argument("--regions-file")
    sp.add_argument("packages", nargs="+", help="region ids (append @2x for retina packages)")
    sp.add_argument("--target", choices=["local", "github"], default="local")
    sp.add_argument("--dir")
    sp.add_argument("--base-url", default="https://charts.example.invalid/gulf")
    sp.add_argument("--repo", help="owner/name (github target)")
    sp.add_argument("--tag", help="release tag (github target)")
    sp.add_argument("--notes")
    sp.add_argument("--base-manifest", help="previous manifest to merge (default: the target's current one)")
    sp.add_argument("--include-state", action="store_true", help="also upload state/ as chart-build-state.tar.gz")
    sp.set_defaults(func=cmd_publish)

    sp = sub.add_parser("calibrate", help="live measurements (costs requests)")
    common(sp, region=False)
    politeness(sp)
    sp.add_argument("--at", default="-89.43544,28.90172", help="lon,lat")
    sp.add_argument("--zooms", default="12,14,16")
    sp.add_argument("--what", default="determinism,pinned,seams", help="any of extent,determinism,pinned,seams")
    sp.add_argument("--gutters", default="0,64,128,256")
    sp.add_argument("--both-axes", action="store_true")
    sp.add_argument("--images")
    sp.set_defaults(func=cmd_calibrate)

    sp = sub.add_parser("status", help="versions and unfinished runs")
    sp.add_argument("--root", required=True)
    sp.set_defaults(func=cmd_status)
    return p


def main(argv=None):
    args = build_parser().parse_args(argv)
    if getattr(args, "region", None) is None and getattr(args, "bbox", None) is None and args.cmd in (
            "build", "update", "verify", "canary") or (args.cmd == "plan" and not args.all_regions
                                                        and args.region is None and args.bbox is None):
        sys.exit("--region or --bbox is required")
    try:
        args.func(args)
    except BuildRefused as e:
        print(f"refused: {e}", file=sys.stderr)
        sys.exit(2)
    except RendererChanged as e:
        print(f"renderer changed: {e}\nA new baseline is needed (or rerun with --accept-renderer-change).", file=sys.stderr)
        sys.exit(3)


if __name__ == "__main__":
    main()
