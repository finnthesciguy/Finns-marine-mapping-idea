"""Catalog-driven, cached build of a region's routing pack.

Cache levels (all under WORK_DIR):
  zips/            cell zips, re-downloaded only when edition/update changes
  extract/cells/   per cell edition+update pickles (S-57 read once)
  regions/<rid>/merged.<key>.pkl   merge, key = hash(cells+editions, builder version, CRS)
  regions/<rid>/routing-<rid>-<date>.pack + build.json, key = hash(merge key, params, builder)
A rebuild with an unchanged catalog does nothing; a changed cell re-extracts
only that cell and re-runs merge and mesh.
"""
from __future__ import annotations

import hashlib
import json
import time

import pandas as pd
import shapely

from . import config
from .config import BUILDER_VERSION, Region


def _cells(region, catalog_copy=None):
    from .catalog import parse_catalog, select_cells
    from .download import get_catalog

    cat = get_catalog(local_copy=catalog_copy)
    return select_cells(parse_catalog(cat), region.bbox)


def build(region: Region, force: bool = False, catalog_copy=None) -> dict:
    from . import mesh, packfmt
    from .download import download_cells
    from .extract import extract_cells
    from .merge import merge_region

    t0 = time.time()
    cells = _cells(region, catalog_copy)
    dl = download_cells(cells)
    per_layer, metas, n_new = extract_cells(cells)
    ident = sorted(f"{c.name}.{c.edtn}.{c.updn}" for c in cells)
    mkey = hashlib.sha256(json.dumps([ident, BUILDER_VERSION, region.crs]).encode()).hexdigest()[:16]
    mpath = region.dir(f"merged.{mkey}.pkl")
    if mpath.exists() and not force:
        merged, mstats = pd.read_pickle(mpath)
        merged_cached = True
    else:
        merged, mstats = merge_region(region, per_layer, metas)
        pd.to_pickle((merged, mstats), mpath)
        merged_cached = False
    bkey = hashlib.sha256(json.dumps([mkey, region.params.key(), BUILDER_VERSION]).encode()).hexdigest()[:16]
    bjson = region.dir("build.json")
    if bjson.exists() and not force:
        prev = json.loads(bjson.read_text())
        if prev.get("key") == bkey and (region.dir(prev["pack"])).exists():
            prev["cached"] = True
            prev["download"] = dl
            return prev
    pack, prep, rep = mesh.build_pack(region, merged, metas, mstats)
    name = f"routing-{region.rid}-{pack.data_date}.pack"
    sizes = packfmt.write_pack(pack, region.dir(name), with_adjacency=False)
    # source obstacles (raw land/structures/blocking hazards, metric WKB) for
    # the regression check that no route touches them
    region.dir("obstacles.wkb").write_bytes(shapely.to_wkb(prep["block_raw"]))
    region.dir("domain.wkb").write_bytes(shapely.to_wkb(prep["domain"]))
    region.dir("bridge_zone.wkb").write_bytes(shapely.to_wkb(prep["bridge_zone"]))
    region.dir("fenders.wkb").write_bytes(shapely.to_wkb(prep["fender_raw"]))
    out = {"key": bkey, "merge_key": mkey, "pack": name, "pack_bytes": region.dir(name).stat().st_size,
           "sections": {k: {"stored": v[0], "raw": v[1]} for k, v in sizes.items()},
           "cells": len(cells), "cells_extracted_now": n_new, "merge_cached": merged_cached,
           "download": dl, "report": rep, "seconds": round(time.time() - t0, 1), "cached": False}
    bjson.write_text(json.dumps(out, indent=1, default=str))
    return out
