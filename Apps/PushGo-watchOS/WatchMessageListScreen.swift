import SwiftUI

struct WatchMessageListScreen: View {
    @Environment(AppEnvironment.self) private var environment: AppEnvironment
    @Environment(LocalizationManager.self) private var localizationManager: LocalizationManager

    let viewModel: WatchLightStoreViewModel
    @State private var navigationPath: [String] = []
    @State private var didLoad = false

    var body: some View {
        NavigationStack(path: $navigationPath) {
            List {
                Section {
                    if viewModel.messages.isEmpty {
                        emptyState
                    } else {
                        ForEach(viewModel.messages) { message in
                            NavigationLink(value: message.messageId) {
                                WatchLightMessageRowView(message: message)
                            }
                        }
                    }
                }
            }
            .navigationTitle(localizationManager.localized("messages"))
            .accessibilityIdentifier("screen.messages.list")
            .navigationDestination(for: String.self) { messageId in
                WatchMessageDetailScreen(messageId: messageId, viewModel: viewModel)
            }
            .onAppear {
                guard !didLoad else {
                    openPendingMessageIfNeeded()
                    return
                }
                didLoad = true
                Task { @MainActor in
                    await viewModel.reload()
                    openPendingMessageIfNeeded()
                }
            }
            .onChange(of: viewModel.messages) { _, _ in
                openPendingMessageIfNeeded()
            }
            .onChange(of: environment.pendingMessageToOpen) { _, _ in
                openPendingMessageIfNeeded()
            }
#if DEBUG
            .task(id: automationStateVersion) {
                PushGoWatchAutomationRuntime.shared.publishState(
                    environment: environment,
                    activeTab: MainTab.messages.automationIdentifier,
                    visibleScreen: navigationPath.last == nil ? "screen.messages.list" : "screen.message.detail",
                    openedMessageId: navigationPath.last
                )
            }
#endif
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: WatchEntityVisualTokens.sectionSpacing) {
            Image(systemName: "tray")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text(localizationManager.localized(
                "you_can_use_the_pushgo_cli_or_other_integration_tools_to_send_a_test_push_to_the_current_device"
            ))
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .listRowInsets(EdgeInsets(top: 12, leading: 0, bottom: 12, trailing: 0))
    }

    private func openPendingMessageIfNeeded() {
        let trimmed = environment.pendingMessageToOpen?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return }
        guard viewModel.messages.contains(where: { $0.messageId == trimmed }) else { return }
        navigationPath = [trimmed]
        environment.pendingMessageToOpen = nil
    }

    private var automationStateVersion: String {
        [
            navigationPath.last ?? "",
            environment.pendingMessageToOpen ?? "",
            String(environment.unreadMessageCount),
            String(environment.totalMessageCount),
            String(viewModel.messages.count),
        ].joined(separator: "|")
    }
}

private struct WatchLightMessageRowView: View {
    let message: WatchLightMessage

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 8) {
                Text(message.title)
                    .font(.headline)
                    .lineLimit(1)
                Spacer(minLength: 6)
                if let severity = message.severity, !severity.isEmpty {
                    Text(severity.capitalized)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            if !message.body.isEmpty {
                Text(message.body)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
            HStack(spacing: 8) {
                if !message.isRead {
                    Image(systemName: "circle.fill")
                        .font(.system(size: 6))
                }
                Text(watchDateText(message.receivedAt))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, WatchEntityVisualTokens.rowVerticalPadding)
    }
}

#Preview {
    WatchMessageListScreen(viewModel: WatchLightStoreViewModel())
}
