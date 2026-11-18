"""Measurements that justify the render settings: determinism, pinned display
parameters versus the service defaults, exact extent, and seam behaviour
against the gutter size. Each costs a known, small number of requests."""
from __future__ import annotations

import json
from dataclasses import dataclass

import numpy as np
from PIL import Image

from .config import RenderConfig
from .grid import Metatile, lonlat_to_tile
from .renderer import MCSRenderer, decode_rgba, pixel_hash


@dataclass(frozen=True, order=True)
class Block(Metatile):
    """A tile-aligned block that is not on the metatile grid (seam reference)."""
    ox: int = 0
    oy: int = 0

    @property
    def x0(self) -> int:
        return self.ox

    @property
    def y0(self) -> int:
        return self.oy

    def key(self) -> str:
        return f"{self.z}/block@{self.ox},{self.oy}"


def _norm(a):
    a = a.astype(np.int16).copy()
    a[a[..., 3] == 0] = 0
    return a


def determinism(r: MCSRenderer, metatiles: list[Metatile]) -> list[dict]:
    """Same request twice: raw PNG bytes and decoded pixels identical?"""
    out = []
    for mt in metatiles:
        url, params, _ = r.request(mt)
        b1 = r.client.get_image(url, params, tag=f"det1/{mt.key()}")
        b2 = r.client.get_image(url, params, tag=f"det2/{mt.key()}")
        p1, p2 = decode_rgba(b1), decode_rgba(b2)
        out.append({"metatile": mt.key(), "bytes_identical": b1 == b2, "pixels_identical": pixel_hash(p1) == pixel_hash(p2),
                    "bytes": len(b1), "nonblank": bool(p1[..., 3].any())})
    return out


def pinned_vs_default(r: MCSRenderer, mt: Metatile) -> dict:
    """Pinned display_params/layers versus no display_params/layers at all."""
    url, params, _ = r.request(mt)
    pinned = decode_rgba(r.client.get_image(url, params, tag=f"pinned/{mt.key()}"))
    bare = {k: v for k, v in params.items() if k not in ("display_params", "layers")}
    default = decode_rgba(r.client.get_image(url, bare, tag=f"default/{mt.key()}"))
    d = np.abs(_norm(pinned) - _norm(default)).max(axis=2) > 0
    return {"metatile": mt.key(), "pixels_identical": not d.any(), "diff_fraction": float(d.mean())}


def extent_check(r: MCSRenderer, mt: Metatile) -> dict:
    """Ask for f=json: the server reports the extent it actually drew."""
    url, params, size = r.request(mt)
    p = dict(params, f="json")
    r.client._reserve()
    r.client.limiter.acquire()
    resp = r.client.session.get(url, params=p, timeout=60)
    r.client._log({"tag": f"extent/{mt.key()}", "status": resp.status_code, "bytes": len(resp.content)})
    if resp.content[:8] == b"\x89PNG\r\n\x1a\n":
        # Seen 2026-11-12: the MaritimeChartService export ignores f=json and returns the PNG
        # (labelled application/json), so the drawn extent cannot be read back.
        return {"metatile": mt.key(), "status": resp.status_code, "reply": "PNG (f=json not supported)"}
    j = resp.json()
    if "extent" not in j:
        return {"metatile": mt.key(), "status": resp.status_code, "reply": json.dumps(j)[:400]}
    want = [float(v) for v in params["bbox"].split(",")]
    got = [j["extent"][k] for k in ("xmin", "ymin", "xmax", "ymax")]
    return {"metatile": mt.key(), "requested": want, "returned": got, "width": j.get("width"), "height": j.get("height"),
            "scale": j.get("scale"), "max_abs_diff_m": max(abs(a - b) for a, b in zip(want, got))}


def seam_test(r: MCSRenderer, z: int, lon: float, lat: float, gutters=(0, 64, 128, 256), vertical: bool = False,
              save: str | None = None) -> dict:
    """Render the two grid metatiles either side of the seam nearest (lon, lat)
    and a reference block centred on that seam (no seam there). Report the
    share of differing pixels between the stitched pair and the reference, by
    distance from the seam. Clipping or missing symbols at the seam shows up
    as a peak in the first bands; label-placement noise is flat."""
    cfg = r.cfg
    n, tp = cfg.metatile, cfg.tile_px
    x, y = lonlat_to_tile(lon, lat, z)
    a = Metatile.of(z, x, y, n)
    if not vertical:
        sx = (a.mx + 1) * n if (x % n) >= n // 2 else a.mx * n  # seam column (tile index)
        left, right = Metatile(z, sx // n - 1, a.my, n), Metatile(z, sx // n, a.my, n)
        ref = Block(z, 0, 0, n, ox=sx - n // 2, oy=a.my * n)
    else:
        sy = (a.my + 1) * n if (y % n) >= n // 2 else a.my * n
        left, right = Metatile(z, a.mx, sy // n - 1, n), Metatile(z, a.mx, sy // n, n)
        ref = Block(z, 0, 0, n, ox=a.mx * n, oy=sy - n // 2)
    bands = [(0, 8), (8, 32), (32, 128), (128, 512)]
    res = {"z": z, "seam": "vertical-seam(rows)" if vertical else "horizontal-seam(columns)", "left": left.key(),
           "right": right.key(), "ref": ref.key(), "gutters": {}}
    images = {}
    for g in gutters:
        ia, ib, ir = (r.render(m, gutter_px=g) for m in (left, right, ref))
        crop = lambda im: im[g:im.shape[0] - g, g:im.shape[1] - g]  # noqa: E731
        ia, ib, ir = crop(ia), crop(ib), crop(ir)
        half = n // 2 * tp
        if not vertical:
            stitched = np.concatenate([ia[:, -half:], ib[:, :half]], axis=1)
            dist = np.abs(np.arange(2 * half) - half + 0.5)[None, :].repeat(stitched.shape[0], 0)
        else:
            stitched = np.concatenate([ia[-half:, :], ib[:half, :]], axis=0)
            dist = np.abs(np.arange(2 * half) - half + 0.5)[:, None].repeat(stitched.shape[1], 1)
        d = np.abs(_norm(stitched) - _norm(ir)).max(axis=2) > 0
        row = {}
        for lo, hi in bands:
            m = (dist >= lo) & (dist < hi)
            row[f"{lo}-{hi}px"] = round(float(d[m].mean()), 5)
        row["all"] = round(float(d.mean()), 5)
        row["nonblank_fraction"] = round(float((ir[..., 3] > 0).mean()), 3)
        res["gutters"][str(g)] = row
        images[g] = (stitched, ir, d)
    if save:
        _save_seam(images, vertical, save)
    return res


def _save_seam(images, vertical, path):
    """Strip around the seam: stitched | reference | diff, one row per gutter."""
    rows = []
    for g, (st, ref, d) in images.items():
        h, w = st.shape[:2]
        if not vertical:
            sl = (slice(0, min(h, 512)), slice(w // 2 - 256, w // 2 + 256))
        else:
            sl = (slice(h // 2 - 256, h // 2 + 256), slice(0, min(w, 512)))
        a, b = st[sl], ref[sl]
        dm = np.full(a.shape, 255, np.uint8)
        dm[d[sl]] = (255, 0, 0, 255)
        if not vertical:
            a = a.copy()
            a[:, 255:257] = (0, 200, 0, 255)  # mark the seam
        rows.append(np.concatenate([a, b, dm], axis=1))
    Image.fromarray(np.concatenate(rows, axis=0).astype(np.uint8)).save(path)


def dump(obj) -> str:
    return json.dumps(obj, indent=1)


__all__ = ["Block", "determinism", "pinned_vs_default", "extent_check", "seam_test", "RenderConfig"]
