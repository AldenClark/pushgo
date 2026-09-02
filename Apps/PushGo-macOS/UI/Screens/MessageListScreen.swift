import Observation
import SwiftUI

struct MessageListScreen: View {
    @Environment(LocalizationManager.self) private var localizationManager: LocalizationManager
    @Environment(MessageSearchViewModel.self) private var searchViewModel: MessageSearchViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let viewModel: MessageListViewModel
    let messages: [PushMessageSummary]
    let searchResults: [PushMessageSummary]
    let isShowingSearchResults: Bool
    @Binding var selection: UUID?
    @State private var pendingScrollTarget: UUID?
    var onOpenMessage: ((PushMessageSummary) -> Void)? = nil
    var onCopyMessageIdentifier: ((PushMessageSummary) -> Void)? = nil
    var onMarkMessageRead: ((PushMessageSummary) -> Void)? = nil
    var onDeleteMessage: ((PushMessageSummary) -> Void)? = nil

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
                initialLoadingState
            } else if viewModel.loadState == .failed && messages.isEmpty {
                messageLoadFailureState
            } else {
                ZStack {
                    activeListView
                        .opacity(showsEmptyState ? 0.001 : 1)
                        .allowsHitTesting(!showsEmptyState)
                        .accessibilityHidden(showsEmptyState)

                    if showsEmptyState {
                        emptyState
                    }

                    if viewModel.loadState == .failed && !messages.isEmpty {
                        messageLoadFailureBanner
                            .frame(maxHeight: .infinity, alignment: .top)
                            .padding()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task {
            try? await Task.sleep(for: .milliseconds(180))
            viewModel.enableChannelSummaries()
        }
        .overlay(alignment: .topLeading) {
            Text("Messages screen")
                .font(.system(size: 1))
                .foregroundStyle(.clear)
                .frame(width: 1, height: 1)
                .accessibilityIdentifier("screen.messages.list")
        }
        return baseView
    }

    private var initialLoadingState: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text(localizationManager.localized(
                viewModel.loadState == .slow
                    ? "message_ingress_processing_slow"
                    : "message_ingress_processing_progress"
            ))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(
            viewModel.loadState == .slow ? "state.messages.loading.slow" : "state.messages.loading"
        )
    }

    private var messageLoadFailureState: some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text(localizationManager.localized("message_load_failed"))
            Button(localizationManager.localized("retry")) {
                Task { await viewModel.retryAfterFailure() }
            }
            .accessibilityIdentifier("action.messages.retry")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("state.messages.load_failed")
    }

    private var messageLoadFailureBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text(localizationManager.localized("message_load_failed"))
            Spacer(minLength: 8)
            Button(localizationManager.localized("retry")) {
                Task { await viewModel.retryAfterFailure() }
            }
            .accessibilityIdentifier("action.messages.retry")
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityIdentifier("state.messages.load_failed")
    }

    @ViewBuilder
    private var activeListView: some View {
        if isShowingSearchResults {
            searchResultsList
        } else {
            messagesList
        }
    }

    private var showsEmptyState: Bool {
        !isShowingSearchResults && messages.isEmpty
    }

    private var showsUnreadFilterEmptyState: Bool {
        showsEmptyState && viewModel.isUnreadOnlyFilterActive && viewModel.totalMessageCount > 0
    }

    private var messagesList: some View {
        ScrollViewReader { proxy in
            List {
                ForEach(messages) { message in
                    Button {
                        openMessage(message)
                    } label: {
                        MessageRowView(message: message)
                            .id(message.rowLayoutKey)
                            .entityListRowTapTarget()
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("message.row.\(message.id.uuidString.lowercased())")
                    .modifier(messageAccessibilityActions(for: message))
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
            .accessibilityIdentifier("messages.list.scroll")
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(EntityVisualTokens.pageBackground)
            .overlay(alignment: .bottom) {
                if viewModel.isLoadingPage {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text(localizationManager.localized("message_page_loading"))
                            .font(.caption)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.bottom, 10)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("state.messages.page.loading")
                } else if viewModel.pageLoadError != nil {
                    messagePageFailureOverlay
                }
            }
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

    private var messagePageFailureOverlay: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.secondary)
            Text(localizationManager.localized("message_load_failed"))
                .font(.caption)
            Button(localizationManager.localized("retry")) {
                Task { await viewModel.retryPageAfterFailure() }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .accessibilityIdentifier("action.messages.page.retry")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
        .padding(.bottom, 10)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("state.messages.page.failed")
    }

    private var searchResultsList: some View {
        ScrollViewReader { proxy in
            List {
                if searchResults.isEmpty {
                    if searchViewModel.isSearching {
                        searchProgressRow
                    } else if searchViewModel.searchFailed {
                        searchFailureRow
                    } else {
                        searchPlaceholderRow
                    }
                } else {
                    Section {
                        ForEach(searchResults) { message in
                            Button {
                                openMessage(message)
                            } label: {
                                MessageRowView(message: message)
                                    .id(message.rowLayoutKey)
                                    .entityListRowTapTarget()
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("message.row.\(message.id.uuidString.lowercased())")
                            .modifier(messageAccessibilityActions(for: message))
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
                        HStack {
                            Text(localizationManager.localized("found_number_results", searchViewModel.totalResults))
                            Spacer()
                            if searchViewModel.isSearching {
                                ProgressView()
                                    .progressViewStyle(.circular)
                                    .controlSize(.small)
                            }
                        }
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

    private func openMessage(_ message: PushMessageSummary) {
        if let onOpenMessage {
            onOpenMessage(message)
        } else {
            selection = message.id
        }
    }

    private func messageAccessibilityActions(for message: PushMessageSummary) -> some ViewModifier {
        MessageListRowAccessibilityActions(
            message: message,
            openLabel: localizationManager.localized("open_link"),
            copyLabel: localizationManager.localized("copy_content"),
            markReadLabel: localizationManager.localized("mark_as_read"),
            deleteLabel: localizationManager.localized("delete"),
            onOpen: { openMessage($0) },
            onCopy: onCopyMessageIdentifier,
            onMarkRead: onMarkMessageRead,
            onDelete: onDeleteMessage
        )
    }

    private var emptyState: some View {
        Group {
            if showsUnreadFilterEmptyState {
                EntityEmptyView(
                    iconName: "tray",
                    title: localizationManager.localized("placeholder_no_unread_messages"),
                    subtitle: localizationManager.localized("message_unread_filter_empty_hint"),
                    subtitleMaxWidth: 420
                )
            } else {
                EntityOnboardingEmptyView(kind: .messages)
            }
        }
        .accessibilityIdentifier("state.messages.empty")
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

    private var searchProgressRow: some View {
        VStack(spacing: 12) {
            ProgressView()
                .progressViewStyle(.circular)
                .controlSize(.large)

            Text(localizationManager.localized(
                searchViewModel.isSearchLoadSlow ? "message_loading_slow" : "searching_messages"
            ))
                .font(.subheadline)
                .foregroundStyle(Color.appTextSecondary)
                .accessibilityIdentifier(
                    searchViewModel.isSearchLoadSlow
                        ? "state.messages.search.loading.slow"
                        : "state.messages.search.loading"
                )
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, 60)
        .listRowInsets(EdgeInsets())
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("state.messages.search.loading")
    }

    private var searchFailureRow: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text(localizationManager.localized("operation_failed"))
                .font(.headline)
            Button(localizationManager.localized("retry")) {
                searchViewModel.retrySearch()
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("action.messages.search.retry")
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, 60)
        .listRowInsets(EdgeInsets())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("state.messages.search.failed")
    }

    private func scrollToSelectionIfNeeded(_ proxy: ScrollViewProxy) {
        guard let target = pendingScrollTarget ?? selection else { return }
        let existsInMessages = messages.contains { $0.id == target }
        let existsInSearch = searchResults.contains { $0.id == target }
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

private struct MessageListRowAccessibilityActions: ViewModifier {
    let message: PushMessageSummary
    let openLabel: String
    let copyLabel: String
    let markReadLabel: String
    let deleteLabel: String
    let onOpen: (PushMessageSummary) -> Void
    let onCopy: ((PushMessageSummary) -> Void)?
    let onMarkRead: ((PushMessageSummary) -> Void)?
    let onDelete: ((PushMessageSummary) -> Void)?

    func body(content: Content) -> some View {
        content
            .accessibilityAction(named: Text(openLabel)) {
                onOpen(message)
            }
            .accessibilityAction(named: Text(copyLabel)) {
                onCopy?(message)
            }
            .accessibilityAction(named: Text(markReadLabel)) {
                guard !message.isRead else { return }
                onMarkRead?(message)
            }
            .accessibilityAction(named: Text(deleteLabel)) {
                onDelete?(message)
            }
    }
}
