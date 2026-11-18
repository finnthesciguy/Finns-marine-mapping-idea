"""Routing-pack entries for the app's chart manifest (ChartKit schema 1).

`python -m enc_routing manifest --manifest manifest.json --region ncds_10 ...`
writes each built region's `routingPack` object into the existing region
entry of a manifest file:

    "routingPack": {"url": ..., "byteSize": ..., "sha256": ..., "version": ...,
                    "dataDate": "YYYY-MM-DD", "formatVersion": 1}

and validates the whole manifest with ChartKit's rules (mirrored here from
Packages/ChartKit/Sources/ChartKit/Manifest.swift: ChartManifest.validate()
plus the decoder's type and date rules). Nothing is uploaded or published:
`url` is a placeholder built from a template until hosting is decided.
"""
from __future__ import annotations

import hashlib
import json
import os
import re
from datetime import date, datetime, timezone
from pathlib import Path

SCHEMA_VERSION = 1
ID_RE = re.compile(r"^[A-Za-z0-9._-]{1,64}$")
HEX64 = re.compile(r"^[0-9a-fA-F]{64}$")
TILE_FORMATS = {"png", "jpg", "jpeg", "webp", "pbf"}
MAX_ZOOM = 30
DEFAULT_URL_TEMPLATE = "https://example.invalid/routing/{file}"


class ManifestInvalid(ValueError):
    pass


def parse_date(s) -> bool:
    """ChartKit ChartDates.parse: date-only (10 chars) or ISO 8601 with time."""
    if not isinstance(s, str):
        return False
    t = s.strip()
    if len(t) == 10:
        try:
            date.fromisoformat(t)
            return True
        except ValueError:
            return False
    try:
        datetime.fromisoformat(t.replace("Z", "+00:00"))
        return "T" in t
    except ValueError:
        return False


def _is_int(v) -> bool:
    return isinstance(v, int) and not isinstance(v, bool)


def _artifact(a, rid: str, what: str, routing: bool = False) -> None:
    if not isinstance(a, dict):
        raise ManifestInvalid(f"region {rid}: {what} must be an object")
    for k in ("url", "byteSize", "sha256", "version", "dataDate"):
        if k not in a:
            raise ManifestInvalid(f"region {rid}: {what}.{k} is required")
    if not _is_int(a["byteSize"]) or a["byteSize"] <= 0:
        raise ManifestInvalid(f"region {rid}: {what}.byteSize must be an integer > 0")
    if not isinstance(a["sha256"], str) or not HEX64.match(a["sha256"]):
        raise ManifestInvalid(f"region {rid}: {what}.sha256 is not a 64-character hex digest")
    if not isinstance(a["url"], str) or not re.match(r"^https?://\S+$", a["url"], re.I):
        raise ManifestInvalid(f"region {rid}: {what}.url must be http(s)")
    if not isinstance(a["version"], str) or not a["version"]:
        raise ManifestInvalid(f"region {rid}: {what}.version is empty")
    if not parse_date(a["dataDate"]):
        raise ManifestInvalid(f"region {rid}: {what}.dataDate is not an ISO 8601 date: {a['dataDate']!r}")
    if routing and "formatVersion" in a and a["formatVersion"] is not None and not _is_int(a["formatVersion"]):
        raise ManifestInvalid(f"region {rid}: {what}.formatVersion must be an integer")


def validate(m: dict) -> None:
    """Raise ManifestInvalid with the first problem ChartKit would report."""
    if not isinstance(m, dict):
        raise ManifestInvalid("manifest must be an object")
    sv = m.get("schemaVersion")
    if not _is_int(sv) or sv < 1:
        raise ManifestInvalid("schemaVersion must be an integer >= 1")
    if sv > SCHEMA_VERSION:
        raise ManifestInvalid(f"schemaVersion {sv} is newer than supported ({SCHEMA_VERSION})")
    if not parse_date(m.get("generatedAt")):
        raise ManifestInvalid("generatedAt must be an ISO 8601 timestamp")
    if "publisher" in m and m["publisher"] is not None and not isinstance(m["publisher"], str):
        raise ManifestInvalid("publisher must be a string")
    regions = m.get("regions")
    if not isinstance(regions, list):
        raise ManifestInvalid("regions must be an array")
    seen = set()
    for r in regions:
        rid = r.get("id") if isinstance(r, dict) else None
        if not isinstance(rid, str) or not ID_RE.match(rid) or rid in (".", ".."):
            raise ManifestInvalid(f"invalid region id {rid!r}")
        if rid in seen:
            raise ManifestInvalid(f"region {rid}: duplicate id")
        seen.add(rid)
        for k in ("title", "bounds", "minZoom", "maxZoom", "tileFormat", "package", "source"):
            if k not in r:
                raise ManifestInvalid(f"region {rid}: {k} is required")
        if not isinstance(r["title"], str) or not isinstance(r["source"], str):
            raise ManifestInvalid(f"region {rid}: title and source must be strings")
        if "summary" in r and r["summary"] is not None and not isinstance(r["summary"], str):
            raise ManifestInvalid(f"region {rid}: summary must be a string")
        b = r["bounds"]
        try:
            w, s, e, n = (float(b[k]) for k in ("west", "south", "east", "north"))
        except (KeyError, TypeError, ValueError):
            raise ManifestInvalid(f"region {rid}: bounds needs numeric west/south/east/north") from None
        if not (-180 <= w < e <= 180 and -90 <= s < n <= 90):
            raise ManifestInvalid(f"region {rid}: invalid bounds {b}")
        lo, hi = r["minZoom"], r["maxZoom"]
        if not (_is_int(lo) and _is_int(hi)) or not (0 <= lo <= hi <= MAX_ZOOM):
            raise ManifestInvalid(f"region {rid}: invalid zoom range {lo}-{hi}")
        if str(r["tileFormat"]).lower() not in TILE_FORMATS:
            raise ManifestInvalid(f"region {rid}: unknown tileFormat {r['tileFormat']}")
        _artifact(r["package"], rid, "package")
        if r.get("routingPack") is not None:
            _artifact(r["routingPack"], rid, "routingPack", routing=True)


def _ymd_iso(v: int) -> str:
    s = str(int(v))
    return f"{s[:4]}-{s[4:6]}-{s[6:8]}"


def routing_entry(pack_path, url_template: str = DEFAULT_URL_TEMPLATE, region_id: str | None = None) -> dict:
    """The routingPack object for a pack file (size and SHA-256 computed from
    the file; version = data date + first 8 hex of the content hash, so it
    changes exactly when the pack content changes)."""
    from . import packfmt as P

    path = Path(pack_path)
    raw = path.read_bytes()
    h = P.read_header(raw)
    sha = hashlib.sha256(raw).hexdigest()
    content = hashlib.sha256(raw[P.HEADER_SIZE:]).hexdigest()
    rid = region_id or h["region_id"]
    return {"url": url_template.format(region=rid, file=path.name),
            "byteSize": len(raw), "sha256": sha,
            "version": f"{_ymd_iso(h['data_date'])}.{content[:8]}",
            "dataDate": _ymd_iso(h["data_date"]),
            "formatVersion": int(h["major"])}


def merge_into(manifest: dict, entries: dict, now: datetime | None = None, touch: bool = True) -> tuple[dict, list]:
    """Set routingPack on the manifest's regions; returns (new manifest,
    region ids that are not in the manifest and were skipped: a region entry
    needs a chart package, which only the chart build can supply)."""
    m = json.loads(json.dumps(manifest))
    by_id = {r.get("id"): r for r in m.get("regions", []) if isinstance(r, dict)}
    skipped = []
    for rid, e in sorted(entries.items()):
        if rid not in by_id:
            skipped.append(rid)
            continue
        by_id[rid]["routingPack"] = e
    if touch:
        m["generatedAt"] = (now or datetime.now(timezone.utc)).strftime("%Y-%m-%dT%H:%M:%SZ")
    validate(m)
    return m, skipped


def write_manifest(m: dict, path) -> None:
    path = Path(path)
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_text(json.dumps(m, indent=2, ensure_ascii=False) + "\n")
    os.replace(tmp, path)
