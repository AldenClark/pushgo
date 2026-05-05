import Foundation

@MainActor
final class ChannelSubscriptionController {
    typealias ServerConfigProvider = @MainActor () -> ServerConfig?
    typealias MessageStateCoordinatorProvider = @MainActor () -> MessageStateCoordinator?
    typealias RefreshCountsAndNotify = @MainActor () async -> Void

    private let dataStore: LocalDataStore
    private let channelSubscriptionService: ChannelSubscriptionService
    private let providerRouteController: ProviderRouteController
    private let channelSyncController: ChannelSyncController
    private let localizationManager: LocalizationManager
    private let serverConfigProvider: ServerConfigProvider
    private let messageStateCoordinatorProvider: MessageStateCoordinatorProvider
    private let refreshMessageCountsAndNotify: RefreshCountsAndNotify
    private let platform = "ios"

    init(
        dataStore: LocalDataStore,
        channelSubscriptionService: ChannelSubscriptionService,
        providerRouteController: ProviderRouteController,
        channelSyncController: ChannelSyncController,
        localizationManager: LocalizationManager,
        serverConfigProvider: @escaping ServerConfigProvider,
        messageStateCoordinatorProvider: @escaping MessageStateCoordinatorProvider,
        refreshMessageCountsAndNotify: @escaping RefreshCountsAndNotify
    ) {
        self.dataStore = dataStore
        self.channelSubscriptionService = channelSubscriptionService
        self.providerRouteController = providerRouteController
        self.channelSyncController = channelSyncController
        self.localizationManager = localizationManager
        self.serverConfigProvider = serverConfigProvider
        self.messageStateCoordinatorProvider = messageStateCoordinatorProvider
        self.refreshMessageCountsAndNotify = refreshMessageCountsAndNotify
    }

    func channelExists(channelId: String) async throws -> ChannelSubscriptionService.ExistsPayload {
        guard let config = serverConfigProvider() else { throw AppError.noServer }
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

    func renameChannel(channelId: String, alias: String) async throws {
        guard let config = serverConfigProvider() else { throw AppError.noServer }
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
        await channelSyncController.refreshChannelSubscriptions()
    }

    func unsubscribeChannel(channelId: String, deleteLocalMessages: Bool) async throws -> Int {
        guard let config = serverConfigProvider() else { throw AppError.noServer }
        let gatewayKey = config.gatewayKey
        let normalized = try ChannelIdValidator.normalize(channelId)
        let token = try await channelSyncController.ensureActivePushToken(serverConfig: config)
        let deviceKey = try await providerRouteController.ensureProviderRoute(
            config: config,
            providerToken: token
        )

        _ = try await channelSubscriptionService.unsubscribe(
            baseURL: config.baseURL,
            token: config.token,
            deviceKey: deviceKey,
            channelId: normalized
        )

        try await dataStore.softDeleteChannelSubscription(gateway: gatewayKey, channelId: normalized)
        await channelSyncController.refreshChannelSubscriptions()

        guard deleteLocalMessages else { return 0 }
        let eventImageURLs = try await dataStore
            .loadEventMessagesForProjection()
            .filter { Self.channelMatches($0.channel, normalizedChannel: normalized) }
            .flatMap(\.imageURLs)
        let thingImageURLs = try await dataStore
            .loadThingMessagesForProjection()
            .filter { Self.channelMatches($0.channel, normalizedChannel: normalized) }
            .flatMap(\.imageURLs)
        guard let messageStateCoordinator = messageStateCoordinatorProvider() else {
            throw AppError.unknown(localizationManager.localized("operation_failed"))
        }
        let removedMessages = try await messageStateCoordinator.deleteMessages(channel: normalized, readState: nil)
        let removedEvents = try await dataStore.deleteEventRecords(channel: normalized)
        let removedThings = try await dataStore.deleteThingRecords(channel: normalized)
        let remainingMessages = try await dataStore.loadMessages(filter: .all, channel: normalized)
        let remainingEvents = try await dataStore
            .loadEventMessagesForProjection()
            .filter { Self.channelMatches($0.channel, normalizedChannel: normalized) }
        let remainingThings = try await dataStore
            .loadThingMessagesForProjection()
            .filter { Self.channelMatches($0.channel, normalizedChannel: normalized) }
        if !remainingMessages.isEmpty || !remainingEvents.isEmpty || !remainingThings.isEmpty {
            throw AppError.localStore(
                "channel cleanup incomplete messages=\(remainingMessages.count) events=\(remainingEvents.count) things=\(remainingThings.count)"
            )
        }
        await SharedImageCache.purge(urls: eventImageURLs + thingImageURLs)
        await refreshMessageCountsAndNotify()
        return removedMessages + removedEvents + removedThings
    }

    private func subscribeChannel(
        channelId: String?,
        alias: String?,
        password: String
    ) async throws -> ChannelSubscriptionService.SubscribePayload {
        guard let config = serverConfigProvider() else { throw AppError.noServer }
        let gatewayKey = config.gatewayKey
        let validatedPassword = try ChannelPasswordValidator.validate(password)
        let token = try await channelSyncController.ensureActivePushToken(serverConfig: config)
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
        await channelSyncController.refreshChannelSubscriptions()
        return payload
    }

    private func subscribeWithDeviceKeyRecovery(
        config: ServerConfig,
        providerToken: String,
        channelId: String?,
        alias: String?,
        password: String
    ) async throws -> ChannelSubscriptionService.SubscribePayload {
        let initialDeviceKey = try await providerRouteController.ensureProviderRoute(
            config: config,
            providerToken: providerToken
        )
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
                try await providerRouteController.persistProviderDeviceKey(
                    refreshedDeviceKey,
                    source: "provider.device_key.subscribe_refresh"
                )
            }
            let ensuredDeviceKey = try await providerRouteController.ensureProviderRoute(
                config: config,
                providerToken: providerToken
            )
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

    private static func channelMatches(_ candidate: String?, normalizedChannel: String) -> Bool {
        guard let candidate else { return false }
        if let normalizedCandidate = try? ChannelIdValidator.normalize(candidate) {
            return normalizedCandidate == normalizedChannel
        }
        return candidate.trimmingCharacters(in: .whitespacesAndNewlines) == normalizedChannel
    }
}
