"""Routing input layers, prepared in the region's metric CRS from the merged
ENC layers and the USACE National Channel Framework (NCF).

Depth and height conventions (verified from DSPM in every pilot cell):
depths in metres at MLLW, heights and clearances in metres above MHW. NOAA
compiles US charts in feet and writes metric S-57 values TRUNCATED to 0.1 m
(6 ft = 1.8288 m is stored as 1.8, 65 ft = 19.812 m as 19.8). All values go
into the pack as integer decimetres exactly as charted (`to_dm`). A boat
requirement in feet is converted with `req_dm` (see the format spec, part B).
"""
from __future__ import annotations

import json
import math

import geopandas as gpd
import numpy as np
import pandas as pd
import shapely
from shapely.geometry import LineString, Point, box

from .config import FT, GEO_CRS

# --------------------------------------------------------------------------- units


def to_dm(metres) -> np.ndarray:
    """Chart metres (0.1 m resolution) -> int decimetres; NaN -> -32768."""
    m = np.asarray(metres, dtype=float)
    out = np.where(np.isnan(m), -32768, np.round(np.nan_to_num(m) * 10.0))
    return out.astype(np.int32)


def ft_to_chart_dm(ft) -> np.ndarray:
    """Feet -> the decimetre value NOAA would chart: floor(ft * 3.048).
    Used for USACE depths, which are published in feet. NaN -> -32768."""
    f = np.asarray(ft, dtype=float)
    out = np.where(np.isnan(f), -32768, np.floor(np.nan_to_num(f) * 3.048 + 1e-9))
    return out.astype(np.int32)


def req_dm(required_ft: float) -> int:
    """Boat requirement in feet -> decimetre threshold (format spec B.2):
    round the requirement UP to whole feet (charts are compiled in whole
    feet) and convert like NOAA does, floor(F * 3.048). A charted value v
    (dm) satisfies the requirement iff v >= req_dm."""
    whole = math.ceil(required_ft - 1e-9)
    return (whole * 3048) // 1000


# --------------------------------------------------------------------------- S-57 helpers

def int_set(v) -> set[int]:
    if v is None or (isinstance(v, float) and np.isnan(v)):
        return set()
    out = set()
    for x in str(v).replace(";", ",").split(","):
        x = x.strip()
        if x:
            try:
                out.add(int(float(x)))
            except ValueError:
                pass
    return out


# CATBRG: 1 fixed, 2 opening, 3 swing, 4 lifting, 5 bascule, 6 pontoon,
# 7 drawbridge, 8 transporter, 9 footbridge, 10 viaduct, 11 aqueduct, 12 suspension.
OPENING_CATBRG = {2, 3, 4, 5, 7, 8}

# Regulated areas -> kind (1 prohibited, 2 restricted, 3 caution).
RESTRN_PROHIBITED = {7}                  # entry prohibited
RESTRN_RESTRICTED = {8, 14}              # entry restricted, area to be avoided
CATREA_RESTRICTED = {1, 9, 14}           # safety zone, military area, minefield
CATREA_CAUTION = {4, 5, 22, 23, 24, 27, 28}  # nature reserves, no-wake, sensitive sea areas
RESTRN_CAUTION = {13, 27}                # no wake, speed restricted


def area_kind(cls: str, restrn, catrea) -> int:
    if cls == "CTNARE":
        return 3
    r, c = int_set(restrn), int_set(catrea)
    if r & RESTRN_PROHIBITED:
        return 1
    if r & RESTRN_RESTRICTED or c & CATREA_RESTRICTED:
        return 2
    if c & CATREA_CAUTION or r & RESTRN_CAUTION:
        return 3
    return 0


def survey_year(v) -> int:
    s = str(v or "").strip()
    if len(s) >= 4 and s[:4].isdigit():
        return int(s[:4])
    return 0


# --------------------------------------------------------------------------- inputs


def _get(merged, layer):
    g = merged.get(layer)
    if g is None:
        return gpd.GeoDataFrame({"geometry": []}, geometry="geometry")
    return g


def _fkeys(g):
    if "fkey" in g.columns:
        return g.fkey.values
    return np.array([f"row:{k}" for k in range(len(g))], dtype=object)


def _polys(g):
    return g[g.geom_type.isin(["Polygon", "MultiPolygon"])]


def close(geom, d):
    return geom.buffer(d, join_style="mitre").buffer(-d, join_style="mitre")


def depth_areas(merged) -> gpd.GeoDataFrame:
    frames = []
    for layer in ["DEPARE", "DRGARE"]:
        g = _polys(_get(merged, layer))
        if g.empty:
            continue
        frames.append(pd.DataFrame({
            "cls": layer, "DRVAL1": pd.to_numeric(g.DRVAL1, errors="coerce").values,
            "DRVAL2": pd.to_numeric(g.DRVAL2, errors="coerce").values,
            "cell": g.cell.values, "cscale": g.cscale.values, "OBJNAM": g.OBJNAM.values,
            "SORDAT": g.SORDAT.values, "geometry": g.geometry.values}))
    if not frames:
        return gpd.GeoDataFrame({"cls": pd.Series([], dtype=object), "DRVAL1": pd.Series([], dtype=float),
                                 "DRVAL2": pd.Series([], dtype=float), "cell": pd.Series([], dtype=object),
                                 "cscale": pd.Series([], dtype=int), "OBJNAM": pd.Series([], dtype=object),
                                 "SORDAT": pd.Series([], dtype=object), "d1": pd.Series([], dtype=np.int32),
                                 "d2": pd.Series([], dtype=np.int32), "geometry": gpd.GeoSeries([])},
                                geometry="geometry")
    df = pd.concat(frames, ignore_index=True)
    df["d1"] = to_dm(df.DRVAL1)
    df["d2"] = to_dm(df.DRVAL2)
    return gpd.GeoDataFrame(df, geometry="geometry")


def hazards(merged) -> gpd.GeoDataFrame:
    """Every charted point/line/area hazard (OBSTRN, WRECKS, UWTROC), raw
    geometry. Foul ground (OBSTRN CATOBS 7) is not a hazard to navigation."""
    frames = []
    for code, layer in ((1, "OBSTRN"), (2, "WRECKS"), (3, "UWTROC")):
        g = _get(merged, layer)
        if g.empty:
            continue
        cat = g.CATOBS if layer == "OBSTRN" else (g.CATWRK if layer == "WRECKS" else pd.Series(np.nan, index=g.index))
        cat = pd.Series([min(int_set(v)) if int_set(v) else np.nan for v in cat], index=g.index, dtype=float)
        keep = ~((layer == "OBSTRN") & (cat == 7))
        g = g[keep.values]
        cat = cat[keep.values]
        frames.append(pd.DataFrame({
            "cls": code, "VALSOU": pd.to_numeric(g.VALSOU, errors="coerce").values,
            "WATLEV": pd.to_numeric(g.WATLEV, errors="coerce").fillna(0).astype(int).values,
            "cat": cat.fillna(0).astype(int).values, "OBJNAM": g.OBJNAM.values,
            "fkey": _fkeys(g), "geometry": g.geometry.values}))
    if not frames:
        return gpd.GeoDataFrame({"cls": pd.Series([], dtype=int), "VALSOU": pd.Series([], dtype=float),
                                 "WATLEV": pd.Series([], dtype=int), "cat": pd.Series([], dtype=int),
                                 "OBJNAM": pd.Series([], dtype=object), "fkey": pd.Series([], dtype=object),
                                 "valsou_dm": pd.Series([], dtype=int), "blocking": pd.Series([], dtype=bool),
                                 "geometry": gpd.GeoSeries([])}, geometry="geometry")
    df = pd.concat(frames, ignore_index=True)
    df["valsou_dm"] = to_dm(df.VALSOU)
    # unknown depth, drying or awash: blocks every boat
    df["blocking"] = (df.valsou_dm == -32768) | (df.valsou_dm <= 0)
    return gpd.GeoDataFrame(df, geometry="geometry")


FENDER_CATSLC = {14}  # fender: guides vessels through a bridge opening


def shore_parts(merged, split_fenders: bool = False):
    """Land and fixed structures (raw geometry, any dimension). With
    split_fenders, returns (parts, fenders) where fenders are SLCONS with
    CATSLC 14, which get the smaller fender clearance."""
    parts = []
    land = _get(merged, "LNDARE")
    parts += list(land.geometry.values)
    sl = _get(merged, "SLCONS")
    fender = np.array([bool(int_set(v) & FENDER_CATSLC) for v in sl.CATSLC]) if len(sl) else np.zeros(0, bool)
    fenders = list(sl.geometry.values[fender]) if split_fenders else []
    parts += list(sl.geometry.values[~fender] if split_fenders else sl.geometry.values)
    for layer in ["PONTON", "HULKES", "FLODOC", "DRYDOC", "DAMCON", "GATCON", "DYKCON", "PILPNT"]:
        parts += list(_get(merged, layer).geometry.values)
    parts += list(_polys(_get(merged, "UNSARE")).geometry.values)
    # A causeway polygon is charted straight across its bridge span (e.g. the
    # bascule span of Welch Causeway over the ICW): cut the bridge footprint out.
    cw = _get(merged, "CAUSWY")
    if len(cw):
        br = _get(merged, "BRIDGE")
        span = shapely.union_all(shapely.buffer(br.geometry.values, 5.0)) if len(br) else shapely.Polygon()
        parts += [g.difference(span) for g in cw.geometry.values]
    parts = [p for p in parts if p is not None and not p.is_empty]
    return (parts, fenders) if split_fenders else parts


def overhead(merged, water) -> gpd.GeoDataFrame:
    """Bridges, overhead cables and pipes that touch navigable water.
    clr_dm: charted clearance (dm; for an opening span the closed clearance
    VERCCL, else VERCLR); -32768 = not charted."""
    rows = []
    if water is not None:
        shapely.prepare(water)
    for code, layer in ((1, "BRIDGE"), (2, "CBLOHD"), (3, "PIPOHD")):
        g = _get(merged, layer)
        for r in g.itertuples():
            geom = r.geometry
            if geom is None or geom.is_empty or (water is not None and not water.intersects(geom)):
                continue
            cats = int_set(getattr(r, "CATBRG", None)) if layer == "BRIDGE" else set()
            opens = bool(cats & OPENING_CATBRG)
            verclr = pd.to_numeric(getattr(r, "VERCLR", None), errors="coerce")
            verccl = pd.to_numeric(getattr(r, "VERCCL", None), errors="coerce")
            vercop = pd.to_numeric(getattr(r, "VERCOP", None), errors="coerce")
            horclr = pd.to_numeric(getattr(r, "HORCLR", None), errors="coerce")
            if layer == "CBLOHD":
                vsa = pd.to_numeric(getattr(r, "VERCSA", None), errors="coerce")
                if not np.isnan(vsa):
                    verclr = vsa
            clr = verccl if (opens and not np.isnan(verccl)) else verclr
            rows.append({"kind": code, "opens": opens, "catbrg": sum(1 << (c - 1) for c in cats if 1 <= c <= 16),
                         "clr_dm": int(to_dm([clr])[0]), "open_dm": int(to_dm([vercop])[0]),
                         "hor_dm": int(to_dm([horclr])[0]), "OBJNAM": r.OBJNAM,
                         "fkey": getattr(r, "fkey", f"{layer}:{r.Index}"), "geometry": geom})
    df = gpd.GeoDataFrame(rows, geometry="geometry") if rows else gpd.GeoDataFrame(
        {"kind": [], "geometry": []}, geometry="geometry")
    # Overhead cables are often charted twice (identical geometry): keep one
    # (the first in feature-key order, so the choice does not depend on tiling).
    if len(df):
        df = df.sort_values("fkey", kind="stable").reset_index(drop=True)
        wkb = shapely.to_wkb(shapely.normalize(df.geometry.values))
        df = df[~pd.Series(wkb).duplicated().values].reset_index(drop=True)
    return df


def _date_ms(v) -> int:
    try:
        v = float(v)
    except (TypeError, ValueError):
        return 0
    if np.isnan(v) or v <= 0:
        return 0
    import datetime as dt
    d = dt.datetime.fromtimestamp(v / 1000, dt.timezone.utc)
    return d.year * 10000 + d.month * 100 + d.day


def _ymd(v) -> int:
    s = "".join(ch for ch in str(v or "") if ch.isdigit())
    if len(s) >= 8:
        return int(s[:8])
    if len(s) == 4:
        return int(s) * 10000 + 101
    return 0


def is_icw(name) -> bool:
    n = str(name or "").upper()
    return "INTRACOASTAL" in n or n.startswith("GIWW")


def channels(merged, ncf_reach, ncf_line, crs, p) -> tuple[gpd.GeoDataFrame, gpd.GeoDataFrame]:
    """(channel polygons with attributes, highway centrelines), in crs.

    Channel polygons: NCF reaches (source 1) with maintained/authorised depth,
    ENC FAIRWY (2), ENC DRGARE (3), ENC RECTRC/NAVLNE buffered (4).
    Highway lines: NCF centrelines and the ENC ICW recommended track.
    ncf_reach / ncf_line are lon/lat GeoDataFrames (ncf.py) or None.
    Rows are sorted by feature key, so "lowest index wins" ties do not
    depend on how the area was tiled."""
    rows = []
    if ncf_reach is not None and len(ncf_reach):
        ncf = ncf_reach[ncf_reach.geometry.notna()].to_crs(crs)
        for r in ncf.itertuples():
            g = shapely.make_valid(r.geometry)
            if g.is_empty:
                continue
            # NCF reaches sit 1-30 m off the charted channel: grow them by a
            # tolerance (maintained depth is opt-in and always graded yellow)
            g = shapely.simplify(g.buffer(p.ncf_tolerance_m, quad_segs=4), 1.0)
            rows.append({"source": 1, "icw": is_icw(r.name_clean), "name": r.name_clean.title() if r.name_clean else "",
                         "ident": str(r.ident or ""), "desc": str(r.desc or "").title(),
                         "maint_dm": int(ft_to_chart_dm([r.depthmaintained])[0]),
                         "auth_dm": int(ft_to_chart_dm([r.depthauthorized])[0]),
                         "date": int(r.date or 0), "fkey": r.fkey, "geometry": g})
    for src, layer in ((2, "FAIRWY"), (3, "DRGARE")):
        g = _polys(_get(merged, layer))
        for r, fk in zip(g.itertuples(), _fkeys(g)):
            rows.append({"source": src, "icw": is_icw(r.OBJNAM), "name": str(r.OBJNAM or ""),
                         "ident": str(r.LNAM or ""), "desc": "", "maint_dm": -32768,
                         "auth_dm": int(to_dm([getattr(r, "DRVAL1", np.nan)])[0]) if layer == "DRGARE" else -32768,
                         "date": _ymd(r.SORDAT), "fkey": fk, "geometry": r.geometry})
    for layer in ("RECTRC", "NAVLNE"):
        g = _get(merged, layer)
        for r, fk in zip(g.itertuples(), _fkeys(g)):
            rows.append({"source": 4, "icw": is_icw(r.OBJNAM), "name": str(r.OBJNAM or ""),
                         "ident": str(r.LNAM or ""), "desc": "", "maint_dm": -32768, "auth_dm": -32768,
                         "date": _ymd(r.SORDAT), "fkey": fk, "geometry": r.geometry.buffer(p.track_buffer_m)})
    if rows:
        chan = gpd.GeoDataFrame(rows, geometry="geometry", crs=crs)
        chan = chan.sort_values("fkey", kind="stable").reset_index(drop=True)
    else:
        chan = gpd.GeoDataFrame({"source": [], "icw": [], "name": [], "ident": [], "desc": [], "maint_dm": [],
                                 "auth_dm": [], "date": [], "fkey": [], "geometry": []}, geometry="geometry", crs=crs)
    hw = []
    if ncf_line is not None and len(ncf_line):
        hw += list(ncf_line[ncf_line.geometry.notna()].to_crs(crs).geometry.values)
    rt = _get(merged, "RECTRC")
    if len(rt):
        hw += list(rt[rt.OBJNAM.map(is_icw)].geometry.values)
    highway = gpd.GeoDataFrame({"geometry": hw}, geometry="geometry", crs=crs)
    return chan, highway


def reg_areas(merged) -> gpd.GeoDataFrame:
    rows = []
    for layer in ("RESARE", "CTNARE"):
        g = _polys(_get(merged, layer))
        for r in g.itertuples():
            k = area_kind(layer, getattr(r, "RESTRN", None), getattr(r, "CATREA", None))
            if k == 0:
                continue
            rows.append({"kind": k, "cls": layer, "OBJNAM": r.OBJNAM, "INFORM": r.INFORM,
                         "RESTRN": str(getattr(r, "RESTRN", "") or ""), "fkey": getattr(r, "fkey", f"{layer}:{r.Index}"),
                         "geometry": r.geometry})
    if not rows:
        return gpd.GeoDataFrame({"kind": [], "cls": [], "OBJNAM": [], "INFORM": [], "RESTRN": [], "fkey": [],
                                 "geometry": []}, geometry="geometry")
    return gpd.GeoDataFrame(rows, geometry="geometry").sort_values("fkey", kind="stable").reset_index(drop=True)


CATZOC_CODE = {1: 1, 2: 2, 3: 3, 4: 4, 5: 5, 6: 6}  # A1, A2, B, C, D, U


def quality(merged) -> gpd.GeoDataFrame:
    g = _polys(_get(merged, "M_QUAL"))
    if g.empty:
        return gpd.GeoDataFrame({"catzoc": [], "year": [], "geometry": []}, geometry="geometry")
    cz = pd.to_numeric(g.CATZOC, errors="coerce").fillna(0).astype(int).clip(0, 6)
    yr = g.SUREND.map(survey_year)
    return gpd.GeoDataFrame({"catzoc": cz.values, "year": yr.values}, geometry=g.geometry.values)


def quality_byte(catzoc: int, year: int) -> int:
    """bits 0-2 CATZOC (0 unknown, 1 A1, 2 A2, 3 B, 4 C, 5 D, 6 U);
    bits 3-7 survey decade code: 0 unknown, else clamp((year-1850)//10, 1, 31)."""
    dec = 0 if year <= 0 else max(1, min(31, (year - 1850) // 10))
    return (int(catzoc) & 7) | (dec << 3)


def soundings(merged) -> gpd.GeoDataFrame:
    s = _get(merged, "SOUNDG")
    if s.empty:
        return s
    s = s[s.geom_type == "Point"]
    return gpd.GeoDataFrame({"depth_dm": to_dm(pd.to_numeric(s.DEPTH, errors="coerce")),
                             "cell": s.cell.values, "cscale": s.cscale.values},
                            geometry=s.geometry.values)
