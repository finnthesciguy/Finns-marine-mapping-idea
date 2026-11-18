"""Parse NOAA's ENC product catalog (ENCProdCat.xml).

The catalog is a flat list of <cell> elements. Each has scalar children
(name, lname, cscale, status, zipfile_*, edtn, updn, uadt, isdt), lists
(coast_guard_districts/coast_guard_district, states/state, regions/region) and
an optional <cov> with one or more <panel>s. A panel has <type> E (exterior)
or I (interior hole) and a ring of <vertex><lat/><long/></vertex>. Cancelled
cells carry no <cov>.
"""
from __future__ import annotations

import xml.etree.ElementTree as ET
from dataclasses import dataclass, field
from typing import IO, Iterable, Iterator

from shapely.geometry import Polygon
from shapely.ops import unary_union

CATALOG_URL = "https://www.charts.noaa.gov/ENCs/ENCProdCat.xml"

BAND_NAMES = {
    1: "overview",
    2: "general",
    3: "coastal",
    4: "approach",
    5: "harbour",
    6: "berthing",
}


@dataclass
class Panel:
    number: int
    kind: str  # "E" exterior, "I" interior
    ring: list[tuple[float, float]]  # (lon, lat)


@dataclass
class Cell:
    name: str
    lname: str = ""
    cscale: int = 0
    status: str = ""
    coast_guard_districts: list[str] = field(default_factory=list)
    states: list[str] = field(default_factory=list)
    regions: list[str] = field(default_factory=list)
    zipfile_location: str = ""
    zipfile_datetime: str = ""  # ISO 8601 (zipfile_datetime_iso8601)
    zipfile_size: int = 0
    edtn: int = 0
    updn: int = 0
    uadt: str = ""  # update application date, YYYY-MM-DD
    isdt: str = ""  # issue date, YYYY-MM-DD
    panels: list[Panel] = field(default_factory=list)

    @property
    def active(self) -> bool:
        return self.status.lower() == "active"

    @property
    def band(self) -> int:
        """Usage band from the cell name (US<band>...), falling back to scale."""
        if len(self.name) >= 3 and self.name[2].isdigit() and 1 <= int(self.name[2]) <= 6:
            return int(self.name[2])
        return band_from_scale(self.cscale)

    @property
    def band_name(self) -> str:
        return BAND_NAMES.get(self.band, f"band{self.band}")

    def coverage(self):
        """Shapely geometry of the coverage (exterior panels minus interior panels), or None."""
        return coverage_geometry(self.panels)

    def bbox(self) -> tuple[float, float, float, float] | None:
        pts = [p for panel in self.panels if panel.kind == "E" for p in panel.ring]
        if not pts:
            return None
        xs = [p[0] for p in pts]
        ys = [p[1] for p in pts]
        return (min(xs), min(ys), max(xs), max(ys))


@dataclass
class Catalog:
    date_created: str
    time_created: str
    dt_valid: str
    cells: list[Cell]

    def by_name(self) -> dict[str, Cell]:
        return {c.name: c for c in self.cells}


def band_from_scale(cscale: int) -> int:
    """Rough usage band from compilation scale (used only if the name has no band digit)."""
    if cscale <= 0:
        return 0
    if cscale >= 1_500_000:
        return 1
    if cscale >= 350_000:
        return 2
    if cscale >= 90_000:
        return 3
    if cscale >= 22_000:
        return 4
    if cscale >= 4_000:
        return 5
    return 6


def coverage_geometry(panels: Iterable[Panel]):
    ext, holes = [], []
    for p in panels:
        if len(p.ring) < 3:
            continue
        poly = Polygon(p.ring)
        if not poly.is_valid:
            poly = poly.buffer(0)
        (holes if p.kind == "I" else ext).append(poly)
    if not ext:
        return None
    geom = unary_union(ext)
    if holes:
        geom = geom.difference(unary_union(holes))
    return geom


def _int(text: str | None) -> int:
    try:
        return int((text or "").strip())
    except ValueError:
        return 0


def _float(text: str | None) -> float:
    return float((text or "").strip())


def _cell_from_element(el: ET.Element) -> Cell:
    t = lambda tag: (el.findtext(tag) or "").strip()  # noqa: E731
    panels = []
    for pe in el.findall("cov/panel"):
        ring = []
        for v in pe.findall("vertex"):
            ring.append((_float(v.findtext("long")), _float(v.findtext("lat"))))
        panels.append(Panel(_int(pe.findtext("panel_no")), (pe.findtext("type") or "E").strip(), ring))
    return Cell(
        name=t("name"),
        lname=t("lname"),
        cscale=_int(t("cscale")),
        status=t("status"),
        coast_guard_districts=[(x.text or "").strip() for x in el.findall("coast_guard_districts/coast_guard_district")],
        states=[(x.text or "").strip() for x in el.findall("states/state")],
        regions=[(x.text or "").strip() for x in el.findall("regions/region")],
        zipfile_location=t("zipfile_location"),
        zipfile_datetime=t("zipfile_datetime_iso8601"),
        zipfile_size=_int(t("zipfile_size")),
        edtn=_int(t("edtn")),
        updn=_int(t("updn")),
        uadt=t("uadt"),
        isdt=t("isdt"),
        panels=panels,
    )


def iter_cells(source: str | IO[bytes]) -> Iterator[Cell]:
    """Stream cells from a catalog file path or binary file object."""
    for _event, el in ET.iterparse(source, events=("end",)):
        if el.tag == "cell":
            yield _cell_from_element(el)
            el.clear()


def parse_catalog(source: str | IO[bytes]) -> Catalog:
    header = {}
    cells = []
    for _event, el in ET.iterparse(source, events=("end",)):
        if el.tag == "cell":
            cells.append(_cell_from_element(el))
            el.clear()
        elif el.tag == "Header":
            header = {ch.tag: (ch.text or "").strip() for ch in el}
    return Catalog(
        date_created=header.get("date_created", ""),
        time_created=header.get("time_created", ""),
        dt_valid=header.get("dt_valid", ""),
        cells=cells,
    )


__all__ = [
    "BAND_NAMES",
    "CATALOG_URL",
    "Catalog",
    "Cell",
    "Panel",
    "band_from_scale",
    "coverage_geometry",
    "iter_cells",
    "parse_catalog",
]
