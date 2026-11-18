# Chart build job (operator guide)

Status: Wave 2, 2026-11-12. The tool is `pipeline/charts` (`chart-build`). It renders nautical chart raster tiles from NOAA's dynamic chart export service into our own MBTiles region packages, keeps them current from the ENC catalog diff, and publishes `manifest.json` for the app (ChartKit schema 1). Background and the choice of renderer are in [spikes/chart-source.md](spikes/chart-source.md) and PLAN.md D1.

Everything below marked **(measured)** was run from the build container on 2026-11-12 (catalog snapshot of 2026-11-11). Nothing here has run in GitHub Actions yet.

## 1. What it does

```
enc-catalog snapshot ──► chart-build plan ──► build (baseline) ─┐
         │                                                       ├─► verify ──► publish (packages + manifest.json)
         └── diff vs stored snapshot ──► update (incremental) ───┘
```

- **Renderer.** `MCS/NOAAChartDisplay` MaritimeChartService `export` on `gis.charttools.noaa.gov`. One request renders a **metatile**: an aligned block of 8 × 8 tiles (2048 px) plus a **256 px gutter** on every side, so the image is 2560 × 2560 px. The gutter is cropped off and the rest is cut into 256 px tiles. Retina (`--scale 2`) renders 4 × 4 tiles of 512 px at 192 dpi per request, with a 512 px gutter.
- **Tile set.** Decided by ENC coverage and scale (section 4), never by the box alone.
- **Package.** MBTiles in NOAA's own layout (`map` + `images` tables, `tiles` view, TMS rows), identical tiles stored once, blank tiles dropped.
- **Incremental.** `update` diffs two catalog snapshots, re-renders only the metatiles touching changed cells (including the lower-zoom ancestors) and writes a new package version.
- **Polite.** At most 1 request/s sustained, at most 2 in flight, a per-run request budget, exponential backoff on 429/5xx, and a stop after 3 failed requests in a row. Section 6 has the details.

## 2. Install and test

```sh
python3 -m venv .venv && . .venv/bin/activate
pip install -e pipeline/catalog -e "pipeline/charts[test]"
pytest pipeline/charts                              # offline: a fake renderer stands in for NOAA
CHART_BUILD_LIVE=1 pytest pipeline/charts -k live   # one real export request
```

The offline suite covers:

- tile and metatile grid maths;
- gutter cropping and seams;
- blank detection and lossless PNG encoding;
- MBTiles writing, the TMS flip and dedup;
- kill-and-resume, which must give a byte-identical package;
- budget refusal and stopping at the budget;
- incremental planning, ancestors and cancelled cells;
- the canary check, including its tolerance of render noise;
- HTTP backoff and rate limiting;
- manifest generation and validation, against ChartKit's own sample manifest too;
- the CLI end to end.

One test builds a baseline, applies an update, and checks the result is byte-identical to a fresh baseline built from the new data.

## 3. Running it

All state lives under one build root (`--root`):

```
state/<pkg>/snapshot.json   catalog snapshot the current package was built from
state/<pkg>/versions.json   version history: file, bytes, sha256, data date, config hash, canaries, request count
work/<pkg>/                 an unfinished run (run.json, snapshot.json, work.mbtiles); deleted when the run finishes
packages/<pkg>/<pkg>-<version>.mbtiles
logs/requests.jsonl         one line per request to NOAA (time, tag, status, seconds, bytes, attempt)
```

`<pkg>` is the region id. Retina packages get `_2x` appended, e.g. `ncds_13_2x`. Regions are listed in `pipeline/charts/src/chart_build/data/regions.json`:

- `ncds_10` … `ncds_14` keep NOAA's ids and boxes, so our packages replace NOAA's May 2024 files in the app as an ordinary update. `ncds_10` is the exception: its east edge is moved to -80.05 to take in the upper Keys, which fall outside all five NOAA boxes.
- `demo_swpass` is the demonstration region.
- `--bbox=W,S,E,N --id NAME` builds an ad-hoc area. Use the `=` form, because the values are negative.

### Baseline

```sh
enc-catalog fetch --out ENCProdCat.xml
enc-catalog snapshot --catalog ENCProdCat.xml --out snap.json
chart-build plan  --root R --region ncds_13 --snapshot snap.json            # dry run, no requests
chart-build build --root R --region ncds_13 --snapshot snap.json --budget 2000
chart-build verify --root R --region ncds_13 --deep
chart-build publish --root R ncds_13 --dir R/publish --base-url https://<host>/charts
```

- **Over budget.** `build` refuses to start if the plan needs more requests than `--budget` (default 2,500). It exits with code 2 having sent nothing.
- **Big regions in chunks.** A region needs 1,700–6,300 requests, so pass `--allow-over-budget`. The run stops cleanly when the budget is used up (exit 4), keeping everything finished so far.
- **Resuming.** Running the same command again resumes the run. Each metatile's tiles, its ledger row and its removal from the pending list are committed in one SQLite transaction, so a killed run (Ctrl-C, `kill -9`, a runner timeout) loses at most the requests that were in flight. A resumed run uses the snapshot it started with, not the one on the command line.

### Weekly update

```sh
enc-catalog fetch --out ENCProdCat.xml          # conditional GET
enc-catalog snapshot --catalog ENCProdCat.xml --out snap-new.json
chart-build plan   --root R --region ncds_13 --mode update --snapshot snap-new.json
chart-build update --root R --region ncds_13 --snapshot snap-new.json
chart-build verify --root R --region ncds_13 --deep    # also diffs a sample of tiles against the previous version
chart-build publish --root R ncds_13 ...
```

`update` works in this order:

1. Compare the new snapshot with `state/<pkg>/snapshot.json`.
2. Compute the tiles of every added, updated, new-edition or cancelled cell. This uses the old and new footprints, each cell's own deepest useful zoom, and a dilation of 1 tile, closed upwards over all ancestors and limited to the package's coverage.
3. Run the canary check (section 7).
4. Copy the previous package to a work file.
5. Delete tiles whose coverage has gone.
6. Re-render the affected metatiles. Every in-policy tile of each metatile is rewritten, so a metatile is never half old and half new.
7. Write `<pkg>-<new version>.mbtiles`.

The version is the catalog date, with `.2`, `.3`, … added if that date is already taken. `update` refuses to run (exit 2) in these cases:

- the render configuration hash differs from the previous version's;
- there is no previous version;
- the previous package file is missing.

### Other commands

- `chart-build canary --root R --region ncds_13` re-renders the reference metatiles only.
- `chart-build status --root R` lists versions and unfinished runs.
- `chart-build calibrate` repeats the determinism and seam measurements (about 45 requests).

Exit codes:

| Code | Meaning |
|---|---|
| 0 | OK |
| 1 | Verification failed |
| 2 | Refused; nothing was requested |
| 3 | Renderer changed: a new baseline is needed |
| 4 | Stopped early; run the same command again to resume |

## 4. Zoom and coverage policy

A tile at zoom z is in a package when two things hold:

- some selected ENC cell whose **deepest useful zoom** is at least z covers part of the tile;
- the tile is inside the region's box for that zoom.

A cell's deepest useful zoom is `ceil(log2(559,082,264 / cscale)) + 2`, capped at 16. This is the same rule `enc-catalog diff` uses for changed tiles.

| Cell band (typical scale) | Deepest zoom |
|---|---|
| Overview (1:3.5M) | 10 |
| General (1:700k–1:1.2M) | 11–12 |
| Coastal (1:180k) | 14 |
| Approach (1:45k–1:80k) | 15 |
| Harbour (1:5k–1:22k) | 16 |

So open Gulf water covered only by small-scale cells stops at z10–z12, and the map over-zooms it. Only tiles with harbour or large approach cells reach z16. Rendered tiles outside the policy, which arrive with a metatile, are discarded, so the tile set of a package is a pure function of the catalog snapshot and the region. The incremental and verify steps rely on that.

### Full-Gulf estimate (from the 2026-11-11 snapshot, `chart-build plan --all-regions`; not run)

| Region | Tiles in policy | z14 | z15 | z16 | Requests at 1× (8×8) | Requests at 2× (4×4) |
|---|---|---|---|---|---|---|
| ncds_10 | 309,026 | 36,462 | 65,017 | 184,350 | 5,289 | 20,089 |
| ncds_11 | 300,834 | 41,680 | 72,100 | 166,683 | 5,115 | 19,523 |
| ncds_12 | 220,417 | 15,251 | 40,560 | 157,632 | 3,646 | 14,124 |
| ncds_13 | 94,653 | 14,105 | 22,326 | 49,234 | 1,667 | 6,217 |
| ncds_14 | 371,710 | 39,165 | 71,715 | 238,332 | 6,305 | 24,109 |
| **Gulf** | **1,296,640** | | | | **22,022** | **84,062** |

- **Requests.** 21,496 at 1× and 83,078 at 2× if metatiles shared by two regions were rendered once. The tool renders them per region, at about 2.5% extra.
- **Time.** At 1 request/s a 1× baseline is **about 6.1 h** of requests. Allow about 7 h with slow responses: one response took 77 s during the demonstration. A 2× baseline is **about 23 h**, so run it in chunks.
- **Weekly updates.** From the spike's 12-week replay: a median of about 1,100 requests (about 20 min) and at most about 2,500 (about 45 min). This fits the default budget.
- **Comparison with NOAA.** NOAA's ncds_13 holds 114,072 non-blank tiles against our policy's 94,653. Its packages carry larger-scale detail down to lower zooms (see section 8). Our z16 tile count over the demonstration area is within 10% of NOAA's: 4,416 against 4,011 present in both.
- **Package size at 1×, about 2.0 GB for the Gulf** (plausible range 1.6–2.6 GB).
  - On the 7,035 demonstration tiles that NOAA's ncds_13 also has, our PNGs are **12% smaller** than NOAA's (49.0 MB against 55.9 MB) **(measured)**.
  - Our policy holds about 13% fewer tiles than NOAA's estimated 1.5 M.
  - NOAA's five packages total 2.67 GB, so ours should be about 2.67 × 0.87 × 0.88 ≈ 2.0 GB.
  - The demonstration package itself averages 7.4 KB per tile, because it is almost all dense delta detail. NOAA's whole ncds_13 averages 3.3 KB per tile thanks to large deduplicated open-water areas.
  - Per region, roughly 1.3× the NOAA file size times the policy-to-NOAA tile ratio: about 0.33 GB for ncds_13 and about 0.6 GB each for 10, 11 and 14.
- **Package size at 2×: about 4.8 GB for the Gulf** (range about 3.8–6.2 GB). On 202 tiles rendered both ways, a 512 px @2x tile is **2.4×** the bytes of the 1× tile at the same address (2.1–3.0× by zoom) **(measured)**. Per region that is at most about 1.4 GB (ncds_14), under GitHub's 2 GiB asset limit.

## 5. Export parameters (pinned)

`pipeline/charts/src/chart_build/data/render.json` holds everything that changes pixels. Its hash (`build_config_hash`) is stored in every package and in the version history. A changed hash means a new baseline.

| Parameter | Value | Why |
|---|---|---|
| `bbox`, `bboxSR`, `imageSR` | metatile bounds in EPSG:3857 metres, grown by the gutter, 6 decimals | Exactly the web-mercator tile grid. Width / pixels equals the tile resolution, so the server never resamples. |
| `size` | `2560,2560` (1×) | 8 × 256 + 2 × 256 gutter. The service allows up to 4096. |
| `dpi` | 96 (1×), 192 (2×) | Size and dpi must scale together, or the service draws a different display scale and different cells. |
| `format`, `transparent` | `png32`, `true` | Outside chart coverage stays alpha 0, which is how blank tiles are detected. |
| `layers` | `show:0,1,2,3,4,5,6,7` | The service's default-visible layers, named explicitly. |
| `display_params` | the full `ECDISParameters` 10.9.1 object returned by `.../MaritimeChartService/MapServer/parameters` on 2026-11-12 | Pins NOAA's current defaults, so a silent change of defaults cannot restyle our tiles. **(measured)** An export with this object is pixel-identical to one with no `display_params` at all. |
| `f` | `image` | The MCS export ignores `f=json`: it returns the PNG, labelled `application/json` **(measured)**, so the drawn extent cannot be read back. Alignment is enforced by the exact bbox/size ratio and by checking the returned image size. |

No tuning pass was done. The parameters are NOAA's current defaults. See section 8 for the visible differences from NOAA's 2024 packages.

## 6. Request budget and politeness

| Rule | Default | Where |
|---|---|---|
| Sustained rate | 1 request/s (configurable up to 2) | `http.RateLimiter`. Request starts are spaced ≥ 1/rate apart. |
| In flight | 2 (or 1) | Semaphore, plus a pool of 2 render workers. |
| Per-run budget | 2,500 requests | Every attempt, retries included, counts. `plan` and `build`/`update` refuse to start a run that needs more, unless `--allow-over-budget` is passed. The client stops hard at the budget either way. |
| Backoff | 4 s, doubling, 4 retries, honours `Retry-After` | On 429, 5xx, connection errors, timeouts (90 s) and a 200 reply that is not a PNG (ArcGIS sends JSON errors with status 200). |
| Stop | 3 requests in a row that failed after their retries | Raises `ServiceFailing`. The run is resumable. |
| Friday guard | Refuses Friday 12:00 to Saturday 06:00 US Central | NOAA reloads ENC data then and warns of downtime. Override with `--allow-friday`. |
| User-Agent | `chart-tile-client/0.1 (python-requests)` | Generic, no names. |
| Audit | `logs/requests.jsonl` | One line per attempt. |

Run builds at night US time or at weekends, after the Friday reload. The suggested schedule is Saturday 09:17 UTC.

## 7. Failure modes

- **Service down or slow, especially on Friday afternoons.**
  - The Friday guard keeps scheduled runs out of that window.
  - Outside it, backoff absorbs short outages and three consecutive failures stop the run.
  - Nothing is published from an unfinished run. The next run resumes it: in Actions the `work/` directory is kept in the Actions cache between runs.
  - **Observed on 2026-11-12, about 04:15–04:19 UTC:**
    - two responses took 77 s and 83 s; all others took under 1.3 s;
    - one reply was an **HTML error page with status 200**, retried successfully;
    - three replies were **25,624-byte images** for metatiles that render as normal chart (about 1.3 MB) minutes later.
  - Defences:
    - a non-PNG reply counts as a failed request;
    - **a fully transparent metatile at z ≥ 6 is treated as a failure**: it is retried after 30 s and 60 s, then the run stops with the metatile still pending. Every requested metatile lies inside ENC coverage by construction, so this is never a legitimate result at those zooms.
    
    Without these defences a glitch would silently drop tiles, or in an update delete them. The demonstration builds ran before the guard existed but saw no such reply: verify confirmed every planned metatile kept tiles and no stored tile is blank.
- **Renderer change detection (canary).**
  - At each version, about 20 detailed metatiles (6 in the demonstration) spread across zooms are recorded as **canaries**.
  - Before every update, the canaries whose metatiles the update does not touch are re-rendered and compared with the tiles in the current package.
  - If any differs by more than render noise, the update stops with exit code 3 ("renderer output changed for unchanged data, a new baseline is needed"). Mixing two renderer versions in one package would show seams.
  - **Render noise (measured):** re-rendering the same request minutes apart changed 10–38 isolated pixels in 3 of 7,362 tiles. They lay along one anti-aliased magenta line, by at most 16 levels per channel. Real changes move text and symbols by far more.
  - So a canary passes when no pixel differs by more than 48 levels and at most 0.1% of pixels differ at all.
  - Example of a real change the spike saw: NOAA's renderer began rounding a 9.1 m light height to `29ft` instead of `30ft`. That is a text change of about 100 px at full contrast, and it would trip this check.
  - `chart-build canary` runs the check on its own. `--accept-renderer-change` overrides it.
- **Render config changed by us.** `update` refuses and a baseline is needed.
- **Catalog layout changes (cell renames).** A renamed cell shows up as one cell cancelled and one added. Both footprints are re-rendered, so the update is correct, only larger.
- **Corrupt or partial files.** `verify` runs these checks:
  - SQLite `quick_check`, the `tiles` and `metadata` schema, and the required metadata;
  - the format sniff, the zoom range against the tiles, and that every tile is inside `bounds`;
  - that every image decodes at the right size and that no stored tile is blank;
  - that no tile is outside the policy and that every planned metatile was rendered;
  - that the file's sha256 matches the build record.
  
  `publish` re-hashes each file and refuses one that changed after the build.

## 8. Demonstration (measured, 2026-11-12)

Region `demo_swpass`, the Mississippi River passes:

- z0–12 over the Louisiana coast box;
- z13–14 over the Birdfoot delta;
- z15–16 over Southwest Pass to Head of Passes (about 34 × 37 km).

| Item | Result |
|---|---|
| Plan | 7,370 tiles in policy, 167 metatile requests |
| Build | 167 requests, 0 errors, 173 s; 7,362 tiles kept, 8 dropped as blank (all z0–4, where the service draws nothing for this small area) |
| Package | 54.5 MB; 7,362 tiles, 6,623 distinct images (little open water here); 4,596 palette, 1,616 RGBA and 411 RGB PNGs |
| `verify --deep` | OK: no errors or warnings, coverage complete (167/167 metatiles) |
| Metadata | `name`, `format=png`, `bounds`, `center`, `minzoom=5`, `maxzoom=16`, `type=overlay`, `attribution`, `version`, `scheme=tms`, `tile_size`, `scale`, plus `data_date=2026-11-02`, `catalog_date`, `build_version`, `build_mode`, `build_base_version`, `build_date`, `build_config_hash`, `build_source`, `generator` |
| Manifest | `publish` wrote packages and `manifest.json`; it passes our validator (which mirrors `ChartManifest.validate`) and ChartKit's own Swift code. A scratch Swift executable linked against `Packages/ChartKit` ran these on the published files, and all passed:

- `ChartManifest.decode` on the manifest;
- `MBTilesReader.checkIntegrity(deep: true)`, giving `tilesView` and `png`;
- the zoom range, `bounds` and tile counts;
- `StreamingSHA256` equal to the manifest's `sha256`, and the byte size equal too;
- `coverage(zoom: 16)` near buoy 3A: 25/25.

The same checks passed on the retina package. ChartKit's own gated sample test was not used: it hard-codes NOAA's ncds_13 values |

**Retina.** A small `--scale 2` build (`--bbox=-89.46,28.88,-89.40,28.93`) made 41 requests and kept 202 of 207 tiles. The package is 5.2 MB and `verify --deep` passes. Content and display scale are the same as at 1×, with text and symbols drawn at twice the pixel size (`scratchpad/chart-build/retina_vs_1x_z16.png`). Metadata carries `tile_size=512` and `scale=2`; the app's MapLibre source must use `tileSize: 512` for these packages. The ChartKit manifest has no field for that yet; see the open items.

**Determinism.** The same request twice gives byte-identical PNGs at z12, z14 and z16 (3 of 3 pairs). Over time it is nearly but not exactly deterministic: see render noise in section 7.

**Seams and gutter.** Method:

1. Render the two grid metatiles on either side of a seam.
2. Render a reference block of the same size centred on the seam, so the reference has no seam there.
3. Count the pixels of the stitched pair that differ from the reference, by distance from the seam.

Fraction of pixels that differ:

| Seam | Gutter 0: 0–8 px | 8–32 px | 32–128 px | Gutter 64: 0–8 px | Gutter 128: 0–8 px | Gutter 256: 0–8 px | 128–512 px (noise floor) |
|---|---|---|---|---|---|---|---|
| z12, columns | 0.51% | 0.11% | 0.004% | 0.015% | 0.13% | 0.012% | 0.01–0.02% |
| z14, columns | 1.05% | 0.12% | 0.009% | 0.003% | 0.003% | 0.006% | 0.015% |
| z16, columns | 1.40% | 0.89% | 0.46% | 1.02% | 0.003% | 0.006% | 0.003% |
| z12, rows | 0.92% | | | | | 0.037% | 0.006–0.011% |
| z16, rows | 0.31% | | | | | 0.003% | 0.003% |

Without a gutter, symbols and labels are clipped or missing at metatile edges: up to 1.4% of pixels next to the seam, against a noise floor of about 0.01%. z16 needs at least 128 px, because 64 px still leaves 1%. With 256 px every band is at the noise floor at every zoom, so **256 px is the configured gutter**. It costs about 56% more pixels per request, but no extra requests. Seam strips are saved in `scratchpad/chart-build/calib/img/seam_z*_{h,v}.png`.

**Blank versus open water.** Two kinds of tile are possible here:

- **Blank:** no ENC coverage and a transparent background, so every pixel has alpha 0. These are dropped.
- **Open water inside coverage:** drawn with the depth-area fill, fully opaque. These are kept.

In the demonstration, 4,137 tiles are fully opaque and 3,225 partly transparent (coverage edges, z ≤ 12). 744 are a single uniform colour (open water and land interiors) and are kept and deduplicated. A tile with even one non-transparent pixel is kept. This matches NOAA's packages, whose one blank image is fully transparent.

**PNG encoding.** Tiles with at most 256 distinct RGBA colours are written as 8-bit palette PNGs, losslessly, with a tRNS chunk when they have transparency. That is 74% of tiles (median 108 colours). The rest are written as RGB or RGBA. Lossy quantisation to 256 colours was measured and **rejected**:

- it changed the median tile's pixels almost everywhere (99%);
- the largest error reached 30 levels per channel, which shifts chart colours and softens linework;
- it saved about half the bytes.

The lossless palette path saves 17% against plain RGBA (49.4 MB against 59.7 MB of tile data). It is also 12% smaller than NOAA's own tiles at the same addresses.

**Incremental update proof.**

1. A synthetic "older" snapshot (catalog 2026-11-04) was made in which harbour cell US5PLQCI, which holds Southwest Pass Lighted Buoy 3A, was at edition 7 instead of 8.
2. `plan --mode update` against the real 2026-11-11 snapshot found 1 new edition. It planned 553 affected tiles in **38 of the package's 167 metatiles**, plus 6 canaries. By zoom: 9 metatiles at z16, 4 at z15 and z14, 2 at z13 and z12, and 1–2 per zoom from z11 to z0 for the ancestors.
3. `update` made exactly **44 requests**: the 38 planned metatiles, each once, plus 6 canaries, all 6 pixel-identical.
4. It wrote version `2026-11-11.2` with `base_version 2026-11-11`.
5. `verify` compared all 7,362 common tiles with the previous version:
   - 7,359 identical;
   - 3 different, by 10–38 noise pixels each (above);
   - 0 tiles added or removed.

That is the expected result: the service's data did not change between the two renders. The offline suite proves the other half. With the fake renderer, an update after a data change gives exactly the package a fresh baseline built from the new data would.

**Comparison with NOAA's May 2024 package.** `scratchpad/chart-build/compare_ours_vs_ncds13.png`, kept outside the repository. On the left is NOAA's ncds_13 (28 May 2024), on the right our build, for the same tiles at z16, z14 and z12.

- **z16, Southwest Pass entrance.** Ours draws **Lighted Buoy G "3A" Q G**, added to the ENC in August 2024 and absent from NOAA's package. Ours shows far fewer soundings. NOAA's package shows two label styles for the same light: `Q 30ft 5M` and `Q(1)W 1s9.1m5M`. Ours shows one, `Q 29ft 5M`: the renderer's rounding change.
- **z14.** Same symbology. Ours adds statute-mile marks and fresher depths, and has fewer light labels.
- **z12.** The largest difference. NOAA's package shows harbour-scale detail overscaled at z12, very busy. The live service draws the coastal and general cells it considers right for that scale, so it is much plainer.

**Open tuning question.** The sounding density at z16 and the generalisation at z11–13 come from the service's display logic. `HonorScamin` made no difference **(measured)**. Matching NOAA's 2024 look, if wanted, needs a tuning pass on `display_params`; the spike notes that NOAA's own viewer configuration is on a host refused here. It must happen before the first full baseline, because any change means a new baseline.

## 9. Open items

- **Display tuning** before the first full baseline (section 8).
- **Retina packages in the manifest.** ChartKit has no tile-size field. A retina package is published as region `<id>_2x`, and the app would need to read `tile_size` from the MBTiles metadata, or the schema would need a field.
- **First GitHub Actions run** of `chart-build.yml` and of `GitHubReleaseTarget`.
- **One package per region.** A metatile on a region boundary is rendered once per region, about 2.5% extra requests.

## 10. GitHub Actions

`.github/workflows/chart-build.yml`:

- **Trigger.** Manual (`workflow_dispatch`) with inputs region, mode (`plan`, `baseline`, `update`), budget, scale, allow-over-budget and publish. A weekly schedule is commented out.
- **Limits.** `concurrency: chart-build` allows one build at a time. `timeout-minutes: 350` stays under GitHub's 6 h limit.
- **Permissions.** Only the built-in `GITHUB_TOKEN`, with `contents: write`.

Where state lives:

- **State (`state/`: snapshots and version history)** is uploaded with every publish as the release asset `chart-build-state.tar.gz`. The next run downloads it from the latest release with `gh release download`.
- **Packages** are release assets. The manifest's URLs point at `https://github.com/<repo>/releases/download/<tag>/<file>`. An update downloads the previous package from the `published_url` recorded in `versions.json`.
- Each publish creates the release `charts-YYYYMMDD-<run>`, holding the changed packages, the merged `manifest.json` and the state. Unchanged regions keep pointing at their older release. The app can poll `https://github.com/<repo>/releases/latest/download/manifest.json`.
- **Unfinished runs** (`work/`) are saved to the Actions cache, so a baseline that is bigger than one job's budget or time resumes in the next dispatch.

Limits to know:

- A release asset may be at most 2 GiB. Every 1× region is well under that. The largest 2× region (ncds_14) may come close; check the estimate in section 4.
- `GitHubReleaseTarget` (REST API: create the release, upload assets) is implemented but has **not been run**: there is no token in the build container. Try it against a scratch repository first.
- The workflow YAML was only checked for syntax. It has never run.

## 11. Courtesy message to NOAA (draft for the owner to send)

To: the contact named in the ENCOnline / NOAAChartDisplay service description on gis.charttools.noaa.gov.

> Subject: Planned use of the NOAAChartDisplay export service for an offline recreational chart app
>
> Hello,
>
> I am building a free/low-cost iPhone app for recreational boaters on the US Gulf Coast that shows NOAA charts offline. NOAA's NCDS MBTiles packages for the Gulf (ncds_10–14) are dated 28 May 2024, so I would like to build my own offline packages from the MCS NOAAChartDisplay export service, which is current.
>
> Intended usage:
> - One baseline render of the Gulf Coast (about 22,000 export requests of 2560×2560 px), spread over several nights at no more than 1 request per second with at most 2 connections, outside US business hours and never during your Friday-afternoon reload.
> - After that, a weekly incremental run that re-renders only areas whose ENC cells changed, driven by the ENC Product Catalog: typically about 1,100 requests (at most about 2,500) per week, on Saturdays.
> - Requests use fixed display parameters, back off on errors and stop after repeated failures. Tiles are served to app users from our own storage, never proxied to your service.
> - Packages are labelled "rendered from NOAA ENC® data, not an official NOAA product, not for navigation", with the data date and a link to the ENC User Agreement.
>
> Is this acceptable? If you would prefer a different rate, time window or another service (or if a refreshed NCDS MBTiles build is planned), I will adapt. I'm also happy to share the request logs.
>
> Thank you,
> <name, contact>

## 12. Reproduce the measurements

The scripts, outputs and images are in the session scratchpad under `chart-build/`:

- `calib/calib1.json`, `calib/calib_vertical.txt`: determinism, pinned parameters and seams.
- `demo/`: the build root with both versions and the request log.
- `sizes.json` (from `scripts/sizes.py`): PNG options against NOAA.
- `compare_ours_vs_ncds13.png` (from `scripts/compare.py`).
- `update-plan.json`, `demo-update*.json`, `update-diff.png`: the incremental proof.
- `gulf-estimate-{1,2}.json`: full-Gulf estimates.
- `retina/`, `retina_vs_1x_z16.png`: the @2x demonstration.
- `swiftcheck/`: the ChartKit verification executable.
- `publish/`: the local publish output (manifest.json, package, state tarball).

Requests to NOAA in this work: **328 to gis.charttools.noaa.gov** (324 exports). They break down as:

- 2 service metadata;
- 61 calibration and diagnostics;
- 167 baseline;
- 44 update;
- 12 canary (including 1 retry);
- 41 retina;
- 1 live test.

No other NOAA host was contacted; the catalog snapshot from the Wave 1 spike was reused.
