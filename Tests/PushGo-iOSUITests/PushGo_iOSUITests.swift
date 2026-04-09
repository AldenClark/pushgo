import XCTest

@MainActor
final class PushGo_iOSUITests: XCTestCase {
    private struct AutomationState: Decodable {
        let activeTab: String?
        let visibleScreen: String?
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
        let runtimeErrorCount: Int?
        let localStoreMode: String?
        let lastFixtureImportMessageCount: Int?

        private enum CodingKeys: String, CodingKey {
            case activeTab = "active_tab"
            case visibleScreen = "visible_screen"
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
            case runtimeErrorCount = "runtime_error_count"
            case localStoreMode = "local_store_mode"
            case lastFixtureImportMessageCount = "last_fixture_import_message_count"
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

    private func configuredLaunchContext(
        runtimeRoot: URL? = nil,
        startupFixturePath: String? = nil,
        requestName: String? = nil,
        args: [String: String] = [:]
    ) -> LaunchContext {
        let app = XCUIApplication()
        let resolvedRuntimeRoot = runtimeRoot ?? makeRuntimeRoot()
        try? FileManager.default.createDirectory(at: resolvedRuntimeRoot, withIntermediateDirectories: true)
        runtimeRoots.append(resolvedRuntimeRoot)

        let responseURL = resolvedRuntimeRoot.appendingPathComponent("automation-response.json")
        let stateURL = resolvedRuntimeRoot.appendingPathComponent("automation-state.json")
        let eventsURL = resolvedRuntimeRoot.appendingPathComponent("automation-events.jsonl")
        let traceURL = resolvedRuntimeRoot.appendingPathComponent("automation-trace.json")
        let fileManager = FileManager.default
        for url in [responseURL, stateURL, eventsURL, traceURL] {
            try? fileManager.removeItem(at: url)
        }

        app.launchEnvironment["PUSHGO_AUTOMATION_STORAGE_ROOT"] = resolvedRuntimeRoot.path
        app.launchEnvironment["PUSHGO_AUTOMATION_PROVIDER_TOKEN"] = "ios-ui-test-provider-token"
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
}
