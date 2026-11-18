"""Metatile renderers: NOAA's MCS export (live) and a deterministic local fake (tests, dry runs)."""
from __future__ import annotations

import hashlib
import io
from typing import Protocol

import numpy as np
from PIL import Image

from .config import RenderConfig
from .grid import ORIGIN, Metatile, tile_size_m
from .http import PoliteClient


class Renderer(Protocol):
    cfg: RenderConfig

    def render(self, mt: Metatile) -> np.ndarray:
        """RGBA uint8 array of the whole request image, gutter included."""


def decode_rgba(png: bytes) -> np.ndarray:
    im = Image.open(io.BytesIO(png))
    im.load()
    return np.asarray(im.convert("RGBA"))


def pixel_hash(a: np.ndarray) -> str:
    """Hash of decoded pixels with fully transparent pixels normalised, so two
    encodings of the same picture hash the same."""
    a = a.copy()
    a[a[..., 3] == 0] = 0
    h = hashlib.sha256()
    h.update(f"{a.shape}".encode())
    h.update(np.ascontiguousarray(a).tobytes())
    return h.hexdigest()


class SuspectBlank(RuntimeError):
    """The service returned a fully transparent image where the coverage policy expects chart."""


class MCSRenderer:
    """NOAA Maritime Chart Service (`MCS/NOAAChartDisplay`) export.

    Seen on 2026-11-12 during a slow period: an HTML error page with status 200
    (handled by the client as a retryable failure) and, right after it, three
    small (25,624-byte) images for metatiles that render as normal chart a few
    minutes later. An all-transparent metatile at z >= `blank_check_zoom` is
    therefore treated as a failed request: retried after a pause, and if it
    stays blank the metatile fails (the run stops and can be resumed) instead
    of silently dropping or deleting tiles. Every metatile we request lies in
    ENC coverage by construction (policy.py), so a genuine all-blank result at
    those zooms is not expected; at z0-5 small areas really are blank.
    """

    blank_check_zoom = 6

    def __init__(self, cfg: RenderConfig, client: PoliteClient, blank_retries: int = 2, blank_pause: float = 30.0,
                 sleep=None):
        import time
        self.cfg, self.client = cfg, client
        self.blank_retries, self.blank_pause = blank_retries, blank_pause
        self.sleep = sleep or time.sleep

    def request(self, mt: Metatile, gutter_px: int | None = None) -> tuple[str, dict, int]:
        g = self.cfg.gutter_px if gutter_px is None else gutter_px
        bbox, size = mt.request_geometry(self.cfg.tile_px, g)
        return self.cfg.service, self.cfg.export_params(bbox, size), size

    def render(self, mt: Metatile, gutter_px: int | None = None) -> np.ndarray:
        url, params, size = self.request(mt, gutter_px)
        for attempt in range(self.blank_retries + 1):
            png = self.client.get_image(url, params, tag=f"{self.cfg.scale}x/{mt.key()}" + (f"/blank-retry{attempt}" if attempt else ""))
            a = decode_rgba(png)
            if a.shape[:2] != (size, size):
                raise ValueError(f"{mt.key()}: expected {size}x{size} px, got {a.shape[1]}x{a.shape[0]}")
            if mt.z < self.blank_check_zoom or a[..., 3].any():
                return a
            if attempt < self.blank_retries:
                self.sleep(self.blank_pause * (attempt + 1))
        raise SuspectBlank(f"{mt.key()}: fully transparent image {self.blank_retries + 1} times inside ENC coverage")


class FakeRenderer:
    """Deterministic stand-in for the export service.

    Pixels are a pure function of the global web-mercator pixel position, so
    metatiles agree at seams and repeated renders are identical. Outside
    `coverage` (lon/lat boxes) pixels are transparent ("no chart"), inside they
    are an opaque water colour, with a grid of dark "linework" and, in
    `features` boxes, a coloured patch whose colour comes from a data version,
    so a test can change the data in one area. `style` stands for the
    renderer's software version: changing it changes every non-blank pixel.
    """

    def __init__(self, cfg: RenderConfig, coverage=((-180.0, -85.0, 180.0, 85.0),), features=None, style: int = 0,
                 fail_after: int | None = None):
        self.cfg = cfg
        self.coverage = list(coverage)
        self.features = dict(features or {})  # name -> (bbox, version)
        self.style = style
        self.calls: list[str] = []
        self.fail_after = fail_after

    def render(self, mt: Metatile, gutter_px: int | None = None) -> np.ndarray:
        if self.fail_after is not None and len(self.calls) >= self.fail_after:
            raise KeyboardInterrupt("fake renderer: simulated kill")
        self.calls.append(mt.key())
        g = self.cfg.gutter_px if gutter_px is None else gutter_px
        (minx, miny, maxx, maxy), size = mt.request_geometry(self.cfg.tile_px, g)
        res = tile_size_m(mt.z) / self.cfg.tile_px
        # Centres of pixels in metres.
        xs = minx + (np.arange(size) + 0.5) * res
        ys = maxy - (np.arange(size) + 0.5) * res
        X, Y = np.meshgrid(xs, ys)
        lon = X / ORIGIN * 180.0
        lat = np.degrees(2 * np.arctan(np.exp(Y / ORIGIN * np.pi)) - np.pi / 2)
        img = np.zeros((size, size, 4), np.uint8)
        cov = np.zeros((size, size), bool)
        for w, s, e, n in self.coverage:
            cov |= (lon >= w) & (lon < e) & (lat >= s) & (lat < n)
        img[cov] = (200 + self.style % 40, 225, 245, 255)
        # Linework every 0.01 degree, one pixel wide at this zoom (global grid, so seams agree).
        gx = np.floor(X / res).astype(np.int64)
        gy = np.floor(Y / res).astype(np.int64)
        step = max(1, int(round(1000 / res)))  # a line every ~1 km on the ground
        line = cov & (((gx % step) == 0) | ((gy % step) == 0))
        img[line] = (40, 40, 60, 255)
        for name, ((w, s, e, n), version) in sorted(self.features.items()):
            m = cov & (lon >= w) & (lon < e) & (lat >= s) & (lat < n)
            h = hashlib.sha256(f"{name}:{version}:{self.style}".encode()).digest()
            img[m] = (h[0], h[1], h[2], 255)
        return img
