import Observation
import SwiftUI

struct MessageListScreen: View {
    @Environment(LocalizationManager.self) private var localizationManager: LocalizationManager
    @Environment(MessageSearchViewModel.self) private var searchViewModel: MessageSearchViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @Bindable var viewModel: MessageListViewModel
    @Binding var selection: UUID?
    @Binding var batchSelection: Set<UUID>
    @Binding var isBatchMode: Bool
    @State private var pendingScrollTarget: UUID?

    private enum Layout {
        static let rowInsets = EdgeInsets(
            top: EntityVisualTokens.listRowInsetVertical,
            leading: EntityVisualTokens.listRowInsetHorizontal,
            bottom: EntityVisualTokens.listRowInsetVertical + 2,
            trailing: EntityVisualTokens.listRowInsetHorizontal
        )
    }

    var body: some View {
        let baseView = Group {
            if !viewModel.hasLoadedOnce {
                Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if isShowingSearchResults {
                if isBatchMode {
                    searchResultsBatchList
                } else {
                    searchResultsList
                }
            } else if viewModel.filteredMessages.isEmpty {
                emptyState
            } else {
                if isBatchMode {
                    messagesBatchList
                } else {
                    messagesList
                }
            }
        }
        .task {
            try? await Task.sleep(for: .milliseconds(180))
            viewModel.enableChannelSummaries()
        }
        .accessibilityIdentifier("screen.messages.list")
        return baseView
    }

    private var isShowingSearchResults: Bool {
        searchViewModel.hasSearched
    }

    private var messagesList: some View {
        ScrollViewReader { proxy in
            List {
                ForEach(viewModel.filteredMessages) { message in
                    Button {
                        selection = message.id
                    } label: {
                        MessageRowView(message: message)
                            .id(message.rowLayoutKey)
                            .entityListRowTapTarget()
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("message.row.\(message.id.uuidString)")
                    .id(message.id)
                    .listRowInsets(Layout.rowInsets)
                    .alignmentGuide(.listRowSeparatorLeading) { dimensions in
                        dimensions[.leading]
                    }
                    .alignmentGuide(.listRowSeparatorTrailing) { dimensions in
                        dimensions[.trailing] - Layout.rowInsets.trailing
                    }
                    .listRowBackground(EntitySelectionBackground(isSelected: selection == message.id))
                    .onAppear { Task { await viewModel.loadMoreIfNeeded(currentItem: message) } }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(EntityVisualTokens.pageBackground)
            .onAppear { scrollToSelectionIfNeeded(proxy) }
            .onChange(of: selection) { _, newValue in
                pendingScrollTarget = newValue
                scrollToSelectionIfNeeded(proxy)
            }
            .onChange(of: viewModel.filteredMessagesIdentityRevision) { _, _ in
                scrollToSelectionIfNeeded(proxy)
            }
        }
    }

    private var messagesBatchList: some View {
        List {
            ForEach(viewModel.filteredMessages) { message in
                Button {
                    toggleBatchSelection(message.id)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: batchSelection.contains(message.id) ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(batchSelection.contains(message.id) ? .accent : .secondary)
                        MessageRowView(message: message)
                            .id(message.rowLayoutKey)
                    }
                    .entityListRowTapTarget()
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("message.row.\(message.id.uuidString)")
                .id(message.id)
                .listRowInsets(Layout.rowInsets)
                .alignmentGuide(.listRowSeparatorLeading) { dimensions in
                    dimensions[.leading]
                }
                .alignmentGuide(.listRowSeparatorTrailing) { dimensions in
                    dimensions[.trailing] - Layout.rowInsets.trailing
                }
                .listRowBackground(EntitySelectionBackground(isSelected: batchSelection.contains(message.id)))
                .onAppear { Task { await viewModel.loadMoreIfNeeded(currentItem: message) } }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(EntityVisualTokens.pageBackground)
    }

    private var searchResultsList: some View {
        ScrollViewReader { proxy in
            List {
                if searchViewModel.displayedResults.isEmpty {
                    searchPlaceholderRow
                } else {
                    Section {
                        ForEach(searchViewModel.displayedResults) { message in
                            Button {
                                selection = message.id
                            } label: {
                                MessageRowView(message: message)
                                    .id(message.rowLayoutKey)
                                    .entityListRowTapTarget()
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("message.row.\(message.id.uuidString)")
                            .id(message.id)
                            .listRowInsets(Layout.rowInsets)
                            .alignmentGuide(.listRowSeparatorLeading) { dimensions in
                                dimensions[.leading]
                            }
                            .alignmentGuide(.listRowSeparatorTrailing) { dimensions in
                                dimensions[.trailing] - Layout.rowInsets.trailing
                            }
                            .listRowBackground(EntitySelectionBackground(isSelected: selection == message.id))
                            .onAppear { searchViewModel.loadMoreIfNeeded(currentItem: message) }
                        }
                        if searchViewModel.hasMore {
                            HStack {
                                Spacer()
                                ProgressView().progressViewStyle(.circular)
                                Spacer()
                            }
                            .listRowInsets(Layout.rowInsets)
                        }
                    } header: {
                        Text(localizationManager.localized("found_number_results", searchViewModel.totalResults))
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(EntityVisualTokens.pageBackground)
            .onAppear { scrollToSelectionIfNeeded(proxy) }
            .onChange(of: selection) { _, newValue in
                pendingScrollTarget = newValue
                scrollToSelectionIfNeeded(proxy)
            }
            .onChange(of: searchViewModel.displayedResultsIdentityRevision) { _, _ in
                scrollToSelectionIfNeeded(proxy)
            }
        }
    }

    private var searchResultsBatchList: some View {
        List {
            if searchViewModel.displayedResults.isEmpty {
                searchPlaceholderRow
            } else {
                Section {
                    ForEach(searchViewModel.displayedResults) { message in
                        Button {
                            toggleBatchSelection(message.id)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: batchSelection.contains(message.id) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(batchSelection.contains(message.id) ? .accent : .secondary)
                                MessageRowView(message: message)
                                    .id(message.rowLayoutKey)
                            }
                            .entityListRowTapTarget()
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("message.row.\(message.id.uuidString)")
                        .id(message.id)
                        .listRowInsets(Layout.rowInsets)
                        .alignmentGuide(.listRowSeparatorLeading) { dimensions in
                            dimensions[.leading]
                        }
                        .alignmentGuide(.listRowSeparatorTrailing) { dimensions in
                            dimensions[.trailing] - Layout.rowInsets.trailing
                        }
                        .listRowBackground(EntitySelectionBackground(isSelected: batchSelection.contains(message.id)))
                        .onAppear { searchViewModel.loadMoreIfNeeded(currentItem: message) }
                    }
                    if searchViewModel.hasMore {
                        HStack {
                            Spacer()
                            ProgressView().progressViewStyle(.circular)
                            Spacer()
                        }
                        .listRowInsets(Layout.rowInsets)
                    }
                } header: {
                    Text(localizationManager.localized("found_number_results", searchViewModel.totalResults))
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(EntityVisualTokens.pageBackground)
    }

    private func toggleBatchSelection(_ messageId: UUID) {
        if batchSelection.contains(messageId) {
            batchSelection.remove(messageId)
        } else {
            batchSelection.insert(messageId)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 24) {
            VStack(spacing: 12) {
                Image(systemName: "tray")
                    .font(.largeTitle)
                    .foregroundStyle(Color.appTextSecondary)
                    .accessibilityHidden(true)
                Text(localizationManager.localized("no_messages_yet"))
                    .font(.headline)
                Text(localizationManager.localized(
                    "you_can_use_the_pushgo_cli_or_other_integration_tools_to_send_a_test_push_to_the_current_device"
                ))
                .font(.subheadline)
                .foregroundStyle(Color.appTextSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            }
            .frame(maxWidth: .infinity)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.top, 48)
        .padding(.horizontal, 24)
    }

    private var searchPlaceholderRow: some View {
        MessageSearchPlaceholderView(
            imageName: "questionmark.circle",
            title: "no_matching_results",
            detailKey: "try_changing_a_keyword_or_adjusting_the_filter_conditions"
        )
        .padding(.vertical, 60)
        .frame(maxWidth: .infinity, alignment: .center)
        .listRowInsets(EdgeInsets())
    }

    private func scrollToSelectionIfNeeded(_ proxy: ScrollViewProxy) {
        guard let target = pendingScrollTarget ?? selection else { return }
        let existsInMessages = viewModel.filteredMessages.contains { $0.id == target }
        let existsInSearch = searchViewModel.displayedResults.contains { $0.id == target }
        guard existsInMessages || existsInSearch else { return }
        if reduceMotion {
            proxy.scrollTo(target, anchor: .center)
        } else {
            withAnimation(.easeInOut(duration: 0.2)) {
                proxy.scrollTo(target, anchor: .center)
            }
        }
        pendingScrollTarget = nil
    }
}
