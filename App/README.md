# Gulf Nav — iOS app

SwiftUI app for iPhone and iPad, iOS 17.0+. The Xcode project is generated from `project.yml` with
[XcodeGen](https://github.com/yonaskolb/XcodeGen); no `.xcodeproj` is committed. Logic lives in the Swift
packages under `../Packages` (NavCore, ChartKit, GPXKit, Persistence, RoutingKit, AppServices); this target is
views and thin view models.

What the app does so far:

- **Disclaimer** on first launch, which must be accepted: not certified for navigation, not a substitute for
  official charts, NOAA data as-is, routes are suggestions, no NOAA endorsement (`AppServices.Disclaimer`).
- **Chart map** (`Sources/Map`): `MLNMapView` with a bundled offline style (`Resources/offline-style.json`,
  one water-coloured background layer, no network sources). One raster source and layer per installed
  region from ChartKit's `MapLibreSources.layerPlan`, rebuilt when the installed set changes; files
  superseded by an update are released with `removeSupersededFiles()` once the map has switched. Own-ship
  marker pointing along course over ground (compass heading when stopped), follow mode (a pan turns it
  off), north-up / course-up toggle, instrument strip (SOG in knots, COG, position in degrees and decimal
  minutes) and a chart-age badge (oldest installed region, orange after 90 days, red after a year).
- **Charts screen** (`Sources/Charts`): the five Gulf regions from ChartKit's sample manifest with size and
  data date, a confirmation showing the download size and free space before anything is downloaded (App
  Store guideline 4.2.3), progress, cancel (keeps the partial file), resume, update, delete, free space.
- **Simulate GPS** (debug builds only, the ant button on the map): replays a short Tampa Bay run at 6 kn,
  one fix per second, through `SimulatedLocationService`.
- **Persistence** (`AppServices.AppEnvironment.live`): the SQLite store at `Library/AppData/gulfnav.sqlite` is
  opened by `StoreOpener`, which never fails. A damaged file is set aside by Persistence and a banner says so;
  any other failure (e.g. a file from a newer app version) falls back to an in-memory store with a banner
  saying changes will not be kept, and the file is left untouched. The disclaimer acceptance lives in the
  store (`PersistenceAcknowledgementStore`); an acceptance stored in UserDefaults by earlier builds is copied
  in once at startup and then removed (`AcknowledgementMigration`, kept if the store is in memory).
  A recording interrupted by termination less than two hours ago is resumed at startup (with a new segment,
  so the gap is not counted), older ones are closed (`RecordingRecovery`); a banner says which.
- **Waypoints** (`Sources/Waypoints`, map button `map.waypointsButton`): drop at the boat (`map.dropWaypoint`
  or the list) or by long-pressing the chart, named "WP 001", "WP 002", … with numbers that never repeat in
  the store even after a rename or delete (`AppServices.WaypointNumbering`, counter kept in Persistence); list sorted by distance from the boat with bearing; edit name,
  symbol (GPX `<sym>` names) and notes; delete; tap a waypoint on the chart to select it (card with range and
  bearing, Go to, Edit). **Go to** starts direct-to navigation (`AppServices.NavigationSession` on NavCore's
  `RouteNavigator`): the guidance panel shows bearing, distance, cross-track error, time to go and ETA, a
  dashed line runs from the boat to the waypoint, and arrival (inside 0.05 nm) is announced. After arrival
  go-to stays on, showing bearing and distance back to the mark (no XTE, time to go or ETA while arrived);
  once the boat is more than twice the arrival radius away it re-arms (ETA returns, a later arrival is
  announced again), so "Go to" a mark the boat is at or has just left is useful for returning to it. A
  followed route finishes at its last point and does not re-arm.
- **Routes** (`Sources/Routes`): "New route on the chart" then tap the chart to add points (Undo, Cancel,
  Save in the edit bar; tapping near a waypoint uses its position and name; follow mode is switched off
  while editing so the chart does not move under the finger); list with point count and
  length; detail screen with name, points (reorder and delete with Edit), legs with length and bearing, show
  on the chart, add points on the chart, export, delete. **Follow** joins the route at the leg the boat is on
  (`NavigationSession.bestStartIndex`), shows the next point (`2/5`), bearing, distance, XTE, time to go and
  ETA to the end, advances legs automatically (arrival circle or passing the perpendicular; the final point
  needs the arrival circle) and announces each advance and the arrival; Skip and Stop. Prepared for
  auto-routes: legs carry a `grade` (from Persistence's `AutoRouteInfo`, `none` for manual routes) drawn by
  separate green/yellow/red line layers, the leg list shows the grade colour and reason codes, and a "Route
  check" section shows the `AutoRouteInfo` summary (distance, shallowest depth, lowest clearance, worst
  grade, chart data date) when present.
- **Tracks** (`Sources/Tracks`): record/stop from the map (`map.recordButton`) or the Tracks screen, pause
  and resume (new segment), live track line on the chart; points are filtered (interval from Settings,
  10 m minimum movement, accuracy better than 50 m, one point every 5 minutes when stopped) and written in
  batches of 10 or every 30 s, and on going to the background (`AppServices.TrackRecorder`). List with date,
  distance, duration and average speed; show on the chart (geometry simplified for the zoom with
  Persistence's `trackGeometry(_:detail:)`, reloaded per whole zoom level); rename, export, delete.
- **GPX**: export one waypoint, route or track, or everything (Waypoints screen toolbar), through the share
  sheet; import with the document picker (`map.importButton`) or "Open in Gulf Nav" (the app declares the
  `com.topografix.gpx` document type). Before anything is written, the import screen shows Persistence's
  import plan: what the file contains, which items are already saved or repeated in the file, and a
  per-item decision (import as new / skip / replace the saved copy) with "all duplicates" shortcuts.
- **Settings** (`Sources/Settings`): distance, speed and depth units (used throughout), map orientation at
  launch, track recording interval, keep the screen on (default on), the disclaimer text, NOAA attribution
  and the data date of each installed chart. Saved immediately in Persistence.
- **Boat profiles** (`Sources/AutoRoute/BoatProfilesScreen.swift`, from Settings > Boat profiles and from the
  planner's Boat row): list (default first), add, edit, delete, make default. Name, draft, safety margin, air
  draft, beam, cruising speed (in the Settings depth and speed units), "use maintained channels", "accept
  unknown clearance" (both off by default). A new profile starts at 4.5 ft draft, 1.5 ft margin, 20 ft air draft,
  6 kn; air draft is required for routing. Parsing and checks: `AppServices.BoatProfileForm`; the store keeps
  exactly one default.
- **Auto-routing** (`Sources/AutoRoute`, map button `map.autoRouteButton` or Routes > "Plan an auto-route"):
  choose the start (boat position, a waypoint, or a point picked on the chart), the destination (a waypoint or a
  picked point) and the boat; the screen shows which routing pack (and data date) will be used. Plan shows
  progress and can be cancelled (30 s limit). A result shows the planned route on the chart in grade colours
  (white casing, green/yellow), a summary (distance, time at the cruising speed, legs by grade, shallowest charted
  depth and where, lowest overhead clearance, bridges that must open, clearances not charted, how far start and
  end were moved onto water, chart data date and age, pack, boat), the legs with their reasons, and Save, Save and
  follow, Show on the chart, Discard. "Options for this plan" (maintained channels, unknown clearance, inside
  route only) change the next plan only. A failure shows the explanation; for "no route", the blocked places are
  red dots on the chart and listed, and each option that would give a route is a button ("Allow maintained
  channels and plan again"). Snap failures say which end, why and how far the nearest suitable water is. Saved
  auto-routes appear in Routes with their "Route check" section and per-leg colours and are followed like any
  route. All planning, wording and the safety rules are in `AppServices` (`AutoRoutePlanner`,
  `AutoRoutePresenter`, `AutoRouteSafety`, `AutoRouteSaving`; tested on Linux against `testdata/routing`).
- **Routing packs** (Charts screen): each region row says whether it has a routing pack (data date, size); a
  "Routing packs" section lists every pack on the device (chart-region and side-loaded), and debug builds have
  "Install a routing pack file…" (document picker; the file is fully validated by RoutingKit before it is copied
  in). See "Routing packs" below.
- **Chart overlays**: MapLibre shape sources and line/circle layers for tracks, routes, route points, the
  direct-to line and waypoints, above the chart rasters (`Sources/Map/MapOverlayLayers.swift`; GeoJSON from
  `AppServices.MapOverlays`). No text labels on the chart: the offline style has no glyphs; names appear in
  the selection card and lists.

## Auto-route safety behaviour (PLAN.md D5)

- **Notice before the first plan**: "Auto-routes are suggestions" (a suggestion from chart data, not a safe route;
  review every leg; charted depths at chart datum with no tide allowance; the chart data date is shown) must be
  acknowledged before planning, and again whenever `AutoRouteNotice.version` is bumped. Stored in Persistence
  (`autoroute.noticeAcknowledgement`); `AutoRoutePlanner` itself refuses to plan without it.
- **Only green and yellow legs** can be saved or followed (`AutoRouteSafety`); RoutingKit never returns a red leg
  (a would-be red leg makes the query fail with an explanation instead), and any other grade in the stored legs is
  refused. Every yellow leg must state at least one reason, or the route is refused.
- **Yellow legs need confirmation**: Save and Save and follow on a route with yellow legs first show an alert
  listing each distinct reason with its leg count ("Maintained channel depth (14 legs)"); only "I have reviewed the
  yellow legs" saves. The check runs again on the stored legs immediately before writing.
- **Hints are never applied silently**: a "no route" answer offers the option that would help as a button; it
  applies to that re-plan only and the boat profile is not changed. The options used are stored with the route.
- Depth requirement = draft + safety margin, rounded up to whole feet as RoutingKit specifies (spec B.2); NOAA
  depths are compared truncated to 0.1 m.

## Routing packs

Routing packs are not published yet. When the chart build service publishes them, each region in `manifest.json`
carries a `routingPack` entry and `ChartInstaller.install(_:)` downloads it with the chart package (size and
SHA-256), then `AppEnvironment` runs RoutingKit's full pack check as ChartKit's `routingPackValidator`, so a
corrupt pack is rejected and nothing is installed. The planner finds it through `RoutingPackLibrary`, which lists
packs by reading only their 256-byte headers and opens one pack at a time (a region pack is about 80 MB loaded;
opening another or validating at install time releases the one held). Start and destination must lie in the same
pack; otherwise the planner says which end is outside or that they are in different regions.

Side-loading the pilot pack in a debug build (Tampa Bay to Charlotte Harbor, 4.3 MB, not in the repository):
copy the `.pack` file into the simulator or device (drag it onto the simulator to put it in Files, or AirDrop
it), open Charts > Routing packs > "Install a routing pack file…" and pick it. It is validated, copied to
`Library/RoutingPacks/<region id>.pack` and listed with its data date and size; swipe to delete it. The UI tests
use the same folder through `GULFNAV_PREINSTALL_FIXTURE_ROUTING` with the bundled 216 KB `sarasota.pack`.

## Background recording and battery

`UIBackgroundModes` contains `location`, and `LocationPolicy` switches `allowsBackgroundLocationUpdates`
(and the blue background indicator) on **only while a track is being recorded**; otherwise the app stops
receiving locations when it leaves the foreground, as before. Gulf Nav only asks for when-in-use permission:
updates started in the foreground continue in the background with the indicator, which is the pattern Apple
documents for navigation and fitness recording. `NSLocationAlwaysAndWhenInUseUsageDescription` is present
because the background mode requires it and it is shown if the user grants "Always" in Settings.

Battery: recording keeps GPS on at best accuracy for as long as it runs, screen on or off. Expect a few per
cent of battery per hour on a recent iPhone with the screen off, and much more with the screen on (keep
screen on is a setting, default on, because the chart is the point of the app underway). The recording
interval setting changes how many points are stored, not how often GPS runs. The Tracks screen says so.

App Store review: the justification to give is "Gulf Nav records the user's boat track while the user has
started a recording, so a passage is recorded without gaps with the screen locked; background location is
used only during a recording the user started and is stopped when they stop it; location never leaves the
device." The privacy answers stay "location used on device only, not collected".

## Runtime tests (CI job `iOS app (Simulator UI tests)`)

`UITests/` (XCUITest, target `GulfNavUITests`) and `UnitTests/` (hosted unit tests of app-target helpers,
target `GulfNavTests`) run on a booted iPhone simulator. The job picks the simulator by parsing
`xcrun simctl list devices available -j` (newest iOS runtime, plain "iPhone NN" preferred, one is created if
none exists), builds with ad hoc signing (`CODE_SIGN_IDENTITY=-`, falling back to `CODE_SIGNING_ALLOWED=NO`
on a signing error) and runs `xcodebuild test-without-building`. All output goes to files uploaded as
artifacts (`ios-app-test-logs`: full test log, simulator log, crash reports; `ios-app-test-results`: the
`.xcresult`; `ios-app-test-screenshots`: attachments exported with `xcresulttool export attachments`). Only a
compact summary from `Scripts/test-summary.sh` is printed, at the end of the test step and again as the
job's last step: one line per test case with result and duration, each failure's file:line and message,
and the last `map.status` values the UI tests printed (`GULFNAV-MAP-STATUS` lines).

The UI tests drive the app through launch environment variables, read by debug builds only
(`AppServices.LaunchConfiguration`):

| Variable | Effect |
|---|---|
| `GULFNAV_DATA_ROOT=<name>` | all data (charts, store) in `tmp/GulfNavTestData/<name>/`; UserDefaults not used |
| `GULFNAV_RESET_DATA=1` | delete that directory first (clean state) |
| `GULFNAV_SIMULATE_GPS=1` | start on the simulated Tampa Bay track (CoreLocation never asks for permission) |
| `GULFNAV_PREINSTALL_FIXTURE_CHART=1` | install the bundled 16 KB test chart (`FixtureChart`, AppServices' `tiny-a.mbtiles`, debug builds only) through `LocalFileChartTransport`, no network |
| `GULFNAV_PREINSTALL_FIXTURE_ROUTING=1` | side-load the bundled routing test pack (`testdata/routing/sarasota.pack`, debug builds only, `AppServices.FixtureRoutingPack`), add waypoints "RT Longboat", "RT Marina Jack", "RT Roberts Bay" at points from `sarasota.vectors.json`, and run the simulated GPS in Sarasota Bay |
| `GULFNAV_SIM_SPEED_KNOTS=<n>` | speed of the simulated track (default 6; the route-following test uses 240 to reach route points within a couple of minutes) |
| `GULFNAV_TRACK_BATCH_SIZE=<n>` | track points per database write (default 10; the recording test uses 2) |

Tests: (a) the disclaimer gates the app and is not shown again after relaunch; (b) the map style loads and
the instrument strip shows speed, course and a DDM position from simulated GPS; (c) the pre-installed test
chart is listed as installed with its data date, and the map reports a chart layer applied
(`GulfNavUITests.swift`). In `NavigationDataUITests.swift`: waypoints (drop at the boat, list distance and
bearing, rename, go to with guidance values and the direct-to line, stop, long-press drop, delete); a route
created by tapping the chart, saved, drawn and followed; the debug GPX sample's route followed at 240 kn
until legs advance and arrival is announced; a recording killed mid-way, resumed on relaunch, stopped,
listed and drawn; GPX import plan, duplicate re-import and export; the speed unit setting applied and kept
across a relaunch. In `AutoRouteUITests.swift`: the auto-route notice gates planning and is remembered after a
relaunch; RT Longboat → RT Marina Jack (vectors q1) plans 28 green legs, is drawn (`plannedLegs:28`), saved, shown
in Routes with its Route check, and followed; RT Marina Jack → RT Roberts Bay (q4) has no route with one blocked
place on the chart (`blocked:1`) and the "use maintained channels" hint, which plans 55 legs (39 green, 16 yellow,
as q3) that are saved and followed after the yellow-leg confirmation; boat profiles are added, edited, made
default and deleted, and kept across a relaunch. App state is read from a second debug-only element, `app.status`
(`PlotterModel.statusValue`: `waypoints=… routes=… tracks=… recording=… trackPoints=… trackStored=… nav=…
navTarget=… navAdvances=… navArrivals=… editPoints=… selected=… shownRoutes=… shownTracks=… speedUnit=…
lastExport=… lastImport=…`, then from `AutoRouteModel.statusValue`: `notice=unknown|needed|ok`
`planState=idle|planning|proposal|noRoute|snapFailed|<failure kind>` `planLegs=` `planGreen=` `planYellow=`
`planBlocked=` `planHints=useMaintainedChannels,acceptUnknownClearance|none` `planPack=<pack region id>|none`
`routingPacks=N` `planSaved=<route name>|none` `picking=start|goal|none`, and from `BoatProfilesModel`:
`profiles=N defaultProfile=<name>|none`), and what reached the map from `map.status`'s
`overlayFeatures=waypoints:N,routeLegs:N,routePoints:N,tracks:N,direct:N,plannedLegs:N,blocked:N` (counted when
the GeoJSON is set on the style's shape sources). The map state is
read from a debug-only invisible accessibility element `map.status` (value from
`AppServices.MapDiagnostics`: `style=loaded; chartLayers=N; overlayLayers=N; styleVia=…;` then counts of the
MapLibre delegate callbacks `willStartLoading`, `didFinishLoadingMap`, `didFinishLoadingStyle`,
`didFailLoading=<error>`, `frames`, `fullFrames`, `idle`, `rendererErrors`, then `overlayFeatures`), not
from pixels.

**Style loading.** The first CI run showed `style=pending`: `MLNMapView(frame:styleJSON:)` hands the inline
style to mbgl's `loadJSON` inside the initializer, which (as far as the iOS sources at `ios-v7.0.0` show:
`-setStyleJSON:` → `getStyle().loadJSON(...)`, and the style object is created in
`-mapViewDidFinishLoadingStyle`) reports the style loaded before the initializer returns, so the delegate set
afterwards never receives `mapView(_:didFinishLoading:)`. The coordinator now checks `mapView.style` when
it attaches and on every update, and applies chart layers as soon as the style object exists; nothing waits
for a rendered frame. `styleVia` in `map.status` shows which path found the style (`attach`, `update`,
`delegate`). Accessibility identifiers used: `disclaimer.title`, `disclaimer.accept`,
`map.chartsButton`, `map.noChartsBanner`, `map.orientationButton`, `map.followButton`, `map.debugMenu`,
`map.chartAgeBadge`, `chart-map` (the `MLNMapView`), `map.status`, `instrument.strip`, `instrument.sog`,
`instrument.cog`, `instrument.latitude`, `instrument.longitude`, `notice.<kind>`, `charts.done`,
`region.title.<id>`, `region.status.<id>`, `region.dataDate.<id>`, `region.routingPack.<id>`,
`routingPack.row.<pack region>`, `charts.sideLoadPack`; auto-route: `map.autoRouteButton`, `autoroute.notice.accept`,
`autoroute.start`, `autoroute.goal`, `autoroute.profile`, `autoroute.choice.boat|chart|wp.<name>`, `autoroute.plan`,
`autoroute.cancel`, `autoroute.save`, `autoroute.saveFollow`, `autoroute.discard`, `autoroute.hint.<kind>`,
`autoroute.confirmCaution`, `autoroute.summary.<line id>`, `autoroute.leg.<n>`, `autoroute.noRoute.message`,
`autoroute.blocked.<n>`, `autoroute.done`; Route check `route.check.<line id>`; profiles `settings.boatProfiles`,
`profiles.add`, `profile.name|detail|default|use.<name>`, `profile.edit.name|draft|margin|airDraft|beam|speed|save`,
`profile.makeDefault`, `profile.delete`, `profile.confirmDelete`.

To run locally: `xcodegen generate`, then in Xcode Product > Test (or `xcodebuild test -scheme GulfNav
-destination 'platform=iOS Simulator,name=<an iPhone you have>'`).

## Generate and run on a Mac

Requires Xcode 16 or later (CI uses the `macos-26` runner's default Xcode) and Homebrew.

```sh
brew install xcodegen
cd App
xcodegen generate            # writes GulfNav.xcodeproj and Info.plist (both git-ignored)
open GulfNav.xcodeproj       # pick an iPhone simulator, Run
```

Command-line build, as CI does it:

```sh
xcodebuild -project GulfNav.xcodeproj -scheme GulfNav -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO build
```

Re-run `xcodegen generate` after adding or removing source files or editing `project.yml`.

In the simulator: accept the disclaimer, open **Charts**, download a region (ncds_13, 381 MB, is the
smallest), then turn on **Simulate GPS** from the ant menu to see the marker move up Tampa Bay (region 10
covers Tampa Bay; it is 621 MB).

## Placeholders the owner must replace

| What | Where | Now |
|---|---|---|
| Bundle identifier | `project.yml` `PRODUCT_BUNDLE_IDENTIFIER` (and `options.bundleIdPrefix`) | `com.example.gulfnav` |
| Display name | `project.yml` `CFBundleDisplayName` | `Gulf Nav` |
| App icon | `Resources/Assets.xcassets/AppIcon.appiconset` | empty slot (add one 1024×1024 PNG) |
| Accent colour | `Resources/Assets.xcassets/AccentColor.colorset` | a navy blue |
| Version | `project.yml` `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` | 0.1.0 (1) |

## Signing and TestFlight (later)

1. Enrol in the Apple Developer Program and create the app record in App Store Connect with the real bundle id.
2. Set `DEVELOPMENT_TEAM` in `project.yml` (it is empty) and regenerate; automatic signing is already selected.
3. For CI uploads: create an App Store Connect API key, store it as repository secrets, and add an archive +
   export + upload job (`xcodebuild archive`, `-exportArchive` with an `ExportOptions.plist`, then
   `xcrun altool --upload-app` or `fastlane pilot`). Not part of this piece.
4. Before external TestFlight / App Store review: real icon, privacy policy URL, the App Privacy answers
   (location is used on device only, not collected), and the background-location justification once
   background tracking is turned on.

## Configuration notes

- **Swift language mode: Swift 5 with `SWIFT_STRICT_CONCURRENCY = complete`** for the app target. The packages
  (including AppServices) stay in Swift 6 mode. Reason: this target can only be compiled on CI, and the
  MapLibre delegate protocol and SwiftUI/UIKit glue are where Swift 6's isolation rules turn into hard
  errors (MapLibre's Objective-C headers carry no concurrency annotations). In Swift 5 mode the same
  findings are warnings, so a first build is not blocked by them. Switch to `SWIFT_VERSION: "6.0"` once the
  warning list from CI is clean.
- **Info.plist** (generated from `project.yml`): display name, `NSLocationWhenInUseUsageDescription`,
  `NSLocationAlwaysAndWhenInUseUsageDescription`, `UIBackgroundModes = [location]` (used only while
  recording, see above), the GPX document type (`CFBundleDocumentTypes` with `com.topografix.gpx`, declared
  in `UTImportedTypeDeclarations` as conforming to `public.xml`, extension `gpx`, MIME
  `application/gpx+xml`), `LSSupportsOpeningDocumentsInPlace = NO` (opened files are copied in), launch
  screen, orientations, `ITSAppUsesNonExemptEncryption = NO`.
- **Privacy manifest** (`Resources/PrivacyInfo.xcprivacy`): no tracking, no collected data; required-reason
  APIs: UserDefaults `CA92.1` (read once to migrate an older disclaimer acceptance), file timestamp `C617.1` (ChartKit reads file
  attributes of its own packages), disk space `85F4.1` (shown on the Charts screen) and `E174.1` (free-space
  check before a download).
- **Storage**: charts in `Library/Charts` (no spaces, excluded from backup), the Persistence store at
  `Library/AppData/gulfnav.sqlite` (`AppServices.AppPaths`).

## MapLibre

Pinned: **MapLibre Native for iOS 7.0.0** via `https://github.com/maplibre/maplibre-gl-native-distribution`
(`exactVersion: 7.0.0`, released 28 Oct 2026; its `Package.swift` points at the `ios-v7.0.0`
`MapLibre.dynamic.xcframework.zip`, checksum `64f2472a…1734`). 7.0.0's breaking changes (minimum iOS 15.5,
`Mapbox.h` → `MapLibre.h`) do not affect a Swift app targeting iOS 17.

Every API the app uses was checked against the headers and Swift examples at tag `ios-v7.0.0` of
`github.com/maplibre/maplibre-native` (sparse clone), not from memory:

| API | Verified in |
|---|---|
| `MLNMapView(frame:styleJSON:)`, `delegate`, `style`, `setCenter(_:zoomLevel:animated:)`, `setCenter(_:zoomLevel:direction:animated:)`, `direction`, `setDirection(_:animated:)`, `zoomLevel`, `minimumZoomLevel`, `maximumZoomLevel`, `isRotateEnabled`, `isPitchEnabled`, `addAnnotation(_:)`, `removeAnnotation(_:)` | `platform/ios/src/MLNMapView.h`; Swift spellings of `setCenter` in `platform/ios/app-swift/Sources/*.swift` |
| `MLNMapViewDelegate`: `mapView(_:didFinishLoading:)`, `mapView(_:viewFor:)`, `mapView(_:regionWillChangeWith:animated:)`, `mapView(_:regionIsChangingWith:)`, `mapView(_:regionDidChangeWith:animated:)` | `platform/ios/src/MLNMapViewDelegate.h`; Swift names in `platform/ios/test/MLNMapViewDelegateIntegrationTests.swift` |
| `MLNCameraChangeReason.gesturePan` (NS_OPTIONS) | `platform/ios/src/MLNCameraChangeReason.h` |
| `MLNStyle.addSource(_:)`, `addLayer(_:)`, `removeLayer(_:)`; `-removeSource:` called by selector | `platform/darwin/src/MLNStyle.h` (both `-removeSource:` and `-removeSource:error:` exist, hence the selector) |
| `MLNRasterTileSource(identifier:tileURLTemplates:options:)`, `MLNTileSourceOption` `.minimumZoomLevel`, `.maximumZoomLevel`, `.tileSize`, `.coordinateBounds` | `platform/darwin/src/MLNRasterTileSource.h`, `MLNTileSource.h`; Swift usage in `platform/darwin/test/MLNDocumentationExampleTests.swift` |
| `NSValue(mlnCoordinateBounds:)`, `MLNCoordinateBounds(sw:ne:)` | `platform/darwin/src/NSValue+MLNAdditions.h`, `MLNGeometry.h`; Swift pattern `NSValue(mlnSphericalPosition:)` in the doc example tests |
| `MLNRasterStyleLayer(identifier:source:)`, `minimumZoomLevel`, `maximumZoomLevel` | `MLNStyleLayer.h`; Swift usage in `MLNDocumentationExampleTests.swift` |
| `MLNPointAnnotation.coordinate` (settable), `MLNAnnotationView(reuseIdentifier:)`, `isEnabled` | `platform/darwin/src/MLNPointAnnotation.h`, `platform/ios/src/MLNAnnotationView.h`, `app-swift/Sources/AnnotationViewExample.swift` |
| `MLNMapViewDelegate` (diagnostics): `mapViewWillStartLoadingMap(_:)`, `mapViewDidFinishLoadingMap(_:)`, `mapViewDidFailLoadingMap(_:withError:)`, `mapViewDidFinishRenderingFrame(_:fullyRendered:)`, `mapViewDidBecomeIdle(_:)`, `mapViewRendererDidError(_:)` | `MLNMapViewDelegate.h`; Swift names in `MLNMapViewDelegateIntegrationTests.swift` |
| `MLNShapeSource(identifier:shape:options:)` (shape `nil` at first), `shape` (settable), `MLNShape(data:encoding:)` (throws; GeoJSON) | `platform/darwin/src/MLNShapeSource.h`, `MLNShape.h`; Swift usage `MLNShape(data: data, encoding: String.Encoding.utf8.rawValue)` and `MLNShapeSource(identifier: "circles", shape: nil, options: nil)` in `MLNDocumentationExampleTests.swift` / `MLNDocumentationGuideTests.swift`; `polylineSource?.shape = polyline` in `app-swift/Sources/AnimatedLineExample.swift` |
| `MLNLineStyleLayer(identifier:source:)` with `lineColor`, `lineWidth`, `lineCap`, `lineJoin`, `lineOpacity`, `lineDashPattern`; `MLNCircleStyleLayer(identifier:source:)` with `circleColor`, `circleRadius`, `circleStrokeColor`, `circleStrokeWidth`; `MLNVectorStyleLayer.predicate`; `NSExpression(forConstantValue:)` | the layer headers are generated: template `platform/darwin/src/MLNStyleLayer.h.ejs`, names from the style spec camel-cased with the renames in `platform/darwin/scripts/style-spec-cocoa-conventions-v8.json` (`line-dasharray` → `lineDashPattern`); Swift usage of the initializers, colours, widths, `lineCap`, `predicate` (including `cluster == YES`) in `MLNDocumentationExampleTests.swift`, `app-swift/Sources/AnimatedLineExample.swift`, `ClusteringExample.swift` |
| `MLNStyle.insertLayer(_:below:)`, `source(withIdentifier:)`, `layer(withIdentifier:)`; `MLNSource.identifier`, `MLNStyleLayer.identifier` | `MLNStyle.h`, `MLNSource.h`, `MLNStyleLayer.h`; `style.insertLayer(layer, below: symbolLayer)` in `MLNDocumentationGuideTests.swift`, `layer(withIdentifier:)` in `MLNDocumentationExampleTests.swift` |
| Map gestures: `gestureRecognizers` (our tap requires MapLibre's taps to fail), `convert(_:toCoordinateFrom:)`, `convert(_:toPointTo:)` (`-convertCoordinate:toPointToView:`), `centerCoordinate` | `MLNMapView.h`; the tap pattern and `convert(tapPoint, toCoordinateFrom: nil)` from `app-swift/Sources/LineTapMapView.swift`; MapLibre's own single-tap recognizer refuses to begin unless an annotation is hit (`gestureRecognizerShouldBegin:` in `MLNMapView.mm`), so ours fires |
| Auto-route overlays and framing: no new API. Sources `gn-planned` and `gn-blocked` are `MLNShapeSource`s like the others; layers `gn-planned-casing`, `gn-planned-green`, `gn-planned-yellow`, `gn-planned-red` (`MLNLineStyleLayer`) and `gn-blocked` (`MLNCircleStyleLayer`) use only the `grade == %@` predicate form already used for route legs; the camera move is `setCenter(_:zoomLevel:animated:)` | as the rows above |
| `mbtiles://` URLs | `platform/default/src/mln/storage/mbtiles_file_source.cpp`: registered in `file_source_manager.cpp`, tried before the cache and network in `main_resource_loader.cpp`; the path after `mbtiles://` is **percent-decoded** and cut at `?`; tile requests use the tile address, not the URL; the TileJSON it generates uses `<url>?file={x}/{y}/{z}.<format>` |

Overlay layers, bottom to top (all above the chart rasters, which are inserted below the first overlay
layer): saved tracks, live track, active-leg casing, route legs by grade (`none` blue, `green`, `yellow`,
`red`), completed legs (grey), the route being edited (orange dashes), route points, the next point,
the direct-to line (dashed), the planned auto-route (white casing, then green / yellow / red), blocked places
(red dots), waypoints, the direct-to target, the selected waypoint (ring). A plan's result is framed on the chart
with `setCenter(_:zoomLevel:animated:)` (zoom from `AppServices.MapFocus`), switching follow mode off. Shapes are
replaced only when their GeoJSON changed.

How charts are wired: each region becomes an `MLNRasterTileSource` with the inline template
`mbtiles:///…/chart-….mbtiles?file={x}/{y}/{z}.png` (the form MapLibre itself generates), the region's box
as `coordinateBounds` and the package's zoom range, 256-px tiles. Inline templates rather than a TileJSON
URL are used so the region box can be set: NOAA packages contain world-wide tiles at z0–7.

## Needed in existing packages

1. **Done:** Persistence's shim target is now `PersistenceCSQLite` and AppServices depends on Persistence
   unconditionally. Previous note, for the record — **rename one `CSQLite` target.** ChartKit and Persistence both declare a
   system-library target named `CSQLite`. SwiftPM (and Xcode) refuse any package graph containing both:
   `multiple packages ('chartkit', 'persistence') declare targets with a conflicting name: 'CSQLite'`
   (reproduced here with Swift 6.4.2; `moduleAliases` does not help because the module name comes from the
   module map). Fix, e.g. in Persistence: rename the target to `PersistenceCSQLite` in `Package.swift` (target
   and both `.target(name:condition:)` references), the directory `Sources/CSQLite` → `Sources/PersistenceCSQLite`,
   `module CSQLite` → `module PersistenceCSQLite` in its `module.modulemap`, and `import CSQLite` →
   `import PersistenceCSQLite` in `Sources/Persistence/SQLite.swift` and the test target. Then set
   `includePersistence = true` in `Packages/AppServices/Package.swift`, which compiles
   `PersistenceAcknowledgementStore` (disclaimer via `SettingKey.disclaimerAcknowledgement`) and
   `AppPaths.openStore()`, and switch `AppEnvironment.live()` to it. Until then the disclaimer acceptance is
   stored in UserDefaults (`UserDefaultsAcknowledgementStore`). The Persistence-backed code was compiled and
   tested on Linux in a scratch package that depends on Persistence alone.
2. ChartKit `ResumeRecord` has no public memberwise initialiser (tests build one through `Codable`).
3. ChartKit `removeSupersededFiles()` removes all superseded files at once; a `removeSupersededFiles(except:)`
   or per-region variant would let the app release files without the "is any of them still in the applied
   plan" check in `ChartLibrary.releaseSupersededFiles(notReferencedBy:)`.
4. ChartKit has no way to mark a region failed from outside the installer, so a failed NOAA HEAD (before
   `install` is called) is shown from the app's own message table.

## When our own manifest is published

This build installs every NOAA-hosted region through ChartKit's no-manifest fallback
(`InstallStrategy.choose`): HEAD the package URL, build the spec with `RemoteFileCheck.downloadSpec`
(size from Content-Length, version from the ETag, data date from Last-Modified) and call
`install(_:chart:routingPack:)`, which checks size and MBTiles integrity but no checksum. That is needed
because four of the five SHA-256 values in the bundled sample manifest are placeholders.

When the chart build service publishes `manifest.json` with real checksums:

- fetch it at launch / on pull-to-refresh instead of the bundled sample (keep the bundled copy as the offline
  first-launch list), and call `ChartInstaller.apply(_:)` to mark updates;
- regions on our host with real checksums take `InstallStrategy.manifest` (`install(_:)`: size + SHA-256 +
  integrity) automatically; delete the NOAA-host rule in `InstallStrategy.choose` once NOAA's packages are no
  longer offered;
- updates come from the manifest diff rather than `checkRemote` HEAD checks;
- routing packs arrive through the same install call when `routingPack` is present (validated by RoutingKit at
  install time; see "Routing packs").

## Known gaps

- **Not compiled here.** This container has no Xcode; the app target is compiled only by the CI jobs
  `iOS app (Simulator build)` and `iOS app (Simulator UI tests)` (the UI-test file is type-checked on Linux
  against stub XCUI types, which proves nothing about the real framework). AppServices (everything except `CoreLocationService`) is built and tested on
  Linux; the CI `apple` job also builds AppServices for iOS and tests it on macOS.
- **Foreground downloads only.** `URLSessionChartTransport` uses a data task in a default session and streams
  into the partial file; iOS suspends it when the app leaves the foreground, and the next attempt resumes.
  For true background downloads: a `URLSessionConfiguration.background(withIdentifier:)` session whose
  download task carries the same `Range`/`If-Range` headers (`ChartHTTP.downloadHeaders`); append the
  delivered temporary file to the partial file in `urlSession(_:downloadTask:didFinishDownloadingTo:)`
  (or truncate on 200, per `ChartHTTP.decide`); persist the task identifier → region mapping so a relaunch
  can reattach; implement `application(_:handleEventsForBackgroundURLSession:completionHandler:)` via a
  `UIApplicationDelegateAdaptor`; and report progress from `didWriteData`. ChartKit's `download` call is
  `async`, so the background variant must also survive the app being relaunched mid-download (re-enter
  `install` after relaunch; the partial file and resume record are already persisted).
- Background recording has only run in the simulator with simulated GPS (CoreLocation's background
  behaviour is untested until a device run); the battery figures above are estimates, not measurements.
- No text labels on the chart (no glyphs offline). Bundling a glyph range (PBF) for one font would allow
  waypoint and route-point names on the chart.
- GPX export of everything is offered from the Waypoints screen toolbar only; a route's points are exported
  as `<rtept>` without the auto-route metadata.
- MapLibre keeps an open SQLite handle for every `.mbtiles` path it has read (its file source never closes
  them). The app removes the layer before ChartKit deletes or supersedes a file, so the handle is not read
  again, but the disk space of a deleted package may only be returned when the app restarts.
- The chart-age badge shows the oldest installed region, not the one under the viewport.
- Auto-routing: one region at a time (no routes across packs); the 30 s limit is fixed; "inside route only" is a
  per-plan option because Persistence's boat profile has no field for it (it is recorded in the saved route's
  planner record); a saved auto-route's GPX export has no grades; routes are not re-checked when a newer pack
  arrives. Picking a chart point closes the planner while you tap.
- Not handled yet: anchor watch, manifest fetching, retina (512 px) packages
  (the manifest has no tile-size field yet). Depth units are in Settings but no depth is shown yet.
- `URLSessionChartTransport` integration tests (real HTTP with Range/If-Range, drops, cancellation) run only
  when `APPSERVICES_TEST_SERVER` points at `Packages/AppServices/Scripts/range_server.py`; they passed on
  Linux (FoundationNetworking) but have not run on Apple's URLSession.
