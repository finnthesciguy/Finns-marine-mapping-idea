import json

from enc_catalog import load_aoi, load_regions, select_cells

GULF = {
    "US1GLBCF", "US2GOACB", "US2GOADC", "US3LA1BA", "US3LA1CD", "US3LA1CB", "US4LA1DP", "US4LA1FH",
    "US4FL1XG", "US4TX1AB", "US4AL1DB", "US5PLQCI", "US5PLQEJ", "US5PLQCJ", "US5PLVCA", "US5MOBHF",
    "US5PFNEC", "US5BPGBE", "US5HOUAJ", "US5BROAA", "US5FL7HZ", "US4FL1FT", "US5FL4DE", "US5TPAEG",
    "US4FL1OQ", "US5FL5GL",
}


def names(sel):
    return {c.name for c in sel.cells}


def test_gulf_cells_selected(selection):
    assert names(selection) == GULF


def test_atlantic_florida_excluded_despite_fl_state_tag(catalog, selection):
    by = catalog.by_name()
    for n in ("US5JAXEC", "US4FL2PE", "US3FL1FF", "US2ATLNB"):
        assert "FL" in by[n].states or n == "US2ATLNB"
        assert n not in names(selection)


def test_other_exclusions(selection):
    got = names(selection)
    assert "US1GLBAA" not in got  # Pacific
    assert "US1EEZ1M" not in got  # cancelled
    assert "US5MI62M" not in got  # Great Lakes
    assert "US4PQ1V0" not in got  # Cay Sal Bank: shares only an edge with the AOI
    assert "US4FL2EH" not in got  # Saint Lucie Canal, Atlantic side of Lake Okeechobee


def test_region_assignment(selection):
    r = selection.regions_of
    assert r["US5PLQCI"] == ["ncds_13"]
    assert r["US5BPGBE"] == ["ncds_12"]  # Baton Rouge, lower Mississippi
    assert r["US5HOUAJ"] == ["ncds_14"]
    assert r["US5BROAA"] == ["ncds_14"]  # Brownsville
    assert r["US5TPAEG"] == ["ncds_10"]
    assert r["US5FL4DE"] == ["ncds_10"]  # Dry Tortugas
    assert r["US5MOBHF"] == ["ncds_11"]
    assert r["US5FL5GL"] == []  # upper Keys, east of ncds_10's -80.6 edge
    assert set(r["US1GLBCF"]) == {"ncds_10", "ncds_11", "ncds_12", "ncds_13", "ncds_14"}


def test_grouping(selection):
    bands = selection.by_band()
    assert sum(len(v) for v in bands.values()) == len(selection.cells)
    assert {c.name for c in bands[1]} == {"US1GLBCF"}
    table = selection.table()
    assert "(outside region boxes)" in table
    assert table["ncds_13"][5] == 3  # US5PLQCI, US5PLQEJ, US5PLQCJ


def test_custom_aoi_and_regions(tmp_path, catalog):
    aoi = tmp_path / "aoi.json"
    aoi.write_text(json.dumps({"type": "Feature", "geometry": {
        "type": "Polygon", "coordinates": [[[-89.6, 28.8], [-89.2, 28.8], [-89.2, 29.2], [-89.6, 29.2], [-89.6, 28.8]]]}}))
    regions = tmp_path / "regions.json"
    regions.write_text(json.dumps({"regions": {"delta": {"bbox": [-90, 28, -89, 30]}}}))
    sel = select_cells(catalog.cells, load_aoi(aoi), load_regions(regions))
    assert {"US5PLQCI", "US5PLQEJ", "US4LA1DP"} <= names(sel)
    assert "US5TPAEG" not in names(sel)
    assert all(sel.regions_of[n] == ["delta"] for n in names(sel))


def test_bbox_aoi(tmp_path):
    p = tmp_path / "b.json"
    p.write_text(json.dumps({"bbox": [-90, 28, -89, 30]}))
    assert load_aoi(p).bounds == (-90.0, 28.0, -89.0, 30.0)
