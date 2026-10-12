import Foundation

@MainActor
final class ProviderRouteController {
    typealias RuntimeMessageRecorder = @MainActor (_ message: String, _ source: String, _ category: String, _ code: String?) -> Void
    typealias AutomationStateRefresher = @MainActor () -> Void

    private let dataStore: LocalDataStore
    private let channelSubscriptionService: ChannelSubscriptionService
    private let localizationManager: LocalizationManager
    private let refreshAutomationState: AutomationStateRefresher
    private let runtimeMessageRecorder: RuntimeMessageRecorder
    private let platform: String
    private let channelType: String
    private let providerRouteResultReuseInterval: TimeInterval = 25

    private var providerRouteTask: Task<String, Error>?
    private var providerRouteTaskKey: String?
    private var lastProviderRouteResultKey: String?
    private var lastProviderRouteDeviceKey: String?
    private var lastProviderRouteResolvedAt: Date = .distantPast
    private var lastWakeupRouteFingerprint: String?

    init(
        platform: String,
        channelType: String = "apns",
        dataStore: LocalDataStore,
        channelSubscriptionService: ChannelSubscriptionService,
        localizationManager: LocalizationManager,
        refreshAutomationState: @escaping AutomationStateRefresher,
        runtimeMessageRecorder: @escaping RuntimeMessageRecorder
    ) {
        self.platform = platform
        self.channelType = channelType
        self.dataStore = dataStore
        self.channelSubscriptionService = channelSubscriptionService
        self.localizationManager = localizationManager
        self.refreshAutomationState = refreshAutomationState
        self.runtimeMessageRecorder = runtimeMessageRecorder
    }

    /// Deletes the old remote route only after the caller has durably committed
    /// the new local gateway identity.  The caller owns persistence/retry of a
    /// failure so this method must not turn an operational error into a silent
    /// success.
    func cleanupPreviousGatewayDeviceRoute(
        previousConfig: ServerConfig?,
        previousDeviceKey: String?,
        nextConfig: ServerConfig?
    ) async throws {
        guard let previousConfig else { return }
        let trimmedDeviceKey = previousDeviceKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmedDeviceKey.isEmpty else { return }
        guard gatewayIdentity(previousConfig) != gatewayIdentity(nextConfig) else { return }
        do {
            try await channelSubscriptionService.deleteDeviceChannel(
                baseURL: previousConfig.baseURL,
                token: previousConfig.token,
                deviceKey: trimmedDeviceKey,
                channelType: channelType
            )
        } catch let error as AppError where Self.isAlreadyRetiredGatewayRoute(error) {
            // Delete is idempotent at the business boundary: a route/device
            // already absent (or no longer of this channel type) satisfies the
            // cleanup obligation and must not keep the durable journal pending.
            return
        }
    }

    func syncProviderPullRoute(config: ServerConfig, providerToken: String) async {
        let normalizedToken = providerToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedToken.isEmpty else { return }
        let cachedDeviceKey = await dataStore.cachedDeviceKey(
            for: platform,
            channelType: channelType
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

    func persistPushTokenAndRotateRoute(config: ServerConfig, token: String) async {
        let normalizedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedToken.isEmpty else { return }
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

    func ensureProviderRoute(config: ServerConfig, providerToken: String) async throws -> String {
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
            let resolvedDeviceKey = try await self.prepareProviderRoute(
                config: config,
                providerToken: normalizedProviderToken,
                reuseExistingDeviceKey: true
            )
            try await self.persistProviderDeviceKey(
                resolvedDeviceKey,
                source: "provider.device_key.route"
            )
            self.refreshAutomationState()
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

    /// Proves that a candidate gateway can register this device and accept the
    /// active provider route without changing any local gateway identity. The
    /// caller owns the later local commit and compensation boundary.
    func prepareProviderRoute(
        config: ServerConfig,
        providerToken: String,
        reuseExistingDeviceKey: Bool
    ) async throws -> String {
        let normalizedProviderToken = providerToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedProviderToken.isEmpty else {
            throw AppError.typedLocal(
                code: "provider_token_missing",
                category: .validation,
                message: localizationManager.localized("operation_failed"),
                detail: "provider token missing"
            )
        }
        let cachedDeviceKey: String? = if reuseExistingDeviceKey {
            await dataStore.cachedDeviceKey(
                for: platform,
                channelType: channelType
            )?.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            nil
        }
        let registered = try await channelSubscriptionService.registerDevice(
            baseURL: config.baseURL,
            token: config.token,
            platform: platform,
            existingDeviceKey: cachedDeviceKey?.isEmpty == false ? cachedDeviceKey : nil
        )
        let bootstrapDeviceKey = try requireResolvedDeviceKey(registered.deviceKey)
        let route = try await channelSubscriptionService.upsertDeviceChannel(
            baseURL: config.baseURL,
            token: config.token,
            deviceKey: bootstrapDeviceKey,
            platform: platform,
            channelType: channelType,
            providerToken: normalizedProviderToken
        )
        return try requireResolvedDeviceKey(route.deviceKey)
    }

    func persistProviderDeviceKey(_ deviceKey: String, source: String) async throws {
        let result = await dataStore.saveCachedDeviceKey(
            deviceKey,
            for: platform,
            channelType: channelType
        )
        try requireProviderDeviceKeyPersistence(result, source: source)
    }

    /// Restores a previously protected key during a failed gateway transition.
    /// Nil is a valid old value and means that the protected keychain entry must
    /// be removed; a non-nil value must round-trip through the canonical store.
    func restoreProviderDeviceKey(_ deviceKey: String?, source: String) async throws {
        let normalized = deviceKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = normalized?.isEmpty == false ? normalized : nil
        let result = await dataStore.saveCachedDeviceKey(
            value,
            for: platform,
            channelType: channelType
        )
        try requireProviderDeviceKeyPersistence(
            result,
            source: source,
            allowDeletion: value == nil
        )
        if value == nil {
            guard await dataStore.cachedDeviceKey(
                for: platform,
                channelType: channelType
            ) == nil else {
                runtimeMessageRecorder(
                    "provider_device_key_restore_failed platform=\(platform)",
                    source,
                    "keychain",
                    "E_PROVIDER_DEVICE_KEY_RESTORE_FAILED"
                )
                throw AppError.typedLocal(
                    code: "provider_device_key_restore_failed",
                    category: .local,
                    message: localizationManager.localized("operation_failed"),
                    detail: "provider device key remained after rollback"
                )
            }
        }
        lastProviderRouteResultKey = nil
        lastProviderRouteDeviceKey = nil
        lastProviderRouteResolvedAt = .distantPast
    }

    func cachedProviderPullDeviceKey() async -> String? {
        if Date().timeIntervalSince(lastProviderRouteResolvedAt) < providerRouteResultReuseInterval,
           let recentDeviceKey = lastProviderRouteDeviceKey?.trimmingCharacters(in: .whitespacesAndNewlines),
           !recentDeviceKey.isEmpty
        {
            return recentDeviceKey
        }
        let deviceKey = await dataStore.cachedDeviceKey(for: platform)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return deviceKey?.isEmpty == false ? deviceKey : nil
    }

    private func retireProviderToken(config: ServerConfig, providerToken: String) async {
        let normalized = providerToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }
        do {
            try await channelSubscriptionService.retireProviderToken(
                baseURL: config.baseURL,
                token: config.token,
                platform: platform,
                providerToken: normalized
            )
        } catch {}
    }

    private func requireProviderDeviceKeyPersistence(
        _ result: ProviderDeviceKeyStore.SaveResult?,
        source: String,
        allowDeletion: Bool = false
    ) throws {
        guard let result else {
            runtimeMessageRecorder(
                "provider_device_key_save_failed platform=invalid",
                source,
                "keychain",
                "E_PROVIDER_DEVICE_KEY_SAVE_FAILED"
            )
            throw AppError.typedLocal(
                code: "provider_device_key_save_failed",
                category: .local,
                message: localizationManager.localized("operation_failed"),
                detail: "provider_device_key_save_failed platform=invalid"
            )
        }
        guard result.error == nil, result.didPersist || allowDeletion else {
            runtimeMessageRecorder(
                Self.deviceKeySaveErrorDescription(result),
                source,
                "keychain",
                "E_PROVIDER_DEVICE_KEY_SAVE_FAILED"
            )
            throw result.error ?? AppError.typedLocal(
                code: "provider_device_key_save_failed",
                category: .local,
                message: localizationManager.localized("operation_failed"),
                detail: "provider_device_key_save_failed"
            )
        }
    }

    private func requireResolvedDeviceKey(_ rawValue: String) throws -> String {
        let resolved = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !resolved.isEmpty else {
            throw AppError.typedLocal(
                code: "gateway_response_missing_device_key",
                category: .internalError,
                message: localizationManager.localized("operation_failed"),
                detail: "gateway response missing device_key"
            )
        }
        return resolved
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

    private static func isAlreadyRetiredGatewayRoute(_ error: AppError) -> Bool {
        [
            "device_key_not_found",
            "device_not_found",
            "route_not_found",
            "channel_type_mismatch",
        ].contains { error.matchesGatewayCode($0) }
    }

    private func gatewayIdentity(_ config: ServerConfig?) -> String {
        guard let config else { return "" }
        let token = config.token?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return "\(config.baseURL.absoluteString)|\(token)"
    }
}
