from enc_catalog.catalog import band_from_scale


def test_header_and_count(catalog):
    assert catalog.date_created == "2026-11-11"
    assert catalog.dt_valid == "2026-11-11T06:00:23Z"
    assert len(catalog.cells) == 35


def test_cell_fields(catalog):
    c = catalog.by_name()["US5PLQCI"]
    assert c.lname == "Mississippi River - Southwest Pass - Mile 17-20"
    assert c.status == "Active" and c.active
    assert (c.edtn, c.updn, c.uadt, c.isdt) == (8, 0, "2026-09-10", "2026-09-10")
    assert c.zipfile_size == 84343
    assert c.zipfile_location == "https://www.charts.noaa.gov/ENCs/US5PLQCI.zip"
    assert c.zipfile_datetime.endswith("Z")
    assert c.states == ["LA"]
    assert c.band == 5 and c.band_name == "harbour"
    w, s, e, n = c.bbox()
    assert w <= -89.4354 <= e and s <= 28.9017 <= n


def test_cancelled_cell_has_no_coverage(catalog):
    c = catalog.by_name()["US1EEZ1M"]
    assert not c.active
    assert c.panels == [] and c.coverage() is None and c.bbox() is None


def test_interior_panel_is_a_hole(catalog):
    c = catalog.by_name()["US5MI62M"]
    kinds = [p.kind for p in c.panels]
    assert kinds == ["E", "I"]
    from shapely.geometry import Polygon

    ext = Polygon(c.panels[0].ring)
    assert c.coverage().area < ext.area


def test_band_from_scale():
    assert band_from_scale(3_000_000) == 1
    assert band_from_scale(350_000) == 2
    assert band_from_scale(120_000) == 3
    assert band_from_scale(40_000) == 4
    assert band_from_scale(10_000) == 5
    assert band_from_scale(2_000) == 6
