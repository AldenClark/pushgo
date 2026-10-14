import Foundation
import GRDB
import Testing
@testable import PushGoAppleCore

@MainActor
struct PendingLocalDeletionControllerTests {
    @Test
    func cancelledConfirmationDoesNotWriteIntentOrCanonicalData() async throws {
        try await withIsolatedLocalDataStore { (store, _) async throws -> Void in
            let target = Self.makeMessage(title: "cancel")
            try await store.saveMessage(target)
            _ = try await store.prepareLocalDeletion(intent: .messages(ids: [target.id]))
            #expect(try await store.loadMessage(id: target.id)?.title == target.title)
            #expect(try await store.loadPendingLocalDeletions(now: Date()).isEmpty)
        }
    }

    @Test
    func confirmedDeleteCommitsImmediatelyAndDuplicateDoesNotDeleteControl() async throws {
        try await withIsolatedLocalDataStore { (store, _) async throws -> Void in
            let target = Self.makeMessage(title: "target")
            let control = Self.makeMessage(title: "control")
            try await store.saveMessage(target)
            try await store.saveMessage(control)
            let confirmation = try await store.prepareLocalDeletion(intent: .messages(ids: [target.id, target.id]))
            let cleanup = try await store.deleteConfirmedLocalData(confirmation)
            #expect(cleanup.deletedRecordCount == 1)
            #expect(try await store.loadMessage(id: target.id) == nil)
            #expect(try await store.loadMessage(id: control.id)?.title == control.title)
            #expect(try await store.loadPendingLocalDeletions(now: Date()).allSatisfy { $0.state == .cleanupPending })
            #expect(try await store.deleteConfirmedLocalData(confirmation) == cleanup)
            let worker = await PendingLocalDeletionController(dataStore: store)
            await worker.reconcileCommittedCleanup()
            #expect(await worker.isDormant)
            #expect(try await store.loadPendingLocalDeletions(now: Date()).isEmpty)
            #expect(try await store.deleteConfirmedLocalData(confirmation).deletedRecordCount == 0)
            #expect(try await store.loadMessage(id: control.id)?.title == control.title)
        }
    }

    @Test
    func changedConfirmedVersionRejectsWholeTransactionWithoutIntent() async throws {
        try await withIsolatedLocalDataStore { (store, _) async throws -> Void in
            let first = Self.makeMessage(title: "first")
            let changed = Self.makeMessage(title: "second")
            try await store.saveMessage(first)
            try await store.saveMessage(changed)
            let confirmation = try await store.prepareLocalDeletion(intent: .messages(ids: [first.id, changed.id]))
            try await store.setMessageReadState(id: changed.id, isRead: true)
            do {
                _ = try await store.deleteConfirmedLocalData(confirmation)
                Issue.record("A stale confirmation deleted data")
            } catch {
                #expect((error as? AppError)?.code == "local_deletion_confirmation_changed")
            }
            #expect(try await store.loadMessage(id: first.id)?.title == first.title)
            #expect(try await store.loadMessage(id: changed.id)?.isRead == true)
            #expect(try await store.loadPendingLocalDeletions(now: Date()).isEmpty)
        }
    }

    @Test
    func configurationSwitchBeforeQueuedCommitRejectsConfirmedDeletion() async throws {
        try await withIsolatedLocalDataStore { (store, _) async throws -> Void in
            let target = Self.makeMessage(title: "configuration race")
            try await store.saveMessage(target)
            let confirmation = try await store.prepareLocalDeletion(intent: .messages(ids: [target.id]))
            #expect(confirmation.persistedConfiguration == nil)
            #expect(confirmation.summary == target.title)
            let entered = AsyncStream<Void>.makeStream()
            let release = AsyncStream<Void>.makeStream()
            await store.setBeforeConfirmedDeletionTransactionForTesting {
                entered.continuation.yield(())
                for await _ in release.stream { break }
            }
            let deletion = Task { try await store.deleteConfirmedLocalData(confirmation) }
            for await _ in entered.stream { break }
            try await store.saveServerConfig(ServerConfig(baseURL: URL(string: "https://replacement.example")!, token: "replacement"))
            release.continuation.yield(())
            do { _ = try await deletion.value; Issue.record("Config switch deleted the confirmed old target") }
            catch { #expect((error as? AppError)?.code == "local_deletion_confirmation_changed") }
            await store.setBeforeConfirmedDeletionTransactionForTesting(nil)
            #expect(try await store.loadMessage(id: target.id)?.title == target.title)
            #expect(try await store.loadPendingLocalDeletions(now: Date()).isEmpty)
        }
    }

    @Test
    func preparingAndCancellingDoesNotBackfillCredentialStore() async throws {
        try await withIsolatedLocalDataStore { (store, _) async throws -> Void in
            let target = Self.makeMessage(title: "read-only")
            try await store.saveMessage(target)
            let config = ServerConfig(baseURL: URL(string: "https://original.example")!, token: "original")
            try await store.saveServerConfig(config)
            #expect(ProviderGatewayTokenStore().save(token: nil, baseURL: config.baseURL))
            #expect(ProviderGatewayTokenStore().load(baseURL: config.baseURL) == nil)
            _ = try await store.prepareLocalDeletion(intent: .messages(ids: [target.id]))
            #expect(ProviderGatewayTokenStore().load(baseURL: config.baseURL) == nil)
            #expect(try await store.loadPendingLocalDeletions(now: Date()).isEmpty)
            #expect(try await store.loadMessage(id: target.id)?.title == target.title)
        }
    }

    @Test
    func unavailableTargetCannotCreateConfirmation() async throws {
        try await withIsolatedLocalDataStore { (store, _) async throws -> Void in
            do {
                _ = try await store.prepareLocalDeletion(intent: .messages(ids: [UUID()]))
                Issue.record("An unavailable target produced a confirmation")
            } catch { #expect((error as? AppError)?.code == "local_deletion_target_unavailable") }
            #expect(try await store.loadPendingLocalDeletions(now: Date()).isEmpty)
        }
    }

    @Test
    func sqliteFailureRollsBackCanonicalDeletionAndCleanupReceipt() async throws {
        try await withIsolatedLocalDataStore { (store, appGroup) async throws -> Void in
            let target = Self.makeMessage(title: "failure")
            try await store.saveMessage(target)
            let confirmation = try await store.prepareLocalDeletion(intent: .messages(ids: [target.id]))
            let directory = try AppConstants.appLocalDatabaseDirectory(appGroupIdentifier: appGroup)
            let queue = try DatabaseQueue(path: directory.appendingPathComponent(AppConstants.databaseStoreFilename).path)
            try await queue.write { db in
                try db.execute(sql: "CREATE TRIGGER reject_confirmed_delete BEFORE DELETE ON messages BEGIN SELECT RAISE(ABORT, 'injected deletion failure'); END;")
            }
            do { _ = try await store.deleteConfirmedLocalData(confirmation); Issue.record("Injected transaction failure succeeded") }
            catch { #expect(error.localizedDescription.contains("injected deletion failure")) }
            #expect(try await store.loadMessage(id: target.id)?.title == target.title)
            #expect(try await store.loadPendingLocalDeletions(now: Date()).isEmpty)
            try await queue.write { db in try db.execute(sql: "DROP TRIGGER reject_confirmed_delete;") }
            #expect(try await store.deleteConfirmedLocalData(confirmation).deletedRecordCount == 1)
        }
    }

    @Test
    func confirmedCleanupSurvivesStoreRecreationWithoutResurrectingData() async throws {
        try await withIsolatedLocalDataStore { (store, appGroup) async throws -> Void in
            let target = Self.makeMessage(title: "reopen")
            let control = Self.makeMessage(title: "control")
            try await store.saveMessage(target)
            try await store.saveMessage(control)
            let confirmation = try await store.prepareLocalDeletion(intent: .messages(ids: [target.id]))
            _ = try await store.deleteConfirmedLocalData(confirmation)
            let root = try #require(PushGoAutomationContext.storageRootOverrideURL)
            LocalDataStore.releaseSharedResourcesForTesting(storageRootURL: root)
            let reopened = LocalDataStore(appGroupIdentifier: appGroup, spotlightIndexer: nil)
            #expect(try await reopened.loadMessage(id: target.id) == nil)
            #expect(try await reopened.loadMessage(id: control.id)?.title == control.title)
            #expect(try await reopened.nextPendingLocalDeletionCleanup()?.id == confirmation.id)
            let worker = await PendingLocalDeletionController(dataStore: reopened)
            await worker.restoreAndReconcile()
            #expect(try await reopened.loadPendingLocalDeletions(now: Date()).isEmpty)
            #expect(await worker.isDormant)
        }
    }

    @Test
    func oldAcceptedQueueDrainsImmediatelyAndBecomesDormant() async throws {
        try await withIsolatedLocalDataStore { (store, _) async throws -> Void in
            let first = Self.makeMessage(title: "old undoable")
            let second = Self.makeMessage(title: "old queued")
            try await store.saveMessage(first)
            try await store.saveMessage(second)
            for message in [first, second] {
                _ = try await store.seedLegacyPendingLocalDeletion(summary: message.title, undoLabel: "Undo",
                    intent: .messages(ids: [message.id]), timeout: 3600, now: Date())
            }
            let worker = await PendingLocalDeletionController(dataStore: store)
            await worker.restoreAndReconcile()
            #expect(try await store.loadMessage(id: first.id) == nil)
            #expect(try await store.loadMessage(id: second.id) == nil)
            #expect(try await store.loadPendingLocalDeletions(now: Date()).isEmpty)
            #expect(await worker.isDormant)
            await worker.sceneBecameActive()
            #expect(await worker.isDormant)
        }
    }

    @Test
    func relatedScopeChangeRequiresConfirmationAgain() async throws {
        try await withIsolatedLocalDataStore { (store, _) async throws -> Void in
            let target = Self.makeEntityMessage(kind: "thing", entityID: "target")
            let control = Self.makeEntityMessage(kind: "thing", entityID: "control")
            try await store.saveMessage(target)
            try await store.saveMessage(control)
            let stale = try await store.prepareLocalDeletion(intent: .things(ids: ["target"]))
            let added = Self.makeEntityMessage(kind: "thing", entityID: "target")
            try await store.saveMessage(added)
            do { _ = try await store.deleteConfirmedLocalData(stale); Issue.record("Changed related scope was deleted") }
            catch { #expect((error as? AppError)?.code == "local_deletion_confirmation_changed") }
            #expect(try await store.loadMessage(id: target.id) != nil)
            var relatedEvent = Self.makeEntityMessage(kind: "event", entityID: "related-event")
            relatedEvent.rawPayload["thing_id"] = AnyCodable("target")
            relatedEvent.rawPayload["projection_destination"] = AnyCodable("event_head")
            try await store.saveMessage(relatedEvent)
            #expect(try await store.loadEventProjectionDetail(eventId: "related-event").head != nil)
            let confirmed = try await store.prepareLocalDeletion(intent: .things(ids: ["target"]))
            #expect(try await store.deleteConfirmedLocalData(confirmed).deletedRecordCount == 3)
            #expect(try await store.loadEventProjectionDetail(eventId: "related-event").head == nil)
            #expect(try await store.loadThingProjectionDetail(thingId: "control").head?.id == control.id)
            #expect(try await store.loadMessage(id: target.id) == nil)
            #expect(try await store.loadMessage(id: added.id) == nil)
            #expect(try await store.loadMessage(id: control.id)?.title == control.title)
        }
    }

    @Test
    func cleanupPendingSurvivesExecutorLossAndIsReconciledOnRestore() async throws {
        try await withIsolatedLocalDataStore { (store, _) async throws -> Void in
            let message = Self.makeMessage(title: "cleanup-recovery")
            try await store.saveMessage(message)
            let now = Date()
            _ = try await store.seedLegacyPendingLocalDeletion(
                summary: message.title,
                undoLabel: "Undo",
                intent: .messages(ids: [message.id]),
                timeout: 0,
                now: now
            )
            let claimed = try #require(try await store.claimNextPendingLocalDeletion(
                owner: "lost-executor",
                leaseDuration: 30,
                now: now
            ))
            _ = try await store.commitClaimedPendingLocalDeletion(
                id: claimed.id,
                owner: "lost-executor",
                now: now
            )
            #expect(try await store.nextPendingLocalDeletionCleanup() != nil)

            let restored = await PendingLocalDeletionController(dataStore: store)
            await restored.restoreAndReconcile()

            #expect(try await store.loadMessage(id: message.id) == nil)
            #expect(try await store.loadPendingLocalDeletions(now: Date()).isEmpty)
        }
    }

    @Test
    func expiredDeletionLeaseIsReclaimedByNextExecutorWithoutDuplicateIntent() async throws {
        try await withIsolatedLocalDataStore { (store, _) async throws -> Void in
            let message = Self.makeMessage(title: "lease-recovery")
            try await store.saveMessage(message)
            let startedAt = Date()
            let pending = try await store.seedLegacyPendingLocalDeletion(
                summary: message.title,
                undoLabel: "Undo",
                intent: .messages(ids: [message.id]),
                timeout: 0,
                now: startedAt
            )

            let firstClaim = try #require(try await store.claimNextPendingLocalDeletion(
                owner: "first-executor",
                leaseDuration: 1,
                now: startedAt
            ))
            #expect(firstClaim.id == pending.id)
            #expect(firstClaim.state == .executing)
            #expect(firstClaim.attemptCount == 1)

            let recoveredAt = startedAt.addingTimeInterval(2)
            let secondClaim = try #require(try await store.claimNextPendingLocalDeletion(
                owner: "second-executor",
                leaseDuration: 30,
                now: recoveredAt
            ))
            #expect(secondClaim.id == pending.id)
            #expect(secondClaim.state == .executing)
            #expect(secondClaim.attemptCount == 2)
            #expect(secondClaim.leaseOwner == "second-executor")
            #expect(secondClaim.lastErrorCode == "execution_lease_expired")

            await #expect(throws: (any Error).self) {
                _ = try await store.commitClaimedPendingLocalDeletion(
                    id: secondClaim.id,
                    owner: "first-executor",
                    now: recoveredAt
                )
            }
            #expect(try await store.loadMessage(id: message.id) != nil)

            _ = try await store.commitClaimedPendingLocalDeletion(
                id: secondClaim.id,
                owner: "second-executor",
                now: recoveredAt
            )
            try await store.completePendingLocalDeletionCleanup(id: secondClaim.id)

            #expect(try await store.loadMessage(id: message.id) == nil)
            #expect(try await store.loadPendingLocalDeletions(now: recoveredAt).isEmpty)
        }
    }

    @Test
    func failedChannelCommitRollsBackPrimaryDeletionAndKeepsDurableLease() async throws {
        try await withIsolatedLocalDataStore { (store, _) async throws -> Void in
            let message = Self.makeMessage(title: "channel-rollback", channel: "channel-a")
            try await store.saveMessage(message)
            let now = Date()
            let pending = try await store.seedLegacyPendingLocalDeletion(
                summary: "channel-a",
                undoLabel: "Undo",
                intent: .channelHistory(
                    channelID: "channel-a",
                    expectedGateway: "gateway-a",
                    expectedUpdatedAt: now
                ),
                timeout: 0,
                now: now
            )
            _ = try #require(try await store.claimNextPendingLocalDeletion(
                owner: "channel-owner",
                leaseDuration: 30,
                now: now
            ))

            await #expect(throws: (any Error).self) {
                _ = try await store.commitClaimedPendingLocalDeletion(
                    id: pending.id,
                    owner: "channel-owner",
                    now: now
                )
            }

            #expect(try await store.loadMessage(id: message.id) != nil)
            let retained = try #require(
                try await store.loadPendingLocalDeletions(now: now).first { $0.id == pending.id }
            )
            #expect(retained.state == .executing)
            #expect(retained.leaseOwner == "channel-owner")
        }
    }

    @Test
    func channelIntentPayloadContainsNoChannelCredential() throws {
        let marker = "credential-marker-that-must-not-be-persisted"
        let intent = PendingLocalDeletionIntent.channelHistory(
            channelID: "channel-a",
            expectedGateway: "gateway-a",
            expectedUpdatedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        let encoded = try JSONEncoder().encode(intent)
        let payload = try #require(String(data: encoded, encoding: .utf8))

        #expect(!payload.contains(marker))
        #expect(!payload.lowercased().contains("password"))
        #expect(!payload.lowercased().contains("token"))
    }

    @Test
    func persistedChannelIntentPreservesSubsecondSubscriptionVersion() async throws {
        try await withIsolatedLocalDataStore { (store, _) async throws -> Void in
            let expected = Date(timeIntervalSince1970: 1_800_000_000.123)
            let inserted = try await store.seedLegacyPendingLocalDeletion(
                summary: "channel",
                undoLabel: "Undo",
                intent: .channelHistory(
                    channelID: "channel-a",
                    expectedGateway: "gateway-a",
                    expectedUpdatedAt: expected
                ),
                timeout: 5,
                now: Date()
            )
            let restored = try #require(
                try await store.loadPendingLocalDeletions(now: Date()).first { $0.id == inserted.id }
            )
            guard case let .channelHistory(_, _, actual) = restored.intent else {
                Issue.record("Expected a restored channel deletion intent.")
                return
            }
            #expect(abs(actual.timeIntervalSince(expected)) < 0.000_001)
        }
    }

    @Test
    func malformedPersistedIntentIsQuarantinedAndDoesNotBlockQueuedDeletion() async throws {
        try await withIsolatedAutomationStorage { _, appGroupIdentifier in
            let store = LocalDataStore(
                appGroupIdentifier: appGroupIdentifier,
                spotlightIndexer: nil
            )
            let now = Date()
            let first = try await store.seedLegacyPendingLocalDeletion(
                summary: "invalid",
                undoLabel: "Undo",
                intent: .events(ids: ["event-invalid"]),
                timeout: 5,
                now: now
            )
            _ = try await store.seedLegacyPendingLocalDeletion(
                summary: "valid",
                undoLabel: "Undo",
                intent: .events(ids: ["event-valid"]),
                timeout: 5,
                now: now
            )
            let directory = try AppConstants.appLocalDatabaseDirectory(
                appGroupIdentifier: appGroupIdentifier
            )
            let queue = try DatabaseQueue(
                path: directory.appendingPathComponent(AppConstants.databaseStoreFilename).path
            )
            try await queue.write { db in
                try db.execute(
                    sql: "UPDATE pending_local_deletions SET payload_json = 'not-json' WHERE id = ?;",
                    arguments: [first.id.uuidString]
                )
            }

            let active = try await store.loadPendingLocalDeletions(now: now)

            #expect(active.count == 1)
            #expect(active.first?.intent == .events(ids: ["event-valid"]))
            #expect(active.first?.state == .queued)
            #expect(active.first?.deadline == nil)
            #expect(try await store.pendingLocalDeletionRecoveryCount() == 1)
            let worker = await PendingLocalDeletionController(dataStore: store)
            await worker.restoreAndReconcile()
            #expect(await worker.recoveryRequiredCount == 1)
            #expect(await worker.recoveryErrorCodes == ["invalid_persisted_payload"])
            #expect(await worker.isDormant == false)
            #expect(try await store.loadPendingLocalDeletions(now: now).isEmpty)
            let payload = try await queue.read { db in
                try String.fetchOne(db, sql: "SELECT payload_json FROM pending_local_deletions WHERE id = ?;", arguments: [first.id.uuidString])
            }
            #expect(payload == "not-json")
        }
    }

    nonisolated private static func makeMessage(
        title: String,
        channel: String = "test"
    ) -> PushMessage {
        let id = UUID()
        let messageID = "message-\(id.uuidString.lowercased())"
        return PushMessage(
            id: id,
            messageId: messageID,
            title: title,
            body: "body",
            channel: channel,
            rawPayload: ["message_id": AnyCodable(messageID)]
        )
    }

    nonisolated private static func makeEntityMessage(
        kind: String,
        entityID: String
    ) -> PushMessage {
        let id = UUID()
        let messageID = "entity-message-\(id.uuidString.lowercased())"
        var payload: [String: AnyCodable] = [
            "message_id": AnyCodable(messageID),
            "entity_type": AnyCodable(kind),
            "entity_id": AnyCodable(entityID),
        ]
        payload[kind == "event" ? "event_id" : "thing_id"] = AnyCodable(entityID)
        return PushMessage(
            id: id,
            messageId: messageID,
            title: entityID,
            body: "body",
            channel: "test",
            rawPayload: payload
        )
    }
}
