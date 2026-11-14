"""On-disk layout of a build root and the per-region version history.

    <root>/
      state/<pkg>/snapshot.json   catalog snapshot the current package was built from
      state/<pkg>/versions.json   package version history (newest last)
      work/<pkg>/run.json         an unfinished run (mode, version, snapshot) -> resume
      work/<pkg>/snapshot.json    the snapshot that run is building towards
      work/<pkg>/work.mbtiles     the package being written (has chart_build_pending)
      packages/<pkg>/<pkg>-<version>.mbtiles   finished packages
      publish/                    default local publish directory (manifest.json + packages)
      logs/requests.jsonl         every request made to NOAA, one JSON object per line

`<pkg>` is the region id, with `_2x` appended for retina packages. In GitHub
Actions `state/` travels as a release asset (see docs/chart-build.md).
"""
from __future__ import annotations

import json
import os
import shutil
from dataclasses import dataclass
from pathlib import Path


def package_id(region: str, scale: int) -> str:
    return region if scale == 1 else f"{region}_{scale}x"


def _write_json(path: Path, obj) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_text(json.dumps(obj, indent=1, sort_keys=False) + "\n")
    os.replace(tmp, path)


@dataclass
class BuildRoot:
    root: Path

    def __post_init__(self):
        self.root = Path(self.root)

    def state_dir(self, pkg: str) -> Path:
        return self.root / "state" / pkg

    def work_dir(self, pkg: str) -> Path:
        return self.root / "work" / pkg

    def package_dir(self, pkg: str) -> Path:
        return self.root / "packages" / pkg

    @property
    def request_log(self) -> Path:
        p = self.root / "logs" / "requests.jsonl"
        p.parent.mkdir(parents=True, exist_ok=True)
        return p

    # versions
    def versions(self, pkg: str) -> list[dict]:
        p = self.state_dir(pkg) / "versions.json"
        return json.loads(p.read_text())["versions"] if p.exists() else []

    def current(self, pkg: str) -> dict | None:
        v = self.versions(pkg)
        return v[-1] if v else None

    def add_version(self, pkg: str, rec: dict) -> None:
        vs = self.versions(pkg)
        vs.append(rec)
        _write_json(self.state_dir(pkg) / "versions.json", {"package": pkg, "versions": vs})

    def update_version(self, pkg: str, version: str, **fields) -> None:
        vs = self.versions(pkg)
        for v in vs:
            if v["version"] == version:
                v.update(fields)
        _write_json(self.state_dir(pkg) / "versions.json", {"package": pkg, "versions": vs})

    def next_version(self, pkg: str, catalog_date: str) -> str:
        taken = {v["version"] for v in self.versions(pkg)}
        if catalog_date not in taken:
            return catalog_date
        k = 2
        while f"{catalog_date}.{k}" in taken:
            k += 1
        return f"{catalog_date}.{k}"

    def package_path(self, pkg: str, rec: dict) -> Path:
        return self.package_dir(pkg) / rec["file"]

    # snapshots
    def snapshot_path(self, pkg: str) -> Path:
        return self.state_dir(pkg) / "snapshot.json"

    def save_snapshot(self, pkg: str, src: Path) -> None:
        dst = self.snapshot_path(pkg)
        dst.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(src, dst)

    # runs
    def run_record(self, pkg: str) -> dict | None:
        p = self.work_dir(pkg) / "run.json"
        return json.loads(p.read_text()) if p.exists() else None

    def start_run(self, pkg: str, rec: dict, snapshot: dict) -> None:
        d = self.work_dir(pkg)
        d.mkdir(parents=True, exist_ok=True)
        _write_json(d / "snapshot.json", snapshot)
        _write_json(d / "run.json", rec)

    def discard_run(self, pkg: str) -> None:
        shutil.rmtree(self.work_dir(pkg), ignore_errors=True)


write_json = _write_json
