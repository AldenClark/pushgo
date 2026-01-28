import Foundation
import Observation
import ServiceManagement
import SwiftUI
import UserNotifications
#if canImport(AppKit)
import AppKit
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

    private var toastDismissTask: Task<Void, Never>?
    @ObservationIgnored private let countsRefreshDelay: TimeInterval = 0.4
    @ObservationIgnored private let messageListRefreshDelay: TimeInterval = 0.35
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
        Task.detached(priority: .utility) {
            Self.syncBuiltInRingtonesToAppGroup()
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

    private nonisolated static func syncBuiltInRingtonesToAppGroup() {
        let fileManager = FileManager.default
        guard let containerURL = fileManager.containerURL(
            forSecurityApplicationGroupIdentifier: AppConstants.appGroupIdentifier
        ) else {
            return
        }

        let soundsDirectory = containerURL.appendingPathComponent(
            AppConstants.customRingtoneRelativePath,
            isDirectory: true
        )
        if !fileManager.fileExists(atPath: soundsDirectory.path) {
            do {
                try fileManager.createDirectory(at: soundsDirectory, withIntermediateDirectories: true)
            } catch {
                return
            }
        }

        let allowedExtensions = ["caf", "wav", "aif", "aiff"]
        var bundleSoundURLs: [URL] = []
        for fileExtension in allowedExtensions {
            if let urls = Bundle.main.urls(forResourcesWithExtension: fileExtension, subdirectory: nil) {
                bundleSoundURLs.append(contentsOf: urls)
            }
            if let urls = Bundle.main.urls(forResourcesWithExtension: fileExtension, subdirectory: "Sounds") {
                bundleSoundURLs.append(contentsOf: urls)
            }
        }
        if bundleSoundURLs.isEmpty {
            return
        }

        var seenFilenames = Set<String>()
        for url in bundleSoundURLs {
            let filename = url.lastPathComponent
            guard !filename.isEmpty else { continue }
            if !seenFilenames.insert(filename).inserted {
                continue
            }
            let destinationURL = soundsDirectory.appendingPathComponent(filename)
            if fileManager.fileExists(atPath: destinationURL.path) {
                continue
            }
            try? fileManager.copyItem(at: url, to: destinationURL)
        }
    }

    private static func makeDefaultServerConfig() -> ServerConfig? {
        guard let url = AppConstants.defaultServerURL else { return nil }
        return ServerConfig(baseURL: url, token: nil, notificationKeyMaterial: nil, updatedAt: Date())
    }

    private func handlePerformanceDegradation() async {
        let stored = await dataStore.loadAutoCleanupPreference()
        let defaultEnabled = false
        let isEnabled = stored ?? defaultEnabled
        if stored == nil {
            await dataStore.saveAutoCleanupPreference(defaultEnabled)
        }

        if isEnabled {
            let excludedChannels = channelSubscriptions
                .filter { !$0.autoCleanupEnabled }
                .map { $0.channelId }
            _ = (try? await messageStateCoordinator.deleteOldestReadMessages(
                limit: AppConstants.autoCleanupBatchSize,
                excludingChannels: excludedChannels
            )) ?? 0
            showToast(
                message: localizationManager.localized("auto_cleanup_manual_suggestion"),
                style: .info,
                duration: 2.5
            )
            return
        }

        showToast(
            message: localizationManager.localized("auto_cleanup_suggestion"),
            style: .info,
            duration: 2.5
        )
    }

    func resolvedAutoCleanupEnabled() async -> Bool {
        let stored = await dataStore.loadAutoCleanupPreference()
        let defaultEnabled = false
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
                identifier: AppConstants.actionCopyIdentifier,
                title: LocalizationManager.localizedSync("copy_content"),
                options: [.foreground]
            ),
            UNNotificationAction(
                identifier: AppConstants.actionMarkReadIdentifier,
                title: LocalizationManager.localizedSync("mark_as_read"),
                options: []
            ),
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

    private func syncLaunchAtLoginPreferenceIfNeeded() async {
        let stored = await dataStore.loadLaunchAtLoginPreference()
        let shouldEnable = stored ?? true
        if stored == nil {
            await dataStore.saveLaunchAtLoginPreference(true)
        }
        applyLaunchAtLoginPreference(shouldEnable)
    }

    func updateLaunchAtLogin(isEnabled: Bool) {
        Task { @MainActor in
            await dataStore.saveLaunchAtLoginPreference(isEnabled)
        }
        applyLaunchAtLoginPreference(isEnabled)
    }

    private func applyLaunchAtLoginPreference(_ isEnabled: Bool) {
        guard #available(macOS 13.0, *) else { return }
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

    func addLocalMessage(
        title: String,
        body: String,
        channel: String?,
        url: URL?,
        rawPayload: [String: Any],
        decryptionState: PushMessage.DecryptionState? = nil,
        messageId: UUID? = nil,
    ) async {
        if let messageId {
            do {
                if let _ = try await dataStore.loadMessage(messageId: messageId) {
                    return
                }
            } catch {
            }
        }

        var payload = rawPayload
        if payload["title"] == nil {
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
        let sanitizedURL = URLSanitizer.sanitizeHTTPSURL(url)
        if let sanitizedURL, payload["url"] == nil {
            payload["url"] = sanitizedURL.absoluteString
        }

        let mappedPayload = payload.reduce(into: [String: AnyCodable]()) { result, element in
            result[element.key] = AnyCodable(element.value)
        }

        let channel = ((payload["channel_id"] as? String)
            ?? (payload["channel"] as? String))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedChannel = channel?.isEmpty == true ? nil : channel

        let message = PushMessage(
            messageId: messageId,
            title: title,
            body: body,
            channel: resolvedChannel,
            url: sanitizedURL,
            isRead: false,
            receivedAt: Date(),
            rawPayload: mappedPayload,
            status: .normal,
            decryptionState: decryptionState,
        )
        do {
            try await dataStore.saveMessage(message)
            await refreshMessageCountsAndNotify()
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
        #if canImport(AppKit)
        NSAccessibility.post(
            element: NSApplication.shared,
            notification: .announcementRequested,
            userInfo: [NSAccessibility.NotificationUserInfoKey.announcement: message]
        )
        #endif
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
                await self?.syncSubscriptionsOnLaunch()
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

    private func syncSubscriptionsOnLaunch() async {
        do {
            try await syncSubscriptionsIfNeeded()
        } catch let appError as AppError {
            showToast(message: appError.errorDescription ?? localizationManager
                .localized("unable_to_sync_channels"))
        } catch {
            showToast(message: localizationManager.localized(
                "unable_to_sync_channels_placeholder",
                error.localizedDescription,
            ))
        }
    }

    private func ensureActivePushToken(serverConfig: ServerConfig) async throws -> String {
        let token = try await pushRegistrationService.awaitToken()
        let platform = platformIdentifier()
        let cached = await dataStore.cachedPushToken(for: platform)
        if let cached, cached != token {
            _ = try? await channelSubscriptionService.retire(
                baseURL: serverConfig.baseURL,
                token: serverConfig.token,
                deviceToken: cached,
                platform: platform
            )
        }
        await dataStore.saveCachedPushToken(token, for: platform)
        return token
    }

    private func resolvedDeviceTokens(primaryToken: String) -> [ChannelSubscriptionService.DeviceTokenRegistration] {
        [
            .init(deviceToken: primaryToken, platform: platformIdentifier()),
        ]
    }

    func syncSubscriptionsIfNeeded() async throws {
        guard let config = serverConfig else { throw AppError.noServer }
        let gatewayKey = config.gatewayKey
        let token = try await ensureActivePushToken(serverConfig: config)
        let deviceTokens = resolvedDeviceTokens(primaryToken: token)

        let credentials = try await dataStore.activeChannelCredentials(gateway: gatewayKey)
        let channels = credentials.map {
            ChannelSubscriptionService.SyncItem(channelId: $0.channelId, password: $0.password)
        }
        guard !channels.isEmpty else {
            await refreshChannelSubscriptions()
            return
        }

        let payload = try await channelSubscriptionService.sync(
            baseURL: config.baseURL,
            token: config.token,
            deviceTokens: deviceTokens,
            channels: channels
        )

        let syncedAt = Date()
        var staleChannels: [String] = []
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
            } else if result.errorCode == "channel_not_found" {
                staleChannels.append(result.channelId)
            }
        }
        for channelId in staleChannels {
            try? await dataStore.softDeleteChannelSubscription(
                gateway: gatewayKey,
                channelId: channelId
            )
        }
        await refreshChannelSubscriptions()
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

    private func loadPersistedState() async {
        await syncLaunchAtLoginPreferenceIfNeeded()
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

    func updateDefaultRingtoneFilename(_ filename: String?) async {
        await dataStore.saveDefaultRingtoneFilename(filename)
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

        let payload = try await channelSubscriptionService.subscribe(
            baseURL: config.baseURL,
            token: config.token,
            channelId: channelId,
            channelName: alias,
            password: validatedPassword,
            deviceTokens: resolvedDeviceTokens(primaryToken: token)
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
        return payload
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

        _ = try await channelSubscriptionService.unsubscribe(
            baseURL: config.baseURL,
            token: config.token,
            channelId: normalized,
            deviceTokens: resolvedDeviceTokens(primaryToken: token)
        )

        try await dataStore.softDeleteChannelSubscription(gateway: gatewayKey, channelId: normalized)
        await refreshChannelSubscriptions()

        guard deleteLocalMessages else { return 0 }
        return try await messageStateCoordinator.deleteMessages(channel: normalized, readState: nil)
    }

    func handlePushTokenUpdate() {
        Task { @MainActor in
            do {
                try await syncSubscriptionsIfNeeded()
            } catch {
                let message = (error as? AppError)?.errorDescription ?? error.localizedDescription
                showToast(message: localizationManager.localized(
                    "unable_to_sync_channels_placeholder",
                    message
                ))
            }
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
    func persistNotificationIfNeeded(_ notification: UNNotification) async {
        let request = notification.request
        let requestId = request.identifier

        do {
            if let _ = try await dataStore.loadMessage(notificationRequestId: requestId) {
                return
            }
        } catch {
        }

        let receivedAt = Date()
        let content = request.content
        let normalized = NotificationPayloadNormalizer.normalize(content: content, requestId: requestId)
        let messageId = normalized.messageId
        if let messageId {
            do {
                if let _ = try await dataStore.loadMessage(messageId: messageId) {
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
        isMainWindowVisible
    }

    private func flushPendingMessageListRefreshIfNeeded() {
        guard pendingMessageListRefresh, canRefreshMessageList else { return }
        messageStoreRevision = UUID()
        pendingMessageListRefresh = false
    }

}
