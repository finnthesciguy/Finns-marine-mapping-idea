"""Static configuration for the routing-data spike.

Everything that is generated or downloaded lives under WORK_DIR (outside the
repository). Override with the ENC_ROUTING_WORK environment variable.
"""
from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path

DEFAULT_WORK = (
    "/tmp/claude-0/-home-user-Finns-marine-mapping-idea/"
    "0d9063c0-a7fe-5990-bd5f-28d024ba18eb/scratchpad/routing-spike"
)
WORK_DIR = Path(os.environ.get("ENC_ROUTING_WORK", DEFAULT_WORK))

CATALOG_URL = "https://www.charts.noaa.gov/ENCs/ENCProdCat.xml"
USER_AGENT = "enc-routing-spike/0.1 (generic research client)"

# Pilot area: Tampa Bay to Charlotte Harbor (lon_min, lat_min, lon_max, lat_max).
PILOT_BBOX = (-83.3, 26.3, -81.9, 28.1)

# Metric working projection for the pilot: UTM zone 17N (NAD83 / WGS84 are
# within a metre of each other here, which is below chart accuracy).
WORK_CRS = "EPSG:32617"
GEO_CRS = "EPSG:4326"

FT = 0.3048  # metres per foot

# Safe-water thresholds in feet at chart datum (MLLW).
THRESHOLDS_FT = (3, 4, 5, 6, 8, 10, 15)

# S-57 navigational purpose (the 3rd character of the cell name) -> band name.
BANDS = {
    "1": "overview",
    "2": "general",
    "3": "coastal",
    "4": "approach",
    "5": "harbour",
    "6": "berthing",
}


@dataclass(frozen=True)
class BoatProfile:
    draft_ft: float = 4.5
    margin_ft: float = 1.5
    air_draft_ft: float = 20.0

    @property
    def required_depth_ft(self) -> float:
        return self.draft_ft + self.margin_ft


def work(*parts: str) -> Path:
    p = WORK_DIR.joinpath(*parts)
    p.parent.mkdir(parents=True, exist_ok=True)
    return p
