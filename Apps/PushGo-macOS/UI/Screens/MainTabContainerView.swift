import SwiftUI
import UniformTypeIdentifiers
import AppKit

struct MainTabContainerView: View {
    @Environment(\.appEnvironment) private var environment: AppEnvironment
    @Environment(LocalizationManager.self) private var localizationManager: LocalizationManager

    @State private var searchViewModel = MessageSearchViewModel()
    @State private var messageListViewModel = MessageListViewModel()
    @State private var sidebarSelection: SidebarSelection? = .messagesAll

    @State private var selectedMessageId: UUID?
    @State private var selectedMessageSnapshot: PushMessage?
    @State private var pendingNotificationSelectionId: UUID?

    @State private var isExportingMessages = false
    @State private var exportDocument = MessagesExportDocument(messages: [])
    @State private var exportFilename = ""
    @State private var exportChannelDisplayName = LocalizationManager.localizedSync("all_groups")

    @State private var ignoreMessageStoreRevisionsUntil: Date?
    @State private var ignoreRevisionResetTask: Task<Void, Never>?
    @State private var didRefreshAuthorizationStatus: Bool = false
    @State private var showChannelCleanupConfirmation = false
    @State private var isCleaningChannel = false

    var body: some View {
        NavigationSplitView {
            sidebarMenu
                .navigationSplitViewColumnWidth(min: 220, ideal: 220, max: 240)
        } detail: {
            detailContent
        }
        .environment(searchViewModel)
        .alert(
            localizationManager.localized("confirm_cleanup_messages"),
            isPresented: $showChannelCleanupConfirmation
        ) {
            Button(localizationManager.localized("confirm")) {
                guard !isCleaningChannel else { return }
                isCleaningChannel = true
                Task {
                    _ = await messageListViewModel.cleanupReadMessages()
                    isCleaningChannel = false
                }
            }
            Button(localizationManager.localized("cancel"), role: .cancel) {}
        } message: {
            Text(cleanupConfirmationMessage)
        }
        .task {
            guard !didRefreshAuthorizationStatus else { return }
            didRefreshAuthorizationStatus = true
            await environment.pushRegistrationService.refreshAuthorizationStatus()
            environment.updateActiveTab(activeTab)
            if activeTab == .messages {
                await refreshMessagesIfNeeded()
            }
            if environment.pendingMessageToOpen != nil {
                openPendingMessageIfNeeded()
            }
        }
        .task {
            for await _ in NotificationCenter.default.notifications(named: .pushgoOpenSettingsFromMenuBar) {
                sidebarSelection = .settings
            }
        }
        .onChange(of: environment.pendingMessageToOpen) { _, id in
            if id != nil {
                openPendingMessageIfNeeded()
            }
        }
        .onChange(of: localizationManager.locale) { _, _ in
            exportChannelDisplayName = localizationManager.localized("all_groups")
        }
        .onChange(of: sidebarSelection) { oldValue, newValue in
            applySidebarSelection(previous: oldValue, current: newValue)
        }
        .onChange(of: messageListViewModel.selectedChannel) { _, _ in
            syncSidebarSelectionIfNeeded()
        }
        .onChange(of: environment.messageStoreRevision) { _, _ in
            guard !shouldIgnoreMessageStoreRevision() else { return }
            Task { await refreshMessagesForStoreChange() }
        }
        .onChange(of: messageListViewModel.filteredMessages) { _, _ in
            guard activeTab == .messages else { return }
            ensureMessagesSelectionIfNeeded()
            Task { await syncSelectedMessageSnapshot(for: selectedMessageId, markRead: false) }
        }
        .onChange(of: searchViewModel.displayedResults) { _, _ in
            guard activeTab == .messages else { return }
            ensureMessagesSelectionIfNeeded()
            Task { await syncSelectedMessageSnapshot(for: selectedMessageId, markRead: false) }
        }
        .onChange(of: selectedMessageId) { _, newValue in
            guard activeTab == .messages else { return }
            if newValue != pendingNotificationSelectionId {
                pendingNotificationSelectionId = nil
            }
            ensureMessagesSelectionIfNeeded()
            Task { await syncSelectedMessageSnapshot(for: newValue, markRead: true) }
        }
    }

    private var activeTab: MainTab {
        sidebarSelection?.mainTab ?? .messages
    }

    private var sidebarChannelSummaries: [MessageChannelSummary] {
        let summaries = messageListViewModel.channelSummaries
        let hasNamedChannel = summaries.contains { summary in
            if case .named = summary.key {
                return true
            }
            return false
        }
        return hasNamedChannel ? summaries : []
    }

    @ViewBuilder
    private var sidebarMenu: some View {
        if sidebarChannelSummaries.isEmpty {
            List(selection: $sidebarSelection) {
                sidebarPrimaryRow(.messages)
                    .tag(SidebarSelection.messagesAll)
                sidebarPrimaryRow(.channels)
                    .tag(SidebarSelection.channels)
                sidebarPrimaryRow(.devices)
                    .tag(SidebarSelection.devices)
                sidebarPrimaryRow(.settings)
                    .tag(SidebarSelection.settings)
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
        } else {
            VStack(spacing: 0) {
                List(selection: $sidebarSelection) {
                    sidebarPrimaryRow(.messages)
                        .tag(SidebarSelection.messagesAll)
                    ForEach(sidebarChannelSummaries) { summary in
                        sidebarChannelRow(summary)
                            .tag(SidebarSelection.messagesChannel(summary.key))
                    }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
                .frame(maxHeight: .infinity)

                List(selection: $sidebarSelection) {
                    sidebarPrimaryRow(.channels)
                        .tag(SidebarSelection.channels)
                    sidebarPrimaryRow(.devices)
                        .tag(SidebarSelection.devices)
                    sidebarPrimaryRow(.settings)
                        .tag(SidebarSelection.settings)
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
                .scrollDisabled(true)
                .frame(height: SidebarLayout.bottomListHeight)
            }
        }
    }

    private func sidebarPrimaryRow(_ tab: MainTab) -> some View {
        HStack(spacing: 10) {
            sidebarIcon(systemImageName: tab.systemImageName)
            Text(tab.localizedTitle(using: localizationManager))
                .font(.headline.weight(.semibold))
            Spacer(minLength: 6)
        }
        .padding(.vertical, SidebarLayout.primaryRowVerticalPadding)
        .contentShape(Rectangle())
        .accessibilityIdentifier("sidebar-\(tab.accessibilityIdentifier)")
        .listRowSeparator(.hidden)
    }

    @ViewBuilder
    private func sidebarChannelRow(_ summary: MessageChannelSummary) -> some View {
        let channelName = resolvedChannelDisplayName(for: summary.key) ?? summary.title
        let baseText = Text(channelName)
            .font(.callout)
            .foregroundStyle(.primary)
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.vertical, SidebarLayout.channelRowVerticalPadding)
            .padding(.leading, SidebarLayout.channelRowLeadingPadding)
            .padding(.trailing, SidebarLayout.channelRowTrailingPadding)
            .listRowSeparator(.hidden)
        if summary.unreadCount > 0 {
            baseText.badge(summary.unreadCount)
        } else {
            baseText
        }
    }

    private enum SidebarLayout {
        static let primaryRowVerticalPadding: CGFloat = 6
        static let primaryRowEstimatedHeight: CGFloat = 32
        static let bottomListHeight: CGFloat = primaryRowEstimatedHeight * 3 + 32
        static let channelRowVerticalPadding: CGFloat = 4
        static let channelRowLeadingPadding: CGFloat = 12
        static let channelRowTrailingPadding: CGFloat = 0
    }

    private func sidebarIcon(systemImageName: String) -> some View {
        let foreground = Color.secondary
        return Image(systemName: systemImageName)
            .font(.caption.weight(.semibold))
            .foregroundColor(foreground)
    }

    @ViewBuilder
    private var detailContent: some View {
        if activeTab == .messages {
            messagesContent
        } else {
            detailView(for: activeTab)
        }
    }

    private var messagesContent: some View {
        let baseView = HSplitView {
            MessageListScreen(viewModel: messageListViewModel, selection: $selectedMessageId)
                .frame(minWidth: 280, idealWidth: 300, maxWidth: 320)
                .toolbar { messageListToolbarContent }
            messagesDetail
                .toolbar { messageDetailToolbarContent }
        }
        return applyToolbarSearchIfNeeded(baseView)
        .fileExporter(
            isPresented: $isExportingMessages,
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
    }

    @ViewBuilder
    private func applyToolbarSearchIfNeeded<Content: View>(_ content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.modifier(MessagesSearchModifier(
                localizationManager: localizationManager,
                searchViewModel: searchViewModel,
            ))
        } else {
            content
        }
    }

    @ViewBuilder
    private func detailView(for tab: MainTab) -> some View {
        switch tab {
        case .messages:
            messagesDetail
        case .devices:
            PushScreen()
        case .channels:
            ChannelManagementView()
        case .settings:
            SettingsView()
        }
    }

    private var messagesDetail: some View {
        Group {
            if let messageId = selectedMessageId {
                MessageDetailScreen(
                    messageId: messageId,
                    message: selectedMessageSnapshot,
                    onDelete: {
                        selectedMessageId = nil
                        selectedMessageSnapshot = nil
                    },
                    shouldDismissOnDelete: false,
                    useNavigationContainer: false,
                )
                .id(messageId)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "rectangle.split.2x1")
                        .font(.title.weight(.semibold))
                        .foregroundColor(.secondary)
                    Text(localizationManager.localized("select_a_message_to_view_details"))
                        .font(.headline)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        await syncSelectedMessageSnapshot(for: selectedMessageId, markRead: false)
    }

    @MainActor
    private func refreshMessagesForStoreChange() async {
        if activeTab == .messages {
            await refreshMessagesIfNeeded()
        } else {
            await messageListViewModel.refresh()
            searchViewModel.refreshMessagesIfNeeded()
        }
    }

    private func ensureMessagesSelectionIfNeeded() {
        guard let selectedMessageId else { return }

        let existsInMessages = messageListViewModel.filteredMessages.contains(where: { $0.id == selectedMessageId })
        let existsInSearch = searchViewModel.displayedResults.contains(where: { $0.id == selectedMessageId })

        if pendingNotificationSelectionId == selectedMessageId {
            if existsInMessages || existsInSearch {
                pendingNotificationSelectionId = nil
            }
            return
        }

        if searchViewModel.hasSearched {
            if !existsInSearch {
                self.selectedMessageId = nil
            }
        } else {
            if !existsInMessages {
                self.selectedMessageId = nil
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

        let loaded = try? await environment.dataStore.loadMessage(id: messageId)
        await MainActor.run {
            guard selectedMessageId == messageId else { return }
            selectedMessageSnapshot = loaded
        }
        guard markRead, let loaded else { return }
        await markMessageReadIfNeeded(loaded, messageId: messageId)
    }

    private func openPendingMessageIfNeeded() {
        guard let targetId = environment.pendingMessageToOpen else { return }
        Task {
            let loaded = try? await environment.dataStore.loadMessage(id: targetId)
            guard let message = loaded else { return }
            await MainActor.run {
                if activeTab != .messages {
                    sidebarSelection = messagesSidebarSelection
                }
                pendingNotificationSelectionId = targetId
                selectedMessageId = targetId
                selectedMessageSnapshot = message
                environment.pendingMessageToOpen = nil
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
            guard selectedMessageId == messageId else { return }
            selectedMessageSnapshot?.isRead = true
        }
    }

    private func handleMarkAllAsRead() async {
        _ = await messageListViewModel.markCurrentChannelAsRead()
    }

    private func toggleSelectedMessageReadState() {
        guard let message = selectedMessageSnapshot, !message.isRead else { return }
        let currentId = selectedMessageId
        ignoreNextMessageStoreRevisions(for: 1.0)
        Task {
            await messageListViewModel.markRead(PushMessageSummary(message: message), isRead: true)
            await MainActor.run {
                guard selectedMessageId == currentId else { return }
                selectedMessageSnapshot?.isRead = true
            }
        }
    }

    private func deleteSelectedMessage() {
        guard let message = selectedMessageSnapshot else { return }
        ignoreNextMessageStoreRevisions(for: 1.2)
        Task {
            await messageListViewModel.delete(PushMessageSummary(message: message))
            await MainActor.run {
                selectedMessageId = nil
                selectedMessageSnapshot = nil
                ensureMessagesSelectionIfNeeded()
            }
        }
    }

    private func copySelectedMessageContent() {
        guard let message = selectedMessageSnapshot else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(message.resolvedBody.rawText, forType: .string)
        environment.showToast(
            message: localizationManager.localized("message_content_copied"),
            style: .success,
            duration: 1.2
        )
    }

    private func startMessagesExport() {
        Task {
            do {
                let messages = try await environment.dataStore.loadMessages(
                    filter: messageListViewModel.currentQueryFilter(),
                    channel: messageListViewModel.currentChannelRawValue(),
                )
                guard !messages.isEmpty else {
                    await MainActor.run {
                        environment.showToast(
                            message: localizationManager.localized(
                                "placeholder_no_exported_messages_yet",
                                resolvedChannelDisplayName(for: messageListViewModel.selectedChannel)
                                    ?? localizationManager.localized("all_groups")
                            ),
                            style: .info,
                            duration: 1.5,
                        )
                    }
                    return
                }
                await MainActor.run {
                    exportDocument = MessagesExportDocument(messages: messages)
                    exportFilename = exportFilenameForExport(channel: messageListViewModel.selectedChannel)
                    exportChannelDisplayName = resolvedChannelDisplayName(for: messageListViewModel.selectedChannel)
                        ?? localizationManager.localized("all_groups")
                    isExportingMessages = true
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

    private func exportFilenameForExport(channel: MessageChannelKey?) -> String {
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

    private func sanitizedFilenameComponent(_ raw: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        var buffer = ""
        var previousWasSeparator = false
        for scalar in raw.unicodeScalars {
            if allowed.contains(scalar) {
                buffer.append(Character(scalar))
                previousWasSeparator = false
            } else if !previousWasSeparator {
                buffer.append("-")
                previousWasSeparator = true
            }
        }
        let trimmed = buffer.trimmingCharacters(in: CharacterSet(charactersIn: "-_"))
        return trimmed.isEmpty ? "channel" : trimmed
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

    private var shouldShowExportButton: Bool {
        !messageListViewModel.filteredMessages.isEmpty
    }

    private var hasMessages: Bool {
        messageListViewModel.totalMessageCount > 0
    }

    private var cleanupConfirmationMessage: String {
        if let channel = messageListViewModel.selectedChannel {
            let displayName = resolvedChannelDisplayName(for: channel) ?? channel.displayName
            let action = localizationManager.localized("clean_channel_read_placeholder", displayName)
            return localizationManager.localized("confirm_cleanup_messages_placeholder", action)
        }
        let action = localizationManager.localized("clean_all_read_messages")
        return localizationManager.localized("confirm_cleanup_messages_placeholder", action)
    }

    private var shouldShowMarkAllAsReadButton: Bool {
        if let channel = messageListViewModel.selectedChannel {
            return messageListViewModel.channelSummaries.first(where: { $0.key == channel })?.hasUnread ?? false
        }
        return messageListViewModel.unreadMessageCount > 0
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
        if #available(macOS 26.0, *) {
            ToolbarItemGroup(placement: .secondaryAction) {
                messageDetailToolbarButtons
            }
        } else {
            ToolbarItemGroup(placement: .primaryAction) {
                messageDetailToolbarButtons
            }
        }
    }

    @ViewBuilder
    private var messageListToolbarButtons: some View {
        if shouldShowMarkAllAsReadButton {
            Button {
                ignoreNextMessageStoreRevisions(for: 1.2)
                Task { await handleMarkAllAsRead() }
            } label: {
                Image(systemName: "envelope.open.fill")
            }
            .help(localizationManager.localized("mark_all_as_read"))
            .accessibilityLabel(localizationManager.localized("mark_all_as_read"))
        }

        if hasMessages {
            Button {
                showChannelCleanupConfirmation = true
            } label: {
                Image(systemName: "bin.xmark")
            }
            .help(localizationManager.localized("clean_all_read_messages"))
            .accessibilityLabel(localizationManager.localized("clean_all_read_messages"))
            .disabled(isCleaningChannel)
        }

        if shouldShowExportButton {
            Button {
                startMessagesExport()
            } label: {
                Image(systemName: "square.and.arrow.up")
            }
            .help(localizationManager.localized("export_messages"))
            .accessibilityLabel(localizationManager.localized("export_messages"))
        }
    }

    @ViewBuilder
    private var messageDetailToolbarButtons: some View {
        if let selectedMessageSnapshot, !selectedMessageSnapshot.isRead {
            Button {
                toggleSelectedMessageReadState()
            } label: {
                Image(systemName: "envelope.open")
            }
            .help(localizationManager.localized("mark_as_read"))
            .accessibilityLabel(localizationManager.localized("mark_as_read"))
        }

        Button(role: .destructive) {
            deleteSelectedMessage()
        } label: {
            Image(systemName: "trash")
        }
        .help(localizationManager.localized("delete"))
        .accessibilityLabel(localizationManager.localized("delete"))
        .disabled(selectedMessageSnapshot == nil)

        Button {
            copySelectedMessageContent()
        } label: {
            Image(systemName: "doc.on.doc")
        }
        .help(localizationManager.localized("copy_content"))
        .accessibilityLabel(localizationManager.localized("copy_content"))
        .disabled(selectedMessageSnapshot == nil)
    }

    private func shouldIgnoreMessageStoreRevision() -> Bool {
        guard let until = ignoreMessageStoreRevisionsUntil else { return false }
        if until > Date() {
            return true
        }
        ignoreMessageStoreRevisionsUntil = nil
        return false
    }

    private var messagesSidebarSelection: SidebarSelection {
        if let channel = messageListViewModel.selectedChannel {
            return .messagesChannel(channel)
        }
        return .messagesAll
    }

    private func applySidebarSelection(previous: SidebarSelection?, current: SidebarSelection?) {
        let previousTab = previous?.mainTab ?? .messages
        let nextTab = current?.mainTab ?? .messages
        environment.updateActiveTab(nextTab)
        guard nextTab == .messages else { return }
        switch current ?? .messagesAll {
        case .messagesAll:
            if messageListViewModel.selectedChannel != nil {
                messageListViewModel.clearChannelSelection()
            }
        case let .messagesChannel(channel):
            if messageListViewModel.selectedChannel != channel {
                messageListViewModel.toggleChannelSelection(channel)
            }
        case .channels, .devices, .settings:
            break
        }
        if previousTab != .messages {
            Task { await refreshMessagesIfNeeded() }
        }
    }

    private func syncSidebarSelectionIfNeeded() {
        guard activeTab == .messages else { return }
        let desired = messagesSidebarSelection
        if sidebarSelection != desired {
            sidebarSelection = desired
        }
    }
}

private struct MessagesSearchModifier: ViewModifier {
    let localizationManager: LocalizationManager
    let searchViewModel: MessageSearchViewModel

    func body(content: Content) -> some View {
        content.searchable(
            text: Binding(
                get: { searchViewModel.query },
                set: { newValue in searchViewModel.updateQuery(newValue) }
            ),
            placement: .toolbar,
            prompt: Text(localizationManager.localized("search_messages"))
        )
    }
}

enum MainTab: Hashable, CaseIterable {
    case messages
    case channels
    case devices
    case settings

    var title: String {
        switch self {
        case .messages:
            "messages"
        case .channels:
            "channels"
        case .devices:
            "push"
        case .settings:
            "settings"
        }
    }

    func localizedTitle(using localizationManager: LocalizationManager) -> String {
        localizationManager.localized(title)
    }

    var systemImageName: String {
        switch self {
        case .messages:
            "tray.full"
        case .channels:
            "dot.radiowaves.left.and.right"
        case .devices:
            "link"
        case .settings:
            "gearshape"
        }
    }

    var accessibilityIdentifier: String {
        switch self {
        case .messages:
            "messages"
        case .channels:
            "channels"
        case .devices:
            "devices"
        case .settings:
            "settings"
        }
    }
}

enum SidebarSelection: Hashable {
    case messagesAll
    case messagesChannel(MessageChannelKey)
    case channels
    case devices
    case settings

    var mainTab: MainTab {
        switch self {
        case .messagesAll, .messagesChannel:
            .messages
        case .channels:
            .channels
        case .devices:
            .devices
        case .settings:
            .settings
        }
    }
}
