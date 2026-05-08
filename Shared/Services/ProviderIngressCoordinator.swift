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
    private let hooks: Hooks
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
        wakeupPullClaimStore: ProviderWakeupPullClaimStore = .shared,
        hooks: Hooks
    ) {
        self.platformSuffix = platformSuffix
        self.dataStore = dataStore
        self.channelSubscriptionService = channelSubscriptionService
        self.notificationIngressInbox = notificationIngressInbox
        self.ackMarkerStore = ackMarkerStore
        self.wakeupPullClaimStore = wakeupPullClaimStore
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
            case let .pulled(resolvedPayload, requestIdentifier):
                let result = await hooks.persistPayload(resolvedPayload, requestIdentifier)
                await hooks.applyPersistenceResult(result)
                if result.isApplied {
                    applied += 1
                }
                shouldRemove = shouldRemoveInboxEntry(payload: resolvedPayload, result: result)
            case let .direct(resolvedPayload, requestIdentifier):
                let effectiveRequestIdentifier = requestIdentifier ?? pendingEntry.record.requestIdentifier
                let result = await hooks.persistPayload(resolvedPayload, effectiveRequestIdentifier)
                await hooks.applyPersistenceResult(result)
                if result.isApplied {
                    applied += 1
                }
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
        var wakeupPullLease: ProviderWakeupPullClaimStore.ClaimLease?
        if let normalizedDeliveryId {
            guard let lease = await wakeupPullClaimStore.acquireLease(
                deliveryId: normalizedDeliveryId,
                owner: "app.sync.\(platformSuffix)",
                leaseDuration: 30
            ) else {
                return .skipped
            }
            wakeupPullLease = lease
        }

        do {
            let items = try await channelSubscriptionService.pullMessages(
                baseURL: config.baseURL,
                token: config.token,
                deviceKey: deviceKey,
                deliveryId: normalizedDeliveryId
            )
            guard !items.isEmpty else {
                if let wakeupPullLease {
                    await wakeupPullClaimStore.releaseLease(wakeupPullLease)
                }
                return .succeeded(appliedCount: 0)
            }

            var applied = 0
            for item in items {
                let payload: [AnyHashable: Any] = item.payload.reduce(into: [:]) { result, element in
                    result[element.key] = element.value
                }
                let result = await hooks.persistPayload(payload, item.deliveryId)
                await hooks.applyPersistenceResult(result)
                if result.isApplied {
                    applied += 1
                }
                if result.allowsAck {
                    await ackMarkerStore.markCompleted(deliveryId: item.deliveryId)
                }
            }
            if let wakeupPullLease {
                await wakeupPullClaimStore.markCompleted(wakeupPullLease)
            }
            return .succeeded(appliedCount: applied)
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
        source: String,
        fallbackDeliveryId: String? = nil
    ) async {
        guard result.allowsAck else { return }
        guard NotificationHandling.providerWakeupPullDeliveryId(from: payload) == nil else { return }
        guard let deliveryId = providerDeliveryId(from: payload)
            ?? normalizedText(fallbackDeliveryId)
        else { return }
        await ackDelivery(
            deliveryId: deliveryId,
            baseURL: await hooks.serverConfig()?.baseURL,
            source: source
        )
    }

    func drainAckMarkers(source: String) async {
        guard await hooks.isEnabled(), !isDrainingAckMarkers else { return }
        isDrainingAckMarkers = true
        defer { isDrainingAckMarkers = false }

        let currentConfig = await hooks.serverConfig()
        let currentDeviceKey = await hooks.cachedDeviceKey()
        let markers = await ackMarkerStore.pendingMarkers(
            limit: 64,
            minimumAge: Self.appAckMarkerMinimumAge
        )
        for marker in markers {
            let deliveryId = marker.record.deliveryId
            let identity = ProviderIngressIdentity(
                messageId: nil,
                deliveryId: deliveryId,
                requestIdentifier: deliveryId
            )
            guard await hooks.hasPersistedNotification(identity) else {
                continue
            }
            guard let baseURL = marker.baseURL ?? currentConfig?.baseURL else { continue }
            let deviceKey = normalizedText(currentDeviceKey) ?? ""
            guard !deviceKey.isEmpty else { continue }
            let token = currentConfig?.baseURL.absoluteString == baseURL.absoluteString
                ? currentConfig?.token
                : nil
            guard let lease = await ackMarkerStore.acquireAckLease(
                marker,
                owner: "app.\(platformSuffix)",
                leaseDuration: 30
            ) else {
                continue
            }

            do {
                _ = try await channelSubscriptionService.ackMessage(
                    baseURL: baseURL,
                    token: token,
                    deviceKey: deviceKey,
                    deliveryId: deliveryId
                )
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
    }

    private func ackDelivery(
        deliveryId: String,
        baseURL fallbackBaseURL: URL?,
        source: String
    ) async {
        guard let config = await hooks.serverConfig(),
              let deviceKey = await hooks.cachedDeviceKey()
        else {
            _ = await ackMarkerStore.markInboxDurable(
                deliveryId: deliveryId,
                baseURL: fallbackBaseURL,
                deviceKeyAccount: nil,
                source: "\(source).unavailable",
                retryAfter: Date().addingTimeInterval(60),
                postNotification: false
            )
            return
        }
        _ = await ackMarkerStore.markInboxDurable(
            deliveryId: deliveryId,
            baseURL: config.baseURL,
            deviceKeyAccount: nil,
            source: "\(source).pending",
            postNotification: false
        )
        guard let lease = await ackMarkerStore.acquireAckLease(
            deliveryId: deliveryId,
            owner: "app.direct.\(platformSuffix)",
            leaseDuration: 30
        ) else {
            return
        }

        do {
            _ = try await channelSubscriptionService.ackMessage(
                baseURL: config.baseURL,
                token: config.token,
                deviceKey: deviceKey,
                deliveryId: deliveryId
            )
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

    private func providerDeliveryId(from payload: [AnyHashable: Any]) -> String? {
        let sanitized = UserInfoSanitizer.sanitize(payload)
        return normalizedText(sanitized["delivery_id"] as? String)
    }

    private func normalizedText(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}
