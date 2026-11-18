# pipeline/catalog — NOAA ENC catalog tool

Reads NOAA's ENC product catalog (`https://www.charts.noaa.gov/ENCs/ENCProdCat.xml`, about 10 MB, regenerated daily), picks the active cells for the US Gulf Coast, and works out what changed between two runs. Its output drives the incremental chart build (PLAN.md D1) and the routing-pack build (D3).

What it does:

- **Select.** Picks the active cells whose coverage polygons share area with the Gulf area of interest. The AOI runs from Brownsville to the Keys and Dry Tortugas and includes the bays, the GIWW and the lower Mississippi up to Baton Rouge. Selection uses the coverage panels, not the `states` tags: the FL tag also covers the Atlantic coast, and those cells are excluded. Cells are grouped by usage band (1 overview … 6 berthing, from the cell name) and by the five chart regions.
- **Snapshot.** Writes a compact JSON record per cell: edition, update, issue and update-application dates, zip size and URL, bbox, regions and coverage rings. For the 1,157 Gulf cells this is about 490 KB.
- **Diff.** Compares two snapshots and lists cells that were added, got a new edition, were updated or reissued, or were cancelled or left the AOI. It also gives the web-mercator tiles (XYZ, per zoom) those cells cover, using the old and new footprint. Each cell only reaches down to its own useful zoom, `ceil(log2(559082264 / cscale)) + overscale`, so an overview-cell update does not dirty z16. The tile set is grown by `--dilate` tiles (default 1) to catch symbols and labels that spill over cell edges.
- **Download.** Fetches cell zips into a cache. Downloads resume through HTTP Range from a `.part` file, provided the partial file belongs to the same cell version. Each file is checked against the catalog's `zipfile_size` and must pass a zip CRC test. A sha256 is recorded in `cache.json`. A cell is skipped when its edition, update and dates are unchanged; `--verify` also re-hashes the cached file before skipping it.
- **Activity.** Counts cells per ISO week by their latest issue date (`isdt`).

HTTP is polite by default. Requests carry a generic User-Agent, at most 2 run at once, and 429/5xx responses get exponential backoff that honours `Retry-After`. The catalog is fetched with a conditional GET (ETag / Last-Modified).

## Install and test

```sh
python3 -m venv .venv && . .venv/bin/activate
pip install -e "pipeline/catalog[test]"
pytest pipeline/catalog                         # offline, uses tests/fixtures/ENCProdCat_trimmed.xml
ENC_CATALOG_LIVE=1 pytest pipeline/catalog -k live   # fetches the real catalog and one small cell
```

The fixture holds 35 real `<cell>` entries copied verbatim from the 2026-11-11 catalog:

- Gulf cells from every region and band;
- Atlantic-side Florida cells that must be excluded;
- a Pacific cell, a cancelled cell, and a Great Lakes cell with an interior (hole) panel;
- Cay Sal Bank, which only shares an edge with the AOI.

## CLI

```sh
enc-catalog fetch --out ENCProdCat.xml
enc-catalog select   --catalog ENCProdCat.xml [--format text|json|names]
enc-catalog snapshot --catalog ENCProdCat.xml --out snap-2026-11-11.json
enc-catalog diff snap-OLD.json snap-NEW.json [--max-zoom 16] [--overscale 2] [--dilate 1] [--tiles-out tiles.json] [--json]
enc-catalog download --snapshot snap-NEW.json --cache cache/ [--changed-since snap-OLD.json] [--only CELL ...] [--verify]
enc-catalog activity --catalog ENCProdCat.xml --weeks 12
```

`select`, `snapshot` and `activity` accept `--aoi FILE` and `--regions FILE` to override the built-in polygon and boxes in `src/enc_catalog/data/`. An AOI file can be `{"polygon": [[lon, lat], ...]}`, `{"bbox": [w, s, e, n]}`, or a GeoJSON geometry, Feature or FeatureCollection.

Output on the 2026-11-11 catalog:

```
catalog 2026-11-11: 1157 active cells in AOI, 133.0 MB zipped, newest issue date 2026-11-09
region                      overview   general   coastal  approach   harbour   total
(outside region boxes)             0         0         2         6         8      16
ncds_10                            1         4        23        72       139     239
ncds_11                            1         4        20        86       197     308
ncds_12                            1         2         8        63       144     218
ncds_13                            1         4        12        32        44      93
ncds_14                            1         3        18        84       249     355
all (distinct cells)               1         9        64       315       768    1157
```

## Notes and limits

- **Region boxes** are read from each NOAA `ncds_<n>.mbtiles` file's own `bounds` metadata. They are NOAA's tile-package extents, not tidy coastal regions. The upper Keys east of -80.6 (Key Largo, Card Sound) fall outside all five boxes and are reported as "(outside region boxes)". The chart build must decide which package they go in.
- **Cancelled cells** lose their coverage in the catalog. The diff therefore finds their tiles from the previous snapshot's coverage.
- **`zipfile_datetime` is ignored.** It changes every day for every cell and is not a change signal. Changes are detected from `edtn`, `updn`, `isdt` and `uadt`.
- **Weekly counts are a floor.** `activity` counts each cell only in the week of its latest issue. Counts for older weeks are therefore lower bounds; a cell that changed again later is counted only then.
- **Name re-layout.** NOAA is moving cells to a gridded layout, so cell names change. Nothing here hard-codes cell names, apart from the test fixture.
