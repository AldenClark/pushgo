import CryptoKit
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
    // Proven per-item identity conflict; it remains unacknowledged and durable.
    // Unlike an unknown database failure, it does not invalidate peer writes.
    case identityConflict
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
        case .rejected, .identityConflict, .failed:
            return false
        }
    }

    var allowsPulledItemRemoval: Bool {
        switch self {
        case .identityConflict, .failed: false
        case .persisted, .duplicate, .rejected: true
        }
    }

    var removesSuccessfulInboxEntry: Bool {
        switch self {
        case .persisted, .duplicate:
            return true
        case .rejected, .identityConflict, .failed:
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
        case .identityConflict:
            self = .identityConflict
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
    let sourceBaseURL: String?
    let isWakeup: Bool

    init(
        messageId: String?,
        deliveryId: String?,
        requestIdentifier: String? = nil,
        entityType: String? = nil,
        entityId: String? = nil,
        sourceBaseURL: String? = nil,
        isWakeup: Bool = false
    ) {
        self.messageId = messageId
        self.deliveryId = deliveryId
        self.requestIdentifier = requestIdentifier
        self.entityType = entityType
        self.entityId = entityId
        self.sourceBaseURL = sourceBaseURL
        self.isWakeup = isWakeup
    }

    func matchesPersisted(_ message: PushMessage) -> Bool {
        if let sourceBaseURL {
            return message.providerSourceBaseURL == sourceBaseURL
        }
        // A source-less wakeup is only a hint. A globally equal delivery ID
        // cannot prove that its Gateway's payload was stored.
        return !isWakeup
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
        // Ephemeral provenance from this coordinator's existing finalization
        // state. A direct notification is not necessarily a Pull response.
        let isPulled: Bool

        init(payload: [AnyHashable: Any], requestIdentifier: String?, isPulled: Bool = false) {
            self.payload = payload
            self.requestIdentifier = requestIdentifier
            self.isPulled = isPulled
        }
    }

    private struct DurablePulledItem {
        let payload: [AnyHashable: Any]
        let deliveryID: String
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
    private var fullSyncGeneration = UUID()
    private var pullContinuationTask: Task<Void, Never>?
    private var lastFullSyncAttemptAt = Date.distantPast
    private var inboxMergeTask: Task<Int, Never>?
    private var inboxMergeRequested = false
    private var pendingInboxAllowsWakeupSync = false
    private var pendingInboxLimit = 64
    private var pendingInboxReason = "unspecified"
    private var qualityMessageRefreshAttempt = 0
    private let inboxApplyOwner = "app.ingress.\(UUID().uuidString.lowercased())"
    private static let recentFullSyncInterval: TimeInterval = 3
    private static let pullPagesPerTurn = 4
    private static let pullTurnInterval: TimeInterval = 5
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
            entityId: entityTarget?.entityId,
            sourceBaseURL: normalizedText(sanitized["base_url"] as? String),
            isWakeup: NotificationHandling.providerWakeupPullDeliveryId(from: sanitized) != nil
        )
    }

    @discardableResult
    @MainActor
    func mergeInbox(
        reason: String,
        allowWakeupSync: Bool,
        limit: Int = 256
    ) async -> Int {
        inboxMergeRequested = true
        pendingInboxAllowsWakeupSync = pendingInboxAllowsWakeupSync || allowWakeupSync
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
                let runAllowsWakeupSync = pendingInboxAllowsWakeupSync
                let runLimit = pendingInboxLimit
                let runReason = pendingInboxReason
                pendingInboxAllowsWakeupSync = false
                pendingInboxLimit = 64
                totalApplied += await performMergeInbox(
                    reason: runReason,
                    allowWakeupSync: runAllowsWakeupSync,
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
        allowWakeupSync: Bool,
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
            for claimedEntry in claimedEntries {
                guard !Task.isCancelled else { return applied }
                visited += 1
                let payload = claimedEntry.payload

                let ingress = await NotificationHandling.resolveNotificationIngress(
                    from: payload,
                    dataStore: dataStore,
                    fallbackServerConfig: hooks.serverConfig(),
                    channelSubscriptionService: channelSubscriptionService,
                    notificationIngressInbox: notificationIngressInbox,
                    allowNetwork: allowWakeupSync,
                    alreadyJournaled: true,
                    wakeupPullClaimStore: wakeupPullClaimStore
                )
                guard !Task.isCancelled else { return applied }

                switch ingress {
                case let .failed(error):
                    _ = await notificationIngressInbox.markRetry(claimedEntry, reason: "origin_store_failed")
                    hooks.recordProviderError(error, "provider.inbox.origin.\(platformSuffix)")
                    return applied
                case let .processedDuplicate(payload):
                    let finishedReceipt: Bool
                    do {
                        finishedReceipt = try await notificationIngressInbox.finishKnownReceipt(claimedEntry)
                    } catch {
                        _ = await notificationIngressInbox.markRetry(claimedEntry, reason: "known_receipt_store_failed")
                        hooks.recordProviderError(error, "provider.inbox.known_receipt.\(platformSuffix)")
                        return applied
                    }
                    if await ackProcessedDeliveryIfNeeded(payload: payload, source: "provider.inbox.known.\(platformSuffix)") {
                        hooks.applyPersistenceResults([.duplicate])
                        let removedHint = await notificationIngressInbox.removeRedundantHint(claimedEntry)
                        if finishedReceipt || removedHint { settled += 1 }
                    } else {
                        _ = await notificationIngressInbox.markRetry(claimedEntry, reason: "known_delivery_ack_not_durable")
                    }
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
                case .direct:
                    _ = await notificationIngressInbox.markRetry(claimedEntry, reason: "unproven_direct_origin")
                case .claimedByPeer:
                    // A peer lease is not a processed fact for advertised
                    // origin fields. Keep the hint until that fact is durable.
                    _ = await notificationIngressInbox.markRetry(claimedEntry, reason: "canonical_claimed_by_peer")
                case let .unresolvedWakeup(unresolvedPayload, requestIdentifier, requestError):
                    if let requestError { hooks.recordProviderError(requestError, "provider.inbox.targeted.\(platformSuffix)") }
                    guard allowWakeupSync else {
                        _ = await notificationIngressInbox.markRetry(
                            claimedEntry,
                            reason: "wakeup_sync_disabled"
                        )
                        break
                    }
                    let unresolvedDeliveryId = requestIdentifier
                        ?? NotificationHandling.providerWakeupPullDeliveryId(from: unresolvedPayload)
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
                    // The resolver already attempted the bounded authenticated
                    // targeted request. Do not immediately repeat it in this
                    // same turn; the durable hint and existing due retry own it.
                    _ = unresolvedDeliveryId
                }
            }

            if !resolvedItems.isEmpty {
                let results = await persistPayloads(
                    resolvedItems.map { item in
                        let isPulled: Bool
                        switch item.finalization {
                        case .direct: isPulled = false
                        case .pulled: isPulled = true
                        }
                        return PersistenceInput(
                            payload: item.payload,
                            requestIdentifier: item.requestIdentifier,
                            isPulled: isPulled
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
                    if !shouldRemove {
                        _ = await notificationIngressInbox.markRetry(
                            item.claimed,
                            reason: "canonical_or_resolution_retry"
                        )
                    }
                }
                for (item, result) in zip(resolvedItems, results) {
                    switch item.finalization {
                    case .direct:
                        await ackDirectDeliveryIfNeeded(
                            payload: item.payload,
                            result: result,
                            source: "provider.inbox.direct.\(platformSuffix)"
                        )
                    case let .pulled(requestIdentifier, context):
                        let terminal = await finalizePulledIngress(
                            deliveryId: requestIdentifier,
                            context: context,
                            result: result,
                            source: "provider.inbox.pulled.\(platformSuffix)"
                        )
                        if terminal {
                            _ = await notificationIngressInbox.removeRedundantHint(item.claimed)
                            settled += 1
                        }
                    }
                }
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
#if DEBUG
        if let outcome = await consumeQualityMessageRefreshScenario(reason: reason) {
            return outcome
        }
#endif
        let normalizedDeliveryId = normalizedText(deliveryId)
        let isFullSync = normalizedDeliveryId == nil
        if isFullSync {
            // Even explicit refreshes share one owner. The metadata revision is
            // the cross-process fence; this generation protects this request.
            guard !isFullSyncInFlight else { return .skipped }
            if !bypassesRecentFullSyncCoalescing(reason: reason),
               Date().timeIntervalSince(lastFullSyncAttemptAt) < Self.recentFullSyncInterval {
                return .skipped
            }
            isFullSyncInFlight = true
            fullSyncGeneration = UUID()
            lastFullSyncAttemptAt = Date()
        }
        let requestGeneration = fullSyncGeneration
        defer { if isFullSync { isFullSyncInFlight = false } }

        if !skipInboxMerge {
            _ = await mergeInbox(
                reason: "sync_\(reason)",
                allowWakeupSync: false
            )
        }
        guard !Task.isCancelled else { return .skipped }
        guard let config = hooks.serverConfig()?.normalized() else { return .skipped }
        guard !Task.isCancelled else { return .skipped }
        guard let deviceKey = await hooks.cachedDeviceKey() else { return .skipped }
        guard !Task.isCancelled, hooks.isEnabled(), hooks.serverConfig()?.normalized() == config else { return .skipped }
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
            var frontier = isFullSync
                ? try await notificationIngressInbox.beginPullFrontier(scope: Self.pullScope(config: config, deviceKey: deviceKey))
                : nil
            var applied = 0
            var targetPersistenceFailed = false
            var turnFailed = false
            var mayContinue = true
            var pages = 0
            let turnStarted = ProcessInfo.processInfo.systemUptime
            while mayContinue {
                try Task.checkCancellation()
                guard await pullContextIsCurrent(config: config, deviceKey: deviceKey,
                                                 generation: requestGeneration, fullSync: isFullSync) else { return .skipped }
                let pullResult: ChannelSubscriptionService.PullResult
                do {
                    pullResult = try await channelSubscriptionService.pullMessages(
                    baseURL: config.baseURL,
                    token: config.token,
                    deviceKey: deviceKey,
                    deliveryId: normalizedDeliveryId,
                    pageToken: frontier?.pageToken
                    )
                } catch {
                    if let frontier, error is ChannelSubscriptionService.PullContinuationRejection {
                        // A reset is durable and CAS-fenced, never a same-turn
                        // retry loop. Existing due work can start a fresh pass.
                        _ = try await notificationIngressInbox.checkpointPullFrontier(expected: frontier, pageToken: nil)
                    }
                    throw error
                }
                guard await pullContextIsCurrent(config: config, deviceKey: deviceKey,
                                                 generation: requestGeneration, fullSync: isFullSync) else { return .skipped }
                pages += 1
                var deliveryIdsToAck: [String] = []
                var pageContainsFailedItem = false
                var pageContainsIdentityConflict = false
                var durableItems: [DurablePulledItem] = []
                for item in pullResult.items {
                    var payload: [AnyHashable: Any] = item.payload.reduce(into: [:]) { result, element in
                        result[element.key] = element.value
                    }
                    payload["delivery_id"] = item.deliveryId
                    payload["base_url"] = config.baseURL.absoluteString
                    payload["provider_device_key"] = deviceKey
                    guard let ingressIdentity = ProviderDeliveryAckFailureStore.DeliveryIdentity(
                        deliveryId: item.deliveryId,
                        baseURL: config.baseURL,
                        deviceKey: deviceKey,
                        ackContract: .v2Batch
                    ) else {
                        pageContainsFailedItem = true
                        continue
                    }
                    guard await journalPulledPayload(
                        payload,
                        deliveryID: item.deliveryId,
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
                            ingressIdentity: ingressIdentity
                        )
                    )
                }

                try Task.checkCancellation()
                let persistenceResults = await persistPayloads(
                    durableItems.map {
                        PersistenceInput(
                            payload: $0.payload,
                            requestIdentifier: $0.deliveryID,
                            isPulled: true
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
                    if case .identityConflict = result {
                        pageContainsIdentityConflict = true
                        if normalizedDeliveryId == item.deliveryID { targetPersistenceFailed = true }
                    }
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
                    case .identityConflict, .failed:
                        break
                    }
                    if result.allowsPulledItemRemoval {
                        deliveryIdsToAck.append(item.deliveryID)
                    }
                }

                guard await pullContextIsCurrent(config: config, deviceKey: deviceKey,
                                                 generation: requestGeneration, fullSync: isFullSync) else { return .skipped }
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

                guard await pullContextIsCurrent(config: config, deviceKey: deviceKey,
                                                 generation: requestGeneration, fullSync: isFullSync) else { return .skipped }
                guard !pageContainsFailedItem, ackSucceeded else {
                    turnFailed = true
                    break
                }
                if let expected = frontier, let scanComplete = pullResult.scanComplete {
                    // Every returned item has a durable journal/server owner.
                    // Unknown storage failure stops the pass; only a proven
                    // per-item identity conflict may be left behind without ACK.
                    guard let checkpoint = try await notificationIngressInbox.checkpointPullFrontier(
                        expected: expected, pageToken: pullResult.nextPageToken
                    ) else { return .skipped }
                    frontier = checkpoint
                    mayContinue = !scanComplete
                    if mayContinue && (pages >= Self.pullPagesPerTurn
                        || ProcessInfo.processInfo.systemUptime - turnStarted >= Self.pullTurnInterval) {
                        schedulePullContinuation(config: config, deviceKey: deviceKey, generation: requestGeneration)
                        break
                    }
                } else {
                    // Old servers provide no continuation. Preserve their
                    // bounded head behavior, without claiming deep progress.
                    if let expected = frontier, expected.pageToken != nil {
                        guard try await notificationIngressInbox.checkpointPullFrontier(
                            expected: expected, pageToken: nil
                        ) != nil else { return .skipped }
                    }
                    frontier = nil
                    mayContinue = pullResult.hasMore && ackSucceeded
                        && (!pageContainsIdentityConflict || !deliveryIdsToAck.isEmpty)
                    if pages >= Self.pullPagesPerTurn
                        || ProcessInfo.processInfo.systemUptime - turnStarted >= Self.pullTurnInterval { break }
                }
            }
            if let wakeupPullLease {
                if targetPersistenceFailed {
                    await wakeupPullClaimStore.releaseLease(wakeupPullLease)
                } else {
                    await wakeupPullClaimStore.markCompleted(wakeupPullLease)
                }
            }
            return targetPersistenceFailed || turnFailed ? .failed : .succeeded(appliedCount: applied)
        } catch {
            if let wakeupPullLease {
                await wakeupPullClaimStore.releaseLease(wakeupPullLease)
            }
            hooks.recordProviderError(error, "provider.ingress.\(reason)")
            return .failed
        }
    }

#if DEBUG
    private func consumeQualityMessageRefreshScenario(reason: String) async -> SyncOutcome? {
        guard reason == "messages_pull_to_refresh",
              let session = PushGoAutomationContext.qualitySession,
              session.messageRefreshScenario != .none
        else {
            return nil
        }

        qualityMessageRefreshAttempt += 1
        if session.messageRefreshScenario == .failOnceThenNewMessage,
           qualityMessageRefreshAttempt == 1 {
            return .failed
        }
        guard qualityMessageRefreshAttempt == 1
                || (session.messageRefreshScenario == .failOnceThenNewMessage
                    && qualityMessageRefreshAttempt == 2)
        else {
            return .succeeded(appliedCount: 0)
        }

        let messageID = "quality-refresh-result"
        let deliveryID = "quality-delivery-refresh-result"
        let payload: [AnyHashable: Any] = [
            "entity_type": "message",
            "entity_id": messageID,
            "message_id": messageID,
            "delivery_id": deliveryID,
            "title": "P2 Refresh Result",
            "body": "Persisted through the provider refresh ingress path.",
            "channel": "quality",
            "received_at": "2026-01-16T08:00:00Z",
            "aps": [
                "alert": [
                    "title": "P2 Refresh Result",
                    "body": "Persisted through the provider refresh ingress path.",
                ],
            ],
        ]
        let results = await persistPayloads([
            PersistenceInput(payload: payload, requestIdentifier: deliveryID),
        ])
        hooks.applyPersistenceResults(results)
        guard let result = results.first else { return .failed }
        switch result {
        case .persisted:
            return .succeeded(appliedCount: 1)
        case .duplicate:
            return .succeeded(appliedCount: 0)
        case .rejected, .identityConflict, .failed:
            return .failed
        }
    }
#endif

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
        // New duties use V2, including recovery of a previously accepted direct
        // delivery. A caller's result alone cannot prove the immutable origin.
        do {
            guard try await NotificationHandling.hasProcessedProviderHint(payload,
                dataStore: dataStore, notificationIngressInbox: notificationIngressInbox) else { return }
            _ = await ackProcessedDeliveryIfNeeded(payload: payload, source: "\(source).pending")
        } catch {
            hooks.recordProviderError(error, "\(source).origin_store_failed")
        }
    }

    /// This is only called after an exact existing processed fact was read.
    /// It never admits advertised bytes or extends the fact's retention time.
    func ackProcessedDeliveryIfNeeded(payload: [AnyHashable: Any], source: String) async -> Bool {
        guard let old = ProviderDeliveryAckFailureStore.DeliveryIdentity.direct(from: UserInfoSanitizer.sanitize(payload)),
              let identity = ProviderDeliveryAckFailureStore.DeliveryIdentity(deliveryId: old.deliveryId,
                baseURL: old.baseURL, deviceKey: old.deviceKey, ackContract: .v2Batch) else { return false }
        // Recovery must not replace a persisted old contract merely because a
        // processed duplicate was observed by the new release. Only new duties
        // use V2; an existing single-item duty keeps its original owner/route.
        do {
            if try await ackMarkerStore.hasAckResponsibility(identity: old) { return true }
        } catch {
            hooks.recordProviderError(error, "\(source).ack_responsibility_store_failed")
            return false
        }
        if await ackMarkerStore.markInboxDurable(identity: identity, source: source, postNotification: false) { return true }
        // A leased or completed ACK already owns this exact duty. Do not
        // retain a duplicate raw hint forever or reopen the processed window.
        return (try? await ackMarkerStore.hasAckResponsibility(identity: identity)) ?? false
    }

    @discardableResult
    func finalizePulledIngress(
        deliveryId: String,
        context: ProviderPullContext,
        result: ProviderIngressPersistenceResult,
        source: String
    ) async -> Bool {
        guard result.allowsPulledItemRemoval else {
            await wakeupPullClaimStore.releaseLease(context.claimLease)
            return false
        }

        guard let identity = ProviderDeliveryAckFailureStore.DeliveryIdentity(
            deliveryId: deliveryId,
            baseURL: context.baseURL,
            deviceKey: context.deviceKey,
            ackContract: .v2Batch
        ) else {
            await wakeupPullClaimStore.releaseLease(context.claimLease)
            return false
        }
        switch result {
        case .persisted, .duplicate:
            guard await notificationIngressInbox.markTerminal(
                identity: identity,
                discarded: false
            ) else { return false }
        case .rejected:
            guard await notificationIngressInbox.markTerminal(
                identity: identity,
                discarded: true,
                reason: "canonical_validation_rejected"
            ) else { return false }
        case .identityConflict, .failed:
            break
        }
        await wakeupPullClaimStore.markCompleted(context.claimLease)
        // ACK is owned by the durable worker. Canonical persistence and
        // notification presentation never wait for Gateway network I/O.
        return true
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
            baseURL: context.baseURL,
            deviceKey: context.deviceKey,
            source: source
        )
    }

    private func journalPulledPayload(
        _ payload: [AnyHashable: Any],
        deliveryID: String,
        baseURL: URL,
        deviceKey: String,
        source: String
    ) async -> Bool {
        guard let identity = ProviderDeliveryAckFailureStore.DeliveryIdentity(
            deliveryId: deliveryID,
            baseURL: baseURL,
            deviceKey: deviceKey,
            ackContract: .v2Batch
        ) else { return false }
        var durablePayload = UserInfoSanitizer.sanitize(payload)
        durablePayload["base_url"] = baseURL.absoluteString
        durablePayload["provider_device_key"] = deviceKey
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
            requiredEntryState: "terminal_local"
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
            if identity.ackContract == .legacySingle {
                let hint: [AnyHashable: Any] = ["base_url": identity.baseURLString,
                    "provider_device_key": identity.deviceKey, "delivery_id": identity.deliveryId]
                let processed: Bool
                do {
                    processed = try await NotificationHandling.hasProcessedProviderHint(hint,
                        dataStore: dataStore, notificationIngressInbox: notificationIngressInbox)
                } catch let error as AppError where error.code == "identity_conflict" {
                    await ackMarkerStore.markAckFailed(lease, source: "\(source).identity_conflict",
                        retryAfter: Date().addingTimeInterval(60), postNotification: false)
                    continue
                } catch {
                    await ackMarkerStore.markAckFailed(lease, source: "\(source).origin_store_failed",
                        retryAfter: Date().addingTimeInterval(60), postNotification: false)
                    hooks.recordProviderError(error, "\(source).origin_store_failed")
                    return
                }
                guard processed else {
                    await ackMarkerStore.markAckFailed(lease, source: "\(source).unproven_direct_origin",
                        retryAfter: Date().addingTimeInterval(60), postNotification: false)
                    continue
                }
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
        return normalized.contains("pull_to_refresh") || normalized.contains("manual") || normalized == "pull_continuation"
    }

    private static func pullScope(config: ServerConfig, deviceKey: String) -> String {
        // Configuration generation is not a credential fingerprint. Tokens are
        // only compared in memory; neither token nor token hash is checkpointed.
        // LocalKeychainConfigStore persists dates with JSONEncoder.iso8601
        // (whole seconds). Use that same representation before and after a
        // restart instead of an in-memory fractional Double bit pattern.
        let configurationDate = ISO8601DateFormatter().string(from: config.updatedAt)
        let value = [ackBatchKey(for: config.baseURL), deviceKey, config.id.uuidString,
                     configurationDate].joined(separator: "\n")
        return SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func pullContextIsCurrent(config: ServerConfig, deviceKey: String,
                                      generation: UUID, fullSync: Bool) async -> Bool {
        guard !Task.isCancelled, hooks.isEnabled(),
              hooks.serverConfig()?.normalized() == config,
              !fullSync || fullSyncGeneration == generation else { return false }
        let currentDevice = await hooks.cachedDeviceKey()
        return !Task.isCancelled && hooks.isEnabled() && currentDevice == deviceKey
            && hooks.serverConfig()?.normalized() == config
            && (!fullSync || fullSyncGeneration == generation)
    }

    private func schedulePullContinuation(config: ServerConfig, deviceKey: String, generation: UUID) {
        guard pullContinuationTask == nil else { return }
        pullContinuationTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard let self else { return }
            self.pullContinuationTask = nil
            guard await self.pullContextIsCurrent(config: config, deviceKey: deviceKey,
                                                  generation: generation, fullSync: true) else { return }
            _ = await self.syncProviderIngressOutcome(reason: "pull_continuation", skipInboxMerge: true)
        }
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
