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
    private struct NotificationInboxIdentity {
        let messageId: String?
        let deliveryId: String?
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
    @ObservationIgnored private var bootstrapTask: Task<Void, Never>?
    @ObservationIgnored private var didBootstrap = false
    @ObservationIgnored private var providerRouteTask: Task<String, Error>?
    @ObservationIgnored private var providerRouteTaskKey: String?
    @ObservationIgnored private var lastProviderRouteResultKey: String?
    @ObservationIgnored private var lastProviderRouteDeviceKey: String?
    @ObservationIgnored private var lastProviderRouteResolvedAt: Date = .distantPast
    @ObservationIgnored private var subscriptionSyncTask: Task<Void, Error>?
    @ObservationIgnored private var subscriptionSyncTaskKey: String?
    @ObservationIgnored private var lastSubscriptionSyncKey: String?
    @ObservationIgnored private var lastSubscriptionSyncAt: Date = .distantPast
    @ObservationIgnored private var providerIngressBootstrapRecoveryInFlight = false

    private var toastDismissTask: Task<Void, Never>?
    private(set) var isMainWindowVisible = true
    @ObservationIgnored private var lastWakeupRouteFingerprint: String?
    @ObservationIgnored private let providerRouteResultReuseInterval: TimeInterval = 25

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
    private(set) var channelSubscriptions: [ChannelSubscription] = []
    private var channelSubscriptionLookup: [String: ChannelSubscription] = [:]
    @ObservationIgnored private let appUpdateManager: any AppUpdateManaging

    private let channelSubscriptionService = ChannelSubscriptionService()
    private let notificationIngressInbox = NotificationIngressInbox.shared
    private let ackFailureStore = ProviderDeliveryAckFailureStore.shared
    @ObservationIgnored private lazy var providerIngressCoordinator = ProviderIngressCoordinator(
        platformSuffix: "macos",
        dataStore: dataStore,
        channelSubscriptionService: channelSubscriptionService,
        notificationIngressInbox: notificationIngressInbox,
        ackMarkerStore: ackFailureStore,
        hooks: ProviderIngressCoordinator.Hooks(
            isEnabled: { true },
            serverConfig: { [weak self] in self?.serverConfig },
            cachedDeviceKey: { [weak self] in
                guard let self else { return nil }
                return await self.cachedProviderPullDeviceKey()
            },
            hasPersistedNotification: { [weak self] identity in
                guard let self else { return false }
                return await self.hasPersistedNotification(identity: NotificationInboxIdentity(
                    messageId: identity.messageId,
                    deliveryId: identity.deliveryId
                ))
            },
            persistPayload: { [weak self] payload, requestIdentifier in
                guard let self else { return .failed }
                let dataStore = await MainActor.run { self.dataStore }
                let outcome = await NotificationPersistenceCoordinator.persistRemotePayloadIfNeeded(
                    payload,
                    requestIdentifier: requestIdentifier,
                    dataStore: dataStore,
                    beforeSave: { [weak self] message in
                        await MainActor.run {
                            self?.autoEnableDataPageIfNeeded(for: message)
                        }
                    }
                )
                return ProviderIngressPersistenceResult(outcome)
            },
            applyPersistenceResult: { [weak self] result in
                switch result {
                case .persisted, .duplicate:
                    self?.scheduleCountsRefresh()
                case .rejected, .failed:
                    break
                }
            },
            recordProviderError: { [weak self] error, source in
                self?.showAutomationErrorToastIfNeeded(error, source: source)
            }
        )
    )
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
        schedulePreviousGatewayDeviceCleanup(
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
                userFacingErrorMessage(error),
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
                userFacingErrorMessage(error),
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
        let normalizedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedToken.isEmpty else {
            throw AppError.typedLocal(
                code: "provider_token_missing",
                category: .validation,
                message: localizationManager.localized("operation_failed"),
                detail: "provider token missing"
            )
        }
        let syncKey = "\(gatewayKey)|\(normalizedToken)"
        if let inFlightTask = subscriptionSyncTask,
           subscriptionSyncTaskKey == syncKey
        {
            try await inFlightTask.value
            return
        }
        if lastSubscriptionSyncKey == syncKey,
           Date().timeIntervalSince(lastSubscriptionSyncAt) < 3
        {
            return
        }

        let task = Task<Void, Error> { @MainActor [weak self] in
            guard let self else {
                throw AppError.typedLocal(
                    code: "subscription_sync_context_released",
                    category: .internalError,
                    message: LocalizationProvider.localized("operation_failed"),
                    detail: "subscription sync context released"
                )
            }
            try await self.performSubscriptionsSync(
                config: config,
                credentials: credentials,
                providerToken: normalizedToken
            )
        }
        subscriptionSyncTaskKey = syncKey
        subscriptionSyncTask = task
        defer {
            if subscriptionSyncTaskKey == syncKey {
                subscriptionSyncTaskKey = nil
                subscriptionSyncTask = nil
            }
        }
        try await task.value
        lastSubscriptionSyncKey = syncKey
        lastSubscriptionSyncAt = Date()
    }

    private func performSubscriptionsSync(
        config: ServerConfig,
        credentials: [(channelId: String, password: String)],
        providerToken: String
    ) async throws {
        let gatewayKey = config.gatewayKey
        let channels = credentials.map {
            ChannelSubscriptionService.SyncItem(channelId: $0.channelId, password: $0.password)
        }
        guard !channels.isEmpty else {
            await refreshChannelSubscriptions()
            return
        }
        let deviceKey = try await ensureProviderRoute(config: config, providerToken: providerToken)

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
                switch result.resolvedErrorCode?.lowercased() {
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
            throw AppError.typedLocal(
                code: "channel_subscribe_failed",
                category: .internalError,
                message: localizationManager.localized("operation_failed"),
                detail: "channel subscribe failed"
            )
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
                try await persistProviderDeviceKey(
                    refreshedDeviceKey,
                    platform: platform,
                    channelType: "apns",
                    source: "provider.device_key.subscribe_refresh"
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
        if let appError = error as? AppError,
           appError.matchesGatewayCode("device_key_not_found")
        {
            return true
        }
        let text: String
        if let appError = error as? AppError {
            text = (appError.failureReason ?? appError.errorDescription ?? "").lowercased()
        } else {
            text = error.localizedDescription.lowercased()
        }
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
            throw AppError.typedLocal(
                code: "channel_password_missing",
                category: .validation,
                message: localizationManager.localized("channel_password_missing"),
                detail: "channel password missing"
            )
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

    func unsubscribeChannel(channelId: String) async throws {
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
    }

    func deleteLocalHistoryForChannel(channelId: String) async throws -> Int {
        let normalized = try ChannelIdValidator.normalize(channelId)
        let eventImageURLs = try await dataStore
            .loadEventMessagesForProjection()
            .filter { channelMatches($0.channel, normalizedChannel: normalized) }
            .flatMap(\.imageURLs)
        let thingImageURLs = try await dataStore
            .loadThingMessagesForProjection()
            .filter { channelMatches($0.channel, normalizedChannel: normalized) }
            .flatMap(\.imageURLs)
        let removedMessages = try await messageStateCoordinator.deleteMessages(channel: normalized, readState: nil)
        let removedEvents = try await dataStore.deleteEventRecords(channel: normalized)
        let removedThings = try await dataStore.deleteThingRecords(channel: normalized)
        let remainingMessages = try await dataStore.loadMessages(filter: .all, channel: normalized)
        let remainingEvents = try await dataStore
            .loadEventMessagesForProjection()
            .filter { channelMatches($0.channel, normalizedChannel: normalized) }
        let remainingThings = try await dataStore
            .loadThingMessagesForProjection()
            .filter { channelMatches($0.channel, normalizedChannel: normalized) }
        if !remainingMessages.isEmpty || !remainingEvents.isEmpty || !remainingThings.isEmpty {
            throw AppError.localStore(
                "channel cleanup incomplete messages=\(remainingMessages.count) events=\(remainingEvents.count) things=\(remainingThings.count)"
            )
        }
        await SharedImageCache.purge(urls: eventImageURLs + thingImageURLs)
        await refreshMessageCountsAndNotify()
        return removedMessages + removedEvents + removedThings
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
                showToast(message: localizationManager.localized(
                    "unable_to_sync_channels_placeholder",
                    userFacingErrorMessage(error)
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
            navigationState.setSceneActive(true)
            clearDeliveredSystemNotifications()
            syncBadgeWithUnreadCount()
            scheduleMessageListRefresh()
            Task { @MainActor in
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

    private func syncProviderPullRoute(config: ServerConfig, providerToken: String) async {
        let normalizedToken = providerToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedToken.isEmpty else { return }
        let platform = platformIdentifier()
        let cachedDeviceKey = await dataStore.cachedDeviceKey(
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
        guard (try? await ensureProviderRoute(config: config, providerToken: normalizedToken)) != nil else {
            return
        }
        await retireProviderToken(config: config, providerToken: resolvedPrevious)
    }

    private func retireProviderToken(config: ServerConfig, providerToken: String) async {
        let normalized = providerToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }
        let platform = platformIdentifier()
        do {
            try await channelSubscriptionService.retireProviderToken(
                baseURL: config.baseURL,
                token: config.token,
                platform: platform,
                providerToken: normalized
            )
        } catch {}
    }

    private func ensureProviderRoute(config: ServerConfig, providerToken: String) async throws -> String {
        let normalizedProviderToken = providerToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedProviderToken.isEmpty else {
            throw AppError.typedLocal(
                code: "provider_token_missing",
                category: .validation,
                message: localizationManager.localized("operation_failed"),
                detail: "provider token missing"
            )
        }
        let taskKey = "\(config.gatewayKey)|\(normalizedProviderToken)"
        if lastProviderRouteResultKey == taskKey,
           Date().timeIntervalSince(lastProviderRouteResolvedAt) < providerRouteResultReuseInterval,
           let resolvedDeviceKey = lastProviderRouteDeviceKey?.trimmingCharacters(in: .whitespacesAndNewlines),
           !resolvedDeviceKey.isEmpty
        {
            return resolvedDeviceKey
        }
        if providerRouteTaskKey == taskKey, let providerRouteTask {
            return try await providerRouteTask.value
        }

        let task = Task<String, Error> { @MainActor [weak self] in
            guard let self else {
                throw AppError.typedLocal(
                    code: "provider_route_context_released",
                    category: .internalError,
                    message: LocalizationProvider.localized("operation_failed"),
                    detail: "provider route context released"
                )
            }
            let platform = platformIdentifier()
            let cachedApnsKey = await dataStore.cachedDeviceKey(
                for: platform,
                channelType: "apns"
            )?.trimmingCharacters(in: .whitespacesAndNewlines)
            let registered = try await channelSubscriptionService.registerDevice(
                baseURL: config.baseURL,
                token: config.token,
                platform: platform,
                existingDeviceKey: cachedApnsKey?.isEmpty == false ? cachedApnsKey : nil
            )
            let bootstrapDeviceKey = registered.deviceKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !bootstrapDeviceKey.isEmpty else {
                throw AppError.typedLocal(
                    code: "gateway_response_missing_device_key",
                    category: .internalError,
                    message: localizationManager.localized("operation_failed"),
                    detail: "gateway response missing device_key"
                )
            }
            let route = try await channelSubscriptionService.upsertDeviceChannel(
                baseURL: config.baseURL,
                token: config.token,
                deviceKey: bootstrapDeviceKey,
                platform: platform,
                channelType: "apns",
                providerToken: normalizedProviderToken
            )
            let resolvedDeviceKey = route.deviceKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !resolvedDeviceKey.isEmpty else {
                throw AppError.typedLocal(
                    code: "gateway_response_missing_device_key",
                    category: .internalError,
                    message: localizationManager.localized("operation_failed"),
                    detail: "gateway response missing device_key"
                )
            }
            try await persistProviderDeviceKey(
                resolvedDeviceKey,
                platform: platform,
                channelType: "apns",
                source: "provider.device_key.route"
            )
            refreshAutomationStateIfNeeded()
            return resolvedDeviceKey
        }

        providerRouteTaskKey = taskKey
        providerRouteTask = task
        defer {
            if providerRouteTaskKey == taskKey {
                providerRouteTaskKey = nil
                providerRouteTask = nil
            }
        }
        let resolvedDeviceKey = try await task.value
        lastProviderRouteResultKey = taskKey
        lastProviderRouteDeviceKey = resolvedDeviceKey
        lastProviderRouteResolvedAt = Date()
        return resolvedDeviceKey
    }

    private func persistProviderDeviceKey(
        _ deviceKey: String,
        platform: String,
        channelType: String? = nil,
        source: String
    ) async throws {
        let result: ProviderDeviceKeyStore.SaveResult?
        if let channelType {
            result = await dataStore.saveCachedDeviceKey(
                deviceKey,
                for: platform,
                channelType: channelType
            )
        } else {
            result = await dataStore.saveCachedDeviceKey(deviceKey, for: platform)
        }
        try requireProviderDeviceKeyPersistence(result, source: source)
    }

    private func requireProviderDeviceKeyPersistence(
        _ result: ProviderDeviceKeyStore.SaveResult?,
        source: String
    ) throws {
        guard let result else {
            let message = "provider_device_key_save_failed platform=invalid"
            recordAutomationRuntimeMessage(
                message,
                source: source,
                category: "keychain",
                code: "E_PROVIDER_DEVICE_KEY_SAVE_FAILED"
            )
            throw AppError.typedLocal(
                code: "provider_device_key_save_failed",
                category: .local,
                message: localizationManager.localized("operation_failed"),
                detail: "provider_device_key_save_failed platform=invalid"
            )
        }
        guard result.error == nil, result.didPersist else {
            recordAutomationRuntimeMessage(
                Self.deviceKeySaveErrorDescription(result),
                source: source,
                category: "keychain",
                code: "E_PROVIDER_DEVICE_KEY_SAVE_FAILED"
            )
            throw result.error ?? AppError.typedLocal(
                code: "provider_device_key_save_failed",
                category: .local,
                message: localizationManager.localized("operation_failed"),
                detail: "provider_device_key_save_failed"
            )
        }
    }

    private static func deviceKeySaveErrorDescription(
        _ result: ProviderDeviceKeyStore.SaveResult
    ) -> String {
        var parts = [
            "provider_device_key_save_failed",
            "platform=\(result.platform)",
            "account=\(result.account)",
            "access_group=\(result.accessGroup ?? "nil")",
        ]
        if let status = result.error?.statusCode {
            parts.append("status=\(status)")
        } else if result.error == .unexpectedData {
            parts.append("error=unexpected_data")
        } else if let error = result.error {
            parts.append("error=\(error.localizedDescription)")
        } else {
            parts.append("error=not_persisted")
        }
        return parts.joined(separator: " ")
    }

    private func schedulePreviousGatewayDeviceCleanup(
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

    private func cachedProviderPullDeviceKey() async -> String? {
        if Date().timeIntervalSince(lastProviderRouteResolvedAt) < providerRouteResultReuseInterval,
           let recentDeviceKey = lastProviderRouteDeviceKey?.trimmingCharacters(in: .whitespacesAndNewlines),
           !recentDeviceKey.isEmpty
        {
            return recentDeviceKey
        }
        let platform = platformIdentifier()
        let deviceKey = await dataStore.cachedDeviceKey(for: platform)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return deviceKey?.isEmpty == false ? deviceKey : nil
    }

    private func providerIngressDeliveryId(from payload: [AnyHashable: Any]) -> String? {
        let sanitized = UserInfoSanitizer.sanitize(payload)
        let trimmed = (sanitized["delivery_id"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private func notificationInboxIdentity(from payload: [AnyHashable: Any]) -> NotificationInboxIdentity {
        let sanitized = UserInfoSanitizer.sanitize(payload)
        let messageId = NotificationHandling.extractMessageId(from: sanitized)
        let deliveryId = providerIngressDeliveryId(from: sanitized)
        return NotificationInboxIdentity(messageId: messageId, deliveryId: deliveryId)
    }

    private func hasPersistedNotification(identity: NotificationInboxIdentity) async -> Bool {
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

    private func applyNotificationPersistenceOutcome(
        _ outcome: NotificationPersistenceOutcome
    ) {
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
    }

    private func handleNotificationIngressChanged(reason: String) async {
        _ = await mergeNotificationIngressInbox(
            reason: reason,
            allowFallbackPull: false
        )
    }

    private func drainProviderDeliveryAckFailures(source: String) async {
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
        let outcome = await NotificationPersistenceCoordinator.persistRemotePayloadIfNeeded(
            payload,
            requestIdentifier: requestIdentifier,
            dataStore: dataStore,
            beforeSave: { [weak self] message in
                guard let self else { return }
                await self.autoEnableDataPageIfNeeded(for: message)
            }
        )
        applyNotificationPersistenceOutcome(outcome)
        return outcome
    }

    @discardableResult
    func persistNotificationIfNeeded(_ notification: UNNotification) async -> NotificationPersistenceOutcome {
        let notificationPayload = UserInfoSanitizer.sanitize(notification.request.content.userInfo)
        let identity = notificationInboxIdentity(from: notificationPayload)
        if await hasPersistedNotification(identity: identity) {
            return .duplicate
        }

        let ingress = await NotificationHandling.resolveNotificationIngress(
            from: notificationPayload,
            dataStore: dataStore,
            fallbackServerConfig: serverConfig,
            channelSubscriptionService: channelSubscriptionService
        )
        let outcome: NotificationPersistenceOutcome
        switch ingress {
        case let .pulled(payload, requestIdentifier):
            outcome = await persistRemotePayloadIfNeeded(
                payload,
                requestIdentifier: requestIdentifier
            )
            return outcome
        case .claimedByPeer:
            outcome = await hasPersistedNotification(identity: identity) ? .duplicate : .rejected
            return outcome
        case let .unresolvedWakeup(payload, requestIdentifier):
            if shouldDeferStartupWakeupPulls {
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
                    let resolvedIdentity = NotificationInboxIdentity(
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
                beforeSave: { [weak self] message in
                    guard let self else { return }
                    await self.autoEnableDataPageIfNeeded(for: message)
                }
            )
        }
        applyNotificationPersistenceOutcome(outcome)
        return outcome
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
