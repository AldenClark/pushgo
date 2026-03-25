import AppKit
import Observation
import SwiftUI

struct MessageListScreen: View {
    @Environment(LocalizationManager.self) private var localizationManager: LocalizationManager
    @Environment(MessageSearchViewModel.self) private var searchViewModel: MessageSearchViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @Bindable var viewModel: MessageListViewModel
    @Binding var selection: UUID?
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
                searchResultsList
            } else if viewModel.filteredMessages.isEmpty {
                emptyState
            } else {
                messagesList
            }
        }
        .task {
            try? await Task.sleep(nanoseconds: 180_000_000)
            viewModel.enableChannelSummaries()
        }
        .accessibilityIdentifier("screen.messages.list")
        .navigationTitle(localizationManager.localized("messages"))
        let titledView = applyTitleToolbarIfNeeded(baseView)
        return applySearchIfNeeded(titledView)
    }

    @ViewBuilder
    private func applyTitleToolbarIfNeeded<Content: View>(_ content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content
        } else {
            content.toolbar {
                ToolbarItem(placement: .navigation) {
                    Text(localizationManager.localized("messages"))
                        .font(.headline.weight(.semibold))
                }
            }
        }
    }

    @ViewBuilder
    private func applySearchIfNeeded<Content: View>(_ content: Content) -> some View {
        content
    }

    private var isShowingSearchResults: Bool {
        searchViewModel.hasSearched
    }

    private var messagesList: some View {
        ScrollViewReader { proxy in
            List(selection: $selection) {
                ForEach(viewModel.filteredMessages) { message in
                    MessageRowView(message: message)
                        .accessibilityIdentifier("message.row.\(message.id.uuidString)")
                        .tag(message.id)
                        .id(message.id)
                        .listRowInsets(Layout.rowInsets)
                        .alignmentGuide(.listRowSeparatorLeading) { dimensions in
                            dimensions[.leading]
                        }
                        .alignmentGuide(.listRowSeparatorTrailing) { dimensions in
                            dimensions[.trailing] - Layout.rowInsets.trailing
                        }
                        .listRowBackground(selectedRowBackground(isSelected: selection == message.id))
                        .onAppear { Task { await viewModel.loadMoreIfNeeded(currentItem: message) } }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(EntityVisualTokens.pageBackground)
            .background(ListScrollStyleStabilizer())
            .onAppear { scrollToSelectionIfNeeded(proxy) }
            .onChange(of: selection) { _, newValue in
                pendingScrollTarget = newValue
                scrollToSelectionIfNeeded(proxy)
            }
            .onChange(of: viewModel.filteredMessages.map(\.id)) { _, _ in
                scrollToSelectionIfNeeded(proxy)
            }
        }
    }

    private var searchResultsList: some View {
        ScrollViewReader { proxy in
            List(selection: $selection) {
                if searchViewModel.displayedResults.isEmpty {
                    searchPlaceholderRow
                } else {
                    Section {
                        ForEach(searchViewModel.displayedResults) { message in
                            MessageRowView(message: message)
                                .accessibilityIdentifier("message.row.\(message.id.uuidString)")
                                .tag(message.id)
                                .id(message.id)
                                .listRowInsets(Layout.rowInsets)
                                .alignmentGuide(.listRowSeparatorLeading) { dimensions in
                                    dimensions[.leading]
                                }
                                .alignmentGuide(.listRowSeparatorTrailing) { dimensions in
                                    dimensions[.trailing] - Layout.rowInsets.trailing
                                }
                                .listRowBackground(selectedRowBackground(isSelected: selection == message.id))
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
            .background(ListScrollStyleStabilizer())
            .onAppear { scrollToSelectionIfNeeded(proxy) }
            .onChange(of: selection) { _, newValue in
                pendingScrollTarget = newValue
                scrollToSelectionIfNeeded(proxy)
            }
            .onChange(of: searchViewModel.displayedResults.map(\.id)) { _, _ in
                scrollToSelectionIfNeeded(proxy)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 24) {
            VStack(spacing: 12) {
                Image(systemName: "tray")
                    .font(.largeTitle)
                    .foregroundColor(.secondary)
                    .accessibilityHidden(true)
                Text(localizationManager.localized("no_messages_yet"))
                    .font(.headline)
                Text(localizationManager.localized(
                    "you_can_use_the_pushgo_cli_or_other_integration_tools_to_send_a_test_push_to_the_current_device"
                ))
                .font(.subheadline)
                .foregroundColor(.secondary)
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

    @ViewBuilder
    private func selectedRowBackground(isSelected: Bool) -> some View {
        if isSelected {
            Color.accentColor.opacity(0.06)
        } else {
            Color.clear
        }
    }
}
