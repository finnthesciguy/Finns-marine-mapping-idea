import io

import numpy as np
from PIL import Image

from chart_build.calibrate import Block
from chart_build.grid import Metatile
from chart_build.renderer import FakeRenderer, decode_rgba, pixel_hash
from chart_build.tiles import classify, encode_png, is_blank, slice_metatile

COV = [(-89.5, 28.85, -89.3, 29.0)]


def test_gutter_crop_is_pixel_aligned(cfg):
    """Slicing with any gutter gives the same tiles (the fake is position-pure)."""
    m = Metatile.of(15, 8263, 13627, cfg.metatile)
    r = FakeRenderer(cfg, COV)
    a = slice_metatile(r.render(m, gutter_px=0), m, cfg.tile_px, 0)
    b = slice_metatile(r.render(m, gutter_px=24), m, cfg.tile_px, 24)
    assert a.keys() == b.keys() == set(m.tiles())
    for k in a:
        assert np.array_equal(a[k], b[k])


def test_adjacent_metatiles_agree_with_a_block_across_the_seam(cfg):
    r = FakeRenderer(cfg, COV)
    n, tp = cfg.metatile, cfg.tile_px
    left, right = Metatile(15, 2065, 3406, n), Metatile(15, 2066, 3406, n)
    ref = Block(15, 0, 0, n, ox=2066 * n - n // 2, oy=3406 * n)
    g = cfg.gutter_px
    crop = lambda im: im[g:-g, g:-g]  # noqa: E731
    stitched = np.concatenate([crop(r.render(left))[:, -n // 2 * tp:], crop(r.render(right))[:, :n // 2 * tp]], axis=1)
    assert np.array_equal(stitched, crop(r.render(ref)))


def test_slice_rejects_wrong_size(cfg):
    m = Metatile.of(15, 8263, 13627, cfg.metatile)
    try:
        slice_metatile(np.zeros((10, 10, 4), np.uint8), m, cfg.tile_px, cfg.gutter_px)
    except ValueError:
        return
    raise AssertionError("expected ValueError")


def test_blank_rules():
    t = np.zeros((256, 256, 4), np.uint8)
    assert is_blank(t) and classify(t) == "blank"
    # Coloured but fully transparent pixels are still blank.
    t[..., :3] = 200
    assert is_blank(t)
    water = np.zeros((256, 256, 4), np.uint8)
    water[:] = (201, 237, 252, 255)
    assert not is_blank(water) and classify(water) == "uniform"
    edge = np.zeros((256, 256, 4), np.uint8)
    edge[0, 0] = (0, 0, 0, 10)
    assert not is_blank(edge) and classify(edge) == "detail"


def _rt(png):
    return np.asarray(Image.open(io.BytesIO(png)).convert("RGBA"))


def test_lossless_palette_roundtrip_with_transparency():
    rng = np.random.default_rng(1)
    pal = rng.integers(0, 256, (40, 4), dtype=np.uint8)
    pal[0] = (0, 0, 0, 0)
    pal[1, 3] = 128
    idx = rng.integers(0, 40, (256, 256))
    t = pal[idx]
    png = encode_png(t)
    im = Image.open(io.BytesIO(png))
    assert im.mode == "P"
    back = _rt(png).copy()
    want = t.copy()
    want[want[..., 3] == 0] = 0
    back[back[..., 3] == 0] = 0
    assert np.array_equal(back, want)
    assert encode_png(t) == png  # deterministic bytes -> dedup works


def test_many_colours_fall_back_to_rgba_losslessly():
    rng = np.random.default_rng(2)
    t = rng.integers(0, 256, (256, 256, 4), dtype=np.uint8)
    t[..., 3] = 255
    png = encode_png(t)
    assert Image.open(io.BytesIO(png)).mode == "RGB"
    assert np.array_equal(_rt(png), t)
    t[0, 0, 3] = 7
    png = encode_png(t)
    assert Image.open(io.BytesIO(png)).mode == "RGBA"
    assert np.array_equal(_rt(png), t)


def test_pixel_hash_ignores_colour_of_transparent_pixels():
    a = np.zeros((4, 4, 4), np.uint8)
    b = a.copy()
    b[..., 0] = 99
    assert pixel_hash(a) == pixel_hash(b)
    b[0, 0, 3] = 1
    assert pixel_hash(a) != pixel_hash(b)


def test_decode_rgba():
    t = np.zeros((8, 8, 4), np.uint8)
    t[..., 3] = 255
    assert decode_rgba(encode_png(t)).shape == (8, 8, 4)
