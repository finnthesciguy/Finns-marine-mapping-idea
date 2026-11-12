"""Configuration: work directory, regions and build parameters.

Everything that is generated or downloaded lives under WORK_DIR (outside the
repository). Override with the ENC_ROUTING_WORK environment variable.
"""
from __future__ import annotations

import hashlib
import json
import os
from dataclasses import asdict, dataclass, field
from pathlib import Path

DEFAULT_WORK = (
    "/tmp/claude-0/-home-user-Finns-marine-mapping-idea/"
    "0d9063c0-a7fe-5990-bd5f-28d024ba18eb/scratchpad/routing-spike"
)
WORK_DIR = Path(os.environ.get("ENC_ROUTING_WORK", DEFAULT_WORK))

CATALOG_URL = "https://www.charts.noaa.gov/ENCs/ENCProdCat.xml"
USER_AGENT = "enc-routing/0.2 (generic chart-data client)"

GEO_CRS = "EPSG:4326"
FT = 0.3048  # metres per foot

# S-57 navigational purpose (the 3rd character of the cell name) -> band name.
BANDS = {"1": "overview", "2": "general", "3": "coastal", "4": "approach", "5": "harbour",
         "6": "berthing"}

# Regions (lon_min, lat_min, lon_max, lat_max). "pilot" is Tampa Bay to
# Charlotte Harbor.
REGIONS = {
    "pilot": (-83.3, 26.3, -81.9, 28.1),
}
# Sub-areas cut out of a built pack for the test vectors.
CUTS = {
    "sarasota": ("pilot", (-82.62, 27.24, -82.50, 27.42)),
}

# Bump when the builder's output changes for identical inputs; part of every
# cache key and written into the pack's build info.
BUILDER_VERSION = "2.0.0"


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
    grid_deg: float = 0.02             # constraint grid that bounds triangle size (degrees)
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

    def key(self) -> str:
        return hashlib.sha256(json.dumps(asdict(self), sort_keys=True).encode()).hexdigest()[:16]


def work(*parts: str) -> Path:
    p = WORK_DIR.joinpath(*parts)
    p.parent.mkdir(parents=True, exist_ok=True)
    return p


def work_crs(bbox) -> str:
    """Metric working projection for a region: transverse Mercator centred
    on the region (scale error < 1e-4 across a 2 degree wide region)."""
    lon0 = (bbox[0] + bbox[2]) / 2
    return f"+proj=tmerc +lat_0=0 +lon_0={lon0:.4f} +k=1 +x_0=0 +y_0=0 +datum=WGS84 +units=m +no_defs"


@dataclass(frozen=True)
class Region:
    rid: str
    bbox: tuple
    params: BuildParams = field(default_factory=BuildParams)

    @property
    def crs(self) -> str:
        return work_crs(self.bbox)

    def dir(self, *parts) -> Path:
        return work("regions", self.rid, *parts)
