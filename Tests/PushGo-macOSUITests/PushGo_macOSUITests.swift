import XCTest

final class PushGo_macOSUITests: XCTestCase {
    private let automationArtifactTimeout: TimeInterval = 30
    private let automationRuntimeDirectoryName = "automation-ui-tests"

    private struct AutomationState: Decodable {
        let activeTab: String?
        let visibleScreen: String?
        let openedMessageId: String?
        let unreadMessageCount: Int?
        let totalMessageCount: Int?
        let openedEntityType: String?
        let openedEntityId: String?
        let eventPageEnabled: Bool?
        let eventCount: Int?
        let thingCount: Int?
        let channelCount: Int?
        let gatewayBaseURL: String?
        let gatewayTokenPresent: Bool?
        let lastNotificationAction: String?
        let lastNotificationTarget: String?
        let lastFixtureImportEntityRecordCount: Int?
        let lastFixtureImportSubscriptionCount: Int?
        let runtimeErrorCount: Int?
        let localStoreMode: String?

        private enum CodingKeys: String, CodingKey {
            case activeTab = "active_tab"
            case visibleScreen = "visible_screen"
            case openedMessageId = "opened_message_id"
            case unreadMessageCount = "unread_message_count"
            case totalMessageCount = "total_message_count"
            case openedEntityType = "opened_entity_type"
            case openedEntityId = "opened_entity_id"
            case eventPageEnabled = "event_page_enabled"
            case eventCount = "event_count"
            case thingCount = "thing_count"
            case channelCount = "channel_count"
            case gatewayBaseURL = "gateway_base_url"
            case gatewayTokenPresent = "gateway_token_present"
            case lastNotificationAction = "last_notification_action"
            case lastNotificationTarget = "last_notification_target"
            case lastFixtureImportEntityRecordCount = "last_fixture_import_entity_record_count"
            case lastFixtureImportSubscriptionCount = "last_fixture_import_subscription_count"
            case runtimeErrorCount = "runtime_error_count"
            case localStoreMode = "local_store_mode"
        }
    }

    private struct AutomationResponse {
        let ok: Bool
        let error: String?
    }

    private struct LaunchContext {
        let app: XCUIApplication
        let runtimeRoot: URL
        let responseURL: URL
        let stateURL: URL
        let eventsURL: URL
        let traceURL: URL
    }

    private let eventFixturePath = fixturePath("event-lifecycle.json")
    private let eventFixtureId = "evt_p2_active_001"
    private let thingFixturePath = fixturePath("rich-thing-detail.json")
    private let thingFixtureId = "thing_p2_rich_001"
    private let messageSeedFixturePath = fixturePath("seed-split.json")
    private let entityRecordFixturePath = fixturePath("seed-entity-records.json")
    private let subscriptionFixturePath = fixturePath("seed-subscriptions.json")
    private let seedMessageId = "msg_p2_seed_001"
    private let crossAppPromptDismissButtons = ["Don’t Allow", "Don't Allow", "Not Now", "Later", "不允许", "以后"]
    private var runtimeRoots: [URL] = []

    private static func fixturePath(_ filename: String) -> String {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures", isDirectory: true)
            .appendingPathComponent("p2", isDirectory: true)
            .appendingPathComponent(filename)
            .path
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        let fileManager = FileManager.default
        for runtimeRoot in runtimeRoots {
            try? fileManager.removeItem(at: runtimeRoot)
        }
        runtimeRoots.removeAll()
    }

    @MainActor
    func testLaunchesIntoMessageList() {
        let context = configuredApp()
        launch(context)

        assertVisibleScreen("screen.messages.list", in: context)
    }

    @MainActor
    func testSidebarNavigationCoversPrimaryScreens() {
        let context = configuredApp()
        launch(context)

        let routeMatrix: [(sidebar: String, screen: String)] = [
            ("events", "screen.events.list"),
            ("things", "screen.things.list"),
            ("channels", "screen.channels"),
            ("settings", "screen.settings"),
            ("messages", "screen.messages.list"),
        ]
        for route in routeMatrix {
            openSidebarTab(route.sidebar, in: context.app)
            assertVisibleScreen(route.screen, in: context, timeout: 12)
        }
    }

    @MainActor
    func testAutomationRequestCanOpenChannelsScreen() {
        let context = configuredApp(
            requestName: "nav.switch_tab",
            args: ["tab": "channels"]
        )
        launch(context)

        assertVisibleScreen("screen.channels", in: context)
        XCTAssertTrue(element(in: context.app, identifier: "screen.channels").waitForExistence(timeout: 8))
    }

    @MainActor
    func testImportedEventFixtureCanOpenEventDetailFromStartupRequest() {
        let context = configuredApp(
            startupFixturePath: eventFixturePath,
            requestName: "entity.open",
            args: [
                "entity_type": "event",
                "entity_id": eventFixtureId,
            ]
        )
        launch(context)

        assertVisibleScreen("screen.events.detail", in: context)
        guard automationArtifactsAvailable(in: context) else { return }
        XCTAssertNotNil(waitForAutomationResponse(at: context.responseURL, timeout: automationArtifactTimeout, matching: { $0.ok }))
        XCTAssertNotNil(
            waitForAutomationEvent(
                at: context.eventsURL,
                timeout: automationArtifactTimeout,
                matching: { event in
                    guard (event["type"] as? String) == "entity.opened",
                          let details = event["details"] as? [String: Any]
                    else { return false }
                    return (details["entity_type"] as? String) == "event"
                        && (details["entity_id"] as? String) == self.eventFixtureId
                }
            )
        )
    }

    @MainActor
    func testImportedThingFixtureCanOpenThingDetailFromStartupRequest() {
        let context = configuredApp(
            startupFixturePath: thingFixturePath,
            requestName: "entity.open",
            args: [
                "entity_type": "thing",
                "entity_id": thingFixtureId,
            ]
        )
        launch(context)

        assertVisibleScreen("screen.things.detail", in: context)
        guard automationArtifactsAvailable(in: context) else { return }
        XCTAssertNotNil(waitForAutomationResponse(at: context.responseURL, timeout: automationArtifactTimeout, matching: { $0.ok }))
        XCTAssertNotNil(
            waitForAutomationEvent(
                at: context.eventsURL,
                timeout: automationArtifactTimeout,
                matching: { event in
                    guard (event["type"] as? String) == "entity.opened",
                          let details = event["details"] as? [String: Any]
                    else { return false }
                    return (details["entity_type"] as? String) == "thing"
                        && (details["entity_id"] as? String) == self.thingFixtureId
                }
            )
        )
    }

    @MainActor
    func testSettingsSidebarCanOpenDecryptionOverlay() {
        let context = configuredApp()
        launch(context)

        openSidebarTab("settings", in: context.app)
        assertVisibleScreen("screen.settings", in: context)

        let decryptionButton = element(in: context.app, identifier: "action.settings.open_decryption")
        XCTAssertTrue(decryptionButton.waitForExistence(timeout: 10))
        decryptionButton.click()
        assertVisibleScreen("screen.settings.decryption", in: context)
    }

    @MainActor
    func testSettingsScreenControlMatrixShowsCriticalGroups() {
        let context = configuredApp()
        launch(context)

        openSidebarTab("settings", in: context.app)
        assertVisibleScreen("screen.settings", in: context)
        assertElementExists("action.settings.server_management", in: context.app)
        assertElementExists("group.settings.page_visibility", in: context.app)
        assertElementExists("action.settings.open_decryption", in: context.app)
    }

    @MainActor
    func testSettingsPageVisibilityCommandCanHideEventPage() {
        let context = configuredApp(
            requestName: "settings.set_page_visibility",
            args: ["page": "events", "enabled": "false"]
        )
        launch(context)

        let eventsTab = element(in: context.app, identifier: "sidebar-events")
        let eventsText = context.app.staticTexts["sidebar-events"]
        let eventsImage = context.app.images["sidebar-events"]
        XCTAssertTrue(waitForElementToDisappear(eventsTab, timeout: 18))
        XCTAssertTrue(waitForElementToDisappear(eventsText, timeout: 18))
        XCTAssertTrue(waitForElementToDisappear(eventsImage, timeout: 18))
        guard automationArtifactsAvailable(in: context) else { return }
        XCTAssertNotNil(waitForAutomationResponse(at: context.responseURL, timeout: automationArtifactTimeout, matching: { $0.ok }))
        XCTAssertNotNil(
            waitForAutomationEvent(
                at: context.eventsURL,
                timeout: automationArtifactTimeout,
                matching: { event in
                    guard (event["type"] as? String) == "settings.changed",
                          let details = event["details"] as? [String: Any]
                    else { return false }
                    let changedKeys = (details["changed_keys"] as? String) ?? ""
                    let enabled = (details["event_page_enabled"] as? String) ?? ""
                    return changedKeys.contains("event_page_enabled") && enabled == "false"
                }
            )
        )
    }

    @MainActor
    func testSettingsPageVisibilityCommandCanRoundTripEventPage() {
        let sharedRuntimeRoot = makeRuntimeRoot()
        let hideContext = configuredApp(
            runtimeRoot: sharedRuntimeRoot,
            requestName: "settings.set_page_visibility",
            args: ["page": "events", "enabled": "false"]
        )
        launch(hideContext)
        guard automationArtifactsAvailable(in: hideContext) else { return }
        XCTAssertNotNil(
            waitForAutomationState(
                at: hideContext.stateURL,
                timeout: automationArtifactTimeout,
                matching: { $0.eventPageEnabled == false }
            )
        )
        XCTAssertTrue(
            waitForAutomationResponse(
                at: hideContext.responseURL,
                timeout: automationArtifactTimeout,
                matching: { $0.ok }
            ) != nil
        )
        XCTAssertNotNil(
            waitForAutomationEvent(
                at: hideContext.eventsURL,
                timeout: automationArtifactTimeout,
                matching: { event in
                    guard (event["type"] as? String) == "settings.changed",
                          let details = event["details"] as? [String: Any]
                    else { return false }
                    let changedKeys = (details["changed_keys"] as? String) ?? ""
                    let enabled = (details["event_page_enabled"] as? String) ?? ""
                    return changedKeys.contains("event_page_enabled") && enabled == "false"
                }
            )
        )

        let showContext = configuredApp(
            runtimeRoot: sharedRuntimeRoot,
            requestName: "settings.set_page_visibility",
            args: ["page": "events", "enabled": "true"]
        )
        launch(showContext)
        guard automationArtifactsAvailable(in: showContext) else { return }
        XCTAssertNotNil(
            waitForAutomationState(
                at: showContext.stateURL,
                timeout: automationArtifactTimeout,
                matching: { $0.eventPageEnabled == true }
            )
        )
        XCTAssertTrue(
            waitForAutomationResponse(
                at: showContext.responseURL,
                timeout: automationArtifactTimeout,
                matching: { $0.ok }
            ) != nil
        )
        XCTAssertNotNil(
            waitForAutomationEvent(
                at: showContext.eventsURL,
                timeout: automationArtifactTimeout,
                matching: { event in
                    guard (event["type"] as? String) == "settings.changed",
                          let details = event["details"] as? [String: Any]
                    else { return false }
                    let changedKeys = (details["changed_keys"] as? String) ?? ""
                    let enabled = (details["event_page_enabled"] as? String) ?? ""
                    return changedKeys.contains("event_page_enabled") && enabled == "true"
                }
            )
        )
    }

    @MainActor
    func testFixtureSeedEntityRecordsPublishesProjectionCounts() {
        let context = configuredApp(
            requestName: "fixture.seed_entity_records",
            args: ["path": entityRecordFixturePath]
        )
        launch(context)

        guard automationArtifactsAvailable(in: context) else { return }
        XCTAssertNotNil(
            waitForAutomationState(
                at: context.stateURL,
                timeout: automationArtifactTimeout,
                matching: {
                    $0.lastFixtureImportEntityRecordCount == 2
                        && ($0.eventCount ?? 0) >= 1
                        && ($0.thingCount ?? 0) >= 1
                }
            )
        )
        XCTAssertTrue(
            waitForAutomationResponse(
                at: context.responseURL,
                timeout: automationArtifactTimeout,
                matching: { $0.ok }
            ) != nil
        )
        XCTAssertNotNil(
            waitForAutomationEvent(
                at: context.eventsURL,
                timeout: automationArtifactTimeout,
                matching: { event in
                    guard (event["type"] as? String) == "fixture.imported",
                          let details = event["details"] as? [String: Any]
                    else { return false }
                    return (details["entity_record_count"] as? String) == "2"
                }
            )
        )
    }

    @MainActor
    func testFixtureSeedSubscriptionsPublishesImportState() {
        let context = configuredApp(
            requestName: "fixture.seed_subscriptions",
            args: ["path": subscriptionFixturePath]
        )
        launch(context)

        guard automationArtifactsAvailable(in: context) else { return }
        XCTAssertNotNil(
            waitForAutomationState(
                at: context.stateURL,
                timeout: automationArtifactTimeout,
                matching: {
                    $0.lastFixtureImportSubscriptionCount == 2
                        && ($0.runtimeErrorCount ?? 0) == 0
                        && $0.localStoreMode != "unavailable"
                }
            )
        )
        XCTAssertTrue(
            waitForAutomationResponse(
                at: context.responseURL,
                timeout: automationArtifactTimeout,
                matching: { $0.ok }
            ) != nil
        )
        XCTAssertNotNil(
            waitForAutomationEvent(
                at: context.eventsURL,
                timeout: automationArtifactTimeout,
                matching: { event in
                    guard (event["type"] as? String) == "fixture.imported",
                          let details = event["details"] as? [String: Any]
                    else { return false }
                    return (details["subscription_count"] as? String) == "2"
                }
            )
        )
    }

    @MainActor
    func testEntityOpenPublishesEntityStateAndProjectionCounts() {
        let eventContext = configuredApp(
            startupFixturePath: eventFixturePath,
            requestName: "entity.open",
            args: ["entity_type": "event", "entity_id": eventFixtureId]
        )
        launch(eventContext)
        guard automationArtifactsAvailable(in: eventContext) else {
            XCTAssertTrue(element(in: eventContext.app, identifier: "screen.events.detail").exists)
            return
        }
        let eventState = waitForAutomationState(
            at: eventContext.stateURL,
            timeout: automationArtifactTimeout,
            matching: { state in
                state.visibleScreen == "screen.events.detail"
                    && state.openedEntityType == "event"
            }
        )
        XCTAssertNotNil(eventState)
        XCTAssertNotNil(waitForAutomationResponse(at: eventContext.responseURL, timeout: automationArtifactTimeout, matching: { $0.ok }))
        XCTAssertNotNil(
            waitForAutomationEvent(
                at: eventContext.eventsURL,
                timeout: automationArtifactTimeout,
                matching: { event in
                    guard (event["type"] as? String) == "entity.opened",
                          let details = event["details"] as? [String: Any]
                    else { return false }
                    return (details["entity_type"] as? String) == "event"
                        && (details["entity_id"] as? String) == self.eventFixtureId
                }
            )
        )

        let thingContext = configuredApp(
            startupFixturePath: thingFixturePath,
            requestName: "entity.open",
            args: ["entity_type": "thing", "entity_id": thingFixtureId]
        )
        launch(thingContext)
        guard automationArtifactsAvailable(in: thingContext) else {
            XCTAssertTrue(element(in: thingContext.app, identifier: "screen.things.detail").exists)
            return
        }
        let thingState = waitForAutomationState(
            at: thingContext.stateURL,
            timeout: automationArtifactTimeout,
            matching: { state in
                state.visibleScreen == "screen.things.detail"
                    && state.openedEntityType == "thing"
            }
        )
        XCTAssertNotNil(thingState)
        XCTAssertNotNil(waitForAutomationResponse(at: thingContext.responseURL, timeout: automationArtifactTimeout, matching: { $0.ok }))
        XCTAssertNotNil(
            waitForAutomationEvent(
                at: thingContext.eventsURL,
                timeout: automationArtifactTimeout,
                matching: { event in
                    guard (event["type"] as? String) == "entity.opened",
                          let details = event["details"] as? [String: Any]
                    else { return false }
                    return (details["entity_type"] as? String) == "thing"
                        && (details["entity_id"] as? String) == self.thingFixtureId
                }
            )
        )
    }

    @MainActor
    func testMessageOpenPublishesMessageDetailState() {
        let context = configuredApp(
            startupFixturePath: messageSeedFixturePath,
            requestName: "message.open",
            args: ["message_id": seedMessageId]
        )
        launch(context)

        assertVisibleScreen("screen.message.detail", in: context)
        guard automationArtifactsAvailable(in: context) else { return }
        XCTAssertNotNil(
            waitForAutomationState(
                at: context.stateURL,
                timeout: automationArtifactTimeout,
                matching: {
                    $0.visibleScreen == "screen.message.detail"
                        && $0.openedMessageId == self.seedMessageId
                }
            )
        )
        XCTAssertNotNil(
            waitForAutomationEvent(
                at: context.eventsURL,
                timeout: automationArtifactTimeout,
                matching: { event in
                    guard (event["type"] as? String) == "entity.opened",
                          let details = event["details"] as? [String: Any]
                    else { return false }
                    return (details["entity_type"] as? String) == "message"
                        && (details["entity_id"] as? String) == self.seedMessageId
                }
            )
        )
    }

    @MainActor
    func testNotificationOpenPublishesMessageDetailState() {
        let context = configuredApp(
            startupFixturePath: messageSeedFixturePath,
            requestName: "notification.open",
            args: ["message_id": seedMessageId]
        )
        launch(context)

        assertVisibleScreen("screen.message.detail", in: context)
        guard automationArtifactsAvailable(in: context) else { return }
        XCTAssertNotNil(
            waitForAutomationState(
                at: context.stateURL,
                timeout: automationArtifactTimeout,
                matching: {
                    $0.visibleScreen == "screen.message.detail"
                        && $0.openedMessageId == self.seedMessageId
                }
            )
        )
        XCTAssertTrue(
            waitForAutomationResponse(
                at: context.responseURL,
                timeout: automationArtifactTimeout,
                matching: { $0.ok }
            ) != nil
        )
    }

    @MainActor
    func testNotificationMarkReadCommandUpdatesUnreadState() {
        let context = configuredApp(
            startupFixturePath: messageSeedFixturePath,
            requestName: "notification.mark_read",
            args: ["message_id": seedMessageId]
        )
        launch(context)

        guard automationArtifactsAvailable(in: context) else { return }
        XCTAssertNotNil(
            waitForAutomationState(
                at: context.stateURL,
                timeout: automationArtifactTimeout,
                matching: {
                    $0.unreadMessageCount == 0
                        && $0.lastNotificationAction == "mark_read"
                        && $0.lastNotificationTarget == self.seedMessageId
                }
            )
        )
        XCTAssertNotNil(
            waitForAutomationEvent(
                at: context.eventsURL,
                timeout: automationArtifactTimeout,
                matching: { event in
                    guard (event["type"] as? String) == "notification.action",
                          let details = event["details"] as? [String: Any]
                    else { return false }
                    return (details["action"] as? String) == "mark_read"
                        && (details["target"] as? String) == self.seedMessageId
                }
            )
        )
    }

    @MainActor
    func testNotificationDeleteCommandUpdatesCounts() {
        let context = configuredApp(
            startupFixturePath: messageSeedFixturePath,
            requestName: "notification.delete",
            args: ["message_id": seedMessageId]
        )
        launch(context)

        guard automationArtifactsAvailable(in: context) else { return }
        XCTAssertNotNil(
            waitForAutomationState(
                at: context.stateURL,
                timeout: automationArtifactTimeout,
                matching: {
                    $0.totalMessageCount == 0
                        && $0.lastNotificationAction == "delete"
                        && $0.lastNotificationTarget == self.seedMessageId
                }
            )
        )
        XCTAssertNotNil(
            waitForAutomationEvent(
                at: context.eventsURL,
                timeout: automationArtifactTimeout,
                matching: { event in
                    guard (event["type"] as? String) == "notification.action",
                          let details = event["details"] as? [String: Any]
                    else { return false }
                    return (details["action"] as? String) == "delete"
                        && (details["target"] as? String) == self.seedMessageId
                }
            )
        )
    }

    @MainActor
    func testGatewaySetServerCommandUpdatesConfigurationState() {
        let context = configuredApp(
            requestName: "gateway.set_server",
            args: [
                "base_url": "https://pushgo.example.test",
                "token": "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
            ]
        )
        launch(context)

        guard automationArtifactsAvailable(in: context) else { return }
        XCTAssertNotNil(
            waitForAutomationState(
                at: context.stateURL,
                timeout: automationArtifactTimeout,
                matching: {
                    $0.gatewayBaseURL == "https://pushgo.example.test"
                        && $0.gatewayTokenPresent == true
                }
            )
        )
        XCTAssertNotNil(
            waitForAutomationEvent(
                at: context.eventsURL,
                timeout: automationArtifactTimeout,
                matching: { event in
                    guard (event["type"] as? String) == "settings.changed",
                          let details = event["details"] as? [String: Any]
                    else { return false }
                    let changedKeys = (details["changed_keys"] as? String) ?? ""
                    return changedKeys.contains("gateway_base_url")
                        && (details["gateway_base_url"] as? String) == "https://pushgo.example.test"
                }
            )
        )
    }

    @MainActor
    func testBaselineAutomationStateHasNoRuntimeErrors() {
        let context = configuredApp()
        launch(context)

        guard automationArtifactsAvailable(in: context) else {
            XCTAssertTrue(element(in: context.app, identifier: "screen.messages.list").exists)
            return
        }
        let state = waitForAutomationState(
            at: context.stateURL,
            timeout: automationArtifactTimeout,
            matching: { $0.visibleScreen == "screen.messages.list" && $0.runtimeErrorCount != nil }
        )
        XCTAssertNotNil(state)
        XCTAssertEqual(state?.runtimeErrorCount, 0)
        XCTAssertNotEqual(state?.localStoreMode, "unavailable")
    }

    @MainActor
    private func configuredApp(
        runtimeRoot: URL? = nil,
        startupFixturePath: String? = nil,
        requestName: String? = nil,
        args: [String: String] = [:]
    ) -> LaunchContext {
        let app = XCUIApplication()
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
        let resolvedRuntimeRoot = runtimeRoot ?? makeRuntimeRoot()
        do {
            try FileManager.default.createDirectory(at: resolvedRuntimeRoot, withIntermediateDirectories: true)
        } catch {
            XCTFail("failed to prepare automation runtime root: \(resolvedRuntimeRoot.path), error: \(error)")
        }
        runtimeRoots.append(resolvedRuntimeRoot)

        let responseURL = resolvedRuntimeRoot.appendingPathComponent("automation-response.json")
        let stateURL = resolvedRuntimeRoot.appendingPathComponent("automation-state.json")
        let eventsURL = resolvedRuntimeRoot.appendingPathComponent("automation-events.jsonl")
        let traceURL = resolvedRuntimeRoot.appendingPathComponent("automation-trace.json")
        let fileManager = FileManager.default
        for url in [responseURL, stateURL, eventsURL, traceURL] {
            try? fileManager.removeItem(at: url)
        }

        let storageToken = "sandbox-tmp:\(resolvedRuntimeRoot.lastPathComponent)"
        setAutomationValue(storageToken, for: "PUSHGO_AUTOMATION_STORAGE_ROOT", in: app)
        setAutomationValue(
            "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            for: "PUSHGO_AUTOMATION_PROVIDER_TOKEN",
            in: app
        )
        setAutomationValue("1", for: "PUSHGO_AUTOMATION_SKIP_PUSH_AUTHORIZATION", in: app)
        setAutomationValue("0", for: "PUSHGO_AUTOMATION_ALLOW_CROSS_APP_DATA_ACCESS", in: app)
        setAutomationValue(responseURL.path, for: "PUSHGO_AUTOMATION_RESPONSE_PATH", in: app)
        setAutomationValue(stateURL.path, for: "PUSHGO_AUTOMATION_STATE_PATH", in: app)
        setAutomationValue(eventsURL.path, for: "PUSHGO_AUTOMATION_EVENTS_PATH", in: app)
        setAutomationValue(traceURL.path, for: "PUSHGO_AUTOMATION_TRACE_PATH", in: app)
        setAutomationValue("1", for: "PUSHGO_AUTOMATION_FORCE_FOREGROUND_APP", in: app)
        if let startupFixturePath {
            setAutomationValue(startupFixturePath, for: "PUSHGO_AUTOMATION_STARTUP_FIXTURE_PATH", in: app)
            let fixtureURL = URL(fileURLWithPath: startupFixturePath)
            let fixtureData = try! Data(contentsOf: fixtureURL)
            setAutomationValue(
                fixtureData.base64EncodedString(),
                for: "PUSHGO_AUTOMATION_STARTUP_FIXTURE_BASE64",
                in: app
            )
        }

        if let requestName {
            let requestPayload = [
                "id": UUID().uuidString,
                "plane": "command",
                "name": requestName,
                "args": args,
            ] as [String: Any]
            let data = try! JSONSerialization.data(withJSONObject: requestPayload, options: [])
            setAutomationValue(String(decoding: data, as: UTF8.self), for: "PUSHGO_AUTOMATION_REQUEST", in: app)
        }

        return LaunchContext(
            app: app,
            runtimeRoot: resolvedRuntimeRoot,
            responseURL: responseURL,
            stateURL: stateURL,
            eventsURL: eventsURL,
            traceURL: traceURL
        )
    }

    private func makeRuntimeRoot() -> URL {
        let fileManager = FileManager.default
        let sharedBase = fileManager.temporaryDirectory
            .appendingPathComponent(automationRuntimeDirectoryName, isDirectory: true)
        do {
            try fileManager.createDirectory(at: sharedBase, withIntermediateDirectories: true)
        } catch {
            XCTFail("failed to create automation runtime base: \(sharedBase.path), error: \(error)")
        }
        return sharedBase
            .appendingPathComponent("PushGo-macOSUITests-\(UUID().uuidString)", isDirectory: true)
    }

    @MainActor
    private func setAutomationValue(_ value: String, for key: String, in app: XCUIApplication) {
        app.launchEnvironment[key] = value
        app.launchArguments += ["-\(key)", value]
    }

    @MainActor
    private func dismissLocalStoreRecoveryIfNeeded(in app: XCUIApplication) {
        let cancelButton = app.buttons["action-button-3"]
        if cancelButton.waitForExistence(timeout: 2) {
            cancelButton.click()
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
    }

    @MainActor
    private func launch(_ context: LaunchContext) {
        context.app.launch()
        context.app.activate()
        dismissSystemPrivacyDialogsIfNeeded(in: context.app)
        XCTAssertTrue(context.app.windows.firstMatch.waitForExistence(timeout: 12))
        dismissLocalStoreRecoveryIfNeeded(in: context.app)
        dismissSystemPrivacyDialogsIfNeeded(in: context.app)
        XCTAssertFalse(
            context.app.buttons["action-button-3"].exists,
            "local store recovery prompt still visible, runtime root=\(context.runtimeRoot.path)"
        )
    }

    @MainActor
    private func dismissSystemPrivacyDialogsIfNeeded(in app: XCUIApplication) {
        for title in crossAppPromptDismissButtons {
            let appButton = app.buttons[title]
            if appButton.exists {
                appButton.click()
                RunLoop.current.run(until: Date().addingTimeInterval(0.4))
                return
            }
        }
    }

    @MainActor
    private func openSidebarTab(_ tabIdentifier: String, in app: XCUIApplication) {
        let sidebarText = app.staticTexts["sidebar-\(tabIdentifier)"]
        if sidebarText.waitForExistence(timeout: 10) {
            sidebarText.click()
            RunLoop.current.run(until: Date().addingTimeInterval(0.4))
            return
        }
        let sidebarImage = app.images["sidebar-\(tabIdentifier)"]
        if sidebarImage.waitForExistence(timeout: 5) {
            sidebarImage.click()
            RunLoop.current.run(until: Date().addingTimeInterval(0.4))
            return
        }
        let sidebar = element(in: app, identifier: "sidebar-\(tabIdentifier)")
        XCTAssertTrue(sidebar.waitForExistence(timeout: 5), "sidebar-\(tabIdentifier) not found")
        sidebar.click()
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
    }

    @MainActor
    private func assertVisibleScreen(
        _ screenIdentifier: String,
        in context: LaunchContext,
        timeout: TimeInterval = 10,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        if element(in: context.app, identifier: screenIdentifier).waitForExistence(timeout: timeout) {
            return
        }
        if waitForAutomationState(
            at: context.stateURL,
            timeout: timeout,
            matching: { $0.visibleScreen == screenIdentifier }
        ) != nil {
            return
        }
        let stateText = (try? String(contentsOf: context.stateURL, encoding: .utf8)) ?? "<missing state>"
        XCTFail("Expected visible screen \(screenIdentifier), current state: \(stateText)", file: file, line: line)
    }

    @MainActor
    private func waitForAutomationState(
        at url: URL,
        timeout: TimeInterval,
        matching predicate: (AutomationState) -> Bool
    ) -> AutomationState? {
        let deadline = Date().addingTimeInterval(timeout)
        let decoder = JSONDecoder()
        while Date() < deadline {
            if let data = try? Data(contentsOf: url),
               let state = try? decoder.decode(AutomationState.self, from: data),
               predicate(state) {
                return state
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return nil
    }

    @MainActor
    private func element(in app: XCUIApplication, identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    @MainActor
    private func waitForAutomationResponse(
        at url: URL,
        timeout: TimeInterval,
        matching predicate: (AutomationResponse) -> Bool
    ) -> AutomationResponse? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let data = try? Data(contentsOf: url),
               let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let ok = raw["ok"] as? Bool {
                let response = AutomationResponse(
                    ok: ok,
                    error: raw["error"] as? String
                )
                if predicate(response) {
                    return response
                }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return nil
    }

    @MainActor
    private func waitForAutomationEvent(
        at url: URL,
        timeout: TimeInterval,
        matching predicate: ([String: Any]) -> Bool
    ) -> [String: Any]? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            for event in automationEvents(at: url) where predicate(event) {
                return event
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return nil
    }

    private func automationEvents(at url: URL) -> [[String: Any]] {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        var events: [[String: Any]] = []
        for line in content.split(whereSeparator: \.isNewline) {
            guard let data = String(line).data(using: .utf8),
                  let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            events.append(event)
        }
        return events
    }

    @MainActor
    private func assertElementExists(
        _ identifier: String,
        in app: XCUIApplication,
        timeout: TimeInterval = 8,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let target = element(in: app, identifier: identifier)
        XCTAssertTrue(target.waitForExistence(timeout: timeout), "Missing element: \(identifier)", file: file, line: line)
    }

    @MainActor
    private func waitForAnyElementExists(
        identifiers: [String],
        in app: XCUIApplication,
        timeout: TimeInterval
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            for identifier in identifiers where element(in: app, identifier: identifier).exists {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return identifiers.contains { element(in: app, identifier: $0).exists }
    }

    @MainActor
    private func automationArtifactsAvailable(in context: LaunchContext, timeout: TimeInterval = 2) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        let fileManager = FileManager.default
        while Date() < deadline {
            if fileManager.fileExists(atPath: context.stateURL.path)
                || fileManager.fileExists(atPath: context.responseURL.path)
                || fileManager.fileExists(atPath: context.eventsURL.path)
                || fileManager.fileExists(atPath: context.traceURL.path)
            {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return false
    }

    @MainActor
    private func waitForElementToDisappear(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !element.exists {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return !element.exists
    }

}
