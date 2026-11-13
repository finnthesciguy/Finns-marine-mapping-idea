import XCTest

/// Waypoints, routes, tracks, GPX and settings (deliverable 3). Same conventions as the tests in
/// `GulfNavUITests.swift`: isolated data directory, simulated GPS, assertions on the debug-only status
/// elements `app.status` (counts and states from `PlotterModel.statusValue`) and `map.status`
/// (`overlayFeatures=waypoints:N,routeLegs:N,routePoints:N,tracks:N,direct:N` as applied to the map's
/// style sources), rather than on pixels. Every wait polls with a generous timeout.
extension GulfNavUITests {
    static let ddmDistancePattern = "^[0-9]+\\.?[0-9]* nm$"
    static let bearingPattern = "^[0-9]{3}°T$"
    static let clockPattern = "^[0-9]{2}:[0-9]{2}$"

    // MARK: Waypoints

    /// Drop at the boat, list with distance and bearing, rename, go to (guidance and direct-to line), stop,
    /// drop by long-press, delete.
    @MainActor
    func testWaypointsDropEditListGoToAndDelete() throws {
        let app: XCUIApplication = GulfNavUITests.makeApp(root: GulfNavUITests.uniqueRoot("waypoints"), reset: true)
        app.launch()
        acceptDisclaimer(app)
        waitForFix(app)

        app.buttons["map.dropWaypoint"].tap()
        waitForStatus(app, "waypoints", "1")
        waitForStatus(app, "selected", "WP 001")
        waitForOverlay(app, "waypoints", atLeast: 1)

        app.buttons["map.waypointsButton"].tap()
        let distance: XCUIElement = app.staticTexts["waypoint.distance.WP 001"]
        XCTAssertTrue(distance.waitForExistence(timeout: GulfNavUITests.stepTimeout), "waypoint listed")
        waitUntil(GulfNavUITests.stepTimeout, "distance shown, got '\(distance.label)'") {
            GulfNavUITests.matches(distance.label, GulfNavUITests.ddmDistancePattern)
        }
        let bearing: XCUIElement = app.staticTexts["waypoint.bearing.WP 001"]
        waitUntil(GulfNavUITests.stepTimeout, "bearing shown, got '\(bearing.label)'") {
            GulfNavUITests.matches(bearing.label, GulfNavUITests.bearingPattern)
        }
        attachScreenshot(app, "waypoints-list")

        // Rename.
        app.staticTexts["waypoint.name.WP 001"].tap()
        let nameField: XCUIElement = app.textFields["waypoint.edit.name"]
        XCTAssertTrue(nameField.waitForExistence(timeout: GulfNavUITests.stepTimeout))
        replaceText(in: nameField, with: "Egmont")
        app.buttons["waypoint.edit.save"].tap()
        XCTAssertTrue(app.staticTexts["waypoint.name.Egmont"].waitForExistence(timeout: GulfNavUITests.stepTimeout),
                      "renamed waypoint listed")

        // Go to the waypoint just dropped at the boat: the boat is at (or near) it, so arrival may be
        // announced at once (ETA "—" is then correct); bearing and distance are shown either way.
        app.staticTexts["waypoint.name.Egmont"].tap()
        let goTo: XCUIElement = app.buttons["waypoint.edit.goTo"]
        XCTAssertTrue(goTo.waitForExistence(timeout: GulfNavUITests.stepTimeout))
        goTo.tap()
        waitForStatus(app, "nav", "directTo")
        waitForStatus(app, "navTarget", "Egmont")
        let target: XCUIElement = app.staticTexts["guidance.target"]
        XCTAssertTrue(target.waitForExistence(timeout: GulfNavUITests.stepTimeout))
        XCTAssertEqual(target.label, "Egmont")
        let dtw: XCUIElement = app.staticTexts["guidance.distance"]
        let brg: XCUIElement = app.staticTexts["guidance.bearing"]
        waitUntil(GulfNavUITests.stepTimeout, "distance and bearing, got '\(dtw.label)' '\(brg.label)'") {
            GulfNavUITests.matches(dtw.label, GulfNavUITests.ddmDistancePattern)
                && GulfNavUITests.matches(brg.label, GulfNavUITests.bearingPattern)
        }
        GulfNavUITests.logMapStatus(app, "goto-near")
        app.buttons["guidance.stop"].tap()
        waitForStatus(app, "nav", "idle")
        waitForOverlay(app, "direct", equals: 0)

        // Long-press the chart well north of the boat (the chart follows the boat, so its centre is the
        // boat; a quarter of the screen up at zoom 9 is tens of miles) to drop a second waypoint.
        let arrivalsBefore: String = GulfNavUITests.statusField(app, "navArrivals") ?? "0"
        GulfNavUITests.chartMap(app).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25)).press(forDuration: 1.2)
        waitForStatus(app, "waypoints", "2")
        // The new waypoint is selected. Its default number never repeats: WP 001 was renamed, so this is
        // WP 002 (AppServices.WaypointNumbering). Read the name rather than assume it, then check it.
        waitUntil(GulfNavUITests.stepTimeout, "the new waypoint selected, status: \(GulfNavUITests.appStatusValue(app))") {
            let selected: String = GulfNavUITests.statusField(app, "selected") ?? "none"
            return selected != "none" && selected != "Egmont"
        }
        let farName: String = GulfNavUITests.statusField(app, "selected") ?? "?"
        XCTAssertEqual(farName, "WP 002", "waypoint numbers are not reused after a rename")
        waitForOverlay(app, "waypoints", atLeast: 2)

        // Go to it from the selection card: full guidance, including XTE and ETA, and the direct-to line.
        let cardGoTo: XCUIElement = app.buttons["selection.goTo"]
        XCTAssertTrue(cardGoTo.waitForExistence(timeout: GulfNavUITests.stepTimeout))
        cardGoTo.tap()
        waitForStatus(app, "navTarget", farName)
        let xte: XCUIElement = app.staticTexts["guidance.xte"]
        let eta: XCUIElement = app.staticTexts["guidance.eta"]
        waitUntil(GulfNavUITests.stepTimeout, "guidance values, got '\(dtw.label)' '\(brg.label)' '\(xte.label)'") {
            GulfNavUITests.matches(dtw.label, GulfNavUITests.ddmDistancePattern)
                && GulfNavUITests.matches(brg.label, GulfNavUITests.bearingPattern)
                && (xte.label.hasSuffix(" nm") || xte.label.hasSuffix(" R") || xte.label.hasSuffix(" L"))
        }
        waitUntil(GulfNavUITests.stepTimeout, "ETA shown, got '\(eta.label)'") {
            GulfNavUITests.matches(eta.label, GulfNavUITests.clockPattern)
        }
        XCTAssertEqual(GulfNavUITests.statusField(app, "navArrivals"), arrivalsBefore, "no arrival at a distant mark")
        waitForOverlay(app, "direct", atLeast: 1)
        GulfNavUITests.logMapStatus(app, "goto-far")
        attachScreenshot(app, "go-to")
        app.buttons["guidance.stop"].tap()
        waitForStatus(app, "nav", "idle")

        // Delete it from the list.
        app.buttons["map.waypointsButton"].tap()
        let second: XCUIElement = app.staticTexts["waypoint.name.\(farName)"]
        XCTAssertTrue(second.waitForExistence(timeout: GulfNavUITests.stepTimeout))
        second.tap()
        let delete: XCUIElement = app.buttons["waypoint.edit.delete"]
        XCTAssertTrue(delete.waitForExistence(timeout: GulfNavUITests.stepTimeout))
        delete.tap()
        tapConfirmation(app, identifier: "waypoint.edit.confirmDelete", label: "Delete")
        waitForStatus(app, "waypoints", "1")
        GulfNavUITests.logMapStatus(app, "waypoints-end")
        attachScreenshot(app, "waypoints-end")
    }

    // MARK: Routes

    /// Create a route by tapping the chart, save it, see it listed and drawn, follow it, stop.
    @MainActor
    func testRouteCreatedOnTheChartIsSavedDrawnAndFollowed() throws {
        let app: XCUIApplication = GulfNavUITests.makeApp(root: GulfNavUITests.uniqueRoot("routes"), reset: true)
        app.launch()
        acceptDisclaimer(app)
        waitForFix(app)
        // Stop following the boat so the chart stays put while points are tapped.
        app.buttons["map.followButton"].tap()

        app.buttons["map.routesButton"].tap()
        let newRoute: XCUIElement = app.buttons["routes.new"]
        XCTAssertTrue(newRoute.waitForExistence(timeout: GulfNavUITests.stepTimeout))
        newRoute.tap()
        waitForStatus(app, "editPoints", "0")

        let map: XCUIElement = GulfNavUITests.chartMap(app)
        // Upper half of the chart: the route edit bar, the map buttons and the instruments fill the lower
        // half on a phone (the first run's third point at 46 % landed on the edit bar), and banners the top.
        let offsets: [CGVector] = [CGVector(dx: 0.35, dy: 0.22), CGVector(dx: 0.62, dy: 0.28), CGVector(dx: 0.45, dy: 0.35)]
        for (index, offset) in offsets.enumerated() {
            map.coordinate(withNormalizedOffset: offset).tap()
            waitForStatus(app, "editPoints", String(index + 1))
        }
        waitForOverlay(app, "routePoints", atLeast: 3)
        attachScreenshot(app, "route-editing")
        app.buttons["routeEdit.save"].tap()
        waitForStatus(app, "routes", "1")
        waitForStatus(app, "editPoints", "-1")
        waitForOverlay(app, "routeLegs", atLeast: 2)

        app.buttons["map.routesButton"].tap()
        let detail: XCUIElement = app.staticTexts["route.detail.0"]
        XCTAssertTrue(detail.waitForExistence(timeout: GulfNavUITests.stepTimeout))
        XCTAssertTrue(detail.label.hasPrefix("3 points, "), detail.label)
        app.staticTexts["route.name.0"].tap()
        let follow: XCUIElement = app.buttons["route.follow"]
        XCTAssertTrue(follow.waitForExistence(timeout: GulfNavUITests.stepTimeout))
        follow.tap()
        waitForStatus(app, "nav", "route")
        let progress: XCUIElement = app.staticTexts["guidance.progress"]
        XCTAssertTrue(progress.waitForExistence(timeout: GulfNavUITests.stepTimeout))
        XCTAssertTrue(GulfNavUITests.matches(progress.label, "^[1-3]/3$"), progress.label)
        GulfNavUITests.logMapStatus(app, "route-follow")
        attachScreenshot(app, "route-follow")
        app.buttons["guidance.stop"].tap()
        waitForStatus(app, "nav", "idle")
    }

    /// Import the sample GPX, follow its route at high simulated speed: the route is joined at the leg the
    /// boat is on, legs advance automatically, and arrival is reported.
    @MainActor
    func testFollowingAnImportedRouteAdvancesLegsAndArrives() throws {
        let app: XCUIApplication = GulfNavUITests.makeApp(root: GulfNavUITests.uniqueRoot("follow"), reset: true,
                                                          speedKnots: 240)
        app.launch()
        acceptDisclaimer(app)
        importSampleGPX(app)
        let importButton: XCUIElement = app.buttons["gpx.import"]
        importButton.tap()
        waitForStatus(app, "routes", "1")

        app.buttons["map.routesButton"].tap()
        let row: XCUIElement = app.staticTexts["route.name.0"]
        XCTAssertTrue(row.waitForExistence(timeout: GulfNavUITests.stepTimeout))
        row.tap()
        let follow: XCUIElement = app.buttons["route.follow"]
        XCTAssertTrue(follow.waitForExistence(timeout: GulfNavUITests.stepTimeout))
        follow.tap()
        waitForStatus(app, "nav", "route")
        let joinedAt: String = GulfNavUITests.statusField(app, "navTarget") ?? "?"
        print("GULFNAV-NOTE joined the route at \(joinedAt)")
        attachScreenshot(app, "follow-start")

        // At 240 kn the simulated boat reaches the end of the sample route in about a minute and a half.
        waitUntil(180, "arrival, status: \(GulfNavUITests.appStatusValue(app))") {
            (Int(GulfNavUITests.statusField(app, "navArrivals") ?? "0") ?? 0) >= 1
        }
        if joinedAt == "WP 2" || joinedAt == "Start" {
            let advances: Int = Int(GulfNavUITests.statusField(app, "navAdvances") ?? "0") ?? 0
            XCTAssertGreaterThanOrEqual(advances, 1, "joined before the last point, so at least one leg advanced")
        }
        XCTAssertTrue(app.staticTexts["guidance.target"].label == "End", app.staticTexts["guidance.target"].label)
        GulfNavUITests.logMapStatus(app, "follow-arrived")
        attachScreenshot(app, "follow-arrived")
    }

    // MARK: Tracks

    /// Record, kill the app mid-recording, relaunch: the recording is resumed, then stopped, listed with
    /// distance and duration, and drawn from the saved geometry.
    @MainActor
    func testTrackRecordingSurvivesRelaunchAndIsListed() throws {
        let root: String = GulfNavUITests.uniqueRoot("tracks")
        let app: XCUIApplication = GulfNavUITests.makeApp(root: root, reset: true, speedKnots: 30, trackBatchSize: 2)
        app.launch()
        acceptDisclaimer(app)
        waitForFix(app)

        app.buttons["map.recordButton"].tap()
        waitForStatus(app, "recording", "recording")
        waitUntil(90, "two points stored, status: \(GulfNavUITests.appStatusValue(app))") {
            (Int(GulfNavUITests.statusField(app, "trackStored") ?? "0") ?? 0) >= 2
        }
        waitForOverlay(app, "tracks", atLeast: 1)
        GulfNavUITests.logMapStatus(app, "recording")
        attachScreenshot(app, "recording")

        // Kill the app while recording, as iOS might.
        app.terminate()
        let relaunched: XCUIApplication = GulfNavUITests.makeApp(root: root, reset: false, speedKnots: 30, trackBatchSize: 2)
        relaunched.launch()
        XCTAssertTrue(relaunched.buttons["map.chartsButton"].waitForExistence(timeout: GulfNavUITests.launchTimeout))
        waitForStatus(relaunched, "recording", "recording")
        XCTAssertTrue(relaunched.buttons["notice.recordingInterrupted"].waitForExistence(timeout: GulfNavUITests.stepTimeout),
                      "the user is told the recording was resumed")
        let storedBefore: Int = Int(GulfNavUITests.statusField(relaunched, "trackStored") ?? "0") ?? 0
        waitUntil(90, "more points after resuming, status: \(GulfNavUITests.appStatusValue(relaunched))") {
            (Int(GulfNavUITests.statusField(relaunched, "trackStored") ?? "0") ?? 0) >= max(storedBefore, 2) + 2
        }

        relaunched.buttons["map.recordButton"].tap()
        waitForStatus(relaunched, "recording", "idle")
        waitForStatus(relaunched, "tracks", "1")
        waitForStatus(relaunched, "shownTracks", "1")
        waitForOverlay(relaunched, "tracks", atLeast: 1)

        relaunched.buttons["map.tracksButton"].tap()
        let distance: XCUIElement = relaunched.staticTexts["track.distance.0"]
        XCTAssertTrue(distance.waitForExistence(timeout: GulfNavUITests.stepTimeout))
        XCTAssertTrue(GulfNavUITests.matches(distance.label, GulfNavUITests.ddmDistancePattern), distance.label)
        XCTAssertNotEqual(distance.label, "0.00 nm")
        let duration: XCUIElement = relaunched.staticTexts["track.duration.0"]
        XCTAssertTrue(GulfNavUITests.matches(duration.label, "^[0-9]+ (s|min)$|^[0-9]+ h [0-9]{2} min$"), duration.label)
        attachScreenshot(relaunched, "tracks-list")
        relaunched.buttons["tracks.done"].tap()
        GulfNavUITests.logMapStatus(relaunched, "tracks-end")
    }

    // MARK: GPX

    /// Import the sample GPX (plan, then apply), import it again (all duplicates, skipped), export all.
    @MainActor
    func testGPXImportPlanShowsDuplicatesAndExportWritesAFile() throws {
        let app: XCUIApplication = GulfNavUITests.makeApp(root: GulfNavUITests.uniqueRoot("gpx"), reset: true)
        app.launch()
        acceptDisclaimer(app)

        importSampleGPX(app)
        XCTAssertEqual(app.staticTexts["gpx.summary"].label, "2 waypoints, 1 route and 1 track.")
        attachScreenshot(app, "import-plan")
        app.buttons["gpx.import"].tap()
        waitForStatus(app, "waypoints", "2")
        waitForStatus(app, "routes", "1")
        waitForStatus(app, "tracks", "1")
        waitForStatus(app, "lastImport", "Imported 4.")
        waitForOverlay(app, "routeLegs", atLeast: 2)

        importSampleGPX(app)
        let summary: XCUIElement = app.staticTexts["gpx.summary"]
        XCTAssertTrue(summary.label.contains("4 already saved or repeated. 4 will be skipped."), summary.label)
        let duplicate: XCUIElement = app.staticTexts["gpx.duplicate.w0"]
        XCTAssertTrue(duplicate.waitForExistence(timeout: GulfNavUITests.stepTimeout))
        XCTAssertTrue(duplicate.label.hasPrefix("Already saved as"), duplicate.label)
        attachScreenshot(app, "import-duplicates")
        app.buttons["gpx.import"].tap()
        waitForStatus(app, "lastImport", "Imported 0, skipped 4.")
        waitForStatus(app, "waypoints", "2")

        app.buttons["map.waypointsButton"].tap()
        let export: XCUIElement = app.buttons["waypoints.exportAll"]
        XCTAssertTrue(export.waitForExistence(timeout: GulfNavUITests.stepTimeout))
        export.tap()
        waitUntil(GulfNavUITests.stepTimeout, "export written, status: \(GulfNavUITests.appStatusValue(app))") {
            (GulfNavUITests.statusField(app, "lastExport") ?? "").hasSuffix(".gpx")
        }
        // The share sheet's own elements belong to the system; only report whether it appeared.
        let shareSheet: XCUIElement = app.otherElements["ActivityListView"]
        print("GULFNAV-NOTE share sheet visible: \(shareSheet.waitForExistence(timeout: 10))")
        attachScreenshot(app, "export-share-sheet")
    }

    // MARK: Settings

    /// Change the speed unit; the instrument strip follows, and the setting survives a relaunch.
    @MainActor
    func testSettingsSpeedUnitIsAppliedAndKept() throws {
        let root: String = GulfNavUITests.uniqueRoot("settings")
        let app: XCUIApplication = GulfNavUITests.makeApp(root: root, reset: true)
        app.launch()
        acceptDisclaimer(app)
        let sog: XCUIElement = app.staticTexts["instrument.sog"]
        waitUntil(GulfNavUITests.stepTimeout, "speed in knots, got '\(sog.label)'") { sog.label.hasSuffix(" kn") }

        app.buttons["map.settingsButton"].tap()
        let segmented: XCUIElement = app.segmentedControls["settings.speedUnit"]
        let kmh: XCUIElement = segmented.exists ? segmented.buttons["km/h"] : app.buttons["km/h"].firstMatch
        XCTAssertTrue(kmh.waitForExistence(timeout: GulfNavUITests.stepTimeout), "km/h choice shown")
        kmh.tap()
        waitForStatus(app, "speedUnit", "kilometersPerHour")
        // The About section is below the fold; rows off screen are not in the accessibility tree until scrolled.
        let attribution: XCUIElement = app.descendants(matching: .any).matching(identifier: "settings.attribution").firstMatch
        var swipes: Int = 0
        while !attribution.exists && swipes < 6 {
            app.swipeUp()
            swipes += 1
        }
        XCTAssertTrue(attribution.exists, "NOAA attribution shown (after \(swipes) swipes)")
        XCTAssertTrue(attribution.label.contains("NOAA"), attribution.label)
        attachScreenshot(app, "settings")
        app.buttons["settings.done"].tap()
        waitUntil(GulfNavUITests.stepTimeout, "speed in km/h, got '\(sog.label)'") { sog.label.hasSuffix(" km/h") }

        app.terminate()
        let relaunched: XCUIApplication = GulfNavUITests.makeApp(root: root, reset: false)
        relaunched.launch()
        let sogAgain: XCUIElement = relaunched.staticTexts["instrument.sog"]
        XCTAssertTrue(sogAgain.waitForExistence(timeout: GulfNavUITests.launchTimeout))
        waitUntil(GulfNavUITests.stepTimeout, "km/h after relaunch, got '\(sogAgain.label)'") { sogAgain.label.hasSuffix(" km/h") }
        attachScreenshot(relaunched, "settings-relaunched")
    }

    // MARK: Helpers

    @MainActor
    static func chartMap(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "chart-map").firstMatch
    }

    @MainActor
    static func appStatusValue(_ app: XCUIApplication) -> String {
        value(of: app.descendants(matching: .any).matching(identifier: "app.status").firstMatch)
    }

    /// One `key=value` field of `app.status`, or nil.
    @MainActor
    static func statusField(_ app: XCUIApplication, _ key: String) -> String? {
        let status: String = appStatusValue(app)
        for part in status.components(separatedBy: "; ") {
            guard let equals = part.firstIndex(of: "=") else { continue }
            if String(part[..<equals]) == key {
                return String(part[part.index(after: equals)...])
            }
        }
        return nil
    }

    /// `name:N` from `map.status`'s overlayFeatures, or -1.
    @MainActor
    static func overlayCount(_ app: XCUIApplication, _ name: String) -> Int {
        let status: String = value(of: mapStatus(app))
        guard let range = status.range(of: name + ":") else { return -1 }
        let digits: String = String(status[range.upperBound...].prefix(while: { $0.isNumber }))
        return Int(digits) ?? -1
    }

    @MainActor
    func waitForStatus(_ app: XCUIApplication, _ key: String, _ expected: String,
                       timeout: TimeInterval = GulfNavUITests.stepTimeout) {
        waitUntil(timeout, "app.status \(key)=\(expected), status: \(GulfNavUITests.appStatusValue(app))") {
            GulfNavUITests.statusField(app, key) == expected
        }
    }

    @MainActor
    func waitForOverlay(_ app: XCUIApplication, _ name: String, atLeast minimum: Int) {
        waitUntil(GulfNavUITests.stepTimeout, "overlay \(name) >= \(minimum), map.status: \(GulfNavUITests.value(of: GulfNavUITests.mapStatus(app)))") {
            GulfNavUITests.overlayCount(app, name) >= minimum
        }
    }

    @MainActor
    func waitForOverlay(_ app: XCUIApplication, _ name: String, equals expected: Int) {
        waitUntil(GulfNavUITests.stepTimeout, "overlay \(name) == \(expected), map.status: \(GulfNavUITests.value(of: GulfNavUITests.mapStatus(app)))") {
            GulfNavUITests.overlayCount(app, name) == expected
        }
    }

    /// Waits until the simulated GPS has delivered a position.
    @MainActor
    func waitForFix(_ app: XCUIApplication) {
        let latitude: XCUIElement = app.staticTexts["instrument.latitude"]
        waitUntil(GulfNavUITests.stepTimeout, "a position, got '\(latitude.label)'") {
            GulfNavUITests.matches(latitude.label, GulfNavUITests.latitudePattern)
        }
    }

    /// Debug menu > Import sample GPX, then waits for the import plan.
    @MainActor
    func importSampleGPX(_ app: XCUIApplication) {
        let menu: XCUIElement = app.buttons["map.debugMenu"]
        XCTAssertTrue(menu.waitForExistence(timeout: GulfNavUITests.stepTimeout))
        menu.tap()
        let item: XCUIElement = app.buttons["Import sample GPX"].firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: GulfNavUITests.stepTimeout), "debug menu item")
        item.tap()
        XCTAssertTrue(app.staticTexts["gpx.summary"].waitForExistence(timeout: GulfNavUITests.stepTimeout), "import plan shown")
    }

    @MainActor
    func replaceText(in field: XCUIElement, with text: String) {
        field.tap()
        let current: String = (field.value as? String) ?? ""
        if !current.isEmpty {
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count + 2))
        }
        field.typeText(text)
    }

    /// Taps a confirmation dialog's button by identifier, falling back to its label.
    @MainActor
    func tapConfirmation(_ app: XCUIApplication, identifier: String, label: String) {
        // A confirmation dialog can expose its button more than once in the accessibility tree,
        // so never use a query that requires a single match here.
        let matches: XCUIElementQuery = app.buttons.matching(identifier: identifier)
        let first: XCUIElement = matches.firstMatch
        if first.waitForExistence(timeout: 5) {
            let count: Int = matches.count
            var index: Int = 0
            while index < count {
                let candidate: XCUIElement = matches.element(boundBy: index)
                if candidate.isHittable {
                    candidate.tap()
                    return
                }
                index += 1
            }
            first.tap()
            return
        }
        let byLabel: XCUIElement = app.buttons.matching(NSPredicate(format: "label == %@", label)).firstMatch
        XCTAssertTrue(byLabel.waitForExistence(timeout: GulfNavUITests.stepTimeout), "confirmation button \(label)")
        byLabel.tap()
    }
}
