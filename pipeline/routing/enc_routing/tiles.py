"""Tiled, incremental mesh build.

The plane is cut into fixed lon/lat tiles of `tile_deg` (0.2 deg) on a
global grid, so a tile means the same area in every region and every build.
Each tile is meshed on its own:

- its inputs are the merged ENC features, NCF features and the open-Gulf
  mask window within `tile_margin_m` of the tile (clipped to that box), in a
  transverse Mercator centred on the tile (so UTM zones 14-17 need no
  special handling: the scale error inside a tile is below 2e-6);
- the tile edges are constraint lines on the integer 1e-7 degree grid, and
  only faces inside the tile are kept. Snap-rounding cannot move a tile
  edge: an edge x = X0 (an integer) only passes through hot pixels centred
  on x = X0. Neighbouring tiles therefore meet on the same straight line;
  assemble.py splits the T-junctions where their vertices differ;
- the result (vertices, triangles, per-triangle attributes, side-table keys)
  is cached under tiles/<key>.pkl, where key is a hash of every input of
  the tile and of the build parameters. A changed chart cell changes the
  inputs of the tiles it touches only, so only those are rebuilt, and an
  unchanged tile is reused across builds and across regions (the overlap
  strips of two regions are the same tiles).

Tile content depends only on the tile's inputs, never on the order tiles
are built in or on which region asked for them.
"""
from __future__ import annotations

import hashlib
import json
import math
import os
import time
from dataclasses import dataclass

import numpy as np
import pandas as pd
import shapely
from shapely.geometry import box

from .config import BUILDER_VERSION, GEO_CRS, UNITS, tmerc, work

# Merged ENC layers a tile needs (names-only layers are not mesh inputs).
TILE_LAYERS = ["DEPARE", "DRGARE", "LNDARE", "UNSARE", "SLCONS", "PONTON", "HULKES", "FLODOC", "DRYDOC",
               "CAUSWY", "DAMCON", "GATCON", "DYKCON", "PILPNT", "OBSTRN", "WRECKS", "UWTROC", "SOUNDG",
               "BRIDGE", "CBLOHD", "PIPOHD", "FAIRWY", "RECTRC", "NAVLNE", "RESARE", "CTNARE", "M_QUAL"]
# Layers whose presence near a 0.1 degree cell switches it to the fine size grid.
NEAR_LAYERS = ["LNDARE", "SLCONS", "UNSARE", "PONTON"]
M_PER_DEG = 111_195.0


@dataclass(frozen=True)
class Tile:
    ix: int
    iy: int
    size: int  # units

    @property
    def id(self) -> str:
        return f"x{self.ix}_y{self.iy}"

    @property
    def rect(self) -> tuple:
        return (self.ix * self.size, self.iy * self.size, (self.ix + 1) * self.size, (self.iy + 1) * self.size)

    @property
    def bounds(self) -> tuple:
        return tuple(v / UNITS for v in self.rect)

    def grown(self, metres: float) -> tuple:
        """Bounds grown by at least `metres` on every side (degrees)."""
        w, s, e, n = self.bounds
        dlat = metres / M_PER_DEG
        dlon = dlat / math.cos(math.radians(max(abs(s), abs(n))))
        return (w - dlon, s - dlat, e + dlon, n + dlat)


def tile_size(p) -> int:
    return int(round(p.tile_deg * UNITS))


def tiles_for(area, coverage, p) -> list[Tile]:
    """Tiles meeting area (lon/lat geometry) that hold some ENC coverage."""
    T = tile_size(p)
    w, s, e, n = area.bounds
    shapely.prepare(area)
    if coverage is not None:
        shapely.prepare(coverage)
    out = []
    for ix in range(math.floor(w * UNITS / T), math.ceil(e * UNITS / T)):
        for iy in range(math.floor(s * UNITS / T), math.ceil(n * UNITS / T)):
            t = Tile(ix, iy, T)
            b = box(*t.bounds)
            if shapely.area(shapely.intersection(area, b)) <= 0:
                continue
            if coverage is not None and shapely.area(shapely.intersection(coverage, b)) <= 0:
                continue
            out.append(t)
    return out


# --------------------------------------------------------------------------- inputs

def safe_clip(geoms, bounds):
    """shapely.clip_by_rect, falling back to an exact intersection where GEOS's
    rectangle clipper fails on a degenerate ring."""
    geoms = np.asarray(geoms, dtype=object)
    try:
        return shapely.clip_by_rect(geoms, *bounds)
    except shapely.errors.GEOSException:
        bx = box(*bounds)
        cut = []
        for x in geoms:
            try:
                cut.append(shapely.clip_by_rect(x, *bounds))
            except shapely.errors.GEOSException:
                cut.append(shapely.intersection(shapely.make_valid(x), bx))
        return np.asarray(cut, dtype=object)


def _clip_frame(g, bounds):
    """Rows of g meeting bounds, clipped to it (dimension kept)."""
    from .merge import same_dim

    if g is None or g.empty:
        return None
    geoms = np.asarray(g.geometry.values, dtype=object)
    dims = shapely.get_dimensions(geoms)
    cut = safe_clip(geoms, bounds)
    cut = np.array([same_dim(c, d) if not c.is_empty else c for c, d in zip(cut, dims)], dtype=object)
    keep = ~shapely.is_empty(cut)
    if not keep.any():
        return None
    out = g[keep].copy()
    out = out.set_geometry(cut[keep])
    return out.reset_index(drop=True)


def _hash_frame(h, name, g, cols):
    h.update(name.encode())
    if g is None or g.empty:
        h.update(b"<empty>")
        return
    h.update(str(len(g)).encode())
    for wkb in shapely.to_wkb(g.geometry.values, output_dimension=2):
        h.update(wkb)
    for c in cols:
        if c in g.columns:
            h.update(c.encode())
            h.update(json.dumps([None if (isinstance(v, float) and np.isnan(v)) else str(v)
                                 for v in g[c].values]).encode())


class Source:
    """Region-level access to the merged ENC features, the NCF and the mask,
    cut into tile inputs."""

    def __init__(self, merged_entries: dict, load_merged, ncf: dict, mask: dict | None, bounds, p, log=print):
        self.p = p
        self.mask = mask
        self.frames = {}
        grow = (p.fine_zone_m + 2 * p.tile_margin_m) / M_PER_DEG * 1.3
        b = box(bounds[0] - grow, bounds[1] - grow, bounds[2] + grow, bounds[3] + grow)
        self.cells = sorted(n for n, e in merged_entries.items() if not e["excl"].is_empty and e["excl"].intersects(b))
        per = {}
        for n in self.cells:
            m = load_merged(merged_entries[n])
            for layer, g in m.items():
                per.setdefault(layer, []).append(g)
        for layer, fr in per.items():
            g = pd.concat(fr, ignore_index=True)
            g = g.sort_values("fkey", kind="stable").reset_index(drop=True)
            self.frames[layer] = g
        self.trees = {k: shapely.STRtree(g.geometry.values) for k, g in self.frames.items()}
        self.ncf = {}
        for kind in ("reach", "line"):
            g = ncf.get(kind)
            if g is not None and len(g):
                g = g[g.intersects(b)].sort_values("fkey", kind="stable").reset_index(drop=True)
            self.ncf[kind] = g
        self.ncf_trees = {k: shapely.STRtree(g.geometry.values) for k, g in self.ncf.items()
                          if g is not None and len(g)}
        log(f"source: {len(self.cells)} cells, {sum(len(g) for g in self.frames.values())} features")

    def _query(self, layer, bounds, trees, frames):
        t = trees.get(layer)
        if t is None:
            return None
        idx = np.sort(t.query(box(*bounds)))
        if len(idx) == 0:
            return None
        return frames[layer].iloc[idx]

    def fine_cells(self, tile: Tile) -> list:
        p = self.p
        cu = int(round(p.coarse_grid_deg * UNITS))
        n = tile.size // cu
        out = []
        for i in range(n):
            for j in range(n):
                x0 = (tile.rect[0] + i * cu) / UNITS
                y0 = (tile.rect[1] + j * cu) / UNITS
                dlat = p.fine_zone_m / M_PER_DEG
                dlon = dlat / math.cos(math.radians(abs(y0) + p.coarse_grid_deg))
                b = box(x0 - dlon, y0 - dlat, x0 + p.coarse_grid_deg + dlon, y0 + p.coarse_grid_deg + dlat)
                hit = False
                for layer in NEAR_LAYERS:
                    t = self.trees.get(layer)
                    if t is not None and len(t.query(b, predicate="intersects")):
                        hit = True
                        break
                if hit:
                    out.append((i, j))
        return out

    def inputs(self, tile: Tile) -> dict:
        p = self.p
        gb = tile.grown(p.tile_margin_m)
        layers = {}
        for layer in TILE_LAYERS:
            g = _clip_frame(self._query(layer, gb, self.trees, self.frames), gb)
            if g is not None:
                layers[layer] = g
        ncf = {k: _clip_frame(self._query(k, gb, self.ncf_trees, self.ncf), gb) for k in ("reach", "line")}
        gulf = None
        if self.mask is not None:
            from .mask import window_polygon

            gulf = window_polygon(self.mask, gb)
        inp = {"tile": tile, "params": p, "layers": layers, "ncf_reach": ncf["reach"], "ncf_line": ncf["line"],
               "gulf": gulf, "fine_cells": self.fine_cells(tile), "bounds": gb}
        inp["key"] = input_key(inp)
        return inp


def input_key(inp) -> str:
    h = hashlib.sha256()
    h.update(json.dumps([BUILDER_VERSION, inp["params"].key(), inp["tile"].id, inp["fine_cells"],
                         [round(v, 9) for v in inp["bounds"]]]).encode())
    for layer in sorted(inp["layers"]):
        g = inp["layers"][layer]
        # the issue date does not shape the mesh: a re-issued cell with unchanged
        # features keeps its tiles
        cols = sorted(c for c in g.columns if c not in ("geometry", "isdt"))
        _hash_frame(h, layer, g, cols)
    for k in ("ncf_reach", "ncf_line"):
        g = inp[k]
        _hash_frame(h, k, g, sorted(c for c in g.columns if c != "geometry") if g is not None else [])
    gulf = inp["gulf"]
    h.update(b"gulf")
    h.update(shapely.to_wkb(gulf) if gulf is not None and not gulf.is_empty else b"<none>")
    return h.hexdigest()[:24]


def tile_cache_path(key: str):
    return work("tiles", key[:2], f"{key}.pkl")


# --------------------------------------------------------------------------- build one tile

def build_tile(inp) -> dict:
    """Mesh one tile. Pure function of its inputs; raises if the tile's
    topology check fails."""
    from . import mesh, topology
    from . import packfmt as P

    t0 = time.time()
    p = inp["params"]
    tile = inp["tile"]
    rect = tile.rect
    lon0 = (rect[0] + rect[2]) / 2 / UNITS
    crs = tmerc(lon0)
    merged = {}
    for k, v in inp["layers"].items():
        g = v.to_crs(crs)
        # projecting can make a valid lon/lat ring self-touch: repair, keeping the dimension
        from .merge import same_dim

        geoms = g.geometry.values
        bad = ~shapely.is_valid(geoms)
        if bad.any():
            dims = shapely.get_dimensions(geoms)
            fixed = np.array(geoms, dtype=object)
            fixed[bad] = [same_dim(shapely.make_valid(x), d) for x, d in zip(geoms[bad], dims[bad])]
            g = g.set_geometry(fixed)
            g = g[~shapely.is_empty(g.geometry.values)]
        merged[k] = g
    res = {"tile": tile.id, "key": inp["key"], "triangles": 0}
    prep = mesh.prepare_tile(merged, inp["ncf_reach"], inp["ncf_line"], inp["gulf"], crs, p)
    hz = prep["haz"]
    tb = box(*tile.bounds)
    hz_keys = []
    if len(hz):
        g = inp["layers"]
        hk = []
        for layer in ("OBSTRN", "WRECKS", "UWTROC"):
            if layer in g:
                gg = g[layer]
                hk += list(gg.fkey.values[shapely.intersects(gg.geometry.values, tb)])
        hz_keys = sorted(set(hk) & set(hz.fkey.values))
    res["hazard_keys"] = hz_keys
    regs = prep["regs"]
    res["area_keys_present"] = []
    if prep["domain"].is_empty:
        res.update(coords=np.zeros((0, 2), np.int64), tris=np.zeros((0, 3), np.int32), attrs={},
                   chan_keys=[], over_keys=[], area_keys=[], over_water_keys=[], chan_domain_keys=[],
                   used_cells=[], area2=0, topology={"ok": True, "faces": 0}, seconds=round(time.time() - t0, 2))
        return res
    U = mesh.Units(crs)
    lines = mesh.constraint_lines(prep)
    lines_u = list(U.geoms_to_units(lines))
    gulf = inp["gulf"]
    if gulf is not None and not gulf.is_empty:
        lines_u.append(shapely.transform(shapely.boundary(gulf), lambda xy: xy * UNITS))
    mlat = p.line_margin_m / M_PER_DEG * UNITS
    mlon = mlat / math.cos(math.radians(max(abs(rect[1]), abs(rect[3])) / UNITS))
    lb = (int(math.floor(rect[0] - mlon)), int(math.floor(rect[1] - mlat)),
          int(math.ceil(rect[2] + mlon)), int(math.ceil(rect[3] + mlat)))
    lines_u = [g for g in safe_clip(lines_u, lb) if not g.is_empty]
    domain_u = U.geoms_to_units([prep["domain"]])[0]
    grid = mesh.tile_grid_lines(rect, lb, int(round(p.coarse_grid_deg * UNITS)), int(round(p.grid_deg * UNITS)),
                                inp["fine_cells"])
    faces, coords, tris, face_of, topo = mesh.faces_and_triangles(lines_u, domain_u, None, p, grid=grid,
                                                                  keep_rect=rect)
    if not topo["ok"]:
        raise RuntimeError(f"tile {tile.id}: mesh topology validation failed: {topo}")
    if len(tris) == 0:
        res.update(coords=coords, tris=tris.astype(np.int32), attrs={}, chan_keys=[], over_keys=[], area_keys=[],
                   over_water_keys=[], chan_domain_keys=[], used_cells=[], area2=0, topology=topo,
                   seconds=round(time.time() - t0, 2))
        return res
    pts_u, _ = mesh.face_sample_points(coords, tris, face_of, len(faces))
    pts_m = U.units_to_metric(pts_u)
    fa = mesh.face_attributes(prep, pts_m, p)
    # side-table references: tile-local index -> feature key
    chan, over = prep["chan"], prep["over"]
    keymaps = {"channel": list(chan.fkey.values) if len(chan) else [],
               "overhead": list(over.fkey.values) if len(over) else [],
               "area": list(regs.fkey.values) if len(regs) else []}
    attrs = {k: np.asarray(v)[face_of] for k, v in fa.items()}
    res.update(coords=coords.astype(np.int64), tris=tris.astype(np.int32), attrs=attrs,
               chan_keys=keymaps["channel"], over_keys=keymaps["overhead"], area_keys=keymaps["area"],
               over_water_keys=keymaps["overhead"], chan_domain_keys=keymaps["channel"],
               used_cells=prep["used_cells"], area2=int(topo["area2_faces"]), topology=topo,
               faces=int(len(faces)), seconds=round(time.time() - t0, 2))
    res["triangles"] = int(len(tris))
    del P
    return res


def _run(inp):
    """Worker entry: build (or load) one tile and cache it. Returns a summary."""
    path = tile_cache_path(inp["key"])
    if path.exists():
        return {"tile": inp["tile"].id, "key": inp["key"], "cached": True}
    try:
        res = build_tile(inp)
    except Exception as e:  # noqa: BLE001 - name the tile, keep the cause
        import traceback

        raise RuntimeError(f"tile {inp['tile'].id} {inp['tile'].bounds}: {type(e).__name__}: {e}\n"
                           + traceback.format_exc()) from None
    tmp = path.with_suffix(f".{os.getpid()}.tmp")
    pd.to_pickle(res, tmp)
    os.replace(tmp, path)
    return {"tile": res["tile"], "key": res["key"], "cached": False, "seconds": res.get("seconds"),
            "triangles": res["triangles"]}


def build_tiles(source: Source, tiles: list[Tile], workers: int = 4, log=print, order=None) -> dict:
    """Build every tile not yet cached (in parallel, spawn workers). Returns
    {tile id: key} and stats. `order` permutes the submission order (tests)."""
    import multiprocessing as mp
    from concurrent.futures import ProcessPoolExecutor, as_completed

    keys, todo = {}, []
    t0 = time.time()
    for t in tiles:
        inp = source.inputs(t)
        keys[t.id] = inp["key"]
        if not tile_cache_path(inp["key"]).exists():
            todo.append(inp)
    log(f"tiles: {len(tiles)} in region, {len(tiles) - len(todo)} cached, {len(todo)} to build "
        f"(inputs {time.time() - t0:.0f} s)")
    if order is not None:
        todo = [todo[i] for i in order(len(todo))]
    built, secs, tri = 0, [], 0
    if todo and workers <= 1:
        for inp in todo:
            r = _run(inp)
            built += 1
            secs.append(r.get("seconds") or 0)
            tri += r.get("triangles") or 0
    elif todo:
        ctx = mp.get_context("spawn")
        with ProcessPoolExecutor(workers, mp_context=ctx, max_tasks_per_child=25) as ex:
            futs = {ex.submit(_run, inp): inp["tile"].id for inp in todo}
            for k, f in enumerate(as_completed(futs)):
                r = f.result()
                built += 1
                secs.append(r.get("seconds") or 0)
                tri += r.get("triangles") or 0
                if (k + 1) % 25 == 0 or k + 1 == len(todo):
                    log(f"  tiles built {k + 1}/{len(todo)} ({time.time() - t0:.0f} s)")
    return {"keys": keys, "built": built, "cached": len(tiles) - len(todo),
            "tile_seconds_max": max(secs) if secs else 0, "tile_seconds_sum": round(sum(secs), 1),
            "new_triangles": tri}


def load_tile(key: str) -> dict:
    return pd.read_pickle(tile_cache_path(key))


__all__ = ["Tile", "Source", "build_tile", "build_tiles", "load_tile", "tiles_for", "tile_size", "GEO_CRS"]
