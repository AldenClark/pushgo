import Foundation
import GRDB
import Testing
@testable import PushGoAppleCore

struct DeletedEntityReplayTests {
    @Test
    func confirmedEventDeletionDoesNotRecreateTheSameDeliveryOrOperation() async throws {
        try await verifyDeletedReplay(entityType: "event")
    }

    @Test
    func confirmedThingDeletionDoesNotRecreateTheSameDeliveryOrOperation() async throws {
        try await verifyDeletedReplay(entityType: "thing")
    }

    private func verifyDeletedReplay(entityType: String) async throws {
        try await withIsolatedAutomationStorage { root, group in
            let store = LocalDataStore(appGroupIdentifier: group, spotlightIndexer: nil)
            let entityID = "deleted-\(entityType)"
            let payload = entityPayload(entityType: entityType, entityID: entityID, suffix: "first")
            let first = await NotificationPersistenceCoordinator.persistRemotePayloadIfNeeded(
                payload, requestIdentifier: "\(entityType)-delivery-first", dataStore: store)
            guard case let .persistedMain(saved) = first else {
                Issue.record("A valid entity must first persist through normal notification ingress.")
                return
            }
            _ = try await store.deleteConfirmedLocalData(try await store.prepareLocalDeletion(
                intent: entityType == "event" ? .events(ids: [entityID]) : .things(ids: [entityID])))
            #expect(try await canonicalCount(group: group) == 0)
            let replay = await NotificationPersistenceCoordinator.persistRemotePayloadIfNeeded(
                payload, requestIdentifier: "\(entityType)-delivery-first", dataStore: store)
            guard case .duplicate = replay else {
                Issue.record("The same deleted entity delivery must not recreate content.")
                return
            }
            #expect(ProviderIngressPersistenceResult(replay).allowsAck)
            var operationReplay = payload
            operationReplay["delivery_id"] = "different-envelope"
            #expect(isDuplicate(await NotificationPersistenceCoordinator.persistRemotePayloadIfNeeded(
                operationReplay, requestIdentifier: "different-envelope", dataStore: store)))
            var deliveryReplay = payload
            deliveryReplay["op_id"] = nil
            #expect(isDuplicate(await NotificationPersistenceCoordinator.persistRemotePayloadIfNeeded(
                deliveryReplay, requestIdentifier: "delivery-only-replay", dataStore: store)))
            #expect(try await store.saveMessages([saved]).isEmpty)
            try await store.saveEntityRecords([saved])
            #expect(try await canonicalCount(group: group) == 0)

            LocalDataStore.releaseSharedResourcesForTesting(storageRootURL: root)
            let reopened = LocalDataStore(appGroupIdentifier: group, spotlightIndexer: nil)
            let afterRestart = await NotificationPersistenceCoordinator.persistRemotePayloadIfNeeded(
                payload, requestIdentifier: "\(entityType)-delivery-first", dataStore: reopened)
            guard case .duplicate = afterRestart else {
                Issue.record("Processed entity identity must survive reopening.")
                return
            }
            #expect(try await canonicalCount(group: group) == 0)
            let fresh = entityPayload(entityType: entityType, entityID: entityID, suffix: "fresh")
            let next = await NotificationPersistenceCoordinator.persistRemotePayloadIfNeeded(
                fresh, requestIdentifier: "\(entityType)-delivery-fresh", dataStore: reopened)
            guard case .persistedMain = next else {
                Issue.record("A new operation/delivery for the same entity remains legal.")
                return
            }
            #expect(try await canonicalCount(group: group) == 1)
            #expect(try await reopened.loadMessage(messageId: "\(entityType)-record-fresh")?.body == "Exact \(entityType) body")
        }
    }

    @Test
    func deletingAWaitingEventPreventsRequeueButNotAnotherParentDomain() async throws {
        try await withIsolatedAutomationStorage { _, group in
            let store = LocalDataStore(appGroupIdentifier: group, spotlightIndexer: nil)
            var waiting = entityPayload(entityType: "event", entityID: "child-event", suffix: "waiting")
            waiting["thing_id"] = "deleted-parent"
            // This projection flag must not define another delivery lifecycle.
            waiting["projection_destination"] = "event_head"
            let pending = await NotificationPersistenceCoordinator.persistRemotePayloadIfNeeded(
                waiting, requestIdentifier: "event-delivery-waiting", dataStore: store)
            guard case .persistedPending = pending else {
                Issue.record("A valid child must first be durable in the waiting area.")
                return
            }
            _ = try await store.deleteConfirmedLocalData(
                try await store.prepareLocalDeletion(intent: .things(ids: ["deleted-parent"])))
            #expect(isDuplicate(await NotificationPersistenceCoordinator.persistRemotePayloadIfNeeded(
                waiting, requestIdentifier: "event-delivery-waiting", dataStore: store)))
            #expect(try await pendingCount(group: group) == 0)

            // Same event/op in a distinct parent domain remains a legal child.
            var independent = waiting
            independent["thing_id"] = "new-parent"
            independent["message_id"] = "event-new-parent-record"
            independent["delivery_id"] = "event-new-parent-delivery"
            let otherPending = await NotificationPersistenceCoordinator.persistRemotePayloadIfNeeded(
                independent, requestIdentifier: "event-new-parent-delivery", dataStore: store)
            guard case .persistedPending = otherPending else {
                Issue.record("Deletion cannot permanently suppress another parent lifecycle.")
                return
            }
            let parent = entityPayload(entityType: "thing", entityID: "new-parent", suffix: "parent")
            let accepted = await NotificationPersistenceCoordinator.persistRemotePayloadIfNeeded(
                parent, requestIdentifier: "thing-delivery-parent", dataStore: store)
            guard case .persistedMain = accepted else { Issue.record("Parent must persist."); return }
            #expect(try await pendingCount(group: group) == 0)
            let child = try #require(try await store.loadMessage(messageId: "event-new-parent-record"))
            #expect(child.thingId == "new-parent")
            _ = try await store.deleteConfirmedLocalData(
                try await store.prepareLocalDeletion(intent: .events(ids: ["child-event"])))
            #expect(isDuplicate(await NotificationPersistenceCoordinator.persistRemotePayloadIfNeeded(
                independent, requestIdentifier: "event-new-parent-delivery", dataStore: store)))
            #expect(try await pendingCount(group: group) == 0)
            #expect(try await store.loadMessage(messageId: "event-new-parent-record") == nil)
        }
    }

    @Test
    func eventConfirmationAlsoConsumesWaitingEventsAndNotAnotherEntity() async throws {
        try await withIsolatedAutomationStorage { _, group in
            let store = LocalDataStore(appGroupIdentifier: group, spotlightIndexer: nil)
            for entityID in ["deleted-event", "kept-event"] {
                var payload = entityPayload(entityType: "event", entityID: entityID, suffix: entityID)
                payload["thing_id"] = "missing-parent"
                _ = await NotificationPersistenceCoordinator.persistRemotePayloadIfNeeded(
                    payload, requestIdentifier: "event-delivery-\(entityID)", dataStore: store)
            }
            _ = try await store.deleteConfirmedLocalData(
                try await store.prepareLocalDeletion(intent: .events(ids: ["deleted-event"])))
            #expect(try await pendingCount(group: group) == 1)
            var replay = entityPayload(entityType: "event", entityID: "deleted-event", suffix: "deleted-event")
            replay["thing_id"] = "missing-parent"
            #expect(isDuplicate(await NotificationPersistenceCoordinator.persistRemotePayloadIfNeeded(
                replay, requestIdentifier: "event-delivery-deleted-event", dataStore: store)))
            #expect(try await pendingCount(group: group) == 1)
            #expect(try await canonicalCount(group: group) == 0)
        }
    }

    @Test(arguments: ["event", "thing"], ["gateway", "recipient"])
    func entityDeletionFactsDoNotBorrowAnotherGatewayOrRecipient(_ entityType: String, changedScope: String) async throws {
        try await withIsolatedAutomationStorage { _, group in
            let store = LocalDataStore(appGroupIdentifier: group, spotlightIndexer: nil)
            let original = entityPayload(entityType: entityType, entityID: "shared-entity", suffix: "source")
            _ = await NotificationPersistenceCoordinator.persistRemotePayloadIfNeeded(
                original, requestIdentifier: "\(entityType)-delivery-source", dataStore: store)
            _ = try await store.deleteConfirmedLocalData(try await store.prepareLocalDeletion(
                intent: entityType == "event" ? .events(ids: ["shared-entity"]) : .things(ids: ["shared-entity"])))
            var independent = original
            independent["base_url"] = changedScope == "gateway"
                ? "https://gateway-a.invalid/other-prefix" : original["base_url"]
            independent["provider_device_key"] = changedScope == "recipient"
                ? "recipient-b" : original["provider_device_key"]
            independent["message_id"] = "other-source-\(entityType)"
            let result = await NotificationPersistenceCoordinator.persistRemotePayloadIfNeeded(
                independent, requestIdentifier: "\(entityType)-delivery-source", dataStore: store)
            guard case .persistedMain = result else { Issue.record("Another origin has no deleted identity."); return }
            #expect(isDuplicate(await NotificationPersistenceCoordinator.persistRemotePayloadIfNeeded(
                original, requestIdentifier: "\(entityType)-delivery-source", dataStore: store)))
            #expect(try await canonicalCount(group: group) == 1)
            #expect(try await store.loadMessage(messageId: "other-source-\(entityType)")?.providerSourceBaseURL == independent["base_url"] as? String)
        }
    }

    private func canonicalCount(group: String) async throws -> Int {
        let url = try AppConstants.appLocalDatabaseDirectory(appGroupIdentifier: group)
            .appendingPathComponent(AppConstants.databaseStoreFilename)
        let queue = try DatabaseQueue(path: url.path)
        return try await queue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM messages;") ?? 0 }
    }

    private func pendingCount(group: String) async throws -> Int {
        let url = try AppConstants.appLocalDatabaseDirectory(appGroupIdentifier: group)
            .appendingPathComponent(AppConstants.databaseStoreFilename)
        let queue = try DatabaseQueue(path: url.path)
        return try await queue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM pending_inbound_messages;") ?? 0 }
    }

    private func isDuplicate(_ result: NotificationPersistenceOutcome) -> Bool {
        if case .duplicate = result { return true }
        return false
    }

    private func entityPayload(entityType: String, entityID: String, suffix: String) -> [AnyHashable: Any] {
        var payload: [AnyHashable: Any] = [
            "entity_type": entityType, "entity_id": entityID,
            "message_id": "\(entityType)-record-\(suffix)",
            "delivery_id": "\(entityType)-delivery-\(suffix)",
            "op_id": "\(entityType)-operation-\(suffix)", "channel_id": "lifecycle",
            "title": "Exact \(entityType) title", "body": "Exact \(entityType) body",
            "base_url": "https://gateway-a.invalid/prefix", "provider_device_key": "recipient-a",
            "sent_at": "2026-10-23T10:00:00Z",
        ]
        payload[entityType == "event" ? "event_id" : "thing_id"] = entityID
        return payload
    }
}
