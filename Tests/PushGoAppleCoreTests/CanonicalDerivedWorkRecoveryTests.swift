import Foundation
import GRDB
import Testing
@testable import PushGoAppleCore

struct CanonicalDerivedWorkRecoveryTests {
    @Test
    func failedSpotlightProjectionRemainsRetryableAndWakesWithoutNewIngress() async throws {
        try await withIsolatedAutomationStorage { _, appGroupIdentifier in
            let indexer = ControllableFailingSpotlightIndexer()
            let store = LocalDataStore(
                appGroupIdentifier: appGroupIdentifier,
                spotlightIndexer: indexer,
                canonicalDerivedWorkRetryDelay: 0.2
            )
            let message = PushMessage(
                id: UUID(uuidString: "40000000-0000-0000-0000-000000000001")!,
                messageId: "derived-retry-001",
                title: "Derived retry probe",
                body: "Spotlight is temporarily unavailable",
                channel: "tests",
                receivedAt: Date(timeIntervalSince1970: 1_800_100_000)
            )

            _ = try await store.persistNotificationMessageIfNeeded(message)

            let retrying = try await waitForWork(
                appGroupIdentifier: appGroupIdentifier,
                messageID: message.id,
                kind: "search",
                matching: { $0.state == "retry_wait" && $0.attemptCount >= 1 }
            )
            #expect(retrying.lastError?.contains("injected Spotlight failure") == true)

            // The external Spotlight projection is unavailable, but the
            // canonical Store remains the user-visible source of truth. Keep
            // this assertion on the real read/search APIs so a transactional
            // regression cannot hide behind a durable retry row.
            let canonicalDuringFailure = try await store.loadMessages()
                .first { $0.messageId == message.messageId }
            #expect(canonicalDuringFailure?.title == message.title)
            #expect(canonicalDuringFailure?.body == message.body)
            #expect(try await store.searchMessagesCount(query: "Derived retry probe") == 1)
            await indexer.allowSuccess()

            // No new ingress or explicit drain request follows. The worker must
            // wake itself from the durable next_attempt timestamp.
            let completed = try await waitForWork(
                appGroupIdentifier: appGroupIdentifier,
                messageID: message.id,
                kind: "search",
                matching: { $0.state == "completed" }
            )
            #expect(completed.attemptCount >= retrying.attemptCount)
            #expect(completed.lastError == nil)
            #expect(await indexer.indexAttempts >= 2)
            #expect(try await store.searchMessagesCount(query: "Derived retry probe") == 1)
        }
    }

    @Test
    func reportableLiveActivityFailureIsRetriedBeforeCompletion() async throws {
        try await withIsolatedAutomationStorage { _, appGroupIdentifier in
            let handler = ControllableFailingLiveActivityHandler()
            let store = LocalDataStore(
                appGroupIdentifier: appGroupIdentifier,
                spotlightIndexer: nil,
                canonicalDerivedWorkRetryDelay: 0.2,
                canonicalLiveActivityHandler: { message in
                    try await handler.handle(message)
                }
            )
            let message = PushMessage(
                id: UUID(uuidString: "40000000-0000-0000-0000-000000000002")!,
                messageId: "derived-live-retry-001",
                title: "Live Activity retry probe",
                body: "Activity request is temporarily unavailable",
                channel: "tests",
                receivedAt: Date(timeIntervalSince1970: 1_800_100_001),
                rawPayload: [
                    "entity_type": AnyCodable("event"),
                    "entity_id": AnyCodable("event-live-retry-001"),
                    "event_id": AnyCodable("event-live-retry-001"),
                    "event_state": AnyCodable("open"),
                ]
            )

            _ = try await store.persistNotificationMessageIfNeeded(message)

            let retrying = try await waitForWork(
                appGroupIdentifier: appGroupIdentifier,
                messageID: message.id,
                kind: "live_activity",
                matching: { $0.state == "retry_wait" && $0.attemptCount >= 1 }
            )
            #expect(retrying.lastError?.contains("injected Live Activity failure") == true)
            await handler.allowSuccess()

            let completed = try await waitForWork(
                appGroupIdentifier: appGroupIdentifier,
                messageID: message.id,
                kind: "live_activity",
                matching: { $0.state == "completed" }
            )
            #expect(completed.attemptCount >= retrying.attemptCount)
            #expect(await handler.attempts >= 2)
        }
    }

    @Test
    func notificationContextWriteFailureStaysRetryableUntilFilesystemRecovers() async throws {
        try await withIsolatedAutomationStorage { _, appGroupIdentifier in
            let store = LocalDataStore(
                appGroupIdentifier: appGroupIdentifier,
                spotlightIndexer: nil,
                canonicalDerivedWorkRetryDelay: 0.2
            )
            let snapshotURL = try #require(NotificationContextSnapshotStore.snapshotFileURL(
                appGroupIdentifier: appGroupIdentifier
            ))
            let blockingFile = try blockSnapshotDirectory(for: snapshotURL)
            let message = PushMessage(
                id: UUID(uuidString: "40000000-0000-0000-0000-000000000003")!,
                messageId: "derived-context-retry-001",
                title: "Notification context retry probe",
                body: "Context storage is temporarily unavailable",
                channel: "tests",
                receivedAt: Date(timeIntervalSince1970: 1_800_100_002),
                rawPayload: [
                    "entity_type": AnyCodable("event"),
                    "entity_id": AnyCodable("event-context-retry-001"),
                    "event_id": AnyCodable("event-context-retry-001"),
                ]
            )

            _ = try await store.persistNotificationMessageIfNeeded(message)
            let retrying = try await waitForWork(
                appGroupIdentifier: appGroupIdentifier,
                messageID: message.id,
                kind: "notification_context",
                matching: { $0.state == "retry_wait" }
            )
            #expect(retrying.attemptCount >= 1)

            try FileManager.default.removeItem(at: blockingFile)
            let completed = try await waitForWork(
                appGroupIdentifier: appGroupIdentifier,
                messageID: message.id,
                kind: "notification_context",
                matching: { $0.state == "completed" }
            )
            #expect(completed.attemptCount >= retrying.attemptCount)
            #expect(NotificationContextSnapshotStore.load(
                appGroupIdentifier: appGroupIdentifier
            )?.events["event-context-retry-001"] != nil)
        }
    }

    @Test
    func systemSnapshotWriteFailureStaysRetryableUntilFilesystemRecovers() async throws {
        try await withIsolatedAutomationStorage { _, appGroupIdentifier in
            let store = LocalDataStore(
                appGroupIdentifier: appGroupIdentifier,
                spotlightIndexer: nil,
                canonicalDerivedWorkRetryDelay: 0.2
            )
            let snapshotURL = try #require(PushGoSystemSnapshotStore.snapshotFileURL(
                appGroupIdentifier: appGroupIdentifier
            ))
            let blockingFile = try blockSnapshotDirectory(for: snapshotURL)
            let message = PushMessage(
                id: UUID(uuidString: "40000000-0000-0000-0000-000000000004")!,
                messageId: "derived-system-snapshot-retry-001",
                title: "System snapshot retry probe",
                body: "System snapshot storage is temporarily unavailable",
                channel: "tests",
                receivedAt: Date(timeIntervalSince1970: 1_800_100_003)
            )

            _ = try await store.persistNotificationMessageIfNeeded(message)
            let retrying = try await waitForWork(
                appGroupIdentifier: appGroupIdentifier,
                messageID: message.id,
                kind: "system_snapshot",
                matching: { $0.state == "retry_wait" }
            )
            #expect(retrying.attemptCount >= 1)

            try FileManager.default.removeItem(at: blockingFile)
            let completed = try await waitForWork(
                appGroupIdentifier: appGroupIdentifier,
                messageID: message.id,
                kind: "system_snapshot",
                matching: { $0.state == "completed" }
            )
            #expect(completed.attemptCount >= retrying.attemptCount)
            #expect(PushGoSystemSnapshotStore.load(
                appGroupIdentifier: appGroupIdentifier
            )?.counts.totalMessages == 1)
        }
    }

    @Test
    func snapshotThrowingWritesSurfaceFilesystemFailure() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pushgo-derived-write-failure-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let blockingParent = root.appendingPathComponent("not-a-directory")
        try Data([0x01]).write(to: blockingParent)
        let destination = blockingParent.appendingPathComponent("snapshot.bin")

        let notificationSnapshot = NotificationContextSnapshot(
            schemaVersion: NotificationContextSnapshot.schemaVersion,
            generatedAtEpochMs: 1,
            source: "tests",
            events: [:],
            things: [:]
        )
        #expect(throws: (any Error).self) {
            try NotificationContextSnapshotStore.writeOrThrow(
                notificationSnapshot,
                to: destination
            )
        }

        #expect(throws: (any Error).self) {
            try PushGoSystemSnapshotStore.writeOrThrow(
                .empty(source: "tests"),
                to: destination
            )
        }
    }

    private struct WorkSnapshot: Sendable {
        let state: String
        let attemptCount: Int
        let lastError: String?
    }

    private struct TimedOutWaitingForWork: Error {}

    private actor ControllableFailingSpotlightIndexer: PushGoSpotlightIndexing {
        private(set) var indexAttempts = 0
        private var shouldFail = true

        func index(_ summaries: [PushGoSystemSummary]) async throws {
            guard !summaries.isEmpty else { return }
            indexAttempts += 1
            if shouldFail {
                throw InjectedFailure()
            }
        }

        func allowSuccess() {
            shouldFail = false
        }

        func delete(_ identifiers: [PushGoSpotlightIdentifier]) async throws {
            _ = identifiers
        }

        func deleteAll() async throws {}

        private struct InjectedFailure: Error, CustomStringConvertible {
            let description = "injected Spotlight failure"
        }
    }

    private actor ControllableFailingLiveActivityHandler {
        private(set) var attempts = 0
        private var shouldFail = true

        func handle(_ message: PushMessage) throws {
            _ = message
            attempts += 1
            if shouldFail {
                throw InjectedFailure()
            }
        }

        func allowSuccess() {
            shouldFail = false
        }

        private struct InjectedFailure: Error, CustomStringConvertible {
            let description = "injected Live Activity failure"
        }
    }

    private func waitForWork(
        appGroupIdentifier: String,
        messageID: UUID,
        kind: String,
        matching predicate: (WorkSnapshot) -> Bool
    ) async throws -> WorkSnapshot {
        for _ in 0..<400 {
            if let snapshot = try readWork(
                appGroupIdentifier: appGroupIdentifier,
                messageID: messageID,
                kind: kind
            ), predicate(snapshot) {
                return snapshot
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw TimedOutWaitingForWork()
    }

    private func blockSnapshotDirectory(for snapshotURL: URL) throws -> URL {
        let directoryURL = snapshotURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directoryURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data([0x01]).write(to: directoryURL)
        return directoryURL
    }

    private func readWork(
        appGroupIdentifier: String,
        messageID: UUID,
        kind: String
    ) throws -> WorkSnapshot? {
        let databaseURL = try AppConstants.appLocalDatabaseDirectory(
            fileManager: .default,
            appGroupIdentifier: appGroupIdentifier
        )
        .appendingPathComponent(AppConstants.databaseStoreFilename)
        let queue = try DatabaseQueue(path: databaseURL.path)
        return try queue.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT state, attempt_count, last_error
                    FROM canonical_derived_work
                    WHERE local_message_id = ? AND kind = ?;
                    """,
                arguments: [messageID.uuidString, kind]
            ) else { return nil }
            return WorkSnapshot(
                state: row["state"],
                attemptCount: row["attempt_count"],
                lastError: row["last_error"]
            )
        }
    }
}
