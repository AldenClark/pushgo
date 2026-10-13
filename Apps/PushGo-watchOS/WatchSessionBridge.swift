import Foundation

@MainActor
final class WatchSessionBridge {
    static let shared = WatchSessionBridge()

    private let coordinator = WatchConnectivityCoordinator.shared

    private init() {
        coordinator.installHandlers(
            .init(
                linkStateDidChange: { _ in
                    await AppEnvironment.shared.handleWatchSessionReachabilityChanged()
                },
                manifestDidReceive: { manifest in
                    await AppEnvironment.shared.applyWatchSyncManifestFromPhone(manifest)
                },
                eventDidReceive: { event in
                    await Self.handleIncomingEvent(event)
                },
                standalonePackageDidReceive: { package in
                    await AppEnvironment.shared.applyStandaloneProvisioningFromPhone(package.snapshot)
                },
                latestManifestRequested: nil
            )
        )
    }

    func activateIfNeeded() {
        coordinator.activateIfNeeded()
    }

    func consumeForcedReconfigureFlag() async -> Bool {
        await coordinator.consumeForcedReconfigureFlag()
    }

    func clearPersistentState() async {
        await coordinator.clearPersistentState()
    }

    func sendTokenToPhone(_ token: String) {
        coordinator.enqueueReliablePushToken(token)
    }

    func publishControlContext(_ context: WatchControlContext) {
        coordinator.publishControlManifest(context)
    }

    func publishStandaloneReadinessStatusManifest(
        _ status: WatchStandaloneReadinessStatus,
        mode: WatchMode,
        controlGeneration: Int64
    ) {
        coordinator.publishStandaloneReadinessStatusManifest(
            mode: mode,
            controlGeneration: controlGeneration,
            standaloneReadinessStatus: status
        )
    }

    func publishStandaloneProvisioningAckManifest(
        _ ack: WatchStandaloneProvisioningAck,
        mode: WatchMode,
        controlGeneration: Int64
    ) {
        coordinator.publishStandaloneProvisioningAckManifest(
            mode: mode,
            controlGeneration: controlGeneration,
            ack: ack
        )
    }

    func sendStandaloneProvisioningAck(_ ack: WatchStandaloneProvisioningAck) {
        coordinator.enqueueReliableStandaloneProvisioningAck(ack)
    }

    func sendStandaloneProvisioningNack(_ nack: WatchStandaloneProvisioningNack) {
        coordinator.enqueueReliableStandaloneProvisioningNack(nack)
    }

    func requestLatestManifestIfReachable() {
        coordinator.requestLatestManifestIfReachable()
    }

    private static func handleIncomingEvent(_ event: WatchEventEnvelope) async {
        switch event.kind {
        case .standaloneProvisioningInline:
            guard let package = WatchConnectivityWire.decode(StandaloneProvisioningPackage.self, from: event.payload) else {
                return
            }
            await AppEnvironment.shared.applyStandaloneProvisioningFromPhone(package.snapshot)
        case .mirrorActionAck, .mirrorSnapshotInline, .mirrorActionBatch, .mirrorSnapshotAck, .mirrorSnapshotNack, .pushTokenUpdate, .standaloneProvisioningAck, .standaloneProvisioningNack:
            break
        }
    }
}
