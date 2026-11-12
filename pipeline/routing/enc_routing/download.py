"""Cached HTTP downloads (catalog + cell zips). Downloaded files are data only."""
from __future__ import annotations

import json
import os
import ssl
import time
import urllib.request
import zipfile
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

from .config import CATALOG_URL, USER_AGENT, work


def _ssl_context() -> ssl.SSLContext:
    for var in ("SSL_CERT_FILE", "REQUESTS_CA_BUNDLE", "CURL_CA_BUNDLE"):
        if os.environ.get(var) and Path(os.environ[var]).exists():
            return ssl.create_default_context(cafile=os.environ[var])
    if Path("/root/.ccr/ca-bundle.crt").exists():
        return ssl.create_default_context(cafile="/root/.ccr/ca-bundle.crt")
    return ssl.create_default_context()


_CTX = None


def fetch(url: str, dest: Path, timeout: float = 120, retries: int = 3) -> Path:
    global _CTX
    if _CTX is None:
        _CTX = _ssl_context()
    dest.parent.mkdir(parents=True, exist_ok=True)
    tmp = dest.with_suffix(dest.suffix + ".part")
    last = None
    for attempt in range(retries):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
            with urllib.request.urlopen(req, timeout=timeout, context=_CTX) as r, open(tmp, "wb") as f:
                while chunk := r.read(1 << 16):
                    f.write(chunk)
            tmp.replace(dest)
            return dest
        except Exception as e:  # noqa: BLE001 - report and retry
            last = e
            time.sleep(2 * (attempt + 1))
    raise RuntimeError(f"download failed {url}: {last}")


def get_catalog(max_age_h: float = 24, local_copy: str | None = None) -> Path:
    dest = work("catalog", "ENCProdCat.xml")
    if dest.exists() and time.time() - dest.stat().st_mtime < max_age_h * 3600:
        return dest
    if local_copy and Path(local_copy).exists():
        dest.write_bytes(Path(local_copy).read_bytes())
        return dest
    return fetch(CATALOG_URL, dest)


def download_cells(cells, workers: int = 6) -> dict:
    """Download each cell zip unless a cached copy with the same edition/update
    exists. Returns a summary dict (also written to downloads.json)."""
    state_path = work("zips", "state.json")
    state = json.loads(state_path.read_text()) if state_path.exists() else {}

    def one(c):
        dest = work("zips", f"{c.name}.zip")
        key = f"{c.edtn}.{c.updn}"
        if dest.exists() and state.get(c.name) == key and zipfile.is_zipfile(dest):
            return c.name, key, dest.stat().st_size, False
        fetch(c.url, dest)
        if not zipfile.is_zipfile(dest):
            raise RuntimeError(f"{c.name}: not a zip")
        return c.name, key, dest.stat().st_size, True

    fetched = 0
    total = 0
    with ThreadPoolExecutor(workers) as ex:
        for name, key, size, new in ex.map(one, cells):
            state[name] = key
            total += size
            fetched += new
    state_path.write_text(json.dumps(state, indent=1))
    return {"cells": len(cells), "fetched": fetched, "bytes": total}


def unzip_cell(name: str) -> Path:
    """Extract ENC_ROOT/<name>/* (base cell + updates) to cells/<name>/.
    Only plain member names are written (no path traversal)."""
    out = work("cells", name, "x").parent
    zpath = work("zips", f"{name}.zip")
    marker = out / ".ok"
    if marker.exists() and marker.stat().st_mtime >= zpath.stat().st_mtime:
        return out
    with zipfile.ZipFile(zpath) as z:
        for m in z.namelist():
            base = os.path.basename(m)
            if f"/{name}/" in "/" + m and base.startswith(name) and not m.endswith("/"):
                (out / base).write_bytes(z.read(m))
    marker.touch()
    return out
