# Routing-pack build: operator guide

Status: Wave 4 round 2, 2026-11-15 (builder 3.1.1). Code: [`pipeline/routing`](../pipeline/routing). Format: [routing-pack-format.md](routing-pack-format.md) (1.2: locks, area-wide advisories, new leg construction; packs must be rebuilt, readers still accept 1.0 and 1.1). Workflow: [`.github/workflows/routing-build.yml`](../.github/workflows/routing-build.yml) (manual only, uploads workflow artifacts, publishes nothing).

## 1. What is built

One routing pack per chart region, with the chart region's id, so it installs alongside the chart package:

| pack | chart region | routing area |
|---|---|---|
| `ncds_10` | Tampa Bay to the Keys and Dry Tortugas | chart box + 15 nm, inside the Gulf AOI |
| `ncds_11` | Tarpon Springs to Biloxi | same rule |
| `ncds_12` | Mississippi River, Lake Pontchartrain, Louisiana waterways | same rule |
| `ncds_13` | Louisiana coast south of 29.33° N | same rule |
| `ncds_14` | Sabine to Brownsville | same rule |

**Overlap policy.** The on-device engine routes inside one pack only. Every pack therefore extends 15 nautical miles past its chart box on every side (clipped to pipeline/catalog's Gulf area of interest; 30 nm until round 2, when 37 % of all stored triangles were overlap copies). Any passage that starts in a chart region and ends less than 15 nm past its edge can be planned in that region's pack. Examples: Clearwater to Anclote and St. Petersburg to Anclote (10/11 line at 28.1° N; Gulfport FL to Anclote now only in ncds_10); Gulfport to Mobile and Biloxi to the Rigolets (11/12 line at 89.07° W); Grand Isle, Venice and Port Fourchon to New Orleans (12/13 line at 29.33° N: the ncds_12 pack reaches 29.08° N and holds Head of Passes and Grand Isle; the ncds_13 pack reaches 29.58° N, so Houma's floodgate is in it but Morgan City is not — Atchafalaya Bay to Morgan City is now an ncds_12 route); Intracoastal City to Cameron (13/14 line at 92.46° W; the ncds_14 pack reaches 92.16° W, just past Freshwater Bayou). The upper Keys east of 80.6° W, outside every chart box, are in the ncds_10 pack.

**Sizes.** The five packs are 12.0 / 12.7 / 15.1 / 8.0 / 13.0 MB (61 MB, 12.5 million triangles), against 13.2 / 20.1 / 22.8 / 18.6 / 14.5 MB (89 MB, 18.3 million triangles) before round 2. The reduction comes from the 15 nm overlap and from not meshing water no boat can use far from live water (format spec C.10a).

**What still cannot be planned in one go.** A passage longer than the overlap across a region line, for example Texas to Florida, Morgan City to Galveston, Pensacola to Tampa, or Sarasota to Cedar Key. The app already refuses it with "Start and destination in different regions … plan to a point inside one region first". It should say which region line the passage crosses and suggest the hand-over points that both packs hold (for example "plan to Gulfport, then from Gulfport to Mobile"). A cross-pack planner (stitching two packs at a shared tile edge) is the real fix; the tiles of the overlap are identical in both packs, which makes such stitching possible later.

## 2. How to build

```sh
cd pipeline/routing
pip install -e ../catalog -e .              # or the venv described in pipeline/routing/README.md
export ENC_ROUTING_WORK=/path/to/work       # caches and outputs; never inside the repository
python -W ignore -m enc_routing build --region all          # fetch + build the five packs
python -W ignore -m enc_routing validate --region all       # file-only validation, exit 1 on failure
python -W ignore -m enc_routing reference --region all --gate   # release gate (section 5)
python -W ignore -m enc_routing giww --region all           # GIWW continuity report (giww.json)
python -W ignore -m enc_routing render --region ncds_12     # overview PNG
python -m enc_routing manifest --manifest manifest.json --region all \
    --url-template "https://HOST/routing/{file}"            # writes routingPack entries, validates (section 6)
```

Hosts used: `www.charts.noaa.gov` (catalog and cell zips, via pipeline/catalog: generic User-Agent, at most 2 downloads at a time, resumable, size + zip CRC + sha256 checked) and `services7.arcgis.com` (USACE National Channel Framework, one request at a time with a 1.5 s pause, 1° blocks, cached). Downloaded files are parsed, never executed.

Outputs per region in `$ENC_ROUTING_WORK/regions/<id>/`: `routing-<id>-<data date>.pack`, `build.json` (sizes, timings, memory, anomalies, sha256 and a content sha256 that ignores the header's build time), `tiles.json`, `checks.pkl` (raw source geometry for the gate), and after `reference`: `routes.json`, `routes-summary.json`, `reference.vectors.json` (a routing-vectors/1 file for RoutingKit's gated pilot test).

The header build date and time are taken from `--build-time` or `SOURCE_DATE_EPOCH` when set, otherwise the current time.

## 3. Expected times, sizes and memory (this container: 4 CPUs, 15 GB)

Source stage, whole Gulf, cold: catalog 1 s, 1,147 cells (band 3 and better, 129 MB) downloaded in 60 s, extracted in 40 s (4 processes), merged in 63 s, open-Gulf mask 22 s (1.9 GB peak), NCF 106 blocks about 6 minutes (polite rate; cached afterwards).

Per region, tiles and assembly from an empty tile cache (sources cached):

| region | tiles | triangles | pack | tiles (4 workers) | assemble | total | peak memory: main / largest worker |
|---|---|---|---|---|---|---|---|
| ncds_10 | 704 | 2,661,238 | 13.2 MB | 59 s | 29 s | 108 s | 2.0 GB / 1.9 GB |
| ncds_11 | 643 | 4,182,842 | 20.1 MB | 80 s | 48 s | 133 s | 2.9 GB / 0.9 GB |
| ncds_12 | 242 | 4,746,427 | 22.8 MB | 79 s | 52 s | 136 s | 3.1 GB / 1.0 GB |
| ncds_13 | 432 | 3,828,240 | 18.6 MB | 74 s | 42 s | 120 s | 2.6 GB / 0.8 GB |
| ncds_14 | 654 | 2,930,074 | 14.5 MB | 62 s | 32 s | 99 s | 2.1 GB / 0.8 GB |

The slowest single tile takes 20 s (Louisiana marsh, up to 274,000 triangles per 0.2° tile). Building all five in one run shares the overlap tiles (2,056 tile builds instead of 2,675) and took 8 minutes (sources cached). ncds_10's worker peak includes a mask rebuild.

A whole-Gulf cold build is therefore roughly 20 minutes of compute; the 120-minute workflow limit leaves room for slow servers. Disk: about 3.5 GB of caches (zips 126 MB, extractions 626 MB, merged cells 472 MB, tiles 1.3 GB, unzipped cells 320 MB which may be deleted).

On the device (RoutingKit release build, Linux, glibc with `MALLOC_MMAP_THRESHOLD_=131072` so that freed large buffers are returned as on iOS; process RSS including a 25 MB test-process baseline):

| | before round 2 (4.75 M triangles, old RoutingKit) | round 2 (3.19 M triangles) |
|---|---|---|
| decoded arrays | 233 MB | 116 MB |
| resident after load | 258 MB | 142 MB |
| peak while loading | 333 MB | 184 MB |
| peak while running the 27 reference queries | 319 MB | 180 MB |
| load time | 1.47 s | 1.6 s |

With glibc's default (dynamic) mmap threshold the round 2 numbers are 183 / 202 / 188 MB, because glibc keeps freed decoder buffers in its heap. The saving is about half from the smaller pack and half from RoutingKit (attribute classes: 4 bytes per triangle instead of 17; adjacency derived from per-vertex corner lists; ATTR decoded before the mesh arrays; search state allocated in pages on first touch). The remaining load peak is the derived adjacency (about 16 bytes per triangle, transient).

## 4. Incremental rebuilds

Every stage is cached by content:

| stage | cache | invalidated by |
|---|---|---|
| download | `cache/cells/<cell>.zip` + `cache/cache.json` | edition, update or dates in the catalog |
| extract | `extract/v3/<cell>.<ed>.<upd>.pkl` | edition or update |
| merge | `merge/<cell>.<key>.pkl` | the cell's edition/update or that of any higher-priority cell overlapping it |
| mask | `mask/outside.<key>.npz` | any merged cell (cheap: 22 s) |
| tile | `tiles/<k>/<key>.pkl` | a hash of every input feature within 600 m of the tile (geometry and attributes, not the issue date), the NCF features, the mask window, the fine-grid choice and the build parameters |
| pack | `regions/<id>/build.json` key | the region's tile keys, cell editions, parameters, builder version |

A changed cell re-extracts that cell, re-clips it and the cells under it, rebuilds only the tiles whose inputs changed, and re-assembles the regions that contain them. Tiles are a fixed 0.2° grid, independent of the region, so a tile in an overlap strip is built once for both packs. The output does not depend on the order tiles are built in, on worker count or on which tiles came from the cache (tests: `tests/test_tiles.py`; on the real data the per-region cold builds and the all-regions build produce identical pack content, see PLAN.md 5d).

**Measured on the real data** (ncds_14, a copy of the work directory): a fake new update of harbour cell US5TX1AE (GIWW, Laguna Madre) with one wreck removed re-clipped 3 cells, rebuilt 1 of 654 tiles (2.8 s), re-computed the Gulf mask (22 s; its key covers every merged cell, a known coarseness) and re-assembled the pack: 82 s in all, against about 100 s for the region's tiles and assembly from scratch plus the source stage. The fixed costs are loading the region's merged data and assembling (about 36 s); the tile work is what incrementality removes. A re-issued cell whose features are unchanged rebuilds no tiles (the issue date is not a tile input).

## 5. Release gate: reference routes

`reference --gate` runs each region's reference routes (endpoints are named ENC features, `gulf_places.py`) with the default boat (4.5 ft draft, 1.5 ft margin, 20 ft air draft) in three modes: strict, maintained channels allowed, and maintained plus unknown overhead clearance. Every route found, in both directions, is checked against the raw chart data (`checks.pkl`): it must not touch land, shoreline constructions, pontoons, piles or blocking hazards, must keep 12 m from them outside bridge zones (4 m inside, 3 m from fenders), and must not pass under a fixed bridge, cable or pipe charted lower than the air draft (or a bridge part without a charted clearance). Any violation fails the gate. RoutingKit must reproduce `reference.vectors.json` exactly:

```sh
ROUTINGKIT_PILOT_PACK=…/routing-ncds_12-20261109.pack ROUTINGKIT_PILOT_VECTORS=…/reference.vectors.json \
  swift test -c release -Xswiftc -enable-testing --filter PilotPerformanceTests/referenceRoutes
```

(`loadTimeAndMemory` in that suite also runs with a region pack, but its triangle-count expectation is the pilot's and fails by design.)

A route that changes class (strict, maintained, relaxed, failed) between two releases must be looked at by a person before publishing.

## 6. Manifest entries

`manifest --manifest FILE` writes, into each built region's existing entry of a ChartKit manifest (schema 1):

```json
"routingPack": {"url": "https://example.invalid/routing/routing-ncds_12-20261109.pack", "byteSize": 22787408,
                "sha256": "…", "version": "2026-11-09.<first 8 hex of the content hash>",
                "dataDate": "2026-11-09", "formatVersion": 1}
```

`version` changes exactly when the pack content changes. A region not yet in the manifest is skipped with a message: an entry needs a chart package, which the chart build supplies. The whole manifest is then validated with ChartKit's rules (`enc_routing/manifest.py` mirrors `ChartManifest.validate()` and its decoder) and written atomically. `--url-template` sets the placeholder URL until hosting is decided.

## 7. A weekly update

1. `enc-catalog fetch` and `enc-catalog snapshot` (the build also writes `snapshots/snap-<catalog date>.json`).
2. `enc-catalog diff snapshots/snap-OLD.json snapshots/snap-NEW.json --json` lists the changed cells (median about 25 a week). Nothing else is needed for the routing build: `build --region all` with the caches restored downloads and re-extracts only those cells, rebuilds only the tiles they touch, and re-assembles only the regions whose tile set changed; an unchanged catalog is a no-op.
3. `validate --region all`, `reference --region all --gate`, and compare `routes-summary.json` with last week's.
4. `manifest` with the new packs, then publish packs and manifest together (not automated yet).

In the workflow, the caches are kept with `actions/cache` between runs.

## 8. Builder rules

Part C of the format document is current for builder 3.1.0 (the Wave 4 tiled build and the round 2 rules: locks and floodgates C.2a, extended sounding raise C.4b, area-wide advisories C.7a, water no boat can use C.10a). The derived layers (`derived.py`) are computed once per build for the whole Gulf; the extended sounding raise takes about 3 minutes and is cached under `sndext/gulf.<key>.pkl` (key: every merged cell, the parameters and `EXT_VERSION`).
