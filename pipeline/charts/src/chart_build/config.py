"""Render configuration (what is drawn) and run policy (how politely it is fetched)."""
from __future__ import annotations

import copy
import hashlib
import json
from dataclasses import dataclass, field
from importlib import resources
from pathlib import Path

DEFAULT_USER_AGENT = "chart-tile-client/0.1 (python-requests)"

# Safe defaults. A weekly update has needed 400-2,500 metatile requests
# (median ~1,100); a full Gulf baseline needs ~27,000 and must be asked for
# explicitly with --budget.
DEFAULT_BUDGET = 2500
DEFAULT_RATE = 1.0          # requests per second, sustained
DEFAULT_MAX_INFLIGHT = 2


def _data(name: str) -> dict:
    return json.loads(resources.files("chart_build").joinpath("data", name).read_text())


@dataclass(frozen=True)
class RenderConfig:
    """Pinned export parameters. Anything that changes pixels lives here and is
    part of config_hash (stored in every package and in the build state)."""
    raw: dict
    scale: int = 1  # 1 = 256 px tiles at 96 dpi; 2 = 512 px "@2x" tiles at 192 dpi

    @staticmethod
    def load(path: str | Path | None = None, scale: int = 1) -> "RenderConfig":
        raw = json.loads(Path(path).read_text()) if path else _data("render.json")
        if scale not in (1, 2):
            raise ValueError("scale must be 1 or 2")
        return RenderConfig(raw, scale)

    @property
    def service(self) -> str:
        return self.raw["service"]

    @property
    def tile_px(self) -> int:
        return self.raw["tile_px"] * self.scale

    @property
    def metatile(self) -> int:
        """Tiles per metatile side. The request stays 2048 px wide at @2x, so
        it covers 4 x 4 tiles instead of 8 x 8."""
        return max(1, self.raw["metatile"] // self.scale)

    @property
    def gutter_px(self) -> int:
        return self.raw["gutter_px"] * self.scale

    @property
    def dpi(self) -> int:
        # Size and dpi must scale together, or the service draws a different
        # display scale (and different cells) for the same footprint.
        return self.raw["base_dpi"] * self.scale

    def with_overrides(self, **kw) -> "RenderConfig":
        raw = copy.deepcopy(self.raw)
        raw.update(kw)
        return RenderConfig(raw, self.scale)

    def pixel_fields(self) -> dict:
        r = {k: v for k, v in self.raw.items() if not k.startswith("_")}
        r["scale"] = self.scale
        return r

    @property
    def config_hash(self) -> str:
        blob = json.dumps(self.pixel_fields(), sort_keys=True, separators=(",", ":"))
        return hashlib.sha256(blob.encode()).hexdigest()[:16]

    def export_params(self, bbox: tuple[float, float, float, float], size: int) -> dict:
        d = self.raw.get("bbox_decimals", 6)
        return {
            "bbox": ",".join(f"{v:.{d}f}" for v in bbox),
            "bboxSR": 3857,
            "imageSR": 3857,
            "size": f"{size},{size}",
            "dpi": self.dpi,
            "format": self.raw["format"],
            "transparent": "true" if self.raw.get("transparent", True) else "false",
            "layers": self.raw["layers"],
            "display_params": json.dumps(self.raw["display_params"], separators=(",", ":"), sort_keys=False),
            "f": "image",
        }


@dataclass(frozen=True)
class RegionDef:
    id: str
    title: str
    bbox: tuple[float, float, float, float]
    summary: str | None = None
    zoom_boxes: tuple[tuple[int, tuple[float, float, float, float]], ...] = ()

    def bbox_at(self, z: int) -> tuple[float, float, float, float]:
        """The box in force at zoom z: the region box narrowed by every zoom box whose min_zoom <= z."""
        w, s, e, n = self.bbox
        for mz, (bw, bs, be, bn) in self.zoom_boxes:
            if z >= mz:
                w, s, e, n = max(w, bw), max(s, bs), min(e, be), min(n, bn)
        return w, s, e, n


def load_regions(path: str | Path | None = None) -> dict[str, RegionDef]:
    raw = json.loads(Path(path).read_text()) if path else _data("regions.json")
    out = {}
    for rid, r in raw["regions"].items():
        zb = tuple(sorted((int(b["min_zoom"]), tuple(b["bbox"])) for b in r.get("zoom_boxes", [])))
        out[rid] = RegionDef(rid, r["title"], tuple(r["bbox"]), r.get("summary"), zb)
    return out


def region_from_bbox(rid: str, bbox, title: str | None = None) -> RegionDef:
    return RegionDef(rid, title or rid, tuple(bbox))


@dataclass
class RunPolicy:
    """How hard we may lean on NOAA. Enforced by http.PoliteClient."""
    rate: float = DEFAULT_RATE
    max_inflight: int = DEFAULT_MAX_INFLIGHT
    budget: int = DEFAULT_BUDGET
    timeout: float = 90.0
    retries: int = 4
    backoff: float = 4.0
    max_consecutive_failures: int = 3
    user_agent: str = DEFAULT_USER_AGENT
    allow_friday: bool = False
    extra: dict = field(default_factory=dict)

    def __post_init__(self):
        if not (0 < self.rate <= 2.0):
            raise ValueError("rate must be in (0, 2] requests/s")
        if not (1 <= self.max_inflight <= 2):
            raise ValueError("max_inflight must be 1 or 2")
        if self.budget < 0:
            raise ValueError("budget must be >= 0")
