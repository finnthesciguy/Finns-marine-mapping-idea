# ChartKit

Pure-Swift chart package logic for the Gulf Coast navigation app (see `docs/PLAN.md`, D1/D2/D4).
Builds and tests on Linux; targets iOS 17+ / macOS 14+. No third-party dependencies. SQLite comes
from the system (`CSQLite` system library on Linux, `import SQLite3` on Apple platforms).

| Area | Types |
|---|---|
| MBTiles reading | `MBTilesReader` (actor), `MBTilesMetadata`, `MBTilesError`, `TileCoordinate`, `TileMath`, `BoundingBox`, `TileFormat` |
| Manifest | `ChartManifest`, `ChartRegion`, `PackageArtifact`, `RoutingPackArtifact`, `ManifestError`, `ChartDates` |
| Update diffing and chart age | `UpdatePlanner`, `UpdatePlan`, `RegionUpdate`, `ChartAge`, `StalenessPolicy` |
| Install / update | `ChartInstaller` (actor), `InstallState`, `InstallStateMachine`, `InstallFailure`, `ChartTransport`, `DiskSpaceProvider`, `ResumeRecord` |
| No-manifest fallback (NOAA NCDS files) | `RemoteValidators`, `RemoteFileCheck`, `HTTPDate` |
| Map wiring | `MapLibreSources.sourceURL(forFileAt:)`, `MapLibreSources.layerPlan(for:resolveURL:)` |
| Hashing | `StreamingSHA256` (CryptoKit is Apple-only) |

## `manifest.json` (schema version 1)

Published by the chart build service next to the region packages. Unknown keys are ignored, so the
service can add fields without breaking older apps. A `schemaVersion` above what the app supports is
refused (`ManifestError.unsupportedSchemaVersion`).

```jsonc
{
  "schemaVersion": 1,                       // integer, required
  "generatedAt": "2026-11-12T06:00:00Z",    // ISO 8601 timestamp, required
  "publisher": "Gulf chart build service",  // optional
  "regions": [
    {
      "id": "ncds_13",                      // required; [A-Za-z0-9._-]{1,64}, unique (it becomes a directory name)
      "title": "Region 13: ...",            // required
      "summary": "Louisiana's coast ...",   // optional
      "bounds": { "west": -92.457141, "south": 17.6, "east": -89.069253, "north": 29.333333 },
      "minZoom": 0,                         // required, 0...30, <= maxZoom
      "maxZoom": 16,
      "tileFormat": "png",                  // png | jpg | webp | pbf (must match the package's own `format`)
      "package": {                          // the MBTiles chart package, required
        "url": "https://.../ncds_13.mbtiles",   // http(s)
        "byteSize": 380833792,              // > 0; checked against HEAD Content-Length and the download
        "sha256": "6d9b07...0439",          // 64 hex chars; checked after download
        "version": "2024-05-28",            // opaque; any change (or a sha256 change) = update
        "dataDate": "2024-05-28"            // date of the chart data (date-only or full ISO 8601)
      },
      "source": "NOAA NCDS baseline 2024-05-28",   // required, shown to the user
      "routingPack": {                      // optional (PLAN.md D3)
        "url": "https://.../ncds_13.routingpack",
        "byteSize": 41234567,
        "sha256": "...",
        "version": "2026-11-11",
        "dataDate": "2026-11-11",
        "formatVersion": 1                  // optional, routing pack file format
      }
    }
  ]
}
```

`Samples/gulf-manifest.sample.json` lists the five Gulf regions pointing at NOAA's own
`distribution.charts.noaa.gov/ncds/mbtiles/` URLs. Byte sizes are the real `Content-Length` values
from a HEAD on 2026-11-12. **Only ncds_13's `sha256` is real** (computed from the downloaded file);
the other four are all-zero placeholders, because hashing them means downloading 2.3 GB. An install
from this sample would fail its checksum for those four, as it should. Region boxes for 10, 11, 12
and 14 come from the third-party area list noted in PLAN.md; ncds_13 uses the file's own metadata.

## Install model

```
notInstalled/installed/failed/updateAvailable --enqueue--> queued --> downloading(progress)
    --> verifying --> installing --> installed(version)
any busy state --fail--> failed(reason)    installed --updateFound--> updateAvailable
```

`ChartInstaller(rootDirectory:transport:diskSpace:configuration:)` owns a directory the app picks:

```
chartkit-state.json                          installed regions + resume records (atomic writes)
staging/<id>-<kind>.partial                  in-progress downloads
regions/<id>/<kind>-<version>-<sha12>.<ext>  installed files, never modified in place
```

`install(region)`: free-space precheck → HEAD for validators (and a size check against the manifest)
→ GET, resuming with `Range` + `If-Range` → streamed SHA-256 → MBTiles integrity check → rename into
`regions/` under a new name → atomically rewrite the state file (the commit) → keep the superseded
file until the app calls `removeSupersededFiles()` (after it has closed its readers and pointed the
map at the new file; leftovers are removed the next time an installer is created). Until the commit the old version stays installed; any failure removes the new file and keeps
the old one. Paths in the state file are relative to the root, because iOS changes the app container
path between installs.

Resume rules: the partial file's size is the source of truth for bytes received. A resume sends
`If-Range` with the strong ETag (else Last-Modified). A 200 means the server sent a whole new file,
which is accepted from byte 0. A 206 whose validators differ from the recorded ones (a server that
ignores `If-Range`) throws the partial away and restarts. A partial with no validator is never
resumed. If the manifest entry changes while a partial exists, the partial is discarded.

The transport is a protocol (`head`, `download(request, progress)`), so the iOS app can plug in a
background `URLSession`. ChartKit does not include a transport itself.

## Map wiring

`MapLibreSources.sourceURL(forFileAt:)` gives `mbtiles:///absolute/path.mbtiles`. `layerPlan` orders
overlapping regions bottom to top: lower max zoom first, then larger area, then older data. Each
layer's source `bounds` is the region box, so MapLibre does not draw a package's blank tiles outside
its own area (NOAA packages contain world-wide tiles at z0–7). Layers stay visible up to z22, over-zoomed
from the package's max zoom.

## Tests

`swift test` runs everything with small MBTiles files generated in the test code. To also run the
tests against NOAA's real package (metadata, known tiles, per-zoom counts, coverage, deep integrity
check, and an end-to-end install checked against the sample manifest's SHA-256):

```
CHARTKIT_SAMPLE_MBTILES=/path/to/ncds_13.mbtiles swift test
```

The end-to-end install takes about 55 s in a debug build (mostly SHA-256 over 381 MB) and about 2 s
in release.
