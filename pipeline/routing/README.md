# pipeline/routing: ENC to routing packs, and the reference router

This package builds the **routing pack** for a chart region from NOAA ENC (S-57) cells and the USACE National Channel Framework. The pack is one binary file per region, which the phone downloads with the chart package. The package also contains the **Python reference router**, which reads only the pack file.

- The format, the routing algorithm and the builder rules are specified in [`docs/routing-pack-format.md`](../../docs/routing-pack-format.md).
- The Wave 1 findings are in [`docs/spikes/routing-data.md`](../../docs/spikes/routing-data.md), and its "Wave 2 follow-up" section covers the changes.

## Run

```sh
cd pipeline/routing
python -m enc_routing build [--region pilot] [--force]    # catalog → download → extract → merge → mesh → pack
python -m enc_routing validate [PACK]                      # checksums, topology, index, references; exit 1 on failure
python -m enc_routing route --start -82.6225,27.768 --goal -82.5465,27.333 --draft 4.5 --margin 1.5 --air 20 \
        [--maintained] [--unknown] [--inside]               # JSON result (part B.13 of the spec)
python -m enc_routing reference                            # reference routes, checked against the source data
python -m enc_routing render [--out DIR]                   # PNG figures
python -m enc_routing vectors [--out testdata/routing]     # synthetic pack, Sarasota cut, vectors, record dumps
python -m pytest -q                                        # offline, about 10 s
```

Everything that is downloaded or generated goes under `$ENC_ROUTING_WORK`. The default is the session scratchpad `.../scratchpad/routing-spike`. The command `vectors` writes into `testdata/routing/`.

## Build caching (incremental, catalog-driven)

| level | cache | invalidated by |
|---|---|---|
| download | `zips/<cell>.zip` + `zips/state.json` | edition or update number in the catalog |
| extract | `extract/cells/<cell>.<ed>.<upd>.pkl` | edition or update |
| merge | `regions/<rid>/merged.<key>.pkl` | the set of cells and editions, builder version, CRS |
| pack | `regions/<rid>/routing-<rid>-<date>.pack` + `build.json` | merge key, `BuildParams`, builder version |

An unchanged catalog makes `build` a no-op (2.5 s). A changed cell re-extracts only that cell, then re-runs merge (8 s) and mesh (about 3 min for the pilot). The mesh is not tiled yet: a changed cell rebuilds the whole region (see the follow-up in the spike report).

## Code map

| module | job |
|---|---|
| `config.py` | work directory, regions, `BuildParams` (every number that shapes the mesh) |
| `catalog.py`, `download.py`, `extract.py` | catalog selection, cached download, S-57 extraction (GDAL, updates applied) |
| `merge.py` | best-available multi-scale merge (one cell per location) |
| `layers.py` | routing inputs in metric CRS: depth areas, hazards, obstacles, overhead, NCF channels, regulated areas, quality; unit conversions (`to_dm`, `ft_to_chart_dm`, `req_dm`) |
| `mesh.py` | domain with safety clearance, sounding refinement, constraint lines, snap-rounded noding, CDT, attribute sampling, side tables, `build_pack` |
| `topology.py` | exact-integer repairs (flat triangles, T-junctions) and the validation that fails the build |
| `packfmt.py` | the binary format: writer and reader (numpy + zlib + struct only) |
| `router.py` | reference router (spec part B): passability, cost, snapping, A*, funnel, grading, leg validation, no-route report |
| `validate.py` | pack validation from the file alone |
| `assess.py`, `places.py` | reference routes and their check against the raw source obstacles |
| `analysis.py` | effect of the sounding refinement |
| `synth.py`, `vectors.py` | synthetic test pack, cut-down packs, record dumps and expected-result vectors |
| `render.py`, `build.py`, `cli.py` | figures, cached build, command line |

`catalog.py` still duplicates part of `pipeline/catalog`, which is installed in the same venv. Switching to it is a small follow-up, deliberately not done while that package is owned by another worker.

## Dependencies and licences

Everything is permissive. There is no GPL, AGPL or non-commercial code. Triangulation is GEOS's constrained Delaunay through shapely. Shewchuk's Triangle and CGAL are not used.

| package | used for | licence |
|---|---|---|
| shapely 2.2 (bundles GEOS 3.14) | geometry, snap-rounding noding, CDT | BSD-3-Clause (GEOS: LGPL-2.1, dynamically linked, server-side only) |
| geopandas 1.2 | feature tables | BSD-3-Clause |
| pyogrio 0.13 (bundles GDAL 3.12) | S-57 reading | MIT (GDAL: MIT/X) |
| pyproj 3.8 (PROJ) | projections | MIT |
| numpy, pandas | arrays | BSD-3-Clause |
| scipy 1.18 | Delaunay of soundings | BSD-3-Clause |
| matplotlib 3.11 | figures | Matplotlib licence (PSF-style, BSD-compatible) |
| Pillow 13 | palette PNG | MIT-CMU (HPND) |
| zlib (Python stdlib) | pack compression and CRC-32 | zlib licence |
| pytest 9 (tests only) | tests | MIT |

Data: NOAA ENC and USACE NCF are US Government works.

**On the phone:** a reader needs only zlib (`libz` on iOS, the system zlib on Linux) and plain integer arithmetic. No GEOS or other library is needed.
