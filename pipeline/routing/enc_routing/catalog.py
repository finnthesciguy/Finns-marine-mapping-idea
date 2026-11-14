"""ENC catalog access through pipeline/catalog (`enc_catalog`).

The routing builder no longer parses the catalog itself: `enc_catalog`
reads ENCProdCat.xml, selects the active Gulf cells against its area of
interest, writes snapshots and diffs them. This module only adds what the
router needs on top: the coastal-or-better band filter and a plain bbox
selection for fixed-box regions (the pilot) and tests.
"""
from __future__ import annotations

from pathlib import Path
from typing import Iterable

from enc_catalog import Cell, load_aoi, load_regions, parse_catalog as _parse
from enc_catalog import select_cells as _select
from shapely.geometry import box

from .config import MIN_BAND

__all__ = ["Cell", "parse_catalog", "select_cells", "gulf_selection", "cell_coverage"]


def parse_catalog(path: str | Path):
    """List of enc_catalog.Cell (all statuses)."""
    return _parse(str(path)).cells


def cell_coverage(c: Cell):
    return c.coverage()


def select_cells(cells: Iterable[Cell], bbox, min_band: int = 1) -> list[Cell]:
    """Active cells whose catalog coverage shares area with bbox (lon/lat box or
    polygon), sorted by (band, name)."""
    area = box(*bbox) if isinstance(bbox, (tuple, list)) else bbox
    sel = _select(list(cells), aoi=area, regions=[])
    out = [c for c in sel.cells if c.band >= min_band]
    return sorted(out, key=lambda c: (c.band, c.name))


def gulf_selection(catalog_path: str | Path, min_band: int = MIN_BAND):
    """(catalog, selection, cells): the Gulf cells of pipeline/catalog's
    area of interest, keeping bands >= min_band."""
    cat = _parse(str(catalog_path))
    sel = _select(cat.cells, aoi=load_aoi(), regions=load_regions())
    cells = sorted((c for c in sel.cells if c.band >= min_band), key=lambda c: (c.band, c.name))
    return cat, sel, cells
