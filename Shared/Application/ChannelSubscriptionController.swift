import Foundation

@MainActor
final class ChannelSubscriptionController {
    typealias ServerConfigProvider = @MainActor () -> ServerConfig?
    typealias MessageStateCoordinatorProvider = @MainActor () -> MessageStateCoordinator?

    private let dataStore: LocalDataStore
    private let channelSubscriptionService: ChannelSubscriptionService
    private let providerRouteController: ProviderRouteController
    private let channelSyncController: ChannelSyncController
    private let localizationManager: LocalizationManager
    private let serverConfigProvider: ServerConfigProvider
    private let messageStateCoordinatorProvider: MessageStateCoordinatorProvider
    private let platform: String

    init(
        platform: String,
        dataStore: LocalDataStore,
        channelSubscriptionService: ChannelSubscriptionService,
        providerRouteController: ProviderRouteController,
        channelSyncController: ChannelSyncController,
        localizationManager: LocalizationManager,
        serverConfigProvider: @escaping ServerConfigProvider,
        messageStateCoordinatorProvider: @escaping MessageStateCoordinatorProvider
    ) {
        self.platform = platform
        self.dataStore = dataStore
        self.channelSubscriptionService = channelSubscriptionService
        self.providerRouteController = providerRouteController
        self.channelSyncController = channelSyncController
        self.localizationManager = localizationManager
        self.serverConfigProvider = serverConfigProvider
        self.messageStateCoordinatorProvider = messageStateCoordinatorProvider
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
            throw AppError.typedLocal(
                code: "channel_password_missing",
                category: .validation,
                message: localizationManager.localized("channel_password_missing"),
                detail: "missing stored password for channel rename"
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
        await channelSyncController.refreshChannelSubscriptions()
    }

    func unsubscribeChannel(channelId: String) async throws {
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
    }

    func unsubscribeChannelAndDeleteLocalHistory(
        channelId: String,
        expectedGateway: String,
        expectedUpdatedAt: Date
    ) async throws -> Int {
        guard let config = serverConfigProvider() else { throw AppError.noServer }
        let gatewayKey = config.gatewayKey
        let normalizedExpectedGateway = expectedGateway.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let normalizedCurrentGateway = gatewayKey.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard normalizedExpectedGateway == normalizedCurrentGateway else {
            throw AppError.typedLocal(
                code: "gateway_changed_during_channel_removal",
                category: .validation,
                message: localizationManager.localized("operation_failed"),
                detail: "gateway changed while channel removal was pending"
            )
        }
        let normalized = try ChannelIdValidator.normalize(channelId)
        let currentSubscription = try await dataStore.loadChannelSubscriptions(
            gateway: gatewayKey,
            includeDeleted: false
        ).first {
            $0.channelId.trimmingCharacters(in: .whitespacesAndNewlines) == normalized
        }
        guard let currentSubscription,
              abs(currentSubscription.updatedAt.timeIntervalSince(expectedUpdatedAt)) < 0.001
        else {
            throw AppError.typedLocal(
                code: "channel_subscription_changed_during_removal",
                category: .validation,
                message: localizationManager.localized("operation_failed"),
                detail: "channel subscription changed while removal was pending"
            )
        }
        guard try await dataStore.activeChannelPassword(gateway: gatewayKey, for: normalized) != nil else {
            throw AppError.typedLocal(
                code: "channel_password_missing",
                category: .validation,
                message: localizationManager.localized("channel_password_missing"),
                detail: "missing stored password for transactional channel removal"
            )
        }
        guard let messageStateCoordinator = messageStateCoordinatorProvider() else {
            throw AppError.typedLocal(
                code: "message_state_coordinator_unavailable",
                category: .local,
                message: localizationManager.localized("operation_failed"),
                detail: "messageStateCoordinatorProvider returned nil during channel cleanup"
            )
        }
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

        let result: LocalDataStore.ChannelRemovalResult
        do {
            result = try await dataStore.softDeleteChannelSubscriptionAndDeleteHistory(
                gateway: gatewayKey,
                channelId: normalized,
                expectedUpdatedAt: expectedUpdatedAt
            )
        } catch {
            let localError = error
            let currentPassword: String?
            do {
                currentPassword = try await dataStore.activeChannelPassword(
                    gateway: gatewayKey,
                    for: normalized
                )
            } catch {
                throw AppError.localStore(
                    "channel removal local transaction failed and remote compensation state "
                        + "could not be verified; local=\(localError.localizedDescription); "
                        + "credential_read=\(error.localizedDescription)"
                )
            }
            guard let currentPassword else {
                // A newer local removal superseded this intent. Do not resurrect
                // the subscription with a credential captured by the stale intent.
                throw localError
            }
            do {
                _ = try await subscribeWithDeviceKeyRecovery(
                    config: config,
                    providerToken: token,
                    channelId: normalized,
                    alias: nil,
                    password: currentPassword
                )
            } catch {
                throw AppError.localStore(
                    "channel removal local transaction failed and remote compensation failed; "
                        + "local=\(localError.localizedDescription); compensation=\(error.localizedDescription)"
                )
            }
            throw localError
        }

        await messageStateCoordinator.reconcileExternallyDeletedMessages(
            notificationRequestIDs: result.deletedNotificationRequestIDs,
            imageURLs: result.deletedImageURLs
        )
        await channelSyncController.refreshChannelSubscriptions()
        return result.deletedRecordCount
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
            throw AppError.typedLocal(
                code: "channel_subscribe_failed",
                category: .internalError,
                message: localizationManager.localized("operation_failed"),
                detail: "gateway subscribe response returned subscribed=false"
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

    private static func channelMatches(_ candidate: String?, normalizedChannel: String) -> Bool {
        guard let candidate else { return false }
        if let normalizedCandidate = try? ChannelIdValidator.normalize(candidate) {
            return normalizedCandidate == normalizedChannel
        }
        return candidate.trimmingCharacters(in: .whitespacesAndNewlines) == normalizedChannel
    }
}
