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
        guard authorizeNotificationsIfNeeded(in: app, springboard: springboard) else { return }
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
        guard authorizeNotificationsIfNeeded(in: app, springboard: springboard) else { return }
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
        try runSystemNotificationDeleteJourney(confirmDeletion: true)
    }

    func testSystemNotificationDeleteCancelPreservesUnreadTargetAfterRelaunch() throws {
        try runSystemNotificationDeleteJourney(confirmDeletion: false)
    }

    private func runSystemNotificationDeleteJourney(confirmDeletion: Bool) throws {
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
        guard authorizeNotificationsIfNeeded(in: app, springboard: springboard) else { return }
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

        let foregrounded = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "state == %d", XCUIApplication.State.runningForeground.rawValue),
            object: app
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [foregrounded], timeout: 10),
            .completed,
            "The notification Delete action must foreground PushGo for confirmation"
        )
        assertQualityRuntimeReady(in: app, timeout: 15)
        let confirmation = localDeletionConfirmation(in: app, summary: title)
        XCTAssertTrue(
            confirmation.waitForExistence(timeout: 8),
            "The notification action must request confirmation before deleting its canonical target"
        )
        XCTAssertTrue(
            confirmation.label.contains(title),
            "The confirmation must identify the exact notification target"
        )
        if !confirmDeletion {
            tapWhenHittable(
                app.alerts.buttons.matching(identifier: "action.local_deletion.cancel").firstMatch,
                timeout: 8,
                message: "The notification Delete confirmation must support cancellation"
            )
            XCTAssertTrue(confirmation.waitForNonExistence(timeout: 5))
            assertUnreadMessage(title: title, body: body, in: app)
            XCTAssertTrue(app.staticTexts[controlTitle].waitForExistence(timeout: 5))

            app.terminate()
            launch(app)
            assertQualityRuntimeReady(in: app, timeout: 15)
            assertUnreadMessage(title: title, body: body, in: app)
            XCTAssertTrue(app.staticTexts[controlTitle].waitForExistence(timeout: 5))
            XCTAssertFalse(confirmation.exists, "A cancelled Delete request must not survive relaunch")
            return
        }
        tapWhenHittable(
            app.alerts.buttons.matching(identifier: "action.local_deletion.confirm").firstMatch,
            timeout: 8,
            message: "The notification target must be deleted only after explicit confirmation"
        )
        XCTAssertTrue(confirmation.waitForNonExistence(timeout: 5))
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
        guard authorizeNotificationsIfNeeded(in: app, springboard: springboard) else { return }
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

    private func authorizeNotificationsIfNeeded(
        in app: XCUIApplication,
        springboard: XCUIApplication
    ) -> Bool {
        // Quality sessions intentionally skip automatic provider bootstrap. Request real
        // system permission through Settings before publishing readiness for simctl push.
        tapWhenHittable(
            tabButton(in: app, identifier: "tab.channels", labels: ["Channels", "频道", "頻道"]),
            timeout: 8,
            message: "QUALITY_PRECONDITION: Channels must be available to open notification settings"
        )
        let settingsButton = element(in: app, identifier: "action.channels.settings")
        guard settingsButton.waitForExistence(timeout: 8) else {
            XCTFail("QUALITY_PRECONDITION: the Channels settings action did not appear")
            return false
        }
        tapWhenHittable(
            settingsButton,
            timeout: 8,
            message: "QUALITY_PRECONDITION: notification settings must be reachable"
        )
        let settingsScreen = element(in: app, identifier: "screen.settings")
        guard settingsScreen.waitForExistence(timeout: 8),
              element(in: app, identifier: "action.settings.server_management").waitForExistence(timeout: 8)
        else {
            XCTFail("QUALITY_PRECONDITION: Settings did not finish loading")
            return false
        }
        let requestPermission = app.buttons.matching(NSPredicate(
            format: "label CONTAINS %@ OR label CONTAINS %@ OR label CONTAINS %@",
            "Request notification permission", "申请通知权限", "申請通知權限"
        )).firstMatch
        let deniedPermission = app.buttons.matching(NSPredicate(
            format: "label CONTAINS %@ OR label CONTAINS %@ OR label CONTAINS %@",
            "Please enable notification permission in system settings first",
            "请先在系统设置中打开通知权限", "請先在系統設定中開啟通知權限"
        )).firstMatch
        guard !deniedPermission.exists else {
            XCTFail("QUALITY_PRECONDITION: system notification permission was already denied")
            return false
        }

        let authorizationAlert = springboard.alerts.firstMatch
        if requestPermission.exists {
            tapWhenHittable(
                requestPermission,
                timeout: 8,
                message: "QUALITY_PRECONDITION: the real notification permission action was unavailable"
            )
            guard authorizationAlert.waitForExistence(timeout: 2) else {
                XCTFail("QUALITY_PRECONDITION: requesting notification permission did not show the native prompt")
                return false
            }
            let allowButton = authorizationAlert.buttons
                .matching(NSPredicate(format: "label IN %@", ["Allow", "允许", "允許"]))
                .firstMatch
            guard allowButton.waitForExistence(timeout: 3) else {
                XCTFail("QUALITY_PRECONDITION: the iOS Allow action was unavailable")
                return false
            }
            allowButton.tap()
            guard authorizationAlert.waitForNonExistence(timeout: 8) else {
                XCTFail("QUALITY_PRECONDITION: the iOS authorization prompt did not dismiss after allowing notifications")
                return false
            }
        }
        // The authorized Settings branch has neither permission card. Keep the loaded
        // screen in view so absent cards cannot be mistaken for an absent Settings UI.
        guard settingsScreen.exists,
              requestPermission.waitForNonExistence(timeout: 8),
              !deniedPermission.exists,
              !authorizationAlert.exists
        else {
            XCTFail("QUALITY_PRECONDITION: Settings did not confirm authorized notifications")
            return false
        }
        tapWhenHittable(
            app.navigationBars.buttons.firstMatch,
            timeout: 8,
            message: "QUALITY_PRECONDITION: notification settings must be dismissible"
        )
        guard settingsScreen.waitForNonExistence(timeout: 8) else {
            XCTFail("QUALITY_PRECONDITION: Settings remained open after navigating back")
            return false
        }
        tapWhenHittable(
            tabButton(in: app, identifier: "tab.messages", labels: ["Messages", "消息", "訊息"]),
            timeout: 8,
            message: "QUALITY_PRECONDITION: Messages must be available after notification authorization"
        )
        let returnedToMessages = element(in: app, identifier: "screen.messages.list").waitForExistence(timeout: 8)
        XCTAssertTrue(returnedToMessages, "QUALITY_PRECONDITION: notification preparation did not return to Messages")
        return returnedToMessages
    }

    private func tabButton(in app: XCUIApplication, identifier: String, labels: [String]) -> XCUIElement {
        let identifiedTab = app.tabBars.buttons[identifier]
        if identifiedTab.exists {
            return identifiedTab
        }
        return app.tabBars.buttons.matching(NSPredicate(format: "label IN %@", labels)).firstMatch
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

    private func assertUnreadMessage(title: String, body: String, in app: XCUIApplication) {
        let row = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "message.row.", title)
        ).firstMatch
        XCTAssertTrue(
            row.waitForExistence(timeout: 10),
            "Cancelling notification deletion must retain the exact canonical message"
        )
        XCTAssertTrue(
            row.label.localizedCaseInsensitiveContains("unread"),
            "Requesting or cancelling deletion must not mark the target message read"
        )
        XCTAssertEqual(
            row.value as? String,
            body,
            "Cancelling notification deletion must preserve the exact canonical message body"
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

    private func localDeletionConfirmation(in app: XCUIApplication, summary: String) -> XCUIElement {
        // Native alerts preserve the message label but omit the SwiftUI Text identifier.
        let messages = [
            "Permanently delete \(summary) from local storage? This cannot be undone.",
            "永久删除本地存储中的“\(summary)”？此操作无法撤销。",
            "永久刪除本機儲存中的「\(summary)」？此操作無法復原。",
        ]
        return app.alerts.staticTexts.matching(NSPredicate(format: "label IN %@", messages)).firstMatch
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
