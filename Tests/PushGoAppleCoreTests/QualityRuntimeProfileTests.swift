import Foundation
import Testing
@testable import PushGoAppleCore

@Suite("Quality runtime profile")
struct QualityRuntimeProfileTests {
    @Test
    func appOwnedDefaultsStayIsolatedByRootAndSuiteAndSurviveAnotherProcess() async throws {
        try await withIsolatedAutomationStorage { root, _ in
            let suite = "quality-defaults-test"
            let otherRoot = root.appendingPathComponent("other-session", isDirectory: true)
            let key = "owned-" + UUID().uuidString
            let firstName = try #require(AppConstants.automationUserDefaultsSuiteName(suiteName: suite))
            let secondName = try PushGoAutomationContext.$storageRootOverrideURL.withValue(otherRoot) {
                try #require(AppConstants.automationUserDefaultsSuiteName(suiteName: suite))
            }
            let otherSuiteName = try #require(AppConstants.automationUserDefaultsSuiteName(suiteName: suite + ".other"))
            let first = AppConstants.sharedUserDefaults(suiteName: suite)
            #expect(first !== UserDefaults.standard)
            defer {
                for name in [firstName, secondName, otherSuiteName] { first.removePersistentDomain(forName: name) }
            }
            first.set("root-one", forKey: key)
            #expect(first.synchronize())
            PushGoAutomationContext.$storageRootOverrideURL.withValue(otherRoot) {
                let second = AppConstants.sharedUserDefaults(suiteName: suite)
                #expect(second !== UserDefaults.standard)
                #expect(second.string(forKey: key) == nil)
                second.set("root-two", forKey: key)
                #expect(second.synchronize())
            }
            #expect(AppConstants.sharedUserDefaults(suiteName: suite + ".other").string(forKey: key) == nil)
            #expect(AppConstants.sharedUserDefaults(suiteName: suite).string(forKey: key) == "root-one")
            let child = Process()
            child.executableURL = try qualityDefaultsChildExecutable()
            child.arguments = ["defaults-probe", suite, key]
            var childEnvironment = ProcessInfo.processInfo.environment
            childEnvironment["PUSHGO_AUTOMATION_STORAGE_ROOT"] = root.path
            // An invalid explicit descriptor prevents unrelated cold-launch
            // lease discovery; the valid explicit storage root still owns this probe.
            childEnvironment["PUSHGO_QUALITY_SESSION_BASE64"] = "invalid-owned-defaults-probe"
            child.environment = childEnvironment
            let output = Pipe()
            child.standardOutput = output
            child.standardError = Pipe()
            try child.run()
            child.waitUntilExit()
            #expect(child.terminationStatus == 0)
            #expect(String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) == "root-one")
        }
    }

    @Test
    func activeAutomationWithoutStorageRootFailsBeforeOpeningStandardDefaults() throws {
        let child = Process()
        child.executableURL = try qualityDefaultsChildExecutable()
        child.arguments = ["defaults-probe", "rootless-quality-probe"]
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "PUSHGO_AUTOMATION_STORAGE_ROOT")
        environment["PUSHGO_QUALITY_SESSION_BASE64"] = "invalid-rootless-defaults-probe"
        environment.removeValue(forKey: "PUSHGO_AUTOMATION_ALLOW_CROSS_APP_DATA_ACCESS")
        environment["PUSHGO_AUTOMATION_PROVIDER_TOKEN"] = "synthetic-rootless-probe"
        environment["SWIFT_BACKTRACE"] = "enable=no"
        child.environment = environment
        let output = Pipe()
        let errors = Pipe()
        child.standardOutput = output
        child.standardError = errors
        try child.run()
        child.waitUntilExit()
        #expect(child.terminationStatus != 0)
        #expect(output.fileHandleForReading.readDataToEndOfFile().isEmpty)
        #expect(String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.contains("Automation storage root is required for isolated defaults.") == true)
    }

    @Test("Local App-owned preparation requires an explicit Gateway for automatic provider startup")
    func automaticProviderBootstrapRequiresExplicitGatewayForAppOwnedFixtures() {
        let session = PushGoQualitySessionDescriptor(sessionID: "provider-bootstrap-local", fixture: .messagesStandard)
        #expect(PushGoAutomationContext.automaticProviderBootstrapAllowed(qualitySession: nil, explicitGatewayBaseURL: nil))
        #expect(PushGoAutomationContext.automaticProviderBootstrapAllowed(qualitySession: nil, explicitGatewayBaseURL: "https://controlled.example"))
        #expect(!PushGoAutomationContext.automaticProviderBootstrapAllowed(qualitySession: session, explicitGatewayBaseURL: nil))
        #expect(!PushGoAutomationContext.automaticProviderBootstrapAllowed(qualitySession: session, explicitGatewayBaseURL: "  \n"))
        #expect(PushGoAutomationContext.automaticProviderBootstrapAllowed(qualitySession: session, explicitGatewayBaseURL: "https://controlled.example"))
    }

    @Test("App-owned fixtures isolate Spotlight while explicit and system indexers retain ownership")
    func spotlightOwnershipForQualitySessions() {
        let session = PushGoQualitySessionDescriptor(sessionID: "spotlight-quality", fixture: .messagesStandard)
        let live = CoreSpotlightPushGoIndexer()
        #expect(spotlightIndexerForQualitySession(live, session: session) is RecordingPushGoSpotlightIndexer)
        #expect(spotlightIndexerForQualitySession(live, session: nil) is CoreSpotlightPushGoIndexer)
        let systemSession = PushGoQualitySessionDescriptor(
            sessionID: "spotlight-system",
            fixture: .messagesStandard,
            allowsSystemColdLaunch: true
        )
        #expect(spotlightIndexerForQualitySession(live, session: systemSession) is CoreSpotlightPushGoIndexer)
        let explicit = RecordingPushGoSpotlightIndexer()
        #expect((spotlightIndexerForQualitySession(explicit, session: session) as? RecordingPushGoSpotlightIndexer) === explicit)
        #expect(spotlightIndexerForQualitySession(nil, session: session) == nil)
    }

    @Test("accepts the small typed session contract used by UI runners")
    func acceptsTypedSession() throws {
        let encoded = try encodedSession(
            sessionID: "ios-pr-123_retry-1",
            fixture: "messages.standard",
            faults: [
                "local_store_failure_streak_threshold": 1,
                "message_page_load_delay_ms": 1_500,
                "message_refresh_delay_ms": 2_500,
                "message_search_delay_ms": 2_000,
                "fail_message_page_load_once": true,
                "fail_message_search_once": true,
                "fail_gateway_switch_validation_once": true,
                "fail_gateway_switch_commit_once": true,
                "pause_gateway_switch_before_commit": true,
                "fail_gateway_post_commit_sync_once": true,
                "fail_notification_material_persistence_once": true,
                "fail_channel_subscription_persistence_once": true,
            ]
        )

        let descriptor = try PushGoAutomationContext.decodeQualitySession(encoded)

        #expect(descriptor.schemaVersion == 1)
        #expect(descriptor.sessionID == "ios-pr-123_retry-1")
        #expect(descriptor.fixture == .messagesStandard)
        #expect(descriptor.faults.messageLoadDelayMilliseconds == nil)
        #expect(descriptor.faults.messagePageLoadDelayMilliseconds == 1_500)
        #expect(descriptor.faults.localStoreFailureStreakThreshold == 1)
        #expect(descriptor.faults.messageRefreshDelayMilliseconds == 2_500)
        #expect(descriptor.faults.messageSearchDelayMilliseconds == 2_000)
        #expect(descriptor.faults.failMessageLoad == false)
        #expect(descriptor.faults.failMessagePageLoadOnce)
        #expect(descriptor.faults.failMessageSearchOnce)
        #expect(descriptor.faults.failGatewaySwitchValidationOnce)
        #expect(descriptor.faults.failGatewaySwitchCommitOnce)
        #expect(descriptor.faults.pauseGatewaySwitchBeforeCommit)
        #expect(descriptor.faults.failGatewayPostCommitSyncOnce)
        #expect(descriptor.faults.failNotificationMaterialPersistenceOnce)
        #expect(descriptor.faults.failChannelSubscriptionPersistenceOnce)
        #expect(descriptor.messageRefreshScenario == .none)
        #expect(descriptor.eventCloseScenario == .none)
        #expect(descriptor.channelMutationScenario == .none)
    }

    @Test("decodes the dense positive core fixture used by the low-cost PR journey")
    func decodesCorePositiveFixture() throws {
        let encoded = try encodedSession(
            sessionID: "core-positive",
            fixture: "core.positive"
        )

        let descriptor = try PushGoAutomationContext.decodeQualitySession(encoded)

        #expect(descriptor.fixture == .corePositive)
    }

    @Test("decodes the typed provider refresh scenario")
    func decodesMessageRefreshScenario() throws {
        let encoded = try encodedSession(
            sessionID: "refresh-result",
            fixture: "messages.standard",
            messageRefreshScenario: "fail_once_then_new_message"
        )

        let descriptor = try PushGoAutomationContext.decodeQualitySession(encoded)

        #expect(descriptor.messageRefreshScenario == .failOnceThenNewMessage)
    }

    @Test("decodes the typed App-owned legacy store preparation")
    func decodesLegacyStorePreparation() throws {
        let encoded = try encodedSession(
            sessionID: "legacy-store-result",
            fixture: "messages.standard",
            legacyStore: "messages.v17"
        )

        let descriptor = try PushGoAutomationContext.decodeQualitySession(encoded)

        #expect(descriptor.legacyStore == .messagesV17)
    }

    @Test("decodes the typed event close round trip")
    func decodesEventCloseScenario() throws {
        let encoded = try encodedSession(
            sessionID: "event-close-result",
            fixture: "event.standard",
            eventCloseScenario: "fail_once_then_accepted_and_delivered"
        )

        let descriptor = try PushGoAutomationContext.decodeQualitySession(encoded)

        #expect(descriptor.eventCloseScenario == .failOnceThenAcceptedAndDelivered)
    }

    @Test("event close quality boundary becomes one production-shaped delivered payload")
    func buildsEventCloseDelivery() throws {
        let boundary: [String: Any] = [
            "channel_id": "quality-channel",
            "event_id": "quality-event-active",
            "op_id": "quality-close-operation",
            "status": "closed",
            "message": "closed by the user",
            "severity": "normal",
            "attrs": ["owner": "qa"],
        ]

        let delivery = try #require(
            PushGoQualityEventCloseDelivery.make(
                boundaryPayload: boundary,
                endpointPath: "/event/close",
                scenario: .acceptedAndDelivered
            )
        )

        #expect(delivery.requestIdentifier == "quality-event-close-quality-event-active")
        #expect(delivery.payload["entity_type"] as? String == "event")
        #expect(delivery.payload["entity_id"] as? String == "quality-event-active")
        #expect(delivery.payload["event_state"] as? String == "closed")
        #expect(delivery.payload["projection_destination"] as? String == "event_head")
        #expect(delivery.payload["delivery_id"] as? String == "quality-event-close-quality-event-active")
        #expect(delivery.payload["received_at"] as? String == "2026-01-15T08:03:00Z")
        #expect(delivery.payload["channel_id"] as? String == "quality-channel")
        #expect(delivery.payload["op_id"] as? String == "quality-close-operation")
        #expect(delivery.payload["message"] as? String == "closed by the user")
        #expect(boundary["entity_type"] == nil, "The immutable boundary input must not be rewritten in place.")
        #expect(
            PushGoQualityEventCloseDelivery.make(
                boundaryPayload: boundary,
                endpointPath: "/event/close",
                scenario: .failOnceThenAcceptedAndDelivered
            )?.payload["event_state"] as? String == "closed"
        )
    }

    @Test("event close quality boundary rejects inactive or unrelated calls")
    func rejectsUnrelatedEventCloseDelivery() {
        let boundary: [String: Any] = ["event_id": "quality-event-active"]

        #expect(
            PushGoQualityEventCloseDelivery.make(
                boundaryPayload: boundary,
                endpointPath: "/event/close",
                scenario: .none
            ) == nil
        )
        #expect(
            PushGoQualityEventCloseDelivery.make(
                boundaryPayload: boundary,
                endpointPath: "/channel/create",
                scenario: .acceptedAndDelivered
            ) == nil
        )
        #expect(
            PushGoQualityEventCloseDelivery.make(
                boundaryPayload: [:],
                endpointPath: "/event/close",
                scenario: .acceptedAndDelivered
            ) == nil
        )
    }

    @Test("decodes the typed channel mutation round trip")
    func decodesChannelMutationScenario() throws {
        let expectedGatewayURL = "https://quality-settings.invalid/api"
        let encoded = try encodedSession(
            sessionID: "channel-mutation-result",
            fixture: "channels.standard",
            channelMutationScenario: "accepted",
            expectedChannelMutationGatewayURL: expectedGatewayURL
        )

        let descriptor = try PushGoAutomationContext.decodeQualitySession(encoded)

        #expect(descriptor.fixture == .channelsStandard)
        #expect(descriptor.channelMutationScenario == .accepted)
        #expect(descriptor.expectedChannelMutationGatewayURL == expectedGatewayURL)
    }

    @Test("decodes channel rejection and compensation scenarios")
    func decodesChannelFailureScenarios() throws {
        let rejected = try encodedSession(
            sessionID: "channel-rejected-result",
            fixture: "channels.standard",
            channelMutationScenario: "reject_once_then_accepted"
        )
        let compensated = try encodedSession(
            sessionID: "channel-compensation-result",
            fixture: "channels.standard",
            channelMutationScenario: "require_create_compensation"
        )

        #expect(
            try PushGoAutomationContext.decodeQualitySession(rejected).channelMutationScenario
                == .rejectOnceThenAccepted
        )
        #expect(
            try PushGoAutomationContext.decodeQualitySession(compensated).channelMutationScenario
                == .requireCreateCompensation
        )
    }

    @Test("rejects path traversal instead of treating a host path as a session")
    func rejectsPathTraversalSessionID() throws {
        let encoded = try encodedSession(
            sessionID: "../../shared-database",
            fixture: "empty.clean"
        )

        #expect(throws: PushGoQualitySessionError.invalidSessionID) {
            try PushGoAutomationContext.decodeQualitySession(encoded)
        }
    }

    @Test("rejects unbounded delay faults before app startup")
    func rejectsUnboundedDelay() throws {
        let encoded = try encodedSession(
            sessionID: "slow-load-negative-control",
            fixture: "messages.standard",
            faults: ["message_load_delay_ms": 30_001]
        )

        #expect(throws: PushGoQualitySessionError.invalidMessageLoadDelay(30_001)) {
            try PushGoAutomationContext.decodeQualitySession(encoded)
        }
    }

    @Test("rejects an unbounded next-page delay before app startup")
    func rejectsUnboundedPageDelay() throws {
        let encoded = try encodedSession(
            sessionID: "slow-page-negative-control",
            fixture: "messages.standard",
            faults: ["message_page_load_delay_ms": 30_001]
        )

        #expect(throws: PushGoQualitySessionError.invalidMessagePageLoadDelay(30_001)) {
            try PushGoAutomationContext.decodeQualitySession(encoded)
        }
    }

    @Test("rejects unbounded refresh delay faults before app startup")
    func rejectsUnboundedRefreshDelay() throws {
        let encoded = try encodedSession(
            sessionID: "slow-refresh-negative-control",
            fixture: "messages.standard",
            faults: ["message_refresh_delay_ms": 30_001]
        )

        #expect(throws: PushGoQualitySessionError.invalidMessageRefreshDelay(30_001)) {
            try PushGoAutomationContext.decodeQualitySession(encoded)
        }
    }

    @Test("rejects unbounded search delay faults before app startup")
    func rejectsUnboundedSearchDelay() throws {
        let encoded = try encodedSession(
            sessionID: "slow-search-negative-control",
            fixture: "messages.standard",
            faults: ["message_search_delay_ms": 30_001]
        )

        #expect(throws: PushGoQualitySessionError.invalidMessageSearchDelay(30_001)) {
            try PushGoAutomationContext.decodeQualitySession(encoded)
        }
    }

    @Test("rejects a Store recovery threshold outside the production range")
    func rejectsInvalidLocalStoreFailureStreakThreshold() throws {
        let encoded = try encodedSession(
            sessionID: "store-recovery-threshold-negative-control",
            fixture: "messages.standard",
            faults: ["local_store_failure_streak_threshold": 0]
        )

        #expect(throws: PushGoQualitySessionError.invalidLocalStoreFailureStreakThreshold(0)) {
            try PushGoAutomationContext.decodeQualitySession(encoded)
        }
    }

    @Test("derives storage beneath an app-owned base directory")
    func derivesContainedSessionRoot() throws {
        let descriptor = try PushGoAutomationContext.decodeQualitySession(
            encodedSession(sessionID: "contained-session", fixture: "empty.clean")
        )
        let appOwnedBase = URL(fileURLWithPath: "/app/container/Application Support", isDirectory: true)

        let root = try #require(
            PushGoAutomationContext.qualitySessionRootURL(
                for: descriptor,
                baseURL: appOwnedBase
            )
        )

        #expect(root.path.hasPrefix(appOwnedBase.path + "/"))
        #expect(root.lastPathComponent == "contained-session")
        #expect(!root.path.contains(".."))
    }

    @Test("focused UI roots require an exact session-scoped sandbox token")
    func focusedQualityRootIsExplicitAndContained() {
        let session = PushGoQualitySessionDescriptor(sessionID: "resource-ui-one", fixture: .messagesStandard)
        let appBase = URL(fileURLWithPath: "/app/Application Support", isDirectory: true)
        let temporary = URL(fileURLWithPath: "/app/tmp", isDirectory: true)
        func base(_ token: String?, for identity: PushGoQualitySessionDescriptor?) -> URL {
            PushGoAutomationContext.qualitySessionBaseURL(
                for: identity, applicationSupportURL: appBase,
                temporaryDirectory: temporary, storageRootToken: token
            )
        }
        #if DEBUG
        #expect(base("sandbox-tmp:resource-ui-one", for: session).path == "/app/tmp/PushGoQualityIsolated/resource-ui-one")
        #else
        #expect(base("sandbox-tmp:resource-ui-one", for: session) == appBase)
        #endif
        for token in [nil, "/app/arbitrary", "sandbox-tmp:another-session", "sandbox-tmp:../resource-ui-one", "sandbox-tmp:resource-ui-one/extra"] {
            #expect(base(token, for: session) == appBase)
        }
        #expect(base("sandbox-tmp:resource-ui-one", for: nil) == appBase)
        let invalid = PushGoQualitySessionDescriptor(sessionID: "../resource-ui-one", fixture: .messagesStandard)
        #expect(base("sandbox-tmp:../resource-ui-one", for: invalid) == appBase)
    }

    @Test("focused UI cleanup never enumerates earlier App-owned session roots")
    func focusedQualityCleanupLeavesPriorSessionsUntouched() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent("resource-ui-root-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }
        let appBase = root.appendingPathComponent("Application Support", isDirectory: true)
        let temporary = root.appendingPathComponent("tmp", isDirectory: true)
        let session = PushGoQualitySessionDescriptor(sessionID: "current-resource-ui", fixture: .messagesStandard)
        let prior = appBase.appendingPathComponent("PushGoQuality/Sessions/prior-evidence", isDirectory: true)
        try fileManager.createDirectory(at: prior, withIntermediateDirectories: true)
        let sentinel = prior.appendingPathComponent("preserve.txt")
        try Data("prior evidence".utf8).write(to: sentinel)
        let scopedBase = PushGoAutomationContext.qualitySessionBaseURL(
            for: session, applicationSupportURL: appBase,
            temporaryDirectory: temporary, storageRootToken: "sandbox-tmp:current-resource-ui"
        )
        #if DEBUG
        let active = try #require(PushGoAutomationContext.qualitySessionRootURL(for: session, baseURL: scopedBase))
        try fileManager.createDirectory(at: active, withIntermediateDirectories: true)
        #expect(try PushGoAutomationContext.cleanupPriorQualitySessions(activeSession: session, baseURL: scopedBase) == 0)
        #expect(try Data(contentsOf: sentinel) == Data("prior evidence".utf8))
        #expect(active.path.hasPrefix(temporary.path + "/PushGoQualityIsolated/current-resource-ui/"))
        #else
        #expect(scopedBase == appBase)
        #endif
    }

    @Test("cleanup removes only prior validated quality sessions")
    func cleanupPriorSessionsIsContained() throws {
        let fileManager = FileManager.default
        let base = fileManager.temporaryDirectory
            .appendingPathComponent("pushgo-quality-cleanup-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: base) }
        let active = try PushGoAutomationContext.decodeQualitySession(
            encodedSession(sessionID: "active-session", fixture: "empty.clean")
        )
        let sessions = base
            .appendingPathComponent("PushGoQuality", isDirectory: true)
            .appendingPathComponent("Sessions", isDirectory: true)
        let activeURL = sessions.appendingPathComponent("active-session", isDirectory: true)
        let staleURL = sessions.appendingPathComponent("stale-session", isDirectory: true)
        let unrelatedURL = sessions.appendingPathComponent("not a session", isDirectory: true)
        for directory in [activeURL, staleURL, unrelatedURL] {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        let removed = try PushGoAutomationContext.cleanupPriorQualitySessions(
            activeSession: active,
            baseURL: base,
            fileManager: fileManager
        )

        #expect(removed == 1)
        #expect(fileManager.fileExists(atPath: activeURL.path))
        #expect(!fileManager.fileExists(atPath: staleURL.path))
        #expect(fileManager.fileExists(atPath: unrelatedURL.path))
    }

    @Test("release builds cannot activate the quality runtime")
    func releaseIsolation() throws {
        let encoded = try encodedSession(
            sessionID: "release-isolation",
            fixture: "empty.clean"
        )
        let profile = PushGoAutomationContext.resolveRuntimeProfile(
            encodedQualitySession: encoded
        )

        #if DEBUG
        #expect(profile == .quality(try PushGoAutomationContext.decodeQualitySession(encoded)))
        #else
        #expect(profile == .production)
        #endif
    }

    @Test("cold-launch lease is app-owned, bounded, and explicitly cleared")
    func coldLaunchLeaseIsBoundedAndClearable() throws {
        let fileManager = FileManager.default
        let base = fileManager.temporaryDirectory
            .appendingPathComponent("pushgo-cold-launch-lease-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: base) }
        let encoded = try encodedSession(
            sessionID: "cold-launch-once",
            fixture: "empty.clean",
            allowsSystemColdLaunch: true
        )
        let now = Date(timeIntervalSince1970: 1_787_918_400)

        try PushGoAutomationContext.writeQualityColdLaunchLease(
            encodedSession: encoded,
            baseURL: base,
            expiresAt: now.addingTimeInterval(60),
            fileManager: fileManager
        )

        #expect(
            PushGoAutomationContext.loadQualityColdLaunchLease(
                baseURL: base,
                now: now,
                fileManager: fileManager
            ) == encoded
        )
        #expect(
            PushGoAutomationContext.loadQualityColdLaunchLease(
                baseURL: base,
                now: now,
                fileManager: fileManager
            ) == encoded
        )
        PushGoAutomationContext.clearQualityColdLaunchLease(
            baseURL: base,
            fileManager: fileManager
        )
        #expect(
            PushGoAutomationContext.loadQualityColdLaunchLease(
                baseURL: base,
                now: now,
                fileManager: fileManager
            ) == nil
        )
    }

    @Test("expired cold-launch lease cannot reactivate a quality session")
    func expiredColdLaunchLeaseIsRejected() throws {
        let fileManager = FileManager.default
        let base = fileManager.temporaryDirectory
            .appendingPathComponent("pushgo-expired-cold-launch-lease-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: base) }
        let encoded = try encodedSession(
            sessionID: "cold-launch-expired",
            fixture: "empty.clean",
            allowsSystemColdLaunch: true
        )
        let now = Date(timeIntervalSince1970: 1_787_918_400)
        try PushGoAutomationContext.writeQualityColdLaunchLease(
            encodedSession: encoded,
            baseURL: base,
            expiresAt: now.addingTimeInterval(-1),
            fileManager: fileManager
        )

        #expect(
            PushGoAutomationContext.loadQualityColdLaunchLease(
                baseURL: base,
                now: now,
                fileManager: fileManager
            ) == nil
        )
        #expect(
            PushGoAutomationContext.loadQualityColdLaunchLease(
                baseURL: base,
                now: now,
                fileManager: fileManager
            ) == nil
        )
    }

    @Test("cold-launch lease rejects a session without explicit opt-in")
    func coldLaunchLeaseRequiresExplicitOptIn() throws {
        let fileManager = FileManager.default
        let base = fileManager.temporaryDirectory
            .appendingPathComponent("pushgo-cold-launch-opt-in-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: base) }
        let encoded = try encodedSession(
            sessionID: "cold-launch-disabled",
            fixture: "empty.clean"
        )

        #expect(throws: PushGoQualitySessionError.systemColdLaunchNotAllowed) {
            try PushGoAutomationContext.writeQualityColdLaunchLease(
                encodedSession: encoded,
                baseURL: base,
                expiresAt: Date().addingTimeInterval(60),
                fileManager: fileManager
            )
        }
    }

    private func encodedSession(
        sessionID: String,
        fixture: String,
        faults: [String: Any]? = nil,
        messageRefreshScenario: String? = nil,
        eventCloseScenario: String? = nil,
        channelMutationScenario: String? = nil,
        expectedChannelMutationGatewayURL: String? = nil,
        legacyStore: String? = nil,
        allowsSystemColdLaunch: Bool = false
    ) throws -> String {
        var payload: [String: Any] = [
            "schema_version": 1,
            "session_id": sessionID,
            "fixture": fixture,
        ]
        if let faults {
            payload["faults"] = faults
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
        if let expectedChannelMutationGatewayURL {
            payload["expected_channel_mutation_gateway_url"] = expectedChannelMutationGatewayURL
        }
        if let legacyStore {
            payload["legacy_store"] = legacyStore
        }
        payload["allows_system_cold_launch"] = allowsSystemColdLaunch
        return try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
            .base64EncodedString()
    }
}


private final class QualityDefaultsChildBundleAnchor: NSObject {}

private func qualityDefaultsChildExecutable() throws -> URL {
    let products = Bundle(for: QualityDefaultsChildBundleAnchor.self).bundleURL.deletingLastPathComponent()
    let executable = products.appendingPathComponent("PushGoSQLiteMigrationChild")
    return try #require(FileManager.default.isExecutableFile(atPath: executable.path) ? executable : nil)
}
