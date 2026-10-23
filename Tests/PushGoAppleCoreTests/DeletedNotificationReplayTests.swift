import Foundation
import GRDB
import Testing
import UserNotifications
@testable import PushGoAppleCore

struct DeletedNotificationReplayTests {
    @Test
    func confirmedDeletionKeepsProcessedOperationAcrossReplayAndReopen() async throws {
        try await withIsolatedAutomationStorage { root, group in
            let store = LocalDataStore(appGroupIdentifier: group, spotlightIndexer: nil)
            let original = message("original", delivery: "delivery-1", operation: "operation-1")
            guard case let .persisted(saved) = try await store.persistNotificationMessageIfNeeded(original) else {
                Issue.record("First delivery must be durable before it is acknowledged.")
                return
            }
            let confirmation = try await store.prepareLocalDeletion(intent: .messages(ids: [saved.id]))
            _ = try await store.deleteConfirmedLocalData(confirmation)
            #expect(try await store.loadMessages().isEmpty)
            let replay = try await store.persistNotificationMessageIfNeeded(original)
            #expect(isProcessedDuplicate(replay))
            #expect(try await store.loadMessages().isEmpty)
            var deliveryOnlyReplay = original
            deliveryOnlyReplay.rawPayload["op_id"] = nil
            #expect(isProcessedDuplicate(try await store.persistNotificationMessageIfNeeded(deliveryOnlyReplay)))
            var operationOnlyReplay = original
            operationOnlyReplay.rawPayload["delivery_id"] = nil
            #expect(isProcessedDuplicate(try await store.persistNotificationMessageIfNeeded(operationOnlyReplay)))

            LocalDataStore.releaseSharedResourcesForTesting(storageRootURL: root)
            let reopened = LocalDataStore(appGroupIdentifier: group, spotlightIndexer: nil)
            #expect(isProcessedDuplicate(try await reopened.persistNotificationMessageIfNeeded(original)))
            #expect(try await reopened.loadMessages().isEmpty)

            // Same visible content is not a permanent content tombstone.
            let newDelivery = message("new", delivery: "delivery-2", operation: "operation-2")
            guard case .persisted = try await reopened.persistNotificationMessageIfNeeded(newDelivery) else {
                Issue.record("A genuinely new operation/delivery must remain receivable.")
                return
            }
            #expect(try await reopened.loadMessages().map(\.messageId) == [newDelivery.messageId])
        }
    }

    @Test
    func deliveryWithoutOperationAlsoRemainsProcessedAfterDeletion() async throws {
        try await withIsolatedLocalDataStore { store, _ in
            let original = message("delivery-only", delivery: "delivery-no-op", operation: nil)
            _ = try await store.persistNotificationMessageIfNeeded(original)
            let confirmation = try await store.prepareLocalDeletion(intent: .messages(ids: [original.id]))
            _ = try await store.deleteConfirmedLocalData(confirmation)
            #expect(isProcessedDuplicate(try await store.persistNotificationMessageIfNeeded(original)))
            #expect(try await store.loadMessages().isEmpty)
        }
    }

    @Test
    func staleGenericRecoverySnapshotCannotUpsertDeletedMessage() async throws {
        try await withIsolatedLocalDataStore { store, _ in
            let original = message("generic-recovery", delivery: "generic-delivery", operation: "generic-operation")
            try await store.saveMessage(original)
            var staleRecovery = try #require(try await store.loadMessage(id: original.id))
            staleRecovery.body = "Late decrypted replacement from the pre-delete snapshot"
            _ = try await store.deleteConfirmedLocalData(
                try await store.prepareLocalDeletion(intent: .messages(ids: [original.id])))
            let reportedWrites = try await store.saveMessages([staleRecovery])
            #expect(reportedWrites.isEmpty)
            try await store.saveMessage(staleRecovery)
            // The separate bulk fast path must honor the same processed fact.
            try await store.saveMessagesBatch(Array(repeating: staleRecovery, count: 501))
            #expect(try await store.loadMessages().isEmpty)
            var fresh = message("generic-new", delivery: "generic-new-delivery", operation: "generic-new-operation")
            #expect(try await store.saveMessages([fresh]).count == 1)
            fresh.body = "A live canonical row can still be enriched"
            fresh.receivedAt = fresh.receivedAt.addingTimeInterval(1)
            #expect(try await store.saveMessages([fresh]).count == 1)
            #expect(try await store.loadMessage(messageId: fresh.messageId!)?.body == fresh.body)
        }
    }

    @Test
    func staleSnapshotDoesNotOverwriteAnotherOriginReusingDeletedCanonicalKey() async throws {
        try await withIsolatedLocalDataStore { store, _ in
            let first = message("reused-key", delivery: "origin-a-delivery", operation: "origin-a-operation")
            _ = try await store.persistNotificationMessageIfNeeded(first)
            _ = try await store.deleteConfirmedLocalData(
                try await store.prepareLocalDeletion(intent: .messages(ids: [first.id])))
            var replacement = message("reused-key", delivery: "origin-b-delivery", operation: "origin-b-operation",
                gateway: "https://gateway-b.invalid/prefix")
            replacement.title = "Only Gateway B owns this live row"
            _ = try await store.persistNotificationMessageIfNeeded(replacement)
            #expect(try await store.saveMessages([first]).isEmpty)
            #expect(isProcessedDuplicate(try await store.persistNotificationMessageIfNeeded(first)))
            let survivor = try #require(try await store.loadMessage(messageId: first.messageId!))
            #expect(survivor.providerSourceBaseURL == replacement.providerSourceBaseURL)
            #expect(survivor.title == replacement.title)
            #expect(try await store.loadMessages().count == 1)
        }
    }

    @Test
    func processedIdentityIsScopedToOriginalGatewayAndRecipient() async throws {
        try await withIsolatedLocalDataStore { store, _ in
            var original = message("scope-a", delivery: "shared-delivery", operation: "shared-operation")
            original.rawPayload["entity_id"] = AnyCodable("shared-entity")
            _ = try await store.persistNotificationMessageIfNeeded(original)
            let confirmation = try await store.prepareLocalDeletion(intent: .messages(ids: [original.id]))
            _ = try await store.deleteConfirmedLocalData(confirmation)
            for (suffix, gateway, recipient) in [
                ("gateway-b", "https://gateway-b.invalid/prefix", "recipient-a"),
                ("recipient-b", "https://gateway-a.invalid/prefix", "recipient-b"),
            ] {
                var independent = message(suffix, delivery: "shared-delivery", operation: "shared-operation",
                    gateway: gateway, recipient: recipient)
                independent.rawPayload["entity_id"] = AnyCodable("shared-entity")
                guard case .persisted = try await store.persistNotificationMessageIfNeeded(independent) else {
                    Issue.record("Another Gateway/recipient must not inherit a deleted identity.")
                    return
                }
            }
            #expect(try await store.loadMessages().count == 2)
            #expect(isProcessedDuplicate(try await store.persistNotificationMessageIfNeeded(original)))
        }
    }

    @Test
    func deletedWaitingMessageDoesNotReenterPendingQueue() async throws {
        try await withIsolatedLocalDataStore { store, group in
            var child = message("waiting-child", delivery: "waiting-delivery", operation: "waiting-operation")
            child.rawPayload["thing_id"] = AnyCodable("missing-parent")
            child.rawPayload["occurred_at"] = AnyCodable(Int64(1_800_000_000_000))
            guard case .persistedPending = try await store.persistNotificationMessageIfNeeded(child) else {
                Issue.record("A child arriving before its parent must first be durably pending.")
                return
            }
            let confirmation = try await store.prepareLocalDeletion(intent: .things(ids: ["missing-parent"]))
            _ = try await store.deleteConfirmedLocalData(confirmation)
            #expect(isProcessedDuplicate(try await store.persistNotificationMessageIfNeeded(child)))
            let databaseURL = try AppConstants.appLocalDatabaseDirectory(appGroupIdentifier: group)
                .appendingPathComponent(AppConstants.databaseStoreFilename)
            let queue = try DatabaseQueue(path: databaseURL.path)
            #expect(try await queue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM pending_inbound_messages;") } == 0)
            #expect(try await store.loadMessages().isEmpty)
        }
    }

    @Test
    func legacyLiveCanonicalIdentityIsRetainedByConfirmedDeletion() async throws {
        try await withIsolatedLocalDataStore { store, _ in
            // saveMessage is the pre-existing import/update path, not the new
            // notification ingress writer. Confirmation must retain facts from
            // that existing row without guessing an origin after it is gone.
            let oldRow = message("legacy-live", delivery: "legacy-live-delivery", operation: "legacy-live-operation")
            try await store.saveMessage(oldRow)
            _ = try await store.deleteConfirmedLocalData(
                try await store.prepareLocalDeletion(intent: .messages(ids: [oldRow.id])))
            #expect(isProcessedDuplicate(try await store.persistNotificationMessageIfNeeded(oldRow)))
            #expect(try await store.loadMessages().isEmpty)
        }
    }

    @Test
    func oldUnattributableOperationDoesNotPoisonAnotherGatewayScope() async throws {
        try await withIsolatedLocalDataStore { store, group in
            let databaseURL = try AppConstants.appLocalDatabaseDirectory(appGroupIdentifier: group)
                .appendingPathComponent(AppConstants.databaseStoreFilename)
            let queue = try DatabaseQueue(path: databaseURL.path)
            // Explicit pre-change boundary fixture: its canonical payload is
            // gone, so this old ledger row cannot prove a Gateway/recipient.
            try await queue.write { db in
                try db.execute(sql: """
                    INSERT INTO operation_ledger(scope_key, message_id, op_id, channel_id,
                        entity_type, entity_id, delivery_id, applied_at)
                    VALUES ('lifecycle|message|unknown-origin-entity|unknown-origin-op',
                        'old-unknown-origin-message', 'unknown-origin-op', 'lifecycle',
                        'message', 'unknown-origin-entity', 'old-unknown-origin-delivery', 123);
                    """)
            }
            var incoming = message("new-origin", delivery: "new-origin-delivery", operation: "unknown-origin-op")
            incoming.rawPayload["entity_id"] = AnyCodable("unknown-origin-entity")
            guard case .persisted = try await store.persistNotificationMessageIfNeeded(incoming) else {
                Issue.record("An unattributable old row must not be assigned to a new Gateway by guesswork.")
                return
            }
            #expect(try await queue.read { try Double.fetchOne($0, sql: "SELECT applied_at FROM operation_ledger WHERE message_id = 'old-unknown-origin-message';") } == 123)
            #expect(try await store.loadMessages().map(\.messageId) == [incoming.messageId])
        }
    }

    @Test
    func oldOperationWithSurvivingCanonicalPayloadKeepsItsProvenOrigin() async throws {
        try await withIsolatedLocalDataStore { store, group in
            var original = message("old-operation", delivery: "old-operation-delivery", operation: "old-operation")
            original.rawPayload["entity_id"] = AnyCodable("old-operation-entity")
            try await store.saveMessage(original)
            #expect(await store.drainDerivedWorkForBackgroundRefresh())
            let url = try AppConstants.appLocalDatabaseDirectory(appGroupIdentifier: group)
                .appendingPathComponent(AppConstants.databaseStoreFilename)
            let queue = try DatabaseQueue(path: url.path)
            try await queue.write { db in
                try db.execute(sql: """
                    INSERT INTO operation_ledger(scope_key, message_id, op_id, channel_id,
                        entity_type, entity_id, delivery_id, applied_at)
                    VALUES ('lifecycle|message|old-operation-entity|old-operation',
                        'message-old-operation', 'old-operation', 'lifecycle',
                        'message', 'old-operation-entity', 'old-operation-delivery', 123);
                    """)
            }
            var replay = message("old-operation-replay", delivery: "different-envelope", operation: "old-operation")
            replay.rawPayload["entity_id"] = AnyCodable("old-operation-entity")
            guard case let .duplicateMessage(existing) = try await store.persistNotificationMessageIfNeeded(replay) else {
                Issue.record("A provable legacy operation must remain idempotent after origin scoping.")
                return
            }
            #expect(existing.messageId == original.messageId)
            #expect(try await store.loadMessages().count == 1)
            _ = try await store.deleteConfirmedLocalData(
                try await store.prepareLocalDeletion(intent: .messages(ids: [original.id])))
            #expect(isProcessedDuplicate(try await store.persistNotificationMessageIfNeeded(replay)))
            #expect(try await store.loadMessages().isEmpty)
        }
    }

    @Test
    func retainedJournalTerminalProtectsPreChangeDeletedDirectAndPreservesLiveEnrichment() async throws {
        try await withIsolatedLocalDataStore { store, group in
            let original = message("journal-history", delivery: "journal-delivery", operation: "journal-operation")
            try await store.saveMessage(original)
            let inbox = NotificationIngressInbox(appGroupIdentifier: group)
            #expect(await inbox.enqueue(codablePayload: original.rawPayload,
                requestIdentifier: original.deliveryId, source: "test.prechange.direct"))
            let pending = try #require(await inbox.pendingEntries().first)
            await inbox.markCompleted(pending)
            // A retained terminal must not prevent enrichment while the same
            // canonical content is still visible.
            var updated = original
            updated.title = "Enriched visible title"
            guard case .duplicateRequest = try await store.persistNotificationMessageIfNeeded(updated) else {
                Issue.record("Live content enrichment must not be gated by a terminal journal.")
                return
            }
            #expect(try await store.loadMessage(messageId: original.messageId!)?.title == updated.title)
            // This fixture represents an offline old-version state. Finish the
            // real post-commit worker before the explicit historical mutation.
            #expect(await store.drainDerivedWorkForBackgroundRefresh())
            let databaseURL = try AppConstants.appLocalDatabaseDirectory(appGroupIdentifier: group)
                .appendingPathComponent(AppConstants.databaseStoreFilename)
            let queue = try DatabaseQueue(path: databaseURL.path)
            // Explicit old-version fixture: canonical content and scoped facts
            // did not survive, but its validated source journal did.
            try await queue.write { db in
                try db.execute(sql: "DELETE FROM messages;")
                try db.execute(sql: "DELETE FROM operation_ledger;")
            }
            #expect(isProcessedDuplicate(try await store.persistNotificationMessageIfNeeded(original)))
            #expect(try await store.loadMessages().isEmpty)
        }
    }

    @Test
    func pendingJournalIsNotProofOfProcessedContentAndReadFailureNeverAcknowledges() async throws {
        try await withIsolatedLocalDataStore { store, group in
            let original = message("journal-pending", delivery: "pending-delivery", operation: "pending-operation")
            let inbox = NotificationIngressInbox(appGroupIdentifier: group)
            #expect(await inbox.enqueue(codablePayload: original.rawPayload,
                requestIdentifier: original.deliveryId, source: "test.pending.direct"))
            guard case .persisted = try await store.persistNotificationMessageIfNeeded(original) else {
                Issue.record("A pending journal is not a canonical commit.")
                return
            }
            let journal = DurableIngressJournal(appGroupIdentifier: group)
            let url = try #require(await journal.databaseURL)
            let queue = try DatabaseQueue(path: url.path)
            try await queue.write { db in
                try db.execute(sql: "ALTER TABLE ingress_entry RENAME TO fixture_unavailable_ingress_entry;")
            }
            let payload = message("journal-failure", delivery: "failure-delivery", operation: "failure-operation")
                .rawPayload.reduce(into: [AnyHashable: Any]()) { $0[$1.key] = $1.value.value }
            let outcome = await NotificationPersistenceCoordinator.persistRemotePayloadIfNeeded(
                payload, requestIdentifier: "failure-delivery", dataStore: store)
            guard case .failed = outcome else {
                Issue.record("Unreadable historical identity evidence must fail closed.")
                return
            }
            #expect(!ProviderIngressPersistenceResult(outcome).allowsAck)
            #expect(try await store.loadMessages().count == 1)
        }
    }

    @Test
    func directProductionPersistenceReturnsAckableDuplicateWithoutRecreatingBody() async throws {
        try await withIsolatedLocalDataStore { store, _ in
            let payload: [AnyHashable: Any] = [
                "entity_type": "message", "entity_id": "direct-message", "message_id": "direct-message",
                "delivery_id": "direct-delivery", "op_id": "direct-operation", "channel_id": "lifecycle",
                "base_url": "https://gateway-a.invalid/prefix", "provider_device_key": "recipient-a",
                "title": "Preserved title", "body": "Preserved body",
            ]
            let first = await NotificationPersistenceCoordinator.persistRemotePayloadIfNeeded(
                payload, requestIdentifier: "direct-delivery", dataStore: store)
            guard case let .persistedMain(saved) = first else {
                Issue.record("Production notification persistence must first save the delivery.")
                return
            }
            let normalDuplicate = await NotificationPersistenceCoordinator.persistRemotePayloadIfNeeded(
                payload, requestIdentifier: "direct-delivery", dataStore: store)
            #expect(ProviderIngressPersistenceResult(normalDuplicate).allowsAck)
            #expect(try await store.loadMessages().count == 1)
            _ = try await store.deleteConfirmedLocalData(
                try await store.prepareLocalDeletion(intent: .messages(ids: [saved.id])))
            let replay = await NotificationPersistenceCoordinator.persistRemotePayloadIfNeeded(
                payload, requestIdentifier: "direct-delivery", dataStore: store)
            guard case .duplicate = replay else {
                Issue.record("Deleted, already-processed Direct must be a duplicate, not rejected or inserted.")
                return
            }
            #expect(ProviderIngressPersistenceResult(replay).allowsAck)
            #expect(try await store.loadMessages().isEmpty)
        }
    }

    private func isProcessedDuplicate(_ outcome: NotificationStoreSaveOutcome) -> Bool {
        // A body-bearing duplicate is also a valid outcome for a live canonical row.
        switch outcome {
        case .persisted, .persistedPending: return false
        default: return true
        }
    }

    private func message(_ suffix: String, delivery: String, operation: String?,
        gateway: String = "https://gateway-a.invalid/prefix", recipient: String = "recipient-a") -> PushMessage {
        var payload: [String: AnyCodable] = [
            "message_id": AnyCodable("message-\(suffix)"), "entity_type": AnyCodable("message"),
            "entity_id": AnyCodable("message-\(suffix)"), "channel_id": AnyCodable("lifecycle"),
            "delivery_id": AnyCodable(delivery), "_notificationRequestId": AnyCodable(delivery),
            "base_url": AnyCodable(gateway), "provider_device_key": AnyCodable(recipient),
        ]
        if let operation { payload["op_id"] = AnyCodable(operation) }
        return PushMessage(messageId: "message-\(suffix)", title: "Same title", body: "Same body",
            channel: "lifecycle", rawPayload: payload)
    }
}
