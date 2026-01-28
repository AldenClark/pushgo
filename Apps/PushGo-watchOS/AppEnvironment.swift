import Foundation
import Observation
import SwiftUI
import UserNotifications
import WatchKit
import WatchConnectivity
#if canImport(UIKit)
import UIKit
#endif

private struct AppEnvironmentKey: EnvironmentKey {
    static let defaultValue: AppEnvironment = .shared
}

extension EnvironmentValues {
    var appEnvironment: AppEnvironment {
        get { self[AppEnvironmentKey.self] }
        set { self[AppEnvironmentKey.self] = newValue }
    }
}

@MainActor
@Observable
final class AppEnvironment {
    @MainActor
    private static let _shared = AppEnvironment()
    nonisolated static var shared: AppEnvironment {
        MainActor.assumeIsolated { _shared }
    }

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
    @ObservationIgnored private var performanceObserver: NSObjectProtocol?
    @ObservationIgnored private var pendingCountsRefreshTask: Task<Void, Never>?
    @ObservationIgnored private var pendingMessageListRefreshTask: Task<Void, Never>?
    @ObservationIgnored private var pendingRetentionTask: Task<Void, Never>?
    @ObservationIgnored private var lastRemoteNotificationRequestAt: Date?
    @ObservationIgnored private let remoteNotificationRequestInterval: TimeInterval = 30

    private var toastDismissTask: Task<Void, Never>?
    @ObservationIgnored private let countsRefreshDelay: TimeInterval = 0.4
    @ObservationIgnored private let messageListRefreshDelay: TimeInterval = 0.35
    @ObservationIgnored private let retentionDays: Int = 30
    @ObservationIgnored private let maxStoredMessages: Int = 500
    @ObservationIgnored private let retentionBatchSize: Int = 100
    @ObservationIgnored private var pendingMessageListRefresh = false
    @ObservationIgnored private var isMainWindowVisible = true

    private(set) var serverConfig: ServerConfig? = AppEnvironment.makeDefaultServerConfig()
    private(set) var totalMessageCount: Int = 0
    private(set) var unreadMessageCount: Int = 0
    private(set) var messageStoreRevision: UUID = UUID()
    private(set) var toastMessage: ToastMessage?
    var pendingMessageToOpen: UUID?
    private(set) var activeMainTab: MainTab = .messages
    private(set) var isMessageListAtTop: Bool = true
    private(set) var channelSubscriptions: [ChannelSubscription] = []
    private var channelSubscriptionLookup: [String: ChannelSubscription] = [:]
    private var isSceneActive = false
    private(set) var defaultRingtoneFilename: String = AppConstants.fallbackRingtoneFilename

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
                await self.reloadMessagesFromStore()
            }
        }
        performanceObserver = NotificationCenter.default.addObserver(
            forName: Notification.Name(AppConstants.performanceDegradationNotificationName),
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            Task { @MainActor in
                await self.handlePerformanceDegradation()
            }
        }
        registerDefaultNotificationCategories()
        Task { @MainActor in
            await refreshDefaultRingtoneFromStore()
        }
    }

    func bootstrap() async {
        Task(priority: .userInitiated) { @MainActor in
            await loadPersistedState()
        }
        Task(priority: .utility) { @MainActor in
            await preparePushInfrastructure()
        }
        let store = dataStore
        Task.detached(priority: .utility) {
            await store.warmCachesIfNeeded()
        }
    }

    private static func makeDefaultServerConfig() -> ServerConfig? {
        guard let url = AppConstants.defaultServerURL else { return nil }
        return ServerConfig(baseURL: url, token: nil, notificationKeyMaterial: nil, updatedAt: Date())
    }

    private func handlePerformanceDegradation() async {
        scheduleRetentionPrune()
    }

    func resolvedAutoCleanupEnabled() async -> Bool {
        let stored = await dataStore.loadAutoCleanupPreference()
        let defaultEnabled = true
        if stored == nil {
            await dataStore.saveAutoCleanupPreference(defaultEnabled)
        }
        return stored ?? defaultEnabled
    }

    func setChannelAutoCleanupEnabled(channelId: String, isEnabled: Bool) async throws {
        guard let gatewayKey = serverConfig?.gatewayKey else { throw AppError.noServer }
        _ = try await dataStore.setChannelAutoCleanupEnabled(
            gateway: gatewayKey,
            channelId: channelId,
            isEnabled: isEnabled
        )
        await refreshChannelSubscriptions()
    }

    private func registerDefaultNotificationCategories() {
        let actions = [
            UNNotificationAction(
                identifier: AppConstants.actionDeleteIdentifier,
                title: LocalizationManager.localizedSync("delete"),
                options: [.destructive]
            ),
        ]

        let categories = AppConstants.nceCategories.map {
            UNNotificationCategory(
                identifier: $0,
                actions: actions,
                intentIdentifiers: [],
                options: []
            )
        }
        UNUserNotificationCenter.current().setNotificationCategories(Set(categories))
    }

    func updateServerConfig(_ config: ServerConfig?) async throws {
        let normalized = config?.normalized()
        try await dataStore.saveServerConfig(normalized)
        serverConfig = normalized
        await refreshChannelSubscriptions()
    }

    func replaceMessages(_ newMessages: [PushMessage]) async {
        do {
            let sanitized = newMessages.map { message in
                var copy = message
                copy.url = URLSanitizer.sanitizeHTTPSURL(message.url)
                return copy
            }
            try await dataStore.saveMessages(sanitized.sorted { $0.receivedAt > $1.receivedAt })
            await refreshMessageCountsAndNotify()
            scheduleRetentionPrune()
        } catch {
            showToast(message: localizationManager.localized(
                "failed_to_save_message_placeholder",
                error.localizedDescription,
            ))
        }
    }

    func reloadMessagesFromStore() async {
        await refreshMessageCountsAndNotify()
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

    func refreshChannelSubscriptions() async {
        await MainActor.run {
            channelSubscriptions = []
            channelSubscriptionLookup = [:]
        }
    }

    func refreshDefaultRingtoneFromStore() async {
        let stored = await dataStore.loadDefaultRingtoneFilename()
        let trimmed = stored?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let resolved = trimmed.isEmpty ? AppConstants.fallbackRingtoneFilename : trimmed
        defaultRingtoneFilename = resolved
        if trimmed.isEmpty {
            await dataStore.saveDefaultRingtoneFilename(resolved)
        }
    }

    func applyDefaultRingtoneFilenameFromPhone(_ filename: String?) async {
        let trimmed = filename?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let resolved = trimmed.isEmpty ? AppConstants.fallbackRingtoneFilename : trimmed
        defaultRingtoneFilename = resolved
        await dataStore.saveDefaultRingtoneFilename(resolved)
    }

    func channelDisplayName(for channelId: String?) -> String? {
        let trimmed = channelId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return nil }
        if let match = channelSubscriptionLookup[trimmed] {
            return match.displayName
        }
        return trimmed
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
        #if canImport(UIKit) && !os(watchOS)
        UIAccessibility.post(notification: .announcement, argument: message)
        #endif
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

    func applyNotificationKeyMaterialFromPhone(data: Data?, isPresent: Bool) async {
        let material: ServerConfig.NotificationKeyMaterial?
        if isPresent, let data, !data.isEmpty {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            material = try? decoder.decode(ServerConfig.NotificationKeyMaterial.self, from: data)
        } else {
            material = nil
        }

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
        try? await updateServerConfig(config)
    }

    func applyChannelSubscriptionsFromPhone(_ subscriptions: [ChannelSubscription]) async {
        channelSubscriptions = subscriptions
        channelSubscriptionLookup = Dictionary(uniqueKeysWithValues: subscriptions.map { ($0.channelId, $0) })
        await persistChannelSubscriptions(subscriptions)
    }

    private func persistChannelSubscriptions(_ subscriptions: [ChannelSubscription]) async {
        do {
            let existing = try await dataStore.loadChannelSubscriptions(includeDeleted: true)
            let incomingKeys = Set(subscriptions.map { subscription in
                makeChannelKey(
                    gateway: resolveGateway(subscription.gateway),
                    channelId: subscription.channelId
                )
            })
            for subscription in subscriptions {
                let trimmedId = subscription.channelId.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmedId.isEmpty else { continue }
                let resolvedGateway = resolveGateway(subscription.gateway)
                guard !resolvedGateway.isEmpty else { continue }
                let trimmedName = subscription.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
                let resolvedName = trimmedName.isEmpty ? trimmedId : trimmedName
                try await dataStore.upsertChannelSubscription(
                    gateway: resolvedGateway,
                    channelId: trimmedId,
                    displayName: resolvedName,
                    password: nil,
                    lastSyncedAt: subscription.lastSyncedAt,
                    updatedAt: subscription.updatedAt,
                    isDeleted: false,
                    deletedAt: nil
                )
            }

            let deletedAt = Date()
            for item in existing {
                let itemKey = makeChannelKey(
                    gateway: resolveGateway(item.gateway),
                    channelId: item.channelId
                )
                guard incomingKeys.contains(itemKey) == false else { continue }
                let trimmedId = item.channelId.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmedId.isEmpty else { continue }
                try await dataStore.softDeleteChannelSubscription(
                    gateway: resolveGateway(item.gateway),
                    channelId: trimmedId,
                    deletedAt: deletedAt
                )
            }
        } catch {
        }
    }

    private func resolveGateway(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return trimmed
        }
        return serverConfig?.gatewayKey ?? ""
    }

    private func makeChannelKey(gateway: String, channelId: String) -> String {
        "\(gateway)|\(channelId)"
    }

    var currentNotificationMaterial: ServerConfig.NotificationKeyMaterial? {
        serverConfig?.notificationKeyMaterial
    }

    private func loadPersistedState() async {
        var bootstrapErrors: [String] = []
        let storeState = dataStore.storageState
        switch storeState.mode {
        case .inMemory:
            bootstrapErrors.append(localizationManager.localized("local_store_in_memory_fallback"))
        case .unavailable:
            bootstrapErrors.append(localizationManager.localized("local_store_unavailable"))
        case .persistent:
            break
        }
        do {
            serverConfig = try await dataStore.loadServerConfig()?.normalized()
        } catch {
            serverConfig = nil
            bootstrapErrors.append(localizationManager.localized("server_configuration_read_failed"))
        }

        if serverConfig == nil, let defaultConfig = Self.makeDefaultServerConfig() {
            let normalized = defaultConfig.normalized()
            serverConfig = normalized
            do {
                try await dataStore.saveServerConfig(normalized)
            } catch {
                bootstrapErrors.append(localizationManager.localized(
                    "failed_to_save_server_configuration_placeholder",
                    error.localizedDescription
                ))
            }
        }

        do {
            let counts = try await dataStore.messageCounts()
            totalMessageCount = counts.total
            unreadMessageCount = counts.unread
            syncBadgeWithUnreadCount()
        } catch {
            totalMessageCount = 0
            unreadMessageCount = 0
            bootstrapErrors.append(localizationManager.localized("failed_to_read_historical_messages"))
        }

        if !bootstrapErrors.isEmpty {
            let listFormatter = ListFormatter()
            listFormatter.locale = localizationManager.swiftUILocale
            let mergedReasons = listFormatter.string(from: bootstrapErrors) ?? bootstrapErrors.joined(separator: "、")
            showToast(message: localizationManager.localized("initialization_failed_placeholder", mergedReasons))
        }
        await refreshChannelSubscriptions()
        scheduleRetentionPrune()
    }

    func refreshPushAuthorization(requestAuthorization: Bool = false) async {
        do {
            if requestAuthorization {
                try await pushRegistrationService.requestAuthorization()
            } else {
                await pushRegistrationService.refreshAuthorizationStatus()
                if pushRegistrationService.authorizationState == .notDetermined {
                    try await pushRegistrationService.requestAuthorization()
                }
            }

            guard pushRegistrationService.authorizationState == .authorized else {
                throw AppError.apnsDenied
            }

            Task(priority: .utility) { @MainActor [weak self] in
                await self?.syncWatchTokenToPhone()
            }
        } catch let appError as AppError {
            showToast(message: appError.errorDescription ?? localizationManager
                .localized("unable_to_obtain_apns_token"))
        } catch {
            showToast(message: localizationManager.localized(
                "unable_to_obtain_apns_token_placeholder",
                error.localizedDescription,
            ))
        }
    }

    func syncWatchTokenToPhone() async {
        requestRemoteNotificationsIfNeeded()
        do {
            let token = try await pushRegistrationService.awaitToken()
            WatchTokenMessenger.shared.sendTokenToPhone(token)
        } catch {
        }
    }

    func syncSubscriptionsIfNeeded() async throws {
    }

    private func preparePushInfrastructure() async {
        await pushRegistrationService.refreshAuthorizationStatus()

        if pushRegistrationService.authorizationState == .notDetermined {
            do {
                try await pushRegistrationService.requestAuthorization()
            } catch {
                showToast(message: localizationManager.localized(
                    "request_for_notification_permission_failed_placeholder",
                    error.localizedDescription,
                ))
                return
            }
        }

        await refreshPushAuthorization(requestAuthorization: false)
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
            Task { @MainActor in
                await syncWatchTokenToPhone()
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

    func shouldPresentForegroundNotification() -> Bool {
        !shouldSuppressForegroundNotifications
    }

    func updateLaunchAtLogin(isEnabled: Bool) {
        Task { @MainActor in
            await dataStore.saveLaunchAtLoginPreference(isEnabled)
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

    private func scheduleRetentionPrune() {
        pendingRetentionTask?.cancel()
        pendingRetentionTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            await self?.enforceRetentionLimits()
        }
    }

    private func enforceRetentionLimits() async {
        let cutoff = Calendar.current.date(byAdding: .day, value: -retentionDays, to: Date())
        _ = try? await messageStateCoordinator.deleteMessages(readState: nil, before: cutoff)
        await messageStateCoordinator.pruneMessagesIfNeeded(
            maxCount: maxStoredMessages,
            batchSize: retentionBatchSize
        )
    }

    private func syncBadgeWithUnreadCount() {
        BadgeManager.syncAppBadge(unreadCount: unreadMessageCount)
    }

    func removeDeliveredNotificationIfNeeded(for message: PushMessage) {
        guard message.isRead, let identifier = message.notificationRequestId else { return }
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [identifier])
    }

    func requestRemoteNotificationsIfNeeded() {
        WKExtension.shared().registerForRemoteNotifications()
    }
    func persistNotificationIfNeeded(_ notification: UNNotification) async {
        let request = notification.request
        let requestId = request.identifier

        let receivedAt = Date()
        let content = request.content
        let normalized = NotificationPayloadNormalizer.normalize(content: content, requestId: requestId)
        let messageId = normalized.messageId
        if let messageId {
            if let _ = try? await dataStore.loadMessage(messageId: messageId) {
                return
            }
        } else {
            do {
                if let _ = try await dataStore.loadMessage(notificationRequestId: requestId) {
                    return
                }
            } catch {
            }
        }

        let message = PushMessage(
            messageId: messageId,
            title: normalized.title,
            body: normalized.body,
            channel: normalized.channel,
            url: normalized.url,
            isRead: false,
            receivedAt: receivedAt,
            rawPayload: normalized.rawPayload,
            status: .normal,
            decryptionState: normalized.decryptionState,
        )

        do {
            try await dataStore.saveMessage(message)
            scheduleCountsRefresh()
            scheduleRetentionPrune()
        } catch {
        }
    }
    func handleNotificationOpen(notificationRequestId: String) async {
        await handleNotificationOpenInternal(
            notificationRequestId: notificationRequestId,
            markAsReadInStore: true,
            removeFromNotificationCenter: true
        )
    }

    func handleNotificationOpen(messageId: UUID) async {
        await handleNotificationOpenInternal(
            messageId: messageId,
            markAsReadInStore: true,
            removeFromNotificationCenter: true
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
            guard let target = try await dataStore.loadMessage(notificationRequestId: notificationRequestId) else {
                return
            }
            await handleNotificationOpenTarget(
                target,
                markAsReadInStore: markAsReadInStore,
                removeFromNotificationCenter: removeFromNotificationCenter
            )
        } catch {
            showToast(message: localizationManager.localized(
                "sync_message_failed_placeholder",
                error.localizedDescription
            ))
        }
    }

    private func handleNotificationOpenInternal(
        messageId: UUID,
        markAsReadInStore: Bool,
        removeFromNotificationCenter: Bool
    ) async {
        do {
            guard let target = try await dataStore.loadMessage(messageId: messageId) else {
                return
            }
            await handleNotificationOpenTarget(
                target,
                markAsReadInStore: markAsReadInStore,
                removeFromNotificationCenter: removeFromNotificationCenter
            )
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

        pendingMessageToOpen = targetId
    }

    private func clearDeliveredSystemNotifications() {
    }

    private var shouldSuppressForegroundNotifications: Bool {
        isSceneActive && activeMainTab == .messages && isMessageListAtTop
    }

    private var canRefreshMessageList: Bool {
        isSceneActive && isMainWindowVisible
    }

    private func flushPendingMessageListRefreshIfNeeded() {
        guard pendingMessageListRefresh, canRefreshMessageList else { return }
        messageStoreRevision = UUID()
        pendingMessageListRefresh = false
    }

}

@MainActor
private final class WatchTokenMessenger: NSObject, WCSessionDelegate {
    static let shared = WatchTokenMessenger()

    private let session: WCSession? = WCSession.isSupported() ? WCSession.default : nil
    private var isActivated = false

    private override init() {
        super.init()
        session?.delegate = self
    }

    func sendTokenToPhone(_ token: String) {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        activateIfNeeded()
        guard let session else { return }

        let payload: [String: Any] = ["watch_apns_token": trimmed]
        do {
            try session.updateApplicationContext(payload)
        } catch {
        }
        if session.isReachable {
            session.sendMessage(payload, replyHandler: nil, errorHandler: nil)
        }
    }

    private func activateIfNeeded() {
        guard let session, !isActivated else { return }
        session.activate()
        isActivated = true
    }

    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        _ = (session, activationState, error)
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        _ = session
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveApplicationContext applicationContext: [String: Any]
    ) {
        handlePayload(applicationContext)
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveMessage message: [String: Any]
    ) {
        handlePayload(message)
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveUserInfo userInfo: [String: Any]
    ) {
        handlePayload(userInfo)
    }

    private nonisolated func handlePayload(_ payload: [String: Any]) {
        if let isPresent = payload["notification_key_material_present"] as? Bool {
            let data = payload["notification_key_material"] as? Data
            Task { @MainActor in
                await AppEnvironment.shared.applyNotificationKeyMaterialFromPhone(
                    data: data,
                    isPresent: isPresent
                )
            }
        }

        if let data = payload["channel_subscriptions"] as? Data, !data.isEmpty {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            if let subscriptions = try? decoder.decode([ChannelSubscription].self, from: data) {
                Task { @MainActor in
                    await AppEnvironment.shared.applyChannelSubscriptionsFromPhone(subscriptions)
                }
            }
        }

        if let filename = payload["default_ringtone_filename"] as? String {
            Task { @MainActor in
                await AppEnvironment.shared.applyDefaultRingtoneFilenameFromPhone(filename)
            }
        }
    }
}
