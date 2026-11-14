"""Polite HTTP: catalog fetch (conditional GET) and resumable, verified cell downloads."""
from __future__ import annotations

import hashlib
import json
import os
import threading
import time
import zipfile
import zlib
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path

import requests

from .catalog import CATALOG_URL

USER_AGENT = "enc-catalog/0.1 (python-requests)"
RETRY_STATUS = {429, 500, 502, 503, 504}


class Http:
    """requests.Session with a generic User-Agent, a concurrency cap and
    exponential backoff on 429/5xx (honouring Retry-After)."""

    def __init__(self, max_concurrency: int = 2, retries: int = 5, backoff: float = 2.0, timeout: float = 120):
        self.session = requests.Session()
        self.session.headers["User-Agent"] = USER_AGENT
        self._sem = threading.Semaphore(max_concurrency)
        self.retries, self.backoff, self.timeout = retries, backoff, timeout

    def request(self, method: str, url: str, **kw) -> requests.Response:
        delay = self.backoff
        last_exc = None
        for attempt in range(self.retries + 1):
            try:
                with self._sem:
                    r = self.session.request(method, url, timeout=self.timeout, **kw)
                if r.status_code not in RETRY_STATUS or attempt == self.retries:
                    return r
                ra = r.headers.get("Retry-After", "")
                wait = float(ra) if ra.isdigit() else delay
                r.close()
            except (requests.ConnectionError, requests.Timeout) as e:
                last_exc = e
                if attempt == self.retries:
                    raise
                wait = delay
            time.sleep(wait)
            delay *= 2
        raise last_exc  # pragma: no cover


def fetch_catalog(dest: str | Path, http: Http | None = None, url: str = CATALOG_URL) -> bool:
    """Download the catalog to dest. Uses ETag/Last-Modified from a sidecar
    file for a conditional GET. Returns True if dest was (re)written."""
    http = http or Http()
    dest = Path(dest)
    meta_path = dest.with_name(dest.name + ".http.json")
    headers = {}
    if dest.exists() and meta_path.exists():
        meta = json.loads(meta_path.read_text())
        if meta.get("etag"):
            headers["If-None-Match"] = meta["etag"]
        if meta.get("last_modified"):
            headers["If-Modified-Since"] = meta["last_modified"]
    r = http.request("GET", url, headers=headers, stream=True)
    if r.status_code == 304:
        return False
    r.raise_for_status()
    tmp = dest.with_name(dest.name + ".tmp")
    with open(tmp, "wb") as f:
        for chunk in r.iter_content(1 << 16):
            f.write(chunk)
    os.replace(tmp, dest)
    meta_path.write_text(json.dumps({"etag": r.headers.get("ETag"), "last_modified": r.headers.get("Last-Modified"),
                                     "fetched": _now()}))
    return True


@dataclass
class CellRequest:
    name: str
    url: str
    size: int
    edtn: int
    updn: int
    isdt: str
    uadt: str

    @property
    def version(self) -> dict:
        return {"edtn": self.edtn, "updn": self.updn, "isdt": self.isdt, "uadt": self.uadt}

    @classmethod
    def from_snapshot(cls, name: str, e: dict) -> "CellRequest":
        return cls(name, e["zip_url"], e["zip_size"], e["edtn"], e["updn"], e["isdt"], e["uadt"])


@dataclass
class Result:
    name: str
    status: str  # "skipped" | "downloaded" | "resumed" | "failed"
    bytes: int = 0
    error: str = ""


class CellCache:
    """cache_dir/cells/<NAME>.zip plus cache_dir/cache.json recording the
    version, size and sha256 of each cached zip."""

    def __init__(self, cache_dir: str | Path):
        self.dir = Path(cache_dir)
        self.cells = self.dir / "cells"
        self.cells.mkdir(parents=True, exist_ok=True)
        self.index_path = self.dir / "cache.json"
        self._lock = threading.Lock()
        self.index = json.loads(self.index_path.read_text()) if self.index_path.exists() else {}

    def path(self, name: str) -> Path:
        return self.cells / f"{name}.zip"

    def is_current(self, req: CellRequest, verify: bool = False) -> bool:
        e = self.index.get(req.name)
        p = self.path(req.name)
        if not e or not p.exists() or e.get("version") != req.version:
            return False
        if p.stat().st_size != e.get("size") or (req.size and e.get("size") != req.size):
            return False
        return not verify or _sha256(p) == e.get("sha256")

    def _record(self, req: CellRequest, p: Path):
        with self._lock:
            self.index[req.name] = {"version": req.version, "size": p.stat().st_size, "sha256": _sha256(p),
                                    "url": req.url, "fetched": _now()}
            tmp = self.index_path.with_suffix(".tmp")
            tmp.write_text(json.dumps(dict(sorted(self.index.items())), indent=1))
            os.replace(tmp, self.index_path)

    def fetch(self, req: CellRequest, http: Http, verify: bool = False) -> Result:
        if self.is_current(req, verify):
            return Result(req.name, "skipped")
        final, part = self.path(req.name), self.path(req.name).with_suffix(".zip.part")
        # A .part is only resumable if it belongs to the same version.
        tag = part.with_suffix(".part.version")
        if part.exists() and (not tag.exists() or json.loads(tag.read_text()) != req.version):
            part.unlink()
        tag.write_text(json.dumps(req.version))
        have = part.stat().st_size if part.exists() else 0
        status = "resumed" if have else "downloaded"
        try:
            if req.size and have > req.size:
                part.unlink()
                have, status = 0, "downloaded"
            if not (req.size and have == req.size):
                headers = {"Range": f"bytes={have}-"} if have else {}
                r = http.request("GET", req.url, headers=headers, stream=True)
                if r.status_code == 416 and have:
                    r.close()
                elif r.status_code in (200, 206):
                    mode = "ab" if (r.status_code == 206 and have) else "wb"
                    if mode == "wb":
                        status = "downloaded"
                    with open(part, mode) as f:
                        for chunk in r.iter_content(1 << 16):
                            f.write(chunk)
                else:
                    return Result(req.name, "failed", error=f"HTTP {r.status_code}")
            got = part.stat().st_size
            if req.size and got != req.size:
                return Result(req.name, "failed", got, f"size {got} != catalog {req.size}")
            try:
                with zipfile.ZipFile(part) as z:
                    bad = z.testzip()
            except (zipfile.BadZipFile, zlib.error, EOFError) as e:
                bad = repr(e)
            if bad is not None:
                part.unlink()
                return Result(req.name, "failed", got, f"corrupt zip: {bad}")
            os.replace(part, final)
            tag.unlink(missing_ok=True)
            self._record(req, final)
            return Result(req.name, status, got)
        except (requests.RequestException, OSError) as e:
            return Result(req.name, "failed", error=repr(e))

    def fetch_all(self, reqs: list[CellRequest], http: Http | None = None, verify: bool = False,
                  workers: int = 2) -> list[Result]:
        http = http or Http(max_concurrency=workers)
        with ThreadPoolExecutor(max_workers=workers) as ex:
            return list(ex.map(lambda r: self.fetch(r, http, verify), reqs))


def _sha256(p: Path) -> str:
    h = hashlib.sha256()
    with open(p, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def _now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
