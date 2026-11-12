"""Command line: python -m enc_routing <step> [...]

Steps (each caches its output under WORK_DIR and can be re-run):
  select     parse the ENC catalog, list cells covering the pilot bbox
  download   fetch cell zips (cached by edition/update)
  extract    S-57 -> extract.gpkg (updates applied)
  merge      best-available multi-scale merge -> merged.gpkg
  polygons   safe-water polygons per threshold + connectivity report
  channels   channel/track/aid density report (+ USACE NCF probe)
  bridges    overhead-clearance table
  graph      navigation mesh (CDT) -> mesh.npz
  route      run the reference routes
  render     PNG figures
  all        everything above in order
"""
from __future__ import annotations

import argparse
import json
import sys
import time

from . import config


def _cells(args):
    from .catalog import parse_catalog, select_cells
    from .download import get_catalog

    cat = get_catalog(local_copy=args.catalog_copy)
    return select_cells(parse_catalog(cat), config.PILOT_BBOX)


def step_select(args):
    from collections import Counter

    cells = _cells(args)
    by_band = Counter(c.band_name for c in cells)
    size = sum(c.size for c in cells)
    rep = {"cells": len(cells), "zip_bytes": size, "by_band": dict(by_band),
           "names": [c.name for c in cells]}
    config.work("reports", "select.json").write_text(json.dumps(rep, indent=1))
    print(f"{len(cells)} active cells, {size/1e6:.1f} MB zipped, by band {dict(by_band)}")
    return cells


def step_download(args):
    from .download import download_cells

    print(download_cells(_cells(args)))


def step_extract(args):
    from .extract import extract_all

    p = extract_all(_cells(args), force=args.force)
    print("wrote", p)
    print(config.work("extract", "counts.json").read_text())


def step_merge(args):
    from .merge import run_merge

    rep = run_merge()
    rep.pop("features", None)
    print(json.dumps(rep, indent=1)[:3000])


def step_polygons(args):
    from .safewater import run_polygons

    if args.force:
        config.work("polygons", "gulf_mask.wkb").unlink(missing_ok=True)
    rep = run_polygons()
    for t, r in rep["thresholds"].items():
        print(t, "ft:", r["components_ge_100m2"], "parts,", len(r["icw_breaks"]), "ICW breaks")


def step_channels(args):
    from .channels import run_channels

    print(json.dumps(run_channels(), indent=1, default=str)[:3000])


def step_bridges(args):
    from .bridges import run_bridges

    print(json.dumps(run_bridges(), indent=1)[:4000])


def step_graph(args):
    from .graph import run_graph

    print(json.dumps(run_graph(force=args.force), indent=1))


def step_route(args):
    from .route import run_routes

    for k, v in run_routes().items():
        print(k, json.dumps(v, default=str)[:600])


def step_render(args):
    from .render import run_render

    run_render()


STEPS = {
    "select": step_select, "download": step_download, "extract": step_extract,
    "merge": step_merge, "polygons": step_polygons, "channels": step_channels,
    "bridges": step_bridges, "graph": step_graph, "route": step_route, "render": step_render,
}


def main(argv=None):
    ap = argparse.ArgumentParser(prog="enc_routing", description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("step", choices=list(STEPS) + ["all"])
    ap.add_argument("--force", action="store_true", help="ignore caches")
    ap.add_argument("--catalog-copy", default=None,
                    help="use this local ENCProdCat.xml instead of downloading")
    args = ap.parse_args(argv)
    steps = list(STEPS) if args.step == "all" else [args.step]
    for s in steps:
        t = time.time()
        print(f"== {s}", file=sys.stderr)
        STEPS[s](args)
        print(f"== {s} done in {time.time()-t:.1f}s", file=sys.stderr)


if __name__ == "__main__":
    main()
