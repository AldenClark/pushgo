import XCTest

@MainActor
final class PushGo_iOSSystemNotificationTests: XCTestCase {
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

    func testSystemNotificationTapOpensAccurateReadDetailAndPersists() throws {
        let runID = UUID().uuidString.lowercased()
        let title = "Quality iOS system route \(runID.prefix(8))"
        let body = "Exact iOS notification route body \(runID)."
        let messageID = "quality-ios-system-route-message-\(runID)"
        let app = configuredApp(sessionID: runID)
        launch(app)
        assertQualityRuntimeReady(in: app, timeout: 15)

        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let authorizationAlert = springboard.alerts.firstMatch
        // XCTest may consume the launch-time permission interruption before a SpringBoard
        // query observes it. If it is still present, choose Allow explicitly. Either way,
        // the exact notification must later appear in SpringBoard, which is the decisive
        // authorization/delivery oracle and cannot pass when permission was not granted.
        if authorizationAlert.waitForExistence(timeout: 2) {
            let allowButton = authorizationAlert.buttons
                .matching(NSPredicate(format: "label IN %@", ["Allow", "允许", "允許"]))
                .firstMatch
            XCTAssertTrue(
                allowButton.waitForExistence(timeout: 3),
                "QUALITY_PRECONDITION: the iOS Allow action was unavailable"
            )
            allowButton.tap()
            XCTAssertTrue(
                authorizationAlert.waitForNonExistence(timeout: 8),
                "QUALITY_PRECONDITION: the iOS authorization prompt did not dismiss after allowing notifications"
            )
        }

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

        let readinessURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("pushgo-system-notification-ready", isDirectory: false)
        let readinessPayload = try JSONSerialization.data(
            withJSONObject: ["title": title, "body": body, "message_id": messageID],
            options: [.sortedKeys]
        )
        do {
            try readinessPayload.write(to: readinessURL, options: .atomic)
        } catch {
            XCTFail("QUALITY_PRECONDITION: could not publish system-notification readiness: \(error)")
            return
        }
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

    private func configuredApp(sessionID: String) -> XCUIApplication {
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
        app.launchEnvironment["PUSHGO_QUALITY_SESSION_BASE64"] = qualitySessionPayload(sessionID: sessionID)
        return app
    }

    private func qualitySessionPayload(sessionID: String) -> String {
        let payload: [String: Any] = [
            "schema_version": 1,
            "session_id": "ios-system-notification-\(sessionID)",
            "fixture": "empty.clean",
            "faults": [:],
        ]
        let data = try! JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        return data.base64EncodedString()
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
