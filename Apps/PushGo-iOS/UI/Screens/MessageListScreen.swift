import SwiftUI
import Observation

struct MessageListScreen: View {
    @Environment(AppEnvironment.self) private var environment: AppEnvironment
    @Environment(LocalizationManager.self) private var localizationManager: LocalizationManager
    @Environment(MessageSearchViewModel.self) private var searchViewModel: MessageSearchViewModel
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Bindable private var viewModel: MessageListViewModel
    @State private var selectedMessage: PushMessageSummary?
    @State private var selectedMessageIDs: Set<UUID> = []
    @State private var isBatchModeActive = false
    @State private var showBatchDeleteConfirmation = false
    @State private var pendingMessageStoreRefresh = false
    private let onSelect: ((PushMessageSummary) -> Void)?
    private let autoSelectFirstMessage: Bool
    private let useNavigationContainer: Bool
    private let scrollToUnreadToken: Int
    private let scrollToTopToken: Int
    @State private var lastAutoSelectedMessageId: UUID?
    @State private var pendingScrollTarget: UUID?

    init(
        viewModel: MessageListViewModel,
        onSelect: ((PushMessageSummary) -> Void)? = nil,
        autoSelectFirstMessage: Bool = false,
        useNavigationContainer: Bool = true,
        scrollToUnreadToken: Int = 0,
        scrollToTopToken: Int = 0,
    ) {
        _viewModel = Bindable(viewModel)
        self.onSelect = onSelect
        self.autoSelectFirstMessage = autoSelectFirstMessage
        self.useNavigationContainer = useNavigationContainer
        self.scrollToUnreadToken = scrollToUnreadToken
        self.scrollToTopToken = scrollToTopToken
    }

    var body: some View {
        containerView
    }

    @ViewBuilder
    private var containerView: some View {
        containerCore
            .accessibilityIdentifier("screen.messages.list")
            .onAppear {
                environment.updateMessageListPosition(isAtTop: true)
                openPendingMessageIfNeeded()
#if DEBUG
                publishAutomationState()
#endif
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(180))
                    viewModel.enableChannelSummaries()
                }
            }
            .onChange(of: environment.pendingMessageToOpen) { _, _ in
                openPendingMessageIfNeeded()
#if DEBUG
                publishAutomationState()
#endif
            }
            .onChange(of: scenePhase) { _, newValue in
                if newValue == .active {
                    openPendingMessageIfNeeded()
                }
#if DEBUG
                publishAutomationState()
#endif
            }
            .onChange(of: searchViewModel.query) { _, newValue in
#if DEBUG
                PushGoAutomationRuntime.shared.recordSearchResultsUpdated(
                    query: newValue,
                    resultCount: searchViewModel.totalResults
                )
#endif
            }
            .onChange(of: searchViewModel.totalResults) { _, newValue in
#if DEBUG
                PushGoAutomationRuntime.shared.recordSearchResultsUpdated(
                    query: searchViewModel.query,
                    resultCount: newValue
                )
#endif
            }
            .onChange(of: isBatchMode) { _, active in
                if active {
                    selectedMessage = nil
                    pendingMessageStoreRefresh = false
                } else {
                    selectedMessageIDs.removeAll()
                    openPendingMessageIfNeeded()
                }
            }
    }

    @ViewBuilder
    private var containerCore: some View {
        if useNavigationContainer {
            navigationContainer {
                coreContent
            }
        } else {
            coreContent
        }
    }

    @ViewBuilder
    private var coreContent: some View {
        let baseContent = screenContent
            .navigationTitle(localizationManager.localized("messages"))
            .navigationBarTitleDisplayMode(.large)
            .applyToolbarBackgroundIfNeeded()
            .onChange(of: environment.messageStoreRevision) { _, _ in
                handleMessageStoreRevisionChange()
            }
            .onChange(of: selectedMessage) { _, newValue in
#if DEBUG
                publishAutomationState()
#endif
                guard newValue == nil, pendingMessageStoreRefresh else { return }
                pendingMessageStoreRefresh = false
                handleMessageStoreRevisionChange()
            }
            .onAppear {
                configureNavigationAppearance()
            }
            .onChange(of: viewModel.hasLoadedOnce) { _, _ in
                applyDefaultSelectionIfNeeded()
            }
            .onChange(of: viewModel.filteredMessages.first?.id) { _, _ in
                applyDefaultSelectionIfNeeded()
            }
            .toolbar { toolbarContent }
            .toolbar(isBatchMode ? .hidden : .visible, for: .tabBar)
            .alert(
                localizationManager.localized("delete"),
                isPresented: $showBatchDeleteConfirmation,
            ) {
                Button(localizationManager.localized("delete"), role: .destructive) {
                    Task { await deleteSelectedMessages() }
                }
                Button(localizationManager.localized("cancel"), role: .cancel) {}
            } message: {
                Text(localizationManager.localized("batch_delete_selected_messages_confirm", selectedMessageIDs.count))
            }

        if onSelect == nil {
            baseContent
                .sheet(item: $selectedMessage) { message in
                    MessageDetailScreen(messageId: message.id, message: nil)
                        .pushgoSheetSizing(.detail)
                        .accessibilityIdentifier("sheet.message.detail")
                }
        } else {
            baseContent
        }
    }

#if DEBUG
    private func publishAutomationState() {
        PushGoAutomationRuntime.shared.publishState(
            environment: environment,
            activeTab: "messages",
            visibleScreen: selectedMessage == nil ? "screen.messages.list" : "screen.message.detail",
            openedMessageId: selectedMessage?.messageId ?? selectedMessage?.id.uuidString
        )
    }
#endif

    @ViewBuilder
    private var screenContent: some View {
        if !viewModel.hasLoadedOnce {
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if viewModel.filteredMessages.isEmpty && !isShowingSearchResults {
            emptyState
        } else {
            messageList
        }
    }

    private var isShowingSearchResults: Bool {
        searchViewModel.hasSearched
    }

    private var hasMessages: Bool { viewModel.totalMessageCount > 0 }

    private var hasVisibleMessageRows: Bool {
        if isShowingSearchResults {
            return !searchViewModel.displayedResults.isEmpty
        }
        return !viewModel.filteredMessages.isEmpty
    }

    private var displayedChannelSummaries: [MessageChannelSummary] {
        let summaries = viewModel.channelSummaries
        let hasNamedChannel = summaries.contains { summary in
            if case .named = summary.key { return true }
            return false
        }
        return hasNamedChannel ? summaries : []
    }
    @ViewBuilder
    private var messageList: some View {
        ScrollViewReader { proxy in
            List(selection: batchSelectionBinding) {
                if isShowingSearchResults {
                    if searchViewModel.displayedResults.isEmpty {
                        searchPlaceholderRow
                    } else {
                        Section {
                            ForEach(searchViewModel.displayedResults.indices, id: \.self) { index in
                                let message = searchViewModel.displayedResults[index]
                                messageRow(for: message, at: index)
                                .tag(message.id)
                                .onAppear {
                                    searchViewModel.loadMoreIfNeeded(currentItem: message)
                                }
                                .modifier(
                                    TopSeparatorModifier(
                                        hide: index == 0,
                                    ),
                                )
                                .modifier(
                                    BottomSeparatorModifier(
                                        hide: index == searchViewModel.displayedResults.count - 1,
                                    ),
                                )
                            }
                            if searchViewModel.hasMore {
                                HStack {
                                    Spacer()
                                    ProgressView().progressViewStyle(.circular)
                                    Spacer()
                                }
                            }
                        } header: {
                            Text(localizationManager.localized("found_number_results", searchViewModel.totalResults))
                        }
                    }
                } else {
                    ForEach(viewModel.filteredMessages.indices, id: \.self) { index in
                        let message = viewModel.filteredMessages[index]
                        messageRow(for: message, at: index)
                            .tag(message.id)
                            .id(message.id)
                            .modifier(
                                TopSeparatorModifier(
                                    hide: index == 0,
                                ),
                            )
                            .modifier(
                                BottomSeparatorModifier(
                                    hide: index == viewModel.filteredMessages.count - 1,
                                ),
                            )
                            .onAppear {
                                Task { await viewModel.loadMoreIfNeeded(currentItem: message) }
                            }
                    }
                }
            }
            .modifier(MessageListSearchableModifier(searchViewModel: searchViewModel, enabled: hasMessages && !isBatchMode))
            .modifier(
                ScrollObserverModifier(enabled: true) { topOffset, pullDistance in
                    _ = pullDistance
                    updateMessageListTopState(topOffset: topOffset)
                },
            )
            .environment(\.editMode, isBatchMode ? .constant(.active) : .constant(.inactive))
            .listStyle(.plain)
            .listRowSpacing(0)
            .listClearBackground()
            .modifier(MessageListScrollDismissModifier())
            .onAppear {
                scrollToPendingMessageIfNeeded(proxy)
            }
            .onChange(of: pendingScrollTarget) { _, _ in
                scrollToPendingMessageIfNeeded(proxy)
            }
            .onChange(of: viewModel.filteredMessagesIdentityRevision) { _, _ in
                scrollToPendingMessageIfNeeded(proxy)
            }
            .onChange(of: scrollToUnreadToken) { _, _ in
                scrollToNearestUnreadIfNeeded(proxy)
            }
            .onChange(of: scrollToTopToken) { _, _ in
                scrollToTopIfNeeded(proxy)
            }
        }
    }

    @ViewBuilder
    private func messageRow(for message: PushMessageSummary, at index: Int) -> some View {
        Group {
            if isBatchMode {
                MessageRowView(message: message)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 0)
                    .padding(.horizontal, EntityVisualTokens.listRowInsetHorizontal)
                    .contentShape(Rectangle())
            } else {
                Button {
                    if !message.isRead {
                        Task { await viewModel.markRead(message, isRead: true) }
                    }
                    handleSelect(message)
                } label: {
                    MessageRowView(message: message)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 0)
                        .padding(.horizontal, EntityVisualTokens.listRowInsetHorizontal)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.appPlain)
                .swipeActions {
                    markReadAction(for: message)
                    deleteAction(for: message)
                }
            }
        }
        .accessibilityIdentifier("message.row.\(message.id.uuidString)")
        .listRowInsets(EdgeInsets(
            top: EntityVisualTokens.listRowInsetVertical,
            leading: 0,
            bottom: EntityVisualTokens.listRowInsetVertical + 2,
            trailing: 0,
        ))
    }

    @ViewBuilder
    private func markReadAction(for message: PushMessageSummary) -> some View {
        if !message.isRead {
            Button {
                Task { await viewModel.markRead(message, isRead: true) }
            } label: {
                Label(
                    localizationManager.localized("mark_as_read"),
                    systemImage: "envelope.open",
                )
            }
            .tint(.accentColor)
        }
    }

    private func deleteAction(for message: PushMessageSummary) -> some View {
        Button(role: .destructive) {
            Task { await viewModel.delete(message) }
        } label: {
            Label(localizationManager.localized("delete"), systemImage: "trash")
        }
    }

    private func updateMessageListTopState(topOffset: CGFloat) {
        let isAtTop = !hasMessages || topOffset <= MessageListTopMetrics.topTolerance
        environment.updateMessageListPosition(isAtTop: isAtTop)
    }

    private var emptyState: some View {
        VStack(spacing: 24) {
            VStack(spacing: 12) {
                Image(systemName: "tray")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(localizationManager.localized("no_messages_yet"))
                    .font(.headline)
                Text(localizationManager
                    .localized(
                        "you_can_use_the_pushgo_cli_or_other_integration_tools_to_send_a_test_push_to_the_current_device",
                    ))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.top, 48)
        .padding(.horizontal, 24)
    }

    private func resetSearchState() {
        guard searchViewModel.hasSearched || !searchViewModel.query.isEmpty else { return }
        searchViewModel.updateQuery("")
    }

    private func configureNavigationAppearance() {
    }

    private var searchPlaceholderRow: some View {
        MessageSearchPlaceholderView(
            imageName: "questionmark.circle",
            title: "no_matching_results",
            detailKey: "try_changing_a_keyword_or_adjusting_the_filter_conditions",
        )
        .padding(.vertical, 60)
        .frame(maxWidth: .infinity, alignment: .center)
        .listRowInsets(EdgeInsets())
        .listRowBackground(
            Group { Color.clear },
        )
        .hideListSeparator()
    }
}

private struct ScrollObserverModifier: ViewModifier {
    let enabled: Bool
    let onChange: (_ topOffset: CGFloat, _ pullDistance: CGFloat) -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled {
            content
                .onScrollGeometryChange(
                    for: CGFloat.self,
                    of: { geom in
                        geom.contentOffset.y
                    },
                    action: { _, newY in
                        let topOffset = newY
                        let pull = max(0, -newY)
                        onChange(topOffset, pull)
                    },
                )
        } else {
            content
        }
    }
}

private enum MessageListTopMetrics {
    static let topTolerance: CGFloat = 2
}

private struct TopSeparatorModifier: ViewModifier {
    let hide: Bool
    @ViewBuilder
    func body(content: Content) -> some View {
        content.listRowSeparator(hide ? .hidden : .visible, edges: .top)
    }
}

private struct BottomSeparatorModifier: ViewModifier {
    let hide: Bool
    @ViewBuilder
    func body(content: Content) -> some View {
        content.listRowSeparator(hide ? .hidden : .visible, edges: .bottom)
    }
}

private struct HideListBackgroundIfAvailable: ViewModifier {
    func body(content: Content) -> some View {
        content.scrollContentBackground(.hidden)
    }
}

private struct MessageListScrollDismissModifier: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        content.scrollDismissesKeyboard(.interactively)
    }
}

private struct MessageListSearchableModifier: ViewModifier {
    @Bindable var searchViewModel: MessageSearchViewModel
    let enabled: Bool
    @Environment(LocalizationManager.self) private var localizationManager: LocalizationManager
    @State private var searchFieldText: String = ""

    @ViewBuilder
    func body(content: Content) -> some View {
        if !enabled {
            content
        } else {
            content
                .onAppear {
                    if searchFieldText != searchViewModel.query {
                        searchFieldText = searchViewModel.query
                    }
                }
                .onChange(of: searchFieldText) { _, newValue in
                    guard searchViewModel.query != newValue else { return }
                    searchViewModel.updateQuery(newValue)
                }
                .onChange(of: searchViewModel.query) { _, newValue in
                    if searchFieldText != newValue {
                        searchFieldText = newValue
                    }
                }
                .searchable(
                    text: $searchFieldText,
                    placement: .navigationBarDrawer(displayMode: .automatic),
                    prompt: localizationManager.localized("search_messages")
                )
                .onSubmit(of: .search) {
                    searchViewModel.applySearchTextImmediately(searchViewModel.query)
                }
        }
    }
}

private extension View {
    @ViewBuilder
    func listClearBackground() -> some View {
        self
            .scrollContentBackground(.hidden)
            .background(EntityVisualTokens.pageBackground)
    }

    @ViewBuilder
    func hideListSeparator() -> some View {
        self.listRowSeparator(.hidden)
    }
    @ViewBuilder
    func applyToolbarBackgroundIfNeeded() -> some View {
        self
    }
}

private extension MessageListScreen {
    var shouldDeferMessageStoreRefresh: Bool {
        onSelect == nil && selectedMessage != nil
    }

    func handleMessageStoreRevisionChange() {
        guard !shouldDeferMessageStoreRefresh else {
            pendingMessageStoreRefresh = true
            return
        }

        Task {
            await viewModel.refresh()
            applyDefaultSelectionIfNeeded()
        }
        if viewModel.totalMessageCount == 0 {
            resetSearchState()
        } else {
            searchViewModel.refreshMessagesIfNeeded()
        }
        if environment.pendingMessageToOpen != nil {
            openPendingMessageIfNeeded()
        }
    }

    private func resolvedChannelDisplayName(for channel: MessageChannelKey?) -> String? {
        guard let channel else { return nil }
        if channel.rawChannelValue == "" {
            return localizationManager.localized("not_grouped")
        }
        return environment.channelDisplayName(for: channel.rawChannelValue) ?? channel.displayName
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button {
                isBatchModeActive.toggle()
            } label: {
                Image(systemName: isBatchMode ? "checkmark" : "checklist.unchecked")
            }
            .accessibilityLabel(isBatchMode ? localizationManager.localized("done") : localizationManager.localized("edit"))
        }
        ToolbarItemGroup(placement: .primaryAction) {
            if !isBatchMode {
                Menu {
                    channelFilterMenuContent
                } label: {
                    Image(systemName: isFilterMenuHighlighted ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease")
                }
                .accessibilityLabel(localizationManager.localized("channel"))
            }
        }
        if isBatchMode {
            ToolbarItemGroup(placement: .bottomBar) {
                Button {
                    Task { await markSelectedMessagesAsRead() }
                } label: {
                    Image(systemName: "envelope.open")
                }
                .accessibilityLabel(localizationManager.localized("mark_as_read"))
                .disabled(selectedUnreadMessages.isEmpty)

                Spacer()

                Button(role: .destructive) {
                    showBatchDeleteConfirmation = true
                } label: {
                    Image(systemName: "trash")
                }
                .accessibilityLabel(localizationManager.localized("delete"))
                .disabled(selectedMessageIDs.isEmpty)
            }
        }
    }

    private var isBatchMode: Bool {
        isBatchModeActive
    }

    private var batchSelectionBinding: Binding<Set<UUID>> {
        if isBatchMode {
            return $selectedMessageIDs
        }
        return .constant([])
    }

    private var selectedUnreadMessages: [PushMessageSummary] {
        let selectedIds = selectedMessageIDs
        guard !selectedIds.isEmpty else { return [] }
        let currentMessages = isShowingSearchResults ? searchViewModel.displayedResults : viewModel.filteredMessages
        return currentMessages.filter { selectedIds.contains($0.id) && !$0.isRead }
    }

    @ViewBuilder
    private var channelFilterMenuContent: some View {
        Section {
            Button {
                viewModel.setFilter(isUnreadOnlyFilterEnabled ? .all : .unread)
            } label: {
                channelFilterMenuItemLabel(
                    title: localizationManager.localized("only_show_unread_messages"),
                    isSelected: isUnreadOnlyFilterEnabled
                )
            }
        }

        Section {
            ForEach(displayedChannelSummaries) { summary in
                Button {
                    viewModel.toggleChannelSelection(summary.key)
                } label: {
                    channelFilterMenuItemLabel(
                        title: resolvedChannelDisplayName(for: summary.key) ?? summary.title,
                        isSelected: viewModel.selectedChannel == summary.key
                    )
                }
            }
        }
    }

    private var isUnreadOnlyFilterEnabled: Bool {
        viewModel.selectedFilter == .unread
    }

    private var isFilterMenuHighlighted: Bool {
        isUnreadOnlyFilterEnabled || viewModel.selectedChannel != nil
    }

    private func channelFilterMenuItemLabel(title: String, isSelected: Bool) -> some View {
        HStack(spacing: 8) {
            if isSelected {
                Image(systemName: "checkmark")
            } else {
                Image(systemName: "checkmark")
                    .hidden()
            }
            Text(title)
        }
    }

    private func handleSelect(_ message: PushMessageSummary) {
        guard !isBatchMode else { return }
        selectedMessage = message
        if let onSelect {
            onSelect(message)
        }
    }
    private func openPendingMessageIfNeeded() {
        guard let targetId = environment.pendingMessageToOpen else { return }
        Task { @MainActor in
            let maxAttempts = 20
            for attempt in 0..<maxAttempts {
                if let summary = viewModel.filteredMessages.first(where: { $0.id == targetId }) {
                    handleSelect(summary)
                    pendingScrollTarget = targetId
                    environment.pendingMessageToOpen = nil
                    return
                }
                if let message = try? await environment.dataStore.loadMessage(id: targetId) {
                    let summary = PushMessageSummary(message: message)
                    handleSelect(summary)
                    pendingScrollTarget = targetId
                    environment.pendingMessageToOpen = nil
                    return
                }
                guard environment.pendingMessageToOpen == targetId else { return }
                if attempt + 1 < maxAttempts {
                    try? await Task.sleep(for: .milliseconds(100))
                }
            }
        }
    }

    private func scrollToPendingMessageIfNeeded(_ proxy: ScrollViewProxy) {
        guard let targetId = pendingScrollTarget else { return }
        guard viewModel.filteredMessages.contains(where: { $0.id == targetId }) else { return }
        scroll(proxy, to: targetId, anchor: .center)
        pendingScrollTarget = nil
    }

    private func scrollToNearestUnreadIfNeeded(_ proxy: ScrollViewProxy) {
        guard let targetId = displayedMessages.first(where: { !$0.isRead })?.id else { return }
        scroll(proxy, to: targetId, anchor: .center)
    }

    private func scrollToTopIfNeeded(_ proxy: ScrollViewProxy) {
        guard let targetId = displayedMessages.first?.id else { return }
        scroll(proxy, to: targetId, anchor: .top)
    }

    private var displayedMessages: [PushMessageSummary] {
        if isShowingSearchResults {
            return searchViewModel.displayedResults
        }
        return viewModel.filteredMessages
    }

    private func scroll(_ proxy: ScrollViewProxy, to targetId: UUID, anchor: UnitPoint) {
        if reduceMotion {
            proxy.scrollTo(targetId, anchor: anchor)
        } else {
            withAnimation(.easeInOut(duration: 0.2)) {
                proxy.scrollTo(targetId, anchor: anchor)
            }
        }
    }

    private func applyDefaultSelectionIfNeeded() {
        guard !isBatchMode else { return }
        guard autoSelectFirstMessage, let onSelect else { return }
        guard !isShowingSearchResults else { return }
        guard let first = viewModel.filteredMessages.first else { return }
        guard lastAutoSelectedMessageId != first.id else { return }
        lastAutoSelectedMessageId = first.id
        onSelect(first)
    }

    private func deleteSelectedMessages() async {
        let ids = selectedMessageIDs
        guard !ids.isEmpty else { return }
        for messageId in ids {
            try? await environment.messageStateCoordinator.deleteMessage(messageId: messageId)
        }
        selectedMessageIDs.removeAll()
        await viewModel.refresh()
        searchViewModel.refreshMessagesIfNeeded()
        isBatchModeActive = false
    }

    private func markSelectedMessagesAsRead() async {
        let unreadMessages = selectedUnreadMessages
        guard !unreadMessages.isEmpty else { return }
        for message in unreadMessages {
            await viewModel.markRead(message, isRead: true)
        }
        await viewModel.refresh()
        searchViewModel.refreshMessagesIfNeeded()
        selectedMessageIDs.removeAll()
    }
}
