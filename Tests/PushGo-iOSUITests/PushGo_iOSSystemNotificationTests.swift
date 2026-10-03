import XCTest

@MainActor
final class PushGo_iOSSystemNotificationTests: XCTestCase {
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

    func testSystemNotificationTapOpensAccurateReadDetailAndPersists() throws {
        let runID = UUID().uuidString.lowercased()
        let title = "Quality iOS system route \(runID.prefix(8))"
        let body = "Exact iOS notification route body \(runID)."
        let messageID = "quality-ios-system-route-message-\(runID)"
        let app = configuredApp(sessionID: runID)
        launch(app)
        assertQualityRuntimeReady(in: app, timeout: 15)

        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        authorizeNotificationsIfNeeded(in: springboard)
        background(app)
        let readinessURL = try publishReadiness(
            title: title,
            body: body,
            messageID: messageID,
            severity: "critical"
        )
        defer { try? FileManager.default.removeItem(at: readinessURL) }

        let notificationTitle = springboard.staticTexts[title]
        XCTAssertTrue(
            notificationTitle.waitForExistence(timeout: 30),
            "The injected payload never became a real SpringBoard notification"
        )
        XCTAssertTrue(
            springboard.staticTexts[body].waitForExistence(timeout: 5),
            "SpringBoard did not expose the exact payload body"
        )
        notificationTitle.tap()

        let foregrounded = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "state == %d", XCUIApplication.State.runningForeground.rawValue),
            object: app
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [foregrounded], timeout: 10),
            .completed,
            "The system notification did not foreground PushGo through UNNotificationResponse"
        )
        let detail = element(in: app, identifier: "sheet.message.detail")
        XCTAssertTrue(detail.waitForExistence(timeout: 10), "The exact message detail did not open")
        XCTAssertTrue(detail.staticTexts[title].waitForExistence(timeout: 5))
        XCTAssertTrue(detail.staticTexts[body].waitForExistence(timeout: 5))
        XCTAssertTrue(
            detail.staticTexts["Critical message, please handle it as soon as possible."]
                .waitForExistence(timeout: 5),
            "The critical system message did not expose its user guidance in the exact detail"
        )
        tapWhenHittable(
            element(in: app, identifier: "action.message.close"),
            timeout: 8,
            message: "The routed detail must be dismissible"
        )
        XCTAssertTrue(app.staticTexts[title].waitForExistence(timeout: 8))
        XCTAssertFalse(
            element(in: app, identifier: "action.messages.mark_all_read").waitForExistence(timeout: 3),
            "Opening the system-routed detail did not persist the read outcome"
        )

        app.terminate()
        launch(app)
        assertQualityRuntimeReady(in: app, timeout: 15)
        XCTAssertTrue(
            app.staticTexts[title].waitForExistence(timeout: 8),
            "The system-routed canonical message did not survive relaunch"
        )
        XCTAssertEqual(
            app.staticTexts.matching(NSPredicate(format: "label == %@", title)).count,
            1,
            "The single system notification did not produce exactly one canonical list row"
        )
        XCTAssertFalse(
            element(in: app, identifier: "action.messages.mark_all_read").waitForExistence(timeout: 3),
            "The read outcome was lost on relaunch"
        )
        tapWhenHittable(
            app.staticTexts[title],
            timeout: 8,
            message: "The persisted system-routed message row must remain actionable"
        )
        let relaunchedDetail = element(in: app, identifier: "sheet.message.detail")
        XCTAssertTrue(relaunchedDetail.waitForExistence(timeout: 8))
        XCTAssertTrue(
            relaunchedDetail.staticTexts[body].waitForExistence(timeout: 5),
            "The exact system-routed body was lost after relaunch"
        )
    }

    func testSystemNotificationTapColdLaunchesAccurateReadDetailAndPersists() throws {
        let runID = UUID().uuidString.lowercased()
        let title = "Quality iOS cold notification route \(runID.prefix(8))"
        let body = "Exact iOS cold notification route body \(runID)."
        let messageID = "quality-ios-cold-system-route-message-\(runID)"
        let app = configuredApp(sessionID: runID, allowsSystemColdLaunch: true)
        launch(app)
        assertQualityRuntimeReady(in: app, timeout: 15)

        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        authorizeNotificationsIfNeeded(in: springboard)
        background(app)
        let readinessURL = try publishReadiness(title: title, body: body, messageID: messageID)
        defer { try? FileManager.default.removeItem(at: readinessURL) }

        let notificationTitle = springboard.staticTexts[title]
        XCTAssertTrue(
            notificationTitle.waitForExistence(timeout: 30),
            "The cold-launch payload never became a real SpringBoard notification"
        )
        XCTAssertTrue(
            springboard.staticTexts[body].waitForExistence(timeout: 5),
            "SpringBoard did not expose the exact cold-launch payload body"
        )

        app.terminate()
        XCTAssertEqual(
            app.state,
            .notRunning,
            "QUALITY_PRECONDITION: PushGo was still running before the cold notification tap"
        )
        XCTAssertTrue(
            notificationTitle.waitForExistence(timeout: 5),
            "The delivered notification disappeared when PushGo terminated"
        )
        notificationTitle.tap()

        let foregrounded = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "state == %d", XCUIApplication.State.runningForeground.rawValue),
            object: app
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [foregrounded], timeout: 10),
            .completed,
            "The system notification did not cold-launch PushGo"
        )
        assertQualityRuntimeReady(in: app, timeout: 15)
        let detail = element(in: app, identifier: "sheet.message.detail")
        XCTAssertTrue(detail.waitForExistence(timeout: 10), "The cold-routed exact detail did not open")
        XCTAssertTrue(detail.staticTexts[title].waitForExistence(timeout: 5))
        XCTAssertTrue(detail.staticTexts[body].waitForExistence(timeout: 5))
        tapWhenHittable(
            element(in: app, identifier: "action.message.close"),
            timeout: 8,
            message: "The cold-routed detail must be dismissible"
        )
        XCTAssertTrue(app.staticTexts[title].waitForExistence(timeout: 8))
        XCTAssertEqual(
            app.staticTexts.matching(NSPredicate(format: "label == %@", title)).count,
            1,
            "The cold system route produced duplicate canonical rows"
        )
        XCTAssertFalse(
            element(in: app, identifier: "action.messages.mark_all_read").waitForExistence(timeout: 3),
            "The cold system route did not persist the read outcome"
        )

        app.terminate()
        app.launchEnvironment["PUSHGO_QUALITY_SESSION_BASE64"] = qualitySessionPayload(
            sessionID: runID,
            fixture: "empty.clean",
            allowsSystemColdLaunch: false
        )
        launch(app)
        assertQualityRuntimeReady(in: app, timeout: 15)
        assertAccurateReadMessage(title: title, body: body, in: app)
    }

    func testSystemNotificationDeleteActionRemovesOnlyTargetAndPersists() throws {
        let runID = UUID().uuidString.lowercased()
        let title = "Quality iOS notification delete \(runID.prefix(8))"
        let body = "Exact iOS notification delete body \(runID)."
        let messageID = "quality-ios-system-delete-message-\(runID)"
        let controlTitle = "Quality Keep History Message"
        let controlBody = "Deterministic history owned by 01H00000000000000000000001."
        let app = configuredApp(sessionID: runID, fixture: "channels.standard")
        launch(app)
        assertQualityRuntimeReady(in: app, timeout: 15)
        XCTAssertTrue(
            app.staticTexts[controlTitle].waitForExistence(timeout: 8),
            "QUALITY_PRECONDITION: the unrelated canonical control message did not load"
        )

        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        authorizeNotificationsIfNeeded(in: springboard)
        background(app)
        let readinessURL = try publishReadiness(title: title, body: body, messageID: messageID)
        defer { try? FileManager.default.removeItem(at: readinessURL) }

        let notificationTitle = springboard.staticTexts[title]
        XCTAssertTrue(
            notificationTitle.waitForExistence(timeout: 30),
            "The target payload never became a real SpringBoard notification"
        )
        XCTAssertTrue(
            springboard.staticTexts[body].waitForExistence(timeout: 5),
            "SpringBoard did not expose the exact target payload body"
        )
        notificationTitle.press(forDuration: 1)
        let deleteAction = springboard.buttons
            .matching(NSPredicate(format: "label IN %@", ["Delete", "删除", "刪除"]))
            .firstMatch
        XCTAssertTrue(
            deleteAction.waitForExistence(timeout: 8),
            "The production notification category did not expose its destructive Delete action"
        )
        deleteAction.tap()
        XCTAssertTrue(
            notificationTitle.waitForNonExistence(timeout: 8),
            "The handled notification remained visible after its Delete action"
        )

        activateAndAwaitForeground(app)
        assertQualityRuntimeReady(in: app, timeout: 15)
        assertControlMessage(
            title: controlTitle,
            body: controlBody,
            targetTitle: title,
            in: app
        )

        app.terminate()
        launch(app)
        assertQualityRuntimeReady(in: app, timeout: 15)
        assertControlMessage(
            title: controlTitle,
            body: controlBody,
            targetTitle: title,
            in: app
        )
    }

    func testSystemNotificationMarkReadActionPersistsAccurateReadTarget() throws {
        let runID = UUID().uuidString.lowercased()
        let title = "Quality iOS notification mark read \(runID.prefix(8))"
        let body = "Exact iOS notification mark-read body \(runID)."
        let messageID = "quality-ios-system-mark-read-message-\(runID)"
        let app = configuredApp(sessionID: runID)
        launch(app)
        assertQualityRuntimeReady(in: app, timeout: 15)

        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        authorizeNotificationsIfNeeded(in: springboard)
        background(app)
        let readinessURL = try publishReadiness(title: title, body: body, messageID: messageID)
        defer { try? FileManager.default.removeItem(at: readinessURL) }

        let notificationTitle = springboard.staticTexts[title]
        XCTAssertTrue(
            notificationTitle.waitForExistence(timeout: 30),
            "The mark-read payload never became a real SpringBoard notification"
        )
        XCTAssertTrue(
            springboard.staticTexts[body].waitForExistence(timeout: 5),
            "SpringBoard did not expose the exact mark-read payload body"
        )
        notificationTitle.press(forDuration: 1)
        let markReadAction = springboard.buttons
            .matching(NSPredicate(format: "label IN %@", ["Mark as read", "标记已读", "標記已讀"]))
            .firstMatch
        XCTAssertTrue(
            markReadAction.waitForExistence(timeout: 8),
            "The production notification category did not expose its Mark as read action"
        )
        markReadAction.tap()
        XCTAssertTrue(
            notificationTitle.waitForNonExistence(timeout: 8),
            "The handled notification remained visible after its Mark as read action"
        )

        activateAndAwaitForeground(app)
        assertQualityRuntimeReady(in: app, timeout: 15)
        assertAccurateReadMessage(title: title, body: body, in: app)

        app.terminate()
        launch(app)
        assertQualityRuntimeReady(in: app, timeout: 15)
        assertAccurateReadMessage(title: title, body: body, in: app)
    }

    private func configuredApp(
        sessionID: String,
        fixture: String = "empty.clean",
        allowsSystemColdLaunch: Bool = false
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-ApplePersistenceIgnoreState", "YES",
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
        ]
        app.launchEnvironment["PUSHGO_AUTOMATION_PROVIDER_TOKEN"] =
            "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
        app.launchEnvironment["PUSHGO_AUTOMATION_SKIP_PUSH_AUTHORIZATION"] = "0"
        app.launchEnvironment["PUSHGO_AUTOMATION_ALLOW_CROSS_APP_DATA_ACCESS"] = "0"
        app.launchEnvironment["PUSHGO_QUALITY_SESSION_BASE64"] = qualitySessionPayload(
            sessionID: sessionID,
            fixture: fixture,
            allowsSystemColdLaunch: allowsSystemColdLaunch
        )
        return app
    }

    private func qualitySessionPayload(
        sessionID: String,
        fixture: String,
        allowsSystemColdLaunch: Bool
    ) -> String {
        let payload: [String: Any] = [
            "schema_version": 1,
            "session_id": "ios-system-notification-\(sessionID)",
            "fixture": fixture,
            "faults": [:],
            "allows_system_cold_launch": allowsSystemColdLaunch,
        ]
        let data = try! JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        return data.base64EncodedString()
    }

    private func authorizeNotificationsIfNeeded(in springboard: XCUIApplication) {
        let authorizationAlert = springboard.alerts.firstMatch
        // XCTest may consume the launch-time permission interruption before a SpringBoard
        // query observes it. If it is still present, choose Allow explicitly. Either way,
        // the exact notification appearing in SpringBoard is the decisive authorization oracle.
        if authorizationAlert.waitForExistence(timeout: 2) {
            let allowButton = authorizationAlert.buttons
                .matching(NSPredicate(format: "label IN %@", ["Allow", "允许", "允許"]))
                .firstMatch
            XCTAssertTrue(
                allowButton.waitForExistence(timeout: 3),
                "QUALITY_PRECONDITION: the iOS Allow action was unavailable"
            )
            guard allowButton.exists else { return }
            allowButton.tap()
            XCTAssertTrue(
                authorizationAlert.waitForNonExistence(timeout: 8),
                "QUALITY_PRECONDITION: the iOS authorization prompt did not dismiss after allowing notifications"
            )
        }
    }

    private func background(_ app: XCUIApplication) {
        XCUIDevice.shared.press(.home)
        let backgrounded = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "state == %d", XCUIApplication.State.runningBackground.rawValue),
            object: app
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [backgrounded], timeout: 8),
            .completed,
            "QUALITY_PRECONDITION: PushGo did not reach the background before remote-push injection"
        )
    }

    private func activateAndAwaitForeground(_ app: XCUIApplication) {
        app.activate()
        let foregrounded = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "state == %d", XCUIApplication.State.runningForeground.rawValue),
            object: app
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [foregrounded], timeout: 10),
            .completed,
            "PushGo did not foreground after the background notification action completed"
        )
    }

    private func publishReadiness(
        title: String,
        body: String,
        messageID: String,
        severity: String = "normal"
    ) throws -> URL {
        let readinessURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("pushgo-system-notification-ready", isDirectory: false)
        let readinessPayload = try JSONSerialization.data(
            withJSONObject: [
                "title": title,
                "body": body,
                "message_id": messageID,
                "severity": severity,
            ],
            options: [.sortedKeys]
        )
        do {
            try readinessPayload.write(to: readinessURL, options: .atomic)
        } catch {
            XCTFail("QUALITY_PRECONDITION: could not publish system-notification readiness: \(error)")
            throw error
        }
        return readinessURL
    }

    private func assertControlMessage(
        title: String,
        body: String,
        targetTitle: String,
        in app: XCUIApplication
    ) {
        let controlMessage = app.staticTexts[title]
        let controlExists = controlMessage.waitForExistence(timeout: 10)
        XCTAssertTrue(
            controlExists,
            "The unrelated control message must remain after notification deletion"
        )
        guard controlExists else { return }
        XCTAssertFalse(
            app.staticTexts.matching(NSPredicate(format: "label == %@", targetTitle)).firstMatch.exists,
            "The notification Delete action did not remove its canonical target"
        )
        tapWhenHittable(
            controlMessage,
            timeout: 8,
            message: "The unrelated control message must remain actionable"
        )
        let detail = element(in: app, identifier: "sheet.message.detail")
        XCTAssertTrue(detail.waitForExistence(timeout: 8))
        XCTAssertTrue(
            detail.staticTexts[body].waitForExistence(timeout: 5),
            "The unrelated control message body changed during target deletion"
        )
        tapWhenHittable(
            element(in: app, identifier: "action.message.close"),
            timeout: 8,
            message: "The control detail must remain dismissible"
        )
    }

    private func assertAccurateReadMessage(title: String, body: String, in app: XCUIApplication) {
        let targetMessage = app.staticTexts[title]
        let targetExists = targetMessage.waitForExistence(timeout: 10)
        XCTAssertTrue(
            targetExists,
            "The Mark as read action lost its canonical target"
        )
        guard targetExists else { return }
        XCTAssertFalse(
            element(in: app, identifier: "action.messages.mark_all_read").waitForExistence(timeout: 3),
            "The notification action did not persist the target's read state"
        )
        tapWhenHittable(
            targetMessage,
            timeout: 8,
            message: "The marked-read canonical message must remain actionable"
        )
        let detail = element(in: app, identifier: "sheet.message.detail")
        XCTAssertTrue(detail.waitForExistence(timeout: 8))
        XCTAssertTrue(
            detail.staticTexts[body].waitForExistence(timeout: 5),
            "The Mark as read action changed or routed to the wrong canonical body"
        )
        tapWhenHittable(
            element(in: app, identifier: "action.message.close"),
            timeout: 8,
            message: "The marked-read detail must remain dismissible"
        )
    }

    private func launch(_ app: XCUIApplication) {
        let key = "PUSHGO_QUALITY_SESSION_BASE64"
        var arguments = app.launchArguments
        while let index = arguments.firstIndex(of: "-\(key)") {
            arguments.remove(at: index)
            if arguments.indices.contains(index) {
                arguments.remove(at: index)
            }
        }
        if let payload = app.launchEnvironment[key], !payload.isEmpty {
            arguments += ["-\(key)", payload]
        }
        app.launchArguments = arguments
        app.launch()
    }

    private func element(in app: XCUIApplication, identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }

    private func tapWhenHittable(
        _ element: XCUIElement,
        timeout: TimeInterval,
        message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let actionable = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND hittable == true"),
            object: element
        )
        let result = XCTWaiter.wait(for: [actionable], timeout: timeout)
        XCTAssertEqual(result, .completed, message, file: file, line: line)
        guard result == .completed else { return }
        element.tap()
    }

    private func assertQualityRuntimeReady(
        in app: XCUIApplication,
        timeout: TimeInterval,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(
            element(in: app, identifier: "quality-runtime.ready").waitForExistence(timeout: timeout),
            "QUALITY_PRECONDITION: App-owned quality session did not become ready",
            file: file,
            line: line
        )
    }
}
