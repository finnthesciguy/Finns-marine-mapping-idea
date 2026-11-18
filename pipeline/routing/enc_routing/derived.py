"""Derived chart layers, computed once per build for the whole Gulf from the
merged cells (never per tile, so every tile and every region sees the same
values). They are added to the tile inputs as extra layers:

- LOCKZN  lock and navigable floodgate zones (format part C.2a)
- DATUMN  cells whose soundings are not referred to MLLW (an area-wide advisory, C.7a)
- SNDEXT  extended sounding raise for depth areas whose band starts at or near zero (C.4b)

and RESARE / CTNARE get a boolean column `areawide` (C.7a).

Everything here is lon/lat in, lon/lat out. Metric work uses CONUS Albers
(EPSG:5070) for the Gulf-wide groupings (scale error well under 1 %), and a
transverse Mercator per cell for the sounding raise.
"""
from __future__ import annotations

import hashlib
import json
import re

import geopandas as gpd
import numpy as np
import pandas as pd
import shapely
from pyproj import Geod, Transformer

from . import layers as L
from .config import BUILDER_VERSION, GEO_CRS, tmerc, work

ALBERS = "EPSG:5070"
_GEOD = Geod(ellps="WGS84")


def _tr(a, b):
    t = Transformer.from_crs(a, b, always_xy=True)
    return lambda g: shapely.transform(g, lambda xy: np.column_stack(t.transform(xy[:, 0], xy[:, 1])))


# --------------------------------------------------------------------------- locks and floodgates

NAVIGABLE_CATGAT = {2, 4}          # flood barrage gate, lock gate
_NOT_NAVIGABLE_TEXT = re.compile(r"wall|closed(?!\s+position)", re.IGNORECASE)


def gate_is_navigable(catgat, inform) -> bool:
    """A GATCON is a navigable gate when CATGAT is 2 (flood barrage gate) or 4 (lock gate) and its INFORM
    does not mark it as a wall (guide wall, floodwall) or as closed ("Closed", "Permanently closed to
    navigation"; "closed position", the charted position of a gate, does not count)."""
    if not (L.int_set(catgat) & NAVIGABLE_CATGAT):
        return False
    text = "" if inform is None or (isinstance(inform, float) and np.isnan(inform)) else str(inform)
    return not _NOT_NAVIGABLE_TEXT.search(text)


def navigable_gate_mask(g) -> np.ndarray:
    if g is None or not len(g):
        return np.zeros(0, bool)
    cat = g["CATGAT"].values if "CATGAT" in g.columns else [None] * len(g)
    return np.array([gate_is_navigable(c, i) for c, i in zip(cat, g["INFORM"].values)], bool)


def lock_zones(gates: gpd.GeoDataFrame, p) -> gpd.GeoDataFrame:
    """Navigable gates within p.lock_group_m of each other form one lock; its zone is the convex hull of
    its gates grown by p.lock_zone_m. Name: the first OBJNAM of the group (feature-key order), else
    "Lock" when a lock gate is present, else "Floodgate"; text: the first INFORM."""
    cols = {"kind": [], "OBJNAM": [], "INFORM": [], "fkey": [], "geometry": []}
    if gates is None or not len(gates):
        return gpd.GeoDataFrame(cols, geometry="geometry", crs=GEO_CRS)
    g = gates[navigable_gate_mask(gates)].sort_values("fkey", kind="stable").reset_index(drop=True)
    if not len(g):
        return gpd.GeoDataFrame(cols, geometry="geometry", crs=GEO_CRS)
    to_m, to_ll = _tr(GEO_CRS, ALBERS), _tr(ALBERS, GEO_CRS)
    gm = np.array([to_m(x) for x in g.geometry.values], dtype=object)
    n = len(gm)
    parent = list(range(n))

    def find(i):
        while parent[i] != i:
            parent[i] = parent[parent[i]]
            i = parent[i]
        return i
    tree = shapely.STRtree(gm)
    a, b = tree.query(gm, predicate="dwithin", distance=p.lock_group_m)
    for i, j in zip(a.tolist(), b.tolist()):
        ri, rj = find(i), find(j)
        if ri != rj:
            parent[max(ri, rj)] = min(ri, rj)
    groups = {}
    for i in range(n):
        groups.setdefault(find(i), []).append(i)
    for root in sorted(groups):
        idx = groups[root]
        hull = shapely.convex_hull(shapely.union_all(gm[idx]))
        zone = shapely.buffer(hull, p.lock_zone_m, quad_segs=4)
        names = [str(v) for v in g.OBJNAM.values[idx] if isinstance(v, str) and v.strip() and v != "nan"]
        lockgate = any(4 in L.int_set(c) for c in g.CATGAT.values[idx])
        texts = [str(v) for v in g.INFORM.values[idx] if isinstance(v, str) and v.strip() and v != "nan"]
        cols["kind"].append(4)
        cols["OBJNAM"].append(names[0] if names else ("Lock" if lockgate else "Floodgate"))
        cols["INFORM"].append(texts[0] if texts else "")
        cols["fkey"].append("LOCK:" + g.fkey.values[idx[0]])
        cols["geometry"].append(to_ll(zone))
    return gpd.GeoDataFrame(cols, geometry="geometry", crs=GEO_CRS)


# --------------------------------------------------------------------------- area-wide advisories

ENV_CATREA = {4, 5, 22, 23, 27, 28}      # nature reserve, bird/fish sanctuary, ecological reserve, ESSA, PSSA
SPEED_RESTRN = {13, 27}                   # no wake, speed restricted
SPEED_CATREA = {24}                       # no-wake area


def areawide_keys(frames: dict, p) -> set:
    """Feature keys of the RESARE / CTNARE features that are area-wide advisories (spec C.7a):
    restricted or caution kind (never prohibited), not a no-wake or speed area, and either a caution
    RESARE with an environmental category, or part of a connected group (same class, kind and name, or
    the same INFORM text when unnamed) covering at least p.areawide_km2."""
    out = set()
    groups = {}
    for layer in ("RESARE", "CTNARE"):
        g = frames.get(layer)
        if g is None or not len(g):
            continue
        g = g[g.geom_type.isin(["Polygon", "MultiPolygon"])]
        for r in g.itertuples():
            restrn, catrea = getattr(r, "RESTRN", None), getattr(r, "CATREA", None)
            k = L.area_kind(layer, restrn, catrea)
            if k not in (2, 3):
                continue
            if L.int_set(restrn) & SPEED_RESTRN or L.int_set(catrea) & SPEED_CATREA:
                continue
            if layer == "RESARE" and k == 3 and L.int_set(catrea) & ENV_CATREA:
                out.add(r.fkey)
                continue
            name = r.OBJNAM if isinstance(r.OBJNAM, str) and r.OBJNAM.strip() and r.OBJNAM != "nan" else ""
            text = r.INFORM if isinstance(r.INFORM, str) and r.INFORM != "nan" else ""
            groups.setdefault((layer, k, name or ("text:" + text)), []).append((r.fkey, r.geometry))
    for key in sorted(groups):
        items = sorted(groups[key], key=lambda x: x[0])
        geoms = np.array([shapely.make_valid(x[1]) for x in items], dtype=object)
        u = shapely.union_all(shapely.buffer(geoms, 1e-6))   # touching parts (cut by cells) join
        for comp in shapely.get_parts(u):
            if abs(_GEOD.geometry_area_perimeter(comp)[0]) / 1e6 < p.areawide_km2:
                continue
            hit = shapely.intersects(geoms, comp)
            out.update(items[i][0] for i in np.flatnonzero(hit))
    return out


DATUM_TEXT = {24: "a local datum (on the Mississippi River the Low Water Reference Plane)",
              5: "mean low water"}


def datum_notes(entries: dict) -> gpd.GeoDataFrame:
    """One area-wide advisory per non-MLLW sounding datum (DSPM SDAT != 12): the union of the exclusive
    regions of the cells that use it."""
    per = {}
    for name in sorted(entries):
        e = entries[name]
        sdat = (e["meta"].get("dspm") or {}).get("SDAT")
        if sdat in (None, 12) or e["excl"].is_empty:
            continue
        per.setdefault(int(sdat), []).append(e["excl"])
    rows = {"kind": [], "OBJNAM": [], "INFORM": [], "fkey": [], "geometry": []}
    for sdat in sorted(per):
        rows["kind"].append(3)
        rows["OBJNAM"].append("Chart datum")
        rows["INFORM"].append(f"Depths in this area are referred to {DATUM_TEXT.get(sdat, f'S-57 vertical datum {sdat}')}, "
                              "not mean lower low water (MLLW)")
        rows["fkey"].append(f"DATUM:{sdat}")
        rows["geometry"].append(shapely.make_valid(shapely.union_all(per[sdat])))
    return gpd.GeoDataFrame(rows, geometry="geometry", crs=GEO_CRS)


# --------------------------------------------------------------------------- extended sounding raise

def _min_angle_deg(pts):
    """Smallest interior angle of each triangle, pts (n,3,2)."""
    out = np.full(len(pts), 180.0)
    for k in range(3):
        a, b, c = pts[:, k], pts[:, (k + 1) % 3], pts[:, (k + 2) % 3]
        u, v = b - a, c - a
        cosv = (u * v).sum(1) / np.maximum(np.linalg.norm(u, axis=1) * np.linalg.norm(v, axis=1), 1e-12)
        out = np.minimum(out, np.degrees(np.arccos(np.clip(cosv, -1, 1))))
    return out


def _empty_ext():
    return gpd.GeoDataFrame({"area_fkey": [], "refined_dm": [], "geometry": []}, geometry="geometry", crs=GEO_CRS)


def _extension(dep, snd, haz_geoms, p, crs) -> gpd.GeoDataFrame:
    """Spec C.4b. dep: DEPARE rows (lon/lat; DRVAL1, DRVAL2, fkey, cscale); snd: SOUNDG points (lon/lat; DEPTH,
    cscale); haz_geoms: hazard geometries (lon/lat). Depth areas of the same band that touch (one area cut by chart
    cells) are one area. Returns lon/lat polygons (area_fkey, refined_dm), split by the original DEPARE rows."""
    from scipy.spatial import Delaunay

    if dep is None or snd is None or not len(dep) or len(snd) < 3:
        return _empty_ext()
    to_m, to_ll = _tr(GEO_CRS, crs), _tr(crs, GEO_CRS)
    dep = dep[dep.geom_type.isin(["Polygon", "MultiPolygon"])].reset_index(drop=True)
    if "cls" not in dep.columns:
        dep = dep.assign(cls="DEPARE")
    if "cell" not in dep.columns:
        dep = dep.assign(cell="")
    d1_all = L.to_dm(pd.to_numeric(dep.DRVAL1, errors="coerce"))
    d2_all = L.to_dm(pd.to_numeric(dep.DRVAL2, errors="coerce"))
    sel = (dep.cls.values == "DEPARE") & (d1_all >= 0) & (d1_all <= p.ext_d1_max_dm) & (d2_all > d1_all) \
        & (d1_all != -32768) & (d2_all != -32768)
    if not sel.any():
        return _empty_ext()
    # every depth area (DEPARE, DRGARE) touching an eligible one: deeper neighbours and cross-cell support
    all_m = np.array([shapely.make_valid(to_m(g)) for g in dep.geometry.values], dtype=object)
    sel_idx = np.flatnonzero(sel)
    near = np.unique(shapely.STRtree(all_m).query(all_m[sel_idx], predicate="dwithin", distance=0.05)[1])
    nb_m, nb_d1 = all_m[near], d1_all[near]
    nb_cell, nb_cls = dep.cell.values[near], dep.cls.values[near]
    dep, d1, d2 = dep[sel].reset_index(drop=True), d1_all[sel], d2_all[sel]
    mem = all_m[sel_idx]
    # areas: connected unions of same-band rows (touching parts of one area cut by chart cells join)
    comps, comp_d1, comp_d2, comp_members = [], [], [], []
    for band in sorted(set(zip(d1.tolist(), d2.tolist()))):
        idx = np.flatnonzero((d1 == band[0]) & (d2 == band[1]))
        u = shapely.union_all(shapely.buffer(mem[idx], 0.05))
        parts = list(shapely.get_parts(u))
        q_in, q_part = shapely.STRtree(parts).query(mem[idx], predicate="intersects")
        for k, part in enumerate(parts):
            mi = idx[np.unique(q_in[q_part == k])]
            comps.append(part)
            comp_d1.append(band[0])
            comp_d2.append(band[1])
            comp_members.append(mi)
    # Support: a deeper-or-equal DEPARE of another chart cell that meets the area along the cut between the cells
    # (the same water compiled at another scale, e.g. 0-5 m in one cell and 2-5 m in the next) joins the area for
    # the triangulation, so the soundings on both sides of the cut count; it is never raised itself. Deeper
    # neighbours (any cell, DEPARE or DRGARE) also lift the 150 m boundary rule for values up to their DRVAL1.
    nb_tree = shapely.STRtree(nb_m)
    comp_union, comp_deep = [], []
    for c, part in enumerate(comps):
        cells = set(dep.cell.values[comp_members[c]].tolist())
        touch = nb_tree.query(part, predicate="dwithin", distance=0.05)
        deeper = [int(j) for j in touch if nb_d1[j] > comp_d1[c]]
        support = [nb_m[j] for j in deeper if nb_cls[j] == "DEPARE" and nb_cell[j] not in cells]
        comp_union.append(shapely.union_all([part] + support) if support else part)
        comp_deep.append([(int(nb_d1[j]), nb_m[j]) for j in deeper])
    comps = np.array(comp_union, dtype=object)
    comp_d1, comp_d2 = np.array(comp_d1), np.array(comp_d2)
    snd = snd[snd.geom_type == "Point"]
    sd_all = L.to_dm(pd.to_numeric(snd.DEPTH, errors="coerce"))
    ok = sd_all != -32768
    snd, sd_all = snd[ok], sd_all[ok]
    if len(snd) < 3:
        return _empty_ext()
    xy_all = shapely.get_coordinates(to_m(snd.geometry.values))
    sc_all = np.asarray(snd.cscale.values, float)
    pts_all = shapely.points(xy_all)
    ctree = shapely.STRtree(comps)
    pi, ci = ctree.query(pts_all, predicate="within")
    c_of = np.full(len(xy_all), -1)
    c_of[pi] = ci
    use = np.flatnonzero(c_of >= 0)
    if len(use) < 3:
        return _empty_ext()
    xy, sd, sc, cc = xy_all[use], sd_all[use], sc_all[use], c_of[use]
    try:
        tri = Delaunay(xy).simplices
    except Exception:  # noqa: BLE001 - degenerate soundings: nothing to raise
        return _empty_ext()
    A = cc[tri]
    same = (A[:, 0] == A[:, 1]) & (A[:, 1] == A[:, 2])
    tri, a = tri[same], A[same, 0]
    P = xy[tri]
    edge = np.stack([np.linalg.norm(P[:, k] - P[:, (k + 1) % 3], axis=1) for k in range(3)], 1).max(1)
    std = np.minimum(p.tin_edge_frac * sc[tri].min(1), p.tin_edge_cap_m)
    dd = sd[tri]
    spread = dd.max(1) - dd.min(1)
    keep = (edge > std) & (edge <= p.ext_edge_max_m) & (_min_angle_deg(P) >= p.ext_min_angle_deg) \
        & (spread <= p.ext_spread_max_dm)
    tri, a, P, dd = tri[keep], a[keep], P[keep], dd[keep]
    val = np.minimum(dd.min(1), comp_d2[a]) - p.ext_margin_dm
    keep = val > comp_d1[a]
    a, P, dd, val = a[keep], P[keep], dd[keep], val[keep]
    if not len(a):
        return _empty_ext()
    polys = shapely.polygons(np.concatenate([P, P[:, :1]], axis=1))
    inside = shapely.within(polys, comps[a])
    # nothing that could make it shallower nearby: no hazard of any depth within ext_clear_m, no sounding shallower
    # than the triangle's least sounding within ext_clear_m, none shallower than the raised value within ext_shoal_m
    if len(haz_geoms):
        hg = np.array([to_m(g) for g in haz_geoms], dtype=object)
        hi, _ = shapely.STRtree(hg).query(polys, predicate="dwithin", distance=p.ext_clear_m)
        inside[np.unique(hi)] = False
    st = shapely.STRtree(pts_all)
    si, sj = st.query(polys, predicate="dwithin", distance=p.ext_clear_m)
    inside[np.unique(si[sd_all[sj] < dd.min(1)[si]])] = False
    si, sj = st.query(polys, predicate="dwithin", distance=p.ext_shoal_m)
    inside[np.unique(si[sd_all[sj] < val[si]])] = False
    out_a, out_v, out_g = [], [], []
    core = {}
    for k in np.flatnonzero(inside):
        c = int(a[k])
        v = int(val[k])
        if (c, v) not in core:
            # 150 m from the area's boundary, except along neighbours charted at least as deep as the value
            deep = [g for dd1, g in comp_deep[c] if dd1 >= v]
            cv = shapely.buffer(comps[c], -p.ext_boundary_m)
            if deep:
                cv = shapely.union_all([cv, shapely.intersection(
                    comps[c], shapely.buffer(shapely.union_all(deep), p.ext_boundary_m))])
            core[(c, v)] = cv
        g = shapely.intersection(polys[k], core[(c, v)])
        if g.is_empty or g.area < 1.0:
            continue
        for m in comp_members[c]:
            piece = shapely.intersection(g, mem[m])
            if piece.is_empty or piece.area < 1.0:
                continue
            out_a.append(dep.fkey.values[m])
            out_v.append(int(val[k]))
            out_g.append(piece)
    if not out_g:
        return _empty_ext()
    df = gpd.GeoDataFrame({"area_fkey": out_a, "refined_dm": out_v}, geometry=out_g)
    df = df.dissolve(by=["area_fkey", "refined_dm"], as_index=False)
    df["geometry"] = [shapely.make_valid(to_ll(g)) for g in df.geometry.values]
    return gpd.GeoDataFrame(df, geometry="geometry", crs=GEO_CRS)


def _with_cscale(g, cscale):
    g = g.copy()
    if "cscale" not in g.columns:
        g["cscale"] = cscale
    if "fkey" not in g.columns:
        g["fkey"] = [f"row:{k}" for k in range(len(g))]
    return g


def sounding_extension(merged: dict, excl_ll, cscale: int, p) -> gpd.GeoDataFrame:
    """Spec C.4b on the features of one merged cell (tests and probes; the build uses the whole Gulf at once,
    sounding_extensions)."""
    dep, snd = merged.get("DEPARE"), merged.get("SOUNDG")
    if dep is None or snd is None or excl_ll.is_empty:
        return _empty_ext()
    haz = [g for k in ("OBSTRN", "WRECKS", "UWTROC") if k in merged for g in merged[k].geometry.values]
    c = excl_ll.centroid
    return _extension(_with_cscale(dep, cscale), _with_cscale(snd, cscale), haz, p, tmerc(round(c.x, 1)))


EXT_VERSION = 2  # bump when the C.4b code changes (part of the cache key)


def _ext_cache_key(entries, p) -> str:
    keys = {k: getattr(p, k) for k in ("ext_d1_max_dm", "ext_edge_max_m", "ext_min_angle_deg", "ext_spread_max_dm",
                                        "ext_margin_dm", "ext_clear_m", "ext_shoal_m", "ext_boundary_m", "tin_edge_frac",
                                        "tin_edge_cap_m")}
    paths = sorted(str(e["path"]) for e in entries.values() if not e["excl"].is_empty)
    return hashlib.sha256(json.dumps([BUILDER_VERSION, EXT_VERSION, paths, keys], sort_keys=True).encode()).hexdigest()[:16]


def sounding_extensions(entries: dict, load_merged, p, log=print) -> gpd.GeoDataFrame:
    """C.4b for the whole Gulf at once (depth areas cut by chart cells are joined; hazards and soundings of
    neighbouring cells count), in CONUS Albers. Cached by every merged cell and the parameters."""
    path = work("sndext", f"gulf.{_ext_cache_key(entries, p)}.pkl")
    if path.exists():
        out = pd.read_pickle(path)
        log(f"sounding extension: {len(out)} regions (cached)")
        return out
    deps, snds, haz = [], [], []
    for name in sorted(entries):
        e = entries[name]
        if e["excl"].is_empty:
            continue
        m = load_merged(e)
        cs = int(e["meta"].get("cscale") or 0) or 12000
        for layer in ("DEPARE", "DRGARE"):
            if layer in m:
                deps.append(_with_cscale(m[layer], cs).assign(cls=layer, cell=name))
        if "SOUNDG" in m:
            snds.append(_with_cscale(m["SOUNDG"][["DEPTH", "geometry"]], cs))
        for k in ("OBSTRN", "WRECKS", "UWTROC"):
            if k in m:
                haz += list(m[k].geometry.values)
    dep = gpd.GeoDataFrame(pd.concat(deps, ignore_index=True), geometry="geometry", crs=GEO_CRS) if deps else None
    snd = gpd.GeoDataFrame(pd.concat(snds, ignore_index=True), geometry="geometry", crs=GEO_CRS) if snds else None
    out = _extension(dep, snd, haz, p, ALBERS)
    out["fkey"] = [f"SNDEXT:{a}:{v}" for a, v in zip(out.area_fkey.values, out.refined_dm.values)]
    pd.to_pickle(out, path)
    log(f"sounding extension: {len(out)} regions over {out.area_fkey.nunique() if len(out) else 0} depth areas")
    return out


# --------------------------------------------------------------------------- all of it

def derive(entries: dict, load_merged, p, log=print) -> dict:
    """{"LOCKZN": frame, "DATUMN": frame, "SNDEXT": frame, "areawide": set of fkeys}."""
    gates, regs = [], {"RESARE": [], "CTNARE": []}
    for name in sorted(entries):
        e = entries[name]
        if e["excl"].is_empty:
            continue
        m = load_merged(e)
        if "GATCON" in m:
            gates.append(m["GATCON"])
        for k in regs:
            if k in m:
                regs[k].append(m[k])
    gates = pd.concat(gates, ignore_index=True) if gates else None
    regs = {k: pd.concat(v, ignore_index=True) for k, v in regs.items() if v}
    lz = lock_zones(gates, p)
    aw = areawide_keys(regs, p)
    dn = datum_notes(entries)
    se = sounding_extensions(entries, load_merged, p, log=log)
    log(f"derived: {len(lz)} lock zones, {len(aw)} area-wide regulated features, {len(dn)} datum notes")
    return {"LOCKZN": lz, "DATUMN": dn, "SNDEXT": se, "areawide": aw}
