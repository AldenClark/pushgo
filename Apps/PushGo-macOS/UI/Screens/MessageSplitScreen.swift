import SwiftUI

struct MessageSplitScreen: View {
    @Environment(AppEnvironment.self) private var environment: AppEnvironment
    @Environment(LocalizationManager.self) private var localizationManager: LocalizationManager

    @Bindable var messageListViewModel: MessageListViewModel
    let searchViewModel: MessageSearchViewModel
    @Binding var selection: UUID?
    @Binding var selectedMessageSnapshot: PushMessage?
    var openMessageId: UUID? = nil
    var onOpenMessageHandled: (() -> Void)? = nil

    @State private var pendingNotificationSelectionId: UUID?
    @State private var ignoreMessageStoreRevisionsUntil: Date?
    @State private var ignoreRevisionResetTask: Task<Void, Never>?
    @State private var didLoad: Bool = false

    private let fixedListWidth: CGFloat = 300

    var body: some View {
        navigationContainer {
            HSplitView {
                messageListPane
                messageDetailPane
            }
            .environment(searchViewModel)
            .onAppear {
                guard !didLoad else { return }
                didLoad = true
                Task {
                    await refreshMessagesIfNeeded()
                    openPendingMessageIfNeeded()
                }
            }
            .onChange(of: messageListViewModel.filteredMessages) { _, _ in
                ensureMessagesSelectionIfNeeded()
                Task { await syncSelectedMessageSnapshot(for: selection, markRead: false) }
            }
            .onChange(of: searchViewModel.displayedResults) { _, _ in
                ensureMessagesSelectionIfNeeded()
                Task { await syncSelectedMessageSnapshot(for: selection, markRead: false) }
            }
            .onChange(of: selection) { _, newValue in
                if newValue != pendingNotificationSelectionId {
                    pendingNotificationSelectionId = nil
                }
                if let newValue, selectedMessageSnapshot?.id != newValue {
                    selectedMessageSnapshot = nil
                }
                ensureMessagesSelectionIfNeeded()
                Task { await syncSelectedMessageSnapshot(for: newValue, markRead: true) }
                if let newValue {
                    Task { await prefetchNeighborMessages(around: newValue) }
                }
            }
            .onChange(of: openMessageId) { _, _ in
                openPendingMessageIfNeeded()
            }
            .onChange(of: environment.messageStoreRevision) { _, _ in
                guard !shouldIgnoreMessageStoreRevision() else { return }
                Task { await refreshMessagesForStoreChange() }
            }
        }
    }

    private var messageListPane: some View {
        navigationContainer {
            MessageListScreen(viewModel: messageListViewModel, selection: $selection)
                .searchable(
                    text: Binding(
                        get: { searchViewModel.query },
                        set: { newValue in searchViewModel.updateQuery(newValue) }
                    ),
                    prompt: Text(localizationManager.localized("search_messages"))
                )
                .frame(minWidth: fixedListWidth, idealWidth: fixedListWidth, maxWidth: fixedListWidth)
        }
        .toolbar { messageListToolbarContent }
    }

    private var messageDetailPane: some View {
        navigationContainer {
            messagesDetail
        }
        .toolbar { messageDetailToolbarContent }
    }

    private var messagesDetail: some View {
        Group {
            if let messageId = selection {
                MessageDetailScreen(
                    messageId: messageId,
                    message: selectedMessageSnapshot,
                    onDelete: {
                        selection = nil
                        selectedMessageSnapshot = nil
                    },
                    shouldDismissOnDelete: false,
                    useNavigationContainer: false,
                )
                .id(messageId)
            } else {
                EntityEmptyView(
                    iconName: "rectangle.split.2x1",
                    title: localizationManager.localized("select_a_message_to_view_details"),
                    subtitle: localizationManager.localized("select_a_message_to_view_details_hint"),
                    subtitleMaxWidth: 420
                )
                .background(messageDetailEmptyBackground)
            }
        }
    }

    private var messageDetailEmptyBackground: Color {
        if #available(macOS 26.0, *) {
            Color.appWindowBackground
        } else {
            Color.messageListBackground
        }
    }

    @MainActor
    private func refreshMessagesIfNeeded() async {
        await messageListViewModel.refresh()
        searchViewModel.refreshMessagesIfNeeded()
        ensureMessagesSelectionIfNeeded()
        await syncSelectedMessageSnapshot(for: selection, markRead: false)
    }

    @MainActor
    private func refreshMessagesForStoreChange() async {
        await refreshMessagesIfNeeded()
    }

    private func ensureMessagesSelectionIfNeeded() {
        guard let selection else { return }

        let existsInMessages = messageListViewModel.filteredMessages.contains(where: { $0.id == selection })
        let existsInSearch = searchViewModel.displayedResults.contains(where: { $0.id == selection })

        if pendingNotificationSelectionId == selection {
            if existsInMessages || existsInSearch {
                pendingNotificationSelectionId = nil
            }
            return
        }

        if searchViewModel.hasSearched {
            if !existsInSearch {
                self.selection = nil
            }
        } else {
            if !existsInMessages {
                self.selection = nil
            }
        }
    }

    private func syncSelectedMessageSnapshot(for messageId: UUID?, markRead: Bool) async {
        guard let messageId else {
            await MainActor.run {
                selectedMessageSnapshot = nil
            }
            return
        }

        let existingSnapshot = await MainActor.run { selectedMessageSnapshot }
        if let existingSnapshot, existingSnapshot.id == messageId {
            if markRead {
                await markMessageReadIfNeeded(existingSnapshot, messageId: messageId)
            }
            return
        }

        let revision = environment.messageStoreRevision
        let loadResult = await MessageDetailSnapshotCache.shared.loadMessage(
            id: messageId,
            revision: revision
        ) { [dataStore = environment.dataStore] in
            try await dataStore.loadMessage(id: messageId)
        }
        let loaded = loadResult.message
        await MainActor.run {
            guard selection == messageId else { return }
            selectedMessageSnapshot = loaded
        }
        guard markRead, let loaded else { return }
        await markMessageReadIfNeeded(loaded, messageId: messageId)
    }

    private func openPendingMessageIfNeeded() {
        guard let targetId = openMessageId else { return }
        Task {
            let loadResult = await MessageDetailSnapshotCache.shared.loadMessage(
                id: targetId,
                revision: environment.messageStoreRevision
            ) { [dataStore = environment.dataStore] in
                try await dataStore.loadMessage(id: targetId)
            }
            let loaded = loadResult.message
            guard let message = loaded else { return }
            await MainActor.run {
                pendingNotificationSelectionId = targetId
                selection = targetId
                selectedMessageSnapshot = message
                onOpenMessageHandled?()
            }
        }
    }

    private func markMessageReadIfNeeded(_ message: PushMessage, messageId: UUID) async {
        guard !message.isRead else { return }
        await MainActor.run {
            ignoreNextMessageStoreRevisions()
        }
        await messageListViewModel.markRead(PushMessageSummary(message: message), isRead: true)
        await MainActor.run {
            guard selection == messageId else { return }
            selectedMessageSnapshot?.isRead = true
            MessageDetailSnapshotCache.shared.store(
                message: selectedMessageSnapshot,
                id: messageId,
                revision: environment.messageStoreRevision
            )
        }
    }

    private func currentMessageSelectionOrder() -> [UUID] {
        if searchViewModel.hasSearched {
            return searchViewModel.displayedResults.map(\.id)
        }
        return messageListViewModel.filteredMessages.map(\.id)
    }

    private func prefetchNeighborMessages(around messageId: UUID) async {
        let messageIds = currentMessageSelectionOrder()
        guard let centerIndex = messageIds.firstIndex(of: messageId) else { return }
        var neighborIds: [UUID] = []
        if centerIndex > 0 {
            neighborIds.append(messageIds[centerIndex - 1])
        }
        if centerIndex + 1 < messageIds.count {
            neighborIds.append(messageIds[centerIndex + 1])
        }
        guard !neighborIds.isEmpty else { return }
        let revision = environment.messageStoreRevision
        for neighborId in neighborIds {
            await MessageDetailSnapshotCache.shared.prefetchMessage(
                id: neighborId,
                revision: revision
            ) { [dataStore = environment.dataStore] in
                try await dataStore.loadMessage(id: neighborId)
            }
        }
    }

    private func deleteSelectedMessage() {
        guard let message = selectedMessageSnapshot else { return }
        ignoreNextMessageStoreRevisions(for: 1.2)
        Task {
            await messageListViewModel.delete(PushMessageSummary(message: message))
            await MainActor.run {
                selection = nil
                selectedMessageSnapshot = nil
                ensureMessagesSelectionIfNeeded()
            }
        }
    }

    private func ignoreNextMessageStoreRevisions(for interval: TimeInterval = 0.7) {
        ignoreMessageStoreRevisionsUntil = Date().addingTimeInterval(interval)
        ignoreRevisionResetTask?.cancel()
        ignoreRevisionResetTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64((interval + 0.2) * 1_000_000_000))
            guard let until = ignoreMessageStoreRevisionsUntil else { return }
            if until <= Date() {
                ignoreMessageStoreRevisionsUntil = nil
            }
        }
    }

    private func shouldIgnoreMessageStoreRevision() -> Bool {
        guard let until = ignoreMessageStoreRevisionsUntil else { return false }
        if until > Date() {
            return true
        }
        ignoreMessageStoreRevisionsUntil = nil
        return false
    }

    @ToolbarContentBuilder
    private var messageListToolbarContent: some ToolbarContent {
        if #available(macOS 26.0, *) {
            ToolbarItemGroup(placement: .primaryAction) {
                messageListToolbarButtons
            }
        } else {
            ToolbarItemGroup(placement: .navigation) {
                messageListToolbarButtons
            }
        }
    }

    @ToolbarContentBuilder
    private var messageDetailToolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .secondaryAction) {
            messageDetailToolbarButtons
        }
    }

    @ViewBuilder
    private var messageListToolbarButtons: some View {
        Menu {
            channelFilterMenuContent
        } label: {
            Image(systemName: messageListViewModel.selectedChannel == nil ? "line.3.horizontal.decrease" : "line.3.horizontal.decrease.circle.fill")
        }
        .menuIndicator(.hidden)
        .help(localizationManager.localized("channel"))
        .accessibilityLabel(localizationManager.localized("channel"))

        Button {
            let nextFilter: MessageFilter = messageListViewModel.selectedFilter == .unread ? .all : .unread
            messageListViewModel.setFilter(nextFilter)
        } label: {
            Image(systemName: messageListViewModel.selectedFilter == .unread ? "envelope.badge.fill" : "envelope.badge")
        }
        .help(localizationManager.localized("unread"))
        .accessibilityLabel(localizationManager.localized("unread"))
    }

    @ViewBuilder
    private var messageDetailToolbarButtons: some View {
        Button(role: .destructive) {
            deleteSelectedMessage()
        } label: {
            Image(systemName: "trash")
        }
        .help(localizationManager.localized("delete"))
        .accessibilityLabel(localizationManager.localized("delete"))
        .disabled(selectedMessageSnapshot == nil)
    }

    @ViewBuilder
    private var channelFilterMenuContent: some View {
        Button {
            messageListViewModel.clearChannelSelection()
        } label: {
            channelFilterMenuItemLabel(
                title: localizationManager.localized("all_groups"),
                isSelected: messageListViewModel.selectedChannel == nil
            )
        }

        ForEach(messageListViewModel.channelSummaries) { summary in
            Button {
                messageListViewModel.toggleChannelSelection(summary.key)
            } label: {
                channelFilterMenuItemLabel(
                    title: resolvedChannelDisplayName(for: summary.key) ?? summary.title,
                    isSelected: messageListViewModel.selectedChannel == summary.key
                )
            }
        }
    }

    private func channelFilterMenuItemLabel(title: String, isSelected: Bool) -> some View {
        HStack(spacing: 8) {
            if isSelected {
                Image(systemName: "checkmark")
            }
            Text(title)
        }
    }

    private func resolvedChannelDisplayName(for channel: MessageChannelKey?) -> String? {
        guard let channel else { return nil }
        if channel.rawChannelValue == "" {
            return localizationManager.localized("not_grouped")
        }
        return environment.channelDisplayName(for: channel.rawChannelValue) ?? channel.displayName
    }
}
