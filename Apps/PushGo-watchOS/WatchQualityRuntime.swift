#if DEBUG
import Foundation
import SQLite3

enum WatchQualityRuntime {
    private static let profileEnvironmentKey = "PUSHGO_QUALITY_PROFILE"
    private static let scenarioEnvironmentKey = "PUSHGO_QUALITY_SCENARIO"
    private static let sessionEnvironmentKey = "PUSHGO_QUALITY_SESSION_ID"
    private static let preparedSessionDefaultsKey = "io.ethan.pushgo.watch.quality.prepared-session"

    static var isHermeticRequested: Bool {
        normalizedEnvironmentValue(profileEnvironmentKey) == "hermetic"
    }

    static func prepareLegacyStoreIfRequested(
        fileManager: FileManager,
        appGroupIdentifier: String
    ) throws {
        guard isHermeticRequested,
              normalizedEnvironmentValue(scenarioEnvironmentKey) == "watch.migration",
              let sessionID = normalizedEnvironmentValue(sessionEnvironmentKey)
        else { return }

        let defaults = UserDefaults.standard
        guard defaults.string(forKey: preparedSessionDefaultsKey) != sessionID else { return }

        let directory = try AppConstants.appLocalDatabaseDirectory(
            fileManager: fileManager,
            appGroupIdentifier: appGroupIdentifier
        )
        let storeURL = directory.appendingPathComponent(AppConstants.databaseStoreFilename)
        for suffix in ["", "-wal", "-shm"] {
            let member = URL(fileURLWithPath: storeURL.path + suffix)
            if fileManager.fileExists(atPath: member.path) {
                try fileManager.removeItem(at: member)
            }
        }

        var db: OpaquePointer?
        let openResult = sqlite3_open_v2(
            storeURL.path,
            &db,
            SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard openResult == SQLITE_OK, let db else {
            if let db { sqlite3_close(db) }
            throw WatchQualityRuntimeError.legacyStorePreparationFailed("open code \(openResult)")
        }
        defer { sqlite3_close(db) }

        try executeLegacySQL(
            """
            CREATE TABLE watch_light_messages (
                message_id TEXT PRIMARY KEY NOT NULL,
                title TEXT NOT NULL,
                body TEXT NOT NULL,
                image_url TEXT,
                url TEXT,
                severity TEXT,
                received_at REAL NOT NULL,
                is_read INTEGER NOT NULL,
                entity_type TEXT NOT NULL,
                entity_id TEXT,
                notification_request_id TEXT
            );
            INSERT INTO watch_light_messages (
                message_id, title, body, severity, received_at, is_read, entity_type
            ) VALUES (
                'quality-watch-legacy-message',
                'Legacy watch alert',
                'Persisted before the upgrade.',
                'normal',
                1788000120,
                0,
                'message'
            );

            CREATE TABLE watch_light_events (
                event_id TEXT PRIMARY KEY NOT NULL,
                title TEXT NOT NULL,
                summary TEXT,
                state TEXT,
                severity TEXT,
                image_url TEXT,
                updated_at REAL NOT NULL
            );
            INSERT INTO watch_light_events (
                event_id, title, summary, state, severity, updated_at
            ) VALUES (
                'quality-watch-legacy-event',
                'Legacy payments incident',
                'Legacy checkout errors remain visible.',
                'RESOLVED',
                'high',
                1788000120
            );

            CREATE TABLE watch_light_things (
                thing_id TEXT PRIMARY KEY NOT NULL,
                title TEXT NOT NULL,
                summary TEXT,
                attrs_json TEXT,
                image_url TEXT,
                updated_at REAL NOT NULL
            );
            INSERT INTO watch_light_things (
                thing_id, title, summary, attrs_json, updated_at
            ) VALUES (
                'quality-watch-legacy-thing',
                'Legacy checkout API',
                'Legacy region remains available.',
                '{"region":"legacy-eu","version":"17"}',
                1788000120
            );

            CREATE TABLE app_settings (
                id TEXT PRIMARY KEY NOT NULL,
                updated_at REAL NOT NULL DEFAULT 0
            );
            """,
            db: db
        )
    }

    @MainActor
    static func prepareIfRequested(environment: AppEnvironment) async throws {
        guard isHermeticRequested else { return }

        guard let sessionID = normalizedEnvironmentValue(sessionEnvironmentKey) else {
            throw WatchQualityRuntimeError.missingSession
        }
        let scenario = normalizedEnvironmentValue(scenarioEnvironmentKey)
        guard scenario == "watch.standard"
                || scenario == "watch.migration"
                || scenario == "watch.message-load-failure"
        else {
            throw WatchQualityRuntimeError.unsupportedScenario(
                scenario ?? "<missing>"
            )
        }

        let defaults = UserDefaults.standard
        if defaults.string(forKey: preparedSessionDefaultsKey) != sessionID {
            if scenario != "watch.migration" {
                try await environment.dataStore.clearWatchLightStore()
            }
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

    private static func executeLegacySQL(_ sql: String, db: OpaquePointer) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(db, sql, nil, nil, &errorMessage)
        guard result == SQLITE_OK else {
            let message: String
            if let errorMessage {
                message = String(cString: errorMessage)
            } else {
                message = "code \(result)"
            }
            sqlite3_free(errorMessage)
            throw WatchQualityRuntimeError.legacyStorePreparationFailed(message)
        }
    }
}

private enum WatchQualityRuntimeError: LocalizedError {
    case missingSession
    case unsupportedScenario(String)
    case legacyStorePreparationFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingSession:
            return "Hermetic watch quality launch requires an App-owned session identifier."
        case let .unsupportedScenario(scenario):
            return "Unsupported hermetic watch quality scenario: \(scenario)."
        case let .legacyStorePreparationFailed(reason):
            return "Unable to prepare the App-owned legacy watch store: \(reason)."
        }
    }
}
#endif
