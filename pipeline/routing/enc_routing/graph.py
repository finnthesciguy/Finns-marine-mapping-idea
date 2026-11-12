"""Navigation mesh: constrained Delaunay triangulation of all navigable water.

One mesh serves every boat. The water domain is cut into faces along every
boundary that changes what a boat may do (depth-area edges, hazard
clearance rings, bridge and overhead-cable footprints, channel limits, the
open-Gulf mask and a coarse grid that bounds triangle size). Each face is
triangulated with GEOS's constrained Delaunay triangulation (no Steiner
points, so neighbouring faces share edges exactly), and every triangle
inherits its face's attributes:

  depth_m      least charted depth (min of depth area DRVAL1 and any hazard VALSOU;
               -1 for a hazard of unknown depth)
  proj_m       USACE maintained (project) depth when inside an NCF channel reach, else NaN
  clear_m      least overhead clearance above MHW (inf when none, NaN when unknown)
  flags        bit0 channel (FAIRWY / NCF reach / near RECTRC or NAVLNE)
               bit1 opening bridge   bit2 open Gulf (outside)
               bit3 overhead object of unknown clearance

The mesh is saved as mesh.npz (vertices, triangles, neighbours, attributes),
which is the prototype of the on-phone routing pack.
"""
from __future__ import annotations

import json
import time

import geopandas as gpd
import numpy as np
import pandas as pd
import shapely
from shapely.geometry import LineString, box

from .config import FT, GEO_CRS, PILOT_BBOX, WORK_CRS, work

GRID_M = 2000.0
SIMPLIFY_M = 2.0
F_CHANNEL, F_OPENING, F_GULF, F_UNKNOWN_CLR = 1, 2, 4, 8


# ---------------------------------------------------------------- pure helpers

def triangle_adjacency(tris: np.ndarray):
    """tris: (T,3) vertex ids. Returns
    nbr (T,3): neighbour across edge k (edge k = vertices k,(k+1)%3), -1 = boundary
    n_nonmanifold: number of edges shared by more than two triangles."""
    T = len(tris)
    a = tris
    e = np.stack([np.stack([a[:, k], a[:, (k + 1) % 3]], 1) for k in range(3)], 1)  # (T,3,2)
    flat = e.reshape(-1, 2)
    key = np.sort(flat, axis=1)
    order = np.lexsort((key[:, 1], key[:, 0]))
    ks = key[order]
    same = np.all(ks[1:] == ks[:-1], axis=1)
    nbr = -np.ones(T * 3, dtype=np.int64)
    idx = np.where(same)[0]
    # count runs longer than 2
    run3 = same[1:] & same[:-1] if len(same) > 1 else np.zeros(0, bool)
    for i in idx:
        p, q = order[i], order[i + 1]
        nbr[p] = q // 3
        nbr[q] = p // 3
    return nbr.reshape(T, 3), int(run3.sum())


def orient_ccw(coords: np.ndarray, tris: np.ndarray) -> np.ndarray:
    p = coords[tris]
    cross = (p[:, 1, 0] - p[:, 0, 0]) * (p[:, 2, 1] - p[:, 0, 1]) - (p[:, 1, 1] - p[:, 0, 1]) * (p[:, 2, 0] - p[:, 0, 0])
    out = tris.copy()
    cw = cross < 0
    out[cw, 1], out[cw, 2] = tris[cw, 2], tris[cw, 1]
    return out


def _area2(coords, tris):
    p = coords[tris]
    return (p[:, 1, 0] - p[:, 0, 0]) * (p[:, 2, 1] - p[:, 0, 1]) - (p[:, 1, 1] - p[:, 0, 1]) * (p[:, 2, 0] - p[:, 0, 0])


def fix_degenerate(coords: np.ndarray, tris: np.ndarray, face_of: np.ndarray, eps: float = 1e-3):
    """GEOS's polygon CDT emits zero-area ("flat") triangles where a face
    boundary has collinear vertices (e.g. where a grid line or a neighbour's
    vertex sits on a straight edge). A flat triangle (a, b, c) with b between
    a and c hides a T-junction: the real triangle across a-c must be split at
    b so both sides share edges a-b and b-c. Repeats until none are left."""
    tris = tris.copy()
    face_of = face_of.copy()
    for _ in range(20):
        ar = np.abs(_area2(coords, tris))
        deg = np.where(ar < eps)[0]
        if len(deg) == 0:
            break
        good = np.ones(len(tris), bool)
        good[deg] = False
        emap = {}
        for t in np.where(good)[0]:
            v = tris[t]
            for k in range(3):
                a, b = int(v[k]), int(v[(k + 1) % 3])
                emap.setdefault((min(a, b), max(a, b)), []).append(int(t))
        touched = set()
        new_t, new_f = [], []
        keep = good.copy()
        for t in deg:
            v = tris[t]
            P = coords[v]
            # the middle vertex is opposite the longest edge
            L = [np.sum((P[(k + 1) % 3] - P[(k + 2) % 3]) ** 2) for k in range(3)]
            m = int(np.argmax(L))
            b = int(v[m])
            a, c = int(v[(m + 1) % 3]), int(v[(m + 2) % 3])
            if a == b or b == c or a == c:
                continue  # collapsed by rounding: just drop
            for x_t in emap.get((min(a, c), max(a, c)), []):
                if x_t in touched or not keep[x_t]:
                    continue
                xv = [int(q) for q in tris[x_t]]
                x = [q for q in xv if q not in (a, c)][0]
                keep[x_t] = False
                touched.add(x_t)
                new_t += [[a, b, x], [b, c, x]]
                new_f += [face_of[x_t], face_of[x_t]]
                break
        tris = np.concatenate([tris[keep], np.array(new_t, dtype=tris.dtype).reshape(-1, 3)])
        face_of = np.concatenate([face_of[keep], np.array(new_f, dtype=face_of.dtype)])
    ar = np.abs(_area2(coords, tris))
    ok = ar >= eps
    return orient_ccw(coords, tris[ok]), face_of[ok]


def fix_tjunctions(coords, tris, face_of, nbr, boundary, tol: float = 0.01):
    """Split triangles whose unmatched edge has other mesh vertices lying on
    it (T-junctions left over after fix_degenerate). Edges on the real domain
    boundary (`boundary`, a shapely linework) are skipped. Returns
    (tris, face_of, n_split)."""
    ti, k = np.where(nbr < 0)
    a = tris[ti, k]
    c = tris[ti, (k + 1) % 3]
    mid = (coords[a] + coords[c]) / 2
    shapely.prepare(boundary)
    inner = ~shapely.dwithin(boundary, shapely.points(mid), tol)
    if not inner.any():
        return tris, face_of, 0
    tree = shapely.STRtree(shapely.points(coords))
    drop, add_t, add_f = set(), [], []
    for t, kk, va, vc in zip(ti[inner], k[inner], a[inner], c[inner]):
        if t in drop:
            continue
        seg = shapely.LineString([coords[va], coords[vc]])
        cand = tree.query(seg, predicate="dwithin", distance=tol)
        cand = [int(v) for v in cand if v not in (va, vc)]
        if not cand:
            continue
        P, Q = coords[va], coords[vc]
        d = Q - P
        s = [float(np.dot(coords[v] - P, d) / np.dot(d, d)) for v in cand]
        chain = [va] + [v for _, v in sorted(zip(s, cand)) if 0 < _ < 1] + [vc]
        if len(chain) == 2:
            continue
        x = int(tris[t, (kk + 2) % 3])
        drop.add(int(t))
        for u, w in zip(chain[:-1], chain[1:]):
            add_t.append([u, w, x])
            add_f.append(face_of[t])
    if not drop:
        return tris, face_of, 0
    keep = np.ones(len(tris), bool)
    keep[list(drop)] = False
    tris = np.concatenate([tris[keep], np.array(add_t, dtype=tris.dtype)])
    face_of = np.concatenate([face_of[keep], np.array(add_f, dtype=face_of.dtype)])
    return orient_ccw(coords, tris), face_of, len(drop)


def triangulate_faces(faces) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    """CDT every face. Returns (coords (V,2), tris (T,3), face_index (T,))."""
    all_xy, face_of = [], []
    for i, f in enumerate(faces):
        tri = shapely.constrained_delaunay_triangles(f)
        parts = shapely.get_parts(tri)
        if len(parts) == 0:
            continue
        xy = shapely.get_coordinates(shapely.get_exterior_ring(parts))  # 4 pts per triangle
        xy = xy.reshape(len(parts), 4, 2)[:, :3, :]
        all_xy.append(xy)
        face_of.append(np.full(len(parts), i))
    xy = np.concatenate(all_xy)
    face_of = np.concatenate(face_of)
    flat = np.round(xy.reshape(-1, 2), 2)  # cm grid for vertex identity
    coords, inv = np.unique(flat, axis=0, return_inverse=True)
    tris = inv.reshape(-1, 3)
    tris, face_of = fix_degenerate(coords, tris, face_of)
    return coords, tris, face_of


# ---------------------------------------------------------------- build

def _grid_lines(bounds, step):
    x0, y0, x1, y1 = bounds
    xs = np.arange(np.floor(x0 / step) * step, x1 + step, step)
    ys = np.arange(np.floor(y0 / step) * step, y1 + step, step)
    return [LineString([(x, y0), (x, y1)]) for x in xs] + [LineString([(x0, y), (x1, y)]) for y in ys]


def _inputs():
    from .bridges import overhead_table
    from .channels import ncf_query
    from .safewater import _read, close, depth_areas, gulf_mask, hazards, obstacles

    areas = depth_areas()
    areas = areas[areas.DRVAL1.fillna(-1) >= 0].reset_index(drop=True)
    obst = obstacles()
    haz = hazards()
    over = overhead_table()
    over = over.assign(geometry=over.geometry.buffer(np.where(over.geom_type == "Polygon", 2.0, 5.0)))
    gulf = gulf_mask(obst)
    ncf = ncf_query(2).to_crs(WORK_CRS)
    ncf = ncf[ncf.geometry.notna() & ~ncf.geometry.is_empty]
    ncf = ncf.assign(geometry=shapely.make_valid(ncf.geometry.values))
    fair = _read("FAIRWY")
    tracks = pd.concat([_read("RECTRC"), _read("NAVLNE")], ignore_index=True)
    chan = shapely.union_all(list(fair.geometry.values) + list(ncf.geometry.values) +
                             list(shapely.buffer(tracks.geometry.values, 15.0)))
    return dict(areas=areas, obst=obst, haz=haz, over=over, gulf=gulf, ncf=ncf, chan=chan, close=close)


def face_geometry(inp):
    """Domain and the planar partition of it (slow: ~3 min for the pilot)."""
    t0 = time.time()
    areas, obst = inp["areas"], inp["obst"]
    domain = inp["close"](shapely.union_all(areas.geometry.values)).difference(obst)
    domain = shapely.make_valid(domain.simplify(SIMPLIFY_M))
    domain = shapely.union_all([p for p in shapely.get_parts(domain) if p.geom_type == "Polygon" and p.area > 50])
    haz = inp["haz"][inp["haz"].intersects(domain)]
    lines = [shapely.boundary(domain)]
    lines += list(shapely.boundary(shapely.simplify(areas.geometry.values, SIMPLIFY_M)))
    lines += list(shapely.boundary(haz.geometry.values))
    lines += list(shapely.boundary(inp["over"].geometry.values))
    lines.append(shapely.boundary(inp["chan"].simplify(SIMPLIFY_M)))
    # NCF reach limits separately: they vanish inside the (wider) channel union
    lines += list(shapely.boundary(inp["ncf"].geometry.values))
    lines.append(shapely.boundary(inp["gulf"]))
    lines += _grid_lines(domain.bounds, GRID_M)
    lines = [l for l in lines if l is not None and not l.is_empty]
    clip = domain.buffer(1.0)
    shapely.prepare(clip)
    lines = [l.intersection(clip) if not clip.contains(l) else l for l in lines]
    noded = shapely.union_all([l for l in lines if not l.is_empty])
    faces = list(shapely.get_parts(shapely.polygonize(shapely.get_parts(noded))))
    print(f"noding+polygonize {time.time()-t0:.1f}s, {len(faces)} raw faces")
    rp = shapely.point_on_surface(faces)
    shapely.prepare(domain)
    keep = shapely.contains(domain, rp)
    faces = [f for f, k in zip(faces, keep) if k]
    return faces, domain


def face_attributes(faces, inp) -> pd.DataFrame:
    """Per-face routing attributes, sampled at a representative point."""
    areas, haz, over, ncf, chan, gulf = (inp[k] for k in ("areas", "haz", "over", "ncf", "chan", "gulf"))
    rp = shapely.point_on_surface(faces)
    pts = gpd.GeoDataFrame({"fid": np.arange(len(faces))}, geometry=rp, crs=WORK_CRS)

    def agg(src, col, how):
        j = gpd.sjoin(pts, src[[col, "geometry"]], predicate="within", how="left")
        return np.array(j.groupby("fid")[col].agg(how).reindex(pts.fid).values, dtype=float)

    depth = agg(areas, "DRVAL1", "max")
    miss = np.isnan(depth)
    if miss.any():  # sliver healed by closing: take the nearest depth area
        j = gpd.sjoin_nearest(pts[miss], areas[["DRVAL1", "geometry"]], max_distance=50)
        depth[np.where(miss)[0]] = j.groupby("fid").DRVAL1.max().reindex(pts.fid[miss]).values
    hz = haz.assign(V=haz.VALSOU.fillna(-1.0))
    hmin = agg(hz, "V", "min")
    depth = np.where(np.isnan(hmin), depth, np.fmin(depth, hmin))

    ncf2 = ncf.assign(P=pd.to_numeric(ncf.depthmaintained, errors="coerce") * FT)
    proj = agg(ncf2, "P", "max")

    flags = np.zeros(len(faces), np.uint8)
    shapely.prepare(chan)
    flags |= np.where(shapely.contains(chan, rp), F_CHANNEL, 0).astype(np.uint8)
    shapely.prepare(gulf)
    flags |= np.where(shapely.contains(gulf, rp), F_GULF, 0).astype(np.uint8)

    # Overhead clearance. A BRIDGE part without any clearance attribute is
    # treated as a solid obstruction (clearance 0): these are approach spans
    # and deck pieces next to the charted opening/navigation span, and routing
    # under them was the main failure of the first prototype. Cables and
    # pipes without clearance stay "unknown" (NaN + flag).
    is_bridge = over.cls == "BRIDGE"
    C = over.clearance_m.astype(float).where(~(is_bridge & over.clearance_m.isna()), 0.0)
    ov = over.assign(C=C, O=over.opens.astype(float), U=C.isna().astype(float))
    j = gpd.sjoin(pts, ov[["C", "O", "U", "geometry"]], predicate="within", how="inner")
    clear = np.full(len(faces), np.inf)
    if len(j):
        g = j.groupby("fid")
        # the navigation span's known clearance wins over a co-located part
        # without one only when that part is not a bridge (bridges already 0)
        cmin = g.C.min()
        clear[cmin.index.values] = cmin.values
        op = g.O.max()
        flags[op.index.values[op.values > 0]] |= F_OPENING
        un = g.U.max()
        idx = un.index.values[un.values > 0]
        flags[idx] |= F_UNKNOWN_CLR
        allnan = g.C.apply(lambda s: s.isna().all())
        clear[allnan.index.values[allnan.values]] = np.nan
    return pd.DataFrame({"depth_m": depth, "proj_m": proj, "clear_m": clear, "flags": flags})


def run_graph(force: bool = False) -> dict:
    t0 = time.time()
    inp = _inputs()
    cache = work("graph", "faces_geom.pkl")
    if cache.exists() and not force:
        faces, domain = pd.read_pickle(cache)
    else:
        faces, domain = face_geometry(inp)
        pd.to_pickle((faces, domain), cache)
    attrs = face_attributes(faces, inp)
    t1 = time.time()
    coords, tris, face_of = triangulate_faces(faces)
    t2 = time.time()
    nbr, nonmanifold = triangle_adjacency(tris)
    tris, face_of, n_tj = fix_tjunctions(coords, tris, face_of, nbr, shapely.boundary(domain))
    nbr, nonmanifold = triangle_adjacency(tris)
    _, _, n_tj_left = fix_tjunctions(coords, tris, face_of, nbr, shapely.boundary(domain))
    t3 = time.time()
    a = attrs.iloc[face_of].reset_index(drop=True)
    dest = work("graph", "mesh.npz")
    origin = coords.min(axis=0).round(-3)
    np.savez(dest, coords=coords, tris=tris.astype(np.int32), nbr=nbr.astype(np.int32),
             depth_m=a.depth_m.values.astype(np.float32), proj_m=a.proj_m.values.astype(np.float32),
             clear_m=a.clear_m.values.astype(np.float32), flags=a["flags"].values.astype(np.uint8),
             origin=origin)
    packed = pack_bytes(coords, tris, nbr, a)
    n_edges_interior = int((nbr >= 0).sum() // 2)
    rep = {
        "faces": len(faces), "vertices": int(len(coords)), "triangles": int(len(tris)),
        "interior_edges": n_edges_interior, "boundary_edges": int((nbr < 0).sum()),
        "nonmanifold_edges": nonmanifold,
        "tjunction_triangles_split": n_tj, "tjunctions_remaining": n_tj_left,
        "mesh_area_km2": round(float(domain.area) / 1e6, 1),
        "seconds": {"faces": round(t1 - t0, 1), "cdt": round(t2 - t1, 1), "adjacency": round(t3 - t2, 1)},
        "pack_bytes": packed,
        "depth_classes_m": sorted(set(np.round(a.depth_m.dropna().values, 1).tolist()))[:30],
    }
    work("reports", "graph.json").write_text(json.dumps(rep, indent=1))
    return rep


def pack_bytes(coords, tris, nbr, a) -> dict:
    """Size of a compact binary pack: vertices int32 cm offsets (8 B), per
    triangle 3x uint32 vertex + 3x int32 neighbour (24 B) + depth int16 dm,
    proj uint8 ft, clearance uint16 dm, flags uint8 (6 B). Also zlib size."""
    import zlib

    origin = coords.min(axis=0)
    v = np.round((coords - origin) * 100).astype(np.int32)
    t = tris.astype(np.uint32)
    n = nbr.astype(np.int32)
    d = np.nan_to_num(np.round(a.depth_m.values * 10), nan=-32768).clip(-32768, 32767).astype(np.int16)
    p = np.nan_to_num(np.round(a.proj_m.values / FT), nan=0).clip(0, 255).astype(np.uint8)
    c = a.clear_m.values
    c = np.where(np.isinf(c), 65535, np.where(np.isnan(c), 65534, np.round(c * 10))).clip(0, 65535).astype(np.uint16)
    f = a["flags"].values.astype(np.uint8)
    blobs = [v.tobytes(), t.tobytes(), n.tobytes(), d.tobytes(), p.tobytes(), c.tobytes(), f.tobytes()]
    raw = sum(len(b) for b in blobs)
    comp = sum(len(zlib.compress(b, 9)) for b in blobs)
    # delta-encode vertex ids per triangle helps compression a lot
    return {"raw": raw, "zlib": comp, "bytes_per_triangle_raw": round(raw / len(tris), 1)}
