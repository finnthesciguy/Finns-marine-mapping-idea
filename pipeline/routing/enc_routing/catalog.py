"""Minimal ENC product catalog reader and cell selection.

NOTE: pipeline/catalog (owned by another worker) does the full, change-aware
version of this. This module is deliberately self-contained so the spike has
no cross-dependency; consolidate in Wave 2.
"""
from __future__ import annotations

import xml.etree.ElementTree as ET
from dataclasses import dataclass, field
from pathlib import Path
from typing import Iterable

from shapely.geometry import Polygon, box
from shapely.ops import unary_union

from .config import BANDS


@dataclass
class Cell:
    name: str
    lname: str
    cscale: int
    status: str
    url: str
    size: int
    edtn: int
    updn: int
    uadt: str
    isdt: str
    coverage: object = field(repr=False, default=None)  # shapely geometry (lon/lat)

    @property
    def band(self) -> int:
        """Navigational purpose 1..6 from the cell name (US5... -> 5)."""
        return int(self.name[2])

    @property
    def band_name(self) -> str:
        return BANDS.get(self.name[2], "?")


def _text(el, tag, default=""):
    x = el.find(tag)
    return x.text.strip() if x is not None and x.text else default


def parse_coverage(cell_el) -> object | None:
    """Coverage panels: type E = exterior polygon, type I = interior (hole)."""
    ext, holes = [], []
    cov = cell_el.find("cov")
    if cov is None:
        return None
    for panel in cov.findall("panel"):
        pts = [
            (float(_text(v, "long")), float(_text(v, "lat")))
            for v in panel.findall("vertex")
        ]
        if len(pts) < 3:
            continue
        poly = Polygon(pts).buffer(0)
        (holes if _text(panel, "type") == "I" else ext).append(poly)
    if not ext:
        return None
    g = unary_union(ext)
    if holes:
        g = g.difference(unary_union(holes))
    return g


def parse_catalog(path: Path) -> list[Cell]:
    cells = []
    for _, el in ET.iterparse(str(path), events=("end",)):
        if el.tag != "cell":
            continue
        cells.append(
            Cell(
                name=_text(el, "name"),
                lname=_text(el, "lname"),
                cscale=int(_text(el, "cscale", "0") or 0),
                status=_text(el, "status"),
                url=_text(el, "zipfile_location"),
                size=int(_text(el, "zipfile_size", "0") or 0),
                edtn=int(_text(el, "edtn", "0") or 0),
                updn=int(_text(el, "updn", "0") or 0),
                uadt=_text(el, "uadt"),
                isdt=_text(el, "isdt"),
                coverage=parse_coverage(el),
            )
        )
        el.clear()
    return cells


def select_cells(cells: Iterable[Cell], bbox) -> list[Cell]:
    """Active cells whose catalog coverage intersects bbox (any scale band)."""
    area = box(*bbox)
    out = [
        c
        for c in cells
        if c.status == "Active" and c.coverage is not None and c.coverage.intersects(area)
    ]
    return sorted(out, key=lambda c: (c.band, c.name))
