"""Compact snapshots of the selected cells and the diff between two snapshots."""
from __future__ import annotations

import json
from dataclasses import dataclass, field
from pathlib import Path

from shapely.geometry import Polygon, box
from shapely.ops import unary_union

from .aoi import Selection
from .catalog import Catalog
from .tiles import cell_max_zoom, dilate, merge, tiles_for_geometry

SNAPSHOT_FORMAT = 1
COORD_DIGITS = 6


def _ring(r):
    return [[round(x, COORD_DIGITS), round(y, COORD_DIGITS)] for x, y in r]


def make_snapshot(catalog: Catalog, selection: Selection) -> dict:
    cells = {}
    for c in selection.cells:
        cells[c.name] = {
            "lname": c.lname,
            "band": c.band,
            "cscale": c.cscale,
            "edtn": c.edtn,
            "updn": c.updn,
            "uadt": c.uadt,
            "isdt": c.isdt,
            "zip_datetime": c.zipfile_datetime,
            "zip_size": c.zipfile_size,
            "zip_url": c.zipfile_location,
            "bbox": [round(v, COORD_DIGITS) for v in c.bbox()],
            "regions": selection.regions_of.get(c.name, []),
            # Exterior and interior rings; small, and lets a later diff find the
            # tiles of a cell that has since been cancelled (cancelled cells
            # lose their coverage in the catalog).
            "cov": {
                "E": [_ring(p.ring) for p in c.panels if p.kind != "I"],
                "I": [_ring(p.ring) for p in c.panels if p.kind == "I"],
            },
        }
    return {
        "format": SNAPSHOT_FORMAT,
        "catalog_date": catalog.date_created,
        "catalog_dt_valid": catalog.dt_valid,
        "cell_count": len(cells),
        "cells": dict(sorted(cells.items())),
    }


def write_snapshot(snap: dict, path: str | Path) -> None:
    Path(path).write_text(json.dumps(snap, separators=(",", ":"), sort_keys=False) + "\n")


def read_snapshot(path: str | Path) -> dict:
    snap = json.loads(Path(path).read_text())
    if snap.get("format") != SNAPSHOT_FORMAT:
        raise ValueError(f"{path}: unsupported snapshot format {snap.get('format')!r}")
    return snap


def cell_geometry(entry: dict):
    cov = entry.get("cov") or {}
    ext = [Polygon(r) for r in cov.get("E", []) if len(r) >= 3]
    if not ext:
        return box(*entry["bbox"])
    g = unary_union([p if p.is_valid else p.buffer(0) for p in ext])
    holes = [Polygon(r) for r in cov.get("I", []) if len(r) >= 3]
    if holes:
        g = g.difference(unary_union(holes))
    return g


def _version(e: dict) -> tuple:
    return (e["edtn"], e["updn"], e["isdt"], e["uadt"])


@dataclass
class Diff:
    added: list[str] = field(default_factory=list)
    updated: list[str] = field(default_factory=list)  # same edition, new update or reissue
    new_edition: list[str] = field(default_factory=list)
    cancelled: list[str] = field(default_factory=list)  # gone from the selection
    old: dict = field(default_factory=dict)
    new: dict = field(default_factory=dict)

    @property
    def changed(self) -> list[str]:
        return sorted(set(self.added) | set(self.updated) | set(self.new_edition) | set(self.cancelled))

    def summary(self) -> dict:
        return {
            "old_catalog_date": self.old.get("catalog_date"),
            "new_catalog_date": self.new.get("catalog_date"),
            "added": self.added,
            "new_edition": self.new_edition,
            "updated": self.updated,
            "cancelled": self.cancelled,
            "download_bytes": sum(self.new["cells"][n]["zip_size"] for n in self.added + self.new_edition + self.updated),
        }

    def tiles(self, max_zoom: int = 16, overscale: int = 2, dilate_tiles: int = 1, min_zoom: int = 0):
        """Tiles to re-render, per zoom: coverage of every changed cell (old and
        new footprint), from min_zoom to the cell's own deepest useful zoom."""
        acc: dict[int, set] = {z: set() for z in range(min_zoom, max_zoom + 1)}
        for name in self.changed:
            entries = [s["cells"][name] for s in (self.old, self.new) if name in s.get("cells", {})]
            geom = unary_union([cell_geometry(e) for e in entries])
            cscale = min(e["cscale"] for e in entries)
            zmax = cell_max_zoom(cscale, max_zoom, overscale)
            if zmax < min_zoom:
                continue
            acc = merge(acc, tiles_for_geometry(geom, zmax, min_zoom))
        return dilate(acc, dilate_tiles)


def diff_snapshots(old: dict, new: dict) -> Diff:
    oc, nc = old["cells"], new["cells"]
    d = Diff(old=old, new=new)
    for name in sorted(nc):
        if name not in oc:
            d.added.append(name)
        elif nc[name]["edtn"] != oc[name]["edtn"]:
            d.new_edition.append(name)
        elif _version(nc[name]) != _version(oc[name]):
            d.updated.append(name)
    d.cancelled = sorted(set(oc) - set(nc))
    return d

