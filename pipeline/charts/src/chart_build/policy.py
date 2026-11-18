"""Zoom and coverage policy: which tiles a region package contains.

Rule: a tile at zoom z is in the package when some selected ENC cell whose
deepest useful zoom is >= z covers part of it, inside the region's box at z.
A cell's deepest useful zoom is `ceil(log2(559082264 / cscale)) + overscale`
(capped at max_zoom), the same rule `enc-catalog diff` uses for changed
tiles. So harbour cells (1:5k-1:20k) reach z16, approach cells (~1:40k-1:80k)
z15-16, coastal cells (~1:80k-1:350k) z13-15, general cells (~1:1.2M) z11 and
the overview cell z10: open Gulf water covered only by small-scale cells
stops at z10-11 and is over-zoomed by the map, as in NOAA's packages.
"""
from __future__ import annotations

from shapely.geometry import box
from shapely.ops import unary_union

from enc_catalog.snapshot import Diff, cell_geometry
from enc_catalog.tiles import cell_max_zoom, dilate, merge, tiles_for_geometry

from .config import RegionDef
from .grid import ancestors, metatiles_for


def _bands(region: RegionDef, min_zoom: int, max_zoom: int):
    """Zoom ranges [lo, hi] over which the region's box is constant."""
    cuts = sorted({min_zoom} | {mz for mz, _ in region.zoom_boxes if min_zoom < mz <= max_zoom})
    for i, lo in enumerate(cuts):
        hi = cuts[i + 1] - 1 if i + 1 < len(cuts) else max_zoom
        yield lo, hi, region.bbox_at(lo)


def policy_tiles(snapshot: dict, region: RegionDef, max_zoom: int = 16, overscale: int = 2,
                 min_zoom: int = 0) -> dict[int, set[tuple[int, int]]]:
    rb = box(*region.bbox)
    groups: dict[int, list] = {}
    for name, e in snapshot["cells"].items():
        if not box(*e["bbox"]).intersects(rb):
            continue
        zmax = cell_max_zoom(e["cscale"], max_zoom, overscale)
        groups.setdefault(zmax, []).append(cell_geometry(e))
    acc: dict[int, set] = {z: set() for z in range(min_zoom, max_zoom + 1)}
    for zmax, geoms in sorted(groups.items()):
        g = unary_union(geoms)
        for lo, hi, bb in _bands(region, min_zoom, max_zoom):
            top = min(hi, zmax)
            if top < lo:
                continue
            clip = g.intersection(box(*bb))
            if clip.is_empty:
                continue
            acc = merge(acc, tiles_for_geometry(clip, top, lo))
    return {z: s for z, s in acc.items() if s}


def affected_tiles(diff: Diff, new_policy: dict, old_tiles: dict | None = None, max_zoom: int = 16,
                   overscale: int = 2, dilate_tiles: int = 1) -> dict[int, set[tuple[int, int]]]:
    """Tiles an update must re-render: every tile of every changed cell (old and
    new footprint, down to the cell's own useful zoom, grown by dilate_tiles),
    closed upwards over the ancestors, restricted to what the package holds
    now or will hold (new policy, plus old tiles so removed coverage is redrawn)."""
    t = diff.tiles(max_zoom, overscale, dilate_tiles)
    t = ancestors({z: s for z, s in t.items() if s})
    scope = merge(new_policy, old_tiles or {})
    return {z: s & scope.get(z, set()) for z, s in t.items() if s & scope.get(z, set())}


def count(tiles: dict[int, set], n: int) -> dict:
    per = {}
    for z in sorted(tiles):
        mts = {(x // n, y // n) for x, y in tiles[z]}
        per[z] = {"tiles": len(tiles[z]), "metatiles": len(mts)}
    return {
        "per_zoom": per,
        "tiles": sum(v["tiles"] for v in per.values()),
        "requests": sum(v["metatiles"] for v in per.values()),
    }


__all__ = ["policy_tiles", "affected_tiles", "count", "metatiles_for", "dilate"]
