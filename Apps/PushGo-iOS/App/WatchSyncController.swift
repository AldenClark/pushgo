import Foundation
import Observation

#if DEBUG
struct WatchProvisioningAutomationStatus: Equatable, Sendable {
    let generation: Int64
    let digest: String?
    let acknowledgedGeneration: Int64?
    let acknowledgedDigest: String?

    var isAcknowledged: Bool {
        guard generation > 0, let digest, !digest.isEmpty else { return false }
        return acknowledgedGeneration == generation && acknowledgedDigest == digest
    }
}
#endif

@MainActor
@Observable
final class WatchSyncController {
    private struct WatchControlSemanticState: Equatable {
        let mode: WatchMode
        let standaloneProvisioningGeneration: Int64
    }

    typealias ServerConfigProvider = @MainActor () -> ServerConfig?

    private let dataStore: LocalDataStore
    @ObservationIgnored private let serverConfigProvider: ServerConfigProvider

    @ObservationIgnored private var pendingWatchProvisioningTask: Task<Void, Never>?
    @ObservationIgnored private var pendingWatchStandaloneProvisioningAckRetryTask: Task<Void, Never>?
    @ObservationIgnored private let watchSyncDebounceDelay: TimeInterval = 0.5
    @ObservationIgnored private let watchStandaloneProvisioningAckRetryDelay: TimeInterval = 5
    @ObservationIgnored private let watchStandaloneProvisioningAckRetryAttempts = 6
    @ObservationIgnored private var watchControlGeneration: Int64 = 0
    @ObservationIgnored private var watchStandaloneProvisioningGeneration: Int64 = 0
    @ObservationIgnored private var lastObservedWatchStandaloneReadinessReportedAt = Date.distantPast
    @ObservationIgnored private var lastPublishedWatchControlSemanticState: WatchControlSemanticState?
    @ObservationIgnored private var lastPublishedWatchStandaloneProvisioningDigest: String?
    @ObservationIgnored private var lastWatchStandaloneProvisioningAck: WatchStandaloneProvisioningAck?
    @ObservationIgnored private var lastWatchStandaloneProvisioningNack: WatchStandaloneProvisioningNack?

    #if DEBUG
    var standaloneProvisioningAutomationStatus: WatchProvisioningAutomationStatus {
        WatchProvisioningAutomationStatus(
            generation: watchStandaloneProvisioningGeneration,
            digest: lastPublishedWatchStandaloneProvisioningDigest,
            acknowledgedGeneration: lastWatchStandaloneProvisioningAck?.generation,
            acknowledgedDigest: lastWatchStandaloneProvisioningAck?.contentDigest
        )
    }
    #endif

    private(set) var standaloneReady = false
    private(set) var watchReceiverState: WatchReceiverState = .unprovisioned
    private(set) var isWatchCompanionAvailable = false

    init(
        dataStore: LocalDataStore,
        serverConfigProvider: @escaping ServerConfigProvider
    ) {
        self.dataStore = dataStore
        self.serverConfigProvider = serverConfigProvider
    }

    #if DEBUG
    // The native regression drives this real controller without starting a
    // second WCSession or changing the running app's publication state.
    convenience init(dataStore: LocalDataStore, regressionPublication: WatchPublicationState) {
        self.init(dataStore: dataStore, serverConfigProvider: { nil })
        watchControlGeneration = regressionPublication.syncGenerations.controlGeneration
        watchStandaloneProvisioningGeneration = regressionPublication.syncGenerations.standaloneProvisioningGeneration
        lastPublishedWatchStandaloneProvisioningDigest = regressionPublication.standaloneProvisioningContentDigest
    }
    #endif

    func loadPersistedState() async {
        _ = await WatchTokenReceiver.shared.consumeForcedReconfigureFlag()
        let publication = await dataStore.loadWatchPublicationState()
        watchControlGeneration = publication.syncGenerations.controlGeneration
        watchStandaloneProvisioningGeneration = publication.syncGenerations.standaloneProvisioningGeneration
        lastPublishedWatchStandaloneProvisioningDigest = publication.standaloneProvisioningContentDigest
        isWatchCompanionAvailable = WatchTokenReceiver.shared.refreshCompanionAvailability()
    }

    func completeBootstrapSync() async {
        await publishWatchControlContext()
        requestWatchStandaloneProvisioningSync(immediate: true)
    }

    func handleWatchSessionStateDidChange() async {
        isWatchCompanionAvailable = WatchTokenReceiver.shared.refreshCompanionAvailability()
        if isWatchCompanionAvailable {
            await publishWatchControlContext(force: true)
            requestWatchStandaloneProvisioningSync(immediate: true)
        } else {
            standaloneReady = false
            watchReceiverState = .offline
            cancelWatchStandaloneProvisioningAckRetry()
        }
    }

    func refreshWatchCompanionAvailability() async {
        await handleWatchSessionStateDidChange()
    }

    func handleWatchLatestManifestRequested() async {
        requestWatchStandaloneProvisioningSync(immediate: true)
    }

    func resetWatchConnectivityStateForMigration() async {
        pendingWatchProvisioningTask?.cancel()
        cancelWatchStandaloneProvisioningAckRetry()
        standaloneReady = false
        isWatchCompanionAvailable = WatchTokenReceiver.shared.refreshCompanionAvailability()
        watchControlGeneration = 0
        watchStandaloneProvisioningGeneration = 0
        lastPublishedWatchControlSemanticState = nil
        lastPublishedWatchStandaloneProvisioningDigest = nil
        lastWatchStandaloneProvisioningAck = nil
        lastWatchStandaloneProvisioningNack = nil
        await dataStore.saveWatchPublicationState(.empty)
    }

    func handleWatchStandaloneProvisioningAck(_ ack: WatchStandaloneProvisioningAck) async {
        guard ack.generation == watchStandaloneProvisioningGeneration,
              let expectedDigest = lastPublishedWatchStandaloneProvisioningDigest,
              !expectedDigest.isEmpty,
              ack.contentDigest == expectedDigest
        else { return }
        // An ACK confirms the saved configuration, not Gateway registration.
        // Readiness owns the receiving state even when both share a manifest.
        lastWatchStandaloneProvisioningAck = ack
        cancelWatchStandaloneProvisioningAckRetry()
    }

    func handleWatchStandaloneReadinessStatus(_ status: WatchStandaloneReadinessStatus) async {
        guard status.sourceControlGeneration >= watchControlGeneration else { return }
        guard status.provisioningGeneration == watchStandaloneProvisioningGeneration else { return }
        guard status.reportedAt >= lastObservedWatchStandaloneReadinessReportedAt else { return }
        guard status.reportedAt >= (lastWatchStandaloneProvisioningNack?.reportedAt ?? .distantPast) else { return }
        lastObservedWatchStandaloneReadinessReportedAt = status.reportedAt

        let nextReady = status.effectiveMode == .standalone && status.standaloneReady
        standaloneReady = nextReady
        watchReceiverState = nextReady ? .ready : .degraded
    }

    func handleWatchStandaloneProvisioningNack(_ nack: WatchStandaloneProvisioningNack) async {
        guard nack.generation == watchStandaloneProvisioningGeneration,
              nack.contentDigest == lastPublishedWatchStandaloneProvisioningDigest,
              nack.reportedAt >= lastObservedWatchStandaloneReadinessReportedAt,
              nack.reportedAt >= (lastWatchStandaloneProvisioningNack?.reportedAt ?? .distantPast)
        else { return }
        lastWatchStandaloneProvisioningNack = nack
        standaloneReady = false
        watchReceiverState = .degraded
        guard isWatchCompanionAvailable else { return }
        await publishWatchControlContext()
        requestWatchStandaloneProvisioningSync(immediate: true)
    }

    func requestWatchStandaloneProvisioningSync(immediate: Bool) {
        guard isWatchCompanionAvailable else { return }
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


    private func currentWatchPublicationState() -> WatchPublicationState {
        WatchPublicationState(
            syncGenerations: WatchSyncGenerationState(
                controlGeneration: watchControlGeneration,
                standaloneProvisioningGeneration: watchStandaloneProvisioningGeneration
            ),
            standaloneProvisioningContentDigest: lastPublishedWatchStandaloneProvisioningDigest
        )
    }

    private func persistWatchPublicationState() async {
        await dataStore.saveWatchPublicationState(currentWatchPublicationState())
    }

    private func publishWatchControlContext(force: Bool = false) async {
        let semanticState = WatchControlSemanticState(
            mode: .standalone,
            standaloneProvisioningGeneration: watchStandaloneProvisioningGeneration
        )
        guard force || semanticState != lastPublishedWatchControlSemanticState else { return }
        let context = WatchControlContext(
            mode: .standalone,
            controlGeneration: watchControlGeneration,
            standaloneProvisioningGeneration: watchStandaloneProvisioningGeneration
        )
        lastPublishedWatchControlSemanticState = semanticState
        await persistWatchPublicationState()
        WatchTokenReceiver.shared.publishControlContext(context)
    }

    private func publishWatchStandaloneProvisioning() async {
        let sortedChannels = await currentStandaloneProvisioningChannels()
        let watchAlertWindowMinutes = await dataStore.loadWatchAlertWindowMinutes()
        let serverConfig = serverConfigProvider()
        let contentDigest = WatchStandaloneProvisioningSnapshot.contentDigest(
            serverConfig: serverConfig,
            notificationKeyMaterial: serverConfig?.notificationKeyMaterial,
            channels: sortedChannels,
            watchAlertWindowMinutes: watchAlertWindowMinutes
        )
        let shouldReuseGeneration =
            watchStandaloneProvisioningGeneration > 0 &&
            lastPublishedWatchStandaloneProvisioningDigest == contentDigest
        let generation = shouldReuseGeneration ? watchStandaloneProvisioningGeneration : nextWatchGeneration()
        if !shouldReuseGeneration {
            standaloneReady = false
            watchReceiverState = .provisioning
            lastObservedWatchStandaloneReadinessReportedAt = .distantPast
            lastWatchStandaloneProvisioningAck = nil
            lastWatchStandaloneProvisioningNack = nil
        }
        watchStandaloneProvisioningGeneration = generation
        let snapshot = WatchStandaloneProvisioningSnapshot(
            generation: generation,
            mode: .standalone,
            serverConfig: serverConfig,
            notificationKeyMaterial: serverConfig?.notificationKeyMaterial,
            channels: sortedChannels,
            contentDigest: contentDigest,
            watchAlertWindowMinutes: watchAlertWindowMinutes
        )
        lastPublishedWatchStandaloneProvisioningDigest = snapshot.contentDigest
        WatchTokenReceiver.shared.sendStandaloneProvisioning(snapshot)
        await persistWatchPublicationState()
        await publishWatchControlContext()
        scheduleWatchStandaloneProvisioningAckRetry(for: generation)
    }

    private func currentStandaloneProvisioningChannels() async -> [WatchStandaloneChannelCredential] {
        let activeSubscriptions = (try? await dataStore.loadChannelSubscriptions(includeDeleted: false)) ?? []
        let fallbackGateway = serverConfigProvider()?.gatewayKey ?? ""
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
        guard isWatchCompanionAvailable else { return }
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
                guard self.isWatchCompanionAvailable,
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

    private func nextWatchGeneration() -> Int64 {
        Int64((Date().timeIntervalSince1970 * 1_000_000).rounded())
    }
}
