"""Mesh construction and topology validation on small synthetic geometry."""
from __future__ import annotations

import numpy as np
import shapely
from shapely.geometry import LineString, Polygon, box

from enc_routing import topology
from enc_routing.config import BuildParams
from enc_routing.mesh import faces_and_triangles, polygon_area2


def test_faces_triangulate_conformingly():
    # a square domain with a hole, cut by a depth contour and a hazard ring (units = 1e-7 deg)
    dom = box(0, 0, 20000, 10000).difference(box(8000, 3000, 9000, 4000))
    lines = [shapely.boundary(dom), LineString([(5000, -10), (5000, 10010)]),
             shapely.boundary(shapely.Point(15000, 5000).buffer(700))]
    faces, coords, tris, face_of, rep = faces_and_triangles(lines, dom, (0, 0, 20000, 10000),
                                                            BuildParams(grid_deg=0.0005))
    assert rep["ok"], rep
    assert rep["area_mismatch"] == 0 and rep["tjunctions"] == 0 and rep["duplicate_directed_edges"] == 0
    assert polygon_area2(dom) <= rep["area2_triangles"] <= polygon_area2(dom) + 2000 * 4 * 700


def test_validate_detects_flaws():
    p = np.array([[0, 0], [10, 0], [10, 10], [0, 10], [5, 0]], np.int64)
    good = np.array([[0, 4, 3], [4, 1, 2], [4, 2, 3]])
    assert topology.validate(p, good)["ok"]
    # T-junction: vertex 4 lies inside the boundary edge 0-1 of triangle (0,1,2)
    tj = np.array([[0, 1, 2], [0, 2, 3]])
    r = topology.validate(p[:5], np.vstack([tj, [[4, 1, 2]]]))
    assert not r["ok"]
    # overlap / duplicated directed edge
    r = topology.validate(p, np.array([[0, 1, 2], [0, 1, 3]]))
    assert r["duplicate_directed_edges"] == 1 and not r["ok"]
    # flat triangle
    r = topology.validate(p, np.array([[0, 4, 1], [0, 1, 2]]))
    assert r["non_positive_triangles"] == 1


def test_fix_flat_splits_the_hidden_t_junction():
    p = np.array([[0, 0], [10, 0], [5, 0], [5, 8], [5, -8]], np.int64)
    # flat (0, 2, 1) on the shared edge; real triangles (0, 1, 3) above, (0, 4, 1) below split at 2
    tris = np.array([[0, 2, 1], [0, 1, 3], [0, 4, 2], [2, 4, 1]])
    t, f, n = topology.fix_flat(p, tris, np.arange(4))
    assert n == 1
    assert topology.validate(p, t)["ok"]
