"""Hand-checkable synthetic routing pack for the test vectors.

An 8 x 4 grid of 0.001 degree squares (about 99 m east-west, 111 m
north-south) at lon -82.000 .. -81.992, lat 27.000 .. 27.004, each square
split into two triangles along its SW-NE diagonal, with square (col 2,
row 0) missing (an "island"). Columns run west to east (0..7), rows south
to north (0..3).

  row 3  deep 60 dm      | col 2 cable, unknown clearance (rows 2-3) | col 5 fixed bridge 30 dm (rows 2-3) | col 6 PROHIBITED
  row 2  open 21 dm      | col 4 known-depth hazard zone 15 dm       | col 6 RESTRICTED | col 7 band 9 dm refined to 21 dm
  row 1  channel 36 dm   (HIGHWAY, NCF maintained 27 dm), col 3 shoaled to 9 dm, col 5 opening bridge closed 18 dm
  row 0  shallow 6 dm, CATZOC D | col 1 CAUTION | col 2 missing (island)

All other quality bytes: CATZOC A2, survey 2010.
"""
from __future__ import annotations

import numpy as np

from . import packfmt as P
from .layers import quality_byte

LON0, LAT0, STEP = -820000000, 270000000, 10000  # units (1e-7 deg)
NX, NY = 8, 4
MISSING = {(2, 0)}


def square_values(c, r):
    d = dict(depth=21, band=21, maint=P.DEPTH_NONE, clr=P.CLR_NONE, flags=0, channel=P.ID_NONE,
             overhead=P.ID_NONE, area=P.ID_NONE, q=quality_byte(2, 2010), shore=3)
    if r == 3:
        d.update(depth=60, band=60)
    if r == 1:
        d.update(depth=36, band=36, maint=27, flags=P.F_CHANNEL | P.F_HIGHWAY, channel=0)
        if c == 3:
            d.update(depth=9, band=9)
    if r == 0:
        d.update(depth=6, band=6, q=quality_byte(5, 1950), shore=0)
        if c == 1:
            d["flags"] |= P.F_CAUTION
            d["area"] = 2
    if c == 2 and r in (2, 3):
        d.update(clr=P.CLR_UNKNOWN, overhead=2)
        d["flags"] |= P.F_UNKNOWN_CLR
    if c == 5 and r in (2, 3):
        d.update(clr=30, overhead=1)
    if c == 5 and r == 1:
        d.update(clr=18, overhead=0)
        d["flags"] |= P.F_OPENING
    if c == 4 and r == 2:
        d.update(depth=15, band=15)
        d["flags"] |= P.F_HAZARD_DEPTH | P.F_NEAR_HAZARD
    if c == 6 and r == 2:
        d["flags"] |= P.F_RESTRICTED
        d["area"] = 1
    if c == 6 and r == 3:
        d["flags"] |= P.F_PROHIBITED
        d["area"] = 0
    if c == 7 and r == 2:
        d.update(depth=21, band=9)
        d["flags"] |= P.F_REFINED
    d["flags"] |= d.pop("shore") << P.SHORE_SHIFT
    return d


def build_synthetic() -> P.Pack:
    vid = {}
    verts = []
    for r in range(NY + 1):
        for c in range(NX + 1):
            vid[(c, r)] = len(verts)
            verts.append((LON0 + c * STEP, LAT0 + r * STEP))
    tris, vals = [], []
    for r in range(NY):
        for c in range(NX):
            if (c, r) in MISSING:
                continue
            sw, se, ne, nw = vid[(c, r)], vid[(c + 1, r)], vid[(c + 1, r + 1)], vid[(c, r + 1)]
            v = square_values(c, r)
            tris += [(sw, se, ne), (sw, ne, nw)]
            vals += [v, v]
    verts = np.array(verts, np.int64)
    tris = np.array(tris, np.int64)
    V, T, perm = P.canonicalize(verts, tris)
    vals = [vals[i] for i in perm]
    attrs = {
        "depth_dm": np.array([v["depth"] for v in vals]), "band_depth_dm": np.array([v["band"] for v in vals]),
        "maint_dm": np.array([v["maint"] for v in vals]), "clearance_dm": np.array([v["clr"] for v in vals]),
        "flags": np.array([v["flags"] for v in vals]), "channel": np.array([v["channel"] for v in vals]),
        "overhead": np.array([v["overhead"] for v in vals]), "area": np.array([v["area"] for v in vals]),
        "quality": np.array([v["q"] for v in vals]),
    }
    strings = ["", "Test Opening Bridge", "Test Fixed Bridge", "Test Cable", "Test Wreck",
               "Test Channel", "CUT-1", "Approach Cut", "Prohibited Zone", "Restricted Zone",
               "Caution Zone", "Shoal reported", "US5TEST1"]
    sid = {s: i for i, s in enumerate(strings)}

    def pt(c, r):  # units of a grid node
        return LON0 + c * STEP, LAT0 + r * STEP
    geom = []

    def add(points):
        first = len(geom)
        geom.extend(points)
        return first, len(points)
    # overhead 0: opening bridge, a N-S line across col 5 row 1 at lon of col 5.5
    x55 = LON0 + 5 * STEP + STEP // 2
    g0 = add([(x55, LAT0 + 1 * STEP), (x55, LAT0 + 2 * STEP)])
    g1 = add([(x55, LAT0 + 2 * STEP), (x55, LAT0 + 4 * STEP)])
    x25 = LON0 + 2 * STEP + STEP // 2
    g2 = add([(x25, LAT0 + 2 * STEP), (x25, LAT0 + 4 * STEP)])
    ovh = np.array([
        (1, 1, 1 << 4, 18, P.CLR_UNKNOWN, 274, 0, sid["Test Opening Bridge"], x55, LAT0 + 15000, *g0, 2, (0,) * 7),
        (1, 0, 1 << 0, 30, P.CLR_UNKNOWN, P.CLR_UNKNOWN, 0, sid["Test Fixed Bridge"], x55, LAT0 + 30000, *g1, 2, (0,) * 7),
        (2, 0, 0, P.CLR_UNKNOWN, P.CLR_UNKNOWN, P.CLR_UNKNOWN, 0, sid["Test Cable"], x25, LAT0 + 30000, *g2, 2, (0,) * 7),
    ], dtype=P.OVHD_DT)
    hx, hy = pt(4, 2)
    g3 = add([(hx + STEP // 2, hy + STEP // 2)])
    hz = np.array([(2, 3, 0, 1, 15, 0, hx + STEP // 2, hy + STEP // 2, *g3, sid["Test Wreck"], 0)], dtype=P.HAZD_DT)
    ch = np.array([(1, 1, 27, 27, 0, sid["Test Channel"], sid["CUT-1"], sid["Approach Cut"], 20260101,
                    LON0 + 40000, LAT0 + 15000)], dtype=P.CHAN_DT)
    ar = np.array([(1, 1, 0, sid["Prohibited Zone"], 0, LON0 + 65000, LAT0 + 35000, (0, 0, 0)),
                   (2, 1, 0, sid["Restricted Zone"], 0, LON0 + 65000, LAT0 + 25000, (0, 0, 0)),
                   (3, 2, 0, sid["Caution Zone"], sid["Shoal reported"], LON0 + 15000, LAT0 + 5000, (0, 0, 0))],
                  dtype=P.AREA_DT)
    src = np.array([(sid["US5TEST1"], 3, 1, 20261101, 12000, 5, 1, (0,) * 6)], dtype=P.SRCS_DT)
    bbox = (LON0, LAT0, LON0 + NX * STEP, LAT0 + NY * STEP)
    nbr, dup = P.adjacency(T)
    assert dup == 0
    grid = P.build_grid(V, T, bbox, 20000)  # 0.002 degree cells: 4 x 2
    return P.Pack(region_id="synthetic", bbox=bbox, data_date=20261101, build_date=20261112, build_time=120000,
                  clearance_dm=120, check_dm=110, shore_rings_m=(50, 150), vertices=V, tris=T, attrs=attrs,
                  strings=strings, overhead=ovh, hazards=hz, channels=ch, areas=ar, sources=src,
                  geom=np.array(geom, np.int32), info={"builder": "enc_routing synth", "note": "synthetic test pack"},
                  nbr=nbr, grid=grid)
