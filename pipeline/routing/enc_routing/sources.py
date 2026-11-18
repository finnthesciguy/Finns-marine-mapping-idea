"""Source data for the whole Gulf: catalog -> snapshot -> download -> extract.

All Gulf cells of band >= MIN_BAND are fetched and extracted once (cached per
edition and update), and the catalog snapshot of every run is kept so the
next run can be diffed against it (`enc-catalog diff`).
"""
from __future__ import annotations

import json
import time

from .config import MIN_BAND, work


def log(msg):
    print(f"[{time.strftime('%H:%M:%S')}] {msg}", flush=True)


def gulf_cells(catalog_copy=None, max_age_h: float = 12):
    """(catalog, cells): active Gulf cells of band >= MIN_BAND from the current catalog;
    also writes snapshots/snap-<catalog date>.json."""
    from enc_catalog import make_snapshot, write_snapshot

    from .catalog import gulf_selection
    from .download import get_catalog

    path = get_catalog(max_age_h=max_age_h, local_copy=catalog_copy)
    cat, sel, cells = gulf_selection(path, MIN_BAND)
    snap = work("snapshots", f"snap-{cat.date_created or 'unknown'}.json")
    if not snap.exists():
        write_snapshot(make_snapshot(cat, sel), snap)
    return cat, cells


def fetch_and_extract(catalog_copy=None, workers: int = 4) -> dict:
    """Download and extract every Gulf cell. Returns a summary (also written to
    sources.json): catalog date, cell count, download stats, failures."""
    from .download import download_cells
    from .extract import extract_cells

    t0 = time.time()
    cat, cells = gulf_cells(catalog_copy)
    log(f"catalog {cat.date_created}: {len(cells)} Gulf cells of band >= {MIN_BAND}, "
        f"{sum(c.zipfile_size for c in cells) / 1e6:.1f} MB zipped")
    dl = download_cells(cells)
    log(f"download: {dl['fetched']} fetched, {len(dl['failed'])} failed")
    ok = [c for c in cells if c.name not in dl["failed"]]
    errors = extract_cells(ok, workers=workers, log=log)
    out = {"catalog_date": cat.date_created, "cells": len(cells), "download": dl,
           "extract_failed": errors, "seconds": round(time.time() - t0, 1)}
    work("sources.json").write_text(json.dumps(out, indent=1))
    return out
