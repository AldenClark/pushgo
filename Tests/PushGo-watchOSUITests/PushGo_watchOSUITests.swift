import XCTest

@MainActor
final class PushGo_watchOSUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    override func tearDown() async throws {
        let app = XCUIApplication()
        if app.state != .notRunning {
            app.terminate()
        }
    }

    func testCoreWatchJourneyShowsAccurateObjectsDeletesOneAndPersistsAfterRelaunch() throws {
        let app = XCUIApplication()
        let sessionID = UUID().uuidString
        configureHermeticLaunch(app, sessionID: sessionID)
        app.launch()

        let gatewayMessage = app.buttons["row.message.quality-watch-message-001"]
        let databaseMessage = app.buttons["row.message.quality-watch-message-002"]
        XCTAssertTrue(gatewayMessage.waitForExistence(timeout: 10), startupFailureDescription(in: app))
        XCTAssertTrue(databaseMessage.exists)
        XCTAssertEqual(gatewayMessage.label, "Gateway health warning")
        XCTAssertEqual(
            gatewayMessage.value as? String,
            "Unread, Critical, Primary API latency is above budget."
        )
        XCTAssertTrue(gatewayMessage.isHittable)
        XCTAssertEqual(databaseMessage.label, "Database recovered")
        XCTAssertEqual(
            databaseMessage.value as? String,
            "Unread, Normal, Replica lag returned to normal."
        )

        gatewayMessage.tap()
        XCTAssertTrue(app.staticTexts["Primary API latency is above budget."].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Critical"].exists)
        let messageImage = app.descendants(matching: .any)["image.message.quality-watch-message-001"]
        XCTAssertTrue(scrollToExistingElement(messageImage, in: app, maximumSwipes: 2))
        XCTAssertEqual(messageImage.label, "Image")
        XCTAssertGreaterThan(messageImage.frame.width, 0)
        XCTAssertGreaterThan(messageImage.frame.height, 0)
        let openLink = app.links["action.message.open_link"]
        XCTAssertTrue(scrollToElement(openLink, in: app, maximumSwipes: 3))
        XCTAssertEqual(openLink.label, "Open link")
        XCTAssertTrue(openLink.isHittable)

        let deleteButton = app.buttons["Delete"]
        XCTAssertTrue(scrollToElement(deleteButton, in: app, maximumSwipes: 3))
        deleteButton.tap()
        let cancelButton = app.buttons["Cancel"]
        XCTAssertTrue(cancelButton.waitForExistence(timeout: 5))
        cancelButton.tap()
        XCTAssertTrue(app.descendants(matching: .any)["screen.message.detail"].exists)
        XCTAssertTrue(deleteButton.isHittable)

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
        XCTAssertTrue(
            waitUntil(timeout: 5) {
                databaseMessage.value as? String == "Read, Normal, Replica lag returned to normal."
            }
        )

        app.terminate()
        configureHermeticLaunch(app, sessionID: sessionID)
        app.launch()
        XCTAssertTrue(databaseMessage.waitForExistence(timeout: 10), startupFailureDescription(in: app))
        XCTAssertFalse(gatewayMessage.exists)
        XCTAssertEqual(
            databaseMessage.value as? String,
            "Read, Normal, Replica lag returned to normal."
        )

        let event = app.buttons["row.event.quality-watch-event-001"]
        XCTAssertTrue(swipeLeft(to: event, in: app))
        XCTAssertEqual(event.label, "Payments incident")
        XCTAssertEqual(event.value as? String, "ONGOING, High, Checkout errors exceeded threshold.")
        XCTAssertTrue(event.isHittable)
        event.tap()
        XCTAssertTrue(app.descendants(matching: .any)["screen.event.detail"].waitForExistence(timeout: 5))
        XCTAssertTrue(scrollToElement(app.staticTexts["Checkout errors exceeded threshold."], in: app, maximumSwipes: 2))
        XCTAssertTrue(app.staticTexts["ONGOING"].exists)
        let eventImage = app.buttons["image.event.quality-watch-event-001"]
        XCTAssertTrue(scrollToElement(eventImage, in: app, maximumSwipes: 2))
        eventImage.tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["image.event.preview"].waitForExistence(timeout: 5)
        )
        XCTAssertEqual(app.descendants(matching: .any)["image.event.preview"].label, "Image")
        app.swipeDown()
        XCTAssertTrue(app.descendants(matching: .any)["screen.event.detail"].waitForExistence(timeout: 5))

        pressBack(in: app)
        let thing = app.buttons["row.thing.quality-watch-thing-001"]
        XCTAssertTrue(swipeLeft(to: thing, in: app))
        XCTAssertEqual(thing.label, "Checkout API")
        XCTAssertEqual(thing.value as? String, "Degraded in eu-west.")
        XCTAssertTrue(thing.isHittable)
        let thingRowImage = app.descendants(matching: .any)["image.thing.row.quality-watch-thing-001"]
        XCTAssertTrue(thingRowImage.exists)
        XCTAssertEqual(thingRowImage.label, "Image")
        thing.tap()
        XCTAssertTrue(app.descendants(matching: .any)["screen.thing.detail"].waitForExistence(timeout: 5))
        let thingDetailImage = app.descendants(matching: .any)["image.thing.detail.quality-watch-thing-001"]
        XCTAssertTrue(thingDetailImage.waitForExistence(timeout: 5))
        XCTAssertEqual(thingDetailImage.label, "Image")
        XCTAssertTrue(app.staticTexts["Degraded in eu-west."].waitForExistence(timeout: 5))
        XCTAssertTrue(scrollToElement(app.staticTexts["eu-west"], in: app, maximumSwipes: 2))
        XCTAssertTrue(app.staticTexts["region"].exists)
        XCTAssertTrue(scrollToElement(app.staticTexts["version"], in: app, maximumSwipes: 2))
        XCTAssertTrue(app.staticTexts["42"].exists)

        pressBack(in: app)
        let receiverTitle = app.staticTexts["Receiver"]
        XCTAssertTrue(
            swipeLeft(to: receiverTitle, in: app),
            "The Receiver page must remain reachable after the three canonical data pages."
        )
        let needsSyncState = app.staticTexts["Needs sync"]
        XCTAssertTrue(
            needsSyncState.waitForExistence(timeout: 5),
            "A data-only hermetic launch must not claim that the unprovisioned receiver is ready."
        )
        XCTAssertFalse(app.staticTexts["Ready"].exists)
        XCTAssertTrue(app.staticTexts["Direct receive"].exists)
        XCTAssertTrue(
            scrollToElement(
                app.staticTexts["Apple Watch stores PushGo deliveries from direct notifications and pull refreshes."],
                in: app,
                maximumSwipes: 1
            )
        )
        XCTAssertTrue(
            scrollToElement(
                app.staticTexts["If the watch has no cellular service and is away from iPhone and Wi-Fi, messages arrive after it reconnects."],
                in: app,
                maximumSwipes: 2
            )
        )
        XCTAssertTrue(app.staticTexts["Offline behavior"].exists)
        XCTAssertTrue(
            scrollToElement(
                app.staticTexts["Keep iPhone nearby when refreshing receiver credentials and subscriptions."],
                in: app,
                maximumSwipes: 2
            )
        )
        XCTAssertTrue(app.staticTexts["iPhone sync"].exists)
    }

    func testLegacyWatchStoreMigratesAccurateMessageAndKeepsNewDataAcrossRelaunch() {
        let app = XCUIApplication()
        let sessionID = UUID().uuidString
        configureHermeticLaunch(app, sessionID: sessionID, scenario: "watch.migration")
        app.launch()

        let legacyMessage = app.staticTexts["Legacy watch alert"]
        XCTAssertTrue(legacyMessage.waitForExistence(timeout: 10), startupFailureDescription(in: app))
        XCTAssertTrue(app.staticTexts["Gateway health warning"].exists)
        legacyMessage.tap()
        XCTAssertTrue(app.staticTexts["Persisted before the upgrade."].waitForExistence(timeout: 5))

        app.terminate()
        configureHermeticLaunch(app, sessionID: sessionID, scenario: "watch.migration")
        app.launch()
        XCTAssertTrue(legacyMessage.waitForExistence(timeout: 10), startupFailureDescription(in: app))
        XCTAssertTrue(app.staticTexts["Gateway health warning"].exists)
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

    func testGatewayRouteCleanupRecoversAfterRelaunchAndNeverReusesRetiredKey() {
        let app = XCUIApplication()
        let sessionID = UUID().uuidString
        configureHermeticLaunch(app, sessionID: sessionID, scenario: "watch.gateway-cleanup-seed")
        app.launch()
        XCTAssertTrue(
            app.staticTexts["Gateway cleanup seed passed"].waitForExistence(timeout: 15),
            startupFailureDescription(in: app)
        )

        app.terminate()
        configureHermeticLaunch(app, sessionID: sessionID, scenario: "watch.gateway-cleanup-recover")
        app.launch()
        XCTAssertTrue(
            app.staticTexts["Gateway cleanup recovery passed"].waitForExistence(timeout: 15),
            startupFailureDescription(in: app)
        )
    }

    func testInterruptedPhoneProvisioningBlocksMixedCredentialsUntilReplay() {
        let app = XCUIApplication()
        let sessionID = UUID().uuidString
        configureHermeticLaunch(app, sessionID: sessionID, scenario: "watch.provisioning-interrupted-seed")
        app.launch()
        XCTAssertTrue(
            app.staticTexts["Provisioning interruption seed passed"].waitForExistence(timeout: 15),
            startupFailureDescription(in: app)
        )

        app.terminate()
        configureHermeticLaunch(app, sessionID: sessionID, scenario: "watch.provisioning-interrupted-recover")
        app.launch()
        XCTAssertTrue(
            app.staticTexts["Provisioning interruption recovery passed"].waitForExistence(timeout: 15),
            startupFailureDescription(in: app)
        )
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
        to destination: XCUIElement,
        in app: XCUIApplication,
        maximumAttempts: Int = 2
    ) -> Bool {
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
        if element.exists, element.isHittable { return true }
        for _ in 0..<maximumSwipes {
            app.swipeUp()
            if element.waitForExistence(timeout: 1), element.isHittable {
                return true
            }
        }
        return false
    }

    private func scrollToExistingElement(
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
