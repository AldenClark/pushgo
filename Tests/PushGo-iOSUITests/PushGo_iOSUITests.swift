import XCTest
import os

private enum PushGoIOSUITestRuntimeRoots {
    private static let roots = OSAllocatedUnfairLock<[URL]>(initialState: [])

    static func append(_ root: URL) {
        roots.withLock { roots in
            roots.append(root)
        }
    }

    static func consumeAll() -> [URL] {
        roots.withLock { roots in
            defer { roots.removeAll() }
            return roots
        }
    }
}

@MainActor
final class PushGo_iOSUITests: XCTestCase {
    private struct AutomationState: Decodable {
        let activeTab: String?
        let visibleScreen: String?
        let openedMessageId: String?
        let unreadMessageCount: Int?
        let openedEntityType: String?
        let openedEntityId: String?
        let messagePageEnabled: Bool?
        let eventPageEnabled: Bool?
        let thingPageEnabled: Bool?
        let notificationKeyConfigured: Bool?
        let notificationKeyEncoding: String?
        let eventCount: Int?
        let thingCount: Int?
        let totalMessageCount: Int?
        let channelCount: Int?
        let gatewayBaseURL: String?
        let gatewayTokenPresent: Bool?
        let watchMode: String?
        let lastNotificationAction: String?
        let lastNotificationTarget: String?
        let lastFixtureImportEntityRecordCount: Int?
        let lastFixtureImportSubscriptionCount: Int?
        let runtimeErrorCount: Int?
        let localStoreMode: String?
        let lastFixtureImportMessageCount: Int?
        let residentMemoryBytes: UInt64?
        let mainThreadMaxStallMilliseconds: Int?

        private enum CodingKeys: String, CodingKey {
            case activeTab = "active_tab"
            case visibleScreen = "visible_screen"
            case openedMessageId = "opened_message_id"
            case unreadMessageCount = "unread_message_count"
            case openedEntityType = "opened_entity_type"
            case openedEntityId = "opened_entity_id"
            case messagePageEnabled = "message_page_enabled"
            case eventPageEnabled = "event_page_enabled"
            case thingPageEnabled = "thing_page_enabled"
            case notificationKeyConfigured = "notification_key_configured"
            case notificationKeyEncoding = "notification_key_encoding"
            case eventCount = "event_count"
            case thingCount = "thing_count"
            case totalMessageCount = "total_message_count"
            case channelCount = "channel_count"
            case gatewayBaseURL = "gateway_base_url"
            case gatewayTokenPresent = "gateway_token_present"
            case watchMode = "watch_mode"
            case lastNotificationAction = "last_notification_action"
            case lastNotificationTarget = "last_notification_target"
            case lastFixtureImportEntityRecordCount = "last_fixture_import_entity_record_count"
            case lastFixtureImportSubscriptionCount = "last_fixture_import_subscription_count"
            case runtimeErrorCount = "runtime_error_count"
            case localStoreMode = "local_store_mode"
            case lastFixtureImportMessageCount = "last_fixture_import_message_count"
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

    private struct LocalizationSpec {
        let code: String
        let localeIdentifier: String
    }

    private struct ScreenshotPage {
        let id: String
        let visibleScreen: String
        let requestName: String?
        let requestArgs: [String: String]
    }

    private struct LocalizationFixture: Decodable {
        struct Message: Decodable {
            struct RawPayload: Decodable {
                let entityType: String?
                let entityID: String?

                private enum CodingKeys: String, CodingKey {
                    case entityType = "entity_type"
                    case entityID = "entity_id"
                }
            }

            let id: String
            let messageID: String
            let rawPayload: RawPayload?

            private enum CodingKeys: String, CodingKey {
                case id
                case messageID = "message_id"
                case rawPayload = "raw_payload"
            }
        }

        let messages: [Message]
    }

    private struct LocalizationFixtureIDs {
        let messageID: String
        let eventID: String
        let thingID: String
    }


    private let eventFixturePath = fixturePath("event-lifecycle.json")
    private let eventFixtureId = "evt_p2_active_001"
    private let thingFixturePath = fixturePath("rich-thing-detail.json")
    private let thingFixtureId = "thing_p2_rich_001"
    private let messageSeedFixturePath = fixturePath("seed-split.json")
    private let entityRecordFixturePath = fixturePath("seed-entity-records.json")
    private let subscriptionFixturePath = fixturePath("seed-subscriptions.json")
    private let seedMessageId = "msg_p2_seed_001"
    private let localizationSpecs: [LocalizationSpec] = [
        .init(code: "en", localeIdentifier: "en_US"),
        .init(code: "de", localeIdentifier: "de_DE"),
        .init(code: "es", localeIdentifier: "es_ES"),
        .init(code: "fr", localeIdentifier: "fr_FR"),
        .init(code: "ja", localeIdentifier: "ja_JP"),
        .init(code: "ko", localeIdentifier: "ko_KR"),
        .init(code: "zh-CN", localeIdentifier: "zh_CN"),
        .init(code: "zh-TW", localeIdentifier: "zh_TW"),
    ]

    private func localizationShowcaseFixturePath(for localization: LocalizationSpec) -> String {
        Self.fixturePath("localization-showcase.\(localization.code).json")
    }
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
        for runtimeRoot in PushGoIOSUITestRuntimeRoots.consumeAll() {
            try? fileManager.removeItem(at: runtimeRoot)
        }
    }

    func testLaunchesIntoMessageList() {
        let context = configuredLaunchContext()
        launch(context.app)

        assertVisibleScreen("screen.messages.list", in: context)
    }

    func testAutomationRequestCanOpenChannelsScreen() {
        let context = configuredLaunchContext(
            requestName: "nav.switch_tab",
            args: ["tab": "channels"]
        )
        launch(context.app)

        assertVisibleScreen("screen.channels", in: context)
        XCTAssertTrue(element(in: context.app, identifier: "screen.channels").waitForExistence(timeout: 8))
    }

    func testNavSwitchTabMatrixCoversPrimaryScreens() {
        let routeMatrix: [(tab: String, screen: String)] = [
            ("messages", "screen.messages.list"),
            ("events", "screen.events.list"),
            ("things", "screen.things.list"),
            ("channels", "screen.channels"),
        ]
        for route in routeMatrix {
            let context = configuredLaunchContext(
                requestName: "nav.switch_tab",
                args: ["tab": route.tab]
            )
            launch(context.app)
            assertVisibleScreen(route.screen, in: context, timeout: 12)
            context.app.terminate()
        }
    }

    func testImportedEventFixtureCanOpenEventDetail() {
        let context = configuredLaunchContext(
            startupFixturePath: eventFixturePath,
            requestName: "entity.open",
            args: ["entity_type": "event", "entity_id": eventFixtureId]
        )
        launch(context.app)

        assertVisibleScreen("screen.events.detail", in: context)
        XCTAssertNotNil(waitForAutomationResponse(at: context.responseURL, timeout: 12, matching: { $0.ok }))
        XCTAssertNotNil(
            waitForAutomationEvent(
                at: context.eventsURL,
                timeout: 12,
                matching: { event in
                    guard (event["type"] as? String) == "entity.opened",
                          let details = event["details"] as? [String: Any]
                    else { return false }
                    return (details["entity_type"] as? String) == "event"
                        && (details["entity_id"] as? String) == self.eventFixtureId
                }
            )
        )
        XCTAssertTrue(waitForFileNonEmpty(context.eventsURL, timeout: 10))
    }

    func testImportedThingFixtureCanOpenThingDetail() {
        let context = configuredLaunchContext(
            startupFixturePath: thingFixturePath,
            requestName: "entity.open",
            args: ["entity_type": "thing", "entity_id": thingFixtureId]
        )
        launch(context.app)

        assertVisibleScreen("screen.things.detail", in: context)
        XCTAssertNotNil(waitForAutomationResponse(at: context.responseURL, timeout: 12, matching: { $0.ok }))
        XCTAssertNotNil(
            waitForAutomationEvent(
                at: context.eventsURL,
                timeout: 12,
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

    func testPushSettingsCanOpenDecryptionScreen() {
        let context = configuredLaunchContext(
            requestName: "settings.open_decryption"
        )
        launch(context.app)

        assertVisibleScreen("screen.settings.decryption", in: context, timeout: 15)
        XCTAssertNotNil(waitForAutomationResponse(at: context.responseURL, timeout: 12, matching: { $0.ok }))
    }

    func testFixtureSeedMessagesRefreshesMessageList() {
        let context = configuredLaunchContext(
            requestName: "fixture.seed_messages",
            args: ["path": messageSeedFixturePath]
        )
        launch(context.app)

        assertVisibleScreen("screen.messages.list", in: context)
        XCTAssertNotNil(
            waitForAutomationState(
                at: context.stateURL,
                timeout: 12,
                matching: {
                    $0.lastFixtureImportMessageCount == 1
                        && ($0.totalMessageCount ?? 0) >= 1
                }
            )
        )
        XCTAssertNotNil(
            waitForAutomationEvent(
                at: context.eventsURL,
                timeout: 12,
                matching: { event in
                    guard (event["type"] as? String) == "fixture.imported",
                          let details = event["details"] as? [String: Any],
                          let messageCount = details["message_count"] as? String
                    else { return false }
                    return messageCount == "1"
                }
            )
        )
        XCTAssertNotNil(
            waitForAutomationResponse(
                at: context.responseURL,
                timeout: 12,
                matching: { $0.ok }
            )
        )
    }

    func testFixtureSeedEntityRecordsPublishesProjectionCounts() {
        let context = configuredLaunchContext(
            requestName: "fixture.seed_entity_records",
            args: ["path": entityRecordFixturePath]
        )
        launch(context.app)

        assertVisibleScreen("screen.messages.list", in: context)
        XCTAssertNotNil(
            waitForAutomationState(
                at: context.stateURL,
                timeout: 12,
                matching: {
                    $0.lastFixtureImportEntityRecordCount == 2
                        && ($0.eventCount ?? 0) >= 1
                        && ($0.thingCount ?? 0) >= 1
                }
            )
        )
        XCTAssertNotNil(
            waitForAutomationEvent(
                at: context.eventsURL,
                timeout: 12,
                matching: { event in
                    guard (event["type"] as? String) == "fixture.imported",
                          let details = event["details"] as? [String: Any],
                          let entityRecordCount = details["entity_record_count"] as? String
                    else { return false }
                    return entityRecordCount == "2"
                }
            )
        )
        XCTAssertNotNil(waitForAutomationResponse(at: context.responseURL, timeout: 12, matching: { $0.ok }))
    }

    func testFixtureSeedSubscriptionsPublishesImportState() {
        let context = configuredLaunchContext(
            requestName: "fixture.seed_subscriptions",
            args: ["path": subscriptionFixturePath]
        )
        launch(context.app)

        assertVisibleScreen("screen.messages.list", in: context)
        XCTAssertNotNil(
            waitForAutomationState(
                at: context.stateURL,
                timeout: 12,
                matching: {
                    $0.lastFixtureImportSubscriptionCount == 2
                        && ($0.runtimeErrorCount ?? 0) == 0
                        && $0.localStoreMode != "unavailable"
                }
            )
        )
        XCTAssertNotNil(
            waitForAutomationEvent(
                at: context.eventsURL,
                timeout: 12,
                matching: { event in
                    guard (event["type"] as? String) == "fixture.imported",
                          let details = event["details"] as? [String: Any],
                          let subscriptionCount = details["subscription_count"] as? String
                    else { return false }
                    return subscriptionCount == "2"
                }
            )
        )
        XCTAssertNotNil(waitForAutomationResponse(at: context.responseURL, timeout: 12, matching: { $0.ok }))
    }

    func testSettingsPageVisibilityCommandCanHideEventPage() {
        let context = configuredLaunchContext(
            requestName: "settings.set_page_visibility",
            args: ["page": "events", "enabled": "false"]
        )
        launch(context.app)

        let state = waitForAutomationState(
            at: context.stateURL,
            timeout: 12,
            matching: { $0.eventPageEnabled == false }
        )
        XCTAssertNotNil(state)
        XCTAssertNotNil(waitForAutomationResponse(at: context.responseURL, timeout: 12, matching: { $0.ok }))
        XCTAssertNotNil(
            waitForAutomationEvent(
                at: context.eventsURL,
                timeout: 12,
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
        XCTAssertTrue(waitForFileNonEmpty(context.eventsURL, timeout: 8))
    }

    func testSettingsPageVisibilityCommandCanRoundTripEventPage() {
        let sharedRuntimeRoot = makeRuntimeRoot()
        let disableContext = configuredLaunchContext(
            runtimeRoot: sharedRuntimeRoot,
            requestName: "settings.set_page_visibility",
            args: ["page": "events", "enabled": "false"]
        )
        launch(disableContext.app)
        let disabledState = waitForAutomationState(
            at: disableContext.stateURL,
            timeout: 12,
            matching: { $0.eventPageEnabled == false }
        )
        XCTAssertNotNil(disabledState)
        XCTAssertTrue(
            waitForAutomationResponse(
                at: disableContext.responseURL,
                timeout: 12,
                matching: { $0.ok }
            ) != nil
        )
        XCTAssertNotNil(
            waitForAutomationEvent(
                at: disableContext.eventsURL,
                timeout: 12,
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

        let enableContext = configuredLaunchContext(
            runtimeRoot: sharedRuntimeRoot,
            requestName: "settings.set_page_visibility",
            args: ["page": "events", "enabled": "true"]
        )
        launch(enableContext.app)
        let enabledState = waitForAutomationState(
            at: enableContext.stateURL,
            timeout: 12,
            matching: { $0.eventPageEnabled == true }
        )
        XCTAssertNotNil(enabledState)
        XCTAssertTrue(
            waitForAutomationResponse(
                at: enableContext.responseURL,
                timeout: 12,
                matching: { $0.ok }
            ) != nil
        )
        XCTAssertNotNil(
            waitForAutomationEvent(
                at: enableContext.eventsURL,
                timeout: 12,
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

    func testEntityOpenPublishesEntityStateAndProjectionCounts() {
        let eventContext = configuredLaunchContext(
            startupFixturePath: eventFixturePath,
            requestName: "entity.open",
            args: ["entity_type": "event", "entity_id": eventFixtureId]
        )
        launch(eventContext.app)
        let eventState = waitForAutomationState(
            at: eventContext.stateURL,
            timeout: 15,
            matching: { state in
                state.visibleScreen == "screen.events.detail"
                    && state.openedEntityType == "event"
            }
        )
        XCTAssertNotNil(eventState)
        XCTAssertNotNil(waitForAutomationResponse(at: eventContext.responseURL, timeout: 12, matching: { $0.ok }))
        XCTAssertNotNil(
            waitForAutomationEvent(
                at: eventContext.eventsURL,
                timeout: 12,
                matching: { event in
                    guard (event["type"] as? String) == "entity.opened",
                          let details = event["details"] as? [String: Any]
                    else { return false }
                    return (details["entity_type"] as? String) == "event"
                        && (details["entity_id"] as? String) == self.eventFixtureId
                }
            )
        )

        let thingContext = configuredLaunchContext(
            startupFixturePath: thingFixturePath,
            requestName: "entity.open",
            args: ["entity_type": "thing", "entity_id": thingFixtureId]
        )
        launch(thingContext.app)
        let thingState = waitForAutomationState(
            at: thingContext.stateURL,
            timeout: 15,
            matching: { state in
                state.visibleScreen == "screen.things.detail"
                    && state.openedEntityType == "thing"
            }
        )
        XCTAssertNotNil(thingState)
        XCTAssertNotNil(waitForAutomationResponse(at: thingContext.responseURL, timeout: 12, matching: { $0.ok }))
        XCTAssertNotNil(
            waitForAutomationEvent(
                at: thingContext.eventsURL,
                timeout: 12,
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

    func testMessageOpenPublishesMessageDetailState() {
        let context = configuredLaunchContext(
            startupFixturePath: messageSeedFixturePath,
            requestName: "message.open",
            args: ["message_id": seedMessageId]
        )
        launch(context.app)

        assertVisibleScreen("screen.message.detail", in: context)
        XCTAssertNotNil(
            waitForAutomationState(
                at: context.stateURL,
                timeout: 12,
                matching: {
                    $0.visibleScreen == "screen.message.detail"
                        && $0.openedMessageId == self.seedMessageId
                }
            )
        )
        XCTAssertNotNil(waitForAutomationResponse(at: context.responseURL, timeout: 12, matching: { $0.ok }))
        XCTAssertNotNil(
            waitForAutomationEvent(
                at: context.eventsURL,
                timeout: 12,
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

    func testNotificationOpenPublishesMessageDetailState() {
        let context = configuredLaunchContext(
            startupFixturePath: messageSeedFixturePath,
            requestName: "notification.open",
            args: ["message_id": seedMessageId]
        )
        launch(context.app)

        assertVisibleScreen("screen.message.detail", in: context)
        XCTAssertNotNil(
            waitForAutomationState(
                at: context.stateURL,
                timeout: 12,
                matching: {
                    $0.visibleScreen == "screen.message.detail"
                        && $0.openedMessageId == self.seedMessageId
                }
            )
        )
        XCTAssertNotNil(waitForAutomationResponse(at: context.responseURL, timeout: 12, matching: { $0.ok }))
    }

    func testNotificationMarkReadCommandUpdatesUnreadState() {
        let context = configuredLaunchContext(
            startupFixturePath: messageSeedFixturePath,
            requestName: "notification.mark_read",
            args: ["message_id": seedMessageId]
        )
        launch(context.app)

        XCTAssertNotNil(
            waitForAutomationState(
                at: context.stateURL,
                timeout: 12,
                matching: {
                    $0.unreadMessageCount == 0
                        && $0.lastNotificationAction == "mark_read"
                        && $0.lastNotificationTarget == self.seedMessageId
                }
            )
        )
        XCTAssertNotNil(waitForAutomationResponse(at: context.responseURL, timeout: 12, matching: { $0.ok }))
        XCTAssertNotNil(
            waitForAutomationEvent(
                at: context.eventsURL,
                timeout: 12,
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

    func testNotificationDeleteCommandUpdatesCounts() {
        let context = configuredLaunchContext(
            startupFixturePath: messageSeedFixturePath,
            requestName: "notification.delete",
            args: ["message_id": seedMessageId]
        )
        launch(context.app)

        XCTAssertNotNil(
            waitForAutomationState(
                at: context.stateURL,
                timeout: 12,
                matching: {
                    $0.totalMessageCount == 0
                        && $0.lastNotificationAction == "delete"
                        && $0.lastNotificationTarget == self.seedMessageId
                }
            )
        )
        XCTAssertNotNil(waitForAutomationResponse(at: context.responseURL, timeout: 12, matching: { $0.ok }))
        XCTAssertNotNil(
            waitForAutomationEvent(
                at: context.eventsURL,
                timeout: 12,
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

    func testGatewaySetServerCommandUpdatesConfigurationState() {
        let context = configuredLaunchContext(
            requestName: "gateway.set_server",
            args: [
                "base_url": "https://pushgo.example.test",
                "token": "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
            ]
        )
        launch(context.app)

        XCTAssertNotNil(
            waitForAutomationState(
                at: context.stateURL,
                timeout: 12,
                matching: {
                    $0.gatewayBaseURL == "https://pushgo.example.test"
                        && $0.gatewayTokenPresent == true
                }
            )
        )
        XCTAssertNotNil(waitForAutomationResponse(at: context.responseURL, timeout: 12, matching: { $0.ok }))
        XCTAssertNotNil(
            waitForAutomationEvent(
                at: context.eventsURL,
                timeout: 12,
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

    func testBaselineAutomationStateHasNoRuntimeErrors() {
        let context = configuredLaunchContext()
        launch(context.app)

        let state = waitForAutomationState(
            at: context.stateURL,
            timeout: 12,
            matching: { $0.visibleScreen == "screen.messages.list" && $0.runtimeErrorCount != nil }
        )
        XCTAssertNotNil(state)
        XCTAssertEqual(state?.runtimeErrorCount, 0)
        XCTAssertEqual(state?.localStoreMode, "persistent")
    }

    func testWatchSetModeMirrorCommandPublishesMirrorState() {
        let context = configuredLaunchContext(
            requestName: "watch.set_mode",
            args: ["mode": "mirror"]
        )
        launch(context.app)

        XCTAssertNotNil(
            waitForAutomationState(
                at: context.stateURL,
                timeout: 12,
                matching: { $0.watchMode == "mirror" }
            )
        )
        XCTAssertNotNil(waitForAutomationResponse(at: context.responseURL, timeout: 12, matching: { $0.ok }))
    }

    func testSettingsSetDecryptionKeyRejectsInvalidLength() {
        let context = configuredLaunchContext(
            requestName: "settings.set_decryption_key",
            args: ["key": "abcd", "encoding": "plain"]
        )
        launch(context.app)

        let response = waitForAutomationResponse(
            at: context.responseURL,
            timeout: 12,
            matching: { !$0.ok }
        )
        XCTAssertNotNil(response)
        XCTAssertTrue(response?.error?.contains("key") == true)
    }

    func testSettingsSetDecryptionKeyAcceptsBase64Key() {
        let context = configuredLaunchContext(
            requestName: "settings.set_decryption_key",
            args: ["key": "MDEyMzQ1Njc4OWFiY2RlZg==", "encoding": "base64"]
        )
        launch(context.app)

        let response = waitForAutomationResponse(
            at: context.responseURL,
            timeout: 12,
            matching: { $0.ok }
        )
        XCTAssertNotNil(response)
        XCTAssertTrue(
            waitForStateBool(
                at: context.stateURL,
                key: "notification_key_configured",
                equals: true,
                timeout: 12
            )
        )
        XCTAssertTrue(
            waitForStateString(
                at: context.stateURL,
                key: "notification_key_encoding",
                equals: "base64",
                timeout: 12
            )
        )
    }

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

        let context = configuredLaunchContext(
            runtimeRoot: runtimeRoot,
            requestName: "fixture.seed_messages",
            args: ["path": fixtureURL.path]
        )
        let launchStartedAt = Date()
        launch(context.app)
        assertVisibleScreen("screen.messages.list", in: context, timeout: 30)

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

        let scrollStartedAt = Date()
        let messageListElement = runtimeQualityScrollableList(in: context.app)
        XCTAssertTrue(messageListElement.waitForExistence(timeout: 10))
        for _ in 0..<6 {
            messageListElement.swipeUp()
            RunLoop.current.run(until: Date().addingTimeInterval(0.12))
        }
        assertVisibleScreen("screen.messages.list", in: context, timeout: 8)
        let scrollDuration = Date().timeIntervalSince(scrollStartedAt)

        let foregroundRecoveryStartedAt = Date()
        XCUIDevice.shared.press(.home)
        _ = context.app.wait(for: .runningBackground, timeout: 10)
        context.app.activate()
        assertVisibleScreen("screen.messages.list", in: context, timeout: 20)
        XCTAssertNotNil(
            waitForAutomationState(
                at: context.stateURL,
                timeout: runtimeQualityUITimeout(default: 30),
                matching: {
                    ($0.totalMessageCount ?? 0) > 0
                        && ($0.runtimeErrorCount ?? 0) == 0
                }
            )
        )
        let foregroundRecoveryDuration = Date().timeIntervalSince(foregroundRecoveryStartedAt)

        let searchStartedAt = Date()
        let searchField = runtimeQualitySearchField(in: context.app)
        XCTAssertTrue(searchField.waitForExistence(timeout: 10))
        searchField.tap()
        let runtimeQualitySearchQuery = "Runtime quality"
        searchField.typeText(runtimeQualitySearchQuery)
        let searchEvent = waitForAutomationEvent(
            at: context.eventsURL,
            timeout: runtimeQualityUITimeout(default: 30),
            matching: { event in
                guard (event["type"] as? String) == "search.results_updated",
                      let details = event["details"] as? [String: Any],
                      (details["search_query"] as? String) == runtimeQualitySearchQuery,
                      let rawCount = details["result_count"] as? String,
                      let resultCount = Int(rawCount)
                else { return false }
                return resultCount > 0
            }
        )
        XCTAssertNotNil(searchEvent)
        let searchDuration = Date().timeIntervalSince(searchStartedAt)

        context.app.terminate()

        let filterContext = configuredLaunchContext(
            runtimeRoot: runtimeRoot,
            requestName: "fixture.seed_messages",
            args: ["path": fixtureURL.path]
        )
        let filterStartedAt = Date()
        launch(filterContext.app)
        assertVisibleScreen("screen.messages.list", in: filterContext, timeout: 30)
        XCTAssertNotNil(
            waitForAutomationState(
                at: filterContext.stateURL,
                timeout: runtimeQualityUITimeout(default: 90),
                matching: {
                    $0.lastFixtureImportMessageCount == scale
                        && ($0.totalMessageCount ?? 0) > 0
                        && ($0.runtimeErrorCount ?? 0) == 0
                }
            )
        )
        let filterButton = element(in: filterContext.app, identifier: "action.messages.filter")
        XCTAssertTrue(filterButton.waitForExistence(timeout: 10))
        filterButton.tap()
        let tagFilter = runtimeQualityFilterTag(
            "filter.tag.runtimequality",
            title: "runtimequality",
            in: filterContext.app
        )
        XCTAssertTrue(tagFilter.waitForExistence(timeout: 10))
        tagFilter.tap()
        assertVisibleScreen("screen.messages.list", in: filterContext, timeout: 8)
        XCTAssertNotNil(
            waitForAutomationState(
                at: filterContext.stateURL,
                timeout: 8,
                matching: { ($0.runtimeErrorCount ?? 0) == 0 }
            )
        )
        let filterDuration = Date().timeIntervalSince(filterStartedAt)
        filterContext.app.terminate()

        let queryContext = configuredLaunchContext(
            runtimeRoot: runtimeRoot,
            requestName: "runtime.measure_message_queries"
        )
        let queryStartedAt = Date()
        launch(queryContext.app)
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

        let sortModeContext = configuredLaunchContext(
            runtimeRoot: runtimeRoot,
            requestName: "runtime.measure_sort_modes"
        )
        let sortModeStartedAt = Date()
        launch(sortModeContext.app)
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
        writeRuntimeQualityPartialMetrics(
            at: runtimeRoot,
            stage: "sort_modes",
            metrics: [
                "platform": "ios",
                "scale": String(scale),
                "sortModeDurationSeconds": String(sortModeDuration),
                "sortModeMetrics": runtimeQualitySortModeSummary(from: sortModeMetrics),
            ]
        )
        sortModeContext.app.terminate()

        let detailVariantContext = configuredLaunchContext(
            runtimeRoot: runtimeRoot,
            requestName: "runtime.measure_detail_variants"
        )
        let detailVariantStartedAt = Date()
        launch(detailVariantContext.app)
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

        let mediaCycleContext = configuredLaunchContext(
            runtimeRoot: runtimeRoot,
            requestName: "runtime.measure_media_cycles"
        )
        let mediaCycleStartedAt = Date()
        launch(mediaCycleContext.app)
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

        let detailReleaseContext = configuredLaunchContext(
            runtimeRoot: runtimeRoot,
            requestName: "runtime.measure_detail_release_cycles"
        )
        let detailReleaseStartedAt = Date()
        launch(detailReleaseContext.app)
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

        let detailContext = configuredLaunchContext(
            runtimeRoot: runtimeRoot,
            requestName: "message.open",
            args: ["message_id": "runtime-ui-msg-0"]
        )
        let detailStartedAt = Date()
        launch(detailContext.app)
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
        detailContext.app.terminate()

        let eventDetailContext = configuredLaunchContext(
            runtimeRoot: runtimeRoot,
            requestName: "entity.open",
            args: ["entity_type": "event", "entity_id": "event-runtime-1"]
        )
        let eventDetailStartedAt = Date()
        launch(eventDetailContext.app)
        let eventDetailResponse = waitForAutomationResponse(
            at: eventDetailContext.responseURL,
            timeout: runtimeQualityUITimeout(default: 90),
            matching: { $0.ok }
        )
        let eventDetailState = waitForAutomationState(
            at: eventDetailContext.stateURL,
            timeout: runtimeQualityUITimeout(default: 90),
            matching: {
                $0.visibleScreen == "screen.events.detail"
                    && $0.openedEntityType == "event"
                    && $0.openedEntityId == "event-runtime-1"
                    && ($0.runtimeErrorCount ?? 0) == 0
            }
        )
        let eventDetailDuration = Date().timeIntervalSince(eventDetailStartedAt)
        XCTAssertNotNil(eventDetailResponse)
        XCTAssertNotNil(eventDetailState)
        eventDetailContext.app.terminate()

        let thingDetailContext = configuredLaunchContext(
            runtimeRoot: runtimeRoot,
            requestName: "entity.open",
            args: ["entity_type": "thing", "entity_id": "thing-runtime-2"]
        )
        let thingDetailStartedAt = Date()
        launch(thingDetailContext.app)
        let thingDetailResponse = waitForAutomationResponse(
            at: thingDetailContext.responseURL,
            timeout: runtimeQualityUITimeout(default: 90),
            matching: { $0.ok }
        )
        let thingDetailState = waitForAutomationState(
            at: thingDetailContext.stateURL,
            timeout: runtimeQualityUITimeout(default: 90),
            matching: {
                $0.visibleScreen == "screen.things.detail"
                    && $0.openedEntityType == "thing"
                    && $0.openedEntityId == "thing-runtime-2"
                    && ($0.runtimeErrorCount ?? 0) == 0
            }
        )
        let thingDetailDuration = Date().timeIntervalSince(thingDetailStartedAt)
        XCTAssertNotNil(thingDetailResponse)
        XCTAssertNotNil(thingDetailState)

        let commandStallTimeline = runtimeQualityCommandStallSummary(
            at: runtimeRoot.appendingPathComponent("automation-events.jsonl")
        )
        let topStallPhase = runtimeQualityTopStallPhaseSummary(
            at: runtimeRoot.appendingPathComponent("automation-events.jsonl")
        )
        let runtimeSummary = [
            "[runtime-quality-ui]",
            "platform=ios",
            "scale=\(scale)",
            "fixtureGeneration=\(generationDuration)s",
            "launchImportListReady=\(readyDuration)s",
            "listScroll=\(scrollDuration)s",
            "foregroundRecovery=\(foregroundRecoveryDuration)s",
            "searchResultsReady=\(searchDuration)s",
            "tagFilterReady=\(filterDuration)s",
            "messageQueriesReady=\(queryDuration)s",
            "messageQueryMetrics=\(queryMetrics ?? [:])",
            "sortModesReady=\(sortModeDuration)s",
            "sortModeMetrics=\(runtimeQualitySortModeSummary(from: sortModeMetrics))",
            "detailVariantsReady=\(detailVariantDuration)s",
            "detailVariantMetrics=\(runtimeQualityDetailVariantSummary(from: detailVariantMetrics))",
            "mediaCyclesReady=\(mediaCycleDuration)s",
            "mediaCycleMetrics=\(runtimeQualityMediaCycleSummary(from: mediaCycleMetrics))",
            "detailReleaseReady=\(detailReleaseDuration)s",
            "detailReleaseMetrics=\(runtimeQualityDetailReleaseSummary(from: detailReleaseMetrics))",
            "commandStallTimeline=\(commandStallTimeline)",
            "topStallPhase=\(topStallPhase)",
            "messageDetailReady=\(detailDuration)s",
            "eventDetailReady=\(eventDetailDuration)s",
            "thingDetailReady=\(thingDetailDuration)s",
            "totalMessageCount=\(state?.totalMessageCount ?? -1)",
            "residentMemoryBytes=\(thingDetailState?.residentMemoryBytes ?? detailState?.residentMemoryBytes ?? state?.residentMemoryBytes ?? 0)",
            "mainThreadMaxStallMs=\(thingDetailState?.mainThreadMaxStallMilliseconds ?? detailState?.mainThreadMaxStallMilliseconds ?? state?.mainThreadMaxStallMilliseconds ?? -1)",
        ].joined(separator: " ")
        XCTContext.runActivity(named: runtimeSummary) { _ in }
        thingDetailContext.app.terminate()
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

    func testCaptureLocalizedPrimaryScreens() throws {
        let envOutputRootPath = ProcessInfo.processInfo.environment["PUSHGO_IOS_UI_SCREENSHOT_DIR"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let outputRoot: URL
        if envOutputRootPath.isEmpty {
            outputRoot = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("artifacts", isDirectory: true)
                .appendingPathComponent("localized-screenshots", isDirectory: true)
        } else {
            outputRoot = URL(fileURLWithPath: envOutputRootPath, isDirectory: true)
        }
        try FileManager.default.createDirectory(at: outputRoot, withIntermediateDirectories: true)

        for localization in localizationSpecs {
            let fixturePath = localizationShowcaseFixturePath(for: localization)
            let pages: [ScreenshotPage] = [
                .init(id: "messages-list", visibleScreen: "screen.messages.list", requestName: nil, requestArgs: [:]),
                .init(id: "events-list", visibleScreen: "screen.events.list", requestName: "nav.switch_tab", requestArgs: ["tab": "events"]),
                .init(id: "things-list", visibleScreen: "screen.things.list", requestName: "nav.switch_tab", requestArgs: ["tab": "things"]),
                .init(id: "channels", visibleScreen: "screen.channels", requestName: "nav.switch_tab", requestArgs: ["tab": "channels"]),
            ]
            let localeOutput = outputRoot.appendingPathComponent(localization.code, isDirectory: true)
            try FileManager.default.createDirectory(at: localeOutput, withIntermediateDirectories: true)
            let fixtureIDs = try localizationFixtureIDs(at: fixturePath)
            for page in pages {
                let context = configuredLaunchContext(
                    startupFixturePath: fixturePath,
                    requestName: page.requestName,
                    args: page.requestArgs,
                    launchArguments: [
                        "-AppleLanguages", "(\(localization.code))",
                        "-AppleLocale", localization.localeIdentifier,
                    ]
                )
                launch(context.app)
                assertVisibleScreen(page.visibleScreen, in: context, timeout: 15)
                RunLoop.current.run(until: Date().addingTimeInterval(0.8))
                let screenshotPath = localeOutput.appendingPathComponent("\(page.id).png")
                try context.app.screenshot().pngRepresentation.write(to: screenshotPath, options: .atomic)
                context.app.terminate()
            }

            // message detail
            do {
                let context = configuredLaunchContext(
                    startupFixturePath: fixturePath,
                    requestName: "message.open",
                    args: ["message_id": fixtureIDs.messageID],
                    launchArguments: [
                        "-AppleLanguages", "(\(localization.code))",
                        "-AppleLocale", localization.localeIdentifier,
                    ]
                )
                launch(context.app)
                assertVisibleScreen("screen.messages.list", in: context, timeout: 15)
                let response = waitForAutomationResponse(at: context.responseURL, timeout: 12, matching: { _ in true })
                XCTAssertTrue(response?.ok == true, response?.error ?? "message.open returned no response")
                assertVisibleScreen("screen.message.detail", in: context, timeout: 15)
                RunLoop.current.run(until: Date().addingTimeInterval(0.8))
                let screenshotPath = localeOutput.appendingPathComponent("message-detail.png")
                try context.app.screenshot().pngRepresentation.write(to: screenshotPath, options: .atomic)
                context.app.terminate()
            }

            // event detail
            do {
                let context = configuredLaunchContext(
                    startupFixturePath: fixturePath,
                    requestName: "entity.open",
                    args: ["entity_type": "event", "entity_id": fixtureIDs.eventID],
                    launchArguments: [
                        "-AppleLanguages", "(\(localization.code))",
                        "-AppleLocale", localization.localeIdentifier,
                    ]
                )
                launch(context.app)
                let response = waitForAutomationResponse(at: context.responseURL, timeout: 12, matching: { _ in true })
                XCTAssertTrue(response?.ok == true, response?.error ?? "entity.open(event) returned no response")
                assertVisibleScreen("screen.events.detail", in: context, timeout: 15)
                RunLoop.current.run(until: Date().addingTimeInterval(0.8))
                let screenshotPath = localeOutput.appendingPathComponent("event-detail.png")
                try context.app.screenshot().pngRepresentation.write(to: screenshotPath, options: .atomic)
                context.app.terminate()
            }

            // thing detail
            do {
                let context = configuredLaunchContext(
                    startupFixturePath: fixturePath,
                    requestName: "entity.open",
                    args: ["entity_type": "thing", "entity_id": fixtureIDs.thingID],
                    launchArguments: [
                        "-AppleLanguages", "(\(localization.code))",
                        "-AppleLocale", localization.localeIdentifier,
                    ]
                )
                launch(context.app)
                let response = waitForAutomationResponse(at: context.responseURL, timeout: 12, matching: { _ in true })
                XCTAssertTrue(response?.ok == true, response?.error ?? "entity.open(thing) returned no response")
                assertVisibleScreen("screen.things.detail", in: context, timeout: 15)
                RunLoop.current.run(until: Date().addingTimeInterval(0.8))
                let screenshotPath = localeOutput.appendingPathComponent("thing-detail.png")
                try context.app.screenshot().pngRepresentation.write(to: screenshotPath, options: .atomic)
                context.app.terminate()
            }
        }
    }

    private func configuredLaunchContext(
        runtimeRoot: URL? = nil,
        startupFixturePath: String? = nil,
        requestName: String? = nil,
        args: [String: String] = [:],
        launchArguments: [String] = []
    ) -> LaunchContext {
        let app = XCUIApplication()
        app.launchArguments += launchArguments
        let resolvedRuntimeRoot = runtimeRoot ?? makeRuntimeRoot()
        try? FileManager.default.createDirectory(at: resolvedRuntimeRoot, withIntermediateDirectories: true)
        PushGoIOSUITestRuntimeRoots.append(resolvedRuntimeRoot)

        let responseURL = resolvedRuntimeRoot.appendingPathComponent("automation-response.json")
        let stateURL = resolvedRuntimeRoot.appendingPathComponent("automation-state.json")
        let eventsURL = resolvedRuntimeRoot.appendingPathComponent("automation-events.jsonl")
        let traceURL = resolvedRuntimeRoot.appendingPathComponent("automation-trace.json")
        let fileManager = FileManager.default
        for url in [responseURL, stateURL, eventsURL, traceURL] {
            try? fileManager.removeItem(at: url)
        }

        app.launchEnvironment["PUSHGO_AUTOMATION_STORAGE_ROOT"] = resolvedRuntimeRoot.path
        app.launchEnvironment["PUSHGO_AUTOMATION_PROVIDER_TOKEN"] = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
        app.launchEnvironment["PUSHGO_AUTOMATION_SKIP_PUSH_AUTHORIZATION"] = "1"
        app.launchEnvironment["PUSHGO_AUTOMATION_ALLOW_CROSS_APP_DATA_ACCESS"] = "0"
        app.launchEnvironment["PUSHGO_AUTOMATION_RESPONSE_PATH"] = responseURL.path
        app.launchEnvironment["PUSHGO_AUTOMATION_STATE_PATH"] = stateURL.path
        app.launchEnvironment["PUSHGO_AUTOMATION_EVENTS_PATH"] = eventsURL.path
        app.launchEnvironment["PUSHGO_AUTOMATION_TRACE_PATH"] = traceURL.path
        if let startupFixturePath {
            app.launchEnvironment["PUSHGO_AUTOMATION_STARTUP_FIXTURE_PATH"] = startupFixturePath
            let fixtureURL = URL(fileURLWithPath: startupFixturePath)
            let fixtureData = try! Data(contentsOf: fixtureURL)
            app.launchEnvironment["PUSHGO_AUTOMATION_STARTUP_FIXTURE_BASE64"] = fixtureData.base64EncodedString()
        }

        if let requestName {
            let requestPayload = [
                "id": UUID().uuidString,
                "plane": "command",
                "name": requestName,
                "args": args,
            ] as [String: Any]
            let data = try! JSONSerialization.data(withJSONObject: requestPayload, options: [])
            app.launchEnvironment["PUSHGO_AUTOMATION_REQUEST"] = String(decoding: data, as: UTF8.self)
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
        URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("PushGo-iOSUITests-\(UUID().uuidString)", isDirectory: true)
    }

    private func launch(_ app: XCUIApplication) {
        app.launch()
    }

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

    private func element(in app: XCUIApplication, identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

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

    private func localizationFixtureIDs(at fixturePath: String) throws -> LocalizationFixtureIDs {
        let fixtureURL = URL(fileURLWithPath: fixturePath)
        let data = try Data(contentsOf: fixtureURL)
        let fixture = try JSONDecoder().decode(LocalizationFixture.self, from: data)

        guard let messageID = fixture.messages.first?.messageID else {
            throw NSError(domain: "PushGo_iOSUITests", code: 1001, userInfo: [
                NSLocalizedDescriptionKey: "fixture has no messages: \(fixturePath)"
            ])
        }

        guard let eventID = fixture.messages
            .first(where: { $0.rawPayload?.entityType == "event" })?
            .rawPayload?
            .entityID
        else {
            throw NSError(domain: "PushGo_iOSUITests", code: 1002, userInfo: [
                NSLocalizedDescriptionKey: "fixture has no event entity_id: \(fixturePath)"
            ])
        }

        guard let thingID = fixture.messages
            .first(where: { $0.rawPayload?.entityType == "thing" })?
            .rawPayload?
            .entityID
        else {
            throw NSError(domain: "PushGo_iOSUITests", code: 1003, userInfo: [
                NSLocalizedDescriptionKey: "fixture has no thing entity_id: \(fixturePath)"
            ])
        }

        return .init(messageID: messageID, eventID: eventID, thingID: thingID)
    }

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

    private func waitForFileNonEmpty(_ url: URL, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let content = try? String(contentsOf: url, encoding: .utf8),
               !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return false
    }

    private func writeRuntimeQualityPartialMetrics(
        at runtimeRoot: URL,
        stage: String,
        metrics: [String: String]
    ) {
        let fileURL = runtimeRoot.appendingPathComponent("runtime-quality-partial-\(stage).json")
        guard let data = try? JSONSerialization.data(withJSONObject: metrics, options: [.prettyPrinted, .sortedKeys]) else {
            return
        }
        try? data.write(to: fileURL, options: .atomic)
    }

    private func waitForStateBool(
        at url: URL,
        key: String,
        equals expected: Bool,
        timeout: TimeInterval
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let data = try? Data(contentsOf: url),
               let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let value = raw[key] {
                if let boolValue = value as? Bool, boolValue == expected {
                    return true
                }
                if let stringValue = value as? String {
                    let normalized = stringValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    if (normalized == "true" && expected) || (normalized == "false" && !expected) {
                        return true
                    }
                }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return false
    }

    private func waitForStateString(
        at url: URL,
        key: String,
        equals expected: String,
        timeout: TimeInterval
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let data = try? Data(contentsOf: url),
               let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let value = raw[key] as? String,
               value == expected {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return false
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
            let markerURL = URL(fileURLWithPath: "/tmp/pushgo-runtime-quality-ui-timeout")
            guard let markerValue = try? String(contentsOf: markerURL, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  let value = TimeInterval(markerValue),
                  value > 0
            else {
                return defaultValue
            }
            return value
        }
        return value
    }

    private func runtimeQualityScrollableList(in app: XCUIApplication) -> XCUIElement {
        let collectionView = app.collectionViews.firstMatch
        if collectionView.exists {
            return collectionView
        }
        let table = app.tables.firstMatch
        if table.exists {
            return table
        }
        let scrollView = app.scrollViews.firstMatch
        if scrollView.exists {
            return scrollView
        }
        return element(in: app, identifier: "screen.messages.list")
    }

    private func runtimeQualitySearchField(in app: XCUIApplication) -> XCUIElement {
        let searchField = app.searchFields.firstMatch
        if searchField.exists {
            return searchField
        }
        let list = runtimeQualityScrollableList(in: app)
        for _ in 0..<8 {
            list.swipeDown()
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
            if searchField.exists {
                return searchField
            }
        }
        app.swipeDown()
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        return app.searchFields.firstMatch
    }

    private func runtimeQualityDismissSearch(in app: XCUIApplication) {
        let cancelLabels = ["Cancel", "取消", "キャンセル", "Annuler", "Abbrechen", "Cancelar", "Annulla"]
        for label in cancelLabels {
            let button = app.buttons[label].firstMatch
            if button.waitForExistence(timeout: 1) {
                button.tap()
                RunLoop.current.run(until: Date().addingTimeInterval(0.4))
                return
            }
        }
        let searchButton = app.keyboards.buttons["Search"].firstMatch
        if searchButton.waitForExistence(timeout: 1) {
            searchButton.tap()
            RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        }
        app.swipeDown()
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
    }

    private func runtimeQualityFilterTag(
        _ identifier: String,
        title: String,
        in app: XCUIApplication
    ) -> XCUIElement {
        let tag = element(in: app, identifier: identifier)
        if tag.exists {
            return tag
        }
        let textTag = app.staticTexts[title].firstMatch
        if textTag.exists {
            return textTag
        }
        let buttonTag = app.buttons[title].firstMatch
        if buttonTag.exists {
            return buttonTag
        }
        for _ in 0..<8 {
            if let scrollView = app.scrollViews.allElementsBoundByIndex.last, scrollView.exists {
                scrollView.swipeUp()
            } else {
                app.swipeUp()
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
            if tag.exists {
                return tag
            }
            if textTag.exists {
                return textTag
            }
            if buttonTag.exists {
                return buttonTag
            }
        }
        return tag
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
            "tags": runtimeQualityUITagsJSON(index: index),
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
            "tags": runtimeQualityUITagsJSON(index: index),
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

    private func runtimeQualityUITagsJSON(index: Int) -> String {
        var tags = ["runtimequality", "channel-\(index % 32)"]
        if index % 10 == 4 {
            tags.append("task")
        }
        if index % 7 == 0 {
            tags.append("url")
        }
        let data = try! JSONSerialization.data(withJSONObject: tags, options: [])
        return String(decoding: data, as: UTF8.self)
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
}
