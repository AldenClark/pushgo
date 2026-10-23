import Foundation
import GRDB
import Testing
@testable import PushGoAppleCore

@MainActor
struct LocalDeletionConfirmationControllerTests {
    @Test
    func cancelAndClosedHostLeaveCanonicalTargetAndNoIntent() async throws {
        try await withIsolatedLocalDataStore { store, _ in
            try await verifyCancellation(store: store)
        }
    }

    private func verifyCancellation(store: LocalDataStore) async throws {
        let message = makeMessage(title: "cancel exact target")
        try await store.saveMessage(message)
        let original = try await store.loadMessage(id: message.id)
        var completed = 0
        var failures = 0
        let controller = LocalDeletionConfirmationController(dataStore: store, configuration: { nil },
            reconcileCleanup: {}, failure: { _ in failures += 1 })
        let host = UUID()
        controller.registerHost(host)
        await controller.request(summary: "stale display summary", intent: .messages(ids: [message.id])) { completed += 1 }
        let pending = try #require(controller.pendingConfirmation)
        #expect(pending.summary == message.title)
        controller.cancel(id: pending.id)
        await controller.confirm(id: pending.id)
        await controller.request(summary: message.title, intent: .messages(ids: [message.id])) { completed += 1 }
        controller.unregisterHost(host)
        #expect(controller.pendingConfirmation == nil)
        #expect(completed == 0)
        #expect(failures == 0)
        #expect(try await store.loadMessage(id: message.id) == original)
        #expect(try await store.loadPendingLocalDeletions(now: Date()).isEmpty)
    }

    @Test
    func acceptedConfirmationCommitsOnceAndStaleCallbacksCannotDeleteNextTarget() async throws {
        try await withIsolatedLocalDataStore { store, _ in
            try await verifyConsumption(store: store)
        }
    }

    private func verifyConsumption(store: LocalDataStore) async throws {
        let target = makeMessage(title: "accepted target")
        let survivor = makeMessage(title: "independent survivor")
        try await store.saveMessage(target)
        try await store.saveMessage(survivor)
        let originalSurvivor = try await store.loadMessage(id: survivor.id)
        let worker = PendingLocalDeletionController(dataStore: store)
        var completed = 0
        var failures = 0
        let controller = LocalDeletionConfirmationController(dataStore: store, configuration: { nil },
            reconcileCleanup: { await worker.reconcileCommittedCleanup() }, failure: { _ in failures += 1 })
        controller.registerHost(UUID())
        await controller.request(summary: target.title, intent: .messages(ids: [target.id])) { completed += 1 }
        let first = try #require(controller.pendingConfirmation)
        await controller.confirm(id: first.id)
        await controller.confirm(id: first.id)
        await controller.request(summary: survivor.title, intent: .messages(ids: [survivor.id])) { completed += 1 }
        controller.cancel(id: first.id)
        await controller.confirm(id: first.id)
        #expect(controller.pendingConfirmation?.id != first.id)
        #expect(completed == 1)
        #expect(failures == 0)
        #expect(try await store.loadMessage(id: target.id) == nil)
        #expect(try await store.loadMessage(id: survivor.id) == originalSurvivor)
        #expect(try await store.loadPendingLocalDeletions(now: Date()).isEmpty)
    }

    @Test
    func changedConfigurationFailsWithoutCompletingOrDeleting() async throws {
        try await withIsolatedLocalDataStore { store, _ in
            try await verifyConfigurationChange(store: store)
        }
    }

    private func verifyConfigurationChange(store: LocalDataStore) async throws {
        let message = makeMessage(title: "configuration-bound target")
        try await store.saveMessage(message)
        let original = try await store.loadMessage(id: message.id)
        var configuration: ServerConfig?
        var completed = false
        var errors: [String] = []
        let controller = LocalDeletionConfirmationController(dataStore: store, configuration: { configuration },
            reconcileCleanup: {}, failure: { errors.append(($0 as? AppError)?.code ?? "unknown") })
        controller.registerHost(UUID())
        await controller.request(summary: message.title, intent: .messages(ids: [message.id])) { completed = true }
        let pending = try #require(controller.pendingConfirmation)
        configuration = ServerConfig(baseURL: URL(string: "https://replacement.invalid")!)
        await controller.confirm(id: pending.id)
        #expect(!completed)
        #expect(errors == ["local_deletion_target_changed"])
        #expect(try await store.loadMessage(id: message.id) == original)
        #expect(try await store.loadPendingLocalDeletions(now: Date()).isEmpty)
    }

    private func makeMessage(title: String) -> PushMessage {
        let id = UUID()
        let messageID = "confirmation-\(id.uuidString)"
        return PushMessage(id: id, messageId: messageID, title: title, body: "exact canonical body",
            channel: "confirmation-tests", rawPayload: ["message_id": AnyCodable(messageID)])
    }

    @Test(arguments: [false, true])
    func confirmedUserEntryRetainsDeletedIdentityAcrossReplayAndRestart(hasOperation: Bool) async throws {
        try await withIsolatedAutomationStorage { root, group in
            try await verifyConfirmedUserReplay(root: root, group: group, hasOperation: hasOperation)
        }
    }

    @MainActor
    private func verifyConfirmedUserReplay(root: URL, group: String, hasOperation: Bool) async throws {
        let store = LocalDataStore(appGroupIdentifier: group, spotlightIndexer: nil)
        var original = makeMessage(title: "confirmed body")
        original.rawPayload["entity_type"] = AnyCodable("message")
        original.rawPayload["entity_id"] = AnyCodable(original.messageId!)
        original.rawPayload["channel_id"] = AnyCodable("confirmation-tests")
        original.rawPayload["delivery_id"] = AnyCodable("confirmation-delivery")
        original.rawPayload["base_url"] = AnyCodable("https://confirmation-a.invalid/prefix")
        original.rawPayload["provider_device_key"] = AnyCodable("confirmation-recipient")
        if hasOperation { original.rawPayload["op_id"] = AnyCodable("confirmation-operation") }
        // The existing import path can contain old canonical content
        // without a first-delivery fact. User confirmation must reuse the
        // approved transition rather than a direct-delete facade.
        try await store.saveMessage(original)
        var failures = 0
        let controller = LocalDeletionConfirmationController(dataStore: store, configuration: { nil },
            reconcileCleanup: {}, failure: { _ in failures += 1 })
        controller.registerHost(UUID())
        await controller.request(summary: original.title, intent: .messages(ids: [original.id]))
        let pendingConfirmation = controller.pendingConfirmation
        let confirmation = try #require(pendingConfirmation)
        await controller.confirm(id: confirmation.id)
        #expect(failures == 0)
        #expect(try await store.loadMessage(id: original.id) == nil)
        let queue = try DatabaseQueue(path: AppConstants.appLocalDatabaseDirectory(appGroupIdentifier: group)
            .appendingPathComponent(AppConstants.databaseStoreFilename).path)
        let beforeReplay = try await queue.read { db in
            try Row.fetchAll(db, sql: "SELECT scope_key, applied_at FROM operation_ledger ORDER BY scope_key;")
                .map { ($0["scope_key"] as String, $0["applied_at"] as Double) }
        }
        #expect(!beforeReplay.isEmpty)
        let replay = try await store.persistNotificationMessageIfNeeded(original)
        guard case .duplicateProcessed = replay else {
            Issue.record("Confirmed deletion must not reconstruct an already processed delivery.")
            return
        }
        await controller.confirm(id: confirmation.id)
        let afterReplay = try await queue.read { db in
            try Row.fetchAll(db, sql: "SELECT scope_key, applied_at FROM operation_ledger ORDER BY scope_key;")
                .map { ($0["scope_key"] as String, $0["applied_at"] as Double) }
        }
        #expect(beforeReplay.map(\.0) == afterReplay.map(\.0))
        #expect(beforeReplay.map(\.1) == afterReplay.map(\.1))
        LocalDataStore.releaseSharedResourcesForTesting(storageRootURL: root)
        let reopened = LocalDataStore(appGroupIdentifier: group, spotlightIndexer: nil)
        let afterRestart = try await reopened.persistNotificationMessageIfNeeded(original)
        guard case .duplicateProcessed = afterRestart else {
            Issue.record("The confirmed identity must remain processed after reopening storage.")
            return
        }
        #expect(try await reopened.loadMessage(id: original.id) == nil)
        var independent = original
        independent.id = UUID()
        independent.messageId = "independent-confirmation-message"
        independent.rawPayload["message_id"] = AnyCodable(independent.messageId!)
        independent.rawPayload["base_url"] = AnyCodable("https://confirmation-b.invalid/prefix")
        guard case .persisted = try await reopened.persistNotificationMessageIfNeeded(independent) else {
            Issue.record("The same external identity from another proved origin must remain legal.")
            return
        }
        var fresh = original
        fresh.id = UUID()
        fresh.messageId = "fresh-confirmation-message"
        fresh.rawPayload["message_id"] = AnyCodable(fresh.messageId!)
        fresh.rawPayload["entity_id"] = AnyCodable(fresh.messageId!)
        fresh.rawPayload["delivery_id"] = AnyCodable("fresh-confirmation-delivery")
        fresh.rawPayload["op_id"] = hasOperation ? AnyCodable("fresh-confirmation-operation") : nil
        guard case .persisted = try await reopened.persistNotificationMessageIfNeeded(fresh) else {
            Issue.record("Equal content with a genuinely new identity must remain receivable.")
            return
        }
        #expect(try await reopened.loadMessages().count == 2)
    }
}
