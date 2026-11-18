"""MBTiles package writer/reader.

Layout follows NOAA's NCDS packages (and the MBTiles 1.3 spec): a `map` table
of (zoom, column, TMS row) -> image id, an `images` table holding each
distinct PNG once, and a `tiles` view joining them, which is what ChartKit
(`MBTilesReader`) and MapLibre read. Identical tiles (open water, land) are
stored once.

Two build tables travel with the package; readers ignore them:
- `chart_build_metatiles`: one row per rendered metatile (ledger: when, how
  many tiles kept, pixel hash). Used by verify, canary and update.
- `chart_build_pending`: metatiles still to render in an unfinished run.
  Its presence means the file is a work file, not a finished package.
"""
from __future__ import annotations

import hashlib
import sqlite3
from pathlib import Path

SCHEMA = """
CREATE TABLE IF NOT EXISTS metadata (name TEXT, value TEXT);
CREATE UNIQUE INDEX IF NOT EXISTS name ON metadata (name);
CREATE TABLE IF NOT EXISTS map (zoom_level INTEGER, tile_column INTEGER, tile_row INTEGER, tile_id TEXT);
CREATE UNIQUE INDEX IF NOT EXISTS map_index ON map (zoom_level, tile_column, tile_row);
CREATE TABLE IF NOT EXISTS images (tile_data BLOB, tile_id TEXT);
CREATE UNIQUE INDEX IF NOT EXISTS images_id ON images (tile_id);
CREATE VIEW IF NOT EXISTS tiles AS
  SELECT map.zoom_level AS zoom_level, map.tile_column AS tile_column, map.tile_row AS tile_row,
         images.tile_data AS tile_data
  FROM map JOIN images ON images.tile_id = map.tile_id;
CREATE TABLE IF NOT EXISTS chart_build_metatiles (
  zoom_level INTEGER, mx INTEGER, my INTEGER, scale INTEGER, kept INTEGER, blank INTEGER,
  pixel_sha TEXT, run TEXT, rendered_at TEXT,
  PRIMARY KEY (zoom_level, mx, my));
"""
PENDING = """
CREATE TABLE IF NOT EXISTS chart_build_pending (
  zoom_level INTEGER, mx INTEGER, my INTEGER, PRIMARY KEY (zoom_level, mx, my));
"""


def tile_id(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()[:32]


class MBTilesWriter:
    def __init__(self, path: str | Path):
        self.path = Path(path)
        self.db = sqlite3.connect(self.path)
        self.db.execute("PRAGMA journal_mode=WAL")
        self.db.execute("PRAGMA synchronous=NORMAL")
        self.db.executescript(SCHEMA)
        self.db.commit()

    # metadata
    def set_metadata(self, values: dict) -> None:
        with self.db:
            for k, v in values.items():
                if v is None:
                    self.db.execute("DELETE FROM metadata WHERE name = ?", (k,))
                else:
                    self.db.execute("INSERT OR REPLACE INTO metadata (name, value) VALUES (?, ?)", (k, str(v)))

    def metadata(self) -> dict:
        return dict(self.db.execute("SELECT name, value FROM metadata"))

    # pending queue (resume)
    def add_pending(self, metatiles) -> None:
        with self.db:
            self.db.executescript(PENDING)
            self.db.executemany("INSERT OR IGNORE INTO chart_build_pending VALUES (?, ?, ?)",
                                [(m.z, m.mx, m.my) for m in metatiles])

    def pending(self) -> list[tuple[int, int, int]]:
        if not self._has_table("chart_build_pending"):
            return []
        return [tuple(r) for r in self.db.execute(
            "SELECT zoom_level, mx, my FROM chart_build_pending ORDER BY zoom_level, my, mx")]

    def has_pending_table(self) -> bool:
        return self._has_table("chart_build_pending")

    def drop_pending(self) -> None:
        with self.db:
            self.db.execute("DROP TABLE IF EXISTS chart_build_pending")

    def _has_table(self, name: str) -> bool:
        return self.db.execute("SELECT 1 FROM sqlite_master WHERE name = ?", (name,)).fetchone() is not None

    # tiles
    def commit_metatile(self, z: int, mx: int, my: int, scale: int, tiles: dict[tuple[int, int], bytes | None],
                        pixel_sha: str, run: str, rendered_at: str) -> None:
        """Write one metatile's result atomically: put (bytes) or delete (None)
        each tile, record the ledger row and take it off the pending list."""
        n = 1 << z
        kept = sum(1 for v in tiles.values() if v is not None)
        with self.db:
            for (x, y), data in tiles.items():
                row = n - 1 - y
                if data is None:
                    self.db.execute("DELETE FROM map WHERE zoom_level=? AND tile_column=? AND tile_row=?", (z, x, row))
                    continue
                tid = tile_id(data)
                self.db.execute("INSERT OR IGNORE INTO images (tile_data, tile_id) VALUES (?, ?)", (data, tid))
                self.db.execute("INSERT OR REPLACE INTO map (zoom_level, tile_column, tile_row, tile_id) VALUES (?,?,?,?)",
                                (z, x, row, tid))
            self.db.execute("INSERT OR REPLACE INTO chart_build_metatiles VALUES (?,?,?,?,?,?,?,?,?)",
                            (z, mx, my, scale, kept, len(tiles) - kept, pixel_sha, run, rendered_at))
            if self._has_table("chart_build_pending"):
                self.db.execute("DELETE FROM chart_build_pending WHERE zoom_level=? AND mx=? AND my=?", (z, mx, my))

    def delete_tiles(self, tiles: dict[int, set[tuple[int, int]]]) -> int:
        k = 0
        with self.db:
            for z, s in tiles.items():
                n = 1 << z
                for x, y in s:
                    k += self.db.execute("DELETE FROM map WHERE zoom_level=? AND tile_column=? AND tile_row=?",
                                         (z, x, n - 1 - y)).rowcount
        return k

    def drop_ledger_rows(self, keys) -> None:
        with self.db:
            self.db.executemany("DELETE FROM chart_build_metatiles WHERE zoom_level=? AND mx=? AND my=?", list(keys))

    def gc_images(self) -> int:
        with self.db:
            return self.db.execute("DELETE FROM images WHERE tile_id NOT IN (SELECT DISTINCT tile_id FROM map)").rowcount

    def close(self) -> None:
        self.db.commit()
        self.db.close()

    def finalize(self, dest: str | Path) -> Path:
        """Drop the work tables, garbage-collect images and write a compact,
        single-file (no WAL) copy to dest."""
        self.drop_pending()
        self.gc_images()
        self.db.execute("PRAGMA wal_checkpoint(TRUNCATE)")
        dest = Path(dest)
        dest.parent.mkdir(parents=True, exist_ok=True)
        tmp = dest.with_name(dest.name + ".tmp")
        if tmp.exists():
            tmp.unlink()
        self.db.execute("VACUUM INTO ?", (str(tmp),))
        out = sqlite3.connect(tmp)
        out.execute("PRAGMA journal_mode=DELETE")
        out.close()
        tmp.replace(dest)
        return dest


def open_ro(path: str | Path) -> sqlite3.Connection:
    return sqlite3.connect(f"file:{Path(path).resolve()}?mode=ro", uri=True)


def read_tile_set(conn: sqlite3.Connection) -> dict[int, set[tuple[int, int]]]:
    out: dict[int, set[tuple[int, int]]] = {}
    has_map = conn.execute("SELECT 1 FROM sqlite_master WHERE name='map' AND type='table'").fetchone()
    src = "map" if has_map else "tiles"  # plain MBTiles: a tiles table only
    for z, x, row in conn.execute(f"SELECT zoom_level, tile_column, tile_row FROM {src}"):
        out.setdefault(z, set()).add((x, (1 << z) - 1 - row))
    return out


def get_tile(conn: sqlite3.Connection, z: int, x: int, y: int) -> bytes | None:
    r = conn.execute("SELECT tile_data FROM tiles WHERE zoom_level=? AND tile_column=? AND tile_row=?",
                     (z, x, (1 << z) - 1 - y)).fetchone()
    return r[0] if r else None
