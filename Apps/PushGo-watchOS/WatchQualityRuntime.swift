#if DEBUG
import Foundation

enum WatchQualityRuntime {
    private static let profileEnvironmentKey = "PUSHGO_QUALITY_PROFILE"
    private static let scenarioEnvironmentKey = "PUSHGO_QUALITY_SCENARIO"
    private static let sessionEnvironmentKey = "PUSHGO_QUALITY_SESSION_ID"
    private static let preparedSessionDefaultsKey = "io.ethan.pushgo.watch.quality.prepared-session"

    static var isHermeticRequested: Bool {
        normalizedEnvironmentValue(profileEnvironmentKey) == "hermetic"
    }

    @MainActor
    static func prepareIfRequested(environment: AppEnvironment) async throws {
        guard isHermeticRequested else { return }

        guard let sessionID = normalizedEnvironmentValue(sessionEnvironmentKey) else {
            throw WatchQualityRuntimeError.missingSession
        }
        let scenario = normalizedEnvironmentValue(scenarioEnvironmentKey)
        guard scenario == "watch.standard" || scenario == "watch.message-load-failure" else {
            throw WatchQualityRuntimeError.unsupportedScenario(
                scenario ?? "<missing>"
            )
        }

        let defaults = UserDefaults.standard
        if defaults.string(forKey: preparedSessionDefaultsKey) != sessionID {
            try await environment.dataStore.clearWatchLightStore()
            let snapshot = standardSnapshot()
            try await environment.dataStore.mergeWatchMirrorSnapshot(snapshot)
            defaults.set(sessionID, forKey: preparedSessionDefaultsKey)
        }

        if scenario == "watch.message-load-failure" {
            await environment.dataStore.enableQualityWatchMessageLoadFailure()
        }

        await environment.refreshWatchLightCountsAndNotify()
    }

    private static func standardSnapshot() -> WatchMirrorSnapshot {
        let receivedAt = Date(timeIntervalSince1970: 1_788_000_000)
        let messages = [
            WatchLightMessage(
                messageId: "quality-watch-message-001",
                title: "Gateway health warning",
                body: "Primary API latency is above budget.",
                imageURL: nil,
                url: URL(string: "https://example.com/incidents/gateway"),
                severity: "critical",
                receivedAt: receivedAt,
                isRead: false,
                entityType: "message",
                entityId: nil,
                notificationRequestId: "quality-watch-request-001"
            ),
            WatchLightMessage(
                messageId: "quality-watch-message-002",
                title: "Database recovered",
                body: "Replica lag returned to normal.",
                imageURL: nil,
                url: nil,
                severity: "normal",
                receivedAt: receivedAt.addingTimeInterval(-60),
                isRead: false,
                entityType: "message",
                entityId: nil,
                notificationRequestId: "quality-watch-request-002"
            ),
        ]
        let events = [
            WatchLightEvent(
                eventId: "quality-watch-event-001",
                title: "Payments incident",
                summary: "Checkout errors exceeded threshold.",
                state: "ONGOING",
                severity: "high",
                decryptionState: nil,
                imageURL: nil,
                updatedAt: receivedAt.addingTimeInterval(-120)
            ),
        ]
        let things = [
            WatchLightThing(
                thingId: "quality-watch-thing-001",
                title: "Checkout API",
                summary: "Degraded in eu-west.",
                attrsJSON: #"{"region":"eu-west","version":"42"}"#,
                decryptionState: nil,
                imageURL: nil,
                updatedAt: receivedAt.addingTimeInterval(-180)
            ),
        ]
        return WatchMirrorSnapshot(
            generation: 1,
            mode: .standalone,
            messages: messages,
            events: events,
            things: things,
            exportedAt: receivedAt,
            contentDigest: WatchMirrorSnapshot.contentDigest(
                messages: messages,
                events: events,
                things: things
            )
        )
    }

    private static func normalizedEnvironmentValue(_ key: String) -> String? {
        let value = ProcessInfo.processInfo.environment[key]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? nil : value
    }
}

private enum WatchQualityRuntimeError: LocalizedError {
    case missingSession
    case unsupportedScenario(String)

    var errorDescription: String? {
        switch self {
        case .missingSession:
            return "Hermetic watch quality launch requires an App-owned session identifier."
        case let .unsupportedScenario(scenario):
            return "Unsupported hermetic watch quality scenario: \(scenario)."
        }
    }
}
#endif
