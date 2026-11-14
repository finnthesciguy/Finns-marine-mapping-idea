import sqlite3

import numpy as np

from chart_build.mbtiles import MBTilesWriter, get_tile, open_ro, read_tile_set
from chart_build.tiles import encode_png
from chart_build.verify import check_package


def _png(colour):
    t = np.zeros((256, 256, 4), np.uint8)
    t[:] = colour
    return encode_png(t)


def _meta():
    return {"name": "x", "format": "png", "bounds": "-120,0,-60,45", "minzoom": 3, "maxzoom": 4, "type": "overlay",
            "attribution": "a", "version": "v1", "data_date": "2026-11-01", "build_version": "v1",
            "build_date": "2026-11-12T00:00:00Z", "build_config_hash": "abc"}


def test_write_tms_rows_view_and_dedup(tmp_path):
    w = MBTilesWriter(tmp_path / "w.mbtiles")
    water = _png((201, 237, 252, 255))
    land = _png((250, 230, 180, 255))
    w.add_pending([type("M", (), {"z": 4, "mx": 0, "my": 0})()])
    w.commit_metatile(4, 0, 0, 1, {(3, 6): water, (3, 7): water, (4, 6): land, (4, 7): None}, "sha", "v1", "t")
    assert w.pending() == []
    w.commit_metatile(3, 0, 0, 1, {(1, 3): water}, "sha", "v1", "t")
    w.set_metadata(_meta())
    out = w.finalize(tmp_path / "pkg.mbtiles")
    w.close()
    c = open_ro(out)
    assert c.execute("SELECT type FROM sqlite_master WHERE name='tiles'").fetchone()[0] == "view"
    assert c.execute("SELECT COUNT(*) FROM map").fetchone()[0] == 4
    assert c.execute("SELECT COUNT(*) FROM images").fetchone()[0] == 2  # deduplicated
    # XYZ (4, 3, 6) is TMS row 16 - 1 - 6 = 9
    assert c.execute("SELECT tile_data FROM tiles WHERE zoom_level=4 AND tile_column=3 AND tile_row=9").fetchone()[0] == water
    assert get_tile(c, 4, 4, 6) == land and get_tile(c, 4, 4, 7) is None
    assert read_tile_set(c) == {4: {(3, 6), (3, 7), (4, 6)}, 3: {(1, 3)}}
    assert c.execute("SELECT 1 FROM sqlite_master WHERE name='chart_build_pending'").fetchone() is None
    assert c.execute("PRAGMA journal_mode").fetchone()[0] == "delete"
    c.close()
    rep = check_package(out)
    assert rep["ok"], rep["errors"]
    assert rep["stats"]["dedup_ratio"] == 2.0


def test_replacing_a_tile_and_gc(tmp_path):
    w = MBTilesWriter(tmp_path / "w.mbtiles")
    a, b = _png((1, 2, 3, 255)), _png((4, 5, 6, 255))
    w.commit_metatile(5, 0, 0, 1, {(1, 1): a}, "s", "v1", "t")
    w.commit_metatile(5, 0, 0, 1, {(1, 1): b}, "s", "v2", "t")
    assert w.gc_images() == 1
    assert w.db.execute("SELECT COUNT(*) FROM images").fetchone()[0] == 1
    w.close()


def test_check_package_catches_problems(tmp_path):
    w = MBTilesWriter(tmp_path / "w.mbtiles")
    blank = encode_png(np.zeros((256, 256, 4), np.uint8))
    w.commit_metatile(3, 0, 0, 1, {(1, 3): blank}, "s", "v", "t")
    m = _meta()
    m["minzoom"] = 0
    w.set_metadata(m)
    w.add_pending([type("M", (), {"z": 3, "mx": 0, "my": 0})()])
    w.close()
    rep = check_package(tmp_path / "w.mbtiles")
    errs = " | ".join(rep["errors"])
    assert not rep["ok"]
    assert "fully transparent" in errs and "zoom range" in errs and "unfinished" in errs


def test_not_sqlite(tmp_path):
    p = tmp_path / "x.mbtiles"
    p.write_bytes(b"hello")
    assert check_package(p)["errors"] == ["not an SQLite database"]


def test_plain_tiles_table_is_accepted(tmp_path):
    p = tmp_path / "plain.mbtiles"
    c = sqlite3.connect(p)
    c.execute("CREATE TABLE tiles (zoom_level INTEGER, tile_column INTEGER, tile_row INTEGER, tile_data BLOB)")
    c.execute("CREATE TABLE metadata (name TEXT, value TEXT)")
    c.execute("INSERT INTO tiles VALUES (3, 1, 4, ?)", (_png((9, 9, 9, 255)),))
    c.executemany("INSERT INTO metadata VALUES (?, ?)", list({**_meta(), "minzoom": 3, "maxzoom": 3}.items()))
    c.commit()
    c.close()
    rep = check_package(p)
    assert rep["ok"], rep["errors"]
