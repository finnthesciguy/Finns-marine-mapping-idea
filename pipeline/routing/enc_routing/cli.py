"""Command line: python -m enc_routing <command> [...]

  fetch      catalog -> snapshot -> download -> extract every Gulf cell (cached)
  regions    the routing regions (chart box + overlap) and their tiles
  build      merge -> tiles -> assemble -> pack, for one region or all (cached, incremental)
  validate   decode a pack, check checksums, topology, index and references
  route      route between two points on a pack (reads only the pack)
  reference  run a region's reference routes and check them against the source data
  giww       walk the Gulf Intracoastal Waterway link by link and report where it breaks
  render     overview PNG of a region's reference routes
  manifest   write routing-pack entries into a ChartKit manifest and validate it
  vectors    write testdata/routing (synthetic pack, Sarasota cut, vectors, record dumps)
"""
from __future__ import annotations

import argparse
import datetime as dt
import gzip
import json
import sys
from pathlib import Path

from . import config

REPO = Path(__file__).resolve().parents[3]


def _region(name):
    from .regions import get_region

    return get_region(name)


def _region_ids(name):
    from .regions import GULF_REGION_IDS

    return list(GULF_REGION_IDS) if name == "all" else name.split(",")


def _pack_path(region):
    b = json.loads(region.dir("build.json").read_text())
    return region.dir(b["pack"])


def _stamp(s):
    if not s:
        return None
    return dt.datetime.fromisoformat(s.replace("Z", "+00:00")).astimezone(dt.timezone.utc)


def cmd_fetch(a):
    from .sources import fetch_and_extract

    print(json.dumps(fetch_and_extract(a.catalog_copy, workers=a.workers), indent=1, default=str))


def cmd_regions(a):
    from .build import coverage_union, prepare_sources
    from .tiles import tiles_for

    cov = None
    if a.tiles:
        cov = coverage_union(prepare_sources(offline=True)[2])
    for rid in _region_ids(a.region):
        r = _region(rid)
        row = {"region": rid, "chart_bbox": r.chart_bbox, "routing_bounds": r.bbox}
        if cov is not None:
            row["tiles"] = len(tiles_for(r.geometry, cov, r.params))
        print(json.dumps(row))


def cmd_build(a):
    from .build import build, prepare_sources

    prepared = prepare_sources(a.catalog_copy, a.offline, a.workers)
    rc = 0
    for rid in _region_ids(a.region):
        try:
            r = build(_region(rid), force=a.force, workers=a.workers, build_stamp=_stamp(a.build_time),
                      offline=a.offline, prepared=prepared)
            r = {k: v for k, v in r.items() if k not in ("anomalies",)}
            print(json.dumps(r, indent=1, default=str))
        except Exception as e:  # noqa: BLE001 - report every region, fail at the end
            print(f"region {rid}: BUILD FAILED: {type(e).__name__}: {e}", file=sys.stderr)
            rc = 1
            if a.region != "all":
                raise
    sys.exit(rc)


def cmd_validate(a):
    from .validate import validate_pack

    paths = [Path(a.pack)] if a.pack else [_pack_path(_region(r)) for r in _region_ids(a.region)]
    ok = True
    for path in paths:
        rep = validate_pack(path)
        print(json.dumps(rep, indent=1, default=str))
        ok &= rep["ok"]
    sys.exit(0 if ok else 1)


def cmd_route(a):
    from . import packfmt
    from .router import Profile, Router

    path = Path(a.pack) if a.pack else _pack_path(_region(a.region))
    rt = Router(packfmt.read_pack(path))
    prof = Profile(a.draft, a.margin, a.air, use_maintained=a.maintained,
                   accept_unknown_clearance=a.unknown, avoid_open_gulf=a.inside)
    s = tuple(float(v) for v in a.start.split(","))
    g = tuple(float(v) for v in a.goal.split(","))
    res = rt.route(s, g, prof, a.max_snap)
    res.pop("corridor", None)
    if not a.full:
        for leg in res.get("legs", []):
            leg.pop("crossings", None)
    print(json.dumps(res, indent=1, default=str))


def cmd_reference(a):
    from .assess import run_reference, summarize

    rc = 0
    for rid in _region_ids(a.region):
        reg = _region(rid)
        rows = run_reference(_pack_path(reg), reg)
        reg.dir("routes.json").write_text(json.dumps(rows, default=str))
        from .vectors import vectors_from_reference

        vectors_from_reference(_pack_path(reg), rows, reg.dir("reference.vectors.json"))
        summ = summarize(rows)
        reg.dir("routes-summary.json").write_text(json.dumps(summ, indent=1, default=str))
        print(json.dumps(summ["counts"]))
        if summ["counts"]["check_failures"]:
            rc = 1
    sys.exit(rc if a.gate else 0)


def cmd_giww(a):
    from .giww import CHAIN, run_giww

    for rid in _region_ids(a.region):
        if rid not in CHAIN:
            continue
        reg = _region(rid)
        rows = run_giww(_pack_path(reg), reg)
        reg.dir("giww.json").write_text(json.dumps(rows, indent=1, default=str))


def cmd_render(a):
    from .render import run_render, run_render_region

    for rid in _region_ids(a.region):
        reg = _region(rid)
        if rid == "pilot":
            run_render(reg, out_dir=a.out)
        else:
            run_render_region(reg, out_dir=a.out, small=a.small)


def cmd_manifest(a):
    from .manifest import ManifestInvalid, merge_into, routing_entry, validate, write_manifest

    src = Path(a.manifest)
    m = json.loads(src.read_text())
    entries = {}
    for rid in _region_ids(a.region):
        reg = _region(rid)
        if not reg.dir("build.json").exists():
            print(f"region {rid}: not built, skipped", file=sys.stderr)
            continue
        entries[rid] = routing_entry(_pack_path(reg), a.url_template, rid)
    try:
        out, skipped = merge_into(m, entries, touch=not a.keep_generated_at)
    except ManifestInvalid as e:
        print(f"manifest invalid: {e}", file=sys.stderr)
        sys.exit(1)
    for rid in skipped:
        print(f"region {rid}: not in the manifest (needs a chart package entry first), skipped", file=sys.stderr)
    validate(out)
    dest = Path(a.out) if a.out else src
    write_manifest(out, dest)
    print(json.dumps({"written": str(dest), "routingPack": entries, "skipped": skipped}, indent=1))


def cmd_vectors(a):
    from . import packfmt, synth, vectors

    out = Path(a.out)
    out.mkdir(parents=True, exist_ok=True)
    sp = out / "synthetic.pack"
    packfmt.write_pack(synth.build_synthetic(), sp, with_adjacency=True)
    vectors.make_vectors(sp, vectors.SYNTH_QUERIES, out / "synthetic.vectors.json")
    (out / "synthetic.records.json").write_text(json.dumps(vectors.dump_records(sp), indent=1, default=vectors._np))
    src_region, bbox = config.CUTS["sarasota"]
    big = packfmt.read_pack(_pack_path(_region(src_region)))
    cut = vectors.cut_pack(big, bbox, "pilot-sarasota")
    cp = out / "sarasota.pack"
    packfmt.write_pack(cut, cp, with_adjacency=False)
    vectors.make_vectors(cp, vectors.SARASOTA_QUERIES, out / "sarasota.vectors.json")
    (out / "sarasota.records.json").write_text(json.dumps(vectors.dump_records(cp), indent=1, default=vectors._np))
    reg = _region(src_region)
    for name in ("obstacles", "bridge_zone"):
        g = vectors.clip_source_geometry(reg, name, bbox)
        (out / f"sarasota.{name}.wkb.gz").write_bytes(gzip.compress(g, 9, mtime=0))
    for f in sorted(out.iterdir()):
        print(f.name, f.stat().st_size)


def main(argv=None):
    ap = argparse.ArgumentParser(prog="enc_routing", description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    rhelp = "ncds_10..ncds_14, pilot, a comma list, or all"
    f = sub.add_parser("fetch")
    f.add_argument("--catalog-copy", default=None)
    f.add_argument("--workers", type=int, default=4)
    f.set_defaults(fn=cmd_fetch)
    g = sub.add_parser("regions")
    g.add_argument("--region", default="all", help=rhelp)
    g.add_argument("--tiles", action="store_true", help="count tiles (needs extracted cells)")
    g.set_defaults(fn=cmd_regions)
    b = sub.add_parser("build")
    b.add_argument("--region", default="all", help=rhelp)
    b.add_argument("--force", action="store_true", help="re-assemble even if the pack key is unchanged")
    b.add_argument("--catalog-copy", default=None)
    b.add_argument("--workers", type=int, default=4)
    b.add_argument("--offline", action="store_true", help="use cached downloads and NCF blocks only")
    b.add_argument("--build-time", default=None, help="ISO timestamp for the header (else SOURCE_DATE_EPOCH or now)")
    b.set_defaults(fn=cmd_build)
    v = sub.add_parser("validate")
    v.add_argument("pack", nargs="?")
    v.add_argument("--region", default="pilot", help=rhelp)
    v.set_defaults(fn=cmd_validate)
    r = sub.add_parser("route")
    r.add_argument("--pack")
    r.add_argument("--region", default="pilot")
    r.add_argument("--start", required=True, help="lon,lat")
    r.add_argument("--goal", required=True, help="lon,lat")
    r.add_argument("--draft", type=float, default=4.5)
    r.add_argument("--margin", type=float, default=1.5)
    r.add_argument("--air", type=float, default=20.0)
    r.add_argument("--maintained", action="store_true", help="use USACE maintained depths")
    r.add_argument("--unknown", action="store_true", help="accept unknown overhead clearance")
    r.add_argument("--inside", action="store_true", help="avoid the open Gulf")
    r.add_argument("--max-snap", type=float, default=750.0)
    r.add_argument("--full", action="store_true")
    r.set_defaults(fn=cmd_route)
    e = sub.add_parser("reference")
    e.add_argument("--region", default="pilot", help=rhelp)
    e.add_argument("--gate", action="store_true", help="exit 1 if any route touches source obstacles or "
                                                       "passes under a fixed object below the air draft")
    e.set_defaults(fn=cmd_reference)
    w = sub.add_parser("giww", help="walk the GIWW link by link, inside only, strict and maintained")
    w.add_argument("--region", default="all", help=rhelp)
    w.set_defaults(fn=cmd_giww)
    d = sub.add_parser("render")
    d.add_argument("--region", default="pilot", help=rhelp)
    d.add_argument("--out", default=None)
    d.add_argument("--small", action="store_true", help="also write a small PNG (< 400 KB) for docs")
    d.set_defaults(fn=cmd_render)
    m = sub.add_parser("manifest")
    m.add_argument("--manifest", required=True, help="existing ChartKit manifest.json to merge into")
    m.add_argument("--region", default="all", help=rhelp)
    m.add_argument("--url-template", default="https://example.invalid/routing/{file}",
                   help="URL placeholder; {region} and {file} are substituted")
    m.add_argument("--out", default=None, help="write here instead of over --manifest")
    m.add_argument("--keep-generated-at", action="store_true")
    m.set_defaults(fn=cmd_manifest)
    t = sub.add_parser("vectors")
    t.add_argument("--out", default=str(REPO / "testdata" / "routing"))
    t.set_defaults(fn=cmd_vectors)
    a = ap.parse_args(argv)
    a.fn(a)


if __name__ == "__main__":
    main()
