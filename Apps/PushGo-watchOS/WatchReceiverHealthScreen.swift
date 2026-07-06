import SwiftUI

struct WatchReceiverHealthScreen: View {
    @Environment(AppEnvironment.self) private var environment: AppEnvironment

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                WatchReceiverHealthHeader(state: receiverState)
                WatchReceiverHealthFact(
                    title: "watch_receiver_health_direct_title",
                    message: "watch_receiver_health_direct_message"
                )
                WatchReceiverHealthFact(
                    title: "watch_receiver_health_offline_title",
                    message: "watch_receiver_health_offline_message"
                )
                WatchReceiverHealthFact(
                    title: "watch_receiver_health_sync_title",
                    message: "watch_receiver_health_sync_message"
                )
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .accessibilityIdentifier("screen.receiver.health")
    }

    private var receiverState: WatchReceiverState {
        if environment.watchMode == .standalone, environment.standaloneReady {
            return .ready
        }
        if environment.watchMode == .standalone {
            return .degraded
        }
        return .unprovisioned
    }
}

private struct WatchReceiverHealthHeader: View {
    let state: WatchReceiverState

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("watch_receiver_health_title", systemImage: "applewatch.radiowaves.left.and.right")
                .font(.headline)
            Text(stateTitle)
                .font(.caption.weight(.semibold))
                .foregroundStyle(state == .ready ? .green : .orange)
        }
    }

    private var stateTitle: LocalizedStringKey {
        switch state {
        case .ready:
            "watch_receiver_status_ready"
        case .degraded:
            "watch_receiver_status_degraded"
        case .offline:
            "watch_receiver_status_offline"
        case .provisioning:
            "watch_receiver_status_provisioning"
        case .unprovisioned:
            "watch_receiver_status_unprovisioned"
        case .disabled:
            "watch_receiver_status_disabled"
        }
    }
}

private struct WatchReceiverHealthFact: View {
    let title: LocalizedStringKey
    let message: LocalizedStringKey

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption.weight(.semibold))
            Text(message)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
