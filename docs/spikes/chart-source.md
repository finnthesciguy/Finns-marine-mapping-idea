# Spike: where current chart imagery comes from (decision D1)

Status: measured 2026-11-12 from this container. The ENC catalog used is dated 2026-11-11. Scratch data and the comparison images are outside the repo, under the session scratchpad `chart-spike/`.

## Answer in one paragraph

NOAA's **WMTS tile service (`MarineChart_Services/NOAACharts`) is not current**. It is a static tile cache: every tile's ETag decodes to 27 Sep 2023, and the service is missing a buoy that was added to the ENC in August 2024. It is therefore older than the May 2024 offline packages. NOAA's **dynamic Maritime Chart Service export (`MCS/NOAAChartDisplay`) is current**:

- it draws a breakwater light change published in LNM 43/26 and issued in an ENC update on 3 Nov 2026;
- it uses the same "paper chart" symbol set as the offline packages;
- it renders 2048 × 2048 px metatiles (64 tiles) in about 0.7 s;
- it supports true high-DPI output;
- it returned no errors in 424 benchmarked requests (400 single tiles across both services, 24 metatiles) or in about 100 other tile and export requests.

Neither live service reproduces the May 2024 packages pixel for pixel. Only about 7% of non-blank sample tiles match exactly, and the renderer itself has visibly changed. So we cannot patch NOAA's old packages with live tiles; we must render our own baseline once and then update it incrementally. **Recommendation: option A, with the MCS export as the renderer instead of the WMTS.** Build a full baseline once (about 27k metatile requests, roughly 7–8 h at 1 request/s). Then run weekly incremental re-renders, driven by `pipeline/catalog diff`: a median of about 1,100 metatile requests (about 20 min) per week. Ship NOAA's dated May 2024 packages (option C) only until our first baseline exists. Keep option B (our own S-57 renderer) as the contingency.

## 1. Is NOAA's live chart service current?

### Services found

| Service | Kind | Data currency | Notes |
|---|---|---|---|
| `https://gis.charttools.noaa.gov/arcgis/rest/services/MarineChart_Services/NOAACharts/MapServer/WMTS` | Pre-rendered tile cache (WMTS 1.0.0, RESTful + KVP) | **Stale: cache built 2023-09-27.** No date in the capabilities document. | The MapServer REST root returns HTTP 500 "Could not find service" (the cache is served while the map service behind it is stopped). |
| `https://gis.charttools.noaa.gov/arcgis/rest/services/MCS/NOAAChartDisplay/MapServer/exts/MaritimeChartService/MapServer/export` | Dynamic render from ENC, "traditional paper chart" symbols | **Current**: shows changes from the 3 Nov 2026 cell update (below). | NOAA's GIS page says the chart images "are rendered from the latest NOAA electronic navigational chart (NOAA ENC®) data. The ENC data and the chart images derived from it are updated weekly." |
| `https://gis.charttools.noaa.gov/arcgis/rest/services/MCS/ENCOnline/MapServer/exts/MaritimeChartService/MapServer/export` | Dynamic render, IHO S-52 (ECDIS) symbols | **Current** (same test) | Its service description says: "ENCs are updated weekly on Friday afternoons. Please be aware there may be service downtime during this update period." `identify` works and returns per-feature `cellName`, `SORDAT` and `SORIND`. |
| `https://gis.charttools.noaa.gov/arcgis/rest/services/MarineChart_Services/ncds_tilecache_metadata/MapServer/0/query` | Feature layer listing all 47 NCDS MBTiles packages | Gives `date_creat` per package: **all 47 are "05 28 2024"**, including ncds_10–14. | This is a machine-readable index of the offline packages, with name, date, size and URL. ChartKit can use it for option C. Queries failed intermittently with HTTP 500 and worked on retry. |

### WMTS details (from its capabilities document)

- **Layer and format.** One layer, `MarineChart_Services_NOAACharts`, style `default`, format `image/png` only. The URL template is `…/WMTS/tile/1.0.0/MarineChart_Services_NOAACharts/{Style}/{TileMatrixSet}/{TileMatrix}/{TileRow}/{TileCol}.png`.
- **`default028mm` works.** It has 17 levels, 256 px tiles and the same origin and resolutions as Google/OSM. **Level L equals XYZ zoom L+2**, so XYZ zoom 2–18 is advertised. In practice nothing above XYZ zoom 16 was served at the test points: zooms 17 and 18 returned HTTP 400, and so did tiles over empty land (no blank tile).
- **`GoogleMapsCompatible` mostly fails.** It is advertised for z0–18 but returned HTTP 400 "Invalid URL" at z10, z14, z16 and z18, and worked only at z4.
- **Caching headers.** Tiles are sent with `Cache-Control: public, max-age=86400` and an ETag such as `"18ad52f8d50"`. Read as hex milliseconds since the epoch, that is 2023-09-27T05:49:38Z. All 200 sampled tiles, z8–z16, decode to 2023-09-27, rising with zoom level from 05:49 to 13:29 UTC, which is what a single sequential cache build looks like. This is an inference from ArcGIS behaviour, not a documented date. The buoy test below supports it independently.

### Change tests (visually identifiable)

**Test 1: "Southwest Pass Lighted Buoy 3A".** The buoy is at -89.43544, 28.90172. In the current cell US5PLQCI (edition 8, issued 2026-09-10) it carries `SORDAT 20240814` and `SORIND US,US,reprt,8thCGD,LNM 33/24`, so it was added in August 2024. Results at z15 and z16:

| Source | Buoy 3A drawn? |
|---|---|
| ncds_13.mbtiles (May 2024) | no |
| WMTS | no |
| MCS NOAAChartDisplay | **yes**, green buoy labelled `G "3A" Q G` |

An obstruction from LNM 27/24 (July 2024) at -89.36301, 29.0741 is likewise drawn only by MCS.

**Test 2: Port Lavaca Danger Breakwater Lights.** Cell US5PLVCA got update 3, issued 2026-11-03. The update changes three beacons and lights (`SORIND …LNM 43/26`, `SORDAT 20261028`) at about -96.622, 28.621. Results at z16:

| Source | Lights drawn? |
|---|---|
| WMTS | no (and older shoreline) |
| MCS NOAAChartDisplay | **yes**, three lights labelled `Fl 2.5s 13ft Priv` |
| MCS ENCOnline | **yes**, three lights labelled `Fl(1)W 2.5s4m` |

So the MCS services include ENC updates within at most 9 days of issue. NOAA says they reload weekly, on Friday afternoons.

**Neither service exposes a data date** in its capabilities. Currency can be shown with the catalog (`isdt` per cell) plus a probe like the one above.

### Do live tiles match the offline package pixel for pixel?

**No.** Method: decode both PNGs to RGBA, treat fully transparent pixels as equal, and count pixels that are not identical. The sample was 200 random non-blank ncds_13 tiles: 20 at z8, 30 at z10, 40 at z12, 50 at z14 and 60 at z16.

| Live source vs ncds_13 (May 2024) | Uniform tiles (one colour) | Non-uniform tiles: median identical pixels | Non-uniform tiles exactly identical |
|---|---|---|---|
| WMTS | 51 of 51 identical | 97.4% | 10 of 149 |
| MCS NOAAChartDisplay (default parameters) | 51 of 51 identical | 96.8% | 9 of 149 |

What the differences are:

- **The WMTS uses a different, older portrayal at large scales.** Lights carry names but no characteristics, and drying areas are grey. At z5 it is nearly the same as ncds.
- **The MCS uses the same symbol library as ncds.** A light symbol and its label rendered identically to the pixel. But its default display parameters differ: soundings are shown at small scales, and it uses different text groups and different detail at z10–z12. Its software has also changed. For example, a light `HEIGHT 9.1` m is labelled `Q 30ft` in the May 2024 package and `Q 29ft` now, while the source value has been unchanged since 2015 (SORDAT 201506). That is a rounding change in the renderer, not a data change.
- **The parameters are configurable but not fully matched.** `display_params` (`ECDISParameters.DynamicParameters`) does take effect: `DisplayCategory = "1,2"` raised one z7 tile from 87.7% to 96.8% identical. The exact parameter set NOAA used for the packages lives in the NCDS viewer's web map on noaa.maps.arcgis.com, and **that host is refused by this environment's proxy**, so I could not retrieve it.
- **No catalog-unchanged area exists to test against.** All 93 ENC cells in the ncds_13 box have been reissued since May 2024: 71 in 2026 and 22 in 2025.

Conclusion: live tiles **cannot be mixed** into NOAA's May 2024 packages without visible seams. What MCS does give us is consistency with itself: the same request returned byte-identical PNGs, so our own baseline and later incremental tiles will match, as long as the parameters and NOAA's software stay the same.

## 2. Throughput, reliability, sizes and DPI

### Single 256 px tiles

Two requests in flight, generic User-Agent, 200 tiles per service (the sample above):

| Service | Requests | Errors | p50 latency | p95 latency | Max latency | Throughput at 2 in flight |
|---|---|---|---|---|---|---|
| WMTS | 200 | 0 | 53 ms | 75 ms | 465 ms | 31 tiles/s |
| MCS export, 256 px | 200 | 0 | 67 ms | 131 ms | 182 ms | 25 tiles/s |

### MCS metatiles

Two requests in flight, 8 requests per row:

| Request | p50 latency | Max latency | Effective rate | Payload |
|---|---|---|---|---|
| z16, 2048 px = 8 × 8 tiles at 1× | 0.71 s | 1.22 s | 156 tiles/s | 2.2 MB per 8 requests |
| z14, 2048 px = 8 × 8 tiles at 1× | 0.62 s | 1.22 s | 158 tiles/s | 8.7 MB |
| z16, 2048 px = 4 × 4 tiles at 2× (dpi 192) | 0.35 s | 0.39 s | 90 tiles/s at 512 px | 1.8 MB |

Reliability:

- **Tile and image endpoints: 0 errors in 424 benchmarked requests, and none in about 100 other tile and export requests.** No 429 or 503 was ever seen and no `Retry-After` was sent. These are short bursts, not a sustained load test.
- **Other REST endpoints failed intermittently** with HTTP 500 "Could not find service. Service may be stopped or it may not be configured." Affected: the NOAACharts MapServer root, NOAAChartDisplay `identify`, and once the `ncds_tilecache_metadata` query, which worked later. The build job must retry these.

Size and DPI options:

- **WMTS: 256 px PNG only.** No 512 px or high-DPI tile matrix set.
- **MCS export: any size up to at least 2048 × 2048 px**, plus a `dpi` parameter. Asking for `size=512,512&dpi=192` over one tile's footprint gives a **true retina tile**: the same chart content at the same scale, with symbols and text drawn at twice the pixel size. The layer advertises `maxImageWidth/Height 4096`. Output is always PNG with alpha, whatever `format` says.
- **Caution: size and dpi change what is drawn.** MCS picks what to draw from the display scale. 512 px at dpi 96 over the same footprint is a 2× larger scale and shows different cells, so `dpi` must scale with `size`.
- **Metatile and single-tile renders differ.** A tile cut from a metatile differs from the same tile exported alone in about 3.3% of pixels, from label placement. The build must always cut the same fixed metatile grid.

## 3. Sizing the job

### Tiles per region and zoom

**Measured for ncds_13** (non-blank tiles, i.e. not the all-transparent image):

| z | 0–7 | 8 | 9 | 10 | 11 | 12 | 13 | 14 | 15 | 16 | Total |
|---|---|---|---|---|---|---|---|---|---|---|---|
| Tiles | 30 | 30 | 114 | 380 | 1,102 | 3,666 | 4,602 | 18,172 | 32,956 | 53,020 | **114,072** |

Note: ncds_13 holds 409,602 tile rows in total, but 268,221 of them point to one transparent image. Only 81,395 distinct images exist.

**Estimated for all five regions.** Method:

1. Take the union of the selected cells' coverage, per region box.
2. Count tiles down to each cell's own useful zoom (`pipeline/catalog` rule, overscale 2).
3. Calibrate on ncds_13: the model gives 94,653 against 114,072 measured, a factor of 1.21.

| Region | Model z14 | Model z15 | Model z16 | Model total | Calibrated total | 8 × 8 metatile requests (z ≥ 10) |
|---|---|---|---|---|---|---|
| ncds_10 Tampa–Keys | 32,629 | 57,467 | 154,150 | 265,878 | ~320,000 | 4,851 |
| ncds_11 Tarpon Springs–Biloxi | 41,680 | 72,100 | 166,683 | 300,834 | ~363,000 | 5,267 |
| ncds_12 Mississippi R. / Pontchartrain | 15,251 | 40,560 | 157,632 | 220,417 | ~266,000 | 3,712 |
| ncds_13 Louisiana coast | 14,105 | 22,326 | 49,234 | 94,653 | 114,072 (measured) | 1,818 |
| ncds_14 Sabine–Brownsville | 39,165 | 71,715 | 238,332 | 371,710 | ~448,000 | 6,627 |
| **All** | | | | **1.25 M** | **~1.5 M** | **22,275 (~27k calibrated)** |

Cross-check by file size: if tile count scaled with bytes (ncds_13 is 381 MB, the five files total 2.67 GB), the total would be about 0.8 M tiles. **Planning range: 0.8–1.5 M tiles at 1×.**

### Full rebuild time at a polite rate

| Method | Requests | At 1 request/s | At 2 in flight (measured) |
|---|---|---|---|
| MCS 8 × 8 metatiles at 1× | ~27k | **~7.5 h** | ~2.5 h |
| MCS 4 × 4 metatiles at 2× (retina) | ~107k | ~30 h | ~10 h |
| 256 px single tiles (WMTS-style) | ~1.5 M | 17 days | 14–17 h, too aggressive to be polite |

### Weekly incremental size

Method: for each of the last 12 complete weeks, take the cells whose latest issue date (`isdt`) falls in that week. Feed them to `diff`'s tile computation with `--max-zoom 16 --overscale 2 --dilate 1`, then count 8 × 8 metatiles.

| | Median week | Range |
|---|---|---|
| Changed Gulf cells | 24.5 | 6–36 |
| Zipped cell downloads | 4.2 MB | 0.7–7.2 MB |
| Tiles to re-render | 39,000 | 8,400–92,500 |
| 8 × 8 metatile requests | ~1,100 | 399–2,477 |
| Time at 1 request/s | **~18 min** | 7–41 min |

These counts are a floor for older weeks. `isdt` only records each cell's latest change, so a cell that changed twice is counted once, in its later week. The two most recent complete weeks, 22 and 25 cells, are accurate.

`enc-catalog activity --weeks 30` gives the full table. Weeks with general-band (band 2) changes dominate the z11–z13 tile count, because those cells cover the whole Gulf.

## 4. Terms of use, rate limits, caching

**Display services (gis.charttools.noaa.gov).** I found no published terms of use, rate limits or caching guidance for NOAACharts, NOAAChartDisplay or ENCOnline. What exists:

- the ENCOnline service description sentence quoted in section 1 (weekly Friday reload, possible downtime);
- the Maritime Chart Service `documentInfo.comments`: "Not to be used for navigation.";
- response headers: WMTS tiles `Cache-Control: public, max-age=86400`; WMTS capabilities and MCS exports `Cache-Control: public, must-revalidate, max-age=0`;
- NOAA's GIS page (https://nauticalcharts.noaa.gov/data/gis-data-and-services.html), which describes the services as simple HTTP interfaces "for user applications to request geo-registered nautical chart images from NOAA databases for display in online and offline applications for which a basemap of nautical chart data is desired, including GIS, web-based, and mobile mapping applications."

The ENCOnline description names a NOAA contact for questions. Wave 2 should write to that contact before running full builds.

**MBTiles page (https://distribution.charts.noaa.gov/ncds/index.html)**, verbatim: "NOAA Chart Display Service MBTiles contain raster datasets derived from the latest NOAA ENC® data. Baseline MBTiles packages are updated weekly." NOAA's own `ncds_tilecache_metadata` service contradicts this: every package is dated 28 May 2024.

**ENC download page (https://www.charts.noaa.gov/ENCs/ENCs.shtml)** lists as option 3: "Write an application or script that uses the data in the ENC Product Catalog, an XML file that contains the status of the ENCs available for download."

**ENC update cadence (https://nauticalcharts.noaa.gov/charts/noaa-enc.html):** "NOAA continually updates ENCs with data from a variety of sources and new ENC update cells are uploaded every weekday evening." The same page says: "NOAA ENCs downloaded directly from these Coast Survey websites are free."

**ENC User Agreement (https://charts.noaa.gov/ENCs/Agreement.shtml).** The same text is shipped as `USERAGREEMENT.TXT` inside every cell zip. Quoted verbatim:

> **2. Permitted Use** — The NOAA ENCs are intended for navigational use. They are intended to be used in their electronic form only. You may download, use, and redistribute them without restriction, and without payment to NOAA, except as noted herein.

> **3. Limitations on Use** — NOAA ENCs® may be redistributed, but redistributed NOAA ENCs are NOT considered official NOAA ENCs, and do not meet federal chart carriage regulations for regulated vessels unless redistributed by a "Certified NOAA ENC Distributor" or by a "Certified NOAA ENC Value Added Distributor". […]
>
> Copying of the NOAA ENCs to any other server or location for further distribution is discouraged unless the following guidelines are followed: 1) this User Agreement is displayed and accepted by anyone accessing the NOAA ENCs, and 2) a reference to this Web site is included so that anyone accessing the NOAA ENCs is advised of their origin.
>
> If these NOAA ENC's are incorporated into any other product in a form other than as provided by NOAA, the producer of that product assumes full liability and must adhere to conditions described in the paragraph above concerning copying.

> **4. Warnings** — Weekly updates to the ENCs are done on a "best efforts" basis. The timing of their availability is not guaranteed. You are responsible for ensuring that your ENCs are the most current edition and that the most recent updates have been applied.
>
> While NOAA has accuracy standards for each step in the data collection and chart production process, much of the depth information found on NOAA charts is based on surveys conducted before 1940, the shoreline is more than 20 years old, and paper charts used to be compiled manually. […]

> **5. Trademarks and Copyright** — "NOAA®" and the NOAA® emblem are registered trademarks of the National Oceanic and Atmospheric Administration. NOAA ENC® is a registered trademark of the National Oceanic and Atmospheric Administration.

**README.TXT inside each cell zip** (dated July 6, 2026), item 6: "If these NOAA ENCs® are incorporated into any other product in a form other than as provided by NOAA, the producer of that product assumes full liability." Item 5: "As long as it is not redistributed, a downloaded ENC from an official NOAA ENC website will be considered official Federal data to meet chart carriage requirements."

**Data licensing (https://nauticalcharts.noaa.gov/data/data-licensing.html):** "All data acquired by Coast Survey is formally dedicated to the public domain via the Creative Commons Zero 1.0 Universal Public Domain Dedication (CC0-1.0), which removes all copyright from the data so that it may be used by anyone, for any purpose."

**NOAA's site-wide disclaimer** is linked as http://www.noaa.gov/disclaimer. www.noaa.gov is not on this environment's allow-list, so I did not fetch it.

**What this means for the app:**

- **Rendering and redistributing is permitted.** Our raster packages are a product "in a form other than as provided by NOAA".
- **We carry the liability**, and the app must not imply the tiles are official or meet carriage requirements. This matches PLAN D5.
- **Attribution and a dated agreement screen.** Showing the agreement text, or linking to it, along with "Source: NOAA ENC®, data as of <date>" meets the copying guideline.
- **Trademarks.** Use "NOAA ENC®" only as a factual attribution, never as branding.

## 5. Recommendation

**Option A, using the MCS `NOAAChartDisplay` export (not the WMTS) as the renderer:** a weekly incremental re-render into our own region packages.

Evidence:

1. **The renderer is current.** MCS shows the 3 Nov 2026 Port Lavaca update. The WMTS is a 2023 cache and the offline packages are from May 2024.
2. **It is fast and was reliable.** An 8 × 8 metatile takes about 0.7 s, there were 0 errors in 424 benchmarked requests, and output is deterministic. A full Gulf baseline is about 27k requests, roughly 7.5 h at 1 request/s. A typical week is about 1,100 requests, roughly 20 min.
3. **It has the right look.** It uses the paper-chart symbology the offline packages use. Retina output is available through `dpi=192`.
4. **Option B is a much larger job.** Rendering S-57 ourselves means building the chart symbology, which PLAN §7 lists as the largest risk, and nothing here shows we need to.
5. **Option C alone fails the brief.** NOAA's packages are 2.5 years old and NOAA does not update them, despite saying it does.

Risks and mitigations:

| Risk | Mitigation |
|---|---|
| No published usage terms or rate limits. NOAA may object or throttle. | Contact NOAA before the first full build. Run at most 1 request/s on 1–2 connections, with back-off on 429/5xx and a generic User-Agent. Build the baseline once, then only changed metatiles. Run outside US business hours and avoid Friday afternoons, when ENCOnline says the data reloads. |
| NOAA changes MCS software or default parameters. Tiles then stop matching our baseline (we already saw 30 ft become 29 ft). | Pin explicit `display_params` in every request. Every run, re-render about 20 fixed "canary" metatiles in areas whose cells did not change and compare hashes. If they differ, schedule a full rebuild rather than mixing styles. |
| Rendering parameters differ from NOAA's packages (soundings shown at small scale, text groups). | One tuning pass in Wave 2: choose `DisplayCategory`, text groups and so on by eye at z8–z16 and freeze them. Exact parity with the 2024 packages is not needed once we own the baseline. |
| Labels clipped or duplicated at metatile edges | Use a fixed 8 × 8 grid, always replace whole metatiles, and optionally render with a buffer (e.g. a 2304 px request cropped to 2048). Inspect seams in the tuning pass; one seam checked here looked clean. |
| The service is down or slow during a run | The job is resumable. It keeps a list of pending metatiles, retries later, and publishes only complete regions. |
| Data latency (weekday ENC uploads, weekly reload of MCS) | Run Saturday, after the Friday reload. Probe-check one changed feature per run, e.g. ENCOnline `identify` on a changed cell, before publishing. |
| Option B is still needed later | `pipeline/catalog` already downloads and diffs the S-57 cells, so a renderer could slot in behind the same tile list. |

### What the Wave 2 chart build job should look like

1. **Get the catalog and compare.** `enc-catalog fetch` (conditional GET), then `enc-catalog snapshot`, then `enc-catalog diff prev.json new.json --max-zoom 16 --dilate 1 --tiles-out tiles.json`. The previous snapshot is stored with the last release.
2. **Convert changed tiles to metatiles.** Snap the changed tiles to an 8 × 8 grid for z ≥ 10, and use single requests for z < 10. Assign each metatile to the region packages whose boxes it touches; the upper Keys east of -80.6 need an owner.
3. **Render.** Call MCS `NOAAChartDisplay` `export` with `bbox` in EPSG:3857 equal to the metatile bounds, `size=2048,2048&dpi=96`, pinned `display_params`, `format=png32&transparent=true&f=image`. Use 1–2 connections and about 1 request/s. Cut each result into 256 px tiles, drop fully transparent tiles, and dedupe identical images by hash, as the NOAA packages do: one transparent image is referenced by 268k rows. Optionally make a 2× variant with `size=2048,2048&dpi=192` over a 4 × 4 footprint.
4. **Write.** Upsert the tiles into each region's MBTiles (TMS rows). Set metadata: `bounds`, `minzoom`/`maxzoom`, and the data date (the newest `isdt` in the region). Recompute size and sha256.
5. **Run the canary check** (above). If it fails, mark the run for a full rebuild instead of publishing a mixed package.
6. **Publish.** Upload the packages and `manifest.json` (region, version, data date, size, sha256, URL).
7. **First run.** If there is no previous snapshot, treat every cell as added (about 27k requests). Until that run completes, the app ships NOAA's May 2024 packages and labels them clearly as "data as of 28 May 2024".

## Reproduce

All scratch scripts are in the session scratchpad: `chart-spike/scripts/spike.py`, `bench.py`, `tune.py` and `sizing.py`. They read `probe/ncds_13.mbtiles` and `chart-spike/snap_2026-11-11.json`.

Request budget used for the whole spike: roughly 650 HTTP requests to NOAA in total. That covers about 520 tile/export requests, 24 metatile exports, about 40 REST/metadata calls, about 15 web pages, 8 cell zips, 5 HEAD and 5 64 KB range reads of the mbtiles files, and 2 catalog downloads.

Hosts refused by the proxy: `noaa.maps.arcgis.com` (the NCDS viewer's web map, which holds NOAA's display parameters). `www.noaa.gov` was not attempted because it is not on the allow-list.
