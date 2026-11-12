# Gulf Coast marine navigation app — build plan

Status: plan v1, 2026-11-12. Facts marked **(verified)** were checked against the live source on that date.

## 1. What we are building

A native iPhone/iPad app for recreational boaters on the US Gulf Coast (Brownsville, TX to the Florida Keys) that:

1. shows official US nautical charts as raster imagery, fully offline;
2. keeps those charts current by downloading new editions as they are published;
3. shows the boat's GPS position, course and speed, with waypoints, routes, tracks and GPX import/export;
4. auto-routes between two points, on the phone and offline, keeping to water deep enough for the user's boat.

## 2. Three facts that change the original brief

| Brief said | What is true | Consequence |
|---|---|---|
| "USCG raster maps" | US charts are published by NOAA Office of Coast Survey. The Coast Guard publishes the Light List and Local Notices to Mariners. | Chart data comes from NOAA. Coast Guard data is a later add-on (temporary hazards). |
| Traditional raster charts | NOAA cancelled its last traditional raster chart in December 2024 (unverified date, from search). The only charts NOAA maintains are vector ENCs (S-57 format). | Any raster we show is a picture rendered from ENC data. |
| "Download the most recent raster maps" | NOAA publishes ready-made offline raster packages (MBTiles) and says they are "updated weekly", but the five Gulf files on the server are all dated **28 May 2024** **(verified)**. The ENC data behind them was last rebuilt **11 Nov 2026** **(verified)**. | NOAA's ready-made packages are 2.5 years stale. To have current charts we must build our own packages from current NOAA data (section 4). |

## 3. Verified data inventory

**NOAA offline raster packages** — `https://distribution.charts.noaa.gov/ncds/mbtiles/ncds_<region>.mbtiles` **(verified)**

| Region | Covers | Size |
|---|---|---|
| ncds_10 | Tampa Bay to the Keys and Dry Tortugas | 621 MB |
| ncds_11 | Tarpon Springs to Biloxi | 589 MB |
| ncds_12 | Mississippi River, Lake Pontchartrain, Louisiana waterways | 440 MB |
| ncds_13 | Louisiana coast south of 29.33°N | 381 MB |
| ncds_14 | Sabine to Brownsville | 636 MB |

- Total 2.67 GB. PNG tiles, zoom 0–16, standard `tiles` view **(verified by opening ncds_13)**.
- The server supports range requests and returns `Last-Modified` and `ETag`, so downloads can resume and updates can be detected with a HEAD request. NOAA publishes no catalog file for these packages.
- Coverage descriptions and region boxes come from a third-party project; ncds_13's box matched the file's own metadata.

**NOAA ENC product catalog** — `https://www.charts.noaa.gov/ENCs/ENCProdCat.xml` **(verified)**

- 10 MB XML, regenerated daily. Lists every chart cell with edition, update number, dates, states and zip URL.
- 1,419 active cells touch TX, LA, MS, AL or FL (this includes Florida's Atlantic side): 945 harbour-scale, 380 approach, 78 coastal, 16 smaller-scale. Together they are only **147 MB zipped**. Newest update in the set: 5 Nov 2026.
- Cell names are changing as NOAA moves to a gridded layout, so everything keys on the catalog, never on hard-coded cell names.

**NOAA live tile service** — `https://gis.charttools.noaa.gov/arcgis/rest/services/MarineChart_Services/NOAACharts/MapServer/WMTS` responds **(verified reachable; freshness and rate limits not yet checked)**.

**Not yet verified:** USACE National Channel Framework, Coast Guard NAVCEN GeoJSON feeds, NOAA tide API, licence wording. All are public-domain US government sources per search results. Hosts are now allowed in this environment so the build workers will verify them.

## 4. Key decisions

### D1. Where the chart imagery comes from — recommended: our own weekly chart build

A scheduled job (GitHub Actions) that:

1. reads the ENC catalog and works out which Gulf cells changed since the last run;
2. re-renders only the tiles those cells cover, and repackages each region;
3. publishes region packages plus a small `manifest.json` (region, version, date, size, checksum, URL);
4. the app polls the manifest, shows "update available", and downloads in the background.

Rendering source, in order of preference:

- **A. NOAA's live chart tile service** as the renderer (paper-chart look, no symbology work). Needs a politeness budget and ideally NOAA's blessing; changed-tiles-only keeps the load small.
- **B. Render from S-57 ourselves** if A proves stale, rate-limited or unreliable. Much more work (chart symbology).

Day-one fallback, already working: ship NOAA's May 2024 packages unchanged, clearly dated in the UI. The app code is identical either way because both are MBTiles.

Wave 1 measures option A (is the live service current? how fast can we fetch politely?) before we commit.

### D2. Map engine — MapLibre Native iOS

Free, open source, reads local MBTiles directly through an `mbtiles://` source and handles the tile row flip itself. MapKit with a custom tile overlay is the fallback.

### D3. Auto-routing — precomputed navigation graph, A* on the phone

- **Built offline from ENC vector data** (not from the raster imagery): depth areas, dredged areas, land, obstructions, wrecks, rocks, bridges and overhead cables with clearances, restricted areas.
- **Graph**: a triangulated mesh of safe water, plus "highway" edges along charted channels and the Gulf Intracoastal Waterway. Each edge stores least depth, minimum overhead clearance, width class and flags.
- **On the phone**: A* over edges the boat can use (draft + safety margin, air draft), path straightening, then every leg is re-checked against a hazard index and coloured green / yellow / red.
- **Tides**: charted depths are at mean lower low water. Default is no tide credit. Gulf tides are small and winter northers push water below datum.
- **Shipped as** a routing pack per region, estimated 20–80 MB each, downloaded alongside the chart package.

A plain depth raster was rejected: keeping 100 ft channels open needs 10–20 m cells across 1,500 miles of coast.

### D4. Code layout — logic in pure Swift packages, testable without a Mac

This container has no Xcode. A Swift 6.4.2 Linux toolchain works here **(verified, tests ran)**, so all logic lives in packages that build and test on Linux, with thin iOS-only adapters around them.

| Package | Contents | Builds on Linux |
|---|---|---|
| `NavCore` | geodesy, course/speed, cross-track error, ETA, anchor-alarm maths, units | yes |
| `GPXKit` | GPX read/write for waypoints, routes, tracks | yes |
| `ChartKit` | MBTiles reader, region manifest model, update diffing, install/swap logic | yes |
| `RoutingKit` | routing pack reader, A*, path straightening, hazard validation, leg grading | yes |
| `Persistence` | SQLite store for waypoints, routes, tracks, settings | yes |
| `AppServices` | CoreLocation tracking, background downloads | iOS only |
| `App` | SwiftUI screens, MapLibre map view | iOS only |

Server-side tooling is Python with GDAL (S-57 driver verified present here):

| Tool | Job |
|---|---|
| `pipeline/catalog` | read the ENC catalog, select Gulf cells, detect changes |
| `pipeline/charts` | build and publish chart packages and the manifest (D1) |
| `pipeline/routing` | turn ENC cells into routing packs (D3) |

Target iOS 17+. The Xcode project is generated from a `project.yml` (XcodeGen) so it can be written here and built on a macOS CI runner.

### D5. Safety and legal

- First-launch and pre-route acknowledgement: not certified for navigation, not a substitute for official charts, auto-routes are suggestions the skipper must review.
- Never silently route through a red leg. Route summary shows shallowest point, lowest bridge, and chart data date.
- Every chart region shows its data date; a stale region gets a visible warning.
- NOAA attribution; no implication of NOAA endorsement. Redistributed NOAA data is not "official" for carriage requirements.

## 5. Build waves

Each piece is built by an Opus worker against a written brief, reviewed and integrated by the orchestrator. A wave is done when its tests pass and its acceptance check is demonstrated.

**Wave 1 — foundations (all buildable and testable in this container)**

| Piece | Acceptance check |
|---|---|
| `NavCore` + `GPXKit` | unit tests against known geodesy values; GPX round-trip |
| `ChartKit` | reads the real ncds_13 package; manifest diffing and resumable-install logic tested |
| `pipeline/catalog` + chart-source spike | lists Gulf cells from the live catalog; report on live tile service freshness and fetch rate (settles D1) |
| `pipeline/routing` spike | one region (Tampa Bay to Charlotte Harbor): ENC cells to safe-water polygons and hazards, with a rendered picture to inspect |

**Wave 2 — routing engine and chart service**

| Piece | Acceptance check |
|---|---|
| Routing pack format + builder | pack for the pilot region within size budget |
| `RoutingKit` | routes between test harbours avoid land and respect draft; reference routes reviewed on a map |
| Chart build job | weekly GitHub Action publishes packages and manifest; incremental run touches only changed tiles |
| `Persistence` | store tests |

**Wave 3 — the iOS app** (needs a macOS build, see section 6)

| Piece | Acceptance check |
|---|---|
| Project skeleton, CI build on a macOS runner | app compiles and launches in the simulator on CI |
| Chart map screen with offline packages | charts display with no network |
| Region download manager | background download, resume, update prompt, storage screen |
| GPS, tracks, waypoints, routes, GPX | simulator route playback |
| Auto-route UI | boat profile, graded legs, route summary, acknowledgement flow |

**Wave 4 — whole Gulf and hardening**

- Routing packs and chart packages for all five regions.
- On-water testing through TestFlight.
- App Store submission (disclaimers, background-location justification, privacy manifest, download-size prompt).

**Later:** USACE channel survey depths with dates, tide credit, opening-bridge schedules, Coast Guard notices as temporary hazards, anchor alarm, AIS-traffic route prior.

## 6. What the owner has to do

Nothing is needed for Waves 1 and 2. Before Wave 3:

- Enrol in the Apple Developer Program ($99/year) and create the app record.
- Create an App Store Connect API key and add it to the repo's CI secrets.
- Decide where chart packages are hosted (GitHub Releases works to start; a CDN later).
- Have an iPhone or iPad with TestFlight for on-water testing; the simulator cannot validate GPS behaviour.

## 7. Main risks

1. **False "safe" legs.** Charted depths go stale in passes and inlets. Mitigation: conservative defaults, graded legs, data dates shown, mandatory review.
2. **Chart currency (D1).** If NOAA's live tile service is also stale or throttled we need our own renderer, which is the largest single piece of extra work.
3. **Routing pipeline topology.** Slivers and gaps in polygons can falsely connect or cut off water. Mitigation: visual review per region and reference-route tests.
4. **NOAA's cell re-layout** changes cell names mid-project. Mitigation: catalog-driven everywhere.
5. **No local Mac.** iOS-only code is only compiled on CI. Mitigation: keep it thin; logic stays in Linux-tested packages.
6. **Licences.** Avoid GPL/AGPL code (OpenCPN and similar) in the app.

## 8. Development environment notes

- Cloud environment `finns-marine-mapping-idea` allows the NOAA, NAVCEN, USACE and swift.org hosts.
- Swift for Linux: `https://download.swift.org/swift-6.4.2-release/ubuntu2404/swift-6.4.2-RELEASE/swift-6.4.2-RELEASE-ubuntu24.04.tar.gz` (1.1 GB).
- GDAL: `apt-get install -y gdal-bin python3-gdal`; Python geo stack via pip in a venv (`shapely pyproj geopandas rasterio fiona`). The `osgeo` bindings load only under `/usr/bin/python3.12`.
