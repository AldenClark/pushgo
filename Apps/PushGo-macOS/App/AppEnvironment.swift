import Foundation
import Darwin
import Observation
import ServiceManagement
import SwiftUI
@preconcurrency import UserNotifications
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
    @ObservationIgnored private var notificationIngressObserver: DarwinNotificationObserver?
    @ObservationIgnored private var pendingCountsRefreshTask: Task<Void, Never>?
    @ObservationIgnored private var bootstrapTask: Task<Void, Never>?
    @ObservationIgnored private var didBootstrap = false
    @ObservationIgnored private var providerIngressBootstrapRecoveryInFlight = false

    private var toastDismissTask: Task<Void, Never>?
    private(set) var isMainWindowVisible = true

    private(set) var serverConfig: ServerConfig? = AppEnvironment.makeDefaultServerConfig()
    private(set) var totalMessageCount: Int = 0
    private(set) var unreadMessageCount: Int = 0
    private(set) var messageStoreRevision: UUID = UUID()
    private(set) var toastMessage: ToastMessage?
    @ObservationIgnored let pendingLocalDeletionController = PendingLocalDeletionController()
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
    private(set) var launchAtLoginEnabled: Bool = false
    private(set) var betaChannelEnabled: Bool = false
    var activeMainTab: MainTab { navigationState.activeMainTab }
    var channelSubscriptions: [ChannelSubscription] { channelSyncController.channelSubscriptions }
    private(set) var channelListFeedbackMessage: String?
    @ObservationIgnored private let appUpdateManager: any AppUpdateManaging

    private let channelSubscriptionService = ChannelSubscriptionService()
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
    @ObservationIgnored private(set) lazy var notificationIngressController = makeNotificationIngressController()
    @ObservationIgnored private let localStoreFailureStreakThreshold = 3
    @ObservationIgnored private let localStoreFailureStreakKey = "pushgo.local_store.failure_streak"
    @ObservationIgnored private let localStoreFailureDefaults = AppConstants.sharedUserDefaults()
    // Keep AppEnvironment as the composition root. Feature-specific behavior
    // should extend the dedicated controllers below instead of growing new
    // state machines in this type.
    @ObservationIgnored private(set) lazy var navigationState = AppNavigationState()
    @ObservationIgnored private(set) lazy var dataPageVisibilityController = DataPageVisibilityController(
        dataStore: dataStore
    )
    @ObservationIgnored private(set) lazy var channelSyncController = ChannelSyncController(
        platform: platformIdentifier(),
        dataStore: dataStore,
        pushRegistrationService: pushRegistrationService,
        channelSubscriptionService: channelSubscriptionService,
        providerRouteController: providerRouteController,
        localizationManager: localizationManager,
        serverConfigProvider: { [weak self] in
            self?.serverConfig
        },
        requestWatchStandaloneProvisioningSync: { _ in },
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
        refreshMessageCountsAndNotify: { [weak self] in
            await self?.refreshMessageCountsAndNotify()
        }
    )
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
            NSApp.terminate(nil)
        }
    )

    private init(
        dataStore: LocalDataStore = LocalDataStore(),
        pushRegistrationService: PushRegistrationService? = nil,
        localizationManager: LocalizationManager? = nil,
    ) {
        self.dataStore = dataStore
        self.pushRegistrationService = pushRegistrationService ?? PushRegistrationService.shared
        self.localizationManager = localizationManager ?? LocalizationManager.shared
        self.appUpdateManager = AppUpdateManagerFactory.make()
        self.betaChannelEnabled = appUpdateManager.isBetaChannelEnabled
        SharedImageCache.startMaintenance()
        messageSyncObserver = DarwinNotificationObserver(name: AppConstants.messageSyncNotificationName) { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                await self.reloadMessagesFromStore()
            }
        }
        notificationIngressObserver = DarwinNotificationObserver(
            name: AppConstants.notificationIngressChangedNotificationName
        ) { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                await self.handleNotificationIngressChanged(reason: "darwin_notification")
            }
        }
        registerDefaultNotificationCategories()
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
            recordProviderError: { [weak self] error, source in
                self?.showAutomationErrorToastIfNeeded(error, source: source)
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

    private func performBootstrap() async {
        beginProviderIngressBootstrapRecovery()
        await loadPersistedState()
        _ = await mergeNotificationIngressInbox(
            reason: "bootstrap",
            allowFallbackPull: false
        )
        await drainProviderDeliveryAckFailures(source: "provider.bootstrap.ack_failure.macos")
        Task(priority: .utility) { @MainActor in
            defer {
                finishProviderIngressBootstrapRecovery()
            }
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

    private func syncLaunchAtLoginPreferenceIfNeeded() async {
        let stored = await dataStore.loadLaunchAtLoginPreference()
        let actual = currentLaunchAtLoginState()
        let resolved = stored ?? actual
        if stored != resolved {
            await dataStore.saveLaunchAtLoginPreference(resolved)
        }
        launchAtLoginEnabled = resolved
        if actual != resolved {
            applyLaunchAtLoginPreference(resolved)
            await synchronizeLaunchAtLoginStateWithSystem()
        }
    }

    func refreshLaunchAtLoginStatus() async {
        await synchronizeLaunchAtLoginStateWithSystem()
    }

    func updateLaunchAtLogin(isEnabled: Bool) {
        launchAtLoginEnabled = isEnabled
        Task { @MainActor in
            await dataStore.saveLaunchAtLoginPreference(isEnabled)
        }
        applyLaunchAtLoginPreference(isEnabled)
        Task { @MainActor in
            await synchronizeLaunchAtLoginStateWithSystem()
        }
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

    private func synchronizeLaunchAtLoginStateWithSystem() async {
        let actual = currentLaunchAtLoginState()
        if launchAtLoginEnabled != actual {
            launchAtLoginEnabled = actual
        }
        await dataStore.saveLaunchAtLoginPreference(actual)
    }

    private func currentLaunchAtLoginState() -> Bool {
        switch SMAppService.mainApp.status {
        case .enabled, .requiresApproval:
            return true
        case .notRegistered, .notFound:
            return false
        @unknown default:
            return false
        }
    }

    var supportsInAppUpdates: Bool {
        appUpdateManager.isEnabled
    }

    func checkForUpdatesFromSettings() {
        guard appUpdateManager.isEnabled else { return }
        guard appUpdateManager.checkForUpdates() else {
            showToast(message: "当前版本未配置更新源，暂时无法检查更新。", style: .info, duration: 2.5)
            return
        }
    }

    func setBetaChannelEnabled(_ isEnabled: Bool) {
        guard appUpdateManager.isEnabled else { return }
        guard betaChannelEnabled != isEnabled else { return }
        betaChannelEnabled = isEnabled
        appUpdateManager.setBetaChannelEnabled(isEnabled)
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
        serverConfig = normalized
        await refreshChannelSubscriptions()
        await syncPrivateChannelState()
        providerRouteController.schedulePreviousGatewayDeviceCleanup(
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
        } catch {
            totalMessageCount = 0
            unreadMessageCount = 0
            BadgeManager.syncAppBadge(unreadCount: 0)
            scheduleMessageListRefresh()
        }
    }

    private func scheduleCountsRefresh() {
        pendingCountsRefreshTask?.cancel()
        pendingCountsRefreshTask = Task { @MainActor [weak self] in
            await self?.refreshMessageCountsAndNotify()
        }
    }

    private func scheduleMessageListRefresh() {
        messageStoreRevision = UUID()
    }

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

    private func showAutomationErrorToastIfNeeded(
        _ error: Error,
        source: String,
        category: String = "runtime"
    ) {
        recordAutomationRuntimeError(error, source: source, category: category)
        guard !PushGoAutomationContext.isActive else { return }
        if let appError = error as? AppError {
            showToast(
                message: appError.errorDescription
                    ?? localizationManager.localized("failed_to_save_message_status_placeholder", String(describing: appError))
            )
            return
        }
        showErrorToast(
            error,
            fallbackMessage: localizationManager.localized("operation_failed")
        )
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
        NSAccessibility.post(
            element: NSApplication.shared,
            notification: .announcementRequested,
            userInfo: [NSAccessibility.NotificationUserInfoKey.announcement: message]
        )
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
        localStoreRecoveryController.terminateForLocalStoreFailure()
    }

    func rebuildLocalStoreForRecoveryAndTerminate() {
        localStoreRecoveryController.rebuildLocalStoreForRecoveryAndTerminate()
    }

    private func handleLocalStoreUnavailable(_ state: LocalDataStore.StorageState) {
        localStoreRecoveryController.handleLocalStoreUnavailable(state)
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
        await channelSyncController.syncSubscriptionsOnLaunch()
    }

    func syncSubscriptionsOnChannelListEntry() async {
        await channelSyncController.syncSubscriptionsOnChannelListEntry()
    }

    func syncSubscriptionsIfNeeded() async throws {
        try await channelSyncController.syncSubscriptionsIfNeeded()
    }

    func clearChannelListFeedback() {
        channelListFeedbackMessage = nil
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
                userFacingErrorMessage(error),
            ))
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

    private func loadDataPageVisibility() async {
        await dataPageVisibilityController.loadPersistedState()
    }

    private func autoEnableDataPageIfNeeded(for message: PushMessage) {
        dataPageVisibilityController.autoEnableDataPageIfNeeded(for: message)
    }

    private func autoEnableDataPage(for entityType: String) {
        dataPageVisibilityController.autoEnableDataPage(for: entityType)
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
        await providerRouteController.syncProviderPullRoute(config: config, providerToken: token)
    }

    func refreshChannelSubscriptions() async {
        await channelSyncController.refreshChannelSubscriptions()
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

    func deleteLocalHistoryForChannel(channelId: String) async throws -> Int {
        try await channelSubscriptionController.deleteLocalHistoryForChannel(channelId: channelId)
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

    private func platformIdentifier() -> String {
        "macos"
    }

    func updateScenePhase(_ phase: ScenePhase) {
        switch phase {
        case .active:
            navigationState.setSceneActive(true)
            clearDeliveredSystemNotifications()
            syncBadgeWithUnreadCount()
            scheduleMessageListRefresh()
            Task { @MainActor in
                _ = await mergeNotificationIngressInbox(
                    reason: "macos_scene_active",
                    allowFallbackPull: true
                )
                await refreshLaunchAtLoginStatus()
                await refreshChannelSubscriptions()
                await syncPrivateChannelState()
            }
        case .background, .inactive:
            navigationState.setSceneActive(false)
            Task { @MainActor in
                await pendingLocalDeletionController.commitCurrentIfNeeded()
            }
            Task {
                await dataStore.flushWrites()
            }
            Task { @MainActor in
                await syncPrivateChannelState()
            }
        @unknown default:
            navigationState.setSceneActive(false)
        }
    }

    private func syncPrivateChannelState() async {
        await channelSyncController.refreshPrivateChannelRouteState()
    }

    func updateMainWindowVisibility(isVisible: Bool) {
        guard isMainWindowVisible != isVisible else { return }
        isMainWindowVisible = isVisible
    }

    func updateActiveTab(_ tab: MainTab) {
        navigationState.updateActiveTab(tab)
        clearDeliveredSystemNotifications()
    }

    func shouldPresentForegroundNotification(payload: [AnyHashable: Any]? = nil) -> Bool {
        guard let payload else {
            return true
        }
        return NotificationHandling.shouldPresentUserAlert(from: payload)
    }

    private func handleNotificationIngressChanged(reason: String) async {
        await notificationIngressController.handleNotificationIngressChanged(reason: reason)
    }

    private func drainProviderDeliveryAckFailures(source: String) async {
        await notificationIngressController.drainProviderDeliveryAckFailures(source: source)
    }

    @discardableResult
    func mergeNotificationIngressInbox(
        reason: String,
        allowFallbackPull: Bool,
        limit: Int = 256
    ) async -> Int {
        await notificationIngressController.mergeNotificationIngressInbox(
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
        MainWindowController.shared.showMainWindow()
    }

    func openDeepLink(_ url: URL) async {
        guard let target = PushGoDeepLink.parse(url) else { return }
        await openSystemTarget(target)
    }

    func handleNotificationOpenFromCopy(notificationRequestId: String) async {
        await notificationOpenController.handleNotificationOpen(notificationRequestId: notificationRequestId)
    }

    private func clearDeliveredSystemNotifications() {
    }

    private func channelMatches(_ candidate: String?, normalizedChannel: String) -> Bool {
        guard let candidate else { return false }
        if let normalizedCandidate = try? ChannelIdValidator.normalize(candidate) {
            return normalizedCandidate == normalizedChannel
        }
        return candidate.trimmingCharacters(in: .whitespacesAndNewlines) == normalizedChannel
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
        ChannelSubscriptionService.applyGatewayHeaders(&request, token: config.token)
        request.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [])

        let (data, response) = try await URLSession.shared.data(for: request)
        _ = try ChannelSubscriptionService.decodeGatewayResponse(
            ChannelSubscriptionService.EmptyPayload.self,
            data: data,
            response: response
        )
    }

    private func escapedGatewayPathComponent(_ raw: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/")
        return raw.addingPercentEncoding(withAllowedCharacters: allowed) ?? raw
    }

}
