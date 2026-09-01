import Foundation
import GRDB
import Testing
@testable import PushGoAppleCore

private struct DeletionTestItem: Sendable {
    let id: String
    let title: String
}

@MainActor
struct PendingLocalDeletionControllerTests {
    private func waitUntil(
        timeout: Duration = .seconds(3),
        interval: Duration = .milliseconds(10),
        _ condition: @escaping @MainActor () async -> Bool
    ) async -> Bool {
        let start = ContinuousClock.now
        while ContinuousClock.now - start < timeout {
            if await condition() { return true }
            try? await Task.sleep(for: interval)
        }
        return await condition()
    }

    @Test
    func countdownExpiryDeletesCanonicalMessageAndClearsDurableIntent() async throws {
        try await withIsolatedLocalDataStore { store, _ in
            let message = Self.makeMessage(title: "expires")
            try await store.saveMessage(message)
            let controller = await PendingLocalDeletionController(dataStore: store, timeout: 0.03)

            let scheduled = await controller.schedule(
                summary: message.title,
                undoLabel: "Undo",
                intent: .messages(ids: [message.id])
            )
            #expect(scheduled)

            let completed = await waitUntil(timeout: .seconds(10)) {
                let stored = try? await store.loadMessage(id: message.id)
                let records = try? await store.loadPendingLocalDeletions(now: Date())
                return stored == nil && records?.isEmpty == true
            }
            #expect(completed)
            #expect(await controller.pendingDeletion == nil)
            #expect(await controller.effectiveScope.messageIDs.isEmpty)
        }
    }

    @Test
    func undoRemovesOnlyTheIntentAndPreservesCanonicalMessage() async throws {
        try await withIsolatedLocalDataStore { store, _ in
            let message = Self.makeMessage(title: "undo")
            try await store.saveMessage(message)
            let controller = await PendingLocalDeletionController(dataStore: store, timeout: 5)
            _ = await controller.schedule(
                summary: message.title,
                undoLabel: "Undo",
                intent: .messages(ids: [message.id])
            )

            await controller.undoCurrent()
            let undone = await waitUntil {
                (try? await store.loadPendingLocalDeletions(now: Date()).isEmpty) == true
            }

            #expect(undone)
            #expect(try await store.loadMessage(id: message.id) != nil)
            #expect(await controller.effectiveScope.messageIDs.isEmpty)
        }
    }

    @Test
    func restoredControllerRecoversIntentAndCanFinishDeletion() async throws {
        try await withIsolatedLocalDataStore { store, _ in
            let message = Self.makeMessage(title: "restore")
            try await store.saveMessage(message)
            let first = await PendingLocalDeletionController(dataStore: store, timeout: 5)
            _ = await first.schedule(
                summary: message.title,
                undoLabel: "Undo",
                intent: .messages(ids: [message.id])
            )

            let restored = await PendingLocalDeletionController(dataStore: store, timeout: 5)
            await restored.restoreAndReconcile()
            #expect(await restored.pendingDeletion?.id == first.pendingDeletion?.id)
            #expect(await restored.effectiveScope.messageIDs == Set([message.id]))

            await restored.commitCurrentIfNeeded()
            #expect(try await store.loadMessage(id: message.id) == nil)
            #expect(try await store.loadPendingLocalDeletions(now: Date()).isEmpty)
        }
    }

    @Test
    func restoringPendingStateSuppressesDueContentWithoutExecutingDeletion() async throws {
        try await withIsolatedLocalDataStore { store, _ in
            let message = Self.makeMessage(title: "deferred restore")
            try await store.saveMessage(message)
            _ = try await store.enqueuePendingLocalDeletion(
                summary: message.title,
                undoLabel: "Undo",
                intent: .messages(ids: [message.id]),
                timeout: 0,
                now: Date(timeIntervalSinceNow: -1)
            )

            let controller = await PendingLocalDeletionController(dataStore: store, timeout: 5)
            await controller.restorePendingState()

            #expect(try await store.loadMessage(id: message.id) != nil)
            #expect(await controller.effectiveScope.messageIDs == Set([message.id]))

            await controller.processDueDeletions()
            #expect(try await store.loadMessage(id: message.id) == nil)
        }
    }

    @Test
    func queueKeepsOneUndoWindowAndPromotesNextAfterUndo() async throws {
        await withIsolatedLocalDataStore { store, _ in
            let controller = await PendingLocalDeletionController(dataStore: store, timeout: 5)
            _ = await controller.schedule(
                summary: "first",
                undoLabel: "Undo",
                intent: .events(ids: ["event-a"])
            )
            _ = await controller.schedule(
                summary: "second",
                undoLabel: "Undo",
                intent: .events(ids: ["event-b"])
            )

            #expect(await controller.pendingDeletion?.scope.eventIDs == Set(["event-a"]))
            #expect(await controller.effectiveScope.eventIDs == Set(["event-a", "event-b"]))
            await controller.undoCurrent()

            let promoted = await waitUntil {
                controller.pendingDeletion?.scope.eventIDs == Set(["event-b"])
            }
            #expect(promoted)
            #expect(await controller.effectiveScope.eventIDs == Set(["event-b"]))
        }
    }

    @Test
    func committingCurrentEntryGivesNextQueuedEntryAFreshUndoWindow() async throws {
        try await withIsolatedLocalDataStore { store, _ in
            let controller = await PendingLocalDeletionController(dataStore: store, timeout: 5)
            _ = await controller.schedule(
                summary: "first",
                undoLabel: "Undo",
                intent: .events(ids: ["event-a"])
            )
            _ = await controller.schedule(
                summary: "second",
                undoLabel: "Undo",
                intent: .events(ids: ["event-b"])
            )
            let commitStarted = Date()

            await controller.commitCurrentIfNeeded()

            let next = try #require(try await store.loadPendingLocalDeletions(now: Date()).first {
                $0.intent == .events(ids: ["event-b"])
            })
            #expect(next.state == .undoable)
            #expect((next.deadline?.timeIntervalSince(commitStarted) ?? 0) > 4.5)
            #expect(await controller.pendingDeletion?.scope.eventIDs == Set(["event-b"]))
        }
    }

    @Test
    func countdownUsesAbsoluteDeadlineWithoutAnInteractionPauseState() async throws {
        try await withIsolatedLocalDataStore { store, _ in
            let message = Self.makeMessage(title: "absolute-deadline")
            try await store.saveMessage(message)
            let controller = await PendingLocalDeletionController(dataStore: store, timeout: 0.03)
            _ = await controller.schedule(
                summary: message.title,
                undoLabel: "Undo",
                intent: .messages(ids: [message.id])
            )

            try? await Task.sleep(for: .milliseconds(100))
            await controller.sceneBecameActive()
            #expect(try await store.loadMessage(id: message.id) == nil)
            #expect(await controller.pendingDeletion == nil)
        }
    }

    @Test
    func undoAndLeaseClaimRaceHasExactlyOneWinner() async throws {
        try await withIsolatedLocalDataStore { store, _ in
            let now = Date()
            let record = try await store.enqueuePendingLocalDeletion(
                summary: "race",
                undoLabel: "Undo",
                intent: .events(ids: ["race-event"]),
                timeout: 0,
                now: now
            )

            async let undo = store.undoPendingLocalDeletion(id: record.id, timeout: 5, now: now)
            async let claim = store.claimNextPendingLocalDeletion(
                owner: "test-owner",
                leaseDuration: 30,
                timeout: 5,
                now: now
            )
            let (didUndo, claimed) = try await (undo, claim)

            #expect(didUndo != (claimed != nil))
            if let claimed {
                _ = try await store.commitClaimedPendingLocalDeletion(
                    id: claimed.id,
                    owner: "test-owner",
                    now: now
                )
                try await store.completePendingLocalDeletionCleanup(id: claimed.id)
            }
            #expect(try await store.loadPendingLocalDeletions(now: now).isEmpty)
        }
    }

    @Test
    func cleanupPendingSurvivesExecutorLossAndIsReconciledOnRestore() async throws {
        try await withIsolatedLocalDataStore { store, _ in
            let message = Self.makeMessage(title: "cleanup-recovery")
            try await store.saveMessage(message)
            let now = Date()
            _ = try await store.enqueuePendingLocalDeletion(
                summary: message.title,
                undoLabel: "Undo",
                intent: .messages(ids: [message.id]),
                timeout: 0,
                now: now
            )
            let claimed = try #require(try await store.claimNextPendingLocalDeletion(
                owner: "lost-executor",
                leaseDuration: 30,
                timeout: 5,
                now: now
            ))
            _ = try await store.commitClaimedPendingLocalDeletion(
                id: claimed.id,
                owner: "lost-executor",
                now: now
            )
            #expect(try await store.nextPendingLocalDeletionCleanup() != nil)

            let restored = await PendingLocalDeletionController(dataStore: store, timeout: 5)
            await restored.restoreAndReconcile()

            #expect(try await store.loadMessage(id: message.id) == nil)
            #expect(try await store.loadPendingLocalDeletions(now: Date()).isEmpty)
        }
    }

    @Test
    func expiredDeletionLeaseIsReclaimedByNextExecutorWithoutDuplicateIntent() async throws {
        try await withIsolatedLocalDataStore { store, _ in
            let message = Self.makeMessage(title: "lease-recovery")
            try await store.saveMessage(message)
            let startedAt = Date()
            let pending = try await store.enqueuePendingLocalDeletion(
                summary: message.title,
                undoLabel: "Undo",
                intent: .messages(ids: [message.id]),
                timeout: 0,
                now: startedAt
            )

            let firstClaim = try #require(try await store.claimNextPendingLocalDeletion(
                owner: "first-executor",
                leaseDuration: 1,
                timeout: 5,
                now: startedAt
            ))
            #expect(firstClaim.id == pending.id)
            #expect(firstClaim.state == .executing)
            #expect(firstClaim.attemptCount == 1)

            let recoveredAt = startedAt.addingTimeInterval(2)
            let secondClaim = try #require(try await store.claimNextPendingLocalDeletion(
                owner: "second-executor",
                leaseDuration: 30,
                timeout: 5,
                now: recoveredAt
            ))
            #expect(secondClaim.id == pending.id)
            #expect(secondClaim.state == .executing)
            #expect(secondClaim.attemptCount == 2)
            #expect(secondClaim.leaseOwner == "second-executor")
            #expect(secondClaim.lastErrorCode == "execution_lease_expired")

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
        try await withIsolatedLocalDataStore { store, _ in
            let message = Self.makeMessage(title: "channel-rollback", channel: "channel-a")
            try await store.saveMessage(message)
            let now = Date()
            let pending = try await store.enqueuePendingLocalDeletion(
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
                timeout: 5,
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
    func backgroundDrainEndsAllUndoWindowsAndDeletesEntireQueue() async throws {
        try await withIsolatedLocalDataStore { store, _ in
            let first = Self.makeMessage(title: "first")
            let second = Self.makeMessage(title: "second")
            try await store.saveMessage(first)
            try await store.saveMessage(second)
            let controller = await PendingLocalDeletionController(dataStore: store, timeout: 5)
            _ = await controller.schedule(
                summary: first.title,
                undoLabel: "Undo",
                intent: .messages(ids: [first.id])
            )
            _ = await controller.schedule(
                summary: second.title,
                undoLabel: "Undo",
                intent: .messages(ids: [second.id])
            )

            await controller.commitAllForBackground()

            #expect(try await store.loadMessage(id: first.id) == nil)
            #expect(try await store.loadMessage(id: second.id) == nil)
            #expect(try await store.loadPendingLocalDeletions(now: Date()).isEmpty)
        }
    }

    @Test
    func durableExecutorsDeleteEventAndThingRecords() async throws {
        try await withIsolatedLocalDataStore { store, _ in
            let event = Self.makeEntityMessage(kind: "event", entityID: "event-a")
            let thing = Self.makeEntityMessage(kind: "thing", entityID: "thing-a")
            try await store.saveMessage(event)
            try await store.saveMessage(thing)
            let controller = await PendingLocalDeletionController(dataStore: store, timeout: 5)
            _ = await controller.schedule(
                summary: "event-a",
                undoLabel: "Undo",
                intent: .events(ids: ["event-a"])
            )
            _ = await controller.schedule(
                summary: "thing-a",
                undoLabel: "Undo",
                intent: .things(ids: ["thing-a"])
            )

            await controller.commitAllForBackground()

            #expect(try await store.loadMessage(id: event.id) == nil)
            #expect(try await store.loadMessage(id: thing.id) == nil)
            #expect(try await store.loadPendingLocalDeletions(now: Date()).isEmpty)
        }
    }

    @Test
    func scheduleItemsDeduplicatesBeforePersistingIntent() async throws {
        try await withIsolatedLocalDataStore { store, _ in
            let controller = await PendingLocalDeletionController(dataStore: store, timeout: 5)
            let result = await controller.scheduleItems(
                [
                    DeletionTestItem(id: "event-a", title: "Alpha"),
                    DeletionTestItem(id: "event-a", title: "Duplicate"),
                    DeletionTestItem(id: "event-b", title: "Beta"),
                ],
                identity: { $0.id },
                title: { $0.title },
                fallbackSingleSummary: "Event",
                multipleSummaryTitle: "Events",
                undoLabel: "Undo",
                intent: { .events(ids: $0) }
            )

            #expect(result?.map(\.id) == ["event-a", "event-b"])
            #expect(await controller.pendingDeletion?.summary == "2 × Events")
            let persisted = try #require(try await store.loadPendingLocalDeletions(now: Date()).first)
            #expect(persisted.intent == .events(ids: ["event-a", "event-b"]))
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
        try await withIsolatedLocalDataStore { store, _ in
            let expected = Date(timeIntervalSince1970: 1_800_000_000.123)
            let inserted = try await store.enqueuePendingLocalDeletion(
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
            let first = try await store.enqueuePendingLocalDeletion(
                summary: "invalid",
                undoLabel: "Undo",
                intent: .events(ids: ["event-invalid"]),
                timeout: 5,
                now: now
            )
            _ = try await store.enqueuePendingLocalDeletion(
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
            #expect(active.first?.state == .undoable)
            #expect(active.first?.deadline != nil)
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
