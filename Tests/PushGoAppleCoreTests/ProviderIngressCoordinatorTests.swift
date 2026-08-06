import Foundation
import os
import Testing
@testable import PushGoAppleCore

private actor ProviderIngressCapture {
    private var results: [ProviderIngressPersistenceResult]
    private(set) var deliveryIds: [String] = []
    private(set) var payloadDeliveryIds: [String?] = []
    private(set) var errors: [String] = []

    init(results: [ProviderIngressPersistenceResult]) {
        self.results = results
    }

    func persist(
        deliveryId: String?,
        payloadDeliveryId: String?
    ) -> ProviderIngressPersistenceResult {
        deliveryIds.append(deliveryId ?? "")
        payloadDeliveryIds.append(payloadDeliveryId)
        return results.isEmpty ? .persisted : results.removeFirst()
    }

    func record(error: Error, source: String) {
        errors.append("\(source):\(error)")
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

struct ProviderIngressCoordinatorTests {
    @Test
    func v2FullSyncTraversesEmptyCorruptPageAndUsesOuterDeliveryIds() async throws {
        try await withIsolatedLocalDataStore { store, appGroupIdentifier in
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
        try await withIsolatedLocalDataStore { store, appGroupIdentifier in
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
            #expect(await context.ackStore.pendingMarkers(limit: 10, minimumAge: 0).count == 1)

            await context.coordinator.drainAckMarkers(source: "test_rejected_drain")
            #expect(await context.ackStore.pendingMarkers(limit: 10, minimumAge: 0).isEmpty)
            #expect(httpState.recordedPaths().filter { $0.hasSuffix("/v2/messages/ack") }.count == 2)
        }
    }

    @Test
    func failedTargetReleasesClaimAndPeerRetryCanPersistAndAck() async throws {
        try await withIsolatedLocalDataStore { store, appGroupIdentifier in
            let host = "provider-claim-\(UUID().uuidString.lowercased()).example"
            let baseURL = try #require(URL(string: "https://\(host)/GatewayA"))
            let page = #"{"success":true,"data":{"items":[{"delivery_id":"target-001","payload":{"title":"target"}}],"has_more":false}}"#
            let httpState = ProviderIngressHTTPState(pullPayloads: [page, page])
            let capture = ProviderIngressCapture(results: [.failed, .persisted])
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
    func legacyFallbackPersistsOuterIdentityWithoutCreatingAckMarker() async throws {
        try await withIsolatedLocalDataStore { store, appGroupIdentifier in
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
            #expect(outcome.appliedCount == 1)
            #expect(await capture.deliveryIds == ["legacy-outer"])
            #expect(await capture.payloadDeliveryIds == ["legacy-outer"])
            #expect(await context.ackStore.pendingMarkers(limit: 10, minimumAge: 0).isEmpty)
            #expect(httpState.recordedPaths() == [
                "/GatewayA/v2/messages/pull",
                "/GatewayA/messages/pull",
            ])
        }
    }

    @Test
    func legacyDirectAckMarkerRetriesThroughSingleItemRoute() async throws {
        try await withIsolatedLocalDataStore { store, appGroupIdentifier in
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
        try await withIsolatedLocalDataStore { store, appGroupIdentifier in
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
    func directAckWithMissingImmutableSourceDoesNotGuessCurrentConfig() async throws {
        try await withIsolatedLocalDataStore { store, appGroupIdentifier in
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
        try await withIsolatedLocalDataStore { store, appGroupIdentifier in
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
            #expect(await context.ackStore.pendingMarkers(limit: 10, minimumAge: 0).count == 1)

            await context.coordinator.drainAckMarkers(source: "test_partial_ack_drain")
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

    private func makeCoordinatorContext(
        host: String,
        baseURL: URL,
        store: LocalDataStore,
        appGroupIdentifier: String,
        httpState: ProviderIngressHTTPState,
        capture: ProviderIngressCapture
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
                persistPayload: { payload, deliveryId in
                    let payloadDeliveryId = payload["delivery_id"] as? String
                    return await capture.persist(
                        deliveryId: deliveryId,
                        payloadDeliveryId: payloadDeliveryId
                    )
                },
                applyPersistenceResult: { _ in },
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
