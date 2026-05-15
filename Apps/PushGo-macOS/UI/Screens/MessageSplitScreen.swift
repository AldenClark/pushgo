import SwiftUI

struct MessageSplitScreen: View {
    @Environment(AppEnvironment.self) private var environment: AppEnvironment
    @Environment(LocalizationManager.self) private var localizationManager: LocalizationManager

    let messageListViewModel: MessageListViewModel
    let searchViewModel: MessageSearchViewModel
    @Binding var selection: UUID?
    @Binding var selectedMessageSnapshot: PushMessage?
    var openMessageId: UUID? = nil
    var onOpenMessageHandled: (() -> Void)? = nil

    @State private var pendingNotificationSelectionId: UUID?
    @State private var didLoad: Bool = false
    @State private var isBatchMode: Bool = false
    @State private var batchSelection: Set<UUID> = []
    @State private var searchFieldText: String = ""
    @State private var isFilterPopoverPresented = false

    private let fixedListWidth: CGFloat = 300

    var body: some View {
        HSplitView {
            messageListPane
            messageDetailPane
        }
        .environment(searchViewModel)
        .onAppear {
            if searchFieldText != searchViewModel.query {
                searchFieldText = searchViewModel.query
            }
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
        .onChange(of: searchFieldText) { _, newValue in
            guard !isBatchMode else { return }
            guard searchViewModel.query != newValue else { return }
            searchViewModel.updateQuery(newValue)
        }
        .onChange(of: searchViewModel.query) { _, newValue in
            guard !isBatchMode else { return }
            if searchFieldText != newValue {
                searchFieldText = newValue
            }
        }
        .onChange(of: isBatchMode) { _, isActive in
            searchFieldText = isActive ? "" : searchViewModel.query
        }
        .onChange(of: selection) { _, newValue in
            if newValue != pendingNotificationSelectionId {
                pendingNotificationSelectionId = nil
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
        .onChange(of: environment.pendingLocalDeletionController.pendingDeletion) { _, _ in
            if let selectedMessageSnapshot,
               isPendingLocalDeletion(selectedMessageSnapshot.id, channelId: selectedMessageSnapshot.channel)
            {
                selection = nil
                self.selectedMessageSnapshot = nil
            }
            let visibleIDs = Set((searchViewModel.hasSearched ? visibleSearchResults : visibleFilteredMessages).map(\.id))
            batchSelection = batchSelection.intersection(visibleIDs)
            ensureMessagesSelectionIfNeeded()
        }
    }

    @ViewBuilder
    private var messageListPane: some View {
        navigationContainer {
            MessageListScreen(
                viewModel: messageListViewModel,
                selection: $selection,
                batchSelection: $batchSelection,
                isBatchMode: $isBatchMode
            )
            .frame(minWidth: fixedListWidth, idealWidth: fixedListWidth, maxWidth: fixedListWidth)
            .refreshable {
                await handleProviderIngressPullRefresh()
            }
            .searchable(
                text: $searchFieldText,
                placement: .toolbar,
                prompt: Text(localizationManager.localized("search_messages"))
            )
            .navigationTitle(isBatchMode ? "" : localizationManager.localized("messages"))
        }
        .pendingLocalDeletionBarHost(environment: environment)
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
            if let displayedMessage = selectedMessageSnapshot {
                MessageDetailScreen(
                    messageId: displayedMessage.id,
                    message: displayedMessage,
                    onPrepareDelete: {
                        if selection == displayedMessage.id {
                            selection = nil
                        }
                        selectedMessageSnapshot = nil
                    },
                    shouldDismissOnDelete: false,
                    useNavigationContainer: false,
                    showsDeleteToolbarAction: false,
                    showsPendingDeletionBar: false,
                )
                .id(displayedMessage.id)
            } else if let messageId = selection {
                Color.clear
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(messageDetailEmptyBackground)
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
        Color.appWindowBackground
    }

    @MainActor
    private func refreshMessagesIfNeeded() async {
        await messageListViewModel.refresh()
        searchViewModel.refreshMessagesIfNeeded()
        ensureMessagesSelectionIfNeeded()
        await syncSelectedMessageSnapshot(for: selection, markRead: false)
    }

    @MainActor
    private func handleProviderIngressPullRefresh() async {
        _ = await environment.syncProviderIngress(reason: "messages_pull_to_refresh")
        if messageListViewModel.isUnreadOnlyFilterActive {
            await messageListViewModel.reconcileUnreadFilterSession()
            searchViewModel.refreshMessagesIfNeeded()
            ensureMessagesSelectionIfNeeded()
            await syncSelectedMessageSnapshot(for: selection, markRead: false)
        } else {
            await refreshMessagesIfNeeded()
        }
    }

    private func ensureMessagesSelectionIfNeeded() {
        guard let selection else { return }

        let existsInMessages = visibleFilteredMessages.contains(where: { $0.id == selection })
        let existsInSearch = visibleSearchResults.contains(where: { $0.id == selection })

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
        if let loaded {
            scheduleDetailImageMetadataPrime(for: loaded)
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
            scheduleDetailImageMetadataPrime(for: message)
        }
    }

    private func scheduleDetailImageMetadataPrime(for message: PushMessage) {
        let bodyText = message.resolvedBody.rawText
        let directImageURLs = message.imageURLs
        Task.detached(priority: .utility) {
            let imageURLs = resolvedDetailImageAssetURLs(
                bodyText: bodyText,
                directImageURLs: directImageURLs
            )
            await SharedImageCache.primeMetadataSnapshots(for: imageURLs)
        }
    }

    private func markMessageReadIfNeeded(_ message: PushMessage, messageId: UUID) async {
        guard !message.isRead else { return }
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
            return visibleSearchResults.map(\.id)
        }
        return visibleFilteredMessages.map(\.id)
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

    private var visibleFilteredMessages: [PushMessageSummary] {
        let baseMessages = messageListViewModel.filteredMessages.filter { !isPendingLocalDeletion($0.id, channelId: $0.channel) }
        let selectedTags = messageListViewModel.selectedTags
        guard !selectedTags.isEmpty else {
            return baseMessages
        }
        return baseMessages.filter { message in
            let tags = Set(message.tags.map(normalizedTag))
            return selectedTags.contains(where: tags.contains)
        }
    }

    private var visibleSearchResults: [PushMessageSummary] {
        searchViewModel.displayedResults.filter { !isPendingLocalDeletion($0.id, channelId: $0.channel) }
    }

    private func isPendingLocalDeletion(_ messageId: UUID, channelId: String?) -> Bool {
        environment.pendingLocalDeletionController.suppressesMessage(id: messageId, channelId: channelId)
    }

    private var displayedTagOptions: [String] {
        messageListViewModel.tagSummaries
            .sorted { lhs, rhs in
                if lhs.totalCount != rhs.totalCount {
                    return lhs.totalCount > rhs.totalCount
                }
                return lhs.tag.localizedCaseInsensitiveCompare(rhs.tag) == .orderedAscending
            }
            .map(\.tag)
    }

    private var displayedChannelSummaries: [MessageChannelSummary] {
        messageListViewModel.channelSummaries.sorted { lhs, rhs in
            if lhs.totalCount != rhs.totalCount {
                return lhs.totalCount > rhs.totalCount
            }
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
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

        if let selectedMessageSnapshot,
           scope.suppressesMessage(id: selectedMessageSnapshot.id, channelId: selectedMessageSnapshot.channel)
        {
            selection = nil
            self.selectedMessageSnapshot = nil
        }
        batchSelection.subtract(scope.messageIDs)
    }

    private var selectedBatchMessageSummaries: [PushMessageSummary] {
        let source: [PushMessageSummary] = searchViewModel.hasSearched
            ? visibleSearchResults
            : visibleFilteredMessages
        return source.filter { batchSelection.contains($0.id) }
    }

    private var selectedBatchUnreadMessages: [PushMessageSummary] {
        selectedBatchMessageSummaries.filter { !$0.isRead }
    }

    private var allVisibleMessageIDs: Set<UUID> {
        let source: [PushMessageSummary] = searchViewModel.hasSearched
            ? visibleSearchResults
            : visibleFilteredMessages
        return Set(source.map(\.id))
    }

    private var areAllVisibleMessagesSelected: Bool {
        let visibleIDs = allVisibleMessageIDs
        return !visibleIDs.isEmpty && batchSelection == visibleIDs
    }

    private func toggleSelectAllVisibleMessages() {
        let visibleIDs = allVisibleMessageIDs
        guard !visibleIDs.isEmpty else { return }
        batchSelection = areAllVisibleMessagesSelected ? [] : visibleIDs
    }

    private func setBatchMode(_ enabled: Bool) {
        isBatchMode = enabled
        if enabled {
            selection = nil
            selectedMessageSnapshot = nil
        } else {
            batchSelection.removeAll()
        }
    }

    @MainActor
    private func exitBatchModeAfterFlushingPendingDeletion() async {
        await environment.pendingLocalDeletionController.commitCurrentIfNeeded()
        setBatchMode(false)
    }

    private func markSelectedMessagesAsRead() {
        let unreadMessages = selectedBatchUnreadMessages
        guard !unreadMessages.isEmpty else { return }
        Task {
            await messageListViewModel.markRead(unreadMessages)
            await MainActor.run {
                batchSelection.removeAll()
            }
        }
    }

    @ToolbarContentBuilder
    private var messageListToolbarContent: some ToolbarContent {
        if isBatchMode {
            ToolbarItem(placement: .navigation) {
                Button {
                    toggleSelectAllVisibleMessages()
                } label: {
                    Image(systemName: areAllVisibleMessagesSelected ? "checkmark.rectangle.stack.fill" : "checkmark.rectangle.stack")
                }
                .help(localizationManager.localized("all"))
                .accessibilityLabel(localizationManager.localized("all"))
            }
        }

        ToolbarItemGroup(placement: .primaryAction) {
            if isBatchMode {
                Button {
                    markSelectedMessagesAsRead()
                } label: {
                    Image(systemName: "envelope.open")
                }
                .help(localizationManager.localized("mark_as_read"))
                .accessibilityLabel(localizationManager.localized("mark_as_read"))
                .disabled(selectedBatchUnreadMessages.isEmpty)

                Button(role: .destructive) {
                    Task { await scheduleDeletion(for: selectedBatchMessageSummaries) }
                } label: {
                    Image(systemName: "trash")
                }
                .help(localizationManager.localized("delete"))
                .accessibilityLabel(localizationManager.localized("delete"))
                .disabled(batchSelection.isEmpty)
                
                Button {
                    Task { await exitBatchModeAfterFlushingPendingDeletion() }
                } label: {
                    batchDoneToolbarIcon()
                }
                .help(localizationManager.localized("done"))
                .accessibilityLabel(localizationManager.localized("done"))
            } else {
                Button {
                    isFilterPopoverPresented = true
                } label: {
                    filterToolbarIcon(isHighlighted: isFilterMenuHighlighted)
                }
                .help(localizationManager.localized("channel"))
                .accessibilityLabel(localizationManager.localized("channel"))
                .accessibilityIdentifier("action.messages.filter")
                .popover(isPresented: $isFilterPopoverPresented, arrowEdge: .top) {
                    filterPopoverPresentationContent
                }
            }
        }
    }

    @ToolbarContentBuilder
    private var messageDetailToolbarContent: some ToolbarContent {
        ToolbarItem(placement: .secondaryAction) {
            Button(role: .destructive) {
                if let message = selectedMessageSnapshot, message.id == selection {
                    Task { await scheduleDeletion(for: [PushMessageSummary(message: message)]) }
                }
            } label: {
                Image(systemName: "trash")
            }
            .help(localizationManager.localized("delete"))
            .accessibilityLabel(localizationManager.localized("delete"))
            .disabled(selectedMessageSnapshot?.id != selection || isBatchMode)
        }
    }

    private var filterPopoverPresentationContent: some View {
        ScrollView {
            filterPopoverContent
        }
        .frame(maxHeight: 420)
    }

    private var filterPopoverContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            Button {
                setBatchMode(true)
                isFilterPopoverPresented = false
            } label: {
                filterMenuSelectionRow(
                    title: "选择",
                    systemImage: "checklist",
                    isSelected: isBatchMode
                )
            }
            .buttonStyle(.plain)
            .padding(.vertical, 2)

            Button {
                messageListViewModel.toggleUnreadOnlyFilter()
            } label: {
                filterMenuSelectionRow(
                    title: localizationManager.localized("message_show_unread_only"),
                    systemImage: "envelope.badge",
                    isSelected: messageListViewModel.isUnreadOnlyFilterActive
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

                MessageSplitFilterChipFlowLayout(horizontalSpacing: 8, verticalSpacing: 8) {
                    ForEach(displayedChannelSummaries) { summary in
                        filterCloudChip(
                            title: resolvedChannelDisplayName(for: summary.key) ?? summary.title,
                            isSelected: messageListViewModel.selectedChannels.contains(summary.key)
                        ) {
                            messageListViewModel.toggleChannelSelection(summary.key)
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

                MessageSplitFilterChipFlowLayout(horizontalSpacing: 8, verticalSpacing: 8) {
                    ForEach(displayedTagOptions, id: \.self) { tag in
                        tagCloudChip(tag: tag)
                    }
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .frame(width: 316, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var isFilterMenuHighlighted: Bool {
        !messageListViewModel.selectedChannels.isEmpty
            || !messageListViewModel.selectedTags.isEmpty
            || messageListViewModel.isUnreadOnlyFilterActive
    }

    private func tagCloudChip(tag: String) -> some View {
        let isSelected = messageListViewModel.selectedTags.contains(tag)
        return filterCloudChip(title: tag, isSelected: isSelected) {
            messageListViewModel.toggleTagSelection(tag)
        }
        .accessibilityIdentifier("filter.tag.\(tag)")
    }

    private func filterCloudChip(
        title: String,
        isSelected: Bool,
        onTap: @escaping () -> Void
    ) -> some View {
        Button {
            onTap()
        } label: {
            Text(title)
                .lineLimit(1)
                .truncationMode(.tail)
                .multilineTextAlignment(.center)
                .font(.caption.weight(.medium))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .frame(minWidth: 60, maxWidth: 208, alignment: .center)
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

    private func resolvedChannelDisplayName(for channel: MessageChannelKey?) -> String? {
        guard let channel else { return nil }
        if channel.rawChannelValue == "" {
            return localizationManager.localized("not_grouped")
        }
        return environment.channelDisplayName(for: channel.rawChannelValue) ?? channel.displayName
    }
}

private struct MessageSplitFilterChipFlowLayout: Layout {
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
