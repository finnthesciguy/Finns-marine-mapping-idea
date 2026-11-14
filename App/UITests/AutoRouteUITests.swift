import XCTest

/// Auto-routing (deliverable 3 of the auto-route piece). The app is launched with
/// `GULFNAV_PREINSTALL_FIXTURE_ROUTING=1`: the bundled `sarasota.pack` (216 KB, debug builds only) is
/// side-loaded, waypoints "RT Longboat", "RT Marina Jack" and "RT Roberts Bay" are added at points from
/// `testdata/routing/sarasota.vectors.json`, and the simulated GPS runs in Sarasota Bay. Expected results are
/// those of the vectors (and of the AppServices tests that reproduce them):
///
/// - RT Longboat → RT Marina Jack (q1): 28 legs, all green, 5.70 nm.
/// - RT Marina Jack → RT Roberts Bay with the default profile (q4): no route (DEPTH), one blocked place,
///   hint "use maintained channels"; with the hint applied (q3): 55 legs, 39 green, 16 yellow.
///
/// State is read from `app.status` (`notice`, `planState`, `planLegs`, `planGreen`, `planYellow`,
/// `planBlocked`, `planHints`, `planPack`, `routingPacks`, `planSaved`, `profiles`, `defaultProfile`) and the
/// map from `map.status`'s `overlayFeatures` (`plannedLegs`, `blocked`), not from pixels.
extension GulfNavUITests {
    static let planTimeout: TimeInterval = 90

    // MARK: (a) notice

    /// The auto-route notice gates planning and is remembered across a relaunch.
    @MainActor
    func testAutoRouteNoticeGatesPlanningAndIsRemembered() throws {
        let root: String = GulfNavUITests.uniqueRoot("arnotice")
        let app: XCUIApplication = GulfNavUITests.makeApp(root: root, reset: true, routingFixture: true)
        app.launch()
        acceptDisclaimer(app)
        waitForStatus(app, "routingPacks", "1")
        waitForStatus(app, "notice", "unknown")

        app.buttons["map.autoRouteButton"].tap()
        let accept: XCUIElement = app.buttons["autoroute.notice.accept"]
        XCTAssertTrue(accept.waitForExistence(timeout: GulfNavUITests.stepTimeout), "notice shown before the first plan")
        waitForStatus(app, "notice", "needed")
        XCTAssertFalse(GulfNavUITests.element(app, "autoroute.plan").exists, "no Plan button before the notice is acknowledged")
        XCTAssertTrue(app.staticTexts["autoroute.notice.title"].exists)
        attachScreenshot(app, "autoroute-notice")
        accept.tap()
        waitForStatus(app, "notice", "ok")
        XCTAssertTrue(GulfNavUITests.element(app, "autoroute.plan").waitForExistence(timeout: GulfNavUITests.stepTimeout),
                      "planner shown after acknowledging")
        app.buttons["autoroute.done"].tap()

        app.terminate()
        let relaunched: XCUIApplication = GulfNavUITests.makeApp(root: root, reset: false, routingFixture: true)
        relaunched.launch()
        XCTAssertTrue(relaunched.buttons["map.chartsButton"].waitForExistence(timeout: GulfNavUITests.launchTimeout))
        relaunched.buttons["map.autoRouteButton"].tap()
        XCTAssertTrue(GulfNavUITests.element(relaunched, "autoroute.plan").waitForExistence(timeout: GulfNavUITests.stepTimeout),
                      "planner straight away after relaunch")
        waitForStatus(relaunched, "notice", "ok")
        XCTAssertFalse(relaunched.buttons["autoroute.notice.accept"].exists, "notice not shown again")
        attachScreenshot(relaunched, "autoroute-notice-remembered")
    }

    // MARK: (b) success, save, Route check, follow

    @MainActor
    func testAutoRoutePlansSavesAndFollows() throws {
        let app: XCUIApplication = GulfNavUITests.makeApp(root: GulfNavUITests.uniqueRoot("arplan"), reset: true, routingFixture: true)
        app.launch()
        acceptDisclaimer(app)
        waitForStatus(app, "routingPacks", "1")
        waitForStatus(app, "waypoints", "3")
        openPlannerAcceptingNotice(app)
        addFirstBoatProfile(app)

        choose(app, end: "autoroute.start", waypoint: "RT Longboat")
        choose(app, end: "autoroute.goal", waypoint: "RT Marina Jack")
        waitForStatus(app, "planPack", "pilot-sarasota")
        let plan: XCUIElement = GulfNavUITests.element(app, "autoroute.plan")
        XCTAssertTrue(plan.waitForExistence(timeout: GulfNavUITests.stepTimeout))
        plan.tap()
        waitForStatus(app, "planState", "proposal", timeout: GulfNavUITests.planTimeout)
        XCTAssertEqual(GulfNavUITests.statusField(app, "planLegs"), "28")
        XCTAssertEqual(GulfNavUITests.statusField(app, "planGreen"), "28")
        XCTAssertEqual(GulfNavUITests.statusField(app, "planYellow"), "0")
        waitForOverlay(app, "plannedLegs", equals: 28)
        GulfNavUITests.logMapStatus(app, "autoroute-proposal")
        attachScreenshot(app, "autoroute-proposal")

        let save: XCUIElement = scrollTo(app, "autoroute.save")
        save.tap()
        waitForStatus(app, "planSaved", "RT Longboat to RT Marina Jack")
        waitForStatus(app, "routes", "1")
        waitForStatus(app, "planState", "idle")
        waitForOverlay(app, "plannedLegs", equals: 0)
        waitForOverlay(app, "routeLegs", equals: 28)
        app.buttons["autoroute.done"].tap()

        // In Routes, with its Route check summary.
        app.buttons["map.routesButton"].tap()
        let name: XCUIElement = app.staticTexts["route.name.0"]
        XCTAssertTrue(name.waitForExistence(timeout: GulfNavUITests.stepTimeout))
        XCTAssertEqual(name.label, "RT Longboat to RT Marina Jack")
        name.tap()
        let legs: XCUIElement = scrollTo(app, "route.check.legs")
        XCTAssertEqual(legs.label, "28 legs: 28 green, 0 yellow")
        XCTAssertEqual(GulfNavUITests.element(app, "route.check.distance").label, "5.70 nm")
        let data: XCUIElement = GulfNavUITests.element(app, "route.check.data")
        XCTAssertTrue(data.label.hasPrefix("23 Oct 2026 ("), data.label)
        attachScreenshot(app, "autoroute-route-check")

        // And followed.
        let follow: XCUIElement = scrollTo(app, "route.follow", downwards: true)
        follow.tap()
        waitForStatus(app, "nav", "route")
        GulfNavUITests.logMapStatus(app, "autoroute-follow")
        attachScreenshot(app, "autoroute-follow")
        app.buttons["guidance.stop"].tap()
        waitForStatus(app, "nav", "idle")
    }

    // MARK: (c) no route, blocked place, hint

    @MainActor
    func testAutoRouteNoRouteShowsBlockedPlaceAndHintPlans() throws {
        let app: XCUIApplication = GulfNavUITests.makeApp(root: GulfNavUITests.uniqueRoot("arnoroute"), reset: true, routingFixture: true)
        app.launch()
        acceptDisclaimer(app)
        waitForStatus(app, "routingPacks", "1")
        waitForStatus(app, "waypoints", "3")
        openPlannerAcceptingNotice(app)
        addFirstBoatProfile(app)

        choose(app, end: "autoroute.start", waypoint: "RT Marina Jack")
        choose(app, end: "autoroute.goal", waypoint: "RT Roberts Bay")
        GulfNavUITests.element(app, "autoroute.plan").tap()
        waitForStatus(app, "planState", "noRoute", timeout: GulfNavUITests.planTimeout)
        XCTAssertEqual(GulfNavUITests.statusField(app, "planBlocked"), "1")
        XCTAssertEqual(GulfNavUITests.statusField(app, "planHints"), "useMaintainedChannels")
        waitForOverlay(app, "blocked", equals: 1)
        let message: XCUIElement = GulfNavUITests.element(app, "autoroute.noRoute.message")
        XCTAssertTrue(message.waitForExistence(timeout: GulfNavUITests.stepTimeout))
        XCTAssertTrue(message.label.hasPrefix("No route for My boat: the water is too shallow"), message.label)
        GulfNavUITests.logMapStatus(app, "autoroute-noroute")
        attachScreenshot(app, "autoroute-noroute")

        let hint: XCUIElement = scrollTo(app, "autoroute.hint.useMaintainedChannels")
        hint.tap()
        waitForStatus(app, "planState", "proposal", timeout: GulfNavUITests.planTimeout)
        XCTAssertEqual(GulfNavUITests.statusField(app, "planLegs"), "55")
        XCTAssertEqual(GulfNavUITests.statusField(app, "planGreen"), "39")
        XCTAssertEqual(GulfNavUITests.statusField(app, "planYellow"), "16")
        waitForOverlay(app, "plannedLegs", equals: 55)
        waitForOverlay(app, "blocked", equals: 0)
        attachScreenshot(app, "autoroute-hint-applied")

        // Yellow legs: saving and following needs the explicit confirmation.
        let saveFollow: XCUIElement = scrollTo(app, "autoroute.saveFollow")
        saveFollow.tap()
        tapConfirmation(app, identifier: "autoroute.confirmCaution", label: "I have reviewed the yellow legs")
        waitForStatus(app, "planSaved", "RT Marina Jack to RT Roberts Bay")
        waitForStatus(app, "routes", "1")
        waitForStatus(app, "nav", "route")
        waitForOverlay(app, "routeLegs", equals: 55)
        GulfNavUITests.logMapStatus(app, "autoroute-hint-follow")
        attachScreenshot(app, "autoroute-hint-follow")
    }

    // MARK: (d) boat profiles

    @MainActor
    func testBoatProfilesAddEditDefaultAndDelete() throws {
        let root: String = GulfNavUITests.uniqueRoot("profiles")
        let app: XCUIApplication = GulfNavUITests.makeApp(root: root, reset: true)
        app.launch()
        acceptDisclaimer(app)
        waitForStatus(app, "profiles", "0")

        app.buttons["map.settingsButton"].tap()
        let link: XCUIElement = GulfNavUITests.element(app, "settings.boatProfiles")
        XCTAssertTrue(link.waitForExistence(timeout: GulfNavUITests.stepTimeout))
        link.tap()

        addProfile(app, name: "Alpha", draft: nil)
        waitForStatus(app, "profiles", "1")
        waitForStatus(app, "defaultProfile", "Alpha")
        addProfile(app, name: "Bravo", draft: "3")
        waitForStatus(app, "profiles", "2")
        XCTAssertEqual(GulfNavUITests.statusField(app, "defaultProfile"), "Alpha", "the first boat stays the default")
        let bravoDetail: XCUIElement = app.staticTexts["profile.detail.Bravo"]
        XCTAssertTrue(bravoDetail.waitForExistence(timeout: GulfNavUITests.stepTimeout))
        XCTAssertTrue(bravoDetail.label.hasPrefix("Draft 3.0 ft + 1.5 ft margin"), bravoDetail.label)
        attachScreenshot(app, "profiles-two")

        // Make Bravo the default.
        app.staticTexts["profile.name.Bravo"].tap()
        let makeDefault: XCUIElement = GulfNavUITests.element(app, "profile.makeDefault")
        XCTAssertTrue(makeDefault.waitForExistence(timeout: GulfNavUITests.stepTimeout))
        makeDefault.tap()
        waitForStatus(app, "defaultProfile", "Bravo")

        // Edit Alpha's draft.
        let alpha: XCUIElement = app.staticTexts["profile.name.Alpha"]
        XCTAssertTrue(alpha.waitForExistence(timeout: GulfNavUITests.stepTimeout))
        alpha.tap()
        let draft: XCUIElement = app.textFields["profile.edit.draft"]
        XCTAssertTrue(draft.waitForExistence(timeout: GulfNavUITests.stepTimeout))
        replaceText(in: draft, with: "5")
        app.buttons["profile.edit.save"].tap()
        let alphaDetail: XCUIElement = app.staticTexts["profile.detail.Alpha"]
        waitUntil(GulfNavUITests.stepTimeout, "Alpha's draft updated, got '\(alphaDetail.label)'") {
            alphaDetail.exists && alphaDetail.label.hasPrefix("Draft 5.0 ft")
        }

        // Delete Bravo (the default): the remaining boat becomes the default.
        app.staticTexts["profile.name.Bravo"].tap()
        let delete: XCUIElement = scrollTo(app, "profile.delete")
        delete.tap()
        tapConfirmation(app, identifier: "profile.confirmDelete", label: "Delete")
        waitForStatus(app, "profiles", "1")
        waitForStatus(app, "defaultProfile", "Alpha")
        attachScreenshot(app, "profiles-end")

        // Kept across a relaunch.
        app.terminate()
        let relaunched: XCUIApplication = GulfNavUITests.makeApp(root: root, reset: false)
        relaunched.launch()
        XCTAssertTrue(relaunched.buttons["map.chartsButton"].waitForExistence(timeout: GulfNavUITests.launchTimeout))
        waitForStatus(relaunched, "profiles", "1")
        waitForStatus(relaunched, "defaultProfile", "Alpha")
    }

    // MARK: Helpers

    /// Any element with this accessibility identifier (buttons, cells and texts alike).
    @MainActor
    static func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    /// Swipes the front list until the element exists and is hittable (rows off screen are not in the
    /// accessibility tree until scrolled to). Returns the element.
    @MainActor
    @discardableResult
    func scrollTo(_ app: XCUIApplication, _ identifier: String, downwards: Bool = false) -> XCUIElement {
        let target: XCUIElement = GulfNavUITests.element(app, identifier)
        if target.waitForExistence(timeout: 5) && target.isHittable { return target }
        var swipes: Int = 0
        while !(target.exists && target.isHittable) && swipes < 8 {
            if downwards { app.swipeDown() } else { app.swipeUp() }
            swipes += 1
        }
        XCTAssertTrue(target.exists, "\(identifier) found after \(swipes) swipes")
        return target
    }

    /// Opens the planner and acknowledges the auto-route notice.
    @MainActor
    func openPlannerAcceptingNotice(_ app: XCUIApplication) {
        app.buttons["map.autoRouteButton"].tap()
        let accept: XCUIElement = app.buttons["autoroute.notice.accept"]
        XCTAssertTrue(accept.waitForExistence(timeout: GulfNavUITests.stepTimeout), "auto-route notice")
        accept.tap()
        waitForStatus(app, "notice", "ok")
    }

    /// From the planner: the Boat row ("Add a boat profile"), then the default values (4.5 ft draft, 1.5 ft margin, 20 ft air
    /// draft, the profile of the vectors' queries), saved as "My boat" and used.
    @MainActor
    func addFirstBoatProfile(_ app: XCUIApplication) {
        let add: XCUIElement = GulfNavUITests.element(app, "autoroute.profile")
        XCTAssertTrue(add.waitForExistence(timeout: GulfNavUITests.stepTimeout))
        add.tap()
        let newProfile: XCUIElement = GulfNavUITests.element(app, "profiles.add")
        XCTAssertTrue(newProfile.waitForExistence(timeout: GulfNavUITests.stepTimeout))
        newProfile.tap()
        let save: XCUIElement = app.buttons["profile.edit.save"]
        XCTAssertTrue(save.waitForExistence(timeout: GulfNavUITests.stepTimeout))
        XCTAssertEqual(app.textFields["profile.edit.draft"].value as? String, "4.5")
        save.tap()
        waitForStatus(app, "profiles", "1")
        waitForStatus(app, "defaultProfile", "My boat")
        let use: XCUIElement = GulfNavUITests.element(app, "profile.use.My boat")
        XCTAssertTrue(use.waitForExistence(timeout: GulfNavUITests.stepTimeout))
        use.tap()
        XCTAssertTrue(GulfNavUITests.element(app, "autoroute.plan").waitForExistence(timeout: GulfNavUITests.stepTimeout),
                      "back in the planner with the boat chosen")
    }

    /// Chooses a waypoint for the start or destination row.
    @MainActor
    func choose(_ app: XCUIApplication, end: String, waypoint: String) {
        let row: XCUIElement = GulfNavUITests.element(app, end)
        XCTAssertTrue(row.waitForExistence(timeout: GulfNavUITests.stepTimeout), end)
        row.tap()
        let choice: XCUIElement = GulfNavUITests.element(app, "autoroute.choice.wp.\(waypoint)")
        XCTAssertTrue(choice.waitForExistence(timeout: GulfNavUITests.stepTimeout), "waypoint \(waypoint) offered")
        choice.tap()
        XCTAssertTrue(GulfNavUITests.element(app, "autoroute.plan").waitForExistence(timeout: GulfNavUITests.stepTimeout),
                      "back in the planner")
    }

    /// On the Boat profiles screen: add one (name, and optionally the draft in feet).
    @MainActor
    func addProfile(_ app: XCUIApplication, name: String, draft: String?) {
        let add: XCUIElement = GulfNavUITests.element(app, "profiles.add")
        XCTAssertTrue(add.waitForExistence(timeout: GulfNavUITests.stepTimeout))
        add.tap()
        let nameField: XCUIElement = app.textFields["profile.edit.name"]
        XCTAssertTrue(nameField.waitForExistence(timeout: GulfNavUITests.stepTimeout))
        replaceText(in: nameField, with: name)
        if let draft {
            replaceText(in: app.textFields["profile.edit.draft"], with: draft)
        }
        app.buttons["profile.edit.save"].tap()
        XCTAssertTrue(app.staticTexts["profile.name.\(name)"].waitForExistence(timeout: GulfNavUITests.stepTimeout),
                      "\(name) listed")
    }
}
