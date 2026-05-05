import Foundation
import Observation

enum WatchModeSwitchRequestResult: Equatable {
    case applied
    case timedOut
}

@MainActor
@Observable
final class WatchSyncController {
    private struct WatchControlSemanticState: Equatable {
        let mode: WatchMode
        let mirrorSnapshotGeneration: Int64
        let standaloneProvisioningGeneration: Int64
        let pendingMirrorActionAckGeneration: Int64
    }

    typealias MessageStateCoordinatorProvider = @MainActor () -> MessageStateCoordinator?
    typealias ServerConfigProvider = @MainActor () -> ServerConfig?
    typealias RuntimeErrorRecorder = @MainActor (Error, String) -> Void
    typealias RuntimeMessageRecorder = @MainActor (String, String) -> Void

    private let dataStore: LocalDataStore
    @ObservationIgnored private let messageStateCoordinatorProvider: MessageStateCoordinatorProvider
    @ObservationIgnored private let serverConfigProvider: ServerConfigProvider
    @ObservationIgnored private let runtimeErrorRecorder: RuntimeErrorRecorder
    @ObservationIgnored private let runtimeMessageRecorder: RuntimeMessageRecorder

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

    private(set) var watchMode: WatchMode = .mirror
    private(set) var effectiveWatchMode: WatchMode = .mirror
    private(set) var standaloneReady = false
    private(set) var watchModeSwitchStatus: WatchModeSwitchStatus = .idle
    private(set) var isWatchCompanionAvailable = false

    init(
        dataStore: LocalDataStore,
        messageStateCoordinatorProvider: @escaping MessageStateCoordinatorProvider,
        serverConfigProvider: @escaping ServerConfigProvider,
        runtimeErrorRecorder: @escaping RuntimeErrorRecorder,
        runtimeMessageRecorder: @escaping RuntimeMessageRecorder
    ) {
        self.dataStore = dataStore
        self.messageStateCoordinatorProvider = messageStateCoordinatorProvider
        self.serverConfigProvider = serverConfigProvider
        self.runtimeErrorRecorder = runtimeErrorRecorder
        self.runtimeMessageRecorder = runtimeMessageRecorder
    }

    func loadPersistedState() async {
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
    }

    func completeBootstrapSync() async {
        await publishWatchControlContext()
        if watchMode == .standalone {
            requestWatchStandaloneProvisioningSync(immediate: true)
        }
        requestWatchMirrorSnapshotSync(immediate: watchMode == .standalone)
        scheduleWatchModeReplayIfNeeded(reason: "bootstrap", immediate: true)
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

    func resetWatchConnectivityStateForMigration() async {
        pendingWatchMirrorSnapshotTask?.cancel()
        pendingWatchProvisioningTask?.cancel()
        cancelWatchMirrorSnapshotAckRetry()
        cancelWatchStandaloneProvisioningAckRetry()
        cancelWatchModeReplay()
        watchMode = .mirror
        effectiveWatchMode = .mirror
        standaloneReady = false
        watchModeSwitchStatus = .idle
        isWatchCompanionAvailable = WatchTokenReceiver.shared.refreshCompanionAvailability()
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
           watchModeSwitchStatus != .timedOut {
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

    func requestWatchMirrorSnapshotSync(immediate: Bool = false) {
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

    func requestWatchStandaloneProvisioningSync(immediate: Bool) {
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

    func applyWatchMirrorActionBatch(_ batch: WatchMirrorActionBatch) async {
        guard batch.mode == .mirror else { return }
        guard !batch.actions.isEmpty else { return }
        guard let messageStateCoordinator = messageStateCoordinatorProvider() else { return }

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
            self.runtimeMessageRecorder(
                "watch mode replay exhausted reason=\(reason)",
                "watch.mode_replay"
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
            runtimeErrorRecorder(error, "watch.publish_mirror_snapshot")
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
        let serverConfig = serverConfigProvider()
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

    private func nextWatchGeneration() -> Int64 {
        Int64((Date().timeIntervalSince1970 * 1_000_000).rounded())
    }
}
