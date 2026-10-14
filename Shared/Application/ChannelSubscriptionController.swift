import Foundation

@MainActor
protocol ChannelMutationRoundTrip {
    func subscribe(
        baseURL: URL,
        token: String?,
        channelId: String?,
        channelName: String?,
        credential: String
    ) async throws -> ChannelSubscriptionService.SubscribePayload
    func rename(
        baseURL: URL,
        token: String?,
        channelId: String,
        channelName: String,
        credential: String
    ) async throws -> ChannelSubscriptionService.RenamePayload
    func unsubscribe(baseURL: URL, token: String?, channelId: String) async throws
}

@MainActor
final class ChannelSubscriptionController {
    typealias ServerConfigProvider = @MainActor () -> ServerConfig?

    private let dataStore: LocalDataStore
    private let channelSubscriptionService: ChannelSubscriptionService
    private let providerRouteController: ProviderRouteController
    private let channelSyncController: ChannelSyncController
    private let localizationManager: LocalizationManager
    private let serverConfigProvider: ServerConfigProvider
    private let channelMutationRoundTrip: (any ChannelMutationRoundTrip)?
    private let platform: String
    private var inFlightChannelMutationKeys: Set<String> = []

    init(
        platform: String,
        dataStore: LocalDataStore,
        channelSubscriptionService: ChannelSubscriptionService,
        providerRouteController: ProviderRouteController,
        channelSyncController: ChannelSyncController,
        localizationManager: LocalizationManager,
        serverConfigProvider: @escaping ServerConfigProvider,
        channelMutationRoundTrip: (any ChannelMutationRoundTrip)? = nil
    ) {
        self.platform = platform
        self.dataStore = dataStore
        self.channelSubscriptionService = channelSubscriptionService
        self.providerRouteController = providerRouteController
        self.channelSyncController = channelSyncController
        self.localizationManager = localizationManager
        self.serverConfigProvider = serverConfigProvider
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
        let mutationKey = try beginChannelMutation(config: config, channelID: normalizedId)
        defer { inFlightChannelMutationKeys.remove(mutationKey) }
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
                baseURL: config.baseURL,
                token: config.token,
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

    /// Captures the displayed subscription without creating a request or durable intent.
    func prepareChannelRemoval(
        subscription: ChannelSubscription,
        originalConfig: ServerConfig,
        keepHistory: Bool
    ) async throws -> PendingChannelRemovalTarget {
        guard dataStore.storageState.mode == .persistent else {
            throw AppError.localStore("Channel confirmation requires available canonical storage.")
        }
        guard normalizedGateway(subscription.gateway) == normalizedGateway(originalConfig.gatewayKey) else {
            throw channelRemovalError("gateway_changed_during_channel_removal")
        }
        let channelID = try ChannelIdValidator.normalize(subscription.channelId)
        let current = try await currentRemovalSubscription(
            gateway: originalConfig.gatewayKey,
            channelID: channelID,
            expectedUpdatedAt: subscription.updatedAt
        )
        guard let password = try await dataStore.activeChannelPassword(
            gateway: originalConfig.gatewayKey,
            for: channelID
        ) else {
            throw channelRemovalError("channel_password_missing")
        }
        let deviceKey = await dataStore.cachedDeviceKey(for: platform, backfillWakeupDefaults: false)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // The device-key cache belongs to the active gateway. Never pair a key
        // from a replacement configuration with the displayed subscription.
        guard sameRemoteIdentity(serverConfigProvider(), originalConfig) else {
            throw channelRemovalError("gateway_changed_during_channel_removal")
        }
        let historySnapshot = try await dataStore.prepareChannelRemovalHistory(channelID: channelID)
        var removalConfig = originalConfig
        removalConfig.notificationKeyMaterial = nil
        return PendingChannelRemovalTarget(
            channelID: channelID,
            originalConfig: removalConfig,
            expectedUpdatedAt: current.updatedAt,
            password: password,
            originalDeviceKey: deviceKey?.isEmpty == false ? deviceKey : nil,
            historySnapshot: historySnapshot,
            keepHistory: keepHistory
        )
    }

    func commitPendingChannelRemoval(
        record: PendingLocalDeletionRecord,
        leaseOwner: String
    ) async throws -> PendingLocalDeletionCleanup {
        let target: PendingChannelRemovalTarget
        switch record.intent {
        case let .channelRemoval(captured):
            target = captured
        case let .channelHistory(channelID, expectedGateway, expectedUpdatedAt):
            // Old accepted intents contain no server credentials. They can only
            // be resolved while the original gateway is still active; otherwise
            // the worker retains the receipt for explicit recovery.
            guard let config = serverConfigProvider(),
                  normalizedGateway(config.gatewayKey) == normalizedGateway(expectedGateway)
            else {
                throw channelRemovalError("channel_removal_reconciliation_required")
            }
            let subscription = try await currentRemovalSubscription(
                gateway: expectedGateway,
                channelID: channelID,
                expectedUpdatedAt: expectedUpdatedAt
            )
            let prepared = try await prepareChannelRemoval(
                subscription: subscription,
                originalConfig: config,
                keepHistory: false
            )
            // Execute the exact durable payload. The millisecond Date codec can
            // round a transient ServerConfig date while freezing this receipt.
            target = try await dataStore.freezeLegacyChannelRemoval(id: record.id, owner: leaseOwner, target: prepared)
        case .messages, .events, .things:
            throw AppError.localStore("Invalid pending channel removal payload.")
        }
        let mutationKey = try beginChannelMutation(config: target.originalConfig, channelID: target.channelID)
        defer { inFlightChannelMutationKeys.remove(mutationKey) }
        await channelSyncController.beginChannelRemovalWindow()
        defer { channelSyncController.endChannelRemovalWindow() }
        try await validateRemovalTarget(target)
        return try await finishPendingChannelRemoval(record: record, leaseOwner: leaseOwner, target: target)
    }

    private func finishPendingChannelRemoval(
        record: PendingLocalDeletionRecord,
        leaseOwner: String,
        target: PendingChannelRemovalTarget
    ) async throws -> PendingLocalDeletionCleanup {
        let deviceKey = try await performCapturedRemoteUnsubscribe(target)
        let cleanup: PendingLocalDeletionCleanup
        do {
            cleanup = try await dataStore.commitClaimedChannelRemoval(
                id: record.id,
                owner: leaseOwner,
                target: target
            )
        } catch {
            let localError = error
            if (localError as? AppError)?.code == "channel_removal_lease_changed" {
                // The replacement executor owns the remote/local outcome.
                throw localError
            }
            do {
                try await validateRemovalTarget(target)
            } catch {
                // A changed subscription does not authorize restoring either
                // its replacement credential or the obsolete captured one.
                throw channelRemovalError("channel_removal_reconciliation_required",
                    detail: "local=\(localError.localizedDescription); compensation_state=\(error.localizedDescription)")
            }
            do {
                try await compensateCapturedRemoteUnsubscribe(target, deviceKey: deviceKey)
            } catch {
                throw AppError.localStore(
                    "channel removal local transaction failed and remote compensation failed; "
                        + "local=\(localError.localizedDescription); compensation=\(error.localizedDescription)"
                )
            }
            throw localError
        }
        // The store commits cleanup and receipt together; the worker completes
        // notification, image and projection cleanup even after process loss.
        await channelSyncController.refreshChannelSubscriptions(syncProviderRoute: false)
        return cleanup
    }

    private func performCapturedRemoteUnsubscribe(_ target: PendingChannelRemovalTarget) async throws -> String? {
        if let channelMutationRoundTrip {
            try await channelMutationRoundTrip.unsubscribe(
                baseURL: target.originalConfig.baseURL,
                token: target.originalConfig.token,
                channelId: target.channelID
            )
            return nil
        }
        // A removed/unknown route must not be replaced by a new device merely
        // to satisfy an old unsubscribe. Keep the accepted obligation visible.
        guard let deviceKey = target.originalDeviceKey, !deviceKey.isEmpty else {
            throw channelRemovalError("channel_removal_reconciliation_required")
        }
        _ = try await channelSubscriptionService.unsubscribe(
            baseURL: target.originalConfig.baseURL,
            token: target.originalConfig.token,
            deviceKey: deviceKey,
            channelId: target.channelID
        )
        return deviceKey
    }

    private func compensateCapturedRemoteUnsubscribe(
        _ target: PendingChannelRemovalTarget,
        deviceKey: String?
    ) async throws {
        let payload: ChannelSubscriptionService.SubscribePayload
        if let channelMutationRoundTrip {
            payload = try await channelMutationRoundTrip.subscribe(
                baseURL: target.originalConfig.baseURL,
                token: target.originalConfig.token,
                channelId: target.channelID,
                channelName: nil,
                credential: target.password
            )
        } else {
            guard let deviceKey else {
                throw channelRemovalError("channel_removal_reconciliation_required")
            }
            payload = try await channelSubscriptionService.subscribe(
                baseURL: target.originalConfig.baseURL,
                token: target.originalConfig.token,
                deviceKey: deviceKey,
                channelId: target.channelID,
                channelName: nil,
                password: target.password
            )
        }
        guard payload.subscribed else {
            throw channelRemovalError("channel_removal_reconciliation_required")
        }
    }

    private func validateRemovalTarget(_ target: PendingChannelRemovalTarget) async throws {
        _ = try await currentRemovalSubscription(
            gateway: target.originalConfig.gatewayKey,
            channelID: target.channelID,
            expectedUpdatedAt: target.expectedUpdatedAt
        )
        guard try await dataStore.activeChannelPassword(
            gateway: target.originalConfig.gatewayKey,
            for: target.channelID
        ) == target.password else {
            throw channelRemovalError("channel_subscription_changed_during_removal")
        }
    }

    private func currentRemovalSubscription(
        gateway: String,
        channelID: String,
        expectedUpdatedAt: Date
    ) async throws -> ChannelSubscription {
        let normalizedID = try ChannelIdValidator.normalize(channelID)
        guard let subscription = try await dataStore.loadChannelSubscriptions(
            gateway: gateway,
            includeDeleted: false
        ).first(where: { $0.channelId.trimmingCharacters(in: .whitespacesAndNewlines) == normalizedID }),
              abs(subscription.updatedAt.timeIntervalSince(expectedUpdatedAt)) < 0.001
        else {
            throw channelRemovalError("channel_subscription_changed_during_removal")
        }
        return subscription
    }

    private func channelRemovalError(_ code: String, detail: String? = nil) -> AppError {
        AppError.typedLocal(
            code: code,
            category: .validation,
            message: localizationManager.localized("operation_failed"),
            detail: detail
        )
    }

    private func beginChannelMutation(config: ServerConfig, channelID: String) throws -> String {
        let key = normalizedGateway(config.gatewayKey) + "|" + channelID
        guard inFlightChannelMutationKeys.insert(key).inserted else {
            throw channelRemovalError("channel_mutation_in_progress")
        }
        return key
    }

    private func normalizedGateway(_ gateway: String) -> String {
        gateway.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private func sameRemoteIdentity(_ current: ServerConfig?, _ expected: ServerConfig) -> Bool {
        guard let current else { return false }
        return normalizedGateway(current.gatewayKey) == normalizedGateway(expected.gatewayKey)
            && current.token == expected.token
    }

    private func subscribeChannel(
        channelId: String?,
        alias: String?,
        password: String
    ) async throws -> ChannelSubscriptionService.SubscribePayload {
        guard let config = serverConfigProvider() else { throw AppError.noServer }
        let gatewayKey = config.gatewayKey
        let validatedPassword = try ChannelPasswordValidator.validate(password)
        let mutationKey = try channelId.map { try beginChannelMutation(config: config, channelID: $0) }
        defer { if let mutationKey { inFlightChannelMutationKeys.remove(mutationKey) } }
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
            try await channelMutationRoundTrip.unsubscribe(
                baseURL: config.baseURL,
                token: config.token,
                channelId: channelId
            )
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
                baseURL: config.baseURL,
                token: config.token,
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
