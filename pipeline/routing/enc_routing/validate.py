"""Pack validation: everything a reader can check from the file alone."""
from __future__ import annotations

import numpy as np

from . import packfmt as P
from . import topology

KNOWN_FLAGS = (1 << 13) - 1


def validate_pack(path) -> dict:
    rep = {"file": str(path)}
    errors = []
    try:
        p = P.read_pack(path)  # magic, version, header CRC, section CRCs and lengths
    except P.PackError as e:
        return {"ok": False, "errors": [str(e)]}
    T, V = len(p.tris), len(p.vertices)
    rep.update(vertices=V, triangles=T, sections={s["name"]: s["stored_length"] for s in p.sections})
    if p.tris.min() < 0 or p.tris.max() >= V:
        errors.append("triangle vertex index out of range")
    b = p.bbox
    if not ((p.vertices[:, 0] >= b[0]).all() and (p.vertices[:, 0] <= b[2]).all()
            and (p.vertices[:, 1] >= b[1]).all() and (p.vertices[:, 1] <= b[3]).all()):
        errors.append("vertex outside header bbox")
    # canonical order
    t = p.tris.astype(np.int64)
    if not ((t[:, 0] < t[:, 1]) & (t[:, 0] < t[:, 2])).all():
        errors.append("triangle not rotated to its smallest vertex")
    key = t[:, 0] * (V + 1) ** 2 + t[:, 1] * (V + 1) + t[:, 2]
    if not (np.diff(key) > 0).all():
        errors.append("triangles not sorted / duplicated")
    topo = topology.validate(p.vertices.astype(np.int64), t)
    rep["topology"] = topo
    if not topo["ok"]:
        errors.append("topology")
    nbr, dup = P.adjacency(p.tris)
    if dup or not (nbr == p.nbr).all():
        errors.append("stored adjacency differs from derived adjacency")
    a = p.attrs
    if (a["flags"].astype(np.int64) & ~KNOWN_FLAGS).any():
        errors.append("reserved flag bits set")
    for col, table in (("overhead", p.overhead), ("channel", p.channels), ("area", p.areas)):
        x = a[col].astype(np.int64)
        bad = (x != P.ID_NONE) & (x >= len(table))
        if bad.any():
            errors.append(f"{col} reference out of range ({int(bad.sum())})")
    op = (a["flags"] & P.F_OPENING) > 0
    if (op & (a["clearance_dm"] == P.CLR_NONE)).any():
        errors.append("OPENING flag without overhead object")
    unk = a["clearance_dm"] == P.CLR_UNKNOWN
    if (unk & ((a["flags"] & P.F_UNKNOWN_CLR) == 0)).any():
        errors.append("unknown clearance without UNKNOWN_CLEARANCE flag")
    # grid: every triangle listed in every cell its bbox touches
    g = p.grid
    ref = P.build_grid(p.vertices, p.tris, (g["origin_lon"], g["origin_lat"],
                                            g["origin_lon"] + g["nx"] * g["cell"],
                                            g["origin_lat"] + g["ny"] * g["cell"]), g["cell"])
    if not (np.array_equal(ref["offsets"], g["offsets"]) and np.array_equal(ref["ids"], g["ids"])):
        errors.append("grid index differs from the specified construction")
    for name, recs in (("OVHD", p.overhead), ("HAZD", p.hazards)):
        if len(recs) and ((recs["geom_first"].astype(np.int64) + recs["geom_count"]) > len(p.geom)).any():
            errors.append(f"{name} geometry reference out of range")
    ns = len(p.strings)
    for name, recs, cols in (("OVHD", p.overhead, ["name"]), ("HAZD", p.hazards, ["name"]),
                             ("CHAN", p.channels, ["name", "ident", "desc"]), ("AREA", p.areas, ["name", "text"]),
                             ("SRCS", p.sources, ["name"])):
        for c in cols:
            if len(recs) and (recs[c] >= ns).any():
                errors.append(f"{name}.{c} string id out of range")
    rep["passable_share_6ft"] = float(((a["depth_dm"] >= 18) & ((a["flags"] & P.F_PROHIBITED) == 0)).mean())
    rep["errors"] = errors
    rep["ok"] = not errors
    return rep
