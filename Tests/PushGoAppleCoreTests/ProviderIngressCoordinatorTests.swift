import Foundation
import os
import Testing
@testable import PushGoAppleCore

@MainActor
private func withProviderIngressLocalDataStore<T: Sendable>(
    _ body: @MainActor @Sendable (LocalDataStore, String) async throws -> T
) async rethrows -> T {
    try await withIsolatedLocalDataStore { store, appGroupIdentifier in
        try await body(store, appGroupIdentifier)
    }
}

private actor ProviderIngressCapture {
    private var results: [ProviderIngressPersistenceResult]
    private let pausesFirstBatch: Bool
    private var firstBatchContinuation: CheckedContinuation<Void, Never>?
    private var firstBatchWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var deliveryIds: [String] = []
    private(set) var payloadDeliveryIds: [String?] = []
    private(set) var batchSizes: [Int] = []
    private(set) var errors: [String] = []

    init(results: [ProviderIngressPersistenceResult], pausesFirstBatch: Bool = false) {
        self.results = results
        self.pausesFirstBatch = pausesFirstBatch
    }

    func persist(
        inputs: [ProviderIngressCoordinator.PersistenceInput]
    ) async -> [ProviderIngressPersistenceResult] {
        batchSizes.append(inputs.count)
        if pausesFirstBatch, batchSizes.count == 1 {
            let waiters = firstBatchWaiters
            firstBatchWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
            await withCheckedContinuation { firstBatchContinuation = $0 }
        }
        return inputs.map { input in
            deliveryIds.append(input.requestIdentifier ?? "")
            payloadDeliveryIds.append(input.payload["delivery_id"] as? String)
            return results.isEmpty ? .persisted : results.removeFirst()
        }
    }

    func waitUntilFirstBatchStarts() async {
        if !batchSizes.isEmpty { return }
        await withCheckedContinuation { firstBatchWaiters.append($0) }
    }

    func releaseFirstBatch() {
        firstBatchContinuation?.resume()
        firstBatchContinuation = nil
    }

    func record(error: Error, source: String) {
        errors.append("\(source):\(error)")
    }
}

@MainActor
private final class ProviderInboxProgressCapture {
    private(set) var events: [ProviderInboxProgress] = []

    func record(_ progress: ProviderInboxProgress) {
        events.append(progress)
    }
}

private actor ProviderIngressCancellationBarrier {
    private var started = false
    private var workContinuation: CheckedContinuation<Void, Never>?
    private var startWaiters: [CheckedContinuation<Void, Never>] = []

    func pause() async {
        started = true
        let waiters = startWaiters
        startWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        await withCheckedContinuation { workContinuation = $0 }
    }

    func waitUntilPaused() async {
        if started { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func release() {
        workContinuation?.resume()
        workContinuation = nil
    }
}

private final class ProviderIngressHTTPState: Sendable {
    private struct State: Sendable {
        var pullPayloads: [String]
        var ackFailuresRemaining: Int
        var ackRemovedCounts: [Int]
        var paths: [String] = []
        var requestBodies: [Data] = []
        var authorizationHeaders: [String] = []
    }

    private let state: OSAllocatedUnfairLock<State>
    private let v2RouteNotFound: Bool

    init(
        pullPayloads: [String],
        ackFailuresRemaining: Int = 0,
        ackRemovedCounts: [Int] = [],
        v2RouteNotFound: Bool = false
    ) {
        state = OSAllocatedUnfairLock(initialState: State(
            pullPayloads: pullPayloads,
            ackFailuresRemaining: ackFailuresRemaining,
            ackRemovedCounts: ackRemovedCounts
        ))
        self.v2RouteNotFound = v2RouteNotFound
    }

    func handle(_ request: URLRequest) throws -> (HTTPURLResponse, Data) {
        try state.withLock { state in
            let path = request.url?.path ?? ""
            let bodyData = ChannelServiceURLProtocol.bodyData(from: request) ?? Data()
            state.paths.append(path)
            state.requestBodies.append(bodyData)
            state.authorizationHeaders.append(request.value(forHTTPHeaderField: "Authorization") ?? "")
            if path.hasSuffix("/v2/messages/pull") {
                if v2RouteNotFound {
                    let payload = #"{"success":false,"error_code":"route_not_found","problem":{"code":"route_not_found","category":"not_found","status":404,"title":"Not found","retryable":false}}"#
                    return (response(for: request, status: 404), Data(payload.utf8))
                }
                guard !state.pullPayloads.isEmpty else { throw URLError(.resourceUnavailable) }
                let payload = state.pullPayloads.removeFirst()
                return (response(for: request, status: 200), Data(payload.utf8))
            }
            if path.hasSuffix("/v2/messages/ack") {
                if state.ackFailuresRemaining > 0 {
                    state.ackFailuresRemaining -= 1
                    throw URLError(.networkConnectionLost)
                }
                let object = (try? JSONSerialization.jsonObject(with: bodyData)) as? [String: Any]
                let count = (object?["delivery_ids"] as? [String])?.count ?? 0
                let removedCount = state.ackRemovedCounts.isEmpty ? count : state.ackRemovedCounts.removeFirst()
                let payload = """
                {"success":true,"data":{"removed":\(removedCount > 0),"requested_count":\(count),"removed_count":\(removedCount)}}
                """
                return (response(for: request, status: 200), Data(payload.utf8))
            }
            if path.hasSuffix("/messages/ack") {
                let payload = #"{"success":true,"data":{"removed":true,"requested_count":1,"removed_count":1}}"#
                return (response(for: request, status: 200), Data(payload.utf8))
            }
            if path.hasSuffix("/messages/pull") {
                guard !state.pullPayloads.isEmpty else { throw URLError(.resourceUnavailable) }
                let payload = state.pullPayloads.removeFirst()
                return (response(for: request, status: 200), Data(payload.utf8))
            }
            throw URLError(.unsupportedURL)
        }
    }

    func recordedPaths() -> [String] {
        state.withLock { $0.paths }
    }

    func recordedDeviceKeys() -> [String] {
        state.withLock { state in
            state.requestBodies.compactMap { data in
                let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                return object?["device_key"] as? String
            }
        }
    }

    func recordedAuthorizationHeaders() -> [String] {
        state.withLock { $0.authorizationHeaders }
    }

    private func response(for request: URLRequest, status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
    }
}

@MainActor
struct ProviderIngressCoordinatorTests {
    @Test
    func pendingThingChildrenKeepIngressSuccessAndAckDestinationThroughParentReplay() async throws {
        @MainActor final class GatewayConfiguration {
            var baseURL: URL
            var deviceKey = "original-device"
            init(baseURL: URL) { self.baseURL = baseURL }
        }
        try await withProviderIngressLocalDataStore { store, appGroupIdentifier in
            let host = "provider-thing-children-\(UUID().uuidString.lowercased()).example"
            let baseURL = try #require(URL(string: "https://\(host)/OriginalGateway"))
            let gateway = GatewayConfiguration(baseURL: baseURL)
            var persistedKinds: [String] = []
            var appliedCount = 0
            var providerErrors: [String] = []
            let httpState = ProviderIngressHTTPState(pullPayloads: [])
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [ChannelServiceURLProtocol.self]
            let session = URLSession(configuration: configuration)
            ChannelServiceURLProtocol.register(host: host) { request in
                try httpState.handle(request)
            }
            defer {
                session.invalidateAndCancel()
                ChannelServiceURLProtocol.unregister(host: host)
            }

            let inbox = NotificationIngressInbox(appGroupIdentifier: appGroupIdentifier)
            let ackStore = ProviderDeliveryAckFailureStore(appGroupIdentifier: appGroupIdentifier)
            let coordinator = ProviderIngressCoordinator(
                platformSuffix: "test",
                dataStore: store,
                channelSubscriptionService: ChannelSubscriptionService(session: session),
                notificationIngressInbox: inbox,
                ackMarkerStore: ackStore,
                wakeupPullClaimStore: ProviderWakeupPullClaimStore(appGroupIdentifier: appGroupIdentifier),
                hooks: .init(
                    isEnabled: { true },
                    serverConfig: { ServerConfig(baseURL: gateway.baseURL, token: "test-token") },
                    cachedDeviceKey: { gateway.deviceKey },
                    hasPersistedNotification: { identity in
                        guard let messageID = identity.messageId,
                              let message = try? await store.loadMessage(messageId: messageID)
                        else { return false }
                        return identity.matchesPersisted(message)
                    },
                    persistPayloads: { inputs in
                        let outcomes = await NotificationPersistenceCoordinator.persistRemotePayloadsIfNeeded(
                            inputs.map { .init(payload: $0.payload, requestIdentifier: $0.requestIdentifier) },
                            dataStore: store
                        )
                        for outcome in outcomes {
                            switch outcome {
                            case .persistedPending: persistedKinds.append("pending")
                            case .persistedMain: persistedKinds.append("main")
                            case .duplicate: persistedKinds.append("duplicate")
                            case .rejected: persistedKinds.append("rejected")
                            case .failed: persistedKinds.append("failed")
                            }
                        }
                        return outcomes.map(ProviderIngressPersistenceResult.init)
                    },
                    applyPersistenceResults: { appliedCount += $0.filter(\.isApplied).count },
                    reportInboxProgress: { _ in },
                    recordProviderError: { error, _ in providerErrors.append(String(describing: error)) }
                )
            )
            for kind in ["message", "event"] {
                let messageID = "ingress-child-\(kind)"
                var payload: [String: String] = [
                    "entity_type": kind,
                    "entity_id": messageID,
                    "message_id": messageID,
                    "delivery_id": "delivery-\(kind)",
                    "thing_id": "ingress-parent",
                    "op_id": "operation-\(kind)",
                    "title": "Exact \(kind) child",
                    "body": "Persisted \(kind) body before parent",
                    "base_url": baseURL.absoluteString,
                    "provider_device_key": "original-device",
                ]
                if kind == "event" { payload["event_id"] = messageID }
                let enqueued = await inbox.enqueue(codablePayload: payload.mapValues(AnyCodable.init), requestIdentifier: "delivery-\(kind)",
                    source: "test.thing-child.host-inbox")
                #expect(enqueued)
            }
            #expect(await coordinator.mergeInbox(reason: "test_pending_children", allowWakeupSync: false) == 2)
            #expect(persistedKinds == ["pending", "pending"])
            #expect(appliedCount == 2)
            #expect(await inbox.pendingEntries().isEmpty)
            #expect(try await store.loadMessage(messageId: "ingress-child-message") == nil)
            #expect(try await store.loadMessage(messageId: "ingress-child-event") == nil)
            let markers = await ackStore.pendingMarkers(limit: 10, minimumAge: 0)
            #expect(Set(markers.map(\.record.deliveryId)) == ["delivery-message", "delivery-event"])
            #expect(markers.allSatisfy {
                $0.identity?.baseURLString == baseURL.absoluteString
                    && $0.identity?.deviceKey == "original-device"
                    && $0.identity?.ackContract == .legacySingle
            })

            gateway.baseURL = try #require(URL(string: "https://\(host)/NewGateway"))
            gateway.deviceKey = "new-device"
            await coordinator.drainAckMarkers(source: "test_pending_children_after_config_change")
            #expect(httpState.recordedPaths() == ["/OriginalGateway/messages/ack", "/OriginalGateway/messages/ack"])
            #expect(httpState.recordedDeviceKeys() == ["original-device", "original-device"])
            #expect(await ackStore.pendingMarkers(limit: 10, minimumAge: 0).isEmpty)

            #expect(await inbox.enqueue(payload: [
                "entity_type": "thing", "entity_id": "ingress-parent", "thing_id": "ingress-parent",
                "message_id": "ingress-parent-message", "title": "Exact ingress parent", "body": "Parent body",
            ], requestIdentifier: "parent-request", source: "test.thing-child.parent"))
            #expect(await coordinator.mergeInbox(reason: "test_parent_replay", allowWakeupSync: false) == 1)
            #expect(persistedKinds == ["pending", "pending", "main"])
            #expect(appliedCount == 3, "Parent replay must not emit additional child ingress results")
            let detail = try await store.loadThingProjectionDetail(thingId: "ingress-parent")
            #expect(detail.head?.title == "Exact ingress parent")
            #expect(Set(detail.messages.compactMap(\.messageId)) == [
                "ingress-parent-message", "ingress-child-message", "ingress-child-event",
            ])
            for kind in ["message", "event"] {
                let child = try #require(try await store.loadMessage(messageId: "ingress-child-\(kind)"))
                #expect(child.title == "Exact \(kind) child")
                #expect(child.body == "Persisted \(kind) body before parent")
                #expect(child.providerSourceBaseURL == baseURL.absoluteString)
                #expect(child.deliveryId == "delivery-\(kind)")
            }
            #expect(await store.drainDerivedWorkForBackgroundRefresh())
            #expect(await ackStore.pendingMarkers(limit: 10, minimumAge: 0).isEmpty)
            #expect(providerErrors.isEmpty)
        }
    }

    @Test
    func v2FullSyncTraversesEmptyCorruptPageAndUsesOuterDeliveryIds() async throws {
        try await withProviderIngressLocalDataStore { store, appGroupIdentifier in
            let host = "provider-pages-\(UUID().uuidString.lowercased()).example"
            let baseURL = try #require(URL(string: "https://\(host)/GatewayA"))
            let httpState = ProviderIngressHTTPState(pullPayloads: [
                #"{"success":true,"data":{"items":[],"has_more":true}}"#,
                #"{"success":true,"data":{"items":[{"delivery_id":"outer-001","payload":{"delivery_id":"inner-wrong","title":"one"}},{"delivery_id":"outer-002","payload":{"title":"two"}}],"has_more":true}}"#,
                #"{"success":true,"data":{"items":[{"delivery_id":"outer-003","payload":{"title":"three"}}],"has_more":false}}"#,
            ])
            let capture = ProviderIngressCapture(results: [.persisted, .duplicate, .persisted])
            let context = makeCoordinatorContext(
                host: host,
                baseURL: baseURL,
                store: store,
                appGroupIdentifier: appGroupIdentifier,
                httpState: httpState,
                capture: capture
            )
            defer { context.cleanup() }

            let outcome = await context.coordinator.syncProviderIngressOutcome(
                reason: "test_manual_pages",
                skipInboxMerge: true
            )

            #expect(outcome.appliedCount == 2)
            #expect(await capture.deliveryIds == ["outer-001", "outer-002", "outer-003"])
            #expect(await capture.payloadDeliveryIds == ["outer-001", "outer-002", "outer-003"])
            #expect(httpState.recordedPaths().filter { $0.hasSuffix("/v2/messages/pull") }.count == 3)
            #expect(httpState.recordedPaths().filter { $0.hasSuffix("/v2/messages/ack") }.count == 2)
        }
    }

    @Test
    func rejectedItemSurvivesAckFailureAndDrainRetriesWithoutPersistedRow() async throws {
        try await withProviderIngressLocalDataStore { store, appGroupIdentifier in
            let host = "provider-rejected-\(UUID().uuidString.lowercased()).example"
            let baseURL = try #require(URL(string: "https://\(host)/GatewayA"))
            let httpState = ProviderIngressHTTPState(
                pullPayloads: [
                    #"{"success":true,"data":{"items":[{"delivery_id":"rejected-001","payload":{"_skip_persist":"1"}}],"has_more":false}}"#,
                ],
                ackFailuresRemaining: 1
            )
            let capture = ProviderIngressCapture(results: [.rejected])
            let context = makeCoordinatorContext(
                host: host,
                baseURL: baseURL,
                store: store,
                appGroupIdentifier: appGroupIdentifier,
                httpState: httpState,
                capture: capture
            )
            defer { context.cleanup() }

            _ = await context.coordinator.syncProviderIngressOutcome(
                reason: "test_rejected",
                skipInboxMerge: true
            )
            let retryTime = Date().addingTimeInterval(31)
            #expect(
                await context.ackStore.pendingMarkers(
                    limit: 10,
                    minimumAge: 0,
                    now: retryTime
                ).count == 1
            )

            await context.coordinator.drainAckMarkers(
                source: "test_rejected_drain",
                now: retryTime
            )
            #expect(await context.ackStore.pendingMarkers(limit: 10, minimumAge: 0).isEmpty)
            #expect(httpState.recordedPaths().filter { $0.hasSuffix("/v2/messages/ack") }.count == 2)
        }
    }

    @Test
    func failedTargetReleasesClaimAndPeerRetryCanPersistAndAck() async throws {
        try await withProviderIngressLocalDataStore { store, appGroupIdentifier in
            let host = "provider-claim-\(UUID().uuidString.lowercased()).example"
            let baseURL = try #require(URL(string: "https://\(host)/GatewayA"))
            let page = #"{"success":true,"data":{"items":[{"delivery_id":"target-001","payload":{"title":"target"}}],"has_more":false}}"#
            let httpState = ProviderIngressHTTPState(pullPayloads: [page, page])
            let capture = ProviderIngressCapture(results: [.failed, .persisted, .duplicate])
            let context = makeCoordinatorContext(
                host: host,
                baseURL: baseURL,
                store: store,
                appGroupIdentifier: appGroupIdentifier,
                httpState: httpState,
                capture: capture
            )
            defer { context.cleanup() }

            let first = await context.coordinator.syncProviderIngressOutcome(
                deliveryId: "target-001",
                reason: "test_claim_first",
                skipInboxMerge: true
            )
            #expect(!first.completedRequest)

            let second = await context.coordinator.syncProviderIngressOutcome(
                deliveryId: "target-001",
                reason: "test_claim_retry",
                skipInboxMerge: true
            )
            #expect(second.completedRequest)
            #expect(second.appliedCount == 1)
            #expect(httpState.recordedPaths().filter { $0.hasSuffix("/v2/messages/pull") }.count == 2)
            #expect(httpState.recordedPaths().filter { $0.hasSuffix("/v2/messages/ack") }.count == 1)
        }
    }

    @Test
    func unsupportedV2GatewayFailsWithoutCanonicalContentOrAckOrDestructivePull() async throws {
        try await withProviderIngressLocalDataStore { store, appGroupIdentifier in
            let host = "provider-legacy-\(UUID().uuidString.lowercased()).example"
            let baseURL = try #require(URL(string: "https://\(host)/GatewayA"))
            let httpState = ProviderIngressHTTPState(
                pullPayloads: [
                    #"{"success":true,"data":{"items":[{"delivery_id":"legacy-outer","payload":{"delivery_id":"legacy-inner","title":"legacy"}}]}}"#,
                ],
                v2RouteNotFound: true
            )
            let capture = ProviderIngressCapture(results: [.persisted])
            let context = makeCoordinatorContext(
                host: host,
                baseURL: baseURL,
                store: store,
                appGroupIdentifier: appGroupIdentifier,
                httpState: httpState,
                capture: capture
            )
            defer { context.cleanup() }

            let outcome = await context.coordinator.syncProviderIngressOutcome(
                reason: "test_legacy",
                skipInboxMerge: true
            )
            #expect(!outcome.completedRequest)
            #expect(outcome.appliedCount == 0)
            #expect(await capture.deliveryIds.isEmpty)
            #expect(await capture.payloadDeliveryIds.isEmpty)
            #expect(await context.ackStore.pendingMarkers(limit: 10, minimumAge: 0).isEmpty)
            #expect(httpState.recordedPaths() == [
                "/GatewayA/v2/messages/pull",
            ])
        }
    }

    @Test
    func alreadyDestructivelyFetchedLegacyPayloadDrainsAcrossFailureAndReopenWithoutNetworkOrAck() async throws {
        try await withProviderIngressLocalDataStore { store, appGroupIdentifier in
            let host = "old-pull-drain-\(UUID().uuidString.lowercased()).example"
            let baseURL = try #require(URL(string: "https://\(host)/GatewayA"))
            let httpState = ProviderIngressHTTPState(pullPayloads: [], v2RouteNotFound: true)
            let capture = ProviderIngressCapture(results: [.failed, .persisted])
            let inbox = NotificationIngressInbox(appGroupIdentifier: appGroupIdentifier)
            #expect(await inbox.enqueue(
                payload: [
                    "message_id": "legacy-recovered-message", "delivery_id": "legacy-recovery-001",
                    "title": "Already fetched content", "body": "Preserve destructive fetch across upgrade",
                    "base_url": baseURL.absoluteString, "provider_device_key": "old-device",
                    ProviderLegacyDestructivePullMetadata.markerKey: ProviderLegacyDestructivePullMetadata.markerValue,
                ],
                requestIdentifier: "legacy-recovery-001", source: "old.release.destructive_pull"
            ))
            let pending = try #require(await inbox.pendingEntries().first)
            let first = makeCoordinatorContext(host: host, baseURL: baseURL, store: store,
                appGroupIdentifier: appGroupIdentifier, httpState: httpState, capture: capture, persistToStore: true)
            #expect(await first.coordinator.mergeInbox(reason: "legacy_drain_failure", allowWakeupSync: false) == 0)
            #expect(try await store.loadMessage(messageId: "legacy-recovered-message") == nil)
            // Make the persisted retry due without waiting on the wall clock.
            await inbox.markRetry(pending, reason: "test_retry_due", retryAfter: .distantPast)
            #expect(await inbox.pendingEntries().count == 1)
            first.cleanup()
            LocalDataStore.releaseSharedResourcesForTesting(storageRootURL: try #require(PushGoAutomationContext.storageRootOverrideURL))
            let reopened = LocalDataStore(appGroupIdentifier: appGroupIdentifier, spotlightIndexer: nil)
            let resumed = makeCoordinatorContext(host: host, baseURL: baseURL, store: reopened,
                appGroupIdentifier: appGroupIdentifier, httpState: httpState, capture: capture, persistToStore: true)
            defer { resumed.cleanup() }
            #expect(await resumed.coordinator.mergeInbox(reason: "legacy_drain_resume", allowWakeupSync: false) == 1)
            #expect(try await reopened.loadMessage(messageId: "legacy-recovered-message")?.title == "Already fetched content")
            #expect(try await reopened.loadMessage(messageId: "legacy-recovered-message")?.body == "Preserve destructive fetch across upgrade")
            #expect(await inbox.pendingEntries().isEmpty)
            #expect(await resumed.ackStore.pendingMarkers(limit: 10, minimumAge: 0).isEmpty)
            #expect(httpState.recordedPaths().isEmpty)
        }
    }

    @Test
    func legacyDirectAckMarkerRetriesThroughSingleItemRoute() async throws {
        try await withProviderIngressLocalDataStore { store, appGroupIdentifier in
            let host = "provider-legacy-ack-\(UUID().uuidString.lowercased()).example"
            let baseURL = try #require(URL(string: "https://\(host)/GatewayA"))
            let httpState = ProviderIngressHTTPState(pullPayloads: [])
            let capture = ProviderIngressCapture(results: [])
            let context = makeCoordinatorContext(
                host: host,
                baseURL: baseURL,
                store: store,
                appGroupIdentifier: appGroupIdentifier,
                httpState: httpState,
                capture: capture
            )
            defer { context.cleanup() }
            let identity = try #require(ProviderDeliveryAckFailureStore.DeliveryIdentity(
                deliveryId: "legacy-direct-001",
                baseURL: baseURL,
                deviceKey: "device-key",
                ackContract: .legacySingle
            ))
            #expect(await context.ackStore.markInboxDurable(
                identity: identity,
                source: "test.legacy.direct",
                postNotification: false
            ))

            await context.coordinator.drainAckMarkers(source: "test_legacy_direct_drain")

            #expect(await context.ackStore.pendingMarkers(limit: 10, minimumAge: 0).isEmpty)
            #expect(httpState.recordedPaths() == ["/GatewayA/messages/ack"])
        }
    }

    @Test
    func directAckUsesPayloadGatewayAndDeviceAcrossCurrentConfigSwitch() async throws {
        try await withProviderIngressLocalDataStore { store, appGroupIdentifier in
            let hostA = "provider-direct-a-\(UUID().uuidString.lowercased()).example"
            let hostB = "provider-direct-b-\(UUID().uuidString.lowercased()).example"
            let baseURLA = try #require(URL(string: "https://\(hostA)/GatewayA"))
            let baseURLB = try #require(URL(string: "https://\(hostB)/GatewayB"))
            let stateA = ProviderIngressHTTPState(pullPayloads: [])
            let stateB = ProviderIngressHTTPState(pullPayloads: [])
            let capture = ProviderIngressCapture(results: [])
            let context = makeCoordinatorContext(
                host: hostB,
                baseURL: baseURLB,
                store: store,
                appGroupIdentifier: appGroupIdentifier,
                httpState: stateB,
                capture: capture
            )
            ChannelServiceURLProtocol.register(host: hostA) { request in
                try stateA.handle(request)
            }
            defer {
                context.cleanup()
                ChannelServiceURLProtocol.unregister(host: hostA)
            }
            #expect(ProviderGatewayTokenStore().save(token: "token-a", baseURL: baseURLA))
            #expect(ProviderGatewayTokenStore().save(token: "token", baseURL: baseURLB))

            await context.coordinator.ackDirectDeliveryIfNeeded(
                payload: [
                    "delivery_id": "same-direct-id",
                    "base_url": baseURLA.absoluteString,
                    "provider_device_key": "device-a",
                ],
                result: .persisted,
                source: "test.direct.a"
            )
            await context.coordinator.ackDirectDeliveryIfNeeded(
                payload: [
                    "delivery_id": "same-direct-id",
                    "base_url": baseURLB.absoluteString,
                    "provider_device_key": "device-b",
                ],
                result: .persisted,
                source: "test.direct.b"
            )
            await context.coordinator.drainAckMarkers(source: "test.direct.drain")

            #expect(stateA.recordedPaths() == ["/GatewayA/messages/ack"])
            #expect(stateB.recordedPaths() == ["/GatewayB/messages/ack"])
            #expect(stateA.recordedDeviceKeys() == ["device-a"])
            #expect(stateB.recordedDeviceKeys() == ["device-b"])
            #expect(stateA.recordedAuthorizationHeaders() == ["Bearer token-a"])
            #expect(stateB.recordedAuthorizationHeaders() == ["Bearer token"])
            #expect(await context.ackStore.pendingMarkers(limit: 10, minimumAge: 0).isEmpty)
        }
    }

    @Test
    func deletedDirectReplayStillDrainsAckToItsOriginalGatewayWithoutRestoringContent() async throws {
        try await withProviderIngressLocalDataStore { store, appGroupIdentifier in
            let host = "deleted-direct-\(UUID().uuidString.lowercased()).example"
            let baseURL = try #require(URL(string: "https://\(host)/OriginalGateway"))
            let httpState = ProviderIngressHTTPState(pullPayloads: [])
            let context = makeCoordinatorContext(host: host, baseURL: baseURL, store: store,
                appGroupIdentifier: appGroupIdentifier, httpState: httpState,
                capture: ProviderIngressCapture(results: []), persistToStore: true)
            defer { context.cleanup() }
            let payload: [AnyHashable: Any] = [
                "entity_type": "message", "entity_id": "deleted-direct-message",
                "message_id": "deleted-direct-message", "delivery_id": "deleted-direct-delivery",
                "op_id": "deleted-direct-operation", "channel_id": "lifecycle",
                "title": "Exact deleted title", "body": "Exact deleted body",
                "base_url": baseURL.absoluteString, "provider_device_key": "original-device",
            ]
            let first = await NotificationPersistenceCoordinator.persistRemotePayloadIfNeeded(
                payload, requestIdentifier: "deleted-direct-delivery", dataStore: store)
            guard case let .persistedMain(saved) = first else {
                Issue.record("First Direct must be durably saved.")
                return
            }
            _ = try await store.deleteConfirmedLocalData(
                try await store.prepareLocalDeletion(intent: .messages(ids: [saved.id])))
            let replay = await NotificationPersistenceCoordinator.persistRemotePayloadIfNeeded(
                payload, requestIdentifier: "deleted-direct-delivery", dataStore: store)
            guard case .duplicate = replay else {
                Issue.record("Deleted replay must remain a processed duplicate.")
                return
            }
            await context.coordinator.ackDirectDeliveryIfNeeded(payload: payload,
                result: ProviderIngressPersistenceResult(replay), source: "test.deleted.direct")
            await context.coordinator.drainAckMarkers(source: "test.deleted.direct.drain")
            #expect(httpState.recordedPaths() == ["/OriginalGateway/messages/ack"])
            #expect(httpState.recordedDeviceKeys() == ["original-device"])
            #expect(await context.ackStore.pendingMarkers(limit: 10, minimumAge: 0).isEmpty)
            #expect(try await store.loadMessages().isEmpty)
        }
    }

    @Test
    func directAckWithMissingImmutableSourceDoesNotGuessCurrentConfig() async throws {
        try await withProviderIngressLocalDataStore { store, appGroupIdentifier in
            let host = "provider-direct-missing-\(UUID().uuidString.lowercased()).example"
            let baseURL = try #require(URL(string: "https://\(host)/CurrentGateway"))
            let httpState = ProviderIngressHTTPState(pullPayloads: [])
            let context = makeCoordinatorContext(
                host: host,
                baseURL: baseURL,
                store: store,
                appGroupIdentifier: appGroupIdentifier,
                httpState: httpState,
                capture: ProviderIngressCapture(results: [])
            )
            defer { context.cleanup() }

            await context.coordinator.ackDirectDeliveryIfNeeded(
                payload: [
                    "delivery_id": "missing-source",
                    "provider_device_key": "payload-device",
                ],
                result: .persisted,
                source: "test.direct.missing-base"
            )
            await context.coordinator.ackDirectDeliveryIfNeeded(
                payload: [
                    "delivery_id": "missing-source",
                    "base_url": baseURL.absoluteString,
                ],
                result: .persisted,
                source: "test.direct.missing-device"
            )
            await context.coordinator.ackDirectDeliveryIfNeeded(
                payload: [
                    "base_url": baseURL.absoluteString,
                    "provider_device_key": "payload-device",
                ],
                result: .persisted,
                source: "test.direct.missing-delivery-id"
            )

            #expect(httpState.recordedPaths().isEmpty)
            #expect(await context.ackStore.pendingMarkers(limit: 10, minimumAge: 0).isEmpty)
        }
    }

    @Test
    func freshPartialAckKeepsMarkerUntilIdempotentDrainConfirmsProtocolResponse() async throws {
        try await withProviderIngressLocalDataStore { store, appGroupIdentifier in
            let host = "provider-partial-ack-\(UUID().uuidString.lowercased()).example"
            let baseURL = try #require(URL(string: "https://\(host)/GatewayA"))
            let httpState = ProviderIngressHTTPState(
                pullPayloads: [
                    #"{"success":true,"data":{"items":[{"delivery_id":"partial-001","payload":{"title":"partial"}}],"has_more":false}}"#,
                ],
                ackRemovedCounts: [0, 0]
            )
            let capture = ProviderIngressCapture(results: [.persisted])
            let context = makeCoordinatorContext(
                host: host,
                baseURL: baseURL,
                store: store,
                appGroupIdentifier: appGroupIdentifier,
                httpState: httpState,
                capture: capture
            )
            defer { context.cleanup() }

            _ = await context.coordinator.syncProviderIngressOutcome(
                reason: "test_partial_ack",
                skipInboxMerge: true
            )
            let retryTime = Date().addingTimeInterval(31)
            #expect(
                await context.ackStore.pendingMarkers(
                    limit: 10,
                    minimumAge: 0,
                    now: retryTime
                ).count == 1
            )

            await context.coordinator.drainAckMarkers(
                source: "test_partial_ack_drain",
                now: retryTime
            )
            #expect(await context.ackStore.pendingMarkers(limit: 10, minimumAge: 0).isEmpty)
        }
    }

    @Test
    func ackBatchKeyNormalizesAuthorityButPreservesPathCase() throws {
        let upper = try #require(URL(string: "HTTPS://Gateway.EXAMPLE/GatewayA"))
        let lower = try #require(URL(string: "https://gateway.example/gatewaya"))
        #expect(ProviderIngressCoordinator.ackBatchKey(for: upper) != ProviderIngressCoordinator.ackBatchKey(for: lower))
        #expect(ProviderIngressCoordinator.ackBatchKey(for: upper).contains("/GatewayA"))
    }

    @Test
    func successfulCurrentGatewaySyncCannotPurgeUnresolvedForeignWakeupHint() async throws {
        try await withProviderIngressLocalDataStore { store, appGroupIdentifier in
            let host = "provider-foreign-hint-\(UUID().uuidString.lowercased()).example"
            let baseURL = try #require(URL(string: "https://\(host)/GatewayA"))
            let context = makeCoordinatorContext(
                host: host,
                baseURL: baseURL,
                store: store,
                appGroupIdentifier: appGroupIdentifier,
                httpState: ProviderIngressHTTPState(pullPayloads: []),
                capture: ProviderIngressCapture(results: [])
            )
            defer { context.cleanup() }
            let inbox = NotificationIngressInbox(appGroupIdentifier: appGroupIdentifier)
            #expect(await inbox.enqueue(
                payload: [
                    "provider_wakeup": true,
                    "provider_mode": "wakeup",
                    "delivery_id": "foreign-gateway-delivery",
                    "base_url": "https://foreign-gateway.example/Root",
                    "title": "Recovery hint",
                ],
                requestIdentifier: "foreign-gateway-delivery",
                source: "test.foreign_gateway_hint"
            ))

            #expect(await context.coordinator.purgePendingUnresolvedWakeupEntries() == 0)
            #expect(await inbox.pendingEntries().count == 1)
        }
    }

    @Test
    func foreignGatewayDeliveryIDReusePullsAndPersistsWithoutChangingOriginalMessage() async throws {
        try await withProviderIngressLocalDataStore { store, appGroupIdentifier in
            let deliveryID = "shared-delivery-\(UUID().uuidString.lowercased())"
            let oldBaseURL = try #require(URL(string: "https://old-gateway.example/Root"))
            let host = "provider-source-isolation-\(UUID().uuidString.lowercased()).example"
            let newBaseURL = try #require(URL(string: "https://\(host)/Root"))
            _ = await store.saveCachedDeviceKey("new-device", for: "macos")
            let oldMessageID = "old-\(deliveryID)"
            let newMessageID = "new-\(deliveryID)"
            let oldOutcome = await NotificationPersistenceCoordinator.persistRemotePayloadIfNeeded(
                [
                    "message_id": oldMessageID,
                    "delivery_id": deliveryID,
                    "base_url": oldBaseURL.absoluteString,
                    "provider_device_key": "old-device",
                    "title": "Original gateway message",
                    "body": "Original body",
                ],
                requestIdentifier: deliveryID,
                dataStore: store
            )
            guard case .persistedMain = oldOutcome else {
                Issue.record("The original gateway message must be canonical before the collision")
                return
            }

            let httpState = ProviderIngressHTTPState(pullPayloads: [
                """
                {"success":true,"data":{"items":[{"delivery_id":"\(deliveryID)","payload":{"message_id":"\(newMessageID)","title":"New gateway message","body":"New body"}}],"has_more":false}}
                """,
            ])
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [ChannelServiceURLProtocol.self]
            let session = URLSession(configuration: configuration)
            ChannelServiceURLProtocol.register(host: host) { request in
                try httpState.handle(request)
            }
            defer {
                session.invalidateAndCancel()
                ChannelServiceURLProtocol.unregister(host: host)
            }

            let inbox = NotificationIngressInbox(appGroupIdentifier: appGroupIdentifier)
            let ackStore = ProviderDeliveryAckFailureStore(appGroupIdentifier: appGroupIdentifier)
            let coordinator = ProviderIngressCoordinator(
                platformSuffix: "test",
                dataStore: store,
                channelSubscriptionService: ChannelSubscriptionService(session: session),
                notificationIngressInbox: inbox,
                ackMarkerStore: ackStore,
                wakeupPullClaimStore: ProviderWakeupPullClaimStore(appGroupIdentifier: appGroupIdentifier),
                hooks: .init(
                    isEnabled: { true },
                    serverConfig: { ServerConfig(baseURL: newBaseURL, token: "token") },
                    cachedDeviceKey: { "new-device" },
                    hasPersistedNotification: { identity in
                        if let messageID = identity.messageId,
                           let stored = try? await store.loadMessage(messageId: messageID),
                           identity.matchesPersisted(stored) {
                            return true
                        }
                        if let deliveryID = identity.deliveryId,
                           let stored = try? await store.loadMessages(deliveryId: deliveryID),
                           stored.contains(where: identity.matchesPersisted) {
                            return true
                        }
                        return false
                    },
                    persistPayloads: { inputs in
                        let outcomes = await NotificationPersistenceCoordinator.persistRemotePayloadsIfNeeded(
                            inputs.map { .init(payload: $0.payload, requestIdentifier: $0.requestIdentifier) },
                            dataStore: store
                        )
                        return outcomes.map(ProviderIngressPersistenceResult.init)
                    },
                    applyPersistenceResults: { _ in },
                    reportInboxProgress: { _ in },
                    recordProviderError: { _, _ in }
                )
            )
            #expect(await inbox.enqueue(
                payload: [
                    "provider_wakeup": "1",
                    "provider_mode": "wakeup",
                    "delivery_id": deliveryID,
                    "base_url": newBaseURL.absoluteString,
                    "_skip_persist": "1",
                ],
                requestIdentifier: deliveryID,
                source: "test.new_gateway_hint"
            ))

            _ = await coordinator.mergeInbox(
                reason: "test_foreign_delivery_id_reuse",
                allowWakeupSync: true
            )

            #expect(httpState.recordedPaths().contains("/Root/v2/messages/pull"))
            #expect(try await store.loadMessage(messageId: oldMessageID)?.title == "Original gateway message")
            #expect(try await store.loadMessage(messageId: oldMessageID)?.body == "Original body")
            #expect(try await store.loadMessage(messageId: newMessageID)?.title == "New gateway message")
            #expect(try await store.loadMessage(messageId: newMessageID)?.body == "New body")
            let sameDeliveryRows = try await store.loadMessages(deliveryId: deliveryID)
            #expect(sameDeliveryRows.count == 2)
            let newGatewayIdentity = coordinator.identity(from: [
                "provider_wakeup": "1",
                "delivery_id": deliveryID,
                "base_url": newBaseURL.absoluteString,
            ])
            #expect(sameDeliveryRows.filter(newGatewayIdentity.matchesPersisted).count == 1)
            #expect(await ackStore.pendingMarkers(limit: 10, minimumAge: 0).count == 1)
            await coordinator.drainAckMarkers(source: "test_foreign_delivery_id_reuse")
            #expect(httpState.recordedPaths().contains("/Root/v2/messages/ack"))
            #expect(await ackStore.pendingMarkers(limit: 10, minimumAge: 0).isEmpty)
        }
    }

    @Test
    func inboxMergeWithWakeupSyncDisabledCannotReachDestructiveLegacyPull() async throws {
        try await withProviderIngressLocalDataStore { store, appGroupIdentifier in
            let host = "provider-no-legacy-merge-\(UUID().uuidString.lowercased()).example"
            let baseURL = try #require(URL(string: "https://\(host)/GatewayA"))
            _ = await store.saveCachedDeviceKey("device-key", for: "macos")
            let httpState = ProviderIngressHTTPState(
                pullPayloads: [
                    #"{"success":true,"data":{"items":[{"delivery_id":"must-not-destructively-pull","payload":{"title":"legacy"}}]}}"#,
                ],
                v2RouteNotFound: true
            )
            let capture = ProviderIngressCapture(results: [])
            let context = makeCoordinatorContext(
                host: host,
                baseURL: baseURL,
                store: store,
                appGroupIdentifier: appGroupIdentifier,
                httpState: httpState,
                capture: capture
            )
            defer { context.cleanup() }
            let inbox = NotificationIngressInbox(appGroupIdentifier: appGroupIdentifier)
            #expect(await inbox.enqueue(
                payload: [
                    "provider_wakeup": true,
                    "provider_mode": "wakeup",
                    "delivery_id": "must-not-destructively-pull",
                    "base_url": baseURL.absoluteString,
                    "title": "Recovery hint",
                ],
                requestIdentifier: "must-not-destructively-pull",
                source: "test.no_legacy_merge"
            ))

            #expect(await context.coordinator.mergeInbox(
                reason: "test_no_legacy_merge",
                allowWakeupSync: false
            ) == 0)
            let paths = httpState.recordedPaths()
            #expect(!paths.isEmpty)
            #expect(paths.allSatisfy { $0 == "/GatewayA/v2/messages/pull" })
            #expect(!paths.contains("/GatewayA/messages/pull"))
            #expect(await capture.deliveryIds.isEmpty)
        }
    }

    @Test
    func concurrentInboxMergesShareOneProgressiveBatchDrain() async throws {
        try await withProviderIngressLocalDataStore { store, appGroupIdentifier in
            let host = "provider-single-flight-\(UUID().uuidString.lowercased()).example"
            let baseURL = try #require(URL(string: "https://\(host)/GatewayA"))
            let httpState = ProviderIngressHTTPState(pullPayloads: [])
            let capture = ProviderIngressCapture(results: [], pausesFirstBatch: true)
            let progressCapture = ProviderInboxProgressCapture()
            let context = makeCoordinatorContext(
                host: host,
                baseURL: baseURL,
                store: store,
                appGroupIdentifier: appGroupIdentifier,
                httpState: httpState,
                capture: capture,
                progressCapture: progressCapture
            )
            defer { context.cleanup() }

            let inbox = NotificationIngressInbox(appGroupIdentifier: appGroupIdentifier)
            for index in 0..<265 {
                #expect(await inbox.enqueue(
                    codablePayload: [
                        "message_id": AnyCodable("batch-drain-\(index)"),
                        "delivery_id": AnyCodable("batch-drain-\(index)"),
                        "title": AnyCodable("Batch \(index)"),
                        "body": AnyCodable("Body \(index)"),
                    ],
                    requestIdentifier: "batch-drain-\(index)",
                    source: "test.progressive_batch"
                ))
            }

            let first = Task { @MainActor in
                await context.coordinator.mergeInbox(
                    reason: "test_first",
                    allowWakeupSync: false
                )
            }
            await capture.waitUntilFirstBatchStarts()
            let joining = Task { @MainActor in
                await context.coordinator.mergeInbox(
                    reason: "test_joining",
                    allowWakeupSync: false
                )
            }
            await Task.yield()
            await capture.releaseFirstBatch()

            #expect(await first.value == 265)
            #expect(await joining.value == 265)
            #expect(await capture.batchSizes == [64, 200, 1])
            #expect(progressCapture.events == [
                .processing(completed: 0, total: 265),
                .processing(completed: 64, total: 265),
                .processing(completed: 264, total: 265),
                .processing(completed: 265, total: 265),
                .completed(processed: 265),
            ])
            #expect(await inbox.pendingEntries().isEmpty)
        }
    }

    private func makeCoordinatorContext(
        host: String,
        baseURL: URL,
        store: LocalDataStore,
        appGroupIdentifier: String,
        httpState: ProviderIngressHTTPState,
        capture: ProviderIngressCapture,
        progressCapture: ProviderInboxProgressCapture? = nil,
        persistToStore: Bool = false
    ) -> CoordinatorContext {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ChannelServiceURLProtocol.self]
        let session = URLSession(configuration: configuration)
        ChannelServiceURLProtocol.register(host: host) { request in
            try httpState.handle(request)
        }
        let ackStore = ProviderDeliveryAckFailureStore(appGroupIdentifier: appGroupIdentifier)
        let coordinator = ProviderIngressCoordinator(
            platformSuffix: "test",
            dataStore: store,
            channelSubscriptionService: ChannelSubscriptionService(session: session),
            notificationIngressInbox: NotificationIngressInbox(appGroupIdentifier: appGroupIdentifier),
            ackMarkerStore: ackStore,
            wakeupPullClaimStore: ProviderWakeupPullClaimStore(appGroupIdentifier: appGroupIdentifier),
            ackMarkerMinimumAge: 0,
            hooks: .init(
                isEnabled: { true },
                serverConfig: { ServerConfig(baseURL: baseURL, token: "token") },
                cachedDeviceKey: { "device-key" },
                hasPersistedNotification: { _ in false },
                persistPayloads: { inputs in
                    let injected = await capture.persist(inputs: inputs)
                    guard persistToStore, !injected.contains(where: { if case .failed = $0 { return true }; return false }) else { return injected }
                    return await NotificationPersistenceCoordinator.persistRemotePayloadsIfNeeded(
                        inputs.map { .init(payload: $0.payload, requestIdentifier: $0.requestIdentifier) }, dataStore: store
                    ).map(ProviderIngressPersistenceResult.init)
                },
                applyPersistenceResults: { _ in },
                reportInboxProgress: { progress in
                    progressCapture?.record(progress)
                },
                recordProviderError: { error, source in
                    Task { await capture.record(error: error, source: source) }
                }
            )
        )
        return CoordinatorContext(
            coordinator: coordinator,
            ackStore: ackStore,
            session: session,
            host: host
        )
    }
}

private struct CoordinatorContext {
    let coordinator: ProviderIngressCoordinator
    let ackStore: ProviderDeliveryAckFailureStore
    let session: URLSession
    let host: String

    func cleanup() {
        session.invalidateAndCancel()
        ChannelServiceURLProtocol.unregister(host: host)
    }
}
