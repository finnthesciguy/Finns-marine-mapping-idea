"""Publishing targets: a local directory (used here) and GitHub Releases
(implemented against the REST API, not exercised in this repository yet)."""
from __future__ import annotations

import hashlib
import json
import os
import shutil
from pathlib import Path
from urllib.parse import quote

import requests

from . import manifest as mf


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


class LocalTarget:
    """Copies packages into a directory served at base_url."""

    def __init__(self, directory: str | Path, base_url: str):
        self.dir = Path(directory)
        self.base_url = base_url.rstrip("/")

    def url_for(self, name: str) -> str:
        return f"{self.base_url}/{quote(name)}"

    def upload(self, path: Path, name: str | None = None) -> str:
        name = name or path.name
        self.dir.mkdir(parents=True, exist_ok=True)
        dst = self.dir / name
        if not (dst.exists() and dst.stat().st_size == path.stat().st_size and sha256_file(dst) == sha256_file(path)):
            tmp = dst.with_name(dst.name + ".tmp")
            shutil.copyfile(path, tmp)
            os.replace(tmp, dst)
        return self.url_for(name)

    def existing_manifest(self) -> dict | None:
        p = self.dir / "manifest.json"
        return json.loads(p.read_text()) if p.exists() else None

    def put_manifest(self, m: dict) -> str:
        self.dir.mkdir(parents=True, exist_ok=True)
        p = self.dir / "manifest.json"
        tmp = p.with_name("manifest.json.tmp")
        tmp.write_text(json.dumps(m, indent=2, sort_keys=True) + "\n")
        os.replace(tmp, p)
        return self.url_for("manifest.json")


class GitHubReleaseTarget:
    """Uploads assets to a GitHub release (created if missing) with the REST
    API. Token from GITHUB_TOKEN or GH_TOKEN. Asset URLs are the stable
    `https://github.com/<repo>/releases/download/<tag>/<name>` form, which
    redirects to the CDN and supports Range requests.

    NOTE: implemented but not yet run against GitHub (no token in the build
    container); exercise it with a test repository before relying on it."""

    API = "https://api.github.com"

    def __init__(self, repo: str, tag: str, token: str | None = None, session: requests.Session | None = None,
                 title: str | None = None, notes: str = ""):
        self.repo, self.tag = repo, tag
        token = token or os.environ.get("GITHUB_TOKEN") or os.environ.get("GH_TOKEN")
        if not token:
            raise RuntimeError("GitHubReleaseTarget needs GITHUB_TOKEN or GH_TOKEN in the environment")
        self.s = session or requests.Session()
        self.s.headers.update({"Authorization": f"Bearer {token}", "Accept": "application/vnd.github+json",
                               "X-GitHub-Api-Version": "2022-11-28", "User-Agent": "chart-build-publisher"})
        self.title, self.notes = title or tag, notes
        self._release = None

    def release(self) -> dict:
        if self._release:
            return self._release
        r = self.s.get(f"{self.API}/repos/{self.repo}/releases/tags/{quote(self.tag)}")
        if r.status_code == 404:
            r = self.s.post(f"{self.API}/repos/{self.repo}/releases",
                            json={"tag_name": self.tag, "name": self.title, "body": self.notes, "make_latest": "true"})
        r.raise_for_status()
        self._release = r.json()
        return self._release

    def url_for(self, name: str) -> str:
        return f"https://github.com/{self.repo}/releases/download/{quote(self.tag)}/{quote(name)}"

    def upload(self, path: Path, name: str | None = None, content_type: str = "application/octet-stream") -> str:
        name = name or path.name
        rel = self.release()
        for a in rel.get("assets", []):
            if a["name"] == name:
                if a["size"] == path.stat().st_size and name != "manifest.json":
                    return self.url_for(name)
                self.s.delete(f"{self.API}/repos/{self.repo}/releases/assets/{a['id']}").raise_for_status()
        upload_url = rel["upload_url"].split("{", 1)[0]
        with open(path, "rb") as f:
            r = self.s.post(upload_url, params={"name": name}, data=f,
                            headers={"Content-Type": content_type, "Content-Length": str(path.stat().st_size)},
                            timeout=3600)
        r.raise_for_status()
        self._release = None
        return self.url_for(name)

    def existing_manifest(self) -> dict | None:
        r = self.s.get(f"https://github.com/{self.repo}/releases/latest/download/manifest.json", timeout=60)
        return r.json() if r.status_code == 200 else None

    def put_manifest(self, m: dict) -> str:
        tmp = Path(os.environ.get("RUNNER_TEMP", "/tmp")) / "manifest.json"
        tmp.write_text(json.dumps(m, indent=2, sort_keys=True) + "\n")
        return self.upload(tmp, "manifest.json", "application/json")


def publish(target, items: list[tuple], base_manifest: dict | None = None, publisher: str = "Gulf chart build service") -> dict:
    """items: (RegionDef, version record, package path). Uploads each package,
    checks size and hash against the record, writes and validates the manifest."""
    entries = []
    for region, rec, path in items:
        path = Path(path)
        size, sha = path.stat().st_size, sha256_file(path)
        if size != rec["bytes"] or sha != rec["sha256"]:
            raise RuntimeError(f"{path}: size/hash do not match the build record (file changed after the build?)")
        url = target.upload(path)
        entries.append(mf.region_entry(region, rec, url))
    base = base_manifest if base_manifest is not None else target.existing_manifest()
    m = mf.build(entries, publisher=publisher, base=base)
    target.put_manifest(m)
    return m
