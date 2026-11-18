"""Multi-scale "best available" merge.

Rule: every location is served by exactly one cell -- the highest-priority
cell whose M_COVR (CATCOV=1) covers it. Priority = navigational band
(harbour beats approach beats coastal ...), then larger scale (smaller
cscale), then newer issue date. Each cell therefore owns an *exclusive
region* = its coverage minus everything already claimed by higher-priority
cells. Every feature is clipped to its cell's exclusive region, so nothing is
double counted and (as long as the overview cell covers the pilot box) there
are no holes.

Slivers: hairline pieces of an exclusive region (narrower than SLIVER_M) are
where two higher-priority cells *nearly* meet. Leaving them to the lower
band produces thin strips of small-scale data (e.g. a 50 m wide land polygon
from the 1:180k chart) between harbour cells. We count them, then give them
to the higher-priority neighbour by closing the claimed region with a
morphological buffer(+e).buffer(-e) before differencing.
"""
from __future__ import annotations

import json

import geopandas as gpd
import numpy as np
import pandas as pd
import shapely
from shapely.geometry import box


SLIVER_M = 5.0  # pieces thinner than 2*SLIVER_M/2 are slivers

# Group-1 (skin of the earth) classes that must tile each cell's coverage.
GROUP1 = ["DEPARE", "DRGARE", "LNDARE", "UNSARE", "PONTON", "HULKES", "FLODOC", "DRYDOC"]


def priority_key(band: int, cscale: int, isdt: str):
    """Sort key: lower sorts first = higher priority."""
    return (-int(band), int(cscale), -int(str(isdt).replace("-", "") or 0))


def is_sliver(geom, width_m: float = SLIVER_M) -> bool:
    """True when the polygon vanishes under a negative buffer of width/2."""
    if geom.is_empty:
        return False
    return geom.buffer(-width_m / 2.0).is_empty


def split_parts(geom):
    return [g for g in shapely.get_parts(geom) if not g.is_empty]


def exclusive_regions(covers: list[tuple[str, object]], close_m: float = SLIVER_M):
    """covers: [(cell, coverage_geom)] in priority order.
    Returns (dict cell -> exclusive geom, stats)."""
    claimed = None
    out = {}
    stats = {"sliver_pieces": 0, "sliver_area_m2": 0.0, "cross_band_overlap_km2": 0.0,
             "same_band_overlap_m2": 0.0}
    band_claimed: dict[str, object] = {}
    for name, cov in covers:
        b = name[2]
        if b in band_claimed:
            stats["same_band_overlap_m2"] += cov.intersection(band_claimed[b]).area
        band_claimed[b] = cov if b not in band_claimed else band_claimed[b].union(cov)
        if claimed is None:
            excl = cov
        else:
            stats["cross_band_overlap_km2"] += cov.intersection(claimed).area / 1e6
            raw = cov.difference(claimed)
            closed = claimed.buffer(close_m, join_style="mitre").buffer(-close_m, join_style="mitre")
            excl = cov.difference(closed)
            # drop any residual dust
            excl = shapely.union_all([p for p in split_parts(excl) if p.area > 1.0]) if not excl.is_empty else excl
            # slivers = what the closing took away from this (lower-priority) cell
            removed = [p for p in split_parts(raw.difference(excl)) if p.area > 0.01]
            stats["sliver_pieces"] += len(removed)
            stats["sliver_area_m2"] += sum(p.area for p in removed)
        out[name] = excl
        claimed = cov if claimed is None else claimed.union(cov)
    return out, stats


def clip_to_region(gdf: gpd.GeoDataFrame, region) -> gpd.GeoDataFrame:
    if gdf.empty or region.is_empty:
        return gdf.iloc[0:0]
    shapely.prepare(region)
    geoms = gdf.geometry.values
    inside = shapely.contains_properly(region, geoms)
    touch = shapely.intersects(region, geoms) & ~inside
    res = gdf[inside | touch].copy()
    if touch.any():
        idx = np.where(touch[inside | touch])[0]
        g = res.geometry.values.copy()
        dims = shapely.get_dimensions(g[idx])
        cut = shapely.intersection(g[idx], region)
        g[idx] = [same_dim(c, d) for c, d in zip(cut, dims)]
        res = res.set_geometry(g)
    res = res[~res.geometry.is_empty]
    return res


def same_dim(geom, dim: int):
    """Keep only the parts of `geom` with dimension `dim` (an intersection of
    a polygon can yield a GeometryCollection with stray lines/points)."""
    if geom.is_empty or shapely.get_dimensions(geom) == dim and geom.geom_type != "GeometryCollection":
        return geom
    parts = [p for p in shapely.get_parts(geom) if shapely.get_dimensions(p) == dim and not p.is_empty]
    if not parts:
        return shapely.Polygon() if dim == 2 else shapely.LineString() if dim == 1 else shapely.Point()
    return shapely.union_all(parts) if dim == 2 else (
        shapely.MultiLineString(parts) if dim == 1 and len(parts) > 1 else
        shapely.MultiPoint(parts) if dim == 0 and len(parts) > 1 else parts[0])


# --------------------------------------------------------------------------- per-cell incremental merge

def cell_coverage(layers, catalog_cell=None):
    """Data coverage of a cell (lon/lat): union of its M_COVR CATCOV=1 polygons,
    or the catalog coverage when the cell has none (reported as an anomaly)."""
    mc = layers.get("M_COVR")
    if mc is not None and len(mc):
        cv = mc[pd.to_numeric(mc.CATCOV, errors="coerce") == 1]
        cv = cv[cv.geom_type.isin(["Polygon", "MultiPolygon"])]
        if len(cv):
            g = shapely.union_all(shapely.make_valid(cv.geometry.values))
            g = same_dim(g, 2)
            if not g.is_empty:
                return g, "M_COVR"
    if catalog_cell is not None:
        g = catalog_cell.coverage()
        if g is not None and not g.is_empty:
            return shapely.make_valid(g), "catalog"
    return shapely.Polygon(), "none"


def _to_metric(geom, crs):
    from pyproj import Transformer

    tr = Transformer.from_crs("EPSG:4326", crs, always_xy=True)
    return shapely.transform(geom, lambda xy: np.column_stack(tr.transform(xy[:, 0], xy[:, 1])))


def _to_lonlat(geom, crs):
    from pyproj import Transformer

    tr = Transformer.from_crs(crs, "EPSG:4326", always_xy=True)
    return shapely.transform(geom, lambda xy: np.column_stack(tr.transform(xy[:, 0], xy[:, 1])))


def exclusive_region(cov_ll, higher_ll: list, close_m: float = SLIVER_M):
    """Exclusive region (lon/lat) of a cell with coverage cov_ll, given the
    coverages of the higher-priority cells that overlap it. The claimed area
    is closed by close_m in a local transverse Mercator first, so hairline
    slivers between two higher-priority cells are not left to this cell.
    Returns (exclusive geometry, stats)."""
    from .config import tmerc

    st = {"sliver_pieces": 0, "sliver_area_m2": 0.0}
    if not higher_ll:
        return cov_ll, st
    c = cov_ll.centroid
    crs = tmerc(round(c.x, 1))
    cov = _to_metric(cov_ll, crs)
    claimed = _to_metric(shapely.union_all(higher_ll), crs)
    raw = cov.difference(claimed)
    closed = claimed.buffer(close_m, join_style="mitre").buffer(-close_m, join_style="mitre")
    excl = cov.difference(closed)
    excl = shapely.union_all([p for p in split_parts(excl) if p.area > 1.0]) if not excl.is_empty else excl
    removed = [p for p in split_parts(raw.difference(excl)) if p.area > 0.01]
    st["sliver_pieces"] = len(removed)
    st["sliver_area_m2"] = round(float(sum(p.area for p in removed)), 1)
    if excl.is_empty:
        return shapely.Polygon(), st
    return same_dim(shapely.make_valid(_to_lonlat(excl, crs)), 2), st


def feature_keys(df, layer: str, cell: str) -> list:
    """Stable feature identity across tiles and builds: cell + LNAM, else the
    row number within the cell's layer (fixed for a given edition/update)."""
    lnam = df["LNAM"].values if "LNAM" in df.columns else [None] * len(df)
    out = []
    for k, v in enumerate(lnam):
        v = "" if v is None or (isinstance(v, float) and np.isnan(v)) else str(v)
        out.append(f"{cell}:{v}" if v else f"{cell}:{layer}:{k}")
    return out


def merge_cell(layers: dict, excl_ll) -> dict:
    """Clip every layer of one cell to its exclusive region (lon/lat), with
    stable feature keys. M_COVR is dropped (coverage is held separately)."""
    out = {}
    for layer, gdf in layers.items():
        if layer == "M_COVR" or gdf is None or gdf.empty:
            continue
        g = gdf.copy()
        g["fkey"] = feature_keys(g, layer, str(g.cell.iloc[0]))
        g = g.set_geometry(shapely.make_valid(g.geometry.values))
        g = clip_to_region(g, excl_ll)
        if len(g):
            out[layer] = g.reset_index(drop=True)
    return out


def merge_all(cells, load, close_m: float = SLIVER_M, log=print) -> dict:
    """Per-cell incremental merge of every cell (catalog Cell objects).

    `load(cell)` returns (layers, meta) of the cell's extraction. A cell's
    result is cached under merge/<name>.<key>.pkl, where key covers the
    cell's edition and update and those of every higher-priority cell
    overlapping it: a changed cell re-clips only itself and the
    lower-priority cells under it.

    Returns {name: {"path", "meta", "coverage" (lon/lat), "excl" (lon/lat),
    "stats", "cov_source"}}."""
    import hashlib

    from .config import BUILDER_VERSION, work

    covs, metas = {}, {}
    for c in cells:
        cp = work("merge", "cov", f"{c.name}.{c.edtn}.{c.updn}.pkl")
        if cp.exists():
            covs[c.name], metas[c.name] = pd.read_pickle(cp)
            continue
        layers, meta = load(c)
        cov, src = cell_coverage(layers, c)
        meta = dict(meta, cov_source=src)
        pd.to_pickle((cov, meta), cp)
        covs[c.name], metas[c.name] = cov, meta
    order = sorted(cells, key=lambda c: priority_key(c.name[2], c.cscale, metas[c.name]["isdt"]))
    rank = {c.name: k for k, c in enumerate(order)}
    names = [c.name for c in order]
    geoms = np.array([covs[n] for n in names], dtype=object)
    tree = shapely.STRtree(geoms)
    ident = {c.name: f"{c.name}.{c.edtn}.{c.updn}" for c in cells}
    out = {}
    n_new = 0
    for c in order:
        cov = covs[c.name]
        hi = []
        if not cov.is_empty:
            for j in tree.query(cov, predicate="intersects"):
                o = names[j]
                if rank[o] < rank[c.name] and shapely.area(shapely.intersection(geoms[j], cov)) > 0:
                    hi.append(o)
        hi.sort(key=lambda o: rank[o])
        key = hashlib.sha256(json.dumps([BUILDER_VERSION, ident[c.name], [ident[o] for o in hi], close_m]
                                        ).encode()).hexdigest()[:16]
        path = work("merge", f"{c.name}.{key}.pkl")
        if path.exists():
            excl, st = pd.read_pickle(path)[:2]
        else:
            layers, _ = load(c)
            excl, st = exclusive_region(cov, [covs[o] for o in hi], close_m)
            # same-band overlap with higher-priority cells (rescheming leftovers)
            same = []
            for o in hi:
                if o[2] == c.name[2]:
                    a = _to_metric(shapely.intersection(cov, covs[o]), "EPSG:6933").area / 1e6
                    if a > 0.001:
                        same.append([o, round(a, 3)])
            st["same_band_overlap_km2"] = same
            st["higher"] = hi
            merged = merge_cell(layers, excl)
            pd.to_pickle((excl, st, merged), path)
            n_new += 1
        out[c.name] = {"path": path, "meta": metas[c.name], "coverage": cov, "excl": excl, "stats": st,
                       "cov_source": metas[c.name].get("cov_source")}
    log(f"merge: {len(order)} cells, {n_new} (re)clipped")
    return out


def load_merged(entry) -> dict:
    return pd.read_pickle(entry["path"])[2]
