import SwiftUI
import UniformTypeIdentifiers
import Observation

struct MessageListScreen: View {
    @Environment(\.appEnvironment) private var environment: AppEnvironment
    @Environment(LocalizationManager.self) private var localizationManager: LocalizationManager
    @Environment(MessageSearchViewModel.self) private var searchViewModel: MessageSearchViewModel
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Bindable private var viewModel: MessageListViewModel
    @State private var selectedMessage: PushMessageSummary?
    @State private var pendingMessageStoreRefresh = false
    @State private var isExportingChannelMessages = false
    @State private var exportDocument = MessagesExportDocument(messages: [])
    @State private var exportFilename = ""
    @State private var exportChannelDisplayName = LocalizationManager.localizedSync("all_groups")
    @State private var showChannelCleanupConfirmation = false
    @State private var isCleaningChannel = false
    private let onSelect: ((PushMessageSummary) -> Void)?
    private let autoSelectFirstMessage: Bool
    private let useNavigationContainer: Bool
    @State private var lastAutoSelectedMessageId: UUID?
    @State private var pendingScrollTarget: UUID?

    init(
        viewModel: MessageListViewModel,
        onSelect: ((PushMessageSummary) -> Void)? = nil,
        autoSelectFirstMessage: Bool = false,
        useNavigationContainer: Bool = true,
    ) {
        _viewModel = Bindable(viewModel)
        self.onSelect = onSelect
        self.autoSelectFirstMessage = autoSelectFirstMessage
        self.useNavigationContainer = useNavigationContainer
    }

    var body: some View {
        containerView
    }

    @ViewBuilder
    private var containerView: some View {
        containerCore
            .fileExporter(
                isPresented: $isExportingChannelMessages,
                document: exportDocument,
                contentType: UTType.json,
                defaultFilename: exportFilename,
            ) { result in
                switch result {
                case .success:
                    environment.showToast(
                        message: localizationManager.localized("placeholder_export_successful", exportChannelDisplayName),
                        style: .success,
                        duration: 1.5,
                    )
                case let .failure(error):
                    environment.showToast(
                        message: localizationManager.localized("export_failed_placeholder", error.localizedDescription),
                        style: .error,
                        duration: 2,
                    )
                }
            }
            .onChange(of: localizationManager.locale) { _, _ in
                exportChannelDisplayName = localizationManager.localized("all_groups")
                Task {
                    await viewModel.refresh()
                }
            }
            .onAppear {
                environment.updateMessageListPosition(isAtTop: true)
                openPendingMessageIfNeeded()
            }
            .onChange(of: environment.pendingMessageToOpen) { _, _ in
                openPendingMessageIfNeeded()
            }
            .onChange(of: scenePhase) { _, newValue in
                if newValue == .active {
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

    private var coreContent: some View {
        screenContent
            .navigationTitle(localizationManager.localized("messages"))
            .navigationBarTitleDisplayMode(.large)
            .applyToolbarBackgroundIfNeeded()
            .onChange(of: environment.messageStoreRevision) { _, _ in
                handleMessageStoreRevisionChange()
            }
            .sheet(item: selectedMessageBinding) { message in
                MessageDetailScreen(messageId: message.id, message: nil)
            }
            .onChange(of: selectedMessage) { _, newValue in
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
            .alert(
                localizationManager.localized("confirm_cleanup_messages"),
                isPresented: $showChannelCleanupConfirmation
            ) {
                Button(localizationManager.localized("confirm")) {
                    guard !isCleaningChannel else { return }
                    isCleaningChannel = true
                    Task {
                        _ = await viewModel.cleanupReadMessages()
                        isCleaningChannel = false
                    }
                }
                Button(localizationManager.localized("cancel"), role: .cancel) {}
            } message: {
                Text(cleanupConfirmationMessage)
            }
    }

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

    private var cleanupConfirmationMessage: String {
        if let channel = viewModel.selectedChannel {
            let displayName = resolvedChannelDisplayName(for: channel) ?? channel.displayName
            let action = localizationManager.localized("clean_channel_read_placeholder", displayName)
            return localizationManager.localized("confirm_cleanup_messages_placeholder", action)
        }
        let action = localizationManager.localized("clean_all_read_messages")
        return localizationManager.localized("confirm_cleanup_messages_placeholder", action)
    }
    private var isShowingSearchResults: Bool {
        searchViewModel.hasSearched
    }

    private var hasMessages: Bool { viewModel.totalMessageCount > 0 }

    private var currentChannelMessages: [PushMessageSummary] {
        viewModel.messagesForCurrentChannel()
    }

    private var currentChannelDisplayName: String {
        resolvedChannelDisplayName(for: viewModel.selectedChannel)
            ?? localizationManager.localized("all_groups")
    }

    private var shouldShowExportButton: Bool {
        !viewModel.filteredMessages.isEmpty
    }

    private var shouldShowMarkAllAsReadButton: Bool {
        if let channel = viewModel.selectedChannel {
            return viewModel.channelSummaries.first(where: { $0.key == channel })?.hasUnread ?? false
        }
        return viewModel.unreadMessageCount > 0
    }

    private var displayedChannelSummaries: [MessageChannelSummary] {
        let summaries = viewModel.channelSummaries
        let hasNamedChannel = summaries.contains { summary in
            if case .named = summary.key { return true }
            return false
        }
        return hasNamedChannel ? summaries : []
    }
    private var shouldShowChannelRow: Bool {
        !displayedChannelSummaries.isEmpty
    }

    @ViewBuilder
    private var messageList: some View {
        ScrollViewReader { proxy in
            List {
                if isShowingSearchResults {
                    if searchViewModel.displayedResults.isEmpty {
                        searchPlaceholderRow
                    } else {
                        Section {
                            ForEach(
                                Array(searchViewModel.displayedResults.enumerated()),
                                id: \.element.id,
                            ) { index, message in
                                Button {
                                    if !message.isRead {
                                        Task { await viewModel.markRead(message, isRead: true) }
                                    }
                                    handleSelect(message)
                                } label: {
                                    MessageSearchResultRow(
                                        message: message,
                                        query: searchViewModel.query,
                                    )
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.vertical, 10)
                                    .padding(.horizontal, 12)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.appPlain)
                                .listRowInsets(EdgeInsets(
                                    top: 4,
                                    leading: 0,
                                    bottom: 4,
                                    trailing: 0,
                                ))
                                .onAppear {
                                    searchViewModel.loadMoreIfNeeded(currentItem: message)
                                }
                                .modifier(
                                    TopSeparatorModifier(
                                        hide: index == 0,
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
                    if shouldShowChannelRow {
                        channelFilterListRow
                    }
                    ForEach(Array(viewModel.filteredMessages.enumerated()), id: \.element.id) { index, message in
                        messageRow(for: message, at: index)
                            .id(message.id)
                            .modifier(
                                TopSeparatorModifier(
                                    hide: index == 0,
                                ),
                            )
                            .onAppear {
                                Task { await viewModel.loadMoreIfNeeded(currentItem: message) }
                            }
                    }
                }
            }
            .modifier(MessageListSearchableModifier(searchViewModel: searchViewModel))
            .modifier(
                ScrollObserverModifier(enabled: true) { topOffset, pullDistance in
                    _ = pullDistance
                    updateMessageListTopState(topOffset: topOffset)
                },
            )
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
            .onChange(of: viewModel.filteredMessages.map(\.id)) { _, _ in
                scrollToPendingMessageIfNeeded(proxy)
            }
        }
    }

    @ViewBuilder
    private func messageRow(for message: PushMessageSummary, at index: Int) -> some View {
        let topInset: CGFloat = index == 0 && shouldShowChannelRow ? 0 : 8
        Button {
            if !message.isRead {
                Task { await viewModel.markRead(message, isRead: true) }
            }
            handleSelect(message)
        } label: {
            MessageRowView(message: message)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 0)
                .padding(.horizontal, 12)
                .contentShape(Rectangle())
        }
        .buttonStyle(.appPlain)
        .listRowInsets(EdgeInsets(
            top: topInset,
            leading: 0,
            bottom: 12,
            trailing: 0,
        ))
        .swipeActions {
            markReadAction(for: message)
            deleteAction(for: message)
        }
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

    private var channelFilterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                channelChip(
                    title: "all",
                    unreadCount: viewModel.unreadMessageCount,
                    isSelected: viewModel.selectedChannel == nil,
                ) {
                    viewModel.clearChannelSelection()
                }

                ForEach(displayedChannelSummaries) { summary in
                    channelChip(
                        title: resolvedChannelDisplayName(for: summary.key) ?? summary.title,
                        unreadCount: summary.unreadCount,
                        isSelected: viewModel.selectedChannel == summary.key,
                    ) {
                        viewModel.toggleChannelSelection(summary.key)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, channelFilterVerticalPadding)
        }
        .accessibilityIdentifier("message-channel-filter")
    }

    private var channelFilterListRow: some View {
        channelFilterBar
            .listRowInsets(EdgeInsets())
            .listRowBackground(
                Group { Color.clear },
            )
            .hideListSeparator()
    }

    private var channelFilterVerticalPadding: CGFloat {
        0
    }

    private func channelChip(
        title: String,
        unreadCount: Int,
        isSelected: Bool,
        action: @escaping () -> Void,
    ) -> some View {
        let displayTitle = truncatedChannelTitle(title)

        return Button {
            if reduceMotion {
                action()
            } else {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) {
                    action()
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(displayTitle)
                    .font(.caption)
                    .fontWeight(isSelected ? .semibold : .regular)
                    .foregroundColor(isSelected ? .accentColor : .primary)
                    .lineLimit(1)
                if unreadCount > 0 {
                    Text("\(unreadCount)")
                        .font(.caption2)
                        .fontWeight(.semibold)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(
                            Capsule(style: .continuous)
                                .fill(Color.accentColor),
                        )
                        .foregroundColor(.white)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(
                        isSelected
                            ? Color.accentColor.opacity(0.12)
                            : Color.primary.opacity(0.025),
                    ),
            )
        }
        .buttonStyle(.appPlain)
    }

    private func truncatedChannelTitle(_ title: String) -> String {
        String(title.prefix(16))
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
                    .foregroundColor(.secondary)
                    .accessibilityHidden(true)
                Text(localizationManager.localized("no_messages_yet"))
                    .font(.headline)
                Text(localizationManager
                    .localized(
                        "you_can_use_the_pushgo_cli_or_other_integration_tools_to_send_a_test_push_to_the_current_device",
                    ))
                    .font(.subheadline)
                    .foregroundColor(.secondary)
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
            if #available(iOS 18, *) {
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
    @Environment(LocalizationManager.self) private var localizationManager: LocalizationManager

    func body(content: Content) -> some View {
        let queryBinding = Binding(
            get: { searchViewModel.query },
            set: { searchViewModel.updateQuery($0) },
        )
        return content
            .searchable(
                text: queryBinding,
                placement: .navigationBarDrawer(displayMode: .automatic),
                prompt: localizationManager.localized("search_messages")
            )
            .onSubmit(of: .search) {
                searchViewModel.applySearchTextImmediately(searchViewModel.query)
            }
    }
}

private extension View {
    @ViewBuilder
    func listClearBackground() -> some View {
        self
            .scrollContentBackground(.hidden)
            .background(Color.clear)
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

    func handleMarkAllAsRead() {
        Task {
            let updated = await viewModel.markCurrentChannelAsRead()
            if updated > 0 {
                environment.showToast(
                    message: localizationManager.localized(
                        "placeholder_number_items_read",
                        currentChannelDisplayName,
                        updated,
                    ),
                    style: .success,
                    duration: 1.5,
                )
            } else {
                environment.showToast(
                    message: localizationManager.localized("placeholder_no_unread_messages", currentChannelDisplayName),
                    style: .info,
                    duration: 1.5,
                )
            }
        }
    }

    func startCurrentChannelExport() {
        Task {
            do {
                let messages = try await environment.dataStore.loadMessages(
                    filter: viewModel.currentQueryFilter(),
                    channel: viewModel.currentChannelRawValue(),
                )
                guard !messages.isEmpty else {
                    await MainActor.run {
                        environment.showToast(
                            message: localizationManager.localized(
                                "placeholder_no_exported_messages_yet",
                                currentChannelDisplayName
                            ),
                            style: .info,
                            duration: 1.5,
                        )
                    }
                    return
                }
                await MainActor.run {
                    exportDocument = MessagesExportDocument(messages: messages)
                    exportFilename = exportFilename(for: viewModel.selectedChannel)
                    exportChannelDisplayName = currentChannelDisplayName
                    isExportingChannelMessages = true
                }
            } catch {
                await MainActor.run {
                    environment.showToast(
                        message: localizationManager.localized("export_failed_placeholder", error.localizedDescription),
                        style: .error,
                        duration: 2,
                    )
                }
            }
        }
    }

    func exportFilename(for channel: MessageChannelKey?) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let timestamp = formatter.string(from: Date())
        let channelComponent: String = if let channel {
            sanitizedFilenameComponent(resolvedChannelDisplayName(for: channel) ?? channel.displayName)
        } else {
            "all"
        }
        return "pushgo-\(channelComponent)-\(timestamp)"
    }

    private func resolvedChannelDisplayName(for channel: MessageChannelKey?) -> String? {
        guard let channel else { return nil }
        if channel.rawChannelValue == "" {
            return localizationManager.localized("not_grouped")
        }
        return environment.channelDisplayName(for: channel.rawChannelValue) ?? channel.displayName
    }

    func sanitizedFilenameComponent(_ raw: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        var buffer = ""
        var previousWasSeparator = false
        for scalar in raw.unicodeScalars {
            if allowed.contains(scalar) {
                let character = Character(scalar)
                buffer.append(character)
                previousWasSeparator = false
            } else if !previousWasSeparator {
                buffer.append("-")
                previousWasSeparator = true
            }
        }
        let trimmed = buffer.trimmingCharacters(in: CharacterSet(charactersIn: "-_"))
        return trimmed.isEmpty ? "channel" : trimmed
    }

    private var selectedMessageBinding: Binding<PushMessageSummary?> {
        Binding(
            get: { onSelect == nil ? selectedMessage : nil },
            set: { selectedMessage = $0 },
        )
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            if shouldShowMarkAllAsReadButton {
                Button {
                    handleMarkAllAsRead()
                } label: {
                    Image(systemName: "envelope.open.fill")
                }
                .accessibilityLabel(localizationManager.localized("mark_all_as_read"))
            }

            if hasMessages {
                Button {
                    showChannelCleanupConfirmation = true
                } label: {
                    Image(systemName: "bin.xmark")
                }
                .accessibilityLabel(localizationManager.localized("clean_all_read_messages"))
                .disabled(isCleaningChannel)
            }

            if shouldShowExportButton {
                Button {
                    startCurrentChannelExport()
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .accessibilityLabel(localizationManager.localized("export_messages"))
            }
        }
    }

    private func handleSelect(_ message: PushMessageSummary) {
        selectedMessage = message
        if let onSelect {
            onSelect(message)
        }
    }
    private func openPendingMessageIfNeeded() {
        guard let targetId = environment.pendingMessageToOpen else { return }
        Task {
            let loaded = try? await environment.dataStore.loadMessage(id: targetId)
            guard let message = loaded ?? nil else { return }
            let summary = PushMessageSummary(message: message)
            await MainActor.run {
                handleSelect(summary)
                pendingScrollTarget = targetId
                environment.pendingMessageToOpen = nil
            }
        }
    }

    private func scrollToPendingMessageIfNeeded(_ proxy: ScrollViewProxy) {
        guard let targetId = pendingScrollTarget else { return }
        guard viewModel.filteredMessages.contains(where: { $0.id == targetId }) else { return }
        if reduceMotion {
            proxy.scrollTo(targetId, anchor: .center)
        } else {
            withAnimation(.easeInOut(duration: 0.2)) {
                proxy.scrollTo(targetId, anchor: .center)
            }
        }
        pendingScrollTarget = nil
    }

    private func applyDefaultSelectionIfNeeded() {
        guard autoSelectFirstMessage, let onSelect else { return }
        guard !isShowingSearchResults else { return }
        guard let first = viewModel.filteredMessages.first else { return }
        guard lastAutoSelectedMessageId != first.id else { return }
        lastAutoSelectedMessageId = first.id
        onSelect(first)
    }
}
