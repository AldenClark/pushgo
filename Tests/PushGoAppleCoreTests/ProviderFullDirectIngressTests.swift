import Foundation
import GRDB
import Testing
@testable import PushGoAppleCore

@Suite(.serialized)
@MainActor
struct ProviderFullDirectIngressTests {
    @Test
    func fullAdvertisementUsesAuthenticatedLocalContextAndOnlyPulledContent() async throws {
        try await withFullDirectStore { store, group in
            let server = try FullDirectHTTPFixture()
            defer { server.stop() }
            var response = FullDirectHTTPFixture.Configuration()
            response.pullStatus["advertised"] = 401
            let originalSentAt = Int64(Date().addingTimeInterval(-2 * 60 * 60).timeIntervalSince1970 * 1_000)
            response.sentAt = String(originalSentAt)
            try server.configure(response)
            let config = ServerConfig(baseURL: server.url("current"), token: response.tokens["current"])
            try await prepareFullDirectContext(store, config: config, device: response.devices["current"]!)
            let context = FullDirectContext(store: store, group: group, config: config, device: response.devices["current"]!)
            defer { context.close() }
            let device = response.devices["current"]!
            let foreignHint = fullDirectAdvertisement(response, base: server.url("advertised"), device: device)
            #expect(await context.inbox.enqueue(payload: foreignHint, requestIdentifier: response.deliveryID, source: "test.synthetic_foreign_apns"))
            #expect(await context.coordinator.mergeInbox(reason: "full_direct_foreign_origin", allowWakeupSync: true) == 0)
            #expect(try server.requests().isEmpty)
            #expect(try await store.loadMessages().isEmpty)
            #expect(await context.ackStore.pendingMarkers(minimumAge: 0).isEmpty)
            let foreignIdentity = try #require(ProviderDeliveryAckFailureStore.DeliveryIdentity(
                deliveryId: response.deliveryID, baseURL: server.url("advertised"), deviceKey: device, ackContract: .legacySingle))
            #expect(await context.inbox.durablePayload(identity: foreignIdentity) != nil)
            #expect((await context.inbox.queueCounts(importLegacyState: false)).outstanding == 1)

            let wrongDevice = "untrusted-advertised-device"
            let wrongDeviceHint = fullDirectAdvertisement(response, base: config.baseURL, device: wrongDevice)
            #expect(await context.inbox.enqueue(payload: wrongDeviceHint, requestIdentifier: response.deliveryID, source: "test.synthetic_wrong_device_apns"))
            #expect(await context.coordinator.mergeInbox(reason: "full_direct_wrong_device", allowWakeupSync: true) == 0)
            #expect(try server.requests().isEmpty)
            #expect(try await store.loadMessages().isEmpty)
            #expect(await context.ackStore.pendingMarkers(minimumAge: 0).isEmpty)
            let wrongIdentity = try #require(ProviderDeliveryAckFailureStore.DeliveryIdentity(
                deliveryId: response.deliveryID, baseURL: config.baseURL, deviceKey: wrongDevice, ackContract: .legacySingle))
            #expect(await context.inbox.durablePayload(identity: wrongIdentity) != nil)
            #expect((await context.inbox.queueCounts(importLegacyState: false)).outstanding == 2)

            let hint = fullDirectAdvertisement(response, base: config.baseURL, device: device)
            #expect(hint["sent_at"] == nil)
            #expect(await context.inbox.enqueue(codablePayload: UserInfoSanitizer.sanitize(hint).mapValues(AnyCodable.init), requestIdentifier: response.deliveryID, source: "test.synthetic_raw_apns"))

            #expect(await context.coordinator.mergeInbox(reason: "full_direct_real_http", allowWakeupSync: true) == 1)
            let saved = try #require(try await store.loadMessage(messageId: response.messageID))
            #expect(saved.body == response.body && saved.title == response.title)
            #expect(saved.providerSourceBaseURL == config.baseURL.absoluteString)
            #expect(saved.rawPayload["provider_device_key"]?.value as? String == response.devices["current"])
            #expect(Int64((saved.receivedAt.timeIntervalSince1970 * 1_000).rounded()) == originalSentAt)
            #expect(saved.rawPayload["sent_at"]?.value as? String == response.sentAt)
            let savedPayload = saved.rawPayload.reduce(into: [AnyHashable: Any]()) { $0[$1.key] = $1.value.value }
            #expect(!WatchNotificationFreshness.shouldPresent(payload: savedPayload, configuredMinutes: 30))
            #expect(try server.requests().allSatisfy { !$0.path.hasSuffix(ChannelSubscriptionService.batchAckV2Path) })
            await context.coordinator.drainAckMarkers(source: "test.after_real_store")

            let requests = try server.requests()
            let pulls = requests.filter { $0.path.hasSuffix(ChannelSubscriptionService.pullV2Path) }
            #expect(pulls.count == 1)
            #expect(pulls.allSatisfy { $0.deliveryID == response.deliveryID && $0.deviceKey == response.devices["current"] })
            #expect(requests.allSatisfy { $0.path.hasPrefix("/current/") })
            let authenticatedPulls = pulls.filter { $0.path == "/current" + ChannelSubscriptionService.pullV2Path }
            #expect(authenticatedPulls.count == 1 && authenticatedPulls.allSatisfy { $0.authorizationMatches && $0.hasAuthorization })
            let ack = try #require(requests.last)
            #expect(ack.path == "/current" + ChannelSubscriptionService.batchAckV2Path)
            #expect(ack.deliveryIDs == [response.deliveryID] && ack.deviceKey == response.devices["current"] && ack.authorizationMatches)
            #expect(await context.ackStore.pendingMarkers(minimumAge: 0).isEmpty)
            await server.stopAndWait()
        }
    }

    @Test
    func unavailablePullRetainsRawHintWithoutContentOrAckThenReopens() async throws {
        try await withFullDirectStore { store, group in
            let server = try FullDirectHTTPFixture()
            defer { server.stop() }
            var response = FullDirectHTTPFixture.Configuration()
            response.pullStatus["current"] = 503
            try server.configure(response)
            let config = ServerConfig(baseURL: server.url("current"), token: response.tokens["current"])
            try await prepareFullDirectContext(store, config: config, device: response.devices["current"]!)
            let first = FullDirectContext(store: store, group: group, config: config, device: response.devices["current"]!)
            let hint = fullDirectAdvertisement(response, base: config.baseURL, device: response.devices["current"]!)
            #expect(await first.inbox.enqueue(payload: hint, requestIdentifier: response.deliveryID, source: "test.synthetic_raw_apns"))
            let retry = try #require(await first.inbox.pendingEntries().first)
            #expect(await first.coordinator.mergeInbox(reason: "raw_network_disabled", allowWakeupSync: false) == 0)
            #expect(try await store.loadMessages().isEmpty)
            #expect(try server.requests().isEmpty)
            #expect(await first.ackStore.pendingMarkers(minimumAge: 0).isEmpty)
            // The next explicit turn enables network; make its existing hint
            // due without altering production backoff or retrying an action.
            await first.inbox.markRetry(retry, reason: "test_network_enabled", retryAfter: .distantPast)
            #expect(await first.coordinator.mergeInbox(reason: "raw_pull_unavailable", allowWakeupSync: true) == 0)
            #expect(try await store.loadMessages().isEmpty)
            #expect(await first.ackStore.pendingMarkers(minimumAge: 0).isEmpty)
            #expect((await first.inbox.queueCounts(importLegacyState: false)).outstanding == 1)
            let failedRequests = try server.requests()
            #expect(failedRequests.count == 1 && failedRequests.allSatisfy {
                $0.path.hasSuffix(ChannelSubscriptionService.pullV2Path) && $0.authorizationMatches
                    && $0.deviceKey == response.devices["current"] && $0.deliveryID == response.deliveryID
            })

            // Make this synthetic failure's existing retry due, without sleeping
            // or changing production retry policy, before reopening the owner.
            await first.inbox.markRetry(retry, reason: "test_retry_due", retryAfter: .distantPast)
            first.close()
            LocalDataStore.releaseSharedResourcesForTesting(storageRootURL: try #require(PushGoAutomationContext.storageRootOverrideURL))
            let reopened = LocalDataStore(appGroupIdentifier: group, spotlightIndexer: nil)
            response.pullStatus["current"] = 200
            try server.configure(response)
            let resumed = FullDirectContext(store: reopened, group: group, config: config, device: response.devices["current"]!)
            defer { resumed.close() }
            #expect(await resumed.coordinator.mergeInbox(reason: "raw_pull_reopen", allowWakeupSync: true) == 1)
            #expect(try await reopened.loadMessage(messageId: response.messageID)?.body == response.body)
            await resumed.coordinator.drainAckMarkers(source: "test.reopened_after_store")
            #expect(try server.requests().filter { $0.path.hasSuffix(ChannelSubscriptionService.pullV2Path) }.count == 2)
            #expect(try server.requests().filter { $0.path.hasSuffix(ChannelSubscriptionService.batchAckV2Path) }.count == 1)
            #expect(await resumed.ackStore.pendingMarkers(minimumAge: 0).isEmpty)
            await server.stopAndWait()
        }
    }

    @Test
    func trustedV2JournalReceiptRecoversOriginalBytesAndIdentityWithoutPull() async throws {
        try await withFullDirectStore { store, group in
            let server = try FullDirectHTTPFixture()
            defer { server.stop() }
            var response = FullDirectHTTPFixture.Configuration()
            response.pullStatus = ["current": 503, "original": 503]
            try server.configure(response)
            let current = ServerConfig(baseURL: server.url("current"), token: response.tokens["current"])
            try await prepareFullDirectContext(store, config: current, device: response.devices["current"]!)
            let original = server.url("original"), originalDevice = response.devices["original"]!
            #expect(ProviderGatewayTokenStore().save(token: response.tokens["original"], baseURL: original))
            let identity = try #require(ProviderDeliveryAckFailureStore.DeliveryIdentity(
                deliveryId: response.deliveryID, baseURL: original, deviceKey: originalDevice, ackContract: .v2Batch))
            let inbox = NotificationIngressInbox(appGroupIdentifier: group)
            var receipt = response.payload
            receipt["base_url"] = original.absoluteString
            receipt["provider_device_key"] = originalDevice
            receipt["delivery_id"] = response.deliveryID
            // Explicit fault-state injection through the production typed
            // journal API: this represents an already acquired V2 receipt,
            // not a claim that arbitrary payload literals authenticate it.
            #expect(await inbox.enqueue(codablePayload: receipt.mapValues { AnyCodable($0) },
                requestIdentifier: response.deliveryID, source: "test.synthetic_authenticated_v2_receipt",
                ackIdentity: identity, requiredEntryState: "terminal_local", postChangeNotification: false))
            #expect(await inbox.durablePayload(identity: identity) != nil)
            LocalDataStore.releaseSharedResourcesForTesting(storageRootURL: try #require(PushGoAutomationContext.storageRootOverrideURL))
            let reopened = LocalDataStore(appGroupIdentifier: group, spotlightIndexer: nil)
            let context = FullDirectContext(store: reopened, group: group, config: current, device: response.devices["current"]!)
            defer { context.close() }

            #expect(await context.coordinator.mergeInbox(reason: "trusted_receipt_recovery", allowWakeupSync: false) == 1)
            let saved = try #require(try await reopened.loadMessage(messageId: response.messageID))
            #expect(saved.body == response.body && saved.providerSourceBaseURL == original.absoluteString)
            #expect(saved.rawPayload["provider_device_key"]?.value as? String == originalDevice)
            #expect(try server.requests().isEmpty)
            await context.coordinator.drainAckMarkers(source: "test.original_receipt_after_store")
            let requests = try server.requests()
            #expect(requests.count == 1)
            let ack = try #require(requests.first)
            #expect(ack.path == "/original" + ChannelSubscriptionService.batchAckV2Path)
            #expect(ack.deviceKey == originalDevice && ack.deliveryIDs == [response.deliveryID] && ack.authorizationMatches)
            await server.stopAndWait()
        }
    }

    @Test
    func deletedProcessedReplayUsesIdempotentV2AckWithoutRenewingFact() async throws {
        try await withFullDirectStore { store, group in
            let server = try FullDirectHTTPFixture()
            defer { server.stop() }
            var response = FullDirectHTTPFixture.Configuration()
            response.ackStatus = 503
            try server.configure(response)
            let config = ServerConfig(baseURL: server.url("current"), token: response.tokens["current"])
            try await prepareFullDirectContext(store, config: config, device: response.devices["current"]!)
            let context = FullDirectContext(store: store, group: group, config: config, device: response.devices["current"]!)
            defer { context.close() }
            let hint = fullDirectAdvertisement(response, base: config.baseURL, device: response.devices["current"]!)
            #expect(await context.inbox.enqueue(codablePayload: UserInfoSanitizer.sanitize(hint).mapValues(AnyCodable.init), requestIdentifier: response.deliveryID, source: "test.synthetic_raw_apns"))
            #expect(await context.coordinator.mergeInbox(reason: "delete_replay_seed", allowWakeupSync: true) == 1)
            let saved = try #require(try await store.loadMessage(messageId: response.messageID))
            let identity = try #require(ProviderDeliveryAckFailureStore.DeliveryIdentity(
                deliveryId: response.deliveryID, baseURL: config.baseURL, deviceKey: response.devices["current"]!, ackContract: .v2Batch))
            let firstTimestamp = try await fullDirectProcessedTimestamp(group: group, identity: identity)
            await context.coordinator.drainAckMarkers(source: "test.unconfirmed_first_ack")
            #expect(try server.requests().filter { $0.path.hasSuffix(ChannelSubscriptionService.batchAckV2Path) }.count == 1)
            try await store.deleteMessage(id: saved.id)
            #expect(try await store.loadMessage(messageId: response.messageID) == nil)

            response.pullStatus["current"] = 503
            response.ackStatus = 200
            response.ackRemoved = 0 // Explicit server-side prior completion fixture.
            try server.configure(response)
            let resolution = await NotificationHandling.resolveNotificationIngress(from: hint, dataStore: store,
                fallbackServerConfig: config, channelSubscriptionService: context.service, notificationIngressInbox: context.inbox)
            guard case let .processedDuplicate(payload) = resolution else {
                Issue.record("An exact processed fact must not reacquire or reconstruct advertised content")
                return
            }
            #expect(await context.coordinator.ackProcessedDeliveryIfNeeded(payload: payload, source: "test.processed_duplicate"))
            await context.coordinator.drainAckMarkers(source: "test.idempotent_confirm", now: Date().addingTimeInterval(120))
            #expect(try await store.loadMessage(messageId: response.messageID) == nil)
            #expect(try await fullDirectProcessedTimestamp(group: group, identity: identity) == firstTimestamp)
            let requests = try server.requests()
            #expect(requests.filter { $0.path.hasSuffix(ChannelSubscriptionService.pullV2Path) }.count == 1)
            #expect(requests.filter { $0.path.hasSuffix(ChannelSubscriptionService.batchAckV2Path) }.count == 2)
            #expect(requests.allSatisfy { $0.authorizationMatches })
            #expect(await context.ackStore.pendingMarkers(minimumAge: 0, now: Date().addingTimeInterval(120)).isEmpty)
            await server.stopAndWait()
        }
    }

    @Test
    func rawLegacyMarkerCannotManufactureTrustedContentOrAck() async throws {
        try await withFullDirectStore { store, group in
            let server = try FullDirectHTTPFixture()
            defer { server.stop() }
            var response = FullDirectHTTPFixture.Configuration()
            response.pullStatus["current"] = 503
            try server.configure(response)
            let config = ServerConfig(baseURL: server.url("current"), token: response.tokens["current"])
            try await prepareFullDirectContext(store, config: config, device: response.devices["current"]!)
            let context = FullDirectContext(store: store, group: group, config: config, device: response.devices["current"]!)
            defer { context.close() }
            var hint = fullDirectAdvertisement(response, base: config.baseURL, device: response.devices["current"]!)
            hint[ProviderLegacyDestructivePullMetadata.markerKey] = ProviderLegacyDestructivePullMetadata.markerValue
            // Deliberately inject old raw data without a typed acquired receipt.
            #expect(await context.inbox.enqueue(codablePayload: UserInfoSanitizer.sanitize(hint).mapValues(AnyCodable.init), requestIdentifier: response.deliveryID, source: "test.synthetic_old_raw_legacy_marker"))
            #expect(await context.coordinator.mergeInbox(reason: "raw_marker_not_proof", allowWakeupSync: true) == 0)
            #expect(try await store.loadMessages().isEmpty)
            #expect(await context.ackStore.pendingMarkers(minimumAge: 0).isEmpty)
            let identity = try #require(ProviderDeliveryAckFailureStore.DeliveryIdentity(
                deliveryId: response.deliveryID, baseURL: config.baseURL, deviceKey: response.devices["current"]!, ackContract: .v2Batch))
            #expect(await context.inbox.durablePayload(identity: identity) == nil)
            #expect((await context.inbox.queueCounts(importLegacyState: false)).outstanding == 1)
            let requests = try server.requests()
            #expect(!requests.isEmpty && requests.allSatisfy { $0.path.hasSuffix(ChannelSubscriptionService.pullV2Path) && $0.authorizationMatches })
            await server.stopAndWait()
        }
    }

    @Test
    func unprovenLegacyAckIsDeferredWithoutBlockingProcessedPeer() async throws {
        try await withFullDirectStore { store, group in
            let server = try FullDirectHTTPFixture()
            defer { server.stop() }
            let response = FullDirectHTTPFixture.Configuration()
            try server.configure(response)
            let config = ServerConfig(baseURL: server.url("current"), token: response.tokens["current"])
            let device = response.devices["current"]!
            try await prepareFullDirectContext(store, config: config, device: device)
            let context = FullDirectContext(store: store, group: group, config: config, device: device)
            defer { context.close() }
            let rawID = "unproven-old-nse-" + UUID().uuidString.lowercased()
            var raw = fullDirectAdvertisement(response, base: config.baseURL, device: device)
            raw["delivery_id"] = rawID
            raw["message_id"] = UUID().uuidString.lowercased()
            raw["entity_id"] = raw["message_id"]
            raw["op_id"] = UUID().uuidString.lowercased()
            #expect(await context.inbox.enqueue(codablePayload: UserInfoSanitizer.sanitize(raw).mapValues(AnyCodable.init), requestIdentifier: rawID, source: "test.synthetic_old_nse_raw"))
            let rawIdentity = try #require(ProviderDeliveryAckFailureStore.DeliveryIdentity(
                deliveryId: rawID, baseURL: config.baseURL, deviceKey: device, ackContract: .legacySingle))
            #expect(await context.ackStore.markInboxDurable(identity: rawIdentity, source: "test.synthetic_old_nse_ack", postNotification: false))

            // Independently accepted historical content is seeded through the
            // actual production persistence module, not a fabricated ACK proof.
            var accepted = response.payload
            accepted["base_url"] = config.baseURL.absoluteString
            accepted["provider_device_key"] = device
            accepted["delivery_id"] = response.deliveryID
            let outcomes = await NotificationPersistenceCoordinator.persistRemotePayloadsIfNeeded(
                [.init(payload: accepted.reduce(into: [AnyHashable: Any]()) { $0[$1.key] = $1.value }, requestIdentifier: response.deliveryID)],
                dataStore: store)
            try #require(outcomes.count == 1)
            guard case .persistedMain = outcomes[0] else { Issue.record("Healthy fixture must really commit canonical content"); return }
            let savedBefore = try #require(try await store.loadMessage(messageId: response.messageID))
            let healthyIdentity = try #require(ProviderDeliveryAckFailureStore.DeliveryIdentity(
                deliveryId: response.deliveryID, baseURL: config.baseURL, deviceKey: device, ackContract: .legacySingle))
            #expect(await context.ackStore.markInboxDurable(identity: healthyIdentity, source: "test.synthetic_accepted_legacy_ack", postNotification: false))
            #expect(try await NotificationHandling.hasProcessedProviderHint(raw, dataStore: store, notificationIngressInbox: context.inbox) == false)
            #expect(try await NotificationHandling.hasProcessedProviderHint(
                accepted.reduce(into: [AnyHashable: Any]()) { $0[$1.key] = $1.value },
                dataStore: store, notificationIngressInbox: context.inbox))

            // Deterministically put the unsupported marker first. These two
            // timestamps are an explicitly synthetic old-outbox ordering state;
            // no sleep, production retry policy or business timestamp changes.
            let journal = DurableIngressJournal(appGroupIdentifier: group)
            _ = await journal.durabilityPragmas()
            let journalURL = try #require(await journal.databaseURL)
            let database = try DatabaseQueue(path: journalURL.path)
            let before = Int64(Date().timeIntervalSince1970 * 1_000) - 2_000
            try await database.write { db in
                try db.execute(sql: "UPDATE ack_outbox SET created_at_ms = ?, next_attempt_at_ms = ? WHERE ack_id = ?;",
                    arguments: [before, before, rawIdentity.storageKey])
                try db.execute(sql: "UPDATE ack_outbox SET created_at_ms = ?, next_attempt_at_ms = ? WHERE ack_id = ?;",
                    arguments: [before + 1_000, before + 1_000, healthyIdentity.storageKey])
            }
            let markersBefore = await context.ackStore.pendingMarkers(minimumAge: 0)
            #expect(markersBefore.map(\.record.deliveryId) == [rawID, response.deliveryID])
            let rawBefore = try #require(markersBefore.first)
            let drainStarted = Date()
            await context.coordinator.drainAckMarkers(source: "test.mixed_legacy_origin_gate")

            let requests = try server.requests()
            #expect(requests.count == 1)
            let ack = try #require(requests.first)
            #expect(ack.path == "/current" + ChannelSubscriptionService.ackPath)
            #expect(ack.deliveryID == response.deliveryID && ack.deviceKey == device && ack.authorizationMatches)
            #expect(await context.ackStore.pendingMarkers(minimumAge: 0).isEmpty)
            let retained = await context.ackStore.pendingMarkers(minimumAge: 0, now: drainStarted.addingTimeInterval(120))
            try #require(retained.count == 1)
            let blocked = try #require(retained.first)
            #expect(blocked.record.deliveryId == rawID && blocked.record.createdAtEpochMs == rawBefore.record.createdAtEpochMs)
            #expect((blocked.record.retryAfterEpochMs ?? 0) >= Int64(drainStarted.timeIntervalSince1970 * 1_000) + 60_000)
            #expect(blocked.record.source.contains("unproven_direct_origin"))
            let retainedRaw = try #require(await context.inbox.durablePayload(identity: rawIdentity))
            #expect(retainedRaw["body"]?.value as? String == raw["body"] as? String)
            let savedAfter = try #require(try await store.loadMessage(messageId: response.messageID))
            #expect(savedAfter.id == savedBefore.id && savedAfter.body == savedBefore.body && savedAfter.receivedAt == savedBefore.receivedAt)
            #expect(try await store.loadMessages().count == 1)
            #expect((await context.inbox.queueCounts(importLegacyState: false)).outstanding == 1)
            await server.stopAndWait()
        }
    }

    @Test
    func genericOriginStoreReadFailureStopsAckTurnAndRetainsBothResponsibilities() async throws {
        try await withFullDirectStore { store, group in
            let server = try FullDirectHTTPFixture()
            defer { server.stop() }
            let response = FullDirectHTTPFixture.Configuration()
            try server.configure(response)
            let config = ServerConfig(baseURL: server.url("current"), token: response.tokens["current"])
            let device = response.devices["current"]!
            try await prepareFullDirectContext(store, config: config, device: device)
            let context = FullDirectContext(store: store, group: group, config: config, device: device)
            defer { context.close() }
            let rawID = "unproven-broken-store-" + UUID().uuidString.lowercased()
            var raw = fullDirectAdvertisement(response, base: config.baseURL, device: device)
            raw["delivery_id"] = rawID
            raw["message_id"] = UUID().uuidString.lowercased()
            raw["entity_id"] = raw["message_id"]
            raw["op_id"] = UUID().uuidString.lowercased()
            #expect(await context.inbox.enqueue(codablePayload: UserInfoSanitizer.sanitize(raw).mapValues(AnyCodable.init), requestIdentifier: rawID, source: "test.synthetic_old_nse_raw"))
            let rawIdentity = try #require(ProviderDeliveryAckFailureStore.DeliveryIdentity(
                deliveryId: rawID, baseURL: config.baseURL, deviceKey: device, ackContract: .legacySingle))
            #expect(await context.ackStore.markInboxDurable(identity: rawIdentity, source: "test.synthetic_old_nse_ack", postNotification: false))
            var accepted = response.payload
            accepted["base_url"] = config.baseURL.absoluteString
            accepted["provider_device_key"] = device
            accepted["delivery_id"] = response.deliveryID
            let outcomes = await NotificationPersistenceCoordinator.persistRemotePayloadsIfNeeded(
                [.init(payload: accepted.reduce(into: [AnyHashable: Any]()) { $0[$1.key] = $1.value }, requestIdentifier: response.deliveryID)],
                dataStore: store)
            try #require(outcomes.count == 1)
            guard case .persistedMain = outcomes[0] else { Issue.record("Healthy fixture must really commit before injecting the read failure"); return }
            let savedBefore = try #require(try await store.loadMessage(messageId: response.messageID))
            let healthyIdentity = try #require(ProviderDeliveryAckFailureStore.DeliveryIdentity(
                deliveryId: response.deliveryID, baseURL: config.baseURL, deviceKey: device, ackContract: .legacySingle))
            #expect(await context.ackStore.markInboxDurable(identity: healthyIdentity, source: "test.synthetic_accepted_legacy_ack", postNotification: false))

            let journal = DurableIngressJournal(appGroupIdentifier: group)
            _ = await journal.durabilityPragmas()
            let journalURL = try #require(await journal.databaseURL)
            let queue = try DatabaseQueue(path: journalURL.path)
            let before = Int64(Date().timeIntervalSince1970 * 1_000) - 2_000
            try await queue.write { db in
                try db.execute(sql: "UPDATE ack_outbox SET created_at_ms = ?, next_attempt_at_ms = ? WHERE ack_id = ?;",
                    arguments: [before, before, rawIdentity.storageKey])
                try db.execute(sql: "UPDATE ack_outbox SET created_at_ms = ?, next_attempt_at_ms = ? WHERE ack_id = ?;",
                    arguments: [before + 1_000, before + 1_000, healthyIdentity.storageKey])
            }
            let markersBefore = await context.ackStore.pendingMarkers(minimumAge: 0)
            #expect(markersBefore.map(\.record.deliveryId) == [rawID, response.deliveryID])

            // Explicit corruption injection in this disposable canonical Store
            // only. It must be a thrown database read error, not "not found".
            let storeURL = try AppConstants.appLocalDatabaseDirectory(appGroupIdentifier: group)
                .appendingPathComponent(AppConstants.databaseStoreFilename)
            let brokenStore = try DatabaseQueue(path: storeURL.path)
            try await brokenStore.write { db in try db.execute(sql: "DROP TABLE operation_ledger;") }
            var observedReadFailure = false
            do {
                _ = try await NotificationHandling.hasProcessedProviderHint(raw, dataStore: store, notificationIngressInbox: context.inbox)
            } catch {
                observedReadFailure = true
                #expect(String(describing: error).contains("no such table: operation_ledger"))
            }
            try #require(observedReadFailure)
            await context.coordinator.drainAckMarkers(source: "test.generic_origin_read_failure")
            #expect(try server.requests().isEmpty)
            let due = await context.ackStore.pendingMarkers(minimumAge: 0)
            #expect(due.map(\.record.deliveryId) == [response.deliveryID])
            let retained = await context.ackStore.pendingMarkers(minimumAge: 0, now: Date().addingTimeInterval(120))
            #expect(Set(retained.map(\.record.deliveryId)) == [rawID, response.deliveryID])
            let failed = try #require(retained.first { $0.record.deliveryId == rawID })
            let untouched = try #require(retained.first { $0.record.deliveryId == response.deliveryID })
            #expect(failed.record.source.contains("origin_store_failed") && failed.attemptCount == 1)
            #expect(untouched.attemptCount == 0)
            #expect(failed.record.createdAtEpochMs == markersBefore.first?.record.createdAtEpochMs)
            let savedAfter = try #require(try await store.loadMessage(messageId: response.messageID))
            #expect(savedAfter.body == savedBefore.body && savedAfter.receivedAt == savedBefore.receivedAt)
            await server.stopAndWait()
        }
    }
}

@MainActor
private func withFullDirectStore<T: Sendable>(
    _ body: @MainActor @Sendable (LocalDataStore, String) async throws -> T
) async rethrows -> T {
    try await withIsolatedLocalDataStore { store, group in try await body(store, group) }
}

@MainActor
private func prepareFullDirectContext(_ store: LocalDataStore, config: ServerConfig, device: String) async throws {
    let result = try #require(await store.saveCachedDeviceKey(device, for: "macos"))
    #expect(result.didPersist)
    #expect(ProviderGatewayTokenStore().save(token: config.token, baseURL: config.baseURL))
}

private func fullDirectAdvertisement(_ response: FullDirectHTTPFixture.Configuration, base: URL, device: String) -> [AnyHashable: Any] {
    ["delivery_id": response.deliveryID, "message_id": response.messageID,
     "op_id": response.operationID, "entity_type": "message", "entity_id": response.messageID,
     "title": "Unverified APNs advertisement", "body": "These advertised bytes must never be canonical.",
     "provider_mode": "direct", "base_url": base.absoluteString, "provider_device_key": device]
}

@MainActor
private final class FullDirectContext {
    let inbox: NotificationIngressInbox
    let ackStore: ProviderDeliveryAckFailureStore
    let service: ChannelSubscriptionService
    let coordinator: ProviderIngressCoordinator
    private let session: URLSession

    init(store: LocalDataStore, group: String, config: ServerConfig, device: String) {
        session = URLSession(configuration: .ephemeral)
        service = ChannelSubscriptionService(session: session)
        inbox = NotificationIngressInbox(appGroupIdentifier: group)
        ackStore = ProviderDeliveryAckFailureStore(appGroupIdentifier: group)
        coordinator = ProviderIngressCoordinator(platformSuffix: "macos", dataStore: store,
            channelSubscriptionService: service, notificationIngressInbox: inbox, ackMarkerStore: ackStore,
            wakeupPullClaimStore: ProviderWakeupPullClaimStore(appGroupIdentifier: group), ackMarkerMinimumAge: 0,
            hooks: .init(isEnabled: { true }, serverConfig: { config }, cachedDeviceKey: { device },
                hasPersistedNotification: { _ in false }, persistPayloads: { inputs in
                    await NotificationPersistenceCoordinator.persistRemotePayloadsIfNeeded(
                        inputs.map { .init(payload: $0.payload, requestIdentifier: $0.requestIdentifier) }, dataStore: store
                    ).map(ProviderIngressPersistenceResult.init)
                }, applyPersistenceResults: { _ in }, reportInboxProgress: { _ in }, recordProviderError: { _, _ in }))
    }

    func close() { session.invalidateAndCancel() }
}

private func fullDirectProcessedTimestamp(group: String, identity: ProviderDeliveryAckFailureStore.DeliveryIdentity) async throws -> Int64 {
    let journal = DurableIngressJournal(appGroupIdentifier: group)
    _ = await journal.durabilityPragmas()
    let url = try #require(await journal.databaseURL)
    var configuration = Configuration()
    configuration.readonly = true
    let database = try DatabaseQueue(path: url.path, configuration: configuration)
    return try await database.read { db in
        try #require(try Int64.fetchOne(db, sql: """
            SELECT canonical_applied_at_ms FROM ingress_entry
            WHERE source_base_url = ? AND source_device_key = ? AND delivery_id = ?
              AND resolution_state = 'pulled' AND apply_state = 'applied' LIMIT 1;
            """, arguments: [identity.baseURLString, identity.deviceKey, identity.deliveryId]))
    }
}

/// Small real loopback HTTP fixture, using the same atomic readiness and child
/// termination pattern as ImageHTTPFixture. No URLProtocol/requestTransport.
private final class FullDirectHTTPFixture: @unchecked Sendable {
    struct Configuration: Codable, Sendable {
        var deliveryID = "delivery-" + UUID().uuidString.lowercased()
        var messageID = UUID().uuidString.lowercased()
        var operationID = UUID().uuidString.lowercased()
        var title = "Authenticated V2 content"
        var body = "Only bytes acquired through the targeted V2 response are saved."
        var sentAt = "1800000000000"
        var tokens = ["current": "synthetic-current-context", "original": "synthetic-original-context"]
        var devices = ["current": "local-current-device", "original": "frozen-original-device"]
        var pullStatus = ["current": 200, "original": 200]
        var ackStatus = 200
        var ackRemoved = 1
        var payload: [String: String] {
            ["message_id": messageID, "op_id": operationID, "channel_id": "synthetic-channel",
             "entity_type": "message", "entity_id": messageID, "title": title, "body": body,
             "sent_at": sentAt, "severity": "normal"]
        }
    }
    struct Request: Decodable {
        let path: String
        let authorizationMatches: Bool
        let hasAuthorization: Bool
        let deviceKey: String?
        let deliveryID: String?
        let deliveryIDs: [String]?
    }
    struct FixtureUnavailable: Error {}
    let root: URL
    private let process: Process
    private let port: Int
    private let termination = FullDirectFixtureTermination()

    init() throws {
        let evidence = ProcessInfo.processInfo.environment["PUSHGO_HTTP_TEST_EVIDENCE_ROOT"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) } ?? FileManager.default.temporaryDirectory
        root = evidence.appendingPathComponent("pushgo-provider-hint-http-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONEncoder().encode(Configuration()).write(to: root.appendingPathComponent("configuration.json"), options: .atomic)
        let script = root.appendingPathComponent("server.py")
        try Data(Self.python.utf8).write(to: script)
        process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [script.path, root.path]
        process.standardOutput = FileHandle.nullDevice
        let errorLog = root.appendingPathComponent("server-error.log")
        _ = FileManager.default.createFile(atPath: errorLog.path, contents: nil)
        process.standardError = try FileHandle(forWritingTo: errorLog)
        let completion = termination
        process.terminationHandler = { _ in completion.finish() }
        try process.run()
        let deadline = Date().addingTimeInterval(5)
        var readyPort: Int?
        while process.isRunning, Date() < deadline {
            if let raw = try? String(contentsOf: root.appendingPathComponent("port"), encoding: .utf8),
               let value = Int(raw), (1...65_535).contains(value) { readyPort = value; break }
            Thread.sleep(forTimeInterval: 0.002)
        }
        guard process.isRunning, let readyPort else {
            if process.isRunning { process.terminate() }
            throw FixtureUnavailable()
        }
        port = readyPort
    }

    deinit { stop() }
    func stop() { if process.isRunning { process.terminate() } }
    func stopAndWait() async { stop(); await termination.wait() }
    func url(_ scope: String) -> URL { URL(string: "http://127.0.0.1:\(port)/\(scope)")! }
    func configure(_ configuration: Configuration) throws {
        try JSONEncoder().encode(configuration).write(to: root.appendingPathComponent("configuration.json"), options: .atomic)
    }
    func requests() throws -> [Request] {
        guard FileManager.default.fileExists(atPath: root.appendingPathComponent("requests.json").path) else { return [] }
        return try JSONDecoder().decode([Request].self, from: Data(contentsOf: root.appendingPathComponent("requests.json")))
    }

    private static let python = #"""
import json, pathlib, sys, threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
root = pathlib.Path(sys.argv[1])
lock = threading.Lock()
requests = []
class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def do_POST(self):
        length = int(self.headers.get('Content-Length', '0'))
        if length < 0 or length > 65536:
            self.send_error(413); return
        body = json.loads(self.rfile.read(length))
        with lock:
            config = json.loads((root / 'configuration.json').read_text())
            scope = self.path.split('/')[1]
            expected = config['tokens'].get(scope)
            authorization = self.headers.get('Authorization')
            matches = authorization == ('Bearer ' + expected if expected is not None else None)
            requests.append({'path': self.path, 'authorizationMatches': matches,
                'hasAuthorization': authorization is not None, 'deviceKey': body.get('device_key'),
                'deliveryID': body.get('delivery_id'), 'deliveryIDs': body.get('delivery_ids')})
            temporary = root / 'requests.pending'
            temporary.write_text(json.dumps(requests))
            temporary.replace(root / 'requests.json')
            if len(requests) > 64 or not matches:
                status, result = 401, {'success': False, 'error_code': 'unauthorized'}
            elif self.path.endswith('/v2/messages/pull'):
                status = config['pullStatus'].get(scope, 401)
                valid_device = scope not in config['devices'] or body.get('device_key') == config['devices'][scope]
                if status == 200 and (not valid_device or body.get('delivery_id') != config['deliveryID']):
                    status = 400
                if status == 200:
                    payload = {'message_id': config['messageID'], 'op_id': config['operationID'],
                        'channel_id': 'synthetic-channel', 'entity_type': 'message', 'entity_id': config['messageID'],
                        'title': config['title'], 'body': config['body'], 'sent_at': config['sentAt'], 'severity': 'normal'}
                    result = {'success': True, 'data': {'items': [{'delivery_id': config['deliveryID'], 'payload': payload}],
                        'has_more': False, 'next_page_token': None, 'scan_complete': True}}
                else:
                    result = {'success': False, 'error_code': 'synthetic_unavailable'}
            elif self.path.endswith('/v2/messages/ack'):
                status = config['ackStatus']
                if body.get('device_key') != config['devices'].get(scope) or body.get('delivery_ids') != [config['deliveryID']]:
                    status = 400
                result = ({'success': True, 'data': {'requested_count': 1, 'removed_count': config['ackRemoved']}}
                    if status == 200 else {'success': False, 'error_code': 'synthetic_ack_unconfirmed'})
            elif self.path.endswith('/messages/ack'):
                status = config['ackStatus']
                if body.get('device_key') != config['devices'].get(scope) or body.get('delivery_id') != config['deliveryID']:
                    status = 400
                result = ({'success': True, 'data': {'removed': config['ackRemoved'] == 1}}
                    if status == 200 else {'success': False, 'error_code': 'synthetic_ack_unconfirmed'})
            else:
                status, result = 404, {'success': False, 'error_code': 'route_not_found'}
        encoded = json.dumps(result).encode()
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(encoded)))
        self.end_headers()
        self.wfile.write(encoded)
server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
server.daemon_threads = True
pending = root / 'port.pending'
pending.write_text(str(server.server_port))
pending.replace(root / 'port')
server.serve_forever()
"""#
}

private final class FullDirectFixtureTermination: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func finish() {
        lock.lock()
        finished = true
        let pending = waiters
        waiters.removeAll()
        lock.unlock()
        for waiter in pending { waiter.resume() }
    }
    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if finished { lock.unlock(); continuation.resume() }
            else { waiters.append(continuation); lock.unlock() }
        }
    }
}
