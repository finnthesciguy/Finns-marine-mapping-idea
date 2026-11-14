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


def vertices_on_edges(p, tris, ti, ki, cell=None, max_pairs=20_000_000):
    """For the edges (tris[ti,ki], tris[ti,(ki+1)%3]) find vertices lying
    strictly inside them (exact integer test). Returns a list of
    (edge index, [vertex ids sorted along the edge]).

    Vectorised: vertices are bucketed on a uniform grid; each edge is tested
    against the vertices of every grid cell its bounding box touches, in
    chunks of at most max_pairs candidate pairs."""
    p = np.asarray(p, dtype=np.int64)
    ti = np.asarray(ti, dtype=np.int64)
    ki = np.asarray(ki, dtype=np.int64)
    if len(ti) == 0 or len(p) == 0:
        return []
    a = tris[ti, ki].astype(np.int64)
    c = tris[ti, (ki + 1) % 3].astype(np.int64)
    P, Q = p[a], p[c]
    lo = np.minimum(P, Q)
    hi = np.maximum(P, Q)
    if cell is None:
        ext = np.maximum(hi - lo, 1).max(axis=1)
        cell = int(max(256, np.median(ext)))
    g = p // cell
    gx0, gy0 = g.min(axis=0)
    gx1, gy1 = g.max(axis=0)
    W = int(gy1 - gy0 + 1)
    vkey = (g[:, 0] - gx0) * W + (g[:, 1] - gy0)
    vorder = np.argsort(vkey, kind="stable")
    sk = vkey[vorder]
    clo = lo // cell
    chi = hi // cell
    nx = chi[:, 0] - clo[:, 0] + 1
    ny = chi[:, 1] - clo[:, 1] + 1
    ncell = nx * ny
    out = {}

    def test(ce, cv):
        Pe, Qe = P[ce], Q[ce]
        d = Qe - Pe
        wv = p[cv] - Pe
        cross = d[:, 0] * wv[:, 1] - d[:, 1] * wv[:, 0]
        dot = d[:, 0] * wv[:, 0] + d[:, 1] * wv[:, 1]
        L2 = d[:, 0] * d[:, 0] + d[:, 1] * d[:, 1]
        on = (cross == 0) & (dot > 0) & (dot < L2) & (cv != a[ce]) & (cv != c[ce])
        for e_, v_, t_ in zip(ce[on].tolist(), cv[on].tolist(), dot[on].tolist()):
            out.setdefault(e_, {})[v_] = t_

    # long edges (many grid cells): brute force over the vertices in their bounding box
    big = np.flatnonzero(ncell > 4096)
    if len(big):
        xorder = np.argsort(p[:, 0], kind="stable")
        xs = p[xorder, 0]
        for e_ in big.tolist():
            i0, i1 = np.searchsorted(xs, lo[e_, 0], "left"), np.searchsorted(xs, hi[e_, 0], "right")
            cv = xorder[i0:i1]
            cv = cv[(p[cv, 1] >= lo[e_, 1]) & (p[cv, 1] <= hi[e_, 1])]
            if len(cv):
                test(np.full(len(cv), e_), cv)
    small = np.flatnonzero(ncell <= 4096)
    e0 = 0
    E = len(small)
    while e0 < E:
        # grow the chunk while the number of (edge, cell) pairs stays moderate
        csum = np.cumsum(ncell[small[e0:]])
        e1 = e0 + max(1, int(np.searchsorted(csum, max_pairs // 8)))
        e1 = min(e1, E)
        idx = small[e0:e1]
        cnt = ncell[idx]
        eid = np.repeat(idx, cnt)
        off = np.repeat(np.cumsum(cnt) - cnt, cnt)
        k = np.arange(len(eid)) - off
        w = nx[eid]
        cx = clo[eid, 0] + k % w
        cy = clo[eid, 1] + k // w
        key = (cx - gx0) * W + (cy - gy0)
        valid = (cx >= gx0) & (cx <= gx1) & (cy >= gy0) & (cy <= gy1)
        eid, key = eid[valid], key[valid]
        s0 = np.searchsorted(sk, key, side="left")
        s1 = np.searchsorted(sk, key, side="right")
        m = s1 - s0
        keep = m > 0
        eid, s0, m = eid[keep], s0[keep], m[keep]
        # expand candidate vertices, bounded in chunks
        tot = int(m.sum())
        start = 0
        cm = np.cumsum(m)
        while start < len(eid):
            base = cm[start - 1] if start else 0
            stop = int(np.searchsorted(cm, base + max_pairs, side="right"))
            stop = max(stop, start + 1)
            ee, ss, mm = eid[start:stop], s0[start:stop], m[start:stop]
            ce = np.repeat(ee, mm)
            o2 = np.repeat(np.cumsum(mm) - mm, mm)
            cv = vorder[np.repeat(ss, mm) + (np.arange(len(ce)) - o2)]
            test(ce, cv)
            start = stop
        del tot
        e0 = e1
    res = []
    for e_ in sorted(out):
        vs = out[e_]
        res.append((e_, [v for v, _ in sorted(vs.items(), key=lambda kv: (kv[1], kv[0]))]))
    return res


def fix_tjunctions(p, tris, face_of, max_iter=8):
    """Split every triangle whose boundary edge has a mesh vertex strictly
    inside it (exact test), repeating until none is left. Returns (tris,
    face_of, n_split)."""
    total = 0
    for _ in range(max_iter):
        tris, face_of, n = _fix_tjunctions_once(p, tris, face_of)
        total += n
        if n == 0:
            break
    return tris, face_of, total


def _fix_tjunctions_once(p, tris, face_of):
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
