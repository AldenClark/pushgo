import Foundation
import Testing
@testable import PushGoAppleCore

@Suite("Quality runtime profile")
struct QualityRuntimeProfileTests {
    @Test("accepts the small typed session contract used by UI runners")
    func acceptsTypedSession() throws {
        let encoded = try encodedSession(
            sessionID: "ios-pr-123_retry-1",
            fixture: "messages.standard",
            faults: [
                "message_refresh_delay_ms": 2_500,
                "fail_gateway_switch_validation_once": true,
                "fail_gateway_switch_commit_once": true,
                "fail_notification_material_persistence_once": true,
            ]
        )

        let descriptor = try PushGoAutomationContext.decodeQualitySession(encoded)

        #expect(descriptor.schemaVersion == 1)
        #expect(descriptor.sessionID == "ios-pr-123_retry-1")
        #expect(descriptor.fixture == .messagesStandard)
        #expect(descriptor.faults.messageLoadDelayMilliseconds == nil)
        #expect(descriptor.faults.messageRefreshDelayMilliseconds == 2_500)
        #expect(descriptor.faults.failMessageLoad == false)
        #expect(descriptor.faults.failGatewaySwitchValidationOnce)
        #expect(descriptor.faults.failGatewaySwitchCommitOnce)
        #expect(descriptor.faults.failNotificationMaterialPersistenceOnce)
        #expect(descriptor.messageRefreshScenario == .none)
        #expect(descriptor.eventCloseScenario == .none)
        #expect(descriptor.channelMutationScenario == .none)
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

    @Test("decodes the typed event close round trip")
    func decodesEventCloseScenario() throws {
        let encoded = try encodedSession(
            sessionID: "event-close-result",
            fixture: "event.standard",
            eventCloseScenario: "accepted_and_delivered"
        )

        let descriptor = try PushGoAutomationContext.decodeQualitySession(encoded)

        #expect(descriptor.eventCloseScenario == .acceptedAndDelivered)
    }

    @Test("decodes the typed channel mutation round trip")
    func decodesChannelMutationScenario() throws {
        let encoded = try encodedSession(
            sessionID: "channel-mutation-result",
            fixture: "channels.standard",
            channelMutationScenario: "accepted"
        )

        let descriptor = try PushGoAutomationContext.decodeQualitySession(encoded)

        #expect(descriptor.fixture == .channelsStandard)
        #expect(descriptor.channelMutationScenario == .accepted)
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

    private func encodedSession(
        sessionID: String,
        fixture: String,
        faults: [String: Any]? = nil,
        messageRefreshScenario: String? = nil,
        eventCloseScenario: String? = nil,
        channelMutationScenario: String? = nil
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
        return try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
            .base64EncodedString()
    }
}
