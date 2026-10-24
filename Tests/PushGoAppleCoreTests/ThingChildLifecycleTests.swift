import Foundation
import GRDB
import Testing
@testable import PushGoAppleCore

struct ThingChildLifecycleTests {
    @Test
    func pendingMessageAndEventChildrenReplayWithCanonicalFieldsAndFreshRowsAfterReopen() async throws {
        try await withIsolatedAutomationStorage { root, appGroupIdentifier in
            let thingID = "thing-child-replay"
            let message = child(
                messageID: "thing-child-message", title: "Message child", body: "Message body",
                thingID: thingID, entityType: "message", operationID: "op-message",
                receivedAt: Date(timeIntervalSince1970: 1_800_100_101)
            )
            let event = child(
                messageID: "thing-child-event", title: "Event child", body: "Event body",
                thingID: thingID, entityType: "event", eventID: "event-child-id",
                operationID: "op-event", eventState: "open",
                receivedAt: Date(timeIntervalSince1970: 1_800_100_102)
            )
            let beforeRows: [PendingChildSnapshot]
            do {
                let store = LocalDataStore(appGroupIdentifier: appGroupIdentifier, spotlightIndexer: nil)
                _ = try await store.persistNotificationMessageIfNeeded(message)
                _ = try await store.persistNotificationMessageIfNeeded(event)

                let queue = try databaseQueue(appGroupIdentifier: appGroupIdentifier)
                beforeRows = try await queue.read { db in
                    try PendingChildSnapshot.fetch(db, thingID: thingID)
                }
                #expect(beforeRows.count == 2)
                #expect(Set(beforeRows.map(\.messageID)) == ["thing-child-message", "thing-child-event"])
                #expect(beforeRows.allSatisfy {
                    $0.rawPayloadJSON.contains("metadata")
                        && $0.channel == "channel-x"
                        && $0.url?.contains($0.messageID) == true
                        && $0.status == PushMessage.Status.partiallyDecrypted.rawValue
                        && $0.decryptionState == PushMessage.DecryptionState.decryptFailed.rawValue
                        && $0.notificationRequestID == "request-\($0.messageID)"
                        && $0.deliveryID == "delivery-\($0.messageID)"
                })
                #expect(try await store.loadMessages().isEmpty)
                #expect(try await store.loadThingProjectionDetail(thingId: thingID).messages.isEmpty)
                #expect(try await store.loadThingMessagesForProjectionPage(before: nil, limit: 10).isEmpty)
                let preParentState = try await queue.read { db in
                    let canonical = try Int.fetchOne(
                        db,
                        sql: "SELECT COUNT(*) FROM messages WHERE message_id IN ('thing-child-message', 'thing-child-event');"
                    ) ?? 0
                    let ledgers = try Int.fetchOne(
                        db,
                        sql: "SELECT COUNT(*) FROM operation_ledger WHERE message_id IN ('thing-child-message', 'thing-child-event');"
                    ) ?? 0
                    let derived = try Int.fetchOne(
                        db,
                        sql: """
                            SELECT COUNT(*) FROM canonical_derived_work w
                            JOIN messages m ON m.id = w.local_message_id
                            WHERE m.message_id IN ('thing-child-message', 'thing-child-event');
                            """
                    ) ?? 0
                    return (canonical, ledgers, derived)
                }
                #expect(preParentState.0 == 0)
                #expect(preParentState.1 == 0)
                #expect(preParentState.2 == 0)
            }

            LocalDataStore.releaseSharedResourcesForTesting(storageRootURL: root)
            let reopened = LocalDataStore(appGroupIdentifier: appGroupIdentifier, spotlightIndexer: nil)
            #expect(try await reopened.loadThingProjectionDetail(thingId: thingID).messages.isEmpty)
            try await reopened.saveMessage(parentThing(thingID: thingID))

            let detail = try await reopened.loadThingProjectionDetail(thingId: thingID)
            #expect(detail.head?.messageId == "parent-\(thingID)")
            #expect(Set(detail.history.map(\.messageId)) == ["parent-\(thingID)", "thing-child-message", "thing-child-event"])
            let restoredMessage = try #require(detail.history.first { $0.messageId == message.messageId })
            let restoredEvent = try #require(detail.history.first { $0.messageId == event.messageId })
            #expect(restoredMessage.title == message.title)
            #expect(restoredMessage.body == message.body)
            #expect(restoredMessage.channel == message.channel)
            #expect(restoredMessage.url == message.url)
            #expect(restoredMessage.status == message.status)
            #expect(restoredMessage.decryptionState == message.decryptionState)
            #expect(restoredMessage.isRead == false)
            #expect(restoredMessage.thingId == thingID)
            #expect(restoredMessage.metadata == message.metadata)
            #expect(restoredMessage.tags == message.tags)
            #expect(restoredEvent.title == event.title)
            #expect(restoredEvent.body == event.body)
            #expect(restoredEvent.eventId == "event-child-id")
            #expect(restoredEvent.eventState == "open")
            #expect(restoredEvent.thingId == thingID)
            #expect(restoredEvent.isRead == false)
            #expect(restoredEvent.metadata == event.metadata)

            let afterQueue = try databaseQueue(appGroupIdentifier: appGroupIdentifier)
            let afterRows = try await afterQueue.read { db in
                try PendingChildSnapshot.fetch(db, thingID: thingID)
            }
            #expect(afterRows.isEmpty)
            let canonicalState = try await afterQueue.read { db in
                let raw = try Dictionary(uniqueKeysWithValues: Row.fetchAll(
                    db,
                    sql: """
                        SELECT message_id, raw_payload_json, id, is_read, is_top_level_message,
                               title, body, channel, url, received_at, status, decryption_state,
                               notification_request_id, delivery_id, operation_id, entity_type,
                               entity_id, event_id, thing_id, projection_destination, event_state,
                               event_time_epoch, observed_time_epoch, occurred_at_epoch
                        FROM messages WHERE message_id IN ('thing-child-message', 'thing-child-event');
                        """
                ).map { row in
                    (
                        row["message_id"] as String,
                        CanonicalChildSnapshot(
                            rawPayloadJSON: row["raw_payload_json"], id: row["id"],
                            isRead: row["is_read"], isTopLevel: row["is_top_level_message"],
                            title: row["title"], body: row["body"],
                            channel: row["channel"], url: row["url"], receivedAt: row["received_at"],
                            status: row["status"], decryptionState: row["decryption_state"],
                            notificationRequestID: row["notification_request_id"], deliveryID: row["delivery_id"],
                            operationID: row["operation_id"], entityType: row["entity_type"],
                            entityID: row["entity_id"], eventID: row["event_id"], thingID: row["thing_id"],
                            projectionDestination: row["projection_destination"], eventState: row["event_state"],
                            eventTime: row["event_time_epoch"], observedTime: row["observed_time_epoch"],
                            occurredAt: row["occurred_at_epoch"]
                        )
                    )
                })
                let ledgerCount = try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM operation_ledger WHERE message_id IN ('thing-child-message', 'thing-child-event');"
                ) ?? 0
                let derivedCount = try Int.fetchOne(
                    db,
                    sql: """
                        SELECT COUNT(*) FROM canonical_derived_work w
                        JOIN messages m ON m.id = w.local_message_id
                        WHERE m.message_id IN ('thing-child-message', 'thing-child-event');
                        """
                ) ?? 0
                return (raw, ledgerCount, derivedCount)
            }
            for pending in beforeRows {
                let canonical = try #require(canonicalState.0[pending.messageID])
                #expect(canonical.rawPayloadJSON == pending.rawPayloadJSON)
                #expect(canonical.id != pending.pendingID)
                #expect(canonical.isRead == 0)
                #expect(canonical.isTopLevel == 0)
                #expect(canonical.title == pending.title)
                #expect(canonical.body == pending.body)
                #expect(pending.thingID == thingID)
                #expect(canonical.channel == pending.channel)
                #expect(canonical.url == pending.url)
                #expect(canonical.receivedAt == pending.receivedAt)
                #expect(canonical.status == pending.status)
                #expect(canonical.decryptionState == pending.decryptionState)
                #expect(canonical.notificationRequestID == pending.notificationRequestID)
                #expect(canonical.deliveryID == pending.deliveryID)
                #expect(canonical.operationID == pending.operationID)
                #expect(canonical.entityType == pending.entityType)
                #expect(canonical.entityID == pending.entityID)
                #expect(canonical.eventID == pending.eventID)
                #expect(canonical.thingID == thingID)
                #expect(canonical.projectionDestination == nil)
                #expect(canonical.eventState == pending.eventState)
                #expect(canonical.eventTime == pending.eventTime)
                #expect(canonical.observedTime == pending.observedTime)
                #expect(canonical.occurredAt == pending.occurredAt)
            }
            #expect(canonicalState.1 == 2)
            #expect(canonicalState.2 == 6)
            #expect(canonicalState.0["thing-child-message"]?.id != message.id.uuidString)
            #expect(canonicalState.0["thing-child-event"]?.id != event.id.uuidString)
            #expect(beforeRows.allSatisfy { row in
                canonicalState.0[row.messageID]?.id != row.pendingID
            })
            let eventProjection = try await afterQueue.read { db in
                try Row.fetchOne(db, sql: "SELECT thing_id FROM event_projection_heads WHERE event_id = 'event-child-id';")?["thing_id"] as String?
            }
            #expect(eventProjection == nil)
            let eventDetail = try await reopened.loadEventProjectionDetail(eventId: "event-child-id")
            #expect(eventDetail.messages.map(\.messageId) == ["thing-child-event"])
            #expect(eventDetail.messages.first?.body == "Event body")

            #expect(await reopened.drainDerivedWorkForBackgroundRefresh())
            let snapshot = try #require(NotificationContextSnapshotStore.load(appGroupIdentifier: appGroupIdentifier))
            #expect(snapshot.events["event-child-id"]?.title == event.title)
            #expect(snapshot.events["event-child-id"]?.body == event.body)
            #expect(snapshot.events["event-child-id"]?.thingId == thingID)

            LocalDataStore.releaseSharedResourcesForTesting(storageRootURL: root)
            let finalStore = LocalDataStore(appGroupIdentifier: appGroupIdentifier, spotlightIndexer: nil)
            let finalDetail = try await finalStore.loadThingProjectionDetail(thingId: thingID)
            #expect(Set(finalDetail.history.map(\.messageId)) == ["parent-\(thingID)", "thing-child-message", "thing-child-event"])
        }
    }

    @Test
    func pendingReplayKeepsOldestDuplicateAndConsumesCanonicalAndLedgerCollisions() async throws {
        try await withIsolatedAutomationStorage { _, appGroupIdentifier in
            let store = LocalDataStore(appGroupIdentifier: appGroupIdentifier, spotlightIndexer: nil)
            let sharedMessageID = "pending-cross-thing-message"
            let older = child(
                messageID: sharedMessageID, title: "Oldest wins", body: "old body",
                thingID: "thing-order-a", entityType: "message", operationID: nil,
                receivedAt: Date(timeIntervalSince1970: 1_800_100_001)
            )
            let newerSameThing = child(
                messageID: sharedMessageID, title: "Newer duplicate", body: "new body",
                thingID: "thing-order-a", entityType: "message", operationID: nil,
                receivedAt: Date(timeIntervalSince1970: 1_800_100_002)
            )
            let otherThingDuplicate = child(
                messageID: sharedMessageID, title: "Other thing duplicate", body: "other body",
                thingID: "thing-order-b", entityType: "message", operationID: nil,
                receivedAt: Date(timeIntervalSince1970: 1_800_100_003)
            )
            _ = try await store.persistNotificationMessagesIfNeeded([older, newerSameThing, otherThingDuplicate])

            let formalID = "formal-stable-id"
            let formal = PushMessage(
                messageId: formalID, title: "Formal survives", body: "formal body",
                receivedAt: Date(timeIntervalSince1970: 1_800_100_010)
            )
            try await store.saveMessage(formal)
            let collidingPending = child(
                messageID: formalID, title: "Pending must not overwrite", body: "pending body",
                thingID: "thing-formal-collision", entityType: "message", operationID: nil,
                receivedAt: Date(timeIntervalSince1970: 1_800_100_011)
            )
            _ = try await store.persistNotificationMessageIfNeeded(collidingPending)

            let formalEvent = child(
                messageID: "formal-event-stable-id", title: "Formal event survives", body: "formal event body",
                thingID: nil, entityType: "event", eventID: "formal-event", operationID: nil
            )
            try await store.saveMessage(formalEvent)
            _ = try await store.persistNotificationMessageIfNeeded(child(
                messageID: "formal-event-stable-id", title: "Pending event must not overwrite", body: "pending event body",
                thingID: "thing-formal-event-collision", entityType: "event", eventID: "formal-event", operationID: nil
            ))

            let ledgerSeed = child(
                messageID: "ledger-seed-message", title: "Ledger seed", body: "seed",
                thingID: nil, entityType: "event", eventID: "ledger-event-id", operationID: "same-operation",
                eventState: "open", receivedAt: Date(timeIntervalSince1970: 1_800_100_020)
            )
            _ = try await store.persistNotificationMessageIfNeeded(ledgerSeed)
            let ledgerPending = child(
                messageID: "ledger-pending-message", title: "Ledger blocks replay", body: "pending ledger body",
                thingID: "thing-ledger-collision", entityType: "event", eventID: "ledger-event-id",
                operationID: "same-operation", eventState: "closed",
                receivedAt: Date(timeIntervalSince1970: 1_800_100_021)
            )
            _ = try await store.persistNotificationMessageIfNeeded(ledgerPending)

            let queue = try databaseQueue(appGroupIdentifier: appGroupIdentifier)
            let coexistingRows = try await queue.read { db in
                try Row.fetchAll(db, sql: """
                    SELECT 'formal' AS domain, message_id, title, body FROM messages
                    WHERE message_id IN ('formal-stable-id', 'formal-event-stable-id')
                    UNION ALL
                    SELECT 'pending' AS domain, message_id, title, body FROM pending_inbound_messages
                    WHERE message_id IN ('formal-stable-id', 'formal-event-stable-id');
                    """).map { row in
                        "\(row["domain"] as String)|\(row["message_id"] as String)|\(row["title"] as String)|\(row["body"] as String)"
                    }
            }
            #expect(Set(coexistingRows) == [
                "formal|formal-stable-id|Formal survives|formal body",
                "pending|formal-stable-id|Pending must not overwrite|pending body",
                "formal|formal-event-stable-id|Formal event survives|formal event body",
                "pending|formal-event-stable-id|Pending event must not overwrite|pending event body",
            ])
            // The next mutation is an offline historical-state injection,
            // not a competing production writer. Join the real projections
            // first so the fixture does not race their database transaction.
            #expect(await store.drainDerivedWorkForBackgroundRefresh())
            try await queue.write { db in
                try db.execute(sql: "DELETE FROM messages WHERE message_id = 'ledger-seed-message';")
            }
            try await store.saveMessage(parentThing(thingID: "thing-order-a"))
            try await store.saveMessage(parentThing(thingID: "thing-order-b"))
            try await store.saveMessage(parentThing(thingID: "thing-formal-collision"))
            try await store.saveMessage(parentThing(thingID: "thing-ledger-collision"))
            try await store.saveMessage(parentThing(thingID: "thing-formal-event-collision"))
            let survivingEvent = try #require(try await store.loadMessage(messageId: "formal-event-stable-id"))
            #expect(survivingEvent.title == "Formal event survives")
            #expect(survivingEvent.body == "formal event body")
            #expect(survivingEvent.thingId == nil)

            let rows = try await queue.read { db in
                let children = try Row.fetchAll(
                    db,
                    sql: "SELECT message_id, title, thing_id FROM messages WHERE message_id IN (?, ?, ?, ?);",
                    arguments: [sharedMessageID, formalID, "ledger-seed-message", "ledger-pending-message"]
                ).map { row in
                    (row["message_id"] as String, row["title"] as String, row["thing_id"] as String?)
                }
                let pendingCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM pending_inbound_messages;") ?? 0
                let formalCanonicalCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM messages WHERE message_id = ?;", arguments: [formalID]) ?? 0
                let ledgerSeedCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM messages WHERE message_id = 'ledger-seed-message';") ?? 0
                let ledgerPendingCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM messages WHERE message_id = 'ledger-pending-message';") ?? 0
                let ledgerStillExists = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM operation_ledger WHERE scope_key = 'channel-x|event|ledger-event-id|same-operation';") ?? 0
                return (children, pendingCount, formalCanonicalCount, ledgerSeedCount, ledgerPendingCount, ledgerStillExists)
            }
            let ordered = try #require(rows.0.first { $0.0 == sharedMessageID })
            #expect(ordered.1 == "Oldest wins")
            #expect(ordered.2 == "thing-order-a")
            #expect(rows.0.filter { $0.0 == sharedMessageID }.count == 1)
            #expect(try await store.loadMessages().first { $0.messageId == formalID }?.title == "Formal survives")
            #expect(rows.2 == 1)
            #expect(rows.3 == 0)
            #expect(rows.4 == 0)
            #expect(rows.5 == 1)
            #expect(rows.1 == 0)
        }
    }

    @Test
    func deletingMissingThingHeadRemovesItsPendingChildrenAndLaterChildrenReplayWithoutAffectingControlThing() async throws {
        try await withIsolatedAutomationStorage { _, appGroupIdentifier in
            let store = LocalDataStore(appGroupIdentifier: appGroupIdentifier, spotlightIndexer: nil)
            let target = "thing-deleted-before-parent"
            let control = "thing-control-parent"
            try await store.saveMessage(parentThing(thingID: control))

            _ = try await store.persistNotificationMessageIfNeeded(child(
                messageID: "deleted-old-message", title: "Old message", body: "old",
                thingID: target, entityType: "message", operationID: "old-message-op"
            ))
            _ = try await store.persistNotificationMessageIfNeeded(child(
                messageID: "deleted-old-event", title: "Old event", body: "old event",
                thingID: target, entityType: "event", eventID: "deleted-old-event-id", operationID: "old-event-op"
            ))
            let controlChild = child(
                messageID: "control-event", title: "Control event", body: "control body",
                thingID: control, entityType: "event", eventID: "control-event-id", operationID: "control-op"
            )
            _ = try await store.persistNotificationMessageIfNeeded(controlChild)

            #expect(try await store.loadThingProjectionDetail(thingId: target).messages.isEmpty)
            #expect(Set(try await store.loadThingProjectionDetail(thingId: control).history.map(\.messageId)) == ["parent-\(control)", "control-event"])
            #expect(try await store.deleteThingRecords(thingId: target) == 2)

            _ = try await store.persistNotificationMessageIfNeeded(child(
                messageID: "deleted-late-message", title: "Late message", body: "late",
                thingID: target, entityType: "message", operationID: "late-message-op"
            ))
            _ = try await store.persistNotificationMessageIfNeeded(child(
                messageID: "deleted-late-event", title: "Late event", body: "late event",
                thingID: target, entityType: "event", eventID: "deleted-late-event-id", operationID: "late-event-op"
            ))
            try await store.saveMessage(parentThing(thingID: target))

            let targetHistory = try await store.loadThingProjectionDetail(thingId: target).history
            #expect(Set(targetHistory.map(\.messageId)) == ["parent-\(target)", "deleted-late-message", "deleted-late-event"])
            #expect(try await store.loadMessages().contains { $0.messageId == "deleted-old-message" } == false)
            #expect(try await store.loadMessages().contains { $0.messageId == "deleted-old-event" } == false)
            let controlHistory = try await store.loadThingProjectionDetail(thingId: control).history
            #expect(Set(controlHistory.map(\.messageId)) == ["parent-\(control)", "control-event"])
            #expect(controlHistory.first { $0.messageId == "control-event" }?.title == "Control event")
        }
    }

    @Test
    func pendingDeleteFailureRollsBackParentReplayThenRetryCommitsCompleteChildren() async throws {
        try await withIsolatedAutomationStorage { _, appGroupIdentifier in
            let store = LocalDataStore(appGroupIdentifier: appGroupIdentifier, spotlightIndexer: nil)
            let thingID = "thing-child-delete-failure"
            let message = child(
                messageID: "rollback-child-message", title: "Rollback message", body: "message body",
                thingID: thingID, entityType: "message", operationID: "rollback-message-op"
            )
            let event = child(
                messageID: "rollback-child-event", title: "Rollback event", body: "event body",
                thingID: thingID, entityType: "event", eventID: "rollback-event-id",
                operationID: "rollback-event-op", eventState: "open",
                receivedAt: Date(timeIntervalSince1970: 1_800_100_102)
            )
            _ = try await store.persistNotificationMessagesIfNeeded([message, event])

            let queue = try databaseQueue(appGroupIdentifier: appGroupIdentifier)
            let before = try await queue.read { db in
                try PendingChildSnapshot.fetch(db, thingID: thingID)
            }
            #expect(before.count == 2)
            try await queue.write { db in
                try db.execute(sql: """
                    CREATE TRIGGER reject_child_pending_delete BEFORE DELETE ON pending_inbound_messages
                    WHEN OLD.message_id = 'rollback-child-event'
                    BEGIN SELECT RAISE(ABORT, 'injected pending child delete failure'); END;
                    """)
            }
            do {
                try await store.saveMessage(parentThing(thingID: thingID))
                Issue.record("Parent and pending children committed despite the pending-delete failure")
            } catch {
                #expect(String(describing: error).contains("injected pending child delete failure"))
            }
            let rolledBack = try await queue.read { db in
                let parents = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM messages WHERE message_id = ?;", arguments: ["parent-\(thingID)"]) ?? 0
                let children = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM messages WHERE message_id IN ('rollback-child-message', 'rollback-child-event');") ?? 0
                let ledgers = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM operation_ledger WHERE message_id IN ('rollback-child-message', 'rollback-child-event');") ?? 0
                let derived = try Int.fetchOne(
                    db,
                    sql: """
                        SELECT COUNT(*) FROM canonical_derived_work w
                        JOIN messages m ON m.id = w.local_message_id
                        WHERE m.message_id IN ('rollback-child-message', 'rollback-child-event');
                        """
                ) ?? 0
                let pending = try PendingChildSnapshot.fetch(db, thingID: thingID)
                return (parents, children, ledgers, derived, pending)
            }
            #expect(rolledBack.0 == 0)
            #expect(rolledBack.1 == 0)
            #expect(rolledBack.2 == 0)
            #expect(rolledBack.3 == 0)
            #expect(rolledBack.4 == before)
            #expect(NotificationContextSnapshotStore.load(appGroupIdentifier: appGroupIdentifier)?.events["rollback-event-id"] == nil)
            try await queue.write { db in try db.execute(sql: "DROP TRIGGER reject_child_pending_delete;") }

            try await store.saveMessage(parentThing(thingID: thingID))
            let detail = try await store.loadThingProjectionDetail(thingId: thingID)
            #expect(Set(detail.history.map(\.messageId)) == ["parent-\(thingID)", "rollback-child-message", "rollback-child-event"])
            #expect(try await queue.read { db in try PendingChildSnapshot.fetch(db, thingID: thingID).isEmpty })
            #expect(try await queue.read { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM operation_ledger WHERE message_id IN ('rollback-child-message', 'rollback-child-event');") ?? 0
            } == 2)
            #expect(try await queue.read { db in
                try Int.fetchOne(db, sql: """
                    SELECT COUNT(*) FROM canonical_derived_work w
                    JOIN messages m ON m.id = w.local_message_id
                    WHERE m.message_id IN ('rollback-child-message', 'rollback-child-event');
                    """) ?? 0
            } == 6)
            #expect(await store.drainDerivedWorkForBackgroundRefresh())
            let snapshot = try #require(NotificationContextSnapshotStore.load(appGroupIdentifier: appGroupIdentifier))
            #expect(snapshot.events["rollback-event-id"]?.title == event.title)
            #expect(snapshot.events["rollback-event-id"]?.body == event.body)
            #expect(snapshot.events["rollback-event-id"]?.thingId == thingID)
        }
    }

    @Test
    func pendingReplayActivatesThreePagesInTheOriginalOrderAfterReopen() async throws {
        try await withIsolatedAutomationStorage { root, group in
            let thingID = "thing-three-page-replay"
            let store = LocalDataStore(appGroupIdentifier: group, spotlightIndexer: nil)
            let children = multiPageChildren(thingID: thingID)
            let outcomes = try await store.persistNotificationMessagesIfNeeded(children)
            #expect(outcomes.count == 137)
            #expect(outcomes.allSatisfy { if case .persistedPending = $0 { return true }; return false })
            let queue = try databaseQueue(appGroupIdentifier: group)
            let pending = try await queue.read { db in try PendingChildSnapshot.fetch(db, thingID: thingID) }
            #expect(pending.count == 137)
            #expect(try await store.loadMessages().isEmpty)

            LocalDataStore.releaseSharedResourcesForTesting(storageRootURL: root)
            let reopened = LocalDataStore(appGroupIdentifier: group, spotlightIndexer: nil)
            try await reopened.saveMessage(parentThing(thingID: thingID))
            let committed = try await databaseQueue(appGroupIdentifier: group).read { db in
                // rowid observes actual insertion order only in this test. It
                // is not a new business ordering key or a persisted cursor.
                let inserted = try String.fetchAll(db, sql: "SELECT message_id FROM messages WHERE thing_id = ? AND entity_type IN ('message', 'event') ORDER BY rowid;", arguments: [thingID])
                let remaining = try Int.fetchOne(db, sql: "SELECT count(*) FROM pending_inbound_messages WHERE thing_id = ?;", arguments: [thingID]) ?? 0
                return (inserted, remaining)
            }
            #expect(committed.0 == pending.map(\.messageID))
            #expect(Set(committed.0).count == 137)
            #expect(committed.1 == 0)
            for expected in children {
                let actual = try #require(try await reopened.loadMessage(messageId: expected.messageId!))
                #expect(actual.body == expected.body)
                #expect(actual.thingId == thingID)
                #expect(actual.isRead == false)
            }
        }
    }

    @Test
    func pendingReplayFailureOnSecondPageRollsBackAllThreePagesAndCanRetry() async throws {
        try await withIsolatedAutomationStorage { _, group in
            let thingID = "thing-three-page-rollback"
            let store = LocalDataStore(appGroupIdentifier: group, spotlightIndexer: nil)
            let children = multiPageChildren(thingID: thingID)
            _ = try await store.persistNotificationMessagesIfNeeded(children)
            #expect(await store.drainDerivedWorkForBackgroundRefresh())
            let queue = try databaseQueue(appGroupIdentifier: group)
            let before = try await queue.read { db in try PendingChildSnapshot.fetch(db, thingID: thingID) }
            try #require(before.count == 137)
            let failedPendingID = before[70].pendingID
            try await queue.write { db in
                try db.execute(sql: """
                    CREATE TRIGGER reject_second_replay_page BEFORE DELETE ON pending_inbound_messages
                    WHEN OLD.pending_id = '\(failedPendingID)'
                    BEGIN SELECT RAISE(ABORT, 'synthetic second-page pending delete failure'); END;
                    """)
            }
            do {
                try await store.saveMessage(parentThing(thingID: thingID))
                Issue.record("A later-page failure must roll back the parent and all earlier replay pages.")
            } catch {
                #expect(String(describing: error).contains("synthetic second-page pending delete failure"))
            }
            let rolledBack = try await queue.read { db in
                let canonical = try Int.fetchOne(db, sql: "SELECT count(*) FROM messages;") ?? 0
                let ledgers = try Int.fetchOne(db, sql: "SELECT count(*) FROM operation_ledger;") ?? 0
                let derived = try Int.fetchOne(db, sql: "SELECT count(*) FROM canonical_derived_work;") ?? 0
                return (canonical, ledgers, derived, try PendingChildSnapshot.fetch(db, thingID: thingID))
            }
            #expect(rolledBack.0 == 0)
            #expect(rolledBack.1 == 0)
            #expect(rolledBack.2 == 0)
            #expect(rolledBack.3 == before)
            try await queue.write { db in try db.execute(sql: "DROP TRIGGER reject_second_replay_page;") }
            try await store.saveMessage(parentThing(thingID: thingID))
            #expect(try await queue.read { db in try PendingChildSnapshot.fetch(db, thingID: thingID).isEmpty })
            let ids = try await queue.read { db in
                try String.fetchAll(db, sql: "SELECT message_id FROM messages WHERE thing_id = ? AND entity_type IN ('message', 'event') ORDER BY rowid;", arguments: [thingID])
            }
            #expect(ids == before.map(\.messageID))
            #expect(Set(ids).count == 137)
            #expect(try await queue.read { db in
                try Int.fetchOne(db, sql: "SELECT count(*) FROM messages WHERE thing_id = ?;", arguments: [thingID]) ?? 0
            } == 138)
        }
    }

    private func multiPageChildren(thingID: String) -> [PushMessage] {
        // Reverse admission order and tie each timestamp dimension in groups;
        // the production pending ordering, including pending_id ties, decides
        // activation. The fixture's 137 rows cross two LIMIT-64 boundaries.
        Array((0..<137).reversed()).map { index in
            let identifier = "\(thingID)-child-\(index)"
            let isEvent = index.isMultiple(of: 2)
            var message = child(messageID: identifier, title: "Child \(index)", body: "Exact pending body \(index)",
                thingID: thingID, entityType: isEvent ? "event" : "message",
                eventID: isEvent ? "event-\(identifier)" : nil, operationID: "operation-\(identifier)",
                eventState: isEvent ? "open" : nil,
                receivedAt: Date(timeIntervalSince1970: 1_800_100_101 + Double(index / 2)))
            message.rawPayload["occurred_at"] = AnyCodable(1_800_100_101 + index / 16)
            message.rawPayload["event_time"] = AnyCodable(1_800_100_101 + index / 4)
            message.rawPayload["observed_at"] = AnyCodable(1_800_100_101 + index / 2)
            return message
        }
    }

    private struct PendingChildSnapshot: Equatable {
        let pendingID: String
        let thingID: String
        let messageID: String
        let title: String
        let body: String
        let rawPayloadJSON: String
        let entityType: String
        let channel: String?
        let url: String?
        let receivedAt: Double
        let status: String
        let decryptionState: String?
        let notificationRequestID: String?
        let deliveryID: String?
        let operationID: String?
        let entityID: String?
        let eventID: String?
        let eventState: String?
        let eventTime: Int64?
        let observedTime: Int64?
        let occurredAt: Int64?

        static func fetch(_ db: Database, thingID: String) throws -> [PendingChildSnapshot] {
            try Row.fetchAll(
                db,
                sql: "SELECT * FROM pending_inbound_messages WHERE thing_id = ? ORDER BY occurred_at_epoch ASC, event_time_epoch ASC, observed_time_epoch ASC, received_at ASC, pending_id ASC;",
                arguments: [thingID]
            ).map { row in
                PendingChildSnapshot(
                    pendingID: row["pending_id"], thingID: row["thing_id"],
                    messageID: row["message_id"], title: row["title"], body: row["body"],
                    rawPayloadJSON: row["raw_payload_json"], entityType: row["entity_type"],
                    channel: row["channel"], url: row["url"], receivedAt: row["received_at"],
                    status: row["status"], decryptionState: row["decryption_state"],
                    notificationRequestID: row["notification_request_id"], deliveryID: row["delivery_id"],
                    operationID: row["operation_id"], entityID: row["entity_id"], eventID: row["event_id"],
                    eventState: row["event_state"], eventTime: row["event_time_epoch"],
                    observedTime: row["observed_time_epoch"], occurredAt: row["occurred_at_epoch"]
                )
            }
        }
    }

    private struct CanonicalChildSnapshot {
        let rawPayloadJSON: String
        let id: String
        let isRead: Int64
        let isTopLevel: Int64
        let title: String
        let body: String
        let channel: String?
        let url: String?
        let receivedAt: Double
        let status: String
        let decryptionState: String?
        let notificationRequestID: String?
        let deliveryID: String?
        let operationID: String?
        let entityType: String
        let entityID: String?
        let eventID: String?
        let thingID: String?
        let projectionDestination: String?
        let eventState: String?
        let eventTime: Int64?
        let observedTime: Int64?
        let occurredAt: Int64?
    }

    private func databaseQueue(appGroupIdentifier: String) throws -> DatabaseQueue {
        let databaseURL = try AppConstants.appLocalDatabaseDirectory(
            fileManager: .default,
            appGroupIdentifier: appGroupIdentifier
        ).appendingPathComponent(AppConstants.databaseStoreFilename)
        return try DatabaseQueue(path: databaseURL.path)
    }

    private func parentThing(thingID: String) -> PushMessage {
        PushMessage(
            messageId: "parent-\(thingID)", title: "Parent \(thingID)", body: "Thing parent",
            channel: "channel-x", receivedAt: Date(timeIntervalSince1970: 1_800_100_100),
            rawPayload: [
                "entity_type": AnyCodable("thing"), "entity_id": AnyCodable(thingID),
                "thing_id": AnyCodable(thingID), "metadata": AnyCodable(["role": "parent"]),
            ]
        )
    }

    private func child(
        messageID: String,
        title: String,
        body: String,
        thingID: String?,
        entityType: String,
        eventID: String? = nil,
        operationID: String?,
        eventState: String? = nil,
        receivedAt: Date = Date(timeIntervalSince1970: 1_800_100_101)
    ) -> PushMessage {
        var payload: [String: AnyCodable] = [
            "entity_type": AnyCodable(entityType),
            "entity_id": AnyCodable(eventID ?? messageID),
            "metadata": AnyCodable(["owner": "test", "purpose": "thing-child-lifecycle"]),
            "tags": AnyCodable(["child", "lifecycle"]),
            "severity": AnyCodable("high"),
            "_notificationRequestId": AnyCodable("request-\(messageID)"),
            "delivery_id": AnyCodable("delivery-\(messageID)"),
            "event_time": AnyCodable(receivedAt.timeIntervalSince1970),
            "observed_at": AnyCodable(receivedAt.timeIntervalSince1970 + 0.25),
            "occurred_at": AnyCodable(receivedAt.timeIntervalSince1970 + 0.5),
        ]
        if let thingID { payload["thing_id"] = AnyCodable(thingID) }
        if let eventID { payload["event_id"] = AnyCodable(eventID) }
        if let operationID { payload["op_id"] = AnyCodable(operationID) }
        if let eventState { payload["event_state"] = AnyCodable(eventState) }
        return PushMessage(
            id: UUID(), messageId: messageID, title: title, body: body,
            channel: "channel-x", url: URL(string: "https://example.test/\(messageID)"),
            isRead: true, receivedAt: receivedAt, rawPayload: payload,
            status: .partiallyDecrypted, decryptionState: .decryptFailed
        )
    }
}
