"""Catalog-driven, tiled, incremental build of a region's routing pack.

Stages and caches (all under the work directory, see config.work_dir):

  catalog/ENCProdCat.xml       conditional GET (pipeline/catalog)
  snapshots/snap-<date>.json   catalog snapshot per run (for `enc-catalog diff`)
  cache/cells/<cell>.zip       zips; re-downloaded only when edition/update changes
  extract/v3/<cell>.<ed>.<upd>.pkl   S-57 read once per edition/update
  merge/<cell>.<key>.pkl       the cell clipped to its exclusive region; key covers the cell and every
                               higher-priority cell overlapping it
  ncf/blocks/*.geojson         USACE NCF per 1 degree block
  mask/outside.<key>.npz       open-Gulf raster (whole Gulf)
  tiles/<k>/<key>.pkl          one tile's mesh; key = hash of all its inputs + parameters
  regions/<rid>/routing-<rid>-<date>.pack, build.json, checks.pkl

A rebuild with an unchanged catalog re-reads the caches and re-assembles
nothing (the pack key is unchanged). A changed cell re-extracts that cell,
re-clips it and the cells under it, rebuilds only the tiles whose inputs
changed, and re-assembles the region (seconds to a few minutes).
"""
from __future__ import annotations

import datetime as dt
import hashlib
import json
import os
import resource
import time

import pandas as pd
import shapely

from .config import BUILDER_VERSION, Region


def log(msg):
    print(f"[{time.strftime('%H:%M:%S')}] {msg}", flush=True)


def build_stamp_from_env():
    """SOURCE_DATE_EPOCH (reproducible builds convention) fixes the header build date/time."""
    v = os.environ.get("SOURCE_DATE_EPOCH")
    if v:
        return dt.datetime.fromtimestamp(int(v), dt.timezone.utc)
    return None


def _maxrss_mb():
    return {"parent_mb": round(resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / 1024),
            "largest_worker_mb": round(resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss / 1024)}


def prepare_sources(catalog_copy=None, offline: bool = False, workers: int = 4):
    """Catalog, downloads, extraction and merge for the whole Gulf.
    Returns (catalog, cells, merged_entries, anomalies dict)."""
    from . import merge
    from .download import download_cells
    from .extract import cell_anomalies, extract_cells, load_cell
    from .sources import gulf_cells

    cat, cells = gulf_cells(catalog_copy)
    anomalies = {"download_failed": {}, "extract_failed": {}, "cells": {}}
    if not offline:
        dl = download_cells(cells)
        anomalies["download_failed"] = dl["failed"]
    cells = [c for c in cells if c.name not in anomalies["download_failed"]]
    anomalies["extract_failed"] = extract_cells(cells, workers=workers, log=log)
    cells = [c for c in cells if c.name not in anomalies["extract_failed"]]
    merged = merge.merge_all(cells, load_cell, log=log)
    for c in cells:
        e = merged[c.name]
        a = []
        meta = e["meta"]
        a += [f"GDAL: {w}" for w in meta.get("warnings", [])]
        from .extract import EXPECTED_DSPM
        for k, v in EXPECTED_DSPM.items():
            if meta.get("dspm", {}).get(k) != v:
                a.append(f"DSPM {k}={meta.get('dspm', {}).get(k)} (expected {v})")
        if str(meta.get("updn")) != str(c.updn):
            a.append(f"applied update {meta.get('updn')} != catalog {c.updn}")
        if e["cov_source"] != "M_COVR":
            a.append(f"no M_COVR with CATCOV=1: coverage from {e['cov_source']}")
        st = e["stats"]
        if st.get("same_band_overlap_km2"):
            a.append("same-band overlap with higher-priority cells (km2): " +
                     ", ".join(f"{o} {v}" for o, v in st["same_band_overlap_km2"]))
        if e["excl"].is_empty:
            a.append("fully superseded by higher-priority cells (contributes nothing)")
        if a:
            anomalies["cells"][c.name] = a
    del cell_anomalies
    return cat, cells, merged, anomalies


def coverage_union(merged):
    return shapely.union_all([e["excl"] for e in merged.values() if not e["excl"].is_empty])


def write_checks(region, source, tiles, path):
    """Raw source geometry (lon/lat) for the regression checks of reference
    routes: land, structures and blocking hazards; fenders; bridges over
    water (for the reduced-clearance zones); overhead objects with clearance."""
    from . import layers as L

    b = shapely.union_all([shapely.box(*t.bounds) for t in tiles])
    shapely.prepare(b)
    sub = {}
    for k, g in source.frames.items():
        m = shapely.intersects(b, g.geometry.values)
        if m.any():
            sub[k] = g[m].reset_index(drop=True)
    shore, fenders = L.shore_parts(sub, split_fenders=True)
    haz = L.hazards(sub)
    block = list(shore) + list(haz[haz.blocking].geometry.values)
    over = L.overhead(sub, None)
    checks = {"obstacles": shapely.to_wkb(block), "fenders": shapely.to_wkb(fenders),
              "bridges": shapely.to_wkb(sub["BRIDGE"].geometry.values) if "BRIDGE" in sub else [],
              "overhead": over.drop(columns=[c for c in over.columns if c == "foot"]) if len(over) else over}
    pd.to_pickle(checks, path)


def build(region: Region, force: bool = False, catalog_copy=None, workers: int = 4, build_stamp=None,
          offline: bool = False, prepared=None) -> dict:
    from . import mask as M
    from . import merge, ncf, packfmt
    from .assemble import assemble
    from .tiles import Source, build_tiles, load_tile, tiles_for

    t0 = time.time()
    p = region.params
    cat, cells, merged, anomalies = prepared or prepare_sources(catalog_copy, offline, workers)
    t_src = time.time() - t0
    cov = coverage_union(merged)
    tiles = tiles_for(region.geometry, cov, p)
    if not tiles:
        raise RuntimeError(f"region {region.rid}: no tiles with ENC coverage")
    tb = shapely.union_all([shapely.box(*t.bounds) for t in tiles]).bounds
    log(f"region {region.rid}: {len(tiles)} tiles, bounds {[round(v, 2) for v in tb]}")
    nc = ncf.load(tb, log=log, offline=offline)
    anomalies["ncf"] = nc.pop("anomalies", [])
    mk = M.build_mask(merged, merge.load_merged, p, log=log)
    source = Source(merged, merge.load_merged, nc, mk, tb, p, log=log)
    t1 = time.time()
    tb_stats = build_tiles(source, tiles, workers=workers, log=log)
    t_tiles = time.time() - t1
    keys = tb_stats["keys"]
    region_cells = sorted(f"{n}.{merged[n]['meta']['edtn']}.{merged[n]['meta']['updn']}" for n in source.cells)
    pkey = hashlib.sha256(json.dumps([BUILDER_VERSION, p.key(), sorted(keys.items()), region_cells,
                                      region.rid]).encode()).hexdigest()[:16]
    bjson = region.dir("build.json")
    if bjson.exists() and not force:
        prev = json.loads(bjson.read_text())
        if prev.get("key") == pkey and region.dir(prev["pack"]).exists():
            prev["cached"] = True
            prev["seconds_this_run"] = round(time.time() - t0, 1)
            log(f"region {region.rid}: unchanged (pack key {pkey})")
            return prev
    t2 = time.time()
    pack, rep = assemble(region, keys, source, merged, load_tile, build_stamp=build_stamp or build_stamp_from_env(),
                         log=log)
    name = f"routing-{region.rid}-{pack.data_date}.pack"
    for old in region.dir().glob(f"routing-{region.rid}-*.pack"):
        if old.name != name:
            old.unlink()
    sizes = packfmt.write_pack(pack, region.dir(name), with_adjacency=False)
    t_asm = time.time() - t2
    write_checks(region, source, tiles, region.dir("checks.pkl"))
    raw = region.dir(name).read_bytes()
    out = {"key": pkey, "region": region.rid, "pack": name, "pack_bytes": len(raw),
           "sha256": hashlib.sha256(raw).hexdigest(),
           "content_sha256": hashlib.sha256(raw[256:]).hexdigest(),
           "format": f"{packfmt.FORMAT_MAJOR}.{packfmt.FORMAT_MINOR}", "data_date": pack.data_date,
           "build_date": pack.build_date, "build_time": pack.build_time, "catalog_date": cat.date_created,
           "bbox": [v / 1e7 for v in pack.bbox], "chart_bbox": region.chart_bbox,
           "sections": {k: {"stored": v[0], "raw": v[1]} for k, v in sizes.items()},
           "cells_in_region": len(source.cells), "cells_used": int(pack.sources["used"].sum()),
           "tiles": tb_stats | {"keys": None}, "report": rep, "mask": mk["stats"],
           "anomalies": _region_anomalies(anomalies, source.cells),
           "seconds": {"sources": round(t_src, 1), "tiles": round(t_tiles, 1), "assemble": round(t_asm, 1),
                       "total": round(time.time() - t0, 1)},
           "memory": _maxrss_mb(), "cached": False}
    out["tiles"].pop("keys", None)
    region.dir("tiles.json").write_text(json.dumps(keys, indent=0, sort_keys=True))
    bjson.write_text(json.dumps(out, indent=1, default=str))
    log(f"region {region.rid}: {name} {len(raw) / 1e6:.2f} MB, {rep['triangles']} triangles, "
        f"{out['seconds']['total']} s")
    return out


def _region_anomalies(an, cells):
    cs = set(cells)
    return {"download_failed": an["download_failed"], "extract_failed": an["extract_failed"],
            "cells": {k: v for k, v in an["cells"].items() if k in cs},
            "ncf": an.get("ncf", [])}
