import Foundation

@MainActor
protocol ChannelMutationRoundTrip {
    func subscribe(
        channelId: String?,
        channelName: String?,
        credential: String
    ) async throws -> ChannelSubscriptionService.SubscribePayload
    func rename(
        channelId: String,
        channelName: String,
        credential: String
    ) async throws -> ChannelSubscriptionService.RenamePayload
    func unsubscribe(channelId: String) async throws
}

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
    private let channelMutationRoundTrip: (any ChannelMutationRoundTrip)?
    private let platform: String

    init(
        platform: String,
        dataStore: LocalDataStore,
        channelSubscriptionService: ChannelSubscriptionService,
        providerRouteController: ProviderRouteController,
        channelSyncController: ChannelSyncController,
        localizationManager: LocalizationManager,
        serverConfigProvider: @escaping ServerConfigProvider,
        messageStateCoordinatorProvider: @escaping MessageStateCoordinatorProvider,
        channelMutationRoundTrip: (any ChannelMutationRoundTrip)? = nil
    ) {
        self.platform = platform
        self.dataStore = dataStore
        self.channelSubscriptionService = channelSubscriptionService
        self.providerRouteController = providerRouteController
        self.channelSyncController = channelSyncController
        self.localizationManager = localizationManager
        self.serverConfigProvider = serverConfigProvider
        self.messageStateCoordinatorProvider = messageStateCoordinatorProvider
        self.channelMutationRoundTrip = channelMutationRoundTrip
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

        let payload = if let channelMutationRoundTrip {
            try await channelMutationRoundTrip.rename(
                channelId: normalizedId,
                channelName: normalizedAlias,
                credential: password
            )
        } else {
            try await channelSubscriptionService.renameChannel(
                baseURL: config.baseURL,
                token: config.token,
                channelId: normalizedId,
                channelName: normalizedAlias,
                password: password
            )
        }

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
        if let channelMutationRoundTrip {
            try await channelMutationRoundTrip.unsubscribe(channelId: normalized)
        } else {
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
        }

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
        let providerToken = try await performRemoteUnsubscribe(
            config: config,
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
            if channelMutationRoundTrip != nil {
                throw localError
            }
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
                    providerToken: providerToken,
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

    func commitPendingChannelRemoval(
        record: PendingLocalDeletionRecord,
        leaseOwner: String
    ) async throws -> PendingLocalDeletionCleanup {
        guard case let .channelHistory(channelId, expectedGateway, expectedUpdatedAt) = record.intent else {
            throw AppError.localStore("Invalid pending channel removal payload.")
        }
        return try await commitPendingChannelRemoval(
            record: record,
            leaseOwner: leaseOwner,
            channelId: channelId,
            expectedGateway: expectedGateway,
            expectedUpdatedAt: expectedUpdatedAt
        )
    }

    private func commitPendingChannelRemoval(
        record: PendingLocalDeletionRecord,
        leaseOwner: String,
        channelId: String,
        expectedGateway: String,
        expectedUpdatedAt: Date
    ) async throws -> PendingLocalDeletionCleanup {
        guard let config = serverConfigProvider() else { throw AppError.noServer }
        let gatewayKey = config.gatewayKey
        let expected = expectedGateway.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let current = gatewayKey.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard expected == current else {
            throw AppError.typedLocal(
                code: "gateway_changed_during_channel_removal",
                category: .validation,
                message: localizationManager.localized("operation_failed")
            )
        }
        let normalized = try ChannelIdValidator.normalize(channelId)
        let subscription = try await dataStore.loadChannelSubscriptions(
            gateway: gatewayKey,
            includeDeleted: false
        ).first { $0.channelId.trimmingCharacters(in: .whitespacesAndNewlines) == normalized }
        guard let subscription,
              abs(subscription.updatedAt.timeIntervalSince(expectedUpdatedAt)) < 0.001
        else {
            throw AppError.typedLocal(
                code: "channel_subscription_changed_during_removal",
                category: .validation,
                message: localizationManager.localized("operation_failed")
            )
        }
        return try await finishPendingChannelRemoval(
            record: record,
            leaseOwner: leaseOwner,
            normalizedChannelId: normalized
        )
    }

    private func finishPendingChannelRemoval(
        record: PendingLocalDeletionRecord,
        leaseOwner: String,
        normalizedChannelId: String
    ) async throws -> PendingLocalDeletionCleanup {
        guard case let .channelHistory(_, expectedGateway, expectedUpdatedAt) = record.intent else {
            throw AppError.localStore("Invalid pending channel removal payload.")
        }
        let deletedRecordCount = try await unsubscribeChannelAndDeleteLocalHistory(
            channelId: normalizedChannelId,
            expectedGateway: expectedGateway,
            expectedUpdatedAt: expectedUpdatedAt
        )
        try await dataStore.abandonClaimedPendingLocalDeletion(
            id: record.id,
            owner: leaseOwner
        )
        return PendingLocalDeletionCleanup(deletedRecordCount: deletedRecordCount)
    }

    private func subscribeChannel(
        channelId: String?,
        alias: String?,
        password: String
    ) async throws -> ChannelSubscriptionService.SubscribePayload {
        guard let config = serverConfigProvider() else { throw AppError.noServer }
        let gatewayKey = config.gatewayKey
        let validatedPassword = try ChannelPasswordValidator.validate(password)
        let payload = try await performRemoteSubscribe(
            config: config,
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
        do {
            await dataStore.armQualityChannelSubscriptionPersistenceFailure()
            _ = try await dataStore.upsertChannelSubscription(
                gateway: gatewayKey,
                channelId: payload.channelId,
                displayName: displayName,
                password: validatedPassword,
                lastSyncedAt: Date()
            )
        } catch {
            let localError = error
            // A create attempt owns its newly established remote route. Existing-channel
            // subscribe does not reveal whether the route predated this attempt, so blindly
            // unsubscribing that path could destroy a valid subscription.
            if channelId == nil, payload.created {
                do {
                    _ = try await performRemoteUnsubscribe(config: config, channelId: payload.channelId)
                } catch {
                    throw AppError.localStore(
                        "channel creation local commit failed and remote compensation failed; "
                            + "local=\(localError.localizedDescription); "
                            + "compensation=\(error.localizedDescription)"
                    )
                }
            }
            throw localError
        }
        await channelSyncController.refreshChannelSubscriptions()
        return payload
    }

    private func performRemoteUnsubscribe(
        config: ServerConfig,
        channelId: String
    ) async throws -> String {
        if let channelMutationRoundTrip {
            try await channelMutationRoundTrip.unsubscribe(channelId: channelId)
            return ""
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
            channelId: channelId
        )
        return token
    }

    private func performRemoteSubscribe(
        config: ServerConfig,
        channelId: String?,
        alias: String?,
        password: String
    ) async throws -> ChannelSubscriptionService.SubscribePayload {
        if let channelMutationRoundTrip {
            return try await channelMutationRoundTrip.subscribe(
                channelId: channelId,
                channelName: alias,
                credential: password
            )
        }
        let token = try await channelSyncController.ensureActivePushToken(serverConfig: config)
        return try await subscribeWithDeviceKeyRecovery(
            config: config,
            providerToken: token,
            channelId: channelId,
            alias: alias,
            password: password
        )
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
