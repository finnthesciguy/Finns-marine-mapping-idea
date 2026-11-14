"""Configuration: work directory, regions and build parameters.

Everything that is generated or downloaded lives under the work directory
(outside the repository). Override with the ENC_ROUTING_WORK environment
variable; it is read on every call, so tests can point it at a temporary
directory.
"""
from __future__ import annotations

import hashlib
import json
import os
from dataclasses import asdict, dataclass, field
from pathlib import Path

DEFAULT_WORK = (
    "/tmp/claude-0/-home-user-Finns-marine-mapping-idea/"
    "0d9063c0-a7fe-5990-bd5f-28d024ba18eb/scratchpad/gulf-packs"
)

CATALOG_URL = "https://www.charts.noaa.gov/ENCs/ENCProdCat.xml"
USER_AGENT = "enc-routing/0.3 (generic chart-data client)"

GEO_CRS = "EPSG:4326"
FT = 0.3048  # metres per foot
UNITS = 10_000_000  # integer pack units per degree

# S-57 navigational purpose (the 3rd character of the cell name) -> band name.
BANDS = {"1": "overview", "2": "general", "3": "coastal", "4": "approach", "5": "harbour",
         "6": "berthing"}

# Only cells of these bands feed the routing mesh: the routing domain is the
# coverage of coastal-or-better cells (band 1-2 cells would only add open
# ocean at 1:1,000,000 and smaller).
MIN_BAND = 3

# Fixed-box regions (lon_min, lat_min, lon_max, lat_max). "pilot" is the
# Wave 1/2 pilot (Tampa Bay to Charlotte Harbor). The five Gulf chart regions
# (ncds_10 .. ncds_14) are defined in regions.py from pipeline/catalog.
REGIONS = {
    "pilot": (-83.3, 26.3, -81.9, 28.1),
}
# Sub-areas cut out of a built pack for the test vectors.
CUTS = {
    "sarasota": ("pilot", (-82.62, 27.24, -82.50, 27.42)),
}

# Bump when the builder's output changes for identical inputs; part of every
# cache key and written into the pack's build info.
# 3.0.0: tiled build (per-tile local transverse Mercator), adaptive size grid,
#        derived open-Gulf mask, per-cell incremental merge, catalog via pipeline/catalog.
# 3.0.1: invalid projected geometry repaired per tile; union retried on a 1 mm grid.
BUILDER_VERSION = "3.0.1"


@dataclass(frozen=True)
class BuildParams:
    """Every number that shapes the mesh. Written into the pack's INFO
    section and hashed into the build cache key."""
    clearance_m: float = 12.0          # water is shrunk by this from land, structures, blocking hazards
    bridge_clearance_m: float = 4.0    # reduced clearance near bridges (openings are narrow) ...
    bridge_zone_m: float = 60.0        # ... within this distance of a bridge over water
    fender_clearance_m: float = 3.0    # smaller clearance from bridge fenders (SLCONS CATSLC 14)
    simplify_m: float = 1.0            # obstacle buffers are grown by 2*simplify_m, then simplified by simplify_m
    close_m: float = 5.0               # morphological closing of the water union (heals merge slivers)
    min_part_m2: float = 200.0         # water parts smaller than this are dropped
    hazard_ring_m: float = 30.0        # NEAR_HAZARD zone around every charted hazard
    shore_rings_m: tuple = (50.0, 150.0)  # distance bands from land/structures/blocking hazards (cost only)
    ring_simplify_m: float = 5.0       # simplification of cost-only rings (inward, see mesh.py)
    grid_deg: float = 0.02             # size grid near shore (degrees) ...
    coarse_grid_deg: float = 0.1       # ... and offshore: a 0.1 deg cell gets the fine grid only if it is
    fine_zone_m: float = 3000.0        # ... within this distance of land or a structure
    sounding_near_m: float = 12.0      # a shallower sounding lowers triangles this close
    tin_edge_frac: float = 0.02        # sounding TIN edge limit = frac * compilation scale ...
    tin_edge_cap_m: float = 400.0      # ... capped at this many metres
    ncf_tolerance_m: float = 15.0      # NCF reach polygons are grown by this (offset from the ENC channel)
    track_buffer_m: float = 15.0       # RECTRC/NAVLNE half-width counted as "in channel"
    highway_buffer_m: float = 30.0     # NCF centreline / ICW track half-width counted as highway
    overhead_line_buffer_m: float = 5.0
    overhead_poly_buffer_m: float = 0.0   # polygons are used as charted (no overlap between adjacent parts)
    index_cell_deg: float = 0.01       # point-location grid cell (degrees)
    sample_radius_units: float = 3.0   # attribute sampling disk, in 1e-7 degree units
    # tiling (the mesh is built per tile of a fixed lon/lat grid; see tiles.py)
    tile_deg: float = 0.2              # tile size; a multiple of coarse_grid_deg
    tile_margin_m: float = 600.0       # input features are taken this far beyond the tile
    line_margin_m: float = 200.0       # constraint lines are noded this far beyond the tile
    # open-Gulf mask (mask.py): water far from land, connected to deep offshore water, grown back to the shore
    mask_res_deg: float = 0.002        # raster cell (divides tile_deg)
    mask_seal_m: float = 5000.0        # passes and gaps narrower than twice this are sealed (inside)
    mask_seed_depth_dm: int = 91       # seeds: charted depth area of at least 30 ft (9.1 m) ...
    mask_seed_dist_m: float = 10000.0  # ... at least this far from land

    def key(self) -> str:
        return hashlib.sha256(json.dumps(asdict(self), sort_keys=True).encode()).hexdigest()[:16]


def work_dir() -> Path:
    return Path(os.environ.get("ENC_ROUTING_WORK", DEFAULT_WORK))


def work(*parts: str) -> Path:
    p = work_dir().joinpath(*parts)
    p.parent.mkdir(parents=True, exist_ok=True)
    return p


def tmerc(lon0: float) -> str:
    """Local metric projection: transverse Mercator centred on lon0."""
    return f"+proj=tmerc +lat_0=0 +lon_0={lon0:.4f} +k=1 +x_0=0 +y_0=0 +datum=WGS84 +units=m +no_defs"


def work_crs(bbox) -> str:
    """Metric working projection for an area: transverse Mercator centred
    on it (scale error < 1e-4 across a 2 degree wide area)."""
    return tmerc((bbox[0] + bbox[2]) / 2)


@dataclass(frozen=True)
class Region:
    rid: str
    bbox: tuple
    params: BuildParams = field(default_factory=BuildParams)
    area: object = field(default=None, compare=False, repr=False)   # lon/lat polygon (default: the bbox)
    chart_bbox: tuple | None = None    # the chart region's own box (overlap excluded), for reports

    @property
    def crs(self) -> str:
        return work_crs(self.bbox)

    @property
    def geometry(self):
        from shapely.geometry import box

        return self.area if self.area is not None else box(*self.bbox)

    def dir(self, *parts) -> Path:
        return work("regions", self.rid, *parts)
