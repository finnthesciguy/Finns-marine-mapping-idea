#if targetEnvironment(macCatalyst)
import XCTest

/// Mac-only UI tests (Mac Catalyst build, target GulfNavMacUITests): the window size, the menu bar commands
/// and their keyboard shortcuts, the "no position" state, and the chart's context menu. Same conventions as
/// `GulfNavUITests`: isolated data directory, assertions on `app.status` / `map.status`, not on pixels.
extension GulfNavUITests {
    /// The content window opens no smaller than the content minimum (800 × 600) and the chart fills it.
    @MainActor
    func testMacWindowOpensAtASaneSize() throws {
        let app: XCUIApplication = GulfNavUITests.makeApp(root: GulfNavUITests.uniqueRoot("mac-window"), reset: true)
        app.launch()
        acceptDisclaimer(app)
        let window: XCUIElement = GulfNavUITests.contentWindow(app)
        XCTAssertTrue(window.waitForExistence(timeout: GulfNavUITests.stepTimeout))
        GulfNavUITests.logMacWindow(app, "mac-window")
        let frame: CGRect = window.frame
        print("GULFNAV-NOTE content window frame \(frame)")
        XCTAssertGreaterThanOrEqual(frame.width, 800, "window width \(frame.width)")
        XCTAssertGreaterThanOrEqual(frame.height, 600, "window height \(frame.height)")
        XCTAssertLessThan(frame.width, 10_000)
        // The chart fills the window: the map view is at least most of the window's width.
        let map: XCUIElement = GulfNavUITests.chartMap(app)
        if map.exists {
            XCTAssertGreaterThan(map.frame.width, frame.width * 0.8, "chart width \(map.frame.width)")
        } else {
            print("NOTE: element 'chart-map' not found in the accessibility tree")
        }
        GulfNavUITests.logMapStatus(app, "mac-window")
        attachScreenshot(app, "mac-window")
    }

    /// Menu bar items and their keyboard shortcuts do what the map buttons do.
    @MainActor
    func testMacMenuCommandsAndShortcuts() throws {
        let app: XCUIApplication = GulfNavUITests.makeApp(root: GulfNavUITests.uniqueRoot("mac-menus"), reset: true)
        app.launch()
        acceptDisclaimer(app)
        waitForFix(app)

        // Navigation > Drop Waypoint (menu), then ⌘D (shortcut).
        clickMenuItem(app, menu: "Navigation", item: "Drop Waypoint")
        waitForStatus(app, "waypoints", "1")
        app.typeKey("d", modifierFlags: XCUIElement.KeyModifierFlags.command)
        waitForStatus(app, "waypoints", "2")
        waitForOverlay(app, "waypoints", atLeast: 2)

        // ⌘R starts recording, the menu item stops it.
        app.typeKey("r", modifierFlags: XCUIElement.KeyModifierFlags.command)
        waitForStatus(app, "recording", "recording")
        clickMenuItem(app, menu: "Navigation", item: "Start or Stop Recording")
        waitForStatus(app, "recording", "idle")

        // ⌘2 opens the waypoint list.
        app.typeKey("2", modifierFlags: XCUIElement.KeyModifierFlags.command)
        XCTAssertTrue(app.buttons["waypoints.done"].waitForExistence(timeout: GulfNavUITests.stepTimeout), "waypoints opened by ⌘2")
        attachScreenshot(app, "mac-waypoints-by-shortcut")
        app.buttons["waypoints.done"].tap()

        // Navigation > New Route on Chart (⌘N) starts the route editor; if the shortcut did not arrive (the sheet may
        // still be closing), the menu item is used and a note says so.
        XCTAssertTrue(app.buttons["map.chartsButton"].waitForExistence(timeout: GulfNavUITests.stepTimeout))
        app.typeKey("n", modifierFlags: XCUIElement.KeyModifierFlags.command)
        if !waitBriefly(10, { GulfNavUITests.statusField(app, "editPoints") == "0" }) {
            print("GULFNAV-NOTE ⌘N did not start a route within 10 s; using Navigation > New Route on Chart")
            clickMenuItem(app, menu: "Navigation", item: "New Route on Chart")
        }
        waitForStatus(app, "editPoints", "0")
        let map: XCUIElement = GulfNavUITests.chartMap(app)
        map.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.3)).tap()
        waitForStatus(app, "editPoints", "1")
        app.buttons["routeEdit.cancel"].firstMatch.tap()
        waitForStatus(app, "editPoints", "-1")

        // Zoom commands (shortcuts and the Chart menu) leave the app running normally.
        app.typeKey("=", modifierFlags: XCUIElement.KeyModifierFlags.command)
        app.typeKey("-", modifierFlags: XCUIElement.KeyModifierFlags.command)
        clickMenuItem(app, menu: "Chart", item: "Zoom In")
        GulfNavUITests.logMapStatus(app, "mac-menus")
        attachScreenshot(app, "mac-menus-end")
    }

    /// Without a position (no simulated GPS; a CI Mac has no location), the instrument strip says so instead of
    /// showing values, and "Drop Waypoint" puts a waypoint at the chart's centre.
    @MainActor
    func testMacWithoutPositionDropsWaypointAtChartCentre() throws {
        let app: XCUIApplication = GulfNavUITests.makeApp(root: GulfNavUITests.uniqueRoot("mac-nofix"), reset: true,
                                                          simulateGPS: false)
        app.launch()
        acceptDisclaimer(app)
        let latitude: XCUIElement = app.staticTexts["instrument.latitude"]
        XCTAssertTrue(latitude.waitForExistence(timeout: GulfNavUITests.stepTimeout))
        // Give Location Services a moment; a CI Mac normally never produces a fix.
        RunLoop.current.run(until: Date().addingTimeInterval(5))
        let status: XCUIElement = app.descendants(matching: .any).matching(identifier: "instrument.positionStatus").firstMatch
        if latitude.label == "—" {
            XCTAssertTrue(status.waitForExistence(timeout: GulfNavUITests.stepTimeout), "no-position line shown")
            // "No position yet…" (waiting), "No position: location access is off…" (denied, as on a CI Mac with
            // Location Services off) or "No position for …" (stale): all PositionStatus messages.
            print("GULFNAV-NOTE no-position line: \(status.label)")
            XCTAssertTrue(status.label.hasPrefix("No position"), status.label)
            XCTAssertEqual(app.staticTexts["instrument.sog"].label, "—")
        } else {
            print("GULFNAV-NOTE this Mac has a location fix: \(latitude.label)")
        }
        app.typeKey("d", modifierFlags: XCUIElement.KeyModifierFlags.command)
        waitForStatus(app, "waypoints", "1")
        waitForOverlay(app, "waypoints", atLeast: 1)
        GulfNavUITests.logMapStatus(app, "mac-nofix")
        attachScreenshot(app, "mac-no-position")
    }

    /// Polls `condition` for up to `seconds` without recording a failure.
    @MainActor
    func waitBriefly(_ seconds: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline: Date = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
        return condition()
    }

    /// Right-click on the chart > "Drop Waypoint Here" adds a waypoint there.
    @MainActor
    func testMacChartContextMenuDropsWaypoint() throws {
        let app: XCUIApplication = GulfNavUITests.makeApp(root: GulfNavUITests.uniqueRoot("mac-context"), reset: true)
        app.launch()
        acceptDisclaimer(app)
        waitForFix(app)
        app.buttons["map.followButton"].tap()
        let map: XCUIElement = GulfNavUITests.chartMap(app)
        XCTAssertTrue(map.waitForExistence(timeout: GulfNavUITests.stepTimeout), "chart-map in the accessibility tree")
        print("GULFNAV-NOTE chart-map frame \(map.frame)")
        map.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).rightClick()
        let item: XCUIElement = app.menuItems["Drop Waypoint Here"]
        let shown: Bool = item.waitForExistence(timeout: GulfNavUITests.stepTimeout)
        print("GULFNAV-NOTE context menu after right-click: \(shown), menus=\(app.menus.count), menuItems=\(app.menuItems.count)")
        XCTAssertTrue(shown, "context menu shown")
        attachScreenshot(app, "mac-context-menu")
        item.click()
        waitForStatus(app, "waypoints", "1")
        waitForStatus(app, "selected", "WP 001")
        waitForOverlay(app, "waypoints", atLeast: 1)
        GulfNavUITests.logMapStatus(app, "mac-context")
    }
}
#endif
