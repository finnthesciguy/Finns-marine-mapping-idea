"""Cached, polite downloads through pipeline/catalog (`enc_catalog.download`):
the catalog with a conditional GET, cell zips resumable and verified (size,
zip CRC, sha256), at most two at a time with a generic User-Agent.
Downloaded files are data only: they are parsed, never executed.
"""
from __future__ import annotations

import os
import time
import zipfile
from pathlib import Path

from .config import work


def get_catalog(max_age_h: float = 12, local_copy: str | None = None) -> Path:
    """The catalog file under work/catalog. Re-fetched (conditional GET) when
    older than max_age_h; a local copy can stand in for the network."""
    from enc_catalog.download import Http, fetch_catalog

    dest = work("catalog", "ENCProdCat.xml")
    if local_copy and Path(local_copy).exists():
        if not dest.exists() or Path(local_copy).read_bytes() != dest.read_bytes():
            dest.write_bytes(Path(local_copy).read_bytes())
        return dest
    if dest.exists() and time.time() - dest.stat().st_mtime < max_age_h * 3600:
        return dest
    fetch_catalog(dest, Http(max_concurrency=1))
    os.utime(dest)
    return dest


def cache_dir() -> Path:
    return work("cache", "x").parent


def zip_path(name: str) -> Path:
    return cache_dir() / "cells" / f"{name}.zip"


def download_cells(cells, workers: int = 2) -> dict:
    """Download every cell zip whose cached copy is not current. Returns a
    summary with the failures (a failed cell is left out of the build and
    reported)."""
    from enc_catalog.download import CellCache, CellRequest, Http

    cache = CellCache(cache_dir())
    reqs = [CellRequest(c.name, c.zipfile_location, c.zipfile_size, c.edtn, c.updn, c.isdt, c.uadt)
            for c in cells]
    res = cache.fetch_all(reqs, Http(max_concurrency=workers), workers=workers)
    failed = {r.name: r.error for r in res if r.status == "failed"}
    return {"cells": len(cells), "fetched": sum(r.status in ("downloaded", "resumed") for r in res),
            "bytes": sum(cache.index.get(c.name, {}).get("size", 0) for c in cells), "failed": failed}


def unzip_cell(name: str) -> Path:
    """Extract ENC_ROOT/<name>/* (base cell + updates) to cells/<name>/.
    Only plain member names are written (no path traversal)."""
    out = work("cells", name, "x").parent
    zpath = zip_path(name)
    marker = out / ".ok"
    if marker.exists() and marker.stat().st_mtime >= zpath.stat().st_mtime:
        return out
    for old in out.glob(f"{name}.*"):
        old.unlink()
    with zipfile.ZipFile(zpath) as z:
        for m in z.namelist():
            base = os.path.basename(m)
            if f"/{name}/" in "/" + m and base.startswith(name) and not m.endswith("/"):
                (out / base).write_bytes(z.read(m))
    marker.touch()
    return out
