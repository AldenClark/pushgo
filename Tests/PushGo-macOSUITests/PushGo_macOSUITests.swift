import AppKit
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
    private var launchedApps: [XCUIApplication] = []

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
        // A crash dialog can be posted shortly after the App process exits. Require a
        // quiet observation window before every journey so it cannot cover the next UI.
        try closeProblemReporter(waitForDelayedAppearance: true)
    }

    override func tearDownWithError() throws {
        for app in launchedApps where app.state != .notRunning {
            app.terminate()
        }
        launchedApps.removeAll()

        var cleanupError: Error?
        do {
            try closeProblemReporter(waitForDelayedAppearance: true)
        } catch {
            cleanupError = error
        }
        let fileManager = FileManager.default
        for runtimeRoot in runtimeRoots {
            try? fileManager.removeItem(at: runtimeRoot)
        }
        runtimeRoots.removeAll()
        if let cleanupError {
            throw cleanupError
        }
    }

    private func closeProblemReporter(waitForDelayedAppearance: Bool) throws {
        // macOS has used both the dedicated Problem Reporter process and
        // UserNotificationCenter to own the "app quit unexpectedly" dialog.
        // Treat either host as a blocking crash surface; checking only the legacy
        // bundle identifier leaves a real dialog covering the next journey.
        let crashDialogHostBundleIdentifiers = [
            "com.apple.ProblemReporter",
            "com.apple.UserNotificationCenter",
        ]
        let deadline = Date().addingTimeInterval(waitForDelayedAppearance ? 0.35 : 0)
        repeat {
            let reporters = NSWorkspace.shared.runningApplications.filter {
                guard let bundleIdentifier = $0.bundleIdentifier else { return false }
                return crashDialogHostBundleIdentifiers.contains(bundleIdentifier) && !$0.isTerminated
            }
            if !reporters.isEmpty {
                for reporter in reporters {
                    _ = reporter.terminate()
                }
                Thread.sleep(forTimeInterval: 0.1)
                for reporter in reporters where !reporter.isTerminated {
                    _ = reporter.forceTerminate()
                }
                Thread.sleep(forTimeInterval: 0.1)
            }
            let remaining = NSWorkspace.shared.runningApplications.filter {
                guard let bundleIdentifier = $0.bundleIdentifier else { return false }
                return crashDialogHostBundleIdentifiers.contains(bundleIdentifier) && !$0.isTerminated
            }
            if !remaining.isEmpty && Date() >= deadline {
                throw NSError(
                    domain: "macos_problem_reporter_cleanup_failed",
                    code: 1,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "macos_problem_reporter_cleanup_failed: system crash dialog would obstruct the next UI journey"
                    ]
                )
            }
            if Date() < deadline {
                Thread.sleep(forTimeInterval: 0.05)
            } else {
                break
            }
        } while true
    }

    @MainActor
    // Non-discoverable migration diagnostic. It must not be restored to a test until its
    // command/state oracle is replaced by an independent user-purpose outcome.
    func legacyDiagnosticLaunchesIntoMessageList() {
        let context = configuredApp()
        launch(context)

        assertVisibleScreen("screen.messages.list", in: context)
    }

    @MainActor
    func testQualitySessionUsesAppOwnedStoreAndReachesFunctionalEmptyState() {
        let sessionID = "macos-empty-\(UUID().uuidString.lowercased())"
        let context = configuredQualityApp(sessionID: sessionID, fixture: "empty.clean")
        launchQuality(context, sessionID: sessionID)

        XCTAssertTrue(element(in: context.app, identifier: "screen.messages.list").exists)
        XCTAssertTrue(
            element(in: context.app, identifier: "state.messages.empty")
                .waitForExistence(timeout: 5)
        )
    }

    @MainActor
    func testSystemNotificationClickPersistsAccurateMessageAndSurvivesRelaunch() {
        let sessionID = "macos-system-notification-\(UUID().uuidString.lowercased())"
        let requestID = "quality-macos-notification-\(UUID().uuidString.lowercased())"
        let messageID = "quality-macos-message-\(UUID().uuidString.lowercased())"
        let title = "Quality macOS System Message"
        let body = "The real macOS notification opens this canonical body."
        let context = configuredQualityApp(
            sessionID: sessionID,
            fixture: "empty.clean",
            skipPushAuthorization: false
        )
        context.app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        setAutomationRequest(
            name: "notification.schedule_system",
            args: [
                "notification_request_id": requestID,
                "message_id": messageID,
                "title": title,
                "body": body,
            ],
            in: context.app
        )

        context.app.launch()
        resolveMacNotificationAuthorizationIfNeeded(in: context.app)
        context.app.activate()
        XCTAssertTrue(context.app.windows.firstMatch.waitForExistence(timeout: 12))
        let ready = element(in: context.app, identifier: "quality-runtime.ready")
        XCTAssertTrue(
            ready.waitForExistence(timeout: 15),
            "QUALITY_PRECONDITION: App-owned notification session did not become ready."
        )
        XCTAssertEqual(ready.value as? String, sessionID)

        let commandSucceeded = element(in: context.app, identifier: "quality-command.succeeded")
        let commandFailed = element(in: context.app, identifier: "quality-command.failed")
        guard commandSucceeded.exists else {
            let failureDetail = commandFailed.exists
                ? ((commandFailed.value as? String) ?? "unknown command error")
                : "missing App-owned command outcome"
            XCTFail(
                "QUALITY_PRECONDITION: macOS system notification scheduling failed before product verification: "
                    + failureDetail
            )
            return
        }

        context.app.typeKey("h", modifierFlags: .command)
        let backgrounded = XCTNSPredicateExpectation(
            predicate: NSPredicate(
                format: "state == %d",
                XCUIApplication.State.runningBackground.rawValue
            ),
            object: context.app
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [backgrounded], timeout: 5),
            .completed,
            "QUALITY_PRECONDITION: PushGo did not leave the foreground before notification delivery."
        )

        let notificationCenter = XCUIApplication(bundleIdentifier: "com.apple.notificationcenterui")
        let titleElement = notificationCenter.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", title))
            .firstMatch
        XCTAssertTrue(
            titleElement.waitForExistence(timeout: 15),
            "The exact App-owned payload did not appear in the real macOS notification surface."
        )
        XCTAssertTrue(
            notificationCenter.descendants(matching: .any)
                .matching(NSPredicate(format: "label == %@", body))
                .firstMatch
                .waitForExistence(timeout: 3),
            "The macOS notification surface changed or lost the exact payload body."
        )
        titleElement.click()

        XCTAssertTrue(
            element(in: context.app, identifier: "screen.message.detail")
                .waitForExistence(timeout: 12),
            "The real notification click did not route into the canonical message detail."
        )
        XCTAssertTrue(context.app.staticTexts[title].waitForExistence(timeout: 5))
        XCTAssertTrue(
            context.app.staticTexts[body].waitForExistence(timeout: 5),
            "The routed detail did not display the exact notification body."
        )

        context.app.terminate()
        let relaunched = configuredQualityApp(sessionID: sessionID, fixture: "empty.clean")
        relaunched.app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        launchQuality(relaunched, sessionID: sessionID)
        let persistedRow = messageRow(containing: title, in: relaunched.app)
        XCTAssertTrue(
            persistedRow.waitForExistence(timeout: 10),
            "The system-ingressed canonical message did not survive process relaunch."
        )
        persistedRow.click()
        XCTAssertTrue(
            element(in: relaunched.app, identifier: "screen.message.detail")
                .waitForExistence(timeout: 8)
        )
        XCTAssertTrue(
            relaunched.app.staticTexts[body].waitForExistence(timeout: 5),
            "The persisted notification message changed after relaunch."
        )
    }

    @MainActor
    func testFatalStoreInitializationStopsReadWriteAndRecoversAfterRelaunch() {
        let sessionID = "macos-store-fatal-\(UUID().uuidString.lowercased())"
        let failing = configuredQualityApp(
            sessionID: sessionID,
            fixture: "messages.standard",
            failLocalStoreInitialization: true
        )
        failing.app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        failing.app.launch()
        failing.app.activate()
        dismissSystemPrivacyDialogsIfNeeded(in: failing.app)

        XCTAssertTrue(failing.app.windows.firstMatch.waitForExistence(timeout: 12))
        XCTAssertTrue(
            failing.app.staticTexts[
                "Local storage is unavailable. The app may be unable to load or save messages."
            ].waitForExistence(timeout: 8),
            "A fatal Store open failure must be shown as unavailable, not as an empty message list."
        )
        XCTAssertTrue(
            failing.app.staticTexts.matching(
                NSPredicate(
                    format: "value CONTAINS %@ OR label CONTAINS %@",
                    "Quality-injected local persistent storage initialization failure.",
                    "Quality-injected local persistent storage initialization failure."
                )
            ).firstMatch.exists,
            "The recovery surface must retain the causal Store failure for diagnosis."
        )
        XCTAssertTrue(element(in: failing.app, identifier: "state.storage.unavailable").exists)
        XCTAssertFalse(element(in: failing.app, identifier: "screen.messages.list").exists)
        XCTAssertFalse(element(in: failing.app, identifier: "state.messages.empty").exists)
        XCTAssertFalse(element(in: failing.app, identifier: "quality-runtime.ready").exists)
        let exit = failing.app.sheets.firstMatch.buttons["Exit App"]
        XCTAssertTrue(exit.waitForExistence(timeout: 5) && exit.isHittable)
        exit.click()
        let terminated = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "state == %d", XCUIApplication.State.notRunning.rawValue),
            object: failing.app
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [terminated], timeout: 5),
            .completed,
            "The storage recovery Exit action must actually terminate the App."
        )

        let recovered = configuredQualityApp(sessionID: sessionID, fixture: "messages.standard")
        recovered.app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        launchQuality(recovered, sessionID: sessionID)
        XCTAssertTrue(
            element(
                in: recovered.app,
                identifier: "message.row.00000000-0000-0000-0000-000000000001"
            ).waitForExistence(timeout: 8)
        )
        XCTAssertFalse(element(in: recovered.app, identifier: "action.storage.exit").exists)
    }

    @MainActor
    func testQualityStandardMessagesShowAccurateContentAndSurviveRelaunch() {
        let sessionID = "macos-standard-\(UUID().uuidString.lowercased())"
        let context = configuredQualityApp(
            sessionID: sessionID,
            fixture: "messages.standard",
            legacyStore: "messages.v17",
            allowCrossAppDataAccess: true
        )
        launchQuality(context, sessionID: sessionID)

        let legacyRow = element(
            in: context.app,
            identifier: "message.row.00000000-0000-0000-0000-000000000017"
        )
        XCTAssertTrue(
            legacyRow.waitForExistence(timeout: 8)
                && legacyRow.label.contains("Legacy Upgrade Message"),
            "The production v17-to-current migration must preserve the legacy row in the real macOS list."
        )
        legacyRow.click()
        XCTAssertTrue(
            element(in: context.app, identifier: "screen.message.detail")
                .waitForExistence(timeout: 8)
        )
        XCTAssertTrue(
            context.app.staticTexts["Preserved through the production database migration."].exists,
            "The migrated macOS detail must retain the exact legacy body."
        )

        let row = element(
            in: context.app,
            identifier: "message.row.00000000-0000-0000-0000-000000000001"
        )
        XCTAssertTrue(
            row.waitForExistence(timeout: 8),
            "The real message list did not render the canonical stored row."
        )
        XCTAssertTrue(
            row.label.contains("P2 Split Seed Message"),
            "The accessible row label did not expose the canonical title."
        )
        XCTAssertTrue(
            (row.value as? String)?.contains("Seeded from fixture.seed_messages for UI validation.") == true,
            "The accessible row value did not expose the canonical body."
        )
        row.click()
        XCTAssertTrue(
            element(in: context.app, identifier: "screen.message.detail")
                .waitForExistence(timeout: 8),
            "Selecting the canonical row did not open its real detail pane."
        )
        XCTAssertTrue(context.app.staticTexts["P2 Split Seed Message"].exists)
        XCTAssertTrue(
            context.app.staticTexts["Seeded from fixture.seed_messages for UI validation."].exists
        )

        let pasteboard = NSPasteboard.general
        let savedPasteboardItems: [[NSPasteboard.PasteboardType: Data]] =
            pasteboard.pasteboardItems?.map { item in
                Dictionary(uniqueKeysWithValues: item.types.compactMap { type in
                    item.data(forType: type).map { (type, $0) }
                })
            } ?? []
        defer {
            pasteboard.clearContents()
            let restoredItems = savedPasteboardItems.map { representations in
                let item = NSPasteboardItem()
                for (type, data) in representations {
                    item.setData(data, forType: type)
                }
                return item
            }
            if !restoredItems.isEmpty {
                pasteboard.writeObjects(restoredItems)
            }
        }

        let metadataCopy = element(
            in: context.app,
            identifier: "action.message.copy_metadata_value.0"
        )
        XCTAssertTrue(
            metadataCopy.waitForExistence(timeout: 5) && metadataCopy.isHittable,
            "The canonical metadata value must expose a reachable production copy action."
        )
        assertExactPasteboardCopy(
            "quality-fixture",
            byClicking: metadataCopy,
            pasteboard: pasteboard,
            in: context.app,
            purpose: "message metadata"
        )

        let copyLink = element(in: context.app, identifier: "action.message.copy_link")
        let detailScroll = context.app.scrollViews.firstMatch
        for _ in 0..<3 where !(copyLink.exists && copyLink.isHittable) {
            detailScroll.swipeUp()
        }
        XCTAssertTrue(
            copyLink.exists && copyLink.isHittable,
            "The canonical message URL copy action remained unreachable in the real detail."
        )
        assertExactPasteboardCopy(
            "https://pushgo.dev/quality-message",
            byClicking: copyLink,
            pasteboard: pasteboard,
            in: context.app,
            purpose: "message URL"
        )

        let image = element(in: context.app, identifier: "message.image.0")
        for _ in 0..<3 where !(image.exists && image.isHittable) {
            detailScroll.swipeDown()
        }
        XCTAssertTrue(
            image.waitForExistence(timeout: 8) && image.isHittable,
            "The canonical message image must decode into an interactive detail asset."
        )
        image.click()
        XCTAssertTrue(
            element(in: context.app, identifier: "dialog.image.preview")
                .waitForExistence(timeout: 8),
            "The decoded message image must open the production preview."
        )
        let shareImage = element(in: context.app, identifier: "action.image.preview.share")
        XCTAssertTrue(
            shareImage.waitForExistence(timeout: 8) && shareImage.isHittable,
            "The preview must prepare a real file before enabling its native Share action."
        )
        shareImage.click()
        XCTAssertTrue(
            context.app.menus.firstMatch.waitForExistence(timeout: 5),
            "The prepared image file must reach the native sharing service picker."
        )

        context.app.terminate()
        let relaunched = configuredQualityApp(
            sessionID: sessionID,
            fixture: "messages.standard",
            legacyStore: "messages.v17",
            allowCrossAppDataAccess: true
        )
        launchQuality(relaunched, sessionID: sessionID)
        let relaunchedLegacyRow = element(
            in: relaunched.app,
            identifier: "message.row.00000000-0000-0000-0000-000000000017"
        )
        XCTAssertTrue(
            relaunchedLegacyRow.waitForExistence(timeout: 8)
                && relaunchedLegacyRow.label.contains("Legacy Upgrade Message"),
            "The migrated macOS canonical message must survive an ordinary process relaunch."
        )
        let relaunchedRow = element(
            in: relaunched.app,
            identifier: "message.row.00000000-0000-0000-0000-000000000001"
        )
        XCTAssertTrue(
            relaunchedRow.waitForExistence(timeout: 8)
                && relaunchedRow.label.contains("P2 Split Seed Message"),
            "The canonical message did not survive a real process relaunch."
        )
        XCTAssertFalse(element(in: relaunched.app, identifier: "state.messages.empty").exists)
    }

    @MainActor
    func testHistoryCleanupRemovesOnlyOldMessagesAndPersistsAcrossRelaunch() {
        let sessionID = "macos-cleanup-\(UUID().uuidString.lowercased())"
        let context = configuredQualityApp(sessionID: sessionID, fixture: "messages.cleanup")
        launchQuality(context, sessionID: sessionID)

        let oldRow = element(
            in: context.app,
            identifier: "message.row.00000000-0000-0000-0000-00000000c101"
        )
        let recentRow = element(
            in: context.app,
            identifier: "message.row.00000000-0000-0000-0000-00000000c102"
        )
        let badge = context.app.staticTexts["sidebar.messages.unread_badge"]
        XCTAssertTrue(oldRow.waitForExistence(timeout: 8))
        XCTAssertTrue(recentRow.waitForExistence(timeout: 8))
        XCTAssertTrue(badge.waitForExistence(timeout: 8))
        XCTAssertEqual(badge.value as? String, "2")

        openMessageFilters(in: context.app)
        let cleanup = element(in: context.app, identifier: "action.messages.history_cleanup")
        XCTAssertTrue(cleanup.waitForExistence(timeout: 5) && cleanup.isHittable)
        cleanup.click()
        let rangeSheet = element(in: context.app, identifier: "sheet.messages.history_cleanup.range")
        XCTAssertTrue(rangeSheet.waitForExistence(timeout: 8))
        let thirtyDays = element(
            in: context.app,
            identifier: "option.messages.history_cleanup.30_days"
        )
        if !thirtyDays.waitForExistence(timeout: 2) || !thirtyDays.isHittable {
            rangeSheet.swipeUp()
        }
        XCTAssertTrue(thirtyDays.waitForExistence(timeout: 5) && thirtyDays.isHittable)
        thirtyDays.click()
        let confirm = element(
            in: context.app,
            identifier: "action.messages.history_cleanup.confirm"
        )
        XCTAssertTrue(confirm.waitForExistence(timeout: 5) && confirm.isHittable)
        confirm.click()
        let done = element(in: context.app, identifier: "action.messages.history_cleanup.done")
        XCTAssertTrue(done.waitForExistence(timeout: 8) && done.isHittable)
        done.click()

        XCTAssertTrue(oldRow.waitForNonExistence(timeout: 8))
        XCTAssertTrue(recentRow.waitForExistence(timeout: 8))
        XCTAssertTrue(waitForValue("1", in: badge, timeout: 8))

        context.app.terminate()
        let relaunched = configuredQualityApp(sessionID: sessionID, fixture: "messages.cleanup")
        launchQuality(relaunched, sessionID: sessionID)
        XCTAssertFalse(
            element(
                in: relaunched.app,
                identifier: "message.row.00000000-0000-0000-0000-00000000c101"
            ).exists,
            "The removed old message must not return after process relaunch."
        )
        XCTAssertTrue(
            element(
                in: relaunched.app,
                identifier: "message.row.00000000-0000-0000-0000-00000000c102"
            ).waitForExistence(timeout: 8)
        )
        let relaunchedBadge = relaunched.app.staticTexts["sidebar.messages.unread_badge"]
        XCTAssertTrue(relaunchedBadge.waitForExistence(timeout: 8))
        XCTAssertEqual(relaunchedBadge.value as? String, "1")
    }

    @MainActor
    func testMarkdownFixtureRendersMajorStructuresInTheRealDetail() {
        let sessionID = "macos-markdown-\(UUID().uuidString.lowercased())"
        let context = configuredQualityApp(sessionID: sessionID, fixture: "messages.markdown")
        launchQuality(context, sessionID: sessionID)

        let row = element(
            in: context.app,
            identifier: "message.row.00000000-0000-0000-0000-00000000d001"
        )
        XCTAssertTrue(row.waitForExistence(timeout: 8))
        row.click()
        XCTAssertTrue(
            element(in: context.app, identifier: "screen.message.detail")
                .waitForExistence(timeout: 8)
        )

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
                NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", fragment, fragment)
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
    }

    @MainActor
    func testMessageChannelTagCombinedUngroupedFiltersAndScopedReadPersist() {
        let sessionID = "macos-message-filters-\(UUID().uuidString.lowercased())"
        let context = configuredQualityApp(sessionID: sessionID, fixture: "messages.filters")
        let allTitles = [
            "Quality filter alpha even",
            "Quality filter alpha odd",
            "Quality filter beta odd",
            "Quality filter beta even",
            "Quality filter ungrouped orphan",
        ]
        launchQuality(context, sessionID: sessionID)
        assertMessageTitles(allTitles, excluding: [], in: context.app)

        let badge = context.app.staticTexts["sidebar.messages.unread_badge"]
        XCTAssertTrue(badge.waitForExistence(timeout: 8))
        XCTAssertEqual(badge.value as? String, "4")

        openMessageFilters(in: context.app)
        revealFilterOption("filter.channel-filter-alpha", towardTags: false, in: context.app)
        element(in: context.app, identifier: "filter.channel-filter-alpha").click()
        dismissMessageFilters(in: context.app)

        openMessageFilters(in: context.app)
        revealFilterOption("filter.tag.even", towardTags: true, in: context.app)
        element(in: context.app, identifier: "filter.tag.even").click()
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
        element(in: context.app, identifier: "filter.channel-filter-alpha").click()
        revealFilterOption("filter.tag.even", towardTags: true, in: context.app)
        element(in: context.app, identifier: "filter.tag.even").click()
        revealFilterOption("filter.channel-ungrouped", towardTags: false, in: context.app)
        element(in: context.app, identifier: "filter.channel-ungrouped").click()
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

        let markCurrentScopeRead = element(
            in: context.app,
            identifier: "action.messages.mark_all_read"
        )
        XCTAssertTrue(markCurrentScopeRead.waitForExistence(timeout: 5) && markCurrentScopeRead.isHittable)
        markCurrentScopeRead.click()
        XCTAssertTrue(markCurrentScopeRead.waitForNonExistence(timeout: 8))
        XCTAssertTrue(
            waitForValue("3", in: badge, timeout: 8),
            "Only the selected ungrouped unread message may be marked read"
        )

        context.app.terminate()
        let relaunched = configuredQualityApp(sessionID: sessionID, fixture: "messages.filters")
        launchQuality(relaunched, sessionID: sessionID)
        let relaunchedBadge = relaunched.app.staticTexts["sidebar.messages.unread_badge"]
        XCTAssertTrue(relaunchedBadge.waitForExistence(timeout: 8))
        XCTAssertEqual(relaunchedBadge.value as? String, "3")

        openMessageFilters(in: relaunched.app)
        revealFilterOption("filter.channel-ungrouped", towardTags: false, in: relaunched.app)
        element(in: relaunched.app, identifier: "filter.channel-ungrouped").click()
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

    @MainActor
    func testUnreadBadgeAndChannelLifecyclePersistThroughRealUserActions() {
        let sessionID = "macos-sidebar-badge-\(UUID().uuidString.lowercased())"
        let context = configuredQualityApp(
            sessionID: sessionID,
            fixture: "channels.standard",
            channelMutationScenario: "accepted"
        )
        context.app.launchArguments += [
            "-AppleLanguages", "(zh-Hans)",
            "-AppleLocale", "zh_CN",
        ]
        launchQuality(context, sessionID: sessionID)

        let title = context.app.staticTexts["sidebar-messages"]
        let badge = context.app.staticTexts["sidebar.messages.unread_badge"]
        XCTAssertTrue(title.waitForExistence(timeout: 8))
        XCTAssertTrue(badge.waitForExistence(timeout: 8))
        XCTAssertEqual(
            title.value as? String,
            "消息",
            "The representative sidebar state must exercise the real zh-Hans title."
        )
        XCTAssertEqual(badge.value as? String, "2", "The fixture must exercise a real unread badge.")
        XCTAssertGreaterThanOrEqual(
            title.frame.width,
            24,
            "The full two-glyph Chinese Messages title was compressed or truncated."
        )
        XCTAssertGreaterThan(
            badge.frame.minX,
            title.frame.maxX + 4,
            "The unread badge overlaps the Messages title."
        )

        let titleScreenshot = title.screenshot()
        let attachment = XCTAttachment(screenshot: titleScreenshot)
        attachment.name = "selected-messages-sidebar-title-with-unread-badge"
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertTrue(
            hasReadableForegroundContrast(in: titleScreenshot),
            "The selected Messages title has insufficient visible foreground contrast."
        )

        title.click()
        XCTAssertTrue(
            element(in: context.app, identifier: "screen.messages.list")
                .waitForExistence(timeout: 8),
            "The readable Messages entry must remain a functional navigation target."
        )

        let firstUnread = element(
            in: context.app,
            identifier: "message.row.00000000-0000-0000-0000-00000000c002"
        )
        XCTAssertTrue(firstUnread.waitForExistence(timeout: 8))
        firstUnread.click()
        XCTAssertTrue(
            context.app.staticTexts[
                "Deterministic history owned by 01H00000000000000000000002."
            ].waitForExistence(timeout: 8)
        )
        XCTAssertEqual(
            waitForValue("1", in: badge, timeout: 8),
            true,
            "Opening one real unread message must decrement the sidebar badge exactly once."
        )

        let secondUnread = element(
            in: context.app,
            identifier: "message.row.00000000-0000-0000-0000-00000000c001"
        )
        XCTAssertTrue(secondUnread.waitForExistence(timeout: 8))
        secondUnread.click()
        XCTAssertTrue(
            context.app.staticTexts[
                "Deterministic history owned by 01H00000000000000000000001."
            ].waitForExistence(timeout: 8)
        )
        XCTAssertTrue(
            badge.waitForNonExistence(timeout: 8),
            "Reading the final unread message must remove the sidebar badge."
        )

        openSidebarTab("channels", in: context.app)
        let keepActivity = element(
            in: context.app,
            identifier: "channel.row.01H00000000000000000000001"
        )
        XCTAssertTrue(keepActivity.waitForExistence(timeout: 8))
        XCTAssertTrue(keepActivity.label.contains("1 条消息"))
        XCTAssertTrue(keepActivity.label.contains("0 条未读"))
        let keepLatestDate = ISO8601DateFormatter().date(from: "2026-01-15T08:01:00Z")!
        let keepLatestText = keepLatestDate.formatted(
            Date.FormatStyle(date: .abbreviated, time: .shortened)
                .locale(Locale(identifier: "zh_Hans_CN"))
        )
        XCTAssertTrue(
            keepActivity.label.contains(keepLatestText),
            "Reading messages must update the Channel row while retaining its latest canonical time."
        )
        element(in: context.app, identifier: "action.channels.add").click()
        let entryMode = element(in: context.app, identifier: "select.channels.entry.mode")
        XCTAssertTrue(entryMode.waitForExistence(timeout: 8))
        let subscribeMode = element(in: context.app, identifier: "mode.channels.entry.subscribe")
        XCTAssertTrue(subscribeMode.waitForExistence(timeout: 5))
        subscribeMode.click()
        let subscribedChannelID = "01H00000000000000000000004"
        let subscribeID = element(in: context.app, identifier: "field.channels.subscribe.id")
        let subscribePassword = element(in: context.app, identifier: "field.channels.subscribe.password")
        XCTAssertTrue(subscribeID.waitForExistence(timeout: 5))
        subscribeID.click()
        subscribeID.typeText(subscribedChannelID)
        XCTAssertTrue(subscribePassword.waitForExistence(timeout: 5))
        replaceSecureText(in: subscribePassword, with: "qualityx")
        let subscribeSubmit = element(
            in: context.app,
            identifier: "action.channels.entry.submit"
        )
        XCTAssertTrue(subscribeSubmit.waitForExistence(timeout: 5))
        subscribeSubmit.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        XCTAssertTrue(
            element(in: context.app, identifier: "channel.row.\(subscribedChannelID)")
                .waitForExistence(timeout: 8),
            "An accepted existing-channel subscription must enter the canonical Channel list"
        )

        element(in: context.app, identifier: "action.channels.add").click()
        let createName = element(in: context.app, identifier: "field.channels.create.name")
        let createPassword = element(in: context.app, identifier: "field.channels.create.password")
        XCTAssertTrue(createName.waitForExistence(timeout: 8))
        replaceTextUsingPasteboard(in: createName, with: "Quality Created Channel")
        XCTAssertTrue(createPassword.waitForExistence(timeout: 5))
        replaceSecureText(in: createPassword, with: "qualityx")
        element(in: context.app, identifier: "action.channels.entry.submit").click()

        let createdChannelID = "01H00000000000000000000003"
        let createdRow = element(
            in: context.app,
            identifier: "channel.row.\(createdChannelID)"
        )
        XCTAssertTrue(createdRow.waitForExistence(timeout: 8))
        XCTAssertTrue(
            createdRow.label.contains("Quality Created Channel"),
            "The created Channel row must expose the exact accepted name."
        )

        let createdMenu = element(
            in: context.app,
            identifier: "action.channel.\(createdChannelID).menu"
        )
        XCTAssertTrue(createdMenu.waitForExistence(timeout: 5) && createdMenu.isHittable)
        createdMenu.click()
        let renameAction = element(
            in: context.app,
            identifier: "action.channel.\(createdChannelID).rename"
        )
        XCTAssertTrue(renameAction.waitForExistence(timeout: 5))
        renameAction.click()
        let renameField = context.app.sheets.firstMatch.textFields.firstMatch
        XCTAssertTrue(renameField.waitForExistence(timeout: 5))
        replaceTextUsingPasteboard(in: renameField, with: "Quality Renamed Channel")
        renameField.typeKey(XCUIKeyboardKey.return, modifierFlags: [])
        XCTAssertTrue(
            waitForLabelContaining("Quality Renamed Channel", in: createdRow, timeout: 8),
            "The created Channel row must expose the exact accepted rename."
        )

        let keepChannelID = "01H00000000000000000000001"
        let keepRow = element(in: context.app, identifier: "channel.row.\(keepChannelID)")
        XCTAssertTrue(keepRow.waitForExistence(timeout: 8))
        let keepMenu = element(
            in: context.app,
            identifier: "action.channel.\(keepChannelID).menu"
        )
        XCTAssertTrue(keepMenu.waitForExistence(timeout: 5) && keepMenu.isHittable)
        keepMenu.click()
        let keepUnsubscribe = element(
            in: context.app,
            identifier: "action.channel.\(keepChannelID).unsubscribe"
        )
        XCTAssertTrue(keepUnsubscribe.waitForExistence(timeout: 5))
        keepUnsubscribe.click()
        let keepHistory = element(
            in: context.app,
            identifier: "action.channel.unsubscribe.keep_history"
        )
        XCTAssertTrue(keepHistory.waitForExistence(timeout: 5))
        keepHistory.click()
        XCTAssertTrue(
            keepRow.waitForNonExistence(timeout: 8),
            "Keep-history unsubscribe must remove only the subscription row."
        )

        let deleteChannelID = "01H00000000000000000000002"
        let deleteRow = element(in: context.app, identifier: "channel.row.\(deleteChannelID)")
        XCTAssertTrue(deleteRow.waitForExistence(timeout: 8))
        let deleteMenu = element(
            in: context.app,
            identifier: "action.channel.\(deleteChannelID).menu"
        )
        XCTAssertTrue(deleteMenu.waitForExistence(timeout: 5) && deleteMenu.isHittable)
        deleteMenu.click()
        let deleteUnsubscribe = element(
            in: context.app,
            identifier: "action.channel.\(deleteChannelID).unsubscribe"
        )
        XCTAssertTrue(deleteUnsubscribe.waitForExistence(timeout: 5))
        deleteUnsubscribe.click()
        let deleteHistory = element(
            in: context.app,
            identifier: "action.channel.unsubscribe.delete_history"
        )
        XCTAssertTrue(deleteHistory.waitForExistence(timeout: 5))
        deleteHistory.click()
        XCTAssertTrue(
            deleteRow.waitForNonExistence(timeout: 8),
            "Delete-history unsubscribe must immediately suppress the subscription row."
        )
        let pendingDeletion = element(in: context.app, identifier: "state.pending_deletion")
        XCTAssertTrue(pendingDeletion.waitForExistence(timeout: 5))
        XCTAssertTrue(
            pendingDeletion.waitForNonExistence(timeout: 15),
            "Delete-history unsubscribe must reach its production commit deadline."
        )

        openSidebarTab("messages", in: context.app)
        let keptMessage = element(
            in: context.app,
            identifier: "message.row.00000000-0000-0000-0000-00000000c001"
        )
        XCTAssertTrue(keptMessage.waitForExistence(timeout: 8))
        XCTAssertTrue(
            element(
                in: context.app,
                identifier: "message.row.00000000-0000-0000-0000-00000000c002"
            ).waitForNonExistence(timeout: 5),
            "Delete-history unsubscribe must remove the target history, not only its Channel row."
        )
        keptMessage.click()
        XCTAssertTrue(
            context.app.staticTexts[
                "Deterministic history owned by 01H00000000000000000000001."
            ].waitForExistence(timeout: 8),
            "Keep-history unsubscribe must preserve the accurate canonical message body."
        )

        context.app.terminate()
        let relaunched = configuredQualityApp(
            sessionID: sessionID,
            fixture: "channels.standard",
            channelMutationScenario: "accepted",
            allowCrossAppDataAccess: true
        )
        relaunched.app.launchArguments += [
            "-AppleLanguages", "(zh-Hans)",
            "-AppleLocale", "zh_CN",
        ]
        launchQuality(relaunched, sessionID: sessionID)
        XCTAssertFalse(
            relaunched.app.staticTexts["sidebar.messages.unread_badge"]
                .waitForExistence(timeout: 3),
            "The cleared sidebar badge must not return after process relaunch."
        )
        openSidebarTab("channels", in: relaunched.app)
        XCTAssertTrue(
            element(in: relaunched.app, identifier: "channel.row.\(subscribedChannelID)")
                .waitForExistence(timeout: 8),
            "The existing-channel subscription must survive process relaunch"
        )

        XCTAssertTrue(
            element(in: relaunched.app, identifier: "channel.row.\(createdChannelID)")
                .waitForExistence(timeout: 8),
            "The created Channel must survive process relaunch."
        )
        let relaunchedCreatedRow = element(
            in: relaunched.app,
            identifier: "channel.row.\(createdChannelID)"
        )
        XCTAssertTrue(
            waitForLabelContaining("Quality Renamed Channel", in: relaunchedCreatedRow, timeout: 8),
            "The accepted rename must survive process relaunch."
        )
        XCTAssertFalse(
            element(in: relaunched.app, identifier: "channel.row.\(keepChannelID)").exists,
            "The keep-history subscription must stay removed after relaunch."
        )
        XCTAssertFalse(
            element(in: relaunched.app, identifier: "channel.row.\(deleteChannelID)").exists,
            "The delete-history subscription must stay removed after relaunch."
        )

        let expectedChannelID = createdChannelID
        let row = element(in: relaunched.app, identifier: "channel.row.\(expectedChannelID)")
        XCTAssertTrue(row.waitForExistence(timeout: 8))

        let pasteboard = NSPasteboard.general
        let savedItems: [[NSPasteboard.PasteboardType: Data]] = pasteboard.pasteboardItems?.map { item in
            Dictionary(uniqueKeysWithValues: item.types.compactMap { type in
                item.data(forType: type).map { (type, $0) }
            })
        } ?? []
        defer {
            pasteboard.clearContents()
            let restoredItems = savedItems.map { representations in
                let item = NSPasteboardItem()
                for (type, data) in representations {
                    item.setData(data, forType: type)
                }
                return item
            }
            if !restoredItems.isEmpty {
                pasteboard.writeObjects(restoredItems)
            }
        }
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("pushgo-quality-copy-sentinel", forType: .string))
        row.click()
        XCTAssertTrue(
            element(in: relaunched.app, identifier: "feedback.toast.success")
                .waitForExistence(timeout: 2),
            "The Channel row did not report a successful system pasteboard write"
        )

        let copied = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                pasteboard.string(forType: .string) == expectedChannelID
            },
            object: nil
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [copied], timeout: 3),
            .completed,
            "Clicking the real Channel row did not put its exact ID on the system pasteboard"
        )

        openSidebarTab("messages", in: relaunched.app)
        let relaunchedKeptMessage = element(
            in: relaunched.app,
            identifier: "message.row.00000000-0000-0000-0000-00000000c001"
        )
        XCTAssertTrue(relaunchedKeptMessage.waitForExistence(timeout: 8))
        relaunchedKeptMessage.click()
        XCTAssertTrue(
            relaunched.app.staticTexts[
                "Deterministic history owned by 01H00000000000000000000001."
            ].waitForExistence(timeout: 8),
            "Keep-history data must retain its accurate body after process relaunch."
        )
        XCTAssertTrue(
            element(
                in: relaunched.app,
                identifier: "message.row.00000000-0000-0000-0000-00000000c002"
            ).waitForNonExistence(timeout: 5),
            "Committed delete-history data must not reappear after process relaunch."
        )
    }

    @MainActor
    func testMessageDeletionRestoresThenCommitsAccurateCanonicalStateAcrossRelaunch() {
        let sessionID = "macos-delete-lifecycle-\(UUID().uuidString.lowercased())"
        let context = configuredQualityApp(sessionID: sessionID, fixture: "channels.standard")
        launchQuality(context, sessionID: sessionID)

        let committedRow = element(
            in: context.app,
            identifier: "message.row.00000000-0000-0000-0000-00000000c002"
        )
        let restoredRow = element(
            in: context.app,
            identifier: "message.row.00000000-0000-0000-0000-00000000c001"
        )
        XCTAssertTrue(committedRow.waitForExistence(timeout: 8))
        XCTAssertTrue(restoredRow.exists, "The reversible control message must exist before deletion.")

        restoredRow.click()
        XCTAssertTrue(
            context.app.staticTexts[
                "Deterministic history owned by 01H00000000000000000000001."
            ].waitForExistence(timeout: 8),
            "The undo path must begin from the exact canonical control detail."
        )
        var delete = element(in: context.app, identifier: "action.message.delete")
        XCTAssertTrue(delete.waitForExistence(timeout: 8) && delete.isHittable)
        delete.click()
        XCTAssertTrue(
            restoredRow.waitForNonExistence(timeout: 2),
            "Scheduling the reversible deletion must immediately suppress its row."
        )
        var pending = element(in: context.app, identifier: "state.pending_deletion")
        XCTAssertTrue(pending.waitForExistence(timeout: 5))
        let undo = element(in: context.app, identifier: "action.pending_deletion.undo")
        XCTAssertTrue(undo.waitForExistence(timeout: 5) && undo.isHittable)
        undo.click()
        XCTAssertTrue(
            restoredRow.waitForExistence(timeout: 8),
            "Undo must restore the real row, not merely dismiss pending-deletion UI."
        )
        XCTAssertTrue(
            pending.waitForNonExistence(timeout: 5),
            "Undo must clear the production pending-deletion state."
        )
        restoredRow.click()
        XCTAssertTrue(
            context.app.staticTexts[
                "Deterministic history owned by 01H00000000000000000000001."
            ].waitForExistence(timeout: 8),
            "Undo must restore the exact canonical control content."
        )

        committedRow.click()
        XCTAssertTrue(
            context.app.staticTexts[
                "Deterministic history owned by 01H00000000000000000000002."
            ].waitForExistence(timeout: 8),
            "The committed path must begin from the exact target detail."
        )
        delete = element(in: context.app, identifier: "action.message.delete")
        XCTAssertTrue(delete.waitForExistence(timeout: 8) && delete.isHittable)
        delete.click()

        XCTAssertTrue(committedRow.waitForNonExistence(timeout: 2))
        pending = element(in: context.app, identifier: "state.pending_deletion")
        XCTAssertTrue(pending.waitForExistence(timeout: 5))
        XCTAssertTrue(
            element(in: context.app, identifier: "action.pending_deletion.undo").isHittable,
            "The journey must observe the real undo opportunity before allowing commit."
        )
        XCTAssertTrue(
            pending.waitForNonExistence(timeout: 15),
            "The production undo deadline did not commit and clear the pending deletion."
        )
        XCTAssertFalse(committedRow.exists, "The committed target must remain absent.")
        XCTAssertTrue(
            restoredRow.waitForExistence(timeout: 5),
            "Committing the target must preserve the previously restored control message."
        )
        restoredRow.click()
        XCTAssertTrue(
            context.app.staticTexts[
                "Deterministic history owned by 01H00000000000000000000001."
            ].waitForExistence(timeout: 8),
            "The control message must retain its exact canonical content."
        )

        context.app.terminate()
        let relaunched = configuredQualityApp(sessionID: sessionID, fixture: "channels.standard")
        launchQuality(relaunched, sessionID: sessionID)
        XCTAssertFalse(
            element(
                in: relaunched.app,
                identifier: "message.row.00000000-0000-0000-0000-00000000c002"
            ).exists,
            "A committed deletion must not revive after process relaunch."
        )
        let persistedRestoredRow = element(
            in: relaunched.app,
            identifier: "message.row.00000000-0000-0000-0000-00000000c001"
        )
        XCTAssertTrue(
            persistedRestoredRow.waitForExistence(timeout: 8),
            "The undone canonical message must survive the same process relaunch."
        )
        persistedRestoredRow.click()
        XCTAssertTrue(
            relaunched.app.staticTexts[
                "Deterministic history owned by 01H00000000000000000000001."
            ].exists
        )
    }

    @MainActor
    func testSlowMessageLoadWarnsBeforeDataCompletes() {
        let sessionID = "macos-slow-\(UUID().uuidString.lowercased())"
        let context = configuredQualityApp(
            sessionID: sessionID,
            fixture: "empty.clean",
            messageLoadDelayMilliseconds: 8_000
        )
        launch(context)

        XCTAssertTrue(
            element(in: context.app, identifier: "state.messages.loading.slow")
                .waitForExistence(timeout: 4),
            "A deliberately slow load must warn the user before completion."
        )
        XCTAssertTrue(
            element(in: context.app, identifier: "state.messages.empty")
                .waitForExistence(timeout: 10),
            "The delayed load did not complete into its accurate functional state."
        )
        XCTAssertFalse(element(in: context.app, identifier: "state.messages.load_failed").exists)
    }

    @MainActor
    func testMessageLoadFailureRetryRecoversToFunctionalState() {
        let sessionID = "macos-retry-\(UUID().uuidString.lowercased())"
        let context = configuredQualityApp(
            sessionID: sessionID,
            fixture: "empty.clean",
            failMessageLoad: true
        )
        launch(context)

        XCTAssertTrue(
            element(in: context.app, identifier: "state.messages.load_failed")
                .waitForExistence(timeout: 5),
            "The first controlled load failure must be visible to the user."
        )
        let retry = element(in: context.app, identifier: "action.messages.retry")
        XCTAssertTrue(
            retry.isHittable,
            "Retry must be a usable control, not a diagnostic marker."
        )
        retry.click()
        XCTAssertTrue(
            element(in: context.app, identifier: "state.messages.empty")
                .waitForExistence(timeout: 5),
            "Retry did not recover to the accurate functional empty state."
        )
        XCTAssertFalse(element(in: context.app, identifier: "state.messages.load_failed").exists)
    }

    @MainActor
    func testSlowMessageRefreshKeepsAccurateContentVisibleUntilCompletion() {
        let sessionID = "macos-refresh-slow-\(UUID().uuidString.lowercased())"
        let context = configuredQualityApp(
            sessionID: sessionID,
            fixture: "messages.standard",
            messageRefreshDelayMilliseconds: 2_500
        )
        launchQuality(context, sessionID: sessionID)

        let originalRow = element(
            in: context.app,
            identifier: "message.row.00000000-0000-0000-0000-000000000001"
        )
        XCTAssertTrue(originalRow.waitForExistence(timeout: 8))
        let refresh = element(in: context.app, identifier: "action.messages.refresh")
        XCTAssertTrue(refresh.waitForExistence(timeout: 5) && refresh.isHittable)
        refresh.click()

        XCTAssertTrue(originalRow.exists, "Refresh must not blank the last accurate snapshot.")
        XCTAssertTrue(
            element(in: context.app, identifier: "state.messages.refresh.slow")
                .waitForExistence(timeout: 2),
            "A slow refresh must become visible before the provider operation completes."
        )
        XCTAssertTrue(originalRow.exists, "Slow feedback must coexist with accurate existing data.")
        XCTAssertTrue(
            element(in: context.app, identifier: "state.messages.refresh.slow")
                .waitForNonExistence(timeout: 5),
            "Slow feedback must clear when refresh completes."
        )
        XCTAssertTrue(originalRow.exists, "Successful refresh must finish on accurate content.")
    }

    @MainActor
    func testMessageRefreshFailureKeepsSnapshotAndRetryPersistsAccurateResult() {
        let sessionID = "macos-refresh-recovery-\(UUID().uuidString.lowercased())"
        let context = configuredQualityApp(
            sessionID: sessionID,
            fixture: "messages.standard",
            messageRefreshScenario: "fail_once_then_new_message"
        )
        launchQuality(context, sessionID: sessionID)

        let originalRow = element(
            in: context.app,
            identifier: "message.row.00000000-0000-0000-0000-000000000001"
        )
        XCTAssertTrue(originalRow.waitForExistence(timeout: 8))
        let refresh = element(in: context.app, identifier: "action.messages.refresh")
        XCTAssertTrue(refresh.waitForExistence(timeout: 5) && refresh.isHittable)
        refresh.click()

        XCTAssertTrue(
            element(in: context.app, identifier: "state.messages.refresh.failed")
                .waitForExistence(timeout: 5),
            "The provider refresh failure must be visible on the Messages owner."
        )
        XCTAssertTrue(originalRow.exists, "A failed refresh must retain the last accurate snapshot.")
        XCTAssertTrue(refresh.isHittable, "The same real Refresh control must remain usable for retry.")
        refresh.click()

        let refreshedRow = context.app.buttons
            .matching(NSPredicate(format: "label CONTAINS %@", "P2 Refresh Result"))
            .firstMatch
        XCTAssertTrue(
            refreshedRow.waitForExistence(timeout: 8),
            "The successful retry did not render the newly persisted provider result."
        )
        XCTAssertTrue(originalRow.exists, "Retry must not replace an unrelated canonical message.")
        XCTAssertTrue(
            (refreshedRow.value as? String)?.contains(
                "Persisted through the provider refresh ingress path."
            ) == true,
            "The refreshed row did not expose the accurate persisted body."
        )
        XCTAssertTrue(
            element(in: context.app, identifier: "state.messages.refresh.failed")
                .waitForNonExistence(timeout: 5)
        )
        refreshedRow.click()
        XCTAssertTrue(
            context.app.staticTexts["Persisted through the provider refresh ingress path."]
                .waitForExistence(timeout: 5),
            "The refreshed row did not open its accurate real detail."
        )

        context.app.terminate()
        let relaunched = configuredQualityApp(
            sessionID: sessionID,
            fixture: "messages.standard",
            messageRefreshScenario: "fail_once_then_new_message"
        )
        launchQuality(relaunched, sessionID: sessionID)
        XCTAssertTrue(
            relaunched.app.buttons
                .matching(NSPredicate(format: "label CONTAINS %@", "P2 Refresh Result"))
                .firstMatch
                .waitForExistence(timeout: 8),
            "The provider refresh result did not survive a real process relaunch."
        )
    }

    @MainActor
    func testClosingMainWindowKeepsAppRunningAndStatusItemRestoresOneFunctionalWindow() {
        let sessionID = "macos-window-lifecycle-\(UUID().uuidString.lowercased())"
        let context = configuredQualityApp(
            sessionID: sessionID,
            fixture: "messages.standard",
            messageRefreshDelayMilliseconds: 2_500,
            messageRefreshScenario: "new_message"
        )
        context.app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        launchQuality(context, sessionID: sessionID)

        let originalRow = element(
            in: context.app,
            identifier: "message.row.00000000-0000-0000-0000-000000000001"
        )
        XCTAssertTrue(originalRow.waitForExistence(timeout: 8))
        let refresh = element(in: context.app, identifier: "action.messages.refresh")
        XCTAssertTrue(refresh.waitForExistence(timeout: 5) && refresh.isHittable)
        refresh.click()
        XCTAssertTrue(
            element(in: context.app, identifier: "state.messages.refresh.slow")
                .waitForExistence(timeout: 2),
            "The provider refresh must still be in flight when the main window closes."
        )
        XCTAssertTrue(originalRow.exists, "Closing begins from the last accurate snapshot.")

        let mainWindow = context.app.windows.firstMatch
        XCTAssertTrue(mainWindow.exists)
        let closeButton = mainWindow.buttons[XCUIIdentifierCloseWindow]
        XCTAssertTrue(closeButton.waitForExistence(timeout: 5))
        closeButton.click()

        XCTAssertTrue(
            waitForElementToDisappear(mainWindow, timeout: 8),
            "Closing the main window must hide it without terminating the status-item app."
        )
        XCTAssertNotEqual(
            context.app.state,
            .notRunning,
            "Closing the singleton window must not terminate the status-item app."
        )

        let statusItem = pushGoStatusItem(in: context.app)
        XCTAssertTrue(
            statusItem.waitForExistence(timeout: 8),
            "The app-owned status item must remain reachable after the main window closes."
        )
        statusItem.rightClick()
        let openMainWindow = context.app.menuItems["Open main window"]
        XCTAssertTrue(
            openMainWindow.waitForExistence(timeout: 5) && openMainWindow.isHittable,
            "The real status-item context menu must offer its localized main-window action."
        )
        openMainWindow.click()

        XCTAssertTrue(context.app.windows.firstMatch.waitForExistence(timeout: 10))
        XCTAssertEqual(
            context.app.windows.count,
            1,
            "The context-menu action must restore the unique main window."
        )
        XCTAssertTrue(element(in: context.app, identifier: "screen.messages.list").exists)
        let refreshedRow = context.app.buttons
            .matching(NSPredicate(format: "label CONTAINS %@", "P2 Refresh Result"))
            .firstMatch
        XCTAssertTrue(
            refreshedRow.waitForExistence(timeout: 8),
            "Closing the window must not cancel or lose an in-flight provider result."
        )
        XCTAssertTrue(
            (refreshedRow.value as? String)?.contains(
                "Persisted through the provider refresh ingress path."
            ) == true,
            "The restored window did not expose the accurate persisted provider body."
        )
        XCTAssertTrue(
            originalRow.waitForExistence(timeout: 5),
            "Receiving while the window is closed must not replace unrelated canonical data."
        )
        XCTAssertEqual(
            element(in: context.app, identifier: "quality-runtime.ready").value as? String,
            sessionID,
            "The restored window must still show the same App-owned session and Store state."
        )

        let restoredWindow = context.app.windows.firstMatch
        restoredWindow.buttons[XCUIIdentifierCloseWindow].click()
        XCTAssertTrue(
            waitForElementToDisappear(restoredWindow, timeout: 8),
            "The restored unique window must remain closable before testing the primary status-item action."
        )
        pushGoStatusItem(in: context.app).click()
        XCTAssertTrue(context.app.windows.firstMatch.waitForExistence(timeout: 10))
        XCTAssertEqual(context.app.windows.count, 1, "Left click must restore, not duplicate, the main window.")
        XCTAssertEqual(
            element(in: context.app, identifier: "quality-runtime.ready").value as? String,
            sessionID,
            "Both status-item entry points must preserve the same App-owned session."
        )
    }

    @MainActor
    func testSidebarNavigationCoversPrimaryScreens() throws {
        let sessionID = "macos-navigation-\(UUID().uuidString.lowercased())"
        let context = configuredQualityApp(sessionID: sessionID, fixture: "core.positive")
        context.app.launchArguments += [
            "-AppleLanguages", "(zh-Hans)",
            "-AppleLocale", "zh_CN",
        ]
        launchQuality(context, sessionID: sessionID)

        let messagesTitle = context.app.staticTexts["sidebar-messages"]
        let unreadBadge = context.app.staticTexts["sidebar.messages.unread_badge"]
        XCTAssertTrue(messagesTitle.waitForExistence(timeout: 8))
        XCTAssertTrue(unreadBadge.waitForExistence(timeout: 8))
        XCTAssertEqual(messagesTitle.value as? String, "消息")
        XCTAssertGreaterThan(
            Int(unreadBadge.value as? String ?? "") ?? 0,
            0,
            "The broad positive fixture must exercise navigation with a real unread count."
        )
        XCTAssertGreaterThanOrEqual(
            messagesTitle.frame.width,
            24,
            "The full two-glyph Messages title must remain visible when the unread badge is present."
        )
        XCTAssertGreaterThan(
            unreadBadge.frame.minX,
            messagesTitle.frame.maxX + 4,
            "The unread badge must not cover the Messages title."
        )
        XCTAssertTrue(
            hasReadableForegroundContrast(in: messagesTitle.screenshot()),
            "The selected Messages title must remain visibly readable."
        )

        context.app.open(
            try XCTUnwrap(
                URL(string: "pushgo://open?kind=message&id=00000000-0000-0000-0000-000000000001")
            )
        )
        assertVisibleScreenThroughUI("screen.message.detail", in: context.app, timeout: 8)
        XCTAssertTrue(
            context.app.staticTexts["Seeded from fixture.seed_messages for UI validation."]
                .waitForExistence(timeout: 5),
            "The registered macOS URL scheme must resolve the exact canonical Message."
        )
        context.app.open(try XCTUnwrap(URL(string: "pushgo://open?kind=event&id=list")))
        assertVisibleScreenThroughUI("screen.events.list", in: context.app, timeout: 8)
        context.app.open(try XCTUnwrap(URL(string: "pushgo://open?kind=thing&id=list")))
        assertVisibleScreenThroughUI("screen.things.list", in: context.app, timeout: 8)

        openSidebarTab("messages", in: context.app)
        assertVisibleScreenThroughUI("screen.messages.list", in: context.app, timeout: 8)
        XCTAssertTrue(
            element(
                in: context.app,
                identifier: "message.row.00000000-0000-0000-0000-000000000001"
            ).waitForExistence(timeout: 8),
            "The real Messages sidebar entry must return to the canonical list after system routing."
        )

        openSidebarTab("events", in: context.app)
        assertVisibleScreenThroughUI("screen.events.list", in: context.app, timeout: 8)
        let event = element(in: context.app, identifier: "event.row.quality-event-active")
        XCTAssertTrue(event.waitForExistence(timeout: 8))
        event.click()
        assertVisibleScreenThroughUI("screen.events.detail", in: context.app, timeout: 8)
        XCTAssertTrue(
            context.app.staticTexts["Event fixture for app-owned UI validation."]
                .waitForExistence(timeout: 5)
        )

        openSidebarTab("things", in: context.app)
        assertVisibleScreenThroughUI("screen.things.list", in: context.app, timeout: 8)
        let thing = element(in: context.app, identifier: "thing.row.quality-thing-rich")
        XCTAssertTrue(thing.waitForExistence(timeout: 8))
        thing.click()
        assertVisibleScreenThroughUI("screen.things.detail", in: context.app, timeout: 8)
        XCTAssertTrue(context.app.staticTexts["Fixture thing summary"].waitForExistence(timeout: 5))

        openSidebarTab("channels", in: context.app)
        assertVisibleScreenThroughUI("screen.channels", in: context.app, timeout: 8)
        let channel = element(
            in: context.app,
            identifier: "channel.row.01H00000000000000000000001"
        )
        XCTAssertTrue(channel.waitForExistence(timeout: 8))
        XCTAssertTrue(channel.label.contains("Quality Keep History"))

        openSidebarTab("settings", in: context.app)
        assertVisibleScreenThroughUI("screen.settings", in: context.app, timeout: 8)
    }

    @MainActor
    func testEventDetailCloseAndRelaunchPreserveAccurateProjection() {
        let sessionID = "macos-event-close-\(UUID().uuidString.lowercased())"
        let context = configuredQualityApp(
            sessionID: sessionID,
            fixture: "event.standard",
            eventCloseScenario: "accepted_and_delivered"
        )
        launchQuality(context, sessionID: sessionID)

        openSidebarTab("events", in: context.app)
        let eventRow = element(in: context.app, identifier: "event.row.quality-event-active")
        XCTAssertTrue(eventRow.waitForExistence(timeout: 8))
        XCTAssertTrue(
            (eventRow.label.contains("P2 Event Active"))
                && ((eventRow.value as? String)?.contains("Event fixture for app-owned UI validation.") == true),
            "The Event row must expose the accurate title and purpose-bearing summary."
        )
        eventRow.click()
        assertVisibleScreenThroughUI("screen.events.detail", in: context.app, timeout: 8)
        XCTAssertTrue(context.app.staticTexts["P2 Event Active"].waitForExistence(timeout: 5))
        XCTAssertTrue(
            context.app.staticTexts["Event fixture for app-owned UI validation."]
                .waitForExistence(timeout: 5)
        )

        let closeAction = element(in: context.app, identifier: "action.event.close")
        XCTAssertTrue(closeAction.waitForExistence(timeout: 5) && closeAction.isHittable)
        closeAction.click()
        let confirm = element(in: context.app, identifier: "action.event.close.confirm")
        XCTAssertTrue(confirm.waitForExistence(timeout: 5) && confirm.isHittable)
        confirm.click()
        XCTAssertTrue(
            element(in: context.app, identifier: "field.event.detail.status.closed")
                .waitForExistence(timeout: 12),
            "Closing succeeds only when the real projection becomes closed."
        )
        XCTAssertTrue(
            closeAction.waitForNonExistence(timeout: 5),
            "A closed Event must not continue to offer the close action."
        )

        context.app.terminate()
        let relaunched = configuredQualityApp(
            sessionID: sessionID,
            fixture: "event.standard",
            eventCloseScenario: "accepted_and_delivered"
        )
        launchQuality(relaunched, sessionID: sessionID)
        openSidebarTab("events", in: relaunched.app)
        let persistedRow = element(in: relaunched.app, identifier: "event.row.quality-event-active")
        XCTAssertTrue(persistedRow.waitForExistence(timeout: 8))
        persistedRow.click()
        XCTAssertTrue(
            element(in: relaunched.app, identifier: "field.event.detail.status.closed")
                .waitForExistence(timeout: 8),
            "The same Event must remain closed after a real process relaunch."
        )
        XCTAssertTrue(relaunched.app.staticTexts["P2 Event Active"].exists)
    }

    @MainActor
    func testEventCloseFailureKeepsAccurateDetailBlocksDuplicateAndRetryPersists() {
        let sessionID = "mac-event-close-retry-\(UUID().uuidString.lowercased())"
        let context = configuredQualityApp(
            sessionID: sessionID,
            fixture: "event.standard",
            eventCloseScenario: "fail_once_then_accepted_and_delivered"
        )
        launchQuality(context, sessionID: sessionID)

        openSidebarTab("events", in: context.app)
        let eventRow = element(in: context.app, identifier: "event.row.quality-event-active")
        XCTAssertTrue(eventRow.waitForExistence(timeout: 8))
        eventRow.click()
        assertVisibleScreenThroughUI("screen.events.detail", in: context.app, timeout: 8)
        XCTAssertTrue(context.app.staticTexts["P2 Event Active"].waitForExistence(timeout: 5))
        XCTAssertTrue(
            context.app.staticTexts["Event fixture for app-owned UI validation."].waitForExistence(timeout: 5)
        )

        func confirmClose() {
            let closeAction = element(in: context.app, identifier: "action.event.close")
            XCTAssertTrue(closeAction.waitForExistence(timeout: 5) && closeAction.isHittable)
            closeAction.click()
            let confirm = element(in: context.app, identifier: "action.event.close.confirm")
            XCTAssertTrue(confirm.waitForExistence(timeout: 5) && confirm.isHittable)
            confirm.click()
        }

        confirmClose()
        let closing = element(in: context.app, identifier: "state.event.close.in_progress")
        XCTAssertTrue(closing.waitForExistence(timeout: 2), "A slow close must expose visible progress.")
        XCTAssertFalse(
            element(in: context.app, identifier: "action.event.close").exists,
            "A close already in flight must not allow a duplicate submission."
        )
        XCTAssertTrue(context.app.staticTexts["P2 Event Active"].exists)
        XCTAssertTrue(
            element(in: context.app, identifier: "feedback.event.close").waitForExistence(timeout: 5),
            "The first boundary failure must remain owned by the Event detail."
        )
        XCTAssertTrue(
            element(in: context.app, identifier: "field.event.detail.status.ongoing").exists,
            "A failed close must preserve the canonical ongoing state."
        )

        confirmClose()
        XCTAssertTrue(closing.waitForExistence(timeout: 2))
        XCTAssertFalse(element(in: context.app, identifier: "action.event.close").exists)
        XCTAssertTrue(
            element(in: context.app, identifier: "field.event.detail.status.closed")
                .waitForExistence(timeout: 12),
            "Retry succeeds only after the production-shaped delivery updates the canonical projection."
        )

        context.app.terminate()
        let relaunched = configuredQualityApp(
            sessionID: sessionID,
            fixture: "event.standard",
            eventCloseScenario: "fail_once_then_accepted_and_delivered"
        )
        launchQuality(relaunched, sessionID: sessionID)
        openSidebarTab("events", in: relaunched.app)
        let persistedRow = element(in: relaunched.app, identifier: "event.row.quality-event-active")
        XCTAssertTrue(persistedRow.waitForExistence(timeout: 8))
        persistedRow.click()
        XCTAssertTrue(
            element(in: relaunched.app, identifier: "field.event.detail.status.closed")
                .waitForExistence(timeout: 8)
        )
        XCTAssertFalse(element(in: relaunched.app, identifier: "action.event.close").exists)
    }

    @MainActor
    func testThingRelationsOpenAccurateDetailsAndSurviveRelaunch() {
        let sessionID = "macos-thing-relations-\(UUID().uuidString.lowercased())"
        let context = configuredQualityApp(sessionID: sessionID, fixture: "thing.standard")
        launchQuality(context, sessionID: sessionID)

        openSidebarTab("things", in: context.app)
        let thingRow = element(in: context.app, identifier: "thing.row.quality-thing-rich")
        XCTAssertTrue(thingRow.waitForExistence(timeout: 8))
        let distractorRow = element(
            in: context.app,
            identifier: "thing.row.quality-thing-distractor"
        )
        XCTAssertTrue(distractorRow.waitForExistence(timeout: 8))
        distractorRow.click()
        let deleteThing = element(in: context.app, identifier: "action.thing.delete")
        XCTAssertTrue(deleteThing.waitForExistence(timeout: 8) && deleteThing.isHittable)
        deleteThing.click()
        XCTAssertTrue(
            distractorRow.waitForNonExistence(timeout: 8),
            "Deleting one Thing must immediately remove only that target from the user-visible list."
        )
        XCTAssertTrue(thingRow.waitForExistence(timeout: 8))
        let pendingThingDeletion = element(in: context.app, identifier: "state.pending_deletion")
        XCTAssertTrue(pendingThingDeletion.waitForExistence(timeout: 5))
        XCTAssertTrue(
            pendingThingDeletion.waitForNonExistence(timeout: 15),
            "The production undo deadline must commit before the journey continues."
        )

        context.app.terminate()
        launchQuality(context, sessionID: sessionID)
        openSidebarTab("things", in: context.app)
        XCTAssertTrue(
            distractorRow.waitForNonExistence(timeout: 8),
            "The deleted Thing must not return after the production deadline commits and the App relaunches."
        )
        XCTAssertTrue(
            thingRow.waitForExistence(timeout: 8),
            "Deleting one Thing must preserve the independent control Thing across relaunch."
        )
        let searchField = context.app.searchFields.firstMatch
        XCTAssertTrue(searchField.waitForExistence(timeout: 8))
        searchField.click()
        searchField.typeText("thing-rich")
        searchField.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(thingRow.waitForExistence(timeout: 5))
        XCTAssertTrue(
            distractorRow.waitForNonExistence(timeout: 5),
            "Thing search must keep the exact target while excluding a real distractor."
        )
        XCTAssertTrue(thingRow.label.contains("P2 Thing Rich"))
        thingRow.click()
        assertVisibleScreenThroughUI("screen.things.detail", in: context.app, timeout: 8)
        let identity = element(in: context.app, identifier: "field.thing.detail.identity")
        XCTAssertTrue(identity.waitForExistence(timeout: 5))
        XCTAssertTrue(
            identity.label.contains("P2 Thing Rich")
                && identity.label.localizedCaseInsensitiveContains("active")
                && identity.label.localizedCaseInsensitiveContains("quality"),
            "The Thing identity region must expose the accurate title, lifecycle state, and channel."
        )
        let summary = element(in: context.app, identifier: "field.thing.detail.summary")
        XCTAssertTrue(summary.waitForExistence(timeout: 5))
        XCTAssertTrue(
            summary.label.contains("Fixture thing summary")
                || (summary.value as? String)?.contains("Fixture thing summary") == true,
            "The Thing detail must expose its accurate purpose-bearing summary."
        )

        let relatedEvent = element(
            in: context.app,
            identifier: "thing.related.event.quality-related-event"
        )
        XCTAssertTrue(relatedEvent.waitForExistence(timeout: 8) && relatedEvent.isHittable)
        relatedEvent.click()
        assertVisibleScreenThroughUI("screen.events.detail", in: context.app, timeout: 8)
        XCTAssertTrue(context.app.staticTexts["Quality Related Event"].waitForExistence(timeout: 5))
        let relatedEventSummary = element(in: context.app, identifier: "field.event.detail.summary")
        XCTAssertTrue(relatedEventSummary.waitForExistence(timeout: 5))
        XCTAssertTrue(
            relatedEventSummary.label.contains("A deterministic event associated with P2 Thing Rich.")
                || (relatedEventSummary.value as? String)?
                    .contains("A deterministic event associated with P2 Thing Rich.") == true,
            "The related Event must display the canonical notification body as its accurate summary."
        )
        element(in: context.app, identifier: "action.thing.related.close").click()

        let messagesTab = element(in: context.app, identifier: "tab.thing.detail.messages")
        XCTAssertTrue(messagesTab.waitForExistence(timeout: 5) && messagesTab.isHittable)
        messagesTab.click()
        let relatedMessage = element(
            in: context.app,
            identifier: "thing.related.message.quality-related-message"
        )
        XCTAssertTrue(relatedMessage.waitForExistence(timeout: 8) && relatedMessage.isHittable)
        relatedMessage.click()
        assertVisibleScreenThroughUI("screen.message.detail", in: context.app, timeout: 8)
        XCTAssertTrue(context.app.staticTexts["Quality Related Message"].waitForExistence(timeout: 5))
        XCTAssertTrue(
            context.app.staticTexts["The linked Thing message opens its canonical detail."]
                .waitForExistence(timeout: 5)
        )
        element(in: context.app, identifier: "action.thing.related.close").click()
        XCTAssertTrue(relatedMessage.waitForExistence(timeout: 5))

        let updatesTab = element(in: context.app, identifier: "tab.thing.detail.updates")
        XCTAssertTrue(updatesTab.waitForExistence(timeout: 5) && updatesTab.isHittable)
        updatesTab.click()
        let relatedUpdate = element(
            in: context.app,
            identifier: "thing.related.update.00000000-0000-0000-0000-00000000a000"
        )
        XCTAssertTrue(relatedUpdate.waitForExistence(timeout: 8) && relatedUpdate.isHittable)
        relatedUpdate.click()
        assertVisibleScreenThroughUI("screen.thing.update.detail", in: context.app, timeout: 8)
        XCTAssertTrue(
            context.app.staticTexts["Quality Initial Thing Snapshot"].waitForExistence(timeout: 5)
        )
        element(in: context.app, identifier: "action.thing.related.close").click()

    }

    @MainActor
    func legacyDiagnosticAutomationRequestCanOpenChannelsScreen() {
        let context = configuredApp(
            requestName: "nav.switch_tab",
            args: ["tab": "channels"]
        )
        launch(context)

        assertVisibleScreen("screen.channels", in: context)
        XCTAssertTrue(element(in: context.app, identifier: "screen.channels").waitForExistence(timeout: 8))
    }

    @MainActor
    func legacyDiagnosticImportedEventFixtureCanOpenEventDetailFromStartupRequest() {
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
    func legacyDiagnosticImportedThingFixtureCanOpenThingDetailFromStartupRequest() {
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
    // Superseded by the purpose-level decryption lifecycle and encrypted-message journeys.
    func legacyDiagnosticSettingsSidebarCanOpenDecryptionOverlay() {
        let sessionID = "macos-decryption-overlay-\(UUID().uuidString.lowercased())"
        let context = configuredQualityApp(sessionID: sessionID, fixture: "empty.clean")
        launchQuality(context, sessionID: sessionID)

        openSidebarTab("settings", in: context.app)
        assertVisibleScreenThroughUI("screen.settings", in: context.app)

        let decryptionButton = element(in: context.app, identifier: "action.settings.open_decryption")
        XCTAssertTrue(decryptionButton.waitForExistence(timeout: 10))
        decryptionButton.click()
        assertVisibleScreenThroughUI("screen.settings.decryption", in: context.app)
    }

    @MainActor
    func testSettingsDecryptionRejectsInvalidKeyPersistsAndClearsValidKey() {
        let sessionID = "macos-decryption-life-\(UUID().uuidString.lowercased())"
        let context = configuredQualityApp(sessionID: sessionID, fixture: "messages.standard")
        launchQuality(context, sessionID: sessionID)

        openSidebarTab("settings", in: context.app)
        let initialAction = element(in: context.app, identifier: "action.settings.open_decryption")
        XCTAssertTrue(initialAction.waitForExistence(timeout: 8) && initialAction.isHittable)
        let initialLabel = initialAction.label
        initialAction.click()

        let keyField = element(in: context.app, identifier: "field.settings.decryption.key")
        XCTAssertTrue(keyField.waitForExistence(timeout: 8))
        replaceSecureText(in: keyField, with: "short")
        element(in: context.app, identifier: "action.settings.decryption.save").click()
        XCTAssertTrue(
            element(in: context.app, identifier: "feedback.settings.decryption")
                .waitForExistence(timeout: 5),
            "An invalid key must remain actionable inside the decryption sheet."
        )
        XCTAssertTrue(keyField.exists, "Invalid input must not dismiss its owning editor.")
        XCTAssertFalse(element(in: context.app, identifier: "feedback.settings.root").exists)

        let validKey = String(repeating: "k", count: 32)
        replaceSecureText(in: keyField, with: validKey)
        element(in: context.app, identifier: "action.settings.decryption.save").click()
        XCTAssertTrue(
            keyField.waitForNonExistence(timeout: 8),
            "A valid key may dismiss only after protected persistence succeeds."
        )
        let configuredAction = element(in: context.app, identifier: "action.settings.open_decryption")
        XCTAssertTrue(configuredAction.waitForExistence(timeout: 8))
        let configuredLabel = configuredAction.label
        XCTAssertNotEqual(configuredLabel, initialLabel)

        context.app.terminate()
        let restored = configuredQualityApp(sessionID: sessionID, fixture: "messages.standard")
        launchQuality(restored, sessionID: sessionID)
        openSidebarTab("settings", in: restored.app)
        let restoredAction = element(in: restored.app, identifier: "action.settings.open_decryption")
        XCTAssertTrue(restoredAction.waitForExistence(timeout: 8))
        XCTAssertEqual(restoredAction.label, configuredLabel)
        restoredAction.click()
        let restoredField = element(in: restored.app, identifier: "field.settings.decryption.key")
        XCTAssertTrue(restoredField.waitForExistence(timeout: 8))
        XCTAssertNotEqual(
            restoredField.value as? String,
            validKey,
            "Persisted secret material must never be echoed back into the UI."
        )
        element(in: restored.app, identifier: "action.settings.decryption.save").click()
        XCTAssertTrue(restoredField.waitForNonExistence(timeout: 8))
        XCTAssertEqual(
            element(in: restored.app, identifier: "action.settings.open_decryption").label,
            configuredLabel,
            "Blank Save must preserve the already configured material."
        )

        restored.app.terminate()
        let beforeClear = configuredQualityApp(sessionID: sessionID, fixture: "messages.standard")
        launchQuality(beforeClear, sessionID: sessionID)
        openSidebarTab("settings", in: beforeClear.app)
        let beforeClearAction = element(
            in: beforeClear.app,
            identifier: "action.settings.open_decryption"
        )
        XCTAssertEqual(beforeClearAction.label, configuredLabel)
        beforeClearAction.click()
        let clearAction = element(in: beforeClear.app, identifier: "action.settings.decryption.clear")
        XCTAssertTrue(clearAction.waitForExistence(timeout: 8) && clearAction.isHittable)
        clearAction.click()
        XCTAssertTrue(clearAction.waitForNonExistence(timeout: 8))
        XCTAssertEqual(
            element(in: beforeClear.app, identifier: "action.settings.open_decryption").label,
            initialLabel,
            "Explicit Delete must restore the visible not-configured state."
        )

        beforeClear.app.terminate()
        let cleared = configuredQualityApp(sessionID: sessionID, fixture: "messages.standard")
        launchQuality(cleared, sessionID: sessionID)
        openSidebarTab("settings", in: cleared.app)
        XCTAssertEqual(
            element(in: cleared.app, identifier: "action.settings.open_decryption").label,
            initialLabel,
            "Deleted material must remain absent after a full process relaunch."
        )
    }

    @MainActor
    func testDecryptionProtectedStoreFailureDoesNotConfigureBeforeRetry() {
        let sessionID = "macos-decryption-store-\(UUID().uuidString.lowercased())"
        let failing = configuredQualityApp(
            sessionID: sessionID,
            fixture: "messages.standard",
            failNotificationMaterialPersistenceOnce: true
        )
        launchQuality(failing, sessionID: sessionID)
        openSidebarTab("settings", in: failing.app)
        let initialAction = element(in: failing.app, identifier: "action.settings.open_decryption")
        XCTAssertTrue(initialAction.waitForExistence(timeout: 8))
        let initialLabel = initialAction.label
        initialAction.click()
        let field = element(in: failing.app, identifier: "field.settings.decryption.key")
        XCTAssertTrue(field.waitForExistence(timeout: 8))
        replaceSecureText(in: field, with: String(repeating: "p", count: 32))
        element(in: failing.app, identifier: "action.settings.decryption.save").click()
        XCTAssertTrue(
            element(in: failing.app, identifier: "feedback.settings.decryption")
                .waitForExistence(timeout: 8),
            "Protected-store failure must be owned by the decryption sheet."
        )
        XCTAssertTrue(field.exists, "Failed secret persistence must keep the editor open.")
        XCTAssertFalse(element(in: failing.app, identifier: "feedback.settings.root").exists)

        failing.app.terminate()
        let retry = configuredQualityApp(sessionID: sessionID, fixture: "messages.standard")
        launchQuality(retry, sessionID: sessionID)
        openSidebarTab("settings", in: retry.app)
        let retryAction = element(in: retry.app, identifier: "action.settings.open_decryption")
        XCTAssertTrue(retryAction.waitForExistence(timeout: 8))
        XCTAssertEqual(
            retryAction.label,
            initialLabel,
            "A failed protected write must remain unconfigured after restart."
        )
        retryAction.click()
        let retryField = element(in: retry.app, identifier: "field.settings.decryption.key")
        XCTAssertTrue(retryField.waitForExistence(timeout: 8))
        replaceSecureText(in: retryField, with: String(repeating: "p", count: 32))
        element(in: retry.app, identifier: "action.settings.decryption.save").click()
        XCTAssertTrue(retryField.waitForNonExistence(timeout: 8))
        XCTAssertNotEqual(
            element(in: retry.app, identifier: "action.settings.open_decryption").label,
            initialLabel,
            "Only a successful retry may expose configured state."
        )
    }

    @MainActor
    func testEncryptedMessageWrongKeyThenCorrectKeyRecoversAndSurvivesRelaunch() {
        let sessionID = "macos-encrypted-recovery-\(UUID().uuidString.lowercased())"
        let context = configuredQualityApp(
            sessionID: sessionID,
            fixture: "messages.encrypted.valid"
        )
        launchQuality(context, sessionID: sessionID)

        var encryptedRow = messageRow(containing: "Encrypted Quality Message", in: context.app)
        XCTAssertTrue(encryptedRow.waitForExistence(timeout: 8))
        encryptedRow.click()
        assertVisibleScreenThroughUI("screen.message.detail", in: context.app, timeout: 8)
        XCTAssertTrue(context.app.staticTexts["Configure decryption to read this message."].exists)

        openSidebarTab("settings", in: context.app)
        openDecryptionEditor(in: context.app)
        let wrongKeyField = element(in: context.app, identifier: "field.settings.decryption.key")
        replaceSecureText(in: wrongKeyField, with: String(repeating: "Z", count: 16))
        element(in: context.app, identifier: "action.settings.decryption.save").click()
        XCTAssertTrue(wrongKeyField.waitForNonExistence(timeout: 8))

        openSidebarTab("messages", in: context.app)
        encryptedRow = messageRow(containing: "Encrypted Quality Message", in: context.app)
        XCTAssertTrue(encryptedRow.waitForExistence(timeout: 8))
        XCTAssertFalse(messageRow(containing: "Recovered Quality Message", in: context.app).exists)
        encryptedRow.click()
        XCTAssertTrue(
            context.app.staticTexts["Configure decryption to read this message."].exists,
            "A wrong but valid-length key must preserve the safe original fallback."
        )
        XCTAssertFalse(context.app.staticTexts["Recovered from the original encrypted payload."].exists)

        openSidebarTab("settings", in: context.app)
        openDecryptionEditor(in: context.app)
        let correctKeyField = element(in: context.app, identifier: "field.settings.decryption.key")
        replaceSecureText(in: correctKeyField, with: "QualityKey123456")
        element(in: context.app, identifier: "action.settings.decryption.save").click()
        XCTAssertTrue(correctKeyField.waitForNonExistence(timeout: 8))

        openSidebarTab("messages", in: context.app)
        let recoveredRow = messageRow(containing: "Recovered Quality Message", in: context.app)
        XCTAssertTrue(
            recoveredRow.waitForExistence(timeout: 8),
            "The original canonical message must become readable after saving its matching key."
        )
        XCTAssertTrue(
            (recoveredRow.value as? String)?
                .contains("Recovered from the original encrypted payload.") == true
        )
        XCTAssertFalse(messageRow(containing: "Encrypted Quality Message", in: context.app).exists)
        recoveredRow.click()
        XCTAssertTrue(
            context.app.staticTexts["Recovered from the original encrypted payload."]
                .waitForExistence(timeout: 8)
        )

        context.app.terminate()
        let relaunched = configuredQualityApp(
            sessionID: sessionID,
            fixture: "messages.encrypted.valid"
        )
        launchQuality(relaunched, sessionID: sessionID)
        let persistedRow = messageRow(containing: "Recovered Quality Message", in: relaunched.app)
        XCTAssertTrue(persistedRow.waitForExistence(timeout: 8))
        persistedRow.click()
        XCTAssertTrue(
            relaunched.app.staticTexts["Recovered from the original encrypted payload."].exists,
            "Recovered plaintext must survive a full process relaunch."
        )
    }

    @MainActor
    func testCorruptEncryptedMessageFailsSafelyAndSurvivesRelaunch() {
        let sessionID = "macos-encrypted-corrupt-\(UUID().uuidString.lowercased())"
        let context = configuredQualityApp(
            sessionID: sessionID,
            fixture: "messages.encrypted.corrupt"
        )
        launchQuality(context, sessionID: sessionID)

        var corruptRow = messageRow(containing: "Corrupt Encrypted Message", in: context.app)
        XCTAssertTrue(corruptRow.waitForExistence(timeout: 8))
        corruptRow.click()
        XCTAssertTrue(context.app.staticTexts["Configure decryption to read this message."].exists)
        openSidebarTab("settings", in: context.app)
        openDecryptionEditor(in: context.app)
        let field = element(in: context.app, identifier: "field.settings.decryption.key")
        replaceSecureText(in: field, with: "QualityKey123456")
        element(in: context.app, identifier: "action.settings.decryption.save").click()
        XCTAssertTrue(field.waitForNonExistence(timeout: 8))

        openSidebarTab("messages", in: context.app)
        corruptRow = messageRow(containing: "Corrupt Encrypted Message", in: context.app)
        XCTAssertTrue(corruptRow.waitForExistence(timeout: 8))
        XCTAssertFalse(messageRow(containing: "Recovered Quality Message", in: context.app).exists)
        corruptRow.click()
        XCTAssertTrue(
            context.app.staticTexts["Configure decryption to read this message."].exists,
            "Authenticated corrupt ciphertext must retain the safe fallback."
        )
        XCTAssertFalse(context.app.staticTexts["Recovered from the original encrypted payload."].exists)

        context.app.terminate()
        let relaunched = configuredQualityApp(
            sessionID: sessionID,
            fixture: "messages.encrypted.corrupt"
        )
        launchQuality(relaunched, sessionID: sessionID)
        let persistedCorrupt = messageRow(
            containing: "Corrupt Encrypted Message",
            in: relaunched.app
        )
        XCTAssertTrue(persistedCorrupt.waitForExistence(timeout: 8))
        persistedCorrupt.click()
        XCTAssertTrue(relaunched.app.staticTexts["Configure decryption to read this message."].exists)
        XCTAssertFalse(relaunched.app.staticTexts["Recovered from the original encrypted payload."].exists)
    }

    @MainActor
    func testSettingsPageVisibilityUsesRealControlsAndPersistsAcrossRelaunch() {
        let sessionID = "macos-settings-visibility-\(UUID().uuidString.lowercased())"
        let context = configuredQualityApp(sessionID: sessionID, fixture: "messages.standard")
        context.app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        launchQuality(context, sessionID: sessionID)

        let messagesEntry = element(in: context.app, identifier: "sidebar-messages")
        let eventsEntry = element(in: context.app, identifier: "sidebar-events")
        let thingsEntry = element(in: context.app, identifier: "sidebar-things")
        XCTAssertTrue(messagesEntry.waitForExistence(timeout: 8))
        XCTAssertTrue(eventsEntry.waitForExistence(timeout: 8))
        XCTAssertTrue(thingsEntry.waitForExistence(timeout: 8))
        openSidebarTab("events", in: context.app)
        assertVisibleScreenThroughUI("screen.events.list", in: context.app, timeout: 8)

        openSidebarTab("settings", in: context.app)
        let soundSettingsAction = element(
            in: context.app,
            identifier: "action.settings.notification_sounds"
        )
        XCTAssertTrue(
            soundSettingsAction.waitForExistence(timeout: 8) && soundSettingsAction.isHittable,
            "Notification sounds must be reachable through the real macOS Settings action."
        )
        soundSettingsAction.click()
        let lowPrioritySound = element(
            in: context.app,
            identifier: "picker.settings.notification_sounds.low"
        )
        XCTAssertTrue(
            lowPrioritySound.waitForExistence(timeout: 8),
            "The real notification-sound editor must expose the low-priority setting."
        )
        XCTAssertFalse(
            (lowPrioritySound.value as? String ?? "").isEmpty,
            "The notification-sound editor must project the currently selected value."
        )
        let closeSoundSettings = element(
            in: context.app,
            identifier: "action.settings.notification_sounds.close"
        )
        XCTAssertTrue(closeSoundSettings.waitForExistence(timeout: 8) && closeSoundSettings.isHittable)
        closeSoundSettings.click()
        XCTAssertTrue(
            closeSoundSettings.waitForNonExistence(timeout: 8),
            "Closing notification-sound settings must reliably return to the Settings page."
        )

        let messageToggle = element(in: context.app, identifier: "toggle.settings.page.messages")
        XCTAssertTrue(messageToggle.waitForExistence(timeout: 8) && messageToggle.isHittable)
        messageToggle.click()
        let eventToggle = element(in: context.app, identifier: "toggle.settings.page.events")
        XCTAssertTrue(eventToggle.waitForExistence(timeout: 8) && eventToggle.isHittable)
        eventToggle.click()
        let thingToggle = element(in: context.app, identifier: "toggle.settings.page.things")
        XCTAssertTrue(thingToggle.waitForExistence(timeout: 8) && thingToggle.isHittable)
        thingToggle.click()
        XCTAssertTrue(
            messagesEntry.waitForNonExistence(timeout: 8),
            "Turning off the Messages page must remove its real navigation destination."
        )
        XCTAssertTrue(
            eventsEntry.waitForNonExistence(timeout: 8),
            "Turning off the Event page must remove its real navigation destination."
        )
        XCTAssertTrue(
            thingsEntry.waitForNonExistence(timeout: 8),
            "Turning off the Thing page must remove its real navigation destination."
        )
        openSidebarTab("channels", in: context.app)
        assertVisibleScreenThroughUI("screen.channels", in: context.app, timeout: 8)

        context.app.terminate()
        let persistedOff = configuredQualityApp(sessionID: sessionID, fixture: "messages.standard")
        persistedOff.app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        launchQuality(persistedOff, sessionID: sessionID)
        XCTAssertTrue(
            element(in: persistedOff.app, identifier: "sidebar-messages")
                .waitForNonExistence(timeout: 8),
            "The hidden Messages page must remain hidden after a full process relaunch."
        )
        XCTAssertTrue(
            element(in: persistedOff.app, identifier: "sidebar-events")
                .waitForNonExistence(timeout: 8),
            "The hidden Event page must remain hidden after a full process relaunch."
        )
        XCTAssertTrue(
            element(in: persistedOff.app, identifier: "sidebar-things")
                .waitForNonExistence(timeout: 8),
            "The hidden Thing page must remain hidden after a full process relaunch."
        )
        openSidebarTab("settings", in: persistedOff.app)
        let persistedOffMessageToggle = element(
            in: persistedOff.app,
            identifier: "toggle.settings.page.messages"
        )
        XCTAssertTrue(
            persistedOffMessageToggle.waitForExistence(timeout: 8)
                && persistedOffMessageToggle.isHittable
        )
        persistedOffMessageToggle.click()
        let persistedOffToggle = element(
            in: persistedOff.app,
            identifier: "toggle.settings.page.events"
        )
        XCTAssertTrue(persistedOffToggle.waitForExistence(timeout: 8) && persistedOffToggle.isHittable)
        persistedOffToggle.click()
        let persistedOffThingToggle = element(
            in: persistedOff.app,
            identifier: "toggle.settings.page.things"
        )
        XCTAssertTrue(
            persistedOffThingToggle.waitForExistence(timeout: 8) && persistedOffThingToggle.isHittable
        )
        persistedOffThingToggle.click()

        let restoredMessagesEntry = element(in: persistedOff.app, identifier: "sidebar-messages")
        XCTAssertTrue(
            restoredMessagesEntry.waitForExistence(timeout: 8),
            "Turning the Messages page back on must restore a reachable navigation destination."
        )
        openSidebarTab("messages", in: persistedOff.app)
        assertVisibleScreenThroughUI("screen.messages.list", in: persistedOff.app, timeout: 8)
        let restoredMessageRow = messageRow(
            containing: "P2 Split Seed Message",
            in: persistedOff.app
        )
        XCTAssertTrue(
            restoredMessageRow.waitForExistence(timeout: 8)
                && restoredMessageRow.label.contains("P2 Split Seed Message")
                && ((restoredMessageRow.value as? String)?.contains(
                    "Seeded from fixture.seed_messages for UI validation."
                ) == true),
            "The restored Messages destination must show the accurate App-owned fixture."
        )
        restoredMessageRow.click()
        assertVisibleScreenThroughUI("screen.message.detail", in: persistedOff.app, timeout: 8)
        XCTAssertTrue(
            persistedOff.app.staticTexts[
                "Seeded from fixture.seed_messages for UI validation."
            ].waitForExistence(timeout: 8)
        )
        let restoredEventsEntry = element(in: persistedOff.app, identifier: "sidebar-events")
        XCTAssertTrue(
            restoredEventsEntry.waitForExistence(timeout: 8),
            "Turning the Event page back on must restore a reachable navigation destination."
        )
        openSidebarTab("events", in: persistedOff.app)
        assertVisibleScreenThroughUI("screen.events.list", in: persistedOff.app, timeout: 8)
        XCTAssertTrue(persistedOff.app.staticTexts["No events yet"].waitForExistence(timeout: 8))
        let restoredThingsEntry = element(in: persistedOff.app, identifier: "sidebar-things")
        XCTAssertTrue(
            restoredThingsEntry.waitForExistence(timeout: 8),
            "Turning the Thing page back on must restore a reachable navigation destination."
        )
        openSidebarTab("things", in: persistedOff.app)
        assertVisibleScreenThroughUI("screen.things.list", in: persistedOff.app, timeout: 8)
        XCTAssertTrue(persistedOff.app.staticTexts["No objects yet"].waitForExistence(timeout: 8))

        persistedOff.app.terminate()
        let persistedOn = configuredQualityApp(sessionID: sessionID, fixture: "messages.standard")
        persistedOn.app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        launchQuality(persistedOn, sessionID: sessionID)
        openSidebarTab("messages", in: persistedOn.app)
        assertVisibleScreenThroughUI("screen.messages.list", in: persistedOn.app, timeout: 8)
        let persistedMessageRow = messageRow(containing: "P2 Split Seed Message", in: persistedOn.app)
        XCTAssertTrue(
            persistedMessageRow.waitForExistence(timeout: 8)
                && persistedMessageRow.label.contains("P2 Split Seed Message")
                && ((persistedMessageRow.value as? String)?.contains(
                    "Seeded from fixture.seed_messages for UI validation."
                ) == true)
        )
        openSidebarTab("events", in: persistedOn.app)
        assertVisibleScreenThroughUI("screen.events.list", in: persistedOn.app, timeout: 8)
        XCTAssertTrue(persistedOn.app.staticTexts["No events yet"].waitForExistence(timeout: 8))
        openSidebarTab("things", in: persistedOn.app)
        assertVisibleScreenThroughUI("screen.things.list", in: persistedOn.app, timeout: 8)
        XCTAssertTrue(persistedOn.app.staticTexts["No objects yet"].waitForExistence(timeout: 8))
    }

    @MainActor
    func legacyDiagnosticSettingsScreenControlMatrixShowsCriticalGroups() {
        let context = configuredApp()
        launch(context)

        openSidebarTab("settings", in: context.app)
        assertVisibleScreen("screen.settings", in: context)
        assertElementExists("action.settings.server_management", in: context.app)
        assertElementExists("group.settings.page_visibility", in: context.app)
        assertElementExists("action.settings.open_decryption", in: context.app)
    }

    @MainActor
    func testInvalidServerAddressShowsInlineFeedbackInsteadOfToast() {
        let sessionID = "macos-invalid-server-\(UUID().uuidString.lowercased())"
        let context = configuredQualityApp(
            sessionID: sessionID,
            fixture: "channels.standard",
            failGatewaySwitchValidationOnce: true,
            channelMutationScenario: "accepted"
        )
        launchQuality(context, sessionID: sessionID)

        openSidebarTab("settings", in: context.app)
        assertVisibleScreenThroughUI("screen.settings", in: context.app)
        element(in: context.app, identifier: "action.settings.server_management").click()

        let addressField = element(in: context.app, identifier: "field.settings.server.address")
        XCTAssertTrue(addressField.waitForExistence(timeout: 8))
        let originalAddress = (addressField.value as? String) ?? ""
        XCTAssertFalse(originalAddress.isEmpty)
        replaceText(in: addressField, with: "not a valid url")
        element(in: context.app, identifier: "action.settings.server.save").click()

        let serverFeedback = element(in: context.app, identifier: "feedback.settings.server")
        XCTAssertTrue(
            serverFeedback.waitForExistence(timeout: 5),
            "Server validation errors should stay inline in the sheet."
        )
        let invalidAddressFeedback = serverFeedback.label
        XCTAssertFalse(invalidAddressFeedback.isEmpty)
        XCTAssertFalse(
            element(in: context.app, identifier: "feedback.toast.error").waitForExistence(timeout: 1),
            "Server validation errors must not be routed to the global toast overlay."
        )

        replaceText(in: addressField, with: "https://quality-macos-rejected.invalid/api")
        element(in: context.app, identifier: "action.settings.server.save").click()
        let registrationRejection = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label != %@", invalidAddressFeedback),
            object: serverFeedback
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [registrationRejection], timeout: 8),
            .completed,
            "A rejected candidate registration must stay actionable in its editor."
        )
        XCTAssertTrue(addressField.exists, "Registration rejection must not dismiss the editor.")
        XCTAssertFalse(
            element(in: context.app, identifier: "feedback.settings.root").exists,
            "A server editor failure must not leak into the host Settings page."
        )

        let cancel = element(in: context.app, identifier: "action.settings.server.cancel")
        XCTAssertTrue(cancel.waitForExistence(timeout: 5) && cancel.isHittable)
        cancel.click()
        XCTAssertTrue(addressField.waitForNonExistence(timeout: 8))
        element(in: context.app, identifier: "action.settings.server_management").click()
        let restoredField = element(in: context.app, identifier: "field.settings.server.address")
        XCTAssertTrue(restoredField.waitForExistence(timeout: 8))
        XCTAssertEqual(
            restoredField.value as? String,
            originalAddress,
            "A rejected candidate must not replace the previously saved gateway."
        )
    }

    @MainActor
    func testGatewayCandidateMustRegisterBeforeCommitAndPersistsAfterRelaunch() {
        let sessionID = "macos-settings-server-\(UUID().uuidString.lowercased())"
        let context = configuredQualityApp(
            sessionID: sessionID,
            fixture: "channels.standard",
            channelMutationScenario: "accepted"
        )
        launchQuality(context, sessionID: sessionID)

        openSidebarTab("channels", in: context.app)
        let originalChannel = element(
            in: context.app,
            identifier: "channel.row.01H00000000000000000000001"
        )
        XCTAssertTrue(
            originalChannel.waitForExistence(timeout: 8),
            "The original gateway-scoped channel must be usable before replacement."
        )
        openSidebarTab("settings", in: context.app)
        let serverAction = element(in: context.app, identifier: "action.settings.server_management")
        XCTAssertTrue(serverAction.waitForExistence(timeout: 8) && serverAction.isHittable)
        serverAction.click()

        let addressField = element(in: context.app, identifier: "field.settings.server.address")
        XCTAssertTrue(addressField.waitForExistence(timeout: 8))
        let originalAddress = (addressField.value as? String) ?? ""
        XCTAssertFalse(originalAddress.isEmpty)
        let normalizedAddress = "https://quality-macos-settings.invalid/api"
        replaceText(in: addressField, with: "\(normalizedAddress)/")
        element(in: context.app, identifier: "action.settings.server.save").click()
        XCTAssertTrue(
            addressField.waitForNonExistence(timeout: 10),
            "Only a registered and locally committed candidate may close the editor."
        )

        openSidebarTab("channels", in: context.app)
        XCTAssertTrue(
            originalChannel.waitForNonExistence(timeout: 8),
            "Accepted gateway replacement must immediately scope data away from the old gateway."
        )

        context.app.terminate()
        let relaunched = configuredQualityApp(
            sessionID: sessionID,
            fixture: "channels.standard",
            channelMutationScenario: "accepted"
        )
        launchQuality(relaunched, sessionID: sessionID)
        openSidebarTab("channels", in: relaunched.app)
        XCTAssertTrue(
            element(
                in: relaunched.app,
                identifier: "channel.row.01H00000000000000000000001"
            ).waitForNonExistence(timeout: 8),
            "Relaunch must not reload channel data owned by the previous gateway."
        )
        openSidebarTab("settings", in: relaunched.app)
        element(in: relaunched.app, identifier: "action.settings.server_management").click()
        let restoredField = element(in: relaunched.app, identifier: "field.settings.server.address")
        XCTAssertTrue(restoredField.waitForExistence(timeout: 8))
        XCTAssertEqual(
            restoredField.value as? String,
            normalizedAddress,
            "The registered gateway must remain authoritative after a full process relaunch."
        )
    }

    @MainActor
    func testGatewayLocalCommitFailureRollsBackBeforeRetryCommits() {
        let sessionID = "macos-gateway-commit-\(UUID().uuidString.lowercased())"
        let failing = configuredQualityApp(
            sessionID: sessionID,
            fixture: "channels.standard",
            failGatewaySwitchCommitOnce: true,
            channelMutationScenario: "accepted"
        )
        launchQuality(failing, sessionID: sessionID)

        openSidebarTab("channels", in: failing.app)
        let originalChannel = element(
            in: failing.app,
            identifier: "channel.row.01H00000000000000000000001"
        )
        XCTAssertTrue(
            originalChannel.waitForExistence(timeout: 8),
            "The old Gateway's channel data must be usable before the candidate commit."
        )
        openSidebarTab("settings", in: failing.app)
        element(in: failing.app, identifier: "action.settings.server_management").click()

        let addressField = element(in: failing.app, identifier: "field.settings.server.address")
        XCTAssertTrue(addressField.waitForExistence(timeout: 8))
        let originalAddress = (addressField.value as? String) ?? ""
        XCTAssertFalse(originalAddress.isEmpty)
        let normalizedAddress = "https://quality-macos-commit.invalid/api"
        replaceText(in: addressField, with: "\(normalizedAddress)/")
        element(in: failing.app, identifier: "action.settings.server.save").click()
        XCTAssertTrue(
            element(in: failing.app, identifier: "feedback.settings.server")
                .waitForExistence(timeout: 8),
            "A failed local commit must remain in the server editor."
        )
        XCTAssertTrue(addressField.exists)
        XCTAssertFalse(element(in: failing.app, identifier: "feedback.settings.root").exists)

        let cancel = element(in: failing.app, identifier: "action.settings.server.cancel")
        XCTAssertTrue(cancel.waitForExistence(timeout: 5) && cancel.isHittable)
        cancel.click()
        XCTAssertTrue(addressField.waitForNonExistence(timeout: 8))
        element(in: failing.app, identifier: "action.settings.server_management").click()
        let rolledBackField = element(in: failing.app, identifier: "field.settings.server.address")
        XCTAssertTrue(rolledBackField.waitForExistence(timeout: 8))
        XCTAssertEqual(
            rolledBackField.value as? String,
            originalAddress,
            "A failed local commit must keep the old gateway active immediately, not only after restart."
        )
        element(in: failing.app, identifier: "action.settings.server.cancel").click()
        XCTAssertTrue(rolledBackField.waitForNonExistence(timeout: 8))
        openSidebarTab("channels", in: failing.app)
        XCTAssertTrue(
            originalChannel.waitForExistence(timeout: 8),
            "Immediate rollback must keep the old Gateway's real channel data available."
        )

        failing.app.terminate()
        let retry = configuredQualityApp(
            sessionID: sessionID,
            fixture: "channels.standard",
            channelMutationScenario: "accepted"
        )
        launchQuality(retry, sessionID: sessionID)
        openSidebarTab("channels", in: retry.app)
        let relaunchedOriginalChannel = element(
            in: retry.app,
            identifier: "channel.row.01H00000000000000000000001"
        )
        XCTAssertTrue(
            relaunchedOriginalChannel.waitForExistence(timeout: 8),
            "Process relaunch after rollback must still expose the old Gateway's channel data."
        )
        openSidebarTab("settings", in: retry.app)
        element(in: retry.app, identifier: "action.settings.server_management").click()
        let retryField = element(in: retry.app, identifier: "field.settings.server.address")
        XCTAssertTrue(retryField.waitForExistence(timeout: 8))
        XCTAssertEqual(
            retryField.value as? String,
            originalAddress,
            "Rollback must keep the old gateway authoritative after process restart."
        )
        replaceText(in: retryField, with: "\(normalizedAddress)/")
        element(in: retry.app, identifier: "action.settings.server.save").click()
        XCTAssertTrue(retryField.waitForNonExistence(timeout: 10))

        openSidebarTab("channels", in: retry.app)
        XCTAssertTrue(
            relaunchedOriginalChannel.waitForNonExistence(timeout: 8),
            "Only the successful retry may scope channel data away from the old Gateway."
        )
        openSidebarTab("settings", in: retry.app)
        element(in: retry.app, identifier: "action.settings.server_management").click()
        let committedField = element(in: retry.app, identifier: "field.settings.server.address")
        XCTAssertTrue(committedField.waitForExistence(timeout: 8))
        XCTAssertEqual(
            committedField.value as? String,
            normalizedAddress,
            "Only the successful retry may expose the candidate as active."
        )
    }

    @MainActor
    func legacyDiagnosticSettingsPageVisibilityCommandCanHideEventPage() {
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
    func legacyDiagnosticSettingsPageVisibilityCommandCanRoundTripEventPage() {
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
    func legacyDiagnosticFixtureSeedEntityRecordsPublishesProjectionCounts() {
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
    func legacyDiagnosticFixtureSeedSubscriptionsPublishesImportState() {
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
    func legacyDiagnosticEntityOpenPublishesEntityStateAndProjectionCounts() {
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
    func legacyDiagnosticMessageOpenPublishesMessageDetailState() {
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
    func legacyDiagnosticNotificationOpenPublishesMessageDetailState() {
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
    func legacyDiagnosticNotificationMarkReadCommandUpdatesUnreadState() {
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
    func legacyDiagnosticNotificationDeleteCommandUpdatesCounts() {
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
    func legacyDiagnosticGatewaySetServerCommandUpdatesConfigurationState() {
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
    func legacyDiagnosticBaselineAutomationStateHasNoRuntimeErrors() {
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

    @MainActor
    private func configuredApp(
        runtimeRoot: URL? = nil,
        startupFixturePath: String? = nil,
        requestName: String? = nil,
        args: [String: String] = [:]
    ) -> LaunchContext {
        let app = XCUIApplication()
        launchedApps.append(app)
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

    @MainActor
    private func configuredQualityApp(
        sessionID: String,
        fixture: String,
        failLocalStoreInitialization: Bool = false,
        messageLoadDelayMilliseconds: Int? = nil,
        messageRefreshDelayMilliseconds: Int? = nil,
        legacyStore: String? = nil,
        failMessageLoad: Bool = false,
        failGatewaySwitchValidationOnce: Bool = false,
        failGatewaySwitchCommitOnce: Bool = false,
        failNotificationMaterialPersistenceOnce: Bool = false,
        messageRefreshScenario: String? = nil,
        eventCloseScenario: String? = nil,
        channelMutationScenario: String? = nil,
        allowCrossAppDataAccess: Bool = false,
        skipPushAuthorization: Bool = true
    ) -> LaunchContext {
        XCTAssertTrue(
            isValidQualitySessionID(sessionID),
            "QUALITY_CONFIGURATION: session ID must be 1...64 ASCII letters, digits, '-' or '_'; got \(sessionID.utf8.count) bytes."
        )
        let app = XCUIApplication()
        launchedApps.append(app)
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
        setAutomationValue(
            skipPushAuthorization ? "1" : "0",
            for: "PUSHGO_AUTOMATION_SKIP_PUSH_AUTHORIZATION",
            in: app
        )
        setAutomationValue(
            allowCrossAppDataAccess ? "1" : "0",
            for: "PUSHGO_AUTOMATION_ALLOW_CROSS_APP_DATA_ACCESS",
            in: app
        )
        setAutomationValue("1", for: "PUSHGO_AUTOMATION_FORCE_FOREGROUND_APP", in: app)
        setAutomationValue(
            qualitySessionPayload(
                sessionID: sessionID,
                fixture: fixture,
                failLocalStoreInitialization: failLocalStoreInitialization,
                messageLoadDelayMilliseconds: messageLoadDelayMilliseconds,
                messageRefreshDelayMilliseconds: messageRefreshDelayMilliseconds,
                legacyStore: legacyStore,
                failMessageLoad: failMessageLoad,
                failGatewaySwitchValidationOnce: failGatewaySwitchValidationOnce,
                failGatewaySwitchCommitOnce: failGatewaySwitchCommitOnce,
                failNotificationMaterialPersistenceOnce: failNotificationMaterialPersistenceOnce,
                messageRefreshScenario: messageRefreshScenario,
                eventCloseScenario: eventCloseScenario,
                channelMutationScenario: channelMutationScenario
            ),
            for: "PUSHGO_QUALITY_SESSION_BASE64",
            in: app
        )
        let diagnosticRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("PushGo-macOS-quality-\(sessionID)", isDirectory: true)
        return LaunchContext(
            app: app,
            runtimeRoot: diagnosticRoot,
            responseURL: diagnosticRoot.appendingPathComponent("unused-response.json"),
            stateURL: diagnosticRoot.appendingPathComponent("unused-state.json"),
            eventsURL: diagnosticRoot.appendingPathComponent("unused-events.jsonl"),
            traceURL: diagnosticRoot.appendingPathComponent("unused-trace.json")
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
    private func pushGoStatusItem(in app: XCUIApplication) -> XCUIElement {
        let appOwnedItem = app.descendants(matching: .any)["status-item.pushgo"]
        if appOwnedItem.exists {
            return appOwnedItem
        }
        return XCUIApplication(bundleIdentifier: "com.apple.systemuiserver")
            .descendants(matching: .any)["status-item.pushgo"]
    }

    private func qualitySessionPayload(
        sessionID: String,
        fixture: String,
        failLocalStoreInitialization: Bool = false,
        messageLoadDelayMilliseconds: Int? = nil,
        messageRefreshDelayMilliseconds: Int? = nil,
        legacyStore: String? = nil,
        failMessageLoad: Bool = false,
        failGatewaySwitchValidationOnce: Bool = false,
        failGatewaySwitchCommitOnce: Bool = false,
        failNotificationMaterialPersistenceOnce: Bool = false,
        messageRefreshScenario: String? = nil,
        eventCloseScenario: String? = nil,
        channelMutationScenario: String? = nil
    ) -> String {
        var faults: [String: Any] = [
            "fail_local_store_initialization": failLocalStoreInitialization,
            "fail_message_load": failMessageLoad,
            "fail_gateway_switch_validation_once": failGatewaySwitchValidationOnce,
            "fail_gateway_switch_commit_once": failGatewaySwitchCommitOnce,
            "fail_notification_material_persistence_once": failNotificationMaterialPersistenceOnce,
        ]
        if let messageLoadDelayMilliseconds {
            faults["message_load_delay_ms"] = messageLoadDelayMilliseconds
        }
        if let messageRefreshDelayMilliseconds {
            faults["message_refresh_delay_ms"] = messageRefreshDelayMilliseconds
        }
        var payload: [String: Any] = [
            "schema_version": 1,
            "session_id": sessionID,
            "fixture": fixture,
            "faults": faults,
        ]
        if let legacyStore {
            payload["legacy_store"] = legacyStore
        }
        if let messageRefreshScenario {
            payload["message_refresh_scenario"] = messageRefreshScenario
        }
        if let eventCloseScenario {
            payload["event_close_scenario"] = eventCloseScenario
        }
        if let channelMutationScenario {
            payload["channel_mutation_scenario"] = channelMutationScenario
        }
        let data = try! JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        return data.base64EncodedString()
    }

    private func isValidQualitySessionID(_ value: String) -> Bool {
        guard (1 ... 64).contains(value.utf8.count) else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            switch scalar.value {
            case 45, 48 ... 57, 65 ... 90, 95, 97 ... 122:
                return true
            default:
                return false
            }
        }
    }

    @MainActor
    private func setAutomationValue(_ value: String, for key: String, in app: XCUIApplication) {
        app.launchEnvironment[key] = value
        app.launchArguments += ["-\(key)", value]
    }

    @MainActor
    private func setAutomationRequest(
        name: String,
        args: [String: String],
        in app: XCUIApplication
    ) {
        let request: [String: Any] = [
            "id": UUID().uuidString,
            "plane": "command",
            "name": name,
            "args": args,
        ]
        let data = try! JSONSerialization.data(withJSONObject: request, options: [.sortedKeys])
        setAutomationValue(
            String(decoding: data, as: UTF8.self),
            for: "PUSHGO_AUTOMATION_REQUEST",
            in: app
        )
    }

    @MainActor
    private func resolveMacNotificationAuthorizationIfNeeded(in app: XCUIApplication) {
        let hosts = [
            app,
            XCUIApplication(bundleIdentifier: "com.apple.UserNotificationCenter"),
        ]
        let ready = element(in: app, identifier: "quality-runtime.ready")
        let commandSucceeded = element(in: app, identifier: "quality-command.succeeded")
        let commandFailed = element(in: app, identifier: "quality-command.failed")
        let deadline = Date().addingTimeInterval(6)

        while Date() < deadline {
            // An already-granted or already-denied host completes the command
            // without presenting UI. Stop as soon as the App-owned boundary can
            // classify that result instead of paying two fixed alert timeouts.
            if ready.exists || commandSucceeded.exists || commandFailed.exists {
                return
            }
            for host in hosts {
                let alert = host.alerts.firstMatch
                guard alert.exists else { continue }
                let allow = alert.buttons
                    .matching(NSPredicate(format: "label IN %@", ["Allow", "允许", "允許"]))
                    .firstMatch
                XCTAssertTrue(
                    allow.waitForExistence(timeout: 3),
                    "QUALITY_PRECONDITION: the macOS notification permission Allow action was unavailable."
                )
                if allow.exists {
                    allow.click()
                    XCTAssertTrue(
                        alert.waitForNonExistence(timeout: 8),
                        "QUALITY_PRECONDITION: the macOS notification permission prompt did not dismiss."
                    )
                }
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
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
    private func launchQuality(_ context: LaunchContext, sessionID: String) {
        launch(context)
        let ready = element(in: context.app, identifier: "quality-runtime.ready")
        XCTAssertTrue(
            ready.waitForExistence(timeout: 15),
            "QUALITY_PRECONDITION: App-owned quality session did not become ready."
        )
        XCTAssertEqual(
            ready.value as? String,
            sessionID,
            "QUALITY_PRECONDITION: App launched with the wrong quality session."
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

    private func hasReadableForegroundContrast(in screenshot: XCUIScreenshot) -> Bool {
        guard let bitmap = NSBitmapImageRep(data: screenshot.pngRepresentation),
              bitmap.pixelsWide > 0,
              bitmap.pixelsHigh > 0
        else {
            return false
        }
        var luminances: [CGFloat] = []
        luminances.reserveCapacity(bitmap.pixelsWide * bitmap.pixelsHigh)
        for y in 0 ..< bitmap.pixelsHigh {
            for x in 0 ..< bitmap.pixelsWide {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else {
                    continue
                }
                luminances.append(
                    0.2126 * color.redComponent
                        + 0.7152 * color.greenComponent
                        + 0.0722 * color.blueComponent
                )
            }
        }
        guard luminances.count >= 10 else { return false }
        luminances.sort()
        let darkSample = luminances[luminances.count / 10]
        let lightSample = luminances[luminances.count * 9 / 10]
        return lightSample - darkSample >= 0.25
    }

    @MainActor
    private func openDecryptionEditor(in app: XCUIApplication) {
        let action = element(in: app, identifier: "action.settings.open_decryption")
        XCTAssertTrue(action.waitForExistence(timeout: 8) && action.isHittable)
        action.click()
        assertVisibleScreenThroughUI("screen.settings.decryption", in: app, timeout: 8)
    }

    @MainActor
    private func messageRow(containing title: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", title)).firstMatch
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
    private func assertVisibleScreenThroughUI(
        _ screenIdentifier: String,
        in app: XCUIApplication,
        timeout: TimeInterval = 10,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(
            element(in: app, identifier: screenIdentifier).waitForExistence(timeout: timeout),
            "Expected the real UI screen \(screenIdentifier).",
            file: file,
            line: line
        )
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
    private func openMessageFilters(in app: XCUIApplication) {
        let filter = element(in: app, identifier: "action.messages.filter")
        XCTAssertTrue(filter.waitForExistence(timeout: 5) && filter.isHittable)
        filter.click()
        XCTAssertTrue(
            element(in: app, identifier: "filter.unread_only").waitForExistence(timeout: 5),
            "The production filter popover did not open"
        )
        XCTAssertTrue(
            element(in: app, identifier: "filter.surface").waitForExistence(timeout: 5),
            "The production filter popover has no stable scroll owner"
        )
    }

    @MainActor
    private func revealFilterOption(
        _ identifier: String,
        towardTags: Bool,
        in app: XCUIApplication
    ) {
        let option = element(in: app, identifier: identifier)
        let surface = element(in: app, identifier: "filter.surface")
        for _ in 0..<4 {
            if option.exists, option.isHittable { return }
            if towardTags {
                surface.swipeUp()
            } else {
                surface.swipeDown()
            }
        }
        XCTAssertTrue(option.exists && option.isHittable, "Filter option remained unreachable: \(identifier)")
    }

    @MainActor
    private func dismissMessageFilters(in app: XCUIApplication) {
        let filterSurfaceProbe = element(in: app, identifier: "filter.unread_only")
        guard filterSurfaceProbe.exists else { return }
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(
            filterSurfaceProbe.waitForNonExistence(timeout: 5),
            "The production filter popover did not dismiss with the platform Escape action"
        )
    }

    @MainActor
    private func assertMessageTitles(
        _ expected: [String],
        excluding unexpected: [String],
        in app: XCUIApplication,
        timeout: TimeInterval = 8,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        func titleIsPresented(_ title: String) -> Bool {
            app.staticTexts[title].exists
                || messageRow(containing: title, in: app).exists
        }
        let deadline = Date().addingTimeInterval(timeout)
        var matched = false
        repeat {
            matched = expected.allSatisfy(titleIsPresented)
                && unexpected.allSatisfy { !titleIsPresented($0) }
            if matched { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        } while Date() < deadline
        let visibleRowLabels = app.buttons
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "message.row."))
            .allElementsBoundByIndex
            .map(\.label)
        XCTAssertTrue(
            matched,
            "The visible message set did not match the exact selected facets; rows=\(visibleRowLabels)",
            file: file,
            line: line
        )
        for title in expected {
            XCTAssertTrue(titleIsPresented(title), "Missing expected message: \(title)", file: file, line: line)
        }
        for title in unexpected {
            XCTAssertFalse(titleIsPresented(title), "Unexpected message remained visible: \(title)", file: file, line: line)
        }
    }

    @MainActor
    private func replaceText(in field: XCUIElement, with text: String) {
        field.click()
        field.typeKey("a", modifierFlags: .command)
        field.typeText(text)
    }

    @MainActor
    private func replaceSecureText(in field: XCUIElement, with text: String) {
        replaceTextUsingPasteboard(in: field, with: text)
    }

    @MainActor
    private func replaceTextUsingPasteboard(in field: XCUIElement, with text: String) {
        let pasteboard = NSPasteboard.general
        let savedItems: [[NSPasteboard.PasteboardType: Data]] = pasteboard.pasteboardItems?.map { item in
            Dictionary(uniqueKeysWithValues: item.types.compactMap { type in
                item.data(forType: type).map { (type, $0) }
            })
        } ?? []
        defer {
            pasteboard.clearContents()
            let restoredItems = savedItems.map { savedRepresentations in
                let item = NSPasteboardItem()
                for (type, data) in savedRepresentations {
                    item.setData(data, forType: type)
                }
                return item
            }
            if !restoredItems.isEmpty {
                pasteboard.writeObjects(restoredItems)
            }
        }

        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString(text, forType: .string))
        field.click()
        field.typeKey("a", modifierFlags: .command)
        field.typeKey("v", modifierFlags: .command)
    }

    @MainActor
    private func assertExactPasteboardCopy(
        _ expected: String,
        byClicking action: XCUIElement,
        pasteboard: NSPasteboard,
        in app: XCUIApplication,
        purpose: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        pasteboard.clearContents()
        XCTAssertTrue(
            pasteboard.setString("pushgo-quality-copy-sentinel", forType: .string),
            "Could not prepare the system pasteboard for \(purpose) verification.",
            file: file,
            line: line
        )
        action.click()
        XCTAssertTrue(
            element(in: app, identifier: "feedback.toast.success").waitForExistence(timeout: 2),
            "The \(purpose) action did not report a successful system pasteboard write.",
            file: file,
            line: line
        )
        let copied = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                pasteboard.string(forType: .string) == expected
            },
            object: nil
        )
        let waitResult = XCTWaiter.wait(for: [copied], timeout: 3)
        XCTAssertEqual(
            waitResult,
            .completed,
            "The \(purpose) action did not copy its exact canonical value; actual="
                + (pasteboard.string(forType: .string) ?? "<nil>"),
            file: file,
            line: line
        )
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
    private func waitForValue(
        _ expectedValue: String,
        in element: XCUIElement,
        timeout: TimeInterval
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.exists, element.value as? String == expectedValue {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return element.exists && element.value as? String == expectedValue
    }

    @MainActor
    private func waitForLabelContaining(
        _ expectedText: String,
        in element: XCUIElement,
        timeout: TimeInterval
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.exists, element.label.contains(expectedText) {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return element.exists && element.label.contains(expectedText)
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
