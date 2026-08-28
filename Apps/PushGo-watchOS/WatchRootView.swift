import SwiftUI

struct WatchRootView: View {
    @Environment(AppEnvironment.self) private var environment: AppEnvironment

    @State private var viewModel = WatchLightStoreViewModel()
    @State private var selection: MainTab = .messages

    var body: some View {
        Group {
#if DEBUG
            if let startupFailureMessage = environment.startupFailureMessage {
                WatchStartupFailureView(message: startupFailureMessage)
            } else {
                watchTabs
            }
#else
            watchTabs
#endif
        }
        .onAppear {
            environment.updateActiveTab(selection)
            Task { @MainActor in
                await viewModel.reload()
            }
            syncSelectionWithPendingTarget()
        }
        .onChange(of: selection) { _, newValue in
            environment.updateActiveTab(newValue)
        }
        .onChange(of: environment.pendingMessageToOpen) { _, _ in
            syncSelectionWithPendingTarget()
        }
        .onChange(of: environment.pendingEventToOpen) { _, _ in
            syncSelectionWithPendingTarget()
        }
        .onChange(of: environment.pendingThingToOpen) { _, _ in
            syncSelectionWithPendingTarget()
        }
        .onChange(of: environment.messageStoreRevision) { _, _ in
            Task { @MainActor in
                await viewModel.reload()
            }
        }
#if DEBUG
        .task {
            for await notification in NotificationCenter.default.notifications(named: .pushgoWatchAutomationSelectTab) {
                guard let rawValue = notification.object as? String,
                      let tab = MainTab(automationIdentifier: rawValue)
                else {
                    continue
                }
                selection = tab
            }
        }
#endif
    }

    private var watchTabs: some View {
        TabView(selection: $selection) {
            WatchMessageListScreen(viewModel: viewModel)
                .tag(MainTab.messages)

            WatchEventListScreen(viewModel: viewModel)
                .tag(MainTab.events)

            WatchThingListScreen(viewModel: viewModel)
                .tag(MainTab.things)

            WatchReceiverHealthScreen()
                .tag(MainTab.health)
        }
        .tabViewStyle(.page(indexDisplayMode: .automatic))
    }

    private func syncSelectionWithPendingTarget() {
        if environment.pendingMessageToOpen != nil {
            selection = .messages
        } else if environment.pendingThingToOpen != nil {
            selection = .things
        } else if environment.pendingEventToOpen != nil {
            selection = .events
        }
    }

}

#if DEBUG
private struct WatchStartupFailureView: View {
    let message: String

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Color.appStateDangerForeground)
                Text("Unable to prepare app data")
                    .font(.headline)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(Color.appTextSecondary)
                    .multilineTextAlignment(.center)
            }
            .padding()
        }
        .accessibilityIdentifier("state.startup.failure")
    }
}
#endif

#Preview {
    WatchRootView()
}
