import XCTest

/// End-to-end checks of the running app in the simulator. Every test launches the app on its own isolated
/// data directory (`GULFNAV_DATA_ROOT`, wiped with `GULFNAV_RESET_DATA`), with the simulated GPS track
/// (`GULFNAV_SIMULATE_GPS`, so CoreLocation never asks for permission) and, where needed, the bundled 16 KB
/// test chart installed offline (`GULFNAV_PREINSTALL_FIXTURE_CHART`). Nothing here uses the network.
///
/// Each test attaches named screenshots, the last one at its end; on failure the test action also captures
/// screenshots automatically (scheme setting). Elements are found by accessibility identifier; the map's state is read from the debug-only
/// `map.status` element (`style=loaded; chartLayers=N; ...` plus which MapLibre delegate callbacks fired,
/// see `AppServices.MapDiagnostics`) rather than from pixels. Each read is also printed as a
/// `GULFNAV-MAP-STATUS` line, which CI's summary picks up.
final class GulfNavUITests: XCTestCase {
    /// Generous: the first launch of a freshly booted CI simulator can take a long time.
    static let launchTimeout: TimeInterval = 120
    static let stepTimeout: TimeInterval = 45

    static let latitudePattern = "^[0-9]{2}°[0-9]{2}\\.[0-9]{3}'[NS]$"
    static let longitudePattern = "^[0-9]{3}°[0-9]{2}\\.[0-9]{3}'[EW]$"
    static let speedPattern = "^[0-9]+\\.[0-9] kn$"
    static let coursePattern = "^[0-9]{3}°T$"
    static let fixtureRegionID = "uitest-fixture"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: Tests

    /// (a) The disclaimer is shown on first launch and nothing else is reachable until it is accepted;
    /// after accepting and relaunching it is not shown again.
    @MainActor
    func testDisclaimerGatesTheAppAndIsRememberedAfterRelaunch() throws {
        let root: String = GulfNavUITests.uniqueRoot("disclaimer")
        let app: XCUIApplication = GulfNavUITests.makeApp(root: root, reset: true)
        app.launch()

        let accept: XCUIElement = app.buttons["disclaimer.accept"]
        XCTAssertTrue(accept.waitForExistence(timeout: GulfNavUITests.launchTimeout), "disclaimer shown on first launch")
        XCTAssertTrue(app.staticTexts["disclaimer.title"].exists)
        XCTAssertFalse(app.buttons["map.chartsButton"].exists, "map controls must not be reachable before accepting")
        XCTAssertFalse(GulfNavUITests.mapStatus(app).exists, "the map must not be shown before accepting")
        // Trying to get past it without accepting does nothing.
        app.swipeDown()
        app.swipeUp()
        XCTAssertTrue(accept.exists)
        XCTAssertFalse(app.buttons["map.chartsButton"].exists)
        attachScreenshot(app, "disclaimer")

        accept.tap()
        XCTAssertTrue(app.buttons["map.chartsButton"].waitForExistence(timeout: GulfNavUITests.stepTimeout),
                      "map screen after accepting")
        XCTAssertFalse(accept.exists)
        attachScreenshot(app, "after-accept")

        app.terminate()
        let relaunched: XCUIApplication = GulfNavUITests.makeApp(root: root, reset: false)
        relaunched.launch()
        XCTAssertTrue(relaunched.buttons["map.chartsButton"].waitForExistence(timeout: GulfNavUITests.launchTimeout),
                      "map screen straight away after relaunch")
        XCTAssertFalse(relaunched.buttons["disclaimer.accept"].exists, "disclaimer not shown again")
        attachScreenshot(relaunched, "relaunched")
    }

    /// (b) The map screen and map view appear and, with simulated GPS, the instrument strip shows speed,
    /// course and a position in degrees and decimal minutes.
    @MainActor
    func testMapShowsInstrumentsFromSimulatedGPS() throws {
        let app: XCUIApplication = GulfNavUITests.makeApp(root: GulfNavUITests.uniqueRoot("instruments"), reset: true)
        app.launch()
        acceptDisclaimer(app)

        let status: XCUIElement = GulfNavUITests.mapStatus(app)
        XCTAssertTrue(status.waitForExistence(timeout: GulfNavUITests.stepTimeout), "map status element present")
        waitUntil(GulfNavUITests.stepTimeout, "map style loaded, status: \(GulfNavUITests.value(of: status))") {
            GulfNavUITests.value(of: status).contains("style=loaded")
        }
        GulfNavUITests.logMapStatus(app, "instruments")
        let mapView: XCUIElement = app.descendants(matching: .any).matching(identifier: "chart-map").firstMatch
        if !mapView.exists {
            // Informational only: MapLibre's view is its own accessibility container, so whether its
            // identifier surfaces is up to MapLibre. The loaded style above proves the view is running.
            print("NOTE: element 'chart-map' not found in the accessibility tree")
        }

        let sog: XCUIElement = app.staticTexts["instrument.sog"]
        let cog: XCUIElement = app.staticTexts["instrument.cog"]
        let latitude: XCUIElement = app.staticTexts["instrument.latitude"]
        let longitude: XCUIElement = app.staticTexts["instrument.longitude"]
        XCTAssertTrue(sog.waitForExistence(timeout: GulfNavUITests.stepTimeout))
        waitUntil(GulfNavUITests.stepTimeout, "speed shown, got '\(sog.label)'") {
            GulfNavUITests.matches(sog.label, GulfNavUITests.speedPattern)
        }
        waitUntil(GulfNavUITests.stepTimeout, "course shown, got '\(cog.label)'") {
            GulfNavUITests.matches(cog.label, GulfNavUITests.coursePattern)
        }
        waitUntil(GulfNavUITests.stepTimeout, "latitude in DDM, got '\(latitude.label)'") {
            GulfNavUITests.matches(latitude.label, GulfNavUITests.latitudePattern)
        }
        XCTAssertTrue(GulfNavUITests.matches(longitude.label, GulfNavUITests.longitudePattern),
                      "longitude in DDM, got '\(longitude.label)'")
        // The simulated run is in Tampa Bay.
        XCTAssertTrue(latitude.label.hasPrefix("27°"), latitude.label)
        XCTAssertTrue(longitude.label.hasPrefix("082°") && longitude.label.hasSuffix("W"), longitude.label)
        attachScreenshot(app, "instruments")
    }

    /// (c) With the test chart pre-installed, the charts screen lists it as installed with its data date and
    /// the map has a chart layer in its style.
    @MainActor
    func testPreinstalledChartIsListedAndDrawn() throws {
        let app: XCUIApplication = GulfNavUITests.makeApp(root: GulfNavUITests.uniqueRoot("charts"), reset: true,
                                                          fixtureChart: true)
        app.launch()
        acceptDisclaimer(app)

        let status: XCUIElement = GulfNavUITests.mapStatus(app)
        XCTAssertTrue(status.waitForExistence(timeout: GulfNavUITests.stepTimeout))
        waitUntil(GulfNavUITests.stepTimeout, "a chart layer applied, status: \(GulfNavUITests.value(of: status))") {
            GulfNavUITests.chartLayerCount(GulfNavUITests.value(of: status)) >= 1
        }
        GulfNavUITests.logMapStatus(app, "charts")
        XCTAssertFalse(app.buttons["map.noChartsBanner"].exists, "no 'no charts' banner once a chart is installed")
        attachScreenshot(app, "map-with-chart")

        app.buttons["map.chartsButton"].tap()
        let rowStatus: XCUIElement = app.staticTexts["region.status.\(GulfNavUITests.fixtureRegionID)"]
        XCTAssertTrue(rowStatus.waitForExistence(timeout: GulfNavUITests.stepTimeout), "fixture region row listed")
        waitUntil(GulfNavUITests.stepTimeout, "fixture installed, got '\(rowStatus.label)'") {
            rowStatus.label == "Installed"
        }
        let dataDate: XCUIElement = app.staticTexts["region.dataDate.\(GulfNavUITests.fixtureRegionID)"]
        XCTAssertTrue(dataDate.exists)
        XCTAssertEqual(dataDate.label, "Data 28 May 2024")
        attachScreenshot(app, "charts-screen")

        app.buttons["charts.done"].tap()
        XCTAssertTrue(app.buttons["map.chartsButton"].waitForExistence(timeout: GulfNavUITests.stepTimeout))
    }

    // MARK: Helpers

    static func uniqueRoot(_ prefix: String) -> String {
        prefix + "-" + String(UUID().uuidString.prefix(8))
    }

    /// The app most recently created by `makeApp`, for status logging on timeouts.
    @MainActor static var lastApp: XCUIApplication?

    @MainActor
    var currentApp: XCUIApplication? { GulfNavUITests.lastApp }

    @MainActor
    static func makeApp(root: String, reset: Bool, simulateGPS: Bool = true, fixtureChart: Bool = false,
                        speedKnots: Int? = nil, trackBatchSize: Int? = nil, routingFixture: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        var environment: [String: String] = ["GULFNAV_DATA_ROOT": root]
        if reset { environment["GULFNAV_RESET_DATA"] = "1" }
        if simulateGPS { environment["GULFNAV_SIMULATE_GPS"] = "1" }
        if fixtureChart { environment["GULFNAV_PREINSTALL_FIXTURE_CHART"] = "1" }
        if let speedKnots { environment["GULFNAV_SIM_SPEED_KNOTS"] = String(speedKnots) }
        if let trackBatchSize { environment["GULFNAV_TRACK_BATCH_SIZE"] = String(trackBatchSize) }
        if routingFixture { environment["GULFNAV_PREINSTALL_FIXTURE_ROUTING"] = "1" }
        app.launchEnvironment = environment
        lastApp = app
        return app
    }

    @MainActor
    static func mapStatus(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "map.status").firstMatch
    }

    @MainActor
    static func value(of element: XCUIElement) -> String {
        guard element.exists else { return "(missing)" }
        if let text = element.value as? String { return text }
        return "(no value)"
    }

    /// Prints the current `map.status` value on a line CI's summary collects.
    @MainActor
    static func logMapStatus(_ app: XCUIApplication, _ label: String) {
        print("GULFNAV-MAP-STATUS [\(label)] \(value(of: mapStatus(app)))")
        let appStatus: XCUIElement = app.descendants(matching: .any).matching(identifier: "app.status").firstMatch
        if appStatus.exists {
            print("GULFNAV-APP-STATUS [\(label)] \(value(of: appStatus))")
        }
    }

    /// N from `... chartLayers=N`, or -1.
    static func chartLayerCount(_ status: String) -> Int {
        guard let range = status.range(of: "chartLayers=") else { return -1 }
        let digits: String = String(status[range.upperBound...].prefix(while: { $0.isNumber }))
        return Int(digits) ?? -1
    }

    static func matches(_ text: String, _ pattern: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }

    @MainActor
    func acceptDisclaimer(_ app: XCUIApplication) {
        let accept: XCUIElement = app.buttons["disclaimer.accept"]
        XCTAssertTrue(accept.waitForExistence(timeout: GulfNavUITests.launchTimeout), "disclaimer shown on a clean start")
        accept.tap()
        XCTAssertTrue(app.buttons["map.chartsButton"].waitForExistence(timeout: GulfNavUITests.stepTimeout))
    }

    /// Polls `condition` every half second until it holds or `timeout` passes; on timeout records a failure
    /// with `message` (evaluated then, so it can show the last value seen).
    @MainActor
    @discardableResult
    func waitUntil(_ timeout: TimeInterval, _ message: @autoclosure () -> String, _ condition: () -> Bool) -> Bool {
        let deadline: Date = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
        if condition() { return true }
        if let app = currentApp {
            GulfNavUITests.logMapStatus(app, "timeout")
        }
        XCTFail("Timed out after \(Int(timeout)) s waiting for: \(message())")
        return false
    }

    @MainActor
    func attachScreenshot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
