import math

import pytest

from chart_build.config import RenderConfig
from chart_build.grid import (ORIGIN, Metatile, ancestors, lonlat_to_tile, metatiles_for, tile_bounds_3857,
                              tile_bounds_lonlat, tile_size_m, tms_row, xyz_row)


def test_tile_bounds_3857_world_and_corners():
    assert tile_bounds_3857(0, 0, 0) == pytest.approx((-ORIGIN, -ORIGIN, ORIGIN, ORIGIN))
    minx, miny, maxx, maxy = tile_bounds_3857(1, 1, 0)
    assert (minx, miny, maxx, maxy) == pytest.approx((0, 0, ORIGIN, ORIGIN))


def test_3857_and_lonlat_bounds_agree():
    z, x, y = 16, 16514, 27239
    w, s, e, n = tile_bounds_lonlat(z, x, y)
    minx, miny, maxx, maxy = tile_bounds_3857(z, x, y)
    assert minx / ORIGIN * 180 == pytest.approx(w)
    lat = math.degrees(2 * math.atan(math.exp(maxy / ORIGIN * math.pi)) - math.pi / 2)
    assert lat == pytest.approx(n)
    assert lonlat_to_tile((w + e) / 2, (s + n) / 2, z) == (x, y)


def test_tms_flip_roundtrip():
    assert tms_row(16, 27239) == 38296  # the ChartKit sample-test tile
    assert xyz_row(16, 38296) == 27239


def test_metatile_membership_and_low_zoom_clip():
    m = Metatile.of(16, 16514, 27239, 8)
    assert (m.mx, m.my, m.x0, m.y0, m.side) == (2064, 3404, 16512, 27232, 8)
    assert (16514, 27239) in set(m.tiles())
    world = Metatile.of(1, 1, 1, 8)
    assert world.side == 2 and sorted(world.tiles()) == [(0, 0), (0, 1), (1, 0), (1, 1)]


@pytest.mark.parametrize("scale", [1, 2])
def test_request_geometry_has_tile_grid_resolution(scale):
    cfg = RenderConfig.load(scale=scale)
    m = Metatile.of(14, 4127, 6809, cfg.metatile)
    bbox, size = m.request_geometry(cfg.tile_px, cfg.gutter_px)
    res = tile_size_m(14) / cfg.tile_px
    assert (bbox[2] - bbox[0]) / size == pytest.approx(res, rel=1e-12)
    assert (bbox[3] - bbox[1]) / size == pytest.approx(res, rel=1e-12)
    assert size == cfg.metatile * cfg.tile_px + 2 * cfg.gutter_px
    inner = m.bounds_3857()
    assert bbox[0] == pytest.approx(inner[0] - cfg.gutter_px * res)
    # Retina covers half the tiles per side at twice the pixels per tile: same request width.
    assert cfg.metatile * cfg.tile_px == 2048


def test_export_params_are_pinned_and_dpi_scales():
    for scale, dpi in ((1, 96), (2, 192)):
        cfg = RenderConfig.load(scale=scale)
        p = cfg.export_params((0, 0, 1, 1), 100)
        assert p["dpi"] == dpi and p["bboxSR"] == 3857 and p["imageSR"] == 3857
        assert p["transparent"] == "true" and p["f"] == "image"
        assert "ECDISParameters" in p["display_params"] and p["layers"].startswith("show:")
    assert RenderConfig.load(scale=1).config_hash != RenderConfig.load(scale=2).config_hash


def test_ancestors_closure():
    t = ancestors({16: {(16514, 27239)}}, min_zoom=12)
    assert t[15] == {(8257, 13619)}
    assert t[12] == {(16514 >> 4, 27239 >> 4)}
    assert 11 not in t


def test_metatiles_for_groups_tiles():
    g = metatiles_for({10: {(0, 0), (7, 7), (8, 0)}}, 8)
    assert len(g) == 2
    assert g[Metatile(10, 0, 0, 8)] == {(0, 0), (7, 7)}
