import Foundation

@MainActor
final class WatchTokenReceiver {
    static let shared = WatchTokenReceiver()

    private let coordinator = WatchConnectivityCoordinator.shared
    private(set) var isWatchCompanionAvailable = false

    private init() {
        coordinator.installHandlers(
            .init(
                linkStateDidChange: { [weak self] state in
                    guard let self else { return }
                    self.refreshAvailability(from: state)
                    await AppEnvironment.shared.handleWatchSessionStateDidChange()
                },
                manifestDidReceive: { manifest in
                    await Self.handleIncomingManifest(manifest)
                },
                eventDidReceive: { event in
                    await Self.handleIncomingEvent(event)
                },
                mirrorPackageDidReceive: nil,
                standalonePackageDidReceive: nil,
                latestManifestRequested: {
                    await AppEnvironment.shared.handleWatchLatestManifestRequested()
                }
            )
        )
        refreshAvailability(from: coordinator.refreshCachedLinkState())
    }

    func activateIfNeeded() {
        coordinator.activateIfNeeded()
        refreshAvailability(from: coordinator.refreshCachedLinkState())
    }

    @discardableResult
    func refreshCompanionAvailability() -> Bool {
        activateIfNeeded()
        return isWatchCompanionAvailable
    }

    func consumeForcedReconfigureFlag() async -> Bool {
        await coordinator.consumeForcedReconfigureFlag()
    }

    func clearPersistentState() async {
        await coordinator.clearPersistentState()
    }

    func publishControlContext(_ context: WatchControlContext) {
        coordinator.publishControlManifest(context)
    }

    func replayLatestManifestIfPossible() {
        coordinator.replayLatestManifestIfPossible()
    }

    func sendMirrorSnapshot(_ snapshot: WatchMirrorSnapshot) {
        coordinator.prepareMirrorSnapshot(snapshot)
    }

    func sendStandaloneProvisioning(_ snapshot: WatchStandaloneProvisioningSnapshot) {
        coordinator.prepareStandaloneProvisioning(snapshot)
    }

    func sendMirrorActionAck(_ ack: WatchMirrorActionAck) {
        coordinator.enqueueReliableMirrorActionAck(ack)
    }

    private func refreshAvailability(from state: WatchLinkState) {
        isWatchCompanionAvailable = state.isCompanionAvailable
    }

    private static func handleIncomingEvent(_ event: WatchEventEnvelope) async {
        switch event.kind {
        case .mirrorActionBatch:
            guard let batch = WatchConnectivityWire.decode(WatchMirrorActionBatch.self, from: event.payload) else {
                return
            }
            await AppEnvironment.shared.applyWatchMirrorActionBatch(batch)
        case .pushTokenUpdate:
            guard let token = WatchConnectivityWire.decode(String.self, from: event.payload) else {
                return
            }
            await AppEnvironment.shared.updateWatchPushToken(token)
        case .standaloneProvisioningAck:
            guard let ack = WatchConnectivityWire.decode(WatchStandaloneProvisioningAck.self, from: event.payload) else {
                return
            }
            await AppEnvironment.shared.handleWatchStandaloneProvisioningAck(ack)
        case .standaloneProvisioningNack:
            guard let nack = WatchConnectivityWire.decode(WatchStandaloneProvisioningNack.self, from: event.payload) else {
                return
            }
            await AppEnvironment.shared.handleWatchStandaloneProvisioningNack(nack)
        case .mirrorSnapshotAck:
            guard let ack = WatchConnectivityWire.decode(WatchMirrorSnapshotAck.self, from: event.payload) else {
                return
            }
            await AppEnvironment.shared.handleWatchMirrorSnapshotAck(ack)
        case .mirrorSnapshotNack:
            guard let nack = WatchConnectivityWire.decode(WatchMirrorSnapshotNack.self, from: event.payload) else {
                return
            }
            await AppEnvironment.shared.handleWatchMirrorSnapshotNack(nack)
        case .mirrorActionAck, .mirrorSnapshotInline, .standaloneProvisioningInline:
            break
        }
    }

    private static func handleIncomingManifest(_ manifest: WatchSyncManifest) async {
        if let effectiveModeStatus = manifest.effectiveModeStatus {
            await AppEnvironment.shared.handleWatchEffectiveModeStatus(effectiveModeStatus)
        } else {
            await AppEnvironment.shared.handleWatchEffectiveModeStatus(
                WatchEffectiveModeStatus(
                    effectiveMode: manifest.mode,
                    sourceControlGeneration: manifest.controlGeneration,
                    appliedAt: Date(),
                    noop: false,
                    status: .applied,
                    failureReason: nil
                )
            )
        }

        if let standaloneReadinessStatus = manifest.standaloneReadinessStatus {
            await AppEnvironment.shared.handleWatchStandaloneReadinessStatus(standaloneReadinessStatus)
        } else if manifest.mode == .mirror {
            await AppEnvironment.shared.handleWatchStandaloneReadinessStatus(
                WatchStandaloneReadinessStatus(
                    effectiveMode: .mirror,
                    standaloneReady: false,
                    sourceControlGeneration: manifest.controlGeneration,
                    provisioningGeneration: manifest.standalonePackage?.generation ?? 0,
                    reportedAt: Date(),
                    failureReason: nil
                )
            )
        }

        if let mirrorAck = manifest.mirrorSnapshotAck,
           mirrorAck.generation > 0
        {
            await AppEnvironment.shared.handleWatchMirrorSnapshotAck(
                WatchMirrorSnapshotAck(
                    generation: mirrorAck.generation,
                    contentDigest: mirrorAck.contentDigest,
                    appliedAt: mirrorAck.appliedAt
                )
            )
        }

        if let standaloneAck = manifest.standaloneProvisioningAck,
           standaloneAck.generation > 0
        {
            await AppEnvironment.shared.handleWatchStandaloneProvisioningAck(
                WatchStandaloneProvisioningAck(
                    generation: standaloneAck.generation,
                    contentDigest: standaloneAck.contentDigest,
                    appliedAt: standaloneAck.appliedAt
                )
            )
        }

        guard manifest.mode == .mirror,
              let generation = manifest.ackCursor?.generation,
              generation > 0
        else {
            return
        }
        await AppEnvironment.shared.handleWatchMirrorSnapshotAck(
            WatchMirrorSnapshotAck(
                generation: generation,
                contentDigest: "",
                appliedAt: Date()
            )
        )
    }
}
