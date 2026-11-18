"""USACE National Channel Framework (NCF): channel reaches (maintained depth)
and channel centrelines, fetched politely and cached.

The FeatureServer is queried per 1 x 1 degree block (envelope query, paged
with resultOffset, at most one request at a time with a pause between
requests, generic User-Agent). Each block is cached as GeoJSON under
work/ncf/blocks/, so overlapping regions and later builds reuse it. Features
are de-duplicated by OBJECTID across blocks. Delete the block files to
refresh (the NCF changes a few times a year).
"""
from __future__ import annotations

import json
import math
import time

import geopandas as gpd
import numpy as np
import pandas as pd

from .config import GEO_CRS, work

NCF = ("https://services7.arcgis.com/n1YM8pTrFmm7L4hs/ArcGIS/rest/services/"
       "National_Channel_Framework/FeatureServer")
LAYERS = {
    "reach": (2, "OBJECTID,channelreachidpk,sdsfeaturename,sdsfeaturedescription,depthmaintained,"
                 "depthauthorized,dateuploaded", "1=1"),
    "line": (0, "OBJECTID,sdsfeaturedescription,sdsfeaturename", "sdsfeaturedescription='Centerline'"),
}
PAGE = 1000
PAUSE_S = 1.5


def blocks_for(bounds) -> list[tuple[int, int]]:
    w, s, e, n = bounds
    return [(x, y) for x in range(math.floor(w), math.ceil(e)) for y in range(math.floor(s), math.ceil(n))]


def _fetch_block(kind: str, bx: int, by: int, http, log) -> list:
    import urllib.parse

    layer, fields, where = LAYERS[kind]
    path = work("ncf", "blocks", f"{kind}_{bx}_{by}.geojson")
    if path.exists():
        return json.loads(path.read_text())["features"]
    feats, offset = [], 0
    while True:
        q = {"where": where, "outFields": fields, "f": "geojson", "outSR": "4326",
             "geometry": f"{bx},{by},{bx + 1},{by + 1}", "geometryType": "esriGeometryEnvelope",
             "inSR": "4326", "spatialRel": "esriSpatialRelIntersects", "orderByFields": "OBJECTID",
             "resultOffset": str(offset), "resultRecordCount": str(PAGE)}
        r = http.request("GET", f"{NCF}/{layer}/query?" + urllib.parse.urlencode(q))
        r.raise_for_status()
        d = r.json()
        if "error" in d:
            raise RuntimeError(f"NCF {kind} block {bx},{by}: {d['error']}")
        got = d.get("features", [])
        feats += got
        time.sleep(PAUSE_S)
        if len(got) < PAGE and not d.get("properties", {}).get("exceededTransferLimit") \
                and not d.get("exceededTransferLimit"):
            break
        offset += len(got) or PAGE
    tmp = path.with_suffix(".tmp")
    tmp.write_text(json.dumps({"type": "FeatureCollection", "features": feats}))
    tmp.replace(path)
    log(f"NCF {kind} block {bx},{by}: {len(feats)} features")
    return feats


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


def _clean_name(nm) -> str:
    nm = str(nm or "").strip()
    if nm in ("None", "nan") or len(nm) > 120 or "<" in nm:  # garbage (field shift) seen in a few records
        return ""
    return nm


def load(bounds, log=print, offline: bool = False) -> dict:
    """{"reach": GeoDataFrame, "line": GeoDataFrame} (lon/lat) for the blocks
    covering bounds, plus "anomalies" (list of strings)."""
    from enc_catalog.download import Http

    http = None if offline else Http(max_concurrency=1, retries=4)
    out, anomalies = {}, []
    for kind in LAYERS:
        feats = []
        for bx, by in blocks_for(bounds):
            if offline and not work("ncf", "blocks", f"{kind}_{bx}_{by}.geojson").exists():
                continue
            feats += _fetch_block(kind, bx, by, http, log)
        if not feats:
            out[kind] = gpd.GeoDataFrame({"fkey": [], "geometry": []}, geometry="geometry", crs=GEO_CRS)
            continue
        g = gpd.GeoDataFrame.from_features(feats, crs=GEO_CRS)
        g = g[g.geometry.notna()].drop_duplicates("OBJECTID").sort_values("OBJECTID").reset_index(drop=True)
        g["fkey"] = [f"NCF{kind}:{int(o)}" for o in g.OBJECTID]
        if kind == "reach":
            raw = g.sdsfeaturename.astype(str)
            g["name_clean"] = [_clean_name(v) for v in g.sdsfeaturename]
            bad = int(((raw.str.len() > 120) | raw.str.contains("<")).sum())
            if bad:
                anomalies.append(f"NCF: {bad} reach records with a garbage name (field shift); name dropped")
            g["ident"] = g.channelreachidpk.fillna("").astype(str)
            g["desc"] = g.sdsfeaturedescription.fillna("").astype(str)
            g["date"] = [_date_ms(v) for v in g.dateuploaded]
            dm = pd.to_numeric(g.depthmaintained, errors="coerce")
            g["depthmaintained"] = dm
            g["depthauthorized"] = pd.to_numeric(g.depthauthorized, errors="coerce")
            nod = int((dm.isna() | (dm <= 0)).sum())
            if nod:
                anomalies.append(f"NCF: {nod} of {len(g)} reaches have no maintained depth (not used for depth)")
        out[kind] = g
    out["anomalies"] = anomalies
    return out
