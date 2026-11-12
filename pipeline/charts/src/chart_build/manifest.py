"""manifest.json for the app (ChartKit schema version 1, Packages/ChartKit/README.md).

`validate` mirrors ChartManifest.validate() plus the decoder's type rules, so
a manifest that passes here decodes in the app."""
from __future__ import annotations

import re
from datetime import date, datetime, timezone

SCHEMA_VERSION = 1
ID_RE = re.compile(r"^[A-Za-z0-9._-]{1,64}$")
HEX64 = re.compile(r"^[0-9a-f]{64}$")
TILE_FORMATS = {"png", "jpg", "webp", "pbf"}
MAX_ZOOM = 30


class ManifestInvalid(ValueError):
    pass


def _parse_date(s) -> bool:
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


def _artifact(a, rid: str, what: str, routing: bool = False) -> None:
    if not isinstance(a, dict):
        raise ManifestInvalid(f"region {rid}: {what} must be an object")
    for k in ("url", "byteSize", "sha256", "version", "dataDate"):
        if k not in a:
            raise ManifestInvalid(f"region {rid}: {what}.{k} is required")
    if not isinstance(a["byteSize"], int) or isinstance(a["byteSize"], bool) or a["byteSize"] <= 0:
        raise ManifestInvalid(f"region {rid}: {what}.byteSize must be an integer > 0")
    if not isinstance(a["sha256"], str) or not HEX64.match(a["sha256"].lower()):
        raise ManifestInvalid(f"region {rid}: {what}.sha256 is not a 64-character hex digest")
    if not isinstance(a["url"], str) or not re.match(r"^https?://[^\s]+$", a["url"], re.I):
        raise ManifestInvalid(f"region {rid}: {what}.url must be http(s)")
    if not isinstance(a["version"], str) or not a["version"]:
        raise ManifestInvalid(f"region {rid}: {what}.version is empty")
    if not _parse_date(a["dataDate"]):
        raise ManifestInvalid(f"region {rid}: {what}.dataDate is not an ISO 8601 date: {a['dataDate']!r}")
    if routing and "formatVersion" in a and not isinstance(a["formatVersion"], int):
        raise ManifestInvalid(f"region {rid}: {what}.formatVersion must be an integer")


def validate(m: dict) -> None:
    if not isinstance(m, dict):
        raise ManifestInvalid("manifest must be an object")
    sv = m.get("schemaVersion")
    if not isinstance(sv, int) or isinstance(sv, bool) or sv < 1:
        raise ManifestInvalid("schemaVersion must be an integer >= 1")
    if sv > SCHEMA_VERSION:
        raise ManifestInvalid(f"schemaVersion {sv} is newer than supported ({SCHEMA_VERSION})")
    if not _parse_date(m.get("generatedAt")):
        raise ManifestInvalid("generatedAt must be an ISO 8601 timestamp")
    if "publisher" in m and not isinstance(m["publisher"], str):
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
            raise ManifestInvalid(f"duplicate region id {rid}")
        seen.add(rid)
        for k in ("title", "bounds", "minZoom", "maxZoom", "tileFormat", "package", "source"):
            if k not in r:
                raise ManifestInvalid(f"region {rid}: {k} is required")
        if not isinstance(r["title"], str) or not isinstance(r["source"], str):
            raise ManifestInvalid(f"region {rid}: title and source must be strings")
        if "summary" in r and not isinstance(r["summary"], str):
            raise ManifestInvalid(f"region {rid}: summary must be a string")
        b = r["bounds"]
        try:
            w, s, e, n = (float(b[k]) for k in ("west", "south", "east", "north"))
        except (KeyError, TypeError, ValueError):
            raise ManifestInvalid(f"region {rid}: bounds needs numeric west/south/east/north") from None
        if not (-180 <= w < e <= 180 and -90 <= s < n <= 90):
            raise ManifestInvalid(f"region {rid}: invalid bounds {b}")
        lo, hi = r["minZoom"], r["maxZoom"]
        if not all(isinstance(v, int) and not isinstance(v, bool) for v in (lo, hi)) or not (0 <= lo <= hi <= MAX_ZOOM):
            raise ManifestInvalid(f"region {rid}: invalid zoom range {lo}-{hi}")
        tf = str(r["tileFormat"]).lower()
        if tf == "jpeg":
            tf = "jpg"
        if tf not in TILE_FORMATS:
            raise ManifestInvalid(f"region {rid}: unknown tileFormat {r['tileFormat']}")
        _artifact(r["package"], rid, "package")
        if "routingPack" in r and r["routingPack"] is not None:
            _artifact(r["routingPack"], rid, "routingPack", routing=True)


def region_entry(region, rec: dict, url: str) -> dict:
    """Manifest region for a built package version record (state.versions.json entry)."""
    w, s, e, n = rec["bounds"]
    built = rec["built_at"][:10]
    kind = "baseline" if rec["mode"] == "baseline" else f"weekly update of {rec.get('base_version')}"
    entry = {
        "id": rec.get("package_id", region.id),
        "title": region.title + ("" if rec.get("scale", 1) == 1 else " (high resolution)"),
        "bounds": {"west": w, "south": s, "east": e, "north": n},
        "minZoom": rec["minzoom"],
        "maxZoom": rec["maxzoom"],
        "tileFormat": "png",
        "package": {
            "url": url,
            "byteSize": rec["bytes"],
            "sha256": rec["sha256"],
            "version": rec["version"],
            "dataDate": rec["data_date"] or rec["catalog_date"],
        },
        "source": (f"NOAA ENC® charts as of {rec['catalog_date']}, rendered by NOAA's chart display service; "
                   f"built {built} ({kind})"),
    }
    if region.summary:
        entry["summary"] = region.summary
    return entry


def build(regions: list[dict], publisher: str = "Gulf chart build service", base: dict | None = None,
          now: datetime | None = None) -> dict:
    """New manifest: entries from `regions` replace same-id entries of `base`
    (the previously published manifest); other base entries are kept."""
    out = {r["id"]: r for r in (base or {}).get("regions", [])}
    for r in regions:
        out[r["id"]] = r
    m = {
        "schemaVersion": SCHEMA_VERSION,
        "generatedAt": (now or datetime.now(timezone.utc)).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "publisher": publisher,
        "regions": [out[k] for k in sorted(out)],
    }
    validate(m)
    return m
