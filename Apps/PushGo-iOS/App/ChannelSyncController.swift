import Foundation
import Observation

@MainActor
@Observable
final class ChannelSyncController {
    typealias ServerConfigProvider = @MainActor () -> ServerConfig?
    typealias WatchProvisioningRequester = @MainActor (_ immediate: Bool) -> Void
    typealias RuntimeErrorRecorder = @MainActor (Error, String) -> Void
    typealias ToastPresenter = @MainActor (String) -> Void

    private let dataStore: LocalDataStore
    private let pushRegistrationService: PushRegistrationService
    private let channelSubscriptionService: ChannelSubscriptionService
    private let providerRouteController: ProviderRouteController
    private let localizationManager: LocalizationManager
    @ObservationIgnored private let serverConfigProvider: ServerConfigProvider
    @ObservationIgnored private let requestWatchStandaloneProvisioningSync: WatchProvisioningRequester
    @ObservationIgnored private let recordRuntimeError: RuntimeErrorRecorder
    @ObservationIgnored private let showToast: ToastPresenter
    @ObservationIgnored private let platform = "ios"

    private(set) var channelSubscriptions: [ChannelSubscription] = []
    @ObservationIgnored private var channelSubscriptionLookup: [String: ChannelSubscription] = [:]

    init(
        dataStore: LocalDataStore,
        pushRegistrationService: PushRegistrationService,
        channelSubscriptionService: ChannelSubscriptionService,
        providerRouteController: ProviderRouteController,
        localizationManager: LocalizationManager,
        serverConfigProvider: @escaping ServerConfigProvider,
        requestWatchStandaloneProvisioningSync: @escaping WatchProvisioningRequester,
        recordRuntimeError: @escaping RuntimeErrorRecorder,
        showToast: @escaping ToastPresenter
    ) {
        self.dataStore = dataStore
        self.pushRegistrationService = pushRegistrationService
        self.channelSubscriptionService = channelSubscriptionService
        self.providerRouteController = providerRouteController
        self.localizationManager = localizationManager
        self.serverConfigProvider = serverConfigProvider
        self.requestWatchStandaloneProvisioningSync = requestWatchStandaloneProvisioningSync
        self.recordRuntimeError = recordRuntimeError
        self.showToast = showToast
    }

    func refreshChannelSubscriptions(syncWatch: Bool = true, immediateStandalone: Bool = false) async {
        guard let gatewayKey = serverConfigProvider()?.gatewayKey else {
            channelSubscriptions = []
            channelSubscriptionLookup = [:]
            if syncWatch {
                requestWatchStandaloneProvisioningSync(immediateStandalone)
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
            let normalizedActive = normalizeAndDedupeSubscriptions(active)
            let normalizedAll = normalizeAndDedupeSubscriptions(all)
            channelSubscriptions = normalizedActive
            channelSubscriptionLookup = normalizedAll.reduce(into: [String: ChannelSubscription]()) { result, item in
                result[item.channelId] = item
            }
        } catch {
            channelSubscriptions = []
            channelSubscriptionLookup = [:]
        }

        if syncWatch {
            requestWatchStandaloneProvisioningSync(immediateStandalone)
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

    func handlePushTokenUpdate() {
        Task { @MainActor in
            do {
                if let latestToken = try? await pushRegistrationService.awaitToken() {
                    if let config = serverConfigProvider() {
                        await providerRouteController.persistPushTokenAndRotateRoute(
                            config: config,
                            token: latestToken
                        )
                    } else {
                        await dataStore.saveCachedPushToken(latestToken, for: platform)
                    }
                }
                if serverConfigProvider() != nil {
                    try await syncSubscriptionsIfNeeded()
                }
                if let config = serverConfigProvider(),
                   let token = await dataStore.cachedPushToken(for: platform)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                   !token.isEmpty
                {
                    await providerRouteController.syncProviderPullRoute(
                        config: config,
                        providerToken: token
                    )
                }
            } catch {
                let message = AppError.wrap(
                    error,
                    fallbackMessage: localizationManager.localized("unable_to_sync_channels"),
                    code: "subscription_sync_failed"
                ).errorDescription ?? localizationManager.localized("unable_to_sync_channels")
                showToast(localizationManager.localized(
                    "unable_to_sync_channels_placeholder",
                    message
                ))
            }
        }
    }

    func syncSubscriptionsOnLaunch() async {
        guard serverConfigProvider() != nil else { return }
        do {
            try await syncSubscriptionsIfNeeded()
        } catch let appError as AppError {
            recordRuntimeError(appError, "channel.sync.launch")
            showToast(appError.errorDescription ?? localizationManager.localized("unable_to_sync_channels"))
        } catch {
            recordRuntimeError(error, "channel.sync.launch")
            let message = AppError.wrap(
                error,
                fallbackMessage: localizationManager.localized("unable_to_sync_channels"),
                code: "subscription_sync_failed"
            ).errorDescription ?? localizationManager.localized("unable_to_sync_channels")
            showToast(localizationManager.localized(
                "unable_to_sync_channels_placeholder",
                message
            ))
        }
    }

    func syncSubscriptionsOnChannelListEntry() async {
        guard serverConfigProvider() != nil else {
            await refreshChannelSubscriptions()
            return
        }
        do {
            try await syncSubscriptionsIfNeeded()
        } catch let appError as AppError {
            recordRuntimeError(appError, "channel.sync.entry")
            showToast(appError.errorDescription ?? localizationManager.localized("unable_to_sync_channels"))
        } catch {
            recordRuntimeError(error, "channel.sync.entry")
            let message = AppError.wrap(
                error,
                fallbackMessage: localizationManager.localized("unable_to_sync_channels"),
                code: "subscription_sync_failed"
            ).errorDescription ?? localizationManager.localized("unable_to_sync_channels")
            showToast(localizationManager.localized(
                "unable_to_sync_channels_placeholder",
                message
            ))
        }
    }

    func refreshPrivateChannelRouteState() async {
        await syncPrivateChannelState()
    }

    func ensureActivePushToken(serverConfig: ServerConfig) async throws -> String {
        let token = try await pushRegistrationService.awaitToken()
        await providerRouteController.persistPushTokenAndRotateRoute(config: serverConfig, token: token)
        return token
    }

    func syncSubscriptionsIfNeeded() async throws {
        guard let config = serverConfigProvider() else { throw AppError.noServer }
        let gatewayKey = config.gatewayKey

        let credentials = try await dataStore.activeChannelCredentials(gateway: gatewayKey)
        let token = try await ensureActivePushToken(serverConfig: config)
        guard !credentials.isEmpty else {
            await refreshChannelSubscriptions()
            return
        }
        let deviceKey = try await providerRouteController.ensureProviderRoute(
            config: config,
            providerToken: token
        )
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
                localizationManager.localized(
                    "channel_password_mismatch_removed",
                    "\(limited.joined(separator: ", "))\(suffix)"
                )
            )
        }
        await refreshChannelSubscriptions()
    }

    private func syncPrivateChannelState() async {
        guard let config = serverConfigProvider() else { return }
        if let token = await dataStore.cachedPushToken(for: platform)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !token.isEmpty
        {
            await providerRouteController.syncProviderPullRoute(config: config, providerToken: token)
        }
    }

    private func normalizeAndDedupeSubscriptions(_ items: [ChannelSubscription]) -> [ChannelSubscription] {
        var byChannelId: [String: ChannelSubscription] = [:]
        byChannelId.reserveCapacity(items.count)
        for item in items {
            let channelId = item.channelId.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !channelId.isEmpty else { continue }
            let displayNameTrimmed = item.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedItem = ChannelSubscription(
                gateway: item.gateway,
                channelId: channelId,
                displayName: displayNameTrimmed.isEmpty ? channelId : displayNameTrimmed,
                updatedAt: item.updatedAt,
                lastSyncedAt: item.lastSyncedAt
            )
            if let existing = byChannelId[channelId], existing.updatedAt > normalizedItem.updatedAt {
                continue
            }
            byChannelId[channelId] = normalizedItem
        }
        return byChannelId.values.sorted { lhs, rhs in
            if lhs.channelId != rhs.channelId {
                return lhs.channelId < rhs.channelId
            }
            return lhs.updatedAt > rhs.updatedAt
        }
    }
}
