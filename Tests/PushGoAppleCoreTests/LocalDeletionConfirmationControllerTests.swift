import Foundation
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
}
