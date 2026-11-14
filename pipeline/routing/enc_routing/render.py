"""PNG figures: reference routes (legs coloured by grade) over the merged
depth areas, and mesh details around bridges and jetties."""
from __future__ import annotations

import glob
import json
from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402
import numpy as np  # noqa: E402
import pandas as pd  # noqa: E402
import shapely  # noqa: E402
from matplotlib.collections import LineCollection, PolyCollection  # noqa: E402
from matplotlib.colors import BoundaryNorm, ListedColormap  # noqa: E402
from pyproj import Transformer  # noqa: E402

from . import packfmt as P  # noqa: E402
from .config import GEO_CRS  # noqa: E402

BINS = [-50, 0, 0.9, 1.8, 3.6, 5.4, 9.1, 1e4]
COLS = ["#c9d8b6", "#a7d3ee", "#c6e3f4", "#e4f2fb", "#f3f9fd", "#fbfdff", "#ffffff"]
LABELS = ["drying", "0-3 ft", "3-6 ft", "6-12 ft", "12-18 ft", "18-30 ft", "30+ ft"]
LAND = "#e8d9b0"
GRADE = {"green": "#1a9641", "yellow": "#e6a800"}


def save_small(fig, path, max_kb=380):
    from io import BytesIO

    from PIL import Image

    for dpi in (130, 110, 95, 80, 70, 60):
        buf = BytesIO()
        fig.savefig(buf, dpi=dpi, bbox_inches="tight", format="png")
        im = Image.open(buf).convert("RGB").quantize(colors=96, method=Image.Quantize.MEDIANCUT)
        out = BytesIO()
        im.save(out, format="PNG", optimize=True)
        if out.tell() <= max_kb * 1024:
            break
    Path(path).write_bytes(out.getvalue())
    return out.tell()


class Base:
    def __init__(self, region):
        merged, _ = pd.read_pickle(sorted(glob.glob(str(region.dir("merged.*.pkl"))))[-1])
        self.tr = Transformer.from_crs(region.crs, GEO_CRS, always_xy=True)
        self.dep = merged["DEPARE"]
        self.dep = self.dep[self.dep.geom_type.isin(["Polygon", "MultiPolygon"])]
        self.drg = merged["DRGARE"]
        self.land = shapely.from_wkb(region.dir("obstacles.wkb").read_bytes())
        self.fend = shapely.from_wkb(region.dir("fenders.wkb").read_bytes())
        self.inv = Transformer.from_crs(GEO_CRS, region.crs, always_xy=True)

    def ll(self, g):
        return shapely.transform(g, lambda xy: np.column_stack(self.tr.transform(xy[:, 0], xy[:, 1])))

    def draw(self, ax, bb):
        clip = shapely.box(*bb)
        cmap = ListedColormap(COLS)
        norm = BoundaryNorm(BINS, cmap.N)
        x0, y0 = self.inv.transform(bb[0], bb[1])
        x1, y1 = self.inv.transform(bb[2], bb[3])
        mb = shapely.box(x0 - 200, y0 - 200, x1 + 200, y1 + 200)
        d = self.dep[self.dep.intersects(mb)]
        polys, vals = [], []
        for g, v in zip(self.ll(d.geometry.values), d.DRVAL1.astype(float).values):
            for p in shapely.get_parts(g.intersection(clip)):
                if p.geom_type == "Polygon":
                    polys.append(np.asarray(p.exterior.coords))
                    vals.append(v)
        pc = PolyCollection(polys, array=np.array(vals), cmap=cmap, norm=norm, linewidths=0, rasterized=True)
        ax.add_collection(pc)
        g = self.drg[self.drg.intersects(mb)]
        dp = [np.asarray(p.exterior.coords) for gg in self.ll(g.geometry.values)
              for p in shapely.get_parts(gg.intersection(clip)) if p.geom_type == "Polygon"]
        ax.add_collection(PolyCollection(dp, facecolors="#9ecae1", edgecolors="#3182bd", linewidths=0.3, rasterized=True))
        land = self.ll(self.land.intersection(mb))
        lp = [np.asarray(p.exterior.coords) for p in shapely.get_parts(land) if p.geom_type == "Polygon"]
        ax.add_collection(PolyCollection(lp, facecolors=LAND, edgecolors="#9c8a5a", linewidths=0.2, rasterized=True))
        ln = [np.asarray(p.coords) for p in shapely.get_parts(land) if p.geom_type == "LineString"]
        ln += [np.asarray(p.coords) for p in shapely.get_parts(self.ll(self.fend.intersection(mb)))
               if p.geom_type == "LineString"]
        ax.add_collection(LineCollection(ln, colors="#7a5c00", linewidths=0.8))
        ax.set_xlim(bb[0], bb[2])
        ax.set_ylim(bb[1], bb[3])
        ax.set_aspect(1 / np.cos(np.radians((bb[1] + bb[3]) / 2)))
        ax.set_xticks([])
        ax.set_yticks([])


def draw_route(ax, res, lw=1.6, label=None):
    segs = [[l["from"], l["to"]] for l in res["legs"]]
    cols = [GRADE[l["grade"]] for l in res["legs"]]
    ax.add_collection(LineCollection(segs, colors=cols, linewidths=lw, zorder=5))
    for o in res["summary"]["openings"]:
        ax.scatter([o["lon"]], [o["lat"]], marker="s", color="#d95f02", s=14, zorder=6)
    if label:
        s = res["waypoints"][0]
        ax.annotate(label, s, fontsize=6, zorder=7)


def draw_failure(ax, row):
    for b in row.get("blocked", [])[:3]:
        ax.scatter([b["lon"]], [b["lat"]], marker="x", color="#d7191c", s=40, zorder=7)


def legend(fig):
    from matplotlib.patches import Patch

    h = [Patch(color=c, label=l) for c, l in zip(COLS, LABELS)]
    h += [Patch(color="#9ecae1", label="dredged area"), Patch(color=LAND, label="land/structures/blocking hazards")]
    h += [plt.Line2D([], [], color=GRADE["green"], lw=2, label="green leg"),
          plt.Line2D([], [], color=GRADE["yellow"], lw=2, label="yellow leg"),
          plt.Line2D([], [], marker="s", color="#d95f02", lw=0, label="bridge opening needed"),
          plt.Line2D([], [], marker="x", color="#d7191c", lw=0, label="no route: first blocked place")]
    fig.legend(handles=h, loc="lower center", ncol=6, fontsize=7, framealpha=0.9)


def mesh_panel(ax, pack, bb, req_dm, res_list):
    b = [int(v * 1e7) for v in bb]
    c = pack.vertices[pack.tris].astype(np.int64).mean(1)
    sel = (c[:, 0] > b[0]) & (c[:, 0] < b[2]) & (c[:, 1] > b[1]) & (c[:, 1] < b[3])
    polys = pack.vertices[pack.tris[sel]] / 1e7
    a = pack.attrs
    blocked = (a["depth_dm"][sel] < req_dm) | (a["clearance_dm"][sel] < 61) & ((a["flags"][sel] & P.F_OPENING) == 0)
    col = np.where(blocked, "#d62728", "#2ca02c")
    ax.add_collection(PolyCollection(polys, facecolors="none", edgecolors=col, linewidths=0.25, alpha=0.7, zorder=4))
    for r in res_list:
        draw_route(ax, r, lw=2.0)


def run_render(region, out_dir=None):
    from .cli import _pack_path

    out_dir = Path(out_dir) if out_dir else region.dir("render")
    out_dir.mkdir(parents=True, exist_ok=True)
    rows = json.loads(region.dir("routes.json").read_text())
    byid = {r["id"]: r for r in rows}
    base = Base(region)
    pack = P.read_pack(_pack_path(region))
    sizes = {}
    # 1: overview of all successful reference routes
    fig, ax = plt.subplots(figsize=(8, 10))
    bb = (-82.95, 26.40, -81.90, 27.98)
    base.draw(ax, bb)
    for r in rows:
        if r["ok"]:
            draw_route(ax, r["result"], lw=1.0)
        else:
            draw_failure(ax, r)
    ax.set_title("Wave 2 reference routes on the pilot pack (legs green / yellow by grade)", fontsize=9)
    legend(fig)
    sizes["routing-overview.png"] = save_small(fig, out_dir / "routing-overview.png")
    plt.close(fig)
    # 2: panels of the three spike routes (strict and relaxed)
    panels = [("a_strict", "a_relaxed", "(a) St. Petersburg - Marina Jack", (-82.78, 27.30, -82.50, 27.80)),
              ("b_strict", "b_relaxed_inside", "(b) Venice Inlet - Punta Gorda", (-82.50, 26.68, -82.02, 27.14)),
              ("c_relaxed", "c_strict", "(c) Bradenton Beach - Boca Grande inside", (-82.72, 26.72, -82.22, 27.49))]
    fig, axs = plt.subplots(1, 3, figsize=(15, 8))
    for ax, (k1, k2, title, b) in zip(axs, panels):
        base.draw(ax, b)
        for k, lw in ((k1, 1.8), (k2, 1.0)):
            r = byid.get(k)
            if r and r["ok"]:
                draw_route(ax, r["result"], lw=lw)
            elif r:
                draw_failure(ax, r)
        ax.set_title(f"{title}\nthick: {k1}, thin: {k2}", fontsize=9)
    legend(fig)
    fig.subplots_adjust(bottom=0.12)
    sizes["routing-routes.png"] = save_small(fig, out_dir / "routing-routes.png")
    plt.close(fig)
    # 3: mesh details: Cortez bridge span, Venice south jetty, Roberts Bay gap, Blackburn Point
    det = [("Cortez Bridge bascule span (a, c)", (-82.6975, 27.4655, -82.6875, 27.4725), ["a_strict", "c_relaxed"]),
           ("Venice Inlet jetties (b)", (-82.4700, 27.1070, -82.4560, 27.1170), ["b_strict", "b_relaxed"]),
           ("Roberts Bay ICW gap (c relaxed)", (-82.556, 27.250, -82.526, 27.285), ["c_relaxed"]),
           ("Venice: south ICW gap (b, c relaxed)", (-82.442, 27.035, -82.422, 27.052), ["b_relaxed_inside", "c_relaxed"])]
    fig, axs = plt.subplots(2, 2, figsize=(11, 11))
    for ax, (title, b, ids) in zip(axs.ravel(), det):
        base.draw(ax, b)
        res = [byid[i]["result"] for i in ids if i in byid and byid[i]["ok"]]
        mesh_panel(ax, pack, b, 18, res)
        ax.set_title(title + "\nmesh: green = passable at 6 ft / 20 ft air, red = not", fontsize=8)
    legend(fig)
    fig.subplots_adjust(bottom=0.08)
    sizes["routing-detail.png"] = save_small(fig, out_dir / "routing-detail.png")
    plt.close(fig)
    print(sizes)
    return sizes


# --------------------------------------------------------------------------- region overview (Wave 4)

DEPTH_BINS_DM = [-40000, 0, 18, 36, 55, 91, 40000]          # none/drying, <6 ft, 6-12, 12-18, 18-30, 30+
DEPTH_COLS = ["#d9d3c3", "#b8d8ea", "#d4e9f5", "#e6f2fa", "#f2f8fc", "#ffffff"]
MODE_COLS = {"strict": "#1a9641", "maintained": "#e66101", "relaxed": "#7b3294"}


def run_render_region(region, out_dir=None, small=False, figsize=(11, 9)):
    """Overview of a region's pack (triangles by charted depth, maintained-only
    water in purple) with the reference routes: green = found strictly,
    orange = needs maintained channels, purple = also unknown clearances;
    x = start of a route that failed in every mode."""
    from matplotlib.tri import Triangulation

    from .cli import _pack_path

    out_dir = Path(out_dir) if out_dir else region.dir("render")
    out_dir.mkdir(parents=True, exist_ok=True)
    pack = P.read_pack(_pack_path(region))
    v = pack.vertices.astype(float) / 1e7
    t = pack.tris
    d = pack.attrs["depth_dm"].astype(np.int64)
    d = np.where(d == P.DEPTH_NONE, -1, d)
    cls = np.digitize(d, DEPTH_BINS_DM[1:-1])
    colors = np.array(DEPTH_COLS)[cls]
    maint_only = (pack.attrs["depth_dm"] < 18) & (pack.attrs["maint_dm"] >= 18)
    colors[maint_only] = "#c2a5cf"
    fig, ax = plt.subplots(figsize=figsize)
    ax.set_facecolor("#e8d9b0")
    tri = Triangulation(v[:, 0], v[:, 1], t)
    from matplotlib.colors import ListedColormap

    pal = list(DEPTH_COLS) + ["#c2a5cf"]
    idx = np.where(maint_only, len(DEPTH_COLS), cls)
    ax.tripcolor(tri, facecolors=idx.astype(float), cmap=ListedColormap(pal), vmin=-0.5, vmax=len(pal) - 0.5,
                 edgecolors="none", rasterized=True)
    if region.chart_bbox:
        w, s, e, n = region.chart_bbox
        b = pack.bbox
        w, s, e, n = max(w, b[0] / 1e7), max(s, b[1] / 1e7), min(e, b[2] / 1e7), min(n, b[3] / 1e7)
        ax.plot([w, e, e, w, w], [s, s, n, n, s], ls="--", lw=0.8, color="#555555")
    rows_path = region.dir("routes.json")
    if rows_path.exists():
        rows = json.loads(rows_path.read_text())
        by = {}
        for r in rows:
            by.setdefault(r["id"], {})[r["mode"]] = r
        for rid, modes in by.items():
            best = next((m for m in ("strict", "maintained", "relaxed") if m in modes and modes[m]["ok"]), None)
            if best is None:
                st = next(iter(modes.values()))["start"]
                ax.plot(st[0], st[1], "x", color="#d7191c", ms=7, mew=2)
                continue
            w = np.array(modes[best]["result"]["waypoints"])
            ax.plot(w[:, 0], w[:, 1], color=MODE_COLS[best], lw=1.3)
            ax.annotate(rid.split("_")[0], (w[0, 0], w[0, 1]), fontsize=6, color="#222222")
    ax.set_xlim(pack.bbox[0] / 1e7, pack.bbox[2] / 1e7)
    ax.set_ylim(pack.bbox[1] / 1e7, pack.bbox[3] / 1e7)
    ax.set_aspect(1 / np.cos(np.radians((pack.bbox[1] + pack.bbox[3]) / 2e7)))
    ax.set_title(f"{region.rid}: routing pack ({len(t):,} triangles, data {pack.data_date}); dashed = chart box; "
                 "routes: green strict, orange maintained channels, purple + unknown clearance, x failed",
                 fontsize=8)
    from matplotlib.patches import Patch

    handles = [Patch(color=c, label=lab) for c, lab in zip(
        DEPTH_COLS + ["#c2a5cf"], ["no depth / drying", "< 6 ft", "6-12 ft", "12-18 ft", "18-30 ft", "30+ ft",
                                    "< 6 ft charted, >= 6 ft maintained"])]
    ax.legend(handles=handles, loc="lower left", fontsize=6, framealpha=0.9)
    full = out_dir / f"{region.rid}-overview.png"
    fig.savefig(full, dpi=160, bbox_inches="tight")
    sizes = {full.name: full.stat().st_size}
    if small:
        sp = out_dir / f"gulf-{region.rid}.png"
        sizes[sp.name] = save_small(fig, sp, max_kb=380)
    plt.close(fig)
    print(sizes)
    return sizes
