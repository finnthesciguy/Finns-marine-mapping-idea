"""Navigation mesh builder, per tile: merged ENC + NCF layers -> triangles
with attributes (tiles.py drives it, assemble.py joins the tiles into a pack).

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
   M_QUAL, open-Gulf mask, the tile edges and a lat/lon grid that bounds
   triangle size (0.02 deg near shore, 0.1 deg offshore).
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

import os
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
from .config import GEO_CRS

UNITS = 1e7  # integer units per degree


def log(msg, t0=[time.time()]):
    if os.environ.get("ENC_ROUTING_VERBOSE"):
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
    try:
        tri = Delaunay(xy).simplices
    except Exception:  # noqa: BLE001 - degenerate (collinear) soundings: nothing to refine
        return gpd.GeoDataFrame({"area_idx": [], "refined_dm": [], "geometry": []}, geometry="geometry")
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

def robust_union(geoms):
    """union_all, retried on a 1 mm grid if GEOS reports a topology error."""
    geoms = [g for g in geoms if g is not None and not g.is_empty]
    if not geoms:
        return shapely.Polygon()
    try:
        return shapely.union_all(geoms)
    except shapely.errors.GEOSException:
        return shapely.union_all(shapely.make_valid(np.asarray(geoms, dtype=object)), grid_size=0.001)


def prepare_tile(merged, ncf_reach, ncf_line, gulf_ll, crs, p):
    """All input layers of one tile (with margin) in the tile's metric CRS.
    merged: {layer: GeoDataFrame in crs}; ncf_*: lon/lat GeoDataFrames;
    gulf_ll: open-Gulf polygon (lon/lat) or None. Returns a dict."""
    C, s = p.clearance_m, p.simplify_m
    areas = L.depth_areas(merged).reset_index(drop=True)
    wet = areas[areas.d1 >= 0]
    water = L.close(robust_union(wet.geometry.values), p.close_m) if len(wet) else shapely.Polygon()
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
        if len(brw):
            bridge_zone = shapely.union_all(shapely.buffer(brw.geometry.values, p.bridge_zone_m, quad_segs=4))
    far = robust_union(shapely.buffer(block, C + 2 * s))
    near = robust_union(shapely.buffer(block, p.bridge_clearance_m + 2 * s))
    B = robust_union([far.difference(bridge_zone), near.intersection(bridge_zone),
                      robust_union(shapely.buffer(fenders, p.fender_clearance_m + 2 * s))])
    Bs = shapely.make_valid(shapely.simplify(B, s, preserve_topology=True))
    dom = shapely.make_valid(water.difference(Bs))
    parts = [g for g in shapely.get_parts(dom) if g.geom_type == "Polygon" and g.area >= p.min_part_m2]
    domain = shapely.union_all(parts) if parts else shapely.Polygon()
    rings = []
    base = Bs  # clearance + 2s from obstacles (fenders: less; rings are cost-only)
    for r in p.shore_rings_m[:2]:
        g = shapely.simplify(shapely.buffer(base, r - (C + 2 * s), quad_segs=4), p.ring_simplify_m)
        rings.append(shapely.make_valid(g))
    hz_known = haz[~haz.blocking]
    hz_zone = gpd.GeoDataFrame({"valsou_dm": hz_known.valsou_dm.values},
                               geometry=shapely.buffer(hz_known.geometry.values, C + 0.1))
    hz_ring = shapely.make_valid(shapely.simplify(
        shapely.union_all(shapely.buffer(haz.geometry.values, p.hazard_ring_m, quad_segs=4)), 2.0)) \
        if len(haz) else shapely.Polygon()
    snd = L.soundings(merged)
    refine = sounding_refinement(areas, snd, p)
    lower = sounding_lowering(areas, refine, snd, p)
    over = L.overhead(merged, water)
    if len(over):
        rad = np.where(over.geom_type.isin(["Polygon", "MultiPolygon"]), p.overhead_poly_buffer_m,
                       p.overhead_line_buffer_m)
        over["foot"] = shapely.buffer(over.geometry.values, rad)
    chan, highway = L.channels(merged, ncf_reach, ncf_line, crs, p)
    chan = chan[chan.intersects(domain)].reset_index(drop=True)
    chan["geometry"] = [shapely.simplify(g, 2.0) if src == 4 else g
                        for g, src in zip(chan.geometry.values, chan.source.values)]
    hw = shapely.make_valid(shapely.simplify(
        shapely.union_all(shapely.buffer(highway.geometry.values, p.highway_buffer_m, quad_segs=4)), 2.0)) \
        if len(highway) else shapely.Polygon()
    regs = L.reg_areas(merged).reset_index(drop=True)
    qual = L.quality(merged).reset_index(drop=True)
    if len(qual):
        qual["geometry"] = shapely.make_valid(shapely.simplify(qual.geometry.values, 5.0, preserve_topology=True))
    gulf = None
    if gulf_ll is not None and not gulf_ll.is_empty:
        from pyproj import Transformer

        tr = Transformer.from_crs(GEO_CRS, crs, always_xy=True)
        gulf = shapely.make_valid(shapely.transform(gulf_ll, lambda xy: np.column_stack(tr.transform(xy[:, 0], xy[:, 1]))))
    used_cells = sorted(set(wet[wet.intersects(domain)].cell.astype(str))) if len(wet) and not domain.is_empty else []
    return dict(areas=areas, water=water, domain=domain, obst_buffer=Bs,
                rings=rings, haz=haz, hz_zone=hz_zone, hz_ring=hz_ring, snd=snd, refine=refine,
                lower=lower, over=over, chan=chan, highway=hw, regs=regs, qual=qual, gulf=gulf,
                gulf_ll=gulf_ll, used_cells=used_cells)


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
    lines = [g for g in lines if g is not None and not g.is_empty]
    # keep only what is near the domain (cheap bbox + prepared intersects)
    env = shapely.buffer(dom, 2.0)
    shapely.prepare(env)
    lines = [g for g in lines if env.intersects(g)]
    return lines


def tile_grid_lines(rect_u, box_u, coarse_u: int, fine_u: int, fine_cells):
    """Size-grid lines for a tile (units): coarse lines every coarse_u over
    the whole line box (the tile edges are among them), fine lines every
    fine_u inside the coarse cells listed in fine_cells ((i, j) offsets from
    the tile's south-west corner). All coordinates are exact integers."""
    x0, y0, x1, y1 = rect_u
    bx0, by0, bx1, by1 = box_u
    out = []
    xs = np.arange(-(-bx0 // coarse_u) * coarse_u, bx1 + 1, coarse_u)
    ys = np.arange(-(-by0 // coarse_u) * coarse_u, by1 + 1, coarse_u)
    out += [LineString([(int(x), by0), (int(x), by1)]) for x in xs]
    out += [LineString([(bx0, int(y)), (bx1, int(y))]) for y in ys]
    for i, j in fine_cells:
        cx0, cy0 = x0 + i * coarse_u, y0 + j * coarse_u
        for k in range(1, coarse_u // fine_u):
            out.append(LineString([(cx0 + k * fine_u, cy0), (cx0 + k * fine_u, cy0 + coarse_u)]))
            out.append(LineString([(cx0, cy0 + k * fine_u), (cx0 + coarse_u, cy0 + k * fine_u)]))
    return out


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


def faces_and_triangles(lines_u, domain_u, bbox_u, p, grid=None, keep_rect=None):
    """Node the constraint lines (units) on the integer grid, polygonize, keep
    the faces inside the domain (and inside keep_rect, a tile), triangulate
    them, repair and validate. grid: the size-grid lines (default: a uniform
    grid of p.grid_deg over bbox_u)."""
    if grid is None:
        grid = grid_lines(bbox_u, int(round(p.grid_deg * UNITS)))
    lines_u = list(lines_u) + list(grid)
    log(f"noding {len(lines_u)} lines, {sum(shapely.get_num_coordinates(lines_u))} coords")
    noded = shapely.union_all(np.asarray(lines_u, dtype=object), grid_size=1.0)
    log("noded")
    faces = np.asarray(shapely.get_parts(shapely.polygonize(shapely.get_parts(noded))), dtype=object)
    log(f"polygonized: {len(faces)} faces")
    shapely.prepare(domain_u)
    rp = shapely.point_on_surface(faces)
    keep = shapely.contains(domain_u, rp)
    if keep_rect is not None:
        x0, y0, x1, y1 = keep_rect
        c = shapely.get_coordinates(rp)
        keep &= (c[:, 0] > x0) & (c[:, 0] < x1) & (c[:, 1] > y0) & (c[:, 1] < y1)
    faces = faces[keep]
    if len(faces) == 0:
        rep = {"ok": True, "faces": 0, "flat_removed": 0, "tjunction_splits": 0, "area2_faces": 0,
               "area2_triangles": 0, "area_mismatch": 0, "boundary_edges": 0, "bowtie_vertices": 0}
        return faces, np.zeros((0, 2), np.int64), np.zeros((0, 3), np.int64), np.zeros(0, np.int64), rep
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


def face_attributes(prep, pts_m, p):
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
