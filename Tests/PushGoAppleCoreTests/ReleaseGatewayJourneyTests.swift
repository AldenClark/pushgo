import Foundation
import CryptoKit
import GRDB
import Testing
@testable import PushGoAppleCore

// This opt-in integration suite requires an isolated real Gateway. It never
// substitutes a mocked response when the process is absent.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["PUSHGO_SMOKE_GATEWAY_URL"] != nil))
@MainActor
struct ReleaseGatewayJourneyTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["PUSHGO_SMOKE_DEEP_CONTINUATION"] == "1"))
    func realGatewayFullConflictHeadResumesDurableFrontierAndAcknowledgesOnlyHealthyTail() async throws {
        let base = try #require(URL(string: ProcessInfo.processInfo.environment["PUSHGO_SMOKE_GATEWAY_URL"] ?? ""))
        let auth = try #require(ProcessInfo.processInfo.environment["PUSHGO_SMOKE_GATEWAY_AUTH"])
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let service = ChannelSubscriptionService(session: session)
        try await withIsolatedLocalDataStore { store, group in
            try await Task { @MainActor in
                let device = try await service.registerDevice(baseURL: base, token: auth, platform: "ios", existingDeviceKey: nil)
                _ = try await service.upsertDeviceChannel(baseURL: base, token: auth, deviceKey: device.deviceKey,
                    platform: "ios", channelType: "apns",
                    providerToken: String(repeating: UUID().uuidString.replacingOccurrences(of: "-", with: ""), count: 2))
                let passphrase = UUID().uuidString
                let subscription = try await service.subscribe(baseURL: base, token: auth, deviceKey: device.deviceKey,
                    channelId: nil, channelName: "Apple real deep continuation", password: passphrase)
                #expect(subscription.created && subscription.subscribed)
                _ = await store.saveCachedDeviceKey(device.deviceKey, for: "macos")
                for index in 0..<205 {
                    try await submit(session, base: base, auth: auth, channel: subscription.channelId, passphrase: passphrase,
                        title: "Synthetic ordinary \(index)", body: "Exact deep-page body \(index)")
                }
                var eventIDs: [String] = []
                let stamp = Int64(Date().timeIntervalSince1970 * 1_000)
                for index in 0..<5 {
                    let created = try await post(session, base: base, auth: auth, path: "event/create", payload: [
                        "channel_id": subscription.channelId, "password": passphrase,
                        "event_time": stamp + Int64(index), "title": "Deep event \(index)",
                        "status": "running", "message": "Exact independent event \(index)", "severity": "normal",
                    ])
                    eventIDs.append(try #require(created["event_id"] as? String))
                }

                // Select the actual ordered head, rather than assuming admission
                // order across millisecond ties. Every server row came from its
                // normal API; only this isolated client's historical ledger is injected.
                let head = try await service.pullMessages(baseURL: base, token: auth, deviceKey: device.deviceKey)
                try #require(head.items.count == 200 && head.scanComplete == false)
                let token = try #require(head.nextPageToken)
                let tail = try await service.pullMessages(baseURL: base, token: auth, deviceKey: device.deviceKey, pageToken: token)
                try #require(tail.items.count == 10 && tail.scanComplete == true && tail.nextPageToken == nil)
                #expect(tail.items.filter { $0.payload["entity_type"] == "message" }.count == 5)
                #expect(tail.items.filter { $0.payload["entity_type"] == "event" }.count == 5)
                let headIDs = Set(head.items.map(\.deliveryId))
                let tailIDs = Set(tail.items.map(\.deliveryId))
                #expect(headIDs.isDisjoint(with: tailIDs))
                #expect(try await store.loadMessages().isEmpty)
                let file = try AppConstants.appLocalDatabaseDirectory(appGroupIdentifier: group)
                    .appendingPathComponent(AppConstants.databaseStoreFilename)
                let fixture = try DatabaseQueue(path: file.path)
                try await fixture.write { db in
                    for item in head.items {
                        let op = try #require(item.payload["op_id"])
                        let entity = try #require(item.payload["entity_id"])
                        let channel = try #require(item.payload["channel_id"])
                        #expect(item.payload["entity_type"] == "message")
                        try db.execute(sql: """
                            INSERT INTO operation_ledger
                            (scope_key,message_id,op_id,channel_id,entity_type,entity_id,delivery_id,applied_at)
                            VALUES(?,?,?,?,?,?,?,?);
                            """, arguments: ["\(channel)|message|\(entity)|\(op)", "synthetic-deleted-\(item.deliveryId)",
                                op, channel, "message", entity, "synthetic-old-\(item.deliveryId)", 123])
                    }
                    #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM operation_ledger;") == 200)
                }
                let journal = DurableIngressJournal(appGroupIdentifier: group)
                #expect(await journal.durabilityPragmas() != nil)
                let journalURL = try #require(await journal.databaseURL)
                let gate = RealGatewayCheckpointGate(databaseURL: journalURL)
                let config = ServerConfig(baseURL: base, token: auth, updatedAt: Date(timeIntervalSince1970: 1_800_000_000.375))
                let directory = try #require(PushGoAutomationContext.storageRootOverrideURL)
                    .appendingPathComponent("real-gateway-protected-config", isDirectory: true)
                let configStore = LocalKeychainConfigStore(qualityStorageDirectory: directory)
                try configStore.saveServerConfig(config)
                let ackStore = ProviderDeliveryAckFailureStore(appGroupIdentifier: group)
                var pages: [[String]] = []
                var conflictCount = 0
                @MainActor func coordinator(_ target: LocalDataStore, _ captured: ServerConfig) -> ProviderIngressCoordinator {
                    ProviderIngressCoordinator(platformSuffix: "ios", dataStore: target, channelSubscriptionService: service,
                        notificationIngressInbox: NotificationIngressInbox(appGroupIdentifier: group), ackMarkerStore: ackStore,
                        wakeupPullClaimStore: ProviderWakeupPullClaimStore(appGroupIdentifier: group), hooks: .init(
                            isEnabled: { gate.allowsProgress() }, serverConfig: { captured }, cachedDeviceKey: { device.deviceKey },
                            hasPersistedNotification: { _ in false }, persistPayloads: { inputs in
                                pages.append(inputs.compactMap(\.requestIdentifier))
                                let outcomes = await NotificationPersistenceCoordinator.persistRemotePayloadsIfNeeded(
                                    inputs.map { .init(payload: $0.payload, requestIdentifier: $0.requestIdentifier) }, dataStore: target)
                                let results = outcomes.map(ProviderIngressPersistenceResult.init)
                                for result in results { if case .identityConflict = result { conflictCount += 1 } }
                                return results
                            }, applyPersistenceResults: { _ in }, reportInboxProgress: { _ in },
                            recordProviderError: { error, _ in Issue.record("Actual Gateway continuation failed: \(error)") }))
                }
                var first: ProviderIngressCoordinator? = coordinator(store, config)
                _ = await first?.syncProviderIngressOutcome(reason: "manual_real_deep_checkpoint")
                let savedFrontier = try gate.readFrontier()
                let checkpoint = try #require(savedFrontier)
                #expect(checkpoint.pageToken != nil)
                #expect(!gate.allowsProgress()) // stop this owner only after the durable checkpoint
                #expect(gate.readError == nil)
                try #require(pages.count == 1)
                #expect(Set(pages[0]) == headIDs)
                #expect(conflictCount == 200)
                #expect(try await store.loadMessages().isEmpty)
                #expect(await ackStore.pendingMarkers(limit: 256, minimumAge: 0).isEmpty)
                let pending = await NotificationIngressInbox(appGroupIdentifier: group).pendingEntries(limit: 256)
                #expect(Set(pending.compactMap { $0.record.requestIdentifier }) == headIDs)

                // This new arrival is beyond the stopped pass's captured
                // ceiling. Send the exact serialized bytes, not a re-encoded
                // approximation, and keep HTTP JSON size separate from frames.
                let rejectedOperation = UUID().uuidString
                let rejected = try await submitSizedMessage(session, base: base, auth: auth,
                    channel: subscription.channelId, passphrase: passphrase,
                    operationID: rejectedOperation, bytes: 49_153)
                #expect(rejected.status == 400 && rejected.errorCode == "invalid_request_body")
                let largeOperation = UUID().uuidString
                let large = try await submitSizedMessage(session, base: base, auth: auth,
                    channel: subscription.channelId, passphrase: passphrase,
                    operationID: largeOperation, bytes: 49_152)
                #expect(large.status == 200)

                first = nil
                let root = try #require(PushGoAutomationContext.storageRootOverrideURL)
                LocalDataStore.releaseSharedResourcesForTesting(storageRootURL: root)
                let reopened = LocalDataStore(appGroupIdentifier: group, spotlightIndexer: nil)
                let savedConfig = try configStore.loadServerConfig(backfillGatewayToken: false)
                let loaded = try #require(savedConfig)
                #expect(loaded.updatedAt != config.updatedAt)
                gate.stopAtCheckpoint = false
                let resumed = coordinator(reopened, loaded)
                let result = await resumed.syncProviderIngressOutcome(reason: "manual_real_deep_reopen")
                #expect(result.completedRequest && result.appliedCount == 10)
                // Exercise the normal default recovery entry, including its
                // due inbox batches. The processed-fact precheck now detects
                // the same typed conflict before attempting canonical writes.
                // Their exact durable payloads/backoff are checked below.
                // Losing the frontier would still add another 200-item network
                // head and fail this exact two-page oracle.
                try #require(pages.count == 2)
                #expect(Set(pages[0]) == headIDs)
                let lastPage = try #require(pages.last)
                #expect(Set(lastPage) == tailIDs)
                #expect(conflictCount == 200)
                let savedCompleted = try gate.readFrontier()
                let completed = try #require(savedCompleted)
                #expect(completed.pageToken == nil)
                let remaining = try await service.pullMessages(baseURL: base, token: auth, deviceKey: device.deviceKey)
                #expect(Set(remaining.items.map(\.deliveryId)) == headIDs)
                #expect(remaining.scanComplete == false && remaining.nextPageToken != nil)
                #expect(await ackStore.pendingMarkers(limit: 256, minimumAge: 0).isEmpty)
                // The normal inbox retry established a 30-second backoff. Its
                // due-only accessor is deliberately empty; all 200 exact
                // failed delivery payloads must still remain durably recoverable.
                let retryInbox = NotificationIngressInbox(appGroupIdentifier: group)
                let retainedCounts = await retryInbox.queueCounts(importLegacyState: false)
                #expect(retainedCounts.outstanding == 200 && retainedCounts.due == 0)
                let dueEntries = await retryInbox.pendingEntries(limit: 256)
                #expect(dueEntries.isEmpty)
                for item in head.items {
                    let identity = try #require(ProviderDeliveryAckFailureStore.DeliveryIdentity(
                        deliveryId: item.deliveryId, baseURL: base, deviceKey: device.deviceKey, ackContract: .v2Batch))
                    let retainedPayload = await retryInbox.durablePayload(identity: identity)
                    let payload = try #require(retainedPayload)
                    #expect(payload["delivery_id"]?.value as? String == item.deliveryId)
                    #expect(payload["provider_device_key"]?.value as? String == device.deviceKey)
                    for (key, value) in item.payload {
                        #expect(payload[key]?.value as? String == value)
                    }
                }
                for item in tail.items {
                    if item.payload["entity_type"] == "event" {
                        let entity = try #require(item.payload["entity_id"])
                        let detail = try await reopened.loadEventProjectionDetail(eventId: entity)
                        #expect(detail.head?.title == item.payload["title"])
                    } else {
                        let rows = try await reopened.loadMessages(deliveryId: item.deliveryId)
                        #expect(rows.count == 1 && rows[0].body == item.payload["body"])
                    }
                }

                // An explicitly requested next pass must see the newly
                // accepted 48KiB request, without permanently skipping old
                // failed duties or appending it to the former captured pass.
                let newArrival = await resumed.syncProviderIngressOutcome(reason: "manual_real_deep_new_arrival")
                #expect(newArrival.completedRequest && newArrival.appliedCount == 1)
                #expect(pages.suffix(2).map(\.count) == [200, 1])
                #expect(conflictCount == 400)
                let allRows = try await reopened.loadMessages()
                let largeRow = try #require(allRows.first { $0.operationId?.lowercased() == largeOperation.lowercased() })
                #expect(largeRow.body == large.body)
                let largeDelivery = try #require(largeRow.deliveryId)
                let afterNewArrival = try await service.pullMessages(baseURL: base, token: auth, deviceKey: device.deviceKey)
                #expect(Set(afterNewArrival.items.map(\.deliveryId)) == headIDs)
                #expect(afterNewArrival.scanComplete == true)
                let repeatedAck = try await service.ackMessages(baseURL: base, token: auth, deviceKey: device.deviceKey,
                    deliveryIds: Array(tailIDs) + [largeDelivery])
                #expect(repeatedAck.removedCount == 0)
                if let path = ProcessInfo.processInfo.environment["PUSHGO_SMOKE_RESULT_PATH"] {
                    let evidence: [String: Any] = ["channel_id": subscription.channelId,
                        "historical_ledger_fixture": "200 explicitly injected unattributed/deleted local facts; no server-row injection",
                        "unacknowledged_head_delivery_ids": headIDs.sorted(), "acknowledged_tail_delivery_ids": tailIDs.sorted(),
                        "event_ids": eventIDs, "first_persistence_count": pages[0].count,
                        "resumed_inbox_canonical_retry_page_counts": [Int](), "resumed_network_tail_count": 10,
                        "retained_conflicts_rejected_before_canonical_write": true,
                        "retained_failed_payload_count": retainedCounts.outstanding, "retained_failed_due_count": retainedCounts.due,
                        "retained_failed_payload_identity_and_fields_verified": 200,
                        "identity_conflicts": conflictCount, "ordinary_tail_count": 5, "event_tail_count": 5,
                        "post_ceiling_large_operation_id": largeOperation, "post_ceiling_large_delivery_id": largeDelivery,
                        "large_whole_json_bytes": 49_152, "large_request_sha256": large.requestHash,
                        "large_body_sha256": SHA256.hash(data: Data(large.body.utf8)).map { String(format: "%02x", $0) }.joined(),
                        "rejected_operation_id": rejectedOperation, "rejected_whole_json_bytes": 49_153,
                        "rejected_request_sha256": rejected.requestHash, "rejected_http_status": rejected.status,
                        "non_nil_checkpoint_before_reopen": true, "completed_frontier_after_reopen": true,
                        "recovery_scope": "Coordinator/Store/protected-config reopen; not OS process death"]
                    try JSONSerialization.data(withJSONObject: evidence, options: [.sortedKeys])
                        .write(to: URL(fileURLWithPath: path), options: .atomic)
                }
            }.value
        }
    }

    @Test
    func registeredSubscriberReceivesPersistsOpensReplaysAndAcknowledgesRealGatewayMessages() async throws {
        let base = try #require(URL(string: ProcessInfo.processInfo.environment["PUSHGO_SMOKE_GATEWAY_URL"] ?? ""))
        let auth = try #require(ProcessInfo.processInfo.environment["PUSHGO_SMOKE_GATEWAY_AUTH"])
        let passphrase = UUID().uuidString
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let service = ChannelSubscriptionService(session: session)
        try await withIsolatedLocalDataStore { store, group in
            try await Task { @MainActor in
                let device = try await service.registerDevice(baseURL: base, token: auth, platform: "ios", existingDeviceKey: nil)
                let syntheticProvider = String(repeating: UUID().uuidString.replacingOccurrences(of: "-", with: ""), count: 2)
                let route = try await service.upsertDeviceChannel(baseURL: base, token: auth, deviceKey: device.deviceKey, platform: "ios", channelType: "apns", providerToken: syntheticProvider)
                #expect(route.deviceKey == device.deviceKey)
                let subscription = try await service.subscribe(baseURL: base, token: auth, deviceKey: device.deviceKey, channelId: nil, channelName: "Apple real Gateway journey", password: passphrase)
                #expect(subscription.created && subscription.subscribed)
                _ = await store.saveCachedDeviceKey(device.deviceKey, for: "macos")
                for (title, body) in [("Target", "Exact network body"), ("Survivor", "Keep this separate message")] {
                    try await submit(session, base: base, auth: auth, channel: subscription.channelId, passphrase: passphrase, title: title, body: body)
                }
                // v2 pull is non-destructive. Save the real payload for replay.
                let pending = try await service.pullMessages(baseURL: base, token: auth, deviceKey: device.deviceKey)
                #expect(pending.items.count == 2)
                let ackStore = ProviderDeliveryAckFailureStore(appGroupIdentifier: group)
                let frozenGatewayConfig = ServerConfig(baseURL: base, token: auth)
                let coordinator = ProviderIngressCoordinator(
                    platformSuffix: "ios", dataStore: store,
                    channelSubscriptionService: service,
                    notificationIngressInbox: NotificationIngressInbox(appGroupIdentifier: group),
                    ackMarkerStore: ackStore,
                    wakeupPullClaimStore: ProviderWakeupPullClaimStore(appGroupIdentifier: group),
                    hooks: .init(
                        isEnabled: { true },
                        serverConfig: { frozenGatewayConfig },
                        cachedDeviceKey: { device.deviceKey },
                        hasPersistedNotification: { identity in
                            guard let id = identity.deliveryId, let rows = try? await store.loadMessages(deliveryId: id) else { return false }
                            return rows.contains(where: identity.matchesPersisted)
                        },
                        persistPayloads: { inputs in
                            let outcomes = await NotificationPersistenceCoordinator.persistRemotePayloadsIfNeeded(
                                inputs.map { .init(payload: $0.payload, requestIdentifier: $0.requestIdentifier) }, dataStore: store)
                            // Assert canonical durability before returning to the
                            // coordinator that owns the subsequent network ACK.
                            for input in inputs {
                                let id = input.payload["delivery_id"] as? String ?? ""
                                if input.payload["entity_type"] as? String == "thing" || input.payload["entity_type"] as? String == "event" {
                                    let target = try? await store.loadEntityOpenTarget(notificationRequestId: input.requestIdentifier ?? id)
                                    #expect(target != nil)
                                } else {
                                    let durableRows = try? await store.loadMessages(deliveryId: id)
                                    #expect(durableRows?.count == 1)
                                }
                            }
                            return outcomes.map(ProviderIngressPersistenceResult.init)
                        },
                        applyPersistenceResults: { _ in }, reportInboxProgress: { _ in },
                        recordProviderError: { error, _ in Issue.record("Real Gateway ingress failed: \(error)") }
                    ))
                let result = await coordinator.syncProviderIngressOutcome(reason: "release_gateway_journey", skipInboxMerge: true)
                #expect(result.completedRequest && result.appliedCount == 2)
                let rows = try await store.loadMessages()
                let target = try #require(rows.first { $0.title == "Target" })
                let survivor = try #require(rows.first { $0.title == "Survivor" })
                #expect(target.body == "Exact network body")
                #expect(target.rawPayload["channel_id"]?.value as? String == subscription.channelId)
                #expect(survivor.body == "Keep this separate message")
                #expect(target.id != survivor.id)
                #expect(try await service.pullMessages(baseURL: base, token: auth, deviceKey: device.deviceKey).items.isEmpty)
                #expect(await ackStore.pendingMarkers(limit: 10, minimumAge: 0).isEmpty)

                // Notification Center side effects require an App bundle and are
                // covered by the separate native iOS notification-click profile.
                // This host test checks target routing and the canonical read API.
                let opener = NotificationOpenController(dataStore: store, localizationManager: LocalizationManager(), messageStateCoordinatorProvider: { nil }, refreshCountsAndNotify: {}, removeDeliveredNotificationIfNeeded: { _ in }, autoEnableDataPage: { _ in }, showToast: { _ in })
                await opener.handleNotificationOpen(messageId: try #require(target.messageId))
                #expect(opener.pendingMessageToOpen == target.id)
                try await store.setMessageReadState(id: target.id, isRead: true)
                let targetPayload = try #require(pending.items.first { $0.payload["title"] == "Target" })
                var replay: [AnyHashable: Any] = Dictionary(uniqueKeysWithValues: targetPayload.payload.map { (AnyHashable($0.key), $0.value as Any) })
                replay["delivery_id"] = targetPayload.deliveryId
                replay["base_url"] = base.absoluteString
                replay["provider_device_key"] = device.deviceKey
                let replayInput = NotificationPersistenceCoordinator.RemotePayload(payload: replay, requestIdentifier: targetPayload.deliveryId)
                _ = await NotificationPersistenceCoordinator.persistRemotePayloadsIfNeeded([replayInput], dataStore: store)
                let reopened = LocalDataStore(appGroupIdentifier: group, spotlightIndexer: nil)
                #expect(try await reopened.loadMessages().count == 2)
                #expect(try await reopened.loadMessage(id: target.id)?.isRead == true)
                #expect(try await reopened.loadMessage(id: target.id)?.body == "Exact network body")
                try await reopened.deleteMessage(id: target.id)
                let afterDelete = LocalDataStore(appGroupIdentifier: group, spotlightIndexer: nil)
                #expect(try await afterDelete.loadMessage(id: target.id) == nil)
                #expect(try await afterDelete.loadMessage(id: survivor.id)?.body == "Keep this separate message")

                // Continue through real entity commands and the same receive
                // pipeline: server acceptance alone cannot prove the App's
                // incremental projection, identity or notification routing.
                let stamp = Int64(Date().timeIntervalSince1970 * 1_000)
                let common: [String: Any] = ["channel_id": subscription.channelId, "password": passphrase]
                @MainActor func entity(_ path: String, _ fields: [String: Any]) async throws -> [String: Any] {
                    try await post(session, base: base, auth: auth, path: path, payload: common.merging(fields) { _, value in value })
                }
                let thing = try await entity("thing/create", ["observed_at": stamp, "title": "Gateway Server", "description": "Online", "attrs": ["cpu": "40"]])
                let thingID = try #require(thing["thing_id"] as? String)
                let event = try await entity("event/create", ["event_time": stamp + 1, "title": "Gateway Deploy", "status": "running", "message": "Started", "severity": "normal"])
                let eventID = try #require(event["event_id"] as? String)
                let relatedEvent = try await entity("thing/\(thingID)/event/create", ["event_time": stamp + 1, "title": "Related Gateway Deploy", "status": "running", "message": "Started", "severity": "normal"])
                let relatedEventID = try #require(relatedEvent["event_id"] as? String)
                _ = try await entity("thing/update", ["thing_id": thingID, "observed_at": stamp + 2, "attrs": ["cpu": "55"]])
                _ = try await entity("event/close", ["event_id": eventID, "event_time": stamp + 3, "status": "complete", "message": "Completed", "severity": "normal"])
                _ = try await entity("thing/\(thingID)/event/close", ["event_id": relatedEventID, "event_time": stamp + 3, "status": "complete", "message": "Completed relation", "severity": "normal"])
                _ = try await entity("thing/archive", ["thing_id": thingID, "observed_at": stamp + 4])
                let entityResult = await coordinator.syncProviderIngressOutcome(reason: "manual_release_entities", skipInboxMerge: true)
                #expect(entityResult.completedRequest && entityResult.appliedCount == 7)
                let projectionStore = LocalDataStore(appGroupIdentifier: group, spotlightIndexer: nil)
                let thingDetail = try await projectionStore.loadThingProjectionDetail(thingId: thingID)
                let eventDetail = try await projectionStore.loadEventProjectionDetail(eventId: eventID)
                #expect(thingDetail.head?.thingId == thingID)
                #expect(thingDetail.head?.title == "Gateway Server")
                #expect(thingDetail.head?.rawPayload["attrs"]?.value as? [String: String] == ["cpu": "55"])
                #expect((thingDetail.head?.rawPayload["state"]?.value as? String)?.lowercased() == "archived")
                #expect(eventDetail.head?.eventId == eventID)
                #expect(eventDetail.head?.thingId == nil)
                #expect(eventDetail.head?.title == "Gateway Deploy")
                #expect(eventDetail.head?.eventState == "closed")
                let relatedClosed = try #require(thingDetail.history.first { $0.eventId == relatedEventID && $0.eventState == "closed" })
                #expect(relatedClosed.thingId == thingID)
                #expect(relatedClosed.rawPayload["message"]?.value as? String == "Completed relation")
                #expect(try await projectionStore.loadEventProjectionDetail(eventId: relatedEventID).head == nil)
                // Match the App delegate: entity notifications decode their
                // payload first and use the entity entry, not message fallback.
                let eventHead = try #require(eventDetail.head)
                let eventPayload = Dictionary(uniqueKeysWithValues: eventHead.rawPayload.map { (AnyHashable($0.key), $0.value.value) })
                let eventTarget = try #require(NotificationHandling.entityOpenTargetComponents(from: eventPayload))
                #expect(eventTarget.entityType == "event" && eventTarget.entityId == eventID)
                await opener.handleNotificationOpen(entityType: eventTarget.entityType, entityId: eventTarget.entityId)
                #expect(opener.pendingEventToOpen == eventID && opener.pendingThingToOpen == nil)
                let thingHead = try #require(thingDetail.head)
                let thingPayload = Dictionary(uniqueKeysWithValues: thingHead.rawPayload.map { (AnyHashable($0.key), $0.value.value) })
                let thingTarget = try #require(NotificationHandling.entityOpenTargetComponents(from: thingPayload))
                #expect(thingTarget.entityType == "thing" && thingTarget.entityId == thingID)
                await opener.handleNotificationOpen(entityType: thingTarget.entityType, entityId: thingTarget.entityId)
                #expect(opener.pendingThingToOpen == thingID && opener.pendingEventToOpen == nil)
                #expect(try await service.pullMessages(baseURL: base, token: auth, deviceKey: device.deviceKey).items.isEmpty)
                #expect(try await service.unsubscribe(baseURL: base, token: auth, deviceKey: device.deviceKey, channelId: subscription.channelId))
                try await submit(session, base: base, auth: auth, channel: subscription.channelId, passphrase: passphrase, title: "Unsubscribed", body: "Must not be delivered")
                #expect(try await service.pullMessages(baseURL: base, token: auth, deviceKey: device.deviceKey).items.isEmpty)
            }.value
        }
    }

    private func submitSizedMessage(_ session: URLSession, base: URL, auth: String, channel: String,
                                    passphrase: String, operationID: String, bytes: Int) async throws
        -> (body: String, status: Int, requestHash: String, errorCode: String?) {
        var payload = ["channel_id": channel, "password": passphrase, "op_id": operationID,
                       "title": "Exact whole JSON boundary", "body": ""]
        let overhead = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]).count
        try #require(bytes > overhead)
        let body = String(repeating: "x", count: bytes - overhead)
        payload["body"] = body
        let encoded = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        try #require(encoded.count == bytes)
        var request = URLRequest(url: base.appendingPathComponent("message"))
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("Bearer \(auth)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = encoded
        let (data, response) = try await session.data(for: request)
        let http = try #require(response as? HTTPURLResponse)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["success"] as? Bool == (http.statusCode == 200))
        return (body, http.statusCode,
                SHA256.hash(data: encoded).map { String(format: "%02x", $0) }.joined(),
                object["error_code"] as? String)
    }

    private func submit(_ session: URLSession, base: URL, auth: String, channel: String, passphrase: String, title: String, body: String) async throws {
        _ = try await post(session, base: base, auth: auth, path: "message", payload: ["channel_id": channel, "password": passphrase, "title": title, "body": body])
    }

    private func post(_ session: URLSession, base: URL, auth: String, path: String, payload: [String: Any]) async throws -> [String: Any] {
        var request = URLRequest(url: base.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("Bearer \(auth)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (data, response) = try await session.data(for: request)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["success"] as? Bool == true)
        return try #require(object["data"] as? [String: Any])
    }
}

/// Test-only receiver disable at an observed, already committed frontier. It
/// neither changes wire traffic nor writes the journal, and never logs tokens.
@MainActor
private final class RealGatewayCheckpointGate {
    let databaseURL: URL
    var stopAtCheckpoint = true
    var readError: String?

    init(databaseURL: URL) { self.databaseURL = databaseURL }

    func allowsProgress() -> Bool {
        guard stopAtCheckpoint else { return true }
        do { return try readFrontier()?.pageToken == nil }
        catch { readError = String(describing: error); return false }
    }

    func readFrontier() throws -> DurableIngressJournal.PullFrontier? {
        var configuration = Configuration()
        configuration.readonly = true
        let database = try DatabaseQueue(path: databaseURL.path, configuration: configuration)
        return try database.read { db in
            guard let raw = try String.fetchOne(db, sql: "SELECT value FROM ingress_meta WHERE key='v2_pull_frontier';") else { return nil }
            guard let data = Data(base64Encoded: raw) else { throw CocoaError(.coderReadCorrupt) }
            return try PropertyListDecoder().decode(DurableIngressJournal.PullFrontier.self, from: data)
        }
    }
}
