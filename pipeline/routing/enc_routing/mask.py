"""Open-Gulf mask (flag OUTSIDE), derived from the chart data for every region.

Replaces the Wave 2 hand-seeded mask (a seed point and barrier lines per
region). On a lon/lat raster aligned with the tile grid:

1. barrier = land (LNDARE) or no coastal-or-better ENC coverage;
2. core = water farther than R = mask_seal_m from any barrier (Euclidean,
   metres). No pass, bay mouth or gap between barrier islands narrower than
   2R carries core water, so the core does not leak into the bays behind;
3. seeds = water charted at least mask_seed_depth_dm deep (depth areas) and
   at least mask_seed_dist_m from land: open water offshore, never an
   inland lake, bay or river (none of the Gulf's is both that deep and that
   far from land); the open core = the connected parts of the core that
   hold a seed;
4. OUTSIDE = water within R of the open core. Each such point lies in a
   disk of radius R that is all water, so OUTSIDE reaches every open beach,
   never crosses land and stops at the mouth of a sealed pass (this is the
   morphological opening of the open water by a disk of radius R).

The raster is Gulf-wide and region-independent; each tile vectorises only
its own window (plus margin), so a change of land in one place changes the
mask (and the tile inputs) only where it changes the raster.
"""
from __future__ import annotations

import hashlib
import json

import numpy as np

from .config import BUILDER_VERSION, work

# Raster extent (multiples of the 0.2 degree tile size), covering the Gulf AOI.
EXTENT = (-98.2, 23.4, -79.8, 31.4)


def _shape(res, extent=EXTENT):
    w, s, e, n = extent
    return int(round((n - s) / res)), int(round((e - w) / res))


def _transform(res, extent=EXTENT):
    from rasterio.transform import from_origin

    return from_origin(extent[0], extent[3], res, res)


def build_mask(merged_entries: dict, load_merged, params, log=print, extent=EXTENT) -> dict:
    """Gulf-wide outside raster. merged_entries: merge.merge_all() output.
    Cached by the merge keys of all cells and the mask parameters."""
    from rasterio.features import rasterize
    from scipy import ndimage

    key = hashlib.sha256(json.dumps([BUILDER_VERSION, sorted(str(e["path"].name) for e in merged_entries.values()),
                                     params.mask_res_deg, params.mask_seal_m, params.mask_seed_depth_dm,
                                     params.mask_seed_dist_m, list(extent)]).encode()).hexdigest()[:16]
    path = work("mask", f"outside.{key}.npz")
    if path.exists():
        d = np.load(path)
        return {"key": key, "outside": np.unpackbits(d["bits"])[: int(d["n"])].reshape(d["shape"]).astype(bool),
                "res": float(d["res"]), "stats": json.loads(str(d["stats"])), "extent": tuple(extent)}
    res = params.mask_res_deg
    shape = _shape(res, extent)
    tr = _transform(res, extent)
    cov, land, deep = [], [], []
    for name, e in merged_entries.items():
        if not e["excl"].is_empty:
            cov.append(e["excl"])
        m = load_merged(e)
        g = m.get("LNDARE")
        if g is not None and len(g):
            land += [x for x in g.geometry.values if x.geom_type in ("Polygon", "MultiPolygon")]
        d = m.get("DEPARE")
        if d is not None and len(d):
            import pandas as pd
            d1 = pd.to_numeric(d.DRVAL1, errors="coerce").fillna(-1).values
            deep += [x for x, v in zip(d.geometry.values, d1) if v * 10 >= params.mask_seed_depth_dm - 0.5
                     and x.geom_type in ("Polygon", "MultiPolygon")]
    log(f"mask: rasterising {len(cov)} coverages, {len(land)} land, {len(deep)} deep areas on {shape}")
    covered = rasterize(((g, 1) for g in cov), out_shape=shape, transform=tr, fill=0, dtype="uint8").astype(bool)
    landr = rasterize(((g, 1) for g in land), out_shape=shape, transform=tr, fill=0, dtype="uint8").astype(bool) \
        if land else np.zeros(shape, bool)
    deepr = rasterize(((g, 1) for g in deep), out_shape=shape, transform=tr, fill=0, dtype="uint8").astype(bool) \
        if deep else np.zeros(shape, bool)
    lat = extent[3] - (np.arange(shape[0]) + 0.5) * res
    dy = res * 111_195.0
    dx = float(res * 111_195.0 * np.cos(np.radians(np.mean(lat))))
    barrier = landr | ~covered
    water = ~barrier
    R = params.mask_seal_m
    core = ndimage.distance_transform_edt(water, sampling=(dy, dx)) > R
    far = ndimage.distance_transform_edt(~landr, sampling=(dy, dx)) >= params.mask_seed_dist_m
    seeds = core & deepr & far
    lab, n = ndimage.label(core)
    keep = np.unique(lab[seeds])
    keep = keep[keep > 0]
    outside = np.isin(lab, keep)
    del lab
    # grow the open core back by R (Euclidean). Every disk of radius R centred on
    # core water lies in water, so this is the morphological opening of the water:
    # it reaches every beach, cannot cross land, and stops at the mouth of a pass
    # narrower than 2R.
    outside = (ndimage.distance_transform_edt(~outside, sampling=(dy, dx)) <= R) & water
    stats = {"core_components": int(n), "open_core_components": int(len(keep)), "seed_px": int(seeds.sum()),
             "outside_km2": round(float(outside.sum() * dx * dy / 1e6)), "res_deg": res}
    log(f"mask: {stats}")
    np.savez_compressed(path, bits=np.packbits(outside), n=outside.size, shape=np.array(shape), res=res,
                        stats=json.dumps(stats))
    return {"key": key, "outside": outside, "res": res, "stats": stats, "extent": tuple(extent)}


def window_polygon(mask: dict, bounds):
    """Outside polygon (lon/lat) within bounds, from the raster pixels whose
    cell lies in bounds (bounds snapped outward to the pixel grid)."""
    import shapely
    from affine import Affine
    from rasterio.features import shapes

    res = mask["res"]
    ext = mask.get("extent", EXTENT)
    w, s, e, n = bounds
    c0 = max(0, int(np.floor((w - ext[0]) / res + 1e-9)))
    c1 = min(mask["outside"].shape[1], int(np.ceil((e - ext[0]) / res - 1e-9)))
    r0 = max(0, int(np.floor((ext[3] - n) / res + 1e-9)))
    r1 = min(mask["outside"].shape[0], int(np.ceil((ext[3] - s) / res - 1e-9)))
    if c1 <= c0 or r1 <= r0:
        return shapely.Polygon()
    win = mask["outside"][r0:r1, c0:c1]
    if not win.any():
        return shapely.Polygon()
    # integer pixel coordinates first, then exact degrees (k * res), so neighbouring
    # windows produce identical shared edges
    polys = []
    for geom, v in shapes(win.astype(np.uint8), mask=win, transform=Affine.identity(), connectivity=4):
        polys.append(shapely.geometry.shape(geom))
    g = shapely.union_all(polys)

    def to_deg(xy):
        x = np.rint(xy[:, 0]).astype(np.int64) + c0
        y = np.rint(xy[:, 1]).astype(np.int64) + r0
        return np.column_stack([np.round(ext[0] + x * res, 9), np.round(ext[3] - y * res, 9)])
    g = shapely.transform(g, to_deg)
    return shapely.normalize(shapely.make_valid(g))
