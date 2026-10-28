import Foundation
import Darwin
import GRDB
import Testing
@testable import PushGoAppleCore

/// The real host writer pauses in another process, after constructing its
/// snapshot. Markers coordinate the fault only; database and decoded output
/// assertions in each test remain the product oracles.
final class SnapshotPublicationChild {
    private let process: Process
    private let controlDirectory: URL
    private let releasePipe = Pipe()

    init(root: URL, appGroupIdentifier: String, failFirstWrite: Bool = false) throws {
        controlDirectory = root.appendingPathComponent("snapshot-publication-control", isDirectory: true)
        try FileManager.default.createDirectory(at: controlDirectory, withIntermediateDirectories: true)
        process = Process()
        process.executableURL = Bundle(for: SnapshotChildBundleAnchor.self).bundleURL
            .deletingLastPathComponent().appendingPathComponent("PushGoSQLiteMigrationChild")
        process.arguments = ["snapshot-pause-before-publish", appGroupIdentifier, controlDirectory.path, failFirstWrite ? "fail" : "succeed"]
        process.standardInput = releasePipe
        var environment = ProcessInfo.processInfo.environment
        environment["PUSHGO_AUTOMATION_STORAGE_ROOT"] = root.path
        process.environment = environment
        try process.run()
    }

    deinit {
        try? releasePipe.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
    }

    func waitUntilPaused() async throws {
        for _ in 0..<400 {
            if !process.isRunning {
                process.waitUntilExit()
                try #require(process.isRunning, "Snapshot child exited before a live pause: status \(process.terminationStatus), reason \(process.terminationReason.rawValue), paused=\(FileManager.default.fileExists(atPath: controlDirectory.appendingPathComponent("paused").path))")
            }
            if FileManager.default.fileExists(atPath: controlDirectory.appendingPathComponent("paused").path) { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw FixtureTimeout()
    }

    func releaseAndWait() async throws {
        try releasePipe.fileHandleForWriting.write(contentsOf: Data([1]))
        try releasePipe.fileHandleForWriting.close()
        for _ in 0..<400 {
            if !process.isRunning {
                process.waitUntilExit()
                try #require(process.terminationReason == .exit)
                try #require(process.terminationStatus == 0)
                return
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw FixtureTimeout()
    }

    private struct FixtureTimeout: Error {}
}

private final class SnapshotChildBundleAnchor: NSObject {}

struct CanonicalDerivedWorkRecoveryTests {
    @Test
    func snapshotEnqueueFailureRollsBackBatchThenRetryPublishesAccurateMessageAndEntitySummaries() async throws {
        try await withIsolatedAutomationStorage { _, appGroupIdentifier in
            let store = LocalDataStore(appGroupIdentifier: appGroupIdentifier, spotlightIndexer: nil)
            let message = PushMessage(messageId: "atomic-message", title: "Canonical message", body: "Message body")
            let event = PushMessage(
                messageId: "atomic-event", title: "Open critical event", body: "Event body",
                receivedAt: Date(timeIntervalSince1970: 1_800_100_000),
                rawPayload: [
                    "entity_type": AnyCodable("event"), "entity_id": AnyCodable("atomic-event-id"),
                    "event_id": AnyCodable("atomic-event-id"), "event_state": AnyCodable("open"),
                    "severity": AnyCodable("critical"),
                ]
            )
            let thing = PushMessage(
                messageId: "atomic-thing", title: "Current object", body: "Object body",
                rawPayload: ["entity_type": AnyCodable("thing"), "entity_id": AnyCodable("atomic-thing-id"), "thing_id": AnyCodable("atomic-thing-id")]
            )
            let queue = try databaseQueue(appGroupIdentifier: appGroupIdentifier)
            try await queue.write { db in
                try db.execute(sql: """
                    CREATE TRIGGER reject_snapshot_work BEFORE INSERT ON canonical_derived_work
                    WHEN NEW.work_id = 'system_snapshot'
                    BEGIN SELECT RAISE(ABORT, 'injected snapshot enqueue failure'); END;
                    """)
            }
            do {
                _ = try await store.persistNotificationMessagesIfNeeded([message, event, thing])
                Issue.record("Canonical batch committed without its required snapshot task")
            } catch {
                #expect(String(describing: error).contains("injected snapshot enqueue failure"))
            }
            #expect(try await store.loadMessages().isEmpty)
            #expect(try await store.loadEventMessagesForProjectionPage(before: nil, limit: 10).isEmpty)
            #expect(try await store.loadThingMessagesForProjectionPage(before: nil, limit: 10).isEmpty)
            #expect(try readWork(appGroupIdentifier: appGroupIdentifier, kind: "system_snapshot") == nil)
            try await queue.write { db in try db.execute(sql: "DROP TRIGGER reject_snapshot_work;") }

            _ = try await store.persistNotificationMessagesIfNeeded([message, event, thing])
            #expect(await store.drainDerivedWorkForBackgroundRefresh())
            var snapshot = try #require(PushGoSystemSnapshotStore.load(appGroupIdentifier: appGroupIdentifier))
            #expect(snapshot.counts.totalMessages == 1)
            #expect(snapshot.counts.unreadMessages == 1)
            #expect(snapshot.recentMessages.map(\.title) == [message.title])
            #expect(snapshot.counts.criticalEvents == 1)
            #expect(snapshot.criticalEvents.first?.title == event.title)
            #expect(snapshot.criticalEvents.first?.status == "open")
            #expect(snapshot.latestObjectStates.first?.title == thing.title)
            #expect(snapshot.latestObjectStates.first?.bodyPreview == thing.body)
            #expect(try readWork(appGroupIdentifier: appGroupIdentifier, kind: "system_snapshot")?.generation == 1)

            var updatedEvent = event
            updatedEvent.id = UUID()
            updatedEvent.messageId = "atomic-event-update"
            updatedEvent.title = "Updated critical event"
            updatedEvent.receivedAt = event.receivedAt.addingTimeInterval(1)
            updatedEvent.rawPayload["event_state"] = AnyCodable("closed")
            updatedEvent.rawPayload["title"] = AnyCodable(updatedEvent.title)
            _ = try await store.persistNotificationMessageIfNeeded(updatedEvent)
            #expect(await store.drainDerivedWorkForBackgroundRefresh())
            snapshot = try #require(PushGoSystemSnapshotStore.load(appGroupIdentifier: appGroupIdentifier))
            #expect(snapshot.criticalEvents.map(\.title) == [updatedEvent.title])
            #expect(snapshot.criticalEvents.first?.status == "closed")
            #expect(snapshot.latestObjectStates.first?.title == thing.title)
        }
    }

    @Test
    func newNotificationDuringSnapshotWriteIsVisibleWithoutAnotherIngress() async throws {
        try await withIsolatedAutomationStorage { root, appGroupIdentifier in
            let child = try SnapshotPublicationChild(root: root, appGroupIdentifier: appGroupIdentifier)
            try await child.waitUntilPaused()
            let receiver = LocalDataStore(appGroupIdentifier: appGroupIdentifier, spotlightIndexer: nil)
            _ = try await receiver.persistNotificationMessageIfNeeded(PushMessage(messageId: "second-notification", title: "Second notification", body: "second"))
            try await child.releaseAndWait()
            _ = try await waitForWork(appGroupIdentifier: appGroupIdentifier, kind: "system_snapshot", matching: { $0.state == "completed" })
            let snapshot = try #require(PushGoSystemSnapshotStore.load(appGroupIdentifier: appGroupIdentifier))
            #expect(snapshot.counts.totalMessages == 2)
            #expect(snapshot.counts.unreadMessages == 2)
            #expect(Set(snapshot.recentMessages.map(\.title)) == ["Saved before process exit", "Second notification"])
        }
    }

    @Test
    func processExitAfterClaimRecoversSnapshotFromCanonicalStoreWithoutNewIngress() async throws {
        try await withIsolatedAutomationStorage { root, appGroupIdentifier in
            let executable = Bundle(for: SnapshotChildBundleAnchor.self).bundleURL
                .deletingLastPathComponent().appendingPathComponent("PushGoSQLiteMigrationChild")
            try #require(FileManager.default.isExecutableFile(atPath: executable.path))
            let child = Process()
            child.executableURL = executable
            child.arguments = ["snapshot-crash-before-publish", appGroupIdentifier]
            var environment = ProcessInfo.processInfo.environment
            environment["PUSHGO_AUTOMATION_STORAGE_ROOT"] = root.path
            child.environment = environment
            try child.run()
            defer { if child.isRunning { child.terminate() } }
            try await waitUntil { !child.isRunning }
            child.waitUntilExit()
            #expect(child.terminationReason == .uncaughtSignal)
            #expect(child.terminationStatus == SIGKILL)
            let abandoned = try #require(try readWork(appGroupIdentifier: appGroupIdentifier, kind: "system_snapshot"))
            #expect(abandoned.state == "leased")
            #expect(PushGoSystemSnapshotStore.load(appGroupIdentifier: appGroupIdentifier) == nil)

            // Advance only the recorded lease deadline; the child really died
            // while owning it. Avoid spending the production 60-second lease in
            // every host test while still exercising the startup/wake claimant.
            let queue = try databaseQueue(appGroupIdentifier: appGroupIdentifier)
            try await queue.write { db in
                try db.execute(
                    sql: "UPDATE canonical_derived_work SET lease_until_epoch_ms = ? WHERE work_id = 'system_snapshot';",
                    arguments: [Int64(Date().addingTimeInterval(0.1).timeIntervalSince1970 * 1_000)]
                )
            }
            let reopened = LocalDataStore(appGroupIdentifier: appGroupIdentifier, spotlightIndexer: nil)
            let message = try #require(try await reopened.loadMessages().first)
            #expect(message.messageId == "snapshot-process-exit")
            #expect(message.title == "Saved before process exit")
            #expect(message.body == "Canonical content must survive the interrupted snapshot write.")
            await reopened.scheduleDerivedWorkDrain() // Same entry used at App startup.
            let recovered = try await waitForWork(
                appGroupIdentifier: appGroupIdentifier, kind: "system_snapshot", matching: { $0.state == "completed" }
            )
            #expect(recovered.generation == abandoned.generation)
            #expect(recovered.leaseGeneration == abandoned.leaseGeneration + 1)
            let snapshot = try #require(PushGoSystemSnapshotStore.load(appGroupIdentifier: appGroupIdentifier))
            #expect(snapshot.counts.totalMessages == 1)
            #expect(snapshot.counts.unreadMessages == 1)
            #expect(snapshot.recentMessages.first?.title == message.title)
        }
    }

    @Test
    func mixedV25SnapshotWorkMigratesOnceWithoutReplayingMessagesOrOtherWork() async throws {
        try await withIsolatedAutomationStorage { root, appGroupIdentifier in
            let messages = (0..<4).map { index in
                PushMessage(messageId: "migration-\(index)", title: "Preserved title \(index)", body: "Preserved body \(index)", isRead: index == 0)
            }
            do {
                let store = LocalDataStore(appGroupIdentifier: appGroupIdentifier, spotlightIndexer: nil)
                try await store.saveMessages(messages)
            }
            LocalDataStore.releaseSharedResourcesForTesting(storageRootURL: root)
            let queue = try databaseQueue(appGroupIdentifier: appGroupIdentifier)
            try await queue.write { db in
                // Frozen v25 schema: the fixture must actually exercise removal
                // of the NOT NULL message foreign key, not just a migration name.
                try db.execute(sql: """
                    DROP TABLE canonical_derived_work;
                    DELETE FROM grdb_migrations WHERE identifier = 'v26_output_system_snapshot_work';
                    CREATE TABLE canonical_derived_work (
                        work_id TEXT PRIMARY KEY NOT NULL,
                        local_message_id TEXT NOT NULL REFERENCES messages(id) ON DELETE CASCADE,
                        kind TEXT NOT NULL,
                        state TEXT NOT NULL DEFAULT 'pending',
                        generation INTEGER NOT NULL DEFAULT 1,
                        lease_owner TEXT,
                        lease_until_epoch_ms INTEGER,
                        lease_generation INTEGER NOT NULL DEFAULT 0,
                        attempt_count INTEGER NOT NULL DEFAULT 0,
                        next_attempt_epoch_ms INTEGER NOT NULL,
                        created_at_epoch_ms INTEGER NOT NULL,
                        updated_at_epoch_ms INTEGER NOT NULL,
                        last_error TEXT,
                        CHECK (kind IN ('search', 'notification_context', 'live_activity', 'system_snapshot')),
                        CHECK (state IN ('pending', 'leased', 'retry_wait', 'completed')),
                        UNIQUE(local_message_id, kind)
                    );
                    CREATE INDEX idx_canonical_derived_work_due
                        ON canonical_derived_work(state, next_attempt_epoch_ms, lease_until_epoch_ms, created_at_epoch_ms);
                    """)
                for (index, state) in ["pending", "leased", "retry_wait", "completed"].enumerated() {
                    try db.execute(sql: """
                        INSERT INTO canonical_derived_work (
                            work_id, local_message_id, kind, state, generation,
                            lease_owner, lease_until_epoch_ms, lease_generation,
                            attempt_count, next_attempt_epoch_ms, created_at_epoch_ms,
                            updated_at_epoch_ms, last_error
                        ) VALUES (?, ?, 'system_snapshot', ?, 9, 'old-process', 9000000000000, 7, 3, 9000000000000, 10, 20, 'old failure');
                        """, arguments: ["\(messages[index].id.uuidString.lowercased()):system_snapshot", messages[index].id.uuidString, state])
                }
                for (index, kind) in ["search", "notification_context", "live_activity"].enumerated() {
                    let state = ["leased", "retry_wait", "completed"][index]
                    try db.execute(sql: """
                        INSERT INTO canonical_derived_work (
                            work_id, local_message_id, kind, state, generation,
                            lease_owner, lease_until_epoch_ms, lease_generation,
                            attempt_count, next_attempt_epoch_ms, created_at_epoch_ms,
                            updated_at_epoch_ms, last_error
                        ) VALUES (?, ?, ?, ?, 5, 'preserved-owner', 0, 4, 2, 0, 10, 20, 'preserved retry reason');
                        """, arguments: ["\(messages[index].id.uuidString.lowercased()):\(kind)", messages[index].id.uuidString, kind, state])
                }
            }
            let otherWorkBefore = try await queue.read { db in
                try Row.fetchAll(db, sql: "SELECT * FROM canonical_derived_work WHERE kind <> 'system_snapshot' ORDER BY work_id;").map(\.description)
            }
            do {
                let migrated = LocalDataStore(appGroupIdentifier: appGroupIdentifier, spotlightIndexer: nil)
                let migration = try await queue.read { db in
                    let snapshotRows = try Row.fetchAll(db, sql: "SELECT * FROM canonical_derived_work WHERE kind = 'system_snapshot';")
                    let only = snapshotRows.first
                    let workID: String? = only?["work_id"]
                    let messageID: String? = only?["local_message_id"]
                    let owner: String? = only?["lease_owner"]
                    let otherRows = try Row.fetchAll(db, sql: "SELECT * FROM canonical_derived_work WHERE kind <> 'system_snapshot' ORDER BY work_id;").map(\.description)
                    return (snapshotRows.count, workID, messageID, owner, otherRows)
                }
                #expect(migration.0 == 1)
                #expect(migration.1 == "system_snapshot")
                #expect(migration.2 == nil)
                #expect(migration.3 == nil)
                #expect(migration.4 == otherWorkBefore)
                #expect(await migrated.drainDerivedWorkForBackgroundRefresh())
            }
            LocalDataStore.releaseSharedResourcesForTesting(storageRootURL: root)
            let reopened = LocalDataStore(appGroupIdentifier: appGroupIdentifier, spotlightIndexer: nil)
            let restored = try await reopened.loadMessages()
            #expect(Set(restored.map(\.title)) == Set(messages.map(\.title)))
            #expect(Set(restored.map(\.body)) == Set(messages.map(\.body)))
            #expect(restored.first { $0.id == messages[0].id }?.isRead == true)
            #expect(try await reopened.messageCounts().unread == 3)
            let work = try #require(try readWork(appGroupIdentifier: appGroupIdentifier, kind: "system_snapshot"))
            #expect(work.state == "completed")
            #expect(work.generation == 1)
            #expect(work.leaseGeneration == 1)
            #expect(work.attemptCount == 0)
            let snapshot = try #require(PushGoSystemSnapshotStore.load(appGroupIdentifier: appGroupIdentifier))
            #expect(snapshot.counts.totalMessages == 4)
            #expect(snapshot.counts.unreadMessages == 3)
            #expect(Set(snapshot.recentMessages.map(\.title)) == Set(messages.map(\.title)))
        }
    }

    @Test
    func notificationBatchProducesOneCurrentSystemSnapshotAndKeepsImmediateReadDeleteTiming() async throws {
        try await withIsolatedAutomationStorage { _, appGroupIdentifier in
            let store = LocalDataStore(appGroupIdentifier: appGroupIdentifier, spotlightIndexer: nil)
            let messages = (0..<12).map { index in
                PushMessage(
                    messageId: "snapshot-batch-\(index)", title: "Batch message \(index)", body: "body \(index)",
                    channel: "tests", receivedAt: Date(timeIntervalSince1970: 1_800_100_000 + Double(index))
                )
            }
            _ = try await store.persistNotificationMessagesIfNeeded(messages)
            #expect(await store.drainDerivedWorkForBackgroundRefresh())
            let work = try #require(try readWork(appGroupIdentifier: appGroupIdentifier, kind: "system_snapshot"))
            #expect(work.state == "completed")
            #expect(work.generation == 1)
            let queue = try databaseQueue(appGroupIdentifier: appGroupIdentifier)
            let workCounts = try await queue.read { db in
                let snapshot = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM canonical_derived_work WHERE kind = 'system_snapshot';")
                let messages = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM canonical_derived_work WHERE kind <> 'system_snapshot';")
                return (snapshot, messages)
            }
            #expect(workCounts.0 == 1)
            #expect(workCounts.1 == messages.count * 3)
            var snapshot = try #require(PushGoSystemSnapshotStore.load(appGroupIdentifier: appGroupIdentifier))
            #expect(snapshot.counts.totalMessages == 12)
            #expect(snapshot.counts.unreadMessages == 12)
            #expect(snapshot.recentMessages.map(\.title) == (7...11).reversed().map { "Batch message \($0)" })

            // These APIs must still publish before returning, without draining
            // the background worker or creating another snapshot obligation.
            try await store.setMessageReadState(id: messages[11].id, isRead: true)
            snapshot = try #require(PushGoSystemSnapshotStore.load(appGroupIdentifier: appGroupIdentifier))
            #expect(snapshot.counts.unreadMessages == 11)
            #expect(snapshot.unreadMessages.map(\.title) == (6...10).reversed().map { "Batch message \($0)" })
            try await store.deleteMessage(id: messages[11].id)
            snapshot = try #require(PushGoSystemSnapshotStore.load(appGroupIdentifier: appGroupIdentifier))
            #expect(snapshot.counts.totalMessages == 11)
            #expect(snapshot.recentMessages.first?.title == "Batch message 10")
            #expect(try readWork(appGroupIdentifier: appGroupIdentifier, kind: "system_snapshot")?.generation == 1)

            // The existing >10 deferred-delete path now owns one durable job.
            #expect(try await store.deleteMessages(ids: Array(messages.prefix(11)).map(\.id)) == 11)
            #expect(await store.drainDerivedWorkForBackgroundRefresh())
            #expect(PushGoSystemSnapshotStore.load(appGroupIdentifier: appGroupIdentifier) == nil)
            #expect(try await store.messageCounts().total == 0)
            #expect(try readWork(appGroupIdentifier: appGroupIdentifier, kind: "system_snapshot")?.generation == 2)
        }
    }

    @Test(arguments: [false, true])
    func changesDuringSnapshotPublicationSurviveOldSuccessOrFailure(failFirstWrite: Bool) async throws {
        try await withIsolatedAutomationStorage { root, appGroupIdentifier in
            let child = try SnapshotPublicationChild(root: root, appGroupIdentifier: appGroupIdentifier, failFirstWrite: failFirstWrite)
            try await child.waitUntilPaused()
            let writer = LocalDataStore(appGroupIdentifier: appGroupIdentifier, spotlightIndexer: nil)
            let reader = LocalDataStore(appGroupIdentifier: appGroupIdentifier, spotlightIndexer: nil)
            let deleter = LocalDataStore(appGroupIdentifier: appGroupIdentifier, spotlightIndexer: nil)
            let original = try #require(try await writer.loadMessages().first)
            let latest = PushMessage(messageId: "snapshot-new", title: "Latest canonical title", body: "new")
            let first = try #require(try readWork(appGroupIdentifier: appGroupIdentifier, kind: "system_snapshot"))
            #expect(first.state == "leased")
            _ = try await writer.persistNotificationMessageIfNeeded(latest)
            let readTask = Task { try await reader.setMessageReadState(id: latest.id, isRead: true) }
            let deleteTask = Task { try await deleter.deleteMessage(id: original.id) }
            defer { readTask.cancel(); deleteTask.cancel() }
            let queue = try databaseQueue(appGroupIdentifier: appGroupIdentifier)
            try await waitUntil {
                try queue.read { db in
                    try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM messages;") == 1
                        && Int.fetchOne(db, sql: "SELECT is_read FROM messages WHERE id = ?;", arguments: [latest.id.uuidString]) == 1
                }
            }
            let dirty = try #require(try readWork(appGroupIdentifier: appGroupIdentifier, kind: "system_snapshot"))
            #expect(dirty.state == "leased")
            #expect(dirty.generation == first.generation + 3)
            try await readTask.value
            try await deleteTask.value
            try await child.releaseAndWait()
            // No extra ingress/drain is needed to rearm the newer generation.
            let completed = try await waitForWork(
                appGroupIdentifier: appGroupIdentifier, kind: "system_snapshot", matching: { $0.state == "completed" }
            )
            #expect(completed.generation == dirty.generation)
            #expect(completed.leaseGeneration > first.leaseGeneration)
            let snapshot = try #require(PushGoSystemSnapshotStore.load(appGroupIdentifier: appGroupIdentifier))
            #expect(snapshot.counts.totalMessages == 1)
            #expect(snapshot.counts.unreadMessages == 0)
            #expect(snapshot.recentMessages.map(\.title) == [latest.title])
            #expect(snapshot.unreadMessages.isEmpty)
        }
    }

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
                kind: "system_snapshot",
                matching: { $0.state == "retry_wait" }
            )
            #expect(retrying.attemptCount >= 1)

            try FileManager.default.removeItem(at: blockingFile)
            let completed = try await waitForWork(
                appGroupIdentifier: appGroupIdentifier,
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
        let generation: Int64
        let leaseGeneration: Int64
    }

    private struct TimedOutWaitingForWork: Error {}

    private func waitUntil(_ predicate: () throws -> Bool) async throws {
        for _ in 0..<400 {
            if try predicate() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw TimedOutWaitingForWork()
    }

    private func databaseQueue(appGroupIdentifier: String) throws -> DatabaseQueue {
        let databaseURL = try AppConstants.appLocalDatabaseDirectory(
            fileManager: .default, appGroupIdentifier: appGroupIdentifier
        ).appendingPathComponent(AppConstants.databaseStoreFilename)
        return try DatabaseQueue(path: databaseURL.path)
    }

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
        messageID: UUID? = nil,
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
        messageID: UUID? = nil,
        kind: String
    ) throws -> WorkSnapshot? {
        let queue = try databaseQueue(appGroupIdentifier: appGroupIdentifier)
        return try queue.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT state, attempt_count, last_error, generation, lease_generation
                    FROM canonical_derived_work
                    WHERE work_id = ?;
                    """,
                arguments: [messageID.map { "\($0.uuidString.lowercased()):\(kind)" } ?? kind]
            ) else { return nil }
            return WorkSnapshot(
                state: row["state"],
                attemptCount: row["attempt_count"],
                lastError: row["last_error"],
                generation: row["generation"],
                leaseGeneration: row["lease_generation"]
            )
        }
    }
}
