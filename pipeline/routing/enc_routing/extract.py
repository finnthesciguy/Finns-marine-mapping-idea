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
    # names only (reference-route endpoints and reports; not used by the mesh)
    "SEAARE": ["CATSEA"],
    "LNDRGN": ["CATLND"],
    "BUAARE": [],
    "HRBFAC": ["CATHAF"],
    "SMCFAC": ["CATSCF"],
}

EXTRACT_VERSION = "v3"  # bump when LAYERS or read_cell change (part of the cache path)

# DSPM values every NOAA Gulf cell is expected to carry (verified on the pilot):
# WGS 84, soundings at MLLW, heights above MHW, metres for depth and height.
EXPECTED_DSPM = {"HDAT": 2, "SDAT": 12, "VDAT": 16, "DUNI": 1, "HUNI": 1}


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
    def _i(v):
        try:
            return int(v)
        except (TypeError, ValueError):
            return None

    meta.update(
        dspm={k: _i(getattr(r, f"DSPM_{k}", None)) for k in ("HDAT", "VDAT", "SDAT", "DUNI", "HUNI", "CSCL")},
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


def _extract_one(args):
    """Worker: unzip, read and cache one cell. Returns (name, meta) or (name, error)."""
    name, cscale, cache = args
    from .download import unzip_cell

    import warnings

    try:
        d = unzip_cell(name)
        with warnings.catch_warnings(record=True) as caught:
            warnings.simplefilter("always")
            layers, meta = read_cell(d / f"{name}.000", {"name": name, "cscale": cscale})
        # GDAL warnings (e.g. illegal attribute ids, huge multipolygons) are reported per cell
        meta["warnings"] = sorted({str(w.message).split(". ")[0][:160] for w in caught})
    except Exception as e:  # noqa: BLE001 - a broken cell is reported and left out
        return name, None, f"{type(e).__name__}: {e}"
    tmp = Path(str(cache) + ".tmp")
    pd.to_pickle((layers, meta), tmp)
    os.replace(tmp, cache)
    return name, meta, None


def cell_anomalies(meta: dict, layers: dict | None, cat_updn: int | None = None) -> list[str]:
    """Things about a cell the build should report."""
    out = [f"GDAL: {w}" for w in meta.get("warnings", [])]
    for k, v in EXPECTED_DSPM.items():
        got = meta.get("dspm", {}).get(k)
        if got != v:
            out.append(f"DSPM {k}={got} (expected {v})")
    if cat_updn is not None and str(meta.get("updn")) != str(cat_updn):
        out.append(f"applied update {meta.get('updn')} != catalog {cat_updn}")
    if layers is not None:
        mc = layers.get("M_COVR")
        if mc is None or mc.empty or not (pd.to_numeric(mc.CATCOV, errors="coerce") == 1).any():
            out.append("no M_COVR with CATCOV=1 (catalog coverage used instead)")
        dep = layers.get("DEPARE")
        if dep is not None and len(dep):
            bad = pd.to_numeric(dep.DRVAL1, errors="coerce").isna() & dep.geom_type.isin(["Polygon", "MultiPolygon"])
            if bad.any():
                out.append(f"{int(bad.sum())} DEPARE without DRVAL1 (treated as not navigable)")
    return out


def cache_path(c) -> Path:
    return work("extract", EXTRACT_VERSION, f"{c.name}.{c.edtn}.{c.updn}.pkl")


def extract_cells(cells, force: bool = False, workers: int = 4, log=print) -> dict:
    """Extract every cell not yet cached for its edition and update (in
    parallel). Returns {name: error} for the cells that could not be read."""
    from concurrent.futures import ProcessPoolExecutor

    todo = [c for c in cells if force or not cache_path(c).exists()]
    errors = {}
    if todo:
        log(f"extracting {len(todo)} cells with {workers} workers")
        args = [(c.name, int(c.cscale), cache_path(c)) for c in todo]
        with ProcessPoolExecutor(workers) as ex:
            for k, (name, meta, err) in enumerate(ex.map(_extract_one, args, chunksize=4)):
                if err:
                    errors[name] = err
                    log(f"  extract failed: {name}: {err}")
                if (k + 1) % 100 == 0:
                    log(f"  extracted {k + 1}/{len(todo)}")
    return errors


def load_cell(c):
    """(layers, meta) of a cached cell extraction."""
    layers, meta = pd.read_pickle(cache_path(c))
    meta.setdefault("band", int(c.name[2]))
    return layers, meta
