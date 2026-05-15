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
        let lastFixtureImportMessageCount: Int?
        let lastFixtureImportEntityRecordCount: Int?
        let lastFixtureImportSubscriptionCount: Int?
        let runtimeErrorCount: Int?
        let localStoreMode: String?
        let residentMemoryBytes: UInt64?
        let mainThreadMaxStallMilliseconds: Int?

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
            case lastFixtureImportMessageCount = "last_fixture_import_message_count"
            case lastFixtureImportEntityRecordCount = "last_fixture_import_entity_record_count"
            case lastFixtureImportSubscriptionCount = "last_fixture_import_subscription_count"
            case runtimeErrorCount = "runtime_error_count"
            case localStoreMode = "local_store_mode"
            case residentMemoryBytes = "resident_memory_bytes"
            case mainThreadMaxStallMilliseconds = "main_thread_max_stall_ms"
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
    func testRuntimeQualityLargeFixtureLaunchAndListReadiness() throws {
        try XCTSkipUnless(
            runtimeQualityUIEnabled(),
            "Set PUSHGO_RUNTIME_QUALITY_UI=1 to run large UI runtime quality validation."
        )

        let scale = runtimeQualityUIScale(default: 10_000)
        let runtimeRoot = makeRuntimeRoot()
        try FileManager.default.createDirectory(at: runtimeRoot, withIntermediateDirectories: true)
        let fixtureURL = runtimeRoot.appendingPathComponent("runtime-quality-ui-fixture.json")

        let generationStartedAt = Date()
        try writeRuntimeQualityUIFixture(messageCount: scale, to: fixtureURL)
        let generationDuration = Date().timeIntervalSince(generationStartedAt)

        let context = configuredApp(
            runtimeRoot: runtimeRoot,
            requestName: "fixture.seed_messages",
            args: ["path": fixtureURL.path]
        )
        let launchStartedAt = Date()
        launch(context)
        assertVisibleScreen("screen.messages.list", in: context, timeout: 30)

        guard automationArtifactsAvailable(in: context) else {
            XCTFail("automation artifacts missing for large UI runtime quality test")
            return
        }

        let state = waitForAutomationState(
            at: context.stateURL,
            timeout: runtimeQualityUITimeout(default: 90),
            matching: {
                $0.lastFixtureImportMessageCount == scale
                    && ($0.totalMessageCount ?? 0) > 0
                    && ($0.runtimeErrorCount ?? 0) == 0
            }
        )
        let readyDuration = Date().timeIntervalSince(launchStartedAt)
        XCTAssertNotNil(state)
        XCTAssertEqual(state?.lastFixtureImportMessageCount, scale)
        XCTAssertEqual(state?.runtimeErrorCount, 0)
        context.app.terminate()

        let detailVariantContext = configuredApp(
            runtimeRoot: runtimeRoot,
            requestName: "runtime.measure_detail_variants"
        )
        let detailVariantStartedAt = Date()
        launch(detailVariantContext)
        assertVisibleScreen("screen.messages.list", in: detailVariantContext, timeout: 30)
        let detailVariantResponse = waitForAutomationResponse(
            at: detailVariantContext.responseURL,
            timeout: runtimeQualityUITimeout(default: 90),
            matching: { $0.ok }
        )
        let detailVariantMetrics = waitForRuntimeDetailVariantMetrics(
            at: detailVariantContext.eventsURL,
            timeout: runtimeQualityUITimeout(default: 90)
        )
        let detailVariantDuration = Date().timeIntervalSince(detailVariantStartedAt)
        XCTAssertNotNil(detailVariantResponse)
        XCTAssertNotNil(detailVariantMetrics)
        detailVariantContext.app.terminate()

        let queryContext = configuredApp(
            runtimeRoot: runtimeRoot,
            requestName: "runtime.measure_message_queries"
        )
        let queryStartedAt = Date()
        launch(queryContext)
        assertVisibleScreen("screen.messages.list", in: queryContext, timeout: 30)
        let queryResponse = waitForAutomationResponse(
            at: queryContext.responseURL,
            timeout: runtimeQualityUITimeout(default: 90),
            matching: { $0.ok }
        )
        let queryMetrics = waitForRuntimeMessageQueryMetrics(
            at: queryContext.eventsURL,
            timeout: runtimeQualityUITimeout(default: 90)
        )
        let queryDuration = Date().timeIntervalSince(queryStartedAt)
        XCTAssertNotNil(queryResponse)
        XCTAssertNotNil(queryMetrics)
        queryContext.app.terminate()

        let sortModeContext = configuredApp(
            runtimeRoot: runtimeRoot,
            requestName: "runtime.measure_sort_modes"
        )
        let sortModeStartedAt = Date()
        launch(sortModeContext)
        assertVisibleScreen("screen.messages.list", in: sortModeContext, timeout: 30)
        let sortModeResponse = waitForAutomationResponse(
            at: sortModeContext.responseURL,
            timeout: runtimeQualityUITimeout(default: 90),
            matching: { $0.ok }
        )
        let sortModeMetrics = waitForRuntimeSortModeMetrics(
            at: sortModeContext.eventsURL,
            timeout: runtimeQualityUITimeout(default: 90)
        )
        let sortModeDuration = Date().timeIntervalSince(sortModeStartedAt)
        XCTAssertNotNil(sortModeResponse)
        XCTAssertNotNil(sortModeMetrics)
        sortModeContext.app.terminate()

        let mediaCycleContext = configuredApp(
            runtimeRoot: runtimeRoot,
            requestName: "runtime.measure_media_cycles"
        )
        let mediaCycleStartedAt = Date()
        launch(mediaCycleContext)
        assertVisibleScreen("screen.messages.list", in: mediaCycleContext, timeout: 30)
        let mediaCycleResponse = waitForAutomationResponse(
            at: mediaCycleContext.responseURL,
            timeout: runtimeQualityUITimeout(default: 120),
            matching: { $0.ok }
        )
        let mediaCycleMetrics = waitForRuntimeMediaCycleMetrics(
            at: mediaCycleContext.eventsURL,
            timeout: runtimeQualityUITimeout(default: 120)
        )
        let mediaCycleDuration = Date().timeIntervalSince(mediaCycleStartedAt)
        XCTAssertNotNil(mediaCycleResponse)
        XCTAssertNotNil(mediaCycleMetrics)
        mediaCycleContext.app.terminate()

        let detailReleaseContext = configuredApp(
            runtimeRoot: runtimeRoot,
            requestName: "runtime.measure_detail_release_cycles"
        )
        let detailReleaseStartedAt = Date()
        launch(detailReleaseContext)
        assertVisibleScreen("screen.messages.list", in: detailReleaseContext, timeout: 30)
        let detailReleaseResponse = waitForAutomationResponse(
            at: detailReleaseContext.responseURL,
            timeout: runtimeQualityUITimeout(default: 180),
            matching: { $0.ok }
        )
        let detailReleaseMetrics = waitForRuntimeDetailReleaseMetrics(
            at: detailReleaseContext.eventsURL,
            timeout: runtimeQualityUITimeout(default: 180)
        )
        let detailReleaseDuration = Date().timeIntervalSince(detailReleaseStartedAt)
        XCTAssertNotNil(detailReleaseResponse)
        XCTAssertNotNil(detailReleaseMetrics)
        detailReleaseContext.app.terminate()

        let windowResizeContext = configuredApp(
            runtimeRoot: runtimeRoot,
            requestName: "runtime.measure_window_resize"
        )
        let windowResizeStartedAt = Date()
        launch(windowResizeContext)
        assertVisibleScreen("screen.messages.list", in: windowResizeContext, timeout: 30)
        let windowResizeResponse = waitForAutomationResponse(
            at: windowResizeContext.responseURL,
            timeout: runtimeQualityUITimeout(default: 120),
            matching: { $0.ok }
        )
        let windowResizeMetrics = waitForRuntimeWindowResizeMetrics(
            at: windowResizeContext.eventsURL,
            timeout: runtimeQualityUITimeout(default: 120)
        )
        let windowResizeDuration = Date().timeIntervalSince(windowResizeStartedAt)
        XCTAssertNotNil(windowResizeResponse)
        XCTAssertNotNil(windowResizeMetrics)
        windowResizeContext.app.terminate()

        let detailContext = configuredApp(
            runtimeRoot: runtimeRoot,
            requestName: "message.open",
            args: ["message_id": "runtime-ui-msg-0"]
        )
        let detailStartedAt = Date()
        launch(detailContext)
        assertVisibleScreen("screen.message.detail", in: detailContext, timeout: 30)
        let detailResponse = waitForAutomationResponse(
            at: detailContext.responseURL,
            timeout: runtimeQualityUITimeout(default: 90),
            matching: { $0.ok }
        )
        let detailState = waitForAutomationState(
            at: detailContext.stateURL,
            timeout: runtimeQualityUITimeout(default: 90),
            matching: {
                $0.visibleScreen == "screen.message.detail"
                    && $0.openedMessageId == "runtime-ui-msg-0"
                    && ($0.runtimeErrorCount ?? 0) == 0
            }
        )
        let detailDuration = Date().timeIntervalSince(detailStartedAt)
        XCTAssertNotNil(detailResponse)
        XCTAssertNotNil(detailState)

        let commandStallTimeline = runtimeQualityCommandStallSummary(
            at: runtimeRoot.appendingPathComponent("automation-events.jsonl")
        )
        let topStallPhase = runtimeQualityTopStallPhaseSummary(
            at: runtimeRoot.appendingPathComponent("automation-events.jsonl")
        )
        XCTContext.runActivity(
            named: "[runtime-quality-ui] platform=macos scale=\(scale) fixtureGeneration=\(generationDuration)s launchImportListReady=\(readyDuration)s messageQueriesReady=\(queryDuration)s messageQueryMetrics=\(queryMetrics ?? [:]) sortModesReady=\(sortModeDuration)s sortModeMetrics=\(runtimeQualitySortModeSummary(from: sortModeMetrics)) detailVariantsReady=\(detailVariantDuration)s detailVariantMetrics=\(runtimeQualityDetailVariantSummary(from: detailVariantMetrics)) mediaCyclesReady=\(mediaCycleDuration)s mediaCycleMetrics=\(runtimeQualityMediaCycleSummary(from: mediaCycleMetrics)) detailReleaseReady=\(detailReleaseDuration)s detailReleaseMetrics=\(runtimeQualityDetailReleaseSummary(from: detailReleaseMetrics)) windowResizeReady=\(windowResizeDuration)s windowResizeMetrics=\(runtimeQualityWindowResizeSummary(from: windowResizeMetrics)) commandStallTimeline=\(commandStallTimeline) topStallPhase=\(topStallPhase) messageDetailReady=\(detailDuration)s totalMessageCount=\(state?.totalMessageCount ?? -1) residentMemoryBytes=\(detailState?.residentMemoryBytes ?? state?.residentMemoryBytes ?? 0) mainThreadMaxStallMs=\(detailState?.mainThreadMaxStallMilliseconds ?? state?.mainThreadMaxStallMilliseconds ?? -1)"
        ) { _ in }
        detailContext.app.terminate()
    }

    func testRuntimeQualityReservedMarkdownFixturesStayBelowGatewayBodyLimit() {
        let gatewayBodyLimitBytes = 32 * 1024
        let markdownSafetyCapBytes = 27 * 1024
        let fixtures: [(name: String, body: String)] = [
            ("baseline", runtimeQualityMarkdownBody(targetBytes: 2_048, label: "baseline", imageCount: 0, longLine: false)),
            ("markdown_10k", runtimeQualityMarkdownBody(targetBytes: 10_240, label: "markdown-10k", imageCount: 0, longLine: false)),
            ("markdown_26k", runtimeQualityMarkdownBody(targetBytes: 26_624, label: "markdown-26k", imageCount: 0, longLine: false)),
            ("media_rich", runtimeQualityMarkdownBody(targetBytes: 24_576, label: "media-rich", imageCount: 18, longLine: false)),
            ("longline_unicode", runtimeQualityMarkdownBody(targetBytes: 26_112, label: "longline-unicode", imageCount: 0, longLine: true)),
        ]

        for fixture in fixtures {
            XCTAssertLessThan(
                fixture.body.lengthOfBytes(using: .utf8),
                markdownSafetyCapBytes,
                "\(fixture.name) exceeded markdown safety cap"
            )
            XCTAssertLessThan(
                fixture.body.lengthOfBytes(using: .utf8),
                gatewayBodyLimitBytes,
                "\(fixture.name) exceeded gateway body limit"
            )
        }
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
    private func waitForRuntimeDetailVariantMetrics(
        at url: URL,
        timeout: TimeInterval
    ) -> [String: String]? {
        waitForAutomationEvent(
            at: url,
            timeout: timeout,
            matching: { event in
                guard (event["type"] as? String) == "runtime.detail_variants",
                      let details = event["details"] as? [String: Any]
                else { return false }
                return intValue(details["baseline_ms"]) >= 0
                    && intValue(details["markdown_10k_ms"]) >= 0
                    && intValue(details["markdown_26k_ms"]) >= 0
                    && intValue(details["media_rich_ms"]) >= 0
                    && intValue(details["longline_unicode_ms"]) >= 0
                    && intValue(details["baseline_repeat_ms"]) >= 0
            }
        )
        .flatMap { event in
            guard let details = event["details"] as? [String: Any] else { return nil }
            return details.reduce(into: [String: String]()) { result, entry in
                result[entry.key] = String(describing: entry.value)
            }
        }
    }

    @MainActor
    private func waitForRuntimeMessageQueryMetrics(
        at url: URL,
        timeout: TimeInterval
    ) -> [String: String]? {
        waitForAutomationEvent(
            at: url,
            timeout: timeout,
            matching: { event in
                guard (event["type"] as? String) == "runtime.message_queries",
                      let details = event["details"] as? [String: Any]
                else { return false }
                return intValue(details["first_page_count"]) == 50
                    && intValue(details["second_page_count"]) == 50
                    && intValue(details["unread_page_count"]) > 0
                    && intValue(details["tag_page_count"]) > 0
                    && intValue(details["search_count"]) > 0
                    && intValue(details["search_page_count"]) > 0
                    && intValue(details["first_page_ms"]) < 10_000
                    && intValue(details["second_page_ms"]) < 10_000
                    && intValue(details["unread_page_ms"]) < 10_000
                    && intValue(details["tag_page_ms"]) < 10_000
                    && intValue(details["search_count_ms"]) < 10_000
                    && intValue(details["search_page_ms"]) < 10_000
            }
        )
        .flatMap { event in
            guard let details = event["details"] as? [String: Any] else { return nil }
            return details.reduce(into: [String: String]()) { result, entry in
                result[entry.key] = String(describing: entry.value)
            }
        }
    }

    @MainActor
    private func waitForRuntimeSortModeMetrics(
        at url: URL,
        timeout: TimeInterval
    ) -> [String: String]? {
        waitForAutomationEvent(
            at: url,
            timeout: timeout,
            matching: { event in
                guard (event["type"] as? String) == "runtime.sort_modes",
                      let details = event["details"] as? [String: Any]
                else { return false }
                return intValue(details["query_time_desc_page_count"]) > 0
                    && intValue(details["query_unread_first_page_count"]) > 0
                    && intValue(details["query_time_desc_page_ms"]) >= 0
                    && intValue(details["query_unread_first_page_ms"]) >= 0
                    && intValue(details["viewmodel_set_sort_time_desc_ms"]) >= 0
                    && intValue(details["viewmodel_set_sort_unread_first_ms"]) >= 0
                    && intValue(details["ui_ready_time_desc_ms"]) >= 0
                    && intValue(details["ui_ready_unread_first_ms"]) >= 0
            }
        )
        .flatMap { event in
            guard let details = event["details"] as? [String: Any] else { return nil }
            return details.reduce(into: [String: String]()) { result, entry in
                result[entry.key] = String(describing: entry.value)
            }
        }
    }

    @MainActor
    private func waitForRuntimeMediaCycleMetrics(
        at url: URL,
        timeout: TimeInterval
    ) -> [String: String]? {
        waitForAutomationEvent(
            at: url,
            timeout: timeout,
            matching: { event in
                guard (event["type"] as? String) == "runtime.media_cycles",
                      let details = event["details"] as? [String: Any]
                else { return false }
                return intValue(details["iteration_count"]) >= 5
                    && intValue(details["first_open_ms"]) >= 0
                    && intValue(details["repeat_avg_ms"]) >= 0
                    && intValue(details["repeat_max_ms"]) >= 0
            }
        )
        .flatMap { event in
            guard let details = event["details"] as? [String: Any] else { return nil }
            return details.reduce(into: [String: String]()) { result, entry in
                result[entry.key] = String(describing: entry.value)
            }
        }
    }

    @MainActor
    private func waitForRuntimeDetailReleaseMetrics(
        at url: URL,
        timeout: TimeInterval
    ) -> [String: String]? {
        waitForAutomationEvent(
            at: url,
            timeout: timeout,
            matching: { event in
                guard (event["type"] as? String) == "runtime.detail_release_cycles",
                      let details = event["details"] as? [String: Any]
                else { return false }
                return intValue(details["cycles_per_scenario"]) == 20
                    && intValue(details["normal_avg_cycle_ms"]) >= 0
                    && intValue(details["markdown_26k_avg_cycle_ms"]) >= 0
                    && intValue(details["media_avg_cycle_ms"]) >= 0
            }
        )
        .flatMap { event in
            guard let details = event["details"] as? [String: Any] else { return nil }
            return details.reduce(into: [String: String]()) { result, entry in
                result[entry.key] = String(describing: entry.value)
            }
        }
    }

    @MainActor
    private func waitForRuntimeWindowResizeMetrics(
        at url: URL,
        timeout: TimeInterval
    ) -> [String: String]? {
        waitForAutomationEvent(
            at: url,
            timeout: timeout,
            matching: { event in
                guard (event["type"] as? String) == "runtime.window_resize",
                      let details = event["details"] as? [String: Any]
                else { return false }
                return intValue(details["step_count"]) >= 2
                    && intValue(details["step_0_ms"]) >= 0
                    && intValue(details["step_1_ms"]) >= 0
            }
        )
        .flatMap { event in
            guard let details = event["details"] as? [String: Any] else { return nil }
            return details.reduce(into: [String: String]()) { result, entry in
                result[entry.key] = String(describing: entry.value)
            }
        }
    }

    private func runtimeQualityDetailVariantSummary(from details: [String: String]?) -> String {
        guard let details else { return "missing" }
        let baseline = details["baseline_ms"] ?? "?"
        let baselineSource = details["baseline_source"] ?? "?"
        let markdown10k = details["markdown_10k_ms"] ?? "?"
        let markdown26k = details["markdown_26k_ms"] ?? "?"
        let mediaRich = details["media_rich_ms"] ?? "?"
        let longline = details["longline_unicode_ms"] ?? "?"
        let repeatOpen = details["baseline_repeat_ms"] ?? "?"
        let repeatSource = details["baseline_repeat_source"] ?? "?"
        let baselineStore = details["baseline_store_lookup_ms"] ?? "?"
        let baselineMarkdownPrepare = details["baseline_markdown_prepare_ms"] ?? "?"
        let baselineUIWait = details["baseline_ui_open_wait_ms"] ?? "?"
        return "baseline=\(baseline)ms/\(baselineSource) split=\(baselineStore)+\(baselineMarkdownPrepare)+\(baselineUIWait)ms md10k=\(markdown10k)ms md26k=\(markdown26k)ms media=\(mediaRich)ms longline=\(longline)ms repeat=\(repeatOpen)ms/\(repeatSource)"
    }

    private func runtimeQualitySortModeSummary(from details: [String: String]?) -> String {
        guard let details else { return "missing" }
        let queryTimeDesc = details["query_time_desc_page_ms"] ?? "?"
        let queryUnread = details["query_unread_first_page_ms"] ?? "?"
        let vmTimeDesc = details["viewmodel_set_sort_time_desc_ms"] ?? "?"
        let vmUnread = details["viewmodel_set_sort_unread_first_ms"] ?? "?"
        let uiTimeDesc = details["ui_ready_time_desc_ms"] ?? "?"
        let uiUnread = details["ui_ready_unread_first_ms"] ?? "?"
        return "query=\(queryTimeDesc)/\(queryUnread)ms vm=\(vmTimeDesc)/\(vmUnread)ms ui=\(uiTimeDesc)/\(uiUnread)ms"
    }

    private func runtimeQualityMediaCycleSummary(from details: [String: String]?) -> String {
        guard let details else { return "missing" }
        let first = details["first_open_ms"] ?? "?"
        let repeatAvg = details["repeat_avg_ms"] ?? "?"
        let repeatMax = details["repeat_max_ms"] ?? "?"
        let rssDelta = details["resident_memory_delta_bytes"] ?? "?"
        let rssPeakDelta = details["resident_memory_peak_delta_bytes"] ?? "?"
        let metadataMissDelta = details["markdown_attachment_metadata_miss_count_delta"] ?? "?"
        let metadataHitDelta = details["markdown_attachment_metadata_async_hit_count_delta"] ?? "?"
        let animatedDelta = details["markdown_attachment_animated_count_delta"] ?? "?"
        return "first=\(first)ms repeatAvg=\(repeatAvg)ms repeatMax=\(repeatMax)ms rssDelta=\(rssDelta) peakDelta=\(rssPeakDelta) mdMetaHit=\(metadataHitDelta) mdMetaMiss=\(metadataMissDelta) animated=\(animatedDelta)"
    }

    private func runtimeQualityDetailReleaseSummary(from details: [String: String]?) -> String {
        guard let details else { return "missing" }
        let normalAvg = details["normal_avg_cycle_ms"] ?? "?"
        let markdownAvg = details["markdown_26k_avg_cycle_ms"] ?? "?"
        let mediaAvg = details["media_avg_cycle_ms"] ?? "?"
        let mediaPeakDelta = details["media_resident_memory_peak_delta_bytes"] ?? "?"
        let mediaMetadataMiss = details["media_markdown_attachment_metadata_miss_count_delta"] ?? "?"
        let mediaAnimated = details["media_markdown_attachment_animated_count_delta"] ?? "?"
        return "normal=\(normalAvg)ms md26k=\(markdownAvg)ms media=\(mediaAvg)ms mediaPeakDelta=\(mediaPeakDelta) mediaMetaMiss=\(mediaMetadataMiss) mediaAnimated=\(mediaAnimated)"
    }

    private func runtimeQualityWindowResizeSummary(from details: [String: String]?) -> String {
        guard let details else { return "missing" }
        let step0 = details["step_0_ms"] ?? "?"
        let step1 = details["step_1_ms"] ?? "?"
        let step2 = details["step_2_ms"] ?? "?"
        return "steps=\(step0)/\(step1)/\(step2)ms"
    }

    private func runtimeQualityCommandStallSummary(at url: URL) -> String {
        let events = automationEvents(at: url)
        let segments = events.compactMap { event -> String? in
            guard (event["type"] as? String) == "runtime.command_metrics",
                  let command = event["command"] as? String,
                  let details = event["details"] as? [String: Any]
            else { return nil }
            let stallDelta = intValue(details["main_thread_stall_delta_ms"])
            let commandBodyMs = intValue(details["command_body_ms"])
            let stateWaitMs = intValue(details["state_wait_ms"])
            return "\(command):+\(stallDelta)ms(body=\(commandBodyMs)ms,wait=\(stateWaitMs)ms)"
        }
        return segments.joined(separator: "|")
    }

    private func runtimeQualityTopStallPhaseSummary(at url: URL) -> String {
        let events = automationEvents(at: url)
        let top = events.compactMap { event -> (String, String, Int)? in
            guard (event["type"] as? String) == "runtime.phase_marker",
                  let command = event["command"] as? String,
                  let details = event["details"] as? [String: Any],
                  let phase = details["phase"] as? String,
                  let status = details["status"] as? String,
                  status == "end" || status == "error" || status == "timeout"
            else { return nil }
            let stall = intValue(details["main_thread_max_stall_ms"])
            return (command, phase, stall)
        }.max { lhs, rhs in
            lhs.2 < rhs.2
        }
        guard let top else { return "none" }
        return "\(top.0):\(top.1)=\(top.2)ms"
    }

    private func intValue(_ value: Any?) -> Int {
        if let int = value as? Int {
            return int
        }
        if let string = value as? String,
           let int = Int(string.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return int
        }
        return -1
    }

    private func runtimeQualityUIScale(default defaultValue: Int) -> Int {
        guard let rawValue = ProcessInfo.processInfo.environment["PUSHGO_RUNTIME_QUALITY_UI_SCALE"],
              let value = Int(rawValue),
              value >= 0
        else {
            let markerURL = URL(fileURLWithPath: "/tmp/pushgo-runtime-quality-ui-scale")
            guard let markerValue = try? String(contentsOf: markerURL, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  let value = Int(markerValue),
                  value >= 0
            else {
                return defaultValue
            }
            return value
        }
        return value
    }

    private func runtimeQualityUIEnabled() -> Bool {
        if ProcessInfo.processInfo.environment["PUSHGO_RUNTIME_QUALITY_UI"] == "1" {
            return true
        }
        let markerPath = "/tmp/pushgo-runtime-quality-ui.enabled"
        guard FileManager.default.fileExists(atPath: markerPath) else { return false }
        try? FileManager.default.removeItem(atPath: markerPath)
        return true
    }

    private func runtimeQualityUITimeout(default defaultValue: TimeInterval) -> TimeInterval {
        guard let rawValue = ProcessInfo.processInfo.environment["PUSHGO_RUNTIME_QUALITY_UI_TIMEOUT"],
              let value = TimeInterval(rawValue),
              value > 0
        else {
            return defaultValue
        }
        return value
    }

    private func writeRuntimeQualityUIFixture(messageCount: Int, to url: URL) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer {
            try? handle.close()
        }

        try handle.write(contentsOf: Data(#"{"messages":["#.utf8))
        for index in 0..<messageCount {
            if index > 0 {
                try handle.write(contentsOf: Data(",".utf8))
            }
            let message = runtimeQualityUIMessage(index: index)
            let data = try JSONSerialization.data(withJSONObject: message, options: [])
            try handle.write(contentsOf: data)
        }
        try handle.write(contentsOf: Data(#"],"entity_records":[],"channel_subscriptions":[]}"#.utf8))
    }

    private func runtimeQualityUIMessage(index: Int) -> [String: Any] {
        if let reserved = runtimeQualityUIReservedMessage(index: index) {
            return reserved
        }
        let kind = index % 10
        let entityType: String?
        switch kind {
        case 1:
            entityType = "event"
        case 2, 3:
            entityType = "thing"
        default:
            entityType = nil
        }
        let entityID = entityType.map { "\($0)-runtime-\(index % 2_000)" }
        var payload: [String: Any] = [
            "runtime_quality": true,
            "scenario": runtimeQualityUIScenario(index: index),
            "tags": runtimeQualityUITags(index: index),
            "markdown": "## Runtime quality \(index)\n\n- list row\n- detail body\n\nhttps://example.com/pushgo/\(index)",
            "op_id": "runtime-op-\(index % 7_500)",
        ]
        if let entityType, let entityID {
            payload["entity_type"] = entityType
            payload["entity_id"] = entityID
            if entityType == "event" {
                payload["event_id"] = entityID
            } else if entityType == "thing" {
                payload["thing_id"] = entityID
            }
        }
        if index % 10 == 4 {
            payload["task_id"] = "task-runtime-\(index % 1_000)"
            payload["task_state"] = ["todo", "doing", "blocked", "done"][index % 4]
        }

        return [
            "id": runtimeQualityUUID(index: index),
            "message_id": "runtime-ui-msg-\(index)",
            "title": runtimeQualityUITitle(index: index),
            "body": runtimeQualityUIBody(index: index),
            "channel_id": "runtime-channel-\(index % 32)",
            "url": "https://example.com/pushgo/runtime/\(index)",
            "is_read": index % 3 == 0,
            "received_at": runtimeQualityISO8601Date(offsetSeconds: index),
            "raw_payload": payload,
            "status": "normal",
        ]
    }

    private func runtimeQualityUIReservedMessage(index: Int) -> [String: Any]? {
        switch index {
        case 0:
            return runtimeQualityUIReservedMessage(
                index: index,
                title: "Runtime baseline detail",
                body: runtimeQualityMarkdownBody(targetBytes: 2_048, label: "baseline", imageCount: 0, longLine: false),
                scenario: "baseline_detail"
            )
        case 1:
            return runtimeQualityUIReservedMessage(
                index: index,
                title: "Runtime markdown 10KB",
                body: runtimeQualityMarkdownBody(targetBytes: 10_240, label: "markdown-10k", imageCount: 0, longLine: false),
                scenario: "markdown_10k"
            )
        case 2:
            return runtimeQualityUIReservedMessage(
                index: index,
                title: "Runtime markdown 26KB",
                body: runtimeQualityMarkdownBody(targetBytes: 26_624, label: "markdown-26k", imageCount: 0, longLine: false),
                scenario: "markdown_26k"
            )
        case 3:
            return runtimeQualityUIReservedMessage(
                index: index,
                title: "Runtime media rich detail",
                body: runtimeQualityMarkdownBody(targetBytes: 24_576, label: "media-rich", imageCount: 18, longLine: false),
                scenario: "media_rich"
            )
        case 4:
            return runtimeQualityUIReservedMessage(
                index: index,
                title: "Runtime long line unicode",
                body: runtimeQualityMarkdownBody(targetBytes: 27_648, label: "longline-unicode", imageCount: 0, longLine: true),
                scenario: "longline_unicode"
            )
        default:
            return nil
        }
    }

    private func runtimeQualityUIReservedMessage(
        index: Int,
        title: String,
        body: String,
        scenario: String
    ) -> [String: Any] {
        let payload: [String: Any] = [
            "runtime_quality": true,
            "scenario": scenario,
            "tags": runtimeQualityUITags(index: index),
            "markdown": body,
            "op_id": "runtime-op-reserved-\(index)",
        ]
        return [
            "id": runtimeQualityUUID(index: index),
            "message_id": "runtime-ui-msg-\(index)",
            "title": title,
            "body": body,
            "channel_id": "runtime-channel-\(index % 32)",
            "url": "https://example.com/pushgo/runtime/\(index)",
            "is_read": false,
            "received_at": runtimeQualityISO8601Date(offsetSeconds: index),
            "raw_payload": payload,
            "status": "normal",
        ]
    }

    private func runtimeQualityMarkdownBody(
        targetBytes: Int,
        label: String,
        imageCount: Int,
        longLine: Bool
    ) -> String {
        let imageRefs = imageCount > 0
            ? (0..<imageCount).map { imageIndex in
                "![render-\(imageIndex)](https://runtime-quality.example.com/assets/\(label)-\(imageIndex).png)"
            }.joined(separator: "\n")
            : nil
        let longLineSection = longLine
            ? String(repeating: "LongLine-\(label)-0123456789中文日本語한국어عربى", count: 320)
            : nil
        let reservedTailSections = [imageRefs, longLineSection].compactMap { $0 }
        let reservedTailBytes = reservedTailSections.reduce(0) { partialResult, section in
            partialResult + section.lengthOfBytes(using: .utf8) + 2
        }
        let sectionBudget = max(1_024, targetBytes - reservedTailBytes)
        var sections: [String] = []
        sections.reserveCapacity(max(8, targetBytes / 512))
        var accumulatedBytes = 0
        var sectionIndex = 0
        while accumulatedBytes < sectionBudget {
            let section = runtimeQualityMarkdownSection(label: label, sectionIndex: sectionIndex)
            sections.append(section)
            accumulatedBytes += section.lengthOfBytes(using: .utf8) + 2
            sectionIndex += 1
        }
        sections.append(contentsOf: reservedTailSections)
        return sections.joined(separator: "\n\n")
    }

    private func runtimeQualityMarkdownSection(label: String, sectionIndex: Int) -> String {
        """
        ## \(label) section \(sectionIndex)

        - runtime quality detail rendering
        - unicode 中文 English 日本語 한국어 عربى
        - repeated links https://example.com/pushgo/\(label)/\(sectionIndex)

        | field | value |
        | --- | --- |
        | label | \(label) |
        | section | \(sectionIndex) |
        | mode | render-profile |

        ```json
        {"label":"\(label)","section":\(sectionIndex),"mode":"render-profile"}
        ```

        > This profile is intentionally dense to exercise markdown layout, line wrapping, tables, and code blocks.
        """
    }

    private func runtimeQualityUITitle(index: Int) -> String {
        switch index % 8 {
        case 0:
            return "Runtime quality alert \(index)"
        case 1:
            return "发布流程检查 \(index)"
        case 2:
            return "イベント更新 \(index)"
        case 3:
            return "تنبيه تشغيل \(index)"
        default:
            return "Message \(index)"
        }
    }

    private func runtimeQualityUIBody(index: Int) -> String {
        if index % 17 == 0 {
            return String(repeating: "Long markdown body \(index) ", count: 40)
        }
        if index % 13 == 0 {
            return "Mixed Unicode body \(index): 中文 English 日本語 한국어 عربى"
        }
        return "Runtime quality body \(index) with https://example.com and list/detail content."
    }

    private func runtimeQualityUITags(index: Int) -> [String] {
        var tags = ["runtimequality", "channel-\(index % 32)"]
        if index % 10 == 4 {
            tags.append("task")
        }
        if index % 7 == 0 {
            tags.append("url")
        }
        return tags
    }

    private func runtimeQualityUIScenario(index: Int) -> String {
        let scenarios = [
            "normal",
            "unicode_mixed",
            "rtl_text",
            "long_markdown",
            "task_like",
            "same_timestamp",
            "out_of_order",
            "duplicate_identity",
        ]
        return scenarios[index % scenarios.count]
    }

    private func runtimeQualityUUID(index: Int) -> String {
        String(format: "00000000-0000-4000-8000-%012x", index)
    }

    private func runtimeQualityISO8601Date(offsetSeconds: Int) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let baseTimestamp = 1_767_225_600
        return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(baseTimestamp - offsetSeconds)))
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
