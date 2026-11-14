"""Area of interest and chart regions, and cell selection against them."""
from __future__ import annotations

import json
from dataclasses import dataclass
from importlib import resources
from pathlib import Path

from shapely.geometry import Polygon, box, shape
from shapely.prepared import prep

from .catalog import Cell


@dataclass
class Region:
    key: str
    label: str
    bbox: tuple[float, float, float, float]

    @property
    def geometry(self):
        return box(*self.bbox)


def _data(name: str) -> dict:
    return json.loads(resources.files("enc_catalog").joinpath("data", name).read_text())


def load_aoi(path: str | Path | None = None):
    """Load the AOI polygon. Default: the built-in Gulf polygon.

    A custom file may be the built-in format ({"polygon": [[lon, lat], ...]}),
    a GeoJSON geometry, Feature, or FeatureCollection (first feature), or a
    bbox {"bbox": [w, s, e, n]}.
    """
    d = _data("gulf_aoi.json") if path is None else json.loads(Path(path).read_text())
    if "polygon" in d:
        return Polygon(d["polygon"])
    if "bbox" in d and "type" not in d:
        return box(*d["bbox"])
    if d.get("type") == "FeatureCollection":
        d = d["features"][0]
    if d.get("type") == "Feature":
        d = d["geometry"]
    return shape(d)


def load_regions(path: str | Path | None = None) -> list[Region]:
    d = _data("regions.json") if path is None else json.loads(Path(path).read_text())
    return [Region(k, v.get("label", k), tuple(v["bbox"])) for k, v in d["regions"].items()]


@dataclass
class Selection:
    cells: list[Cell]
    regions_of: dict[str, list[str]]  # cell name -> region keys (may be empty)

    def by_band(self) -> dict[int, list[Cell]]:
        out: dict[int, list[Cell]] = {}
        for c in self.cells:
            out.setdefault(c.band, []).append(c)
        return dict(sorted(out.items()))

    def by_region(self) -> dict[str, list[Cell]]:
        out: dict[str, list[Cell]] = {}
        for c in self.cells:
            for r in self.regions_of[c.name] or ["(outside region boxes)"]:
                out.setdefault(r, []).append(c)
        return dict(sorted(out.items()))

    def table(self) -> dict[str, dict[int, int]]:
        """region -> band -> count."""
        return {r: _count_bands(cs) for r, cs in self.by_region().items()}


def _count_bands(cells: list[Cell]) -> dict[int, int]:
    out: dict[int, int] = {}
    for c in cells:
        out[c.band] = out.get(c.band, 0) + 1
    return dict(sorted(out.items()))


def select_cells(cells, aoi=None, regions: list[Region] | None = None) -> Selection:
    """Active cells whose coverage geometry intersects the AOI.

    Uses the coverage panels, not the state tags: the FL tag also covers the
    Atlantic coast. Cancelled cells carry no coverage in the catalog, so they
    cannot be located; cancellations are detected by the snapshot diff, which
    still has the cell's last known coverage.
    """
    aoi = load_aoi() if aoi is None else aoi
    regions = load_regions() if regions is None else regions
    paoi = prep(aoi)
    rgeoms = [(r.key, prep(r.geometry)) for r in regions]
    chosen, regions_of = [], {}
    for c in cells:
        if not c.active:
            continue
        geom = c.coverage()
        # Require a shared area: NOAA's gridded cells sit on round-degree
        # lines, and a cell that only touches the AOI edge is not in it.
        if geom is None or not paoi.intersects(geom) or geom.touches(aoi):
            continue
        # Region membership is decided on the part of the cell inside the AOI,
        # so a big overview cell is not assigned to every box it brushes.
        inside = geom.intersection(aoi)
        chosen.append(c)
        regions_of[c.name] = [k for k, g in rgeoms if g.intersects(inside) and not _touch_only(inside, k, regions)]
    chosen.sort(key=lambda c: c.name)
    return Selection(chosen, regions_of)


def _touch_only(geom, key, regions) -> bool:
    """True if geom only shares a boundary line with the region box."""
    r = next(r for r in regions if r.key == key)
    return geom.intersection(r.geometry).area == 0
