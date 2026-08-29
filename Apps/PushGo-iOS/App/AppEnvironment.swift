import Foundation
import Darwin
import GRDB
@preconcurrency import Network
import Observation
import SwiftUI
import UserNotifications
import UIKit

#if DEBUG
private let pushGoIngressPerformanceProcessStartUptime = ProcessInfo.processInfo.systemUptime

private struct PushGoIngressPerformanceMeasurement {
    enum Mode: String {
        case baseline
        case seed
        case measure
        case cleanup
    }

    enum PayloadKind: String {
        case short
        case long
    }

    let mode: Mode
    let runID: String
    let pendingCount: Int
    let payloadKind: PayloadKind
    let processStartUptime: TimeInterval
    var baselineMessageCount: Int?
    var didLogFirstBatchCommit = false
    var didLogCachedUI = false
    var didLogFirstBatchUI = false
    var didLogAllPendingUI = false

    var fixtureChannel: String { "__pushgo_ingress_perf_\(runID)__" }

    static func fromEnvironment() -> Self? {
        let environment = ProcessInfo.processInfo.environment
        guard let mode = environment["PUSHGO_INGRESS_PERF_MODE"].flatMap(Mode.init(rawValue:)),
              let rawRunID = environment["PUSHGO_INGRESS_PERF_RUN_ID"]?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !rawRunID.isEmpty,
              let pendingCount = Int(environment["PUSHGO_INGRESS_PERF_COUNT"] ?? ""),
              (0...1_000).contains(pendingCount),
              let payloadKind = PayloadKind(
                rawValue: environment["PUSHGO_INGRESS_PERF_PAYLOAD"] ?? "short"
              )
        else { return nil }
        let safeRunID = rawRunID.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        guard !safeRunID.isEmpty else { return nil }
        return Self(
            mode: mode,
            runID: safeRunID,
            pendingCount: pendingCount,
            payloadKind: payloadKind,
            processStartUptime: pushGoIngressPerformanceProcessStartUptime
        )
    }
}
#endif

@MainActor
@Observable
final class AppEnvironment {
    enum MessageIngressNotice: Equatable {
        case processing(completed: Int, total: Int)
        case processingSlow(completed: Int, total: Int)
        case waitingRetry(remaining: Int)
        case completed
    }

    enum SettingsPresentationRequest: String, Identifiable {
        case settings
        case decryption

        var id: String { rawValue }
    }

    @MainActor
    static let shared = AppEnvironment()

    let dataStore: LocalDataStore
    let pushRegistrationService: PushRegistrationService
    let localizationManager: LocalizationManager
    @ObservationIgnored private(set) lazy var messageStateCoordinator = MessageStateCoordinator(
        dataStore: dataStore,
        refreshCountsAndNotify: { [weak self] in
            guard let self else { return }
            await self.refreshMessageCountsAndNotify()
        }
    )
    @ObservationIgnored private var messageSyncObserver: DarwinNotificationObserver?
    @ObservationIgnored private var notificationIngressObserver: DarwinNotificationObserver?
    @ObservationIgnored private var pendingCountsRefreshTask: Task<Void, Never>?
    @ObservationIgnored private var isCountsRefreshRequested = false
    @ObservationIgnored private var ingressNoticeRevealTask: Task<Void, Never>?
    @ObservationIgnored private var ingressNoticeWatchdogTask: Task<Void, Never>?
    @ObservationIgnored private var ingressNoticeDismissTask: Task<Void, Never>?
    @ObservationIgnored private var pendingInboxProgress: ProviderInboxProgress?
#if DEBUG
    @ObservationIgnored private var ingressPerformanceMeasurement =
        PushGoIngressPerformanceMeasurement.fromEnvironment()
#endif
    @ObservationIgnored private var messageStoreObservationTask: Task<Void, Never>?
    @ObservationIgnored private var bootstrapTask: Task<Void, Never>?
    @ObservationIgnored private var didBootstrap = false
    @ObservationIgnored private var providerIngressBootstrapRecoveryInFlight = false
    @ObservationIgnored private var scenePhases: [UUID: ScenePhase] = [:]
    @ObservationIgnored private var pendingDeletionBackgroundTask: Task<Void, Never>?
    @ObservationIgnored private var pendingDeletionBackgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    @ObservationIgnored private var pendingDeletionBackgroundDrainID: UUID?
#if DEBUG
    @ObservationIgnored private var remainingQualityGatewaySwitchValidationFailures =
        PushGoAutomationContext.qualitySession?.faults.failGatewaySwitchValidationOnce == true ? 1 : 0
    @ObservationIgnored private var remainingQualityGatewaySwitchCommitFailures =
        PushGoAutomationContext.qualitySession?.faults.failGatewaySwitchCommitOnce == true ? 1 : 0
    @ObservationIgnored private var qualityEventCloseAttemptCount = 0
    @ObservationIgnored private var isQualityEventCloseRoundTripInFlight = false
#endif

    private var toastDismissTask: Task<Void, Never>?

    private(set) var serverConfig: ServerConfig? = AppEnvironment.makeDefaultServerConfig()
    private(set) var totalMessageCount: Int = 0
    private(set) var unreadMessageCount: Int = 0
    private(set) var messageStoreRevision: UUID = UUID()
    private(set) var toastMessage: ToastMessage?
    private(set) var messageIngressNotice: MessageIngressNotice?
    private(set) var isDeletionRecoveryReady = false
#if DEBUG
    private(set) var qualityRuntimeReadiness = "inactive"
#endif
    var localStoreRecoveryState: LocalStoreRecoveryState? { localStoreRecoveryController.localStoreRecoveryState }
    private(set) var shouldPresentNotificationPermissionAlert: Bool = false
    var pendingMessageToOpen: UUID? {
        get { notificationOpenController.pendingMessageToOpen }
        set { notificationOpenController.pendingMessageToOpen = newValue }
    }
    var pendingEventToOpen: String? {
        get { notificationOpenController.pendingEventToOpen }
        set { notificationOpenController.pendingEventToOpen = newValue }
    }
    var pendingThingToOpen: String? {
        get { notificationOpenController.pendingThingToOpen }
        set { notificationOpenController.pendingThingToOpen = newValue }
    }
    var isMessagePageEnabled: Bool { dataPageVisibilityController.isMessagePageEnabled }
    var isEventPageEnabled: Bool { dataPageVisibilityController.isEventPageEnabled }
    var isThingPageEnabled: Bool { dataPageVisibilityController.isThingPageEnabled }
    var activeMainTab: MainTab { navigationState.activeMainTab }
    var pendingSystemListToOpen: MainTab? {
        get { notificationOpenController.pendingListToOpen }
        set { notificationOpenController.pendingListToOpen = newValue }
    }
    var isMessageListAtTop: Bool { navigationState.isMessageListAtTop }
    var isEventListAtTop: Bool { navigationState.isEventListAtTop }
    var isThingListAtTop: Bool { navigationState.isThingListAtTop }
    var pendingSettingsPresentation: SettingsPresentationRequest?
    private(set) var channelListFeedbackMessage: String?
    var channelSubscriptions: [ChannelSubscription] { channelSyncController.channelSubscriptions }
    private var isQualityChannelMutationSession: Bool {
#if DEBUG
        guard let scenario = PushGoAutomationContext.qualitySession?.channelMutationScenario else {
            return false
        }
        return scenario != .none
#else
        false
#endif
    }
    private let channelSubscriptionService = ChannelSubscriptionService()
    private let networkPermissionChecker = NetworkPermissionChecker()
    @ObservationIgnored private let localStoreFailureStreakThreshold = 3
    @ObservationIgnored private let localStoreFailureStreakKey = "pushgo.local_store.failure_streak"
    @ObservationIgnored private let localStoreFailureDefaults = AppConstants.sharedUserDefaults()
    // Keep AppEnvironment as the composition root. Feature-specific behavior
    // should extend the dedicated controllers below instead of growing new
    // state machines in this type.
    @ObservationIgnored private(set) lazy var providerRouteController = ProviderRouteController(
        platform: platformIdentifier(),
        dataStore: dataStore,
        channelSubscriptionService: channelSubscriptionService,
        localizationManager: localizationManager,
        refreshAutomationState: { [weak self] in
            self?.refreshAutomationStateIfNeeded()
        },
        runtimeMessageRecorder: { [weak self] message, source, category, code in
            self?.recordAutomationRuntimeMessage(
                message,
                source: source,
                category: category,
                code: code
            )
        }
    )
    @ObservationIgnored private(set) lazy var watchSyncController = WatchSyncController(
        dataStore: dataStore,
        messageStateCoordinatorProvider: { [weak self] in
            self?.messageStateCoordinator
        },
        serverConfigProvider: { [weak self] in
            self?.serverConfig
        },
        runtimeErrorRecorder: { [weak self] error, source in
            self?.recordAutomationRuntimeError(error, source: source, category: "watch")
        },
        runtimeMessageRecorder: { [weak self] message, source in
            self?.recordAutomationRuntimeMessage(message, source: source, category: "watch")
        }
    )
    @ObservationIgnored private(set) lazy var notificationIngressController = makeNotificationIngressController()
    @ObservationIgnored private(set) lazy var notificationOpenController = NotificationOpenController(
        dataStore: dataStore,
        localizationManager: localizationManager,
        messageStateCoordinatorProvider: { [weak self] in
            self?.messageStateCoordinator
        },
        refreshCountsAndNotify: { [weak self] in
            await self?.refreshMessageCountsAndNotify()
        },
        removeDeliveredNotificationIfNeeded: { [weak self] message in
            self?.removeDeliveredNotificationIfNeeded(for: message)
        },
        autoEnableDataPage: { [weak self] entityType in
            self?.autoEnableDataPage(for: entityType)
        },
        showToast: { [weak self] message in
            self?.showToast(message: message)
        }
    )
    @ObservationIgnored private(set) lazy var navigationState = AppNavigationState()
    @ObservationIgnored private(set) lazy var channelSyncController = ChannelSyncController(
        platform: platformIdentifier(),
        dataStore: dataStore,
        pushRegistrationService: pushRegistrationService,
        channelSubscriptionService: channelSubscriptionService,
        providerRouteController: providerRouteController,
        subscriptionSyncRoundTrip: Self.makeQualityChannelSyncRoundTrip(),
        localizationManager: localizationManager,
        serverConfigProvider: { [weak self] in
            self?.serverConfig
        },
        requestWatchStandaloneProvisioningSync: { [weak self] immediate in
            self?.requestWatchStandaloneProvisioningSync(immediate: immediate)
        },
        recordRuntimeError: { [weak self] error, source in
            self?.recordAutomationRuntimeError(error, source: source)
        },
        showToast: { [weak self] message in
            self?.showToast(message: message)
        },
        showChannelEntryFeedback: { [weak self] message in
            self?.channelListFeedbackMessage = message
        }
    )
    @ObservationIgnored private(set) lazy var dataPageVisibilityController = DataPageVisibilityController(
        dataStore: dataStore
    )
    @ObservationIgnored private(set) lazy var channelSubscriptionController = ChannelSubscriptionController(
        platform: platformIdentifier(),
        dataStore: dataStore,
        channelSubscriptionService: channelSubscriptionService,
        providerRouteController: providerRouteController,
        channelSyncController: channelSyncController,
        localizationManager: localizationManager,
        serverConfigProvider: { [weak self] in
            self?.serverConfig
        },
        messageStateCoordinatorProvider: { [weak self] in
            self?.messageStateCoordinator
        },
        channelMutationRoundTrip: Self.makeQualityChannelMutationRoundTrip()
    )
    @ObservationIgnored private(set) lazy var pendingLocalDeletionController = PendingLocalDeletionController(
        dataStore: dataStore,
        channelCommitHandler: { [weak self] record, owner in
            guard let self else { throw CancellationError() }
            return try await self.channelSubscriptionController.commitPendingChannelRemoval(
                record: record,
                leaseOwner: owner
            )
        },
        cleanupHandler: { [weak self] cleanup in
            guard let self else { return }
            await self.messageStateCoordinator.reconcileExternallyDeletedMessages(
                notificationRequestIDs: cleanup.notificationRequestIDs,
                imageURLs: cleanup.imageURLs
            )
        },
        failureHandler: { [weak self] error in
            self?.showErrorToast(error)
        }
    )
    @ObservationIgnored private(set) lazy var localStoreRecoveryController = LocalStoreRecoveryController(
        dataStore: dataStore,
        localizationManager: localizationManager,
        failureStreakThreshold: localStoreFailureStreakThreshold,
        failureStreakKey: localStoreFailureStreakKey,
        failureDefaults: localStoreFailureDefaults,
        showToast: { [weak self] message in
            self?.showToast(message: message)
        },
        terminate: {
            Darwin.exit(0)
        }
    )

    var watchMode: WatchMode { watchSyncController.watchMode }
    var effectiveWatchMode: WatchMode { watchSyncController.effectiveWatchMode }
    var standaloneReady: Bool { watchSyncController.standaloneReady }
    var watchModeSwitchStatus: WatchModeSwitchStatus { watchSyncController.watchModeSwitchStatus }
    var isWatchCompanionAvailable: Bool { watchSyncController.isWatchCompanionAvailable }

    private init(
        dataStore: LocalDataStore = LocalDataStore(),
        pushRegistrationService: PushRegistrationService? = nil,
        localizationManager: LocalizationManager? = nil,
    ) {
        self.dataStore = dataStore
        self.pushRegistrationService = pushRegistrationService ?? PushRegistrationService.shared
        self.localizationManager = localizationManager ?? LocalizationManager.shared
        PushGoLiveActivityTokenRegistrationService.configure { [weak self] in
            self?.serverConfig
        }
        PushGoWidgetPushRegistrationService.configure { [weak self] in
            self?.serverConfig
        }
        SharedImageCache.startMaintenance()
        messageSyncObserver = DarwinNotificationObserver(name: AppConstants.messageSyncNotificationName) { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                await self.reloadMessagesFromStore()
            }
        }
#if DEBUG
        let suppressIngressObserver = ingressPerformanceMeasurement?.mode == .baseline
            || ingressPerformanceMeasurement?.mode == .seed
            || ingressPerformanceMeasurement?.mode == .cleanup
#else
        let suppressIngressObserver = false
#endif
        if !suppressIngressObserver {
            notificationIngressObserver = DarwinNotificationObserver(
                name: AppConstants.notificationIngressChangedNotificationName
            ) { [weak self] in
                guard let self else { return }
                Task { @MainActor in
                    await self.notificationIngressController.handleNotificationIngressChanged(
                        reason: "darwin_notification"
                    )
                }
            }
        }
        registerDefaultNotificationCategories()
    }

    private static func makeQualityChannelMutationRoundTrip() -> (any ChannelMutationRoundTrip)? {
#if DEBUG
        guard let scenario = PushGoAutomationContext.qualitySession?.channelMutationScenario,
              scenario != .none
        else {
            return nil
        }
        return QualityChannelAutomationRoundTrip(scenario: scenario)
#else
        return nil
#endif
    }

    private static func makeQualityChannelSyncRoundTrip() -> (any ChannelSubscriptionSyncRoundTrip)? {
#if DEBUG
        guard let scenario = PushGoAutomationContext.qualitySession?.channelMutationScenario,
              scenario != .none
        else {
            return nil
        }
        return QualityChannelAutomationRoundTrip(scenario: scenario)
#else
        return nil
#endif
    }

    private func makeNotificationIngressController() -> NotificationIngressController {
        NotificationIngressController(
            platformSuffix: platformIdentifier(),
            dataStore: dataStore,
            channelSubscriptionService: channelSubscriptionService,
            serverConfigProvider: { [weak self] in
                self?.serverConfig
            },
            cachedDeviceKeyProvider: { [weak self] in
                guard let self else { return nil }
                return await self.providerRouteController.cachedProviderPullDeviceKey()
            },
            beforePersistMessage: { [weak self] message in
                await MainActor.run {
                    self?.autoEnableDataPageIfNeeded(for: message)
                }
            },
            scheduleCountsRefresh: { [weak self] in
                self?.scheduleCountsRefresh()
            },
            reportInboxProgress: { [weak self] progress in
                self?.handleInboxProgress(progress)
            },
            recordProviderError: { [weak self] error, source in
                self?.recordAutomationRuntimeError(error, source: source, category: "provider")
            },
            shouldDeferStartupWakeupPulls: { [weak self] in
                self?.shouldDeferStartupWakeupPulls ?? false
            },
            notificationIngressInbox: .shared,
            ackFailureStore: .shared
        )
    }

    func bootstrap() async {
        if didBootstrap {
            return
        }
        if let bootstrapTask {
            await bootstrapTask.value
            return
        }

        let task = Task { @MainActor in
            await self.performBootstrap()
        }
        bootstrapTask = task
        await task.value
        didBootstrap = true
        bootstrapTask = nil
    }

#if DEBUG
    func markQualityRuntimeReadiness(_ status: String?) {
        qualityRuntimeReadiness = status ?? "inactive"
    }
#endif

    private func performBootstrap() async {
#if DEBUG
        if await runIngressPerformancePreparationIfNeeded() {
            isDeletionRecoveryReady = true
            return
        }
#endif
        beginProviderIngressBootstrapRecovery()
        await loadPersistedState()
        guard dataStore.storageState.mode == .persistent else {
            finishProviderIngressBootstrapRecovery()
            isDeletionRecoveryReady = true
            return
        }
#if DEBUG
        if ingressPerformanceMeasurement?.mode == .measure {
            ingressPerformanceMeasurement?.baselineMessageCount = totalMessageCount
            logIngressPerformancePhase("canonical_baseline", details: [
                "message_count": "\(totalMessageCount)",
            ])
        }
#endif
        startMessageStoreObservationIfNeeded()
        await pendingLocalDeletionController.restorePendingState()
        isDeletionRecoveryReady = true
        Task(priority: .utility) { @MainActor in
            await pendingLocalDeletionController.processDueDeletions()
        }
        Task(priority: .utility) { @MainActor in
            await drainProviderDeliveryAckFailures(source: "provider.bootstrap.ack_failure.ios")
        }
        Task(priority: .utility) { @MainActor in
            defer {
                finishProviderIngressBootstrapRecovery()
            }
            let applied = await mergeNotificationIngressInbox(
                reason: "bootstrap",
                allowFallbackPull: false
            )
#if DEBUG
            if self.ingressPerformanceMeasurement?.mode == .measure {
                self.logIngressPerformancePhase("canonical_drain_complete", details: [
                    "applied": "\(applied)",
                ])
            }
#endif
            await dataStore.scheduleDerivedWorkDrain()
            await preparePushInfrastructure()
            let syncOutcome = await syncProviderIngressOutcome(reason: "bootstrap_ready")
            _ = await mergeNotificationIngressInbox(
                reason: "bootstrap_post_sync",
                allowFallbackPull: false
            )
            if syncOutcome.completedRequest {
                _ = await purgePendingUnresolvedWakeupEntries()
            }
        }
        let store = dataStore
        Task(priority: .utility) {
            await store.warmCachesIfNeeded()
        }
        Task(priority: .utility) {
            await NotificationSoundManager.shared.reconcileCompiledSounds()
        }
        Task(priority: .utility) {
            await store.ensureSystemSearchIndexHealthy()
        }
    }

    private func startMessageStoreObservationIfNeeded() {
        guard messageStoreObservationTask == nil else { return }
        let store = dataStore
        messageStoreObservationTask = Task { @MainActor [weak self] in
            do {
                let revisions = try await store.messageStoreRevisionValues()
                for try await _ in revisions {
                    guard !Task.isCancelled else { break }
                    self?.scheduleMessageListRefresh()
                }
            } catch {
                // Imperative refresh hooks remain a compatibility accelerator;
                // foreground bootstrap will retry observation next launch.
            }
        }
    }

    private static func makeDefaultServerConfig() -> ServerConfig? {
        guard let url = AppConstants.defaultServerURL else { return nil }
        return ServerConfig(
            baseURL: url,
            token: AppConstants.defaultGatewayToken,
            notificationKeyMaterial: nil,
            updatedAt: Date()
        )
    }

    private func registerDefaultNotificationCategories() {
        UNUserNotificationCenter.current().setNotificationCategories(
            PushGoNotificationActionPolicy.categories()
        )
    }

    func updateServerConfig(_ config: ServerConfig?) async throws {
        let previousConfig = serverConfig
        let previousDeviceKey = await dataStore.cachedDeviceKey(
            for: platformIdentifier(),
            channelType: "apns"
        )?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = config?.normalized()
        try await dataStore.saveServerConfig(normalized)
        await activatePersistedServerConfig(
            normalized,
            previousConfig: previousConfig,
            previousDeviceKey: previousDeviceKey
        )
    }

    /// A user-initiated gateway switch is a prepare/commit operation. The
    /// candidate must accept device registration and the active APNs route
    /// before it can replace the current local identity or trigger cleanup.
    func validateAndUpdateServerConfig(_ config: ServerConfig) async throws {
        let normalized = config.normalized()
        let previousConfig = serverConfig
        if gatewayIdentity(previousConfig) == gatewayIdentity(normalized) {
            try await updateServerConfig(normalized)
            return
        }
        let previousDeviceKey = await dataStore.cachedDeviceKey(
            for: platformIdentifier(),
            channelType: "apns"
        )?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let preparedDeviceKey = try await prepareCandidateGateway(normalized)

        try await dataStore.saveServerConfig(normalized)
        do {
#if DEBUG
            if remainingQualityGatewaySwitchCommitFailures > 0 {
                remainingQualityGatewaySwitchCommitFailures -= 1
                throw AppError.typedLocal(
                    code: "quality_gateway_local_commit_failed",
                    category: .local,
                    message: localizationManager.localized("operation_failed"),
                    detail: "quality gateway commit failed after candidate config persistence"
                )
            }
#endif
            try await providerRouteController.persistProviderDeviceKey(
                preparedDeviceKey,
                source: "provider.device_key.gateway_switch"
            )
        } catch {
            // Keep the old gateway authoritative if the local half of the
            // candidate commit cannot complete. Remote candidate registration
            // is safe to repeat and is not used until a later successful save.
            do {
                try await dataStore.saveServerConfig(previousConfig)
            } catch let rollbackError {
                throw AppError.typedLocal(
                    code: "gateway_local_commit_rollback_failed",
                    category: .local,
                    message: localizationManager.localized("operation_failed"),
                    detail: "commit=\(error.localizedDescription); rollback=\(rollbackError.localizedDescription)"
                )
            }
            throw error
        }
        await activatePersistedServerConfig(
            normalized,
            previousConfig: previousConfig,
            previousDeviceKey: previousDeviceKey
        )
    }

    private func activatePersistedServerConfig(
        _ normalized: ServerConfig?,
        previousConfig: ServerConfig?,
        previousDeviceKey: String?
    ) async {
        serverConfig = normalized
        await refreshChannelSubscriptions(syncWatch: false)
        if isQualityChannelMutationSession {
            return
        }
        requestWatchStandaloneProvisioningSync(immediate: true)
        providerRouteController.schedulePreviousGatewayDeviceCleanup(
            previousConfig: previousConfig,
            previousDeviceKey: previousDeviceKey,
            nextConfig: normalized
        )
    }

    private func prepareCandidateGateway(_ config: ServerConfig) async throws -> String {
#if DEBUG
        if PushGoAutomationContext.qualitySession != nil {
            if remainingQualityGatewaySwitchValidationFailures > 0 {
                remainingQualityGatewaySwitchValidationFailures -= 1
                throw AppError.typedLocal(
                    code: "quality_gateway_registration_rejected",
                    category: .network,
                    message: localizationManager.localized("operation_failed"),
                    detail: "quality candidate gateway rejected device registration"
                )
            }
            guard isQualityChannelMutationSession else {
                throw AppError.typedLocal(
                    code: "quality_gateway_validation_unconfigured",
                    category: .internalError,
                    message: localizationManager.localized("operation_failed"),
                    detail: "quality gateway switch requires an explicit accepted round trip"
                )
            }
            return "quality-gateway-device"
        }
#endif
        let providerToken = try await pushRegistrationService.awaitToken()
        return try await providerRouteController.prepareProviderRoute(
            config: config,
            providerToken: providerToken,
            reuseExistingDeviceKey: false
        )
    }

    private func gatewayIdentity(_ config: ServerConfig?) -> String {
        guard let config else { return "" }
        let normalized = config.normalized()
        let token = normalized.token?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return "\(normalized.baseURL.absoluteString)|\(token)"
    }

    func replaceMessages(_ newMessages: [PushMessage]) async {
        do {
            let sanitized = newMessages.map { message in
                var copy = message
                copy.url = URLSanitizer.sanitizeExternalOpenURL(message.url)
                return copy
            }
            try await dataStore.saveMessages(sanitized.sorted { $0.receivedAt > $1.receivedAt })
            await refreshMessageCountsAndNotify()
        } catch {
            showToast(message: localizationManager.localized(
                "failed_to_save_message_placeholder",
                userFacingErrorMessage(error),
            ))
        }
    }

    func refreshMessageCountsAndNotify() async {
        do {
            let counts = try await dataStore.messageCounts()
            totalMessageCount = counts.total
            unreadMessageCount = counts.unread
            BadgeManager.syncAppBadge(unreadCount: counts.unread)
            clearDeliveredSystemNotifications()
            scheduleMessageListRefresh()
            requestWatchMirrorSnapshotSync()
        } catch {
            totalMessageCount = 0
            unreadMessageCount = 0
            BadgeManager.syncAppBadge(unreadCount: 0)
            scheduleMessageListRefresh()
            requestWatchMirrorSnapshotSync()
        }
    }

    func refreshChannelSubscriptions(
        syncWatch: Bool = true,
        immediateStandalone: Bool = false,
        syncProviderRoute: Bool = true
    ) async {
        await channelSyncController.refreshChannelSubscriptions(
            syncWatch: syncWatch,
            immediateStandalone: immediateStandalone,
            syncProviderRoute: syncProviderRoute
        )
    }

    func channelDisplayName(for channelId: String?) -> String? {
        channelSyncController.channelDisplayName(for: channelId)
    }

    func channelExists(channelId: String) async throws -> ChannelSubscriptionService.ExistsPayload {
        try await channelSubscriptionController.channelExists(channelId: channelId)
    }

    func createChannel(alias: String, password: String) async throws -> ChannelSubscriptionService.SubscribePayload {
        try await channelSubscriptionController.createChannel(alias: alias, password: password)
    }

    func subscribeChannel(channelId: String, password: String) async throws -> ChannelSubscriptionService.SubscribePayload {
        try await channelSubscriptionController.subscribeChannel(channelId: channelId, password: password)
    }

    func renameChannel(channelId: String, alias: String) async throws {
        try await channelSubscriptionController.renameChannel(channelId: channelId, alias: alias)
    }

    func unsubscribeChannel(channelId: String) async throws {
        try await channelSubscriptionController.unsubscribeChannel(channelId: channelId)
    }

    func unsubscribeChannelAndDeleteLocalHistory(
        channelId: String,
        expectedGateway: String,
        expectedUpdatedAt: Date
    ) async throws -> Int {
        try await channelSubscriptionController.unsubscribeChannelAndDeleteLocalHistory(
            channelId: channelId,
            expectedGateway: expectedGateway,
            expectedUpdatedAt: expectedUpdatedAt
        )
    }

    func closeEvent(
        eventId: String,
        thingId: String?,
        channelId: String,
        status: String? = nil,
        message: String? = nil,
        severity: String? = nil
    ) async throws {
        guard let config = serverConfig else { throw AppError.noServer }
        let gatewayKey = config.gatewayKey
        let normalizedChannelId = try ChannelIdValidator.normalize(channelId)
        let normalizedEventId = eventId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedEventId.isEmpty else {
            throw AppError.typedLocal(
                code: "event_id_required",
                category: .validation,
                message: localizationManager.localized("operation_failed"),
                detail: "event_id required"
            )
        }
        let trimmedThingId = thingId?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedThingId = (trimmedThingId?.isEmpty == false) ? trimmedThingId : nil
        let normalizedStatus = status?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedMessage = message?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedSeverity = severity?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let localizedStatus = localizationManager
            .localized("event_status_closed_default")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedStatus: String = {
            let statusCandidate = normalizedStatus.flatMap { $0.isEmpty ? nil : $0 } ?? localizedStatus
            if statusCandidate.isEmpty
                || statusCandidate == "event_status_closed_default"
                || statusCandidate.count > 24
            {
                return "closed"
            }
            return statusCandidate
        }()
        let localizedMessage = localizationManager
            .localized("event_message_closed_default")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedMessage: String = {
            let messageCandidate = normalizedMessage.flatMap { $0.isEmpty ? nil : $0 } ?? localizedMessage
            if messageCandidate.isEmpty || messageCandidate == "event_message_closed_default" {
                return "closed"
            }
            return messageCandidate
        }()
        let resolvedSeverity: String = {
            guard let severity = normalizedSeverity,
                  ["critical", "high", "normal", "low"].contains(severity)
            else {
                return "normal"
            }
            return severity
        }()

#if DEBUG
        if let scenario = PushGoAutomationContext.qualitySession?.eventCloseScenario,
           scenario != .none
        {
            var boundaryPayload: [String: Any] = [
                "channel_id": normalizedChannelId,
                "op_id": OpaqueId.generateHex128(),
                "event_id": normalizedEventId,
                "event_time": Int64(Date().timeIntervalSince1970),
                "status": resolvedStatus,
                "message": resolvedMessage,
                "attrs": [String: Any](),
                "severity": resolvedSeverity,
            ]
            if let normalizedThingId {
                boundaryPayload["thing_id"] = normalizedThingId
            }
            let boundaryPath: String
            if let normalizedThingId {
                boundaryPath = "/thing/\(escapedGatewayPathComponent(normalizedThingId))/event/close"
            } else {
                boundaryPath = "/event/close"
            }
            try await postGatewayPayload(boundaryPayload, endpointPath: boundaryPath, config: config)
            return
        }
#endif

        guard let password = await dataStore.channelPassword(gateway: gatewayKey, for: normalizedChannelId) else {
            throw AppError.typedLocal(
                code: "channel_password_missing",
                category: .validation,
                message: localizationManager.localized("channel_password_missing"),
                detail: "channel password missing"
            )
        }

        let endpointPath: String
        if let normalizedThingId {
            endpointPath = "/thing/\(escapedGatewayPathComponent(normalizedThingId))/event/close"
        } else {
            endpointPath = "/event/close"
        }

        var payload: [String: Any] = [
            "channel_id": normalizedChannelId,
            "password": password,
            "op_id": OpaqueId.generateHex128(),
            "event_id": normalizedEventId,
            "event_time": Int64(Date().timeIntervalSince1970),
            "status": resolvedStatus,
            "message": resolvedMessage,
            "attrs": [String: Any](),
        ]
        if let normalizedThingId {
            payload["thing_id"] = normalizedThingId
        }
        payload["severity"] = resolvedSeverity
        try await postGatewayPayload(payload, endpointPath: endpointPath, config: config)
    }

    func handlePushTokenUpdate() {
        channelSyncController.handlePushTokenUpdate()
    }

    func updateWatchPushToken(_ token: String) async {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let platform = "watchos"
        let previous = await dataStore.cachedPushToken(for: platform)
        guard previous != trimmed else { return }

        await dataStore.saveCachedPushToken(trimmed, for: platform)

        if watchMode == .standalone {
            requestWatchStandaloneProvisioningSync(immediate: true)
        }
    }

    private func scheduleCountsRefresh() {
#if DEBUG
        if ingressPerformanceMeasurement?.mode == .measure,
           ingressPerformanceMeasurement?.didLogFirstBatchCommit == false
        {
            ingressPerformanceMeasurement?.didLogFirstBatchCommit = true
            logIngressPerformancePhase("first_batch_canonical_commit")
        }
#endif
        isCountsRefreshRequested = true
        guard pendingCountsRefreshTask == nil else { return }
        pendingCountsRefreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            repeat {
                self.isCountsRefreshRequested = false
                await self.refreshMessageCountsAndNotify()
            } while self.isCountsRefreshRequested && !Task.isCancelled
            self.pendingCountsRefreshTask = nil
        }
    }

    private func handleInboxProgress(_ progress: ProviderInboxProgress) {
        pendingInboxProgress = progress
        switch progress {
        case let .processing(completed, total):
            ingressNoticeDismissTask?.cancel()
            ingressNoticeDismissTask = nil
            if messageIngressNotice != nil {
                messageIngressNotice = .processing(completed: completed, total: total)
            } else if ingressNoticeRevealTask == nil {
                scheduleIngressNoticeReveal(total: total)
            }
            scheduleIngressNoticeWatchdog()

        case let .waitingRetry(remaining):
            ingressNoticeRevealTask?.cancel()
            ingressNoticeRevealTask = nil
            ingressNoticeWatchdogTask?.cancel()
            ingressNoticeWatchdogTask = nil
            ingressNoticeDismissTask?.cancel()
            ingressNoticeDismissTask = nil
            let wasWaiting: Bool
            if case .waitingRetry = messageIngressNotice {
                wasWaiting = true
            } else {
                wasWaiting = false
            }
            messageIngressNotice = .waitingRetry(remaining: remaining)
            if !wasWaiting {
                announceAccessibility(messageIngressNoticeText())
            }
            ingressNoticeDismissTask = Task { @MainActor [weak self] in
                do {
                    try await Task.sleep(for: .seconds(4))
                } catch {
                    return
                }
                guard self?.messageIngressNotice == .waitingRetry(remaining: remaining) else {
                    return
                }
                self?.messageIngressNotice = nil
                self?.ingressNoticeDismissTask = nil
            }

        case .completed:
            ingressNoticeRevealTask?.cancel()
            ingressNoticeRevealTask = nil
            ingressNoticeWatchdogTask?.cancel()
            ingressNoticeWatchdogTask = nil
            pendingInboxProgress = nil
            guard messageIngressNotice != nil else { return }
            messageIngressNotice = .completed
            announceAccessibility(messageIngressNoticeText())
            ingressNoticeDismissTask?.cancel()
            ingressNoticeDismissTask = Task { @MainActor [weak self] in
                do {
                    try await Task.sleep(for: .milliseconds(800))
                } catch {
                    return
                }
                guard self?.messageIngressNotice == .completed else { return }
                self?.messageIngressNotice = nil
                self?.ingressNoticeDismissTask = nil
            }
        }
    }

    private func scheduleIngressNoticeReveal(total: Int) {
        let delay: Duration = total >= 500 ? .milliseconds(350) : .milliseconds(900)
        ingressNoticeRevealTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            guard let self,
                  case let .processing(completed, latestTotal) = pendingInboxProgress,
                  messageIngressNotice == nil
            else { return }
            messageIngressNotice = .processing(completed: completed, total: latestTotal)
            ingressNoticeRevealTask = nil
            announceAccessibility(messageIngressNoticeText())
        }
    }

    private func scheduleIngressNoticeWatchdog() {
        ingressNoticeWatchdogTask?.cancel()
        ingressNoticeWatchdogTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(10))
            } catch {
                return
            }
            guard let self,
                  case let .processing(completed, total) = pendingInboxProgress
            else { return }
            messageIngressNotice = .processingSlow(completed: completed, total: total)
            ingressNoticeWatchdogTask = nil
            announceAccessibility(messageIngressNoticeText())
        }
    }

    func messageIngressNoticeText(
        for notice: MessageIngressNotice? = nil
    ) -> String {
        let resolvedNotice = notice ?? messageIngressNotice
        switch resolvedNotice {
        case .processing:
            return localizationManager.localized("message_ingress_processing_progress")
        case .processingSlow:
            return localizationManager.localized("message_ingress_processing_slow")
        case .waitingRetry:
            return localizationManager.localized("message_ingress_waiting_retry")
        case .completed:
            return localizationManager.localized("message_ingress_completed")
        case nil:
            return ""
        }
    }

    private func scheduleMessageListRefresh() {
        messageStoreRevision = UUID()
    }

#if DEBUG
    func recordIngressPerformanceUIRefreshCompleted(
        totalMessageCount displayedTotal: Int,
        visibleMessageCount: Int
    ) {
        guard ingressPerformanceMeasurement?.mode == .measure,
              let baseline = ingressPerformanceMeasurement?.baselineMessageCount,
              let pendingCount = ingressPerformanceMeasurement?.pendingCount
        else { return }
        if ingressPerformanceMeasurement?.didLogCachedUI == false {
            ingressPerformanceMeasurement?.didLogCachedUI = true
            logIngressPerformancePhase("first_ui_refresh", details: [
                "displayed_total": "\(displayedTotal)",
                "visible": "\(visibleMessageCount)",
            ])
        }
        let firstBatchTarget = baseline + min(64, pendingCount)
        if displayedTotal >= firstBatchTarget,
           ingressPerformanceMeasurement?.didLogFirstBatchUI == false
        {
            ingressPerformanceMeasurement?.didLogFirstBatchUI = true
            logIngressPerformancePhase("first_batch_ui_visible", details: [
                "displayed_total": "\(displayedTotal)",
                "visible": "\(visibleMessageCount)",
            ])
        }
        let allPendingTarget = baseline + pendingCount
        if displayedTotal >= allPendingTarget,
           ingressPerformanceMeasurement?.didLogAllPendingUI == false
        {
            ingressPerformanceMeasurement?.didLogAllPendingUI = true
            logIngressPerformancePhase("all_pending_ui_visible", details: [
                "displayed_total": "\(displayedTotal)",
                "visible": "\(visibleMessageCount)",
            ])
        }
    }

    private func runIngressPerformancePreparationIfNeeded() async -> Bool {
        guard let measurement = ingressPerformanceMeasurement else { return false }
        switch measurement.mode {
        case .measure:
            logIngressPerformancePhase("process_bootstrap_start")
            return false
        case .baseline:
            return await seedIngressPerformanceBaseline(measurement)
        case .seed:
            return await seedIngressPerformanceFixture(measurement)
        case .cleanup:
            do {
                let removed = try await dataStore.deleteMessages(channel: measurement.fixtureChannel)
                let journalCleanup = await NotificationIngressInbox.shared.purgePerformanceFixtures()
                logIngressPerformancePhase("cleanup_ready", details: [
                    "journal_rows": "\(journalCleanup.rows)",
                    "removed": "\(removed)",
                    "shadows": "\(journalCleanup.shadows)",
                ])
            } catch {
                logIngressPerformancePhase("cleanup_failed")
            }
            return true
        }
    }

    private func seedIngressPerformanceBaseline(
        _ measurement: PushGoIngressPerformanceMeasurement
    ) async -> Bool {
        do {
            let before = try await dataStore.messageCounts().total
            let requiredCount = max(0, measurement.pendingCount - before)
            let inputs = (0..<requiredCount).map { index in
                let identity = "ingress-baseline-\(measurement.runID)-\(index)"
                return NotificationPersistenceCoordinator.RemotePayload(
                    payload: [
                        "message_id": identity,
                        "delivery_id": identity,
                        "title": "Baseline message \(index)",
                        "body": "Baseline",
                        "channel": measurement.fixtureChannel,
                        "channel_id": measurement.fixtureChannel,
                    ],
                    requestIdentifier: identity
                )
            }
            let outcomes = await NotificationPersistenceCoordinator.persistRemotePayloadsIfNeeded(
                inputs,
                dataStore: dataStore
            )
            let accepted = outcomes.reduce(into: 0) { result, outcome in
                switch outcome {
                case .persistedMain, .persistedPending, .duplicate:
                    result += 1
                case .rejected, .failed:
                    break
                }
            }
            let after = try await dataStore.messageCounts().total
            logIngressPerformancePhase("baseline_ready", details: [
                "accepted": "\(accepted)",
                "after": "\(after)",
                "before": "\(before)",
            ])
        } catch {
            logIngressPerformancePhase("baseline_failed")
        }
        return true
    }

    private func seedIngressPerformanceFixture(
        _ measurement: PushGoIngressPerformanceMeasurement
    ) async -> Bool {
        let inbox = NotificationIngressInbox.shared
        let preexistingPendingCount = await inbox.pendingEntries(limit: 10_000).count
        guard preexistingPendingCount == 0 else {
            logIngressPerformancePhase("seed_aborted", details: [
                "preexisting_pending": "\(preexistingPendingCount)",
            ])
            return true
        }
        var acceptedCount = 0
        let sentAtBase = Int64(Date().timeIntervalSince1970 * 1_000)
        let fixtureBody: String
        switch measurement.payloadKind {
        case .short:
            fixtureBody = "短消息实机性能测试"
        case .long:
            fixtureBody = String(
                repeating: "长消息性能测试正文用于验证批量入库首屏加载数据库观察刷新与最终一致性。",
                count: 40
            )
        }
        for index in 0..<measurement.pendingCount {
            let identity = "ingress-perf-\(measurement.runID)-\(index)"
            let accepted = await inbox.enqueue(
                codablePayload: [
                    "message_id": AnyCodable(identity),
                    "delivery_id": AnyCodable(identity),
                    "title": AnyCodable("Ingress performance \(index)"),
                    "body": AnyCodable(fixtureBody),
                    "channel": AnyCodable(measurement.fixtureChannel),
                    "channel_id": AnyCodable(measurement.fixtureChannel),
                    "sent_at": AnyCodable("\(sentAtBase + Int64(index))"),
                ],
                requestIdentifier: identity,
                source: "debug.ingress_performance",
                postChangeNotification: false
            )
            if accepted { acceptedCount += 1 }
        }
        let duePendingCount = await inbox.pendingEntries(limit: 10_000).count
        logIngressPerformancePhase("seed_ready", details: [
            "accepted": "\(acceptedCount)",
            "body_characters": "\(fixtureBody.count)",
            "due_pending": "\(duePendingCount)",
        ])
        return true
    }

    private func logIngressPerformancePhase(
        _ phase: String,
        details: [String: String] = [:]
    ) {
        guard let measurement = ingressPerformanceMeasurement else { return }
        let elapsedMilliseconds = max(
            0,
            Int(
                (ProcessInfo.processInfo.systemUptime - measurement.processStartUptime) * 1_000
            )
        )
        let detailText = details
            .sorted { $0.key < $1.key }
            .map { key, value in
                "\(key)=\(value.replacingOccurrences(of: " ", with: "_"))"
            }
            .joined(separator: " ")
        let suffix = detailText.isEmpty ? "" : " \(detailText)"
        print(
            "[PushGoIngressPerf] run=\(measurement.runID) count=\(measurement.pendingCount) "
                + "payload=\(measurement.payloadKind.rawValue) "
                + "phase=\(phase) elapsed_ms=\(elapsedMilliseconds)\(suffix)"
        )
        fflush(stdout)
    }
#endif

    func publishStoreRefreshForAutomation() {
        messageStoreRevision = UUID()
    }

    func addLocalMessage(
        title: String,
        body: String,
        channel: String?,
        url: URL?,
        rawPayload: [String: Any],
        decryptionState: PushMessage.DecryptionState? = nil,
        messageId: String? = nil,
        operationId: String? = nil,
        titleWasExplicit: Bool = true,
    ) async -> Bool {
        let bridgedPayload: [AnyHashable: Any] = rawPayload.reduce(into: [:]) { result, element in
            result[element.key] = element.value
        }
        var payload = UserInfoSanitizer.sanitize(bridgedPayload)
        if payload["title"] == nil || !titleWasExplicit {
            payload["title"] = title
        }
        if payload["body"] == nil {
            payload["body"] = body
        }
        let trimmedChannel = channel?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmedChannel, !trimmedChannel.isEmpty, payload["channel_id"] == nil {
            payload["channel_id"] = trimmedChannel
        }
        let sanitizedURL = URLSanitizer.sanitizeExternalOpenURL(url)
        if let sanitizedURL, payload["url"] == nil {
            payload["url"] = sanitizedURL.absoluteString
        }
        if payload["decryption_state"] == nil,
           let decryptionState
        {
            payload["decryption_state"] = decryptionState.rawValue
        }
        if payload["op_id"] == nil,
           let operationId = operationId?.trimmingCharacters(in: .whitespacesAndNewlines),
           !operationId.isEmpty
        {
            payload["op_id"] = operationId
        }
        if NotificationHandling.shouldSkipPersistence(for: payload) {
            return true
        }
        let fallbackRequestId: String? = {
            let deliveryId = (payload["delivery_id"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !deliveryId.isEmpty {
                return deliveryId
            }
            let normalizedMessageId = messageId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return normalizedMessageId.isEmpty ? nil : normalizedMessageId
        }()
        let outcome = await NotificationPersistenceCoordinator.persistRemotePayloadIfNeeded(
            payload,
            requestIdentifier: fallbackRequestId,
            dataStore: dataStore,
            beforeSave: { [weak self] message in
                guard let self else { return }
                await self.autoEnableDataPageIfNeeded(for: message)
            }
        )
        switch outcome {
        case .duplicate:
            scheduleCountsRefresh()
            return true
        case .persistedMain, .persistedPending:
            scheduleCountsRefresh()
            requestWatchMirrorSnapshotSync()
            return true
        case .rejected:
            return false
        case .failed:
            showToast(message: localizationManager.localized(
                "failed_to_save_message_placeholder",
                "notification persistence failed"
            ))
            return false
        }
    }

    func reloadMessagesFromStore() async {
        await refreshMessageCountsAndNotify()
    }

    func markMessage(_ messageId: UUID, isRead: Bool) async {
        guard isRead else { return }
        do {
            _ = try await messageStateCoordinator.markRead(messageId: messageId)
        } catch {
            showToast(message: localizationManager.localized(
                "failed_to_save_message_status_placeholder",
                userFacingErrorMessage(error),
            ))
        }
    }

    func consumePendingSystemAction() async {
        guard let action = PushGoSystemPendingActionStore.consume() else { return }
        switch action {
        case .markLatestUnreadMessageRead:
            await markLatestUnreadMessageRead()
        }
    }

    private func markLatestUnreadMessageRead() async {
        do {
            guard let message = try await dataStore.loadMessagesPage(
                before: nil,
                limit: 1,
                filter: .unreadOnly,
                channel: nil,
                tag: nil,
                sortMode: .timeDescending
            ).first else {
                return
            }
            _ = try await messageStateCoordinator.markRead(messageId: message.id)
        } catch {
            showToast(message: localizationManager.localized(
                "failed_to_save_message_status_placeholder",
                userFacingErrorMessage(error),
            ))
        }
    }

    private func syncBadgeWithUnreadCount() {
        BadgeManager.syncAppBadge(unreadCount: unreadMessageCount)
    }

    func removeDeliveredNotificationIfNeeded(for message: PushMessage) {
        guard message.isRead, let identifier = message.notificationRequestId else { return }
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [identifier])
    }

    private func removeDeliveredNotificationsForNewlyReadMessages(
        from oldMessages: [PushMessage],
        to newMessages: [PushMessage]
    ) {
        let oldMap = Dictionary(uniqueKeysWithValues: oldMessages.map { ($0.id, $0) })
        let newlyRead = newMessages.filter { message in
            guard message.isRead else { return false }
            if let previous = oldMap[message.id] {
                return previous.isRead == false
            }
            return true
        }
        newlyRead.forEach { removeDeliveredNotificationIfNeeded(for: $0) }
    }

    func showToast(message: String, style: ToastMessage.Style = .error, duration: TimeInterval = 3) {
        toastDismissTask?.cancel()
        let toast = ToastMessage(text: message, style: style)
        toastMessage = toast
        announceAccessibility(message)
        toastDismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            await MainActor.run {
                self?.dismissToast(id: toast.id)
            }
        }
    }

    func userFacingErrorMessage(
        _ error: Error,
        fallbackMessage: String? = nil
    ) -> String {
        let defaultMessage = fallbackMessage ?? localizationManager.localized("operation_failed")
        let wrapped = AppError.wrap(error, fallbackMessage: defaultMessage)
        return wrapped.errorDescription ?? defaultMessage
    }

    func showErrorToast(
        _ error: Error,
        fallbackMessage: String? = nil,
        style: ToastMessage.Style = .error,
        duration: TimeInterval = 3
    ) {
        showToast(
            message: userFacingErrorMessage(error, fallbackMessage: fallbackMessage),
            style: style,
            duration: duration
        )
    }

    func clearChannelListFeedback() {
        channelListFeedbackMessage = nil
    }

    private func recordAutomationRuntimeError(
        _ error: Error,
        source: String,
        category: String = "runtime"
    ) {
        #if DEBUG
        if shouldSuppressAutomationRuntimeError(error, source: source) {
            return
        }
        let message: String
        let code: String?
        if let appError = error as? AppError {
            message = appError.errorDescription ?? String(describing: appError)
            code = appError.code
        } else {
            message = error.localizedDescription
            code = nil
        }
        PushGoAutomationRuntime.shared.recordRuntimeError(
            source: source,
            category: category,
            code: code,
            message: message
        )
        #endif
    }

    private func shouldSuppressAutomationRuntimeError(_ error: Error, source: String) -> Bool {
        guard PushGoAutomationContext.isActive else { return false }
        if (source == "channel.sync.launch" || source == "channel.sync.entry"),
           PushGoAutomationContext.bypassPushAuthorizationPrompt
        {
            return true
        }
        guard source == "channel.sync.launch" || source == "channel.sync.entry" else { return false }
        if let appError = error as? AppError {
            return appError == .apnsDenied || appError.code == "E_APNS_DENIED"
        }
        return (error as NSError).localizedDescription.contains("E_APNS_DENIED")
    }

    private func recordAutomationRuntimeMessage(
        _ message: String,
        source: String,
        category: String = "runtime",
        code: String? = nil
    ) {
        #if DEBUG
        PushGoAutomationRuntime.shared.recordRuntimeError(
            source: source,
            category: category,
            code: code,
            message: message
        )
        #endif
    }

    private func refreshAutomationStateIfNeeded() {
        #if DEBUG
        PushGoAutomationRuntime.shared.refreshState(environment: self)
        #endif
    }

    func dismissToast(id: UUID) {
        if toastMessage?.id == id {
            toastDismissTask?.cancel()
            toastDismissTask = nil
            toastMessage = nil
        }
    }

    struct ToastMessage: Identifiable, Equatable {
        enum Style {
            case info
            case success
            case error
        }

        let id = UUID()
        let text: String
        let style: Style

        init(text: String, style: Style) {
            self.text = text
            self.style = style
        }
    }

    private func announceAccessibility(_ message: String) {
        UIAccessibility.post(notification: .announcement, argument: message)
    }

    func dismissLocalStoreRecovery() {
        localStoreRecoveryController.dismissLocalStoreRecovery()
    }

    var isLocalStoreRecoveryAlertPresented: Bool {
        get { localStoreRecoveryState != nil }
        set {
            if !newValue {
                dismissLocalStoreRecovery()
            }
        }
    }

    func dismissNotificationPermissionAlert() {
        shouldPresentNotificationPermissionAlert = false
    }

    var isNotificationPermissionAlertPresented: Bool {
        get { shouldPresentNotificationPermissionAlert }
        set {
            if !newValue {
                dismissNotificationPermissionAlert()
            }
        }
    }

    func openSystemNotificationSettings() {
        guard !PushGoAutomationContext.blocksCrossAppDataAccess else { return }
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    private func presentNotificationPermissionAlertIfNeeded() {
        guard !PushGoAutomationContext.isActive else { return }
        shouldPresentNotificationPermissionAlert = true
    }

    func terminateForLocalStoreFailure() {
        localStoreRecoveryController.terminateForLocalStoreFailure()
    }

    func rebuildLocalStoreForRecoveryAndTerminate() {
        localStoreRecoveryController.rebuildLocalStoreForRecoveryAndTerminate()
    }

    func refreshPushAuthorization(
        requestAuthorization: Bool = false,
        presentDeniedPrompt: Bool = false
    ) async {
        do {
            if requestAuthorization {
                try await pushRegistrationService.requestAuthorization()
            } else {
                await pushRegistrationService.refreshAuthorizationStatus()
                if pushRegistrationService.authorizationState == .notDetermined {
                    try await pushRegistrationService.requestAuthorization()
                }
            }

            if pushRegistrationService.authorizationState == .denied {
                if presentDeniedPrompt {
                    presentNotificationPermissionAlertIfNeeded()
                    return
                }
                throw AppError.apnsDenied
            }
            guard pushRegistrationService.authorizationState == .authorized else {
                return
            }

            Task(priority: .utility) { @MainActor [weak self] in
                await self?.syncSubscriptionsOnLaunch()
            }
        } catch let appError as AppError {
            if appError == .apnsDenied, presentDeniedPrompt {
                presentNotificationPermissionAlertIfNeeded()
                return
            }
            recordAutomationRuntimeError(appError, source: "push.authorization.refresh")
            showToast(message: appError.errorDescription ?? localizationManager
                .localized("unable_to_obtain_apns_token"))
        } catch {
            recordAutomationRuntimeError(error, source: "push.authorization.refresh")
            showToast(message: localizationManager.localized(
                "unable_to_obtain_apns_token_placeholder",
                userFacingErrorMessage(error),
            ))
        }
    }

    private func syncSubscriptionsOnLaunch() async {
        if isQualityChannelMutationSession {
            await refreshChannelSubscriptions(syncProviderRoute: false)
            return
        }
        await channelSyncController.syncSubscriptionsOnLaunch()
    }

    func syncSubscriptionsOnChannelListEntry() async {
        if isQualityChannelMutationSession {
            channelListFeedbackMessage = nil
            await refreshChannelSubscriptions(syncProviderRoute: false)
            return
        }
        await channelSyncController.syncSubscriptionsOnChannelListEntry()
    }

    func syncSubscriptionsIfNeeded() async throws {
        if isQualityChannelMutationSession {
            await refreshChannelSubscriptions(syncProviderRoute: false)
            return
        }
        try await channelSyncController.syncSubscriptionsIfNeeded()
    }

    func updateNotificationMaterial(_ material: ServerConfig.NotificationKeyMaterial) async throws {
        var config = serverConfig ?? (Self.makeDefaultServerConfig() ?? ServerConfig(
            id: UUID(),
            name: "Local Device",
            baseURL: AppConstants.defaultServerURL!,
            token: nil,
            notificationKeyMaterial: nil,
            updatedAt: Date(),
        ))
        config.notificationKeyMaterial = material
        config.updatedAt = Date()
        try await updateServerConfig(config)
        let recovery = try await NotificationPersistenceCoordinator.recoverEncryptedMessages(
            using: material,
            dataStore: dataStore
        )
        if recovery.updatedCount > 0 {
            await refreshMessageCountsAndNotify()
        }
    }

    var currentNotificationMaterial: ServerConfig.NotificationKeyMaterial? {
        serverConfig?.notificationKeyMaterial
    }

    var messagePageEnabled: Bool {
        get { isMessagePageEnabled }
        set { setMessagePageEnabled(newValue) }
    }

    var eventPageEnabled: Bool {
        get { isEventPageEnabled }
        set { setEventPageEnabled(newValue) }
    }

    var thingPageEnabled: Bool {
        get { isThingPageEnabled }
        set { setThingPageEnabled(newValue) }
    }

    func setMessagePageEnabled(_ isEnabled: Bool) {
        dataPageVisibilityController.setMessagePageEnabled(isEnabled)
    }

    func setEventPageEnabled(_ isEnabled: Bool) {
        dataPageVisibilityController.setEventPageEnabled(isEnabled)
    }

    func setThingPageEnabled(_ isEnabled: Bool) {
        dataPageVisibilityController.setThingPageEnabled(isEnabled)
    }

    func autoEnableDataPageIfNeeded(for message: PushMessage) {
        dataPageVisibilityController.autoEnableDataPageIfNeeded(for: message)
    }

    private func autoEnableDataPage(for entityType: String) {
        dataPageVisibilityController.autoEnableDataPage(for: entityType)
    }

    private func loadPersistedState() async {
        var bootstrapErrors: [String] = []
        let storeState = dataStore.storageState
        switch storeState.mode {
        case .unavailable:
            recordAutomationRuntimeMessage(
                storeState.reason ?? localizationManager.localized("local_store_unavailable"),
                source: "storage.bootstrap",
                category: "storage",
                code: "E_LOCAL_STORE_UNAVAILABLE"
            )
            localStoreRecoveryController.handleLocalStoreUnavailable(storeState)
            return
        case .persistent:
            localStoreRecoveryController.clearFailureStreak()
            break
        }
        do {
            serverConfig = try await dataStore.loadServerConfig()?.normalized()
        } catch {
            serverConfig = nil
            recordAutomationRuntimeError(error, source: "storage.load_server_config", category: "storage")
            bootstrapErrors.append(localizationManager.localized("server_configuration_read_failed"))
        }

        if serverConfig == nil, let defaultConfig = Self.makeDefaultServerConfig() {
            let normalized = defaultConfig.normalized()
            serverConfig = normalized
            do {
                try await dataStore.saveServerConfig(normalized)
            } catch {
                recordAutomationRuntimeError(error, source: "storage.save_server_config", category: "storage")
                bootstrapErrors.append(localizationManager.localized(
                    "failed_to_save_server_configuration_placeholder",
                    userFacingErrorMessage(error)
                ))
            }
        }
        await watchSyncController.loadPersistedState()
        await dataPageVisibilityController.loadPersistedState()

        do {
            let counts = try await dataStore.messageCounts()
            totalMessageCount = counts.total
            unreadMessageCount = counts.unread
            syncBadgeWithUnreadCount()
        } catch {
            totalMessageCount = 0
            unreadMessageCount = 0
            recordAutomationRuntimeError(error, source: "storage.message_counts", category: "storage")
            bootstrapErrors.append(localizationManager.localized("failed_to_read_historical_messages"))
        }

        if !bootstrapErrors.isEmpty {
            let listFormatter = ListFormatter()
            listFormatter.locale = localizationManager.swiftUILocale
            let mergedReasons = listFormatter.string(from: bootstrapErrors) ?? bootstrapErrors.joined(separator: "、")
            showToast(message: localizationManager.localized("initialization_failed_placeholder", mergedReasons))
        }
        await refreshChannelSubscriptions(syncWatch: false, syncProviderRoute: false)
        await watchSyncController.completeBootstrapSync()
        requestNetworkPermissionOnLaunch()
        Task(priority: .utility) { @MainActor [weak self] in
            await self?.channelSyncController.refreshPrivateChannelRouteState()
        }
    }

    func resyncWatchReceiverProvisioning() async throws {
        await refreshWatchCompanionAvailability()
        guard isWatchCompanionAvailable else {
            throw AppError.typedLocal(
                code: "watch_companion_not_available",
                category: .validation,
                message: localizationManager.localized("watch_companion_not_available"),
                detail: "watch companion unavailable when resyncing receiver provisioning"
            )
        }
        _ = try await watchSyncController.requestWatchModeChangeApplied(.standalone)
        requestWatchStandaloneProvisioningSync(immediate: true)
    }

    func handleWatchSessionStateDidChange() async {
        await watchSyncController.handleWatchSessionStateDidChange()
    }

    func refreshWatchCompanionAvailability() async {
        await watchSyncController.refreshWatchCompanionAvailability()
    }

    private func resetWatchConnectivityStateForMigration() async {
        await watchSyncController.resetWatchConnectivityStateForMigration()
    }

    func handleWatchLatestManifestRequested() async {
        await watchSyncController.handleWatchLatestManifestRequested()
    }

    func handleWatchStandaloneProvisioningAck(_ ack: WatchStandaloneProvisioningAck) async {
        await watchSyncController.handleWatchStandaloneProvisioningAck(ack)
    }

    func handleWatchMirrorSnapshotAck(_ ack: WatchMirrorSnapshotAck) async {
        await watchSyncController.handleWatchMirrorSnapshotAck(ack)
    }

    func handleWatchEffectiveModeStatus(_ status: WatchEffectiveModeStatus) async {
        await watchSyncController.handleWatchEffectiveModeStatus(status)
    }

    func handleWatchStandaloneReadinessStatus(_ status: WatchStandaloneReadinessStatus) async {
        await watchSyncController.handleWatchStandaloneReadinessStatus(status)
    }

    func handleWatchMirrorSnapshotNack(_ nack: WatchMirrorSnapshotNack) async {
        await watchSyncController.handleWatchMirrorSnapshotNack(nack)
    }

    func handleWatchStandaloneProvisioningNack(_ nack: WatchStandaloneProvisioningNack) async {
        await watchSyncController.handleWatchStandaloneProvisioningNack(nack)
    }

    func applyWatchMirrorActionBatch(_ batch: WatchMirrorActionBatch) async {
        await watchSyncController.applyWatchMirrorActionBatch(batch)
    }

    private func requestWatchMirrorSnapshotSync(immediate: Bool = false) {
        watchSyncController.requestWatchMirrorSnapshotSync(immediate: immediate)
    }

    private func requestWatchStandaloneProvisioningSync(immediate: Bool) {
        watchSyncController.requestWatchStandaloneProvisioningSync(immediate: immediate)
    }

    private func requestNetworkPermissionOnLaunch() {
        let config = serverConfig
        let baseURL = config?.baseURL ?? AppConstants.defaultServerURL
        let token = config?.token ?? AppConstants.defaultGatewayToken
        networkPermissionChecker.requestAccessIfNeeded(baseURL: baseURL, token: token) {
            Task { @MainActor in
                let message = LocalizationManager.shared.localized("network_permission_denied_cannot_subscribe")
                AppEnvironment.shared.recordAutomationRuntimeMessage(
                    message,
                    source: "network.permission",
                    category: "permission",
                    code: "E_NETWORK_PERMISSION_DENIED"
                )
                AppEnvironment.shared.showToast(message: message, style: .error, duration: 2.5)
            }
        }
    }

    private func preparePushInfrastructure() async {
        await pushRegistrationService.refreshAuthorizationStatus()

        if pushRegistrationService.authorizationState == .notDetermined {
            do {
                try await pushRegistrationService.requestAuthorization()
            } catch {
                recordAutomationRuntimeError(error, source: "push.authorization.request", category: "permission")
                showToast(message: localizationManager.localized(
                    "request_for_notification_permission_failed_placeholder",
                    userFacingErrorMessage(error),
                ))
                return
            }
        }

        await refreshPushAuthorization(
            requestAuthorization: false,
            presentDeniedPrompt: true
        )
        await prepareAutomationPushStateIfNeeded()
    }

    private func prepareAutomationPushStateIfNeeded() async {
        guard let token = PushGoAutomationContext.providerToken?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty
        else { return }
        let platform = platformIdentifier()
        await dataStore.saveCachedPushToken(token, for: platform)
        guard let config = serverConfig else { return }
        await syncProviderPullRoute(config: config, providerToken: token)
        await syncWidgetPushRegistration()
    }

    private func platformIdentifier() -> String {
        "ios"
    }

    func updateScenePhase(_ phase: ScenePhase, sceneID: UUID) {
        let previousPhase = aggregateScenePhase
        scenePhases[sceneID] = phase
        let currentPhase = aggregateScenePhase
        guard previousPhase != currentPhase else { return }
        applyAggregateScenePhase(currentPhase)
    }

    func removeScenePhase(sceneID: UUID) {
        let previousPhase = aggregateScenePhase
        scenePhases.removeValue(forKey: sceneID)
        let currentPhase = aggregateScenePhase
        guard previousPhase != currentPhase else { return }
        applyAggregateScenePhase(currentPhase)
    }

    private var aggregateScenePhase: ScenePhase {
        if scenePhases.values.contains(.active) { return .active }
        if scenePhases.values.contains(.inactive) { return .inactive }
        return .background
    }

    private func applyAggregateScenePhase(_ phase: ScenePhase) {
        switch phase {
        case .active:
            Task { await pendingLocalDeletionController.sceneBecameActive() }
            navigationState.setSceneActive(true)
            clearDeliveredSystemNotifications()
            syncBadgeWithUnreadCount()
            Task { @MainActor in
                _ = await mergeNotificationIngressInbox(
                    reason: "ios_scene_active",
                    allowFallbackPull: true
                )
                scheduleMessageListRefresh()
                await refreshChannelSubscriptions()
                await syncWidgetPushRegistration()
            }
            Task(priority: .utility) {
                await dataStore.ensureSystemSearchIndexHealthy()
            }
        case .background:
            navigationState.setSceneActive(false)
            PushGoAppDelegate.scheduleIngressBackgroundRefresh(source: "scene_background")
            beginPendingDeletionBackgroundDrain()
            Task {
                await dataStore.flushWrites()
            }
            Task { @MainActor in
                await channelSyncController.refreshPrivateChannelRouteState()
            }
        case .inactive:
            navigationState.setSceneActive(false)
        @unknown default:
            navigationState.setSceneActive(false)
        }
    }

    private func beginPendingDeletionBackgroundDrain() {
        guard pendingDeletionBackgroundTask == nil else { return }
        let drainID = UUID()
        pendingDeletionBackgroundDrainID = drainID
        pendingDeletionBackgroundTaskID = UIApplication.shared.beginBackgroundTask(
            withName: "pending-local-deletion"
        ) { [weak self] in
            Task { @MainActor in
                self?.endPendingDeletionBackgroundDrain(id: drainID, cancel: true)
            }
        }
        pendingDeletionBackgroundTask = Task { [weak self] in
            guard let self else { return }
            await self.pendingLocalDeletionController.commitAllForBackground()
            self.endPendingDeletionBackgroundDrain(id: drainID, cancel: false)
        }
    }

    private func endPendingDeletionBackgroundDrain(id: UUID, cancel: Bool) {
        guard pendingDeletionBackgroundDrainID == id else { return }
        if cancel {
            pendingDeletionBackgroundTask?.cancel()
            pendingLocalDeletionController.cancelExecution()
        }
        pendingDeletionBackgroundTask = nil
        pendingDeletionBackgroundDrainID = nil
        guard pendingDeletionBackgroundTaskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(pendingDeletionBackgroundTaskID)
        pendingDeletionBackgroundTaskID = .invalid
    }

    func updateActiveTab(_ tab: MainTab) {
        navigationState.updateActiveTab(tab)
        clearDeliveredSystemNotifications()
    }

    func updateMessageListPosition(isAtTop: Bool) {
        navigationState.updateMessageListPosition(isAtTop: isAtTop)
        clearDeliveredSystemNotifications()
    }

    func updateEventListPosition(isAtTop: Bool) {
        navigationState.updateEventListPosition(isAtTop: isAtTop)
        clearDeliveredSystemNotifications()
    }

    func updateThingListPosition(isAtTop: Bool) {
        navigationState.updateThingListPosition(isAtTop: isAtTop)
        clearDeliveredSystemNotifications()
    }

    func shouldPresentForegroundNotification(payload: [AnyHashable: Any]? = nil) -> Bool {
        guard let payload else {
            return true
        }
        guard !navigationState.shouldSuppressForegroundNotifications(for: payload) else {
            return false
        }
        return NotificationHandling.shouldPresentUserAlert(from: payload)
    }

    private func syncProviderPullRoute(config: ServerConfig, providerToken: String) async {
        await providerRouteController.syncProviderPullRoute(config: config, providerToken: providerToken)
    }

    private func syncWidgetPushRegistration() async {
        await PushGoWidgetPushRegistrationService.syncPendingRegistration(
            deviceKey: await providerRouteController.cachedProviderPullDeviceKey(),
            platform: platformIdentifier()
        )
    }

    private func persistPushTokenAndRotateRoute(config: ServerConfig, token: String) async {
        await providerRouteController.persistPushTokenAndRotateRoute(config: config, token: token)
    }

    private func ensureProviderRoute(config: ServerConfig, providerToken: String) async throws -> String {
        try await providerRouteController.ensureProviderRoute(config: config, providerToken: providerToken)
    }

    private func handleNotificationIngressChanged(reason: String) async {
        await notificationIngressController.handleNotificationIngressChanged(reason: reason)
    }

    func drainProviderDeliveryAckFailures(source: String) async {
        _ = await notificationIngressController.drainProviderDeliveryAckFailures(source: source)
    }

    func drainProviderDeliveryAckFailuresOutcome(
        source: String
    ) async -> IngressBackgroundRefreshRunner.StageOutcome {
        await notificationIngressController.drainProviderDeliveryAckFailures(source: source)
    }

    @discardableResult
    func mergeNotificationIngressInbox(
        reason: String,
        allowFallbackPull: Bool,
        limit: Int = 256
    ) async -> Int {
#if DEBUG
        if ingressPerformanceMeasurement?.mode == .baseline
            || ingressPerformanceMeasurement?.mode == .seed
            || ingressPerformanceMeasurement?.mode == .cleanup
        {
            return 0
        }
#endif
        return await notificationIngressController.mergeNotificationIngressInbox(
            reason: reason,
            allowFallbackPull: allowFallbackPull,
            limit: limit
        )
    }

    func mergeNotificationIngressInboxOutcome(
        reason: String,
        allowFallbackPull: Bool,
        limit: Int = 256
    ) async -> NotificationIngressController.MergeOutcome {
#if DEBUG
        if ingressPerformanceMeasurement?.mode == .baseline
            || ingressPerformanceMeasurement?.mode == .seed
            || ingressPerformanceMeasurement?.mode == .cleanup
        {
            return NotificationIngressController.MergeOutcome(
                appliedCount: 0,
                stageOutcome: .succeeded
            )
        }
#endif
        return await notificationIngressController.mergeNotificationIngressInboxOutcome(
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
        await notificationIngressController.syncProviderIngress(
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
        await notificationIngressController.syncProviderIngressOutcome(
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
        await notificationIngressController.finalizePulledProviderIngress(
            deliveryId: deliveryId,
            context: context,
            outcome: outcome,
            source: source
        )
    }

    func persistPulledProviderIngress(
        payload: [AnyHashable: Any],
        deliveryId: String,
        context: ProviderPullContext,
        source: String
    ) async -> NotificationPersistenceOutcome {
        await notificationIngressController.persistPulledProviderIngress(
            payload: payload,
            deliveryId: deliveryId,
            context: context,
            source: source
        )
    }

    @discardableResult
    func purgePendingUnresolvedWakeupEntries(limit: Int = 256) async -> Int {
        await notificationIngressController.purgePendingUnresolvedWakeupEntries(limit: limit)
    }

    func beginProviderIngressBootstrapRecovery() {
        providerIngressBootstrapRecoveryInFlight = true
    }

    func finishProviderIngressBootstrapRecovery() {
        providerIngressBootstrapRecoveryInFlight = false
    }

    var shouldDeferStartupWakeupPulls: Bool {
        providerIngressBootstrapRecoveryInFlight
    }

    @discardableResult
    func persistRemotePayloadIfNeeded(
        _ payload: [AnyHashable: Any],
        requestIdentifier: String? = nil
    ) async -> NotificationPersistenceOutcome {
        await notificationIngressController.persistRemotePayloadIfNeeded(
            payload,
            requestIdentifier: requestIdentifier
        )
    }

    func ackDirectProviderIngressIfNeeded(
        payload: [AnyHashable: Any],
        outcome: NotificationPersistenceOutcome,
        source: String
    ) async {
        await notificationIngressController.ackDirectProviderIngressIfNeeded(
            payload: payload,
            outcome: outcome,
            source: source
        )
    }

    func updateLaunchAtLogin(isEnabled: Bool) {
        Task { @MainActor in
            await dataStore.saveLaunchAtLoginPreference(isEnabled)
        }
    }

    @discardableResult
    func persistNotificationIfNeeded(_ notification: UNNotification) async -> NotificationPersistenceOutcome {
        await notificationIngressController.persistNotificationIfNeeded(notification)
    }

    func handleNotificationOpen(notificationRequestId: String) async {
        await notificationOpenController.handleNotificationOpen(notificationRequestId: notificationRequestId)
    }

    func handleNotificationOpen(messageId: String) async {
        await notificationOpenController.handleNotificationOpen(messageId: messageId)
    }

    func handleNotificationOpen(entityType: String, entityId: String) async {
        await notificationOpenController.handleNotificationOpen(entityType: entityType, entityId: entityId)
    }

    func openSystemTarget(_ target: PushGoSystemOpenTarget) async {
        await notificationOpenController.openSystemTarget(target)
    }

    func openDeepLink(_ url: URL) async {
        guard let target = PushGoDeepLink.parse(url) else { return }
        await openSystemTarget(target)
    }

    func handleNotificationOpenFromCopy(notificationRequestId: String) async {
        await handleNotificationOpen(notificationRequestId: notificationRequestId)
    }

    private func clearDeliveredSystemNotifications() {
    }

    private func postGatewayPayload(
        _ payload: [String: Any],
        endpointPath: String,
        config: ServerConfig
    ) async throws {
        guard JSONSerialization.isValidJSONObject(payload) else {
            throw AppError.invalidURL
        }
#if DEBUG
        if try await persistQualityEventCloseRoundTripIfNeeded(
            payload: payload,
            endpointPath: endpointPath
        ) {
            return
        }
#endif
        guard var components = URLComponents(url: config.baseURL, resolvingAgainstBaseURL: false) else {
            throw AppError.invalidURL
        }
        var path = components.path
        if path.hasSuffix("/") {
            path.removeLast()
        }
        components.path = path + endpointPath
        guard let url = components.url else {
            throw AppError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = AppConstants.deviceRegistrationTimeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        ChannelSubscriptionService.applyGatewayHeaders(&request, token: config.token)
        request.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [])

        let (data, response) = try await URLSession.shared.data(for: request)
        _ = try ChannelSubscriptionService.decodeGatewayResponse(
            ChannelSubscriptionService.EmptyPayload.self,
            data: data,
            response: response
        )
    }

#if DEBUG
    /// Replaces only the external Gateway round trip for an explicitly typed quality
    /// session. The simulated delivery still enters through the production notification
    /// parser, canonical event projection, and App-owned store.
    private func persistQualityEventCloseRoundTripIfNeeded(
        payload: [String: Any],
        endpointPath: String
    ) async throws -> Bool {
        let scenario = PushGoAutomationContext.qualitySession?.eventCloseScenario ?? .none
        guard let delivery = PushGoQualityEventCloseDelivery.make(
            boundaryPayload: payload,
            endpointPath: endpointPath,
            scenario: scenario
        )
        else {
            return false
        }

        if scenario == .failOnceThenAcceptedAndDelivered {
            guard !isQualityEventCloseRoundTripInFlight else {
                throw AppError.typedLocal(
                    code: "quality_event_close_duplicate_in_flight",
                    category: .local,
                    message: localizationManager.localized("operation_failed"),
                    detail: "a second event close crossed the boundary while the first was in flight"
                )
            }
            isQualityEventCloseRoundTripInFlight = true
            defer { isQualityEventCloseRoundTripInFlight = false }
            qualityEventCloseAttemptCount += 1
            try await Task.sleep(for: .milliseconds(2_500))
            if qualityEventCloseAttemptCount == 1 {
                throw AppError.typedLocal(
                    code: "quality_event_close_rejected_once",
                    category: .local,
                    message: localizationManager.localized("operation_failed"),
                    detail: "quality event close rejected once before retry"
                )
            }
        }

        let outcome = await persistRemotePayloadIfNeeded(
            delivery.payload,
            requestIdentifier: delivery.requestIdentifier
        )
        switch outcome {
        case .persistedMain, .duplicate:
            return true
        case .persistedPending, .rejected, .failed:
            throw AppError.typedLocal(
                code: "quality_event_close_delivery_failed",
                category: .local,
                message: localizationManager.localized("operation_failed"),
                detail: "quality event close response did not reach the canonical store"
            )
        }
    }
#endif

    private func escapedGatewayPathComponent(_ raw: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/")
        return raw.addingPercentEncoding(withAllowedCharacters: allowed) ?? raw
    }

}

private final class NetworkPermissionChecker {
    private let queue = DispatchQueue(label: "io.ethan.pushgo.network-permission")
    private var monitor: NWPathMonitor?

    func requestAccessIfNeeded(baseURL: URL?, token: String?, onDenied: @escaping @Sendable () -> Void) {
        monitor?.cancel()

        let monitor = NWPathMonitor()
        self.monitor = monitor
        monitor.pathUpdateHandler = { path in
            defer { monitor.cancel() }

            guard path.status == .unsatisfied else { return }

            switch path.unsatisfiedReason {
            case .wifiDenied, .cellularDenied, .localNetworkDenied:
                Task { @MainActor in
                    onDenied()
                }
            default:
                break
            }
        }
        monitor.start(queue: queue)

        guard let url = baseURL else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 3
        request.cachePolicy = .reloadIgnoringLocalCacheData
        ChannelSubscriptionService.applyGatewayHeaders(&request, token: token)
        URLSession.shared.dataTask(with: request).resume()
    }
}
