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

from .config import PILOT_BBOX, WORK_CRS, work
from .extract import LAYERS, load

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


def run_merge() -> dict:
    meta = json.loads(work("extract", "cells_meta.json").read_text())
    mcovr = load("M_COVR").to_crs(WORK_CRS)
    pilot = gpd.GeoSeries([box(*PILOT_BBOX)], crs="EPSG:4326").to_crs(WORK_CRS).iloc[0]

    order = sorted(meta, key=lambda m: priority_key(m["name"][2], m["cscale"], m["isdt"]))
    covers = []
    for m in order:
        cv = mcovr[(mcovr.cell == m["name"]) & (mcovr.CATCOV == 1)]
        g = shapely.union_all(cv.geometry.values).intersection(pilot)
        if not g.is_empty:
            covers.append((m["name"], g))
    excl, stats = exclusive_regions(covers)

    # where does each band win?
    band_area = {}
    for name, g in excl.items():
        band_area[name[2]] = band_area.get(name[2], 0) + g.area
    union_all = shapely.union_all(list(excl.values()))
    stats["pilot_area_km2"] = pilot.area / 1e6
    stats["uncovered_km2"] = pilot.difference(union_all).area / 1e6
    stats["band_area_km2"] = {k: round(v / 1e6, 1) for k, v in sorted(band_area.items())}
    stats["cells_with_area"] = sum(1 for g in excl.values() if g.area > 1)
    stats["cells_fully_superseded"] = [n for n, g in excl.items() if g.area <= 1]

    regions = gpd.GeoDataFrame(
        {"cell": list(excl), "band": [int(n[2]) for n in excl]},
        geometry=list(excl.values()), crs=WORK_CRS,
    )
    dest = work("merge", "merged.gpkg")
    if dest.exists():
        dest.unlink()
    regions.to_file(dest, layer="REGIONS", engine="pyogrio")

    counts = {}
    for layer in LAYERS:
        if layer == "M_COVR":
            continue
        src = load(layer)
        if src.empty:
            continue
        src = src.to_crs(WORK_CRS)
        src = src.set_geometry(shapely.make_valid(src.geometry.values))
        parts = []
        for name, reg in excl.items():
            sub = src[src.cell == name]
            if len(sub):
                parts.append(clip_to_region(sub, reg))
        if not parts:
            continue
        m = gpd.GeoDataFrame(pd.concat(parts, ignore_index=True), crs=WORK_CRS)
        counts[layer] = {"extracted": int(len(src)), "kept": int(len(m))}
        m.to_file(dest, layer=layer, engine="pyogrio")

    stats["features"] = counts
    stats["skin_of_earth"] = skin_check(excl, dest)
    work("reports", "merge.json").write_text(json.dumps(stats, indent=1))
    return stats


def skin_check(excl: dict, merged_path) -> dict:
    """Group-1 objects must tile each exclusive region: measure gaps and
    overlaps after the merge."""
    frames = []
    for layer in GROUP1:
        try:
            g = gpd.read_file(merged_path, layer=layer, engine="pyogrio")
        except Exception:  # layer absent
            continue
        g = g[g.geom_type.isin(["Polygon", "MultiPolygon"])]
        frames.append(g[["cell", "geometry"]])
    allg = pd.concat(frames, ignore_index=True)
    gap_total, ovl_total, gap_pieces = 0.0, 0.0, 0
    per_cell = {}
    for name, reg in excl.items():
        sub = allg[allg.cell == name].geometry.values
        if reg.area <= 1:
            continue
        u = shapely.union_all(sub) if len(sub) else shapely.Polygon()
        gap = reg.difference(u)
        ovl = float(sum(shapely.area(sub))) - u.area
        gp = [p for p in split_parts(gap) if p.area > 1.0]
        gap_total += sum(p.area for p in gp)
        gap_pieces += len(gp)
        ovl_total += max(ovl, 0)
        if gp or ovl > 1:
            per_cell[name] = {"gap_m2": round(sum(p.area for p in gp), 1), "gap_pieces": len(gp),
                              "overlap_m2": round(max(ovl, 0), 1)}
    return {"gap_m2": round(gap_total, 1), "gap_pieces": gap_pieces,
            "overlap_m2": round(ovl_total, 1), "cells_with_issues": per_cell}
