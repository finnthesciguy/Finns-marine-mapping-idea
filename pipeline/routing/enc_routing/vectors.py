"""Cut-down packs, decoded-record dumps and expected-result vectors for the
Swift port (testdata/routing/, schema in docs/routing-pack-format.md part D)."""
from __future__ import annotations

import hashlib
import json
from pathlib import Path

import numpy as np

from . import packfmt as P
from .router import Profile, Router

UNITS = 10_000_000


# --------------------------------------------------------------------------- cut

def cut_pack(pack: P.Pack, bbox_deg, region_id: str) -> P.Pack:
    """Triangles whose centroid lies in bbox, with side tables restricted to
    records whose representative point lies in bbox (references remapped)."""
    b = [int(round(v * UNITS)) for v in bbox_deg]
    c = pack.vertices[pack.tris].astype(np.int64).sum(1) // 3
    keep = (c[:, 0] >= b[0]) & (c[:, 0] <= b[2]) & (c[:, 1] >= b[1]) & (c[:, 1] <= b[3])
    tris = pack.tris[keep]
    used = np.unique(tris)
    remap = -np.ones(len(pack.vertices), np.int64)
    remap[used] = np.arange(len(used))
    verts = pack.vertices[used]
    tris = remap[tris]
    attrs = {k: np.asarray(v)[keep] for k, v in pack.attrs.items()}
    V, T, perm = P.canonicalize(verts, tris)
    attrs = {k: v[perm] for k, v in attrs.items()}
    strings = [""]
    sidx = {"": 0}

    def S(old):
        s = pack.string(int(old))
        if s not in sidx:
            sidx[s] = len(strings)
            strings.append(s)
        return sidx[s]
    geom = []

    def table(recs, ref_col, with_geom, str_cols):
        inb = (recs["lon"] >= b[0]) & (recs["lon"] <= b[2]) & (recs["lat"] >= b[1]) & (recs["lat"] <= b[3])
        # keep records referenced by kept triangles too
        idmap = {}
        if ref_col is not None:
            ref = set(int(x) for x in attrs[ref_col] if x != P.ID_NONE)
            inb = inb | np.isin(np.arange(len(recs)), list(ref))
        out = recs[inb].copy()
        for new, old in enumerate(np.flatnonzero(inb)):
            idmap[int(old)] = new
        for r in out:
            for col in str_cols:
                r[col] = S(r[col])
            if with_geom:
                g = pack.geom[r["geom_first"]: r["geom_first"] + r["geom_count"]]
                r["geom_first"] = len(geom)
                geom.extend(g.tolist())
        if ref_col is not None:
            attrs[ref_col] = np.array([idmap.get(int(x), P.ID_NONE) if x != P.ID_NONE else P.ID_NONE
                                       for x in attrs[ref_col]])
        return out
    ovh = table(pack.overhead, "overhead", True, ["name"])
    hzd = table(pack.hazards, None, True, ["name"])
    chn = table(pack.channels, "channel", False, ["name", "ident", "desc"])
    ars = table(pack.areas, "area", False, ["name", "text"])
    src = pack.sources.copy()
    for r in src:
        r["name"] = S(r["name"])
    # the header bbox holds every vertex and every GEOM point (spec A.3)
    pts = np.vstack([V, np.array(geom, np.int64).reshape(-1, 2)]) if geom else V
    vmin, vmax = pts.min(0), pts.max(0)
    bbox = (min(b[0], int(vmin[0])), min(b[1], int(vmin[1])), max(b[2], int(vmax[0])), max(b[3], int(vmax[1])))
    nbr, dup = P.adjacency(T)
    assert dup == 0
    grid = P.build_grid(V, T, bbox, pack.grid["cell"])
    info = dict(pack.info)
    info["cut_from"] = pack.region_id
    info["cut_bbox"] = ",".join(str(v) for v in bbox_deg)
    return P.Pack(region_id=region_id, bbox=bbox, data_date=pack.data_date, build_date=pack.build_date,
                  build_time=pack.build_time, clearance_dm=pack.clearance_dm, check_dm=pack.check_dm,
                  shore_rings_m=pack.shore_rings_m, vertices=V, tris=T, attrs=attrs, strings=strings,
                  overhead=ovh, hazards=hzd, channels=chn, areas=ars, sources=src,
                  geom=np.array(geom, np.int32).reshape(-1, 2), info=info, nbr=nbr, grid=grid)


def clip_source_geometry(region, wkb_path, bbox_deg, margin_deg=0.01) -> bytes:
    """Source geometry (region metric CRS WKB) clipped to bbox, as EPSG:4326 WKB
    with coordinates rounded to 1e-7 degree."""
    import shapely
    from pyproj import Transformer

    g = shapely.from_wkb(Path(wkb_path).read_bytes())
    tr = Transformer.from_crs(region.crs, "EPSG:4326", always_xy=True)
    inv = Transformer.from_crs("EPSG:4326", region.crs, always_xy=True)
    b = (bbox_deg[0] - margin_deg, bbox_deg[1] - margin_deg, bbox_deg[2] + margin_deg, bbox_deg[3] + margin_deg)
    clip = shapely.transform(shapely.segmentize(shapely.box(*b), 0.001),
                             lambda xy: np.column_stack(inv.transform(xy[:, 0], xy[:, 1])))
    g = g.intersection(clip)
    g = shapely.transform(g, lambda xy: np.round(np.column_stack(tr.transform(xy[:, 0], xy[:, 1])), 7))
    return shapely.to_wkb(g)


# --------------------------------------------------------------------------- record dump

def _rec(r):
    out = {}
    for name in r.dtype.names:
        if name.startswith("pad") or name.startswith("reserved"):
            continue
        v = r[name]
        out[name] = v.tolist() if hasattr(v, "tolist") else v
    return out


def dump_records(path) -> dict:
    p = P.read_pack(path)
    h = dict(p.header)
    h.pop("magic")
    T = len(p.tris)
    pick_t = sorted(set([0, 1, 2, T // 2, T - 1]))
    pick_v = sorted(set([0, 1, 2, len(p.vertices) // 2, len(p.vertices) - 1]))
    g = p.grid
    nonempty = np.flatnonzero(np.diff(g["offsets"]) > 0)
    pick_c = sorted(set([0, int(nonempty[0]), int(nonempty[len(nonempty) // 2]), g["nx"] * g["ny"] - 1]))

    def side(recs, n=3):
        out = []
        for i in sorted(set([0, 1, len(recs) - 1])):
            if 0 <= i < len(recs):
                d = _rec(recs[i])
                d["index"] = i
                if "geom_first" in d:
                    d["geom"] = p.geom[d["geom_first"]: d["geom_first"] + d["geom_count"]].tolist()
                out.append(d)
        return out
    return {
        "file": Path(path).name,
        "sha256": hashlib.sha256(Path(path).read_bytes()).hexdigest(),
        "header": h,
        "sections": p.sections,
        "info": p.info,
        "strings": {"count": len(p.strings), "first": {i: s for i, s in enumerate(p.strings[:8])}},
        "vertices": [{"index": i, "lon": int(p.vertices[i, 0]), "lat": int(p.vertices[i, 1])} for i in pick_v],
        "triangles": [{"index": t, "v": p.tris[t].tolist(), "nbr": p.nbr[t].tolist(),
                       **{k: int(p.attrs[k][t]) for k, _ in P.ATTR_COLUMNS}} for t in pick_t],
        "grid": {"origin_lon": g["origin_lon"], "origin_lat": g["origin_lat"], "cell": g["cell"],
                 "nx": g["nx"], "ny": g["ny"], "total_ids": int(len(g["ids"])),
                 "cells": [{"cell": c, "ids": g["ids"][g["offsets"][c]: g["offsets"][c + 1]].tolist()}
                           for c in pick_c]},
        "sources": side(p.sources), "overhead": side(p.overhead), "hazards": side(p.hazards),
        "channels": side(p.channels), "areas": side(p.areas),
    }


# --------------------------------------------------------------------------- expected results

EXPECTED_KEYS = ["ok", "error", "req_dm", "air_dm", "start", "goal", "corridor", "waypoints_units",
                 "waypoints", "legs", "summary", "reason", "blocked", "hints", "violations", "data_date"]


def expected(res) -> dict:
    out = {k: res[k] for k in EXPECTED_KEYS if k in res}
    if "legs" in out:
        out["distance_m"] = out["summary"]["distance_m"]
    return out


def make_vectors(pack_path, queries, out_json):
    pack = P.read_pack(pack_path)
    rt = Router(pack)
    items = []
    for q in queries:
        prof = Profile(**q["profile"])
        res = rt.route(tuple(q["start"]), tuple(q["goal"]), prof, q.get("max_snap_m", 750.0))
        items.append({**q, "max_snap_m": q.get("max_snap_m", 750.0), "expected": expected(res)})
    doc = {
        "schema": "routing-vectors/1",
        "pack": Path(pack_path).name,
        "pack_sha256": hashlib.sha256(Path(pack_path).read_bytes()).hexdigest(),
        "tolerances": {"waypoints_units": 0, "distance_m": 1e-6, "snap_m": 1e-3,
                       "note": "integer fields and sequences must match exactly; floats within tolerance"},
        "queries": items,
    }
    Path(out_json).write_text(json.dumps(doc, indent=1, default=_np))
    return doc


def _np(o):
    if isinstance(o, (np.integer,)):
        return int(o)
    if isinstance(o, (np.floating,)):
        return float(o)
    if isinstance(o, np.ndarray):
        return o.tolist()
    if isinstance(o, (bytes,)):
        return o.decode()
    raise TypeError(type(o))


SYNTH_QUERIES = [
    {"id": "s1_shoal_blocks", "start": [-81.9995, 27.0015], "goal": [-81.9925, 27.0015],
     "profile": {"draft_ft": 4, "margin_ft": 1, "air_draft_ft": 20},
     "note": "channel shoaled to 9 dm at col 3; detour north blocked by the unknown-clearance cable: NO_ROUTE, hint use_maintained"},
    {"id": "s2_maintained", "start": [-81.9995, 27.0015], "goal": [-81.9925, 27.0015],
     "profile": {"draft_ft": 4, "margin_ft": 1, "air_draft_ft": 20, "use_maintained": True},
     "note": "straight along the channel: maintained depth + bridge opening (closed 18 dm < 61 dm)"},
    {"id": "s3_unknown_detour", "start": [-81.9995, 27.0015], "goal": [-81.9925, 27.0015],
     "profile": {"draft_ft": 4, "margin_ft": 1, "air_draft_ft": 8, "accept_unknown_clearance": True},
     "note": "under the cable, around the shoal, under the 30 dm fixed bridge (air 24 dm), through the restricted square"},
    {"id": "s4_too_deep", "start": [-81.9995, 27.0015], "goal": [-81.9925, 27.0015],
     "profile": {"draft_ft": 12, "margin_ft": 1, "air_draft_ft": 20},
     "note": "13 ft needs 39 dm: only row 3 (60 dm) is deep enough"},
    {"id": "s5_low_air_north", "start": [-81.9995, 27.0035], "goal": [-81.9935, 27.0035],
     "profile": {"draft_ft": 5, "margin_ft": 1, "air_draft_ft": 9, "accept_unknown_clearance": True},
     "note": "row 3 west to east: cable (yellow), fixed bridge 30 dm >= 27 dm, then prohibited col 6 forces a detour south"},
    {"id": "s6_outside_pack", "start": [-82.0100, 27.0015], "goal": [-81.9925, 27.0015],
     "profile": {"draft_ft": 4, "margin_ft": 1, "air_draft_ft": 20}, "note": "start west of the pack bbox"},
    {"id": "s7_island_snap", "start": [-81.9975, 27.0005], "goal": [-81.9985, 27.0025],
     "profile": {"draft_ft": 1, "margin_ft": 0.5, "air_draft_ft": 5}, "max_snap_m": 200,
     "note": "start inside the missing square (island): snapped to the nearest passable triangle"},
    {"id": "s8_shallow_quality", "start": [-81.9995, 27.0005], "goal": [-81.9935, 27.0005],
     "profile": {"draft_ft": 1, "margin_ft": 0.5, "air_draft_ft": 5},
     "note": "row 0 (6 dm, CATZOC D, caution square), detours round the island"},
    {"id": "s9_sounding", "start": [-81.9935, 27.0025], "goal": [-81.9925, 27.0025],
     "profile": {"draft_ft": 5, "margin_ft": 1, "air_draft_ft": 5},
     "note": "goal in the sounding-refined square (band 9, refined 21 dm)"},
    {"id": "s10_overhead_point", "start": [-81.9995, 27.0025], "goal": [-81.9945, 27.0025],
     "profile": {"draft_ft": 1, "margin_ft": 0.5, "air_draft_ft": 5},
     "note": "a leg along the row 1/row 2 boundary passes 0.44 m from the overhead point object (OVHD 3), "
             "outside the leg's bounding box: it is listed as a crossing; the cable and bridge line ends it "
             "touches are not"},
    {"id": "s11_start_is_goal", "start": [-81.9995, 27.0015], "goal": [-81.9995, 27.0015],
     "profile": {"draft_ft": 4, "margin_ft": 1, "air_draft_ft": 20},
     "note": "start equal to goal: a route with one waypoint and no legs"},
    {"id": "s12_invalid_profile", "start": [-81.9995, 27.0015], "goal": [-81.9925, 27.0015],
     "profile": {"draft_ft": -1, "margin_ft": 1, "air_draft_ft": 20}, "note": "negative draft: INVALID_REQUEST"},
    {"id": "s13_goal_out_of_range", "start": [-81.9995, 27.0015], "goal": [-81.9925, 95.0],
     "profile": {"draft_ft": 4, "margin_ft": 1, "air_draft_ft": 20},
     "note": "latitude 95: GOAL_OUTSIDE_PACK, with the snapped start"},
]

SARASOTA_QUERIES = [
    {"id": "q1_longboat_to_marinajack", "start": [-82.6030, 27.4030], "goal": [-82.5465, 27.3330],
     "profile": {"draft_ft": 4.5, "margin_ft": 1.5, "air_draft_ft": 20}},
    {"id": "q2_same_4ft", "start": [-82.6030, 27.4030], "goal": [-82.5465, 27.3330],
     "profile": {"draft_ft": 3, "margin_ft": 1, "air_draft_ft": 20}},
    {"id": "q3_marinajack_to_roberts_relaxed", "start": [-82.5465, 27.3330], "goal": [-82.5390, 27.2620],
     "profile": {"draft_ft": 4.5, "margin_ft": 1.5, "air_draft_ft": 20, "use_maintained": True,
                 "accept_unknown_clearance": True, "avoid_open_gulf": True},
     "note": "ICW through the Roberts Bay gaps on USACE maintained depth (yellow)"},
    {"id": "q4_same_strict", "start": [-82.5465, 27.3330], "goal": [-82.5390, 27.2620],
     "profile": {"draft_ft": 4.5, "margin_ft": 1.5, "air_draft_ft": 20, "avoid_open_gulf": True},
     "note": "charted depth only: NO_ROUTE at the Roberts Bay gap"},
    {"id": "q8_stickney_opening", "start": [-82.5465, 27.3330], "goal": [-82.5330, 27.2500],
     "profile": {"draft_ft": 4.5, "margin_ft": 1.5, "air_draft_ft": 20, "use_maintained": True,
                 "avoid_open_gulf": True},
     "note": "continues through Stickney Point bridge (closed 18 ft < 20 ft air draft): BRIDGE_OPENING"},
    {"id": "q5_ringling_66ft", "start": [-82.6000, 27.3800], "goal": [-82.5450, 27.3000],
     "profile": {"draft_ft": 4.5, "margin_ft": 1.5, "air_draft_ft": 66, "use_maintained": True}},
    {"id": "q6_on_land", "start": [-82.5300, 27.3400], "goal": [-82.5465, 27.3330],
     "profile": {"draft_ft": 4.5, "margin_ft": 1.5, "air_draft_ft": 20}},
    {"id": "q7_15ft", "start": [-82.6000, 27.3800], "goal": [-82.5465, 27.3330],
     "profile": {"draft_ft": 15, "margin_ft": 1.5, "air_draft_ft": 20}},
    {"id": "q9_not_connected", "start": [-82.5454965, 27.3326002], "goal": [-82.6030, 27.4030],
     "profile": {"draft_ft": 4.5, "margin_ft": 1.5, "air_draft_ft": 20},
     "note": "start in a small water part near Marina Jack that the mesh does not connect to the bay: "
             "NOT_CONNECTED, every hint false"},
]
