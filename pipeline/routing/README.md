# pipeline/routing: ENC to routing layers (spike)

This is a spike. It turns NOAA ENC (S-57) cells for one pilot area (Tampa Bay to Charlotte Harbor, lon -83.3 to -81.9, lat 26.3 to 28.1) into the layers an auto-router needs. It then builds a triangle navigation mesh and runs A* with path straightening on it. The findings are in [`docs/spikes/routing-data.md`](../../docs/spikes/routing-data.md).

## Run

```sh
cd pipeline/routing
python -m enc_routing all              # the whole pipeline, cached (about 5 min cold)
python -m enc_routing <step> [--force] [--catalog-copy path/to/ENCProdCat.xml]
python -m pytest -q                    # offline tests, synthetic geometry only
```

The steps run in this order. Each step writes into `$ENC_ROUTING_WORK`, which defaults to the session scratchpad `.../scratchpad/routing-spike`. Nothing is written into the repo.

| step | does | output |
|---|---|---|
| `select` | parses the ENC catalog and picks the active cells whose catalog coverage touches the pilot box | `reports/select.json` |
| `download` | fetches the cell zips, cached by edition and update | `zips/` |
| `extract` | reads S-57 with GDAL/pyogrio (`UPDATES=APPLY,SPLIT_MULTIPOINT=ON,ADD_SOUNDG_DEPTH=ON`) and keeps the routing objects and their attributes | `extract/extract.gpkg` |
| `merge` | builds the multi-scale best-available tiling from M_COVR (see `merge.py`) | `merge/merged.gpkg`, `reports/merge.json` |
| `polygons` | builds safe-water polygons for 3, 4, 5, 6, 8, 10 and 15 ft, then reports connectivity and ICW breaks | `polygons/safe_water.gpkg`, `reports/polygons.json` |
| `channels` | measures how densely the ENC represents channels, and pulls the USACE National Channel Framework (NCF) | `ncf/*.geojson`, `reports/channels.json` |
| `bridges` | lists bridges, overhead cables and overhead pipes over water, with their clearances | `polygons/overhead.gpkg`, `reports/bridges.json` |
| `graph` | builds a constrained Delaunay mesh of all navigable water with per-triangle attributes | `graph/mesh.npz`, `reports/graph.json` |
| `route` | runs the three reference routes in two modes, strict and relaxed | `routes/routes.gpkg`, `reports/routes.json` |
| `render` | draws the PNG figures | `render/*.png` |

## Code map

- `catalog.py`: a minimal catalog parser and cell selector. **This duplicates part of `pipeline/catalog`**, so the spike would not depend on another worker's code. Consolidate the two in Wave 2.
- `extract.py`: S-57 to GeoPackage. List attributes such as CATBRG become comma-joined strings.
- `merge.py`: assigns each location to its best cell (priority is band, then scale, then issue date), clips features to that cell's exclusive region, and closes sliver gaps.
- `safewater.py`: holds the depth and hazard rules (`chart_metres`, `depth_ok`, `hazard_blocks`), builds obstacles, the Gulf mask and the safe-water polygons, and finds ICW breaks.
- `graph.py`: noding, polygonize, GEOS CDT per face, flat-triangle and T-junction repair, adjacency, and the pack-size estimate.
- `route.py`: the passability and cost model, A* over triangles, the funnel (string-pulling) algorithm and corner nudging. It reads only the mesh arrays, which is what the phone would do.
- `places.py`: hand-placed route endpoints, probe points and the Tampa Bay mouth line.
- `render.py`: the figures.

## Dependencies and licences

Everything is permissive. There is no GPL, AGPL or non-commercial code. Shewchuk's Triangle is not used; triangulation is GEOS's constrained Delaunay through shapely.

| package | used for | licence |
|---|---|---|
| shapely 2.2 (bundles GEOS 3.14) | geometry, CDT | BSD-3-Clause (GEOS: LGPL-2.1, dynamically linked) |
| geopandas 1.2 | dataframes of features | BSD-3-Clause |
| pyogrio 0.13 (bundles GDAL 3.12) | reading S-57 and writing GeoPackage | MIT (GDAL: MIT/X) |
| pyproj 3.8 (PROJ) | reprojection to UTM 17N | MIT |
| numpy, pandas | arrays | BSD-3-Clause |
| matplotlib 3.11 | figures | Matplotlib licence (PSF-style, BSD-compatible) |
| Pillow 13 | palette PNG compression | MIT-CMU (HPND) |
| pytest 9 (tests only) | tests | MIT |

Data: NOAA ENC and USACE NCF are US Government works.

Note on the phone: GEOS is LGPL. For the iOS app, Wave 2 should ship only the pack reader and the A*/funnel code, written in Swift. Triangulation happens server-side only.
