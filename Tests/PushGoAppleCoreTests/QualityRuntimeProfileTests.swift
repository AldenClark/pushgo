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
                "message_search_delay_ms": 2_000,
                "fail_gateway_switch_validation_once": true,
                "fail_gateway_switch_commit_once": true,
                "fail_notification_material_persistence_once": true,
                "fail_channel_subscription_persistence_once": true,
            ]
        )

        let descriptor = try PushGoAutomationContext.decodeQualitySession(encoded)

        #expect(descriptor.schemaVersion == 1)
        #expect(descriptor.sessionID == "ios-pr-123_retry-1")
        #expect(descriptor.fixture == .messagesStandard)
        #expect(descriptor.faults.messageLoadDelayMilliseconds == nil)
        #expect(descriptor.faults.messageRefreshDelayMilliseconds == 2_500)
        #expect(descriptor.faults.messageSearchDelayMilliseconds == 2_000)
        #expect(descriptor.faults.failMessageLoad == false)
        #expect(descriptor.faults.failGatewaySwitchValidationOnce)
        #expect(descriptor.faults.failGatewaySwitchCommitOnce)
        #expect(descriptor.faults.failNotificationMaterialPersistenceOnce)
        #expect(descriptor.faults.failChannelSubscriptionPersistenceOnce)
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
        let encoded = try encodedSession(
            sessionID: "channel-mutation-result",
            fixture: "channels.standard",
            channelMutationScenario: "accepted"
        )

        let descriptor = try PushGoAutomationContext.decodeQualitySession(encoded)

        #expect(descriptor.fixture == .channelsStandard)
        #expect(descriptor.channelMutationScenario == .accepted)
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
        payload["allows_system_cold_launch"] = allowsSystemColdLaunch
        return try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
            .base64EncodedString()
    }
}
