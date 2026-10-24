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
#if WATCH_FROZEN_PULL_METADATA_TESTS
    // The Pull adapter must use the response's frozen origin, not a current
    // configuration/device or a payload's legacy Gateway alias.
    do {
        let store = try WatchLocalSQLiteStore(appGroupIdentifier: "frozen-pull-origin")
        let origin: [String: String] = [
            "base_url": "https://OLD-GATEWAY.example/Prefix/",
            "provider_device_key": " original-watch ",
            "gateway_key": "https://new-gateway.example/Other",
        ]
        guard let metadata = WatchDeliveryMetadata.pulled(deliveryId: " frozen-delivery ", payload: origin, now: Date(timeIntervalSince1970: 2_000)) else {
            throw LifecycleFailure.assertion("a real frozen Pull origin must be accepted")
        }
        try require(metadata.gatewayKey == "https://old-gateway.example/Prefix", "Pull must retain normalized request Gateway and path case")
        try require(metadata.watchDeviceKey == "original-watch", "Pull must retain its request device")
        try require(metadata.deliveryId == "frozen-delivery", "existing identity normalization must remain")
        try require(metadata.persistedAt == Date(timeIntervalSince1970: 2_000), "local fact time must be explicit, not from current config")
        let payload = delivery("frozen-delivery", messageID: "frozen-message").payload
        let first = try store.ingestWatchDelivery(WatchDeliveryIngestRecord(payload: payload, metadata: metadata))
        try require(first.disposition == .inserted, "new frozen-origin content must persist")
#if WATCH_DELIVERY_LOOKUP_TESTS
        try require(try store.hasWatchDeliveryRecord(gatewayKey: "https://old-gateway.example/Prefix", deliveryId: "frozen-delivery"), "lookup must find the frozen source")
        try require(try !store.hasWatchDeliveryRecord(gatewayKey: "https://new-gateway.example/Other", deliveryId: "frozen-delivery"), "current/legacy alias cannot acquire old delivery")
#endif
        let message = try store.loadWatchLightMessage(messageId: "frozen-message")!
        try require(try store.deleteWatchLightMessage(matching: message, config: nil, localConfig: nil), "confirmed deletion must commit")
        let replayMetadata = WatchDeliveryMetadata.pulled(deliveryId: "frozen-delivery", payload: origin, now: Date(timeIntervalSince1970: 3_000))!
        let replay = try store.ingestWatchDelivery(WatchDeliveryIngestRecord(payload: payload, metadata: replayMetadata))
        try require(replay.disposition == .duplicateDelivery, "the same frozen source must remain an ACK-safe processed fact")
        try require(replay.deliveryRecord.persistedAt == Date(timeIntervalSince1970: 2_000), "replay must not renew first fact time")
        try require(try store.loadWatchLightMessage(messageId: "frozen-message") == nil, "frozen-source replay may not resurrect deleted content")
        try require(WatchDeliveryMetadata.pulled(deliveryId: "frozen-delivery", payload: ["gateway_key": "https://old-gateway.example/Prefix", "provider_device_key": "original-watch"]) == nil, "legacy alias is not proof of a Pull's source")
        try require(WatchDeliveryMetadata.pulled(deliveryId: "frozen-delivery", payload: ["base_url": "https://old-gateway.example/Prefix"]) == nil, "missing device may not be borrowed from current configuration")
        try require(WatchDeliveryMetadata.pulled(deliveryId: "frozen-delivery", payload: ["base_url": "file:///tmp/not-a-gateway", "provider_device_key": "original-watch"]) == nil, "invalid Gateway source must fail closed")
        print("PASS frozen_pull_origin_metadata_and_deleted_replay")
    }
#endif
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
#if WATCH_DELIVERY_LOOKUP_TESTS
        try require(try store.hasWatchDeliveryRecord(gatewayKey: "https://gateway.example/root", deliveryId: "delivery-1"), "persisted delivery lookup must find the exact source")
        try require(try !store.hasWatchDeliveryRecord(gatewayKey: "https://gateway.example/other", deliveryId: "delivery-1"), "delivery lookup may not claim another Gateway's identity")
        try require(try !store.hasWatchDeliveryRecord(gatewayKey: "https://gateway.example/root", deliveryId: "missing"), "delivery lookup must not invent an absent fact")
#endif
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
#if WATCH_DELIVERY_LOOKUP_TESTS
        try require(try store.hasWatchDeliveryRecord(gatewayKey: "https://gateway.example/root", deliveryId: "deleted-delivery"), "the bounded lookup must retain the fact after content deletion")
#endif
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
#if WATCH_DELIVERY_LOOKUP_TESTS
        try require(try reopened.hasWatchDeliveryRecord(gatewayKey: "https://gateway.example/root", deliveryId: "deleted-delivery"), "the bounded lookup must recover persisted facts after reopen")
#endif
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

    // The lightweight table's canonical key is message_id. After A's content
    // is deleted, B may legitimately fill that empty key. A's retained fact
    // must not become authority to update B's newly visible projection.
    do {
        let store = try WatchLocalSQLiteStore(appGroupIdentifier: "reused-message-id")
        _ = try store.ingestWatchDelivery(delivery("delivery-a", messageID: "shared-message-id"))
        let target = try store.loadWatchLightMessage(messageId: "shared-message-id")!
        try require(try store.deleteWatchLightMessage(matching: target, config: nil, localConfig: nil), "A's confirmed content deletion must commit")
        let foreign = try store.ingestWatchDelivery(delivery(
            "delivery-b", messageID: "shared-message-id", gateway: "https://gateway.example/other",
            title: "B title", body: "B body"
        ))
        try require(foreign.disposition == .inserted, "B's distinct Gateway+delivery must be accepted")
        let oldReplay = try store.ingestWatchDelivery(delivery(
            "delivery-a", messageID: "shared-message-id", title: "Late A title", body: "Late A body", ack: .ackedDirect
        ))
        try require(oldReplay.disposition == .duplicateDelivery, "A remains ACK-safe duplicate after B takes the empty canonical key")
        try require(oldReplay.deliveryRecord.serverAckState == .ackedDirect, "A's delivery ACK metadata must still converge")
        try require(try store.loadWatchLightMessage(messageId: "shared-message-id")?.body == "B body", "A's old duplicate overwrote B's distinct Gateway content")
    }
    do {
        let reopened = try WatchLocalSQLiteStore(appGroupIdentifier: "reused-message-id")
        _ = try reopened.ingestWatchDelivery(delivery(
            "delivery-a", messageID: "shared-message-id", body: "Late A after restart", ack: .ackedDirect
        ))
        try require(try reopened.loadWatchLightMessage(messageId: "shared-message-id")?.body == "B body", "restart forgot cross-Gateway delivery ownership evidence")
        try require(try reopened.loadWatchDeliveryRecords().count == 2, "ownership check must retain both delivery facts")
        print("PASS deleted_identity_reused_by_other_gateway")
    }
}

#if WATCH_RESOURCE_TESTS
private func runResourceTests() throws {
    let hashA = String(repeating: "a", count: 64)
    let hashB = String(repeating: "b", count: 64)
    do {
        let store = try WatchLocalSQLiteStore(appGroupIdentifier: "resource-immutable")
        _ = try store.ingestWatchDelivery(delivery("resource-delivery", messageID: "resource-message"))
        let owner = ImageResourceOwner.watchMessage(localID: "resource-message")
        let initial = try store.imageResourceSnapshot(owner: owner)!
        try require(try store.bindImageResource(snapshot: initial, requestKey: "request", contentHash: hashA), "first acquisition must bind")
        try require(try !store.bindImageResource(snapshot: initial, requestKey: "request", contentHash: hashB), "a later response must not replace the historical binding")
        _ = try store.markWatchLightMessageRead(messageId: "resource-message")
        _ = try store.ingestWatchDelivery(delivery("resource-delivery", messageID: "resource-message", body: "Enriched body"))
        try require(try store.imageResourceSnapshot(owner: owner) == initial, "read state and duplicate metadata may not invalidate acquired content")
        try require(try store.imageResourceBinding(snapshot: initial, requestKey: "request") == hashA, "historical bytes must remain bound")
        print("PASS resource_immutable_binding_and_read_enrichment")
    }
    do {
        let store = try WatchLocalSQLiteStore(appGroupIdentifier: "resource-shared")
        _ = try store.ingestWatchDelivery(delivery("shared-a", messageID: "shared-a"))
        _ = try store.ingestWatchDelivery(delivery("shared-b", messageID: "shared-b"))
        let first = try store.imageResourceSnapshot(owner: .watchMessage(localID: "shared-a"))!
        let second = try store.imageResourceSnapshot(owner: .watchMessage(localID: "shared-b"))!
        try require(first.scope == second.scope, "same proved Gateway and recipient can share a resource")
        try require(try store.bindImageResource(snapshot: first, requestKey: "request", contentHash: hashA), "first reference must bind")
        try require(try store.bindImageResource(snapshot: second, requestKey: "request", contentHash: hashA), "second reference must bind")
        let object = URL(fileURLWithPath: ProcessInfo.processInfo.environment["WATCH_SQLITE_TEST_ROOT"]!).appendingPathComponent("resource-object")
        try Data("retained original".utf8).write(to: object)
        let firstMessage = try store.loadWatchLightMessage(messageId: "shared-a")!
        try require(try store.deleteWatchLightMessage(matching: firstMessage, config: nil, localConfig: nil), "first delete must commit")
        try require(try !store.collectImageResource(contentHash: hashA, remove: { try? FileManager.default.removeItem(at: object) }), "another business reference must prevent unlink")
        try require(FileManager.default.fileExists(atPath: object.path), "shared bytes were deleted too early")
        try require(try !store.bindImageResource(snapshot: first, requestKey: "late-request", contentHash: hashB), "deleted owner's late fetch may not revive a reference")
        let secondMessage = try store.loadWatchLightMessage(messageId: "shared-b")!
        try require(try store.deleteWatchLightMessage(matching: secondMessage, config: nil, localConfig: nil), "second delete must commit")
        try require(try store.collectImageResource(contentHash: hashA, remove: { try? FileManager.default.removeItem(at: object) }), "unreferenced bytes must be collectable")
        try require(!FileManager.default.fileExists(atPath: object.path), "collection must unlink the original")
        print("PASS resource_shared_reference_delete_and_late_bind")
    }
    do {
        let reopened = try WatchLocalSQLiteStore(appGroupIdentifier: "resource-immutable")
        let snapshot = try reopened.imageResourceSnapshot(owner: .watchMessage(localID: "resource-message"))!
        try require(try reopened.imageResourceBinding(snapshot: snapshot, requestKey: "request") == hashA, "reopen must preserve acquired resource identity")
        print("PASS resource_reference_reopen")
    }
    do {
        let store = try WatchLocalSQLiteStore(appGroupIdentifier: "resource-aba")
        _ = try store.ingestWatchDelivery(delivery("aba-old", messageID: "aba-message"))
        let before = try store.imageResourceSnapshot(owner: .watchMessage(localID: "aba-message"))!
        let content = try store.loadWatchLightMessage(messageId: "aba-message")!
        try require(try store.deleteWatchLightMessage(matching: content, config: nil, localConfig: nil), "ABA delete must commit")
        try store.upsertWatchLightPayload(.message(content))
        let recreated = try store.imageResourceSnapshot(owner: .watchMessage(localID: "aba-message"))!
        try require(before.stamp != recreated.stamp, "identical bytes/time after delete must have a new lifecycle")
        try require(try !store.bindImageResource(snapshot: before, requestKey: "late", contentHash: hashA), "ABA old response must not bind the new row")
        try require(try store.bindImageResource(snapshot: recreated, requestKey: "request", contentHash: hashA), "recreated content may acquire its own bytes")
        try require(try store.deleteWatchLightMessage(matching: content, config: nil, localConfig: nil), "second identical delete must commit")
        try store.upsertWatchLightPayload(.message(content))
        let unprovedReplacement = try store.imageResourceSnapshot(owner: .watchMessage(localID: "aba-message"))!
        try require(unprovedReplacement.scope != recreated.scope, "an unknown-source replacement may not fresh-hit another lifecycle's cache namespace")
        _ = try store.ingestWatchDelivery(delivery("aba-new", messageID: "aba-message"))
        let newDelivery = try store.imageResourceSnapshot(owner: .watchMessage(localID: "aba-message"))!
        try require(newDelivery.stamp != recreated.stamp, "a genuine new delivery must not inherit old content bindings")
        try require(try store.imageResourceBinding(snapshot: newDelivery, requestKey: "request") == nil, "new delivery must start without the old binding")
        print("PASS resource_delete_recreate_and_new_delivery_generations")
    }
    do {
        let store = try WatchLocalSQLiteStore(appGroupIdentifier: "resource-entities")
        try store.upsertWatchLightPayload(.event(WatchLightEvent(eventId: "resource-event", title: "Event", summary: nil, state: nil, severity: nil, decryptionState: nil, imageURL: nil, updatedAt: Date(timeIntervalSince1970: 123))))
        try store.upsertWatchLightPayload(.thing(WatchLightThing(thingId: "resource-thing", title: "Thing", summary: nil, attrsJSON: nil, decryptionState: nil, imageURL: nil, updatedAt: Date(timeIntervalSince1970: 123))))
        let event = try store.imageResourceSnapshot(owner: .watchEntity(type: "event", localID: "resource-event"))!
        let thing = try store.imageResourceSnapshot(owner: .watchEntity(type: "thing", localID: "resource-thing"))!
        try require(event.scope != thing.scope, "unproved imported owners must not share a scope")
        try require(try store.bindImageResource(snapshot: event, requestKey: "request", contentHash: hashA), "event reference must bind")
        try require(try store.bindImageResource(snapshot: thing, requestKey: "request", contentHash: hashA), "thing reference must bind")
        try store.clearWatchLightStore()
        try require(try store.imageResourceSnapshot(owner: event.owner) == nil, "reset must remove canonical event")
        try require(try store.collectImageResource(contentHash: hashA, remove: {}), "reset must release both entity references")
        print("PASS resource_entity_scopes_and_reset_release")
    }
    do {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["WATCH_SQLITE_TEST_ROOT"]!).appendingPathComponent("resource-old-schema", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var db: OpaquePointer?
        try require(sqlite3_open(root.appendingPathComponent("watch.sqlite").path, &db) == SQLITE_OK, "old test database must open")
        let oldSQL = """
            CREATE TABLE watch_light_messages(message_id TEXT PRIMARY KEY NOT NULL, title TEXT NOT NULL, body TEXT NOT NULL, image_url TEXT, url TEXT, severity TEXT, received_at REAL NOT NULL, is_read INTEGER NOT NULL, entity_type TEXT NOT NULL, entity_id TEXT, notification_request_id TEXT);
            INSERT INTO watch_light_messages VALUES('old-resource-message', 'Preserved title', 'Preserved body', NULL, NULL, NULL, 123, 0, 'message', 'old-resource-message', 'old-resource-request');
            """
        let migrated: ImageResourceOwnerSnapshot
        try require(sqlite3_exec(db, oldSQL, nil, nil, nil) == SQLITE_OK, "explicit old schema fixture must be valid")
        sqlite3_close(db)
        do {
            let store = try WatchLocalSQLiteStore(appGroupIdentifier: "resource-old-schema")
            try require(try store.loadWatchLightMessage(messageId: "old-resource-message")?.body == "Preserved body", "resource schema upgrade may not discard old content")
            migrated = try store.imageResourceSnapshot(owner: .watchMessage(localID: "old-resource-message"))!
            try require(migrated.scope.hasPrefix("isolated:"), "old unproved source must remain owner-local")
            try require(try store.bindImageResource(snapshot: migrated, requestKey: "request", contentHash: hashA), "migrated existing content may bind safely")
        }
        let reopened = try WatchLocalSQLiteStore(appGroupIdentifier: "resource-old-schema")
        try require(try reopened.imageResourceSnapshot(owner: migrated.owner) == migrated, "reopen may not renew migrated generation")
        try require(try reopened.imageResourceBinding(snapshot: migrated, requestKey: "request") == hashA, "migration must be idempotent")
        print("PASS resource_old_schema_migration_and_reopen")
    }
}
#endif

@main
private enum WatchSQLiteLifecycleTests {
    static func main() {
        do {
            try runLifecycleTests()
            var passed = 7
#if WATCH_RESOURCE_TESTS
            try runResourceTests()
            passed += 6
#endif
#if WATCH_FROZEN_PULL_METADATA_TESTS
            passed += 1
#endif
            print("RESULT passed=\(passed) failed=0 layer=host_production_watch_sqlite")
        } catch {
            FileHandle.standardError.write(Data("FAIL \(error)\n".utf8))
            exit(1)
        }
    }
}
