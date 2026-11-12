# RoutingKit

The on-device auto-routing engine for the Gulf Coast navigation app (see `docs/PLAN.md`, D3/D4). It reads a
**routing pack** and computes routes exactly as [`docs/routing-pack-format.md`](../../docs/routing-pack-format.md)
specifies, reproducing the Python reference router (`pipeline/routing`) bit for bit on every test vector.

The package is pure Swift with Foundation only. It builds and tests on Linux (Swift 6.4.2) and targets iOS 17+ and macOS 14+. It has
no third-party or system-library dependencies. It depends on `NavCore` (relative path) for `Coordinate` and `Distance`.

## API

```swift
let pack = try RoutingPack(contentsOf: url)                 // throws PackError; validates everything (spec A)
let boat = BoatProfile(draftFeet: 4.5, safetyMarginFeet: 1.5, airDraftFeet: 20,
                       useMaintainedChannels: false, acceptUnknownClearance: false, avoidOpenGulf: false)
let request = RouteRequest(start: from, goal: to, profile: boat, maxSnapMeters: 750, timeLimit: .seconds(10))
do {
    let route = try await pack.route(request) { progress in /* phase, expanded, elapsed */ }
    route.legs          // [RouteLeg]: from/to, geometry ([Coordinate]), grade, reasons, lengthMeters, crossings
    route.summary       // distance, green/yellow counts, shallowest, lowest clearance, openings, ...
    route.dataDate      // chart data date (PackDate) to show next to the route
} catch .noRoute(let report) {
    report.blocked.first        // the first place along the cheapest almost-route where the boat cannot go
    report.hints                // e.g. useMaintainedChannels == true: offer the option, do not apply it silently
} catch .snapFailed(let f) {    // f.code: START_OUTSIDE_PACK, GOAL_NO_WATER_NEARBY, ...
} catch .legValidation(let r) { // builder/reader bug indicator; never shown as a red leg
} catch .cancelled { } catch .timedOut { } catch .invalidRequest { }
```

| Type | Role |
|---|---|
| `RoutingPack` | One region in memory, immutable, `Sendable`. Holds the header, section table, `INFO`, side tables (`sources`, `overheadObjects`, `hazards`, `channels`, `areas`) and accessors (`vertex`, `triangleVertices`, `neighbors`, `attributes`, `string`, `geometry`, `locate`, `centroid`). |
| `PackError` | Typed load failure: bad magic or version, checksum or size mismatches, truncation, bad sections, inflate errors, malformed content. |
| `BoatProfile` | Draft, margin and air draft in feet, plus the options of spec B.2. `init(draft:safetyMargin:airDraft:)` takes NavCore `Distance`. `requiredDepthDm` and `requiredAirDm` apply the B.2 rule. |
| `RouteRequest` | Start, goal, profile, `maxSnapMeters` (750 by default) and an optional `timeLimit`. |
| `RouteResult` | `start` and `goal` (`SnappedEndpoint`: point, triangle, `snapMeters`, `inMesh`), `corridor`, `waypointsUnits` (exact) and `waypoints` (degrees), `legs`, `summary`, `dataDate`, `regionID`. |
| `RoutingError` | `.noRoute(NoRouteReport)`, `.snapFailed(SnapFailure)`, `.legValidation(LegValidationReport)`, `.cancelled`, `.timedOut`, `.invalidRequest`. `code` is the spec's B.13 error string. |
| `RoutingProgress` | Phase (`search`, `noRouteReport`, `hints`), triangles expanded, elapsed time. It is reported every 4096 expansions from the routing thread. |

- `route(_:progress:)` is `async`. It always runs on a detached background task, never on the caller's actor, and forwards cancellation.
- Cancellation and the time limit are checked every 4096 A* expansions. On the pilot pack a cancel returns in about 0.5 ms (release).
- `routeSynchronously` is the same computation on the calling thread, for tests and tools.
- `snap(_:profile:)` and `blockReason(triangle:profile:)` expose B.6 and B.3 on their own.

## How results map to the spec

| Spec | Swift |
|---|---|
| B.13 `req_dm`, `air_dm` | `RouteResult.requiredDepthDm`, `.requiredAirDm` (also on `NoRouteReport`) |
| `start` and `goal` `{x, y, triangle, snap_m, in_mesh}` | `SnappedEndpoint.point`, `.triangle`, `.snapMeters` (unrounded; `.roundedSnapMeters` is `round(d, 3)`), `.inMesh` |
| `corridor`, `waypoints_units` | `corridor: [Int]`, `waypointsUnits: [GridPoint]`. These are the exact values to compare. |
| legs `{triangles: [lo, hi], length_m, grade, reasons, min_depth_dm, min_spare_dm, crossings}` | `RouteLeg.corridorRange`, `.lengthMeters`, `.grade` (`RouteGrade`), `.reasons` (`[CautionReason]`, raw values are the spec names), `.minDepthDm`, `.minSpareDm`, `.crossings` |
| summary (B.12) | `RouteSummary`. `overhead` is `nil` where the pack has `0xFFFF`. |
| `NO_ROUTE` `{reason, blocked, hints}` | `NoRouteReport.reason` (`.blocked(BlockReason)` or `.notConnected`), `.blocked`, `.hints`. A hint is `nil` when that option was already on, which is when the spec omits the key; for `NOT_CONNECTED` every other hint is `false`. |
| `INVALID_REQUEST` | `RoutingError.invalidRequest` (spec B.2 valid-profile rule) |
| `LEG_VALIDATION` `{violations}` | `LegValidationReport.violations` (`LegViolation`) and `.corridor` |
| Errors `START_…` and `GOAL_…` | `SnapFailure.code`. `.start` carries the snapped start when the goal failed. `.noWaterNearby(locatedTriangle:nearestMeters:)` |

## Implementation notes

- **zlib: our own INFLATE in pure Swift (`Inflate.swift`), not libz.**
  - No system library has to be linked or installed on any platform, and CI's Linux container needs nothing beyond what it already installs.
  - Behaviour is identical everywhere.
  - Every error is a typed `InflateError`, with no out-of-bounds access.
  - The decoder is strict: it checks the zlib header, the exact output length and the Adler-32 trailer, and it rejects trailing bytes.
  - It uses a 10-bit lookup table with a canonical slow path. The pilot pack inflates and decodes in 0.25 s in release.
- **Memory layout.**
  - Flat `ContiguousArray`s of fixed-width integers: 4-byte vertex coordinates; 4-byte vertex indices and neighbours; the 17 bytes per triangle of `ATTR`; the grid ids; and the `GEOM` pool. There are no per-triangle objects.
  - Derived adjacency uses per-vertex buckets of outgoing edges (8 bytes per edge, transient), not a hash map.
  - Per-query search state is 13 bytes per triangle (cost, entry edge, closed flag). Positions are recomputed from the entry edge, never stored.
  - Classification (B.3–B.5) is computed on demand per triangle. No per-profile arrays are built.
- **Exactness.**
  - All geometry predicates are Int64. The reader rejects packs whose bounding box spans more than 2^30 units, which keeps every A.8 product exact.
  - Integer division uses `floorDiv`.
  - Floating-point expressions follow the spec's operation order, and the reference's where the spec is silent.
- **Validation on load.**
  - Every A.4 check of format 1.1, in the spec's order: header fields, the section-table CRC, the exact layout with zero padding (so every byte of the file is covered by a check), section CRCs, tags, encodings, and the content checks. Format 1.0 files (no table CRC) are accepted.
  - Every count and length, and every index range: vertices, neighbours, grid ids, `CHAN`, `OVHD` and `AREA` references, `GEOM` ranges and string ids.
  - The A.9 orientation check, stored-adjacency consistency, and directed-edge uniqueness when deriving adjacency.
  - GEOM points inside the header bbox, which keeps every A.8 and B.10 orientation exact in Int64.
  - Varint overflow and trailing bytes.

## Tests

`swift test` (swift-testing) finds `testdata/routing` relative to the package through `#filePath`. It runs 41 tests in about 9 s (debug).

- **Records.** Every field in both `*.records.json` files and the A.10 worked examples. On the synthetic pack, stored and derived adjacency must be equal. Adjacency must be symmetric. Grid location must agree with a brute-force search.
- **Vectors.** Every query in both `*.vectors.json` files (13 + 9) must reproduce exactly under the part D rules: integers and sequences exactly, distances to 1e-6 m, `snap_m` to 1e-3 m. A negative control checks that the comparator really detects differences.
- **Properties.** These run over all 992 ordered point pairs on the synthetic pack under 6 profiles. Each query is also run in reverse and repeated, 17,856 queries in all:
  - **Determinism:** the same query always gives the same result.
  - **Symmetry:** the outcome class (route, no route, leg-validation failure) is the same in both directions, and no query fails leg validation.
  - **Route invariants:** corridor adjacency, leg and grade consistency, snapped endpoints inside their triangles, and no leg entering the interior of any impassable triangle, checked by an exact separating-axis test.

  The Sarasota routes are checked forwards and backwards too, and 1,200 random points are snapped to check that every snapped point lies in its triangle.
- **Raw-source regression.** `ObstacleRegressionTests` reads `sarasota.obstacles.wkb.gz` and `sarasota.bridge_zone.wkb.gz` (gzip through the package's INFLATE, WKB parsed in the test) and requires every Sarasota route, forwards and reversed, to stay clear of the raw land, structures and blocking hazards: ≥ 11.5 m outside the bridge zones and ≥ 3.5 m inside them, exactly as the Python test.
- **Corruption.**
  - Every single-bit flip of `synthetic.pack`, and a sample of `sarasota.pack`.
  - Truncation at about 1,500 lengths, with `file_size` and the header CRC both left as they are and patched.
  - Mutations that keep the checksums valid: a test-only re-encoder writes every section raw, then the section contents or section-table fields are mutated and the CRCs fixed.
  - Corrupt zlib streams with a valid section CRC.

  Every bit flip must give a typed error (format 1.1 leaves no byte unchecked). Mutations with every checksum fixed up must give a typed error or load; packs that load are routed once, to show routing cannot crash either. Specific checks (table CRC, padding, `header_size`, `section_table_offset`, duplicate tags, flag bit 0, STRS and GRID counts) have typed-error tests, and a 1.0 copy of each pack must load with identical content.
- **Cancellation and timeouts.**
  - Pre-cancelled async and synchronous queries.
  - Cancellation from inside a running search.
  - `timeLimit`.
  - Progress reporting.
  - Concurrent queries on one shared pack.
- **Pilot pack (gated).** Set `ROUTINGKIT_PILOT_PACK=/path/routing-pilot-20261023.pack`, and optionally
  `ROUTINGKIT_PILOT_VECTORS=/path/pilot.vectors.json` to compare the reference routes exactly (generate that file with
  `enc_routing.vectors.make_vectors` over `enc_routing.places.ROUTES`). The suite is skipped cleanly when the variable is unset.
  For release numbers, run `swift test -c release -Xswiftc -enable-testing --filter PilotPerformanceTests`.

## Performance (pilot pack, 4.3 MB, 860,420 triangles, 548,089 vertices, derived adjacency; Linux x86-64, 4 cores)

| | debug | release |
|---|---|---|
| Load: map, CRC, inflate, decode, validate, derive adjacency | 1.56 s | 0.25–0.28 s |
| Decoded arrays | 42.8 MB | 42.8 MB |
| RSS: before load → after load → peak during load | 24.5 → 72.6 → 81.3 MB | 24.1 → 71.8 → 80.0 MB |
| Peak RSS while running all 19 reference routes | 91.5 MB | 89.2 MB |
| a strict, St Pete → Marina Jack (33.4 nm) | 0.39 s | 25 ms |
| b strict, Venice → Punta Gorda (47.2 nm) | 0.22 s | 18 ms |
| c relaxed, Bradenton Beach → Boca Grande (52.1 nm, 333 legs) | 0.31 s | 26 ms |
| r11 Egmont → Boca Grande offshore (61.4 nm) | 0.45 s | 28 ms |
| c strict (NO_ROUTE, with relaxed search and 2 hint searches) | 4.1 s | 0.28 s |
| Latency from a mid-search cancel to return | 12 ms | 0.5 ms |

- All 19 pilot reference routes match the Python reference exactly (format 1.1 pack, rebuilt 2026-11-12). The Python reference takes about 14 s for all 19.
- Loading costs about 56 MB above baseline at its peak and about 48 MB once loaded.
- Pack sizes vary by region. About 45 MB of packs across five regions averages about 9 MB per pack, or about twice the pilot. Expect about 90 MB of arrays for such a region, and load one region at a time.

## Turning a `RouteResult` into Persistence's `Route` + `AutoRouteInfo` (app side; no dependency here)

```swift
let points = result.waypoints.map { RoutePoint(coordinate: $0) }
let legs = result.legs.enumerated().map { i, leg in
    AutoRouteInfo.Leg(index: i, grade: LegGrade(rawValue: leg.grade.rawValue),          // "green" / "yellow"
                      reasonCodes: leg.reasons.map(\.rawValue),                         // spec names, e.g. "MAINTAINED_DEPTH"
                      leastDepthMeters: Double(leg.minDepthDm) / 10,                    // charted depth, MLLW
                      leastClearanceMeters: leg.crossings.filter { !$0.isOpeningSpan && $0.clearanceDm < 0xFFFE }
                          .map { Double($0.clearanceDm) / 10 }.min())
}
let s = result.summary
let info = AutoRouteInfo(
    boat: .init(name: boatName, draftMeters: result.profile.draftFeet * 0.3048,
                safetyMarginMeters: result.profile.safetyMarginFeet * 0.3048,
                airDraftMeters: result.profile.airDraftFeet * 0.3048,
                useMaintainedChannels: result.profile.useMaintainedChannels,
                acceptUnknownClearance: result.profile.acceptUnknownClearance),
    legs: legs,
    summary: .init(distanceMeters: s.distanceMeters, shallowestDepthMeters: Double(s.shallowest.depthDm) / 10,
                   lowestClearanceMeters: s.lowestClearance.map { Double($0.clearanceDm) / 10 },
                   worstGrade: LegGrade(rawValue: result.worstGrade.rawValue)),
    routingPackDataDate: result.dataDate.date,
    routingPackVersion: "\(result.regionID)-\(result.dataDate.rawValue)")
let route = Route(name: name, points: points, metadata: try RouteMetadata(info))
```

- `AutoRouteInfo.Leg.index` refers to point `index`, and RoutingKit's leg `i` runs from waypoint `i` to `i + 1`, so the two line up.
- Persistence stores the boat in metres. Converting back with `metres / 0.3048` gives the same `requiredDepthDm`, because B.2 subtracts 1e-9 ft before rounding up.
- `avoidOpenGulf` has no field in `BoatSnapshot` yet. Add one, or record it in the route notes.

## Known limitations

- The specification issues found while porting (snap rounding, the overhead polyline rule, the overhead prefilter, under-specified results and reader checks, no table checksum) are fixed in format and algorithm 1.1; see "Changes from 1.0" in the spec.
- Only one region is in memory at a time. Routing across region boundaries is not specified yet.
- `route` keeps 13 bytes per triangle per concurrent query (about 11 MB on the pilot pack). The no-route path runs up to 4 searches in sequence.
