import Foundation
import Observation
import SwiftUI
import UserNotifications
import WatchKit

@MainActor
@Observable
final class AppEnvironment {
    @MainActor
    static let shared = AppEnvironment()

    let dataStore: LocalDataStore
    let pushRegistrationService: PushRegistrationService
    let localizationManager: LocalizationManager
    @ObservationIgnored private var messageSyncObserver: DarwinNotificationObserver?
    @ObservationIgnored private var pendingMessageListRefreshTask: Task<Void, Never>?

    private var toastDismissTask: Task<Void, Never>?
    @ObservationIgnored private let messageListRefreshDelay: TimeInterval = 0.35
    @ObservationIgnored private var pendingMessageListRefresh = false
    @ObservationIgnored private var isMainWindowVisible = true
    @ObservationIgnored private var lastWakeupRouteSyncAt = Date.distantPast
    @ObservationIgnored private var lastWakeupDeviceRegisterAt = Date.distantPast
    @ObservationIgnored private var standaloneRuntimeReconcileTask: Task<Void, Never>?
    @ObservationIgnored private var standaloneRuntimeReconcilePending = false
    @ObservationIgnored private var standaloneRuntimeReconcileNeedsDeniedPrompt = false
    @ObservationIgnored private var standaloneReadinessFailureReason: String?
    @ObservationIgnored private let privateWakeupRouteSyncInterval: TimeInterval = 25
    @ObservationIgnored private let privateWakeupDeviceRegisterInterval: TimeInterval = 45

    private(set) var serverConfig: ServerConfig?
    private(set) var totalMessageCount: Int = 0
    private(set) var unreadMessageCount: Int = 0
    private(set) var messageStoreRevision: UUID = UUID()
    private(set) var toastMessage: ToastMessage?
    private(set) var shouldPresentNotificationPermissionAlert: Bool = false
    var pendingMessageToOpen: String?
    var pendingEventToOpen: String?
    var pendingThingToOpen: String?
    private(set) var activeMainTab: MainTab = .messages
    private(set) var isMessageListAtTop: Bool = true
    private(set) var watchMode: WatchMode = .mirror
    private(set) var standaloneReady = false
    @ObservationIgnored private var watchSyncGenerations: WatchSyncGenerationState = .zero
    private(set) var channelSubscriptions: [ChannelSubscription] = []
    private var isSceneActive = false

    private let channelSubscriptionService = ChannelSubscriptionService()

    private init(
        dataStore: LocalDataStore = LocalDataStore(),
        pushRegistrationService: PushRegistrationService? = nil,
        localizationManager: LocalizationManager? = nil,
    ) {
        self.dataStore = dataStore
        self.pushRegistrationService = pushRegistrationService ?? PushRegistrationService.shared
        self.localizationManager = localizationManager ?? LocalizationManager.shared
        messageSyncObserver = DarwinNotificationObserver(name: AppConstants.messageSyncNotificationName) { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                await self.refreshWatchLightCountsAndNotify()
            }
        }
        registerDefaultNotificationCategories()
    }

    func bootstrap() async {
        WatchSessionBridge.shared.activateIfNeeded()
        await loadPersistedState()
        publishCurrentEffectiveModeStatus(noop: false)
        let store = dataStore
        Task(priority: .utility) {
            await store.warmCachesIfNeeded()
        }
        if isStandaloneMode {
            requestStandaloneRuntimeReconcile(reason: "bootstrap", presentDeniedPrompt: true)
            Task(priority: .utility) { @MainActor [weak self] in
                await self?.maintainDeviceKeyOnLaunch()
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
        let category = UNNotificationCategory(
            identifier: AppConstants.notificationDefaultCategoryIdentifier,
            actions: [],
            intentIdentifiers: [],
            options: []
        )
        let entityReminderCategory = UNNotificationCategory(
            identifier: AppConstants.notificationEntityReminderCategoryIdentifier,
            actions: [],
            intentIdentifiers: [],
            options: []
        )
        UNUserNotificationCenter.current().setNotificationCategories([category, entityReminderCategory])
    }

    func updateServerConfig(_ config: ServerConfig?) async throws {
        let previousConfig = serverConfig
        let previousDeviceKey = await dataStore.cachedProviderDeviceKey(
            for: platformIdentifier(),
            channelType: "apns"
        )?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = config?.normalized()
        try await dataStore.saveWatchProvisioningServerConfig(normalized)
        serverConfig = normalized
        await refreshChannelSubscriptions()
        scheduleLegacyGatewayDeviceCleanup(
            previousConfig: previousConfig,
            previousDeviceKey: previousDeviceKey,
            nextConfig: normalized
        )
        if isStandaloneMode {
            requestStandaloneRuntimeReconcile(reason: "update_server_config")
        }
    }

    func refreshWatchLightCountsAndNotify() async {
        await refreshMessageCountsAndNotify()
    }

    func refreshMessageCountsAndNotify() async {
        do {
            let messages = try await dataStore.loadWatchLightMessages()
            totalMessageCount = messages.count
            unreadMessageCount = messages.filter { !$0.isRead }.count
            BadgeManager.syncAppBadge(unreadCount: unreadMessageCount)
            clearDeliveredSystemNotifications()
            scheduleMessageListRefresh()
        } catch {
            totalMessageCount = 0
            unreadMessageCount = 0
            BadgeManager.syncAppBadge(unreadCount: 0)
            scheduleMessageListRefresh()
        }
    }

    func refreshChannelSubscriptions() async {
        do {
            let all = try await dataStore.loadChannelSubscriptions(includeDeleted: false)
            await MainActor.run {
                channelSubscriptions = all
            }
        } catch {
            await MainActor.run {
                channelSubscriptions = []
            }
        }
    }

    func showToast(message: String, style: ToastMessage.Style = .error, duration: TimeInterval = 3) {
        toastDismissTask?.cancel()
        let toast = ToastMessage(text: message, style: style)
        toastMessage = toast
        announceAccessibility(message)
        toastDismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            await MainActor.run {
                self?.dismissToast(id: toast.id)
            }
        }
    }

    private func recordAutomationRuntimeError(
        _ error: Error,
        source: String,
        category: String = "runtime"
    ) {
        #if DEBUG
        let message: String
        let code: String?
        if let appError = error as? AppError {
            message = appError.errorDescription ?? String(describing: appError)
            code = appError.code
        } else {
            message = error.localizedDescription
            code = nil
        }
        PushGoWatchAutomationRuntime.shared.recordRuntimeError(
            source: source,
            category: category,
            code: code,
            message: message
        )
        #endif
    }

    private func recordAutomationRuntimeMessage(
        _ message: String,
        source: String,
        category: String = "runtime",
        code: String? = nil
    ) {
        #if DEBUG
        PushGoWatchAutomationRuntime.shared.recordRuntimeError(
            source: source,
            category: category,
            code: code,
            message: message
        )
        #endif
    }

    func dismissToast(id: UUID) {
        if toastMessage?.id == id {
            toastDismissTask?.cancel()
            toastDismissTask = nil
            toastMessage = nil
        }
    }

    func dismissNotificationPermissionAlert() {
        shouldPresentNotificationPermissionAlert = false
    }

    func openSystemNotificationSettings() {
        guard !PushGoAutomationContext.blocksCrossAppDataAccess else { return }
        guard let url = URL(string: "app-settings:") else { return }
        WKExtension.shared().openSystemURL(url)
    }

    private func presentNotificationPermissionAlertIfNeeded() {
        guard !PushGoAutomationContext.isActive else { return }
        shouldPresentNotificationPermissionAlert = true
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
        _ = message
    }



    func updateNotificationMaterial(_ material: ServerConfig.NotificationKeyMaterial) async {
        let persistedConfig = try? await dataStore.loadWatchProvisioningServerConfig()?.normalized()
        var config = persistedConfig ?? serverConfig ?? (Self.makeDefaultServerConfig() ?? ServerConfig(
            id: UUID(),
            name: "Local Device",
            baseURL: AppConstants.defaultServerURL!,
            token: nil,
            notificationKeyMaterial: nil,
            updatedAt: Date(),
        ))
        config.notificationKeyMaterial = material
        config.updatedAt = Date()
        do {
            try await updateServerConfig(config)
        } catch {
            showToast(message: localizationManager.localized(
                "failed_to_save_server_configuration_placeholder",
                error.localizedDescription,
            ))
        }
    }

    func applyWatchSyncManifestFromPhone(_ manifest: WatchSyncManifest) async {
        guard manifest.schemaVersion == WatchConnectivitySchema.currentVersion else { return }
        let context = WatchControlContext(
            mode: manifest.mode,
            controlGeneration: manifest.controlGeneration,
            mirrorSnapshotGeneration: manifest.mirrorPackage?.generation ?? watchSyncGenerations.mirrorSnapshotGeneration,
            standaloneProvisioningGeneration: manifest.standalonePackage?.generation ?? watchSyncGenerations.standaloneProvisioningGeneration,
            pendingMirrorActionAckGeneration: watchSyncGenerations.mirrorActionAckGeneration
        )
        await applyWatchControlContextFromPhone(context)
    }

    func applyWatchControlContextFromPhone(_ context: WatchControlContext) async {
        guard context.controlGeneration > watchSyncGenerations.controlGeneration else { return }
        let previousMode = watchMode
        if previousMode == context.mode {
            watchSyncGenerations.controlGeneration = context.controlGeneration
            await dataStore.saveWatchSyncGenerationState(watchSyncGenerations)
            publishCurrentEffectiveModeStatus(
                sourceControlGeneration: context.controlGeneration,
                noop: true
            )
            return
        }
        watchMode = context.mode
        watchSyncGenerations.controlGeneration = context.controlGeneration
        await dataStore.saveWatchMode(context.mode)
        await dataStore.saveWatchSyncGenerationState(watchSyncGenerations)
        await handleWatchModeTransition(from: previousMode, to: context.mode)
        publishCurrentEffectiveModeStatus(
            sourceControlGeneration: context.controlGeneration,
            noop: false
        )
    }

    func applyMirrorSnapshotFromPhone(_ snapshot: WatchMirrorSnapshot) async {
        guard watchMode == .mirror, snapshot.mode == .mirror else { return }
        guard snapshot.generation > watchSyncGenerations.mirrorSnapshotGeneration else { return }
        do {
            try await dataStore.mergeWatchMirrorSnapshot(snapshot)
            let pendingActions = try await dataStore.loadWatchMirrorActions()
            for action in pendingActions {
                switch action.kind {
                case .read:
                    _ = try await dataStore.markWatchLightMessageRead(messageId: action.messageId)
                case .delete:
                    try await dataStore.deleteWatchLightMessage(messageId: action.messageId)
                }
            }
            watchSyncGenerations.mirrorSnapshotGeneration = snapshot.generation
            await dataStore.saveWatchSyncGenerationState(watchSyncGenerations)
            await refreshWatchLightCountsAndNotify()
            publishMirrorSnapshotAck(
                generation: snapshot.generation,
                contentDigest: snapshot.contentDigest
            )
        } catch {
            recordAutomationRuntimeError(error, source: "watch.apply_mirror_snapshot")
            sendMirrorSnapshotNack(
                generation: snapshot.generation,
                contentDigest: snapshot.contentDigest,
                failedStage: "merge_watch_mirror_snapshot",
                errorDescription: error.localizedDescription
            )
            WatchSessionBridge.shared.requestLatestManifestIfReachable()
        }
    }

    func applyStandaloneProvisioningFromPhone(_ snapshot: WatchStandaloneProvisioningSnapshot) async {
        guard watchMode == .standalone, snapshot.mode == .standalone else { return }
        let currentProvisioning = await dataStore.loadWatchProvisioningState()
        guard snapshot.generation > (currentProvisioning?.generation ?? 0) else { return }
        var failedStage = "compare_digest"
        do {
            if currentProvisioning?.contentDigest == snapshot.contentDigest {
                failedStage = "save_provisioning_state"
                await dataStore.saveWatchProvisioningState(
                    WatchProvisioningState(
                        schemaVersion: WatchConnectivitySchema.currentVersion,
                        generation: snapshot.generation,
                        contentDigest: snapshot.contentDigest,
                        appliedAt: Date(),
                        modeAtApply: .standalone,
                        sourceControlGeneration: watchSyncGenerations.controlGeneration
                    )
                )
                watchSyncGenerations.standaloneProvisioningGeneration = snapshot.generation
                await dataStore.saveWatchSyncGenerationState(watchSyncGenerations)
                serverConfig = try await dataStore.loadWatchProvisioningServerConfig()?.normalized()
                await refreshChannelSubscriptions()
                updateStandaloneReadiness(false, failureReason: nil)
                publishStandaloneProvisioningAck(
                    generation: snapshot.generation,
                    contentDigest: snapshot.contentDigest
                )
                requestStandaloneRuntimeReconcile(reason: "apply_standalone_provisioning_digest_match")
                return
            }

            failedStage = "commit_provisioning"
            let appliedState = try await dataStore.applyWatchStandaloneProvisioning(
                snapshot,
                sourceControlGeneration: watchSyncGenerations.controlGeneration
            )
            serverConfig = try await dataStore.loadWatchProvisioningServerConfig()?.normalized()
            await refreshChannelSubscriptions()
            watchSyncGenerations.standaloneProvisioningGeneration = snapshot.generation
            await dataStore.saveWatchSyncGenerationState(watchSyncGenerations)
            updateStandaloneReadiness(false, failureReason: nil)
            publishStandaloneProvisioningAck(
                generation: snapshot.generation,
                contentDigest: appliedState.contentDigest
            )
            requestStandaloneRuntimeReconcile(reason: "apply_standalone_provisioning")
        } catch {
            recordAutomationRuntimeError(error, source: "watch.apply_standalone_provisioning")
            sendStandaloneProvisioningNack(
                generation: snapshot.generation,
                contentDigest: snapshot.contentDigest,
                failedStage: failedStage,
                errorDescription: error.localizedDescription
            )
        }
    }

    func applyWatchMirrorActionAckFromPhone(_ ack: WatchMirrorActionAck) async {
        do {
            if !ack.ackedActionIds.isEmpty {
                try await dataStore.deleteWatchMirrorActions(actionIds: ack.ackedActionIds)
            }
            watchSyncGenerations.mirrorActionAckGeneration = max(
                watchSyncGenerations.mirrorActionAckGeneration,
                ack.ackGeneration
            )
            await dataStore.saveWatchSyncGenerationState(watchSyncGenerations)
        } catch {
            recordAutomationRuntimeError(error, source: "watch.apply_mirror_action_ack")
        }
    }

    func enqueueMirrorMessageAction(kind: WatchMirrorActionKind, messageId: String) async throws {
        let action = WatchMirrorAction(
            actionId: UUID().uuidString,
            kind: kind,
            messageId: messageId,
            issuedAt: Date()
        )
        try await dataStore.enqueueWatchMirrorAction(action)
        switch kind {
        case .read:
            _ = try await dataStore.markWatchLightMessageRead(messageId: messageId)
        case .delete:
            try await dataStore.deleteWatchLightMessage(messageId: messageId)
        }
        await refreshWatchLightCountsAndNotify()
        await sendPendingMirrorActionsIfNeeded()
    }

    func handleWatchSessionReachabilityChanged() async {
        publishCurrentEffectiveModeStatus(noop: false)
        if watchMode == .mirror {
            await sendPendingMirrorActionsIfNeeded()
        } else {
            requestStandaloneRuntimeReconcile(reason: "watch_session_reachability")
        }
    }

    private func sendPendingMirrorActionsIfNeeded() async {
        guard watchMode == .mirror else { return }
        let pending = (try? await dataStore.loadWatchMirrorActions()) ?? []
        guard !pending.isEmpty else { return }
        // Always send full pending action backlog so latest-only applicationContext remains lossless.
        WatchSessionBridge.shared.sendMirrorActionBatch(
            WatchMirrorActionBatch(
                batchId: UUID().uuidString,
                mode: .mirror,
                actions: pending
            )
        )
    }

    private func handleWatchModeTransition(from previousMode: WatchMode, to nextMode: WatchMode) async {
        guard previousMode != nextMode else { return }
        await refreshChannelSubscriptions()
        if previousMode == .standalone {
            await deactivateStandaloneRuntime(reason: "watch_mode_transition")
        }
        if nextMode == .standalone {
            lastWakeupRouteSyncAt = .distantPast
            lastWakeupDeviceRegisterAt = .distantPast
            updateStandaloneReadiness(false, failureReason: nil, publish: false)
            requestStandaloneRuntimeReconcile(
                reason: "watch_mode_transition",
                presentDeniedPrompt: true
            )
        } else {
            updateStandaloneReadiness(false, failureReason: nil, publish: false)
            await sendPendingMirrorActionsIfNeeded()
        }
    }

    private func deactivateStandaloneRuntime(reason: String) async {
        cancelStandaloneRuntimeReconcile()
        updateStandaloneReadiness(false, failureReason: nil, publish: false)
        await tearDownStandaloneInfrastructure()
        lastWakeupRouteSyncAt = .distantPast
        lastWakeupDeviceRegisterAt = .distantPast
        recordAutomationRuntimeMessage(
            "deactivated standalone runtime",
            source: "watch.\(reason)"
        )
    }

    private func tearDownStandaloneInfrastructure() async {
        guard let runtime = await loadPersistedProvisioningRuntimeState() else { return }
        let config = runtime.config
        let platform = platformIdentifier()
        guard let deviceKey = await dataStore.cachedProviderDeviceKey(
            for: platform,
            channelType: "private"
        )?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !deviceKey.isEmpty
        else {
            return
        }
        do {
            _ = try await channelSubscriptionService.sync(
                baseURL: config.baseURL,
                token: config.token,
                deviceKey: deviceKey,
                channels: []
            )
        } catch {
            recordAutomationRuntimeError(error, source: "watch.teardown_subscription_sync")
        }
        do {
            try await channelSubscriptionService.deleteDeviceChannel(
                baseURL: config.baseURL,
                token: config.token,
                deviceKey: deviceKey,
                channelType: "apns"
            )
        } catch {
            recordAutomationRuntimeError(error, source: "watch.teardown_provider_route")
        }
    }

    private func resolveGateway(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return trimmed
        }
        return serverConfig?.gatewayKey ?? ""
    }

    private func loadPersistedProvisioningRuntimeState() async -> (
        config: ServerConfig,
        channels: [(channelId: String, password: String)]
    )? {
        guard let config = await loadPersistedStandaloneServerConfig() else {
            return nil
        }
        let channels = (try? await dataStore.activeChannelCredentials(gateway: config.gatewayKey)) ?? []
        return (config, channels)
    }

    private func loadPersistedStandaloneServerConfig() async -> ServerConfig? {
        (try? await dataStore.loadWatchProvisioningServerConfig()?.normalized())
    }

    private func loadPersistedStandaloneRuntimeState() async -> (
        config: ServerConfig,
        channels: [(channelId: String, password: String)]
    )? {
        guard isStandaloneMode else { return nil }
        return await loadPersistedProvisioningRuntimeState()
    }

    private func currentStandaloneProvisioningChannels() async -> [WatchStandaloneChannelCredential] {
        let activeSubscriptions = (try? await dataStore.loadChannelSubscriptions(includeDeleted: false)) ?? []
        let fallbackGateway = (await loadPersistedStandaloneServerConfig())?.gatewayKey ?? serverConfig?.gatewayKey ?? ""
        let subscriptionsByGateway = Dictionary(
            grouping: activeSubscriptions,
            by: { subscription in
                let normalizedGateway = subscription.gateway.trimmingCharacters(in: .whitespacesAndNewlines)
                return normalizedGateway.isEmpty ? fallbackGateway : normalizedGateway
            }
        )
        var channels: [WatchStandaloneChannelCredential] = []
        for (gatewayKey, subscriptions) in subscriptionsByGateway {
            let normalizedGateway = resolveGateway(gatewayKey)
            guard !normalizedGateway.isEmpty else { continue }
            let displayNameByChannelId = Dictionary(
                uniqueKeysWithValues: subscriptions.map { ($0.channelId, $0.displayName) }
            )
            let updatedAtByChannelId = Dictionary(
                uniqueKeysWithValues: subscriptions.map { ($0.channelId, $0.updatedAt) }
            )
            let credentials = (try? await dataStore.activeChannelCredentials(gateway: normalizedGateway)) ?? []
            channels.append(
                contentsOf: credentials.compactMap { credential in
                    let trimmedChannelId = credential.channelId.trimmingCharacters(in: .whitespacesAndNewlines)
                    let trimmedPassword = credential.password.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmedChannelId.isEmpty, !trimmedPassword.isEmpty else { return nil }
                    return WatchStandaloneChannelCredential(
                        gateway: normalizedGateway,
                        channelId: trimmedChannelId,
                        displayName: displayNameByChannelId[trimmedChannelId] ?? trimmedChannelId,
                        password: trimmedPassword,
                        updatedAt: updatedAtByChannelId[trimmedChannelId] ?? Date.distantPast
                    )
                }
            )
        }
        return channels.sorted {
            if $0.gateway == $1.gateway {
                return $0.channelId < $1.channelId
            }
            return $0.gateway < $1.gateway
        }
    }

    private func publishStandaloneProvisioningAck(generation: Int64, contentDigest: String) {
        WatchSessionBridge.shared.publishStandaloneProvisioningAckManifest(
            WatchStandaloneProvisioningAck(
                generation: generation,
                contentDigest: contentDigest,
                appliedAt: Date()
            ),
            mode: watchMode,
            controlGeneration: watchSyncGenerations.controlGeneration
        )
    }

    private func publishCurrentEffectiveModeStatus(
        sourceControlGeneration: Int64? = nil,
        noop: Bool
    ) {
        let resolvedGeneration = sourceControlGeneration ?? watchSyncGenerations.controlGeneration
        let status = WatchEffectiveModeStatus(
            effectiveMode: watchMode,
            sourceControlGeneration: resolvedGeneration,
            appliedAt: Date(),
            noop: noop,
            status: .applied,
            failureReason: nil
        )
        let readinessStatus = currentStandaloneReadinessStatus(sourceControlGeneration: resolvedGeneration)
        WatchSessionBridge.shared.publishEffectiveModeStatusManifest(
            status,
            mode: watchMode,
            controlGeneration: watchSyncGenerations.controlGeneration,
            standaloneReadinessStatus: readinessStatus
        )
    }

    private func currentStandaloneReadinessStatus(
        sourceControlGeneration: Int64? = nil
    ) -> WatchStandaloneReadinessStatus {
        WatchStandaloneReadinessStatus(
            effectiveMode: watchMode,
            standaloneReady: watchMode == .standalone && standaloneReady,
            sourceControlGeneration: sourceControlGeneration ?? watchSyncGenerations.controlGeneration,
            provisioningGeneration: watchSyncGenerations.standaloneProvisioningGeneration,
            reportedAt: Date(),
            failureReason: standaloneReadinessFailureReason
        )
    }

    private func publishCurrentStandaloneReadinessStatus(
        sourceControlGeneration: Int64? = nil
    ) {
        let status = currentStandaloneReadinessStatus(sourceControlGeneration: sourceControlGeneration)
        WatchSessionBridge.shared.publishStandaloneReadinessStatusManifest(
            status,
            mode: watchMode,
            controlGeneration: watchSyncGenerations.controlGeneration
        )
    }

    private func updateStandaloneReadiness(
        _ nextReady: Bool,
        failureReason: String?,
        sourceControlGeneration: Int64? = nil,
        publish: Bool = true
    ) {
        let normalizedReason = failureReason?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedReason = (normalizedReason?.isEmpty == false) ? normalizedReason : nil
        let changed = standaloneReady != nextReady || standaloneReadinessFailureReason != resolvedReason
        standaloneReady = nextReady
        standaloneReadinessFailureReason = resolvedReason
        guard publish, changed || sourceControlGeneration != nil else { return }
        publishCurrentStandaloneReadinessStatus(sourceControlGeneration: sourceControlGeneration)
    }

    private func publishMirrorSnapshotAck(generation: Int64, contentDigest: String) {
        WatchSessionBridge.shared.publishMirrorSnapshotAckManifest(
            WatchMirrorSnapshotAck(
                generation: generation,
                contentDigest: contentDigest,
                appliedAt: Date()
            ),
            mode: watchMode,
            controlGeneration: watchSyncGenerations.controlGeneration
        )
    }

    private func sendMirrorSnapshotNack(
        generation: Int64,
        contentDigest: String,
        failedStage: String,
        errorDescription: String
    ) {
        WatchSessionBridge.shared.sendMirrorSnapshotNack(
            WatchMirrorSnapshotNack(
                generation: generation,
                contentDigest: contentDigest,
                failedStage: failedStage,
                errorDescription: errorDescription,
                reportedAt: Date()
            )
        )
    }

    private func sendStandaloneProvisioningNack(
        generation: Int64,
        contentDigest: String,
        failedStage: String,
        errorDescription: String
    ) {
        WatchSessionBridge.shared.sendStandaloneProvisioningNack(
            WatchStandaloneProvisioningNack(
                generation: generation,
                contentDigest: contentDigest,
                failedStage: failedStage,
                errorDescription: errorDescription,
                reportedAt: Date()
            )
        )
    }

    var currentNotificationMaterial: ServerConfig.NotificationKeyMaterial? {
        serverConfig?.notificationKeyMaterial
    }

    var isStandaloneMode: Bool {
        watchMode == .standalone
    }

    private func loadPersistedState() async {
        var bootstrapErrors: [String] = []
        standaloneReady = false
        standaloneReadinessFailureReason = nil
        let storeState = dataStore.storageState
        switch storeState.mode {
        case .unavailable:
            recordAutomationRuntimeMessage(
                storeState.reason ?? localizationManager.localized("local_store_unavailable"),
                source: "storage.bootstrap",
                category: "storage",
                code: "E_LOCAL_STORE_UNAVAILABLE"
            )
            bootstrapErrors.append(localizationManager.localized("local_store_unavailable"))
            if let reason = storeState.reason?.trimmingCharacters(in: .whitespacesAndNewlines),
               !reason.isEmpty
            {
                bootstrapErrors.append(reason)
                let lowered = reason.lowercased()
                if lowered.contains("database is locked")
                    || lowered.contains("database is busy")
                    || lowered.contains("sqlite_busy")
                    || lowered.contains("sqlite_locked")
                    || lowered.contains("lock contention")
                    || lowered.contains("locked")
                {
                    bootstrapErrors.append("检测到可能的数据库锁占用，请先彻底退出所有 PushGo 进程/扩展后重试。")
                }
            }
        case .persistent:
            break
        }
        watchMode = await dataStore.loadWatchMode()
        watchSyncGenerations = await dataStore.loadWatchSyncGenerationState()
        do {
            serverConfig = try await dataStore.loadWatchProvisioningServerConfig()?.normalized()
        } catch {
            serverConfig = nil
            recordAutomationRuntimeError(error, source: "storage.load_server_config", category: "storage")
            bootstrapErrors.append(localizationManager.localized("server_configuration_read_failed"))
        }
        if await WatchSessionBridge.shared.consumeForcedReconfigureFlag() {
            await resetWatchConnectivityStateForMigration(previousMode: watchMode)
        }

        do {
            let messages = try await dataStore.loadWatchLightMessages()
            totalMessageCount = messages.count
            unreadMessageCount = messages.filter { !$0.isRead }.count
            syncBadgeWithUnreadCount()
        } catch {
            totalMessageCount = 0
            unreadMessageCount = 0
            recordAutomationRuntimeError(error, source: "storage.watch_light_counts", category: "storage")
            bootstrapErrors.append(localizationManager.localized("failed_to_read_historical_messages"))
        }

        if !bootstrapErrors.isEmpty {
            let listFormatter = ListFormatter()
            listFormatter.locale = localizationManager.swiftUILocale
            let mergedReasons = listFormatter.string(from: bootstrapErrors) ?? bootstrapErrors.joined(separator: "、")
            showToast(message: localizationManager.localized("initialization_failed_placeholder", mergedReasons))
        }
        await refreshChannelSubscriptions()
        if isStandaloneMode {
            requestStandaloneRuntimeReconcile(reason: "load_persisted_state", presentDeniedPrompt: true)
        }
    }

    private func resetWatchConnectivityStateForMigration(previousMode: WatchMode) async {
        watchMode = .mirror
        standaloneReady = false
        standaloneReadinessFailureReason = nil
        watchSyncGenerations = .zero
        await dataStore.saveWatchMode(.mirror)
        await dataStore.saveWatchSyncGenerationState(.zero)
        cancelStandaloneRuntimeReconcile()
        let pendingActions = (try? await dataStore.loadWatchMirrorActions()) ?? []
        if !pendingActions.isEmpty {
            try? await dataStore.deleteWatchMirrorActions(actionIds: pendingActions.map(\.actionId))
        }
        if previousMode == .standalone {
            await deactivateStandaloneRuntime(reason: "watch_connectivity_migration")
        }
        await refreshChannelSubscriptions()
        await refreshWatchLightCountsAndNotify()
        publishCurrentEffectiveModeStatus(noop: false)
    }

    func refreshPushAuthorization(
        requestAuthorization: Bool = false,
        presentDeniedPrompt: Bool = false
    ) async {
        guard isStandaloneMode else { return }
        let isAuthorized = await ensureStandalonePushAuthorization(
            requestAuthorization: requestAuthorization,
            presentDeniedPrompt: presentDeniedPrompt
        )
        guard isAuthorized else { return }
        requestStandaloneRuntimeReconcile(reason: "refresh_push_authorization")
    }

    func syncWatchTokenToPhone() async {
        guard isStandaloneMode else { return }
        requestStandaloneRuntimeReconcile(reason: "sync_watch_token")
    }

    func syncSubscriptionsIfNeeded() async throws {
        guard isStandaloneMode else { return }
        let infrastructureReady = await preparePushInfrastructure(presentDeniedPrompt: true)
        guard infrastructureReady else { throw AppError.apnsDenied }
        let token = try await pushRegistrationService.awaitToken()
        guard let runtime = await loadPersistedStandaloneRuntimeState() else { throw AppError.noServer }
        WatchSessionBridge.shared.sendTokenToPhone(token)
        try await syncStandaloneSubscriptions(
            config: runtime.config,
            credentials: runtime.channels,
            providerToken: token
        )
    }

    private func preparePushInfrastructure(
        presentDeniedPrompt: Bool
    ) async -> Bool {
        guard isStandaloneMode else { return false }
        let isAuthorized = await ensureStandalonePushAuthorization(
            requestAuthorization: false,
            presentDeniedPrompt: presentDeniedPrompt
        )
        guard isAuthorized else { return false }
        requestRemoteNotificationsIfNeeded()
        await prepareAutomationPushStateIfNeeded()
        return true
    }

    private func prepareAutomationPushStateIfNeeded() async {
        guard let token = PushGoAutomationContext.providerToken?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty
        else { return }
        let platform = platformIdentifier()
        await dataStore.saveCachedPushToken(token, for: platform)
        guard let config = await loadPersistedStandaloneServerConfig() else { return }
        _ = await ensureProviderDeviceKey(config: config, platform: platform)
        await syncProviderPullRoute(config: config, providerToken: token)
    }

    private func platformIdentifier() -> String {
#if os(watchOS)
        "watchos"
#else
        "ios"
#endif
    }

    func updateScenePhase(_ phase: ScenePhase) {
        switch phase {
        case .active:
            isSceneActive = true
            clearDeliveredSystemNotifications()
            syncBadgeWithUnreadCount()
            scheduleMessageListRefresh()
            flushPendingMessageListRefreshIfNeeded()
            if isStandaloneMode {
                requestStandaloneRuntimeReconcile(reason: "scene_phase_active", presentDeniedPrompt: true)
            }
        case .background, .inactive:
            isSceneActive = false
            Task {
                await dataStore.flushWrites()
            }
        @unknown default:
            isSceneActive = false
        }
    }

    private func cancelStandaloneRuntimeReconcile() {
        standaloneRuntimeReconcileTask?.cancel()
        standaloneRuntimeReconcileTask = nil
        standaloneRuntimeReconcilePending = false
        standaloneRuntimeReconcileNeedsDeniedPrompt = false
    }

    private func requestStandaloneRuntimeReconcile(
        reason: String,
        presentDeniedPrompt: Bool = false
    ) {
        guard isStandaloneMode else { return }
        standaloneRuntimeReconcileNeedsDeniedPrompt =
            standaloneRuntimeReconcileNeedsDeniedPrompt || presentDeniedPrompt
        if let task = standaloneRuntimeReconcileTask, !task.isCancelled {
            standaloneRuntimeReconcilePending = true
            return
        }
        standaloneRuntimeReconcileTask = Task { @MainActor [weak self] in
            await self?.runStandaloneRuntimeReconcileLoop(initialReason: reason)
        }
    }

    private func runStandaloneRuntimeReconcileLoop(initialReason: String) async {
        var nextReason = initialReason
        while isStandaloneMode {
            let shouldPresentDeniedPrompt = standaloneRuntimeReconcileNeedsDeniedPrompt
            standaloneRuntimeReconcileNeedsDeniedPrompt = false
            standaloneRuntimeReconcilePending = false
            await reconcileStandaloneRuntime(
                reason: nextReason,
                presentDeniedPrompt: shouldPresentDeniedPrompt
            )
            if !standaloneRuntimeReconcilePending || !isStandaloneMode {
                break
            }
            nextReason = "follow_up"
        }
        standaloneRuntimeReconcileTask = nil
    }

    private func reconcileStandaloneRuntime(
        reason: String,
        presentDeniedPrompt: Bool
    ) async {
        guard isStandaloneMode else { return }
        await refreshChannelSubscriptions()
        guard let runtime = await loadPersistedStandaloneRuntimeState() else {
            updateStandaloneReadiness(false, failureReason: "missing_provisioning")
            return
        }
        guard !runtime.channels.isEmpty else {
            updateStandaloneReadiness(false, failureReason: "waiting_for_channel_subscriptions")
            return
        }
        let infrastructureReady = await preparePushInfrastructure(
            presentDeniedPrompt: presentDeniedPrompt
        )
        guard infrastructureReady, !Task.isCancelled, isStandaloneMode else {
            let failureReason: String
            switch pushRegistrationService.authorizationState {
            case .authorized:
                failureReason = "awaiting_push_infrastructure"
            case .denied:
                failureReason = "notification_permission_denied"
            case .notDetermined:
                failureReason = "awaiting_notification_permission"
            }
            updateStandaloneReadiness(false, failureReason: failureReason)
            return
        }
        do {
            let token = try await pushRegistrationService.awaitToken()
            guard !Task.isCancelled, isStandaloneMode else { return }
            WatchSessionBridge.shared.sendTokenToPhone(token)
            try await syncStandaloneSubscriptions(
                config: runtime.config,
                credentials: runtime.channels,
                providerToken: token
            )
            updateStandaloneReadiness(true, failureReason: nil)
        } catch {
            recordAutomationRuntimeError(error, source: "watch.reconcile_standalone_runtime.\(reason)")
            if !standaloneReady {
                updateStandaloneReadiness(false, failureReason: error.localizedDescription)
            }
        }
    }

    private func ensureStandalonePushAuthorization(
        requestAuthorization: Bool,
        presentDeniedPrompt: Bool
    ) async -> Bool {
        guard isStandaloneMode else { return false }
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
                    return false
                }
                throw AppError.apnsDenied
            }

            guard pushRegistrationService.authorizationState == .authorized else {
                return false
            }

            return true
        } catch let appError as AppError {
            if appError == .apnsDenied, presentDeniedPrompt {
                presentNotificationPermissionAlertIfNeeded()
                return false
            }
            recordAutomationRuntimeError(appError, source: "push.authorization.refresh")
            showToast(message: appError.errorDescription ?? localizationManager
                .localized("unable_to_obtain_apns_token"))
        } catch {
            recordAutomationRuntimeError(error, source: "push.authorization.refresh")
            showToast(message: localizationManager.localized(
                "unable_to_obtain_apns_token_placeholder",
                error.localizedDescription,
            ))
        }
        return false
    }

    private func syncStandaloneSubscriptions(
        config: ServerConfig,
        credentials: [(channelId: String, password: String)],
        providerToken: String
    ) async throws {
        guard isStandaloneMode else { return }
        let gatewayKey = config.gatewayKey
        await persistPushTokenAndRotateRoute(config: config, token: providerToken)
        await syncProviderPullRoute(config: config, providerToken: providerToken)
        guard let deviceKey = await ensureProviderDeviceKey(config: config, platform: platformIdentifier()) else {
            throw AppError.saveConfig(reason: "unable to obtain device_key")
        }

        let payload = try await channelSubscriptionService.sync(
            baseURL: config.baseURL,
            token: config.token,
            deviceKey: deviceKey,
            channels: credentials.map {
                ChannelSubscriptionService.SyncItem(channelId: $0.channelId, password: $0.password)
            }
        )

        let syncedAt = Date()
        var staleChannels: [String] = []
        var passwordMismatchChannels: [String] = []
        for result in payload.channels {
            if result.subscribed {
                try? await dataStore.updateChannelDisplayName(
                    gateway: gatewayKey,
                    channelId: result.channelId,
                    displayName: result.channelName ?? result.channelId
                )
                try? await dataStore.updateChannelLastSynced(
                    gateway: gatewayKey,
                    channelId: result.channelId,
                    date: syncedAt
                )
            } else {
                switch result.errorCode {
                case "channel_not_found":
                    staleChannels.append(result.channelId)
                case "password_mismatch":
                    passwordMismatchChannels.append(result.channelId)
                default:
                    break
                }
            }
        }

        for channelId in staleChannels + passwordMismatchChannels {
            try? await dataStore.softDeleteChannelSubscription(
                gateway: gatewayKey,
                channelId: channelId
            )
        }
        if !passwordMismatchChannels.isEmpty {
            let sample = passwordMismatchChannels.prefix(3).joined(separator: ", ")
            let suffix = passwordMismatchChannels.count > 3 ? "..." : ""
            showToast(
                message: localizationManager.localized(
                    "channel_password_mismatch_removed",
                    "\(sample)\(suffix)"
                )
            )
        }
        await refreshChannelSubscriptions()
    }

    func updateMainWindowVisibility(isVisible: Bool) {
        guard isMainWindowVisible != isVisible else { return }
        isMainWindowVisible = isVisible
        if isVisible {
            flushPendingMessageListRefreshIfNeeded()
        }
    }

    func updateActiveTab(_ tab: MainTab) {
        activeMainTab = tab
        clearDeliveredSystemNotifications()
    }

    func updateMessageListPosition(isAtTop: Bool) {
        guard isMessageListAtTop != isAtTop else { return }
        isMessageListAtTop = isAtTop
        clearDeliveredSystemNotifications()
    }

    func shouldPresentForegroundNotification(payload: [AnyHashable: Any]? = nil) -> Bool {
        guard !shouldSuppressForegroundNotifications else {
            return false
        }
        guard let payload else {
            return true
        }
        return shouldPresentUserAlert(for: payload)
    }

    private func ensureProviderDeviceKey(config: ServerConfig, platform: String) async -> String? {
        let existing = await dataStore.cachedProviderDeviceKey(
            for: platform,
            channelType: "private"
        )
        if let existing,
           Date().timeIntervalSince(lastWakeupDeviceRegisterAt) < privateWakeupDeviceRegisterInterval
        {
            return existing
        }
        let registered = try? await channelSubscriptionService.registerDevice(
            baseURL: config.baseURL,
            token: config.token,
            platform: platform,
            existingDeviceKey: existing
        )
        lastWakeupDeviceRegisterAt = Date()
        guard let deviceKey = registered?.deviceKey.trimmingCharacters(in: .whitespacesAndNewlines),
              !deviceKey.isEmpty
        else { return existing }
        await dataStore.saveCachedProviderDeviceKey(
            deviceKey,
            for: platform,
            channelType: "private"
        )
        return deviceKey
    }

    private func maintainDeviceKeyOnLaunch() async {
        guard isStandaloneMode else { return }
        guard let config = await loadPersistedStandaloneServerConfig() else { return }
        let infrastructureReady = await preparePushInfrastructure(presentDeniedPrompt: false)
        guard infrastructureReady else { return }
        guard let token = try? await pushRegistrationService.awaitToken() else { return }
        await persistPushTokenAndRotateRoute(config: config, token: token)
        await syncProviderPullRoute(config: config, providerToken: token)
        _ = await ensureProviderDeviceKey(config: config, platform: platformIdentifier())
    }

    private func scheduleLegacyGatewayDeviceCleanup(
        previousConfig: ServerConfig?,
        previousDeviceKey: String?,
        nextConfig: ServerConfig?
    ) {
        guard let previousConfig else { return }
        let trimmedDeviceKey = previousDeviceKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmedDeviceKey.isEmpty else { return }
        guard gatewayIdentity(previousConfig) != gatewayIdentity(nextConfig) else { return }
        let service = channelSubscriptionService
        Task(priority: .utility) {
            do {
                try await service.deleteDeviceChannel(
                    baseURL: previousConfig.baseURL,
                    token: previousConfig.token,
                    deviceKey: trimmedDeviceKey,
                    channelType: "apns"
                )
            } catch {}
        }
    }

    private func gatewayIdentity(_ config: ServerConfig?) -> String {
        guard let config else { return "" }
        let token = config.token?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return "\(config.baseURL.absoluteString)|\(token)"
    }

    private func syncProviderPullRoute(config: ServerConfig, providerToken: String) async {
        let now = Date()
        guard now.timeIntervalSince(lastWakeupRouteSyncAt) >= privateWakeupRouteSyncInterval else {
            return
        }
        let platform = platformIdentifier()
        guard let deviceKey = await ensureProviderDeviceKey(config: config, platform: platform) else {
            return
        }
        if let route = try? await channelSubscriptionService.upsertDeviceChannel(
            baseURL: config.baseURL,
            token: config.token,
            deviceKey: deviceKey,
            platform: platform,
            channelType: "apns",
            providerToken: providerToken
        ) {
            let resolvedDeviceKey = route.deviceKey.trimmingCharacters(in: .whitespacesAndNewlines)
            let persistedDeviceKey = resolvedDeviceKey.isEmpty ? deviceKey : resolvedDeviceKey
            await dataStore.saveCachedProviderDeviceKey(
                persistedDeviceKey,
                for: platform,
                channelType: "apns"
            )
            lastWakeupRouteSyncAt = now
        }
    }

    private func persistPushTokenAndRotateRoute(config: ServerConfig, token: String) async {
        let normalizedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedToken.isEmpty else { return }
        let platform = platformIdentifier()
        let previousRaw = await dataStore.cachedPushToken(for: platform)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let previousToken = (previousRaw?.isEmpty == false) ? previousRaw : nil
        await dataStore.saveCachedPushToken(normalizedToken, for: platform)
        guard let previousToken, previousToken != normalizedToken else {
            return
        }
        await retireProviderToken(config: config, providerToken: previousToken)
    }

    private func retireProviderToken(config: ServerConfig, providerToken: String) async {
        let normalized = providerToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }
        let platform = platformIdentifier()
        let cachedApnsKey = await dataStore.cachedProviderDeviceKey(
            for: platform,
            channelType: "apns"
        )?.trimmingCharacters(in: .whitespacesAndNewlines)
        let cachedPrivateKey = await ensureProviderDeviceKey(config: config, platform: platform)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let bootstrapDeviceKey = cachedApnsKey?.isEmpty == false ? cachedApnsKey : cachedPrivateKey
        guard let bootstrapDeviceKey, !bootstrapDeviceKey.isEmpty else {
            return
        }
        do {
            let route = try await channelSubscriptionService.upsertDeviceChannel(
                baseURL: config.baseURL,
                token: config.token,
                deviceKey: bootstrapDeviceKey,
                platform: platform,
                channelType: "apns",
                providerToken: normalized
            )
            let resolvedDeviceKeyRaw = route.deviceKey.trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedDeviceKey = resolvedDeviceKeyRaw.isEmpty ? bootstrapDeviceKey : resolvedDeviceKeyRaw
            await dataStore.saveCachedProviderDeviceKey(
                resolvedDeviceKey,
                for: platform,
                channelType: "apns"
            )
            try await channelSubscriptionService.deleteDeviceChannel(
                baseURL: config.baseURL,
                token: config.token,
                deviceKey: resolvedDeviceKey,
                channelType: "apns"
            )
        } catch {}
    }

    func updateLaunchAtLogin(isEnabled: Bool) {
        Task { @MainActor in
            await dataStore.saveLaunchAtLoginPreference(isEnabled)
        }
    }

    private func scheduleMessageListRefresh() {
        guard canRefreshMessageList else {
            pendingMessageListRefresh = true
            return
        }
        pendingMessageListRefreshTask?.cancel()
        let delay = messageListRefreshDelay
        pendingMessageListRefreshTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self else { return }
            messageStoreRevision = UUID()
            pendingMessageListRefresh = false
        }
    }

    private func syncBadgeWithUnreadCount() {
        BadgeManager.syncAppBadge(unreadCount: unreadMessageCount)
    }

    private func persistStandaloneLightPayload(
        _ payload: [String: String],
        titleOverride: String?,
        bodyOverride: String?,
        urlOverride: URL?,
        notificationRequestId: String?
    ) async -> Bool {
        let bridgedPayload: [AnyHashable: Any] = payload.reduce(into: [:]) { result, pair in
            result[pair.key] = pair.value
        }
        if NotificationHandling.shouldSkipPersistence(for: bridgedPayload) {
            return true
        }
        guard let lightPayload = WatchLightQuantizer.quantizeStandalonePayload(
            payload,
            titleOverride: titleOverride,
            bodyOverride: bodyOverride,
            urlOverride: urlOverride,
            notificationRequestId: notificationRequestId
        ) else {
            return false
        }
        do {
            try await dataStore.upsertWatchLightPayload(lightPayload)
            await refreshWatchLightCountsAndNotify()
            return true
        } catch {
            recordAutomationRuntimeError(error, source: "watch.persist_light_payload")
            return false
        }
    }

    func requestRemoteNotificationsIfNeeded() {
        guard isStandaloneMode else { return }
        guard pushRegistrationService.apnsToken == nil else { return }
        WKExtension.shared().registerForRemoteNotifications()
    }
    @discardableResult
    func persistNotificationIfNeeded(_ notification: UNNotification) async -> Bool {
        guard isStandaloneMode else { return false }
        let payload = WatchLightQuantizer.stringifyPayload(notification.request.content.userInfo)
        return await persistStandaloneLightPayload(
            payload,
            titleOverride: notification.request.content.title,
            bodyOverride: notification.request.content.body,
            urlOverride: nil,
            notificationRequestId: notification.request.identifier
        )
    }
    func handleNotificationOpen(notificationRequestId: String) async {
        await handleNotificationOpenInternal(
            notificationRequestId: notificationRequestId,
            markAsReadInStore: true,
            removeFromNotificationCenter: true
        )
    }

    func handleNotificationOpen(messageId: String) async {
        await handleNotificationOpenInternal(
            messageId: messageId,
            markAsReadInStore: true,
            removeFromNotificationCenter: true
        )
    }

    func handleNotificationOpen(entityType: String, entityId: String) async {
        await handleEntityOpenTarget(
            EntityOpenTarget(entityType: entityType, entityId: entityId)
        )
    }
    func handleNotificationOpenFromCopy(notificationRequestId: String) async {
        await handleNotificationOpen(notificationRequestId: notificationRequestId)
    }
    private func handleNotificationOpenInternal(
        notificationRequestId: String,
        markAsReadInStore: Bool,
        removeFromNotificationCenter: Bool
    ) async {
        do {
            let messages = try await dataStore.loadWatchLightMessages()
            if let target = messages.first(where: { $0.notificationRequestId == notificationRequestId })
            {
                await handleNotificationOpenTarget(
                    target,
                    markAsReadInStore: markAsReadInStore,
                    removeFromNotificationCenter: removeFromNotificationCenter
                )
                return
            }
        } catch {
            showToast(message: localizationManager.localized(
                "sync_message_failed_placeholder",
                error.localizedDescription
            ))
        }
    }

    private func handleNotificationOpenInternal(
        messageId: String,
        markAsReadInStore: Bool,
        removeFromNotificationCenter: Bool
    ) async {
        do {
            if let target = try await dataStore.loadWatchLightMessage(messageId: messageId) {
                await handleNotificationOpenTarget(
                    target,
                    markAsReadInStore: markAsReadInStore,
                    removeFromNotificationCenter: removeFromNotificationCenter
                )
                return
            }
        } catch {
            showToast(message: localizationManager.localized(
                "sync_message_failed_placeholder",
                error.localizedDescription
            ))
        }
    }

    private func handleNotificationOpenTarget(
        _ target: WatchLightMessage,
        markAsReadInStore: Bool,
        removeFromNotificationCenter: Bool
    ) async {
        let targetId = target.messageId

        if markAsReadInStore {
            if watchMode == .mirror {
                try? await enqueueMirrorMessageAction(kind: .read, messageId: target.messageId)
            } else {
                _ = try? await dataStore.markWatchLightMessageRead(messageId: target.messageId)
            }
        } else {
            await refreshMessageCountsAndNotify()
        }

        if removeFromNotificationCenter, let identifier = target.notificationRequestId {
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [identifier])
        }

        pendingEventToOpen = nil
        pendingThingToOpen = nil
        pendingMessageToOpen = targetId
    }

    private func handleEntityOpenTarget(_ target: EntityOpenTarget) async {
        pendingMessageToOpen = nil
        if target.entityType == "event" {
            pendingThingToOpen = nil
            pendingEventToOpen = target.entityId
        } else if target.entityType == "thing" {
            pendingEventToOpen = nil
            pendingThingToOpen = target.entityId
        }
    }

    private func clearDeliveredSystemNotifications() {
    }

    private var shouldSuppressForegroundNotifications: Bool {
        isSceneActive && activeMainTab == .messages && isMessageListAtTop
    }

    private var canRefreshMessageList: Bool {
        isSceneActive && isMainWindowVisible
    }

    private func shouldPresentUserAlert(for payload: [AnyHashable: Any]) -> Bool {
        NotificationHandling.shouldPresentUserAlert(from: payload)
    }

    private func flushPendingMessageListRefreshIfNeeded() {
        guard pendingMessageListRefresh, canRefreshMessageList else { return }
        messageStoreRevision = UUID()
        pendingMessageListRefresh = false
    }

}
