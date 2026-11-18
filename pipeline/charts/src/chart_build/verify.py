"""Package checks: the integrity rules ChartKit's MBTilesReader applies, plus
build-specific coverage checks and a sampled visual diff against a previous
version."""
from __future__ import annotations

import io
import random
import sqlite3
from pathlib import Path

import numpy as np
from PIL import Image

from .grid import Metatile, metatiles_for, tile_bounds_lonlat
from .mbtiles import open_ro, read_tile_set
from .renderer import decode_rgba

PNG_SIG = b"\x89PNG\r\n\x1a\n"
REQUIRED_META = ["name", "format", "bounds", "minzoom", "maxzoom", "type", "attribution", "version",
                 "data_date", "build_version", "build_date", "build_config_hash"]


def sniff(data: bytes) -> str | None:
    if data[:8] == PNG_SIG:
        return "png"
    if data[:3] == b"\xff\xd8\xff":
        return "jpg"
    if data[:4] == b"RIFF" and data[8:12] == b"WEBP":
        return "webp"
    return None


def check_package(path: str | Path, wanted: dict | None = None, metatile_n: int | None = None,
                  decode: str = "all") -> dict:
    """Returns {"ok": bool, "errors": [...], "warnings": [...], "stats": {...}}."""
    path = Path(path)
    errors, warnings, stats = [], [], {}
    with open(path, "rb") as f:
        if f.read(16) != b"SQLite format 3\x00":
            return {"ok": False, "errors": ["not an SQLite database"], "warnings": [], "stats": {}}
    conn = open_ro(path)
    try:
        qc = conn.execute("PRAGMA quick_check").fetchone()[0]
        if qc != "ok":
            errors.append(f"quick_check: {qc}")
        kinds = dict(conn.execute("SELECT name, type FROM sqlite_master WHERE name IN ('tiles','metadata')"))
        if "tiles" not in kinds:
            errors.append("no tiles table or view")
        if "metadata" not in kinds:
            errors.append("no metadata table")
        if errors:
            return {"ok": False, "errors": errors, "warnings": warnings, "stats": stats}
        stats["tiles_schema"] = kinds["tiles"]
        for table, cols in (("tiles", {"zoom_level", "tile_column", "tile_row", "tile_data"}), ("metadata", {"name", "value"})):
            have = {r[1].lower() for r in conn.execute(f"PRAGMA table_info({table})")}
            if cols - have:
                errors.append(f"{table} is missing columns {sorted(cols - have)}")
        if conn.execute("SELECT 1 FROM sqlite_master WHERE name='chart_build_pending'").fetchone():
            errors.append("unfinished work file (chart_build_pending present)")
        meta = dict(conn.execute("SELECT name, value FROM metadata"))
        stats["metadata"] = {k: v for k, v in meta.items() if k != "legend"}
        for k in REQUIRED_META:
            if not meta.get(k):
                errors.append(f"metadata.{k} missing")
        fmt = meta.get("format", "").lower()
        try:
            b = [float(v) for v in meta.get("bounds", "").split(",")]
            if len(b) != 4 or not (-180 <= b[0] < b[2] <= 180 and -90 <= b[1] < b[3] <= 90):
                errors.append(f"metadata.bounds invalid: {meta.get('bounds')}")
        except ValueError:
            errors.append(f"metadata.bounds unparseable: {meta.get('bounds')}")
            b = None
        sample = conn.execute("SELECT tile_data FROM tiles WHERE tile_data IS NOT NULL LIMIT 1").fetchone()
        if not sample or not sample[0]:
            errors.append("package contains no tiles")
            return {"ok": False, "errors": errors, "warnings": warnings, "stats": stats}
        if sniff(sample[0]) != fmt:
            errors.append(f"tile data is {sniff(sample[0])} but metadata says {fmt}")
        zr = conn.execute("SELECT MIN(zoom_level), MAX(zoom_level) FROM tiles").fetchone()
        try:
            if (int(meta.get("minzoom", -1)), int(meta.get("maxzoom", -1))) != tuple(zr):
                errors.append(f"metadata zoom range {meta.get('minzoom')}-{meta.get('maxzoom')} != tiles {zr[0]}-{zr[1]}")
        except ValueError:
            errors.append("metadata minzoom/maxzoom not integers")
        per_zoom = dict(conn.execute("SELECT zoom_level, COUNT(*) FROM tiles GROUP BY zoom_level"))
        stats["tiles_per_zoom"] = per_zoom
        stats["tiles"] = sum(per_zoom.values())
        has_split = kinds["tiles"] == "view"
        if has_split:
            stats["images"] = conn.execute("SELECT COUNT(*) FROM images").fetchone()[0]
            orphans_map = conn.execute("SELECT COUNT(*) FROM map WHERE tile_id NOT IN (SELECT tile_id FROM images)").fetchone()[0]
            orphan_img = conn.execute("SELECT COUNT(*) FROM images WHERE tile_id NOT IN (SELECT tile_id FROM map)").fetchone()[0]
            if orphans_map:
                errors.append(f"{orphans_map} map rows point at missing images")
            if orphan_img:
                warnings.append(f"{orphan_img} images are not referenced")
            stats["dedup_ratio"] = round(stats["tiles"] / max(1, stats["images"]), 2)
        dup = conn.execute("SELECT COUNT(*) FROM (SELECT 1 FROM tiles GROUP BY zoom_level, tile_column, tile_row HAVING COUNT(*) > 1)").fetchone()[0]
        if dup:
            errors.append(f"{dup} duplicated tile addresses")
        # Every tile inside the world grid and touching the bounds.
        bad_addr = conn.execute("SELECT COUNT(*) FROM tiles WHERE tile_column < 0 OR tile_row < 0 OR "
                                "tile_column >= (1 << zoom_level) OR tile_row >= (1 << zoom_level)").fetchone()[0]
        if bad_addr:
            errors.append(f"{bad_addr} tiles outside the tile grid")
        tile_px = int(meta.get("tile_size", 256))
        tiles = read_tile_set(conn)
        if b:
            outside = 0
            for z, s in tiles.items():
                for x, y in s:
                    w, so, e, n = tile_bounds_lonlat(z, x, y)
                    if e < b[0] or w > b[2] or n < b[1] or so > b[3]:
                        outside += 1
            if outside:
                errors.append(f"{outside} tiles lie outside metadata.bounds")
        # Decode images.
        src = "SELECT tile_id, tile_data FROM images" if has_split else "SELECT NULL, tile_data FROM tiles"
        rows = conn.execute(src).fetchall()
        if decode == "sample" and len(rows) > 500:
            rows = random.Random(0).sample(rows, 500)
        undecodable, wrong_size, blank, modes, sizes = 0, 0, 0, {}, []
        for _, data in rows:
            try:
                im = Image.open(io.BytesIO(data))
                im.load()
            except Exception:  # noqa: BLE001
                undecodable += 1
                continue
            modes[im.mode] = modes.get(im.mode, 0) + 1
            sizes.append(len(data))
            if im.size != (tile_px, tile_px):
                wrong_size += 1
            if not np.asarray(im.convert("RGBA"))[..., 3].any():
                blank += 1
        stats["images_checked"] = len(rows)
        stats["png_modes"] = modes
        stats["image_bytes_mean"] = int(np.mean(sizes)) if sizes else 0
        if undecodable:
            errors.append(f"{undecodable} images do not decode")
        if wrong_size:
            errors.append(f"{wrong_size} images are not {tile_px}x{tile_px}")
        if blank:
            errors.append(f"{blank} stored images are fully transparent (blank tiles must be dropped)")
        # Coverage against the policy.
        if wanted is not None and metatile_n:
            extra = sum(len(s - wanted.get(z, set())) for z, s in tiles.items())
            if extra:
                errors.append(f"{extra} tiles are outside the coverage policy")
            ledger = {(r[0], r[1], r[2]): (r[3], r[4]) for r in
                      conn.execute("SELECT zoom_level, mx, my, kept, blank FROM chart_build_metatiles")}
            missing_mt = [m for m in metatiles_for(wanted, metatile_n) if (m.z, m.mx, m.my) not in ledger]
            if missing_mt:
                errors.append(f"{len(missing_mt)} planned metatiles were never rendered, e.g. "
                              + ", ".join(m.key() for m in missing_mt[:5]))
            want_n = sum(len(s) for s in wanted.values())
            stats["coverage"] = {"policy_tiles": want_n, "present": stats["tiles"],
                                 "dropped_blank": want_n - stats["tiles"],
                                 "metatiles_rendered": len(ledger)}
    finally:
        conn.close()
    return {"ok": not errors, "errors": errors, "warnings": warnings, "stats": stats}


def _norm(a: np.ndarray) -> np.ndarray:
    a = a.astype(np.int16)
    a[a[..., 3] == 0] = 0
    return a


def visual_diff(new_path, old_path, samples: int = 200, seed: int = 0, mosaic_out: str | Path | None = None) -> dict:
    """Compare a sample of tiles present in both packages (decoded pixels)."""
    a, b = open_ro(new_path), open_ro(old_path)
    ta, tb = read_tile_set(a), read_tile_set(b)
    both = sorted((z, x, y) for z in ta for (x, y) in ta[z] & tb.get(z, set()))
    added = sum(len(s - tb.get(z, set())) for z, s in ta.items())
    removed = sum(len(s - ta.get(z, set())) for z, s in tb.items())
    rnd = random.Random(seed)
    pick = rnd.sample(both, min(samples, len(both)))
    same, diffs, worst = 0, [], []
    for z, x, y in pick:
        row = (1 << z) - 1 - y
        da = a.execute("SELECT tile_data FROM tiles WHERE zoom_level=? AND tile_column=? AND tile_row=?", (z, x, row)).fetchone()[0]
        db = b.execute("SELECT tile_data FROM tiles WHERE zoom_level=? AND tile_column=? AND tile_row=?", (z, x, row)).fetchone()[0]
        if da == db:
            same += 1
            continue
        pa, pb = _norm(decode_rgba(da)), _norm(decode_rgba(db))
        if pa.shape == pb.shape:
            frac = float((np.abs(pa - pb).max(axis=2) > 0).mean())
        else:
            frac = 1.0
        if frac == 0:
            same += 1
            continue
        diffs.append(frac)
        worst.append((frac, z, x, y, da, db))
    worst.sort(reverse=True)
    if mosaic_out and worst:
        k = min(6, len(worst))
        tp = decode_rgba(worst[0][4]).shape[0]
        canvas = Image.new("RGBA", (tp * 3, tp * k), (128, 128, 128, 255))
        for i, (frac, z, x, y, da, db) in enumerate(worst[:k]):
            pa, pb = decode_rgba(da), decode_rgba(db)
            d = (np.abs(_norm(pa) - _norm(pb)).max(axis=2) > 0)
            dm = np.full(pa.shape, 255, np.uint8)
            dm[d] = (255, 0, 0, 255)
            for j, im in enumerate((pb, pa, dm)):
                canvas.paste(Image.fromarray(im), (tp * j, tp * i))
        canvas.save(mosaic_out)
    a.close()
    b.close()
    return {"common_tiles": len(both), "sampled": len(pick), "identical": same, "different": len(diffs),
            "median_diff_fraction": float(np.median(diffs)) if diffs else 0.0, "tiles_added": added,
            "tiles_removed": removed,
            "worst": [{"tile": f"{z}/{x}/{y}", "diff_fraction": round(f, 4)} for f, z, x, y, *_ in worst[:10]]}


def integrity_like_chartkit(path) -> dict:
    """The subset ChartKit's MBTilesReader.checkIntegrity(deep: true) enforces, as a quick boolean."""
    r = check_package(path, decode="sample")
    return {"ok": r["ok"], "errors": r["errors"]}


__all__ = ["check_package", "visual_diff", "integrity_like_chartkit", "Metatile", "sqlite3"]
