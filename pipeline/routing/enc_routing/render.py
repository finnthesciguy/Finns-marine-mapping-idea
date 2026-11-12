"""PNG figures: routes over the merged depth areas."""
from __future__ import annotations

import json

import geopandas as gpd
import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402
import numpy as np  # noqa: E402
from matplotlib.colors import BoundaryNorm, ListedColormap  # noqa: E402
from shapely.geometry import box  # noqa: E402

from .config import GEO_CRS, WORK_CRS, work  # noqa: E402

# depth bins (m, chart values) and colours: drying, 0-3 ft, 3-6, 6-12, 12-18, 18-30, >30
BINS = [-50, 0, 0.9, 1.8, 3.6, 5.4, 9.1, 1e4]
COLS = ["#c9d8b6", "#a7d3ee", "#c6e3f4", "#e4f2fb", "#f3f9fd", "#fbfdff", "#ffffff"]
LABELS = ["drying", "0-3 ft", "3-6 ft", "6-12 ft", "12-18 ft", "18-30 ft", "30+ ft"]
LAND = "#e8d9b0"
ROUTE_COL = {"strict": "#d62728", "relaxed": "#6a00a8"}


def _load():
    m = work("merge", "merged.gpkg")
    dep = gpd.read_file(m, layer="DEPARE", engine="pyogrio")
    drg = gpd.read_file(m, layer="DRGARE", engine="pyogrio")
    land = gpd.read_file(work("polygons", "safe_water.gpkg"), layer="obstacles", engine="pyogrio")
    rts = gpd.read_file(work("routes", "routes.gpkg"), layer="routes", engine="pyogrio")
    over = gpd.read_file(work("polygons", "overhead.gpkg"), layer="overhead", engine="pyogrio")
    return dep, drg, land, rts, over


def _base(ax, dep, drg, land, bb):
    cmap = ListedColormap(COLS)
    norm = BoundaryNorm(BINS, cmap.N)
    clipbox = gpd.GeoSeries([bb], crs=GEO_CRS).to_crs(WORK_CRS).iloc[0]
    d = dep[dep.intersects(clipbox)]
    d = d[d.geom_type.str.contains("Polygon")]
    d.plot(ax=ax, column="DRVAL1", cmap=cmap, norm=norm, linewidth=0, rasterized=True)
    g = drg[drg.intersects(clipbox)]
    g.plot(ax=ax, color="#9ecae1", edgecolor="#3182bd", linewidth=0.3, rasterized=True)
    land.clip(clipbox).plot(ax=ax, color=LAND, linewidth=0, rasterized=True)
    x0, y0, x1, y1 = clipbox.bounds
    ax.set_xlim(x0, x1)
    ax.set_ylim(y0, y1)
    ax.set_xticks([])
    ax.set_yticks([])
    ax.set_xlabel("")
    ax.set_ylabel("")
    ax.set_aspect("equal")


def _legend(ax, fig=None):
    from matplotlib.patches import Patch

    h = [Patch(color=c, label=l) for c, l in zip(COLS, LABELS)]
    h += [Patch(color="#9ecae1", label="dredged area (DRGARE)"), Patch(color=LAND, label="land / structures")]
    h += [plt.Line2D([], [], color=ROUTE_COL["strict"], lw=2, label="route, charted depth only"),
          plt.Line2D([], [], color=ROUTE_COL["relaxed"], lw=2, ls="--",
                     label="route, relaxed (USACE project depth,\nunknown overhead clearance allowed)"),
          plt.Line2D([], [], marker="s", color="orange", lw=0, label="opening bridge"),
          plt.Line2D([], [], marker="x", color="k", lw=0, label="ICW break at 6 ft")]
    if fig is not None:
        fig.legend(handles=h, loc="lower center", ncol=6, fontsize=8, framealpha=0.9)
    else:
        ax.legend(handles=h, loc="lower left", fontsize=7, framealpha=0.9)


def _routes(ax, rts, key):
    for mode, col in ROUTE_COL.items():
        r = rts[(rts.route == key) & (rts["mode"] == mode)]
        if len(r):
            r.plot(ax=ax, color=col, linewidth=1.6 if mode == "strict" else 1.4,
                   linestyle="-" if mode == "strict" else "--", zorder=5)


def _breaks(ax, t="6"):
    rep = json.loads(work("reports", "polygons.json").read_text())
    br = rep["thresholds"][t]["icw_breaks"]
    if br:
        pts = gpd.GeoSeries(gpd.points_from_xy([b["lon"] for b in br], [b["lat"] for b in br]),
                            crs=GEO_CRS).to_crs(WORK_CRS)
        ax.scatter(pts.x, pts.y, marker="x", color="k", s=40, zorder=6)


def _openings(ax, over, bb):
    clipbox = gpd.GeoSeries([bb], crs=GEO_CRS).to_crs(WORK_CRS).iloc[0]
    o = over[(over.cls == "BRIDGE") & over.opens & over.intersects(clipbox)]
    c = o.geometry.representative_point()
    ax.scatter(c.x, c.y, marker="s", color="orange", s=12, zorder=6)


def save_small(fig, path, max_kb=380):
    """Save as a palette PNG under max_kb (shrinks DPI until it fits)."""
    from io import BytesIO

    from PIL import Image

    for a in fig.axes:  # geopandas re-adds CRS axis labels on every plot call
        a.set_xlabel("")
        a.set_ylabel("")
    for dpi in (130, 110, 95, 80, 70):
        buf = BytesIO()
        fig.savefig(buf, dpi=dpi, bbox_inches="tight", format="png")
        im = Image.open(buf).convert("RGB").quantize(colors=96, method=Image.Quantize.MEDIANCUT)
        out = BytesIO()
        im.save(out, format="PNG", optimize=True)
        if out.tell() <= max_kb * 1024:
            break
    path.write_bytes(out.getvalue())
    return out.tell()


def run_render() -> dict:
    dep, drg, land, rts, over = _load()
    out = {}
    # figure 1: whole pilot area with the three routes
    bb = box(-82.95, 26.55, -81.95, 27.85)
    fig, ax = plt.subplots(figsize=(8, 10))
    _base(ax, dep, drg, land, bb)
    for k in rts.route.unique():
        _routes(ax, rts, k)
    _breaks(ax)
    _openings(ax, over, bb)
    _legend(ax)
    ax.set_title("Pilot area: merged best-available depth areas, three test routes\n"
                 "(boat: 4.5 ft draft + 1.5 ft margin, 20 ft air draft)", fontsize=9)
    out["overview"] = save_small(fig, work("render", "routing-overview.png"))
    plt.close(fig)
    # figure 2: the three routes, one panel each
    panels = {
        "a_stpete_to_sarasota": ("(a) St. Petersburg - Sarasota", box(-82.78, 27.30, -82.50, 27.80)),
        "b_venice_inlet_to_punta_gorda": ("(b) Venice Inlet - Punta Gorda", box(-82.50, 26.70, -82.02, 27.14)),
        "c_anna_maria_to_boca_grande_inside": ("(c) Bradenton Beach - Boca Grande, inside",
                                               box(-82.72, 26.72, -82.22, 27.49)),
    }
    fig, axs = plt.subplots(1, 3, figsize=(15, 8))
    for ax, (k, (title, b)) in zip(axs, panels.items()):
        _base(ax, dep, drg, land, b)
        _routes(ax, rts, k)
        _breaks(ax)
        _openings(ax, over, b)
        ax.set_title(title, fontsize=10)
    _legend(axs[0], fig)
    fig.subplots_adjust(bottom=0.14)
    out["routes"] = save_small(fig, work("render", "routing-routes.png"))
    plt.close(fig)
    # figure 3: detail of a chart gap on the ICW with the mesh
    out["detail"] = render_detail(dep, drg, land, rts, over)
    print(out)
    return out


def render_detail(dep, drg, land, rts, over, bb=box(-82.556, 27.250, -82.526, 27.285)):
    import shapely

    from .route import Mesh

    mesh = Mesh.load()
    clipbox = gpd.GeoSeries([bb], crs=GEO_CRS).to_crs(WORK_CRS).iloc[0]
    cen = mesh.centroids
    x0, y0, x1, y1 = clipbox.bounds
    sel = (cen[:, 0] > x0) & (cen[:, 0] < x1) & (cen[:, 1] > y0) & (cen[:, 1] < y1)
    fig, ax = plt.subplots(figsize=(7, 8))
    _base(ax, dep, drg, land, bb)
    from matplotlib.collections import PolyCollection

    polys = mesh.coords[mesh.tris[sel]]
    need = 1.8
    col = np.where(np.nan_to_num(mesh.depth_m[sel], nan=-1) >= need, "#2ca02c", "#d62728")
    ax.add_collection(PolyCollection(polys, facecolors="none", edgecolors=col, linewidths=0.25, alpha=0.6))
    from .channels import ncf_query
    ncf = ncf_query(2).to_crs(WORK_CRS)
    ncf[ncf.intersects(clipbox)].boundary.plot(ax=ax, color="#ff7f0e", linewidth=0.8, linestyle=":")
    for k in rts.route.unique():
        _routes(ax, rts, k)
    _breaks(ax)
    _openings(ax, over, bb)
    ax.set_title("Detail: ICW in Roberts Bay, Sarasota. Mesh triangles green = charted >= 6 ft,\n"
                 "red = shallower; orange dotted = USACE NCF channel reach (9 ft maintained).\n"
                 "x = ICW breaks: the chart has no dredged area here (0-3 ft band).", fontsize=9)
    n = save_small(fig, work("render", "routing-detail.png"))
    plt.close(fig)
    return n
