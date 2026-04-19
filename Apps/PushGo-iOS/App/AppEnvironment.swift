import Foundation
import Darwin
@preconcurrency import Network
import Observation
import SwiftUI
import UserNotifications
import UIKit

@MainActor
@Observable
final class AppEnvironment {
    enum SettingsPresentationRequest: String, Identifiable {
        case settings
        case decryption

        var id: String { rawValue }
    }

    enum WatchModeSwitchRequestResult: Equatable {
        case applied
        case timedOut
    }

    private struct WatchControlSemanticState: Equatable {
        let mode: WatchMode
        let mirrorSnapshotGeneration: Int64
        let standaloneProvisioningGeneration: Int64
        let pendingMirrorActionAckGeneration: Int64
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
    @ObservationIgnored private var pendingCountsRefreshTask: Task<Void, Never>?
    @ObservationIgnored private var pendingMessageListRefreshTask: Task<Void, Never>?
    @ObservationIgnored private var bootstrapTask: Task<Void, Never>?
    @ObservationIgnored private var didBootstrap = false
    @ObservationIgnored private var providerRouteTask: Task<String, Error>?
    @ObservationIgnored private var providerRouteTaskKey: String?

    private var toastDismissTask: Task<Void, Never>?
    @ObservationIgnored private var pendingMessageListRefresh = false
    @ObservationIgnored private var isMainWindowVisible = true
    @ObservationIgnored private var lastWakeupRouteFingerprint: String?
    @ObservationIgnored private var pendingWatchMirrorSnapshotTask: Task<Void, Never>?
    @ObservationIgnored private var pendingWatchProvisioningTask: Task<Void, Never>?
    @ObservationIgnored private var pendingWatchMirrorSnapshotAckRetryTask: Task<Void, Never>?
    @ObservationIgnored private var pendingWatchStandaloneProvisioningAckRetryTask: Task<Void, Never>?
    @ObservationIgnored private var pendingWatchModeReplayTask: Task<Void, Never>?
    @ObservationIgnored private let watchSyncDebounceDelay: TimeInterval = 0.5
    @ObservationIgnored private let watchMirrorSnapshotAckRetryDelay: TimeInterval = 5
    @ObservationIgnored private let watchMirrorSnapshotAckRetryAttempts = 6
    @ObservationIgnored private let watchStandaloneProvisioningAckRetryDelay: TimeInterval = 5
    @ObservationIgnored private let watchStandaloneProvisioningAckRetryAttempts = 6
    @ObservationIgnored private let watchModeReplayDelay: TimeInterval = 2
    @ObservationIgnored private let watchModeReplayAttempts = 5
    @ObservationIgnored private let watchModeConfirmationTimeout: TimeInterval = 12
    @ObservationIgnored private var watchControlGeneration: Int64 = 0
    @ObservationIgnored private var watchMirrorSnapshotGeneration: Int64 = 0
    @ObservationIgnored private var watchStandaloneProvisioningGeneration: Int64 = 0
    @ObservationIgnored private var watchMirrorActionAckGeneration: Int64 = 0
    @ObservationIgnored private var lastConfirmedWatchModeControlGeneration: Int64 = 0
    @ObservationIgnored private var lastObservedWatchModeControlGeneration: Int64 = 0
    @ObservationIgnored private var lastObservedWatchStandaloneReadinessReportedAt = Date.distantPast
    @ObservationIgnored private var lastPublishedWatchControlSemanticState: WatchControlSemanticState?
    @ObservationIgnored private var lastPublishedWatchMirrorSnapshotDigest: String?
    @ObservationIgnored private var lastPublishedWatchStandaloneProvisioningDigest: String?
    @ObservationIgnored private var lastWatchMirrorSnapshotAck: WatchMirrorSnapshotAck?
    @ObservationIgnored private var lastWatchMirrorSnapshotNack: WatchMirrorSnapshotNack?
    @ObservationIgnored private var lastWatchStandaloneProvisioningAck: WatchStandaloneProvisioningAck?
    @ObservationIgnored private var lastWatchStandaloneProvisioningNack: WatchStandaloneProvisioningNack?

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
    private(set) var activeMainTab: MainTab = .messages
    private(set) var isMessageListAtTop: Bool = false
    private(set) var isEventListAtTop: Bool = false
    private(set) var isThingListAtTop: Bool = false
    private(set) var watchMode: WatchMode = .mirror
    private(set) var effectiveWatchMode: WatchMode = .mirror
    private(set) var standaloneReady = false
    private(set) var watchModeSwitchStatus: WatchModeSwitchStatus = .idle
    private(set) var isWatchCompanionAvailable: Bool = false
    var pendingSettingsPresentation: SettingsPresentationRequest?
    private(set) var channelSubscriptions: [ChannelSubscription] = []
    private var channelSubscriptionLookup: [String: ChannelSubscription] = [:]
    private var isSceneActive = false

    private let channelSubscriptionService = ChannelSubscriptionService()
    private let networkPermissionChecker = NetworkPermissionChecker()
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

    private func nextWatchGeneration() -> Int64 {
        Int64((Date().timeIntervalSince1970 * 1_000_000).rounded())
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
        let previousDeviceKey = await dataStore.cachedDeviceKey(
            for: platformIdentifier(),
            channelType: "apns"
        )?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = config?.normalized()
        try await dataStore.saveServerConfig(normalized)
        serverConfig = normalized
        await refreshChannelSubscriptions(syncWatch: false)
        requestWatchStandaloneProvisioningSync(immediate: true)
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
            requestWatchMirrorSnapshotSync()
        } catch {
            totalMessageCount = 0
            unreadMessageCount = 0
            BadgeManager.syncAppBadge(unreadCount: 0)
            scheduleMessageListRefresh()
            requestWatchMirrorSnapshotSync()
        }
    }

    func refreshChannelSubscriptions(syncWatch: Bool = true, immediateStandalone: Bool = false) async {
        guard let gatewayKey = serverConfig?.gatewayKey else {
            await MainActor.run {
                channelSubscriptions = []
                channelSubscriptionLookup = [:]
            }
            if syncWatch {
                requestWatchStandaloneProvisioningSync(immediate: immediateStandalone)
            }
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
            await MainActor.run {
                channelSubscriptions = active
                channelSubscriptionLookup = Dictionary(uniqueKeysWithValues: all.map { ($0.channelId, $0) })
            }
            if syncWatch {
                requestWatchStandaloneProvisioningSync(immediate: immediateStandalone)
            }
        } catch {
            await MainActor.run {
                channelSubscriptions = []
                channelSubscriptionLookup = [:]
            }
            if syncWatch {
                requestWatchStandaloneProvisioningSync(immediate: immediateStandalone)
            }
        }
        await syncPrivateChannelState()
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
                await dataStore.saveCachedDeviceKey(
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

        guard deleteLocalMessages else { return 0 }
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
                if serverConfig != nil {
                    try await syncSubscriptionsIfNeeded()
                }
                if let config = serverConfig,
                   let token = await dataStore.cachedPushToken(for: platformIdentifier())?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !token.isEmpty
                {
                    await syncProviderPullRoute(config: config, providerToken: token)
                    _ = await syncProviderIngress(reason: "token_update")
                }
            } catch {
                let message = (error as? AppError)?.errorDescription ?? error.localizedDescription
                showToast(message: localizationManager.localized(
                    "unable_to_sync_channels_placeholder",
                    message
                ))
            }
        }
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
        pendingCountsRefreshTask?.cancel()
        pendingCountsRefreshTask = Task { @MainActor [weak self] in
            await self?.refreshMessageCountsAndNotify()
        }
    }

    private func scheduleMessageListRefresh() {
        guard canRefreshMessageList else {
            pendingMessageListRefresh = true
            return
        }
        pendingMessageListRefreshTask?.cancel()
        pendingMessageListRefreshTask = Task { @MainActor [weak self] in
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
            try? await Task.sleep(for: .seconds(duration))
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

    struct LocalStoreRecoveryState: Equatable {
        let title: String
        let message: String
        let canRebuild: Bool
    }

    private func announceAccessibility(_ message: String) {
        UIAccessibility.post(notification: .announcement, argument: message)
    }

    func dismissLocalStoreRecovery() {
        localStoreRecoveryState = nil
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
        Darwin.exit(0)
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
        guard serverConfig != nil else { return }
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
        guard serverConfig != nil else {
            await refreshChannelSubscriptions()
            return
        }
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
        guard !credentials.isEmpty else {
            await refreshChannelSubscriptions()
            return
        }
        let deviceKey = try await ensureProviderRoute(config: config, providerToken: token)
        let channels = credentials.map {
            ChannelSubscriptionService.SyncItem(channelId: $0.channelId, password: $0.password)
        }

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
        if await WatchTokenReceiver.shared.consumeForcedReconfigureFlag() {
            await resetWatchConnectivityStateForMigration()
        }
        let persistedWatchPublicationState = await dataStore.loadWatchPublicationState()
        let persistedWatchModeControlState = await dataStore.loadWatchModeControlState()
        watchControlGeneration = persistedWatchPublicationState.syncGenerations.controlGeneration
        watchMirrorSnapshotGeneration = persistedWatchPublicationState.syncGenerations.mirrorSnapshotGeneration
        watchStandaloneProvisioningGeneration = persistedWatchPublicationState.syncGenerations.standaloneProvisioningGeneration
        watchMirrorActionAckGeneration = persistedWatchPublicationState.syncGenerations.mirrorActionAckGeneration
        lastPublishedWatchMirrorSnapshotDigest = persistedWatchPublicationState.mirrorSnapshotContentDigest
        lastPublishedWatchStandaloneProvisioningDigest = persistedWatchPublicationState.standaloneProvisioningContentDigest
        watchMode = persistedWatchModeControlState.desiredMode
        effectiveWatchMode = persistedWatchModeControlState.effectiveMode
        standaloneReady = persistedWatchModeControlState.standaloneReady
        watchModeSwitchStatus = persistedWatchModeControlState.switchStatus
        lastConfirmedWatchModeControlGeneration = persistedWatchModeControlState.lastConfirmedControlGeneration
        lastObservedWatchModeControlGeneration = persistedWatchModeControlState.lastObservedReportedGeneration
        isWatchCompanionAvailable = WatchTokenReceiver.shared.refreshCompanionAvailability()
        if watchMode == .standalone, !isWatchCompanionAvailable {
            watchMode = .mirror
            effectiveWatchMode = .mirror
            standaloneReady = false
            watchModeSwitchStatus = .idle
            await persistWatchModeControlState()
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
        await refreshChannelSubscriptions(syncWatch: false)
        await publishWatchControlContext()
        if watchMode == .standalone {
            requestWatchStandaloneProvisioningSync(immediate: true)
        }
        requestWatchMirrorSnapshotSync(immediate: watchMode == .standalone)
        scheduleWatchModeReplayIfNeeded(reason: "bootstrap", immediate: true)
        requestNetworkPermissionOnLaunch()
    }

    func setWatchMode(_ mode: WatchMode) async {
        await applyDesiredWatchMode(mode, switchStatus: mode == effectiveWatchMode ? .confirmed : .switching)
    }

    func requestWatchModeChangeApplied(_ mode: WatchMode) async throws -> WatchModeSwitchRequestResult {
        await applyDesiredWatchMode(mode, switchStatus: mode == effectiveWatchMode ? .confirmed : .switching)
        guard watchMode != effectiveWatchMode else { return .applied }
        return try await awaitWatchModeConfirmation(
            expectedMode: mode,
            controlGeneration: watchControlGeneration
        )
    }

    func requestWatchModeChangeConfirmed(_ mode: WatchMode) async throws {
        let result = try await requestWatchModeChangeApplied(mode)
        if result == .timedOut {
            throw AppError.saveConfig(reason: "Apple Watch mode change was not confirmed. Please try again.")
        }
    }

    private func applyDesiredWatchMode(
        _ mode: WatchMode,
        switchStatus: WatchModeSwitchStatus
    ) async {
        let desiredChanged = watchMode != mode
        watchMode = mode
        standaloneReady = false
        watchModeSwitchStatus = switchStatus
        if mode != .mirror {
            cancelWatchMirrorSnapshotAckRetry()
        } else {
            cancelWatchStandaloneProvisioningAckRetry()
        }
        cancelWatchModeReplay()
        if desiredChanged || watchControlGeneration == 0 {
            watchControlGeneration = nextWatchGeneration()
        }
        await persistWatchModeControlState()
        await publishWatchControlContext(force: true)
        if mode == .standalone {
            requestWatchStandaloneProvisioningSync(immediate: true)
        }
        requestWatchMirrorSnapshotSync(immediate: true)
        scheduleWatchModeReplayIfNeeded(reason: "mode_change", immediate: false)
    }

    func handleWatchSessionStateDidChange() async {
        let latestAvailability = WatchTokenReceiver.shared.refreshCompanionAvailability()
        let availabilityChanged = latestAvailability != isWatchCompanionAvailable
        isWatchCompanionAvailable = latestAvailability
        if !isWatchCompanionAvailable {
            cancelWatchMirrorSnapshotAckRetry()
            cancelWatchStandaloneProvisioningAckRetry()
            cancelWatchModeReplay()
        }
        if watchMode == .standalone, !isWatchCompanionAvailable {
            effectiveWatchMode = .mirror
            standaloneReady = false
            watchModeSwitchStatus = .idle
            await setWatchMode(.mirror)
            return
        }
        if availabilityChanged {
            await publishWatchControlContext(force: true)
            if watchMode == .standalone {
                requestWatchStandaloneProvisioningSync(immediate: true)
            }
            requestWatchMirrorSnapshotSync(immediate: true)
            scheduleWatchModeReplayIfNeeded(reason: "session_state_changed", immediate: true)
        } else {
            WatchTokenReceiver.shared.replayLatestManifestIfPossible()
            scheduleWatchModeReplayIfNeeded(reason: "session_state_refresh", immediate: true)
        }
    }

    func refreshWatchCompanionAvailability() async {
        let latestAvailability = WatchTokenReceiver.shared.refreshCompanionAvailability()
        guard latestAvailability != isWatchCompanionAvailable else { return }
        isWatchCompanionAvailable = latestAvailability
        if watchMode == .standalone, !latestAvailability {
            effectiveWatchMode = .mirror
            standaloneReady = false
            watchModeSwitchStatus = .idle
            await setWatchMode(.mirror)
            return
        }
        scheduleWatchModeReplayIfNeeded(reason: "refresh_companion_availability", immediate: true)
    }

    private func resetWatchConnectivityStateForMigration() async {
        pendingWatchMirrorSnapshotTask?.cancel()
        pendingWatchProvisioningTask?.cancel()
        cancelWatchMirrorSnapshotAckRetry()
        cancelWatchStandaloneProvisioningAckRetry()
        cancelWatchModeReplay()
        watchMode = .mirror
        effectiveWatchMode = .mirror
        standaloneReady = false
        watchModeSwitchStatus = .idle
        watchControlGeneration = 0
        watchMirrorSnapshotGeneration = 0
        watchStandaloneProvisioningGeneration = 0
        watchMirrorActionAckGeneration = 0
        lastConfirmedWatchModeControlGeneration = 0
        lastObservedWatchModeControlGeneration = 0
        lastPublishedWatchControlSemanticState = nil
        lastPublishedWatchMirrorSnapshotDigest = nil
        lastPublishedWatchStandaloneProvisioningDigest = nil
        lastWatchMirrorSnapshotAck = nil
        lastWatchMirrorSnapshotNack = nil
        lastWatchStandaloneProvisioningAck = nil
        lastWatchStandaloneProvisioningNack = nil
        await persistWatchModeControlState()
        await dataStore.saveWatchPublicationState(.empty)
    }

    func handleWatchLatestManifestRequested() async {
        switch watchMode {
        case .mirror:
            if watchMirrorSnapshotGeneration == 0 {
                requestWatchMirrorSnapshotSync(immediate: true)
            } else {
                WatchTokenReceiver.shared.replayLatestManifestIfPossible()
            }
        case .standalone:
            if watchStandaloneProvisioningGeneration == 0 {
                requestWatchStandaloneProvisioningSync(immediate: true)
            } else {
                WatchTokenReceiver.shared.replayLatestManifestIfPossible()
            }
        }
    }

    func handleWatchStandaloneProvisioningAck(_ ack: WatchStandaloneProvisioningAck) async {
        if ack.generation == watchStandaloneProvisioningGeneration,
           let expectedDigest = lastPublishedWatchStandaloneProvisioningDigest,
           !ack.contentDigest.isEmpty,
           ack.contentDigest != expectedDigest
        {
            return
        }
        lastWatchStandaloneProvisioningAck = ack
        if ack.generation >= watchStandaloneProvisioningGeneration {
            cancelWatchStandaloneProvisioningAckRetry()
        }
    }

    func handleWatchMirrorSnapshotAck(_ ack: WatchMirrorSnapshotAck) async {
        if ack.generation == watchMirrorSnapshotGeneration,
           let expectedDigest = lastPublishedWatchMirrorSnapshotDigest,
           !ack.contentDigest.isEmpty,
           ack.contentDigest != expectedDigest
        {
            return
        }
        lastWatchMirrorSnapshotAck = ack
        if ack.generation >= watchMirrorSnapshotGeneration {
            cancelWatchMirrorSnapshotAckRetry()
        }
    }

    func handleWatchEffectiveModeStatus(_ status: WatchEffectiveModeStatus) async {
        guard status.sourceControlGeneration >= lastObservedWatchModeControlGeneration else { return }
        lastObservedWatchModeControlGeneration = status.sourceControlGeneration
        effectiveWatchMode = status.effectiveMode

        if status.status == .failed,
           status.sourceControlGeneration >= watchControlGeneration
        {
            watchModeSwitchStatus = .failed
            cancelWatchModeReplay()
            await persistWatchModeControlState()
            return
        }

        if status.effectiveMode == watchMode,
           status.status == .applied,
           status.sourceControlGeneration >= watchControlGeneration
        {
            lastConfirmedWatchModeControlGeneration = status.sourceControlGeneration
            watchModeSwitchStatus = .confirmed
            cancelWatchModeReplay()
            if watchMode == .mirror {
                standaloneReady = false
                requestWatchMirrorSnapshotSync(immediate: true)
            } else {
                requestWatchStandaloneProvisioningSync(immediate: true)
                requestWatchMirrorSnapshotSync(immediate: true)
            }
            await persistWatchModeControlState()
            return
        }

        if watchMode != effectiveWatchMode {
            if watchModeSwitchStatus != .failed,
               watchModeSwitchStatus != .timedOut {
                watchModeSwitchStatus = .switching
            }
            await persistWatchModeControlState()
            scheduleWatchModeReplayIfNeeded(reason: "effective_mode_mismatch", immediate: true)
            return
        }

        if watchMode == effectiveWatchMode,
           status.sourceControlGeneration < watchControlGeneration,
           (watchModeSwitchStatus == .switching || watchModeSwitchStatus == .timedOut)
        {
            await persistWatchModeControlState()
            scheduleWatchModeReplayIfNeeded(reason: "stale_mode_generation", immediate: true)
            return
        }

        if watchModeSwitchStatus != .confirmed,
           watchModeSwitchStatus != .timedOut
        {
            watchModeSwitchStatus = .idle
        }
        await persistWatchModeControlState()
    }

    func handleWatchStandaloneReadinessStatus(_ status: WatchStandaloneReadinessStatus) async {
        guard status.sourceControlGeneration >= watchControlGeneration else { return }
        guard status.reportedAt >= lastObservedWatchStandaloneReadinessReportedAt else { return }
        lastObservedWatchStandaloneReadinessReportedAt = status.reportedAt

        let nextReady = status.effectiveMode == .standalone && status.standaloneReady
        guard standaloneReady != nextReady || effectiveWatchMode != status.effectiveMode else {
            return
        }

        effectiveWatchMode = status.effectiveMode
        standaloneReady = nextReady

        if watchMode == .standalone {
            requestWatchMirrorSnapshotSync(immediate: !standaloneReady)
        }

        await persistWatchModeControlState()
    }

    func handleWatchMirrorSnapshotNack(_ nack: WatchMirrorSnapshotNack) async {
        lastWatchMirrorSnapshotNack = nack
        guard watchMode == .mirror, isWatchCompanionAvailable else { return }
        guard nack.generation >= watchMirrorSnapshotGeneration else { return }
        WatchTokenReceiver.shared.replayLatestManifestIfPossible()
    }

    func handleWatchStandaloneProvisioningNack(_ nack: WatchStandaloneProvisioningNack) async {
        lastWatchStandaloneProvisioningNack = nack
        guard watchMode == .standalone, isWatchCompanionAvailable else { return }
        guard nack.generation >= watchStandaloneProvisioningGeneration else { return }
        await publishWatchControlContext()
        requestWatchStandaloneProvisioningSync(immediate: true)
    }

    private var needsWatchModeReplay: Bool {
        guard isWatchCompanionAvailable else { return false }
        if watchMode != effectiveWatchMode {
            return true
        }
        return lastConfirmedWatchModeControlGeneration < watchControlGeneration
            && (watchModeSwitchStatus == .switching || watchModeSwitchStatus == .timedOut)
    }

    private func scheduleWatchModeReplayIfNeeded(
        reason: String,
        immediate: Bool
    ) {
        guard needsWatchModeReplay else {
            cancelWatchModeReplay()
            return
        }
        if let task = pendingWatchModeReplayTask, !task.isCancelled {
            if immediate {
                cancelWatchModeReplay()
            } else {
                return
            }
        }
        let delay = watchModeReplayDelay
        let attempts = watchModeReplayAttempts
        pendingWatchModeReplayTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for attempt in 0..<attempts {
                if !immediate || attempt > 0 {
                    do {
                        try await Task.sleep(for: .seconds(delay))
                    } catch {
                        return
                    }
                }
                guard self.isWatchCompanionAvailable,
                      self.needsWatchModeReplay
                else {
                    self.cancelWatchModeReplay()
                    return
                }
                await self.publishWatchControlContext(force: true)
                WatchTokenReceiver.shared.replayLatestManifestIfPossible()
            }
            guard self.needsWatchModeReplay else {
                self.cancelWatchModeReplay()
                return
            }
            self.watchModeSwitchStatus = .failed
            await self.persistWatchModeControlState()
            self.cancelWatchModeReplay()
            self.recordAutomationRuntimeMessage(
                "watch mode replay exhausted reason=\(reason)",
                source: "watch.mode_replay",
                category: "watch"
            )
        }
    }

    private func cancelWatchModeReplay() {
        pendingWatchModeReplayTask?.cancel()
        pendingWatchModeReplayTask = nil
    }

    private func awaitWatchModeConfirmation(
        expectedMode: WatchMode,
        controlGeneration: Int64
    ) async throws -> WatchModeSwitchRequestResult {
        let deadline = Date().addingTimeInterval(watchModeConfirmationTimeout)
        while Date() < deadline {
            if watchModeSwitchStatus == .confirmed,
               effectiveWatchMode == expectedMode,
               lastConfirmedWatchModeControlGeneration >= controlGeneration
            {
                return .applied
            }
            if watchModeSwitchStatus == .failed,
               watchControlGeneration == controlGeneration
            {
                throw AppError.saveConfig(reason: "Apple Watch mode switch failed.")
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
        watchModeSwitchStatus = .timedOut
        await persistWatchModeControlState()
        return .timedOut
    }

    private func currentWatchPublicationState() -> WatchPublicationState {
        WatchPublicationState(
            syncGenerations: WatchSyncGenerationState(
                controlGeneration: watchControlGeneration,
                mirrorSnapshotGeneration: watchMirrorSnapshotGeneration,
                standaloneProvisioningGeneration: watchStandaloneProvisioningGeneration,
                mirrorActionAckGeneration: watchMirrorActionAckGeneration
            ),
            mirrorSnapshotContentDigest: lastPublishedWatchMirrorSnapshotDigest,
            standaloneProvisioningContentDigest: lastPublishedWatchStandaloneProvisioningDigest
        )
    }

    private func currentWatchModeControlState() -> WatchModeControlPersistenceState {
        WatchModeControlPersistenceState(
            desiredMode: watchMode,
            effectiveMode: effectiveWatchMode,
            standaloneReady: standaloneReady,
            switchStatus: watchModeSwitchStatus,
            lastConfirmedControlGeneration: lastConfirmedWatchModeControlGeneration,
            lastObservedReportedGeneration: lastObservedWatchModeControlGeneration
        )
    }

    private func persistWatchPublicationState() async {
        await dataStore.saveWatchPublicationState(currentWatchPublicationState())
    }

    private func persistWatchModeControlState() async {
        await dataStore.saveWatchModeControlState(currentWatchModeControlState())
    }

    private func publishWatchControlContext(force: Bool = false) async {
        let semanticState = WatchControlSemanticState(
            mode: watchMode,
            mirrorSnapshotGeneration: watchMirrorSnapshotGeneration,
            standaloneProvisioningGeneration: watchStandaloneProvisioningGeneration,
            pendingMirrorActionAckGeneration: watchMirrorActionAckGeneration
        )
        guard force || semanticState != lastPublishedWatchControlSemanticState else { return }
        let context = WatchControlContext(
            mode: watchMode,
            controlGeneration: watchControlGeneration,
            mirrorSnapshotGeneration: watchMirrorSnapshotGeneration,
            standaloneProvisioningGeneration: watchStandaloneProvisioningGeneration,
            pendingMirrorActionAckGeneration: watchMirrorActionAckGeneration
        )
        lastPublishedWatchControlSemanticState = semanticState
        await persistWatchPublicationState()
        await persistWatchModeControlState()
        WatchTokenReceiver.shared.publishControlContext(context)
    }

    private func requestWatchMirrorSnapshotSync(immediate: Bool = false) {
        guard isWatchCompanionAvailable,
              (watchMode == .mirror || !standaloneReady)
        else {
            pendingWatchMirrorSnapshotTask?.cancel()
            return
        }
        pendingWatchMirrorSnapshotTask?.cancel()
        if immediate {
            pendingWatchMirrorSnapshotTask = Task { @MainActor [weak self] in
                await self?.publishWatchMirrorSnapshot()
            }
            return
        }
        let delay = watchSyncDebounceDelay
        pendingWatchMirrorSnapshotTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            await self?.publishWatchMirrorSnapshot()
        }
    }

    private func requestWatchStandaloneProvisioningSync(immediate: Bool) {
        guard watchMode == .standalone, isWatchCompanionAvailable else { return }
        pendingWatchProvisioningTask?.cancel()
        if immediate {
            pendingWatchProvisioningTask = Task { @MainActor [weak self] in
                await self?.publishWatchStandaloneProvisioning()
            }
            return
        }
        let delay = watchSyncDebounceDelay
        pendingWatchProvisioningTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            await self?.publishWatchStandaloneProvisioning()
        }
    }

    private func publishWatchMirrorSnapshot() async {
        do {
            let messages = try await dataStore.loadMessages()
            let eventMessages = try await dataStore.loadEventMessagesForProjection()
            let thingMessages = try await loadAllThingProjectionMessages()
            let generation = nextWatchGeneration()
            watchMirrorSnapshotGeneration = generation
            let snapshot = WatchLightQuantizer.buildMirrorSnapshot(
                messages: messages,
                eventMessages: eventMessages,
                thingMessages: thingMessages,
                generation: generation
            )
            lastPublishedWatchMirrorSnapshotDigest = snapshot.contentDigest
            WatchTokenReceiver.shared.sendMirrorSnapshot(snapshot)
            await publishWatchControlContext()
            scheduleWatchMirrorSnapshotAckRetry(for: generation)
        } catch {
            recordAutomationRuntimeError(error, source: "watch.publish_mirror_snapshot")
        }
    }

    private func scheduleWatchMirrorSnapshotAckRetry(for generation: Int64) {
        cancelWatchMirrorSnapshotAckRetry()
        guard watchMode == .mirror, isWatchCompanionAvailable else { return }
        let attempts = watchMirrorSnapshotAckRetryAttempts
        let delay = watchMirrorSnapshotAckRetryDelay
        pendingWatchMirrorSnapshotAckRetryTask = Task { @MainActor [weak self] in
            for _ in 0..<attempts {
                do {
                    try await Task.sleep(for: .seconds(delay))
                } catch {
                    return
                }
                guard let self else { return }
                guard self.watchMode == .mirror,
                      self.isWatchCompanionAvailable,
                      self.watchMirrorSnapshotGeneration == generation
                else {
                    return
                }
                if self.lastWatchMirrorSnapshotAck?.generation == generation {
                    self.cancelWatchMirrorSnapshotAckRetry()
                    return
                }
                WatchTokenReceiver.shared.replayLatestManifestIfPossible()
            }
        }
    }

    private func cancelWatchMirrorSnapshotAckRetry() {
        pendingWatchMirrorSnapshotAckRetryTask?.cancel()
        pendingWatchMirrorSnapshotAckRetryTask = nil
    }

    private func loadAllThingProjectionMessages() async throws -> [PushMessage] {
        let pageSize = 2000
        var cursor: EntityProjectionPageCursor?
        var accumulated: [PushMessage] = []
        while true {
            let page = try await dataStore.loadThingMessagesForProjectionPage(
                before: cursor,
                limit: pageSize
            )
            guard !page.isEmpty else { break }
            accumulated.append(contentsOf: page)
            cursor = page.last.map { EntityProjectionPageCursor(receivedAt: $0.receivedAt, id: $0.id) }
            if page.count < pageSize {
                break
            }
        }
        return accumulated
    }

    private func publishWatchStandaloneProvisioning() async {
        let sortedChannels = await currentStandaloneProvisioningChannels()
        let contentDigest = WatchStandaloneProvisioningSnapshot.contentDigest(
            serverConfig: serverConfig,
            notificationKeyMaterial: serverConfig?.notificationKeyMaterial,
            channels: sortedChannels
        )
        let shouldReuseGeneration =
            watchStandaloneProvisioningGeneration > 0 &&
            lastPublishedWatchStandaloneProvisioningDigest == contentDigest
        let generation = shouldReuseGeneration ? watchStandaloneProvisioningGeneration : nextWatchGeneration()
        watchStandaloneProvisioningGeneration = generation
        let snapshot = WatchStandaloneProvisioningSnapshot(
            generation: generation,
            mode: .standalone,
            serverConfig: serverConfig,
            notificationKeyMaterial: serverConfig?.notificationKeyMaterial,
            channels: sortedChannels,
            contentDigest: contentDigest
        )
        lastPublishedWatchStandaloneProvisioningDigest = snapshot.contentDigest
        WatchTokenReceiver.shared.sendStandaloneProvisioning(snapshot)
        await persistWatchPublicationState()
        await publishWatchControlContext()
        scheduleWatchStandaloneProvisioningAckRetry(for: generation)
    }

    private func currentStandaloneProvisioningChannels() async -> [WatchStandaloneChannelCredential] {
        let activeSubscriptions = (try? await dataStore.loadChannelSubscriptions(includeDeleted: false)) ?? []
        let fallbackGateway = serverConfig?.gatewayKey ?? ""
        let subscriptionsByGateway = Dictionary(
            grouping: activeSubscriptions,
            by: { subscription in
                let normalizedGateway = subscription.gateway.trimmingCharacters(in: .whitespacesAndNewlines)
                return normalizedGateway.isEmpty ? fallbackGateway : normalizedGateway
            }
        )
        var channels: [WatchStandaloneChannelCredential] = []
        for (gatewayKey, subscriptions) in subscriptionsByGateway {
            let normalizedGateway = gatewayKey.trimmingCharacters(in: .whitespacesAndNewlines)
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

    private func scheduleWatchStandaloneProvisioningAckRetry(for generation: Int64) {
        cancelWatchStandaloneProvisioningAckRetry()
        guard watchMode == .standalone, isWatchCompanionAvailable else { return }
        let attempts = watchStandaloneProvisioningAckRetryAttempts
        let delay = watchStandaloneProvisioningAckRetryDelay
        pendingWatchStandaloneProvisioningAckRetryTask = Task { @MainActor [weak self] in
            for _ in 0..<attempts {
                do {
                    try await Task.sleep(for: .seconds(delay))
                } catch {
                    return
                }
                guard let self else { return }
                guard self.watchMode == .standalone,
                      self.isWatchCompanionAvailable,
                      self.watchStandaloneProvisioningGeneration == generation
                else {
                    return
                }
                if self.lastWatchStandaloneProvisioningAck?.generation == generation {
                    self.cancelWatchStandaloneProvisioningAckRetry()
                    return
                }
                WatchTokenReceiver.shared.replayLatestManifestIfPossible()
            }
        }
    }

    private func cancelWatchStandaloneProvisioningAckRetry() {
        pendingWatchStandaloneProvisioningAckRetryTask?.cancel()
        pendingWatchStandaloneProvisioningAckRetryTask = nil
    }

    func applyWatchMirrorActionBatch(_ batch: WatchMirrorActionBatch) async {
        guard batch.mode == .mirror else { return }
        guard !batch.actions.isEmpty else { return }
        var ackedActionIds: [String] = []
        var handledActionIds: Set<String> = []
        for action in batch.actions {
            guard handledActionIds.insert(action.actionId).inserted else { continue }
            let message = await resolveWatchMirrorActionTarget(messageIdentifier: action.messageId)
            switch action.kind {
            case .read:
                if let message {
                    _ = try? await messageStateCoordinator.markRead(messageId: message.id)
                }
                ackedActionIds.append(action.actionId)
            case .delete:
                if let message {
                    try? await messageStateCoordinator.deleteMessage(messageId: message.id)
                }
                ackedActionIds.append(action.actionId)
            }
        }
        guard !ackedActionIds.isEmpty else { return }
        watchMirrorActionAckGeneration = nextWatchGeneration()
        WatchTokenReceiver.shared.sendMirrorActionAck(
            WatchMirrorActionAck(
                ackGeneration: watchMirrorActionAckGeneration,
                ackedActionIds: ackedActionIds
            )
        )
        await publishWatchControlContext()
        requestWatchMirrorSnapshotSync()
    }

    private func resolveWatchMirrorActionTarget(messageIdentifier: String) async -> PushMessage? {
        if let message = try? await dataStore.loadMessage(messageId: messageIdentifier) {
            return message
        }
        if let message = try? await dataStore.loadMessage(deliveryId: messageIdentifier) {
            return message
        }
        if let message = try? await dataStore.loadMessage(notificationRequestId: messageIdentifier) {
            return message
        }
        return nil
    }

    private func requestNetworkPermissionOnLaunch() {
        let baseURL = serverConfig?.baseURL ?? AppConstants.defaultServerURL
        networkPermissionChecker.requestAccessIfNeeded(baseURL: baseURL) {
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

    private func platformIdentifier() -> String {
        "ios"
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
                _ = await syncProviderIngress(reason: "scene_active")
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

    func updateEventListPosition(isAtTop: Bool) {
        guard isEventListAtTop != isAtTop else { return }
        isEventListAtTop = isAtTop
        clearDeliveredSystemNotifications()
    }

    func updateThingListPosition(isAtTop: Bool) {
        guard isThingListAtTop != isAtTop else { return }
        isThingListAtTop = isAtTop
        clearDeliveredSystemNotifications()
    }

    func shouldPresentForegroundNotification(payload: [AnyHashable: Any]? = nil) -> Bool {
        guard let payload else {
            return true
        }
        guard !shouldSuppressForegroundNotifications(for: payload) else {
            return false
        }
        return NotificationHandling.shouldPresentUserAlert(from: payload)
    }

    private func syncPrivateChannelState() async {
        guard let config = serverConfig else { return }
        if let token = await dataStore.cachedPushToken(for: platformIdentifier())?.trimmingCharacters(in: .whitespacesAndNewlines),
           !token.isEmpty
        {
            await syncProviderPullRoute(config: config, providerToken: token)
        }
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
        let previousToken = (previousRaw?.isEmpty == false) ? previousRaw : nil
        await dataStore.saveCachedPushToken(normalizedToken, for: platform)
        guard let previousToken, previousToken != normalizedToken else {
            return
        }
        guard (try? await ensureProviderRoute(config: config, providerToken: normalizedToken)) != nil else {
            return
        }
        await retireProviderToken(config: config, providerToken: previousToken)
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
            throw AppError.unknown(localizationManager.localized("operation_failed"))
        }
        let taskKey = "\(config.gatewayKey)|\(normalizedProviderToken)"
        if providerRouteTaskKey == taskKey, let providerRouteTask {
            return try await providerRouteTask.value
        }

        let task = Task<String, Error> { @MainActor [weak self] in
            guard let self else {
                throw AppError.unknown("provider route context released")
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
            throw AppError.unknown(localizationManager.localized("operation_failed"))
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
            throw AppError.unknown(localizationManager.localized("operation_failed"))
        }
        await dataStore.saveCachedDeviceKey(
            resolvedDeviceKey,
            for: platform,
            channelType: "apns"
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
        return try await task.value
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

    private func shouldAckProviderDelivery(for outcome: NotificationPersistenceOutcome) -> Bool {
        switch outcome {
        case .duplicate, .persistedMain, .persistedPending:
            return true
        case .rejected, .failed:
            return false
        }
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

    private func ackProviderDeliveryIfNeeded(
        from payload: [AnyHashable: Any],
        outcome: NotificationPersistenceOutcome,
        source: String
    ) {
        guard shouldAckProviderDelivery(for: outcome) else { return }
        guard NotificationHandling.providerWakeupPullDeliveryId(from: payload) == nil else { return }
        guard let deliveryId = providerIngressDeliveryId(from: payload) else { return }
        guard let config = serverConfig else { return }
        Task { [weak self] in
            guard let self else { return }
            guard let deviceKey = await self.cachedProviderPullDeviceKey() else { return }
            do {
                _ = try await self.channelSubscriptionService.ackMessage(
                    baseURL: config.baseURL,
                    token: config.token,
                    deviceKey: deviceKey,
                    deliveryId: deliveryId
                )
            } catch {
                self.recordAutomationRuntimeError(error, source: source, category: "provider")
            }
        }
    }

    @discardableResult
    func syncProviderIngress(
        deliveryId: String? = nil,
        reason: String
    ) async -> Int {
        guard let config = serverConfig else { return 0 }
        var deviceKey = await cachedProviderPullDeviceKey()
        if deviceKey == nil,
           let token = await dataStore.cachedPushToken(for: platformIdentifier())?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !token.isEmpty
        {
            await syncProviderPullRoute(config: config, providerToken: token)
            deviceKey = await cachedProviderPullDeviceKey()
        }
        guard let deviceKey else { return 0 }
        do {
            let items = try await channelSubscriptionService.pullMessages(
                baseURL: config.baseURL,
                token: config.token,
                deviceKey: deviceKey,
                deliveryId: deliveryId
            )
            guard !items.isEmpty else { return 0 }
            var applied = 0
            for item in items {
                let payload: [AnyHashable: Any] = item.payload.reduce(into: [:]) { result, element in
                    result[element.key] = element.value
                }
                let outcome = await NotificationPersistenceCoordinator.persistRemotePayloadIfNeeded(
                    payload,
                    requestIdentifier: item.deliveryId,
                    dataStore: dataStore,
                    beforeSave: { [weak self] message in
                        guard let self else { return }
                        await self.autoEnableDataPageIfNeeded(for: message)
                    }
                )
                applyNotificationPersistenceOutcome(outcome)
                if shouldAckProviderDelivery(for: outcome) {
                    applied += 1
                }
            }
            return applied
        } catch {
            recordAutomationRuntimeError(
                error,
                source: "provider.ingress.\(reason)",
                category: "provider"
            )
            return 0
        }
    }

    func updateLaunchAtLogin(isEnabled: Bool) {
        Task { @MainActor in
            await dataStore.saveLaunchAtLoginPreference(isEnabled)
        }
    }
    @discardableResult
    func persistNotificationIfNeeded(_ notification: UNNotification) async -> NotificationPersistenceOutcome {
        let ingress = await NotificationHandling.resolveNotificationIngress(
            from: notification.request.content.userInfo,
            dataStore: dataStore,
            fallbackServerConfig: serverConfig,
            channelSubscriptionService: channelSubscriptionService
        )
        let outcome: NotificationPersistenceOutcome
        switch ingress {
        case let .pulled(payload, requestIdentifier):
            outcome = await NotificationPersistenceCoordinator.persistRemotePayloadIfNeeded(
                payload,
                requestIdentifier: requestIdentifier,
                dataStore: dataStore,
                beforeSave: { [weak self] message in
                    guard let self else { return }
                    await self.autoEnableDataPageIfNeeded(for: message)
                }
            )
        case let .unresolvedWakeup(payload, requestIdentifier):
            _ = payload
            _ = requestIdentifier
            outcome = .rejected
        case let .direct(_, requestIdentifier):
            let directPayload = notification.request.content.userInfo
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
            ackProviderDeliveryIfNeeded(
                from: directPayload,
                outcome: outcome,
                source: "provider.direct.ack.ios"
            )
        }
        applyNotificationPersistenceOutcome(outcome)
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

    private func shouldSuppressForegroundNotifications(for payload: [AnyHashable: Any]) -> Bool {
        guard isSceneActive else { return false }
        guard let entityType = foregroundNotificationEntityType(from: payload) else {
            return false
        }
        switch (activeMainTab, entityType) {
        case (.messages, "message"):
            return isMessageListAtTop
        case (.events, "event"):
            return isEventListAtTop
        case (.things, "thing"):
            return isThingListAtTop
        default:
            return false
        }
    }

    private func foregroundNotificationEntityType(
        from payload: [AnyHashable: Any]
    ) -> String? {
        let raw = (payload["entity_type"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        switch raw {
        case "message", "event", "thing":
            return raw
        default:
            return nil
        }
    }

    private func channelMatches(_ candidate: String?, normalizedChannel: String) -> Bool {
        guard let candidate else { return false }
        if let normalizedCandidate = try? ChannelIdValidator.normalize(candidate) {
            return normalizedCandidate == normalizedChannel
        }
        return candidate.trimmingCharacters(in: .whitespacesAndNewlines) == normalizedChannel
    }

    private var canRefreshMessageList: Bool {
        isSceneActive && isMainWindowVisible
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

private final class NetworkPermissionChecker {
    private let queue = DispatchQueue(label: "io.ethan.pushgo.network-permission")
    private var monitor: NWPathMonitor?

    func requestAccessIfNeeded(baseURL: URL?, onDenied: @escaping @Sendable () -> Void) {
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
        URLSession.shared.dataTask(with: request).resume()
    }
}
