import Foundation
import GRDB
import Testing
@testable import PushGoAppleCore

@MainActor
struct LegacyDeletionReconfirmationTests {
    @Test
    func cancelledReviewAndOtherPresentationCannotPoisonNextSettingsVisit() async throws {
        try await withIsolatedLocalDataStore { @MainActor store, _ in
            let now = Date()
            let old = try await store.seedLegacyPendingLocalDeletion(summary: "channel", undoLabel: "Undo",
                intent: .channelHistory(channelID: "channel", expectedGateway: "https://original.example", expectedUpdatedAt: now), timeout: 0, now: now)
            let gate = ReviewGate()
            let worker = PendingLocalDeletionController(dataStore: store, legacyChannelPreparationHandler: { _ in
                await gate.pauseOnce()
                return PendingChannelRemovalTarget(channelID: "channel", originalConfig: ServerConfig(baseURL: URL(string: "https://original.example")!), expectedUpdatedAt: now, password: "synthetic", keepHistory: false)
            })
            await worker.restoreAndReconcile()
            let firstPresentation = UUID(), secondPresentation = UUID()
            let task = Task { await worker.reviewLegacyRequest(id: old.id, presentationID: firstPresentation) }
            for _ in 0..<1000 {
                if gate.started { break }
                try await Task.sleep(for: .milliseconds(1))
            }
            #expect(gate.started)
            await worker.reviewLegacyRequest(id: old.id, presentationID: secondPresentation)
            worker.dismissLegacyConfirmation(id: secondPresentation)
            task.cancel()
            gate.release()
            await task.value
            #expect(worker.legacyConfirmation == nil)
            #expect(!worker.isReviewingLegacyRequest)
            await worker.reviewLegacyRequest(id: old.id, presentationID: firstPresentation)
            let fresh = try #require(worker.legacyConfirmation)
            #expect(fresh.requestID == old.id && fresh.id == firstPresentation)
            await worker.reviewLegacyRequest(id: old.id, presentationID: secondPresentation)
            worker.dismissLegacyConfirmation(id: secondPresentation)
            #expect(worker.legacyConfirmation?.id == firstPresentation)
            worker.dismissLegacyConfirmation(id: firstPresentation)
            await worker.reviewLegacyRequest(id: old.id, presentationID: secondPresentation)
            worker.dismissLegacyConfirmation(id: firstPresentation)
            #expect(worker.legacyConfirmation?.id == secondPresentation)
            worker.dismissLegacyConfirmation(id: secondPresentation)
            #expect(try await store.pendingLocalDeletionRecord(id: old.id) != nil)
        }
    }

    @Test
    func vanishedTargetRejectsStaleLegacyConfirmationAndKeepsRequestForExplicitCancel() async throws {
        try await withIsolatedLocalDataStore { @MainActor store, _ in
            let target = message("vanished"), control = message("control")
            try await store.saveMessagesBatch([target, control])
            let old = try await store.seedLegacyPendingLocalDeletion(summary: target.title, undoLabel: "Undo",
                intent: .messages(ids: [target.id]), timeout: 0, now: Date())
            let stale = try await store.prepareLegacyLocalDeletion(id: old.id)
            let separate = try await store.prepareLocalDeletion(intent: .messages(ids: [target.id]))
            _ = try await store.deleteConfirmedLocalData(separate)
            await #expect(throws: (any Error).self) { _ = try await store.deleteConfirmedLocalData(stale) }
            #expect(try await store.pendingLocalDeletionRecord(id: old.id) != nil)
            #expect(try await store.loadMessage(id: control.id)?.body == control.body)
            #expect(try await store.cancelLegacyLocalDeletion(id: old.id))
        }
    }

    @Test
    func appOwnedV29FixtureReallyUpgradesAndPausesItsFutureRequest() async throws {
        try await withIsolatedAutomationStorage { @MainActor _, group in
            let directory = try AppConstants.appLocalDatabaseDirectory(appGroupIdentifier: group)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent(AppConstants.databaseStoreFilename)
            try LocalDataStore.prepareQualityLegacyStoreForTesting(storeURL: url, legacyStore: .pendingDeletionV29)
            let queue = try DatabaseQueue(path: url.path)
            #expect(try await queue.read { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM pragma_table_info('pending_local_deletions') WHERE name = 'execution_authority';")
            } == 0)
            let store = LocalDataStore(appGroupIdentifier: group, spotlightIndexer: nil)
            let worker = PendingLocalDeletionController(dataStore: store)
            await worker.restoreAndReconcile()
            #expect(worker.legacyRequests.count == 1)
            #expect(worker.legacyRequests.first?.id == UUID(uuidString: "00000000-0000-0000-0000-000000000029"))
            #expect(worker.legacyRequests.first?.deadline ?? .distantPast > Date())
            #expect(try await store.loadMessage(messageId: "quality-legacy-v17-message")?.body == "Preserved through the production database migration.")
        }
    }

    @Test
    func futureUndoableAndQueuedKeepContentAcrossMigrationRestartAndCancel() async throws {
        try await withIsolatedLocalDataStore { @MainActor store, group in
            let first = message("future"), second = message("queued"), control = message("control")
            try await store.saveMessagesBatch([first, second, control])
            let now = Date()
            let a = try await store.seedLegacyPendingLocalDeletion(summary: first.title, undoLabel: "Undo",
                intent: .messages(ids: [first.id]), timeout: 3600, now: now)
            let b = try await store.seedLegacyPendingLocalDeletion(summary: second.title, undoLabel: "Undo",
                intent: .messages(ids: [second.id]), timeout: 3600, now: now)
            #expect(a.state == .undoable && a.deadline! > now)
            #expect(b.state == .queued && b.deadline == nil)
            // A real v29-shaped copy upgrades through the new production migration.
            let root = try #require(PushGoAutomationContext.storageRootOverrideURL)
            LocalDataStore.releaseSharedResourcesForTesting(storageRootURL: root)
            let db = try database(group)
            try await db.write { db in
                try db.execute(sql: "ALTER TABLE pending_local_deletions DROP COLUMN execution_authority;")
                try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = 'v30_legacy_deletion_confirmation_authority';")
            }
            let reopened = LocalDataStore(appGroupIdentifier: group, spotlightIndexer: nil)
            let worker = PendingLocalDeletionController(dataStore: reopened)
            await worker.restoreAndReconcile()
            #expect(worker.legacyRequests.map(\.id) == [a.id, b.id])
            #expect(try await reopened.loadMessages().count == 3)
            #expect(try await reopened.claimNextPendingLocalDeletion(owner: "must-not-claim", leaseDuration: 1, now: now.addingTimeInterval(7200)) == nil)
            await worker.cancelLegacyRequest(id: b.id)
            await worker.cancelLegacyRequest(id: b.id)
            #expect(try await reopened.loadMessage(id: second.id)?.body == second.body)
            #expect(try await reopened.pendingLocalDeletionRecord(id: b.id) == nil)
            LocalDataStore.releaseSharedResourcesForTesting(storageRootURL: root)
            let again = LocalDataStore(appGroupIdentifier: group, spotlightIndexer: nil)
            let secondWorker = PendingLocalDeletionController(dataStore: again)
            await secondWorker.restoreAndReconcile()
            #expect(secondWorker.legacyRequests.map(\.id) == [a.id])
            #expect(try await again.loadMessages().map(\.id).contains(control.id))
            #expect(try await again.loadMessage(id: first.id)?.title == first.title)
            #expect(try await again.pendingLocalDeletionRecord(id: a.id)?.deadline == a.deadline)
        }
    }

    @Test
    func reconfirmedCanonicalDeleteConsumesOnlyOldIntentAndDoesNotResurrectOnReplay() async throws {
        try await withIsolatedLocalDataStore { @MainActor store, group in
            var target = message("reconfirm")
            target.rawPayload["base_url"] = AnyCodable("https://original.example")
            target.rawPayload["provider_device_key"] = AnyCodable("synthetic-device")
            target.rawPayload["delivery_id"] = AnyCodable("reconfirm-delivery")
            let accepted = try await store.persistNotificationMessageIfNeeded(target)
            guard case .persisted = accepted else { Issue.record("Actual canonical acceptance required"); return }
            let control = message("unrelated")
            try await store.saveMessage(control)
            let old = try await store.seedLegacyPendingLocalDeletion(summary: "old label", undoLabel: "Undo",
                intent: .messages(ids: [target.id]), timeout: 3600, now: Date())
            let worker = PendingLocalDeletionController(dataStore: store)
            await worker.restoreAndReconcile()
            await worker.reviewLegacyRequest(id: old.id)
            let draft = try #require(worker.legacyConfirmation)
            #expect(draft.summary == target.title)
            await worker.confirmLegacyRequest(id: draft.id)
            await worker.confirmLegacyRequest(id: draft.id)
            #expect(try await store.loadMessage(id: target.id) == nil)
            #expect(try await store.loadMessage(id: control.id)?.title == control.title)
            #expect(try await store.pendingLocalDeletionRecord(id: old.id) == nil)
            guard case .duplicateProcessed = try await store.persistNotificationMessageIfNeeded(target) else { Issue.record("Deleted processed delivery reentered canonical storage"); return }
            let root = try #require(PushGoAutomationContext.storageRootOverrideURL)
            LocalDataStore.releaseSharedResourcesForTesting(storageRootURL: root)
            let reopened = LocalDataStore(appGroupIdentifier: group, spotlightIndexer: nil)
            guard case .duplicateProcessed = try await reopened.persistNotificationMessageIfNeeded(target) else { Issue.record("Deleted delivery resurrected after reopen"); return }
            #expect(try await reopened.loadMessage(id: target.id) == nil)
            #expect(try await reopened.loadMessage(id: control.id)?.title == control.title)
        }
    }

    @Test
    func cancelledOrChangedTargetCannotBeDeletedByAStaleReviewDraft() async throws {
        try await withIsolatedLocalDataStore { @MainActor store, _ in
            let target = message("keep"), control = message("control")
            try await store.saveMessagesBatch([target, control])
            let old = try await store.seedLegacyPendingLocalDeletion(summary: target.title, undoLabel: "Undo",
                intent: .messages(ids: [target.id]), timeout: 0, now: Date())
            _ = try await store.legacyLocalDeletionsRequiringReview(now: Date())
            let cancelled = try await store.prepareLegacyLocalDeletion(id: old.id)
            #expect(try await store.cancelLegacyLocalDeletion(id: old.id))
            await #expect(throws: (any Error).self) { _ = try await store.deleteConfirmedLocalData(cancelled) }
            #expect(try await store.loadMessage(id: target.id) != nil)
            let next = try await store.seedLegacyPendingLocalDeletion(summary: target.title, undoLabel: "Undo",
                intent: .messages(ids: [target.id]), timeout: 0, now: Date())
            let stale = try await store.prepareLegacyLocalDeletion(id: next.id)
            try await store.setMessageReadState(id: target.id, isRead: true)
            await #expect(throws: (any Error).self) { _ = try await store.deleteConfirmedLocalData(stale) }
            #expect(try await store.pendingLocalDeletionRecord(id: next.id) != nil)
            #expect(try await store.loadMessage(id: control.id)?.title == control.title)
            let changedConfig = try await store.prepareLegacyLocalDeletion(id: next.id)
            try LocalKeychainConfigStore().saveServerConfig(ServerConfig(baseURL: URL(string: "https://replacement.example")!, token: "synthetic"))
            await #expect(throws: (any Error).self) { _ = try await store.deleteConfirmedLocalData(changedConfig) }
            #expect(try await store.loadMessage(id: target.id)?.isRead == true)
        }
    }

    @Test
    func committedCleanupContinuesWhileLocalLeasesReviewAndRemoteUnknownStaysQuarantined() async throws {
        try await withIsolatedLocalDataStore { @MainActor store, group in
            let deleted = message("already deleted"), local = message("not committed"), control = message("keep")
            try await store.saveMessagesBatch([deleted, local, control])
            let confirmed = try await store.prepareLocalDeletion(intent: .messages(ids: [deleted.id]))
            _ = try await store.deleteConfirmedLocalData(confirmed)
            let oldLocal = try await store.seedLegacyPendingLocalDeletion(summary: local.title, undoLabel: "Undo",
                intent: .messages(ids: [local.id]), timeout: 0, now: Date())
            let remote = try await store.seedLegacyPendingLocalDeletion(summary: "remote uncertain", undoLabel: "Undo",
                intent: .channelHistory(channelID: "old-channel", expectedGateway: "https://old.example", expectedUpdatedAt: Date()), timeout: 0, now: Date())
            let db = try database(group)
            try await db.write { db in
                try db.execute(sql: "UPDATE pending_local_deletions SET execution_authority = 'legacy' WHERE id = ?;", arguments: [confirmed.id.uuidString])
                for id in [oldLocal.id, remote.id] {
                    try db.execute(sql: "UPDATE pending_local_deletions SET state = 'executing', attempt_count = 1, lease_owner = 'old-process', lease_until_epoch_ms = 0 WHERE id = ?;", arguments: [id.uuidString])
                }
            }
            let worker = PendingLocalDeletionController(dataStore: store)
            await worker.restoreAndReconcile()
            await worker.retryRecovery()
            await worker.restoreAndReconcile()
            #expect(try await store.loadMessage(id: deleted.id) == nil)
            #expect(try await store.pendingLocalDeletionRecord(id: confirmed.id) == nil)
            #expect(try await store.loadMessage(id: local.id)?.title == local.title)
            #expect(worker.legacyRequests.map(\.id) == [oldLocal.id])
            #expect(try await store.pendingLocalDeletionRecord(id: remote.id)?.lastErrorCode == "legacy_deletion_remote_outcome_unknown")
            await #expect(throws: (any Error).self) { _ = try await store.cancelLegacyLocalDeletion(id: remote.id) }
            await #expect(throws: (any Error).self) { _ = try await store.commitClaimedPendingLocalDeletion(id: oldLocal.id, owner: "old-process", now: Date()) }
            #expect(try await store.loadMessage(id: control.id)?.title == control.title)
        }
    }

    @Test
    func malformedOrContradictoryReceiptsRetainRawBytesAndNeverExecute() async throws {
        try await withIsolatedLocalDataStore { @MainActor store, group in
            let target = message("safe")
            try await store.saveMessage(target)
            let old = try await store.seedLegacyPendingLocalDeletion(summary: "bad", undoLabel: "Undo",
                intent: .messages(ids: [target.id]), timeout: 0, now: Date())
            let contradictory = try await store.seedLegacyPendingLocalDeletion(summary: "missing receipt", undoLabel: "Undo",
                intent: .events(ids: ["contradictory-synthetic-event"]), timeout: 0, now: Date())
            #expect(contradictory.id != old.id)
            let unknownState = try await store.seedLegacyPendingLocalDeletion(summary: "unknown source state", undoLabel: "Undo",
                intent: .things(ids: ["unknown-synthetic-thing"]), timeout: 0, now: Date())
            let db = try database(group)
            try await db.write { db in try db.execute(sql: "UPDATE pending_local_deletions SET payload_json = 'unknown-schema-bytes' WHERE id = ?;", arguments: [old.id.uuidString]) }
            try await db.write { db in
                try db.execute(sql: "UPDATE pending_local_deletions SET state = 'cleanup_pending', cleanup_json = NULL WHERE id = ?;", arguments: [contradictory.id.uuidString])
            }
            try await db.write { db in
                // Deliberate synthetic corruption: normal production CHECK rejects unknown states.
                try db.execute(sql: "PRAGMA ignore_check_constraints = ON;")
                try db.execute(sql: "UPDATE pending_local_deletions SET state = 'unknown-future-state' WHERE id = ?;", arguments: [unknownState.id.uuidString])
                try db.execute(sql: "PRAGMA ignore_check_constraints = OFF;")
            }
            let worker = PendingLocalDeletionController(dataStore: store)
            await worker.restoreAndReconcile()
            await worker.retryRecovery()
            await worker.restoreAndReconcile()
            #expect(worker.legacyRequests.isEmpty)
            #expect(worker.recoveryRequiredCount == 3)
            #expect(try await store.pendingLocalDeletionRecord(id: unknownState.id)?.lastErrorCode == "invalid_persisted_payload")
            #expect(try await store.loadMessage(id: target.id)?.title == target.title)
            #expect(try await db.read { db in try String.fetchOne(db, sql: "SELECT payload_json FROM pending_local_deletions WHERE id = ?;", arguments: [old.id.uuidString]) } == "unknown-schema-bytes")
            #expect(Set(try await store.pendingLocalDeletionRecoveryErrorCodes()) == Set(["invalid_persisted_payload", "legacy_deletion_inconsistent_cleanup"]))
        }
    }

    @MainActor
    private final class ReviewGate {
        var started = false
        private var continuation: CheckedContinuation<Void, Never>?
        func pauseOnce() async {
            guard !started else { return }
            started = true
            await withCheckedContinuation { continuation = $0 }
        }
        func release() { continuation?.resume(); continuation = nil }
    }

    private func database(_ group: String) throws -> DatabaseQueue {
        let directory = try AppConstants.appLocalDatabaseDirectory(appGroupIdentifier: group)
        return try DatabaseQueue(path: directory.appendingPathComponent(AppConstants.databaseStoreFilename).path)
    }

    private func message(_ title: String) -> PushMessage {
        let id = UUID()
        return PushMessage(id: id, messageId: "legacy-\(id.uuidString)", title: title, body: "Original \(title)", channel: "legacy", rawPayload: ["message_id": AnyCodable("legacy-\(id.uuidString)")])
    }
}
