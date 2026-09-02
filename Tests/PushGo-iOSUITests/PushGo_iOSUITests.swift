import XCTest
import os
import UIKit

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
    func testInvalidQualitySessionStopsBeforeBusinessUIWithinTenSeconds() {
        let context = configuredLaunchContext()
        context.app.launchEnvironment["PUSHGO_QUALITY_SESSION_BASE64"] = "not-valid-base64"
        let startedAt = Date()

        launch(context.app)

        XCTAssertTrue(
            element(in: context.app, identifier: "quality-runtime.invalid")
                .waitForExistence(timeout: 8),
            "QUALITY_PRECONDITION: invalid App-owned session was not classified within 8 seconds."
        )
        XCTAssertLessThan(
            Date().timeIntervalSince(startedAt),
            10,
            "QUALITY_PRECONDITION: invalid App-owned session exceeded the 10-second preparation budget."
        )
        XCTAssertFalse(element(in: context.app, identifier: "quality-runtime.ready").exists)
        XCTAssertFalse(element(in: context.app, identifier: "screen.messages.list").exists)
        XCTAssertFalse(element(in: context.app, identifier: "state.messages.empty").exists)
    }

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
        let watchReceiverState: String?
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
            case watchReceiverState = "watch_receiver_state"
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

    struct LaunchContext {
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
        .init(code: "zh-CN", localeIdentifier: "zh_CN"),
        .init(code: "zh-TW", localeIdentifier: "zh_TW"),
    ]
    private let largeFixtureQualityHandshakeTimeout: TimeInterval = 60

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
        MainActor.assumeIsolated {
            let app = XCUIApplication()
            if app.state != .notRunning {
                app.terminate()
            }
        }
        let fileManager = FileManager.default
        for runtimeRoot in PushGoIOSUITestRuntimeRoots.consumeAll() {
            try? fileManager.removeItem(at: runtimeRoot)
        }
    }

    // Non-discoverable migration diagnostic. It must not be restored to a test until its
    // command/state oracle is replaced by an independent user-purpose outcome.
    func legacyDiagnosticLaunchesIntoMessageList() {
        let context = configuredLaunchContext()
        launch(context.app)

        assertVisibleScreen("screen.messages.list", in: context)
    }

    func testQualitySessionUsesAppOwnedStoreAndReachesFunctionalEmptyState() {
        let context = configuredLaunchContext()
        let sessionID = "ios-empty-\(UUID().uuidString.lowercased())"
        context.app.launchEnvironment["PUSHGO_QUALITY_SESSION_BASE64"] = qualitySessionPayload(
            sessionID: sessionID,
            fixture: "empty.clean"
        )

        launch(context.app)

        assertQualityRuntimeReady(in: context.app, timeout: 15)
        XCTAssertEqual(
            element(in: context.app, identifier: "quality-runtime.ready").value as? String,
            sessionID
        )
        assertElementExists("screen.messages.list", in: context.app, timeout: 5)
        assertElementExists("state.messages.empty", in: context.app, timeout: 5)

        // A rendered empty marker is only a preparation fact.  Exercise the
        // real Channels -> Settings -> Messages path and require the same
        // functional empty state after returning, so a frozen or one-way
        // launch cannot satisfy this journey.
        openSettingsFromChannels(in: context.app)
        assertElementExists("screen.settings", in: context.app, timeout: 5)
        leaveSettings(in: context.app)
        // Settings is presented from Channels, so the real back action returns
        // to Channels first.  Continue through the production Messages tab
        // before asserting the empty-state business endpoint.
        tapWhenHittable(
            element(in: context.app, identifier: "tab.messages"),
            timeout: 8,
            message: "Messages must remain reachable after returning from Settings"
        )
        assertElementExists("screen.messages.list", in: context.app, timeout: 5)
        assertElementExists("state.messages.empty", in: context.app, timeout: 5)
    }

    func testFatalStoreInitializationStopsReadWriteAndRecoversAfterRelaunch() {
        let sessionID = "ios-store-fatal-\(UUID().uuidString.lowercased())"
        let seeded = configuredLaunchContext(
            launchArguments: ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        )
        seeded.app.launchEnvironment["PUSHGO_QUALITY_SESSION_BASE64"] = qualitySessionPayload(
            sessionID: sessionID,
            fixture: "messages.standard"
        )
        launch(seeded.app)
        assertQualityRuntimeReady(in: seeded.app, timeout: 15)
        XCTAssertTrue(
            seeded.app.staticTexts["P2 Split Seed Message"].waitForExistence(timeout: 8),
            "The destructive recovery journey must begin with real canonical data to lose."
        )
        seeded.app.terminate()
        XCTAssertEqual(seeded.app.state, .notRunning)

        let firstFailure = configuredLaunchContext(
            launchArguments: ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        )
        firstFailure.app.launchEnvironment["PUSHGO_QUALITY_SESSION_BASE64"] = qualitySessionPayload(
            sessionID: sessionID,
            fixture: "messages.standard",
            failLocalStoreInitialization: true,
            localStoreFailureStreakThreshold: 2
        )
        launch(firstFailure.app)
        XCTAssertTrue(
            element(
                in: firstFailure.app,
                identifier: "state.storage.unavailable"
            ).waitForExistence(timeout: 8)
        )
        XCTAssertFalse(
            firstFailure.app.buttons["Rebuild database and exit"].exists,
            "Destructive recovery must not be offered before the configured repeated-failure threshold."
        )
        tapWhenHittable(
            storageRecoveryButton(
                in: firstFailure.app,
                identifier: "action.storage.exit",
                fallbackLabel: "Exit App"
            ),
            timeout: 5,
            message: "The first fatal Store failure must retain the safe exit path."
        )
        let firstExit = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "state == %d", XCUIApplication.State.notRunning.rawValue),
            object: firstFailure.app
        )
        XCTAssertEqual(XCTWaiter.wait(for: [firstExit], timeout: 5), .completed)

        let failing = configuredLaunchContext(
            launchArguments: ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        )
        failing.app.launchEnvironment["PUSHGO_QUALITY_SESSION_BASE64"] = qualitySessionPayload(
            sessionID: sessionID,
            fixture: "messages.standard",
            failLocalStoreInitialization: true,
            localStoreFailureStreakThreshold: 2
        )

        launch(failing.app)

        XCTAssertTrue(
            failing.app.staticTexts[
                "Local storage is unavailable. The app may be unable to load or save messages."
            ].waitForExistence(timeout: 8),
            "A fatal Store open failure must be shown as unavailable, not as an empty message list."
        )
        XCTAssertTrue(
            failing.app.staticTexts.matching(
                NSPredicate(
                    format: "label CONTAINS %@",
                    "Quality-injected local persistent storage initialization failure."
                )
            ).firstMatch.exists,
            "The recovery surface must retain the causal Store failure for diagnosis."
        )
        XCTAssertTrue(element(in: failing.app, identifier: "state.storage.unavailable").exists)
        XCTAssertFalse(element(in: failing.app, identifier: "screen.messages.list").exists)
        XCTAssertFalse(element(in: failing.app, identifier: "state.messages.empty").exists)
        XCTAssertFalse(element(in: failing.app, identifier: "quality-runtime.ready").exists)
        let rebuild = storageRecoveryButton(
            in: failing.app,
            identifier: "action.storage.rebuild",
            fallbackLabel: "Rebuild database and exit"
        )
        tapWhenHittable(
            rebuild,
            timeout: 5,
            message: "Repeated fatal Store failure must offer destructive rebuild recovery."
        )
        let terminated = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "state == %d", XCUIApplication.State.notRunning.rawValue),
            object: failing.app
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [terminated], timeout: 5),
            .completed,
            "The storage rebuild action must finish deletion before terminating the App."
        )

        let recovered = configuredLaunchContext(
            launchArguments: ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        )
        recovered.app.launchEnvironment["PUSHGO_QUALITY_SESSION_BASE64"] = qualitySessionPayload(
            sessionID: sessionID,
            fixture: "messages.standard"
        )
        launch(recovered.app)
        assertQualityRuntimeReady(in: recovered.app, timeout: 15)
        assertElementExists("screen.messages.list", in: recovered.app, timeout: 8)
        assertElementExists("state.messages.empty", in: recovered.app, timeout: 8)
        XCTAssertFalse(
            recovered.app.staticTexts["P2 Split Seed Message"].exists,
            "A destructive rebuild must not resurrect the canonical row that existed before recovery."
        )
        XCTAssertFalse(recovered.app.buttons["Exit App"].exists)
        XCTAssertFalse(recovered.app.buttons["Rebuild database and exit"].exists)
    }

    func testQualityStandardMessagesShowAccurateContentAndSurviveRelaunch() {
        let sessionID = "ios-standard-\(UUID().uuidString.lowercased())"
        let seeded = configuredLaunchContext()
        seeded.app.launchEnvironment["PUSHGO_QUALITY_SESSION_BASE64"] = qualitySessionPayload(
            sessionID: sessionID,
            fixture: "messages.standard",
            legacyStore: "messages.v17",
            messageRefreshScenario: "new_message"
        )

        launch(seeded.app)

        assertQualityRuntimeReady(in: seeded.app, timeout: 15)
        let legacyMessage = seeded.app.staticTexts["Legacy Upgrade Message"]
        XCTAssertTrue(
            legacyMessage.waitForExistence(timeout: 8),
            "The production v17-to-current migration must preserve the legacy message in the real list."
        )
        legacyMessage.tap()
        assertElementExists("sheet.message.detail", in: seeded.app, timeout: 8)
        XCTAssertTrue(
            seeded.app.staticTexts["Preserved through the production database migration."].exists,
            "The migrated detail must retain the exact legacy body, not only a row count."
        )
        tapWhenHittable(
            element(in: seeded.app, identifier: "action.message.close"),
            timeout: 5,
            message: "A migrated message must remain usable through the real detail flow."
        )

        let markAllRead = element(in: seeded.app, identifier: "action.messages.mark_all_read")
        tapWhenHittable(
            markAllRead,
            timeout: 5,
            message: "The real Messages bulk action must establish a known zero-unread baseline."
        )
        assertMessagesTabBadgeCount(
            nil,
            in: seeded.app,
            message: "The provider refresh journey must begin from the persisted zero-unread state."
        )
        tapWhenHittable(
            seeded.app.buttons["action.messages.refresh"],
            timeout: 5,
            message: "The production Refresh action must remain usable in the PR message journey."
        )
        let refreshedTitle = seeded.app.staticTexts["P2 Refresh Result"]
        XCTAssertTrue(
            refreshedTitle.waitForExistence(timeout: 8),
            "A successful provider refresh must add the exact new canonical message to the real list."
        )
        XCTAssertTrue(
            seeded.app.staticTexts["Persisted through the provider refresh ingress path."]
                .waitForExistence(timeout: 5),
            "The refreshed row must expose the provider body's accurate canonical value."
        )
        assertMessagesTabBadgeCount(
            1,
            in: seeded.app,
            message: "The one persisted provider result must create exactly one unread message."
        )
        refreshedTitle.tap()
        assertElementExists("sheet.message.detail", in: seeded.app, timeout: 8)
        XCTAssertTrue(
            seeded.app.staticTexts["Persisted through the provider refresh ingress path."]
                .waitForExistence(timeout: 5),
            "Opening the refreshed result must bind to its exact canonical detail."
        )
        assertMessagesTabBadgeCount(
            nil,
            in: seeded.app,
            message: "Opening the only unread provider result must persist its read transition."
        )
        tapWhenHittable(
            element(in: seeded.app, identifier: "action.message.close"),
            timeout: 5,
            message: "The refreshed canonical detail must return to the same Messages journey."
        )
        XCTAssertTrue(
            seeded.app.staticTexts["P2 Split Seed Message"].waitForExistence(timeout: 8),
            "Seeded title was not rendered by the real message list"
        )
        XCTAssertTrue(
            seeded.app.staticTexts["Seeded from fixture.seed_messages for UI validation."]
                .waitForExistence(timeout: 5),
            "Seeded body was not rendered by the real message list"
        )
        seeded.app.staticTexts["P2 Split Seed Message"].tap()
        assertElementExists("sheet.message.detail", in: seeded.app, timeout: 8)
        XCTAssertTrue(seeded.app.staticTexts["P2 Split Seed Message"].exists)
        XCTAssertTrue(
            seeded.app.staticTexts["Seeded from fixture.seed_messages for UI validation."].exists
        )

        let openLink = scrollToHittableElement(
            identifier: "action.message.open_link",
            in: seeded.app
        )
        tapWhenHittable(
            openLink,
            timeout: 8,
            message: "The canonical message URL must remain reachable through the production detail action"
        )
        let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
        XCTAssertTrue(
            safari.wait(for: .runningForeground, timeout: 10),
            "Opening the canonical message URL must hand off to the real system browser."
        )
        let collapsedAddress = safari.descendants(matching: .any)
            .matching(identifier: "TabBarItemTitle")
            .firstMatch
        tapWhenHittable(
            collapsedAddress,
            timeout: 8,
            message: "Safari must let the user expand its domain-only address display"
        )
        let browserAddress = safari.textFields.matching(
            NSPredicate(
                format: "value ==[c] %@ OR value ==[c] %@",
                "pushgo.dev/quality-message",
                "https://pushgo.dev/quality-message"
            )
        ).firstMatch
        XCTAssertTrue(
            browserAddress.waitForExistence(timeout: 8),
            "Safari must expose the exact canonical message destination, not merely any web page."
        )
        seeded.app.activate()
        assertElementExists("sheet.message.detail", in: seeded.app, timeout: 8)
        XCTAssertTrue(
            seeded.app.staticTexts["Seeded from fixture.seed_messages for UI validation."]
                .waitForExistence(timeout: 5),
            "Returning from the browser must preserve the same accurate message detail."
        )

        let image = element(in: seeded.app, identifier: "message.image.0")
        for _ in 0..<6 where !(image.exists && image.isHittable) {
            seeded.app.scrollViews.firstMatch.swipeDown()
        }
        tapWhenHittable(
            image,
            timeout: 8,
            message: "The canonical message image must decode into an interactive detail asset"
        )
        assertElementExists("dialog.image.preview", in: seeded.app, timeout: 8)
        tapWhenHittable(
            element(in: seeded.app, identifier: "action.image.preview.share"),
            timeout: 8,
            message: "The decoded image preview must expose its real Share action"
        )
        XCTAssertTrue(
            seeded.app.otherElements["ActivityListView"].waitForExistence(timeout: 8),
            "Sharing must prepare a consumable image file and hand it to the system activity view"
        )
        seeded.app.terminate()

        let relaunched = configuredLaunchContext()
        relaunched.app.launchEnvironment["PUSHGO_QUALITY_SESSION_BASE64"] = qualitySessionPayload(
            sessionID: sessionID,
            fixture: "messages.standard",
            // Keep the injected request slow long enough for XCTest's
            // accessibility snapshot cadence to observe the real warning;
            // the product's user-facing slow threshold remains one second.
            messageSearchDelayMilliseconds: 3_000,
            legacyStore: "messages.v17",
            messageRefreshScenario: "new_message"
        )
        launch(relaunched.app)

        assertQualityRuntimeReady(in: relaunched.app, timeout: 15)
        XCTAssertTrue(
            relaunched.app.staticTexts["P2 Split Seed Message"].waitForExistence(timeout: 8),
            "Canonical message did not survive a process relaunch"
        )
        XCTAssertTrue(
            relaunched.app.staticTexts["Legacy Upgrade Message"].exists,
            "The migrated canonical message must survive an ordinary process relaunch."
        )
        let relaunchedRefreshResult = relaunched.app.staticTexts["P2 Refresh Result"]
        XCTAssertTrue(
            relaunchedRefreshResult.waitForExistence(timeout: 8),
            "The successful provider refresh result must survive the existing process relaunch."
        )
        relaunchedRefreshResult.tap()
        assertElementExists("sheet.message.detail", in: relaunched.app, timeout: 8)
        XCTAssertTrue(
            relaunched.app.staticTexts["Persisted through the provider refresh ingress path."]
                .waitForExistence(timeout: 5),
            "Relaunch must preserve the refreshed result's exact canonical detail."
        )
        assertMessagesTabBadgeCount(
            nil,
            in: relaunched.app,
            message: "The refreshed result's read state must remain accurate after relaunch."
        )
        tapWhenHittable(
            element(in: relaunched.app, identifier: "action.message.close"),
            timeout: 5,
            message: "The persisted refresh detail must close before exercising search."
        )
        XCTAssertFalse(element(in: relaunched.app, identifier: "state.messages.empty").exists)

        let searchField = runtimeQualitySearchField(in: relaunched.app)
        XCTAssertTrue(searchField.waitForExistence(timeout: 8))
        searchField.tap()
        searchField.typeText("P2 Split")
        let searchTarget = relaunched.app.staticTexts["P2 Split Seed Message"]
        let searchTargets = relaunched.app.staticTexts.matching(
            NSPredicate(format: "label == %@", "P2 Split Seed Message")
        )
        let slowSearchState = element(
            in: relaunched.app,
            identifier: "state.messages.search.loading.slow"
        )
        let slowSearchFeedback = relaunched.app.staticTexts.matching(
            NSPredicate(
                format: "label CONTAINS[c] %@ OR label CONTAINS[c] %@ OR label CONTAINS[c] %@",
                "Messages are still loading",
                "消息仍在加载",
                "訊息仍在載入"
            )
        ).firstMatch
        XCTAssertTrue(
            slowSearchState.waitForExistence(timeout: 2.5),
            "A deliberately slow search must expose its real slow-loading state before the result is available."
        )
        XCTAssertTrue(
            slowSearchFeedback.exists,
            "The slow-loading state must expose the supported localized warning text."
        )
        XCTAssertFalse(
            searchTarget.exists,
            "The slow-search warning must be visible before the delayed result is available."
        )
        XCTAssertTrue(searchTarget.waitForExistence(timeout: 8))
        XCTAssertEqual(
            searchTargets.count,
            1,
            "The completed search must render one canonical target title, not duplicate results."
        )
        XCTAssertFalse(slowSearchState.exists)
        XCTAssertFalse(element(in: relaunched.app, identifier: "state.messages.search.empty").exists)
        searchTarget.tap()
        assertElementExists("sheet.message.detail", in: relaunched.app, timeout: 8)
        XCTAssertTrue(
            relaunched.app.staticTexts["Seeded from fixture.seed_messages for UI validation."]
                .waitForExistence(timeout: 5),
            "The slow search must open the exact canonical detail it found."
        )
        tapWhenHittable(
            element(in: relaunched.app, identifier: "action.message.close"),
            timeout: 5,
            message: "The slow-search detail must close before exercising the empty-result state."
        )
        tapWhenHittable(
            searchField.buttons.firstMatch,
            timeout: 5,
            message: "The native search clear action must reset the known fresh query"
        )
        searchField.tap()
        searchField.typeText("not-present-in-any-message")
        assertElementExists("state.messages.search.empty", in: relaunched.app, timeout: 8)
        XCTAssertFalse(relaunched.app.staticTexts["P2 Split Seed Message"].exists)
    }

    func testHistoryCleanupRemovesOnlyOldMessagesAndPersistsAcrossRelaunch() {
        let sessionID = "ios-cleanup-\(UUID().uuidString.lowercased())"
        let context = configuredLaunchContext()
        context.app.launchEnvironment["PUSHGO_QUALITY_SESSION_BASE64"] = qualitySessionPayload(
            sessionID: sessionID,
            fixture: "messages.cleanup"
        )
        launch(context.app)

        assertQualityRuntimeReady(in: context.app, timeout: 15)
        let oldRow = element(
            in: context.app,
            identifier: "message.row.00000000-0000-0000-0000-00000000c101"
        )
        let recentRow = element(
            in: context.app,
            identifier: "message.row.00000000-0000-0000-0000-00000000c102"
        )
        XCTAssertTrue(oldRow.waitForExistence(timeout: 8))
        XCTAssertTrue(recentRow.waitForExistence(timeout: 8))
        assertMessagesTabBadgeCount(2, in: context.app)

        openMessageFilters(in: context.app)
        tapWhenHittable(
            element(in: context.app, identifier: "action.messages.history_cleanup"),
            timeout: 5
        )
        let rangeSheet = element(in: context.app, identifier: "sheet.messages.history_cleanup.range")
        XCTAssertTrue(rangeSheet.waitForExistence(timeout: 8))
        let thirtyDays = element(
            in: context.app,
            identifier: "option.messages.history_cleanup.30_days"
        )
        if !thirtyDays.waitForExistence(timeout: 2) || !thirtyDays.isHittable {
            rangeSheet.swipeUp()
        }
        tapWhenHittable(thirtyDays, timeout: 5)
        tapWhenHittable(
            element(in: context.app, identifier: "action.messages.history_cleanup.confirm"),
            timeout: 5
        )
        tapWhenHittable(
            element(in: context.app, identifier: "action.messages.history_cleanup.done"),
            timeout: 8
        )

        XCTAssertTrue(oldRow.waitForNonExistence(timeout: 8))
        XCTAssertTrue(recentRow.waitForExistence(timeout: 8))
        assertMessagesTabBadgeCount(1, in: context.app)

        context.app.terminate()
        let relaunched = configuredLaunchContext()
        relaunched.app.launchEnvironment["PUSHGO_QUALITY_SESSION_BASE64"] = qualitySessionPayload(
            sessionID: sessionID,
            fixture: "messages.cleanup"
        )
        launch(relaunched.app)
        assertQualityRuntimeReady(in: relaunched.app, timeout: 15)
        XCTAssertFalse(
            element(
                in: relaunched.app,
                identifier: "message.row.00000000-0000-0000-0000-00000000c101"
            ).exists,
            "The removed old message must not return after process relaunch"
        )
        XCTAssertTrue(
            element(
                in: relaunched.app,
                identifier: "message.row.00000000-0000-0000-0000-00000000c102"
            ).waitForExistence(timeout: 8)
        )
        assertMessagesTabBadgeCount(1, in: relaunched.app)
    }

    func testMarkdownFixtureRendersMajorStructuresInTheRealDetail() {
        let sessionID = "ios-markdown-\(UUID().uuidString.lowercased())"
        let context = configuredLaunchContext()
        context.app.launchEnvironment["PUSHGO_QUALITY_SESSION_BASE64"] = qualitySessionPayload(
            sessionID: sessionID,
            fixture: "messages.markdown"
        )

        launch(context.app)
        assertQualityRuntimeReady(in: context.app, timeout: 15)
        let row = context.app.staticTexts["Quality Markdown Structure"]
        XCTAssertTrue(row.waitForExistence(timeout: 8))
        row.tap()
        assertElementExists("sheet.message.detail", in: context.app, timeout: 8)

        let requiredContent = [
            "Quality Markdown Heading",
            "Completed deployment check",
            "Production quote remains visible",
            "Gateway",
            "Healthy",
            "pushgo status",
            "{\"environment\":\"quality\"}",
        ]
        let renderedElement: (String) -> XCUIElement = { fragment in
            context.app.descendants(matching: .any).matching(
                NSPredicate(format: "label CONTAINS %@", fragment)
            ).firstMatch
        }
        for fragment in requiredContent {
            let rendered = renderedElement(fragment)
            XCTAssertTrue(
                rendered.waitForExistence(timeout: 5),
                "The production Markdown renderer omitted \(fragment)"
            )
        }
        XCTAssertTrue(
            context.app.links["Open quality guide"].waitForExistence(timeout: 5),
            "The Markdown link was not exposed as a real link"
        )
        XCTAssertFalse(
            context.app.staticTexts["# Quality Markdown Heading"].exists,
            "Raw Markdown syntax was shown instead of the rendered heading"
        )
        let heading = renderedElement("Quality Markdown Heading")
        let task = renderedElement("Completed deployment check")
        let gateway = renderedElement("Gateway")
        let healthy = renderedElement("Healthy")
        XCTAssertGreaterThan(heading.frame.height, task.frame.height)
        XCTAssertNotEqual(gateway.frame, healthy.frame, "The table collapsed into one plain text node")
        XCTAssertLessThan(abs(gateway.frame.midY - healthy.frame.midY), 6)
        XCTAssertGreaterThan(healthy.frame.minX, gateway.frame.minX)

        let tail = renderedElement("Unicode completion sentinel 终点 終點 Ω مرحبا 👩🏽‍💻")
        XCTAssertTrue(tail.waitForExistence(timeout: 5), "The exact Unicode tail was truncated before rendering")
        let detail = element(in: context.app, identifier: "sheet.message.detail")
        XCTAssertFalse(
            detail.frame.intersects(tail.frame),
            "The representative body must actually overflow the initial viewport"
        )
        for _ in 0..<12 {
            if detail.frame.intersects(tail.frame) { break }
            detail.swipeUp()
        }
        XCTAssertTrue(
            detail.frame.intersects(tail.frame),
            "A user must be able to scroll through the exact long body to its Unicode tail"
        )
        tapWhenHittable(
            element(in: context.app, identifier: "action.message.close"),
            timeout: 8,
            message: "Long content must not strand the user in the detail"
        )
        assertElementExists("screen.messages.list", in: context.app, timeout: 8)
        XCTAssertTrue(row.waitForExistence(timeout: 5), "Returning must preserve the exact source message")
    }

    func testSimplifiedChineseAtAccessibility5CompletesMessageDetailAndChannelCreation() {
        let context = configuredLaunchContext(
            launchArguments: [
                "-AppleLanguages", "(zh-Hans)",
                "-AppleLocale", "zh_CN",
            ]
        )
        context.app.launchEnvironment["PUSHGO_QUALITY_SESSION_BASE64"] = qualitySessionPayload(
            sessionID: "ios-zh-large-\(UUID().uuidString.lowercased())",
            fixture: "messages.standard",
            channelMutationScenario: "accepted"
        )

        launch(context.app)

        assertQualityRuntimeReady(in: context.app, timeout: 15)
        XCTAssertTrue(
            element(in: context.app, identifier: "quality-runtime.ready")
                .label.contains("dynamic type accessibility5"),
            "The SwiftUI environment must actually apply accessibility5, not merely receive a launch argument"
        )
        let tabBar = context.app.tabBars.firstMatch
        XCTAssertTrue(tabBar.waitForExistence(timeout: 8), "The production tab bar must be visible.")
        let messagesTab = context.app.buttons["tab.messages"]
        XCTAssertTrue(
            messagesTab.waitForExistence(timeout: 8) && messagesTab.isHittable,
            "The real Messages tab title must remain visible and actionable with an unread badge."
        )
        XCTAssertEqual(
            messagesTab.label,
            "消息",
            "The system tab itself must own the localized Messages title, not a page-title lookalike."
        )
        XCTAssertEqual(
            messagesTab.value as? String,
            "1项",
            "The messages.standard fixture must expose its real unread count in the system tab badge."
        )
        XCTAssertGreaterThanOrEqual(messagesTab.frame.width, 44, "The Messages tab lost its actionable width.")
        let messagesTabScreenshot = messagesTab.screenshot()
        let messagesTabAttachment = XCTAttachment(screenshot: messagesTabScreenshot)
        messagesTabAttachment.name = "ios-zh-hans-messages-tab-title-with-unread-badge"
        messagesTabAttachment.lifetime = .keepAlways
        add(messagesTabAttachment)
        XCTAssertTrue(
            hasReadableLowerTitleContrast(in: messagesTabScreenshot),
            "The lower title region has no readable foreground; the unread badge may have hidden the Messages title."
        )
        messagesTab.tap()
        assertElementExists("screen.messages.list", in: context.app, timeout: 8)
        let messageTitle = context.app.staticTexts["P2 Split Seed Message"]
        tapWhenHittable(messageTitle, timeout: 8, message: "The localized large-font list must open real data")
        assertElementExists("sheet.message.detail", in: context.app, timeout: 8)
        XCTAssertTrue(
            context.app.staticTexts["Seeded from fixture.seed_messages for UI validation."]
                .waitForExistence(timeout: 5),
            "The detail must still expose the canonical stored body at accessibility5"
        )
        tapWhenHittable(
            element(in: context.app, identifier: "action.message.close"),
            timeout: 8,
            message: "The large-font detail must keep its close action reachable"
        )

        let channels = channelsTab(in: context.app)
        XCTAssertEqual(channels.label, "频道", "The real Channels destination must use zh-Hans")
        tapWhenHittable(channels, timeout: 8, message: "Channels must remain reachable at accessibility5")
        assertElementExists("screen.channels", in: context.app, timeout: 8)
        let addChannel = element(in: context.app, identifier: "action.channels.add")
        XCTAssertEqual(addChannel.label, "添加频道", "The real add action must use zh-Hans")
        tapWhenHittable(addChannel, timeout: 8, message: "Add Channel must remain reachable at accessibility5")

        let name = element(in: context.app, identifier: "field.channels.create.name")
        let password = element(in: context.app, identifier: "field.channels.create.password")
        tapWhenHittable(name, timeout: 8, message: "Channel name must remain editable at accessibility5")
        replaceText(in: name, with: "大字体测试频道")
        enterSecureText(in: password, with: "qualityx")
        tapWhenHittable(
            element(in: context.app, identifier: "action.channels.entry.submit"),
            timeout: 8,
            message: "The real localized channel form must be submittable at accessibility5"
        )
        XCTAssertTrue(
            element(in: context.app, identifier: "channel.row.01H00000000000000000000003")
                .waitForExistence(timeout: 8),
            "Successful creation must produce the expected real channel row"
        )
        XCTAssertTrue(context.app.staticTexts["大字体测试频道"].exists)
    }

    func testQualityMessageWorkflowLoadsSecondPageAndPersistsReadActions() {
        let sessionID = "ios-message-workflow-\(UUID().uuidString.lowercased())"
        let context = configuredLaunchContext()
        context.app.launchEnvironment["PUSHGO_QUALITY_SESSION_BASE64"] = qualitySessionPayload(
            sessionID: sessionID,
            fixture: "messages.workflow",
            messagePageLoadDelayMilliseconds: 10_000,
            failMessagePageLoadOnce: true
        )

        launch(context.app, qualityHandshakeTimeout: largeFixtureQualityHandshakeTimeout)

        assertQualityRuntimeReady(in: context.app, timeout: 15)
        XCTAssertTrue(
            context.app.staticTexts["Quality workflow 124"].waitForExistence(timeout: 8),
            "The first production page must start with the newest canonical object"
        )
        assertMessagesTabBadgeCount(39, in: context.app)
        let markAll = element(in: context.app, identifier: "action.messages.mark_all_read")
        XCTAssertTrue(markAll.waitForExistence(timeout: 5))

        let list = runtimeQualityScrollableList(in: context.app)
        XCTAssertTrue(list.waitForExistence(timeout: 5))
        var observedWorkflowIndices = Set<Int>()
        let recordVisibleWorkflowRows = {
            let rows = context.app.buttons.matching(
                NSPredicate(
                    format: "identifier BEGINSWITH %@",
                    "message.row.00000000-0000-0000-0000-"
                )
            )
            var visibleRows: [(index: Int, identifier: String, minY: CGFloat)] = []
            for offset in 0..<rows.count {
                let row = rows.element(boundBy: offset)
                let frame = row.frame
                guard row.exists,
                      frame.width > 0,
                      frame.height > 0,
                      frame.intersects(list.frame),
                      let suffix = row.identifier.split(separator: "-").last,
                      let encodedIndex = Int(suffix, radix: 16),
                      encodedIndex > 0
                else {
                    continue
                }

                let index = encodedIndex - 1
                XCTAssertTrue(
                    row.label.contains("Quality workflow \(index)."),
                    "Stable identity \(row.identifier) must remain bound to Quality workflow \(index)."
                )
                visibleRows.append((index, row.identifier, frame.minY))
                observedWorkflowIndices.insert(index)
            }

            let orderedRows = visibleRows.sorted { $0.minY < $1.minY }
            XCTAssertEqual(
                Set(orderedRows.map(\.identifier)).count,
                orderedRows.count,
                "Every visible workflow row must have one stable identity."
            )
            for pair in zip(orderedRows, orderedRows.dropFirst()) {
                XCTAssertEqual(
                    pair.0.index - pair.1.index,
                    1,
                    "Every visible workflow viewport must preserve contiguous newest-first order."
                )
            }
        }
        let swipeUpAndRecord = {
            list.swipeUp()
            recordVisibleWorkflowRows()
        }
        recordVisibleWorkflowRows()
        let pageLoading = element(in: context.app, identifier: "state.messages.page.loading")
        for _ in 0..<12 where !pageLoading.exists {
            swipeUpAndRecord()
        }
        XCTAssertTrue(
            pageLoading.waitForExistence(timeout: 5) && pageLoading.isHittable,
            "A slow next page must expose a visible, reachable bottom progress state instead of looking frozen"
        )
        XCTAssertTrue(
            pageLoading.label.contains("正在加载更早的消息"),
            "The bottom progress state must explain that earlier messages are loading"
        )
        XCTAssertTrue(
            context.app.staticTexts["Quality workflow 75"].exists,
            "The last row from page 1 must remain usable while page 2 is loading"
        )
        let pageFailure = element(in: context.app, identifier: "state.messages.page.failed")
        XCTAssertTrue(
            pageFailure.waitForExistence(timeout: 8) && pageFailure.isHittable,
            "A failed next page must expose a visible, reachable page-owned recovery state instead of silently stopping."
        )
        let pageFailureMessage = context.app.staticTexts["无法加载消息，请稍后重试。"]
        XCTAssertTrue(
            pageFailureMessage.waitForExistence(timeout: 3) && pageFailureMessage.isHittable,
            "The page-owned failure state must expose a visible, reachable explanation of the load failure."
        )
        let retainedPageOneTail = element(
            in: context.app,
            identifier: "message.row.00000000-0000-0000-0000-00000000004c"
        )
        XCTAssertTrue(
            retainedPageOneTail.exists && retainedPageOneTail.isHittable,
            "The accurate page-1 tail must remain actionable while page 2 is failed."
        )
        let pageRetry = element(in: context.app, identifier: "action.messages.page.retry")
        XCTAssertTrue(
            pageRetry.waitForExistence(timeout: 3) && pageRetry.isHittable,
            "Page Retry must be a real user action on the failed append owner."
        )
        pageRetry.tap()
        let secondPageHead = context.app.staticTexts["Quality workflow 74"]
        for _ in 0..<12 where !secondPageHead.exists {
            swipeUpAndRecord()
        }
        XCTAssertTrue(
            secondPageHead.waitForExistence(timeout: 5),
            "The first canonical object from production page 2 was not reachable."
        )
        let secondPageTail = context.app.staticTexts["Quality workflow 25"]
        for _ in 0..<14 where !secondPageTail.exists {
            swipeUpAndRecord()
        }
        XCTAssertTrue(
            secondPageTail.waitForExistence(timeout: 5),
            "The last canonical object from production page 2 was not reachable."
        )

        let finalPagePredecessor = element(
            in: context.app,
            identifier: "message.row.00000000-0000-0000-0000-000000000002"
        )
        let finalPageTarget = element(
            in: context.app,
            identifier: "message.row.00000000-0000-0000-0000-000000000001"
        )
        for _ in 0..<14 where !(finalPagePredecessor.exists && finalPageTarget.exists) {
            swipeUpAndRecord()
        }
        XCTAssertTrue(
            finalPageTarget.waitForExistence(timeout: 5),
            "The oldest canonical object from production page 3 was not reachable"
        )
        XCTAssertTrue(
            finalPagePredecessor.waitForExistence(timeout: 5),
            "Production page 3 must not silently drop its penultimate canonical object."
        )
        XCTAssertTrue(
            finalPagePredecessor.label.contains("Quality workflow 1"),
            "The penultimate identity must remain bound to its accurate visible title."
        )
        XCTAssertTrue(
            finalPageTarget.label.contains("Quality workflow 0"),
            "The oldest identity must remain bound to its accurate visible title."
        )
        XCTAssertTrue(
            context.app.staticTexts["Quality workflow 1"].exists &&
                context.app.staticTexts["Quality workflow 0"].exists,
            "Both canonical final-page titles must be visibly rendered, not merely exposed as identifiers."
        )
        for identifier in [
            "message.row.00000000-0000-0000-0000-000000000002",
            "message.row.00000000-0000-0000-0000-000000000001",
        ] {
            XCTAssertEqual(
                context.app.descendants(matching: .any).matching(identifier: identifier).count,
                1,
                "Repeated scroll pressure must append every final-page object exactly once."
            )
        }
        XCTAssertLessThan(
            finalPagePredecessor.frame.minY,
            finalPageTarget.frame.minY,
            "Production page 3 must preserve canonical newest-first ordering."
        )
        recordVisibleWorkflowRows()
        XCTAssertEqual(
            observedWorkflowIndices,
            Set(0..<125),
            "The production paging journey must render every canonical object exactly once without gaps."
        )

        let messagesTab = context.app.tabBars.firstMatch.buttons.element(boundBy: 0)
        messagesTab.tap()
        XCTAssertTrue(
            context.app.staticTexts["Quality workflow 39"].waitForExistence(timeout: 5),
            "Reselecting Messages once must reach the nearest unread canonical object"
        )
        XCTAssertFalse(context.app.staticTexts["Quality workflow 124"].exists)

        messagesTab.doubleTap()
        XCTAssertTrue(
            context.app.staticTexts["Quality workflow 124"].waitForExistence(timeout: 5),
            "Double-tapping Messages must reach the newest canonical object"
        )
        RunLoop.current.run(until: Date().addingTimeInterval(0.45))
        XCTAssertTrue(
            context.app.staticTexts["Quality workflow 124"].exists,
            "The canceled single-tap task must not move the list after a double-tap"
        )
        XCTAssertFalse(context.app.staticTexts["Quality workflow 39"].exists)

        messagesTab.tap()
        XCTAssertTrue(
            context.app.staticTexts["Quality workflow 39"].waitForExistence(timeout: 5),
            "A later single reselect must still reach the nearest unread object"
        )
        let unreadRow = element(
            in: context.app,
            identifier: "message.row.00000000-0000-0000-0000-000000000028"
        )
        XCTAssertTrue(unreadRow.waitForExistence(timeout: 5))
        let unreadLabel = unreadRow.label
        unreadRow.tap()
        let detail = element(in: context.app, identifier: "sheet.message.detail")
        XCTAssertTrue(detail.waitForExistence(timeout: 8))
        let closeDetail = element(in: context.app, identifier: "action.message.close")
        XCTAssertTrue(closeDetail.waitForExistence(timeout: 5))
        closeDetail.tap()
        XCTAssertTrue(detail.waitForNonExistence(timeout: 5))
        XCTAssertTrue(unreadRow.waitForExistence(timeout: 5))
        let readStateChanged = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label != %@", unreadLabel),
            object: unreadRow
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [readStateChanged], timeout: 5),
            .completed,
            "Opening the real detail must change the row's accessible read state"
        )
        context.app.terminate()

        let afterSingleRead = configuredLaunchContext()
        afterSingleRead.app.launchEnvironment["PUSHGO_QUALITY_SESSION_BASE64"] = qualitySessionPayload(
            sessionID: sessionID,
            fixture: "messages.workflow"
        )
        launch(afterSingleRead.app, qualityHandshakeTimeout: largeFixtureQualityHandshakeTimeout)
        assertQualityRuntimeReady(in: afterSingleRead.app, timeout: 15)
        assertMessagesTabBadgeCount(
            38,
            in: afterSingleRead.app,
            message: "Reading one real message must persist and decrement the navigation badge exactly once"
        )
        let persistentMarkAll = element(
            in: afterSingleRead.app,
            identifier: "action.messages.mark_all_read"
        )
        XCTAssertTrue(persistentMarkAll.waitForExistence(timeout: 5))
        persistentMarkAll.tap()
        XCTAssertTrue(
            persistentMarkAll.waitForNonExistence(timeout: 8),
            "All unread messages were not cleared"
        )
        assertMessagesTabBadgeCount(
            nil,
            in: afterSingleRead.app,
            message: "Marking all messages read must remove the navigation badge"
        )
        afterSingleRead.app.terminate()

        let relaunched = configuredLaunchContext()
        relaunched.app.launchEnvironment["PUSHGO_QUALITY_SESSION_BASE64"] = qualitySessionPayload(
            sessionID: sessionID,
            fixture: "messages.workflow"
        )
        launch(relaunched.app, qualityHandshakeTimeout: largeFixtureQualityHandshakeTimeout)
        assertQualityRuntimeReady(in: relaunched.app, timeout: 15)
        XCTAssertFalse(
            element(in: relaunched.app, identifier: "action.messages.mark_all_read")
                .waitForExistence(timeout: 3),
            "Read state was reset when the App relaunched"
        )
        assertMessagesTabBadgeCount(
            nil,
            in: relaunched.app,
            message: "The cleared unread badge must not return after process relaunch"
        )
        element(in: relaunched.app, identifier: "action.messages.filter").tap()
        let unreadFilter = element(in: relaunched.app, identifier: "filter.unread_only")
        XCTAssertTrue(unreadFilter.waitForExistence(timeout: 5))
        unreadFilter.tap()
        assertElementExists("state.messages.empty", in: relaunched.app, timeout: 8)

        if !unreadFilter.waitForExistence(timeout: 1) {
            let filterButton = element(in: relaunched.app, identifier: "action.messages.filter")
            XCTAssertTrue(filterButton.waitForExistence(timeout: 5))
            filterButton.tap()
            XCTAssertTrue(unreadFilter.waitForExistence(timeout: 5))
        }
        unreadFilter.tap()
        XCTAssertTrue(relaunched.app.staticTexts["Quality workflow 124"].waitForExistence(timeout: 8))
        XCTAssertFalse(element(in: relaunched.app, identifier: "state.messages.empty").exists)
    }

    func testMessageChannelTagCombinedUngroupedFiltersAndScopedReadPersist() {
        let sessionID = "ios-message-filters-\(UUID().uuidString.lowercased())"
        let context = configuredLaunchContext()
        context.app.launchEnvironment["PUSHGO_QUALITY_SESSION_BASE64"] = qualitySessionPayload(
            sessionID: sessionID,
            fixture: "messages.filters"
        )
        let allTitles = [
            "Quality filter alpha even",
            "Quality filter alpha odd",
            "Quality filter beta odd",
            "Quality filter beta even",
            "Quality filter ungrouped orphan",
        ]

        launch(context.app)
        assertQualityRuntimeReady(in: context.app, timeout: 15)
        assertMessageTitles(allTitles, excluding: [], in: context.app)
        assertMessagesTabBadgeCount(4, in: context.app)

        openMessageFilters(in: context.app)
        tapWhenHittable(element(in: context.app, identifier: "filter.channel-filter-alpha"), timeout: 5)
        dismissMessageFilters(in: context.app)

        openMessageFilters(in: context.app)
        revealFilterOption("filter.tag.even", towardTags: true, in: context.app)
        tapWhenHittable(element(in: context.app, identifier: "filter.tag.even"), timeout: 5)
        dismissMessageFilters(in: context.app)
        assertMessageTitles(
            ["Quality filter alpha even"],
            excluding: [
                "Quality filter alpha odd",
                "Quality filter beta odd",
                "Quality filter beta even",
                "Quality filter ungrouped orphan",
            ],
            in: context.app
        )
        openMessageFilters(in: context.app)
        revealFilterOption("filter.channel-filter-alpha", towardTags: false, in: context.app)
        tapWhenHittable(element(in: context.app, identifier: "filter.channel-filter-alpha"), timeout: 5)
        dismissMessageFilters(in: context.app)
        openMessageFilters(in: context.app)
        revealFilterOption("filter.tag.even", towardTags: true, in: context.app)
        tapWhenHittable(element(in: context.app, identifier: "filter.tag.even"), timeout: 5)
        dismissMessageFilters(in: context.app)
        openMessageFilters(in: context.app)
        revealFilterOption("filter.channel-ungrouped", towardTags: false, in: context.app)
        tapWhenHittable(element(in: context.app, identifier: "filter.channel-ungrouped"), timeout: 5)
        dismissMessageFilters(in: context.app)
        assertMessageTitles(
            ["Quality filter ungrouped orphan"],
            excluding: [
                "Quality filter alpha even",
                "Quality filter alpha odd",
                "Quality filter beta odd",
                "Quality filter beta even",
            ],
            in: context.app
        )

        let ungroupedRow = element(
            in: context.app,
            identifier: "message.row.00000000-0000-0000-0000-00000000f005"
        )
        XCTAssertTrue(ungroupedRow.waitForExistence(timeout: 5))
        let unreadUngroupedLabel = ungroupedRow.label
        let markCurrentScopeRead = element(
            in: context.app,
            identifier: "action.messages.mark_all_read"
        )
        tapWhenHittable(markCurrentScopeRead, timeout: 5)
        XCTAssertTrue(markCurrentScopeRead.waitForNonExistence(timeout: 8))
        assertMessagesTabBadgeCount(
            3,
            in: context.app,
            message: "Only the selected ungrouped unread message may be marked read"
        )

        context.app.terminate()
        let relaunched = configuredLaunchContext()
        relaunched.app.launchEnvironment["PUSHGO_QUALITY_SESSION_BASE64"] = qualitySessionPayload(
            sessionID: sessionID,
            fixture: "messages.filters"
        )
        launch(relaunched.app)
        assertQualityRuntimeReady(in: relaunched.app, timeout: 15)
        assertMessagesTabBadgeCount(3, in: relaunched.app)
        let relaunchedUngroupedRow = element(
            in: relaunched.app,
            identifier: "message.row.00000000-0000-0000-0000-00000000f005"
        )
        XCTAssertTrue(relaunchedUngroupedRow.waitForExistence(timeout: 8))
        XCTAssertNotEqual(
            relaunchedUngroupedRow.label,
            unreadUngroupedLabel,
            "The scoped read result was not preserved across process relaunch"
        )

        openMessageFilters(in: relaunched.app)
        revealFilterOption("filter.channel-ungrouped", towardTags: false, in: relaunched.app)
        tapWhenHittable(element(in: relaunched.app, identifier: "filter.channel-ungrouped"), timeout: 5)
        dismissMessageFilters(in: relaunched.app)
        assertMessageTitles(
            ["Quality filter ungrouped orphan"],
            excluding: Array(allTitles.dropLast()),
            in: relaunched.app
        )
        XCTAssertFalse(
            element(in: relaunched.app, identifier: "action.messages.mark_all_read")
                .waitForExistence(timeout: 2),
            "The already-read ungrouped scope must not offer another unread bulk action"
        )
    }

    func testQualityMessageSearchReturnsOnlyTheTargetAndOpensItsRealDetail() {
        let context = configuredLaunchContext()
        context.app.launchEnvironment["PUSHGO_QUALITY_SESSION_BASE64"] = qualitySessionPayload(
            sessionID: "ios-search-\(UUID().uuidString.lowercased())",
            fixture: "messages.standard",
            failMessageSearchOnce: true
        )

        launch(context.app)

        assertQualityRuntimeReady(in: context.app, timeout: 15)
        let searchField = runtimeQualitySearchField(in: context.app)
        XCTAssertTrue(searchField.waitForExistence(timeout: 8))
        replaceText(in: searchField, with: "P2 Split")
        XCTAssertEqual(searchField.value as? String, "P2 Split")
        let target = context.app.staticTexts["P2 Split Seed Message"]
        assertElementExists("state.messages.search.failed", in: context.app, timeout: 8)
        XCTAssertFalse(
            element(in: context.app, identifier: "state.messages.search.empty").exists,
            "A failed search must not masquerade as a genuine no-results state."
        )
        XCTAssertFalse(
            target.exists,
            "The pre-search list must not remain visible as if it were a result for the failed query."
        )
        tapWhenHittable(
            element(in: context.app, identifier: "action.messages.search.retry"),
            timeout: 5,
            message: "A search failure must offer a real retry action."
        )
        XCTAssertTrue(target.waitForExistence(timeout: 8))
        XCTAssertFalse(element(in: context.app, identifier: "state.messages.search.failed").exists)
        XCTAssertFalse(element(in: context.app, identifier: "state.messages.search.empty").exists)
        target.tap()
        assertElementExists("sheet.message.detail", in: context.app, timeout: 8)
        XCTAssertTrue(
            context.app.staticTexts["Seeded from fixture.seed_messages for UI validation."].exists
        )
    }

    func testQualityMessageDeleteUndoRestoresTheSameObjectAcrossRelaunch() {
        let sessionID = "ios-delete-undo-\(UUID().uuidString.lowercased())"
        let context = configuredLaunchContext()
        context.app.launchEnvironment["PUSHGO_QUALITY_SESSION_BASE64"] = qualitySessionPayload(
            sessionID: sessionID,
            fixture: "messages.standard"
        )

        launch(context.app)

        assertQualityRuntimeReady(in: context.app, timeout: 15)
        let title = context.app.staticTexts["P2 Split Seed Message"]
        XCTAssertTrue(title.waitForExistence(timeout: 8))
        title.tap()
        let delete = element(in: context.app, identifier: "action.message.delete")
        XCTAssertTrue(delete.waitForExistence(timeout: 8))
        delete.tap()
        let row = element(
            in: context.app,
            identifier: "message.row.00000000-0000-0000-0000-000000000001"
        )
        XCTAssertTrue(row.waitForNonExistence(timeout: 2))
        assertElementExists("state.pending_deletion", in: context.app, timeout: 5)
        let undo = element(in: context.app, identifier: "action.pending_deletion.undo")
        XCTAssertTrue(undo.isHittable)
        undo.tap()
        XCTAssertTrue(title.waitForExistence(timeout: 8))
        context.app.terminate()

        let relaunched = configuredLaunchContext()
        relaunched.app.launchEnvironment["PUSHGO_QUALITY_SESSION_BASE64"] = qualitySessionPayload(
            sessionID: sessionID,
            fixture: "messages.standard"
        )
        launch(relaunched.app)
        assertQualityRuntimeReady(in: relaunched.app, timeout: 15)
        XCTAssertTrue(
            relaunched.app.staticTexts["P2 Split Seed Message"].waitForExistence(timeout: 8),
            "Undo must restore the canonical object, not only the visible row"
        )
    }

    func testQualityMessageDeleteWithoutUndoPermanentlyRemovesOnlyTargetAcrossRelaunch() {
        let sessionID = "ios-delete-commit-\(UUID().uuidString.lowercased())"
        let context = configuredLaunchContext()
        context.app.launchEnvironment["PUSHGO_QUALITY_SESSION_BASE64"] = qualitySessionPayload(
            sessionID: sessionID,
            fixture: "channels.standard"
        )

        launch(context.app)

        assertQualityRuntimeReady(in: context.app, timeout: 15)
        let targetRow = element(
            in: context.app,
            identifier: "message.row.00000000-0000-0000-0000-00000000c002"
        )
        let targetTitle = context.app.staticTexts["Quality Delete History Message"]
        let controlTitle = context.app.staticTexts["Quality Keep History Message"]
        XCTAssertTrue(
            targetRow.waitForExistence(timeout: 8) && targetTitle.exists,
            "The exact target row must exist before its later absence can prove deletion"
        )
        XCTAssertTrue(controlTitle.exists, "The unrelated control message must exist before deletion")
        targetTitle.tap()
        assertElementExists("sheet.message.detail", in: context.app, timeout: 8)
        XCTAssertTrue(
            context.app.staticTexts[
                "Deterministic history owned by 01H00000000000000000000002."
            ].exists,
            "The delete action must start from the exact target detail"
        )
        tapWhenHittable(
            element(in: context.app, identifier: "action.message.delete"),
            timeout: 8
        )

        XCTAssertTrue(targetRow.waitForNonExistence(timeout: 2))
        let pendingDeletion = element(in: context.app, identifier: "state.pending_deletion")
        XCTAssertTrue(pendingDeletion.waitForExistence(timeout: 5))
        XCTAssertTrue(
            element(in: context.app, identifier: "action.pending_deletion.undo").isHittable,
            "The test must observe a real undo opportunity before deliberately letting it expire"
        )
        XCTAssertTrue(
            pendingDeletion.waitForNonExistence(timeout: 15),
            "The real undo deadline did not commit and clear the pending deletion"
        )
        XCTAssertFalse(targetTitle.exists, "The committed target must stay absent")
        XCTAssertTrue(
            controlTitle.waitForExistence(timeout: 5),
            "Committing one deletion must not remove an unrelated message"
        )
        controlTitle.tap()
        assertElementExists("sheet.message.detail", in: context.app, timeout: 5)
        XCTAssertTrue(
            context.app.staticTexts[
                "Deterministic history owned by 01H00000000000000000000001."
            ].exists,
            "The control message must retain its exact canonical content"
        )
        tapWhenHittable(
            element(in: context.app, identifier: "action.message.close"),
            timeout: 5
        )
        context.app.terminate()

        let relaunched = configuredLaunchContext()
        relaunched.app.launchEnvironment["PUSHGO_QUALITY_SESSION_BASE64"] = qualitySessionPayload(
            sessionID: sessionID,
            fixture: "channels.standard"
        )
        launch(relaunched.app)
        assertQualityRuntimeReady(in: relaunched.app, timeout: 15)
        XCTAssertFalse(
            element(
                in: relaunched.app,
                identifier: "message.row.00000000-0000-0000-0000-00000000c002"
            ).exists,
            "A committed deletion must not revive when the App rebuilds its canonical list"
        )
        XCTAssertFalse(relaunched.app.staticTexts["Quality Delete History Message"].exists)
        let relaunchedControl = relaunched.app.staticTexts["Quality Keep History Message"]
        XCTAssertTrue(relaunchedControl.waitForExistence(timeout: 8))
        relaunchedControl.tap()
        assertElementExists("sheet.message.detail", in: relaunched.app, timeout: 5)
        XCTAssertTrue(
            relaunched.app.staticTexts[
                "Deterministic history owned by 01H00000000000000000000001."
            ].exists,
            "The unrelated canonical message must remain accurate after relaunch"
        )
        relaunched.app.terminate()

        let unavailableTarget = configuredLaunchContext(
            runtimeRoot: context.runtimeRoot,
            requestName: "message.open",
            args: ["message_id": "01H00000000000000000000002"]
        )
        unavailableTarget.app.launchEnvironment["PUSHGO_QUALITY_SESSION_BASE64"] = qualitySessionPayload(
            sessionID: sessionID,
            fixture: "channels.standard"
        )
        launch(unavailableTarget.app)
        assertQualityRuntimeReady(in: unavailableTarget.app, timeout: 15)
        assertElementExists("screen.messages.list", in: unavailableTarget.app, timeout: 8)
        let unavailableFeedback = element(
            in: unavailableTarget.app,
            identifier: "feedback.message.target_unavailable"
        )
        XCTAssertTrue(
            unavailableFeedback.waitForExistence(timeout: 5),
            "Opening a deleted Message must visibly explain the fallback instead of leaving a pending target."
        )
        let unavailableTargetMessages = [
            "The requested item was not found or has expired.",
            "目标不存在，或已失效。",
            "目標不存在，或已失效。",
        ]
        let unavailableTargetText = [
            unavailableFeedback.label,
            unavailableFeedback.value as? String ?? "",
        ].joined(separator: " ")
        XCTAssertTrue(
            unavailableTargetMessages.contains(where: { message in
                unavailableTargetText.contains(message)
                    || unavailableTarget.app.staticTexts[message].exists
            }),
            "The fallback must explain that the exact Message target is unavailable."
        )
        XCTAssertFalse(
            unavailableTarget.app.staticTexts["Quality Delete History Message"].exists,
            "Routing to the deleted Message must not revive its committed record or stale detail."
        )
        let survivingMessage = unavailableTarget.app.staticTexts["Quality Keep History Message"]
        XCTAssertTrue(
            survivingMessage.waitForExistence(timeout: 5),
            "After the deleted-target fallback, the canonical Messages list must remain usable."
        )
        survivingMessage.tap()
        assertElementExists("sheet.message.detail", in: unavailableTarget.app, timeout: 8)
        XCTAssertTrue(
            unavailableTarget.app.staticTexts[
                "Deterministic history owned by 01H00000000000000000000001."
            ].waitForExistence(timeout: 5),
            "The surviving Message must still open its exact canonical detail after fallback."
        )
    }

    func testSlowMessageLoadBecomesVisibleBeforeDataCompletes() {
        let context = configuredLaunchContext()
        context.app.launchEnvironment["PUSHGO_QUALITY_SESSION_BASE64"] = qualitySessionPayload(
            sessionID: "ios-slow-\(UUID().uuidString.lowercased())",
            fixture: "empty.clean",
            messageLoadDelayMilliseconds: 8_000
        )

        launch(context.app)

        assertElementExists("state.messages.loading.slow", in: context.app, timeout: 4)
        assertElementExists("state.messages.empty", in: context.app, timeout: 10)
        XCTAssertFalse(element(in: context.app, identifier: "state.messages.load_failed").exists)
    }

    func testSlowMessageRefreshKeepsAccurateContentVisibleUntilCompletion() {
        let context = configuredLaunchContext()
        context.app.launchEnvironment["PUSHGO_QUALITY_SESSION_BASE64"] = qualitySessionPayload(
            sessionID: "ios-refresh-slow-\(UUID().uuidString.lowercased())",
            fixture: "messages.standard",
            messageRefreshDelayMilliseconds: 2_500
        )

        launch(context.app)

        assertQualityRuntimeReady(in: context.app, timeout: 15)
        let title = context.app.staticTexts["P2 Split Seed Message"]
        XCTAssertTrue(title.waitForExistence(timeout: 8))
        let refresh = context.app.buttons["action.messages.refresh"]
        XCTAssertTrue(refresh.waitForExistence(timeout: 5))
        refresh.tap()

        XCTAssertTrue(title.exists, "Refresh must not blank the last accurate snapshot")
        assertElementExists("state.messages.refresh.slow", in: context.app, timeout: 2)
        XCTAssertTrue(title.exists, "Slow-state feedback must coexist with the last accurate snapshot")
        XCTAssertTrue(
            element(in: context.app, identifier: "state.messages.refresh.slow")
                .waitForNonExistence(timeout: 5)
        )
        XCTAssertTrue(title.exists, "Successful refresh must end on accurate content")
    }

    func testMessageRefreshFailureKeepsSnapshotAndRetryRecoversPersistedResult() {
        let context = configuredLaunchContext()
        context.app.launchEnvironment["PUSHGO_QUALITY_SESSION_BASE64"] = qualitySessionPayload(
            sessionID: "ios-refresh-recovery-\(UUID().uuidString.lowercased())",
            fixture: "messages.standard",
            messageRefreshScenario: "fail_once_then_new_message"
        )

        launch(context.app)
        assertQualityRuntimeReady(in: context.app, timeout: 15)
        let originalTitle = context.app.staticTexts["P2 Split Seed Message"]
        XCTAssertTrue(originalTitle.waitForExistence(timeout: 8))
        context.app.buttons["action.messages.refresh"].tap()

        assertElementExists("state.messages.refresh.failed", in: context.app, timeout: 5)
        XCTAssertTrue(originalTitle.exists)
        let retry = context.app.buttons["action.messages.refresh"]
        XCTAssertTrue(retry.isHittable)
        retry.tap()

        let refreshedTitle = context.app.staticTexts["P2 Refresh Result"]
        XCTAssertTrue(refreshedTitle.waitForExistence(timeout: 8))
        XCTAssertTrue(
            element(in: context.app, identifier: "state.messages.refresh.failed")
                .waitForNonExistence(timeout: 5)
        )
        refreshedTitle.tap()
        XCTAssertTrue(
            context.app.staticTexts["Persisted through the provider refresh ingress path."]
                .waitForExistence(timeout: 5)
        )
    }

    func testMessageLoadFailureShowsRetryAndRecoversToRealDataState() {
        let context = configuredLaunchContext()
        let sessionID = "ios-retry-\(UUID().uuidString.lowercased())"
        context.app.launchEnvironment["PUSHGO_QUALITY_SESSION_BASE64"] = qualitySessionPayload(
            sessionID: sessionID,
            fixture: "messages.standard",
            failMessageLoad: true
        )

        launch(context.app)
        assertQualityRuntimeReady(
            in: context.app,
            timeout: 15,
            expectedSessionID: sessionID
        )

        assertElementExists("state.messages.load_failed", in: context.app, timeout: 5)
        let retryCandidates = context.app.descendants(matching: .any)
            .matching(identifier: "action.messages.retry")
            .allElementsBoundByIndex
        let retry = retryCandidates.first(where: { $0.exists && $0.isHittable })
        XCTAssertNotNil(
            retry,
            "Retry must expose at least one visible, hittable production interaction"
        )
        retry?.tap()
        let targetTitle = context.app.staticTexts["P2 Split Seed Message"]
        XCTAssertTrue(
            targetTitle.waitForExistence(timeout: 8),
            "Retry must restore the canonical non-empty Message result, not only clear the error state."
        )
        XCTAssertEqual(
            context.app.staticTexts.matching(
                NSPredicate(format: "label == %@", "P2 Split Seed Message")
            ).count,
            1,
            "Retry must restore exactly one canonical target row."
        )
        XCTAssertFalse(element(in: context.app, identifier: "state.messages.load_failed").exists)
        XCTAssertFalse(element(in: context.app, identifier: "state.messages.empty").exists)
        targetTitle.tap()
        XCTAssertTrue(
            context.app.staticTexts["Seeded from fixture.seed_messages for UI validation."]
                .waitForExistence(timeout: 5),
            "Retry must open the restored canonical Message and expose its exact body."
        )
    }

    func legacyDiagnosticAutomationRequestCanOpenChannelsScreen() {
        let context = configuredLaunchContext(
            requestName: "nav.switch_tab",
            args: ["tab": "channels"]
        )
        launch(context.app)

        assertVisibleScreen("screen.channels", in: context)
        XCTAssertTrue(element(in: context.app, identifier: "screen.channels").waitForExistence(timeout: 8))
    }

    func legacyDiagnosticNavSwitchTabMatrixCoversPrimaryScreens() {
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

    func testQualityPrimaryNavigationUsesRealControlsAndReachesEachProductScreen() throws {
        let context = configuredLaunchContext()
        let sessionID = "ios-navigation-\(UUID().uuidString.lowercased())"
        context.app.launchArguments += [
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
        ]
        context.app.launchEnvironment["PUSHGO_QUALITY_SESSION_BASE64"] = qualitySessionPayload(
            sessionID: sessionID,
            fixture: "core.positive",
            eventCloseScenario: "accepted_and_delivered"
        )
        launch(context.app)

        assertQualityRuntimeReady(in: context.app, timeout: 15)
        XCTAssertEqual(
            element(in: context.app, identifier: "quality-runtime.ready").value as? String,
            sessionID
        )
        assertElementExists("screen.messages.list", in: context.app, timeout: 8)
        let tabs = context.app.tabBars.buttons
        XCTAssertGreaterThanOrEqual(tabs.count, 4, "The four primary product destinations must be reachable")
        let messagesTab = context.app.buttons["tab.messages"]
        XCTAssertTrue(
            messagesTab.waitForExistence(timeout: 8) && messagesTab.isHittable,
            "The real Messages tab must remain readable and actionable with a high unread badge."
        )
        XCTAssertEqual(messagesTab.label, "Messages")
        XCTAssertEqual(
            messagesTab.value as? String,
            "99+",
            "The broad positive fixture must expose the real capped high-unread state."
        )
        XCTAssertGreaterThanOrEqual(messagesTab.frame.width, 44, "The high badge compressed the tab target.")
        XCTAssertTrue(
            hasReadableLowerTitleContrast(in: messagesTab.screenshot()),
            "The high unread badge may have hidden the Messages title."
        )

        context.app.open(
            try XCTUnwrap(
                URL(string: "pushgo://open?kind=message&id=00000000-0000-0000-0000-000000000001")
            )
        )
        assertElementExists("sheet.message.detail", in: context.app, timeout: 8)
        XCTAssertTrue(
            context.app.staticTexts["Seeded from fixture.seed_messages for UI validation."]
                .waitForExistence(timeout: 5),
            "The real system URL must resolve the exact canonical Message."
        )
        tapWhenHittable(
            element(in: context.app, identifier: "action.message.close"),
            timeout: 5,
            message: "The system-routed Message detail must return to the App"
        )
        context.app.open(
            try XCTUnwrap(URL(string: "pushgo://open?kind=event&id=quality-event-active"))
        )
        let routedEventDetail = element(in: context.app, identifier: "sheet.event.detail")
        XCTAssertTrue(routedEventDetail.waitForExistence(timeout: 8))
        XCTAssertTrue(
            context.app.staticTexts["Event fixture for app-owned UI validation."]
                .waitForExistence(timeout: 5),
            "The real system URL must resolve the exact canonical Event detail."
        )
        tapWhenHittable(
            element(in: context.app, identifier: "action.event.close"),
            timeout: 5,
            message: "The system-routed Event must expose its real positive action"
        )
        tapWhenHittable(
            context.app.alerts.buttons.element(boundBy: 1),
            timeout: 5,
            message: "The system-routed Event confirmation must complete the positive state change"
        )
        XCTAssertTrue(
            routedEventDetail.waitForNonExistence(timeout: 12),
            "The system-routed Event must return only after the canonical projection accepts the change."
        )

        tabs.element(boundBy: 0).tap()
        assertElementExists("screen.messages.list", in: context.app, timeout: 8)
        XCTAssertTrue(
            context.app.staticTexts["P2 Split Seed Message"].waitForExistence(timeout: 8),
            "The real Messages tab must return to the canonical list after system routing."
        )

        tabs.element(boundBy: 1).tap()
        assertElementExists("screen.events.list", in: context.app, timeout: 8)
        let event = element(in: context.app, identifier: "event.row.quality-event-active")
        XCTAssertTrue(
            event.waitForExistence(timeout: 8),
            "The system-routed Event state change must return to the canonical Events list."
        )
        tapWhenHittable(
            event,
            timeout: 8,
            message: "The Event changed through the system route must remain actionable"
        )
        XCTAssertTrue(
            element(in: context.app, identifier: "sheet.event.detail")
                .waitForExistence(timeout: 8)
        )
        XCTAssertTrue(
            element(in: context.app, identifier: "field.event.detail.status.closed")
                .waitForExistence(timeout: 8),
            "PR navigation must prove the routed close reached canonical closed state, not only that the row still exists."
        )
        XCTAssertFalse(
            element(in: context.app, identifier: "action.event.close").exists,
            "A canonically closed Event must not continue offering the close action."
        )
        let verifiedClosedDetail = element(in: context.app, identifier: "sheet.event.detail")
        verifiedClosedDetail.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.02))
            .press(
                forDuration: 0.2,
                thenDragTo: verifiedClosedDetail.coordinate(
                    withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)
                )
            )
        XCTAssertTrue(
            verifiedClosedDetail.waitForNonExistence(timeout: 5),
            "The verified closed Event detail must return to navigation"
        )

        tabs.element(boundBy: 2).tap()
        assertElementExists("screen.things.list", in: context.app, timeout: 8)
        let thing = element(in: context.app, identifier: "thing.row.quality-thing-rich")
        XCTAssertTrue(thing.waitForExistence(timeout: 8))
        XCTAssertTrue(
            thing.label.contains("P2 Thing Rich")
                || context.app.staticTexts["P2 Thing Rich"].exists,
            "Things must render the exact canonical object; deep relations remain impact-selected."
        )

        tabs.element(boundBy: 3).tap()
        assertElementExists("screen.channels", in: context.app, timeout: 8)
        let channel = element(
            in: context.app,
            identifier: "channel.row.01H00000000000000000000001"
        )
        XCTAssertTrue(channel.waitForExistence(timeout: 8))
        XCTAssertTrue(
            context.app.staticTexts["Quality Keep History"].exists || channel.label.contains("Quality Keep History"),
            "Channels must render the exact canonical subscription, not merely an empty screen."
        )

        let settings = element(in: context.app, identifier: "action.channels.settings")
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        XCTAssertTrue(settings.isHittable)
        settings.tap()
        assertElementExists("screen.settings", in: context.app, timeout: 8)

        let gettingStarted = scrollToHittableElement(
            identifier: "action.settings.open_getting_started_docs",
            in: context.app
        )
        tapWhenHittable(
            gettingStarted,
            timeout: 8,
            message: "The real Settings documentation action must remain usable"
        )
        let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
        XCTAssertTrue(
            safari.wait(for: .runningForeground, timeout: 10),
            "The documentation action must hand off to the real system browser."
        )
        let collapsedAddress = safari.descendants(matching: .any)
            .matching(identifier: "TabBarItemTitle")
            .firstMatch
        tapWhenHittable(
            collapsedAddress,
            timeout: 8,
            message: "Safari must let the user inspect the Settings documentation destination"
        )
        let browserAddress = safari.textFields.matching(
            NSPredicate(
                format: "value ==[c] %@ OR value ==[c] %@",
                "pushgo.dev/guides/getting-started/",
                "https://pushgo.dev/guides/getting-started/"
            )
        ).firstMatch
        XCTAssertTrue(
            browserAddress.waitForExistence(timeout: 8),
            "Safari must expose the exact Getting Started destination, not merely any pushgo.dev page."
        )
        context.app.open(
            try XCTUnwrap(URL(string: "pushgo://open?kind=thing&id=quality-thing-rich"))
        )
        let routedThingDetail = element(in: context.app, identifier: "sheet.thing.detail")
        XCTAssertTrue(routedThingDetail.waitForExistence(timeout: 8))
        XCTAssertTrue(
            context.app.staticTexts["Fixture thing summary"].waitForExistence(timeout: 5),
            "The real system URL must resolve the exact canonical Thing detail."
        )
    }

    func testSettingsPageVisibilityUsesRealControlsAndPersistsAcrossRelaunch() {
        let context = configuredLaunchContext()
        let sessionID = "ios-settings-visibility-\(UUID().uuidString.lowercased())"
        let encodedSession = qualitySessionPayload(
            sessionID: sessionID,
            fixture: "messages.standard"
        )
        context.app.launchEnvironment["PUSHGO_QUALITY_SESSION_BASE64"] = encodedSession
        context.app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        launch(context.app)
        assertQualityRuntimeReady(in: context.app, timeout: 15)
        assertDataTabVisibility(
            messagesVisible: true,
            eventsVisible: true,
            thingsVisible: true,
            in: context.app
        )

        openSettingsFromChannels(in: context.app)
        let soundSettingsAction = scrollToHittableElement(
            identifier: "action.settings.notification_sounds",
            in: context.app
        )
        tapWhenHittable(
            soundSettingsAction,
            timeout: 8,
            message: "Notification sounds must open through the real Settings action"
        )
        let soundSettingsScreen = element(
            in: context.app,
            identifier: "screen.settings.notification_sounds"
        )
        XCTAssertTrue(soundSettingsScreen.waitForExistence(timeout: 8))
        let lowPrioritySound = element(
            in: context.app,
            identifier: "picker.settings.notification_sounds.low"
        )
        tapWhenHittable(
            lowPrioritySound,
            timeout: 8,
            message: "The low-priority sound selector must be operable"
        )
        tapWhenHittable(
            context.app.buttons["Alert Beacon"],
            timeout: 8,
            message: "A real built-in sound must be selectable"
        )
        XCTAssertEqual(
            lowPrioritySound.value as? String,
            "Alert Beacon",
            "The sound editor must project the user's selected low-priority sound."
        )
        tapWhenHittable(
            element(in: context.app, identifier: "action.settings.notification_sounds.close"),
            timeout: 8,
            message: "Saving the selected sound must provide a reliable way back to Settings"
        )
        XCTAssertTrue(
            soundSettingsScreen.waitForNonExistence(timeout: 8),
            "Dismissing the sound editor must return to Settings before lifecycle checks."
        )

        let messageToggle = scrollToHittableElement(
            identifier: "toggle.settings.page.messages",
            in: context.app
        )
        XCTAssertTrue(messageToggle.isHittable)
        messageToggle.tap()
        let eventToggle = scrollToHittableElement(
            identifier: "toggle.settings.page.events",
            in: context.app
        )
        XCTAssertTrue(eventToggle.isHittable)
        eventToggle.tap()
        let thingToggle = scrollToHittableElement(
            identifier: "toggle.settings.page.things",
            in: context.app
        )
        XCTAssertTrue(thingToggle.isHittable)
        thingToggle.tap()
        leaveSettings(in: context.app)
        assertDataTabVisibility(
            messagesVisible: false,
            eventsVisible: false,
            thingsVisible: false,
            in: context.app
        )
        XCTAssertFalse(
            context.app.tabBars.buttons["tab.messages"].exists,
            "Hiding Messages must remove the badge-owning navigation destination, not orphan its unread state"
        )
        assertElementExists("screen.channels", in: context.app, timeout: 8)

        context.app.terminate()
        context.app.launchEnvironment["PUSHGO_QUALITY_SESSION_BASE64"] = encodedSession
        launch(context.app)
        assertQualityRuntimeReady(in: context.app, timeout: 15)
        assertDataTabVisibility(
            messagesVisible: false,
            eventsVisible: false,
            thingsVisible: false,
            in: context.app
        )
        XCTAssertFalse(
            context.app.tabBars.buttons["tab.messages"].exists,
            "The hidden Messages badge owner must not return after process relaunch"
        )

        openSettingsFromChannels(in: context.app)
        let persistedSoundSettingsAction = scrollToHittableElement(
            identifier: "action.settings.notification_sounds",
            in: context.app
        )
        tapWhenHittable(
            persistedSoundSettingsAction,
            timeout: 8,
            message: "Notification sound settings must remain reachable after relaunch"
        )
        let persistedSoundSettingsScreen = element(
            in: context.app,
            identifier: "screen.settings.notification_sounds"
        )
        XCTAssertTrue(persistedSoundSettingsScreen.waitForExistence(timeout: 8))
        let persistedLowPrioritySound = element(
            in: context.app,
            identifier: "picker.settings.notification_sounds.low"
        )
        XCTAssertTrue(persistedLowPrioritySound.waitForExistence(timeout: 8))
        XCTAssertEqual(
            persistedLowPrioritySound.value as? String,
            "Alert Beacon",
            "The selected sound must be restored from App-owned settings after process relaunch."
        )
        tapWhenHittable(
            element(in: context.app, identifier: "action.settings.notification_sounds.close"),
            timeout: 8,
            message: "The restored sound editor must remain dismissible"
        )
        XCTAssertTrue(persistedSoundSettingsScreen.waitForNonExistence(timeout: 8))

        let persistedOffMessageToggle = scrollToHittableElement(
            identifier: "toggle.settings.page.messages",
            in: context.app
        )
        XCTAssertTrue(persistedOffMessageToggle.isHittable)
        persistedOffMessageToggle.tap()
        let persistedOffToggle = scrollToHittableElement(
            identifier: "toggle.settings.page.events",
            in: context.app
        )
        XCTAssertTrue(persistedOffToggle.isHittable)
        persistedOffToggle.tap()
        let persistedOffThingToggle = scrollToHittableElement(
            identifier: "toggle.settings.page.things",
            in: context.app
        )
        XCTAssertTrue(persistedOffThingToggle.isHittable)
        persistedOffThingToggle.tap()
        leaveSettings(in: context.app)
        assertMessagesTabBadgeCount(
            1,
            in: context.app,
            message: "Restoring Messages must project the still-unread canonical message back into its badge owner"
        )
        assertDataTabVisibility(
            messagesVisible: true,
            eventsVisible: true,
            thingsVisible: true,
            in: context.app,
            openWhenVisible: true
        )
    }

    func testSettingsServerUsesRealControlsAndScopesDataAfterRelaunch() {
        let context = configuredLaunchContext()
        let sessionID = "ios-settings-server-\(UUID().uuidString.lowercased())"
        let normalizedAddress = "https://quality-settings.invalid/api"
        let encodedSession = qualitySessionPayload(
            sessionID: sessionID,
            fixture: "channels.standard",
            channelMutationScenario: "accepted",
            expectedChannelMutationGatewayURL: normalizedAddress
        )
        context.app.launchEnvironment["PUSHGO_QUALITY_SESSION_BASE64"] = encodedSession
        launch(context.app)
        assertQualityRuntimeReady(in: context.app, timeout: 15)

        tapWhenHittable(channelsTab(in: context.app), timeout: 8)
        XCTAssertTrue(
            element(in: context.app, identifier: "channel.row.01H00000000000000000000001")
                .waitForExistence(timeout: 8),
            "The original gateway-scoped fixture must exist before the server change"
        )
        openSettingsFromChannels(in: context.app)
        let serverManagementAction = element(
            in: context.app,
            identifier: "action.settings.server_management"
        )
        tapWhenHittable(
            serverManagementAction,
            timeout: 8
        )

        let addressField = element(in: context.app, identifier: "field.settings.server.address")
        XCTAssertTrue(addressField.waitForExistence(timeout: 8))
        let gatewayCredential = String(repeating: "g", count: 24)
        let gatewayFieldID = ["field", "settings", "server", "token"].joined(separator: ".")
        var credentialField = context.app.secureTextFields.matching(identifier: gatewayFieldID).firstMatch
        XCTAssertTrue(credentialField.waitForExistence(timeout: 5))
        enterSecureText(in: credentialField, with: gatewayCredential)
        let credentialVisibilityAction = element(
            in: context.app,
            identifier: "action.settings.server.token.toggle_visibility"
        )
        tapWhenHittable(credentialVisibilityAction, timeout: 5)
        var revealedCredentialField = context.app.textFields.matching(identifier: gatewayFieldID).firstMatch
        XCTAssertTrue(revealedCredentialField.waitForExistence(timeout: 5))
        XCTAssertEqual(revealedCredentialField.value as? String, gatewayCredential)
        revealedCredentialField.typeKey(XCUIKeyboardKey.return.rawValue, modifierFlags: [])
        tapWhenHittable(
            element(
                in: context.app,
                identifier: "action.settings.server.token.toggle_visibility"
            ),
            timeout: 5
        )
        credentialField = context.app.secureTextFields.matching(identifier: gatewayFieldID).firstMatch
        XCTAssertTrue(credentialField.waitForExistence(timeout: 5))
        replaceText(in: addressField, with: "\(normalizedAddress)/")
        addressField.typeKey(XCUIKeyboardKey.return.rawValue, modifierFlags: [])
        tapWhenHittable(
            element(in: context.app, identifier: "action.settings.server.save"),
            timeout: 8
        )
        XCTAssertTrue(
            addressField.waitForNonExistence(timeout: 10),
            "A successfully persisted server address must close the editor"
        )
        leaveSettings(in: context.app)
        XCTAssertTrue(
            element(in: context.app, identifier: "channel.row.01H00000000000000000000001")
                .waitForNonExistence(timeout: 8),
            "Changing servers must immediately scope channel data to the new gateway"
        )
        tapWhenHittable(
            element(in: context.app, identifier: "action.channels.add"),
            timeout: 8
        )
        let createName = element(in: context.app, identifier: "field.channels.create.name")
        let createPassword = element(in: context.app, identifier: "field.channels.create.password")
        XCTAssertTrue(createName.waitForExistence(timeout: 8))
        replaceText(in: createName, with: "New Gateway Channel")
        enterSecureText(in: createPassword, with: "qualityx")
        tapWhenHittable(
            element(in: context.app, identifier: "action.channels.entry.submit"),
            timeout: 8
        )
        let createdChannel = element(
            in: context.app,
            identifier: "channel.row.01H00000000000000000000003"
        )
        XCTAssertTrue(
            createdChannel.waitForExistence(timeout: 8),
            "A post-commit Channel operation must use the newly active Gateway transport."
        )
        XCTAssertTrue(createdChannel.label.contains("New Gateway Channel"))

        context.app.terminate()
        context.app.launchEnvironment["PUSHGO_QUALITY_SESSION_BASE64"] = encodedSession
        launch(context.app)
        assertQualityRuntimeReady(in: context.app, timeout: 15)
        tapWhenHittable(channelsTab(in: context.app), timeout: 8)
        XCTAssertTrue(
            element(
                in: context.app,
                identifier: "channel.row.01H00000000000000000000001"
            ).waitForNonExistence(timeout: 8),
            "Relaunch must not reload channel data owned by the previous gateway"
        )
        XCTAssertTrue(
            element(
                in: context.app,
                identifier: "channel.row.01H00000000000000000000003"
            ).waitForExistence(timeout: 8),
            "The exact post-switch Channel result must remain under the new gateway after relaunch."
        )
        openSettingsFromChannels(in: context.app)
        tapWhenHittable(
            element(in: context.app, identifier: "action.settings.server_management"),
            timeout: 8
        )
        let restoredAddressField = element(in: context.app, identifier: "field.settings.server.address")
        XCTAssertTrue(restoredAddressField.waitForExistence(timeout: 8))
        XCTAssertEqual(
            restoredAddressField.value as? String,
            normalizedAddress,
            "The normalized server address must survive a full app relaunch"
        )
        credentialField = context.app.secureTextFields.matching(identifier: gatewayFieldID).firstMatch
        XCTAssertTrue(credentialField.waitForExistence(timeout: 5))
        tapWhenHittable(
            element(in: context.app, identifier: "action.settings.server.token.toggle_visibility"),
            timeout: 5
        )
        revealedCredentialField = context.app.textFields.matching(identifier: gatewayFieldID).firstMatch
        XCTAssertTrue(revealedCredentialField.waitForExistence(timeout: 5))
        XCTAssertEqual(revealedCredentialField.value as? String, gatewayCredential)
    }

    func testSettingsServerRejectsInvalidAndUnregisteredCandidatesWithoutLeakingSheetError() {
        let context = configuredLaunchContext()
        let sessionID = "ios-server-reject-\(UUID().uuidString.lowercased())"
        context.app.launchEnvironment["PUSHGO_QUALITY_SESSION_BASE64"] = qualitySessionPayload(
            sessionID: sessionID,
            fixture: "channels.standard",
            failGatewaySwitchValidationOnce: true,
            channelMutationScenario: "accepted"
        )
        launch(context.app)
        assertQualityRuntimeReady(in: context.app, timeout: 15)

        tapWhenHittable(channelsTab(in: context.app), timeout: 8)
        openSettingsFromChannels(in: context.app)
        let serverManagementAction = element(
            in: context.app,
            identifier: "action.settings.server_management"
        )
        let originalGatewayLabel = serverManagementAction.label
        tapWhenHittable(serverManagementAction, timeout: 8)

        let addressField = element(in: context.app, identifier: "field.settings.server.address")
        XCTAssertTrue(addressField.waitForExistence(timeout: 8))
        replaceText(in: addressField, with: "not a valid url")
        tapWhenHittable(
            element(in: context.app, identifier: "action.settings.server.save"),
            timeout: 8
        )
        XCTAssertTrue(
            element(in: context.app, identifier: "feedback.settings.server")
                .waitForExistence(timeout: 5),
            "An invalid address must remain in the editor with actionable inline feedback"
        )
        XCTAssertFalse(
            element(in: context.app, identifier: "feedback.settings.root").exists,
            "A server editor failure belongs to the sheet and must not also appear on the host page"
        )

        let rejectedAddress = "https://quality-settings.invalid/api"
        replaceText(in: addressField, with: "\(rejectedAddress)/")
        tapWhenHittable(
            element(in: context.app, identifier: "action.settings.server.save"),
            timeout: 8
        )
        XCTAssertTrue(
            element(in: context.app, identifier: "feedback.settings.server")
                .waitForExistence(timeout: 8),
            "A candidate gateway registration failure must stay in the editor"
        )
        XCTAssertFalse(
            element(in: context.app, identifier: "feedback.settings.root").exists,
            "Candidate registration failure must not leak into the host Settings page"
        )
        XCTAssertTrue(addressField.exists, "A rejected candidate gateway must not dismiss the editor")
        XCTAssertEqual(
            element(in: context.app, identifier: "action.settings.server_management").label,
            originalGatewayLabel,
            "The old gateway must remain active until candidate registration succeeds"
        )

        tapWhenHittable(
            element(in: context.app, identifier: "action.settings.server.cancel"),
            timeout: 8
        )
        XCTAssertTrue(addressField.waitForNonExistence(timeout: 8))
        XCTAssertFalse(
            element(in: context.app, identifier: "feedback.settings.root").exists,
            "A dismissed sheet-owned error must never reappear on the host Settings page"
        )
        XCTAssertEqual(
            element(in: context.app, identifier: "action.settings.server_management").label,
            originalGatewayLabel,
            "Dismissing a rejected candidate must leave the saved gateway unchanged"
        )
    }

    func testSettingsGatewaySyncFailureReportsCommittedGatewayAndPendingRecovery() {
        let context = configuredLaunchContext()
        let sessionID = "ios-server-sync-pending-\(UUID().uuidString.lowercased())"
        let normalizedAddress = "https://quality-sync-pending.invalid/api"
        let encodedSession = qualitySessionPayload(
            sessionID: sessionID,
            fixture: "channels.standard",
            failGatewayPostCommitSyncOnce: true,
            channelMutationScenario: "accepted",
            expectedChannelMutationGatewayURL: normalizedAddress
        )
        context.app.launchEnvironment["PUSHGO_QUALITY_SESSION_BASE64"] = encodedSession
        launch(context.app)
        assertQualityRuntimeReady(in: context.app, timeout: 15)

        openSettingsFromChannels(in: context.app)
        let serverAction = element(
            in: context.app,
            identifier: "action.settings.server_management"
        )
        tapWhenHittable(serverAction, timeout: 8)
        let addressField = element(in: context.app, identifier: "field.settings.server.address")
        XCTAssertTrue(addressField.waitForExistence(timeout: 8))
        replaceText(in: addressField, with: "\(normalizedAddress)/")
        tapWhenHittable(
            element(in: context.app, identifier: "action.settings.server.save"),
            timeout: 8
        )

        let pendingFeedback = element(in: context.app, identifier: "feedback.settings.gateway.result")
        XCTAssertTrue(
            pendingFeedback.waitForExistence(timeout: 8),
            "A committed gateway with recoverable sync work must still report a user-visible result."
        )
        let pendingText = pendingFeedback.label.lowercased()
        XCTAssertTrue(
            pendingText.contains("sync") || pendingFeedback.label.contains("同步"),
            "The result must say that gateway sync is pending, not claim an atomic failure."
        )
        XCTAssertTrue(
            addressField.waitForNonExistence(timeout: 8),
            "A committed gateway must close the editor after reporting pending reconciliation."
        )
        XCTAssertTrue(
            element(in: context.app, identifier: "action.settings.server_management")
                .label.contains(normalizedAddress),
            "The settings row must expose the newly committed gateway, even when sync is pending."
        )
        XCTAssertFalse(
            element(in: context.app, identifier: "feedback.settings.root").exists,
            "A post-commit sync failure must not be surfaced as a host-page form failure."
        )

        context.app.terminate()
        let relaunchedSession = qualitySessionPayload(
            sessionID: sessionID,
            fixture: "channels.standard",
            channelMutationScenario: "accepted",
            expectedChannelMutationGatewayURL: normalizedAddress
        )
        context.app.launchEnvironment["PUSHGO_QUALITY_SESSION_BASE64"] = relaunchedSession
        launch(context.app)
        assertQualityRuntimeReady(in: context.app, timeout: 15)
        // Channels entry is the recovery point.  It must execute the real
        // controller reconciliation before a new-gateway mutation is allowed
        // to establish its canonical result.
        tapWhenHittable(channelsTab(in: context.app), timeout: 8)
        XCTAssertTrue(
            element(in: context.app, identifier: "channel.row.01H00000000000000000000001")
                .waitForNonExistence(timeout: 8),
            "Recovery must retain the newly committed gateway's data scope."
        )
        let recoveredSyncRow = element(
            in: context.app,
            identifier: "channel.row.01H00000000000000000000004"
        )
        XCTAssertTrue(
            recoveredSyncRow.waitForExistence(timeout: 8),
            "Recovery must sync a candidate-scoped subscription, not only reload the list."
        )
        XCTAssertTrue(
            recoveredSyncRow.label.contains("Quality Recovery Sync Completed"),
            "The recovery sync must produce the expected business update."
        )
        tapWhenHittable(
            element(in: context.app, identifier: "action.channels.add"),
            timeout: 8
        )
        let createName = element(in: context.app, identifier: "field.channels.create.name")
        let createPassword = element(in: context.app, identifier: "field.channels.create.password")
        XCTAssertTrue(createName.waitForExistence(timeout: 8))
        replaceText(in: createName, with: "Recovered Gateway Channel")
        enterSecureText(in: createPassword, with: "qualityx")
        tapWhenHittable(
            element(in: context.app, identifier: "action.channels.entry.submit"),
            timeout: 8
        )
        let recoveredChannel = element(
            in: context.app,
            identifier: "channel.row.01H00000000000000000000003"
        )
        XCTAssertTrue(
            recoveredChannel.waitForExistence(timeout: 8),
            "Channels-entry recovery must permit a real mutation on the committed gateway."
        )
        XCTAssertTrue(recoveredChannel.label.contains("Recovered Gateway Channel"))

        openSettingsFromChannels(in: context.app)
        XCTAssertTrue(
            element(in: context.app, identifier: "action.settings.server_management")
                .label.contains(normalizedAddress),
            "The committed gateway must remain authoritative after recovery and a real mutation."
        )
    }

    func testSettingsDecryptionRejectsInvalidKeyPersistsAndClearsValidKey() {
        let context = configuredLaunchContext()
        let sessionID = "ios-settings-decryption-\(UUID().uuidString.lowercased())"
        let encodedSession = qualitySessionPayload(
            sessionID: sessionID,
            fixture: "messages.standard",
            channelMutationScenario: "accepted"
        )
        context.app.launchEnvironment["PUSHGO_QUALITY_SESSION_BASE64"] = encodedSession
        launch(context.app)
        assertQualityRuntimeReady(in: context.app, timeout: 15)
        openSettingsFromChannels(in: context.app)
        let initialDecryptionAction = scrollToHittableElement(
            identifier: "action.settings.open_decryption",
            in: context.app
        )
        let initialStatusLabel = initialDecryptionAction.label
        tapWhenHittable(initialDecryptionAction, timeout: 8)

        let keyField = element(in: context.app, identifier: "field.settings.decryption.key")
        XCTAssertTrue(keyField.waitForExistence(timeout: 8))
        enterSecureText(in: keyField, with: "short")
        XCTAssertEqual(keyField.elementType, .secureTextField)
        let visibilityAction = element(
            in: context.app,
            identifier: "action.settings.decryption.toggle_visibility"
        )
        tapWhenHittable(visibilityAction, timeout: 5)
        let visibleKeyField = element(in: context.app, identifier: keyField.identifier)
        XCTAssertEqual(visibleKeyField.elementType, .textField)
        XCTAssertEqual(visibleKeyField.value as? String, "short")
        tapWhenHittable(
            element(
                in: context.app,
                identifier: "action.settings.decryption.toggle_visibility"
            ),
            timeout: 5
        )
        XCTAssertEqual(
            element(in: context.app, identifier: keyField.identifier).elementType,
            .secureTextField
        )
        tapWhenHittable(
            element(in: context.app, identifier: "action.settings.decryption.save"),
            timeout: 8
        )
        XCTAssertTrue(
            element(in: context.app, identifier: "feedback.settings.decryption")
                .waitForExistence(timeout: 5),
            "An invalid key must remain visible as inline validation feedback"
        )
        XCTAssertTrue(keyField.exists, "Invalid key input must not leave the decryption editor")

        let validKey = String(repeating: "k", count: 32)
        enterSecureText(in: keyField, with: validKey)
        tapWhenHittable(
            element(in: context.app, identifier: "action.settings.decryption.save"),
            timeout: 8
        )
        XCTAssertTrue(
            keyField.waitForNonExistence(timeout: 8),
            "A valid key must dismiss the editor only after persistence succeeds"
        )
        let configuredDecryptionAction = scrollToHittableElement(
            identifier: "action.settings.open_decryption",
            in: context.app
        )
        XCTAssertTrue(configuredDecryptionAction.waitForExistence(timeout: 8))
        let configuredStatusLabel = configuredDecryptionAction.label
        XCTAssertNotEqual(
            configuredStatusLabel,
            initialStatusLabel,
            "The user-visible decryption status must change after persistence"
        )

        context.app.terminate()
        context.app.launchEnvironment["PUSHGO_QUALITY_SESSION_BASE64"] = encodedSession
        launch(context.app)
        assertQualityRuntimeReady(in: context.app, timeout: 15)
        ensureSettingsVisible(in: context.app)
        let restoredDecryptionAction = scrollToHittableElement(
            identifier: "action.settings.open_decryption",
            in: context.app
        )
        XCTAssertEqual(
            restoredDecryptionAction.label,
            configuredStatusLabel,
            "The configured status must survive a full app relaunch"
        )
        tapWhenHittable(restoredDecryptionAction, timeout: 8)
        let restoredKeyField = element(in: context.app, identifier: "field.settings.decryption.key")
        XCTAssertTrue(restoredKeyField.waitForExistence(timeout: 5))
        XCTAssertNotEqual(
            restoredKeyField.value as? String,
            validKey,
            "The persisted secret must never be echoed back into the UI"
        )
        tapWhenHittable(
            element(in: context.app, identifier: "action.settings.decryption.save"),
            timeout: 8
        )
        XCTAssertTrue(restoredKeyField.waitForNonExistence(timeout: 8))
        let preservedAction = scrollToHittableElement(
            identifier: "action.settings.open_decryption",
            in: context.app
        )
        XCTAssertEqual(preservedAction.label, configuredStatusLabel)

        context.app.terminate()
        context.app.launchEnvironment["PUSHGO_QUALITY_SESSION_BASE64"] = encodedSession
        launch(context.app)
        assertQualityRuntimeReady(in: context.app, timeout: 15)
        ensureSettingsVisible(in: context.app)
        let relaunchedPreservedAction = scrollToHittableElement(
            identifier: "action.settings.open_decryption",
            in: context.app
        )
        XCTAssertEqual(
            relaunchedPreservedAction.label,
            configuredStatusLabel,
            "A blank save must not remove the non-echoed configuration after relaunch"
        )
        tapWhenHittable(relaunchedPreservedAction, timeout: 8)
        let clearAction = element(in: context.app, identifier: "action.settings.decryption.clear")
        tapWhenHittable(clearAction, timeout: 8)
        XCTAssertTrue(
            clearAction.waitForNonExistence(timeout: 8),
            "Clearing must finish before the editor closes"
        )
        let clearedDecryptionAction = scrollToHittableElement(
            identifier: "action.settings.open_decryption",
            in: context.app
        )
        XCTAssertEqual(
            clearedDecryptionAction.label,
            initialStatusLabel,
            "Clearing must restore the not-configured state"
        )

        context.app.terminate()
        context.app.launchEnvironment["PUSHGO_QUALITY_SESSION_BASE64"] = encodedSession
        launch(context.app)
        assertQualityRuntimeReady(in: context.app, timeout: 15)
        ensureSettingsVisible(in: context.app)
        let relaunchedClearedAction = scrollToHittableElement(
            identifier: "action.settings.open_decryption",
            in: context.app
        )
        XCTAssertEqual(
            relaunchedClearedAction.label,
            initialStatusLabel,
            "The cleared configuration must remain absent after relaunch"
        )
    }

    func testGatewayLocalCommitFailureRollsBackBeforeRetryCommits() {
        let context = configuredLaunchContext()
        let sessionID = "ios-settings-server-commit-\(UUID().uuidString.lowercased())"
        let failingSession = qualitySessionPayload(
            sessionID: sessionID,
            fixture: "channels.standard",
            failGatewaySwitchCommitOnce: true,
            channelMutationScenario: "accepted"
        )
        let retrySession = qualitySessionPayload(
            sessionID: sessionID,
            fixture: "channels.standard",
            channelMutationScenario: "accepted"
        )
        context.app.launchEnvironment["PUSHGO_QUALITY_SESSION_BASE64"] = failingSession
        launch(context.app)
        assertQualityRuntimeReady(in: context.app, timeout: 15)
        openSettingsFromChannels(in: context.app)

        let serverAction = element(in: context.app, identifier: "action.settings.server_management")
        let originalGatewayLabel = serverAction.label
        tapWhenHittable(serverAction, timeout: 8)
        let addressField = element(in: context.app, identifier: "field.settings.server.address")
        XCTAssertTrue(addressField.waitForExistence(timeout: 8))
        let normalizedAddress = "https://quality-commit.invalid/api"
        replaceText(in: addressField, with: "\(normalizedAddress)/")
        tapWhenHittable(
            element(in: context.app, identifier: "action.settings.server.save"),
            timeout: 8
        )

        XCTAssertTrue(
            element(in: context.app, identifier: "feedback.settings.server")
                .waitForExistence(timeout: 8),
            "A local commit failure must remain actionable in the server sheet"
        )
        XCTAssertTrue(addressField.exists, "A failed local commit must not dismiss the editor")
        XCTAssertFalse(element(in: context.app, identifier: "feedback.settings.root").exists)
        XCTAssertEqual(
            element(in: context.app, identifier: "action.settings.server_management").label,
            originalGatewayLabel,
            "The candidate must not become the active gateway after a partial local commit"
        )

        context.app.terminate()
        context.app.launchEnvironment["PUSHGO_QUALITY_SESSION_BASE64"] = retrySession
        launch(context.app)
        assertQualityRuntimeReady(in: context.app, timeout: 15)
        openSettingsFromChannels(in: context.app)
        let restoredServerAction = element(
            in: context.app,
            identifier: "action.settings.server_management"
        )
        XCTAssertEqual(
            restoredServerAction.label,
            originalGatewayLabel,
            "Rollback must keep the old gateway authoritative after process restart"
        )
        tapWhenHittable(restoredServerAction, timeout: 8)
        let retryField = element(in: context.app, identifier: "field.settings.server.address")
        XCTAssertTrue(retryField.waitForExistence(timeout: 8))
        replaceText(in: retryField, with: "\(normalizedAddress)/")
        tapWhenHittable(
            element(in: context.app, identifier: "action.settings.server.save"),
            timeout: 8
        )
        XCTAssertTrue(retryField.waitForNonExistence(timeout: 10))
        XCTAssertTrue(
            element(in: context.app, identifier: "action.settings.server_management")
                .label.contains(normalizedAddress),
            "Only the successful retry may expose the candidate as active"
        )
    }

    func testDecryptionProtectedStoreFailureDoesNotConfigureBeforeRetry() {
        let context = configuredLaunchContext()
        let sessionID = "ios-settings-key-store-\(UUID().uuidString.lowercased())"
        let failingSession = qualitySessionPayload(
            sessionID: sessionID,
            fixture: "messages.standard",
            failNotificationMaterialPersistenceOnce: true
        )
        let retrySession = qualitySessionPayload(
            sessionID: sessionID,
            fixture: "messages.standard"
        )
        context.app.launchEnvironment["PUSHGO_QUALITY_SESSION_BASE64"] = failingSession
        launch(context.app)
        assertQualityRuntimeReady(in: context.app, timeout: 15)
        openSettingsFromChannels(in: context.app)
        let initialAction = scrollToHittableElement(
            identifier: "action.settings.open_decryption",
            in: context.app
        )
        let initialLabel = initialAction.label
        tapWhenHittable(initialAction, timeout: 8)
        let keyField = element(in: context.app, identifier: "field.settings.decryption.key")
        XCTAssertTrue(keyField.waitForExistence(timeout: 8))
        enterSecureText(in: keyField, with: String(repeating: "p", count: 32))
        tapWhenHittable(
            element(in: context.app, identifier: "action.settings.decryption.save"),
            timeout: 8
        )
        XCTAssertTrue(
            element(in: context.app, identifier: "feedback.settings.decryption")
                .waitForExistence(timeout: 8),
            "Protected-store failure must be owned by the decryption sheet"
        )
        XCTAssertTrue(keyField.exists, "Failed secret persistence must keep the editor open")
        XCTAssertFalse(element(in: context.app, identifier: "feedback.settings.root").exists)

        context.app.terminate()
        context.app.launchEnvironment["PUSHGO_QUALITY_SESSION_BASE64"] = retrySession
        launch(context.app)
        assertQualityRuntimeReady(in: context.app, timeout: 15)
        ensureSettingsVisible(in: context.app)
        let restoredAction = scrollToHittableElement(
            identifier: "action.settings.open_decryption",
            in: context.app
        )
        XCTAssertEqual(
            restoredAction.label,
            initialLabel,
            "A failed protected write must not appear configured after restart"
        )
        tapWhenHittable(restoredAction, timeout: 8)
        let retryField = element(in: context.app, identifier: "field.settings.decryption.key")
        XCTAssertTrue(retryField.waitForExistence(timeout: 8))
        enterSecureText(in: retryField, with: String(repeating: "p", count: 32))
        tapWhenHittable(
            element(in: context.app, identifier: "action.settings.decryption.save"),
            timeout: 8
        )
        XCTAssertTrue(retryField.waitForNonExistence(timeout: 8))
        let configuredAction = scrollToHittableElement(
            identifier: "action.settings.open_decryption",
            in: context.app
        )
        XCTAssertNotEqual(configuredAction.label, initialLabel)
    }

    func testEncryptedMessageRecoversAfterConfiguringKeyAndSurvivesRelaunch() {
        let sessionID = "ios-encrypted-recovery-\(UUID().uuidString.lowercased())"
        let encodedSession = qualitySessionPayload(
            sessionID: sessionID,
            fixture: "messages.encrypted.valid"
        )
        let context = configuredLaunchContext()
        context.app.launchEnvironment["PUSHGO_QUALITY_SESSION_BASE64"] = encodedSession
        launch(context.app)
        assertQualityRuntimeReady(in: context.app, timeout: 15)

        XCTAssertTrue(context.app.staticTexts["Encrypted Quality Message"].waitForExistence(timeout: 8))
        XCTAssertTrue(
            context.app.staticTexts["Configure decryption to read this message."].waitForExistence(timeout: 5)
        )
        context.app.staticTexts["Encrypted Quality Message"].tap()
        assertElementExists("sheet.message.detail", in: context.app, timeout: 8)
        assertElementExists("status.message.decryption.notConfigured", in: context.app, timeout: 5)
        tapWhenHittable(
            element(in: context.app, identifier: "action.message.configure_decryption"),
            timeout: 8
        )

        let keyField = element(in: context.app, identifier: "field.settings.decryption.key")
        XCTAssertTrue(keyField.waitForExistence(timeout: 8))
        enterSecureText(in: keyField, with: String(repeating: "Z", count: 16))
        tapWhenHittable(
            element(in: context.app, identifier: "action.settings.decryption.save"),
            timeout: 8
        )
        XCTAssertTrue(keyField.waitForNonExistence(timeout: 8))

        let settingsScreen = element(in: context.app, identifier: "screen.settings")
        tapWhenHittable(
            element(in: context.app, identifier: "action.settings.close"),
            timeout: 8
        )
        XCTAssertTrue(settingsScreen.waitForNonExistence(timeout: 8))
        XCTAssertTrue(
            context.app.staticTexts["Configure decryption to read this message."].exists,
            "A wrong but valid-length key must preserve the safe original fallback"
        )
        assertElementExists("status.message.decryption.decryptFailed", in: context.app, timeout: 5)
        XCTAssertFalse(
            context.app.staticTexts["Recovered from the original encrypted payload."].exists,
            "A wrong key must never fabricate successful plaintext"
        )

        tapWhenHittable(
            element(in: context.app, identifier: "action.message.configure_decryption"),
            timeout: 8
        )
        XCTAssertTrue(keyField.waitForExistence(timeout: 8))
        enterSecureText(in: keyField, with: ["Quality", "Key", "123456"].joined())
        tapWhenHittable(
            element(in: context.app, identifier: "action.settings.decryption.save"),
            timeout: 8
        )
        XCTAssertTrue(keyField.waitForNonExistence(timeout: 8))
        tapWhenHittable(
            element(in: context.app, identifier: "action.settings.close"),
            timeout: 8
        )
        XCTAssertTrue(settingsScreen.waitForNonExistence(timeout: 8))
        XCTAssertTrue(
            context.app.staticTexts["Recovered from the original encrypted payload."]
                .waitForExistence(timeout: 8),
            "The original persisted message must become readable after saving its valid key"
        )
        assertElementExists("status.message.decryption.decryptOk", in: context.app, timeout: 5)

        context.app.terminate()
        let relaunched = configuredLaunchContext()
        relaunched.app.launchEnvironment["PUSHGO_QUALITY_SESSION_BASE64"] = encodedSession
        launch(relaunched.app)
        assertQualityRuntimeReady(in: relaunched.app, timeout: 15)
        XCTAssertTrue(relaunched.app.staticTexts["Recovered Quality Message"].waitForExistence(timeout: 8))
        relaunched.app.staticTexts["Recovered Quality Message"].tap()
        assertElementExists("sheet.message.detail", in: relaunched.app, timeout: 8)
        XCTAssertTrue(
            relaunched.app.staticTexts["Recovered from the original encrypted payload."].exists
        )
        assertElementExists("status.message.decryption.decryptOk", in: relaunched.app, timeout: 5)
    }

    func testCorruptEncryptedMessageFailsSafelyAndSurvivesRelaunch() {
        let sessionID = "ios-encrypted-corrupt-\(UUID().uuidString.lowercased())"
        let encodedSession = qualitySessionPayload(
            sessionID: sessionID,
            fixture: "messages.encrypted.corrupt"
        )
        let context = configuredLaunchContext()
        context.app.launchEnvironment["PUSHGO_QUALITY_SESSION_BASE64"] = encodedSession
        launch(context.app)
        assertQualityRuntimeReady(in: context.app, timeout: 15)

        XCTAssertTrue(context.app.staticTexts["Corrupt Encrypted Message"].waitForExistence(timeout: 8))
        context.app.staticTexts["Corrupt Encrypted Message"].tap()
        assertElementExists("status.message.decryption.notConfigured", in: context.app, timeout: 5)
        tapWhenHittable(
            element(in: context.app, identifier: "action.message.configure_decryption"),
            timeout: 8
        )
        let fieldIdentifier = ["field.settings.decryption", "key"].joined(separator: ".")
        let field = element(in: context.app, identifier: fieldIdentifier)
        XCTAssertTrue(field.waitForExistence(timeout: 8))
        enterSecureText(in: field, with: ["Quality", "Key", "123456"].joined())
        tapWhenHittable(
            element(in: context.app, identifier: "action.settings.decryption.save"),
            timeout: 8
        )
        XCTAssertTrue(field.waitForNonExistence(timeout: 8))
        tapWhenHittable(
            element(in: context.app, identifier: "action.settings.close"),
            timeout: 8
        )
        assertElementExists("status.message.decryption.decryptFailed", in: context.app, timeout: 5)
        XCTAssertTrue(context.app.staticTexts["Configure decryption to read this message."].exists)
        XCTAssertFalse(context.app.staticTexts["Recovered Quality Message"].exists)

        context.app.terminate()
        let relaunched = configuredLaunchContext()
        relaunched.app.launchEnvironment["PUSHGO_QUALITY_SESSION_BASE64"] = encodedSession
        launch(relaunched.app)
        assertQualityRuntimeReady(in: relaunched.app, timeout: 15)
        XCTAssertTrue(relaunched.app.staticTexts["Corrupt Encrypted Message"].waitForExistence(timeout: 8))
        relaunched.app.staticTexts["Corrupt Encrypted Message"].tap()
        assertElementExists("status.message.decryption.decryptFailed", in: relaunched.app, timeout: 5)
        XCTAssertTrue(relaunched.app.staticTexts["Configure decryption to read this message."].exists)
        XCTAssertFalse(relaunched.app.staticTexts["Recovered Quality Message"].exists)
    }

    func testEventClosePersistsAndOngoingFilterReflectsRealProjection() {
        let context = configuredLaunchContext()
        let sessionID = "ios-event-close-\(UUID().uuidString.lowercased())"
        context.app.launchEnvironment["PUSHGO_QUALITY_SESSION_BASE64"] = qualitySessionPayload(
            sessionID: sessionID,
            fixture: "event.standard",
            eventCloseScenario: "accepted_and_delivered"
        )
        launch(context.app)

        assertQualityRuntimeReady(in: context.app, timeout: 15)
        openEventsTab(in: context.app)
        let eventRow = element(in: context.app, identifier: "event.row.quality-event-active")
        XCTAssertTrue(eventRow.waitForExistence(timeout: 8))
        let offscreenEvent = element(
            in: context.app,
            identifier: "event.row.quality-event-navigation-08"
        )
        let eventList = runtimeQualityScrollableList(in: context.app)
        for _ in 0..<12 where !offscreenEvent.exists {
            eventList.swipeUp()
        }
        XCTAssertTrue(
            offscreenEvent.waitForExistence(timeout: 5),
            "The Event fixture must establish a real off-top position before testing reselection."
        )
        XCTAssertFalse(
            eventRow.exists,
            "The Events list must remain genuinely away from its newest object before the double-tap."
        )
        let collapsedEventsTab = context.app.tabBars.buttons.firstMatch
        XCTAssertTrue(collapsedEventsTab.waitForExistence(timeout: 5))
        XCTAssertTrue(collapsedEventsTab.isHittable)
        collapsedEventsTab.tap()
        let expandedEventsTab = context.app.tabBars.buttons.element(boundBy: 1)
        XCTAssertTrue(expandedEventsTab.waitForExistence(timeout: 5))
        expandedEventsTab.doubleTap()
        XCTAssertTrue(
            eventRow.waitForExistence(timeout: 5),
            "Double-tapping the current Events tab must return to the newest canonical Event."
        )
        XCTAssertFalse(
            offscreenEvent.exists,
            "The Events list must actually leave its off-top control position."
        )
        eventRow.tap()
        let detailSheet = element(in: context.app, identifier: "sheet.event.detail")
        XCTAssertTrue(detailSheet.waitForExistence(timeout: 10))
        XCTAssertTrue(context.app.staticTexts["P2 Event Active"].waitForExistence(timeout: 8))
        XCTAssertTrue(
            context.app.staticTexts["Event fixture for app-owned UI validation."]
                .waitForExistence(timeout: 5)
        )

        let closeAction = element(in: context.app, identifier: "action.event.close")
        XCTAssertTrue(closeAction.waitForExistence(timeout: 5))
        XCTAssertTrue(closeAction.isHittable)
        closeAction.tap()
        let cancel = context.app.alerts.buttons.element(boundBy: 0)
        XCTAssertTrue(cancel.waitForExistence(timeout: 5))
        cancel.tap()
        XCTAssertTrue(detailSheet.waitForExistence(timeout: 5))
        XCTAssertTrue(
            element(in: context.app, identifier: "field.event.detail.status.ongoing")
                .waitForExistence(timeout: 5),
            "Cancelling close must leave the canonical Event ongoing."
        )
        XCTAssertTrue(closeAction.waitForExistence(timeout: 5) && closeAction.isHittable)
        closeAction.tap()
        let confirm = context.app.alerts.buttons.element(boundBy: 1)
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()

        XCTAssertTrue(
            detailSheet.waitForNonExistence(timeout: 15),
            "Closing is complete only after the real async action succeeds and the detail dismisses"
        )
        let closedEventRow = element(
            in: context.app,
            identifier: "event.row.quality-event-active"
        )
        XCTAssertTrue(closedEventRow.waitForExistence(timeout: 10))
        let filters = context.app.buttons["action.events.filters"]
        tapWhenHittable(filters, timeout: 5, message: "Event filters must be an actionable control")
        let ongoingOnly = element(in: context.app, identifier: "filter.events.ongoing")
        XCTAssertTrue(ongoingOnly.waitForExistence(timeout: 5))
        ongoingOnly.tap()
        XCTAssertEqual(ongoingOnly.value as? String, "selected")
        context.app.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.75)).tap()
        let filteredEventRow = element(in: context.app, identifier: "event.row.quality-event-active")
        XCTAssertTrue(filteredEventRow.waitForNonExistence(timeout: 8))

        let thingsTab = element(in: context.app, identifier: "tab.things")
        tapWhenHittable(thingsTab, timeout: 8, message: "The linked Thing must remain reachable")
        let linkedThing = element(in: context.app, identifier: "thing.row.quality-thing-rich")
        tapWhenHittable(linkedThing, timeout: 8, message: "The exact linked Thing must open")
        let linkedEvent = element(
            in: context.app,
            identifier: "thing.related.event.quality-event-active"
        )
        XCTAssertTrue(linkedEvent.waitForExistence(timeout: 8))
        XCTAssertEqual(
            linkedEvent.value as? String,
            "closed",
            "The Thing consumer must converge to the same closed Event."
        )
        XCTAssertTrue(linkedEvent.label.contains("P2 Event Active"))

        context.app.terminate()
        context.app.launchEnvironment["PUSHGO_QUALITY_SESSION_BASE64"] = qualitySessionPayload(
            sessionID: sessionID,
            fixture: "event.standard",
            eventCloseScenario: "accepted_and_delivered"
        )
        launch(context.app)
        assertQualityRuntimeReady(in: context.app, timeout: 15)
        openEventsTab(in: context.app)
        let persistedRow = element(in: context.app, identifier: "event.row.quality-event-active")
        XCTAssertTrue(persistedRow.waitForExistence(timeout: 8))
        let persistedRowActionable = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND hittable == true"),
            object: persistedRow
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [persistedRowActionable], timeout: 8),
            .completed,
            "The persisted closed Event row must remain a real navigation target."
        )
        // Deliberately touch the visual center, which is blank for the short
        // closed-state copy. This proves the whole visible row is actionable,
        // rather than succeeding only when XCTest happens to target its text.
        persistedRow.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(
            element(in: context.app, identifier: "sheet.event.detail").waitForExistence(timeout: 8),
            "Opening the persisted closed Event must reach its real detail before status is asserted."
        )
        let persistedStatus = element(in: context.app, identifier: "field.event.detail.status.closed")
        XCTAssertTrue(persistedStatus.waitForExistence(timeout: 8))
        XCTAssertTrue(
            element(in: context.app, identifier: "event.timeline.count.2")
                .waitForExistence(timeout: 8)
        )
        XCTAssertFalse(
            element(in: context.app, identifier: "action.event.close")
                .waitForExistence(timeout: 2)
        )
    }

    func testEventCloseFailureKeepsAccurateDetailBlocksDuplicateAndRetryPersists() {
        let context = configuredLaunchContext()
        let sessionID = "ios-event-close-retry-\(UUID().uuidString.lowercased())"
        context.app.launchEnvironment["PUSHGO_QUALITY_SESSION_BASE64"] = qualitySessionPayload(
            sessionID: sessionID,
            fixture: "event.standard",
            eventCloseScenario: "fail_once_then_accepted_and_delivered"
        )
        launch(context.app)

        assertQualityRuntimeReady(in: context.app, timeout: 15)
        openEventsTab(in: context.app)
        let eventRow = element(in: context.app, identifier: "event.row.quality-event-active")
        XCTAssertTrue(eventRow.waitForExistence(timeout: 8))
        eventRow.tap()
        let detailSheet = element(in: context.app, identifier: "sheet.event.detail")
        XCTAssertTrue(detailSheet.waitForExistence(timeout: 10))
        XCTAssertTrue(
            context.app.staticTexts["Event fixture for app-owned UI validation."].waitForExistence(timeout: 5)
        )

        func confirmClose() {
            let closeAction = element(in: context.app, identifier: "action.event.close")
            XCTAssertTrue(closeAction.waitForExistence(timeout: 5) && closeAction.isHittable)
            closeAction.tap()
            let confirm = context.app.alerts.buttons.element(boundBy: 1)
            XCTAssertTrue(confirm.waitForExistence(timeout: 5))
            confirm.tap()
        }

        confirmClose()
        let closing = element(in: context.app, identifier: "state.event.close.in_progress")
        XCTAssertTrue(closing.waitForExistence(timeout: 2), "A slow close must expose visible progress.")
        XCTAssertFalse(
            closing.isEnabled,
            "A close already in flight must not allow a duplicate submission."
        )
        XCTAssertTrue(detailSheet.exists)
        XCTAssertTrue(context.app.staticTexts["P2 Event Active"].exists)
        XCTAssertTrue(
            element(in: context.app, identifier: "feedback.event.close").waitForExistence(timeout: 5),
            "The first boundary failure must remain owned by the Event detail."
        )
        XCTAssertTrue(detailSheet.exists, "A failed close must keep the actionable detail open.")
        XCTAssertTrue(
            element(in: context.app, identifier: "field.event.detail.status.ongoing").exists,
            "A failed close must not pretend the canonical Event is closed."
        )

        confirmClose()
        XCTAssertTrue(closing.waitForExistence(timeout: 2))
        XCTAssertFalse(closing.isEnabled)
        XCTAssertTrue(
            detailSheet.waitForNonExistence(timeout: 12),
            "Retry succeeds only after the production-shaped delivery updates the canonical projection."
        )

        context.app.terminate()
        context.app.launchEnvironment["PUSHGO_QUALITY_SESSION_BASE64"] = qualitySessionPayload(
            sessionID: sessionID,
            fixture: "event.standard",
            eventCloseScenario: "fail_once_then_accepted_and_delivered"
        )
        launch(context.app)
        assertQualityRuntimeReady(in: context.app, timeout: 15)
        openEventsTab(in: context.app)
        let persistedRow = element(in: context.app, identifier: "event.row.quality-event-active")
        XCTAssertTrue(persistedRow.waitForExistence(timeout: 8))
        XCTAssertTrue(
            persistedRow.label.localizedCaseInsensitiveContains("closed"),
            "Relaunch must render the canonical Event as closed in the user-visible list."
        )
    }

    func testThingLifecycleFiltersRelationsAndUnavailableTargetFallback() {
        let context = configuredLaunchContext(
            launchArguments: ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        )
        let encodedSession = qualitySessionPayload(
            sessionID: "ios-thing-\(UUID().uuidString.lowercased())",
            fixture: "thing.standard"
        )
        context.app.launchEnvironment["PUSHGO_QUALITY_SESSION_BASE64"] = encodedSession
        launch(context.app)

        assertQualityRuntimeReady(in: context.app, timeout: 15)
        let thingsTab = element(in: context.app, identifier: "tab.things")
        XCTAssertTrue(thingsTab.waitForExistence(timeout: 8))
        thingsTab.tap()
        let thingRow = element(in: context.app, identifier: "thing.row.quality-thing-rich")
        let distractorRow = element(
            in: context.app,
            identifier: "thing.row.quality-thing-distractor"
        )
        XCTAssertTrue(thingRow.waitForExistence(timeout: 8))
        XCTAssertTrue(distractorRow.waitForExistence(timeout: 8))
        let crossChannelControl = element(
            in: context.app,
            identifier: "thing.row.quality-thing-navigation-15"
        )
        XCTAssertTrue(
            crossChannelControl.waitForExistence(timeout: 8),
            "The fixture must expose an other-channel Thing sharing the target tag."
        )

        let filters = element(in: context.app, identifier: "action.things.filters")
        tapWhenHittable(filters, timeout: 5, message: "Thing filters must be actionable")
        let qualityChannel = element(
            in: context.app,
            identifier: "filter.things.channel.quality"
        )
        tapWhenHittable(qualityChannel, timeout: 5)
        let sharedTag = element(
            in: context.app,
            identifier: "filter.things.tag.filter-shared"
        )
        tapWhenHittable(sharedTag, timeout: 5)
        context.app.swipeDown()
        XCTAssertTrue(
            sharedTag.waitForNonExistence(timeout: 5),
            "The production Thing filter popover did not dismiss after the platform gesture."
        )
        XCTAssertTrue(
            thingRow.waitForExistence(timeout: 8),
            "Channel AND tag filters must retain the unique accurate Thing."
        )
        XCTAssertTrue(
            distractorRow.waitForNonExistence(timeout: 5),
            "The same-channel Thing with a different tag must not survive the combined filter."
        )
        XCTAssertTrue(
            crossChannelControl.waitForNonExistence(timeout: 5),
            "The same-tag Thing from a different channel must not survive the combined filter."
        )

        tapWhenHittable(filters, timeout: 5, message: "Thing filters must reopen for clearing")
        tapWhenHittable(
            element(in: context.app, identifier: "filter.things.channel.all"),
            timeout: 5
        )
        tapWhenHittable(
            element(in: context.app, identifier: "filter.things.tag.filter-shared"),
            timeout: 5
        )
        context.app.swipeDown()
        XCTAssertTrue(
            element(in: context.app, identifier: "filter.things.tag.filter-shared")
                .waitForNonExistence(timeout: 5),
            "Clearing must dismiss through the same production filter surface."
        )
        XCTAssertTrue(
            thingRow.waitForExistence(timeout: 8),
            "Clearing the combined filter must retain the accurate target."
        )
        XCTAssertTrue(
            distractorRow.waitForExistence(timeout: 8),
            "Clearing must restore the same-channel control Thing."
        )
        XCTAssertTrue(
            crossChannelControl.waitForExistence(timeout: 8),
            "Clearing must restore the other-channel control Thing."
        )
        let offscreenThing = element(
            in: context.app,
            identifier: "thing.row.quality-thing-navigation-08"
        )
        let thingList = runtimeQualityScrollableList(in: context.app)
        for _ in 0..<12 where !offscreenThing.exists {
            thingList.swipeUp()
        }
        XCTAssertTrue(
            offscreenThing.waitForExistence(timeout: 5),
            "The Thing fixture must establish a real off-top position before testing reselection."
        )
        XCTAssertFalse(
            thingRow.exists,
            "The Things list must remain genuinely away from its newest object before the double-tap."
        )
        let collapsedThingsTab = context.app.tabBars.buttons.firstMatch
        XCTAssertTrue(collapsedThingsTab.waitForExistence(timeout: 5))
        XCTAssertTrue(collapsedThingsTab.isHittable)
        collapsedThingsTab.tap()
        let expandedThingsTab = element(in: context.app, identifier: "tab.things")
        XCTAssertTrue(expandedThingsTab.waitForExistence(timeout: 5))
        expandedThingsTab.doubleTap()
        XCTAssertTrue(
            thingRow.waitForExistence(timeout: 5),
            "Double-tapping the current Things tab must return to the newest canonical Thing."
        )
        XCTAssertFalse(
            offscreenThing.exists,
            "The Things list must actually leave its off-top control position."
        )
        tapWhenHittable(
            distractorRow,
            timeout: 8,
            message: "The distractor Thing must open before deletion"
        )
        assertElementExists("sheet.thing.detail", in: context.app, timeout: 8)
        tapWhenHittable(
            element(in: context.app, identifier: "action.thing.delete"),
            timeout: 8,
            message: "The real Thing detail delete action must be reachable"
        )
        XCTAssertTrue(
            distractorRow.waitForNonExistence(timeout: 8),
            "Deleting one Thing must immediately remove only that target from the user-visible list."
        )
        XCTAssertTrue(thingRow.waitForExistence(timeout: 8))
        assertElementExists("state.pending_deletion", in: context.app, timeout: 5)
        let searchField = runtimeQualitySearchField(in: context.app)
        XCTAssertTrue(searchField.waitForExistence(timeout: 8))
        searchField.tap()
        searchField.typeText("thing-rich")
        XCTAssertTrue(thingRow.waitForExistence(timeout: 5))
        XCTAssertTrue(
            distractorRow.waitForNonExistence(timeout: 5),
            "Thing search must keep the exact target while excluding a real distractor."
        )
        let thingRowActionable = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND hittable == true"),
            object: thingRow
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [thingRowActionable], timeout: 8),
            .completed,
            "The Thing row must expose its full visible width as one navigation target."
        )
        thingRow.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(
            element(in: context.app, identifier: "sheet.thing.detail")
                .waitForExistence(timeout: 10)
        )
        XCTAssertTrue(context.app.staticTexts["P2 Thing Rich"].waitForExistence(timeout: 8))
        XCTAssertTrue(context.app.staticTexts["Fixture thing summary"].waitForExistence(timeout: 5))

        let messagesTab = element(in: context.app, identifier: "tab.thing.detail.messages")
        tapWhenHittable(messagesTab, timeout: 8, message: "Thing Messages tab must be actionable")
        let relatedMessage = element(
            in: context.app,
            identifier: "thing.related.message.quality-related-message"
        )
        tapWhenHittable(relatedMessage, timeout: 8, message: "Related Message must open")
        assertElementExists("screen.message.detail", in: context.app, timeout: 8)
        XCTAssertTrue(context.app.staticTexts["Quality Related Message"].waitForExistence(timeout: 8))
        XCTAssertTrue(
            context.app.staticTexts["The linked Thing message opens its canonical detail."]
                .waitForExistence(timeout: 8)
        )
        tapWhenHittable(
            element(in: context.app, identifier: "action.message.close"),
            timeout: 8,
            message: "Related Message detail must return to the Thing"
        )
        XCTAssertTrue(
            element(in: context.app, identifier: "thing.related.message.quality-related-message")
                .waitForExistence(timeout: 8),
            "Returning from Message detail must preserve the same Thing Messages tab"
        )

        let updatesTab = element(in: context.app, identifier: "tab.thing.detail.updates")
        tapWhenHittable(updatesTab, timeout: 8, message: "Thing Updates tab must be actionable")
        let relatedUpdate = element(
            in: context.app,
            identifier: "thing.related.update.00000000-0000-0000-0000-00000000a000"
        )
        tapWhenHittable(relatedUpdate, timeout: 8, message: "Related Update must open")
        assertElementExists("screen.thing.update.detail", in: context.app, timeout: 8)
        XCTAssertTrue(
            context.app.staticTexts["Quality Initial Thing Snapshot"].waitForExistence(timeout: 8)
        )
        tapWhenHittable(
            element(in: context.app, identifier: "action.thing.update.close"),
            timeout: 8,
            message: "Related Update detail must return to the Thing"
        )
        XCTAssertTrue(
            element(
                in: context.app,
                identifier: "thing.related.update.00000000-0000-0000-0000-00000000a000"
            ).waitForExistence(timeout: 8),
            "Returning from Update detail must preserve the same Thing Updates tab"
        )

        let unavailableTarget = configuredLaunchContext(
            runtimeRoot: context.runtimeRoot,
            requestName: "entity.open",
            args: [
                "entity_type": "thing",
                "entity_id": "quality-thing-distractor",
            ],
            launchArguments: ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        )
        unavailableTarget.app.launchEnvironment["PUSHGO_QUALITY_SESSION_BASE64"] = encodedSession
        launch(unavailableTarget.app)
        assertQualityRuntimeReady(in: unavailableTarget.app, timeout: 15)
        assertElementExists("screen.things.list", in: unavailableTarget.app, timeout: 8)
        XCTAssertTrue(
            element(in: unavailableTarget.app, identifier: "thing.row.quality-thing-distractor")
                .waitForNonExistence(timeout: 8),
            "The deleted Thing must not return after the pending deletion commits and the App relaunches."
        )
        let unavailableFeedback = element(
            in: unavailableTarget.app,
            identifier: "feedback.entity.target_unavailable"
        )
        XCTAssertTrue(
            unavailableFeedback.waitForExistence(timeout: 5),
            "Opening a deleted Thing must visibly explain the fallback instead of leaving a pending target."
        )
        XCTAssertTrue(
            unavailableFeedback.label.contains("The requested item was not found or has expired."),
            "The fallback must explain that the exact target is unavailable."
        )
        let survivingThing = element(
            in: unavailableTarget.app,
            identifier: "thing.row.quality-thing-rich"
        )
        XCTAssertTrue(
            survivingThing.waitForExistence(timeout: 5),
            "After the deleted-target fallback, the canonical Things list must remain usable."
        )
        tapWhenHittable(survivingThing, timeout: 8, message: "The same Thing must survive relaunch")
        let relatedEvent = element(
            in: unavailableTarget.app,
            identifier: "thing.related.event.quality-related-event"
        )
        tapWhenHittable(relatedEvent, timeout: 8, message: "Related Event must open")
        assertElementExists("screen.events.detail", in: unavailableTarget.app, timeout: 8)
        XCTAssertTrue(unavailableTarget.app.staticTexts["Quality Related Event"].waitForExistence(timeout: 8))
    }

    func testChannelCreateRenameAndBothUnsubscribeOutcomesPersist() {
        let context = configuredLaunchContext(
            launchArguments: ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"],
            allowCrossAppDataAccess: true
        )
        let encodedSession = qualitySessionPayload(
            sessionID: "ios-channels-\(UUID().uuidString.lowercased())",
            fixture: "channels.standard",
            channelMutationScenario: "rename_reject_once_then_accepted"
        )
        context.app.launchEnvironment["PUSHGO_QUALITY_SESSION_BASE64"] = encodedSession
        launch(context.app)
        assertQualityRuntimeReady(in: context.app, timeout: 15)

        tapWhenHittable(
            channelsTab(in: context.app),
            timeout: 8,
            message: "Channels must be reachable"
        )
        let keepActivity = element(
            in: context.app,
            identifier: "channel.stats.01H00000000000000000000001"
        )
        XCTAssertTrue(keepActivity.waitForExistence(timeout: 8))
        XCTAssertTrue(keepActivity.label.contains("1 messages"))
        XCTAssertTrue(keepActivity.label.contains("1 unread"))
        let keepLatestDate = ISO8601DateFormatter().date(from: "2026-01-15T08:01:00Z")!
        let keepLatestText = keepLatestDate.formatted(
            Date.FormatStyle(date: .abbreviated, time: .shortened)
                .locale(Locale(identifier: "en_US"))
        )
        XCTAssertTrue(
            keepActivity.label.contains(keepLatestText),
            "The Channel row must expose the latest canonical message time, not only its subscription."
        )
        let subscribedChannelID = "01H00000000000000000000004"
        tapWhenHittable(
            element(in: context.app, identifier: "action.channels.add"),
            timeout: 8,
            message: "Add Channel must be actionable"
        )
        let entryMode = element(in: context.app, identifier: "select.channels.entry.mode")
        XCTAssertTrue(entryMode.waitForExistence(timeout: 8))
        tapWhenHittable(entryMode.buttons["Subscribe Channel"], timeout: 5)
        replaceText(
            in: element(in: context.app, identifier: "field.channels.subscribe.id"),
            with: subscribedChannelID
        )
        enterSecureText(
            in: element(in: context.app, identifier: "field.channels.subscribe.password"),
            with: "qualityx"
        )
        tapWhenHittable(
            element(in: context.app, identifier: "action.channels.entry.submit"),
            timeout: 8,
            message: "Subscribe Channel must submit through the real form"
        )
        XCTAssertTrue(
            element(in: context.app, identifier: "channel.row.\(subscribedChannelID)")
                .waitForExistence(timeout: 8),
            "An accepted existing-channel subscription must enter the canonical Channel list"
        )

        tapWhenHittable(
            element(in: context.app, identifier: "action.channels.add"),
            timeout: 8,
            message: "Add Channel must remain usable after subscribing"
        )
        let createName = element(in: context.app, identifier: "field.channels.create.name")
        let createCredential = element(in: context.app, identifier: "field.channels.create.password")
        XCTAssertTrue(createName.waitForExistence(timeout: 8))
        replaceText(in: createName, with: "Quality Created Channel")
        enterSecureText(in: createCredential, with: "qualityx")
        let credentialLength = element(
            in: context.app,
            identifier: "quality.channels.create.credential_length"
        )
        XCTAssertTrue(credentialLength.waitForExistence(timeout: 3))
        XCTAssertEqual(credentialLength.value as? String, "8")
        tapWhenHittable(
            element(in: context.app, identifier: "action.channels.entry.submit"),
            timeout: 8,
            message: "Create Channel must submit through the real form"
        )

        var createdRow = element(
            in: context.app,
            identifier: "channel.row.01H00000000000000000000003"
        )
        XCTAssertTrue(createdRow.waitForExistence(timeout: 8))
        XCTAssertTrue(context.app.staticTexts["Quality Created Channel"].waitForExistence(timeout: 8))

        createdRow.swipeLeft()
        tapWhenHittable(
            element(
                in: context.app,
                identifier: "action.channel.01H00000000000000000000003.rename"
            ),
            timeout: 5
        )
        var renameField = element(in: context.app, identifier: "field.channel.rename.alias")
        XCTAssertTrue(renameField.waitForExistence(timeout: 5))
        replaceText(in: renameField, with: "Cancelled Rename")
        tapWhenHittable(
            element(in: context.app, identifier: "action.channel.rename.cancel"),
            timeout: 5
        )
        XCTAssertTrue(context.app.staticTexts["Quality Created Channel"].waitForExistence(timeout: 5))

        createdRow.swipeLeft()
        tapWhenHittable(
            element(
                in: context.app,
                identifier: "action.channel.01H00000000000000000000003.rename"
            ),
            timeout: 5,
            message: "Created Channel must expose Rename"
        )
        renameField = element(in: context.app, identifier: "field.channel.rename.alias")
        XCTAssertTrue(renameField.waitForExistence(timeout: 5))
        replaceText(in: renameField, with: String(repeating: "x", count: 129))
        tapWhenHittable(
            element(in: context.app, identifier: "action.channel.rename.save"),
            timeout: 5
        )
        XCTAssertTrue(
            context.app.staticTexts["Channel name is too long (max 128)."].waitForExistence(timeout: 8),
            "Invalid rename feedback must remain owned by the rename alert."
        )
        XCTAssertTrue(context.app.staticTexts["Quality Created Channel"].exists)

        replaceText(in: renameField, with: "Quality Renamed Channel")
        let renameButton = element(in: context.app, identifier: "action.channel.rename.save")
        XCTAssertTrue(renameButton.waitForExistence(timeout: 5))
        XCTAssertTrue(renameButton.isEnabled, "Rename confirmation must be enabled")
        renameButton.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(
            context.app.staticTexts["The channel rename was rejected. Check the name and retry."]
                .waitForExistence(timeout: 8),
            "Remote rejection must reopen the owning rename alert."
        )
        XCTAssertEqual(renameField.value as? String, "Quality Renamed Channel")
        XCTAssertTrue(context.app.staticTexts["Quality Created Channel"].exists)
        tapWhenHittable(
            element(in: context.app, identifier: "action.channel.rename.save"),
            timeout: 5
        )
        XCTAssertTrue(context.app.staticTexts["Quality Renamed Channel"].waitForExistence(timeout: 8))

        context.app.terminate()
        context.app.launchEnvironment["PUSHGO_QUALITY_SESSION_BASE64"] = encodedSession
        launch(context.app)
        assertQualityRuntimeReady(in: context.app, timeout: 15)
        tapWhenHittable(channelsTab(in: context.app), timeout: 8)
        XCTAssertTrue(context.app.staticTexts["Quality Renamed Channel"].waitForExistence(timeout: 8))
        XCTAssertTrue(
            element(in: context.app, identifier: "channel.row.\(subscribedChannelID)")
                .waitForExistence(timeout: 8),
            "The existing-channel subscription must survive process relaunch"
        )

        let keepRow = element(
            in: context.app,
            identifier: "channel.row.01H00000000000000000000001"
        )
        XCTAssertTrue(keepRow.waitForExistence(timeout: 8))
        keepRow.swipeLeft()
        tapWhenHittable(
            element(
                in: context.app,
                identifier: "action.channel.01H00000000000000000000001.unsubscribe"
            ),
            timeout: 5
        )
        tapWhenHittable(
            context.app.buttons["Unsubscribe and keep history"].firstMatch,
            timeout: 5
        )
        XCTAssertTrue(keepRow.waitForNonExistence(timeout: 8))
        tapWhenHittable(element(in: context.app, identifier: "tab.messages"), timeout: 8)
        XCTAssertTrue(context.app.staticTexts["Quality Keep History Message"].waitForExistence(timeout: 8))

        context.app.terminate()
        context.app.launchEnvironment["PUSHGO_QUALITY_SESSION_BASE64"] = encodedSession
        launch(context.app)
        assertQualityRuntimeReady(in: context.app, timeout: 15)
        tapWhenHittable(channelsTab(in: context.app), timeout: 8)
        XCTAssertFalse(keepRow.exists)
        tapWhenHittable(element(in: context.app, identifier: "tab.messages"), timeout: 8)
        XCTAssertTrue(context.app.staticTexts["Quality Keep History Message"].waitForExistence(timeout: 8))

        tapWhenHittable(channelsTab(in: context.app), timeout: 8)
        let deleteRow = element(
            in: context.app,
            identifier: "channel.row.01H00000000000000000000002"
        )
        XCTAssertTrue(deleteRow.waitForExistence(timeout: 8))
        deleteRow.swipeLeft()
        tapWhenHittable(
            element(
                in: context.app,
                identifier: "action.channel.01H00000000000000000000002.unsubscribe"
            ),
            timeout: 5
        )
        tapWhenHittable(
            context.app.buttons["Unsubscribe and delete history"].firstMatch,
            timeout: 5
        )
        XCTAssertTrue(deleteRow.waitForNonExistence(timeout: 8))
        let pendingDeletion = element(in: context.app, identifier: "state.pending_deletion")
        XCTAssertTrue(pendingDeletion.waitForExistence(timeout: 5))
        XCTAssertTrue(pendingDeletion.waitForNonExistence(timeout: 15))

        tapWhenHittable(element(in: context.app, identifier: "tab.messages"), timeout: 8)
        XCTAssertTrue(context.app.staticTexts["Quality Keep History Message"].waitForExistence(timeout: 8))
        XCTAssertFalse(context.app.staticTexts["Quality Delete History Message"].exists)

        context.app.terminate()
        context.app.launchEnvironment["PUSHGO_QUALITY_SESSION_BASE64"] = encodedSession
        launch(context.app)
        assertQualityRuntimeReady(in: context.app, timeout: 15)
        tapWhenHittable(channelsTab(in: context.app), timeout: 8)
        let copiedChannelID = "01H00000000000000000000003"
        createdRow = element(
            in: context.app,
            identifier: "channel.row.\(copiedChannelID)"
        )
        XCTAssertTrue(createdRow.waitForExistence(timeout: 8))
        XCTAssertFalse(deleteRow.exists)
        tapWhenHittable(
            createdRow,
            timeout: 8,
            message: "The canonical Channel row must remain a real copy action after relaunch"
        )
        tapWhenHittable(element(in: context.app, identifier: "tab.messages"), timeout: 8)
        XCTAssertTrue(context.app.staticTexts["Quality Keep History Message"].waitForExistence(timeout: 8))
        XCTAssertFalse(context.app.staticTexts["Quality Delete History Message"].exists)
    }

    func testChannelRemoteRejectionStaysInSheetAndRetryPersists() {
        assertChannelCreateFailureThenRetry(
            sessionPrefix: "ios-channel-rejected",
            scenario: "reject_once_then_accepted",
            failLocalPersistenceOnce: false,
            expectedFailureText: "Channel password is incorrect"
        )
    }

    func testChannelCreateLocalFailureCompensatesRemoteBeforeRetry() {
        assertChannelCreateFailureThenRetry(
            sessionPrefix: "ios-channel-compensation",
            scenario: "require_create_compensation",
            failLocalPersistenceOnce: true,
            expectedFailureText: nil
        )
    }

    func testExistingChannelLocalFailureDoesNotCompensateBeforeRetry() {
        assertChannelCreateFailureThenRetry(
            sessionPrefix: "ios-existing-channel",
            scenario: "existing_subscribe_must_not_compensate",
            failLocalPersistenceOnce: true,
            expectedFailureText: nil,
            existingChannelID: "01H00000000000000000000004"
        )
    }

    private func assertChannelCreateFailureThenRetry(
        sessionPrefix: String,
        scenario: String,
        failLocalPersistenceOnce: Bool,
        expectedFailureText: String?,
        existingChannelID: String? = nil
    ) {
        let context = configuredLaunchContext(
            launchArguments: ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        )
        let encodedSession = qualitySessionPayload(
            sessionID: "\(sessionPrefix)-\(UUID().uuidString.lowercased())",
            fixture: "channels.standard",
            failChannelSubscriptionPersistenceOnce: failLocalPersistenceOnce,
            channelMutationScenario: scenario
        )
        context.app.launchEnvironment["PUSHGO_QUALITY_SESSION_BASE64"] = encodedSession
        launch(context.app)
        assertQualityRuntimeReady(in: context.app, timeout: 15)
        tapWhenHittable(channelsTab(in: context.app), timeout: 8)
        tapWhenHittable(element(in: context.app, identifier: "action.channels.add"), timeout: 8)

        let isExistingSubscription = existingChannelID != nil
        if isExistingSubscription {
            tapWhenHittable(element(in: context.app, identifier: "mode.channels.entry.subscribe"), timeout: 5)
        }
        let identifierInput = element(
            in: context.app,
            identifier: isExistingSubscription
                ? "field.channels.subscribe.id"
                : "field.channels.create.name"
        )
        let passwordInput = element(
            in: context.app,
            identifier: isExistingSubscription
                ? "field.channels.subscribe.password"
                : "field.channels.create.password"
        )
        let expectedChannelID = existingChannelID ?? "01H00000000000000000000003"
        replaceText(in: identifierInput, with: existingChannelID ?? "Quality Retry Channel")
        enterSecureText(in: passwordInput, with: String(repeating: "q", count: 8))
        tapWhenHittable(element(in: context.app, identifier: "action.channels.entry.submit"), timeout: 8)

        let sheetFeedback = element(in: context.app, identifier: "feedback.channels.entry")
        XCTAssertTrue(sheetFeedback.waitForExistence(timeout: 8), "Failure must remain owned by the Channel sheet")
        XCTAssertTrue(element(in: context.app, identifier: "sheet.channels.entry").exists)
        XCTAssertEqual(identifierInput.value as? String, existingChannelID ?? "Quality Retry Channel")
        XCTAssertTrue(element(in: context.app, identifier: "action.channels.entry.submit").isEnabled)
        XCTAssertFalse(element(in: context.app, identifier: "feedback.channels.entry-sync").exists)
        XCTAssertFalse(element(in: context.app, identifier: "channel.row.\(expectedChannelID)").exists)
        if let expectedFailureText {
            XCTAssertTrue(sheetFeedback.label.contains(expectedFailureText))
        }

        tapWhenHittable(element(in: context.app, identifier: "action.channels.entry.cancel"), timeout: 5)
        XCTAssertFalse(
            element(in: context.app, identifier: "feedback.channels.entry-sync").exists,
            "Closing the Channel sheet must not replay its business error on the host page"
        )
        tapWhenHittable(element(in: context.app, identifier: "tab.messages"), timeout: 8)
        tapWhenHittable(channelsTab(in: context.app), timeout: 8)
        XCTAssertFalse(
            element(in: context.app, identifier: "channel.row.\(expectedChannelID)").exists,
            "Reloading Channels after the failed commit must not reveal a partially persisted row"
        )
        tapWhenHittable(element(in: context.app, identifier: "action.channels.add"), timeout: 8)
        if isExistingSubscription {
            tapWhenHittable(element(in: context.app, identifier: "mode.channels.entry.subscribe"), timeout: 5)
        }
        replaceText(
            in: element(
                in: context.app,
                identifier: isExistingSubscription ? "field.channels.subscribe.id" : "field.channels.create.name"
            ),
            with: existingChannelID ?? "Quality Retry Channel"
        )
        enterSecureText(
            in: element(
                in: context.app,
                identifier: isExistingSubscription ? "field.channels.subscribe.password" : "field.channels.create.password"
            ),
            with: String(repeating: "q", count: 8)
        )
        tapWhenHittable(element(in: context.app, identifier: "action.channels.entry.submit"), timeout: 8)
        let createdRow = element(in: context.app, identifier: "channel.row.\(expectedChannelID)")
        XCTAssertTrue(
            createdRow.waitForExistence(timeout: 8),
            "Retry must succeed after a rejected, compensated, or preserved existing remote subscription"
        )

        context.app.terminate()
        launch(context.app)
        assertQualityRuntimeReady(in: context.app, timeout: 15)
        tapWhenHittable(channelsTab(in: context.app), timeout: 8)
        XCTAssertTrue(
            element(in: context.app, identifier: "channel.row.\(expectedChannelID)")
                .waitForExistence(timeout: 8),
            "The accepted retry must survive a real app relaunch"
        )
    }

    func legacyDiagnosticPushSettingsCanOpenDecryptionScreen() {
        let context = configuredLaunchContext(
            requestName: "settings.open_decryption"
        )
        launch(context.app)

        assertVisibleScreen("screen.settings.decryption", in: context, timeout: 15)
        XCTAssertNotNil(waitForAutomationResponse(at: context.responseURL, timeout: 12, matching: { $0.ok }))
    }

    func legacyDiagnosticInvalidServerAddressShowsInlineFeedbackInsteadOfToast() {
        let context = configuredLaunchContext(
            requestName: "nav.switch_tab",
            args: ["tab": "settings"]
        )
        launch(context.app)

        assertVisibleScreen("screen.settings", in: context, timeout: 15)
        element(in: context.app, identifier: "action.settings.server_management").tap()

        let addressField = element(in: context.app, identifier: "field.settings.server.address")
        XCTAssertTrue(addressField.waitForExistence(timeout: 8))
        replaceText(in: addressField, with: "not a valid url")
        element(in: context.app, identifier: "action.settings.server.save").tap()

        XCTAssertTrue(
            element(in: context.app, identifier: "feedback.settings.server").waitForExistence(timeout: 5),
            "Server validation errors should stay inline in the sheet."
        )
        XCTAssertFalse(
            element(in: context.app, identifier: "feedback.toast.error").waitForExistence(timeout: 1),
            "Server validation errors must not be routed to the global toast overlay."
        )
    }

    func legacyDiagnosticFixtureSeedMessagesRefreshesMessageList() {
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

    func legacyDiagnosticSubmittingPopulatedSearchResultsKeepsAppRunning() {
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

        let searchField = runtimeQualitySearchField(in: context.app)
        XCTAssertTrue(searchField.waitForExistence(timeout: 10))
        searchField.tap()
        let query = "P2 Split"
        searchField.typeText(query)
        XCTAssertNotNil(
            waitForAutomationEvent(
                at: context.eventsURL,
                timeout: 12,
                matching: { event in
                    guard (event["type"] as? String) == "search.results_updated",
                          let details = event["details"] as? [String: Any],
                          (details["search_query"] as? String) == query,
                          let rawCount = details["result_count"] as? String,
                          let resultCount = Int(rawCount)
                    else { return false }
                    return resultCount > 0
                }
            )
        )

        searchField.typeText(XCUIKeyboardKey.return.rawValue)

        XCTAssertTrue(context.app.wait(for: .runningForeground, timeout: 3))
        XCTAssertTrue(
            context.app.staticTexts["P2 Split Seed Message"].waitForExistence(timeout: 3),
            "Submitting an already populated search must preserve the results and keep the app alive."
        )
    }

    func legacyDiagnosticFixtureSeedEntityRecordsPublishesProjectionCounts() {
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

    func legacyDiagnosticFixtureSeedSubscriptionsPublishesImportState() {
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

    func legacyDiagnosticEntityOpenPublishesEntityStateAndProjectionCounts() {
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

    func legacyDiagnosticMessageOpenPublishesMessageDetailState() {
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

    func legacyDiagnosticNotificationOpenPublishesMessageDetailState() {
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

    func legacyDiagnosticNotificationMarkReadCommandUpdatesUnreadState() {
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

    func legacyDiagnosticNotificationDeleteCommandUpdatesCounts() {
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

    func legacyDiagnosticGatewaySetServerCommandUpdatesConfigurationState() {
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

    func legacyDiagnosticBaselineAutomationStateHasNoRuntimeErrors() {
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

    func legacyDiagnosticWatchResyncReceiverCommandPublishesReceiverState() {
        let context = configuredLaunchContext(
            requestName: "watch.resync_receiver"
        )
        launch(context.app)

        XCTAssertNotNil(
            waitForAutomationState(
                at: context.stateURL,
                timeout: 12,
                matching: { $0.watchReceiverState != nil && $0.watchReceiverState != "mirror" && $0.watchReceiverState != "standalone" }
            )
        )
    }

    func legacyDiagnosticSettingsSetDecryptionKeyRejectsInvalidLength() {
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

    func legacyDiagnosticSettingsSetDecryptionKeyAcceptsBase64Key() {
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

    func legacyDiagnosticRuntimeQualityLargeFixtureLaunchAndListReadiness() throws {
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

    func legacyDiagnosticRuntimeQualityReservedMarkdownFixturesStayBelowGatewayBodyLimit() {
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

    func legacyDiagnosticCaptureLocalizedPrimaryScreens() throws {
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

    func configuredLaunchContext(
        runtimeRoot: URL? = nil,
        startupFixturePath: String? = nil,
        requestName: String? = nil,
        args: [String: String] = [:],
        launchArguments: [String] = [],
        allowCrossAppDataAccess: Bool = false
    ) -> LaunchContext {
        let app = XCUIApplication()
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
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
        app.launchEnvironment["PUSHGO_AUTOMATION_ALLOW_CROSS_APP_DATA_ACCESS"] = allowCrossAppDataAccess ? "1" : "0"
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

    func qualitySessionPayload(
        sessionID: String,
        fixture: String,
        failLocalStoreInitialization: Bool = false,
        localStoreFailureStreakThreshold: Int? = nil,
        messageLoadDelayMilliseconds: Int? = nil,
        messagePageLoadDelayMilliseconds: Int? = nil,
        messageRefreshDelayMilliseconds: Int? = nil,
        messageSearchDelayMilliseconds: Int? = nil,
        failMessageSearchOnce: Bool = false,
        legacyStore: String? = nil,
        failMessageLoad: Bool = false,
        failMessagePageLoadOnce: Bool = false,
        failGatewaySwitchValidationOnce: Bool = false,
        failGatewaySwitchCommitOnce: Bool = false,
        failGatewayPostCommitSyncOnce: Bool = false,
        failNotificationMaterialPersistenceOnce: Bool = false,
        failChannelSubscriptionPersistenceOnce: Bool = false,
        messageRefreshScenario: String? = nil,
        eventCloseScenario: String? = nil,
        channelMutationScenario: String? = nil,
        expectedChannelMutationGatewayURL: String? = nil
    ) -> String {
        var faults: [String: Any] = [
            "fail_local_store_initialization": failLocalStoreInitialization,
            "fail_message_load": failMessageLoad,
            "fail_message_page_load_once": failMessagePageLoadOnce,
            "fail_message_search_once": failMessageSearchOnce,
            "fail_gateway_switch_validation_once": failGatewaySwitchValidationOnce,
            "fail_gateway_switch_commit_once": failGatewaySwitchCommitOnce,
            "fail_gateway_post_commit_sync_once": failGatewayPostCommitSyncOnce,
            "fail_notification_material_persistence_once": failNotificationMaterialPersistenceOnce,
            "fail_channel_subscription_persistence_once": failChannelSubscriptionPersistenceOnce,
        ]
        if let messageLoadDelayMilliseconds {
            faults["message_load_delay_ms"] = messageLoadDelayMilliseconds
        }
        if let messagePageLoadDelayMilliseconds {
            faults["message_page_load_delay_ms"] = messagePageLoadDelayMilliseconds
        }
        if let localStoreFailureStreakThreshold {
            faults["local_store_failure_streak_threshold"] = localStoreFailureStreakThreshold
        }
        if let messageRefreshDelayMilliseconds {
            faults["message_refresh_delay_ms"] = messageRefreshDelayMilliseconds
        }
        if let messageSearchDelayMilliseconds {
            faults["message_search_delay_ms"] = messageSearchDelayMilliseconds
        }
        let payload: [String: Any] = [
            "schema_version": 1,
            "session_id": sessionID,
            "fixture": fixture,
            "faults": faults,
        ]
            .merging(legacyStore.map { ["legacy_store": $0] } ?? [:]) { _, new in new }
            .merging(messageRefreshScenario.map { ["message_refresh_scenario": $0] } ?? [:]) { _, new in new }
            .merging(eventCloseScenario.map { ["event_close_scenario": $0] } ?? [:]) { _, new in new }
            .merging(channelMutationScenario.map { ["channel_mutation_scenario": $0] } ?? [:]) { _, new in new }
            .merging(expectedChannelMutationGatewayURL.map { ["expected_channel_mutation_gateway_url": $0] } ?? [:]) { _, new in new }
        let data = try! JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        return data.base64EncodedString()
    }

    func launch(_ app: XCUIApplication, qualityHandshakeTimeout: TimeInterval = 15) {
        let qualitySessionKey = "PUSHGO_QUALITY_SESSION_BASE64"
        let qualitySessionArgument = "-\(qualitySessionKey)"
        var launchArguments = app.launchArguments
        while let index = launchArguments.firstIndex(of: qualitySessionArgument) {
            launchArguments.remove(at: index)
            if launchArguments.indices.contains(index) {
                launchArguments.remove(at: index)
            }
        }
        if let encodedSession = app.launchEnvironment[qualitySessionKey], !encodedSession.isEmpty {
            launchArguments.append(contentsOf: [qualitySessionArgument, encodedSession])
        }
        app.launchArguments = launchArguments
        let requiresQualityHandshake = app.launchEnvironment[qualitySessionKey]?.isEmpty == false

        if app.state != .notRunning {
            app.terminate()
            XCTAssertEqual(
                app.state,
                .notRunning,
                "The app must be fully stopped so the next quality session receives fresh launch inputs"
            )
        }
        app.launch()
        guard requiresQualityHandshake else { return }

        let runtimeHandshake = app.descendants(matching: .any)
            .matching(NSPredicate(
                format: "identifier BEGINSWITH %@ OR identifier == %@",
                "quality-runtime.",
                "state.storage.unavailable"
            ))
            .firstMatch
        // Fixture-backed sessions may spend the first few seconds opening the
        // isolated store and applying migrations before publishing their
        // readiness marker. Keep this bounded by the same finite budget used
        // by the explicit readiness oracle instead of failing a valid session
        // at an arbitrary shorter boundary.
        XCTAssertTrue(
            runtimeHandshake.waitForExistence(timeout: qualityHandshakeTimeout),
            "QUALITY_PRECONDITION: App-owned runtime handshake did not become observable after one launch."
        )
    }

    func tapWhenHittable(
        _ element: XCUIElement,
        timeout: TimeInterval,
        message: String = "Expected control to become hittable",
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

    private func assertMessagesTabBadgeCount(
        _ expectedCount: Int?,
        in app: XCUIApplication,
        timeout: TimeInterval = 8,
        message: String = "The Messages navigation badge did not match canonical unread state",
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(
            tabBar.waitForExistence(timeout: timeout),
            "The production TabBar must exist before its Messages badge can be verified",
            file: file,
            line: line
        )
        let identifiedMessagesTab = tabBar.buttons["tab.messages"]
        let messagesTab = identifiedMessagesTab.exists
            ? identifiedMessagesTab
            : tabBar.buttons.element(boundBy: 0)
        XCTAssertTrue(
            messagesTab.waitForExistence(timeout: timeout),
            "The production Messages tab must exist before its badge can be verified",
            file: file,
            line: line
        )
        XCTAssertTrue(
            ["Messages", "消息", "訊息"].contains(messagesTab.label),
            "The first production tab must remain the localized Messages destination",
            file: file,
            line: line
        )
        let deadline = Date().addingTimeInterval(timeout)
        var actualCount = messagesTabBadgeCount(messagesTab)
        while actualCount != expectedCount, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            actualCount = messagesTabBadgeCount(messagesTab)
        }
        XCTAssertEqual(actualCount, expectedCount, message, file: file, line: line)
    }

    private func messagesTabBadgeCount(_ messagesTab: XCUIElement) -> Int? {
        guard let value = messagesTab.value as? String else { return nil }
        let digits = value.filter(\.isNumber)
        return digits.isEmpty ? nil : Int(digits)
    }

    private func openMessageFilters(in app: XCUIApplication) {
        tapWhenHittable(
            element(in: app, identifier: "action.messages.filter"),
            timeout: 5,
            message: "The production message filter control must be reachable"
        )
        XCTAssertTrue(
            element(in: app, identifier: "filter.unread_only").waitForExistence(timeout: 5),
            "The production filter surface did not open"
        )
        XCTAssertTrue(
            element(in: app, identifier: "filter.surface").waitForExistence(timeout: 5),
            "The production filter surface has no stable scroll owner"
        )
    }

    private func revealFilterOption(
        _ identifier: String,
        towardTags: Bool,
        in app: XCUIApplication
    ) {
        let option = element(in: app, identifier: identifier)
        let surface = element(in: app, identifier: "filter.surface")
        for _ in 0..<4 {
            if option.exists, option.isHittable { return }
            let visibleProbe = towardTags
                ? element(in: app, identifier: "filter.unread_only")
                : ["filter.tag.even", "filter.tag.odd"]
                    .map { element(in: app, identifier: $0) }
                    .first(where: { $0.exists && $0.isHittable })
            let gestureSource = visibleProbe?.exists == true && visibleProbe?.isHittable == true
                ? visibleProbe!
                : surface
            if towardTags {
                gestureSource.swipeUp()
            } else {
                gestureSource.swipeDown()
            }
        }
        XCTAssertTrue(option.exists && option.isHittable, "Filter option remained unreachable: \(identifier)")
    }

    private func dismissMessageFilters(in app: XCUIApplication) {
        let filterSurfaceProbe = element(in: app, identifier: "filter.unread_only")
        guard filterSurfaceProbe.exists else { return }
        app.swipeDown()
        XCTAssertTrue(
            filterSurfaceProbe.waitForNonExistence(timeout: 5),
            "The production filter surface did not dismiss after the platform gesture"
        )
    }

    private func assertMessageTitles(
        _ expected: [String],
        excluding unexpected: [String],
        in app: XCUIApplication,
        timeout: TimeInterval = 8,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        var matched = false
        repeat {
            matched = expected.allSatisfy { app.staticTexts[$0].exists }
                && unexpected.allSatisfy { !app.staticTexts[$0].exists }
            if matched { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        } while Date() < deadline
        XCTAssertTrue(
            matched,
            "The visible message set did not match the exact selected facets",
            file: file,
            line: line
        )
        for title in expected {
            XCTAssertTrue(app.staticTexts[title].exists, "Missing expected message: \(title)", file: file, line: line)
        }
        for title in unexpected {
            XCTAssertFalse(app.staticTexts[title].exists, "Unexpected message remained visible: \(title)", file: file, line: line)
        }
    }

    private func channelsTab(in app: XCUIApplication) -> XCUIElement {
        let identified = element(in: app, identifier: "tab.channels")
        if identified.waitForExistence(timeout: 2) {
            return identified
        }
        let tabBar = app.tabBars.firstMatch
        guard tabBar.waitForExistence(timeout: 8), tabBar.buttons.count > 0 else {
            return identified
        }
        // Channels is the only mandatory destination and is always the final
        // tab, even when optional data pages are hidden.
        return tabBar.buttons.element(boundBy: tabBar.buttons.count - 1)
    }

    private func openSettingsFromChannels(in app: XCUIApplication) {
        let channels = channelsTab(in: app)
        tapWhenHittable(channels, timeout: 8, message: "Channels must remain reachable")
        let settings = element(in: app, identifier: "action.channels.settings")
        tapWhenHittable(settings, timeout: 8, message: "Settings must open through the real Channels action")
        assertElementExists("screen.settings", in: app, timeout: 8)
    }

    private func ensureSettingsVisible(in app: XCUIApplication) {
        let settingsScreen = element(in: app, identifier: "screen.settings")
        if settingsScreen.waitForExistence(timeout: 1) {
            return
        }
        let settingsAction = element(in: app, identifier: "action.channels.settings")
        let actionable = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND hittable == true"),
            object: settingsAction
        )
        if XCTWaiter.wait(for: [actionable], timeout: 2) == .completed {
            settingsAction.tap()
            assertElementExists("screen.settings", in: app, timeout: 8)
            return
        }
        openSettingsFromChannels(in: app)
    }

    private func leaveSettings(in app: XCUIApplication) {
        let settingsScreen = element(in: app, identifier: "screen.settings")
        let back = app.navigationBars.buttons.firstMatch
        tapWhenHittable(back, timeout: 8, message: "Settings must provide a real back navigation action")
        XCTAssertTrue(
            settingsScreen.waitForNonExistence(timeout: 8),
            "Settings must finish dismissing before the next lifecycle assertion"
        )
        assertElementExists("screen.channels", in: app, timeout: 8)
    }

    private func scrollToHittableElement(
        identifier: String,
        in app: XCUIApplication
    ) -> XCUIElement {
        let target = element(in: app, identifier: identifier)
        for _ in 0..<6 {
            if target.exists, target.isHittable {
                return target
            }
            if app.tables.firstMatch.exists {
                app.tables.firstMatch.swipeUp()
            } else if app.scrollViews.firstMatch.exists {
                app.scrollViews.firstMatch.swipeUp()
            } else {
                app.swipeUp()
            }
        }
        return target
    }

    private func assertDataTabVisibility(
        messagesVisible: Bool,
        eventsVisible: Bool,
        thingsVisible: Bool,
        in app: XCUIApplication,
        openWhenVisible: Bool = false,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let buttons = app.tabBars.buttons
        let expectedCount = 1
            + (messagesVisible ? 1 : 0)
            + (eventsVisible ? 1 : 0)
            + (thingsVisible ? 1 : 0)
        let countExpectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "count == %d", expectedCount),
            object: buttons
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [countExpectation], timeout: 8),
            .completed,
            "The real navigation destinations must match the saved Messages/Events/Things visibility settings",
            file: file,
            line: line
        )
        guard messagesVisible,
              eventsVisible,
              thingsVisible,
              openWhenVisible,
              buttons.count == expectedCount else { return }
        let messagesButton = buttons.element(boundBy: 0)
        tapWhenHittable(
            messagesButton,
            timeout: 5,
            message: "The restored Messages entry must be actionable",
            file: file,
            line: line
        )
        assertElementExists("screen.messages.list", in: app, timeout: 8)
        XCTAssertTrue(
            app.staticTexts["P2 Split Seed Message"].waitForExistence(timeout: 8),
            "The restored Messages destination must reach its accurate App-owned content",
            file: file,
            line: line
        )
        let eventButton = buttons.element(boundBy: 1)
        tapWhenHittable(
            eventButton,
            timeout: 5,
            message: "The restored Events entry must be actionable",
            file: file,
            line: line
        )
        assertElementExists("screen.events.list", in: app, timeout: 8)
        XCTAssertTrue(
            app.staticTexts["No events yet"].waitForExistence(timeout: 8),
            "The restored Events destination must reach its functional empty state",
            file: file,
            line: line
        )
        XCTAssertTrue(app.staticTexts["Track issues from open to close."].exists)
        XCTAssertTrue(app.staticTexts["Add a channel."].exists)
        XCTAssertTrue(app.staticTexts["Close it when finished."].exists)
        XCTAssertTrue(
            app.buttons["Event API docs"].exists && app.buttons["Event API docs"].isHittable,
            "The Events empty state must give the user an actionable next step"
        )
        let thingButton = buttons.element(boundBy: 2)
        tapWhenHittable(
            thingButton,
            timeout: 5,
            message: "The restored Things entry must be actionable",
            file: file,
            line: line
        )
        assertElementExists("screen.things.list", in: app, timeout: 8)
        XCTAssertTrue(
            app.staticTexts["No objects yet"].waitForExistence(timeout: 8),
            "The restored Things destination must reach its functional empty state",
            file: file,
            line: line
        )
        XCTAssertTrue(app.staticTexts["Track changing state by object."].exists)
        XCTAssertTrue(app.staticTexts["Create or subscribe to a channel."].exists)
        XCTAssertTrue(app.staticTexts["Update related events and messages."].exists)
        XCTAssertTrue(
            app.buttons["Object API docs"].exists && app.buttons["Object API docs"].isHittable,
            "The Things empty state must give the user an actionable next step"
        )
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

    func element(in app: XCUIApplication, identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func eventsTab(in app: XCUIApplication) -> XCUIElement {
        let identifiedTab = app.buttons["tab.events"]
        if identifiedTab.exists {
            return identifiedTab
        }
        // Keep a narrow compatibility fallback for iOS releases that omit the
        // tab-item identifier from the accessibility tree. The post-tap screen
        // assertion below prevents a positional match from being treated as a
        // successful navigation when it did not actually switch pages.
        return app.tabBars.buttons.element(boundBy: 1)
    }

    private func openEventsTab(
        in app: XCUIApplication,
        timeout: TimeInterval = 8,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let target = eventsTab(in: app)
        XCTAssertTrue(
            target.waitForExistence(timeout: timeout),
            "The real Events tab must exist before opening the Events page",
            file: file,
            line: line
        )
        let actionable = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND hittable == true"),
            object: target
        )
        let result = XCTWaiter.wait(for: [actionable], timeout: timeout)
        XCTAssertEqual(
            result,
            .completed,
            "The real Events tab must be actionable before opening the Events page",
            file: file,
            line: line
        )
        guard result == .completed else { return }
        target.tap()
        XCTAssertTrue(
            element(in: app, identifier: "screen.events.list").waitForExistence(timeout: timeout),
            "The Events tab tap must reach the production Events list",
            file: file,
            line: line
        )
    }

    private func storageRecoveryButton(
        in app: XCUIApplication,
        identifier: String,
        fallbackLabel: String
    ) -> XCUIElement {
        let semanticButton = element(in: app, identifier: identifier)
        return semanticButton.exists ? semanticButton : app.buttons[fallbackLabel]
    }

    private func replaceText(in field: XCUIElement, with text: String) {
        field.tap()
        let existing = (field.value as? String) ?? ""
        // XCUI can report an actual field value that happens to equal its
        // placeholder. Treat every non-empty value as replaceable; selecting
        // and deleting a placeholder-only empty field is harmless, while
        // skipping this step appends input to real persisted content.
        let hasEnteredText = !existing.isEmpty
        if hasEnteredText {
            field.typeKey("a", modifierFlags: .command)
            field.typeKey(XCUIKeyboardKey.delete.rawValue, modifierFlags: [])
            // If selection was not honored by the current software keyboard,
            // move to the end and apply a bounded fallback clear. XCUI may
            // expose only the first whitespace-delimited token as `value`.
            field.typeKey(XCUIKeyboardKey.rightArrow.rawValue, modifierFlags: .command)
            field.typeText(
                String(repeating: XCUIKeyboardKey.delete.rawValue, count: 256)
            )
        }
        if !text.isEmpty {
            field.typeText(text)
        }
    }

    private func enterSecureText(
        in field: XCUIElement,
        with text: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let actionable = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND hittable == true"),
            object: field
        )
        let actionableResult = XCTWaiter.wait(for: [actionable], timeout: 8)
        XCTAssertEqual(
            actionableResult,
            .completed,
            "The secure field must be visible and reachable before its single focus tap",
            file: file,
            line: line
        )
        guard actionableResult == .completed else { return }
        field.tap()
        let focused = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "hasKeyboardFocus == true"),
            object: field
        )
        let focusResult = XCTWaiter.wait(for: [focused], timeout: 2)
        XCTAssertEqual(
            focusResult,
            .completed,
            "A single tap must move keyboard focus to the requested secure field",
            file: file,
            line: line
        )
        guard focusResult == .completed else { return }
        let existing = (field.value as? String) ?? ""
        let placeholder = field.placeholderValue ?? ""
        if !existing.isEmpty && existing != placeholder {
            field.typeKey("a", modifierFlags: .command)
            field.typeText(XCUIKeyboardKey.delete.rawValue)
            // iOS Simulator secure fields can acknowledge Command-A while leaving
            // the underlying value selected-but-not-deleted. Delete a bounded
            // maximum credential length as a deterministic fallback, then prove
            // the field is actually empty before typing the replacement.
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 128))
            let cleared = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "value == %@ OR value == ''", placeholder),
                object: field
            )
            XCTAssertEqual(
                XCTWaiter.wait(for: [cleared], timeout: 2),
                .completed,
                "The secure field must be observably empty before replacement input",
                file: file,
                line: line
            )
        }
        field.typeText(text)
    }

    func assertElementExists(
        _ identifier: String,
        in app: XCUIApplication,
        timeout: TimeInterval = 8,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let target = element(in: app, identifier: identifier)
        XCTAssertTrue(target.waitForExistence(timeout: timeout), "Missing element: \(identifier)", file: file, line: line)
    }

    func assertQualityRuntimeReady(
        in app: XCUIApplication,
        timeout: TimeInterval,
        expectedSessionID: String? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let ready = element(in: app, identifier: "quality-runtime.ready")
        if ready.waitForExistence(timeout: timeout) {
            if let expectedSessionID {
                XCTAssertEqual(
                    ready.value as? String,
                    expectedSessionID,
                    "QUALITY_PRECONDITION: App-owned quality session identity did not match the requested session.",
                    file: file,
                    line: line
                )
            }
            return
        }
        let observedStatus = [
            "invalid",
            "missing",
            "failed",
            "seeding.messages.system_snapshot.end",
            "seeding.messages.live_activity.end",
            "seeding.messages.notification_snapshot.end",
            "seeding.messages.system_search.end",
            "seeding.messages.metadata.end",
            "seeding.messages.search.end",
            "seeding.messages.search.start",
            "seeding.messages.backend.end",
            "seeding.messages.backend.start",
            "seeding.messages.saved",
            "seeding.messages",
            "seeding.entities",
            "seeding.entities.saved",
            "seeding.channels",
            "seeding.channels.saved",
            "seeding.refresh",
            "seeding.complete",
            "seeding",
            "executing",
            "finalizing",
            "initializing",
        ]
            .first { element(in: app, identifier: "quality-runtime.\($0)").exists }
            ?? "missing"
        XCTFail(
            "QUALITY_PRECONDITION: App-owned quality session did not become ready; observed status: \(observedStatus)",
            file: file,
            line: line
        )
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

    private func hasReadableLowerTitleContrast(in screenshot: XCUIScreenshot) -> Bool {
        guard let image = screenshot.image.cgImage else { return false }
        let cropRect = CGRect(
            x: CGFloat(image.width) * 0.20,
            y: CGFloat(image.height) * 0.58,
            width: CGFloat(image.width) * 0.60,
            height: CGFloat(image.height) * 0.32
        ).integral
        guard let crop = image.cropping(to: cropRect), crop.width * crop.height >= 10 else { return false }
        let bytesPerPixel = 4
        let bytesPerRow = crop.width * bytesPerPixel
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * crop.height)
        let rendered = pixels.withUnsafeMutableBytes { buffer in
            guard let baseAddress = buffer.baseAddress,
                  let context = CGContext(
                      data: baseAddress,
                      width: crop.width,
                      height: crop.height,
                      bitsPerComponent: 8,
                      bytesPerRow: bytesPerRow,
                      space: CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  )
            else {
                return false
            }
            context.draw(crop, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
            return true
        }
        guard rendered else { return false }
        var luminances: [CGFloat] = []
        luminances.reserveCapacity(crop.width * crop.height)
        for y in 0 ..< crop.height {
            for x in 0 ..< crop.width {
                let offset = y * bytesPerRow + x * bytesPerPixel
                let red = CGFloat(pixels[offset]) / 255
                let green = CGFloat(pixels[offset + 1]) / 255
                let blue = CGFloat(pixels[offset + 2]) / 255
                luminances.append(0.2126 * red + 0.7152 * green + 0.0722 * blue)
            }
        }
        luminances.sort()
        let darkSample = luminances[luminances.count / 20]
        let lightSample = luminances[luminances.count * 19 / 20]
        return lightSample - darkSample >= 0.25
    }
}
