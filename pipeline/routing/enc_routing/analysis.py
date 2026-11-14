"""Effect of the sounding refinement (C.4): area made usable and the ICW gaps."""
from __future__ import annotations

import copy
import json
import math

import numpy as np

from . import packfmt as P
from .places import BOCA_GRANDE, BRADENTON_BEACH
from .router import DEG, K_M_PER_DEG, Profile, Router


def tri_area_m2(pack):
    v = pack.vertices[pack.tris].astype(np.float64) / 1e7
    lat = v[:, :, 1].mean(1)
    kx = K_M_PER_DEG * np.cos(lat * DEG)
    x = v[:, :, 0] * kx[:, None]
    y = v[:, :, 1] * K_M_PER_DEG
    return 0.5 * np.abs((x[:, 1] - x[:, 0]) * (y[:, 2] - y[:, 0]) - (x[:, 2] - x[:, 0]) * (y[:, 1] - y[:, 0]))


def refinement_report(pack_path) -> dict:
    pk = P.read_pack(pack_path)
    a = pk.attrs
    area = tri_area_m2(pk)
    d, b = a["depth_dm"].astype(int), a["band_depth_dm"].astype(int)
    ref = (a["flags"] & P.F_REFINED) > 0
    band36 = (b >= 9) & (b < 18)  # least depth in the 3-6 ft band after lowering
    rep = {"refined_triangles": int(ref.sum()), "refined_km2": round(float(area[ref].sum()) / 1e6, 2),
           "band_3_6ft_km2": round(float(area[band36].sum()) / 1e6, 1)}
    for ft in (4, 5, 6):
        req = (ft * 3048) // 1000
        gain = (d >= req) & (b < req)
        rep[f"usable_at_{ft}ft_km2"] = {
            "without_refinement": round(float(area[b >= req].sum()) / 1e6, 1),
            "with_refinement": round(float(area[d >= req].sum()) / 1e6, 1),
            "gained_km2": round(float(area[gain].sum()) / 1e6, 2),
            "gained_in_3_6ft_band_km2": round(float(area[gain & band36].sum()) / 1e6, 2)}
    # ICW gaps: inside route Bradenton Beach - Boca Grande at 4 and 5 ft, with and without refinement
    flat = copy.copy(pk)
    flat.attrs = dict(pk.attrs)
    flat.attrs["depth_dm"] = pk.attrs["band_depth_dm"]
    flat.attrs["flags"] = (pk.attrs["flags"] & ~np.uint16(P.F_REFINED)).astype(np.uint16)
    rep["icw_inside_route"] = {}
    for label, pack in (("with_refinement", pk), ("without_refinement", flat)):
        rt = Router(pack)
        for ft, (dr, mg) in ((4, (3.0, 1.0)), (5, (4.0, 1.0))):
            r = rt.route(BRADENTON_BEACH, BOCA_GRANDE, Profile(dr, mg, 9.0, accept_unknown_clearance=True,
                                                               avoid_open_gulf=True))
            rep["icw_inside_route"][f"{label}_{ft}ft"] = (
                {"ok": True, "nm": round(r["summary"]["distance_nm"], 1)} if r["ok"] else
                {"ok": False, "blocked": [(x["reason"], round(x["lat"], 4), round(x["lon"], 4), x["depth_dm"])
                                          for x in r.get("blocked", [])]})
    return rep
