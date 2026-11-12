"""Overhead obstructions (bridges, overhead cables and pipes) over water."""
from __future__ import annotations

import json

import geopandas as gpd
import numpy as np
import pandas as pd
import shapely

from .config import FT, GEO_CRS, WORK_CRS, work

# S-57 CATBRG: 1 fixed, 2 opening, 3 swing, 4 lifting, 5 bascule, 6 pontoon,
# 7 drawbridge, 8 transporter, 9 footbridge, 10 viaduct, 11 aqueduct,
# 12 suspension.
OPENING = {2, 3, 4, 5, 7, 8}
CATBRG_NAME = {1: "fixed", 2: "opening", 3: "swing", 4: "lifting", 5: "bascule", 6: "pontoon",
               7: "drawbridge", 8: "transporter", 9: "footbridge", 10: "viaduct",
               11: "aqueduct", 12: "suspension"}


def catbrg_set(v) -> set[int]:
    if v is None or (isinstance(v, float) and np.isnan(v)):
        return set()
    return {int(float(x)) for x in str(v).split(",") if x.strip()}


def is_opening(v) -> bool:
    return bool(catbrg_set(v) & OPENING)


def effective_clearance(catbrg, verclr, verccl, vercop=None):
    """Clearance (m above MHW) a boat must fit under without an opening,
    and whether an opening can give more. Returns (closed_clearance, opens).
    For an opening bridge VERCCL is the closed clearance; VERCLR is used
    when VERCCL is missing."""
    def f(x):
        try:
            x = float(x)
            return None if np.isnan(x) else x
        except (TypeError, ValueError):
            return None
    opens = is_opening(catbrg)
    if opens:
        c = f(verccl)
        return (c if c is not None else f(verclr)), True
    return f(verclr), False


def overhead_table() -> gpd.GeoDataFrame:
    """All overhead objects that intersect navigable water (DRVAL1 >= 0)."""
    from .safewater import _read, depth_areas

    areas = depth_areas()
    water = areas[areas.DRVAL1.fillna(-1) >= 0]
    shapely.prepare(wu := shapely.union_all(water.geometry.values))
    rows = []
    for layer in ["BRIDGE", "CBLOHD", "PIPOHD"]:
        g = _read(layer)
        for _, r in g.iterrows():
            if not wu.intersects(r.geometry):
                continue
            if layer == "BRIDGE":
                clr, opens = effective_clearance(r.CATBRG, r.VERCLR, r.VERCCL, r.VERCOP)
            else:
                v = r.get("VERCSA") if layer == "CBLOHD" and pd.notna(r.get("VERCSA")) else r.VERCLR
                clr, opens = (None if pd.isna(v) else float(v)), False
            rows.append({
                "cls": layer, "name": r.OBJNAM, "cell": r.cell,
                "catbrg": ",".join(CATBRG_NAME.get(c, str(c)) for c in sorted(catbrg_set(r.get("CATBRG")))),
                "VERCLR": r.get("VERCLR"), "VERCCL": r.get("VERCCL"), "VERCOP": r.get("VERCOP"),
                "VERCSA": r.get("VERCSA"), "HORCLR": r.get("HORCLR"),
                "clearance_m": clr, "opens": opens,
                "water_len_m": float(r.geometry.intersection(wu).length) if r.geometry.geom_type != "Point" else 0.0,
                "geometry": r.geometry,
            })
    return gpd.GeoDataFrame(rows, geometry="geometry", crs=WORK_CRS)


def run_bridges() -> dict:
    t = overhead_table()
    dest = work("polygons", "overhead.gpkg")
    if dest.exists():
        dest.unlink()
    t.to_file(dest, layer="overhead", engine="pyogrio")
    rep = {}
    for cls, g in t.groupby("cls"):
        rep[cls] = {
            "over_water": int(len(g)),
            "with_clearance": int(g.clearance_m.notna().sum()),
            "VERCLR_set": int(g.VERCLR.notna().sum()),
            "VERCCL_set": int(g.VERCCL.notna().sum()) if "VERCCL" in g else 0,
            "VERCOP_set": int(g.VERCOP.notna().sum()) if "VERCOP" in g else 0,
            "named": int(g.name.notna().sum()),
            "opening": int(g.opens.sum()),
        }
    # A readable list: named / clearance-bearing bridges, one row per name.
    br = t[(t.cls == "BRIDGE") & t.clearance_m.notna()].copy()
    ll = br.geometry.representative_point().to_crs(GEO_CRS)
    br["lat"], br["lon"] = ll.y.round(4), ll.x.round(4)
    br["clearance_ft"] = (br.clearance_m / FT).round(0)
    br["VERCOP_ft"] = (br.VERCOP.astype(float) / FT).round(0)
    br = br.sort_values(["lat"], ascending=False)
    lst = br[["name", "catbrg", "clearance_ft", "VERCOP_ft", "opens", "lat", "lon", "cell"]]
    lst = lst.drop_duplicates(subset=["name", "clearance_ft", "catbrg"]).fillna({"name": "(unnamed)"})
    rep["bridge_list"] = lst.to_dict(orient="records")
    cb = t[t.cls == "CBLOHD"].copy()
    rep["cable_clearance_ft"] = sorted((cb.clearance_m.dropna() / FT).round(0).astype(int).tolist())
    work("reports", "bridges.json").write_text(json.dumps(rep, indent=1, default=str))
    return rep
