"""Derived layers (spec C.2a locks, C.4b extended sounding raise, C.7a area-wide advisories)."""
from __future__ import annotations

import geopandas as gpd
import numpy as np
import shapely
from shapely.geometry import LineString, Point, box

from enc_routing import derived
from enc_routing.config import BuildParams

P = BuildParams()
DEG_M = 111_195.0


def test_gate_navigability():
    assert derived.gate_is_navigable("4", None)
    assert derived.gate_is_navigable("2", "Floodgate closed position")
    assert not derived.gate_is_navigable("2", "Floodgate guidewall")
    assert not derived.gate_is_navigable("4", "Permanently closed to navigation.")
    assert not derived.gate_is_navigable("4", "Closed")
    assert not derived.gate_is_navigable("6", None)      # sluice
    assert not derived.gate_is_navigable(None, "Lock")    # no category: stays an obstacle


def _gates(lines, cats, names, informs):
    return gpd.GeoDataFrame({"CATGAT": cats, "OBJNAM": names, "INFORM": informs,
                             "fkey": [f"C:{k}" for k in range(len(lines))]}, geometry=lines, crs="EPSG:4326")


def test_lock_zone_groups_the_gates_of_one_lock():
    y0 = 29.9644
    dy = 190 / DEG_M   # a 190 m chamber
    lines = [LineString([(-90.0274, y0), (-90.0272, y0)]), LineString([(-90.0274, y0 + dy), (-90.0272, y0 + dy)]),
             LineString([(-90.20, 29.5), (-90.199, 29.5)]), LineString([(-90.0274, y0 + 2 * dy), (-90.0272, y0 + 2 * dy)])]
    g = _gates(lines, ["4", "4", "2", "1"], ["Industrial Lock", None, None, None], ["Length 190 m", None, None, None])
    z = derived.lock_zones(g, P)
    assert list(z.OBJNAM) == ["Industrial Lock", "Floodgate"]
    assert z.geometry.values[0].contains(Point(-90.0273, y0 + dy / 2))           # the chamber
    assert not z.geometry.values[0].contains(Point(-90.0273, y0 + 2 * dy))       # the CATGAT 1 gate is not a lock
    assert list(z.INFORM) == ["Length 190 m", ""]


def test_areawide_by_size_and_category():
    big = box(-82, 24, -81.9, 24.1)                     # about 112 km2
    small = box(-82, 25, -81.995, 25.005)
    rows = {"RESARE": gpd.GeoDataFrame({
        "OBJNAM": ["Sanctuary", "Sanctuary", "Reserve", "No wake", "Danger"],
        "INFORM": [None] * 5, "RESTRN": [None, None, None, "13", "7"], "CATREA": ["23", "23", "4", None, None],
        "fkey": ["a", "b", "c", "d", "e"]},
        geometry=[box(-82, 24, -81.95, 24.1), box(-81.95, 24, -81.9, 24.1), small, big, big], crs="EPSG:4326"),
        "CTNARE": gpd.GeoDataFrame({"OBJNAM": [None, None], "INFORM": ["Shoal reported", "Piles may be submerged"],
                                    "fkey": ["f", "g"]}, geometry=[small, big], crs="EPSG:4326")}
    aw = derived.areawide_keys(rows, P)
    # environmental reserves always; no-wake and prohibited never; CTNARE by connected size
    assert aw == {"a", "b", "c", "g"}


def test_sounding_extension_raises_inside_dense_consistent_soundings_only():
    lon0, lat0 = -90.2, 30.2
    k = 1 / DEG_M
    area = box(lon0, lat0, lon0 + 8000 * k / np.cos(np.radians(lat0)), lat0 + 8000 * k)
    pts, depths = [], []
    for i in range(1, 8):
        for j in range(1, 8):
            pts.append(Point(lon0 + i * 1000 * k / np.cos(np.radians(lat0)) + (j % 2) * 300 * k, lat0 + j * 1000 * k))
            depths.append(3.6)
    merged = {"DEPARE": gpd.GeoDataFrame({"DRVAL1": [0.0], "DRVAL2": [5.0], "fkey": ["dep"]}, geometry=[area],
                                         crs="EPSG:4326"),
              "SOUNDG": gpd.GeoDataFrame({"DEPTH": depths}, geometry=pts, crs="EPSG:4326")}
    out = derived.sounding_extension(merged, area.buffer(0.05), 40000, P)
    assert len(out) and set(out.refined_dm) == {33}          # 3.6 m - 0.3 m margin
    raised = shapely.union_all(out.geometry.values)
    assert raised.contains(Point(lon0 + 4000 * k / np.cos(np.radians(lat0)), lat0 + 4000 * k))
    assert not raised.intersects(area.exterior.buffer(140 * k))   # 150 m from the depth-area boundary
    # a hazard nearby removes the raise around it
    merged["WRECKS"] = gpd.GeoDataFrame({"VALSOU": [np.nan]}, geometry=[Point(lon0 + 4000 * k / np.cos(np.radians(lat0)),
                                                                                 lat0 + 4000 * k)], crs="EPSG:4326")
    out2 = derived.sounding_extension(merged, area.buffer(0.05), 40000, P)
    assert shapely.union_all(out2.geometry.values).area < raised.area
    # inconsistent soundings (spread over 1 m) are not used
    merged.pop("WRECKS")
    merged["SOUNDG"] = gpd.GeoDataFrame({"DEPTH": [0.6 if n % 2 else 3.6 for n in range(len(pts))]}, geometry=pts,
                                        crs="EPSG:4326")
    assert len(derived.sounding_extension(merged, area.buffer(0.05), 40000, P)) == 0
