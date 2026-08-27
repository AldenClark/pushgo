import Foundation

enum ProviderLegacyDestructivePullMetadata {
    static let markerKey = "_pushgo_legacy_destructive_pull"
    static let markerValue = "1"
}

@MainActor
struct IngressBackgroundRefreshRunner {
    enum Stage: Sendable, Equatable {
        case canonicalIngress
        case acknowledgements
        case derivedWork
    }

    enum StageOutcome: Sendable, Equatable {
        case succeeded
        case failed
    }

    enum Outcome: Sendable, Equatable {
        case succeeded
        case failed(Stage)
        case cancelled

        var isSuccessful: Bool { self == .succeeded }
    }

    typealias StageOperation = @MainActor @Sendable () async -> StageOutcome

    let mergeIngress: StageOperation
    let drainAcknowledgements: StageOperation
    let drainDerivedWork: StageOperation

    func run() async -> Outcome {
        guard !Task.isCancelled else { return .cancelled }
        guard await mergeIngress() == .succeeded else {
            return Task.isCancelled ? .cancelled : .failed(.canonicalIngress)
        }
        guard !Task.isCancelled else { return .cancelled }
        guard await drainAcknowledgements() == .succeeded else {
            return Task.isCancelled ? .cancelled : .failed(.acknowledgements)
        }
        guard !Task.isCancelled else { return .cancelled }
        guard await drainDerivedWork() == .succeeded else {
            return Task.isCancelled ? .cancelled : .failed(.derivedWork)
        }
        return Task.isCancelled ? .cancelled : .succeeded
    }
}

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

enum ProviderInboxProgress: Sendable, Equatable {
    case processing(completed: Int, total: Int)
    case waitingRetry(remaining: Int)
    case completed(processed: Int)
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

/// Owns all host-process ingress coordination on the main actor. Storage and
/// network APIs suspend without blocking it, while legacy notification
/// dictionaries never cross an unchecked Sendable boundary.
@MainActor
final class ProviderIngressCoordinator {
    // Payloads are sanitized and treated as immutable before entering a batch.
    // Foundation's heterogeneous dictionary cannot express that guarantee.
    struct PersistenceInput: @unchecked Sendable {
        let payload: [AnyHashable: Any]
        let requestIdentifier: String?
    }

    private struct DurablePulledItem {
        let payload: [AnyHashable: Any]
        let deliveryID: String
        let ackIdentity: ProviderDeliveryAckFailureStore.DeliveryIdentity?
        let ingressIdentity: ProviderDeliveryAckFailureStore.DeliveryIdentity
    }

    private enum InboxFinalization {
        case direct
        case pulled(requestIdentifier: String, context: ProviderPullContext)
    }

    private struct ResolvedInboxItem {
        let claimed: NotificationIngressInbox.ClaimedEntry
        let payload: [AnyHashable: Any]
        let requestIdentifier: String?
        let finalization: InboxFinalization
    }

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
        let persistPayloads: @MainActor ([PersistenceInput]) async -> [ProviderIngressPersistenceResult]
        let applyPersistenceResults: @MainActor ([ProviderIngressPersistenceResult]) -> Void
        let reportInboxProgress: @MainActor (ProviderInboxProgress) -> Void
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
    private var inboxMergeTask: Task<Int, Never>?
    private var inboxMergeRequested = false
    private var pendingInboxAllowsFallbackPull = false
    private var pendingInboxLimit = 64
    private var pendingInboxReason = "unspecified"
    private let inboxApplyOwner = "app.ingress.\(UUID().uuidString.lowercased())"
    private static let recentFullSyncInterval: TimeInterval = 3
    // NSE never owns correctness-critical network work. The host may claim a
    // freshly durable ACK immediately; duplicate workers are fenced by lease.
    private static let appAckMarkerMinimumAge: TimeInterval = 0

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
    @MainActor
    func mergeInbox(
        reason: String,
        allowFallbackPull: Bool,
        limit: Int = 256
    ) async -> Int {
        inboxMergeRequested = true
        pendingInboxAllowsFallbackPull = pendingInboxAllowsFallbackPull || allowFallbackPull
        pendingInboxLimit = max(pendingInboxLimit, min(512, max(1, limit)))
        pendingInboxReason = reason
        if let inboxMergeTask {
            return await inboxMergeTask.value
        }
        let task = Task { @MainActor [weak self] in
            guard let self else { return 0 }
            var totalApplied = 0
            repeat {
                inboxMergeRequested = false
                let runAllowsFallbackPull = pendingInboxAllowsFallbackPull
                let runLimit = pendingInboxLimit
                let runReason = pendingInboxReason
                pendingInboxAllowsFallbackPull = false
                pendingInboxLimit = 64
                totalApplied += await performMergeInbox(
                    reason: runReason,
                    allowFallbackPull: runAllowsFallbackPull,
                    limit: runLimit
                )
            } while inboxMergeRequested && !Task.isCancelled
            inboxMergeTask = nil
            return totalApplied
        }
        inboxMergeTask = task
        return await task.value
    }

    @MainActor
    private func performMergeInbox(
        reason: String,
        allowFallbackPull: Bool,
        limit: Int
    ) async -> Int {
        guard !Task.isCancelled, hooks.isEnabled() else { return 0 }
        let steadyStateBatchSize = max(1, min(limit, 200))
        var batchSize = min(64, steadyStateBatchSize)
        let maximumEntriesPerDrain = 8_192
        var applied = 0
        var visited = 0
        var settled = 0
        await notificationIngressInbox.prepareForDrain()
        let initialCounts = await notificationIngressInbox.queueCounts(
            importLegacyState: false
        )
        var progressTotal = initialCounts.outstanding
        if initialCounts.due > 0 {
            hooks.reportInboxProgress(
                .processing(completed: 0, total: progressTotal)
            )
        } else if initialCounts.outstanding > 0 {
            hooks.reportInboxProgress(
                .waitingRetry(remaining: initialCounts.outstanding)
            )
        }

        while visited < maximumEntriesPerDrain {
            guard !Task.isCancelled else { return applied }
            let claimedEntries = await notificationIngressInbox.claimPendingEntries(
                owner: inboxApplyOwner,
                leaseDuration: 60,
                limit: batchSize,
                importLegacyState: false
            )
            guard !claimedEntries.isEmpty else { break }
            var resolvedItems: [ResolvedInboxItem] = []
            resolvedItems.reserveCapacity(claimedEntries.count)
            var completedClaims: [NotificationIngressInbox.ClaimedEntry] = []
            completedClaims.reserveCapacity(claimedEntries.count)
            for claimedEntry in claimedEntries {
                guard !Task.isCancelled else { return applied }
                visited += 1
                let payload = claimedEntry.payload
                let identity = identity(
                    from: payload,
                    fallbackRequestIdentifier: claimedEntry.record.requestIdentifier
                )

                if await hooks.hasPersistedNotification(identity) {
                    completedClaims.append(claimedEntry)
                    continue
                }

                let ingress = await NotificationHandling.resolveNotificationIngress(
                    from: payload,
                    dataStore: dataStore,
                    fallbackServerConfig: hooks.serverConfig(),
                    channelSubscriptionService: channelSubscriptionService,
                    notificationIngressInbox: notificationIngressInbox,
                    allowLegacyFallback: allowFallbackPull
                )
                guard !Task.isCancelled else { return applied }

                switch ingress {
                case let .pulled(resolvedPayload, requestIdentifier, context):
                    guard await journalPulledPayload(
                        resolvedPayload,
                        deliveryID: requestIdentifier,
                        context: context,
                        source: "provider.inbox.pull.\(platformSuffix)"
                    ) else {
                        _ = await notificationIngressInbox.markRetry(
                            claimedEntry,
                            reason: "pulled_payload_journal_failed"
                        )
                        continue
                    }
                    resolvedItems.append(
                        ResolvedInboxItem(
                            claimed: claimedEntry,
                            payload: resolvedPayload,
                            requestIdentifier: requestIdentifier,
                            finalization: .pulled(
                                requestIdentifier: requestIdentifier,
                                context: context
                            )
                        )
                    )
                case let .direct(resolvedPayload, requestIdentifier):
                    resolvedItems.append(
                        ResolvedInboxItem(
                            claimed: claimedEntry,
                            payload: resolvedPayload,
                            requestIdentifier: requestIdentifier
                                ?? claimedEntry.record.requestIdentifier,
                            finalization: .direct
                        )
                    )
                case .claimedByPeer:
                    if await hooks.hasPersistedNotification(identity) {
                        completedClaims.append(claimedEntry)
                    } else {
                        _ = await notificationIngressInbox.markRetry(
                            claimedEntry,
                            reason: "canonical_claimed_by_peer"
                        )
                    }
                case let .unresolvedWakeup(unresolvedPayload, requestIdentifier):
                    guard allowFallbackPull else {
                        _ = await notificationIngressInbox.markRetry(
                            claimedEntry,
                            reason: "fallback_pull_disabled"
                        )
                        break
                    }
                    let unresolvedDeliveryId = requestIdentifier
                        ?? NotificationHandling.providerWakeupPullDeliveryId(from: unresolvedPayload)
                        ?? claimedEntry.record.requestIdentifier
                    guard let unresolvedDeliveryId else {
                        _ = await notificationIngressInbox.markRetry(
                            claimedEntry,
                            reason: "unresolved_delivery_identity"
                        )
                        break
                    }
                    // Provider I/O is owned by the separate pull-claim lease. Do
                    // not hold the canonical-apply lease across the network.
                    _ = await notificationIngressInbox.markRetry(
                        claimedEntry,
                        reason: "handoff_to_provider_pull",
                        retryAfter: Date().addingTimeInterval(30)
                    )
                    let pulled = await syncProviderIngress(
                        deliveryId: unresolvedDeliveryId,
                        reason: "inbox_unresolved_\(reason)",
                        skipInboxMerge: true
                    )
                    if pulled > 0 {
                        applied += pulled
                    }
                }
            }

            if !resolvedItems.isEmpty {
                let results = await persistPayloads(
                    resolvedItems.map {
                        PersistenceInput(
                            payload: $0.payload,
                            requestIdentifier: $0.requestIdentifier
                        )
                    }
                )
                hooks.applyPersistenceResults(results)
                for (item, result) in zip(resolvedItems, results) {
                    if result.isApplied { applied += 1 }
                    let shouldRemove = shouldRemoveInboxEntry(
                        payload: item.payload,
                        result: result
                    )
                    if shouldRemove {
                        completedClaims.append(item.claimed)
                    } else {
                        _ = await notificationIngressInbox.markRetry(
                            item.claimed,
                            reason: "canonical_or_resolution_retry"
                        )
                    }
                }
                settled += await notificationIngressInbox.markCompleted(completedClaims)
                for (item, result) in zip(resolvedItems, results) {
                    switch item.finalization {
                    case .direct:
                        await ackDirectDeliveryIfNeeded(
                            payload: item.payload,
                            result: result,
                            source: "provider.inbox.direct.\(platformSuffix)"
                        )
                    case let .pulled(requestIdentifier, context):
                        await finalizePulledIngress(
                            deliveryId: requestIdentifier,
                            context: context,
                            result: result,
                            source: "provider.inbox.pulled.\(platformSuffix)"
                        )
                    }
                }
            } else {
                settled += await notificationIngressInbox.markCompleted(completedClaims)
            }
            let currentCounts = await notificationIngressInbox.queueCounts(
                importLegacyState: false
            )
            progressTotal = max(progressTotal, settled + currentCounts.outstanding)
            if progressTotal > 0 {
                hooks.reportInboxProgress(
                    .processing(completed: settled, total: progressTotal)
                )
            }
            if claimedEntries.count < batchSize { break }
            batchSize = steadyStateBatchSize
        }

        _ = await notificationIngressInbox.performMaintenance()
        let finalCounts = await notificationIngressInbox.queueCounts(
            importLegacyState: false
        )
        if finalCounts.outstanding > 0 {
            hooks.reportInboxProgress(
                .waitingRetry(remaining: finalCounts.outstanding)
            )
        } else if progressTotal > 0 {
            hooks.reportInboxProgress(.completed(processed: settled))
        }
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
        guard !Task.isCancelled, hooks.isEnabled() else { return .skipped }
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
        guard !Task.isCancelled else { return .skipped }
        guard let config = hooks.serverConfig() else { return .skipped }
        guard !Task.isCancelled else { return .skipped }
        guard let deviceKey = await hooks.cachedDeviceKey() else { return .skipped }
        guard !Task.isCancelled else { return .skipped }
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
            guard !Task.isCancelled else { return .skipped }
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
                var durableItems: [DurablePulledItem] = []
                for item in pullResult.items {
                    var payload: [AnyHashable: Any] = item.payload.reduce(into: [:]) { result, element in
                        result[element.key] = element.value
                    }
                    payload["delivery_id"] = item.deliveryId
                    guard let ingressIdentity = ProviderDeliveryAckFailureStore.DeliveryIdentity(
                        deliveryId: item.deliveryId,
                        baseURL: config.baseURL,
                        deviceKey: deviceKey,
                        ackContract: pullResult.requiresAck ? .v2Batch : .legacySingle
                    ) else {
                        pageContainsFailedItem = true
                        continue
                    }
                    let ackIdentity = pullResult.requiresAck ? ingressIdentity : nil
                    guard await journalPulledPayload(
                        payload,
                        deliveryID: item.deliveryId,
                        contract: pullResult.contract,
                        baseURL: config.baseURL,
                        deviceKey: deviceKey,
                        source: "provider.pull.page.\(platformSuffix)"
                    ) else {
                        pageContainsFailedItem = true
                        if normalizedDeliveryId == item.deliveryId {
                            targetPersistenceFailed = true
                        }
                        continue
                    }
                    durableItems.append(
                        DurablePulledItem(
                            payload: payload,
                            deliveryID: item.deliveryId,
                            ackIdentity: ackIdentity,
                            ingressIdentity: ingressIdentity
                        )
                    )
                }

                try Task.checkCancellation()
                let persistenceResults = await persistPayloads(
                    durableItems.map {
                        PersistenceInput(
                            payload: $0.payload,
                            requestIdentifier: $0.deliveryID
                        )
                    }
                )
                hooks.applyPersistenceResults(persistenceResults)
                for (item, result) in zip(durableItems, persistenceResults) {
                    try Task.checkCancellation()
                    if result.isApplied {
                        applied += 1
                    }
                    if case .failed = result {
                        pageContainsFailedItem = true
                        if normalizedDeliveryId == item.deliveryID {
                            targetPersistenceFailed = true
                        }
                    }
                    if item.ackIdentity == nil {
                        if result.allowsPulledItemRemoval {
                            await notificationIngressInbox.markTerminal(
                                identity: item.ingressIdentity,
                                discarded: {
                                    if case .rejected = result { return true }
                                    return false
                                }(),
                                reason: "canonical_validation_rejected"
                            )
                        }
                    } else {
                        switch result {
                        case .persisted, .duplicate:
                            await notificationIngressInbox.markTerminal(
                                identity: item.ingressIdentity,
                                discarded: false
                            )
                        case .rejected:
                            await notificationIngressInbox.markTerminal(
                                identity: item.ingressIdentity,
                                discarded: true,
                                reason: "canonical_validation_rejected"
                            )
                        case .failed:
                            break
                        }
                    }
                    if pullResult.requiresAck, result.allowsPulledItemRemoval {
                        guard item.ackIdentity != nil else {
                            pageContainsFailedItem = true
                            continue
                        }
                        deliveryIdsToAck.append(item.deliveryID)
                    }
                }

                var ackSucceeded = true
                if !deliveryIdsToAck.isEmpty {
                    var pageAckLeases: [ProviderDeliveryAckFailureStore.PendingMarker] = []
                    for deliveryID in deliveryIdsToAck {
                        try Task.checkCancellation()
                        let identity = ProviderDeliveryAckFailureStore.DeliveryIdentity(
                            deliveryId: deliveryID,
                            baseURL: config.baseURL,
                            deviceKey: deviceKey,
                            ackContract: .v2Batch
                        )
                        guard let lease = await ackMarkerStore.acquireAckLease(
                            identity: identity,
                            owner: "app.page.\(platformSuffix)",
                            leaseDuration: 30
                        ) else {
                            ackSucceeded = false
                            break
                        }
                        pageAckLeases.append(lease)
                    }
                    do {
                        try Task.checkCancellation()
                        guard ackSucceeded,
                              pageAckLeases.count == deliveryIdsToAck.count
                        else {
                            throw Self.incompleteFreshAckError(
                                requested: deliveryIdsToAck.count,
                                removed: 0
                            )
                        }
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
                        for lease in pageAckLeases {
                            await ackMarkerStore.markCompleted(lease)
                        }
                    } catch is CancellationError {
                        for lease in pageAckLeases {
                            await ackMarkerStore.markAckFailed(
                                lease,
                                source: "provider.ingress.ack_batch.\(reason).cancelled",
                                retryAfter: Date(),
                                postNotification: false
                            )
                        }
                        throw CancellationError()
                    } catch {
                        ackSucceeded = false
                        for lease in pageAckLeases {
                            await ackMarkerStore.markAckFailed(
                                lease,
                                source: "provider.ingress.ack_batch.\(reason).failed",
                                retryAfter: Date().addingTimeInterval(30),
                                postNotification: false
                            )
                        }
                        hooks.recordProviderError(
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
            hooks.recordProviderError(error, "provider.ingress.\(reason)")
            return .failed
        }
    }

    private func persistPayloads(
        _ inputs: [PersistenceInput]
    ) async -> [ProviderIngressPersistenceResult] {
        guard !inputs.isEmpty else { return [] }
        let results = await hooks.persistPayloads(inputs)
        guard results.count == inputs.count else {
            return Array(repeating: .failed, count: inputs.count)
        }
        return results
    }

    @discardableResult
    func purgePendingUnresolvedWakeupEntries(limit: Int = 256) async -> Int {
        guard hooks.isEnabled() else { return 0 }
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
            }
            // A successful sync against the current Gateway is not evidence
            // that a hint from another immutable Gateway/device identity is
            // obsolete. Keep unresolved hints until canonical persistence (or
            // a future, identity-matched deterministic discard) proves that
            // their recovery role has ended.
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
        guard sanitized[ProviderLegacyDestructivePullMetadata.markerKey] as? String
            != ProviderLegacyDestructivePullMetadata.markerValue
        else { return }
        guard let identity = ProviderDeliveryAckFailureStore.DeliveryIdentity.direct(from: sanitized) else { return }
        _ = await ackMarkerStore.markInboxDurable(
            identity: identity,
            source: "\(source).pending",
            postNotification: false
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

        guard let identity = ProviderDeliveryAckFailureStore.DeliveryIdentity(
            deliveryId: deliveryId,
            baseURL: context.baseURL,
            deviceKey: context.deviceKey,
            ackContract: context.requiresAck ? .v2Batch : .legacySingle
        ) else {
            await wakeupPullClaimStore.releaseLease(context.claimLease)
            return
        }
        if context.requiresAck {
            switch result {
            case .persisted, .duplicate:
                await notificationIngressInbox.markTerminal(
                    identity: identity,
                    discarded: false
                )
            case .rejected:
                await notificationIngressInbox.markTerminal(
                    identity: identity,
                    discarded: true,
                    reason: "canonical_validation_rejected"
                )
            case .failed:
                break
            }
        } else {
            await notificationIngressInbox.markTerminal(
                identity: identity,
                discarded: {
                    if case .rejected = result { return true }
                    return false
                }(),
                reason: "canonical_validation_rejected"
            )
        }
        await wakeupPullClaimStore.markCompleted(context.claimLease)
        // ACK is owned by the durable worker. Canonical persistence and
        // notification presentation never wait for Gateway network I/O.
    }

    @discardableResult
    func journalPulledPayload(
        _ payload: [AnyHashable: Any],
        deliveryID: String,
        context: ProviderPullContext,
        source: String
    ) async -> Bool {
        await journalPulledPayload(
            payload,
            deliveryID: deliveryID,
            contract: context.contract,
            baseURL: context.baseURL,
            deviceKey: context.deviceKey,
            source: source
        )
    }

    private func journalPulledPayload(
        _ payload: [AnyHashable: Any],
        deliveryID: String,
        contract: ChannelSubscriptionService.PullContract,
        baseURL: URL,
        deviceKey: String,
        source: String
    ) async -> Bool {
        let requiresAck = contract == .v2
        let identity = requiresAck
            ? ProviderDeliveryAckFailureStore.DeliveryIdentity(
                deliveryId: deliveryID,
                baseURL: baseURL,
                deviceKey: deviceKey,
                ackContract: .v2Batch
            )
            : nil
        if requiresAck, identity == nil { return false }
        var durablePayload = UserInfoSanitizer.sanitize(payload)
        if !requiresAck {
            durablePayload["base_url"] = baseURL.absoluteString
            durablePayload["provider_device_key"] = deviceKey
            durablePayload[ProviderLegacyDestructivePullMetadata.markerKey] =
                ProviderLegacyDestructivePullMetadata.markerValue
        }
        let codablePayload = durablePayload.reduce(
            into: [String: AnyCodable]()
        ) { result, element in
            result[element.key] = AnyCodable(element.value)
        }
        return await notificationIngressInbox.enqueue(
            codablePayload: codablePayload,
            requestIdentifier: deliveryID,
            source: source,
            ackIdentity: identity,
            requiredEntryState: requiresAck ? "terminal_local" : "durable"
        )
    }

    func drainAckMarkers(source: String, now: Date = Date()) async {
        guard !Task.isCancelled, hooks.isEnabled(), !isDrainingAckMarkers else { return }
        isDrainingAckMarkers = true
        defer { isDrainingAckMarkers = false }

        let markers = await ackMarkerStore.pendingMarkers(
            limit: 64,
            minimumAge: ackMarkerMinimumAge,
            now: now
        )
        var batches: [String: AckBatch] = [:]
        for marker in markers {
            guard !Task.isCancelled else { return }
            guard let identity = marker.identity else { continue }
            let baseURL = identity.baseURL
            let token = gatewayTokenStore.load(baseURL: baseURL)
            guard let lease = await ackMarkerStore.acquireAckLease(
                marker,
                owner: "app.\(platformSuffix)",
                leaseDuration: 30,
                now: now
            ) else {
                continue
            }
            guard !Task.isCancelled else {
                await ackMarkerStore.markAckFailed(
                    lease,
                    source: "\(source).cancelled",
                    retryAfter: now,
                    postNotification: false
                )
                return
            }
            if lease.ackContract == .legacySingle {
                do {
                    try Task.checkCancellation()
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
                    hooks.recordProviderError(error, source)
                }
                guard !Task.isCancelled else { return }
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
            guard !Task.isCancelled else {
                for lease in batch.leases {
                    await ackMarkerStore.markAckFailed(
                        lease,
                        source: "\(source).cancelled",
                        retryAfter: now,
                        postNotification: false
                    )
                }
                return
            }
            do {
                try Task.checkCancellation()
                let response = try await channelSubscriptionService.ackMessages(
                    baseURL: batch.baseURL,
                    token: batch.token,
                    deviceKey: batch.deviceKey,
                    deliveryIds: batch.leases.map(\.record.deliveryId)
                )
                let requested = batch.leases.count
                let idempotentZero = response.removedCount == 0
                    && batch.leases.allSatisfy { $0.attemptCount > 0 }
                guard response.requestedCount == requested,
                      response.removedCount == requested || idempotentZero
                else {
                    throw Self.incompleteFreshAckError(
                        requested: requested,
                        removed: response.removedCount
                    )
                }
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
                hooks.recordProviderError(error, source)
            }
        }
        _ = await notificationIngressInbox.performMaintenance()
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
