from shapely.geometry import Point, Polygon, box

from enc_catalog.tiles import (
    cell_max_zoom, dilate, lonlat_to_tile, native_zoom, tile_bounds, tiles_for_geometry, tms_row,
)


def brute(geom, z):
    w, s, e, n = geom.bounds
    x0, y0 = lonlat_to_tile(w, n, z)
    x1, y1 = lonlat_to_tile(e, s, z)
    tiles = set()
    for x in range(max(x0 - 1, 0), x1 + 2):
        for y in range(max(y0 - 1, 0), y1 + 2):
            tb = box(*tile_bounds(z, x, y))
            if tb.intersection(geom).area > 0:
                tiles.add((x, y))
    return tiles


def test_known_tile():
    # Southwest Pass light area; also checked against the ncds_13 package (TMS row 9574).
    assert lonlat_to_tile(-89.31, 29.05, 14) == (4127, 6809)
    assert tms_row(14, 6809) == 9574
    w, s, e, n = tile_bounds(14, 4127, 6809)
    assert w <= -89.31 <= e and s <= 29.05 <= n


def test_roundtrip_corners():
    for z, x, y in [(0, 0, 0), (5, 7, 13), (16, 16514, 27239)]:
        w, s, e, n = tile_bounds(z, x, y)
        assert lonlat_to_tile(w + 1e-9, n - 1e-9, z) == (x, y)


def test_quadtree_matches_brute_force():
    tri = Polygon([(-89.6, 28.85), (-89.1, 28.9), (-89.4, 29.3)])
    t = tiles_for_geometry(tri, 14)
    for z in range(15):
        assert t[z] == brute(tri, z), z


def test_full_containment_fill_matches_brute_force():
    big = box(-90.0, 28.0, -88.5, 29.5)
    t = tiles_for_geometry(big, 11, min_zoom=6)
    assert set(t) == set(range(6, 12))
    for z in range(6, 12):
        assert t[z] == brute(big, z), z


def test_point_and_empty():
    t = tiles_for_geometry(Point(-89.43, 28.90).buffer(1e-6), 16)
    assert all(len(s) >= 1 for s in t.values())
    assert lonlat_to_tile(-89.43, 28.90, 16) in t[16]
    assert all(not s for s in tiles_for_geometry(None, 5).values())


def test_scale_to_zoom():
    assert native_zoom(1_500_000) == 9
    assert native_zoom(45_000) == 14
    assert native_zoom(10_000) == 16
    assert cell_max_zoom(1_500_000, 16) == 11
    assert cell_max_zoom(10_000, 16) == 16
    assert cell_max_zoom(45_000, 16, overscale=0) == 14


def test_dilate():
    d = dilate({3: {(0, 0), (4, 4)}}, 1)
    assert (0, 0) in d[3] and (1, 1) in d[3] and (5, 5) in d[3]
    assert all(0 <= x < 8 and 0 <= y < 8 for x, y in d[3])
    assert len(d[3]) == 4 + 9
