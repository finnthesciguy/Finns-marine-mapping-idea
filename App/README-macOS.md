# Gulf Nav for Mac

The Mac version is the iOS app built for the Mac with **Mac Catalyst**. It is the target `GulfNavMac` in
`project.yml`, built from the same `Sources/`, `Resources/` and Swift packages as the iOS target `GulfNav`. It is
not a fork: a change to a screen or a package reaches both apps. Every feature of the iOS app is in the Mac app:
- offline NOAA charts and chart downloads
- position where the Mac has one
- waypoints, routes with guidance, track recording
- GPX import and export
- boat profiles and auto-routing

What differs is listed below.

## Why Mac Catalyst, and why MapKit draws the chart on the Mac

Three ways to get a Mac app were considered.

1. **Mac Catalyst with MapLibre** (the preferred way, if possible). It is not possible with the pinned MapLibre.
   The xcframework that `maplibre-gl-native-distribution` 7.0.0 points to
   (`ios-v7.0.0/MapLibre.dynamic.xcframework.zip`, checksum `64f2472a…1734`) was downloaded and its `Info.plist`
   read. It contains only `ios-arm64` and `ios-arm64_x86_64-simulator`; there is no `maccatalyst` slice.
2. **A native macOS (AppKit) target with MapLibre for macOS.** MapLibre's macOS platform exists in the source tree
   (`platform/macos`, with `MLN*` classes), but there is no usable release:
   - the published macOS tags stop at `macos-v0.19.1` (September 2021);
   - the newer `macos-release.yml` workflow is manual and has never produced a `macos-v6`/`v7` release;
   - there is no Swift package for macOS.

   This option would also mean porting every UIKit-specific SwiftUI screen to AppKit.
3. **"Designed for iPad" on Apple silicon Macs.** No code: the iPhone/iPad build runs as-is once it is on the
   App Store, if the Mac availability option is left on in App Store Connect. Limits:
   - Apple silicon Macs only;
   - the iPad interface in a window, with no menu bar commands, right-click or Mac window behaviour;
   - distribution only through the App Store.

   It remains available as a stop-gap.

Chosen: **Mac Catalyst as a separate target that does not link MapLibre.** The chart map on the Mac is MapKit
(`Sources/Map/ChartMapViewMac.swift`), which Mac Catalyst has. Everything else (every screen, the packages, the
tests) is shared. A separate target was used rather than a platform filter on the MapLibre dependency because it
is uncertain whether Xcode skips a binary xcframework without a Catalyst slice when the product is filtered.
Forum reports show "no library for this platform" errors in that case; a separate target avoids the question.
When MapLibre ships a Mac Catalyst slice, the Mac target can link it and drop the MapKit file.

How the MapKit map matches the iOS one:

- **Charts.** One `MKTileOverlay` per installed region, in ChartKit's layer-plan order.
  - Tiles are read from the region's `.mbtiles` through ChartKit's `MBTilesReader`; the same files and folder
    layout as iOS.
  - Only tiles inside the region box are drawn.
  - Above the package's highest zoom, the parent tile is cropped and scaled up, as MapLibre does
    (`AppServices.ChartTileMath`).
- **Offline base.** A water-coloured tile overlay replaces Apple's map, so nothing is loaded from Apple's
  servers and the chart looks as it does on iOS.
- **Missing tiles.** A tile the package does not have (outside the region box, a zoom it lacks) is answered with a
  transparent tile. Returning an error made MapKit report a map load failure (seen on CI).
- **Overlays.** Tracks, routes, route points, the direct-to line, planned auto-routes, blocked places and
  waypoints come from the same GeoJSON (`AppServices.MapOverlays`).
  - The MapLibre layer table is re-expressed as data in `AppServices.OverlayStyling`: the same colours, widths,
    dashes and draw order.
  - Lines are `MKPolyline` overlays; points are annotation views with drawn circles.
  - The mapping is tested on Linux (`MacSupportTests.swift`).
- **The rest is the same as iOS.** Own-ship marker, follow mode, north-up / course-up, single click (select a
  waypoint, add a route point), click-and-hold (drop a waypoint), framing a planned route.
- **Test probes.** The same `map.status` and `chart-map` accessibility probes. MapKit has no style object, so
  `styleVia=attach` straight away. `chartLayers` counts the tile overlays. `overlayFeatures` is the same summary.

Verified, not from memory:
- the xcframework `Info.plist` (above);
- the macOS tags with `git ls-remote`;
- MapKit, CoreLocation and UIKit headers of the iOS 18 SDK, and Apple's documentation pages for the Swift
  spellings and Mac Catalyst availability of every new API. The list is in the header comment of
  `ChartMapViewMac.swift`;
- XcodeGen's `ProjectSpec.md` and `PBXProjGenerator.swift`;
- Swift Build's package builder (`PackagePIFBuilder+Helpers.swift`): a package that declares iOS 17 but no Mac
  Catalyst version gets an aligned Mac Catalyst 17 deployment target;
- the XCUI APIs used on the Mac (`click`, `rightClick`, `typeKey`, `scroll(byDeltaX:deltaY:)`, `menuBarItems`),
  which are all available on Mac Catalyst.

## Build and run on a Mac

Requirements: Xcode 26 (CI uses the `macos-26` runner's default Xcode), Homebrew, macOS 14 or later to run.

```sh
brew install xcodegen
cd App
xcodegen generate                 # GulfNav.xcodeproj, Info.plist, Info-macOS.plist (all git-ignored)
open GulfNav.xcodeproj            # scheme GulfNavMac, destination "My Mac", Run
```

Command line, as CI does it:

```sh
xcodebuild -project GulfNav.xcodeproj -scheme GulfNavMac \
  -destination 'generic/platform=macOS,variant=Mac Catalyst' CODE_SIGNING_ALLOWED=NO build
# tests (ad hoc signed so the sandbox applies):
xcodebuild test -project GulfNav.xcodeproj -scheme GulfNavMac \
  -destination 'platform=macOS,variant=Mac Catalyst' CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=
```

In a debug build the Debug menu has "Simulate GPS (Tampa Bay)" and "Import Sample GPX". With simulated GPS the
boat moves up Tampa Bay as on the iOS simulator. The launch switches in `README.md` (`GULFNAV_DATA_ROOT`,
`GULFNAV_SIMULATE_GPS`, …) work the same way. Set them in the scheme's Run > Arguments > Environment Variables.

## What differs from iOS

| Area | iOS | Mac |
|---|---|---|
| Chart engine | MapLibre Native 7.0.0 | MapKit tile overlays reading the same MBTiles (see above); zoom buttons and a compass from MapKit |
| Position | GPS | Wi-Fi positioning through Location Services, often unavailable or denied. The instrument strip says "No position…" instead of showing values (also when the last fix is older than 30 s), and everything except "drop at the boat" and following works without a position |
| "Drop Waypoint" with no position | error banner | dropped at the centre of the chart |
| Chart interaction | tap, long-press, pinch | click (select / add route point), click-and-hold (drop waypoint), right-click or control-click context menu (Drop Waypoint Here, Go To Here, Auto-Route From Here, Auto-Route To Here, plus Select Waypoint on a waypoint), trackpad / scroll and MapKit's zoom controls, ⌘= / ⌘- |
| Menu bar | — | File: New Route on Chart ⌘N, Plan Auto-Route… ⇧⌘N, Import GPX… ⌘O, Export All as GPX… ⇧⌘E. App menu: Settings… ⌘,. Navigation: Drop Waypoint ⌘D, Start or Stop Recording ⌘R, Charts ⌘1, Waypoints ⌘2, Routes ⌘3, Tracks ⌘4. Chart: Zoom In ⌘=, Zoom Out ⌘-, North Up ⌘U, Switch North Up / Course Up ⇧⌘U, Follow the Boat ⌘L. Debug builds: Debug menu. Each item does exactly what the matching map button does (`AppCommand`, carried out in `MapScreen`) |
| GPX import | document picker, "Open in Gulf Nav" | open panel (⌘O), drag a `.gpx` onto the window, Finder "Open With" > Gulf Nav; the same import plan screen |
| GPX export | share sheet | save panel |
| Screens | sheets | the same SwiftUI sheets, shown as Mac sheets on the window (no redesign) |
| Window | — | opens at 1280 × 860 (clamped to the screen), minimum 800 × 600 (fits a 1024 × 768 display), the chart fills the window. SwiftUI sizes a Catalyst window from its content, and the first content is the small "Loading…" view (CI saw a 59 × 69 window), so the root view has a minimum frame with `.windowResizability(.contentMinSize)`, and `MacWindow.configure()` sets the scene's minimum size and requests a frame (`requestGeometryUpdate(.Mac(systemFrame:))`) when the window is still smaller |
| Keep the screen on | idle timer | "Keep the display awake": a process activity that stops display sleep while the setting is on |
| Track recording | background location mode while recording, blue indicator | no background mode needed (a Mac app keeps running behind other windows); records while a position is available. The Tracks and Settings wording says so |
| Data folder | `Library/Charts`, `Library/AppData`, `Library/RoutingPacks` | the same subfolders under `~/Library/Containers/com.example.gulfnav/Data/Library/Application Support/com.example.gulfnav/` (sandboxed). Charts and routing packs are excluded from backup (Time Machine honours the flag) |
| Interface | iPhone / iPad | "Optimize Interface for Mac" (`TARGETED_DEVICE_FAMILY` 1,2,6): native Mac controls and text sizes. If a control looks wrong, setting the Mac target to "1,2" gives the scaled iPad interface instead |

Platform differences in code are all behind `#if targetEnvironment(macCatalyst)`, and each iOS branch is what the
iOS app did before:
- `Sources/Map/ChartMapViewMac.swift`, and the MapLibre files `ChartMapView.swift` / `MapOverlayLayers.swift`,
  which compile to nothing on the Mac;
- `Sources/Support/PlatformSupport.swift` (wording, keep-awake, export, window, drag and drop);
- `Sources/App/MacCommands.swift`;
- the instrument strip's no-position line in `MapScreen.swift`;
- `AppServices` `AppPaths.live()` and `CoreLocationService`: no background-location properties on the Mac;
  `showsBackgroundLocationIndicator` is unavailable on macOS.

## Mac build settings (project.yml, target GulfNavMac)

- `SUPPORTS_MACCATALYST = YES` and `SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD = NO`.
- `DERIVE_MACCATALYST_PRODUCT_BUNDLE_IDENTIFIER = NO`: the bundle id stays `com.example.gulfnav`, the same as
  iOS, for one App Store record.
- No MapLibre dependency.
- Entitlements `Mac/GulfNav-macOS.entitlements`, used only by this target:
  - app sandbox;
  - outgoing network (chart downloads);
  - user-selected files read/write (GPX import/export, the debug routing-pack side-load);
  - location.
- Hardened runtime on in Release (needed for notarisation), off in Debug so CI can inject the hosted unit tests
  into an ad hoc signed app.
- `Info-macOS.plist`:
  - no `UIBackgroundModes`;
  - `NSLocationWhenInUseUsageDescription` and `NSLocationUsageDescription`;
  - category `public.app-category.navigation`;
  - the GPX document type;
  - `LSSupportsOpeningDocumentsInPlace = YES`. macOS rejects `NO` at build time, and the app only reads an opened
    file in place with security-scoped access (`GPXFiles.plan(fileAt:)`).
- The privacy manifest is shared with iOS. Its required-reason entries cover the Mac too.
- Release builds exclude the test chart and the test routing pack, as on iOS.

## Tests on CI

- **`Mac app (Mac Catalyst build)`**
  - Builds unsigned.
  - Prints the error count, the error lines and the warnings in Mac-specific files.
  - Checks that the built app does not link MapLibre. When the build fails, the post-build checks are skipped
    and say so.
- **`Mac app (Mac Catalyst tests)`**
  - Turns on UI automation (`automationmodetool`).
  - Builds for testing with ad hoc signing (falls back to unsigned on a signing error).
  - Runs `GulfNavMacTests` (the app helper unit tests) and `GulfNavMacUITests` on the runner itself, with no
    simulator.
  - Prints the same compact summary as the iOS job (`Scripts/test-summary.sh` with `SUMMARY_TITLE="Mac app"`, plus
    the tests' `GULFNAV-NOTE` lines).
  - Uploads the artifacts `mac-app-test-logs`, `mac-app-test-results` and `mac-app-test-screenshots`.
- **The UI tests.** The iOS UI tests run unchanged against the Mac app, with Mac conditions in the test helpers:
  - the debug actions go through the menu bar's Debug menu;
  - lists are scrolled with scroll-wheel steps instead of swipes;
  - the speed-unit picker is also found as radio buttons;
  - export expects a save panel and cancels it.
- **Mac-only tests** (`UITests/MacUITests.swift`):
  - the window size (the window that contains the chart, at least 800 × 600) and the chart filling it; every test
    logs each window's frame and the app's `mac.window` probe (screen and window size as macOS reports them) as
    `GULFNAV-NOTE` lines;
  - menu items and ⌘D / ⌘R / ⌘2 / ⌘N doing what the buttons do;
  - no simulated GPS: the "no position" line, and ⌘D dropping at the chart centre;
  - right-click > Drop Waypoint Here.
- **What to expect on a CI Mac.**
  - It has no location fix, so the GPS-dependent tests use `GULFNAV_SIMULATE_GPS`.
  - It may have no GPU surface for MapKit. The tests read `map.status` / `app.status`, which come from the app's
    own state, so they do not depend on tiles being drawn. `frames` / `fullFrames` in `map.status` show whether
    MapKit rendered at all.
  - The no-position test also passes if the Mac does get a fix (it then only checks the drop).

## Distribution (what the owner needs)

**Mac App Store, same App Store Connect record as iOS.**
1. With the same bundle id, add the macOS platform to the existing app in App Store Connect. Universal purchase:
   one purchase covers iPhone, iPad and Mac.
2. Set `DEVELOPMENT_TEAM`; automatic signing creates a Mac Catalyst App Store provisioning profile.
3. Archive the `GulfNavMac` scheme (`xcodebuild archive -scheme GulfNavMac -destination
   'generic/platform=macOS,variant=Mac Catalyst'`) and upload from the Organizer or with `altool` / `notarytool`.
4. For review you need:
   - Mac screenshots;
   - the sandbox entitlements (already set);
   - the same privacy answers (location used on the device only);
   - an export-compliance answer (already `ITSAppUsesNonExemptEncryption = NO`).
5. Option C ("Designed for iPad") should then be switched off in App Store Connect so Apple silicon Macs get the
   real Mac app.

**Direct download (notarised, Developer ID).**
1. Needs a Developer ID Application certificate (Apple Developer Program).
2. Archive `GulfNavMac`, export with method "Developer ID", hardened runtime (on in Release), then
   `xcrun notarytool submit GulfNav.zip --keychain-profile … --wait`, `xcrun stapler staple "Gulf Nav.app"`.
3. Ship a DMG or zip. The sandbox can stay on (recommended).
4. Updates are then the owner's job (e.g. Sparkle); there is no App Store update channel.

Both need the real bundle id, name and icon (see "Placeholders" in `README.md`). The Mac icon comes from the same
asset catalog; add a 1024 × 1024 image.

## Known gaps

- **Not run on a real Mac yet.** CI builds and tests it on a headless runner. MapKit rendering of the MBTiles
  overlays, and Wi-Fi positioning, have only been reasoned about, not seen.
- **Sharper tiles on Retina.** On Retina screens MapKit shows the 256-px chart tiles scaled up, so the chart is
  less sharp than on iPhone. Requesting the next zoom level for `contentScaleFactor` 2 would fix that.
- **Chart framing and zoom are approximate.** MapKit has no zoom levels. Zoom is converted with Web Mercator
  arithmetic, so framing a planned route and ⌘= / ⌘- steps are close to, not identical with, MapLibre's.
- **Follow mode and scroll-wheel zoom.** A scroll-wheel or trackpad pan turns follow mode off (as a drag does on
  iOS); zoom does not. Whether MapKit reports trackpad scrolling as a pan gesture on every Mac is unverified.
- **Fixed shortcuts.** Menu items do not show state ("Stop Recording" vs "Start Recording"); they are fixed
  wording with fixed shortcuts.
- **Untested Mac wiring.** Drag and drop accepts GPX/XML data or a `.gpx` file URL; it is exercised by hand only,
  not by a UI test. The same applies to opening from Finder.
- **AutoRouteUITests on the Mac.** `AutoRouteUITests.swift` (not edited here; another piece of work owns it)
  scrolls lists with `app.swipeUp()` / `app.swipeDown()` in its `scrollTo` helper. Dragging does not scroll a list
  on a Mac, so those tests may fail on the Mac job when an element is below the fold. The fix is a two-line change
  in that helper: replace `if downwards { app.swipeDown() } else { app.swipeUp() }` with
  `if downwards { scrollUp(app) } else { scrollDown(app) }`. Those helpers are defined in
  `NavigationDataUITests.swift` and swipe on iOS exactly as before.
- **Background downloads.** Chart downloads are foreground-only, as on iOS. A Mac app keeps running behind other
  windows, so this matters less there.
