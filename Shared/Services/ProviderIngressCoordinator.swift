import Foundation

enum ProviderIngressPersistenceResult {
    case persisted
    case duplicate
    case rejected
    case failed

    var isApplied: Bool {
        if case .persisted = self {
            return true
        }
        return false
    }

    var allowsAck: Bool {
        switch self {
        case .persisted, .duplicate:
            return true
        case .rejected, .failed:
            return false
        }
    }

    var allowsPulledItemRemoval: Bool {
        if case .failed = self {
            return false
        }
        return true
    }

    var removesSuccessfulInboxEntry: Bool {
        switch self {
        case .persisted, .duplicate:
            return true
        case .rejected, .failed:
            return false
        }
    }
}

#if !os(watchOS)
extension ProviderIngressPersistenceResult {
    init(_ outcome: NotificationPersistenceOutcome) {
        switch outcome {
        case .persistedMain, .persistedPending:
            self = .persisted
        case .duplicate:
            self = .duplicate
        case .rejected:
            self = .rejected
        case .failed:
            self = .failed
        }
    }
}
#endif

struct ProviderIngressIdentity: Sendable, Equatable {
    let messageId: String?
    let deliveryId: String?
    let requestIdentifier: String?
    let entityType: String?
    let entityId: String?

    init(
        messageId: String?,
        deliveryId: String?,
        requestIdentifier: String? = nil,
        entityType: String? = nil,
        entityId: String? = nil
    ) {
        self.messageId = messageId
        self.deliveryId = deliveryId
        self.requestIdentifier = requestIdentifier
        self.entityType = entityType
        self.entityId = entityId
    }
}

final class ProviderIngressCoordinator {
    private struct AckBatch {
        let baseURL: URL
        let token: String?
        let deviceKey: String
        var leases: [ProviderDeliveryAckFailureStore.PendingMarker]
    }

    enum SyncOutcome {
        case skipped
        case succeeded(appliedCount: Int)
        case failed

        var appliedCount: Int {
            switch self {
            case .succeeded(let appliedCount):
                return appliedCount
            case .skipped, .failed:
                return 0
            }
        }

        var completedRequest: Bool {
            if case .succeeded = self {
                return true
            }
            return false
        }
    }

    struct Hooks {
        let isEnabled: @MainActor () -> Bool
        let serverConfig: @MainActor () -> ServerConfig?
        let cachedDeviceKey: @MainActor () async -> String?
        let hasPersistedNotification: @MainActor (ProviderIngressIdentity) async -> Bool
        let persistPayload: ([AnyHashable: Any], String?) async -> ProviderIngressPersistenceResult
        let applyPersistenceResult: @MainActor (ProviderIngressPersistenceResult) -> Void
        let recordProviderError: @MainActor (Error, String) -> Void
    }

    private let platformSuffix: String
    private let dataStore: LocalDataStore
    private let channelSubscriptionService: ChannelSubscriptionService
    private let notificationIngressInbox: NotificationIngressInbox
    private let ackMarkerStore: ProviderDeliveryAckFailureStore
    private let wakeupPullClaimStore: ProviderWakeupPullClaimStore
    private let gatewayTokenStore: ProviderGatewayTokenStore
    private let hooks: Hooks
    private let ackMarkerMinimumAge: TimeInterval
    private var isDrainingAckMarkers = false
    private var isFullSyncInFlight = false
    private var lastFullSyncAttemptAt = Date.distantPast
    private static let recentFullSyncInterval: TimeInterval = 3
    private static let appAckMarkerMinimumAge: TimeInterval = 120

    init(
        platformSuffix: String,
        dataStore: LocalDataStore,
        channelSubscriptionService: ChannelSubscriptionService,
        notificationIngressInbox: NotificationIngressInbox,
        ackMarkerStore: ProviderDeliveryAckFailureStore,
        wakeupPullClaimStore: ProviderWakeupPullClaimStore,
        gatewayTokenStore: ProviderGatewayTokenStore = ProviderGatewayTokenStore(),
        ackMarkerMinimumAge: TimeInterval = ProviderIngressCoordinator.appAckMarkerMinimumAge,
        hooks: Hooks
    ) {
        self.platformSuffix = platformSuffix
        self.dataStore = dataStore
        self.channelSubscriptionService = channelSubscriptionService
        self.notificationIngressInbox = notificationIngressInbox
        self.ackMarkerStore = ackMarkerStore
        self.wakeupPullClaimStore = wakeupPullClaimStore
        self.gatewayTokenStore = gatewayTokenStore
        self.ackMarkerMinimumAge = ackMarkerMinimumAge
        self.hooks = hooks
    }

    func identity(
        from payload: [AnyHashable: Any],
        fallbackRequestIdentifier: String? = nil
    ) -> ProviderIngressIdentity {
        let sanitized = UserInfoSanitizer.sanitize(payload)
        let requestIdentifier = normalizedText(fallbackRequestIdentifier)
        let entityTarget = NotificationHandling.entityOpenTargetComponents(from: sanitized)
        return ProviderIngressIdentity(
            messageId: NotificationHandling.extractMessageId(from: sanitized),
            deliveryId: providerDeliveryId(from: sanitized),
            requestIdentifier: requestIdentifier,
            entityType: entityTarget?.entityType,
            entityId: entityTarget?.entityId
        )
    }

    @discardableResult
    func mergeInbox(
        reason: String,
        allowFallbackPull: Bool,
        limit: Int = 256
    ) async -> Int {
        guard await hooks.isEnabled() else { return 0 }
        let pendingEntries = await notificationIngressInbox.pendingEntries(limit: limit)
        guard !pendingEntries.isEmpty else {
            await drainAckMarkers(source: "provider.inbox.ack_marker.\(platformSuffix)")
            return 0
        }

        var applied = 0
        for pendingEntry in pendingEntries {
            let payload = pendingEntry.payload
            let identity = identity(
                from: payload,
                fallbackRequestIdentifier: pendingEntry.record.requestIdentifier
            )

            if await hooks.hasPersistedNotification(identity) {
                await notificationIngressInbox.markCompleted(pendingEntry)
                continue
            }

            let ingress = await NotificationHandling.resolveNotificationIngress(
                from: payload,
                dataStore: dataStore,
                fallbackServerConfig: await hooks.serverConfig(),
                channelSubscriptionService: channelSubscriptionService
            )

            let shouldRemove: Bool
            switch ingress {
            case let .pulled(resolvedPayload, requestIdentifier, context):
                let result = await hooks.persistPayload(resolvedPayload, requestIdentifier)
                await hooks.applyPersistenceResult(result)
                if result.isApplied {
                    applied += 1
                }
                await finalizePulledIngress(
                    deliveryId: requestIdentifier,
                    context: context,
                    result: result,
                    source: "provider.inbox.pulled.\(platformSuffix)"
                )
                shouldRemove = shouldRemoveInboxEntry(payload: resolvedPayload, result: result)
            case let .direct(resolvedPayload, requestIdentifier):
                let effectiveRequestIdentifier = requestIdentifier ?? pendingEntry.record.requestIdentifier
                let result = await hooks.persistPayload(resolvedPayload, effectiveRequestIdentifier)
                await hooks.applyPersistenceResult(result)
                if result.isApplied {
                    applied += 1
                }
                await ackDirectDeliveryIfNeeded(
                    payload: resolvedPayload,
                    result: result,
                    source: "provider.inbox.direct.\(platformSuffix)"
                )
                shouldRemove = shouldRemoveInboxEntry(payload: resolvedPayload, result: result)
            case .claimedByPeer:
                shouldRemove = await hooks.hasPersistedNotification(identity)
            case let .unresolvedWakeup(unresolvedPayload, requestIdentifier):
                guard allowFallbackPull else {
                    shouldRemove = false
                    break
                }
                let unresolvedDeliveryId = requestIdentifier
                    ?? NotificationHandling.providerWakeupPullDeliveryId(from: unresolvedPayload)
                    ?? pendingEntry.record.requestIdentifier
                guard let unresolvedDeliveryId else {
                    shouldRemove = false
                    break
                }
                let pulled = await syncProviderIngress(
                    deliveryId: unresolvedDeliveryId,
                    reason: "inbox_unresolved_\(reason)",
                    skipInboxMerge: true
                )
                if pulled > 0 {
                    applied += pulled
                    shouldRemove = true
                } else {
                    shouldRemove = false
                }
            }

            if shouldRemove {
                await notificationIngressInbox.markCompleted(pendingEntry)
            }
        }

        await drainAckMarkers(source: "provider.inbox.ack_marker.\(platformSuffix)")
        return applied
    }

    @discardableResult
    func syncProviderIngress(
        deliveryId: String? = nil,
        reason: String,
        skipInboxMerge: Bool = false
    ) async -> Int {
        let outcome = await syncProviderIngressOutcome(
            deliveryId: deliveryId,
            reason: reason,
            skipInboxMerge: skipInboxMerge
        )
        return outcome.appliedCount
    }

    func syncProviderIngressOutcome(
        deliveryId: String? = nil,
        reason: String,
        skipInboxMerge: Bool = false
    ) async -> SyncOutcome {
        guard await hooks.isEnabled() else { return .skipped }
        let normalizedDeliveryId = normalizedText(deliveryId)
        let shouldCoalesceFullSync = normalizedDeliveryId == nil && !bypassesRecentFullSyncCoalescing(reason: reason)
        if shouldCoalesceFullSync {
            guard !isFullSyncInFlight else { return .skipped }
            guard Date().timeIntervalSince(lastFullSyncAttemptAt) >= Self.recentFullSyncInterval else {
                return .skipped
            }
            isFullSyncInFlight = true
            lastFullSyncAttemptAt = Date()
        }
        defer {
            if shouldCoalesceFullSync {
                isFullSyncInFlight = false
            }
        }

        if !skipInboxMerge {
            _ = await mergeInbox(
                reason: "sync_\(reason)",
                allowFallbackPull: false
            )
        }
        guard let config = await hooks.serverConfig() else { return .skipped }
        guard let deviceKey = await hooks.cachedDeviceKey() else { return .skipped }
        _ = gatewayTokenStore.save(token: config.token, baseURL: config.baseURL)
        var wakeupPullLease: ProviderWakeupPullClaimStore.ClaimLease?
        if let normalizedDeliveryId {
            guard let identity = ProviderDeliveryAckFailureStore.DeliveryIdentity(
                deliveryId: normalizedDeliveryId,
                baseURL: config.baseURL,
                deviceKey: deviceKey,
                ackContract: .v2Batch
            ) else {
                return .skipped
            }
            guard let lease = await wakeupPullClaimStore.acquireLease(
                identity: identity,
                owner: "app.sync.\(platformSuffix)",
                leaseDuration: 30
            ) else {
                return .skipped
            }
            wakeupPullLease = lease
        }

        do {
            var applied = 0
            var targetPersistenceFailed = false
            var mayContinue = true
            while mayContinue {
                try Task.checkCancellation()
                let pullResult = try await channelSubscriptionService.pullMessages(
                    baseURL: config.baseURL,
                    token: config.token,
                    deviceKey: deviceKey,
                    deliveryId: normalizedDeliveryId
                )
                var deliveryIdsToAck: [String] = []
                var pageContainsFailedItem = false
                for item in pullResult.items {
                    var payload: [AnyHashable: Any] = item.payload.reduce(into: [:]) { result, element in
                        result[element.key] = element.value
                    }
                    payload["delivery_id"] = item.deliveryId
                    let result = await hooks.persistPayload(payload, item.deliveryId)
                    await hooks.applyPersistenceResult(result)
                    if result.isApplied {
                        applied += 1
                    }
                    if case .failed = result {
                        pageContainsFailedItem = true
                        if normalizedDeliveryId == item.deliveryId {
                            targetPersistenceFailed = true
                        }
                    }
                    if pullResult.requiresAck, result.allowsPulledItemRemoval {
                        guard let identity = ProviderDeliveryAckFailureStore.DeliveryIdentity(
                            deliveryId: item.deliveryId,
                            baseURL: config.baseURL,
                            deviceKey: deviceKey,
                            ackContract: .v2Batch
                        ) else {
                            pageContainsFailedItem = true
                            continue
                        }
                        _ = await ackMarkerStore.markInboxDurable(
                            identity: identity,
                            source: "provider.pull.persisted.\(platformSuffix)",
                            postNotification: false
                        )
                        deliveryIdsToAck.append(item.deliveryId)
                    }
                }

                var ackSucceeded = true
                if !deliveryIdsToAck.isEmpty {
                    do {
                        let ack = try await channelSubscriptionService.ackMessages(
                            baseURL: config.baseURL,
                            token: config.token,
                            deviceKey: deviceKey,
                            deliveryIds: deliveryIdsToAck
                        )
                        guard ack.removedCount == deliveryIdsToAck.count else {
                            throw Self.incompleteFreshAckError(
                                requested: deliveryIdsToAck.count,
                                removed: ack.removedCount
                            )
                        }
                        for deliveryId in deliveryIdsToAck {
                            if let identity = ProviderDeliveryAckFailureStore.DeliveryIdentity(
                                deliveryId: deliveryId,
                                baseURL: config.baseURL,
                                deviceKey: deviceKey,
                                ackContract: .v2Batch
                            ) {
                                await ackMarkerStore.markCompleted(identity: identity)
                            }
                        }
                    } catch {
                        ackSucceeded = false
                        await hooks.recordProviderError(
                            error,
                            "provider.ingress.ack_batch.\(reason)"
                        )
                    }
                }

                mayContinue = pullResult.hasMore && !pageContainsFailedItem && ackSucceeded
            }
            if let wakeupPullLease {
                if targetPersistenceFailed {
                    await wakeupPullClaimStore.releaseLease(wakeupPullLease)
                } else {
                    await wakeupPullClaimStore.markCompleted(wakeupPullLease)
                }
            }
            return targetPersistenceFailed ? .failed : .succeeded(appliedCount: applied)
        } catch {
            if let wakeupPullLease {
                await wakeupPullClaimStore.releaseLease(wakeupPullLease)
            }
            await hooks.recordProviderError(error, "provider.ingress.\(reason)")
            return .failed
        }
    }

    @discardableResult
    func purgePendingUnresolvedWakeupEntries(limit: Int = 256) async -> Int {
        guard await hooks.isEnabled() else { return 0 }
        let pendingEntries = await notificationIngressInbox.pendingEntries(limit: limit)
        guard !pendingEntries.isEmpty else { return 0 }

        var removed = 0
        for pendingEntry in pendingEntries {
            let payload = pendingEntry.payload
            guard NotificationHandling.providerWakeupPullDeliveryId(from: payload) != nil else {
                continue
            }
            let identity = identity(
                from: payload,
                fallbackRequestIdentifier: pendingEntry.record.requestIdentifier
            )
            if await hooks.hasPersistedNotification(identity) {
                await notificationIngressInbox.markCompleted(pendingEntry)
                removed += 1
                continue
            }
            await notificationIngressInbox.markCompleted(pendingEntry)
            removed += 1
        }
        return removed
    }

    func ackDirectDeliveryIfNeeded(
        payload: [AnyHashable: Any],
        result: ProviderIngressPersistenceResult,
        source: String
    ) async {
        guard result.allowsAck else { return }
        guard NotificationHandling.providerWakeupPullDeliveryId(from: payload) == nil else { return }
        let sanitized = UserInfoSanitizer.sanitize(payload)
        guard let identity = ProviderDeliveryAckFailureStore.DeliveryIdentity.direct(from: sanitized) else { return }
        await ackDelivery(
            identity: identity,
            source: source
        )
    }

    func finalizePulledIngress(
        deliveryId: String,
        context: ProviderPullContext,
        result: ProviderIngressPersistenceResult,
        source: String
    ) async {
        guard result.allowsPulledItemRemoval else {
            await wakeupPullClaimStore.releaseLease(context.claimLease)
            return
        }

        if context.requiresAck {
            guard let identity = ProviderDeliveryAckFailureStore.DeliveryIdentity(
                deliveryId: deliveryId,
                baseURL: context.baseURL,
                deviceKey: context.deviceKey,
                ackContract: .v2Batch
            ) else {
                await wakeupPullClaimStore.releaseLease(context.claimLease)
                return
            }
            _ = await ackMarkerStore.markInboxDurable(
                identity: identity,
                source: "\(source).durable",
                postNotification: false
            )
        }
        await wakeupPullClaimStore.markCompleted(context.claimLease)
        guard context.requiresAck else { return }

        do {
            let ack = try await channelSubscriptionService.ackMessages(
                baseURL: context.baseURL,
                token: context.token,
                deviceKey: context.deviceKey,
                deliveryIds: [deliveryId]
            )
            guard ack.removedCount == 1 else {
                throw Self.incompleteFreshAckError(requested: 1, removed: ack.removedCount)
            }
            if let identity = ProviderDeliveryAckFailureStore.DeliveryIdentity(
                deliveryId: deliveryId,
                baseURL: context.baseURL,
                deviceKey: context.deviceKey,
                ackContract: .v2Batch
            ) {
                await ackMarkerStore.markCompleted(identity: identity)
            }
        } catch {
            await hooks.recordProviderError(error, source)
        }
    }

    func drainAckMarkers(source: String) async {
        guard await hooks.isEnabled(), !isDrainingAckMarkers else { return }
        isDrainingAckMarkers = true
        defer { isDrainingAckMarkers = false }

        let markers = await ackMarkerStore.pendingMarkers(
            limit: 64,
            minimumAge: ackMarkerMinimumAge
        )
        var batches: [String: AckBatch] = [:]
        for marker in markers {
            guard let identity = marker.identity else { continue }
            let baseURL = identity.baseURL
            let token = gatewayTokenStore.load(baseURL: baseURL)
            guard let lease = await ackMarkerStore.acquireAckLease(
                marker,
                owner: "app.\(platformSuffix)",
                leaseDuration: 30
            ) else {
                continue
            }
            if lease.ackContract == .legacySingle {
                do {
                    let removed = try await channelSubscriptionService.ackMessage(
                        baseURL: baseURL,
                        token: token,
                        deviceKey: identity.deviceKey,
                        deliveryId: lease.record.deliveryId
                    )
                    guard removed || lease.attemptCount > 0 else {
                        throw Self.incompleteFreshAckError(requested: 1, removed: 0)
                    }
                    await ackMarkerStore.markCompleted(lease)
                } catch {
                    await ackMarkerStore.markAckFailed(
                        lease,
                        source: "\(source).failed",
                        retryAfter: Date().addingTimeInterval(60),
                        postNotification: false
                    )
                    await hooks.recordProviderError(error, source)
                }
                continue
            }
            let batchKey = Self.ackBatchKey(for: baseURL) + "\u{0}" + identity.deviceKey
            if var batch = batches[batchKey] {
                batch.leases.append(lease)
                batches[batchKey] = batch
            } else {
                batches[batchKey] = AckBatch(
                    baseURL: baseURL,
                    token: token,
                    deviceKey: identity.deviceKey,
                    leases: [lease]
                )
            }
        }

        for batch in batches.values {
            do {
                _ = try await channelSubscriptionService.ackMessages(
                    baseURL: batch.baseURL,
                    token: batch.token,
                    deviceKey: batch.deviceKey,
                    deliveryIds: batch.leases.map(\.record.deliveryId)
                )
                for lease in batch.leases {
                    await ackMarkerStore.markCompleted(lease)
                }
            } catch {
                for lease in batch.leases {
                    await ackMarkerStore.markAckFailed(
                        lease,
                        source: "\(source).failed",
                        retryAfter: Date().addingTimeInterval(60),
                        postNotification: false
                    )
                }
                await hooks.recordProviderError(error, source)
            }
        }
    }

    private func ackDelivery(
        identity: ProviderDeliveryAckFailureStore.DeliveryIdentity,
        source: String
    ) async {
        _ = await ackMarkerStore.markInboxDurable(
            identity: identity,
            source: "\(source).pending",
            postNotification: false
        )
        guard let lease = await ackMarkerStore.acquireAckLease(
            identity: identity,
            owner: "app.direct.\(platformSuffix)",
            leaseDuration: 30
        ) else {
            return
        }

        do {
            let removed = try await channelSubscriptionService.ackMessage(
                baseURL: identity.baseURL,
                token: gatewayTokenStore.load(baseURL: identity.baseURL),
                deviceKey: identity.deviceKey,
                deliveryId: identity.deliveryId
            )
            guard removed || lease.attemptCount > 0 else {
                throw Self.incompleteFreshAckError(requested: 1, removed: 0)
            }
            await ackMarkerStore.markCompleted(lease)
        } catch {
            await ackMarkerStore.markAckFailed(
                lease,
                source: "\(source).failed",
                retryAfter: Date().addingTimeInterval(60),
                postNotification: false
            )
            await hooks.recordProviderError(error, source)
        }
    }

    private func shouldRemoveInboxEntry(
        payload: [AnyHashable: Any],
        result: ProviderIngressPersistenceResult
    ) -> Bool {
        if result.removesSuccessfulInboxEntry {
            return true
        }
        if case .rejected = result {
            return NotificationHandling.providerWakeupPullDeliveryId(from: payload) == nil
        }
        return false
    }

    private func bypassesRecentFullSyncCoalescing(reason: String) -> Bool {
        let normalized = reason.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.contains("pull_to_refresh") || normalized.contains("manual")
    }

    static func ackBatchKey(for baseURL: URL) -> String {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            return baseURL.absoluteString
        }
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        return components.string ?? baseURL.absoluteString
    }

    private static func incompleteFreshAckError(requested: Int, removed: Int) -> AppError {
        AppError.typedLocal(
            code: "gateway_ack_incomplete",
            category: .conflict,
            message: LocalizationProvider.localized("operation_failed"),
            detail: "fresh batch ack removed \(removed) of \(requested) deliveries"
        )
    }

    private func providerDeliveryId(from payload: [AnyHashable: Any]) -> String? {
        let sanitized = UserInfoSanitizer.sanitize(payload)
        return normalizedText(sanitized["delivery_id"] as? String)
    }

    private func normalizedText(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}
