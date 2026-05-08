import Foundation
import UserNotifications

@MainActor
final class NotificationIngressController {
    typealias ServerConfigProvider = @MainActor () -> ServerConfig?
    typealias CachedDeviceKeyProvider = @MainActor () async -> String?
    typealias BeforePersistMessage = @Sendable (PushMessage) async -> Void
    typealias CountsRefreshScheduler = @MainActor () -> Void
    typealias ProviderErrorRecorder = @MainActor (Error, String) -> Void
    typealias StartupWakeupPullDeferPredicate = @MainActor () -> Bool

    private let dataStore: LocalDataStore
    private let channelSubscriptionService: ChannelSubscriptionService
    private let serverConfigProvider: ServerConfigProvider
    private let cachedDeviceKeyProvider: CachedDeviceKeyProvider
    private let beforePersistMessage: BeforePersistMessage
    private let scheduleCountsRefresh: CountsRefreshScheduler
    private let recordProviderError: ProviderErrorRecorder
    private let shouldDeferStartupWakeupPulls: StartupWakeupPullDeferPredicate
    private let notificationIngressInbox: NotificationIngressInbox
    private let ackFailureStore: ProviderDeliveryAckFailureStore

    private lazy var providerIngressCoordinator = ProviderIngressCoordinator(
        platformSuffix: "ios",
        dataStore: dataStore,
        channelSubscriptionService: channelSubscriptionService,
        notificationIngressInbox: notificationIngressInbox,
        ackMarkerStore: ackFailureStore,
        hooks: ProviderIngressCoordinator.Hooks(
            isEnabled: { true },
            serverConfig: { [serverConfigProvider] in serverConfigProvider() },
            cachedDeviceKey: { [cachedDeviceKeyProvider] in await cachedDeviceKeyProvider() },
            hasPersistedNotification: { [weak self] identity in
                guard let self else { return false }
                return await self.hasPersistedNotification(identity: identity)
            },
            persistPayload: { [weak self] payload, requestIdentifier in
                guard let self else { return .failed }
                let outcome = await NotificationPersistenceCoordinator.persistRemotePayloadIfNeeded(
                    payload,
                    requestIdentifier: requestIdentifier,
                    dataStore: self.dataStore,
                    beforeSave: self.beforePersistMessage
                )
                return ProviderIngressPersistenceResult(outcome)
            },
            applyPersistenceResult: { [weak self] result in
                self?.applyProviderIngressPersistenceResult(result)
            },
            recordProviderError: { [recordProviderError] error, source in
                recordProviderError(error, source)
            }
        )
    )

    init(
        dataStore: LocalDataStore,
        channelSubscriptionService: ChannelSubscriptionService,
        serverConfigProvider: @escaping ServerConfigProvider,
        cachedDeviceKeyProvider: @escaping CachedDeviceKeyProvider,
        beforePersistMessage: @escaping BeforePersistMessage,
        scheduleCountsRefresh: @escaping CountsRefreshScheduler,
        recordProviderError: @escaping ProviderErrorRecorder,
        shouldDeferStartupWakeupPulls: @escaping StartupWakeupPullDeferPredicate = { false },
        notificationIngressInbox: NotificationIngressInbox = .shared,
        ackFailureStore: ProviderDeliveryAckFailureStore = .shared
    ) {
        self.dataStore = dataStore
        self.channelSubscriptionService = channelSubscriptionService
        self.serverConfigProvider = serverConfigProvider
        self.cachedDeviceKeyProvider = cachedDeviceKeyProvider
        self.beforePersistMessage = beforePersistMessage
        self.scheduleCountsRefresh = scheduleCountsRefresh
        self.recordProviderError = recordProviderError
        self.shouldDeferStartupWakeupPulls = shouldDeferStartupWakeupPulls
        self.notificationIngressInbox = notificationIngressInbox
        self.ackFailureStore = ackFailureStore
    }

    func handleNotificationIngressChanged(reason: String) async {
        _ = await mergeNotificationIngressInbox(
            reason: reason,
            allowFallbackPull: false
        )
    }

    func drainProviderDeliveryAckFailures(source: String) async {
        await providerIngressCoordinator.drainAckMarkers(source: source)
    }

    @discardableResult
    func mergeNotificationIngressInbox(
        reason: String,
        allowFallbackPull: Bool,
        limit: Int = 256
    ) async -> Int {
        await providerIngressCoordinator.mergeInbox(
            reason: reason,
            allowFallbackPull: allowFallbackPull,
            limit: limit
        )
    }

    @discardableResult
    func syncProviderIngress(
        deliveryId: String? = nil,
        reason: String,
        skipInboxMerge: Bool = false
    ) async -> Int {
        await providerIngressCoordinator.syncProviderIngress(
            deliveryId: deliveryId,
            reason: reason,
            skipInboxMerge: skipInboxMerge
        )
    }

    func syncProviderIngressOutcome(
        deliveryId: String? = nil,
        reason: String,
        skipInboxMerge: Bool = false
    ) async -> ProviderIngressCoordinator.SyncOutcome {
        await providerIngressCoordinator.syncProviderIngressOutcome(
            deliveryId: deliveryId,
            reason: reason,
            skipInboxMerge: skipInboxMerge
        )
    }

    @discardableResult
    func purgePendingUnresolvedWakeupEntries(limit: Int = 256) async -> Int {
        await providerIngressCoordinator.purgePendingUnresolvedWakeupEntries(limit: limit)
    }

    @discardableResult
    func persistNotificationIfNeeded(_ notification: UNNotification) async -> NotificationPersistenceOutcome {
        let notificationPayload = UserInfoSanitizer.sanitize(notification.request.content.userInfo)
        let identity = providerIngressCoordinator.identity(from: notificationPayload)
        if await hasPersistedNotification(identity: identity) {
            return .duplicate
        }

        let ingress = await NotificationHandling.resolveNotificationIngress(
            from: notificationPayload,
            dataStore: dataStore,
            fallbackServerConfig: serverConfigProvider(),
            channelSubscriptionService: channelSubscriptionService
        )
        let outcome: NotificationPersistenceOutcome
        switch ingress {
        case let .pulled(payload, requestIdentifier):
            outcome = await NotificationPersistenceCoordinator.persistRemotePayloadIfNeeded(
                payload,
                requestIdentifier: requestIdentifier,
                dataStore: dataStore,
                beforeSave: beforePersistMessage
            )
        case .claimedByPeer:
            outcome = await hasPersistedNotification(identity: identity) ? .duplicate : .rejected
        case let .unresolvedWakeup(payload, requestIdentifier):
            if shouldDeferStartupWakeupPulls() {
                outcome = .rejected
                break
            }
            let unresolvedDeliveryId = requestIdentifier
                ?? NotificationHandling.providerWakeupPullDeliveryId(from: payload)
            if let unresolvedDeliveryId {
                let pulled = await syncProviderIngress(
                    deliveryId: unresolvedDeliveryId,
                    reason: "delegate_unresolved_wakeup",
                    skipInboxMerge: true
                )
                if pulled > 0 {
                    let resolvedIdentity = ProviderIngressIdentity(
                        messageId: identity.messageId,
                        deliveryId: identity.deliveryId ?? unresolvedDeliveryId
                    )
                    outcome = await hasPersistedNotification(identity: resolvedIdentity) ? .duplicate : .rejected
                } else {
                    outcome = .rejected
                }
            } else {
                outcome = .rejected
            }
        case let .direct(_, requestIdentifier):
            outcome = await NotificationPersistenceCoordinator.persistPreparedContentIfNeeded(
                content: notification.request.content,
                requestIdentifier: requestIdentifier,
                fallbackRequestIdentifier: notification.request.identifier,
                dataStore: dataStore,
                beforeSave: beforePersistMessage
            )
        }

        applyNotificationPersistenceOutcome(outcome)
        return outcome
    }

    private func hasPersistedNotification(identity: ProviderIngressIdentity) async -> Bool {
        do {
            if let messageId = identity.messageId,
               try await dataStore.loadMessage(messageId: messageId) != nil
            {
                return true
            }
            if let deliveryId = identity.deliveryId,
               try await dataStore.loadMessage(deliveryId: deliveryId) != nil
            {
                return true
            }
        } catch {}
        return false
    }

    private func applyProviderIngressPersistenceResult(_ result: ProviderIngressPersistenceResult) {
        switch result {
        case .persisted, .duplicate:
            scheduleCountsRefresh()
        case .rejected, .failed:
            break
        }
    }

    private func applyNotificationPersistenceOutcome(
        _ outcome: NotificationPersistenceOutcome
    ) {
        switch outcome {
        case .duplicate, .persistedMain, .persistedPending:
            scheduleCountsRefresh()
        case .rejected, .failed:
            break
        }
    }
}
