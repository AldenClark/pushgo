import Foundation
import Darwin
import Observation
import ServiceManagement
import SwiftUI
import UserNotifications
import AppKit

@MainActor
@Observable
final class AppEnvironment {
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
    @ObservationIgnored private var pendingCountsRefreshTask: Task<Void, Never>?
    @ObservationIgnored private var pendingMessageListRefreshTask: Task<Void, Never>?

    private var toastDismissTask: Task<Void, Never>?
    @ObservationIgnored private let countsRefreshDelay: TimeInterval = 0.4
    @ObservationIgnored private let messageListRefreshDelay: TimeInterval = 0.35
    @ObservationIgnored private var pendingMessageListRefresh = false
    @ObservationIgnored private var isMainWindowVisible = true
    @ObservationIgnored private var lastWakeupRouteFingerprint: String?

    private(set) var serverConfig: ServerConfig? = AppEnvironment.makeDefaultServerConfig()
    private(set) var totalMessageCount: Int = 0
    private(set) var unreadMessageCount: Int = 0
    private(set) var messageStoreRevision: UUID = UUID()
    private(set) var toastMessage: ToastMessage?
    private(set) var localStoreRecoveryState: LocalStoreRecoveryState?
    private(set) var shouldPresentNotificationPermissionAlert: Bool = false
    var pendingMessageToOpen: UUID?
    var pendingEventToOpen: String?
    var pendingThingToOpen: String?
    private(set) var isMessagePageEnabled: Bool = true
    private(set) var isEventPageEnabled: Bool = true
    private(set) var isThingPageEnabled: Bool = true
    private(set) var launchAtLoginEnabled: Bool = false
    private(set) var activeMainTab: MainTab = .messages
    private(set) var isMessageListAtTop: Bool = true
    private(set) var channelSubscriptions: [ChannelSubscription] = []
    private var channelSubscriptionLookup: [String: ChannelSubscription] = [:]
    private var isSceneActive = false

    private let channelSubscriptionService = ChannelSubscriptionService()
    @ObservationIgnored private let localStoreFailureStreakThreshold = 3
    @ObservationIgnored private let localStoreFailureStreakKey = "pushgo.local_store.failure_streak"
    @ObservationIgnored private let localStoreFailureDefaults = AppConstants.sharedUserDefaults()

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
                await self.reloadMessagesFromStore()
            }
        }
        registerDefaultNotificationCategories()
    }

    func bootstrap() async {
        await loadPersistedState()
        Task(priority: .utility) { @MainActor in
            await preparePushInfrastructure()
        }
        let store = dataStore
        Task(priority: .utility) {
            await store.warmCachesIfNeeded()
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

    private func syncLaunchAtLoginPreferenceIfNeeded() async {
        let stored = await dataStore.loadLaunchAtLoginPreference()
        let shouldEnable = stored ?? false
        launchAtLoginEnabled = shouldEnable
        applyLaunchAtLoginPreference(shouldEnable)
    }

    func updateLaunchAtLogin(isEnabled: Bool) {
        launchAtLoginEnabled = isEnabled
        Task { @MainActor in
            await dataStore.saveLaunchAtLoginPreference(isEnabled)
        }
        applyLaunchAtLoginPreference(isEnabled)
    }

    private func applyLaunchAtLoginPreference(_ isEnabled: Bool) {
        do {
            if isEnabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
        }
    }

    func updateServerConfig(_ config: ServerConfig?) async throws {
        let previousConfig = serverConfig
        let previousDeviceKey = await dataStore.cachedProviderDeviceKey(
            for: platformIdentifier(),
            channelType: "apns"
        )?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = config?.normalized()
        try await dataStore.saveServerConfig(normalized)
        serverConfig = normalized
        await refreshChannelSubscriptions()
        await syncPrivateChannelState()
        scheduleLegacyGatewayDeviceCleanup(
            previousConfig: previousConfig,
            previousDeviceKey: previousDeviceKey,
            nextConfig: normalized
        )
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
                error.localizedDescription,
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
        } catch {
            totalMessageCount = 0
            unreadMessageCount = 0
            BadgeManager.syncAppBadge(unreadCount: 0)
            scheduleMessageListRefresh()
        }
    }

    private func scheduleCountsRefresh() {
        pendingCountsRefreshTask?.cancel()
        let delay = countsRefreshDelay
        pendingCountsRefreshTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            await self?.refreshMessageCountsAndNotify()
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

    func publishStoreRefreshForAutomation() {
        pendingMessageListRefreshTask?.cancel()
        pendingMessageListRefresh = false
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
            return true
        case .rejected:
            return false
        case .failed:
            showToast(message: localizationManager.localized(
                "failed_to_save_message_placeholder",
                "notification persistence failed",
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
                error.localizedDescription,
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
        PushGoAutomationRuntime.shared.recordRuntimeError(
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
        PushGoAutomationRuntime.shared.recordRuntimeError(
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

    struct LocalStoreRecoveryState: Equatable {
        let title: String
        let message: String
        let canRebuild: Bool
    }

    private func announceAccessibility(_ message: String) {
        NSAccessibility.post(
            element: NSApplication.shared,
            notification: .announcementRequested,
            userInfo: [NSAccessibility.NotificationUserInfoKey.announcement: message]
        )
    }

    func dismissLocalStoreRecovery() {
        localStoreRecoveryState = nil
    }

    func dismissNotificationPermissionAlert() {
        shouldPresentNotificationPermissionAlert = false
    }

    func openSystemNotificationSettings() {
        guard !PushGoAutomationContext.blocksCrossAppDataAccess else { return }
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") else {
            return
        }
        _ = PushGoSystemInteraction.openExternalURL(url)
    }

    private func presentNotificationPermissionAlertIfNeeded() {
        guard !PushGoAutomationContext.isActive else { return }
        shouldPresentNotificationPermissionAlert = true
    }

    func terminateForLocalStoreFailure() {
        NSApp.terminate(nil)
    }

    func rebuildLocalStoreForRecoveryAndTerminate() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await dataStore.rebuildPersistentStoresForRecovery()
                clearLocalStoreFailureStreak()
                terminateForLocalStoreFailure()
            } catch {
                showToast(message: localizationManager.localized(
                    "initialization_failed_placeholder",
                    error.localizedDescription
                ))
            }
        }
    }

    private func incrementLocalStoreFailureStreak() -> Int {
        let next = localStoreFailureDefaults.integer(forKey: localStoreFailureStreakKey) + 1
        localStoreFailureDefaults.set(next, forKey: localStoreFailureStreakKey)
        return next
    }

    private func clearLocalStoreFailureStreak() {
        localStoreFailureDefaults.removeObject(forKey: localStoreFailureStreakKey)
    }

    private func isLikelyLocalStoreLockContention(reason: String?) -> Bool {
        guard let reason else { return false }
        let lowered = reason.lowercased()
        return lowered.contains("database is locked")
            || lowered.contains("database is busy")
            || lowered.contains("sqlite_busy")
            || lowered.contains("sqlite_locked")
            || lowered.contains("lock contention")
            || lowered.contains("locked")
    }

    private func handleLocalStoreUnavailable(_ state: LocalDataStore.StorageState) {
        let streak = incrementLocalStoreFailureStreak()
        let canRebuild = streak >= localStoreFailureStreakThreshold
        var lines: [String] = [
            localizationManager.localized("local_store_unavailable"),
            "请点击“退出应用”并重新打开。",
        ]
        if let reason = state.reason?.trimmingCharacters(in: .whitespacesAndNewlines), !reason.isEmpty {
            lines.append(reason)
            if isLikelyLocalStoreLockContention(reason: reason) {
                lines.append("检测到可能的数据库锁占用，请先彻底退出所有 PushGo 进程/扩展后重试。")
            }
        }
        if canRebuild {
            lines.append("该错误已连续出现多次，请上报日志；也可以选择“重建数据库并退出”。")
        } else {
            lines.append("若问题反复出现，请上报错误日志。")
        }
        localStoreRecoveryState = LocalStoreRecoveryState(
            title: localizationManager.localized("local_store_unavailable"),
            message: lines.joined(separator: "\n"),
            canRebuild: canRebuild
        )
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
                error.localizedDescription,
            ))
        }
    }

    private func syncSubscriptionsOnLaunch() async {
        do {
            try await syncSubscriptionsIfNeeded()
        } catch let appError as AppError {
            recordAutomationRuntimeError(appError, source: "channel.sync.launch")
            showToast(message: appError.errorDescription ?? localizationManager
                .localized("unable_to_sync_channels"))
        } catch {
            recordAutomationRuntimeError(error, source: "channel.sync.launch")
            showToast(message: localizationManager.localized(
                "unable_to_sync_channels_placeholder",
                error.localizedDescription,
            ))
        }
    }

    func syncSubscriptionsOnChannelListEntry() async {
        do {
            try await syncSubscriptionsIfNeeded()
        } catch let appError as AppError {
            recordAutomationRuntimeError(appError, source: "channel.sync.entry")
            showToast(message: appError.errorDescription ?? localizationManager
                .localized("unable_to_sync_channels"))
        } catch {
            recordAutomationRuntimeError(error, source: "channel.sync.entry")
            showToast(message: localizationManager.localized(
                "unable_to_sync_channels_placeholder",
                error.localizedDescription,
            ))
        }
    }

    private func ensureActivePushToken(serverConfig: ServerConfig) async throws -> String {
        let token = try await pushRegistrationService.awaitToken()
        await persistPushTokenAndRotateRoute(config: serverConfig, token: token)
        return token
    }

    func syncSubscriptionsIfNeeded() async throws {
        guard let config = serverConfig else { throw AppError.noServer }
        let gatewayKey = config.gatewayKey
        let credentials = try await dataStore.activeChannelCredentials(gateway: gatewayKey)
        let token = try await ensureActivePushToken(serverConfig: config)
        _ = try await ensureProviderRoute(config: config, providerToken: token)
        let channels = credentials.map {
            ChannelSubscriptionService.SyncItem(channelId: $0.channelId, password: $0.password)
        }
        guard !channels.isEmpty else {
            await refreshChannelSubscriptions()
            await syncPrivateChannelState()
            return
        }
        let deviceKey = try await ensureProviderRoute(config: config, providerToken: token)

        let payload = try await channelSubscriptionService.sync(
            baseURL: config.baseURL,
            token: config.token,
            deviceKey: deviceKey,
            channels: channels
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
            let limited = Array(passwordMismatchChannels.prefix(3))
            let suffix = passwordMismatchChannels.count > 3 ? "..." : ""
            showToast(
                message: localizationManager.localized(
                    "channel_password_mismatch_removed",
                    "\(limited.joined(separator: ", "))\(suffix)"
                )
            )
        }
        await refreshChannelSubscriptions()
        await syncPrivateChannelState()
    }

    func updateNotificationMaterial(_ material: ServerConfig.NotificationKeyMaterial) async {
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
        do {
            try await updateServerConfig(config)
        } catch {
            showToast(message: localizationManager.localized(
                "failed_to_save_server_configuration_placeholder",
                error.localizedDescription,
            ))
        }
    }

    var currentNotificationMaterial: ServerConfig.NotificationKeyMaterial? {
        serverConfig?.notificationKeyMaterial
    }

    func setMessagePageEnabled(_ isEnabled: Bool) {
        updateDataPageVisibility(messageEnabled: isEnabled)
    }

    func setEventPageEnabled(_ isEnabled: Bool) {
        updateDataPageVisibility(eventEnabled: isEnabled)
    }

    func setThingPageEnabled(_ isEnabled: Bool) {
        updateDataPageVisibility(thingEnabled: isEnabled)
    }

    private func updateDataPageVisibility(
        messageEnabled: Bool? = nil,
        eventEnabled: Bool? = nil,
        thingEnabled: Bool? = nil
    ) {
        var next = DataPageVisibilitySnapshot(
            messageEnabled: isMessagePageEnabled,
            eventEnabled: isEventPageEnabled,
            thingEnabled: isThingPageEnabled
        )
        if let messageEnabled {
            next.messageEnabled = messageEnabled
        }
        if let eventEnabled {
            next.eventEnabled = eventEnabled
        }
        if let thingEnabled {
            next.thingEnabled = thingEnabled
        }
        applyDataPageVisibility(next, persist: true)
    }

    private func applyDataPageVisibility(
        _ visibility: DataPageVisibilitySnapshot,
        persist: Bool
    ) {
        let changed = isMessagePageEnabled != visibility.messageEnabled
            || isEventPageEnabled != visibility.eventEnabled
            || isThingPageEnabled != visibility.thingEnabled
        guard changed else { return }
        isMessagePageEnabled = visibility.messageEnabled
        isEventPageEnabled = visibility.eventEnabled
        isThingPageEnabled = visibility.thingEnabled
        if persist {
            let store = self.dataStore
            Task(priority: .utility) {
                await store.saveDataPageVisibility(visibility)
            }
        }
    }

    private func loadDataPageVisibility() async {
        let visibility = await dataStore.loadDataPageVisibility()
        applyDataPageVisibility(visibility, persist: false)
    }

    private func autoEnableDataPageIfNeeded(for message: PushMessage) {
        let normalized = message.entityType
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        switch normalized {
        case "event", "thing":
            autoEnableDataPage(for: normalized)
        default:
            autoEnableDataPage(for: "message")
        }
    }

    private func autoEnableDataPage(for entityType: String) {
        switch entityType {
        case "event":
            if !isEventPageEnabled {
                updateDataPageVisibility(eventEnabled: true)
            }
        case "thing":
            if !isThingPageEnabled {
                updateDataPageVisibility(thingEnabled: true)
            }
        default:
            if !isMessagePageEnabled {
                updateDataPageVisibility(messageEnabled: true)
            }
        }
    }

    private func loadPersistedState() async {
        await syncLaunchAtLoginPreferenceIfNeeded()
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
            handleLocalStoreUnavailable(storeState)
            return
        case .persistent:
            clearLocalStoreFailureStreak()
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
                    error.localizedDescription
                ))
            }
        }
        await loadDataPageVisibility()

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
        await refreshChannelSubscriptions()
        await syncPrivateChannelState()
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
                    error.localizedDescription,
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
    }

    func refreshChannelSubscriptions() async {
        guard let gatewayKey = serverConfig?.gatewayKey else {
            channelSubscriptions = []
            channelSubscriptionLookup = [:]
            return
        }

        do {
            let active = try await dataStore.loadChannelSubscriptions(
                gateway: gatewayKey,
                includeDeleted: false
            )
            let all = try await dataStore.loadChannelSubscriptions(
                gateway: gatewayKey,
                includeDeleted: true
            )
            channelSubscriptions = active
            channelSubscriptionLookup = Dictionary(uniqueKeysWithValues: all.map { ($0.channelId, $0) })
        } catch {
            channelSubscriptions = []
            channelSubscriptionLookup = [:]
        }
    }

    func channelDisplayName(for channelId: String?) -> String? {
        let trimmed = channelId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return nil }
        if let match = channelSubscriptionLookup[trimmed] {
            return match.displayName
        }
        return trimmed
    }

    func channelExists(channelId: String) async throws -> ChannelSubscriptionService.ExistsPayload {
        guard let config = serverConfig else { throw AppError.noServer }
        let normalized = try ChannelIdValidator.normalize(channelId)
        return try await channelSubscriptionService.channelExists(
            baseURL: config.baseURL,
            token: config.token,
            channelId: normalized
        )
    }

    func createChannel(alias: String, password: String) async throws -> ChannelSubscriptionService.SubscribePayload {
        let normalizedAlias = try ChannelNameValidator.normalize(alias)
        return try await subscribeChannel(channelId: nil, alias: normalizedAlias, password: password)
    }

    func subscribeChannel(channelId: String, password: String) async throws -> ChannelSubscriptionService.SubscribePayload {
        let normalizedId = try ChannelIdValidator.normalize(channelId)
        return try await subscribeChannel(channelId: normalizedId, alias: nil, password: password)
    }

    private func subscribeChannel(
        channelId: String?,
        alias: String?,
        password: String
    ) async throws -> ChannelSubscriptionService.SubscribePayload {
        guard let config = serverConfig else { throw AppError.noServer }
        let gatewayKey = config.gatewayKey
        let validatedPassword = try ChannelPasswordValidator.validate(password)
        let token = try await ensureActivePushToken(serverConfig: config)
        let payload = try await subscribeWithDeviceKeyRecovery(
            config: config,
            providerToken: token,
            channelId: channelId,
            alias: alias,
            password: validatedPassword
        )

        guard payload.subscribed else {
            throw AppError.unknown(localizationManager.localized("operation_failed"))
        }

        let displayName = payload.channelName.isEmpty ? payload.channelId : payload.channelName
        _ = try await dataStore.upsertChannelSubscription(
            gateway: gatewayKey,
            channelId: payload.channelId,
            displayName: displayName,
            password: validatedPassword,
            lastSyncedAt: Date()
        )
        await refreshChannelSubscriptions()
        await syncPrivateChannelState()
        return payload
    }

    private func subscribeWithDeviceKeyRecovery(
        config: ServerConfig,
        providerToken: String,
        channelId: String?,
        alias: String?,
        password: String
    ) async throws -> ChannelSubscriptionService.SubscribePayload {
        let platform = platformIdentifier()
        let initialDeviceKey = try await ensureProviderRoute(config: config, providerToken: providerToken)
        do {
            return try await channelSubscriptionService.subscribe(
                baseURL: config.baseURL,
                token: config.token,
                deviceKey: initialDeviceKey,
                channelId: channelId,
                channelName: alias,
                password: password
            )
        } catch {
            guard isDeviceKeyNotFoundError(error) else {
                throw error
            }
            let registered = try await channelSubscriptionService.registerDevice(
                baseURL: config.baseURL,
                token: config.token,
                platform: platform,
                existingDeviceKey: initialDeviceKey
            )
            let refreshedDeviceKey = registered.deviceKey.trimmingCharacters(in: .whitespacesAndNewlines)
            if !refreshedDeviceKey.isEmpty {
                await dataStore.saveCachedProviderDeviceKey(
                    refreshedDeviceKey,
                    for: platform,
                    channelType: "apns"
                )
            }
            let ensuredDeviceKey = try await ensureProviderRoute(config: config, providerToken: providerToken)
            return try await channelSubscriptionService.subscribe(
                baseURL: config.baseURL,
                token: config.token,
                deviceKey: ensuredDeviceKey,
                channelId: channelId,
                channelName: alias,
                password: password
            )
        }
    }

    private func isDeviceKeyNotFoundError(_ error: Error) -> Bool {
        let text = error.localizedDescription.lowercased()
        return text.contains("device_key_not_found")
            || text.contains("device_key not found")
            || text.contains("device key not found")
    }

    func renameChannel(channelId: String, alias: String) async throws {
        guard let config = serverConfig else { throw AppError.noServer }
        let gatewayKey = config.gatewayKey
        let normalizedId = try ChannelIdValidator.normalize(channelId)
        let normalizedAlias = try ChannelNameValidator.normalize(alias)
        guard let password = await dataStore.channelPassword(gateway: gatewayKey, for: normalizedId) else {
            throw AppError.unknown(localizationManager.localized("channel_password_missing"))
        }

        let payload = try await channelSubscriptionService.renameChannel(
            baseURL: config.baseURL,
            token: config.token,
            channelId: normalizedId,
            channelName: normalizedAlias,
            password: password
        )

        try await dataStore.updateChannelDisplayName(
            gateway: gatewayKey,
            channelId: payload.channelId,
            displayName: payload.channelName
        )
        await refreshChannelSubscriptions()
    }

    func unsubscribeChannel(channelId: String, deleteLocalMessages: Bool) async throws -> Int {
        guard let config = serverConfig else { throw AppError.noServer }
        let gatewayKey = config.gatewayKey
        let normalized = try ChannelIdValidator.normalize(channelId)
        let token = try await ensureActivePushToken(serverConfig: config)
        let deviceKey = try await ensureProviderRoute(config: config, providerToken: token)

        _ = try await channelSubscriptionService.unsubscribe(
            baseURL: config.baseURL,
            token: config.token,
            deviceKey: deviceKey,
            channelId: normalized
        )

        try await dataStore.softDeleteChannelSubscription(gateway: gatewayKey, channelId: normalized)
        await refreshChannelSubscriptions()
        await syncPrivateChannelState()

        guard deleteLocalMessages else { return 0 }
        return try await messageStateCoordinator.deleteMessages(channel: normalized, readState: nil)
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
            throw AppError.unknown("event_id required")
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

        guard let password = await dataStore.channelPassword(gateway: gatewayKey, for: normalizedChannelId) else {
            throw AppError.unknown(localizationManager.localized("channel_password_missing"))
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
        Task { @MainActor in
            do {
                if let latestToken = try? await pushRegistrationService.awaitToken() {
                    if let config = serverConfig {
                        await persistPushTokenAndRotateRoute(config: config, token: latestToken)
                    } else {
                        await dataStore.saveCachedPushToken(latestToken, for: platformIdentifier())
                    }
                }
                try await syncSubscriptionsIfNeeded()
                if let config = serverConfig,
                   let token = await dataStore.cachedPushToken(for: platformIdentifier())?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !token.isEmpty
                {
                    await syncProviderPullRoute(config: config, providerToken: token)
                }
            } catch {
                let message = (error as? AppError)?.errorDescription ?? error.localizedDescription
                showToast(message: localizationManager.localized(
                    "unable_to_sync_channels_placeholder",
                    message
                ))
            }
            await syncPrivateChannelState()
        }
    }

    private func platformIdentifier() -> String {
        "macos"
    }

    func updateScenePhase(_ phase: ScenePhase) {
        switch phase {
        case .active:
            isSceneActive = true
            clearDeliveredSystemNotifications()
            syncBadgeWithUnreadCount()
            scheduleMessageListRefresh()
            flushPendingMessageListRefreshIfNeeded()
            Task { @MainActor in
                await refreshChannelSubscriptions()
                await syncPrivateChannelState()
            }
        case .background, .inactive:
            isSceneActive = false
            Task {
                await dataStore.flushWrites()
            }
            Task { @MainActor in
                await syncPrivateChannelState()
            }
        @unknown default:
            isSceneActive = false
        }
    }

    private func syncPrivateChannelState() async {
        guard let config = serverConfig else { return }
        if let token = await dataStore.cachedPushToken(for: platformIdentifier())?.trimmingCharacters(in: .whitespacesAndNewlines),
           !token.isEmpty
        {
            await syncProviderPullRoute(config: config, providerToken: token)
        }
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
        return NotificationHandling.shouldPresentUserAlert(from: payload)
    }

    private func syncProviderPullRoute(config: ServerConfig, providerToken: String) async {
        let normalizedToken = providerToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedToken.isEmpty else { return }
        let platform = platformIdentifier()
        let cachedDeviceKey = await dataStore.cachedProviderDeviceKey(
            for: platform,
            channelType: "apns"
        )?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let routeKey = cachedDeviceKey, !routeKey.isEmpty {
            let fingerprint = "\(platform)|\(routeKey)|\(normalizedToken)"
            guard lastWakeupRouteFingerprint != fingerprint else {
                return
            }
        }
        if let ensuredDeviceKey = try? await ensureProviderRoute(
            config: config,
            providerToken: normalizedToken
        ) {
            lastWakeupRouteFingerprint = "\(platform)|\(ensuredDeviceKey)|\(normalizedToken)"
        }
    }

    private func persistPushTokenAndRotateRoute(config: ServerConfig, token: String) async {
        let normalizedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedToken.isEmpty else { return }
        let platform = platformIdentifier()
        let previousRaw = await dataStore.cachedPushToken(for: platform)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedPrevious = (previousRaw?.isEmpty == false) ? previousRaw : nil
        await dataStore.saveCachedPushToken(normalizedToken, for: platform)
        guard let resolvedPrevious, resolvedPrevious != normalizedToken else {
            return
        }
        await retireProviderToken(config: config, providerToken: resolvedPrevious)
    }

    private func retireProviderToken(config: ServerConfig, providerToken: String) async {
        let normalized = providerToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }
        let platform = platformIdentifier()
        let cachedApnsKey = await dataStore.cachedProviderDeviceKey(
            for: platform,
            channelType: "apns"
        )?.trimmingCharacters(in: .whitespacesAndNewlines)
        let bootstrapDeviceKey = cachedApnsKey?.isEmpty == false ? cachedApnsKey : nil
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

    private func ensureProviderRoute(config: ServerConfig, providerToken: String) async throws -> String {
        let platform = platformIdentifier()
        let cachedApnsKey = await dataStore.cachedProviderDeviceKey(
            for: platform,
            channelType: "apns"
        )?.trimmingCharacters(in: .whitespacesAndNewlines)
        let bootstrapDeviceKey: String
        if let cachedApnsKey, !cachedApnsKey.isEmpty {
            bootstrapDeviceKey = cachedApnsKey
        } else {
            let registered = try await channelSubscriptionService.registerDevice(
                baseURL: config.baseURL,
                token: config.token,
                platform: platform,
                existingDeviceKey: nil
            )
            let registeredDeviceKey = registered.deviceKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !registeredDeviceKey.isEmpty else {
                throw AppError.unknown(localizationManager.localized("operation_failed"))
            }
            await dataStore.saveCachedProviderDeviceKey(
                registeredDeviceKey,
                for: platform,
                channelType: "apns"
            )
            bootstrapDeviceKey = registeredDeviceKey
        }
        let route = try await channelSubscriptionService.upsertDeviceChannel(
            baseURL: config.baseURL,
            token: config.token,
            deviceKey: bootstrapDeviceKey,
            platform: platform,
            channelType: "apns",
            providerToken: providerToken
        )
        let resolvedDeviceKeyRaw = route.deviceKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedDeviceKey = resolvedDeviceKeyRaw.isEmpty ? bootstrapDeviceKey : resolvedDeviceKeyRaw
        await dataStore.saveCachedProviderDeviceKey(
            resolvedDeviceKey,
            for: platform,
            channelType: "apns"
        )
        return resolvedDeviceKey
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

    @discardableResult
    func persistNotificationIfNeeded(_ notification: UNNotification) async -> NotificationPersistenceOutcome {
        let outcome = await NotificationPersistenceCoordinator.persistIfNeeded(
            notification,
            dataStore: dataStore,
            beforeSave: { [weak self] message in
                guard let self else { return }
                await self.autoEnableDataPageIfNeeded(for: message)
            }
        )
        switch outcome {
        case .duplicate:
            scheduleCountsRefresh()
        case .persistedMain:
            scheduleCountsRefresh()
        case .persistedPending:
            scheduleCountsRefresh()
        case .rejected, .failed:
            break
        }
        return outcome
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
            if let target = try await dataStore.loadMessage(notificationRequestId: notificationRequestId) {
                await handleNotificationOpenTarget(
                    target,
                    markAsReadInStore: markAsReadInStore,
                    removeFromNotificationCenter: removeFromNotificationCenter
                )
                return
            }
            if let entityTarget = try await dataStore.loadEntityOpenTarget(notificationRequestId: notificationRequestId) {
                await handleEntityOpenTarget(entityTarget)
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
            if let target = try await dataStore.loadMessage(messageId: messageId) {
                await handleNotificationOpenTarget(
                    target,
                    markAsReadInStore: markAsReadInStore,
                    removeFromNotificationCenter: removeFromNotificationCenter
                )
                return
            }
            if let entityTarget = try await dataStore.loadEntityOpenTarget(messageId: messageId) {
                await handleEntityOpenTarget(entityTarget)
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
        _ target: PushMessage,
        markAsReadInStore: Bool,
        removeFromNotificationCenter: Bool
    ) async {
        let targetId = target.id

        if markAsReadInStore {
            _ = try? await messageStateCoordinator.markRead(messageId: targetId)
        } else {
            await refreshMessageCountsAndNotify()
            if removeFromNotificationCenter {
                removeDeliveredNotificationIfNeeded(for: target)
            }
        }
        autoEnableDataPage(for: "message")

        pendingEventToOpen = nil
        pendingThingToOpen = nil
        pendingMessageToOpen = targetId
    }

    private func handleEntityOpenTarget(_ target: EntityOpenTarget) async {
        pendingMessageToOpen = nil
        if target.entityType == "event" {
            autoEnableDataPage(for: "event")
            pendingThingToOpen = nil
            pendingEventToOpen = target.entityId
        } else if target.entityType == "thing" {
            autoEnableDataPage(for: "thing")
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
        isMainWindowVisible
    }

    private func flushPendingMessageListRefreshIfNeeded() {
        guard pendingMessageListRefresh, canRefreshMessageList else { return }
        messageStoreRevision = UUID()
        pendingMessageListRefresh = false
    }

    private func postGatewayPayload(
        _ payload: [String: Any],
        endpointPath: String,
        config: ServerConfig
    ) async throws {
        guard JSONSerialization.isValidJSONObject(payload) else {
            throw AppError.invalidURL
        }
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
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token = config.token, !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AppError.serverUnreachable
        }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw AppError.authFailed
        }
        if !(200 ... 299).contains(http.statusCode) {
            throw AppError.unknown("HTTP \(http.statusCode): request failed")
        }

        if let decoded = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            if let success = decoded["success"] as? Bool, success {
                return
            }
            if let message = decoded["error"] as? String,
               !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                throw AppError.unknown(message)
            }
        }
    }

    private func escapedGatewayPathComponent(_ raw: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/")
        return raw.addingPercentEncoding(withAllowedCharacters: allowed) ?? raw
    }

}
