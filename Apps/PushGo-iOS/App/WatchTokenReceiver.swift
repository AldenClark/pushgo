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
                    await Self.handleIncomingManifest(manifest, controller: AppEnvironment.shared.watchSyncController)
                },
                eventDidReceive: { event in
                    await Self.handleIncomingEvent(event)
                },
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

    func sendStandaloneProvisioning(_ snapshot: WatchStandaloneProvisioningSnapshot) {
        coordinator.prepareStandaloneProvisioning(snapshot)
    }

    private func refreshAvailability(from state: WatchLinkState) {
        isWatchCompanionAvailable = state.isCompanionAvailable
    }

    static func handleIncomingManifest(_ manifest: WatchSyncManifest, controller: WatchSyncController) async {
        if let status = manifest.standaloneReadinessStatus {
            await controller.handleWatchStandaloneReadinessStatus(status)
        }
        if let ack = manifest.standaloneProvisioningAck {
            await controller.handleWatchStandaloneProvisioningAck(WatchStandaloneProvisioningAck(generation: ack.generation, contentDigest: ack.contentDigest, appliedAt: ack.appliedAt))
        }
    }

    private static func handleIncomingEvent(_ event: WatchEventEnvelope) async {
        switch event.kind {
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
        case .mirrorActionBatch, .mirrorSnapshotAck, .mirrorSnapshotNack, .mirrorActionAck, .mirrorSnapshotInline, .standaloneProvisioningInline:
            break
        }
    }

}
