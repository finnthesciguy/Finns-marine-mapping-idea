"""Navigation mesh builder: merged ENC + NCF layers -> routing Pack.

Overview (details and the exact rules are in docs/routing-pack-format.md,
part C):

1. Domain. Navigable water = union of depth areas with DRVAL1 >= 0, closed
   by close_m, minus every obstacle grown by the safety clearance. Obstacles
   are land, shoreline constructions, pontoons/hulks/docks/dams/gates/dykes,
   piles, unsurveyed areas, causeways (minus bridge spans) and hazards that
   block every boat (unknown depth, drying or awash). Obstacles are buffered
   by clearance_m + 2*simplify_m and then simplified by simplify_m, so the
   simplified boundary is never closer than clearance_m to any obstacle.
2. Constraint lines. Every boundary that changes what a boat may do or what
   a leg costs: domain boundary, depth-area edges (raw, never simplified),
   sounding-refinement regions and sounding lowering zones, clearance zones
   of known-depth hazards, hazard proximity ring, shore distance rings,
   overhead footprints, channels, highway corridors, regulated areas,
   M_QUAL, open-Gulf mask, and a lat/lon grid that bounds triangle size.
3. The lines are transformed to integer 1e-7 degree units and snap-rounded
   in one pass (GEOS OverlayNG, grid 1 unit), polygonized into faces, and
   every face inside the domain is triangulated with GEOS's constrained
   Delaunay triangulation (no Steiner points). Repairs (flat triangles,
   T-junctions) run in exact integer arithmetic, then topology.validate()
   must pass or the build fails.
4. Attributes are sampled per face at the incentre of its fattest
   triangle, with conservative rules (minimum depth over a 3 cm disk etc.).
"""
from __future__ import annotations

import datetime as dt
import hashlib
import json
import time

import geopandas as gpd
import numpy as np
import pandas as pd
import shapely
from pyproj import Transformer
from shapely.geometry import LineString, box

from . import layers as L
from . import packfmt as P
from . import topology
from .config import BUILDER_VERSION, GEO_CRS

UNITS = 1e7  # integer units per degree


def log(msg, t0=[time.time()]):
    print(f"[{time.time() - t0[0]:7.1f}s] {msg}", flush=True)


# --------------------------------------------------------------------------- transforms

class Units:
    """metric CRS <-> integer 1e-7 degree units."""

    def __init__(self, crs):
        self.fwd = Transformer.from_crs(crs, GEO_CRS, always_xy=True)
        self.inv = Transformer.from_crs(GEO_CRS, crs, always_xy=True)

    def geoms_to_units(self, geoms):
        def f(xy):
            lon, lat = self.fwd.transform(xy[:, 0], xy[:, 1])
            return np.column_stack([np.asarray(lon) * UNITS, np.asarray(lat) * UNITS])
        return shapely.transform(np.asarray(geoms, dtype=object), f)

    def units_to_metric(self, xy):
        x, y = self.inv.transform(np.asarray(xy[:, 0]) / UNITS, np.asarray(xy[:, 1]) / UNITS)
        return np.column_stack([x, y])


# --------------------------------------------------------------------------- open-Gulf mask

def gulf_mask(shore_union, region, crs):
    from .places import GULF_MASK

    cfg = GULF_MASK.get(region.rid)
    if cfg is None:
        return None
    tr = Transformer.from_crs(GEO_CRS, crs, always_xy=True)

    def pt(lonlat):
        return tr.transform(*lonlat)
    area = shapely.segmentize(box(*region.bbox), 0.01)
    area = shapely.transform(area, lambda xy: np.column_stack(tr.transform(xy[:, 0], xy[:, 1])))
    land = shapely.union_all([p for p in shapely.get_parts(shore_union) if p.area > 5e4])
    for line in cfg["barriers"]:
        land = land.union(LineString([pt(p) for p in line]).buffer(50))
    land = land.simplify(20)
    r = cfg["close_m"]
    barrier = land.buffer(r).buffer(-r)
    seed = shapely.Point(pt(cfg["seed"]))
    free = area.difference(barrier)
    return next(p for p in shapely.get_parts(free) if p.covers(seed))


# --------------------------------------------------------------------------- sounding refinement

def tin_edge_limit(cscale, p):
    return np.minimum(p.tin_edge_frac * np.asarray(cscale, float), p.tin_edge_cap_m)


def sounding_refinement(areas: gpd.GeoDataFrame, snd: gpd.GeoDataFrame, p):
    """Regions where a depth area's least depth may be raised.

    For DEPARE areas with a finite band [d1, d2) and d1 >= 0: Delaunay
    triangulate all soundings; keep a TIN triangle when its three soundings
    lie inside the same area A, the triangle lies inside A, and its longest
    edge is at most tin_edge_limit(cscale of A). Its supported least depth is
    min(d2, min of the three sounding depths); it is kept when that exceeds
    d1. Returns GeoDataFrame(area_idx, refined_dm, geometry) dissolved by
    (area, value)."""
    from scipy.spatial import Delaunay

    dep = areas[(areas.cls == "DEPARE") & (areas.d1 >= 0) & (areas.d2 > areas.d1)]
    if len(snd) < 3 or dep.empty:
        return gpd.GeoDataFrame({"area_idx": [], "refined_dm": [], "geometry": []}, geometry="geometry")
    xy = shapely.get_coordinates(snd.geometry.values)
    tree = shapely.STRtree(dep.geometry.values)
    pi, ai = tree.query(snd.geometry.values, predicate="within")
    a_of = np.full(len(snd), -1)
    a_of[pi] = dep.index.values[ai]  # area index in `areas`
    tri = Delaunay(xy).simplices
    A = a_of[tri]
    same = (A[:, 0] >= 0) & (A[:, 0] == A[:, 1]) & (A[:, 1] == A[:, 2])
    tri = tri[same]
    a = A[same, 0]
    pts = xy[tri]
    edges = np.stack([np.linalg.norm(pts[:, k] - pts[:, (k + 1) % 3], axis=1) for k in range(3)], 1).max(1)
    lim = tin_edge_limit(areas.cscale.values[a], p)
    ok = edges <= lim
    tri, a, pts = tri[ok], a[ok], pts[ok]
    dmin = snd.depth_dm.values[tri].min(1)
    d1 = areas.d1.values[a]
    d2 = areas.d2.values[a]
    val = np.minimum(dmin, d2)
    ok = val > d1
    tri, a, pts, val = tri[ok], a[ok], pts[ok], val[ok]
    polys = shapely.polygons(np.concatenate([pts, pts[:, :1]], axis=1))
    inside = shapely.within(polys, areas.geometry.values[a])
    df = gpd.GeoDataFrame({"area_idx": a[inside], "refined_dm": val[inside]}, geometry=polys[inside])
    if df.empty:
        return df
    out = df.dissolve(by=["area_idx", "refined_dm"], as_index=False)
    return out


def sounding_lowering(areas, refine, snd, p):
    """Soundings that are shallower than some depth level (area least depth
    or refined value) within sounding_near_m of them. Each becomes an
    octagon of circumradius near/cos(22.5 deg), so the octagon covers the
    whole near-disk; triangles in it get least depth <= the sounding."""
    if snd.empty:
        return gpd.GeoDataFrame({"depth_dm": [], "geometry": []}, geometry="geometry")
    near = p.sounding_near_m
    lvl = np.full(len(snd), -32768)
    pts = snd.geometry.values
    for geoms, vals in ((areas.geometry.values, areas.d1.values),
                        (refine.geometry.values, refine.refined_dm.values)):
        if len(geoms) == 0:
            continue
        tree = shapely.STRtree(geoms)
        i, j = tree.query(pts, predicate="dwithin", distance=near)
        np.maximum.at(lvl, i, vals[j])
    m = snd.depth_dm.values < lvl
    r = near / np.cos(np.pi / 8) + 0.05
    return gpd.GeoDataFrame({"depth_dm": snd.depth_dm.values[m]},
                            geometry=shapely.buffer(pts[m], r, quad_segs=2))


# --------------------------------------------------------------------------- preparation

def prepare(region, merged):
    """All input layers in the region's metric CRS. Returns a dict."""
    p = region.params
    crs = region.crs
    C, s = p.clearance_m, p.simplify_m
    areas = L.depth_areas(merged).reset_index(drop=True)
    wet = areas[areas.d1 >= 0]
    water = L.close(shapely.union_all(wet.geometry.values), p.close_m)
    log(f"water: {len(wet)} depth areas")
    haz = L.hazards(merged).reset_index(drop=True)
    shore, fenders = L.shore_parts(merged, split_fenders=True)
    block = shore + list(haz[haz.blocking].geometry.values)
    # Bridge openings (bascule/swing spans) are only 25-40 m wide between
    # land, piers and fenders: within bridge_zone_m of a bridge over water the
    # clearance is bridge_clearance_m instead of clearance_m.
    br = merged.get("BRIDGE")
    bridge_zone = shapely.Polygon()
    if br is not None and len(br):
        brw = br[br.intersects(water)]
        bridge_zone = shapely.union_all(shapely.buffer(brw.geometry.values, p.bridge_zone_m, quad_segs=4))
    far = shapely.union_all(shapely.buffer(block, C + 2 * s))
    near = shapely.union_all(shapely.buffer(block, p.bridge_clearance_m + 2 * s))
    B = shapely.union_all([far.difference(bridge_zone), near.intersection(bridge_zone),
                           shapely.union_all(shapely.buffer(fenders, p.fender_clearance_m + 2 * s))])
    Bs = shapely.make_valid(shapely.simplify(B, s, preserve_topology=True))
    dom = shapely.make_valid(water.difference(Bs))
    parts = [g for g in shapely.get_parts(dom) if g.geom_type == "Polygon" and g.area >= p.min_part_m2]
    domain = shapely.union_all(parts)
    log(f"domain: {domain.area / 1e6:.1f} km2 in {len(parts)} parts")
    shore_union = shapely.union_all(shapely.buffer(shore + fenders, 0.01))
    rings = []
    grown = 0.0
    base = Bs  # clearance + 2s from obstacles (fenders: less; rings are cost-only)
    for r in p.shore_rings_m[:2]:
        g = shapely.simplify(shapely.buffer(base, r - (C + 2 * s), quad_segs=4), p.ring_simplify_m)
        rings.append(shapely.make_valid(g))
    log("shore rings")
    hz_known = haz[~haz.blocking]
    hz_zone = gpd.GeoDataFrame({"valsou_dm": hz_known.valsou_dm.values},
                               geometry=shapely.buffer(hz_known.geometry.values, C + 0.1))
    hz_ring = shapely.make_valid(shapely.simplify(
        shapely.union_all(shapely.buffer(haz.geometry.values, p.hazard_ring_m, quad_segs=4)), 2.0))
    snd = L.soundings(merged)
    refine = sounding_refinement(areas, snd, p)
    lower = sounding_lowering(areas, refine, snd, p)
    log(f"soundings: {len(snd)}; refinement regions {len(refine)}, lowering zones {len(lower)}")
    over = L.overhead(merged, water)
    if len(over):
        rad = np.where(over.geom_type.isin(["Polygon", "MultiPolygon"]), p.overhead_poly_buffer_m,
                       p.overhead_line_buffer_m)
        over["foot"] = shapely.buffer(over.geometry.values, rad)
    chan, highway = L.channels(merged, region, crs)
    chan = chan[chan.intersects(domain)].reset_index(drop=True)
    chan["geometry"] = [shapely.simplify(g, 2.0) if src == 4 else g
                        for g, src in zip(chan.geometry.values, chan.source.values)]
    hw = shapely.make_valid(shapely.simplify(
        shapely.union_all(shapely.buffer(highway.geometry.values, p.highway_buffer_m, quad_segs=4)), 2.0)) \
        if len(highway) else shapely.Polygon()
    regs = L.reg_areas(merged).reset_index(drop=True)
    qual = L.quality(merged).reset_index(drop=True)
    qual["geometry"] = shapely.make_valid(shapely.simplify(qual.geometry.values, 5.0, preserve_topology=True))
    gulf = gulf_mask(shore_union, region, crs)
    log("prepared all layers")
    return dict(areas=areas, water=water, domain=domain, obst_buffer=Bs, shore_union=shore_union,
                rings=rings, haz=haz, hz_zone=hz_zone, hz_ring=hz_ring, snd=snd, refine=refine,
                lower=lower, over=over, chan=chan, highway=hw, regs=regs, qual=qual, gulf=gulf,
                block_raw=shapely.union_all(block), bridge_zone=bridge_zone, fender_raw=shapely.union_all(fenders) if fenders else shapely.Polygon())


def constraint_lines(prep):
    dom = prep["domain"]
    lines = [shapely.boundary(dom)]
    wet = prep["areas"][prep["areas"].d1 >= 0]
    lines += list(shapely.boundary(wet.geometry.values))
    lines += list(shapely.boundary(prep["refine"].geometry.values))
    lines += list(shapely.boundary(prep["lower"].geometry.values))
    lines += list(shapely.boundary(prep["hz_zone"].geometry.values))
    lines.append(shapely.boundary(prep["hz_ring"]))
    lines += [shapely.boundary(r) for r in prep["rings"]]
    if len(prep["over"]):
        lines += list(shapely.boundary(prep["over"].foot.values))
    lines += list(shapely.boundary(prep["chan"].geometry.values))
    lines.append(shapely.boundary(prep["highway"]))
    lines += list(shapely.boundary(prep["regs"].geometry.values))
    lines += list(shapely.boundary(prep["qual"].geometry.values))
    if prep["gulf"] is not None:
        lines.append(shapely.boundary(prep["gulf"]))
    lines = [g for g in lines if g is not None and not g.is_empty]
    # keep only what is near the domain (cheap bbox + prepared intersects)
    env = shapely.buffer(dom, 2.0)
    shapely.prepare(env)
    lines = [g for g in lines if env.intersects(g)]
    return lines


def grid_lines(bbox_units, step_units):
    x0, y0, x1, y1 = bbox_units
    xs = np.arange((x0 // step_units) * step_units, x1 + step_units, step_units)
    ys = np.arange((y0 // step_units) * step_units, y1 + step_units, step_units)
    return ([LineString([(x, y0 - step_units), (x, y1 + step_units)]) for x in xs] +
            [LineString([(x0 - step_units, y), (x1 + step_units, y)]) for y in ys])


# --------------------------------------------------------------------------- faces and CDT

def ring_area2(coords):
    c = coords.astype(np.int64)
    c = c - c.min(axis=0)
    x, y = c[:-1, 0], c[:-1, 1]
    x2, y2 = c[1:, 0], c[1:, 1]
    return int((x * y2 - x2 * y).sum())


def polygon_area2(poly):
    a = abs(ring_area2(shapely.get_coordinates(poly.exterior)))
    for h in poly.interiors:
        a -= abs(ring_area2(shapely.get_coordinates(h)))
    return a


def faces_and_triangles(lines_u, domain_u, bbox_u, p):
    lines_u = list(lines_u) + grid_lines(bbox_u, int(round(p.grid_deg * UNITS)))
    log(f"noding {len(lines_u)} lines, {sum(shapely.get_num_coordinates(lines_u))} coords")
    noded = shapely.union_all(np.asarray(lines_u, dtype=object), grid_size=1.0)
    log("noded")
    faces = np.asarray(shapely.get_parts(shapely.polygonize(shapely.get_parts(noded))), dtype=object)
    log(f"polygonized: {len(faces)} faces")
    shapely.prepare(domain_u)
    rp = shapely.point_on_surface(faces)
    keep = shapely.contains(domain_u, rp)
    faces = faces[keep]
    log(f"faces in domain: {len(faces)}")
    cdt = shapely.constrained_delaunay_triangles(faces)
    counts = shapely.get_num_geometries(cdt)
    parts = shapely.get_parts(cdt)
    xy = shapely.get_coordinates(shapely.get_exterior_ring(parts)).reshape(len(parts), 4, 2)[:, :3]
    face_of = np.repeat(np.arange(len(faces)), counts)
    log(f"CDT: {len(parts)} triangles")
    flat = np.rint(xy.reshape(-1, 2)).astype(np.int64)
    assert np.all(flat == xy.reshape(-1, 2)), "CDT produced off-grid coordinates"
    coords, inv = np.unique(flat, axis=0, return_inverse=True)
    tris = inv.reshape(-1, 3).astype(np.int64)
    tris, face_of, n_flat = topology.fix_flat(coords, tris, face_of)
    tris, face_of, n_tj = topology.fix_tjunctions(coords, tris, face_of)
    tris, face_of, n_flat2 = topology.fix_flat(coords, tris, face_of)
    used = np.unique(tris)
    remap = -np.ones(len(coords), np.int64)
    remap[used] = np.arange(len(used))
    coords = coords[used]
    tris = remap[tris]
    area2 = sum(polygon_area2(f) for f in faces)
    rep = topology.validate(coords, tris, area2)
    rep.update({"faces": int(len(faces)), "flat_removed": n_flat + n_flat2, "tjunction_splits": n_tj})
    log(f"topology: {rep}")
    return faces, coords, tris, face_of, rep


# --------------------------------------------------------------------------- attributes

def face_sample_points(coords, tris, face_of, n_faces):
    """Incentre of the triangle with the largest inradius in each face."""
    P = coords[tris].astype(float)
    a = np.linalg.norm(P[:, 1] - P[:, 2], axis=1)
    b = np.linalg.norm(P[:, 2] - P[:, 0], axis=1)
    c = np.linalg.norm(P[:, 0] - P[:, 1], axis=1)
    o = topology.orient2(coords, tris).astype(float)
    per = a + b + c
    r = o / np.maximum(per, 1e-9)
    inc = (a[:, None] * P[:, 0] + b[:, None] * P[:, 1] + c[:, None] * P[:, 2]) / per[:, None]
    order = np.lexsort((-r, face_of))
    first = np.ones(len(order), bool)
    first[1:] = face_of[order][1:] != face_of[order][:-1]
    best = order[first]
    pts = np.full((n_faces, 2), np.nan)
    rad = np.zeros(n_faces)
    pts[face_of[best]] = inc[best]
    rad[face_of[best]] = r[best]
    return pts, rad


def _pairs(geoms, pts, predicate, distance=None):
    if len(geoms) == 0:
        return np.zeros(0, int), np.zeros(0, int)
    tree = shapely.STRtree(np.asarray(geoms, dtype=object))
    if predicate == "dwithin":
        i, j = tree.query(pts, predicate="dwithin", distance=distance)
    else:
        i, j = tree.query(pts, predicate=predicate)
    return i, j


def face_attributes(prep, pts_m, p, region):
    n = len(pts_m)
    pts = shapely.points(pts_m)
    r = p.sample_radius_units * 0.0111  # metres (1 unit ~ 1.1 cm in latitude)
    areas = prep["areas"]
    wet = areas[areas.d1 >= 0]
    # --- depth area least depth (conservative: min over the sample disk)
    depth = np.full(n, 32767, np.int64)
    nareas = np.zeros(n, np.int64)
    one_area = np.full(n, -1, np.int64)
    i, j = _pairs(wet.geometry.values, pts, "dwithin", r)
    np.minimum.at(depth, i, wet.d1.values[j])
    np.add.at(nareas, i, 1)
    one_area[i] = wet.index.values[j]
    miss = nareas == 0
    if miss.any():  # sliver healed by the closing: least depth within 50 m
        i, j = _pairs(wet.geometry.values, pts[miss], "dwithin", 50.0)
        dm = np.full(miss.sum(), 32767, np.int64)
        np.minimum.at(dm, i, wet.d1.values[j])
        depth[np.flatnonzero(miss)] = dm
    depth[depth == 32767] = P.DEPTH_NONE
    flags = np.zeros(n, np.int64)
    # --- refinement (raise) only where exactly one depth area is involved
    refined = depth.copy()
    ref = prep["refine"]
    i, j = _pairs(ref.geometry.values, pts, "within")
    ok = (nareas[i] == 1) & (one_area[i] == ref.area_idx.values[j]) & (ref.refined_dm.values[j] > depth[i])
    refined[i[ok]] = ref.refined_dm.values[j][ok]
    flags[i[ok]] |= P.F_REFINED
    band = depth.copy()
    # --- lowering by shallower soundings and by known-depth hazards
    for g, vals, flag in ((prep["lower"].geometry.values, prep["lower"].depth_dm.values, 0),
                          (prep["hz_zone"].geometry.values, prep["hz_zone"].valsou_dm.values, P.F_HAZARD_DEPTH)):
        i, j = _pairs(g, pts, "dwithin", r)
        lowv = np.full(n, 32767, np.int64)
        np.minimum.at(lowv, i, vals[j])
        hit = lowv < 32767
        refined = np.where(hit & (refined != P.DEPTH_NONE), np.minimum(refined, lowv), refined)
        band = np.where(hit & (band != P.DEPTH_NONE), np.minimum(band, lowv), band)
        if flag:
            flags[hit] |= flag
    # a refined value that was lowered below the band value is no refinement
    flags[refined <= band] &= ~P.F_REFINED
    # --- near hazard, shore class, open Gulf
    hz = prep["hz_ring"]
    shapely.prepare(hz)
    flags[shapely.intersects(hz, shapely.buffer(pts, r, quad_segs=2))] |= P.F_NEAR_HAZARD
    shore = np.full(n, 3, np.int64)
    for k in reversed(range(len(prep["rings"]))):
        g = prep["rings"][k]
        shapely.prepare(g)
        shore[shapely.intersects(g, pts)] = k
    flags |= shore << P.SHORE_SHIFT
    if prep["gulf"] is not None:
        shapely.prepare(prep["gulf"])
        flags[shapely.contains(prep["gulf"], pts)] |= P.F_OUTSIDE
    # --- channels
    chan = prep["chan"]
    channel = np.full(n, P.ID_NONE, np.int64)
    maint = np.full(n, P.DEPTH_NONE, np.int64)
    i, j = _pairs(chan.geometry.values, pts, "within")
    if len(i):
        flags[i] |= P.F_CHANNEL
        pri = chan.source.values[j] * 100000 + j
        best = np.full(n, 1 << 40, np.int64)
        np.minimum.at(best, i, pri)
        has = best < (1 << 40)
        channel[has] = best[has] % 100000
        m = (chan.source.values[j] == 1) & (chan.maint_dm.values[j] > 0)
        mv = np.full(n, 32767, np.int64)
        np.minimum.at(mv, i[m], chan.maint_dm.values[j][m])
        maint = np.where(mv < 32767, mv, maint)
    hw = prep["highway"]
    if not hw.is_empty:
        shapely.prepare(hw)
        flags[shapely.contains(hw, pts)] |= P.F_HIGHWAY | P.F_CHANNEL
    # --- regulated areas (any part of the sample disk)
    regs = prep["regs"]
    area = np.full(n, P.ID_NONE, np.int64)
    i, j = _pairs(regs.geometry.values, pts, "dwithin", r)
    if len(i):
        kind = regs.kind.values[j]
        for k, f in ((1, P.F_PROHIBITED), (2, P.F_RESTRICTED), (3, P.F_CAUTION)):
            flags[i[kind == k]] |= f
        pri = kind * 100000 + j
        best = np.full(n, 1 << 40, np.int64)
        np.minimum.at(best, i, pri)
        has = best < (1 << 40)
        area[has] = best[has] % 100000
    # --- overhead
    over = prep["over"]
    clear = np.full(n, P.CLR_NONE, np.int64)
    ovid = np.full(n, P.ID_NONE, np.int64)
    if len(over):
        i, j = _pairs(over.foot.values, pts, "dwithin", r)
        kinds = over.kind.values[j]
        opens = over.opens.values[j].astype(bool)
        cdm = over.clr_dm.values[j]
        solid = (kinds == 1) & ~opens & (cdm == -32768)  # bridge part without clearance: solid
        known = np.where(solid, 0, cdm)
        unknown = known == -32768
        all_open = np.ones(n, bool)
        anyov = np.zeros(n, bool)
        anyov[i] = True
        np.logical_and.at(all_open, i, opens)
        kmin = np.full(n, 1 << 30, np.int64)
        np.minimum.at(kmin, i[~unknown], known[~unknown])
        anyunk = np.zeros(n, bool)
        anyunk[i[unknown]] = True
        clear = np.where(anyov, np.where(kmin < (1 << 30), kmin, P.CLR_UNKNOWN), P.CLR_NONE)
        clear = np.minimum(clear, P.CLR_NONE)
        flags[anyov & all_open] |= P.F_OPENING
        flags[anyunk] |= P.F_UNKNOWN_CLR
        # representative object: lowest known clearance, else an unknown one
        pri = np.where(unknown, 1 << 20, known) * 100000 + j
        best = np.full(n, 1 << 50, np.int64)
        np.minimum.at(best, i, pri)
        ovid[anyov] = best[anyov] % 100000
    # --- quality: worst CATZOC, oldest survey year
    qual = prep["qual"]
    cz = np.zeros(n, np.int64)
    yr = np.zeros(n, np.int64)
    i, j = _pairs(qual.geometry.values, pts, "within")
    if len(i):
        np.maximum.at(cz, i, qual.catzoc.values[j])
        y = qual.year.values[j]
        yy = np.full(n, 99999, np.int64)
        np.minimum.at(yy, i[y > 0], y[y > 0])
        yr = np.where(yy < 99999, yy, 0)
    qbyte = np.array([L.quality_byte(c, y) for c, y in zip(cz, yr)], np.int64)
    return {"depth_dm": refined, "band_depth_dm": band, "maint_dm": maint, "clearance_dm": clear,
            "flags": flags, "channel": channel, "overhead": ovid, "area": area, "quality": qbyte}


# --------------------------------------------------------------------------- side tables

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


def _geom_records(geoms_u):
    """Split geometries into single parts: (part geometries, source index)."""
    parts, src = [], []
    for k, g in enumerate(geoms_u):
        for q in shapely.get_parts(g):
            if q.is_empty:
                continue
            parts.append(q)
            src.append(k)
    return parts, np.array(src, int)


def _gtype_coords(q):
    if q.geom_type == "Point":
        return 1, shapely.get_coordinates(q)
    if q.geom_type in ("LineString", "LinearRing"):
        return 2, shapely.get_coordinates(q)
    if q.geom_type == "Polygon":
        c = shapely.get_coordinates(q.exterior)[:-1]
        return 3, c
    raise ValueError(q.geom_type)


def side_tables(prep, U, S: Strings):
    geom_pool = []
    npool = 0

    def add_geom(q):
        nonlocal npool
        gt, c = _gtype_coords(q)
        c = np.rint(c).astype(np.int64)
        first = npool
        geom_pool.append(c)
        npool += len(c)
        rp = np.rint(shapely.get_coordinates(shapely.point_on_surface(q))[0]).astype(np.int64)
        return gt, first, len(c), rp

    # overhead: one record per input object (multi-part geometries keep their first part's rep point
    # but list every part as its own record)
    over = prep["over"]
    ov_records, ov_map = [], {}
    if len(over):
        gu = U.geoms_to_units(over.geometry.values)
        for k, (g, row) in enumerate(zip(gu, over.itertuples())):
            ov_map[k] = len(ov_records)
            for q in shapely.get_parts(g):
                gt, first, cnt, rp = add_geom(q)
                clr = row.clr_dm
                fl = 1 if row.opens else 0
                if row.kind == 1 and not row.opens and clr == -32768:
                    clr, fl = 0, fl | 2  # not charted: treated as solid
                ov_records.append((row.kind, fl, row.catbrg,
                                   P.CLR_UNKNOWN if clr == -32768 else clr,
                                   P.CLR_UNKNOWN if row.open_dm == -32768 else row.open_dm,
                                   P.CLR_UNKNOWN if row.hor_dm == -32768 else row.hor_dm, 0,
                                   S(row.OBJNAM), rp[0], rp[1], first, cnt, gt, (0,) * 7))
    ovh = np.array(ov_records, dtype=P.OVHD_DT)
    # hazards (all of them, raw geometry)
    haz = prep["haz"]
    hz_records = []
    gu = U.geoms_to_units(haz.geometry.values)
    for g, row in zip(gu, haz.itertuples()):
        for q in shapely.get_parts(g):
            gt, first, cnt, rp = add_geom(q)
            hz_records.append((row.cls, min(255, max(0, row.WATLEV)), min(255, max(0, row.cat)), gt,
                               row.valsou_dm, 0, rp[0], rp[1], first, cnt, S(row.OBJNAM), 0))
    hzd = np.array(hz_records, dtype=P.HAZD_DT)
    # channels
    chan = prep["chan"]
    rp = U.geoms_to_units(shapely.point_on_surface(chan.geometry.values)) if len(chan) else []
    ch_records = []
    for q, row in zip(rp, chan.itertuples()):
        c = np.rint(shapely.get_coordinates(q)[0]).astype(np.int64)
        ch_records.append((row.source, 1 if row.icw else 0, row.maint_dm, row.auth_dm, 0, S(row.name),
                           S(row.ident), S(row.desc), row.date, c[0], c[1]))
    chn = np.array(ch_records, dtype=P.CHAN_DT)
    regs = prep["regs"]
    rp = U.geoms_to_units(shapely.point_on_surface(regs.geometry.values)) if len(regs) else []
    ar_records = []
    for q, row in zip(rp, regs.itertuples()):
        c = np.rint(shapely.get_coordinates(q)[0]).astype(np.int64)
        name = row.OBJNAM if isinstance(row.OBJNAM, str) and row.OBJNAM else (
            {1: "Entry prohibited area", 2: "Restricted area", 3: "Caution area"}[row.kind])
        ar_records.append((row.kind, 1 if row.cls == "RESARE" else 2, 0, S(name), S(row.INFORM),
                           c[0], c[1], (0, 0, 0)))
    ars = np.array(ar_records, dtype=P.AREA_DT)
    geom = np.concatenate(geom_pool).astype(np.int32) if geom_pool else np.zeros((0, 2), np.int32)
    return ovh, ov_map, hzd, chn, ars, geom


# --------------------------------------------------------------------------- build

def build_pack(region, merged, metas, merge_stats=None, out_path=None) -> tuple[P.Pack, dict]:
    t0 = time.time()
    p = region.params
    prep = prepare(region, merged)
    U = Units(region.crs)
    lines = constraint_lines(prep)
    lines_u = U.geoms_to_units(lines)
    domain_u = U.geoms_to_units([prep["domain"]])[0]
    b = [int(round(v * UNITS)) for v in region.bbox]
    faces, coords, tris, face_of, topo = faces_and_triangles(lines_u, domain_u, b, p)
    if not topo["ok"]:
        raise RuntimeError(f"mesh topology validation failed: {topo}")
    pts_u, inr = face_sample_points(coords, tris, face_of, len(faces))
    pts_m = U.units_to_metric(pts_u)
    fa = face_attributes(prep, pts_m, p, region)
    log("face attributes")
    S = Strings()
    ovh, ov_map, hzd, chn, ars, geom = side_tables(prep, U, S)
    # face attribute overhead index -> record index
    ov = fa["overhead"]
    fa["overhead"] = np.array([ov_map.get(int(x), P.ID_NONE) if x != P.ID_NONE else P.ID_NONE for x in ov])
    attrs_t = {k: np.asarray(v)[face_of] for k, v in fa.items()}
    verts, ctris, perm = P.canonicalize(coords, tris)
    attrs_t = {k: v[perm] for k, v in attrs_t.items()}
    vmin, vmax = verts.min(0), verts.max(0)
    bbox = (min(b[0], int(vmin[0])), min(b[1], int(vmin[1])), max(b[2], int(vmax[0])), max(b[3], int(vmax[1])))
    nbr, dup = P.adjacency(ctris)
    assert dup == 0
    grid = P.build_grid(verts, ctris, bbox, int(round(p.index_cell_deg * UNITS)))
    used = set(merge_stats.get("cells_with_area", [])) if merge_stats else set(m["name"] for m in metas)
    srcs = []
    for m in sorted(metas, key=lambda m: m["name"]):
        srcs.append((S(m["name"]), int(m["edtn"]), int(m["updn"]), int(str(m["isdt"]).replace("-", "") or 0),
                     int(m["cscale"]), int(m["name"][2]), 1 if m["name"] in used else 0, (0,) * 6))
    sources = np.array(srcs, dtype=P.SRCS_DT)
    data_date = int(max((s["issue_date"] for s in sources if s["used"]), default=0))
    now = dt.datetime.now(dt.timezone.utc)
    info = {"builder": f"enc_routing {BUILDER_VERSION}", "params": json.dumps(p.__dict__, default=list),
            "params_key": p.key(), "crs": region.crs, "cells": int(sources["used"].sum()),
            "topology": json.dumps({k: topo[k] for k in ("faces", "flat_removed", "tjunction_splits",
                                                          "bowtie_vertices", "boundary_edges")}),
            "ncf": "USACE National Channel Framework (ChannelReach, ChannelLine)",
            "attribution": "NOAA ENC and USACE NCF data; not for navigation"}
    pack = P.Pack(region_id=region.rid, bbox=bbox, data_date=data_date,
                  build_date=now.year * 10000 + now.month * 100 + now.day,
                  build_time=now.hour * 10000 + now.minute * 100 + now.second,
                  clearance_dm=int(round(p.clearance_m * 10)), check_dm=int(round((p.clearance_m - 1.0) * 10)),
                  shore_rings_m=tuple(int(x) for x in (list(p.shore_rings_m[:2]) + [0, 0])[:2]),
                  vertices=verts, tris=ctris, attrs=attrs_t, strings=S.items, overhead=ovh, hazards=hzd,
                  channels=chn, areas=ars, sources=sources, geom=geom, info=info, nbr=nbr, grid=grid)
    report = {"topology": topo, "vertices": int(len(verts)), "triangles": int(len(ctris)),
              "faces": int(len(faces)), "build_seconds": round(time.time() - t0, 1),
              "domain_km2": round(prep["domain"].area / 1e6, 1)}
    return pack, prep, report
