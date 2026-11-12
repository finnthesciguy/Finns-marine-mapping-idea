"""Exact-integer mesh repair and topology validation.

All coordinates are int64 in 1e-7 degree units, so orientation and
collinearity tests are exact.
"""
from __future__ import annotations

import numpy as np


def orient2(p, tris):
    """Twice the signed area of each triangle (int64, exact)."""
    a = p[tris[:, 0]]
    b = p[tris[:, 1]]
    c = p[tris[:, 2]]
    return (b[:, 0] - a[:, 0]) * (c[:, 1] - a[:, 1]) - (b[:, 1] - a[:, 1]) * (c[:, 0] - a[:, 0])


def make_ccw(p, tris):
    o = orient2(p, tris)
    t = tris.copy()
    cw = o < 0
    t[cw, 1], t[cw, 2] = tris[cw, 2], tris[cw, 1]
    return t


def _edge_map(tris, keep):
    emap = {}
    for t in np.flatnonzero(keep):
        v = tris[t]
        for k in range(3):
            a, b = int(v[k]), int(v[(k + 1) % 3])
            emap.setdefault((min(a, b), max(a, b)), []).append(int(t))
    return emap


def fix_flat(p, tris, face_of, max_iter=50):
    """Remove zero-area triangles. A flat triangle (a, b, c) with b strictly
    between a and c stands for a T-junction: the triangle across edge a-c is
    split at b into (a, b, x) and (b, c, x). Repeats until none are left.
    Returns (tris, face_of, n_flat_removed)."""
    removed = 0
    for _ in range(max_iter):
        ar = orient2(p, tris)
        deg = np.flatnonzero(ar == 0)
        if len(deg) == 0:
            break
        removed += len(deg)
        keep = ar != 0
        emap = _edge_map(tris, keep)
        touched = set()
        new_t, new_f = [], []
        for t in deg:
            v = [int(x) for x in tris[t]]
            if len(set(v)) < 3:
                continue
            P = p[v]
            L = [int(((P[(k + 1) % 3] - P[(k + 2) % 3]) ** 2).sum()) for k in range(3)]
            m = int(np.argmax(L))
            b = v[m]
            a, c = v[(m + 1) % 3], v[(m + 2) % 3]
            for xt in emap.get((min(a, c), max(a, c)), []):
                if xt in touched or not keep[xt]:
                    continue
                x = [q for q in (int(z) for z in tris[xt]) if q not in (a, c)][0]
                keep[xt] = False
                touched.add(xt)
                new_t += [[a, b, x], [b, c, x]]
                new_f += [face_of[xt], face_of[xt]]
                break
        tris = np.concatenate([tris[keep], np.array(new_t, dtype=tris.dtype).reshape(-1, 3)])
        face_of = np.concatenate([face_of[keep], np.array(new_f, dtype=face_of.dtype)])
    ar = orient2(p, tris)
    ok = ar != 0
    return make_ccw(p, tris[ok]), face_of[ok], removed


def boundary_edges(tris):
    """Directed edges (a, b) with no reverse twin, and their (triangle, k)."""
    a = tris.reshape(-1)
    b = tris[:, [1, 2, 0]].reshape(-1)
    nv = int(tris.max()) + 1
    key = a.astype(np.int64) * nv + b
    rkey = b.astype(np.int64) * nv + a
    s = np.sort(key)
    pos = np.clip(np.searchsorted(s, rkey), 0, len(s) - 1)
    has = s[pos] == rkey
    idx = np.flatnonzero(~has)
    return idx // 3, idx % 3


def vertices_on_edges(p, tris, ti, ki, cell=2000):
    """For the edges (tris[ti,ki], tris[ti,(ki+1)%3]) find vertices lying
    strictly inside them (exact). Returns list of (edge index, [vertex ids
    sorted along the edge])."""
    a = tris[ti, ki]
    c = tris[ti, (ki + 1) % 3]
    P, Q = p[a], p[c]
    # bucket vertices on a grid
    g = p // cell
    from collections import defaultdict
    buckets = defaultdict(list)
    for i, (gx, gy) in enumerate(map(tuple, g)):
        buckets[(gx, gy)].append(i)
    out = []
    lo = np.minimum(P, Q) // cell
    hi = np.maximum(P, Q) // cell
    for e in range(len(ti)):
        if (hi[e] - lo[e]).max() > 50:
            cand = np.flatnonzero((p[:, 0] >= min(P[e, 0], Q[e, 0])) & (p[:, 0] <= max(P[e, 0], Q[e, 0]))
                                  & (p[:, 1] >= min(P[e, 1], Q[e, 1])) & (p[:, 1] <= max(P[e, 1], Q[e, 1])))
        else:
            cand = []
            for gx in range(lo[e, 0], hi[e, 0] + 1):
                for gy in range(lo[e, 1], hi[e, 1] + 1):
                    cand += buckets.get((gx, gy), [])
            cand = np.array(cand, dtype=np.int64)
        if len(cand) == 0:
            continue
        cand = cand[(cand != a[e]) & (cand != c[e])]
        if len(cand) == 0:
            continue
        d = Q[e] - P[e]
        w = p[cand] - P[e]
        cross = d[0] * w[:, 1] - d[1] * w[:, 0]
        dot = d[0] * w[:, 0] + d[1] * w[:, 1]
        L2 = d[0] * d[0] + d[1] * d[1]
        on = (cross == 0) & (dot > 0) & (dot < L2)
        if on.any():
            vs = cand[on]
            out.append((e, [int(v) for v in vs[np.argsort(dot[on])]]))
    return out


def fix_tjunctions(p, tris, face_of):
    """Split every triangle whose boundary edge has a mesh vertex strictly
    inside it (exact test). Returns (tris, face_of, n_split)."""
    ti, ki = boundary_edges(tris)
    hits = vertices_on_edges(p, tris, ti, ki)
    if not hits:
        return tris, face_of, 0
    drop, add_t, add_f = set(), [], []
    for e, chain in hits:
        t, k = int(ti[e]), int(ki[e])
        if t in drop:
            continue
        a, c, x = int(tris[t, k]), int(tris[t, (k + 1) % 3]), int(tris[t, (k + 2) % 3])
        pts = [a] + chain + [c]
        drop.add(t)
        for u, w in zip(pts[:-1], pts[1:]):
            add_t.append([u, w, x])
            add_f.append(face_of[t])
    keep = np.ones(len(tris), bool)
    keep[list(drop)] = False
    tris = np.concatenate([tris[keep], np.array(add_t, dtype=tris.dtype)])
    face_of = np.concatenate([face_of[keep], np.array(add_f, dtype=face_of.dtype)])
    return make_ccw(p, tris), face_of, len(drop)


def validate(p, tris, expected_area2=None) -> dict:
    """Topology checks. Returns a report; report['ok'] is False when any of
    the hard rules fails:
      1. every triangle has strictly positive orientation (CCW, non-flat);
      2. no two triangles share a directed edge (=> every undirected edge is
         used by at most two triangles, with opposite orientation:
         manifold, consistently oriented);
      3. no vertex lies strictly inside a boundary edge (no T-junctions);
      4. no duplicate vertices and no unreferenced vertices;
      5. (if expected_area2 is given) the triangles' total doubled area
         equals the doubled area of the faces they triangulate (no overlaps,
         no gaps, exact integer arithmetic).
    Bow-tie vertices (two parts of the domain touching at one point) are
    counted but allowed: they cannot carry a route because routes cross
    edges, never bare vertices."""
    rep = {}
    o = orient2(p, tris)
    rep["non_positive_triangles"] = int((o <= 0).sum())
    a = tris.reshape(-1).astype(np.int64)
    b = tris[:, [1, 2, 0]].reshape(-1).astype(np.int64)
    nv = len(p)
    key = np.sort(a * nv + b)
    rep["duplicate_directed_edges"] = int((key[1:] == key[:-1]).sum())
    ti, ki = boundary_edges(tris)
    rep["boundary_edges"] = int(len(ti))
    rep["tjunctions"] = len(vertices_on_edges(p, tris, ti, ki))
    u = np.unique(p, axis=0)
    rep["duplicate_vertices"] = int(len(p) - len(u))
    used = np.zeros(nv, bool)
    used[tris.reshape(-1)] = True
    rep["unreferenced_vertices"] = int((~used).sum())
    rep["area2_triangles"] = int(o.sum())
    if expected_area2 is not None:
        rep["area2_faces"] = int(expected_area2)
        rep["area_mismatch"] = int(o.sum() - expected_area2)
    # bow-tie count: vertices whose boundary-edge in-degree > 1
    bv = tris[ti, ki]
    rep["bowtie_vertices"] = int((np.bincount(bv, minlength=nv) > 1).sum())
    rep["ok"] = (rep["non_positive_triangles"] == 0 and rep["duplicate_directed_edges"] == 0
                 and rep["tjunctions"] == 0 and rep["duplicate_vertices"] == 0
                 and rep["unreferenced_vertices"] == 0 and rep.get("area_mismatch", 0) == 0)
    return rep
