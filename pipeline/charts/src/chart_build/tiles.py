"""Cutting metatiles into tiles, blank detection and PNG encoding."""
from __future__ import annotations

import io

import numpy as np
from PIL import Image

from .grid import Metatile


def slice_metatile(img: np.ndarray, mt: Metatile, tile_px: int, gutter_px: int) -> dict[tuple[int, int], np.ndarray]:
    """Crop the gutter off a metatile image and cut it into tiles keyed by XYZ (x, y)."""
    side = mt.side
    expect = side * tile_px + 2 * gutter_px
    if img.shape[0] != expect or img.shape[1] != expect:
        raise ValueError(f"metatile {mt.key()} image is {img.shape[1]}x{img.shape[0]}, expected {expect}")
    out = {}
    for dy in range(side):
        for dx in range(side):
            r0 = gutter_px + dy * tile_px
            c0 = gutter_px + dx * tile_px
            out[(mt.x0 + dx, mt.y0 + dy)] = img[r0:r0 + tile_px, c0:c0 + tile_px]
    return out


def is_blank(tile: np.ndarray) -> bool:
    """A tile is blank when every pixel is fully transparent.

    The export draws nothing where no ENC cell has coverage and the request
    asks for a transparent background, so those pixels have alpha 0. Water
    inside coverage is painted (depth-area fill, opaque), as is land, so an
    open-water tile is never blank and is kept. See docs/chart-build.md for the
    measurements behind this rule."""
    return not tile[..., 3].any()


def classify(tile: np.ndarray) -> str:
    """'blank', 'uniform' (one opaque colour, e.g. open water) or 'detail'."""
    a = tile[..., 3]
    if not a.any():
        return "blank"
    flat = tile.reshape(-1, 4)
    if (flat == flat[0]).all():
        return "uniform"
    return "detail"


def encode_png(tile: np.ndarray, mode: str = "lossless-palette") -> bytes:
    """Encode an RGBA tile.

    lossless-palette (default): if the tile has at most 256 distinct RGBA
    colours it is written as an 8-bit palette PNG (with a tRNS chunk when it
    has transparency); the decoded pixels are bit-identical. Otherwise it is
    written as RGBA (or RGB when fully opaque). Fully transparent pixels are
    normalised to (0,0,0,0) first, which does not change the picture.
    rgba: always 32-bit (for measurements).
    Output is deterministic for identical pixels, so byte-level dedup works."""
    t = np.ascontiguousarray(tile, dtype=np.uint8).copy()
    t[t[..., 3] == 0] = 0
    if mode == "lossless-palette":
        flat = t.reshape(-1, 4)
        packed = flat.view(np.uint32).reshape(-1)
        colours, inverse = np.unique(packed, return_inverse=True)
        if len(colours) <= 256:
            pal = colours.view(np.uint8).reshape(-1, 4)
            im = Image.fromarray(inverse.astype(np.uint8).reshape(t.shape[:2]), "P")
            im.putpalette(pal[:, :3].reshape(-1).tolist(), rawmode="RGB")
            alpha = pal[:, 3]
            buf = io.BytesIO()
            if (alpha == 255).all():
                im.save(buf, "PNG", optimize=True)
            else:
                im.save(buf, "PNG", optimize=True, transparency=bytes(alpha.tolist()))
            return buf.getvalue()
    elif mode != "rgba":
        raise ValueError(f"unknown png mode {mode}")
    buf = io.BytesIO()
    if (t[..., 3] == 255).all():
        Image.fromarray(t[..., :3], "RGB").save(buf, "PNG", optimize=True)
    else:
        Image.fromarray(t, "RGBA").save(buf, "PNG", optimize=True)
    return buf.getvalue()


def quantize_png(tile: np.ndarray, colours: int = 256) -> tuple[bytes, float, int]:
    """Lossy palette quantisation (measurement only): PNG bytes, fraction of
    pixels changed and the largest channel error."""
    im = Image.fromarray(np.ascontiguousarray(tile), "RGBA")
    q = im.quantize(colors=colours, method=Image.Quantize.FASTOCTREE, dither=Image.Dither.NONE)
    buf = io.BytesIO()
    q.save(buf, "PNG", optimize=True)
    back = np.asarray(q.convert("RGBA")).astype(int)
    a = tile.astype(int).copy()
    a[a[..., 3] == 0] = 0
    back[back[..., 3] == 0] = 0
    d = np.abs(back - a).max(axis=2)
    return buf.getvalue(), float((d > 0).mean()), int(d.max())
