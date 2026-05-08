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
    private let platform = "ios"
    private let channelType = "apns"
    private let providerRouteResultReuseInterval: TimeInterval = 25

    private var providerRouteTask: Task<String, Error>?
    private var providerRouteTaskKey: String?
    private var lastProviderRouteResultKey: String?
    private var lastProviderRouteDeviceKey: String?
    private var lastProviderRouteResolvedAt: Date = .distantPast
    private var lastWakeupRouteFingerprint: String?

    init(
        dataStore: LocalDataStore,
        channelSubscriptionService: ChannelSubscriptionService,
        localizationManager: LocalizationManager,
        refreshAutomationState: @escaping AutomationStateRefresher,
        runtimeMessageRecorder: @escaping RuntimeMessageRecorder
    ) {
        self.dataStore = dataStore
        self.channelSubscriptionService = channelSubscriptionService
        self.localizationManager = localizationManager
        self.refreshAutomationState = refreshAutomationState
        self.runtimeMessageRecorder = runtimeMessageRecorder
    }

    func schedulePreviousGatewayDeviceCleanup(
        previousConfig: ServerConfig?,
        previousDeviceKey: String?,
        nextConfig: ServerConfig?
    ) {
        guard let previousConfig else { return }
        let trimmedDeviceKey = previousDeviceKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmedDeviceKey.isEmpty else { return }
        guard gatewayIdentity(previousConfig) != gatewayIdentity(nextConfig) else { return }
        let service = channelSubscriptionService
        let channelType = channelType
        Task(priority: .utility) {
            do {
                try await service.deleteDeviceChannel(
                    baseURL: previousConfig.baseURL,
                    token: previousConfig.token,
                    deviceKey: trimmedDeviceKey,
                    channelType: channelType
                )
            } catch {}
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
            let cachedApnsKey = await self.dataStore.cachedDeviceKey(
                for: self.platform,
                channelType: self.channelType
            )?.trimmingCharacters(in: .whitespacesAndNewlines)
            let registered = try await self.channelSubscriptionService.registerDevice(
                baseURL: config.baseURL,
                token: config.token,
                platform: self.platform,
                existingDeviceKey: cachedApnsKey?.isEmpty == false ? cachedApnsKey : nil
            )
            let bootstrapDeviceKey = registered.deviceKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !bootstrapDeviceKey.isEmpty else {
                throw AppError.typedLocal(
                    code: "gateway_response_missing_device_key",
                    category: .internalError,
                    message: self.localizationManager.localized("operation_failed"),
                    detail: "gateway response missing device_key"
                )
            }
            let route = try await self.channelSubscriptionService.upsertDeviceChannel(
                baseURL: config.baseURL,
                token: config.token,
                deviceKey: bootstrapDeviceKey,
                platform: self.platform,
                channelType: self.channelType,
                providerToken: normalizedProviderToken
            )
            let resolvedDeviceKey = route.deviceKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !resolvedDeviceKey.isEmpty else {
                throw AppError.typedLocal(
                    code: "gateway_response_missing_device_key",
                    category: .internalError,
                    message: self.localizationManager.localized("operation_failed"),
                    detail: "gateway response missing device_key"
                )
            }
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

    func persistProviderDeviceKey(_ deviceKey: String, source: String) async throws {
        let result = await dataStore.saveCachedDeviceKey(
            deviceKey,
            for: platform,
            channelType: channelType
        )
        try requireProviderDeviceKeyPersistence(result, source: source)
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
        source: String
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
        guard result.error == nil, result.didPersist else {
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

    private func gatewayIdentity(_ config: ServerConfig?) -> String {
        guard let config else { return "" }
        let token = config.token?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return "\(config.baseURL.absoluteString)|\(token)"
    }
}
