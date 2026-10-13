import Foundation
import GRDB
import Testing
@testable import PushGoAppleCore

struct ThingChildCapacityTests {
    @Test
    func pageQuotaRollsBackParentAndBothChildReplayDomainsThenRestoresAccurately() async throws {
        try await withIsolatedAutomationStorage { root, appGroupIdentifier in
            let store = LocalDataStore(appGroupIdentifier: appGroupIdentifier, spotlightIndexer: nil)
            let formal = PushMessage(
                messageId: "capacity-formal-message", title: "Formal sentinel", body: "Keep this formal row intact.",
                channel: "formal-channel", isRead: true,
                rawPayload: [
                    "entity_type": AnyCodable("message"), "entity_id": AnyCodable("formal-entity"),
                    "op_id": AnyCodable("formal-operation"), "delivery_id": AnyCodable("formal-delivery"),
                ]
            )
            _ = try await store.persistNotificationMessageIfNeeded(formal)

            let database = try databaseQueue(appGroupIdentifier: appGroupIdentifier)
            let initialMetrics = try await store.qualitySQLitePageMetrics()
            guard initialMetrics.pageCount > 0, initialMetrics.pageSize > 0,
                  initialMetrics.maxPageCount >= initialMetrics.pageCount
            else {
                Issue.record("SQLite page metrics were not usable for a bounded replay failure.")
                return
            }
            let (baseBytes, baseOverflow) = initialMetrics.pageCount
                .multipliedReportingOverflow(by: initialMetrics.pageSize)
            let (bodyBytes, bodyOverflow) = baseBytes.multipliedReportingOverflow(by: 3)
            guard !baseOverflow, !bodyOverflow, bodyBytes > 0, bodyBytes <= 64 * 1024 * 1024
            else {
                Issue.record("SQLite page size put the replay payload outside the bounded test budget.")
                return
            }

            let thingID = "capacity-thing"
            let messageChild = child(
                messageID: "capacity-child-message", title: "Message child", body: "Small child body.",
                thingID: thingID, entityType: "message", operationID: "child-message-operation",
                receivedAt: Date(timeIntervalSince1970: 1_800_100_101)
            )
            let eventChild = child(
                messageID: "capacity-child-event", title: "Event child", body: String(repeating: "e", count: bodyBytes),
                thingID: thingID, entityType: "event", eventID: "capacity-event-id",
                operationID: "child-event-operation", eventState: "open",
                receivedAt: Date(timeIntervalSince1970: 1_800_100_102)
            )
            _ = try await store.persistNotificationMessagesIfNeeded([messageChild, eventChild])

            let before = try await snapshot(
                db: database,
                formalMessageID: formal.messageId!,
                childMessageIDs: ["capacity-child-message", "capacity-child-event"],
                thingID: thingID
            )
            #expect(before.pending.count == 2)
            #expect(before.formal.row.contains("Formal sentinel"))
            #expect(before.formal.ledger.count == 1)
            #expect(before.formal.derived.count == 3)
            #expect(before.children.isEmpty)
            #expect(before.pending.map(\.messageID) == ["capacity-child-message", "capacity-child-event"])
            #expect(before.pending.allSatisfy { $0.thingID == thingID })
            #expect(before.pending[0].body == messageChild.body)
            #expect(before.pending[1].body == eventChild.body)

            let replayMetrics = try await store.qualitySQLitePageMetrics()
            let constrained = try await store.setQualitySQLiteMaxPageCount(replayMetrics.pageCount)
            #expect(constrained.maxPageCount == replayMetrics.pageCount)
            #expect(constrained.pageSize == replayMetrics.pageSize)

            var replayError: (any Error)?
            do {
                try await store.saveMessage(parentThing(thingID: thingID))
                Issue.record("The Thing parent and its large child replay unexpectedly fit the constrained SQLite quota.")
            } catch {
                replayError = error
            }
            let restoredQuota = try await store.setQualitySQLiteMaxPageCount(replayMetrics.maxPageCount)
            #expect(restoredQuota.maxPageCount == replayMetrics.maxPageCount)
            guard let replayError else { return }
            #expect(String(describing: replayError).localizedCaseInsensitiveContains("full"))

            let afterFailure = try await snapshot(
                db: database,
                formalMessageID: formal.messageId!,
                childMessageIDs: ["capacity-child-message", "capacity-child-event"],
                thingID: thingID
            )
            #expect(afterFailure.formal == before.formal)
            #expect(afterFailure.pending == before.pending)
            #expect(afterFailure.children.isEmpty)
            #expect(afterFailure.ledger == before.ledger)
            #expect(afterFailure.derived == before.derived)
            #expect(afterFailure.parentCount == 0)

            try await store.saveMessage(parentThing(thingID: thingID))
            let detail = try await store.loadThingProjectionDetail(thingId: thingID)
            #expect(detail.head?.messageId == "parent-\(thingID)")
            let restoredChildren = detail.history.filter {
                ["capacity-child-message", "capacity-child-event"].contains($0.messageId ?? "")
            }
            #expect(Set(restoredChildren.map(\.messageId)) == ["capacity-child-message", "capacity-child-event"])
            #expect(restoredChildren.first { $0.messageId == "capacity-child-message" }?.body == messageChild.body)
            #expect(restoredChildren.first { $0.messageId == "capacity-child-message" }?.isRead == false)
            #expect(restoredChildren.first { $0.messageId == "capacity-child-event" }?.body == eventChild.body)
            #expect(restoredChildren.first { $0.messageId == "capacity-child-event" }?.isRead == false)
            let committed = try await snapshot(
                db: database,
                formalMessageID: formal.messageId!,
                childMessageIDs: ["capacity-child-message", "capacity-child-event"],
                thingID: thingID
            )
            #expect(committed.pending.isEmpty)
            #expect(committed.formal == before.formal)
            #expect(committed.children.count == 2)
            #expect(committed.ledger.count == 2)
            #expect(committed.derived.count == 6)
            #expect(committed.parentCount == 1)

            LocalDataStore.releaseSharedResourcesForTesting(storageRootURL: root)
            let reopened = LocalDataStore(appGroupIdentifier: appGroupIdentifier, spotlightIndexer: nil)
            let restoredDetail = try await reopened.loadThingProjectionDetail(thingId: thingID)
            #expect(restoredDetail.head?.messageId == "parent-\(thingID)")
            let reopenedChildren = restoredDetail.history.filter {
                ["capacity-child-message", "capacity-child-event"].contains($0.messageId ?? "")
            }
            #expect(Set(reopenedChildren.map(\.messageId)) == ["capacity-child-message", "capacity-child-event"])
            #expect(reopenedChildren.first { $0.messageId == "capacity-child-message" }?.body == messageChild.body)
            #expect(reopenedChildren.first { $0.messageId == "capacity-child-event" }?.body == eventChild.body)
            #expect(try await reopened.loadMessage(messageId: formal.messageId!)?.body == formal.body)
        }
    }

    private struct PendingSnapshot: Equatable {
        let pendingID: String
        let thingID: String
        let messageID: String
        let title: String
        let body: String
        let rawPayloadJSON: String
        let fields: String
    }

    private struct StateSnapshot: Equatable {
        let row: String
        let ledger: [String]
        let derived: [String]
    }

    private func snapshot(
        db: DatabaseQueue,
        formalMessageID: String,
        childMessageIDs: [String],
        thingID: String
    ) async throws -> (formal: StateSnapshot, children: [String], pending: [PendingSnapshot], ledger: [String], derived: [String], parentCount: Int) {
        try await db.read { connection in
            let formalRow = try Row.fetchOne(
                connection,
                sql: "SELECT * FROM messages WHERE message_id = ?;",
                arguments: [formalMessageID]
            )
            let formal: StateSnapshot
            if let formalRow {
                let id: String = formalRow["id"]
                formal = StateSnapshot(
                    row: formalRow.description,
                    ledger: try Row.fetchAll(
                        connection,
                        sql: "SELECT * FROM operation_ledger WHERE message_id = ? ORDER BY scope_key;",
                        arguments: [formalMessageID]
                    ).map(\.description),
                    derived: try Row.fetchAll(
                        connection,
                        sql: "SELECT * FROM canonical_derived_work WHERE local_message_id = ? ORDER BY kind;",
                        arguments: [id]
                    ).map(\.description)
                )
            } else {
                formal = StateSnapshot(row: "<missing>", ledger: [], derived: [])
            }
            let children = try Row.fetchAll(
                connection,
                sql: "SELECT message_id FROM messages WHERE message_id IN (?, ?) ORDER BY message_id;",
                arguments: StatementArguments(childMessageIDs)
            ).compactMap { row -> String? in row["message_id"] }
            let childIDs = try Row.fetchAll(
                connection,
                sql: "SELECT id FROM messages WHERE message_id IN (?, ?) ORDER BY message_id;",
                arguments: StatementArguments(childMessageIDs)
            ).compactMap { row -> String? in row["id"] }
            let childLedger = try Row.fetchAll(
                connection,
                sql: "SELECT * FROM operation_ledger WHERE message_id IN (?, ?) ORDER BY scope_key;",
                arguments: StatementArguments(childMessageIDs)
            ).map(\.description)
            let childDerived: [String]
            if childIDs.isEmpty {
                childDerived = []
            } else {
                let localIDs = childIDs.map { "'\($0)'" }.joined(separator: ",")
                childDerived = try Row.fetchAll(
                    connection,
                    sql: "SELECT * FROM canonical_derived_work WHERE local_message_id IN (\(localIDs)) ORDER BY work_id;"
                ).map(\.description)
            }
            let pending = try Row.fetchAll(
                connection,
                sql: "SELECT * FROM pending_inbound_messages WHERE thing_id = ? ORDER BY occurred_at_epoch ASC, event_time_epoch ASC, observed_time_epoch ASC, received_at ASC, pending_id ASC;",
                arguments: [thingID]
            ).map { row in
                PendingSnapshot(
                    pendingID: row["pending_id"], thingID: row["thing_id"],
                    messageID: row["message_id"], title: row["title"], body: row["body"],
                    rawPayloadJSON: row["raw_payload_json"], fields: row.description
                )
            }
            let parentCount = try Int.fetchOne(
                connection,
                sql: "SELECT COUNT(*) FROM messages WHERE message_id = ?;",
                arguments: ["parent-\(thingID)"]
            ) ?? 0
            return (formal, children, pending, childLedger, childDerived, parentCount)
        }
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
            channel: "thing-channel", receivedAt: Date(timeIntervalSince1970: 1_800_100_100),
            rawPayload: [
                "entity_type": AnyCodable("thing"), "entity_id": AnyCodable(thingID),
                "thing_id": AnyCodable(thingID),
            ]
        )
    }

    private func child(
        messageID: String,
        title: String,
        body: String,
        thingID: String,
        entityType: String,
        eventID: String? = nil,
        operationID: String,
        eventState: String? = nil,
        receivedAt: Date
    ) -> PushMessage {
        var payload: [String: AnyCodable] = [
            "entity_type": AnyCodable(entityType),
            "entity_id": AnyCodable(eventID ?? messageID),
            "thing_id": AnyCodable(thingID),
            "op_id": AnyCodable(operationID),
            "delivery_id": AnyCodable("delivery-\(messageID)"),
            "_notificationRequestId": AnyCodable("request-\(messageID)"),
            "metadata": AnyCodable(["purpose": "thing-child-capacity"]),
            "event_time": AnyCodable(receivedAt.timeIntervalSince1970),
            "observed_at": AnyCodable(receivedAt.timeIntervalSince1970 + 0.25),
            "occurred_at": AnyCodable(receivedAt.timeIntervalSince1970 + 0.5),
        ]
        if let eventID { payload["event_id"] = AnyCodable(eventID) }
        if let eventState { payload["event_state"] = AnyCodable(eventState) }
        return PushMessage(
            messageId: messageID, title: title, body: body, channel: "thing-channel",
            isRead: true, receivedAt: receivedAt, rawPayload: payload
        )
    }
}
