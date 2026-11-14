"""Routing regions: one routing pack per chart region, with overlap.

The five Gulf chart regions (ncds_10 .. ncds_14) are NOAA's tile-package
boxes, read from pipeline/catalog (`enc_catalog.load_regions`). A routing
pack carries the same id as its chart region, so it installs alongside the
chart package. The on-device engine cannot route across packs, so each
routing region is its chart box grown by OVERLAP_NM nautical miles on every
side, intersected with the Gulf area of interest (`enc_catalog.load_aoi`).
Every passage that starts in one chart region and ends less than OVERLAP_NM
past its edge can therefore be planned in that region's pack. The cost is
that the overlap strips are stored (and downloaded) twice; see
docs/routing-build.md for the numbers.

A routing region's pack is the union of the fixed lon/lat tiles (tiles.py)
that meet the region area and hold some coastal-or-better ENC coverage.
Tiles are region-independent, so the overlap strips of two packs are
identical and are built only once.
"""
from __future__ import annotations

import math

from shapely.geometry import box

from .config import REGIONS, BuildParams, Region

OVERLAP_NM = 30.0
GULF_REGION_IDS = ("ncds_10", "ncds_11", "ncds_12", "ncds_13", "ncds_14")


def grow_box(bbox, nm: float, lat_ref: float | None = None):
    """Grow a lon/lat box by nm nautical miles on every side (longitude
    growth taken at the latitude of the box edge nearest the equator,
    so it is at least nm everywhere)."""
    w, s, e, n = bbox
    dlat = nm / 60.0
    lat = lat_ref if lat_ref is not None else max(abs(s), abs(n))
    lat = min(abs(lat), 60.0)
    dlon = dlat / math.cos(math.radians(lat))
    return (w - dlon, s - dlat, e + dlon, n + dlat)


def gulf_region(rid: str, overlap_nm: float = OVERLAP_NM, params: BuildParams | None = None,
                aoi=None, chart_regions=None) -> Region:
    from enc_catalog import load_aoi, load_regions

    regs = {r.key: r for r in (chart_regions or load_regions())}
    if rid not in regs:
        raise KeyError(f"unknown chart region {rid}; known: {sorted(regs)}")
    aoi = load_aoi() if aoi is None else aoi
    cb = tuple(regs[rid].bbox)
    # longitude growth at the AOI's northern latitude (31 N): the widest degree count
    ext = grow_box(cb, overlap_nm, lat_ref=31.2)
    area = box(*ext).intersection(aoi)
    return Region(rid, tuple(round(v, 6) for v in area.bounds), params or BuildParams(), area=area,
                  chart_bbox=cb)


def get_region(rid: str, overlap_nm: float = OVERLAP_NM) -> Region:
    if rid in REGIONS:
        return Region(rid, REGIONS[rid], chart_bbox=REGIONS[rid])
    return gulf_region(rid, overlap_nm)


def all_region_ids() -> list[str]:
    return list(GULF_REGION_IDS) + sorted(REGIONS)
