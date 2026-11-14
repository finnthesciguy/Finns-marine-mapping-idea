"""Reference routes on a pack, checked against the SOURCE data.

The router reads only the pack. These checks read the raw chart data of the
build (checks.pkl: land, shoreline constructions, pontoons, piles, blocking
hazards, fenders, bridges and overhead objects, all lon/lat) and verify each
route found:

- it does not touch land, a structure or a blocking hazard, and keeps the
  safety clearance (12 m, or 4 m within the bridge zone, 3 m from fenders;
  0.5 m tolerance for rounding and the local metric);
- every overhead object it crosses is an opening span, or has a charted
  clearance of at least the boat's air draft (cables without a clearance
  only when the profile accepts unknown clearance). A bridge part without a
  clearance is solid.

A route that fails a check is a release blocker (`reference --gate`).
"""
from __future__ import annotations

import json
import time

import numpy as np
import pandas as pd
import shapely
from pyproj import Transformer

from . import packfmt as P
from .config import GEO_CRS, tmerc
from .router import Profile, Router, req_dm

CLEARANCE_TOL_M = 0.5


def load_checks(region) -> dict:
    ck = pd.read_pickle(region.dir("checks.pkl"))
    obst = np.asarray(shapely.from_wkb(ck["obstacles"]), dtype=object)
    fend = np.asarray(shapely.from_wkb(ck["fenders"]), dtype=object) if len(ck["fenders"]) else np.zeros(0, object)
    bridges = np.asarray(shapely.from_wkb(ck["bridges"]), dtype=object) if len(ck["bridges"]) else np.zeros(0, object)
    over = ck["overhead"]
    out = {"obstacles": obst, "fenders": fend, "bridges": bridges, "overhead": over,
           "obst_tree": shapely.STRtree(obst), "fend_tree": shapely.STRtree(fend) if len(fend) else None,
           "bridge_tree": shapely.STRtree(bridges) if len(bridges) else None,
           "over_tree": shapely.STRtree(over.geometry.values) if len(over) else None}
    p = region.params

    def bridge_zone_ll(b):
        if out["bridge_tree"] is None:
            return shapely.Polygon()
        idx = out["bridge_tree"].query(b)
        if not len(idx):
            return shapely.Polygon()
        c = b.centroid
        crs = tmerc(round(c.x, 2))
        fw = Transformer.from_crs(GEO_CRS, crs, always_xy=True)
        bw = Transformer.from_crs(crs, GEO_CRS, always_xy=True)
        g = shapely.transform(bridges[idx], lambda xy: np.column_stack(fw.transform(xy[:, 0], xy[:, 1])))
        z = shapely.union_all(shapely.buffer(shapely.make_valid(g), p.bridge_zone_m, quad_segs=4))
        return shapely.transform(z, lambda xy: np.column_stack(bw.transform(xy[:, 0], xy[:, 1])))
    out["bridge_zone_ll"] = bridge_zone_ll
    return out


def check_route(ck, waypoints, prof: Profile, p) -> dict:
    """Raw-data checks of one route (waypoints lon/lat)."""
    w = np.asarray(waypoints, float)
    line_ll = shapely.LineString(w)
    lon0 = float(np.mean(w[:, 0]))
    crs = tmerc(round(lon0, 2))
    fw = Transformer.from_crs(GEO_CRS, crs, always_xy=True)

    def m(g):
        return shapely.transform(g, lambda xy: np.column_stack(fw.transform(xy[:, 0], xy[:, 1])))
    line = m(line_ll)
    env = line_ll.buffer(0.01)
    out = {}
    idx = ck["obst_tree"].query(env)
    obst = np.asarray([m(g) for g in ck["obstacles"][idx]], dtype=object)
    zone = m(ck["bridge_zone_ll"](env))
    fend = np.zeros(0, object)
    if ck["fend_tree"] is not None:
        fi = ck["fend_tree"].query(env)
        fend = np.asarray([m(g) for g in ck["fenders"][fi]], dtype=object)

    def dmin(geoms, g):
        if len(geoms) == 0 or g.is_empty:
            return None
        return round(float(shapely.distance(geoms, g).min()), 1)
    out["touches_obstacle"] = bool(shapely.intersects(obst, line).any() or shapely.intersects(fend, line).any())
    out["min_obstacle_m"] = dmin(obst, line)
    outside = line.difference(zone) if not zone.is_empty else line
    out["min_obstacle_outside_bridge_zones_m"] = dmin(obst, outside)
    out["min_fender_m"] = dmin(fend, line)
    viol = []
    if out["touches_obstacle"]:
        viol.append("touches land, a structure or a blocking hazard")
    if out["min_obstacle_outside_bridge_zones_m"] is not None and \
            out["min_obstacle_outside_bridge_zones_m"] < p.clearance_m - CLEARANCE_TOL_M:
        viol.append(f"closer than {p.clearance_m} m to an obstacle outside bridge zones "
                    f"({out['min_obstacle_outside_bridge_zones_m']} m)")
    if out["min_obstacle_m"] is not None and out["min_obstacle_m"] < p.bridge_clearance_m - CLEARANCE_TOL_M:
        viol.append(f"closer than {p.bridge_clearance_m} m to an obstacle ({out['min_obstacle_m']} m)")
    if out["min_fender_m"] is not None and out["min_fender_m"] < p.fender_clearance_m - CLEARANCE_TOL_M:
        viol.append(f"closer than {p.fender_clearance_m} m to a fender ({out['min_fender_m']} m)")
    # overhead objects crossed, checked against the raw clearance
    air = req_dm(prof.air_draft_ft)
    crossed = []
    if ck["over_tree"] is not None:
        oi = ck["over_tree"].query(line_ll, predicate="intersects")
        ov = ck["overhead"]
        for k in sorted(oi):
            r = ov.iloc[int(k)]
            g = r.geometry
            # a polygon footprint is passed under only if the route enters its interior
            # (adjacent bridge parts share edges; running along a shared edge is not passing under)
            if g.geom_type in ("Polygon", "MultiPolygon") and not shapely.relate_pattern(line_ll, g, "T********"):
                continue
            clr = int(r.clr_dm)
            name = r.OBJNAM if isinstance(r.OBJNAM, str) else ""
            kind = {1: "bridge", 2: "cable", 3: "pipe"}[int(r.kind)]
            item = {"kind": kind, "name": name, "opening": bool(r.opens), "clearance_dm": None if clr == -32768 else clr}
            crossed.append(item)
            if r.opens:
                continue
            if clr == -32768:
                if int(r.kind) == 1:
                    viol.append(f"under a bridge part without clearance ({name or 'unnamed'})")
                elif not prof.accept_unknown_clearance:
                    viol.append(f"under a {kind} of unknown clearance ({name or 'unnamed'}) in a profile "
                                "that does not accept it")
            elif clr < air:
                viol.append(f"under a fixed {kind} of {clr} dm < air draft {air} dm ({name or 'unnamed'})")
    out["overhead_crossed"] = crossed
    out["violations"] = viol
    return out


MODES = {
    "strict": {},
    "maintained": {"use_maintained": True},
    "relaxed": {"use_maintained": True, "accept_unknown_clearance": True},
}


def run_reference(pack_path, region, routes=None, modes=("strict", "maintained", "relaxed")) -> list:
    from .places import routes_for

    pack = P.read_pack(pack_path)
    rt = Router(pack)
    ck = load_checks(region)
    routes = routes if routes is not None else routes_for(region)
    out = []
    for r in routes:
        for mode in (r.get("modes") or modes):
            prof = Profile(**{**r["profile"], **MODES[mode]})
            t0 = time.time()
            res = rt.route(tuple(r["start"]), tuple(r["end"]), prof)
            row = {"id": r["id"], "mode": mode, "desc": r["desc"], "ok": res["ok"], "error": res.get("error"),
                   "seconds": round(time.time() - t0, 2), "start": r["start"], "end": r["end"],
                   "profile": prof.__dict__ if hasattr(prof, "__dict__") else str(prof), "result": res}
            if res["ok"]:
                s = res["summary"]
                row.update({
                    "nm": round(s["distance_nm"], 2), "green": s["green_legs"], "yellow": s["yellow_legs"],
                    "reasons": sorted({x for leg in res["legs"] for x in leg["reasons"]}),
                    "openings": [o["name"] or f"unnamed {o['lat']:.3f}N" for o in s["openings"]],
                    "unknown_clearances": [o["name"] or f"unnamed {o['lat']:.3f}N" for o in s["unknown_clearances"]],
                    "shallowest_dm": s["shallowest"]["depth_dm"],
                    "lowest_clearance": s["lowest_clearance"],
                    "snap_m": [res["start"]["snap_m"], res["goal"]["snap_m"]],
                    "channel_share": round(float(np.mean((pack.attrs["flags"][res["corridor"]] & P.F_CHANNEL) > 0)), 3),
                    "maintained_legs": sum(1 for leg in res["legs"] if "MAINTAINED_DEPTH" in leg["reasons"]),
                    "outside_share": round(float(np.mean((pack.attrs["flags"][res["corridor"]] & P.F_OUTSIDE) > 0)), 3),
                })
                row["check"] = check_route(ck, res["waypoints"], prof, region.params)
                back = rt.route(tuple(r["end"]), tuple(r["start"]), prof)
                if back["ok"]:
                    row["check_reverse"] = check_route(ck, back["waypoints"], prof, region.params)
                    row["nm_reverse"] = round(back["summary"]["distance_nm"], 2)
            else:
                row["blocked"] = res.get("blocked", [])[:5]
                row["hints"] = res.get("hints")
                row["detail"] = {k: res.get(k) for k in ("start", "goal") if k in res}
            out.append(row)
            brief = {k: row.get(k) for k in ("id", "mode", "ok", "error", "nm", "green", "yellow", "seconds")}
            if "check" in row:
                brief["violations"] = row["check"]["violations"] + row.get("check_reverse", {}).get("violations", [])
            print(json.dumps(brief, default=str), flush=True)
    return out


def summarize(rows) -> dict:
    """Per route: 'strict' if the strict profile finds a route, 'maintained'
    if only maintained channels make it possible, 'relaxed' if it also needs
    unknown clearances accepted, 'failed' otherwise."""
    by = {}
    for r in rows:
        by.setdefault(r["id"], {})[r["mode"]] = r
    routes, counts = [], {"strict": 0, "maintained": 0, "relaxed": 0, "failed": 0, "check_failures": 0}
    for rid, modes in by.items():
        cls = "failed"
        for mode in ("strict", "maintained", "relaxed"):
            if mode in modes and modes[mode]["ok"]:
                cls = mode
                break
        counts[cls] += 1
        viol = []
        for mode, r in modes.items():
            for c in ("check", "check_reverse"):
                viol += [f"{mode}: {v}" for v in r.get(c, {}).get("violations", [])]
        counts["check_failures"] += bool(viol)
        first = next(iter(modes.values()))
        entry = {"id": rid, "desc": first["desc"], "class": cls, "violations": viol}
        for mode, r in modes.items():
            if r["ok"]:
                entry[mode] = {k: r.get(k) for k in ("nm", "green", "yellow", "reasons", "openings", "unknown_clearances",
                                                     "shallowest_dm", "snap_m", "channel_share", "maintained_legs",
                                                     "outside_share", "seconds")}
                entry[mode]["min_obstacle_m"] = r["check"]["min_obstacle_m"]
            else:
                b = (r.get("blocked") or [{}])[0] if r.get("blocked") else {}
                entry[mode] = {"error": r.get("error"), "first_block": b, "hints": r.get("hints"),
                               "seconds": r.get("seconds")}
        routes.append(entry)
    return {"counts": counts, "routes": routes}

