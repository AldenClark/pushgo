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
                mirrorPackageDidReceive: { package in
                    await AppEnvironment.shared.applyMirrorSnapshotFromPhone(package.snapshot)
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

    func publishEffectiveModeStatusManifest(
        _ status: WatchEffectiveModeStatus,
        mode: WatchMode,
        controlGeneration: Int64,
        standaloneReadinessStatus: WatchStandaloneReadinessStatus? = nil
    ) {
        coordinator.publishEffectiveModeStatusManifest(
            mode: mode,
            controlGeneration: controlGeneration,
            effectiveModeStatus: status,
            standaloneReadinessStatus: standaloneReadinessStatus
        )
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

    func publishMirrorSnapshotAckManifest(
        _ ack: WatchMirrorSnapshotAck,
        mode: WatchMode,
        controlGeneration: Int64
    ) {
        coordinator.publishMirrorSnapshotAckManifest(
            mode: mode,
            controlGeneration: controlGeneration,
            ack: ack
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

    func sendMirrorActionBatch(_ batch: WatchMirrorActionBatch) {
        coordinator.enqueueReliableMirrorActionBatch(batch)
    }

    func sendMirrorSnapshotAck(_ ack: WatchMirrorSnapshotAck) {
        coordinator.enqueueReliableMirrorSnapshotAck(ack)
    }

    func sendMirrorSnapshotNack(_ nack: WatchMirrorSnapshotNack) {
        coordinator.enqueueReliableMirrorSnapshotNack(nack)
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
        case .mirrorActionAck:
            guard let ack = WatchConnectivityWire.decode(WatchMirrorActionAck.self, from: event.payload) else {
                return
            }
            await AppEnvironment.shared.applyWatchMirrorActionAckFromPhone(ack)
        case .mirrorSnapshotInline:
            guard let package = WatchConnectivityWire.decode(MirrorSnapshotPackage.self, from: event.payload) else {
                return
            }
            await AppEnvironment.shared.applyMirrorSnapshotFromPhone(package.snapshot)
        case .standaloneProvisioningInline:
            guard let package = WatchConnectivityWire.decode(StandaloneProvisioningPackage.self, from: event.payload) else {
                return
            }
            await AppEnvironment.shared.applyStandaloneProvisioningFromPhone(package.snapshot)
        case .mirrorActionBatch, .mirrorSnapshotAck, .mirrorSnapshotNack, .pushTokenUpdate, .standaloneProvisioningAck, .standaloneProvisioningNack:
            break
        }
    }
}
