import SwiftUI

struct WatchMessageListScreen: View {
    @Environment(\.appEnvironment) private var environment: AppEnvironment
    @Environment(LocalizationManager.self) private var localizationManager: LocalizationManager
    @State private var viewModel = MessageListViewModel()
    @State private var navigationPath: [UUID] = []
    @State private var showFilterSheet = false
    @State private var didLoad = false

    var body: some View {
        NavigationStack(path: $navigationPath) {
            List {
                Section {
                    if viewModel.filteredMessages.isEmpty {
                        emptyState
                    } else {
                        ForEach(viewModel.filteredMessages) { message in
                            NavigationLink(value: message.id) {
                                WatchMessageRowView(message: message)
                            }
                            .listRowInsets(EdgeInsets(top: 6, leading: 10, bottom: 6, trailing: 10))
                            .onAppear {
                                Task {
                                    await viewModel.loadMoreIfNeeded(currentItem: message)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle(localizationManager.localized("messages"))
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showFilterSheet = true
                    } label: {
                        Image(systemName: isFilterActive ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                    }
                }
            }
            .navigationDestination(for: UUID.self) { messageId in
                WatchMessageDetailScreen(messageId: messageId)
            }
            .sheet(isPresented: $showFilterSheet) {
                WatchFilterSheet(
                    selectedChannel: viewModel.selectedChannel,
                    channelSummaries: viewModel.channelSummaries,
                    onSelectChannel: { viewModel.toggleChannelSelection($0) },
                    onClearChannel: { viewModel.clearChannelSelection() }
                )
            }
            .onChange(of: environment.messageStoreRevision) { _, _ in
                Task {
                    await viewModel.refresh()
                }
            }
            .onChange(of: environment.pendingMessageToOpen) { _, id in
                guard let id else { return }
                navigationPath = [id]
            }
            .onAppear {
                guard !didLoad else { return }
                didLoad = true
                Task {
                    await viewModel.refresh()
                }
                if let id = environment.pendingMessageToOpen {
                    navigationPath = [id]
                }
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "tray")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text(localizationManager
                .localized(
                    "you_can_use_the_pushgo_cli_or_other_integration_tools_to_send_a_test_push_to_the_current_device"
                ))
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .listRowInsets(EdgeInsets(top: 12, leading: 0, bottom: 12, trailing: 0))
    }

    private var isFilterActive: Bool {
        viewModel.selectedChannel != nil
    }
}

#Preview {
    WatchMessageListScreen()
}
