import Foundation
import Testing
@testable import PushGoAppleCore

// This opt-in integration suite requires an isolated real Gateway. It never
// substitutes a mocked response when the process is absent.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["PUSHGO_SMOKE_GATEWAY_URL"] != nil))
@MainActor
struct ReleaseGatewayJourneyTests {
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
                let pending = try await service.pullMessages(baseURL: base, token: auth, deviceKey: device.deviceKey, allowLegacyFallback: false)
                #expect(pending.items.count == 2)
                let ackStore = ProviderDeliveryAckFailureStore(appGroupIdentifier: group)
                let coordinator = ProviderIngressCoordinator(
                    platformSuffix: "ios", dataStore: store,
                    channelSubscriptionService: service,
                    notificationIngressInbox: NotificationIngressInbox(appGroupIdentifier: group),
                    ackMarkerStore: ackStore,
                    wakeupPullClaimStore: ProviderWakeupPullClaimStore(appGroupIdentifier: group),
                    hooks: .init(
                        isEnabled: { true },
                        serverConfig: { ServerConfig(baseURL: base, token: auth) },
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
                #expect(try await service.pullMessages(baseURL: base, token: auth, deviceKey: device.deviceKey, allowLegacyFallback: false).items.isEmpty)
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
                #expect(try await service.pullMessages(baseURL: base, token: auth, deviceKey: device.deviceKey, allowLegacyFallback: false).items.isEmpty)
                #expect(try await service.unsubscribe(baseURL: base, token: auth, deviceKey: device.deviceKey, channelId: subscription.channelId))
                try await submit(session, base: base, auth: auth, channel: subscription.channelId, passphrase: passphrase, title: "Unsubscribed", body: "Must not be delivered")
                #expect(try await service.pullMessages(baseURL: base, token: auth, deviceKey: device.deviceKey, allowLegacyFallback: false).items.isEmpty)
            }.value
        }
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
