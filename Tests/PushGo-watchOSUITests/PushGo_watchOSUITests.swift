import XCTest

@MainActor
final class PushGo_watchOSUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        MainActor.assumeIsolated {
            let app = XCUIApplication()
            if app.state != .notRunning {
                app.terminate()
            }
        }
    }

    func testCoreWatchJourneyShowsAccurateObjectsDeletesOneAndPersistsAfterRelaunch() throws {
        let app = XCUIApplication()
        let sessionID = UUID().uuidString
        configureHermeticLaunch(app, sessionID: sessionID)
        app.launch()

        let gatewayMessage = app.staticTexts["Gateway health warning"]
        let databaseMessage = app.staticTexts["Database recovered"]
        let databaseUnreadIndicator = app.descendants(matching: .any)[
            "indicator.message.unread.quality-watch-message-002"
        ]
        XCTAssertTrue(gatewayMessage.waitForExistence(timeout: 10), startupFailureDescription(in: app))
        XCTAssertTrue(databaseMessage.exists)
        XCTAssertTrue(databaseUnreadIndicator.exists)

        gatewayMessage.tap()
        XCTAssertTrue(app.staticTexts["Primary API latency is above budget."].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Critical"].exists)

        let deleteButton = app.buttons["Delete"]
        XCTAssertTrue(scrollToElement(deleteButton, in: app, maximumSwipes: 3))
        deleteButton.tap()
        let cancelButton = app.buttons["Cancel"]
        XCTAssertTrue(cancelButton.waitForExistence(timeout: 5))
        cancelButton.tap()
        XCTAssertTrue(app.staticTexts["Primary API latency is above budget."].exists)

        deleteButton.tap()
        let confirmDeleteButton = try XCTUnwrap(
            app.buttons.matching(identifier: "Delete").allElementsBoundByIndex.first(where: \.isHittable)
        )
        confirmDeleteButton.tap()
        XCTAssertTrue(waitUntil(timeout: 5) { !gatewayMessage.exists })
        XCTAssertTrue(databaseMessage.waitForExistence(timeout: 5))

        databaseMessage.tap()
        XCTAssertTrue(app.staticTexts["Replica lag returned to normal."].waitForExistence(timeout: 5))
        pressBack(in: app)
        XCTAssertTrue(databaseMessage.waitForExistence(timeout: 5))
        XCTAssertTrue(waitUntil(timeout: 5) { !databaseUnreadIndicator.exists })

        app.terminate()
        configureHermeticLaunch(app, sessionID: sessionID)
        app.launch()
        XCTAssertTrue(databaseMessage.waitForExistence(timeout: 10), startupFailureDescription(in: app))
        XCTAssertFalse(app.staticTexts["Gateway health warning"].exists)
        XCTAssertFalse(databaseUnreadIndicator.exists)

        XCTAssertTrue(swipeLeft(to: "screen.events.list", in: app))
        let event = app.staticTexts["Payments incident"]
        XCTAssertTrue(event.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Checkout errors exceeded threshold."].exists)
        event.tap()
        XCTAssertTrue(app.descendants(matching: .any)["screen.event.detail"].waitForExistence(timeout: 5))
        XCTAssertTrue(scrollToElement(app.staticTexts["Checkout errors exceeded threshold."], in: app, maximumSwipes: 2))
        XCTAssertTrue(app.staticTexts["ONGOING"].exists)

        pressBack(in: app)
        XCTAssertTrue(swipeLeft(to: "screen.things.list", in: app))
        let thing = app.staticTexts["Checkout API"]
        XCTAssertTrue(thing.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Degraded in eu-west."].exists)
        thing.tap()
        XCTAssertTrue(app.descendants(matching: .any)["screen.thing.detail"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Degraded in eu-west."].waitForExistence(timeout: 5))
        XCTAssertTrue(scrollToElement(app.staticTexts["eu-west"], in: app, maximumSwipes: 2))
        XCTAssertTrue(app.staticTexts["region"].exists)
        XCTAssertTrue(scrollToElement(app.staticTexts["version"], in: app, maximumSwipes: 2))
        XCTAssertTrue(app.staticTexts["42"].exists)
    }

    func testInvalidHermeticScenarioFailsReadinessExplicitly() {
        let app = XCUIApplication()
        configureHermeticLaunch(
            app,
            sessionID: UUID().uuidString,
            scenario: "watch.unsupported"
        )

        app.launch()

        XCTAssertTrue(
            app.descendants(matching: .any)["state.startup.failure"].waitForExistence(timeout: 10)
        )
        XCTAssertTrue(
            app.staticTexts["Unsupported hermetic watch quality scenario: watch.unsupported."].exists
        )
        XCTAssertFalse(app.staticTexts["Gateway health warning"].exists)
        XCTAssertFalse(app.staticTexts["Database recovered"].exists)
    }

    func testMessageReadFailureStaysOwnedByMessagesWhileOtherDomainsRemainUsable() {
        let app = XCUIApplication()
        configureHermeticLaunch(
            app,
            sessionID: UUID().uuidString,
            scenario: "watch.message-load-failure"
        )

        app.launch()

        XCTAssertTrue(
            app.descendants(matching: .any)["state.messages.error"].waitForExistence(timeout: 10),
            startupFailureDescription(in: app)
        )
        let retryButton = app.buttons["retry"]
        XCTAssertTrue(scrollToElement(retryButton, in: app, maximumSwipes: 2))
        XCTAssertFalse(app.staticTexts["Gateway health warning"].exists)
        retryButton.tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["state.messages.error"].waitForExistence(timeout: 5)
        )

        app.swipeLeft()
        XCTAssertTrue(app.staticTexts["Payments incident"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.descendants(matching: .any)["state.events.error"].exists)
        app.staticTexts["Payments incident"].tap()
        XCTAssertTrue(app.staticTexts["Checkout errors exceeded threshold."].waitForExistence(timeout: 5))

        pressBack(in: app)
        app.swipeLeft()
        XCTAssertTrue(app.staticTexts["Checkout API"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.descendants(matching: .any)["state.things.error"].exists)
        app.staticTexts["Checkout API"].tap()
        XCTAssertTrue(app.staticTexts["Degraded in eu-west."].waitForExistence(timeout: 5))
    }

    private func configureHermeticLaunch(
        _ app: XCUIApplication,
        sessionID: String,
        scenario: String = "watch.standard"
    ) {
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchEnvironment["PUSHGO_QUALITY_PROFILE"] = "hermetic"
        app.launchEnvironment["PUSHGO_QUALITY_SCENARIO"] = scenario
        app.launchEnvironment["PUSHGO_QUALITY_SESSION_ID"] = sessionID
    }

    private func pressBack(in app: XCUIApplication) {
        let backButton = app.navigationBars.buttons.firstMatch
        XCTAssertTrue(backButton.waitForExistence(timeout: 5))
        backButton.tap()
    }

    private func swipeLeft(
        to screenIdentifier: String,
        in app: XCUIApplication,
        maximumAttempts: Int = 2
    ) -> Bool {
        let destination = app.descendants(matching: .any)[screenIdentifier]
        if destination.exists, destination.isHittable { return true }

        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5))
        for _ in 0 ..< maximumAttempts {
            start.press(forDuration: 0.05, thenDragTo: end)
            if waitUntil(timeout: 2, condition: { destination.exists && destination.isHittable }) {
                return true
            }
        }
        return false
    }

    private func startupFailureDescription(in app: XCUIApplication) -> String {
        let failure = app.descendants(matching: .any)["state.startup.failure"]
        return failure.exists
            ? "The App-owned watch quality session failed during preparation: \(failure.debugDescription)"
            : "The expected watch content did not become visible."
    }

    private func waitUntil(timeout: TimeInterval, condition: @escaping () -> Bool) -> Bool {
        let predicate = NSPredicate { _, _ in condition() }
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: nil)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    private func scrollToElement(
        _ element: XCUIElement,
        in app: XCUIApplication,
        maximumSwipes: Int
    ) -> Bool {
        if element.exists { return true }
        for _ in 0..<maximumSwipes {
            app.swipeUp()
            if element.waitForExistence(timeout: 1) {
                return true
            }
        }
        return false
    }
}
