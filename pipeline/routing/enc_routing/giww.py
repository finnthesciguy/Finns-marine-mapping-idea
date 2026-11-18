"""Where is the Gulf Intracoastal Waterway broken on charted depth?

The GIWW is walked as a chain of named ENC features along it (lights,
daybeacons and the waterway's own dredged areas and recommended tracks,
taken from the 2026-11-12 data like gulf_places.P). Each link is routed
inside only (avoid open Gulf) with the default boat in the strict and the
maintained mode; a link that fails strictly reports the first places that
block it (depth, clearance, prohibited area), which are the breaks.
"""
from __future__ import annotations

import json
import time

from .gulf_places import BOAT, P

# Extra GIWW points: (S-57 class, lon, lat). Recommended-track and dredged-area
# points are a point on the feature (its representative point).
G = {
    "GIWW - Corpus Christi Ship Channel to Mile 547 ROQ": ("DRGARE", -97.21815, 27.72254),
    "Colorado River - Mile 0 (GIWW) to Mile 2 LOQ": ("DRGARE", -95.97883, 28.69529),
    "GIWW (RECTRC) near 90.05 W": ("RECTRC", -90.04539, 29.83540),
    "GIWW (RECTRC) near 90.41 W": ("RECTRC", -90.40818, 29.55114),
    "GIWW (RECTRC) near 90.78 W": ("RECTRC", -90.78462, 29.53563),
    "GIWW (RECTRC) near 91.14 W": ("RECTRC", -91.14045, 29.67721),
    "GIWW - Bon Secour Channel - Reach 1": ("DRGARE", -87.97707, 30.26104),
    "GIWW - Santa Rosa Sound 1 - Reach 1": ("DRGARE", -87.11950, 30.35595),
    "West Bay 2 (GIWW)": ("DRGARE", -85.84344, 30.28134),
}

CHAIN = {
    "ncds_10": ["Fort Myers Yacht Basin Breakwater West Light", "Boca Grande Yacht Basin Channel Daybeacon 2",
                "Venice Inlet - Siesta Key Daybeacon 19", "Gulfport Channel Daybeacon 3",
                "Clearwater Harbor Daybeacon 13", "Anclote Anchorage North Entrance Light 7"],
    "ncds_11": ["Carrabelle River Daybeacon 15", "Apalachicola Bay Daybeacon 66", "West Bay 2 (GIWW)",
                "Old East Pass Harbor Channel Light 13", "GIWW - Santa Rosa Sound 1 - Reach 1",
                "Pensacola Mobile Sherman Cove Marina Daybeacon 1", "Homeport Marina",
                "GIWW - Bon Secour Channel - Reach 1", "Mobile Channel Light 41", "Pascagoula Channel Light 43",
                "Back Bay of Biloxi Daybeacon 10", "Gulfport Harbor Light House"],
    "ncds_12": ["Gulfport Harbor Light House", "City of Bay Saint Louis Municipal Pier Light 1", "The Rigolets Light 3",
                "Inner Harbor Navigation Canal Light 2", "GIWW (RECTRC) near 90.05 W", "GIWW (RECTRC) near 90.41 W",
                "GIWW (RECTRC) near 90.78 W", "GIWW (RECTRC) near 91.14 W",
                "Morgan City-Port Allen Alternate Route Daybeacon 10", "Freshwater Bayou Junction Light FW"],
    "ncds_14": ["Freshwater Bayou Junction Light FW", "Calcasieu Channel Light 47", "Port Arthur Canal Light 46",
                "Galveston Channel Light 2", "Freeport Harbor Light 18", "Colorado River - Mile 0 (GIWW) to Mile 2 LOQ",
                "Matagorda Ship Channel Light 21", "Rockport Channel Light 1", "Port Aransas Harbor Light 3",
                "GIWW - Corpus Christi Ship Channel to Mile 547 ROQ", "Port Mansfield Channel Daybeacon 15",
                "Brazos Santiago Pass Entrance Lighted Buoy BS"],
}


def point(name):
    return (P.get(name) or G[name])[1:]


def run_giww(pack_path, region, log=print) -> list:
    from . import packfmt
    from .router import Profile, Router

    rt = Router(packfmt.read_pack(pack_path))
    out = []
    chain = CHAIN.get(region.rid, [])
    for a, b in zip(chain[:-1], chain[1:]):
        row = {"from": a, "to": b}
        for mode, extra in (("strict", {}), ("maintained", {"use_maintained": True})):
            prof = Profile(**dict(BOAT, avoid_open_gulf=True, **extra))
            t0 = time.time()
            res = rt.route(point(a), point(b), prof)
            r = {"ok": res["ok"], "error": res.get("error"), "seconds": round(time.time() - t0, 2)}
            if res["ok"]:
                s = res["summary"]
                r.update(nm=round(s["distance_nm"], 1),
                         maintained_legs=sum(1 for leg in res["legs"] if "MAINTAINED_DEPTH" in leg["reasons"]),
                         shallowest_dm=s["shallowest"]["depth_dm"])
            else:
                r["blocked"] = [{k: x.get(k) for k in ("reason", "lon", "lat", "depth_dm", "maint_dm", "clearance_dm",
                                                       "overhead", "area")} for x in (res.get("blocked") or [])[:4]]
                r["hints"] = res.get("hints")
            row[mode] = r
        out.append(row)
        log(json.dumps({"from": a, "to": b, "strict": row["strict"]["ok"], "maintained": row["maintained"]["ok"],
                        "first_block": (row["strict"].get("blocked") or [None])[0]}, default=str))
    return out
