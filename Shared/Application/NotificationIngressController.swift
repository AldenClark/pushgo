import Foundation
import UserNotifications

@MainActor
final class NotificationIngressController {
    typealias ServerConfigProvider = @MainActor () -> ServerConfig?
    typealias CachedDeviceKeyProvider = @MainActor () async -> String?
    typealias BeforePersistMessage = @Sendable (PushMessage) async -> Void
    typealias CountsRefreshScheduler = @MainActor () -> Void
    typealias InboxProgressReporter = @MainActor (ProviderInboxProgress) -> Void
    typealias ProviderErrorRecorder = @MainActor (Error, String) -> Void
    typealias StartupWakeupPullDeferPredicate = @MainActor () -> Bool

    private let platformSuffix: String
    private let dataStore: LocalDataStore
    private let channelSubscriptionService: ChannelSubscriptionService
    private let serverConfigProvider: ServerConfigProvider
    private let cachedDeviceKeyProvider: CachedDeviceKeyProvider
    private let beforePersistMessage: BeforePersistMessage
    private let scheduleCountsRefresh: CountsRefreshScheduler
    private let reportInboxProgress: InboxProgressReporter
    private let recordProviderError: ProviderErrorRecorder
    private let shouldDeferStartupWakeupPulls: StartupWakeupPullDeferPredicate
    private let notificationIngressInbox: NotificationIngressInbox
    private let ackFailureStore: ProviderDeliveryAckFailureStore
    private var ackDrainTask: Task<Void, Never>?
    private var ingressRetryWakeTask: Task<Void, Never>?
    private var ingressRetryWakeDate: Date?
    private var ackDrainRequested = false

    private lazy var providerIngressCoordinator = ProviderIngressCoordinator(
        platformSuffix: platformSuffix,
        dataStore: dataStore,
        channelSubscriptionService: channelSubscriptionService,
        notificationIngressInbox: notificationIngressInbox,
        ackMarkerStore: ackFailureStore,
        wakeupPullClaimStore: .shared,
        hooks: ProviderIngressCoordinator.Hooks(
            isEnabled: { true },
            serverConfig: { [serverConfigProvider] in serverConfigProvider() },
            cachedDeviceKey: { [cachedDeviceKeyProvider] in await cachedDeviceKeyProvider() },
            hasPersistedNotification: { [weak self] identity in
                guard let self else { return false }
                return await self.hasPersistedNotification(identity: identity)
            },
            persistPayloads: { [weak self] inputs in
                guard let self else {
                    return Array(repeating: .failed, count: inputs.count)
                }
                let outcomes = await NotificationPersistenceCoordinator.persistRemotePayloadsIfNeeded(
                    inputs.map {
                        NotificationPersistenceCoordinator.RemotePayload(
                            payload: $0.payload,
                            requestIdentifier: $0.requestIdentifier
                        )
                    },
                    dataStore: self.dataStore,
                    beforeSave: self.beforePersistMessage
                )
                return outcomes.map(ProviderIngressPersistenceResult.init)
            },
            applyPersistenceResults: { [weak self] results in
                self?.applyProviderIngressPersistenceResults(results)
            },
            reportInboxProgress: { [reportInboxProgress] progress in
                reportInboxProgress(progress)
            },
            recordProviderError: { [recordProviderError] error, source in
                recordProviderError(error, source)
            }
        )
    )

    init(
        platformSuffix: String,
        dataStore: LocalDataStore,
        channelSubscriptionService: ChannelSubscriptionService,
        serverConfigProvider: @escaping ServerConfigProvider,
        cachedDeviceKeyProvider: @escaping CachedDeviceKeyProvider,
        beforePersistMessage: @escaping BeforePersistMessage,
        scheduleCountsRefresh: @escaping CountsRefreshScheduler,
        reportInboxProgress: @escaping InboxProgressReporter = { _ in },
        recordProviderError: @escaping ProviderErrorRecorder,
        shouldDeferStartupWakeupPulls: @escaping StartupWakeupPullDeferPredicate,
        notificationIngressInbox: NotificationIngressInbox,
        ackFailureStore: ProviderDeliveryAckFailureStore
    ) {
        self.platformSuffix = platformSuffix
        self.dataStore = dataStore
        self.channelSubscriptionService = channelSubscriptionService
        self.serverConfigProvider = serverConfigProvider
        self.cachedDeviceKeyProvider = cachedDeviceKeyProvider
        self.beforePersistMessage = beforePersistMessage
        self.scheduleCountsRefresh = scheduleCountsRefresh
        self.reportInboxProgress = reportInboxProgress
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
        guard !Task.isCancelled else { return }
        scheduleProviderAckDrain(source: "provider.ingress_changed.\(platformSuffix)")
    }

    @discardableResult
    func drainProviderDeliveryAckFailures(
        source: String
    ) async -> IngressBackgroundRefreshRunner.StageOutcome {
        scheduleProviderAckDrain(source: source)
        if let task = ackDrainTask {
            await withTaskCancellationHandler {
                await task.value
            } onCancel: {
                task.cancel()
            }
        }
        guard !Task.isCancelled else { return .failed }
        let hasPendingRetry = await ackFailureStore.nextAttemptDate() != nil
        await rearmIngressRetryWake(source: source)
        return hasPendingRetry ? .failed : .succeeded
    }

    @discardableResult
    func mergeNotificationIngressInbox(
        reason: String,
        allowFallbackPull: Bool,
        limit: Int = 256
    ) async -> Int {
        await mergeNotificationIngressInboxOutcome(
            reason: reason,
            allowFallbackPull: allowFallbackPull,
            limit: limit
        ).appliedCount
    }

    struct MergeOutcome: Sendable, Equatable {
        let appliedCount: Int
        let stageOutcome: IngressBackgroundRefreshRunner.StageOutcome
    }

    func mergeNotificationIngressInboxOutcome(
        reason: String,
        allowFallbackPull: Bool,
        limit: Int = 256
    ) async -> MergeOutcome {
        let applied = await providerIngressCoordinator.mergeInbox(
            reason: reason,
            allowFallbackPull: allowFallbackPull,
            limit: limit
        )
        guard !Task.isCancelled else {
            return MergeOutcome(appliedCount: applied, stageOutcome: .failed)
        }
        let hasPendingRetry = await notificationIngressInbox.nextRetryDate() != nil
        scheduleProviderAckDrain(source: "provider.merge.\(reason).\(platformSuffix)")
        return MergeOutcome(
            appliedCount: applied,
            stageOutcome: hasPendingRetry ? .failed : .succeeded
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

    func finalizePulledProviderIngress(
        deliveryId: String,
        context: ProviderPullContext,
        outcome: NotificationPersistenceOutcome,
        source: String
    ) async {
        await providerIngressCoordinator.finalizePulledIngress(
            deliveryId: deliveryId,
            context: context,
            result: ProviderIngressPersistenceResult(outcome),
            source: source
        )
        scheduleProviderAckDrain(source: "\(source).ack")
    }

    @discardableResult
    func persistPulledProviderIngress(
        payload: [AnyHashable: Any],
        deliveryId: String,
        context: ProviderPullContext,
        source: String
    ) async -> NotificationPersistenceOutcome {
        guard await providerIngressCoordinator.journalPulledPayload(
            payload,
            deliveryID: deliveryId,
            context: context,
            source: "\(source).journal"
        ) else {
            await providerIngressCoordinator.finalizePulledIngress(
                deliveryId: deliveryId,
                context: context,
                result: .failed,
                source: "\(source).journal_failed"
            )
            return .failed
        }
        let outcome = await NotificationPersistenceCoordinator.persistRemotePayloadIfNeeded(
            payload,
            requestIdentifier: deliveryId,
            dataStore: dataStore,
            beforeSave: beforePersistMessage
        )
        await finalizePulledProviderIngress(
            deliveryId: deliveryId,
            context: context,
            outcome: outcome,
            source: source
        )
        applyNotificationPersistenceOutcome(outcome)
        return outcome
    }

    func ackDirectProviderIngressIfNeeded(
        payload: [AnyHashable: Any],
        outcome: NotificationPersistenceOutcome,
        source: String
    ) async {
        await providerIngressCoordinator.ackDirectDeliveryIfNeeded(
            payload: payload,
            result: ProviderIngressPersistenceResult(outcome),
            source: source
        )
        scheduleProviderAckDrain(source: "\(source).ack")
    }

    private func scheduleProviderAckDrain(source: String) {
        guard !Task.isCancelled else { return }
        cancelIngressRetryWake()
        ackDrainRequested = true
        guard ackDrainTask == nil else { return }
        ackDrainTask = Task(priority: .utility) { @MainActor [weak self] in
            guard let self else { return }
            defer { ackDrainTask = nil }
            repeat {
                ackDrainRequested = false
                await providerIngressCoordinator.drainAckMarkers(source: source)
            } while ackDrainRequested && !Task.isCancelled
            guard !Task.isCancelled else { return }
            await rearmIngressRetryWake(source: source)
        }
    }

    private func rearmIngressRetryWake(source: String) async {
        guard !Task.isCancelled else { return }
        async let ingressDue = notificationIngressInbox.nextRetryDate()
        async let ackDue = ackFailureStore.nextAttemptDate()
        guard let due = [await ingressDue, await ackDue].compactMap({ $0 }).min() else {
            cancelIngressRetryWake()
            return
        }
        if let scheduled = ingressRetryWakeDate, scheduled <= due {
            return
        }
        cancelIngressRetryWake()
        let delay = max(0.1, due.timeIntervalSinceNow)
        ingressRetryWakeDate = due
        ingressRetryWakeTask = Task(priority: .utility) { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }
            guard !Task.isCancelled, let self else { return }
            await ingressRetryWakeFired(expectedDate: due, source: source)
        }
    }

    private func ingressRetryWakeFired(expectedDate: Date, source: String) async {
        guard ingressRetryWakeDate == expectedDate else { return }
        ingressRetryWakeTask = nil
        ingressRetryWakeDate = nil
        _ = await mergeNotificationIngressInboxOutcome(
            reason: "retry_due_\(platformSuffix)",
            allowFallbackPull: true
        )
        guard !Task.isCancelled else { return }
        _ = await drainProviderDeliveryAckFailures(source: "\(source).retry_due")
    }

    private func cancelIngressRetryWake() {
        ingressRetryWakeTask?.cancel()
        ingressRetryWakeTask = nil
        ingressRetryWakeDate = nil
    }

    @discardableResult
    func purgePendingUnresolvedWakeupEntries(limit: Int = 256) async -> Int {
        await providerIngressCoordinator.purgePendingUnresolvedWakeupEntries(limit: limit)
    }

    @discardableResult
    func persistRemotePayloadIfNeeded(
        _ payload: [AnyHashable: Any],
        requestIdentifier: String? = nil
    ) async -> NotificationPersistenceOutcome {
        let outcome = await NotificationPersistenceCoordinator.persistRemotePayloadIfNeeded(
            payload,
            requestIdentifier: requestIdentifier,
            dataStore: dataStore,
            beforeSave: beforePersistMessage
        )
        applyNotificationPersistenceOutcome(outcome)
        return outcome
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
            channelSubscriptionService: channelSubscriptionService,
            notificationIngressInbox: notificationIngressInbox
        )
        let outcome: NotificationPersistenceOutcome
        switch ingress {
        case let .pulled(payload, requestIdentifier, context):
            outcome = await persistPulledProviderIngress(
                payload: payload,
                deliveryId: requestIdentifier,
                context: context,
                source: "provider.notification.pulled.\(platformSuffix)"
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
            await ackDirectProviderIngressIfNeeded(
                payload: notificationPayload,
                outcome: outcome,
                source: "provider.notification.direct.\(platformSuffix)"
            )
        }

        applyNotificationPersistenceOutcome(outcome)
        return outcome
    }

    private func hasPersistedNotification(identity: ProviderIngressIdentity) async -> Bool {
        do {
            if let messageId = identity.messageId,
               let stored = try await dataStore.loadMessage(messageId: messageId),
               identity.matchesPersisted(stored)
            {
                return true
            }
            if let deliveryId = identity.deliveryId,
               try await dataStore.loadMessages(deliveryId: deliveryId)
                   .contains(where: identity.matchesPersisted)
            {
                return true
            }
        } catch {}
        return false
    }

    private func applyProviderIngressPersistenceResults(
        _ results: [ProviderIngressPersistenceResult]
    ) {
        if results.contains(where: { result in
            switch result {
            case .persisted, .duplicate: true
            case .rejected, .failed: false
            }
        }) {
            scheduleCountsRefresh()
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
