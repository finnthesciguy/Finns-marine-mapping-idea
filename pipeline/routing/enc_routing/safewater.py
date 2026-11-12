"""Safe-water polygons per depth threshold, and connectivity analysis.

Depth semantics (verified from DSPM in every pilot cell): depths in metres
(DUNI=1), sounding datum MLLW (SDAT=12), heights/clearances above MHW
(VDAT=16), horizontal WGS84 (HDAT=2).

NOAA US charts are compiled in feet and the metric S-57 values are rounded
to 0.1 m (6 ft -> 1.8 m, 12 ft -> 3.6 m). A threshold of T feet is therefore
compared against chart_metres(T); comparing with the exact 1.8288 m
would silently drop every 6 ft contour area.
"""
from __future__ import annotations

import json
import math

import geopandas as gpd
import numpy as np
import pandas as pd
import shapely
from shapely.geometry import Point

from .config import FT, GEO_CRS, THRESHOLDS_FT, WORK_CRS, work
from .places import GULF_SEED, PROBES, TAMPA_MOUTH

CLOSE_M = 5.0          # morphological closing that heals merge slivers
HAZARD_POINT_M = 10.0  # clearance radius around point hazards (chart position accuracy)
PASS_CLOSE_M = 1500.0  # land closing radius that seals passes for the 'inside' mask
HAZARD_AREA_M = 10.0   # clearance around line/area hazards
STRUCT_LINE_M = 3.0    # half-width of shoreline-construction lines
MIN_PART_M2 = 100.0    # ignore water parts smaller than this when counting
PROBE_SNAP_M = 500.0   # probe points snap to water this close


def chart_metres(ft: float) -> float:
    """Feet -> the metric value NOAA writes into S-57: feet converted and
    TRUNCATED to 0.1 m (12 ft = 3.6576 m is stored as 3.6, 18 ft as 5.4,
    36 ft as 10.9), verified against the DRVAL1 values in the pilot cells."""
    return math.floor(ft * FT * 10 + 1e-6) / 10


def depth_ok(drval1, threshold_ft: float):
    """Vectorised: area with least depth DRVAL1 (m) is at least threshold_ft."""
    d = np.asarray(drval1, dtype=float)
    return np.nan_to_num(d, nan=-1e9) >= chart_metres(threshold_ft) - 1e-6


def hazard_blocks(valsou, watlev, threshold_ft: float):
    """Vectorised: does a point/area hazard block a boat needing threshold_ft?
    Unknown depth (no VALSOU) blocks, whatever WATLEV says; a known VALSOU
    blocks when shallower than the threshold."""
    v = np.asarray(valsou, dtype=float)
    return np.isnan(v) | (v < chart_metres(threshold_ft) - 1e-6)


def _read(layer):
    p = work("merge", "merged.gpkg")
    try:
        return gpd.read_file(p, layer=layer, engine="pyogrio")
    except Exception:
        return gpd.GeoDataFrame({"geometry": []}, geometry="geometry", crs=WORK_CRS)


def _polys(gdf):
    return gdf[gdf.geom_type.isin(["Polygon", "MultiPolygon"])]


def obstacles() -> object:
    """Land and fixed structures (never navigable)."""
    parts = []
    land = _read("LNDARE")
    parts += list(_polys(land).geometry.values)
    parts += list(shapely.buffer(land[~land.geom_type.str.contains("Polygon")].geometry.values, 10.0))
    sl = _read("SLCONS")
    parts += list(_polys(sl).geometry.values)
    parts += list(shapely.buffer(sl[~sl.geom_type.str.contains("Polygon")].geometry.values, STRUCT_LINE_M))
    for layer in ["PONTON", "HULKES", "FLODOC", "DRYDOC", "DAMCON", "GATCON", "DYKCON"]:
        g = _read(layer)
        if len(g):
            parts += list(shapely.buffer(g.geometry.values, 2.0))
    # A causeway polygon is charted straight across its bridge span (e.g. the
    # bascule span of Welch Causeway over the ICW): the bridge footprint is
    # navigable water under an overhead obstruction, so cut it out.
    cw = _read("CAUSWY")
    if len(cw):
        br = _read("BRIDGE")
        span = shapely.union_all(shapely.buffer(br.geometry.values, 5.0)) if len(br) else shapely.Polygon()
        parts += [g.difference(span) for g in shapely.buffer(cw.geometry.values, 2.0)]
    piles = _read("PILPNT")
    parts += list(shapely.buffer(piles.geometry.values, 5.0))
    unsare = _read("UNSARE")
    parts += list(_polys(unsare).geometry.values)
    return shapely.union_all(parts)


def hazards() -> gpd.GeoDataFrame:
    """OBSTRN/WRECKS/UWTROC with their clearance buffer and VALSOU."""
    frames = []
    for layer in ["OBSTRN", "WRECKS", "UWTROC"]:
        g = _read(layer)
        if g.empty:
            continue
        # CATOBS 7 = foul ground (safe to navigate, not to anchor): skip.
        if layer == "OBSTRN":
            g = g[g.CATOBS.fillna(0) != 7]
        rad = np.where(g.geom_type == "Point", HAZARD_POINT_M, HAZARD_AREA_M)
        frames.append(gpd.GeoDataFrame(
            {"cls": layer, "VALSOU": g.VALSOU.astype(float), "WATLEV": g.WATLEV,
             "cell": g.cell},
            geometry=shapely.buffer(g.geometry.values, rad), crs=WORK_CRS))
    return gpd.GeoDataFrame(pd.concat(frames, ignore_index=True), crs=WORK_CRS)


def depth_areas() -> gpd.GeoDataFrame:
    frames = []
    for layer in ["DEPARE", "DRGARE"]:
        g = _polys(_read(layer))
        frames.append(gpd.GeoDataFrame({"cls": layer, "DRVAL1": g.DRVAL1.astype(float),
                                        "cell": g.cell, "SORDAT": g.SORDAT},
                                       geometry=g.geometry.values, crs=WORK_CRS))
    return gpd.GeoDataFrame(pd.concat(frames, ignore_index=True), crs=WORK_CRS)


def close(geom, d=CLOSE_M):
    return geom.buffer(d, join_style="mitre").buffer(-d, join_style="mitre")


def safe_water(areas, obst, haz, threshold_ft: float):
    w = shapely.union_all(areas.geometry.values[depth_ok(areas.DRVAL1.values, threshold_ft)])
    w = close(w)
    w = w.difference(obst)
    hb = haz.geometry.values[hazard_blocks(haz.VALSOU.values, haz.WATLEV.values, threshold_ft)]
    if len(hb):
        w = w.difference(shapely.union_all(hb))
    return shapely.make_valid(w)


def components(geom, min_area=MIN_PART_M2):
    return [p for p in shapely.get_parts(geom) if p.geom_type == "Polygon" and p.area >= min_area]


def which_component(parts, pt, snap_m: float = 0.0):
    """Index of the component containing pt, or of the nearest one within
    snap_m (probe points are hand-placed and may sit on a shoal edge)."""
    best, bd = None, snap_m
    for i, p in enumerate(parts):
        if p.covers(pt):
            return i
        if snap_m > 0:
            d = p.distance(pt)
            if d <= bd:
                best, bd = i, d
    return best


def to_work(lonlat):
    return gpd.GeoSeries([Point(lonlat)], crs=GEO_CRS).to_crs(WORK_CRS).iloc[0]


def gulf_mask(obst, pilot_bbox=None, close_m: float = PASS_CLOSE_M):
    """Open-Gulf polygon: the part of the pilot box connected to GULF_SEED
    once the land mass is morphologically closed (sealing passes narrower
    than ~2*close_m) and a line is drawn across Tampa Bay mouth. Water not in
    this polygon is 'inside' (bays, sounds, ICW)."""
    from shapely.geometry import LineString, box
    from .config import PILOT_BBOX

    cache = work("polygons", "gulf_mask.wkb")
    if cache.exists():
        return shapely.from_wkb(cache.read_bytes())
    pilot = gpd.GeoSeries([box(*(pilot_bbox or PILOT_BBOX))], crs=GEO_CRS).to_crs(WORK_CRS).iloc[0]
    mouth = gpd.GeoSeries([LineString(TAMPA_MOUTH)], crs=GEO_CRS).to_crs(WORK_CRS).iloc[0]
    land = shapely.union_all([p for p in shapely.get_parts(obst) if p.area > 5e4])
    land = land.simplify(20).union(mouth.buffer(50))
    barrier = land.buffer(close_m).buffer(-close_m)
    seed = to_work(GULF_SEED)
    free = pilot.difference(barrier)
    g = next(p for p in shapely.get_parts(free) if p.covers(seed))
    cache.write_bytes(shapely.to_wkb(g))
    return g


def find_breaks(parts_list, comp_a: int, comp_b: int):
    """Shortest connection between two components: where a channel is cut."""
    line = shapely.shortest_line(parts_list[comp_a], parts_list[comp_b])
    return line


def icw_breaks(icw, iparts, areas, obst, haz, t):
    pts = icw.geometry.representative_point()
    order = np.argsort(-gpd.GeoSeries(pts, crs=WORK_CRS).to_crs(GEO_CRS).y.values)
    comps = [which_component(iparts, pts.iloc[i], 30.0) for i in order]
    breaks, prev = [], None
    for c in comps:
        if c is None or c == prev:
            prev = c if c is not None else prev
            continue
        if prev is not None:
            line = shapely.shortest_line(iparts[prev], iparts[c])
            mid = line.interpolate(0.5, normalized=True)
            ll = gpd.GeoSeries([mid], crs=WORK_CRS).to_crs(GEO_CRS).iloc[0]
            probe = line.buffer(3)
            cause = []
            shallow = areas[areas.intersects(probe) & ~depth_ok(areas.DRVAL1.values, t)]
            if len(shallow):
                cause.append("charted depth " + ",".join(sorted({f"{v:g}" for v in shallow.DRVAL1})) + " m")
            if obst.intersects(probe):
                cause.append("land/structure")
            hb = haz[haz.intersects(probe) & hazard_blocks(haz.VALSOU.values, haz.WATLEV.values, t)]
            if len(hb):
                cause.append(f"{len(hb)} hazard(s) " + ",".join(sorted(set(hb.cls))))
            breaks.append({"from": int(prev), "to": int(c), "lat": round(ll.y, 5), "lon": round(ll.x, 5),
                           "gap_m": round(line.length, 1), "cause": "; ".join(cause) or "?"})
        prev = c
    return breaks


def run_polygons() -> dict:
    areas = depth_areas()
    obst = obstacles()
    haz = hazards()
    gulf = gulf_mask(obst)
    icw = areas[(areas.cls == "DRGARE")]
    icw_src = _read("DRGARE")
    icw = icw_src[icw_src.OBJNAM.fillna("").str.contains("Intracoastal")]
    probes = {k: to_work(v) for k, v in PROBES.items()}

    report = {"hazards_total": int(len(haz)),
              "hazards_without_VALSOU": int(haz.VALSOU.isna().sum()),
              "drval1_values_m": sorted(set(np.round(areas.DRVAL1.dropna().values, 1).tolist()))[:40],
              "thresholds": {}}
    out = []
    for t in THRESHOLDS_FT:
        w = safe_water(areas, obst, haz, t)
        parts = components(w)
        parts.sort(key=lambda p: -p.area)
        inside = w.difference(gulf)
        iparts = sorted(components(inside), key=lambda p: -p.area)
        r = {
            "chart_metres": chart_metres(t),
            "area_km2": round(w.area / 1e6, 1),
            "components_ge_100m2": len(parts),
            "components_ge_1km2": sum(p.area >= 1e6 for p in parts),
            "largest_km2": round(parts[0].area / 1e6, 1) if parts else 0,
            "probe_component": {k: which_component(parts, p, PROBE_SNAP_M) for k, p in probes.items()},
            "inside_probe_component": {k: which_component(iparts, p, PROBE_SNAP_M) for k, p in probes.items()},
        }
        # ICW continuity: walk the ICW dredged pieces north -> south and
        # record every place where consecutive pieces fall in different
        # inside-water components (a "break"), with the gap and its cause.
        r["icw_breaks"] = icw_breaks(icw, iparts, areas, obst, haz, t)
        r["icw_components"] = len({b["to"] for b in r["icw_breaks"]} |
                                  {b["from"] for b in r["icw_breaks"]}) or 1
        report["thresholds"][str(t)] = r
        out.append({"threshold_ft": t, "geometry": w})
        print(t, r["components_ge_100m2"], r["area_km2"], r["inside_probe_component"])
    gdf = gpd.GeoDataFrame(out, geometry="geometry", crs=WORK_CRS)
    dest = work("polygons", "safe_water.gpkg")
    if dest.exists():
        dest.unlink()
    gdf.to_file(dest, layer="safe_water", engine="pyogrio")
    gpd.GeoDataFrame({"geometry": [obst]}, crs=WORK_CRS).to_file(dest, layer="obstacles", engine="pyogrio")
    haz.to_file(dest, layer="hazards", engine="pyogrio")
    work("reports", "polygons.json").write_text(json.dumps(report, indent=1))
    return report
