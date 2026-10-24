import Foundation
import GRDB
import Darwin
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
    private(set) var pulledInputs: [Bool] = []
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
            pulledInputs.append(input.isPulled)
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
            let id = UUID()
            let updatedAt = Date()
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
                    serverConfig: { ServerConfig(id: gateway.id, baseURL: gateway.baseURL, token: "test-token", updatedAt: gateway.updatedAt) },
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
                            case .identityConflict: persistedKinds.append("failed")
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
            #expect(await capture.pulledInputs == [true, true, true])
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

    @Test(arguments: ["message", "event", "thing"])
    func deletedDirectReplayStillDrainsAckToItsOriginalGatewayWithoutRestoringContent(_ entityType: String) async throws {
        try await withProviderIngressLocalDataStore { store, appGroupIdentifier in
            let host = "deleted-direct-\(UUID().uuidString.lowercased()).example"
            let baseURL = try #require(URL(string: "https://\(host)/OriginalGateway"))
            let httpState = ProviderIngressHTTPState(pullPayloads: [])
            let context = makeCoordinatorContext(host: host, baseURL: baseURL, store: store,
                appGroupIdentifier: appGroupIdentifier, httpState: httpState,
                capture: ProviderIngressCapture(results: []), persistToStore: true)
            defer { context.cleanup() }
            var payload: [AnyHashable: Any] = [
                "entity_type": entityType, "entity_id": "deleted-direct-message",
                "message_id": "deleted-direct-message", "delivery_id": "deleted-direct-delivery",
                "op_id": "deleted-direct-operation", "channel_id": "lifecycle",
                "title": "Exact deleted title", "body": "Exact deleted body",
                "base_url": baseURL.absoluteString, "provider_device_key": "original-device",
            ]
            if entityType == "event" { payload["event_id"] = "deleted-direct-message" }
            if entityType == "thing" { payload["thing_id"] = "deleted-direct-message" }
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
            #expect(try await store.loadMessage(messageId: "deleted-direct-message") == nil)
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
            let capturedConfig = ServerConfig(baseURL: newBaseURL, token: "token")
            let coordinator = ProviderIngressCoordinator(
                platformSuffix: "test",
                dataStore: store,
                channelSubscriptionService: ChannelSubscriptionService(session: session),
                notificationIngressInbox: inbox,
                ackMarkerStore: ackStore,
                wakeupPullClaimStore: ProviderWakeupPullClaimStore(appGroupIdentifier: appGroupIdentifier),
                hooks: .init(
                    isEnabled: { true },
                    serverConfig: { capturedConfig },
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
            #expect(await capture.pulledInputs == Array(repeating: false, count: 265))
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
        let capturedConfig = ServerConfig(baseURL: baseURL, token: "token")
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
                serverConfig: { capturedConfig },
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


// A synthetic non-destructive V2 queue: ACK removes only explicitly named targets.
// Unlike a canned sequence, a poison first page remains poison until healthy peers commit.
private final class MixedIngressHTTPState: Sendable {
    private struct State: Sendable {
        var items: [[String: String]]
        var originalOrder: [String]
        var pageSize: Int
        var paths: [String] = []
        var requestedPageTokens: [String?] = []
        var acknowledged: [[String]] = []
        var loseAckResponses: Int
        var rejectContinuationOnce: Bool
        var unavailable = false
        var persistedAt: [String: Double] = [:]
        var ackedAt: [String: Double] = [:]
    }
    private let state: OSAllocatedUnfairLock<State>
    private let supportsContinuation: Bool
    private let failPullRequestNumber: Int?
    private let acknowledgementEvents: AsyncStream<String>?
    private let acknowledgementContinuation: AsyncStream<String>.Continuation?
    init(items: [[String: String]], pageSize: Int = 3, loseAckResponses: Int = 0,
         supportsContinuation: Bool = false, failPullRequestNumber: Int? = nil,
         rejectContinuationOnce: Bool = false) {
        state = OSAllocatedUnfairLock(initialState: State(items: items, originalOrder: supportsContinuation ? items.compactMap { $0["delivery_id"] } : [],
            pageSize: max(1, pageSize), loseAckResponses: loseAckResponses, rejectContinuationOnce: rejectContinuationOnce))
        self.supportsContinuation = supportsContinuation
        self.failPullRequestNumber = failPullRequestNumber
        if supportsContinuation {
            let events = AsyncStream<String>.makeStream(bufferingPolicy: .bufferingNewest(256))
            acknowledgementEvents = events.stream
            acknowledgementContinuation = events.continuation
        } else {
            acknowledgementEvents = nil
            acknowledgementContinuation = nil
        }
    }
    func handle(_ request: URLRequest) throws -> (HTTPURLResponse, Data) {
        try state.withLock { state in
            let path = request.url!.path; state.paths.append(path)
            if state.unavailable { throw URLError(.cannotConnectToHost) }
            let body: [String: Any]
            if path.hasSuffix("/v2/messages/pull") {
                let data = ChannelServiceURLProtocol.bodyData(from: request) ?? Data()
                let requestBody = (try JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
                let pageToken = requestBody["page_token"] as? String
                state.requestedPageTokens.append(pageToken)
                if let failPullRequestNumber, state.requestedPageTokens.count == failPullRequestNumber { throw URLError(.networkConnectionLost) }
                if supportsContinuation {
                    let start: Int
                    if let pageToken {
                        guard !state.rejectContinuationOnce,
                              let bytes = Data(base64Encoded: pageToken),
                              let lastID = String(data: bytes, encoding: .utf8),
                              let position = state.originalOrder.firstIndex(of: lastID) else {
                            state.rejectContinuationOnce = false
                            let error: [String: Any] = ["success": false, "error_code": "page_token_invalid", "problem": ["code": "page_token_invalid", "category": "validation", "status": 400, "title": "Invalid page token", "retryable": false]]
                            return (HTTPURLResponse(url: request.url!, statusCode: 400, httpVersion: nil, headerFields: nil)!, try JSONSerialization.data(withJSONObject: error))
                        }
                        start = position + 1
                    } else { start = 0 }
                    // Seek in the original identity order. Removing an ACKed
                    // item cannot shift an offset and skip its unACKed peer.
                    let eligibleIDs = Set(state.originalOrder.dropFirst(start))
                    let remaining = state.items.filter { eligibleIDs.contains($0["delivery_id"]!) }
                    let selected = Array(remaining.prefix(state.pageSize))
                    let complete = remaining.count <= state.pageSize
                    var page: [String: Any] = ["items": selected.map { ["delivery_id": $0["delivery_id"]!, "payload": $0] as [String: Any] },
                                               "has_more": state.items.count > state.pageSize, "scan_complete": complete,
                                               "next_page_token": NSNull()]
                    if !complete, let lastID = selected.last?["delivery_id"] {
                        page["next_page_token"] = Data(lastID.utf8).base64EncodedString()
                    }
                    body = ["success": true, "data": page]
                } else {
                    body = ["success": true, "data": ["items": state.items.prefix(state.pageSize).map { ["delivery_id": $0["delivery_id"]!, "payload": $0] as [String: Any] }, "has_more": state.items.count > state.pageSize]]
                }
            } else if path.hasSuffix("/v2/messages/ack") {
                let data = ChannelServiceURLProtocol.bodyData(from: request) ?? Data()
                let ids = ((try JSONSerialization.jsonObject(with: data)) as? [String: Any])?["delivery_ids"] as? [String] ?? []
                state.acknowledged.append(ids)
                let before = state.items.count
                state.items.removeAll { ids.contains($0["delivery_id"]!) }
                for id in ids {
                    state.ackedAt[id] = ProcessInfo.processInfo.systemUptime
                    acknowledgementContinuation?.yield(id)
                }
                if state.loseAckResponses > 0 { state.loseAckResponses -= 1; throw URLError(.networkConnectionLost) }
                let removed = before - state.items.count
                body = ["success": true, "data": ["removed": removed > 0, "requested_count": ids.count, "removed_count": removed]]
            } else { throw URLError(.unsupportedURL) }
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, try JSONSerialization.data(withJSONObject: body))
        }
    }
    func append(_ items: [[String: String]]) {
        state.withLock { state in
            state.items += items
            if supportsContinuation {
                for id in items.compactMap({ $0["delivery_id"] }) where !state.originalOrder.contains(id) { state.originalOrder.append(id) }
            }
        }
    }
    func setUnavailable(_ value: Bool) { state.withLock { $0.unavailable = value } }
    func recordPersisted(_ id: String) { state.withLock { $0.persistedAt[id] = ProcessInfo.processInfo.systemUptime } }
    func remaining() -> [String] { state.withLock { $0.items.compactMap { $0["delivery_id"] } } }
    func paths() -> [String] { state.withLock { $0.paths } }
    func acknowledgements() -> [[String]] { state.withLock { $0.acknowledged } }
    func requestedPageTokens() -> [String?] { state.withLock { $0.requestedPageTokens } }
    func waitForAcknowledgement(_ deliveryID: String) async -> Bool {
        guard let acknowledgementEvents else { return false }
        return await withTaskGroup(of: Bool.self) { tasks in
            tasks.addTask { [acknowledgementEvents] in
                for await value in acknowledgementEvents where value == deliveryID { return true }
                return false
            }
            tasks.addTask {
                try? await Task.sleep(for: .seconds(15))
                return false
            }
            let observed = await tasks.next() ?? false
            tasks.cancelAll()
            return observed
        }
    }
    func times() -> (persisted: [String: Double], acked: [String: Double]) { state.withLock { ($0.persistedAt, $0.ackedAt) } }
}

private func mixedPayload(_ id: String, operation: String? = nil, entity: String? = nil) -> [String: String] {
    ["entity_type": "message", "message_id": id, "entity_id": entity ?? id,
     "delivery_id": id, "op_id": operation ?? ("op-" + id), "channel_id": "mixed",
     "title": "Exact " + id, "body": "Persisted content " + id]
}

private func seedUnattributedMixedOperation(_ group: String) async throws -> DatabaseQueue {
    let file = try AppConstants.appLocalDatabaseDirectory(appGroupIdentifier: group).appendingPathComponent(AppConstants.databaseStoreFilename)
    let db = try DatabaseQueue(path: file.path)
    try await db.write { db in
        try db.execute(sql: """
        INSERT INTO operation_ledger(scope_key,message_id,op_id,channel_id,entity_type,entity_id,delivery_id,applied_at)
        VALUES('mixed|message|ambiguous-entity|ambiguous-op','gone-legacy-message','ambiguous-op','mixed','message','ambiguous-entity','gone-legacy-delivery',123);
        """)
    }
    return db
}

@MainActor
private func mixedContext(store: LocalDataStore, group: String, state: MixedIngressHTTPState, base: URL,
                          serverConfig: ServerConfig? = nil) -> CoordinatorContext {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [ChannelServiceURLProtocol.self]
    let session = URLSession(configuration: configuration)
    let host = base.host!
    ChannelServiceURLProtocol.register(host: host) { request in try state.handle(request) }
    let ackStore = ProviderDeliveryAckFailureStore(appGroupIdentifier: group)
    let capturedConfig = serverConfig ?? ServerConfig(baseURL: base, token: "synthetic-token")
    return CoordinatorContext(coordinator: ProviderIngressCoordinator(platformSuffix: "test", dataStore: store,
        channelSubscriptionService: ChannelSubscriptionService(session: session),
        notificationIngressInbox: NotificationIngressInbox(appGroupIdentifier: group), ackMarkerStore: ackStore,
        wakeupPullClaimStore: ProviderWakeupPullClaimStore(appGroupIdentifier: group), ackMarkerMinimumAge: 0,
        hooks: .init(isEnabled: { true }, serverConfig: { capturedConfig }, cachedDeviceKey: { "frozen-device" }, hasPersistedNotification: { _ in false },
            persistPayloads: { inputs in
                let outcomes = await NotificationPersistenceCoordinator.persistRemotePayloadsIfNeeded(inputs.map { .init(payload: $0.payload, requestIdentifier: $0.requestIdentifier) }, dataStore: store)
                for (input, result) in zip(inputs, outcomes) where ProviderIngressPersistenceResult(result).allowsAck { state.recordPersisted(input.requestIdentifier!) }
                return outcomes.map(ProviderIngressPersistenceResult.init)
            }, applyPersistenceResults: { _ in }, reportInboxProgress: { _ in }, recordProviderError: { _, _ in })), ackStore: ackStore, session: session, host: host)
}

extension ProviderIngressCoordinatorTests {
    @Test
    func mixedIdentityConflictDoesNotStarveHealthyAndLaterPage() async throws {
        try await withProviderIngressLocalDataStore { store, group in
            let base = URL(string: "https://mixed-\(UUID().uuidString.lowercased()).invalid/prefix")!
            _ = try await seedUnattributedMixedOperation(group)
            let duplicate = mixedPayload("duplicate")
            var direct = duplicate.reduce(into: [AnyHashable: Any]()) { $0[$1.key] = $1.value }
            direct["base_url"] = base.absoluteString; direct["provider_device_key"] = "frozen-device"
            let input = NotificationPersistenceCoordinator.RemotePayload(payload: direct, requestIdentifier: "duplicate")
            _ = await NotificationPersistenceCoordinator.persistRemotePayloadsIfNeeded([input], dataStore: store)
            let state = MixedIngressHTTPState(items: [duplicate, mixedPayload("poison", operation: "ambiguous-op", entity: "ambiguous-entity"), mixedPayload("healthy-1"), mixedPayload("healthy-later")])
            let context = mixedContext(store: store, group: group, state: state, base: base)
            defer { context.cleanup() }
            let outcome = await context.coordinator.syncProviderIngressOutcome(reason: "manual_mixed", skipInboxMerge: true)
            #expect(outcome.appliedCount == 2)
            #expect(Set(try await store.loadMessages().compactMap(\.messageId)) == ["duplicate", "healthy-1", "healthy-later"])
            #expect(state.remaining() == ["poison"])
            #expect(Set(state.acknowledgements().flatMap { $0 }) == ["duplicate", "healthy-1", "healthy-later"])
            #expect(state.paths().filter { $0.hasSuffix("/pull") }.count == 2)
            let inbox = NotificationIngressInbox(appGroupIdentifier: group)
            #expect(await inbox.pendingEntries().map { $0.record.requestIdentifier } == ["poison"])
            let repeated = await context.coordinator.syncProviderIngressOutcome(reason: "manual_repeated_poison", skipInboxMerge: true)
            #expect(repeated.appliedCount == 0)
            #expect(state.paths().filter { $0.hasSuffix("/pull") }.count == 3)
            #expect(state.remaining() == ["poison"])
            #expect(try await store.loadMessage(messageId: "poison") == nil)
        }
    }

    @Test
    func fullUnacknowledgeableServerHeadStopsWithoutBusyLoopOrFalseAck() async throws {
        try await withProviderIngressLocalDataStore { store, group in
            let base = URL(string: "https://full-poison-\(UUID().uuidString.lowercased()).invalid")!
            _ = try await seedUnattributedMixedOperation(group)
            let poisons = (0..<200).map { mixedPayload("poison-\($0)", operation: "ambiguous-op", entity: "ambiguous-entity") }
            let state = MixedIngressHTTPState(items: poisons + [mixedPayload("healthy-behind-full-head")], pageSize: 200)
            let context = mixedContext(store: store, group: group, state: state, base: base)
            defer { context.cleanup() }
            let result = await context.coordinator.syncProviderIngressOutcome(reason: "manual_full_poison", skipInboxMerge: true)
            #expect(result.appliedCount == 0)
            #expect(state.paths().filter { $0.hasSuffix("/pull") }.count == 1)
            #expect(state.acknowledgements().isEmpty)
            #expect(state.remaining().count == 201)
            #expect(try await store.loadMessages().isEmpty)
            #expect(await NotificationIngressInbox(appGroupIdentifier: group).pendingEntries().count == 200)
            // A legacy V2 server omits the continuation contract. Unknown work
            // behind its full unacknowledgeable head still cannot be fake-ACKed.
        }
    }

    @Test
    func modernContinuationPassesTwoHundredIdentityConflictsWithoutAcknowledgingThem() async throws {
        try await withProviderIngressLocalDataStore { store, group in
            let base = URL(string: "https://modern-poison-\(UUID().uuidString.lowercased()).invalid")!
            _ = try await seedUnattributedMixedOperation(group)
            let poisons = (0..<200).map { mixedPayload("modern-poison-\($0)", operation: "ambiguous-op", entity: "ambiguous-entity") }
            let healthyID = "healthy-after-modern-full-head"
            let state = MixedIngressHTTPState(items: poisons + [mixedPayload(healthyID)], pageSize: 200, supportsContinuation: true)
            let context = mixedContext(store: store, group: group, state: state, base: base)
            defer { context.cleanup() }
            let result = await context.coordinator.syncProviderIngressOutcome(reason: "manual_modern_full_poison", skipInboxMerge: true)
            #expect(result.completedRequest)
            // The 5-second turn budget may yield after the first full page.
            // Await a real server ACK event, never retry the business operation.
            #expect(await state.waitForAcknowledgement(healthyID))
            #expect(try await store.loadMessage(messageId: healthyID)?.title == "Exact " + healthyID)
            #expect(try await store.loadMessages().count == 1)
            #expect(Set(state.remaining()) == Set(poisons.compactMap { $0["delivery_id"] }))
            #expect(state.acknowledgements() == [[healthyID]])
            let tokens = state.requestedPageTokens()
            #expect(tokens.count == 2)
            #expect(tokens.first == .some(nil))
            #expect(tokens.last == .some(Data("modern-poison-199".utf8).base64EncodedString()))
            let pending = await NotificationIngressInbox(appGroupIdentifier: group).pendingEntries(limit: 256)
            #expect(Set(pending.compactMap { $0.record.requestIdentifier }) == Set(poisons.compactMap { $0["delivery_id"] }))
        }
    }

    @Test
    func modernContinuationUsesIdentitySeekWhenEarlierHealthyItemsAreAcknowledged() async throws {
        try await withProviderIngressLocalDataStore { store, group in
            let base = URL(string: "https://modern-seek-\(UUID().uuidString.lowercased()).invalid")!
            _ = try await seedUnattributedMixedOperation(group)
            let state = MixedIngressHTTPState(items: [mixedPayload("healthy-before"),
                mixedPayload("seek-poison", operation: "ambiguous-op", entity: "ambiguous-entity"),
                mixedPayload("healthy-immediately-after"), mixedPayload("healthy-last")], pageSize: 2, supportsContinuation: true)
            let context = mixedContext(store: store, group: group, state: state, base: base)
            defer { context.cleanup() }
            let result = await context.coordinator.syncProviderIngressOutcome(reason: "manual_modern_seek", skipInboxMerge: true)
            #expect(result.appliedCount == 3)
            #expect(Set(try await store.loadMessages().compactMap(\.messageId)) == ["healthy-before", "healthy-immediately-after", "healthy-last"])
            #expect(state.acknowledgements() == [["healthy-before"], ["healthy-immediately-after", "healthy-last"]])
            #expect(state.remaining() == ["seek-poison"])
            #expect(state.requestedPageTokens() == [nil, Data("seek-poison".utf8).base64EncodedString()])
        }
    }

    @Test
    func modernDatabaseFailureKeepsFrontierAtSamePageUntilARealWriteCanCommit() async throws {
        try await withProviderIngressLocalDataStore { store, group in
            let base = URL(string: "https://modern-write-failure-\(UUID().uuidString.lowercased()).invalid")!
            let file = try AppConstants.appLocalDatabaseDirectory(appGroupIdentifier: group).appendingPathComponent(AppConstants.databaseStoreFilename)
            let db = try DatabaseQueue(path: file.path)
            try await db.write { db in try db.execute(sql: "CREATE TRIGGER fail_canonical_write BEFORE INSERT ON messages BEGIN SELECT RAISE(ABORT, 'synthetic database failure'); END;") }
            let state = MixedIngressHTTPState(items: [mixedPayload("write-first"), mixedPayload("write-second"), mixedPayload("write-later")], pageSize: 2, supportsContinuation: true)
            let context = mixedContext(store: store, group: group, state: state, base: base)
            defer { context.cleanup() }
            let failed = await context.coordinator.syncProviderIngressOutcome(reason: "manual_modern_write_failed", skipInboxMerge: true)
            #expect(!failed.completedRequest)
            #expect(state.requestedPageTokens() == [nil])
            #expect(state.acknowledgements().isEmpty)
            #expect(try await store.loadMessages().isEmpty)
            #expect(state.remaining() == ["write-first", "write-second", "write-later"])
            #expect(await NotificationIngressInbox(appGroupIdentifier: group).pendingEntries().count == 2)
            try await db.write { db in try db.execute(sql: "DROP TRIGGER fail_canonical_write;") }
            let recovered = await context.coordinator.syncProviderIngressOutcome(reason: "manual_modern_write_recovered", skipInboxMerge: true)
            #expect(recovered.appliedCount == 3)
            #expect(state.requestedPageTokens() == [nil, nil, Data("write-second".utf8).base64EncodedString()])
            #expect(state.remaining().isEmpty)
            #expect(try await store.loadMessages().count == 3)
        }
    }

    @Test
    func modernContinuationResumesPersistedFrontierAfterCoordinatorAndStoreReopen() async throws {
        try await withProviderIngressLocalDataStore { store, group in
            let base = URL(string: "https://modern-reopen-\(UUID().uuidString.lowercased()).invalid")!
            let capturedConfig = ServerConfig(baseURL: base, token: "synthetic-token",
                updatedAt: Date(timeIntervalSince1970: 1_800_000_000.375))
            let configDirectory = try #require(PushGoAutomationContext.storageRootOverrideURL)
                .appendingPathComponent("frontier-protected-config", isDirectory: true)
            let configStore = LocalKeychainConfigStore(qualityStorageDirectory: configDirectory)
            try configStore.saveServerConfig(capturedConfig)
            let state = MixedIngressHTTPState(items: [mixedPayload("resume-first"), mixedPayload("resume-next")], pageSize: 1,
                supportsContinuation: true, failPullRequestNumber: 2)
            let first = mixedContext(store: store, group: group, state: state, base: base, serverConfig: capturedConfig)
            let interrupted = await first.coordinator.syncProviderIngressOutcome(reason: "manual_modern_interrupted", skipInboxMerge: true)
            #expect(!interrupted.completedRequest)
            #expect(state.acknowledgements() == [["resume-first"]])
            #expect(state.remaining() == ["resume-next"])
            first.cleanup()
            LocalDataStore.releaseSharedResourcesForTesting(storageRootURL: try #require(PushGoAutomationContext.storageRootOverrideURL))
            let reopened = LocalDataStore(appGroupIdentifier: group, spotlightIndexer: nil)
            let persistedConfig = try configStore.loadServerConfig(backfillGatewayToken: false)
            let loadedConfig = try #require(persistedConfig)
            #expect(loadedConfig.id == capturedConfig.id)
            #expect(loadedConfig.updatedAt != capturedConfig.updatedAt,
                    "The real persisted ISO8601 precision must exercise the restart boundary.")
            let resumed = mixedContext(store: reopened, group: group, state: state, base: base, serverConfig: loadedConfig)
            defer { resumed.cleanup() }
            let outcome = await resumed.coordinator.syncProviderIngressOutcome(reason: "manual_modern_resume", skipInboxMerge: true)
            #expect(outcome.appliedCount == 1)
            let token = Data("resume-first".utf8).base64EncodedString()
            #expect(state.requestedPageTokens() == [nil, token, token])
            #expect(state.acknowledgements() == [["resume-first"], ["resume-next"]])
            #expect(try await reopened.loadMessages().count == 2)
            #expect(state.remaining().isEmpty)
        }
    }

    @Test
    func modernCheckpointWriteFailureStopsAfterAckAndReopensFromTheUnadvancedHead() async throws {
        try await withProviderIngressLocalDataStore { store, group in
            let base = URL(string: "https://modern-checkpoint-failure-\(UUID().uuidString.lowercased()).invalid")!
            let capturedConfig = ServerConfig(baseURL: base, token: "synthetic-token")
            let journal = DurableIngressJournal(appGroupIdentifier: group)
            #expect(await journal.durabilityPragmas() != nil)
            let journalURL = try #require(await journal.databaseURL)
            let metadata = try DatabaseQueue(path: journalURL.path)
            try await metadata.write { db in
                try db.execute(sql: "CREATE TRIGGER fail_frontier_checkpoint BEFORE UPDATE OF value ON ingress_meta WHEN NEW.key = 'v2_pull_frontier' BEGIN SELECT RAISE(ABORT, 'synthetic frontier checkpoint failure'); END;")
            }
            let state = MixedIngressHTTPState(items: [mixedPayload("checkpoint-first"), mixedPayload("checkpoint-later")],
                pageSize: 1, supportsContinuation: true)
            let first = mixedContext(store: store, group: group, state: state, base: base, serverConfig: capturedConfig)
            let failed = await first.coordinator.syncProviderIngressOutcome(reason: "manual_checkpoint_write_failed", skipInboxMerge: true)
            #expect(!failed.completedRequest)
            #expect(state.requestedPageTokens() == [nil])
            #expect(state.acknowledgements() == [["checkpoint-first"]])
            #expect(state.remaining() == ["checkpoint-later"])
            #expect(try await store.loadMessage(messageId: "checkpoint-first") != nil)
            #expect(try await store.loadMessage(messageId: "checkpoint-later") == nil)
            try await metadata.write { db in try db.execute(sql: "DROP TRIGGER fail_frontier_checkpoint;") }
            first.cleanup()
            LocalDataStore.releaseSharedResourcesForTesting(storageRootURL: try #require(PushGoAutomationContext.storageRootOverrideURL))
            let reopened = LocalDataStore(appGroupIdentifier: group, spotlightIndexer: nil)
            let resumed = mixedContext(store: reopened, group: group, state: state, base: base, serverConfig: capturedConfig)
            defer { resumed.cleanup() }
            let recovered = await resumed.coordinator.syncProviderIngressOutcome(reason: "manual_checkpoint_write_recovered", skipInboxMerge: true)
            #expect(recovered.appliedCount == 1)
            #expect(state.requestedPageTokens() == [nil, nil])
            #expect(state.acknowledgements() == [["checkpoint-first"], ["checkpoint-later"]])
            #expect(state.remaining().isEmpty)
            #expect(try await reopened.loadMessages().count == 2)
        }
    }

    @Test
    func modernRejectedPageTokenResetsDurablyAndStopsUntilTheNextTurn() async throws {
        try await withProviderIngressLocalDataStore { store, group in
            let base = URL(string: "https://modern-reset-\(UUID().uuidString.lowercased()).invalid")!
            let state = MixedIngressHTTPState(items: [mixedPayload("reset-first"), mixedPayload("reset-next")], pageSize: 1,
                supportsContinuation: true, rejectContinuationOnce: true)
            let context = mixedContext(store: store, group: group, state: state, base: base)
            defer { context.cleanup() }
            let invalid = await context.coordinator.syncProviderIngressOutcome(reason: "manual_modern_invalid_token", skipInboxMerge: true)
            #expect(!invalid.completedRequest)
            #expect(state.requestedPageTokens().count == 2)
            #expect(state.remaining() == ["reset-next"])
            #expect(state.acknowledgements() == [["reset-first"]])
            let retry = await context.coordinator.syncProviderIngressOutcome(reason: "manual_modern_next_turn", skipInboxMerge: true)
            #expect(retry.appliedCount == 1)
            #expect(state.requestedPageTokens() == [nil, Data("reset-first".utf8).base64EncodedString(), nil])
            #expect(state.remaining().isEmpty)
            let rows = try await store.loadMessages()
            #expect(rows.count == 2)
        }
    }

    @Test
    func sqliteWriteFailureRollsBackHealthyBatchAndNeverAcknowledgesIt() async throws {
        try await withProviderIngressLocalDataStore { store, group in
            let base = URL(string: "https://write-failure-\(UUID().uuidString.lowercased()).invalid")!
            let file = try AppConstants.appLocalDatabaseDirectory(appGroupIdentifier: group).appendingPathComponent(AppConstants.databaseStoreFilename)
            let db = try DatabaseQueue(path: file.path)
            try await db.write { db in try db.execute(sql: "CREATE TRIGGER fail_canonical_write BEFORE INSERT ON messages BEGIN SELECT RAISE(ABORT, 'synthetic database failure'); END;") }
            let state = MixedIngressHTTPState(items: [mixedPayload("first"), mixedPayload("second")])
            let context = mixedContext(store: store, group: group, state: state, base: base)
            defer { context.cleanup() }
            let failed = await context.coordinator.syncProviderIngressOutcome(reason: "manual_write_failed", skipInboxMerge: true)
            #expect(!failed.completedRequest)
            #expect(try await store.loadMessages().isEmpty)
            #expect(state.acknowledgements().isEmpty)
            #expect(state.remaining() == ["first", "second"])
            #expect(await NotificationIngressInbox(appGroupIdentifier: group).pendingEntries().count == 2)
            try await db.write { db in try db.execute(sql: "DROP TRIGGER fail_canonical_write;") }
            let recovered = await context.coordinator.syncProviderIngressOutcome(reason: "manual_recovered", skipInboxMerge: true)
            #expect(recovered.appliedCount == 2)
            #expect(state.remaining().isEmpty)
            #expect(try await store.loadMessages().count == 2)
        }
    }

    @Test
    func lostAckResponseRecoveryDoesNotRestoreConfirmedDeletedContent() async throws {
        try await withProviderIngressLocalDataStore { store, group in
            let base = URL(string: "https://lost-ack-\(UUID().uuidString.lowercased()).invalid")!
            let state = MixedIngressHTTPState(items: [mixedPayload("lost-response")], loseAckResponses: 1)
            let context = mixedContext(store: store, group: group, state: state, base: base)
            defer { context.cleanup() }
            _ = await context.coordinator.syncProviderIngressOutcome(reason: "manual_lost_ack", skipInboxMerge: true)
            let saved = try #require(try await store.loadMessage(messageId: "lost-response"))
            #expect(state.remaining().isEmpty)
            #expect(await context.ackStore.pendingMarkers(limit: 10, minimumAge: 0, now: Date().addingTimeInterval(61)).count == 1)
            _ = try await store.deleteConfirmedLocalData(try await store.prepareLocalDeletion(intent: .messages(ids: [saved.id])))
            let reopened = LocalDataStore(appGroupIdentifier: group, spotlightIndexer: nil)
            let resumed = mixedContext(store: reopened, group: group, state: state, base: base)
            defer { resumed.cleanup() }
            await resumed.coordinator.drainAckMarkers(source: "test_restart", now: Date().addingTimeInterval(61))
            #expect(await resumed.ackStore.pendingMarkers(limit: 10, minimumAge: 0, now: Date().addingTimeInterval(120)).isEmpty)
            #expect(try await reopened.loadMessages().isEmpty)
            #expect(state.acknowledgements() == [["lost-response"], ["lost-response"]])
        }
    }
}

@Suite(.enabled(if: ProcessInfo.processInfo.environment["PUSHGO_DELIVERY_LOAD_OUTPUT"] != nil))
@MainActor
struct AppleDeliveryLoadAcceptanceTests {
    @Test func optimizedHealthyIngressFixedLoad() async throws {
        guard let output = ProcessInfo.processInfo.environment["PUSHGO_DELIVERY_LOAD_OUTPUT"] else { return }
        try await withProviderIngressLocalDataStore { store, group in
            let state = MixedIngressHTTPState(items: [], pageSize: 32)
            let base = URL(string: "https://load-\(UUID().uuidString.lowercased()).invalid/prefix")!
            let context = mixedContext(store: store, group: group, state: state, base: base)
            defer { context.cleanup() }
            var offers: [String: Double] = [:]
            var stages: [[String: Any]] = []
            func resident() -> UInt64 {
                var info = mach_task_basic_info(); var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info_data_t>.size / MemoryLayout<natural_t>.size)
                let result = withUnsafeMutablePointer(to: &info) { pointer in pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) } }
                return result == KERN_SUCCESS ? UInt64(info.resident_size) : 0
            }
            func snapshot(_ name: String) {
                var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
                stages.append(["stage": name, "time": ProcessInfo.processInfo.systemUptime, "rss_bytes": resident(), "cpu_seconds": Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000, "server_pending": state.remaining().count])
            }
            func offer(_ id: String) { offers[id] = ProcessInfo.processInfo.systemUptime; state.append([mixedPayload(id)]) }
            snapshot("cold"); try await Task.sleep(for: .seconds(2)); snapshot("idle")
            for index in 0..<8 { offer("low-\(index)"); _ = await context.coordinator.syncProviderIngressOutcome(reason: "manual_low", skipInboxMerge: true); try await Task.sleep(for: .milliseconds(250)) }
            snapshot("low")
            for index in 0..<128 { offer("burst-\(index)") }
            snapshot("burst_offer"); _ = await context.coordinator.syncProviderIngressOutcome(reason: "manual_burst", skipInboxMerge: true); snapshot("burst_drained")
            for index in 0..<64 { offer("steady-\(index)"); _ = await context.coordinator.syncProviderIngressOutcome(reason: "manual_steady", skipInboxMerge: true); try await Task.sleep(for: .milliseconds(16)) }
            snapshot("steady")
            state.setUnavailable(true)
            for index in 0..<16 { offer("outage-\(index)") }
            _ = await context.coordinator.syncProviderIngressOutcome(reason: "manual_outage", skipInboxMerge: true); snapshot("disconnected")
            state.setUnavailable(false); _ = await context.coordinator.syncProviderIngressOutcome(reason: "manual_recover", skipInboxMerge: true); snapshot("recovered")
            #expect(state.remaining().isEmpty)
            #expect(try await store.loadMessages().count == 216)
            #expect(await store.drainDerivedWorkForBackgroundRefresh())
            try await Task.sleep(for: .seconds(2)); snapshot("falloff")
            let times = state.times()
            func percentiles(_ map: [String: Double]) -> [String: Double] {
                let ms = offers.compactMap { id, time in map[id].map { ($0 - time) * 1_000 } }.sorted()
                return ["p50": ms[Int(Double(ms.count - 1) * 0.50)], "p95": ms[Int(Double(ms.count - 1) * 0.95)], "p99": ms[Int(Double(ms.count - 1) * 0.99)]]
            }
            #expect(times.persisted.count == 216 && times.acked.count == 216)
            let report: [String: Any] = ["offered":216,"persisted":times.persisted.count,"acked":times.acked.count,"offer_to_persist_ms":percentiles(times.persisted),"offer_to_ack_ms":percentiles(times.acked),"stages":stages,"limits":"optimized production modules with URLProtocol synthetic V2 transport; fixture CPU included; short idle, not App UI/energy/steady idle or real external service"]
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: output), options: .atomic)
        }
    }
}


@Suite
struct WatchFrozenPullMetadataTests {
    @Test func frozenOriginAndDeviceCannotBeReplacedByCurrentAliases() throws {
        let now = Date(timeIntervalSince1970: 1_234)
        let metadata = try #require(WatchDeliveryMetadata.pulled(deliveryId: " delivery-old ", payload: [
            "base_url": "https://OLD.example/Gateway/", "provider_device_key": " old-device ",
            "gateway_key": "https://new.example", "gateway": "https://new.example", "content_digest": "digest"
        ], now: now))
        #expect(metadata.gatewayKey == "https://old.example/Gateway")
        #expect(metadata.watchDeviceKey == "old-device")
        #expect(metadata.deliveryId == "delivery-old")
        #expect(metadata.persistedAt == now)
        #expect(metadata.contentDigest == "digest")
        #expect(metadata.ingressSource == .watchPull)
        let foreign = try #require(WatchDeliveryMetadata.pulled(deliveryId: "delivery-old", payload: [
            "base_url": "https://different.example/Gateway", "provider_device_key": "old-device"
        ]))
        #expect(metadata.gatewayKey != foreign.gatewayKey)
    }
    @Test func missingOrInvalidFrozenContextIsNotGuessed() {
        #expect(WatchDeliveryMetadata.pulled(deliveryId: "d", payload: ["gateway_key": "https://current.example", "provider_device_key": "device"]) == nil)
        #expect(WatchDeliveryMetadata.pulled(deliveryId: "d", payload: ["base_url": "https://old.example"]) == nil)
        #expect(WatchDeliveryMetadata.pulled(deliveryId: "d", payload: ["base_url": "file:///tmp", "provider_device_key": "device"]) == nil)
        #expect(WatchDeliveryMetadata.pulled(deliveryId: " ", payload: ["base_url": "https://old.example", "provider_device_key": "device"]) == nil)
    }
}
