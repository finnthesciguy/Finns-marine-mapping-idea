"""Extract routing-relevant S-57 objects from each cell (updates applied).

Output: one GeoPackage (extract.gpkg) with a layer per object class, all
cells concatenated, geometry in EPSG:4326, plus columns
  cell, band (1..6), cscale, isdt (issue date of the applied update).
List-valued S-57 attributes (e.g. CATBRG, RESTRN) are normalised to
comma-separated strings so they survive GeoPackage.
"""
from __future__ import annotations

import json
import os
from pathlib import Path

import geopandas as gpd
import numpy as np
import pandas as pd

from .config import work

S57_OPTIONS = "UPDATES=APPLY,SPLIT_MULTIPOINT=ON,ADD_SOUNDG_DEPTH=ON,RETURN_LINKAGES=OFF,LNAM_REFS=ON"

COMMON = ["LNAM", "OBJNAM", "INFORM", "SORDAT", "SORIND", "SCAMIN"]

# object class -> attributes kept (beyond COMMON)
LAYERS: dict[str, list[str]] = {
    # skin of the earth / depth
    "DEPARE": ["DRVAL1", "DRVAL2", "QUASOU"],
    "DRGARE": ["DRVAL1", "DRVAL2", "QUASOU"],
    "LNDARE": ["CONDTN"],
    "UNSARE": [],
    "COALNE": ["CATCOA"],
    "SLCONS": ["CATSLC", "CONDTN", "WATLEV"],
    "PONTON": [],
    "HULKES": [],
    "FLODOC": [],
    "DRYDOC": [],
    "CAUSWY": ["WATLEV"],
    "DAMCON": [],
    "GATCON": [],
    "DYKCON": [],
    # hazards
    "OBSTRN": ["VALSOU", "WATLEV", "CATOBS", "QUASOU", "EXPSOU"],
    "WRECKS": ["VALSOU", "WATLEV", "CATWRK", "QUASOU", "EXPSOU"],
    "UWTROC": ["VALSOU", "WATLEV", "QUASOU", "EXPSOU"],
    "PILPNT": ["CATPLE"],
    "SOUNDG": ["DEPTH", "QUASOU", "TECSOU"],
    # overhead
    "BRIDGE": ["CATBRG", "VERCLR", "VERCCL", "VERCOP", "HORCLR"],
    "CBLOHD": ["CATCBL", "VERCLR", "VERCSA"],
    "PIPOHD": ["CATPIP", "VERCLR"],
    # channels / tracks
    "FAIRWY": ["ORIENT", "TRAFIC", "DRVAL1"],
    "RECTRC": ["CATTRK", "ORIENT", "TRAFIC", "DRVAL1", "DRVAL2"],
    "NAVLNE": ["CATNAV", "ORIENT"],
    "DWRTCL": ["CATTRK", "ORIENT", "TRAFIC", "DRVAL1", "DRVAL2"],
    # regulated
    "RESARE": ["RESTRN", "CATREA"],
    "CTNARE": [],
    # aids to navigation
    "BOYLAT": ["CATLAM", "COLOUR", "BOYSHP"],
    "BCNLAT": ["CATLAM", "COLOUR", "BCNSHP"],
    "BOYSPP": ["CATSPM", "COLOUR"],
    "BCNSPP": ["CATSPM", "COLOUR"],
    "BOYSAW": ["COLOUR"],
    "BCNSAW": ["COLOUR"],
    "BOYCAR": ["CATCAM"],
    "BCNCAR": ["CATCAM"],
    "BOYISD": [],
    "BCNISD": [],
    "LIGHTS": ["COLOUR", "LITCHR"],
    # meta
    "M_COVR": ["CATCOV"],
    "M_QUAL": ["CATZOC", "SURSTA", "SUREND", "POSACC", "SOUACC"],
}


def _norm(v):
    if isinstance(v, (list, tuple, np.ndarray)):
        return ",".join(str(x) for x in v)
    return v


def read_cell(path: Path, cell_meta: dict) -> dict[str, gpd.GeoDataFrame]:
    import pyogrio

    os.environ["OGR_S57_OPTIONS"] = S57_OPTIONS
    present = {n for n, _ in pyogrio.list_layers(str(path))}
    out = {}
    dsid = pyogrio.read_dataframe(str(path), layer="DSID")
    meta = dict(cell_meta)
    r = dsid.iloc[0]
    meta.update(
        dspm=dict(
            HDAT=int(r.DSPM_HDAT), VDAT=int(r.DSPM_VDAT), SDAT=int(r.DSPM_SDAT),
            DUNI=int(r.DSPM_DUNI), HUNI=int(r.DSPM_HUNI), CSCL=int(r.DSPM_CSCL),
        ),
        edtn=str(r.DSID_EDTN), updn=str(r.DSID_UPDN), uadt=str(r.DSID_UADT), isdt=str(r.DSID_ISDT),
    )
    for layer, attrs in LAYERS.items():
        if layer not in present:
            continue
        df = pyogrio.read_dataframe(str(path), layer=layer)
        if df.empty or "geometry" not in df:
            continue
        df = df[~df.geometry.isna()]
        cols = COMMON + attrs
        for c in cols:
            if c not in df.columns:
                df[c] = None
        df = df[cols + ["geometry"]].copy()
        for c in cols:
            if df[c].dtype == object:
                df[c] = df[c].map(_norm)
        df["cell"] = meta["name"]
        df["band"] = int(meta["name"][2])
        df["cscale"] = int(meta["cscale"])
        df["isdt"] = meta["isdt"]
        out[layer] = gpd.GeoDataFrame(df, geometry="geometry", crs="EPSG:4326")
    return out, meta


def extract_cells(cells, force: bool = False):
    """Extract every cell, cached per cell edition and update as a pickle.
    Returns (per_layer {layer: [GeoDataFrame per cell]}, metas, n_extracted)."""
    from .download import unzip_cell

    metas = []
    per_layer: dict[str, list] = {}
    n_new = 0
    for c in cells:
        cache = work("extract", "cells", f"{c.name}.{c.edtn}.{c.updn}.pkl")
        if cache.exists() and not force:
            layers, meta = pd.read_pickle(cache)
        else:
            d = unzip_cell(c.name)
            layers, meta = read_cell(d / f"{c.name}.000", {"name": c.name, "cscale": c.cscale})
            pd.to_pickle((layers, meta), cache)
            n_new += 1
        meta.setdefault("band", int(c.name[2]))
        metas.append(meta)
        for k, v in layers.items():
            per_layer.setdefault(k, []).append(v)
    return per_layer, metas, n_new


def extract_all(cells, force: bool = False) -> Path:
    """Spike helper: concatenate every cell into one GeoPackage."""
    dest = work("extract", "extract.gpkg")
    per_layer, metas, _ = extract_cells(cells, force)
    if dest.exists():
        dest.unlink()
    counts = {}
    for k, frames in sorted(per_layer.items()):
        g = gpd.GeoDataFrame(pd.concat(frames, ignore_index=True), crs="EPSG:4326")
        counts[k] = len(g)
        # GeoPackage needs one geometry type per layer only loosely; pyogrio
        # writes "GEOMETRY" when mixed, which is fine.
        g.to_file(dest, layer=k, driver="GPKG", engine="pyogrio")
    work("extract", "cells_meta.json").write_text(json.dumps(metas, indent=1))
    work("extract", "counts.json").write_text(json.dumps(counts, indent=1))
    return dest


def load(layer: str) -> gpd.GeoDataFrame:
    import pyogrio

    p = work("extract", "extract.gpkg")
    if layer not in {n for n, _ in pyogrio.list_layers(str(p))}:
        return gpd.GeoDataFrame({"geometry": []}, geometry="geometry", crs="EPSG:4326")
    return gpd.read_file(p, layer=layer, engine="pyogrio")
