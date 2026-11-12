# Gulf Nav — iOS app (first piece)

SwiftUI app for iPhone and iPad, iOS 17.0+. The Xcode project is generated from `project.yml` with
[XcodeGen](https://github.com/yonaskolb/XcodeGen); no `.xcodeproj` is committed. Logic lives in the Swift
packages under `../Packages` (NavCore, ChartKit, AppServices); this target is views and thin view models.

What this first piece does:

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
  launch screen, orientations, `ITSAppUsesNonExemptEncryption = NO`. `UIBackgroundModes` is deliberately
  absent; `LocationPolicy` will not set `allowsBackgroundLocationUpdates` without it.
- **Privacy manifest** (`Resources/PrivacyInfo.xcprivacy`): no tracking, no collected data; required-reason
  APIs: UserDefaults `CA92.1` (disclaimer acceptance, interim), file timestamp `C617.1` (ChartKit reads file
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
| `mbtiles://` URLs | `platform/default/src/mln/storage/mbtiles_file_source.cpp`: registered in `file_source_manager.cpp`, tried before the cache and network in `main_resource_loader.cpp`; the path after `mbtiles://` is **percent-decoded** and cut at `?`; tile requests use the tile address, not the URL; the TileJSON it generates uses `<url>?file={x}/{y}/{z}.<format>` |

How charts are wired: each region becomes an `MLNRasterTileSource` with the inline template
`mbtiles:///…/chart-….mbtiles?file={x}/{y}/{z}.png` (the form MapLibre itself generates), the region's box
as `coordinateBounds` and the package's zoom range, 256-px tiles. Inline templates rather than a TileJSON
URL are used so the region box can be set: NOAA packages contain world-wide tiles at z0–7.

## Needed in existing packages

1. **Blocking Persistence in the app — rename one `CSQLite` target.** ChartKit and Persistence both declare a
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
- routing packs arrive through the same install call when `routingPack` is present.

## Known gaps

- **Not compiled here.** This container has no Xcode; the app target is compiled only by the CI job
  `iOS app (Simulator build)`. AppServices (everything except `CoreLocationService`) is built and tested on
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
- No background location: `UIBackgroundModes` is not declared, so recording keeps the background pieces off.
- MapLibre keeps an open SQLite handle for every `.mbtiles` path it has read (its file source never closes
  them). The app removes the layer before ChartKit deletes or supersedes a file, so the handle is not read
  again, but the disk space of a deleted package may only be returned when the app restarts.
- The chart-age badge shows the oldest installed region, not the one under the viewport.
- Not handled yet: tracks, waypoints, routes, GPX, auto-routing, manifest fetching, retina (512 px) packages
  (the manifest has no tile-size field yet), units other than knots/degrees, the Persistence store.
- `URLSessionChartTransport` integration tests (real HTTP with Range/If-Range, drops, cancellation) run only
  when `APPSERVICES_TEST_SERVER` points at `Packages/AppServices/Scripts/range_server.py`; they passed on
  Linux (FoundationNetworking) but have not run on Apple's URLSession.
