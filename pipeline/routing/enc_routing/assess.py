"""Run the reference routes on a pack and check them against the SOURCE
data (raw land, structures and blocking hazards from the build), which the
router itself never sees."""
from __future__ import annotations

import json
import time

import numpy as np
import shapely
from pyproj import Transformer

from . import packfmt as P
from .config import GEO_CRS
from .places import ROUTES
from .router import Profile, Router


def route_line_metric(res, crs):
    tr = Transformer.from_crs(GEO_CRS, crs, always_xy=True)
    w = np.array(res["waypoints"])
    x, y = tr.transform(w[:, 0], w[:, 1])
    return shapely.LineString(np.column_stack([x, y]))


def run_reference(pack_path, region, routes=ROUTES) -> list:
    pack = P.read_pack(pack_path)
    rt = Router(pack)
    obst = shapely.from_wkb(region.dir("obstacles.wkb").read_bytes())
    zone = shapely.from_wkb(region.dir("bridge_zone.wkb").read_bytes())
    fend = shapely.from_wkb(region.dir("fenders.wkb").read_bytes())
    shapely.prepare(obst)
    out = []
    for r in routes:
        prof = Profile(**r["profile"])
        t0 = time.time()
        res = rt.route(r["start"], r["end"], prof)
        sec = time.time() - t0
        row = {"id": r["id"], "desc": r["desc"], "ok": res["ok"], "error": res.get("error"),
               "seconds": round(sec, 2), "expect": r["expect"], "result": res}
        if res["ok"]:
            line = route_line_metric(res, region.crs)
            s = res["summary"]
            row.update({
                "nm": round(s["distance_nm"], 2), "green": s["green_legs"], "yellow": s["yellow_legs"],
                "reasons": sorted({x for l in res["legs"] for x in l["reasons"]}),
                "min_obstacle_m": round(float(obst.distance(line)), 1),
                "min_obstacle_outside_bridge_zones_m": round(float(obst.distance(line.difference(zone))), 1)
                if not line.difference(zone).is_empty else None,
                "min_fender_m": round(float(fend.distance(line)), 1) if not fend.is_empty else None,
                "touches_obstacle": bool(obst.intersects(line) or fend.intersects(line)),
                "openings": [o["name"] or f"unnamed {o['lat']:.3f}N" for o in s["openings"]],
                "unknown_clearances": [o["name"] or f"unnamed {o['lat']:.3f}N" for o in s["unknown_clearances"]],
                "shallowest_dm": s["shallowest"]["depth_dm"],
                "lowest_clearance": s["lowest_clearance"],
                "snap_m": [res["start"]["snap_m"], res["goal"]["snap_m"]],
                "channel_share": round(float(np.mean((pack.attrs["flags"][res["corridor"]] & P.F_CHANNEL) > 0)), 3),
            })
        else:
            row["blocked"] = res.get("blocked", [])[:5]
            row["hints"] = res.get("hints")
            row["detail"] = {k: res.get(k) for k in ("start", "goal") if k in res}
        out.append(row)
        print(json.dumps({k: v for k, v in row.items() if k not in ("result", "desc")}, default=str)[:700], flush=True)
    return out
