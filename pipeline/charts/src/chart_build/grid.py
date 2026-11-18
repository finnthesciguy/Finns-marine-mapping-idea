"""Web-mercator tile and metatile grid (EPSG:3857, XYZ numbering with y down).

A metatile is an aligned block of N x N tiles at one zoom: metatile (mx, my)
holds tiles x in [mx*N, mx*N+N) and y in [my*N, my*N+N). At zooms where the
world is narrower than N tiles the single metatile is the whole world.
The block is always the same for a given tile, so a tile is always cut from
the same render (label placement depends on the image extent).
"""
from __future__ import annotations

import math
from dataclasses import dataclass

# Half the side of the EPSG:3857 square, in metres.
ORIGIN = 20037508.342789244
WORLD = 2 * ORIGIN


def tile_size_m(z: int) -> float:
    return WORLD / (1 << z)


def tile_bounds_3857(z: int, x: int, y: int) -> tuple[float, float, float, float]:
    """(minx, miny, maxx, maxy) in metres."""
    s = tile_size_m(z)
    minx = -ORIGIN + x * s
    maxy = ORIGIN - y * s
    return minx, maxy - s, minx + s, maxy


def tile_bounds_lonlat(z: int, x: int, y: int) -> tuple[float, float, float, float]:
    """(west, south, east, north) in degrees."""
    n = 1 << z
    west = x / n * 360.0 - 180.0
    east = (x + 1) / n * 360.0 - 180.0
    north = math.degrees(math.atan(math.sinh(math.pi * (1 - 2 * y / n))))
    south = math.degrees(math.atan(math.sinh(math.pi * (1 - 2 * (y + 1) / n))))
    return west, south, east, north


def lonlat_to_tile(lon: float, lat: float, z: int) -> tuple[int, int]:
    n = 1 << z
    lat = max(-85.0511287798066, min(85.0511287798066, lat))
    x = int((lon + 180.0) / 360.0 * n)
    y = int((1 - math.asinh(math.tan(math.radians(lat))) / math.pi) / 2 * n)
    return min(max(x, 0), n - 1), min(max(y, 0), n - 1)


def tiles_in_bbox(z: int, bbox: tuple[float, float, float, float]) -> tuple[int, int, int, int]:
    """Inclusive XYZ range (x0, y0, x1, y1) of tiles touching a lon/lat box."""
    w, s, e, n = bbox
    x0, y0 = lonlat_to_tile(w, n, z)
    x1, y1 = lonlat_to_tile(e, s, z)
    return x0, y0, x1, y1


def tms_row(z: int, y: int) -> int:
    return (1 << z) - 1 - y


def xyz_row(z: int, tms: int) -> int:
    return (1 << z) - 1 - tms


def parent(z: int, x: int, y: int) -> tuple[int, int, int]:
    return z - 1, x >> 1, y >> 1


def ancestors(tiles: dict[int, set[tuple[int, int]]], min_zoom: int = 0) -> dict[int, set[tuple[int, int]]]:
    """Close a per-zoom tile set upwards: every tile's parent, grandparent, ...
    down to min_zoom is added. A change visible at z16 can change the z15 tile
    that contains it, so an incremental update must re-render the ancestors."""
    out = {z: set(s) for z, s in tiles.items()}
    zs = sorted(out)
    if not zs:
        return out
    for z in range(max(zs), min_zoom, -1):
        for x, y in out.get(z, ()):
            out.setdefault(z - 1, set()).add((x >> 1, y >> 1))
    return out


@dataclass(frozen=True, order=True)
class Metatile:
    z: int
    mx: int
    my: int
    n: int  # tiles per side for this grid (before clipping to the world)

    @staticmethod
    def of(z: int, x: int, y: int, n: int) -> "Metatile":
        return Metatile(z, x // n, y // n, n)

    @property
    def side(self) -> int:
        """Tiles per side actually covered (smaller than n at low zooms)."""
        return min(self.n, 1 << self.z)

    @property
    def x0(self) -> int:
        return self.mx * self.n

    @property
    def y0(self) -> int:
        return self.my * self.n

    def tiles(self):
        for dy in range(self.side):
            for dx in range(self.side):
                yield self.x0 + dx, self.y0 + dy

    def bounds_3857(self) -> tuple[float, float, float, float]:
        s = tile_size_m(self.z)
        minx = -ORIGIN + self.x0 * s
        maxy = ORIGIN - self.y0 * s
        return minx, maxy - self.side * s, minx + self.side * s, maxy

    def request_geometry(self, tile_px: int, gutter_px: int) -> tuple[tuple[float, float, float, float], int]:
        """Export bbox (metres, grown by the gutter) and square image size in px.

        The bbox and the pixel size have exactly the tile grid's resolution, so
        the server never has to stretch the image and pixel (i, j) of the crop
        lands on the web-mercator pixel grid."""
        res = tile_size_m(self.z) / tile_px
        minx, miny, maxx, maxy = self.bounds_3857()
        g = gutter_px * res
        size = self.side * tile_px + 2 * gutter_px
        return (minx - g, miny - g, maxx + g, maxy + g), size

    def key(self) -> str:
        return f"{self.z}/{self.mx}/{self.my}"


def metatiles_for(tiles: dict[int, set[tuple[int, int]]], n: int) -> dict[Metatile, set[tuple[int, int]]]:
    """Group a per-zoom tile set by metatile; values are the wanted tiles in each."""
    out: dict[Metatile, set[tuple[int, int]]] = {}
    for z, s in tiles.items():
        for x, y in s:
            out.setdefault(Metatile.of(z, x, y, n), set()).add((x, y))
    return out
