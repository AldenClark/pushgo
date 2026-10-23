// Executed with the unmodified WatchLocalSQLiteStore declaration and production
// Watch models by scripts/run_watch_sqlite_lifecycle_tests.py. The host adapters
// change only the sandbox directory and Darwin notification side effect.

private enum LifecycleFailure: Error, CustomStringConvertible {
    case assertion(String)
    var description: String {
        switch self { case let .assertion(message): return message }
    }
}

private func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    guard try condition() else { throw LifecycleFailure.assertion(message) }
}

private func delivery(
    _ deliveryID: String,
    messageID: String,
    gateway: String = "https://gateway.example/root",
    title: String = "Original title",
    body: String = "Original body",
    ack: WatchServerAckState = .pending
) -> WatchDeliveryIngestRecord {
    WatchDeliveryIngestRecord(
        payload: .message(WatchLightMessage(
            messageId: messageID, title: title, body: body,
            imageURL: nil, url: nil, severity: "normal",
            receivedAt: Date(timeIntervalSince1970: 1_800_000_000),
            isRead: false, entityType: "message", entityId: messageID,
            notificationRequestId: deliveryID
        )),
        metadata: WatchDeliveryMetadata(
            deliveryId: deliveryID, gatewayKey: gateway,
            watchDeviceKey: "synthetic-device", ingressSource: ack == .ackedDirect ? .watchPull : .watchAPNS,
            contentDigest: "synthetic-content", serverAckState: ack,
            persistedAt: Date(timeIntervalSince1970: 1_800_000_001)
        )
    )
}

private func runLifecycleTests() throws {
    // Normal duplicate enrichment remains supported while its content exists.
    do {
        let store = try WatchLocalSQLiteStore(appGroupIdentifier: "normal-duplicate")
        let first = try store.ingestWatchDelivery(delivery("delivery-1", messageID: "message-1"))
        let replay = try store.ingestWatchDelivery(delivery(
            "delivery-1", messageID: "incoming-alias", title: "Pull title", body: "Pull body", ack: .ackedDirect
        ))
        try require(first.disposition == .inserted, "first delivery must persist")
        try require(replay.disposition == .duplicateDelivery, "normal duplicate must stay a duplicate")
        try require(try store.loadWatchLightMessage(messageId: "message-1")?.body == "Pull body", "extant projection must retain normal Direct/Pull enrichment")
        try require(try store.loadWatchLightMessage(messageId: "incoming-alias") == nil, "duplicate may not allocate a second message")
        try require(replay.deliveryRecord.serverAckState == .ackedDirect, "duplicate ACK metadata must still converge")
        print("PASS normal_duplicate_enrichment")
    }

    // Confirmed deletion keeps the delivery fact. A late Direct/Pull replay is
    // still accepted as already processed without recreating visible content.
    do {
        let store = try WatchLocalSQLiteStore(appGroupIdentifier: "deleted-replay")
        _ = try store.ingestWatchDelivery(delivery("deleted-delivery", messageID: "deleted-message"))
        let target = try store.loadWatchLightMessage(messageId: "deleted-message")!
        try require(try store.deleteWatchLightMessage(matching: target, config: nil, localConfig: nil), "confirmed delete must commit")
        try require(try store.loadWatchDeliveryRecords().count == 1, "deleting content may not delete the processed fact")
        let replay = try store.ingestWatchDelivery(delivery("deleted-delivery", messageID: "late-alias", ack: .ackedDirect))
        try require(replay.disposition == .duplicateDelivery, "deleted replay is ACK-safe duplicate, not a new delivery")
        try require(replay.deliveryRecord.messageId == "deleted-message", "deleted replay keeps its original durable identity")
        try require(replay.deliveryRecord.serverAckState == .ackedDirect, "deleted replay still updates ACK metadata")
        try require(try store.loadWatchLightMessages().isEmpty, "same delivery resurrected confirmed-deleted content")
        print("PASS delete_then_replay")
    }

    // The previous scope has closed its real SQLite connection. Reopening the
    // same database must retain the deletion result and the processed identity.
    do {
        let reopened = try WatchLocalSQLiteStore(appGroupIdentifier: "deleted-replay")
        try require(try reopened.loadWatchLightMessages().isEmpty, "deleted projection must remain absent after reopen")
        let replay = try reopened.ingestWatchDelivery(delivery("deleted-delivery", messageID: "restart-alias", ack: .ackedDirect))
        try require(replay.disposition == .duplicateDelivery, "reopened delivery fact must still identify replay")
        try require(try reopened.loadWatchLightMessages().isEmpty, "restart replay resurrected confirmed-deleted content")
        print("PASS restart_then_replay")

        // Equal content is not a tombstone identity. A genuinely new message
        // and delivery retain normal receive behavior after earlier deletion.
        let newDelivery = try reopened.ingestWatchDelivery(delivery("new-delivery", messageID: "new-message"))
        try require(newDelivery.disposition == .inserted, "new delivery must not be suppressed by equal content")
        try require(try reopened.loadWatchLightMessage(messageId: "new-message")?.body == "Original body", "new delivery must retain normal receive behavior")
        try require(try reopened.loadWatchLightMessage(messageId: "deleted-message") == nil, "new equal-content delivery may not recreate the old deleted identity")
        print("PASS new_delivery_same_content")

        // Dedupe uses the actual persisted Gateway+delivery primary key, not a
        // global delivery ID. Canonical message IDs remain source-owned.
        let otherGateway = try reopened.ingestWatchDelivery(delivery(
            "deleted-delivery", messageID: "other-gateway-message", gateway: "https://gateway.example/other"
        ))
        try require(otherGateway.disposition == .inserted, "different Gateway must have a distinct delivery scope")
        try require(try reopened.loadWatchLightMessage(messageId: "other-gateway-message") != nil, "other Gateway content must persist")
        try require(try reopened.loadWatchDeliveryRecords().count == 3, "distinct delivery scopes must all retain their own facts")
        print("PASS gateway_scope_isolation")
    }

    // A stale confirmation must neither delete replacement content nor create
    // a terminal state that blocks an otherwise normal duplicate update.
    do {
        let store = try WatchLocalSQLiteStore(appGroupIdentifier: "stale-confirmation")
        _ = try store.ingestWatchDelivery(delivery("stale-delivery", messageID: "stale-message"))
        let stale = try store.loadWatchLightMessage(messageId: "stale-message")!
        _ = try store.ingestWatchDelivery(delivery("stale-delivery", messageID: "stale-message", body: "Replacement"))
        try require(try !store.deleteWatchLightMessage(matching: stale, config: nil, localConfig: nil), "stale confirmation must not delete changed content")
        try require(try store.loadWatchLightMessage(messageId: "stale-message")?.body == "Replacement", "failed confirmation may not suppress normal duplicate behavior")
        print("PASS stale_confirmation_preserves_content")
    }
}

@main
private enum WatchSQLiteLifecycleTests {
    static func main() {
        do {
            try runLifecycleTests()
            print("RESULT passed=6 failed=0 layer=host_production_watch_sqlite")
        } catch {
            FileHandle.standardError.write(Data("FAIL \(error)\n".utf8))
            exit(1)
        }
    }
}
