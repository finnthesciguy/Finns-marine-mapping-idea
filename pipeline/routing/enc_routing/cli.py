"""Command line: python -m enc_routing <command> [...]

  build      catalog -> download -> extract -> merge -> mesh -> pack (cached, incremental)
  validate   decode a pack, check checksums, topology, index and references
  route      route between two points on a pack (reads only the pack)
  reference  run the reference routes and check them against the source data
  render     PNG figures of the reference routes
  vectors    write testdata/routing (synthetic pack, Sarasota cut, vectors, record dumps)
"""
from __future__ import annotations

import argparse
import gzip
import json
import sys
from pathlib import Path

from . import config

REPO = Path(__file__).resolve().parents[3]


def _region(name):
    return config.Region(name, config.REGIONS[name])


def _pack_path(region):
    b = json.loads(region.dir("build.json").read_text())
    return region.dir(b["pack"])


def cmd_build(a):
    from .build import build

    r = build(_region(a.region), force=a.force, catalog_copy=a.catalog_copy)
    print(json.dumps(r, indent=1, default=str))


def cmd_validate(a):
    from .validate import validate_pack

    path = Path(a.pack) if a.pack else _pack_path(_region(a.region))
    rep = validate_pack(path)
    print(json.dumps(rep, indent=1, default=str))
    sys.exit(0 if rep["ok"] else 1)


def cmd_route(a):
    from . import packfmt
    from .router import Profile, Router

    path = Path(a.pack) if a.pack else _pack_path(_region(a.region))
    rt = Router(packfmt.read_pack(path))
    prof = Profile(a.draft, a.margin, a.air, use_maintained=a.maintained,
                   accept_unknown_clearance=a.unknown, avoid_open_gulf=a.inside)
    s = tuple(float(v) for v in a.start.split(","))
    g = tuple(float(v) for v in a.goal.split(","))
    res = rt.route(s, g, prof, a.max_snap)
    res.pop("corridor", None)
    if not a.full:
        for l in res.get("legs", []):
            l.pop("crossings", None)
    print(json.dumps(res, indent=1, default=str))


def cmd_reference(a):
    from .assess import run_reference

    reg = _region(a.region)
    rows = run_reference(_pack_path(reg), reg)
    reg.dir("routes.json").write_text(json.dumps(rows, default=str))


def cmd_render(a):
    from .render import run_render

    run_render(_region(a.region), out_dir=a.out)


def cmd_vectors(a):
    from . import packfmt, synth, vectors

    out = Path(a.out)
    out.mkdir(parents=True, exist_ok=True)
    sp = out / "synthetic.pack"
    packfmt.write_pack(synth.build_synthetic(), sp, with_adjacency=True)
    vectors.make_vectors(sp, vectors.SYNTH_QUERIES, out / "synthetic.vectors.json")
    (out / "synthetic.records.json").write_text(json.dumps(vectors.dump_records(sp), indent=1, default=vectors._np))
    src_region, bbox = config.CUTS["sarasota"]
    big = packfmt.read_pack(_pack_path(_region(src_region)))
    cut = vectors.cut_pack(big, bbox, "pilot-sarasota")
    cp = out / "sarasota.pack"
    packfmt.write_pack(cut, cp, with_adjacency=False)
    vectors.make_vectors(cp, vectors.SARASOTA_QUERIES, out / "sarasota.vectors.json")
    (out / "sarasota.records.json").write_text(json.dumps(vectors.dump_records(cp), indent=1, default=vectors._np))
    reg = _region(src_region)
    for name in ("obstacles", "bridge_zone"):
        g = vectors.clip_source_geometry(reg, reg.dir(f"{name}.wkb"), bbox)
        (out / f"sarasota.{name}.wkb.gz").write_bytes(gzip.compress(g, 9, mtime=0))
    for f in sorted(out.iterdir()):
        print(f.name, f.stat().st_size)


def main(argv=None):
    ap = argparse.ArgumentParser(prog="enc_routing", description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    b = sub.add_parser("build")
    b.add_argument("--region", default="pilot")
    b.add_argument("--force", action="store_true")
    b.add_argument("--catalog-copy", default=None)
    b.set_defaults(fn=cmd_build)
    v = sub.add_parser("validate")
    v.add_argument("pack", nargs="?")
    v.add_argument("--region", default="pilot")
    v.set_defaults(fn=cmd_validate)
    r = sub.add_parser("route")
    r.add_argument("--pack")
    r.add_argument("--region", default="pilot")
    r.add_argument("--start", required=True, help="lon,lat")
    r.add_argument("--goal", required=True, help="lon,lat")
    r.add_argument("--draft", type=float, default=4.5)
    r.add_argument("--margin", type=float, default=1.5)
    r.add_argument("--air", type=float, default=20.0)
    r.add_argument("--maintained", action="store_true", help="use USACE maintained depths")
    r.add_argument("--unknown", action="store_true", help="accept unknown overhead clearance")
    r.add_argument("--inside", action="store_true", help="avoid the open Gulf")
    r.add_argument("--max-snap", type=float, default=750.0)
    r.add_argument("--full", action="store_true")
    r.set_defaults(fn=cmd_route)
    f = sub.add_parser("reference")
    f.add_argument("--region", default="pilot")
    f.set_defaults(fn=cmd_reference)
    d = sub.add_parser("render")
    d.add_argument("--region", default="pilot")
    d.add_argument("--out", default=None)
    d.set_defaults(fn=cmd_render)
    t = sub.add_parser("vectors")
    t.add_argument("--out", default=str(REPO / "testdata" / "routing"))
    t.set_defaults(fn=cmd_vectors)
    a = ap.parse_args(argv)
    a.fn(a)


if __name__ == "__main__":
    main()
