import SwiftUI
import Observation

struct MessageListScreen: View {
    @Environment(AppEnvironment.self) private var environment: AppEnvironment
    @Environment(LocalizationManager.self) private var localizationManager: LocalizationManager
    @Environment(MessageSearchViewModel.self) private var searchViewModel: MessageSearchViewModel
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let viewModel: MessageListViewModel
    @State private var selectedMessage: PushMessageSummary?
    @State private var selectedMessageIDs: Set<UUID> = []
    @State private var isBatchModeActive = false
    private let onSelect: ((PushMessageSummary) -> Void)?
    private let autoSelectFirstMessage: Bool
    private let useNavigationContainer: Bool
    private let scrollToUnreadToken: Int
    private let scrollToTopToken: Int
    @State private var lastAutoSelectedMessageId: UUID?
    @State private var pendingScrollTarget: UUID?
    @State private var isFilterPopoverPresented = false

    private struct MessageTagSummary: Identifiable, Hashable {
        let tag: String
        let totalCount: Int

        var id: String { tag }
    }

    init(
        viewModel: MessageListViewModel,
        onSelect: ((PushMessageSummary) -> Void)? = nil,
        autoSelectFirstMessage: Bool = false,
        useNavigationContainer: Bool = true,
        scrollToUnreadToken: Int = 0,
        scrollToTopToken: Int = 0,
    ) {
        self.viewModel = viewModel
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
                } else {
                    selectedMessageIDs.removeAll()
                    openPendingMessageIfNeeded()
                }
            }
            .onChange(of: environment.pendingLocalDeletionController.pendingDeletion) { _, _ in
                if let selectedMessage, isPendingLocalDeletion(selectedMessage) {
                    self.selectedMessage = nil
                }
                let visibleIDs = Set(displayedMessages.map(\.id))
                selectedMessageIDs = selectedMessageIDs.intersection(visibleIDs)
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
            .refreshable {
                await handlePullToRefresh()
            }
            .onChange(of: selectedMessage) { _, newValue in
#if DEBUG
                publishAutomationState()
#endif
                guard let newValue, !newValue.isRead else { return }
                Task { await viewModel.markRead(newValue, isRead: true) }
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
        } else {
            ZStack {
                messageList
                    .opacity(showsEmptyState ? 0.001 : 1)
                    .allowsHitTesting(!showsEmptyState)
                    .accessibilityHidden(showsEmptyState)

                if showsEmptyState {
                    emptyState
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var isShowingSearchResults: Bool {
        searchViewModel.hasSearched
    }

    private var hasMessages: Bool { viewModel.totalMessageCount > 0 }

    private var showsEmptyState: Bool {
        visibleFilteredMessages.isEmpty && !isShowingSearchResults
    }

    private var showsUnreadFilterEmptyState: Bool {
        showsEmptyState && viewModel.isUnreadOnlyFilterActive && hasMessages
    }

    private var hasVisibleMessageRows: Bool {
        if isShowingSearchResults {
            return !visibleSearchResults.isEmpty
        }
        return !visibleFilteredMessages.isEmpty
    }

    private var displayedChannelSummaries: [MessageChannelSummary] {
        let source = viewModel.isUnreadOnlyFilterActive
            ? viewModel.channelSummaries.filter(\.hasUnread)
            : viewModel.channelSummaries
        let summaries = source.sorted { lhs, rhs in
            if lhs.totalCount != rhs.totalCount {
                return lhs.totalCount > rhs.totalCount
            }
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
        let hasNamedChannel = summaries.contains { summary in
            if case .named = summary.key { return true }
            return false
        }
        return hasNamedChannel ? summaries : []
    }

    private var displayedTagOptions: [MessageTagSummary] {
        var tagCounts: [String: Int] = [:]
        for message in baseVisibleFilteredMessages {
            for tag in message.tags {
                let normalized = normalizedTag(tag)
                if !normalized.isEmpty {
                    tagCounts[normalized, default: 0] += 1
                }
            }
        }
        return tagCounts.map { MessageTagSummary(tag: $0.key, totalCount: $0.value) }
            .sorted { lhs, rhs in
                if lhs.totalCount != rhs.totalCount {
                    return lhs.totalCount > rhs.totalCount
                }
                return lhs.tag.localizedCaseInsensitiveCompare(rhs.tag) == .orderedAscending
            }
    }

    private func handlePullToRefresh() async {
        _ = await environment.syncProviderIngress(reason: "messages_pull_to_refresh")
        if viewModel.isUnreadOnlyFilterActive {
            await viewModel.reconcileUnreadFilterSession()
        } else {
            await viewModel.refresh()
        }
        searchViewModel.refreshMessagesIfNeeded()
    }

    @ViewBuilder
    private var messageList: some View {
        ScrollViewReader { proxy in
            List(selection: batchSelectionBinding) {
                if isShowingSearchResults {
                    if visibleSearchResults.isEmpty {
                        searchPlaceholderRow
                    } else {
                        Section {
                            ForEach(visibleSearchResults.indices, id: \.self) { index in
                                let message = visibleSearchResults[index]
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
                                        hide: index == visibleSearchResults.count - 1,
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
                    ForEach(visibleFilteredMessages.indices, id: \.self) { index in
                        let message = visibleFilteredMessages[index]
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
                                    hide: index == visibleFilteredMessages.count - 1,
                                ),
                            )
                            .onAppear {
                                Task { await viewModel.loadMoreIfNeeded(currentItem: message) }
                            }
                    }
                }
            }
            .modifier(MessageListSearchableModifier(searchViewModel: searchViewModel, enabled: hasMessages && !isBatchMode && !showsUnreadFilterEmptyState))
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
            .onChange(of: viewModel.selectedFilter) { _, _ in
                scrollToTopIfNeeded(proxy)
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
        .listRowBackground(
            EntitySelectionBackground(isSelected: isBatchMode ? selectedMessageIDs.contains(message.id) : selectedMessage?.id == message.id)
        )
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
            .tint(Color.appAccentPrimary)
        }
    }

    private func deleteAction(for message: PushMessageSummary) -> some View {
        Button(role: .destructive) {
            Task { await scheduleDeletion(for: [message]) }
        } label: {
            Label(localizationManager.localized("delete"), systemImage: "trash")
        }
    }

    private func updateMessageListTopState(topOffset: CGFloat) {
        let isAtTop = !hasMessages || topOffset <= MessageListTopMetrics.topTolerance
        environment.updateMessageListPosition(isAtTop: isAtTop)
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
                EntityOnboardingEmptyView(
                    kind: .messages,
                    subtitleMaxWidth: 420
                )
            }
        }
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
    let searchViewModel: MessageSearchViewModel
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
    private func resolvedChannelDisplayName(for channel: MessageChannelKey?) -> String? {
        guard let channel else { return nil }
        if channel.rawChannelValue == "" {
            return localizationManager.localized("not_grouped")
        }
        return environment.channelDisplayName(for: channel.rawChannelValue) ?? channel.displayName
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if isBatchMode {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    toggleSelectAllMessages()
                } label: {
                    Image(systemName: areAllVisibleMessagesSelected ? "checkmark.rectangle.stack.fill" : "checkmark.rectangle.stack")
                }
                .accessibilityLabel(localizationManager.localized("all"))
            }
        }
        ToolbarItemGroup(placement: .primaryAction) {
            if isBatchMode {
                Button {
                    Task { await exitBatchModeAfterFlushingPendingDeletion() }
                } label: {
                    batchDoneToolbarIcon()
                }
                .accessibilityLabel(localizationManager.localized("done"))
            } else {
                Button {
                    isFilterPopoverPresented = true
                } label: {
                    filterToolbarIcon(isHighlighted: isFilterMenuHighlighted)
                }
                .accessibilityLabel(localizationManager.localized("channel"))
                .popover(isPresented: $isFilterPopoverPresented, arrowEdge: .top) {
                    if #available(iOS 16.4, *) {
                        filterPopoverContent
                            .presentationCompactAdaptation(.popover)
                    } else {
                        filterPopoverContent
                    }
                }
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
                    Task { await scheduleDeletion(for: selectedBatchMessages) }
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

    private var selectedBatchMessages: [PushMessageSummary] {
        let selectedIds = selectedMessageIDs
        guard !selectedIds.isEmpty else { return [] }
        let currentMessages = isShowingSearchResults ? searchViewModel.displayedResults : viewModel.filteredMessages
        return currentMessages.filter { selectedIds.contains($0.id) }
    }

    @ViewBuilder
    private var channelFilterMenuContent: some View {
        EmptyView()
    }

    private var isFilterMenuHighlighted: Bool {
        viewModel.selectedChannel != nil || viewModel.selectedTag != nil || viewModel.isUnreadOnlyFilterActive
    }

    private func batchDoneToolbarIcon() -> some View {
        Image(systemName: "checkmark")
            .font(.footnote.weight(.bold))
            .foregroundStyle(
                .appAccentPrimary
            )
    }

    private func filterToolbarIcon(isHighlighted: Bool) -> some View {
        Image(systemName: "line.3.horizontal.decrease")
            .font(.body.weight(.semibold))
            .foregroundStyle(isHighlighted ? .accentColor : Color.primary)
    }

    private var filterPopoverContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            Button {
                isBatchModeActive.toggle()
                isFilterPopoverPresented = false
            } label: {
                filterMenuSelectionRow(
                    title: "选择",
                    systemImage: "checklist",
                    isSelected: isBatchModeActive
                )
            }
            .buttonStyle(.plain)
            .padding(.vertical, 2)

            Button {
                viewModel.toggleUnreadOnlyFilter()
                isFilterPopoverPresented = false
            } label: {
                filterMenuSelectionRow(
                    title: localizationManager.localized("message_show_unread_only"),
                    systemImage: "envelope.badge",
                    isSelected: viewModel.isUnreadOnlyFilterActive
                )
            }
            .buttonStyle(.plain)
            .padding(.vertical, 2)

            if !displayedChannelSummaries.isEmpty {
                Rectangle()
                    .fill(Color.appDividerSubtle.opacity(0.9))
                    .frame(height: 0.5)
                    .padding(.vertical, 2)

                Text("Channels")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                FilterChipFlowLayout(horizontalSpacing: 8, verticalSpacing: 8) {
                    ForEach(displayedChannelSummaries) { summary in
                        filterCloudChip(
                            title: resolvedChannelDisplayName(for: summary.key) ?? summary.title,
                            isSelected: viewModel.selectedChannel == summary.key
                        ) {
                            viewModel.toggleChannelSelection(summary.key)
                        }
                    }
                }
            }

            if !displayedTagOptions.isEmpty {
                Rectangle()
                    .fill(Color.appDividerSubtle.opacity(0.9))
                    .frame(height: 0.5)
                    .padding(.vertical, 2)

                Text("Tags")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                FilterChipFlowLayout(horizontalSpacing: 8, verticalSpacing: 8) {
                    ForEach(displayedTagOptions) { summary in
                        tagCloudChip(tag: summary.tag)
                    }
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .frame(width: 316, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func tagCloudChip(tag: String) -> some View {
        let isSelected = viewModel.selectedTag == tag
        return filterCloudChip(title: tag, isSelected: isSelected) {
            viewModel.toggleTagSelection(tag)
        }
    }

    private func filterCloudChip(title: String, isSelected: Bool, onTap: @escaping () -> Void) -> some View {
        Button {
            onTap()
            isFilterPopoverPresented = false
        } label: {
            Text(title)
                .lineLimit(1)
                .truncationMode(.tail)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(minWidth: 60, maxWidth: 208, alignment: .leading)
            .foregroundStyle(isSelected ? Color.appAccentPrimary : Color.appTextPrimary)
            .background(
                Capsule(style: .continuous)
                    .fill(isSelected ? Color.appAccentPrimary.opacity(0.16) : Color.appSurfaceRaised)
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(
                        isSelected ? Color.appAccentPrimary.opacity(0.45) : Color.appBorderSubtle.opacity(0.95),
                        lineWidth: 0.8
                    )
            )
        }
        .buttonStyle(.plain)
    }

    private func filterMenuSelectionRow(title: String, systemImage: String, isSelected: Bool) -> some View {
        HStack(spacing: 8) {
            if isSelected {
                Image(systemName: "checkmark")
                    .font(.footnote.weight(.semibold))
            } else {
                Image(systemName: "checkmark")
                    .font(.footnote.weight(.semibold))
                    .hidden()
            }
            Image(systemName: systemImage)
                .font(.footnote.weight(.medium))
            Text(title)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .font(.body.weight(.semibold))
        .foregroundStyle(Color.appTextPrimary)
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var allVisibleMessageIDs: Set<UUID> {
        Set(displayedMessages.map(\.id))
    }

    private var areAllVisibleMessagesSelected: Bool {
        let visibleIDs = allVisibleMessageIDs
        return !visibleIDs.isEmpty && selectedMessageIDs == visibleIDs
    }

    private func toggleSelectAllMessages() {
        let visibleIDs = allVisibleMessageIDs
        guard !visibleIDs.isEmpty else { return }
        selectedMessageIDs = areAllVisibleMessagesSelected ? [] : visibleIDs
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
                if let summary = visibleFilteredMessages.first(where: { $0.id == targetId }) {
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
        guard displayedMessages.contains(where: { $0.id == targetId }) else { return }
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
            return visibleSearchResults
        }
        return visibleFilteredMessages
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
        guard let first = visibleFilteredMessages.first else { return }
        guard lastAutoSelectedMessageId != first.id else { return }
        lastAutoSelectedMessageId = first.id
        onSelect(first)
    }

    private func markSelectedMessagesAsRead() async {
        let unreadMessages = selectedUnreadMessages
        guard !unreadMessages.isEmpty else { return }
        await viewModel.markRead(unreadMessages)
        selectedMessageIDs.removeAll()
    }

    @MainActor
    private func exitBatchModeAfterFlushingPendingDeletion() async {
        await environment.pendingLocalDeletionController.commitCurrentIfNeeded()
        isBatchModeActive = false
    }

    private var baseVisibleFilteredMessages: [PushMessageSummary] {
        viewModel.filteredMessages.filter { !isPendingLocalDeletion($0) }
    }

    private var visibleFilteredMessages: [PushMessageSummary] {
        guard let selectedTag = viewModel.selectedTag else {
            return baseVisibleFilteredMessages
        }
        return baseVisibleFilteredMessages.filter { message in
            message.tags.contains(where: { normalizedTag($0) == selectedTag })
        }
    }

    private var visibleSearchResults: [PushMessageSummary] {
        searchViewModel.displayedResults.filter { !isPendingLocalDeletion($0) }
    }

    private func isPendingLocalDeletion(_ message: PushMessageSummary) -> Bool {
        environment.pendingLocalDeletionController.suppressesMessage(
            id: message.id,
            channelId: message.channel
        )
    }

    private func normalizedTag(_ rawTag: String) -> String {
        rawTag.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    @MainActor
    private func scheduleDeletion(for messages: [PushMessageSummary]) async {
        let uniqueMessages = Array(
            Dictionary(uniqueKeysWithValues: messages.map { ($0.id, $0) }).values
        )
        guard !uniqueMessages.isEmpty else { return }

        let summary: String = {
            if uniqueMessages.count == 1,
               let first = uniqueMessages.first
            {
                let title = first.title.trimmingCharacters(in: .whitespacesAndNewlines)
                return title.isEmpty ? localizationManager.localized("tab_messages") : title
            }
            return "\(uniqueMessages.count) × \(localizationManager.localized("tab_messages"))"
        }()

        let scope = PendingLocalDeletionController.Scope(
            messageIDs: Set(uniqueMessages.map(\.id))
        )

        await environment.pendingLocalDeletionController.schedule(
            summary: summary,
            undoLabel: localizationManager.localized("cancel"),
            scope: scope
        ) { [environment] in
            _ = try await environment.messageStateCoordinator.deleteMessages(
                messageIds: uniqueMessages.map(\.id)
            )
        } onCompletion: { [environment] result in
            guard case let .failure(error) = result else { return }
            environment.showErrorToast(error, duration: 2.5)
        }

        if let selectedMessage, scope.suppressesMessage(id: selectedMessage.id, channelId: selectedMessage.channel) {
            self.selectedMessage = nil
        }
        selectedMessageIDs.subtract(scope.messageIDs)
    }
}

private struct FilterChipFlowLayout: Layout {
    let horizontalSpacing: CGFloat
    let verticalSpacing: CGFloat

    init(horizontalSpacing: CGFloat = 8, verticalSpacing: CGFloat = 8) {
        self.horizontalSpacing = horizontalSpacing
        self.verticalSpacing = verticalSpacing
    }

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var cursorX: CGFloat = 0
        var cursorY: CGFloat = 0
        var rowHeight: CGFloat = 0
        var usedWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if cursorX > 0, cursorX + size.width > maxWidth {
                usedWidth = max(usedWidth, cursorX - horizontalSpacing)
                cursorX = 0
                cursorY += rowHeight + verticalSpacing
                rowHeight = 0
            }

            cursorX += size.width + horizontalSpacing
            rowHeight = max(rowHeight, size.height)
        }

        usedWidth = max(usedWidth, cursorX > 0 ? cursorX - horizontalSpacing : 0)
        let totalHeight = subviews.isEmpty ? 0 : (cursorY + rowHeight)
        let resolvedWidth = proposal.width == nil ? usedWidth : min(maxWidth, usedWidth)
        return CGSize(width: resolvedWidth, height: totalHeight)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        var cursorX = bounds.minX
        var cursorY = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if cursorX > bounds.minX, cursorX + size.width > bounds.maxX {
                cursorX = bounds.minX
                cursorY += rowHeight + verticalSpacing
                rowHeight = 0
            }

            let center = CGPoint(
                x: cursorX + (size.width / 2),
                y: cursorY + (size.height / 2)
            )
            subview.place(
                at: center,
                anchor: .center,
                proposal: ProposedViewSize(width: size.width, height: size.height)
            )

            cursorX += size.width + horizontalSpacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
