"""Web-mercator (XYZ, Google/OSM numbering, y down) tile coverage of geometries."""
from __future__ import annotations

import math

from shapely.geometry import box
from shapely.prepared import prep

# Scale denominator of zoom 0 for 256 px tiles at the OGC 0.28 mm pixel
# (the "GoogleMapsCompatible" well-known scale set).
ZOOM0_SCALE = 559082264.0287178
MAX_LAT = 85.0511287798066


def tile_bounds(z: int, x: int, y: int) -> tuple[float, float, float, float]:
    """(west, south, east, north) in degrees."""
    n = 1 << z
    west = x / n * 360.0 - 180.0
    east = (x + 1) / n * 360.0 - 180.0
    north = math.degrees(math.atan(math.sinh(math.pi * (1 - 2 * y / n))))
    south = math.degrees(math.atan(math.sinh(math.pi * (1 - 2 * (y + 1) / n))))
    return west, south, east, north


def lonlat_to_tile(lon: float, lat: float, z: int) -> tuple[int, int]:
    n = 1 << z
    lat = max(-MAX_LAT, min(MAX_LAT, lat))
    x = int((lon + 180.0) / 360.0 * n)
    y = int((1 - math.asinh(math.tan(math.radians(lat))) / math.pi) / 2 * n)
    return min(max(x, 0), n - 1), min(max(y, 0), n - 1)


def tms_row(z: int, y: int) -> int:
    """MBTiles stores TMS rows (y up)."""
    return (1 << z) - 1 - y


def native_zoom(cscale: int) -> int:
    """Smallest zoom whose display scale is at least as large as the compilation scale."""
    if cscale <= 0:
        return 0
    return max(0, math.ceil(math.log2(ZOOM0_SCALE / cscale)))


def cell_max_zoom(cscale: int, max_zoom: int, overscale: int = 2) -> int:
    """Deepest zoom at which a cell of this scale can still be what is drawn.

    A chart renderer shows a cell down to roughly its compilation scale and,
    where nothing larger-scale exists, a couple of levels overscaled.
    """
    return min(max_zoom, native_zoom(cscale) + overscale)


def tiles_for_geometry(geom, max_zoom: int, min_zoom: int = 0) -> dict[int, set[tuple[int, int]]]:
    """All tiles at zooms min_zoom..max_zoom whose footprint intersects geom.

    Quadtree descent from zoom 0, so only intersecting tiles are visited; a
    tile fully inside the geometry has all its descendants added by range.
    """
    out: dict[int, set[tuple[int, int]]] = {z: set() for z in range(min_zoom, max_zoom + 1)}
    if geom is None or geom.is_empty:
        return out
    pg = prep(geom)
    areal = geom.area > 0
    stack = [(0, 0, 0)]
    while stack:
        z, x, y = stack.pop()
        tb = box(*tile_bounds(z, x, y))
        # Interiors must meet: a tile that only shares an edge with the
        # geometry (cells and tiles both sit on round-number lines) is out.
        if not pg.intersects(tb) or (areal and pg.touches(tb)):
            continue
        if pg.contains(tb):
            _fill(out, z, x, y, min_zoom, max_zoom)
            continue
        if z >= min_zoom:
            out[z].add((x, y))
        if z < max_zoom:
            cz, cx, cy = z + 1, 2 * x, 2 * y
            stack.extend([(cz, cx, cy), (cz, cx + 1, cy), (cz, cx, cy + 1), (cz, cx + 1, cy + 1)])
    return out


def _fill(out, z, x, y, min_zoom, max_zoom):
    for zz in range(max(z, min_zoom), max_zoom + 1):
        f = 1 << (zz - z)
        s = out[zz]
        for xx in range(x * f, (x + 1) * f):
            for yy in range(y * f, (y + 1) * f):
                s.add((xx, yy))


def dilate(tiles: dict[int, set[tuple[int, int]]], k: int = 1) -> dict[int, set[tuple[int, int]]]:
    """Grow each zoom's tile set by k tiles in every direction (labels and
    symbols drawn near a cell edge spill into the neighbouring tile)."""
    if k <= 0:
        return {z: set(s) for z, s in tiles.items()}
    out = {}
    for z, s in tiles.items():
        n = 1 << z
        g = set()
        for x, y in s:
            for dx in range(-k, k + 1):
                for dy in range(-k, k + 1):
                    xx, yy = x + dx, y + dy
                    if 0 <= xx < n and 0 <= yy < n:
                        g.add((xx, yy))
        out[z] = g
    return out


def merge(a: dict[int, set], b: dict[int, set]) -> dict[int, set]:
    out = {z: set(s) for z, s in a.items()}
    for z, s in b.items():
        out.setdefault(z, set()).update(s)
    return out
