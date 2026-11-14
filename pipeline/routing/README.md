# pipeline/routing: ENC to routing packs, and the reference router

This package builds the **routing pack** for each chart region from NOAA ENC (S-57) cells and the USACE National Channel Framework. The pack is one binary file per region, which the phone downloads with the chart package. The package also contains the **Python reference router**, which reads only the pack file.

- The format, the routing algorithm and the builder rules are specified in [`docs/routing-pack-format.md`](../../docs/routing-pack-format.md).
- How to build, timings, incremental rebuilds and the release gate: [`docs/routing-build.md`](../../docs/routing-build.md).
- The Wave 1 findings are in [`docs/spikes/routing-data.md`](../../docs/spikes/routing-data.md); Wave 4 (whole Gulf) is summarised in `docs/PLAN.md` section 5d.

## Run

```sh
cd pipeline/routing
python -m enc_routing fetch                                # catalog -> snapshot -> download -> extract (all Gulf cells)
python -m enc_routing build --region all [--offline] [--force] [--workers 4] [--build-time ISO]
python -m enc_routing validate --region ncds_12            # checksums, topology, index, references; exit 1 on failure
python -m enc_routing route --region ncds_10 --start -81.8057,24.5628 --goal -81.1131,24.6901 \
        --draft 4.5 --margin 1.5 --air 20 [--maintained] [--unknown] [--inside]   # JSON result (part B.13)
python -m enc_routing reference --region all [--gate]      # reference routes, checked against the source data
python -m enc_routing render --region ncds_10 [--small]    # overview PNG with the reference routes
python -m enc_routing manifest --manifest manifest.json --region all [--url-template URL] [--out FILE]
python -m enc_routing regions [--tiles]                    # routing regions (chart box + overlap)
python -m enc_routing vectors [--out testdata/routing]     # synthetic pack, Sarasota cut, vectors, record dumps
python -m pytest -q                                        # offline, about 10 s
```

Regions: `ncds_10` … `ncds_14` (the five chart regions, each grown by 30 nm, `regions.py`) and `pilot` (the Wave 2 box). Everything that is downloaded or generated goes under `$ENC_ROUTING_WORK` (default: the session scratchpad `.../scratchpad/gulf-packs`). The command `vectors` writes into `testdata/routing/` and needs the pilot pack built in the work directory.

## How a pack is built

1. **Sources** (`sources.py`, `catalog.py`, `download.py`, `extract.py`): pipeline/catalog's `enc_catalog` reads the catalog, selects the Gulf cells (its area of interest), writes a snapshot and downloads the zips politely (2 at a time, resumable, verified). Cells of band 3 (coastal) and better are read with GDAL, updates applied, cached per edition and update.
2. **Merge** (`merge.py`): one cell per location (band, then scale, then issue date). Each cell is clipped to its exclusive region on its own; the cache key covers the cell and every higher-priority cell overlapping it.
3. **Open-Gulf mask** (`mask.py`): derived from the data for the whole Gulf: water more than 5 km from land, connected to deep offshore water, grown back by 5 km (the opening of the water by a 5 km disk). Passes narrower than 10 km are sealed.
4. **Tiles** (`tiles.py`, `mesh.py`): fixed 0.2° lon/lat tiles, each meshed independently in its own transverse Mercator, with inputs clipped to the tile plus 600 m. A tile's result is cached by a hash of its inputs, so a changed cell rebuilds only the tiles it touches, and the overlap of two regions is built once.
5. **Assemble** (`assemble.py`): tiles are joined on their shared straight edges (T-junctions split exactly), the whole mesh must pass the topology validation, side tables are built from the full features, and the pack is written (`packfmt.py`).

## Code map

| module | job |
|---|---|
| `config.py` | work directory, `BuildParams` (every number that shapes the mesh), `Region` |
| `regions.py` | routing regions: chart boxes from pipeline/catalog, overlap, AOI |
| `catalog.py`, `download.py`, `sources.py`, `extract.py` | catalog selection and downloads via `enc_catalog`, S-57 extraction, anomalies |
| `merge.py` | per-cell incremental best-available merge |
| `ncf.py` | USACE NCF reaches and centrelines, per 1° block, paged, cached |
| `mask.py` | derived open-Gulf mask |
| `layers.py` | routing inputs: depth areas, hazards, obstacles, overhead, channels, regulated areas, quality; unit conversions (`to_dm`, `ft_to_chart_dm`, `req_dm`) |
| `mesh.py` | per-tile preparation (clearance, sounding refinement, constraint lines), snap-rounded noding, CDT, attribute sampling |
| `tiles.py` | tile grid, tile inputs and cache keys, parallel tile builds |
| `assemble.py` | seams, side tables, region pack |
| `topology.py` | exact-integer repairs (flat triangles, T-junctions) and the validation that fails the build |
| `packfmt.py` | the binary format: writer and reader (numpy + zlib + struct only) |
| `router.py` | reference router (spec part B) |
| `validate.py` | pack validation from the file alone |
| `assess.py`, `places.py`, `gulf_places.py` | reference routes (endpoints are named ENC features) and their check against the raw source data |
| `manifest.py` | routing-pack entries for the ChartKit manifest, ChartKit's validation rules |
| `synth.py`, `vectors.py` | synthetic test pack, cut-down packs, record dumps and expected-result vectors |
| `render.py`, `build.py`, `cli.py` | figures, cached build, command line |

## Dependencies and licences

Server-side only; nothing here ships in the app. There is no AGPL or non-commercial code. `gulf-enc-catalog` (pipeline/catalog, this repository) declares GPL-3.0-or-later in its pyproject; it is a build-time tool of the same project.

| package | used for | licence |
|---|---|---|
| gulf-enc-catalog (pipeline/catalog) | catalog, Gulf selection, snapshots, downloads | GPL-3.0-or-later (own code) |
| shapely 2.2 (bundles GEOS 3.14) | geometry, snap-rounding noding, CDT | BSD-3-Clause (GEOS: LGPL-2.1, dynamically linked) |
| geopandas 1.2 | feature tables | BSD-3-Clause |
| pyogrio 0.13 (bundles GDAL 3.12) | S-57 reading | MIT (GDAL: MIT/X) |
| pyproj 3.8 (PROJ) | projections | MIT |
| numpy, pandas | arrays | BSD-3-Clause |
| scipy 1.18 | Delaunay of soundings, mask morphology | BSD-3-Clause |
| rasterio 1.5 | mask raster (rasterize, vectorise) | BSD-3-Clause |
| requests (via gulf-enc-catalog) | HTTP | Apache-2.0 |
| matplotlib 3.11, Pillow 13 | figures | PSF-style / MIT-CMU |
| pytest 9 (tests only) | tests | MIT |

Data: NOAA ENC and USACE NCF are US Government works.

**On the phone:** a reader needs only zlib and plain integer arithmetic.
