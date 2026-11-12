"""Hits NOAA. Run with ENC_CATALOG_LIVE=1 (downloads ~10 MB plus one small cell)."""
from conftest import live

from enc_catalog import parse_catalog, select_cells
from enc_catalog.download import CellCache, CellRequest, Http, fetch_catalog


@live
def test_live_catalog_and_one_cell(tmp_path):
    http = Http()
    dest = tmp_path / "ENCProdCat.xml"
    assert fetch_catalog(dest, http) is True
    cat = parse_catalog(str(dest))
    assert len(cat.cells) > 5000
    sel = select_cells(cat.cells)
    assert 900 < len(sel.cells) < 2000
    assert all(c.active and c.zipfile_size > 0 for c in sel.cells)
    smallest = min((c for c in sel.cells if c.band == 5), key=lambda c: c.zipfile_size)
    r = CellRequest(smallest.name, smallest.zipfile_location, smallest.zipfile_size,
                    smallest.edtn, smallest.updn, smallest.isdt, smallest.uadt)
    cache = CellCache(tmp_path / "cache")
    assert cache.fetch(r, http).status == "downloaded"
    assert cache.fetch(r, http).status == "skipped"
