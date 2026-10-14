import XCTest

@MainActor
final class PushGo_watchOSUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    override func tearDown() async throws {
        let app = XCUIApplication()
        if (testRun?.failureCount ?? 0) > 0 {
            let hierarchy = XCTAttachment(string: app.debugDescription)
            hierarchy.name = "watch-failure-hierarchy"
            hierarchy.lifetime = .keepAlways
            add(hierarchy)
        }
        if app.state != .notRunning {
            app.terminate()
        }
    }

    func testWatchNotificationDeleteCancelPreservesUnreadContentAfterRelaunch() throws {
        let app = XCUIApplication()
        let sessionID = UUID().uuidString
        configureHermeticLaunch(app, sessionID: sessionID, scenario: "watch.notification-delete-confirmation")
        launchPreparedApp(app)
        let cancel = app.buttons["Cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 10), startupFailureDescription(in: app))
        cancel.tap()
        XCTAssertTrue(app.staticTexts["Primary API latency is above budget."].waitForExistence(timeout: 5))
        app.terminate()
        configureHermeticLaunch(app, sessionID: sessionID)
        launchPreparedApp(app)
        let row = app.buttons["row.message.quality-watch-message-001"]
        XCTAssertTrue(row.waitForExistence(timeout: 10), startupFailureDescription(in: app))
        XCTAssertEqual(row.label, "Gateway health warning")
        XCTAssertEqual(row.value as? String, "Unread, Critical, Primary API latency is above budget.")
        XCTAssertTrue(app.buttons["row.message.quality-watch-message-002"].exists)
    }

    func testWatchDeletionGuardsPreserveReplacementAndRejectStaleConfiguration() throws {
        let app = XCUIApplication()
        configureHermeticLaunch(app, sessionID: UUID().uuidString, scenario: "watch.delete-guards")
        launchPreparedApp(app)
        let row = app.buttons["row.message.quality-watch-message-001"]
        XCTAssertTrue(row.waitForExistence(timeout: 10), startupFailureDescription(in: app))
        XCTAssertEqual(row.label, "Gateway health warning")
        row.tap()
        XCTAssertTrue(app.staticTexts["Primary API latency is above budget."].waitForExistence(timeout: 5))
    }

    func testCoreWatchJourneyShowsAccurateObjectsDeletesOneAndPersistsAfterRelaunch() throws {
        let app = XCUIApplication()
        let sessionID = UUID().uuidString
        configureHermeticLaunch(app, sessionID: sessionID)
        launchPreparedApp(app)

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
        XCTAssertTrue(app.descendants(matching: .any)["screen.message.detail"].waitForExistence(timeout: 5), startupFailureDescription(in: app))
        XCTAssertTrue(app.staticTexts["Primary API latency is above budget."].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Critical"].exists)
        let messageImage = app.descendants(matching: .any)["image.message.quality-watch-message-001"]
        XCTAssertTrue(scrollToExistingElement(messageImage, in: app, maximumSwipes: 2), startupFailureDescription(in: app))
        XCTAssertEqual(messageImage.label, "Image")
        XCTAssertGreaterThan(messageImage.frame.width, 0)
        XCTAssertGreaterThan(messageImage.frame.height, 0)
        let openLink = app.links["action.message.open_link"]
        XCTAssertTrue(scrollToElement(openLink, in: app, maximumSwipes: 3))
        XCTAssertEqual(openLink.label, "Open link")
        XCTAssertTrue(openLink.isHittable)

        let deleteButton = app.buttons["action.message.delete"]
        XCTAssertTrue(scrollToElement(deleteButton, in: app, maximumSwipes: 3))
        deleteButton.tap()
        let cancelButton = app.buttons["Cancel"]
        XCTAssertTrue(cancelButton.waitForExistence(timeout: 5))
        cancelButton.tap()
        XCTAssertTrue(app.descendants(matching: .any)["screen.message.detail"].exists)
        XCTAssertTrue(deleteButton.isHittable)
        XCTAssertTrue(scrollBackToElement(app.staticTexts["Primary API latency is above budget."], in: app, maximumSwipes: 4))

        // Cancellation must retain canonical content across an actual app relaunch.
        app.terminate()
        configureHermeticLaunch(app, sessionID: sessionID)
        launchPreparedApp(app)
        XCTAssertTrue(gatewayMessage.waitForExistence(timeout: 10), startupFailureDescription(in: app))
        XCTAssertEqual(gatewayMessage.label, "Gateway health warning")
        XCTAssertTrue(databaseMessage.exists)
        gatewayMessage.tap()
        XCTAssertTrue(app.staticTexts["Primary API latency is above budget."].waitForExistence(timeout: 5))
        XCTAssertTrue(scrollToElement(deleteButton, in: app, maximumSwipes: 3))
        deleteButton.tap()
        // watchOS presents SwiftUI alerts as a native Table and discards custom
        // action identifiers. Scope to its actual title, excluding the detail row.
        let confirmation = app.tables.containing(
            .staticText, identifier: "Delete this message? This cannot be undone."
        ).firstMatch
        let confirmDeleteButton = confirmation.buttons["Delete"]
        XCTAssertTrue(confirmDeleteButton.waitForExistence(timeout: 5), startupFailureDescription(in: app))
        confirmDeleteButton.tap()
        XCTAssertTrue(waitUntil(timeout: 5) { !gatewayMessage.exists })
        if !databaseMessage.waitForExistence(timeout: 5) {
            _ = scrollBackToElement(app.buttons["Retry"], in: app, maximumSwipes: 4)
            XCTFail(startupFailureDescription(in: app))
            return
        }

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
        launchPreparedApp(app)
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
        launchPreparedApp(app)

        let legacyMessage = app.staticTexts["Legacy watch alert"]
        XCTAssertTrue(legacyMessage.waitForExistence(timeout: 10), startupFailureDescription(in: app))
        XCTAssertTrue(scrollToElement(app.buttons["row.message.quality-watch-message-001"], in: app, maximumSwipes: 2), startupFailureDescription(in: app))
        XCTAssertTrue(scrollBackToElement(legacyMessage, in: app, maximumSwipes: 2))
        legacyMessage.tap()
        XCTAssertTrue(app.staticTexts["Persisted before the upgrade."].waitForExistence(timeout: 5))

        app.terminate()
        configureHermeticLaunch(app, sessionID: sessionID, scenario: "watch.migration")
        launchPreparedApp(app)
        XCTAssertTrue(legacyMessage.waitForExistence(timeout: 10), startupFailureDescription(in: app))
        XCTAssertTrue(scrollToElement(app.buttons["row.message.quality-watch-message-001"], in: app, maximumSwipes: 2))
    }

    func testInvalidHermeticScenarioFailsReadinessExplicitly() {
        let app = XCUIApplication()
        configureHermeticLaunch(
            app,
            sessionID: UUID().uuidString,
            scenario: "watch.unsupported"
        )

        launchPreparedApp(app)

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

        launchPreparedApp(app)

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
        launchPreparedApp(app)
        XCTAssertTrue(
            app.staticTexts["Gateway cleanup seed passed"].waitForExistence(timeout: 15),
            startupFailureDescription(in: app)
        )

        app.terminate()
        configureHermeticLaunch(app, sessionID: sessionID, scenario: "watch.gateway-cleanup-recover")
        launchPreparedApp(app)
        XCTAssertTrue(
            app.staticTexts["Gateway cleanup recovery passed"].waitForExistence(timeout: 15),
            startupFailureDescription(in: app)
        )
    }

    func testInterruptedPhoneProvisioningBlocksMixedCredentialsUntilReplay() {
        let app = XCUIApplication()
        let sessionID = UUID().uuidString
        configureHermeticLaunch(app, sessionID: sessionID, scenario: "watch.provisioning-interrupted-seed")
        launchPreparedApp(app)
        XCTAssertTrue(
            app.staticTexts["Provisioning interruption seed passed"].waitForExistence(timeout: 15),
            startupFailureDescription(in: app)
        )

        app.terminate()
        configureHermeticLaunch(app, sessionID: sessionID, scenario: "watch.provisioning-interrupted-recover")
        launchPreparedApp(app)
        XCTAssertTrue(
            app.staticTexts["Provisioning interruption recovery passed"].waitForExistence(timeout: 15),
            startupFailureDescription(in: app)
        )
    }

    func testSilentWakeupUsesV2PullAckAfterStoreAndRetainsContentAcrossDuplicateAndReopen() {
        let app = XCUIApplication()
        let sessionID = UUID().uuidString
        configureHermeticLaunch(app, sessionID: sessionID, scenario: "watch.v2-wakeup")
        launchPreparedApp(app)
        let row = app.buttons["row.message.quality-watch-v2-message"]
        XCTAssertTrue(row.waitForExistence(timeout: 15), startupFailureDescription(in: app))
        XCTAssertEqual(row.label, "Silent V2 delivery")
        XCTAssertEqual(row.value as? String, "Unread, Normal, Pulled content survives duplicate wakeups and reopen.")
        row.tap()
        XCTAssertTrue(app.staticTexts["Pulled content survives duplicate wakeups and reopen."].waitForExistence(timeout: 5))
        pressBack(in: app)
        XCTAssertTrue(waitUntil(timeout: 5) {
            row.value as? String == "Read, Normal, Pulled content survives duplicate wakeups and reopen."
        })

        app.terminate()
        configureHermeticLaunch(app, sessionID: sessionID, scenario: "watch.v2-wakeup-unsupported", language: "zh-Hans", locale: "zh_CN")
        launchPreparedApp(app)
        let upgradeToast = app.descendants(matching: .any)["feedback.toast.error"]
        XCTAssertTrue(upgradeToast.waitForExistence(timeout: 5), startupFailureDescription(in: app))
        let upgradePrompt = XCTAttachment(screenshot: app.screenshot())
        upgradePrompt.name = "Watch real Gateway upgrade prompt"
        upgradePrompt.lifetime = .keepAlways
        add(upgradePrompt)
        // AppContext exposes the toast as its dismiss button. The App-owned
        // transport/Store harness asserts the exact prompt text; retain the
        // real render for visual verification instead of inventing AX text.
        XCTAssertEqual(upgradeToast.label, "关闭")
        XCTAssertTrue(upgradeToast.isHittable)
        XCTAssertTrue(row.waitForExistence(timeout: 10), startupFailureDescription(in: app))
        XCTAssertEqual(row.label, "Silent V2 delivery")
        XCTAssertEqual(row.value as? String, "已读, Normal, Pulled content survives duplicate wakeups and reopen.")
        row.tap()
        XCTAssertTrue(app.staticTexts["Pulled content survives duplicate wakeups and reopen."].waitForExistence(timeout: 5))
    }

    private func launchPreparedApp(_ app: XCUIApplication) {
        app.launch()
        let alert = XCUIApplication(bundleIdentifier: "com.apple.Carousel").alerts.firstMatch
        guard alert.waitForExistence(timeout: 2) else { return }
        let text = alert.staticTexts.allElementsBoundByIndex.map(\.label).joined(separator: " ")
        guard text.contains("PushGo"),
              text.lowercased().contains("notification") || text.contains("通知") else {
            XCTFail("QUALITY_PRECONDITION: Unexpected Watch system alert: \(alert.debugDescription)")
            return
        }
        let allow = ["Allow", "允许", "允許"].map { alert.buttons[$0] }.first { $0.exists }
        guard let allow else {
            XCTFail("QUALITY_PRECONDITION: Missing Watch notification authorization action: \(alert.debugDescription)")
            return
        }
        allow.tap()
        XCTAssertTrue(alert.waitForNonExistence(timeout: 5), "Watch notification preparation must finish before product actions")
    }

    private func configureHermeticLaunch(
        _ app: XCUIApplication,
        sessionID: String,
        scenario: String = "watch.standard",
        language: String = "en",
        locale: String = "en_US"
    ) {
        app.launchArguments = ["-AppleLanguages", "(\(language))", "-AppleLocale", locale]
        app.launchEnvironment["PUSHGO_QUALITY_PROFILE"] = "hermetic"
        app.launchEnvironment["PUSHGO_QUALITY_SCENARIO"] = scenario
        // Reuse the existing Debug-only file-backed credential/storage sandbox.
        // Keep the same root across relaunches without relying on Simulator
        // access-group entitlements or data from another quality session.
        app.launchEnvironment.merge([
            "PUSHGO_QUALITY_SESSION_ID": sessionID,
            "PUSHGO_AUTOMATION_STORAGE_ROOT": "sandbox-tmp:pushgo-watch-\(sessionID)"
        ], uniquingKeysWith: { _, next in next })
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
            : "The expected watch content did not become visible. \(app.debugDescription)"
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

    private func scrollBackToElement(
        _ element: XCUIElement,
        in app: XCUIApplication,
        maximumSwipes: Int
    ) -> Bool {
        if element.exists, element.isHittable { return true }
        for _ in 0..<maximumSwipes {
            app.swipeDown()
            if element.waitForExistence(timeout: 1), element.isHittable { return true }
        }
        return false
    }
}
