"""Channel representation report: ENC channel objects vs USACE National
Channel Framework (NCF)."""
from __future__ import annotations

import json
import urllib.parse

import geopandas as gpd
import numpy as np
import pandas as pd
import shapely
from shapely.geometry import box

from .config import GEO_CRS, PILOT_BBOX, WORK_CRS, work
from .download import fetch

NCF = ("https://services7.arcgis.com/n1YM8pTrFmm7L4hs/ArcGIS/rest/services/"
       "National_Channel_Framework/FeatureServer")
NCF_LAYERS = {0: "ChannelLine", 1: "ChannelArea", 2: "ChannelReach", 3: "ChannelQuarter"}


def ncf_query(layer: int, bbox=PILOT_BBOX, page: int = 1000) -> gpd.GeoDataFrame:
    """Download one NCF layer clipped to bbox (GeoJSON, paginated, cached)."""
    cache = work("ncf", f"{NCF_LAYERS[layer]}.geojson")
    if cache.exists():
        return gpd.read_file(cache)
    feats, offset = [], 0
    while True:
        q = {
            "where": "1=1", "outFields": "*", "f": "geojson", "outSR": "4326",
            "geometry": ",".join(str(v) for v in bbox), "geometryType": "esriGeometryEnvelope",
            "inSR": "4326", "spatialRel": "esriSpatialRelIntersects",
            "resultOffset": str(offset), "resultRecordCount": str(page),
        }
        tmp = work("ncf", f"tmp_{layer}_{offset}.json")
        fetch(f"{NCF}/{layer}/query?" + urllib.parse.urlencode(q), tmp)
        d = json.loads(tmp.read_text())
        tmp.unlink()
        feats += d.get("features", [])
        if len(d.get("features", [])) < page and not d.get("properties", {}).get("exceededTransferLimit"):
            break
        offset += page
    cache.write_text(json.dumps({"type": "FeatureCollection", "features": feats}))
    return gpd.read_file(cache) if feats else gpd.GeoDataFrame({"geometry": []}, crs=GEO_CRS)


def _read(layer):
    from .safewater import _read as r
    return r(layer)


def run_channels() -> dict:
    rep = {"enc": {}, "ncf": {}}
    for layer in ["RECTRC", "NAVLNE", "FAIRWY", "DRGARE", "DWRTCL"]:
        g = _read(layer)
        if g.empty:
            rep["enc"][layer] = {"count": 0}
            continue
        lines = g[g.geom_type.str.contains("Line")]
        polys = g[g.geom_type.str.contains("Polygon")]
        names = g.OBJNAM.fillna("(unnamed)").value_counts()
        rep["enc"][layer] = {
            "count": int(len(g)),
            "line_km": round(float(lines.length.sum()) / 1000, 1),
            "area_km2": round(float(polys.area.sum()) / 1e6, 2),
            "named_icw": int(g.OBJNAM.fillna("").str.contains("Intracoastal").sum()),
            "top_names": names.head(8).to_dict(),
        }
    icw_rt = _read("RECTRC")
    icw_rt = icw_rt[icw_rt.OBJNAM.fillna("").str.contains("Intracoastal")]
    icw_dr = _read("DRGARE")
    icw_dr = icw_dr[icw_dr.OBJNAM.fillna("").str.contains("Intracoastal")]
    rep["enc"]["icw_rectrc_km"] = round(float(icw_rt.length.sum()) / 1000, 1)
    # how much of the ICW recommended track lies inside ICW dredged areas?
    if len(icw_rt) and len(icw_dr):
        dr = shapely.union_all(icw_dr.geometry.buffer(5).values)
        rt = shapely.union_all(icw_rt.geometry.values)
        rep["enc"]["icw_rectrc_inside_drgare_pct"] = round(100 * rt.intersection(dr).length / rt.length, 1)
    aids = {}
    for layer in ["BOYLAT", "BCNLAT", "BOYSPP", "BCNSPP", "BOYSAW", "BCNSAW", "BOYCAR", "BCNCAR"]:
        g = _read(layer)
        aids[layer] = int(len(g))
    rep["enc"]["aids_to_navigation"] = aids

    try:
        for i, name in NCF_LAYERS.items():
            g = ncf_query(i)
            info = {"features": int(len(g)), "fields": [c for c in g.columns if c != "geometry"]}
            if len(g) and "sdsfeaturename" in g:
                info["names"] = g.sdsfeaturename.fillna("?").value_counts().head(15).to_dict()
            if len(g) and "depthmaintained" in g:
                info["depthmaintained_values"] = g.depthmaintained.value_counts(dropna=False).head(10).to_dict()
            if len(g) and i == 0:
                gl = g.to_crs(WORK_CRS)
                info["line_km"] = round(float(gl.length.sum()) / 1000, 1)
                info["linetypes"] = g.channellinetype.value_counts(dropna=False).to_dict()
            rep["ncf"][name] = info
        rep["ncf"]["reachable"] = True
    except Exception as e:  # noqa: BLE001
        rep["ncf"] = {"reachable": False, "error": str(e)}
    work("reports", "channels.json").write_text(json.dumps(rep, indent=1, default=str))
    return rep
