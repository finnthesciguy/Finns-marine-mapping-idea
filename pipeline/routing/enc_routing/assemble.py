"""Join the tiles of a region into one routing pack.

1. Vertices of all tiles are merged by exact integer coordinates; tiles
   meet on straight tile edges, and where the two sides of an edge carry
   different vertices the triangles are split there (exact T-junction
   repair). The whole mesh must then pass topology.validate, including the
   exact area check (sum of the tiles' face areas), or the build fails.
2. Side tables (OVHD, HAZD, CHAN, AREA) are built from the full merged
   features named by the tiles' feature keys, sorted by key, and the
   per-triangle references are remapped to them.
3. Canonical order (packfmt.canonicalize), adjacency, point index, header.

The output depends only on the tiles' contents (in tile-id order), the
region's cells and the build timestamp, so the same inputs give the same
bytes whatever order the tiles were built in.
"""
from __future__ import annotations

import datetime as dt
import json
import time

import numpy as np
import pandas as pd
import shapely

from . import layers as L
from . import packfmt as P
from . import topology
from .config import BUILDER_VERSION, UNITS

LIMIT_U16 = 0xFFFF  # side-table references are u16 with 0xFFFF = none (format A.5)


class FormatLimit(RuntimeError):
    """The region needs more side-table records than the pack format can address."""


def _remap(local_idx, keys_local, index_of):
    out = np.full(len(local_idx), P.ID_NONE, np.int64)
    if len(local_idx) == 0:
        return out
    lut = np.array([index_of[k] for k in keys_local] + [P.ID_NONE], np.int64) if keys_local else \
        np.array([P.ID_NONE], np.int64)
    li = np.asarray(local_idx, np.int64)
    li = np.where(li == P.ID_NONE, len(lut) - 1, li)
    return lut[li]


def _subset(source, layers, keys):
    keys = set(keys)
    out = {}
    for layer in layers:
        g = source.frames.get(layer)
        if g is None:
            continue
        g = g[g.fkey.isin(keys)]
        if len(g):
            out[layer] = g.reset_index(drop=True)
    return out


def _rep_units(q):
    return np.rint(shapely.get_coordinates(shapely.point_on_surface(q))[0] * UNITS).astype(np.int64)


def _gtype_coords_units(q):
    if q.geom_type == "Point":
        return 1, shapely.get_coordinates(q)
    if q.geom_type in ("LineString", "LinearRing"):
        return 2, shapely.get_coordinates(q)
    if q.geom_type == "Polygon":
        return 3, shapely.get_coordinates(q.exterior)[:-1]
    raise ValueError(q.geom_type)


class SideTables:
    def __init__(self):
        self.S = Strings()
        self.pool = []
        self.npool = 0

    def add_geom(self, q):
        gt, c = _gtype_coords_units(q)
        c = np.rint(c * UNITS).astype(np.int64)
        if gt == 2 and len(c) >= 2:
            keep = np.ones(len(c), bool)
            keep[1:] = np.any(c[1:] != c[:-1], axis=1)
            c = c[keep]
            if len(c) < 2:
                gt, c = 1, c[:1]
        if gt == 3:
            keep = np.ones(len(c), bool)
            keep[1:] = np.any(c[1:] != c[:-1], axis=1)
            c = c[keep]
            if len(c) >= 2 and (c[0] == c[-1]).all():
                c = c[:-1]
            if len(c) < 3:
                gt, c = (2, c) if len(c) == 2 else (1, c[:1])
        first = self.npool
        self.pool.append(c)
        self.npool += len(c)
        return gt, first, len(c), _rep_units(q)

    def geom(self):
        return np.concatenate(self.pool).astype(np.int32) if self.pool else np.zeros((0, 2), np.int32)


class Strings:
    def __init__(self):
        self.items = [""]
        self.index = {"": 0}

    def __call__(self, s) -> int:
        s = "" if s is None or (isinstance(s, float) and np.isnan(s)) else str(s).strip()
        if s not in self.index:
            self.index[s] = len(self.items)
            self.items.append(s)
        return self.index[s]


def overhead_table(source, keys, st: SideTables):
    over = L.overhead(_subset(source, ["BRIDGE", "CBLOHD", "PIPOHD"], keys), None)
    recs, first_of = [], {}
    for row in over.itertuples():
        first_of[row.fkey] = len(recs)
        for q in shapely.get_parts(row.geometry):
            if q.is_empty:
                continue
            gt, first, cnt, rp = st.add_geom(q)
            clr = row.clr_dm
            fl = 1 if row.opens else 0
            if row.kind == 1 and not row.opens and clr == -32768:
                clr, fl = 0, fl | 2  # not charted: treated as solid
            recs.append((row.kind, fl, row.catbrg, P.CLR_UNKNOWN if clr == -32768 else clr,
                         P.CLR_UNKNOWN if row.open_dm == -32768 else row.open_dm,
                         P.CLR_UNKNOWN if row.hor_dm == -32768 else row.hor_dm, 0,
                         st.S(row.OBJNAM), rp[0], rp[1], first, cnt, gt, (0,) * 7))
    return np.array(recs, dtype=P.OVHD_DT), first_of


def hazard_table(source, keys, st: SideTables):
    haz = L.hazards(_subset(source, ["OBSTRN", "WRECKS", "UWTROC"], keys))
    haz = haz.sort_values("fkey", kind="stable") if len(haz) else haz
    recs = []
    for row in haz.itertuples():
        for q in shapely.get_parts(row.geometry):
            if q.is_empty:
                continue
            gt, first, cnt, rp = st.add_geom(q)
            recs.append((row.cls, min(255, max(0, row.WATLEV)), min(255, max(0, row.cat)), gt,
                         row.valsou_dm, 0, rp[0], rp[1], first, cnt, st.S(row.OBJNAM), 0))
    return np.array(recs, dtype=P.HAZD_DT)


def channel_table(source, keys, st: SideTables):
    keys = sorted(set(keys))
    rows = {}
    reach = source.ncf.get("reach")
    if reach is not None and len(reach):
        for r in reach[reach.fkey.isin(keys)].itertuples():
            nm = r.name_clean
            rows[r.fkey] = (1, L.is_icw(nm), nm.title() if nm else "", str(r.ident or ""), str(r.desc or "").title(),
                            int(L.ft_to_chart_dm([r.depthmaintained])[0]), int(L.ft_to_chart_dm([r.depthauthorized])[0]),
                            int(r.date or 0), r.geometry)
    sub = _subset(source, ["FAIRWY", "DRGARE", "RECTRC", "NAVLNE"], keys)
    for src, layer in ((2, "FAIRWY"), (3, "DRGARE"), (4, "RECTRC"), (4, "NAVLNE")):
        g = sub.get(layer)
        if g is None:
            continue
        for r in g.itertuples():
            auth = int(L.to_dm([pd.to_numeric(getattr(r, "DRVAL1", np.nan), errors="coerce")])[0]) \
                if layer == "DRGARE" else -32768
            geom = r.geometry
            if src == 4:
                geom = geom.interpolate(0.5, normalized=True) if geom.geom_type in ("LineString",) else geom
            rows[r.fkey] = (src, L.is_icw(r.OBJNAM), str(r.OBJNAM or "") if r.OBJNAM is not None else "",
                            str(r.LNAM or ""), "", -32768, auth, L._ymd(r.SORDAT), geom)
    recs, index_of = [], {}
    for k in keys:
        if k not in rows:
            raise RuntimeError(f"channel feature {k} referenced by a tile is missing from the region data")
        src, icw, name, ident, desc, maint, auth, date, geom = rows[k]
        rp = _rep_units(geom)
        index_of[k] = len(recs)
        recs.append((src, 1 if icw else 0, maint, auth, 0, st.S(name), st.S(ident), st.S(desc), date, rp[0], rp[1]))
    return np.array(recs, dtype=P.CHAN_DT), index_of


def area_table(source, keys, st: SideTables):
    regs = L.reg_areas(_subset(source, ["RESARE", "CTNARE"], keys))
    recs, index_of = [], {}
    for row in regs.itertuples():
        rp = _rep_units(row.geometry)
        name = row.OBJNAM if isinstance(row.OBJNAM, str) and row.OBJNAM else (
            {1: "Entry prohibited area", 2: "Restricted area", 3: "Caution area"}[row.kind])
        index_of[row.fkey] = len(recs)
        recs.append((row.kind, 1 if row.cls == "RESARE" else 2, 0, st.S(name), st.S(row.INFORM), rp[0], rp[1],
                     (0, 0, 0)))
    return np.array(recs, dtype=P.AREA_DT), index_of


def assemble(region, tile_keys: dict, source, merged_entries, load_tile, build_stamp=None, log=print):
    """Pack for region from its tiles. tile_keys: {tile id: cache key}.
    build_stamp: datetime (UTC) written as the build date and time (default:
    now). Returns (Pack, report)."""
    t0 = time.time()
    p = region.params
    coords, tris, attrs, area2 = [], [], {}, 0
    keys = {"channel": set(), "overhead": set(), "area": set(), "hazard": set()}
    tri_local = []
    used_cells = set()
    nverts = 0
    tile_tri = {}
    for tid in sorted(tile_keys):
        r = load_tile(tile_keys[tid])
        keys["hazard"].update(r.get("hazard_keys", []))
        if not len(r["tris"]):
            tile_tri[tid] = 0
            continue
        coords.append(r["coords"])
        tris.append(r["tris"].astype(np.int64) + nverts)
        nverts += len(r["coords"])
        area2 += int(r["area2"])
        used_cells.update(r["used_cells"])
        tile_tri[tid] = len(r["tris"])
        for k in ("channel", "overhead", "area"):
            keys[k].update(r[{"channel": "chan_keys", "overhead": "over_keys", "area": "area_keys"}[k]])
        tri_local.append((r, len(r["tris"])))
    if not tris:
        raise RuntimeError(f"region {region.rid}: no navigable water in its tiles")
    allc = np.vstack(coords)
    tris = np.vstack(tris)
    uniq, inv = np.unique(allc, axis=0, return_inverse=True)
    inv = inv.reshape(-1)
    tris = inv[tris]
    log(f"assemble: {len(tile_keys)} tiles, {len(uniq)} vertices, {len(tris)} triangles")
    # side tables
    st = SideTables()
    ovh, ov_first = overhead_table(source, keys["overhead"], st)
    hzd = hazard_table(source, keys["hazard"], st)
    chn, ch_index = channel_table(source, keys["channel"], st)
    ars, ar_index = area_table(source, keys["area"], st)
    geom = st.geom()
    for name, n in (("OVHD", len(ovh)), ("CHAN", len(chn)), ("AREA", len(ars))):
        if n >= LIMIT_U16:
            raise FormatLimit(f"region {region.rid}: {n} {name} records; the format addresses at most 65534")
    # per-triangle attributes, references remapped to the region tables
    cols = {k: [] for k, _ in P.ATTR_COLUMNS}
    missing = {"overhead": 0}
    for r, n in tri_local:
        a = r["attrs"]
        for k in ("depth_dm", "band_depth_dm", "maint_dm", "clearance_dm", "flags", "quality"):
            cols[k].append(np.asarray(a[k], np.int64))
        cols["channel"].append(_remap(a["channel"], r["chan_keys"], ch_index))
        ov_index = {k: ov_first.get(k, P.ID_NONE) for k in r["over_keys"]}
        missing["overhead"] += sum(1 for k in r["over_keys"] if k not in ov_first)
        cols["overhead"].append(_remap(a["overhead"], r["over_keys"], ov_index))
        cols["area"].append(_remap(a["area"], r["area_keys"], ar_index))
    attrs = {k: np.concatenate(v) for k, v in cols.items()}
    # seams: split T-junctions where neighbouring tiles' vertices differ
    tris, src, n_split = topology.fix_tjunctions(uniq, tris, np.arange(len(tris)))
    attrs = {k: v[src] for k, v in attrs.items()}
    topo = topology.validate(uniq, tris, area2)
    topo["seam_splits"] = int(n_split)
    log(f"assemble: seams split {n_split}; topology ok={topo['ok']}")
    if not topo["ok"]:
        raise RuntimeError(f"region {region.rid}: mesh topology validation failed: {topo}")
    verts, ctris, perm = P.canonicalize(uniq, tris)
    attrs = {k: v[perm] for k, v in attrs.items()}
    allpts = np.vstack([verts.astype(np.int64), geom.astype(np.int64).reshape(-1, 2)])
    vmin, vmax = allpts.min(0), allpts.max(0)
    bbox = (int(vmin[0]), int(vmin[1]), int(vmax[0]), int(vmax[1]))
    nbr, dup = P.adjacency(ctris)
    assert dup == 0
    grid = P.build_grid(verts, ctris, bbox, int(round(p.index_cell_deg * UNITS)))
    # sources: every cell with coverage in the region's tiles; used = contributed water
    srcs = []
    S = st.S
    tb = shapely.union_all([shapely.box(*_tile_bounds(t, p)) for t in tile_keys])
    shapely.prepare(tb)
    for name in sorted(source.cells):
        e = merged_entries[name]
        if e["excl"].is_empty or not tb.intersects(e["excl"]):
            continue
        m = e["meta"]
        srcs.append((S(name), int(m["edtn"]), int(m["updn"]), int(str(m["isdt"]).replace("-", "") or 0),
                     int(m["cscale"]), int(name[2]), 1 if name in used_cells else 0, (0,) * 6))
    sources = np.array(srcs, dtype=P.SRCS_DT)
    data_date = int(max((s["issue_date"] for s in sources if s["used"]), default=0))
    now = build_stamp or dt.datetime.now(dt.timezone.utc)
    info = {"builder": f"enc_routing {BUILDER_VERSION}",
            "params": json.dumps(p.__dict__, default=list), "params_key": p.key(),
            "crs": "per-tile transverse Mercator (tile centre)", "tiles": len(tile_keys),
            "cells": int(sources["used"].sum()),
            "topology": json.dumps({k: topo.get(k) for k in ("boundary_edges", "bowtie_vertices", "seam_splits")}),
            "ncf": "USACE National Channel Framework (ChannelReach, ChannelLine)",
            "attribution": "NOAA ENC and USACE NCF data; not for navigation"}
    pack = P.Pack(region_id=region.rid, bbox=bbox, data_date=data_date,
                  build_date=now.year * 10000 + now.month * 100 + now.day,
                  build_time=now.hour * 10000 + now.minute * 100 + now.second,
                  clearance_dm=int(round(p.clearance_m * 10)), check_dm=int(round((p.clearance_m - 1.0) * 10)),
                  shore_rings_m=tuple(int(x) for x in (list(p.shore_rings_m[:2]) + [0, 0])[:2]),
                  vertices=verts, tris=ctris, attrs=attrs, strings=S.items, overhead=ovh, hazards=hzd,
                  channels=chn, areas=ars, sources=sources, geom=geom, info=info, nbr=nbr, grid=grid)
    report = {"topology": topo, "vertices": int(len(verts)), "triangles": int(len(ctris)),
              "tiles": len(tile_keys), "tiles_with_water": sum(1 for v in tile_tri.values() if v),
              "records": {"OVHD": len(ovh), "HAZD": len(hzd), "CHAN": len(chn), "AREA": len(ars), "GEOM": len(geom),
                          "SRCS": len(sources)},
              "overhead_keys_missing": missing["overhead"], "assemble_seconds": round(time.time() - t0, 1)}
    return pack, report


def _tile_bounds(tid: str, p):
    from .tiles import tile_size

    ix, iy = (int(v[1:]) for v in tid.split("_"))
    T = tile_size(p)
    return (ix * T / UNITS, iy * T / UNITS, (ix + 1) * T / UNITS, (iy + 1) * T / UNITS)
