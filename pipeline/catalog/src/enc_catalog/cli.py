"""enc-catalog command line."""
from __future__ import annotations

import argparse
import json
import sys
from datetime import date
from pathlib import Path

from .activity import weekly_issue_counts
from .aoi import load_aoi, load_regions, select_cells
from .catalog import BAND_NAMES, parse_catalog
from .download import CellCache, CellRequest, Http, fetch_catalog
from .snapshot import diff_snapshots, make_snapshot, read_snapshot, write_snapshot


def _select(args):
    cat = parse_catalog(args.catalog)
    sel = select_cells(cat.cells, load_aoi(args.aoi), load_regions(args.regions))
    return cat, sel


def cmd_fetch(args):
    changed = fetch_catalog(args.out, Http())
    print(f"{args.out}: {'downloaded' if changed else 'not modified'}")


def cmd_select(args):
    cat, sel = _select(args)
    if args.format == "names":
        for c in sel.cells:
            print(c.name)
        return
    table = sel.table()
    bands = sel.by_band()
    if args.format == "json":
        json.dump({
            "catalog_date": cat.date_created,
            "cells": len(sel.cells),
            "zip_bytes": sum(c.zipfile_size for c in sel.cells),
            "by_band": {BAND_NAMES.get(b, str(b)): len(cs) for b, cs in bands.items()},
            "by_region": {r: {BAND_NAMES.get(b, str(b)): n for b, n in d.items()} for r, d in table.items()},
            "newest_isdt": max((c.isdt for c in sel.cells), default=None),
        }, sys.stdout, indent=1)
        print()
        return
    print(f"catalog {cat.date_created}: {len(sel.cells)} active cells in AOI, "
          f"{sum(c.zipfile_size for c in sel.cells) / 1e6:.1f} MB zipped, "
          f"newest issue date {max((c.isdt for c in sel.cells), default='-')}")
    allb = sorted(bands)
    hdr = f"{'region':<26}" + "".join(f"{BAND_NAMES.get(b, b):>10}" for b in allb) + f"{'total':>8}"
    print(hdr)
    for r, d in table.items():
        print(f"{r:<26}" + "".join(f"{d.get(b, 0):>10}" for b in allb) + f"{sum(d.values()):>8}")
    print(f"{'all (distinct cells)':<26}" + "".join(f"{len(bands[b]):>10}" for b in allb) + f"{len(sel.cells):>8}")


def cmd_snapshot(args):
    cat, sel = _select(args)
    snap = make_snapshot(cat, sel)
    write_snapshot(snap, args.out)
    print(f"{args.out}: {snap['cell_count']} cells, catalog {snap['catalog_date']}, "
          f"{Path(args.out).stat().st_size / 1024:.0f} KB")


def cmd_diff(args):
    d = diff_snapshots(read_snapshot(args.old), read_snapshot(args.new))
    s = d.summary()
    tiles = d.tiles(args.max_zoom, args.overscale, args.dilate, args.min_zoom)
    s["tiles_per_zoom"] = {str(z): len(t) for z, t in sorted(tiles.items())}
    s["tiles_total"] = sum(len(t) for t in tiles.values())
    if args.tiles_out:
        Path(args.tiles_out).write_text(json.dumps(
            {"scheme": "xyz", "tiles": {str(z): sorted(map(list, t)) for z, t in sorted(tiles.items())}},
            separators=(",", ":")))
    if args.json:
        json.dump(s, sys.stdout, indent=1)
        print()
        return
    print(f"{s['old_catalog_date']} -> {s['new_catalog_date']}: "
          f"{len(d.added)} added, {len(d.new_edition)} new editions, {len(d.updated)} updated, "
          f"{len(d.cancelled)} cancelled; {s['download_bytes'] / 1e6:.1f} MB to download")
    for k in ("added", "new_edition", "updated", "cancelled"):
        if s[k]:
            print(f"  {k}: {' '.join(s[k])}")
    print(f"  tiles to re-render (z{args.min_zoom}-{args.max_zoom}, dilate {args.dilate}): {s['tiles_total']}")
    print("  " + " ".join(f"z{z}:{n}" for z, n in s["tiles_per_zoom"].items()))


def cmd_download(args):
    snap = read_snapshot(args.snapshot)
    names = list(snap["cells"])
    if args.changed_since:
        names = [n for n in diff_snapshots(read_snapshot(args.changed_since), snap).changed if n in snap["cells"]]
    if args.only:
        wanted = set(args.only)
        names = [n for n in names if n in wanted]
    reqs = [CellRequest.from_snapshot(n, snap["cells"][n]) for n in names]
    results = CellCache(args.cache).fetch_all(reqs, Http(max_concurrency=args.workers), args.verify, args.workers)
    counts = {}
    for r in results:
        counts[r.status] = counts.get(r.status, 0) + 1
        if r.status == "failed":
            print(f"FAILED {r.name}: {r.error}", file=sys.stderr)
    got = sum(r.bytes for r in results if r.status in ("downloaded", "resumed"))
    print(f"{len(results)} cells: " + ", ".join(f"{v} {k}" for k, v in sorted(counts.items())) + f"; {got / 1e6:.1f} MB fetched")
    if counts.get("failed"):
        sys.exit(1)


def cmd_activity(args):
    cat, sel = _select(args)
    today = date.fromisoformat(args.today) if args.today else date.fromisoformat(cat.date_created or date.today().isoformat())
    rows = weekly_issue_counts(sel.cells, args.weeks, today)
    if args.json:
        json.dump(rows, sys.stdout, indent=1)
        print()
        return
    print(f"{'week of':<12}{'cells':>7}{'MB':>8}")
    for r in rows:
        print(f"{r['week_start']:<12}{r['cells']:>7}{r['zip_bytes'] / 1e6:>8.1f}")


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="enc-catalog", description=__doc__)
    sub = p.add_subparsers(dest="cmd", required=True)

    def sel_args(sp):
        sp.add_argument("--catalog", required=True, help="path to ENCProdCat.xml")
        sp.add_argument("--aoi", help="AOI JSON/GeoJSON (default: built-in Gulf polygon)")
        sp.add_argument("--regions", help="regions JSON (default: built-in ncds_10..14 boxes)")

    sp = sub.add_parser("fetch", help="download the catalog (conditional GET)")
    sp.add_argument("--out", default="ENCProdCat.xml")
    sp.set_defaults(func=cmd_fetch)

    sp = sub.add_parser("select", help="list active cells in the AOI by region and band")
    sel_args(sp)
    sp.add_argument("--format", choices=["text", "json", "names"], default="text")
    sp.set_defaults(func=cmd_select)

    sp = sub.add_parser("snapshot", help="write a compact snapshot of the selected cells")
    sel_args(sp)
    sp.add_argument("--out", required=True)
    sp.set_defaults(func=cmd_snapshot)

    sp = sub.add_parser("diff", help="added/updated/cancelled cells and tiles to re-render")
    sp.add_argument("old")
    sp.add_argument("new")
    sp.add_argument("--max-zoom", type=int, default=16)
    sp.add_argument("--min-zoom", type=int, default=0)
    sp.add_argument("--overscale", type=int, default=2,
                    help="zoom levels past a cell's compilation scale at which it may still be drawn")
    sp.add_argument("--dilate", type=int, default=1, help="grow the tile set by N tiles (edge labels/symbols)")
    sp.add_argument("--tiles-out", help="write the tile list (XYZ) to this JSON file")
    sp.add_argument("--json", action="store_true")
    sp.set_defaults(func=cmd_diff)

    sp = sub.add_parser("download", help="download cell zips into a cache (resumable, verified)")
    sp.add_argument("--snapshot", required=True)
    sp.add_argument("--cache", required=True)
    sp.add_argument("--changed-since", metavar="OLD_SNAPSHOT", help="only cells changed since this snapshot")
    sp.add_argument("--only", nargs="+", metavar="CELL")
    sp.add_argument("--verify", action="store_true", help="re-hash cached files before skipping them")
    sp.add_argument("--workers", type=int, default=2, choices=[1, 2])
    sp.set_defaults(func=cmd_download)

    sp = sub.add_parser("activity", help="cells issued per week (from isdt)")
    sel_args(sp)
    sp.add_argument("--weeks", type=int, default=12)
    sp.add_argument("--today", help="YYYY-MM-DD (default: catalog date)")
    sp.add_argument("--json", action="store_true")
    sp.set_defaults(func=cmd_activity)
    return p


def main(argv=None):
    args = build_parser().parse_args(argv)
    args.func(args)


if __name__ == "__main__":
    main()
