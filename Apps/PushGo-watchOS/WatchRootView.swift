import SwiftUI

struct WatchRootView: View {
    @Environment(AppEnvironment.self) private var environment: AppEnvironment

    @State private var viewModel = WatchLightStoreViewModel()
    @State private var selection: MainTab = .messages

    var body: some View {
        TabView(selection: $selection) {
            WatchMessageListScreen(viewModel: viewModel)
                .tag(MainTab.messages)

            WatchEventListScreen(viewModel: viewModel)
                .tag(MainTab.events)

            WatchThingListScreen(viewModel: viewModel)
                .tag(MainTab.things)
        }
        .tabViewStyle(.page(indexDisplayMode: .automatic))
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
        .task(id: automationStateVersion) {
            PushGoWatchAutomationRuntime.shared.publishState(
                environment: environment,
                activeTab: selection.automationIdentifier,
                visibleScreen: selection.automationVisibleScreen
            )
        }
#endif
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

    private var automationStateVersion: String {
        [
            selection.automationIdentifier,
            environment.pendingMessageToOpen ?? "",
            environment.pendingEventToOpen ?? "",
            environment.pendingThingToOpen ?? "",
            String(environment.unreadMessageCount),
            String(environment.totalMessageCount),
            environment.watchMode.rawValue,
        ].joined(separator: "|")
    }
}

#Preview {
    WatchRootView()
}
