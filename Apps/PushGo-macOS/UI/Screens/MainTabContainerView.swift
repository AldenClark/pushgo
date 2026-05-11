import SwiftUI

struct MainTabContainerView: View {
    @Environment(AppEnvironment.self) private var environment: AppEnvironment
    @Environment(LocalizationManager.self) private var localizationManager: LocalizationManager

    @State private var searchViewModel = MessageSearchViewModel()
    @State private var messageListViewModel = MessageListViewModel()
    @State private var entityViewModel = EntityProjectionViewModel()
    @State private var sidebarSelection: SidebarSelection? = .messagesAll

    @State private var selectedMessageId: UUID?
    @State private var selectedMessageSnapshot: PushMessage?
    @State private var selectedEventId: String?
    @State private var selectedThingId: String?

    @State private var didRefreshAuthorizationStatus: Bool = false
    @State private var dataRefreshTask: Task<Void, Never>?

    var body: some View {
        configuredRootView(splitViewContent)
    }

    private var splitViewContent: some View {
        NavigationSplitView {
            sidebarMenu
                .navigationSplitViewColumnWidth(min: 220, ideal: 220, max: 240)
        } detail: {
            detailContent
        }
    }

    @ViewBuilder
    private func configuredRootView<Content: View>(_ content: Content) -> some View {
        content
            .task {
                guard !didRefreshAuthorizationStatus else { return }
                didRefreshAuthorizationStatus = true
                await environment.pushRegistrationService.refreshAuthorizationStatus()
                await refreshDataForStoreChange()
                environment.updateActiveTab(activeTab)
                if environment.pendingEventToOpen != nil || environment.pendingThingToOpen != nil {
                    openPendingEntityIfNeeded()
                }
                ensureSidebarSelectionIsVisible()
            }
            .task {
                for await _ in NotificationCenter.default.notifications(named: .pushgoOpenSettingsFromMenuBar) {
                    sidebarSelection = .settings
                }
            }
#if DEBUG
            .task {
                for await notification in NotificationCenter.default.notifications(
                    named: .pushgoAutomationSelectTab
                ) {
                    guard let requestedTab = notification.object as? String else { continue }
                    switch requestedTab {
                    case "messages":
                        sidebarSelection = .messagesAll
                    case "events":
                        sidebarSelection = .events
                    case "things":
                        sidebarSelection = .things
                    case "channels":
                        sidebarSelection = .channels
                    case "settings":
                        sidebarSelection = .settings
                    default:
                        continue
                    }
                }
            }
            .task(id: automationStateVersion) {
                publishAutomationState()
            }
#endif
        .onChange(of: environment.pendingMessageToOpen) { _, id in
            if id != nil {
                sidebarSelection = .messagesAll
            }
        }
        .onChange(of: environment.pendingEventToOpen) { _, id in
            if id != nil {
                openPendingEntityIfNeeded()
            }
        }
        .onChange(of: environment.pendingThingToOpen) { _, id in
            if id != nil {
                openPendingEntityIfNeeded()
            }
        }
        .onChange(of: sidebarSelection) { oldValue, newValue in
            applySidebarSelection(previous: oldValue, current: newValue)
        }
        .onChange(of: environment.messageStoreRevision) { _, _ in
            scheduleDataRefreshForStoreChange()
        }
        .onChange(of: visibleNavigationSignature) { _, _ in
            ensureSidebarSelectionIsVisible()
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
    }

#if DEBUG
    private var automationStateVersion: String {
        [
            activeTab.automationIdentifier,
            selectedMessageId?.uuidString ?? "",
            environment.pendingMessageToOpen?.uuidString ?? "",
            environment.pendingEventToOpen ?? "",
            environment.pendingThingToOpen ?? "",
            "\(environment.totalMessageCount)",
        ].joined(separator: "|")
    }

    private func publishAutomationState() {
        guard activeTab.automationPublishesFromRoot else { return }
        PushGoAutomationRuntime.shared.publishState(
            environment: environment,
            activeTab: activeTab.automationIdentifier,
            visibleScreen: selectedMessageId == nil ? activeTab.automationVisibleScreen : "screen.message.detail",
            openedMessageId: selectedMessageSnapshot?.messageId ?? selectedMessageId?.uuidString
        )
    }
#endif

    private var activeTab: MainTab {
        sidebarSelection?.mainTab ?? .messages
    }

    @MainActor
    private func refreshDataForStoreChange() async {
        await messageListViewModel.refresh()
        searchViewModel.refreshMessagesIfNeeded()
        await entityViewModel.reload()
        ensureSidebarSelectionIsVisible()
    }

    private func scheduleDataRefreshForStoreChange() {
        dataRefreshTask?.cancel()
        dataRefreshTask = Task { @MainActor in
            await refreshDataForStoreChange()
        }
    }

    @ViewBuilder
    private var sidebarMenu: some View {
        VStack(spacing: 0) {
            List(selection: $sidebarSelection) {
                if showsMessagesEntry {
                    sidebarPrimaryRow(.messages)
                        .tag(SidebarSelection.messagesAll)
                }
                if showsEventsEntry {
                    sidebarPrimaryRow(.events)
                        .tag(SidebarSelection.events)
                }
                if showsThingsEntry {
                    sidebarPrimaryRow(.things)
                        .tag(SidebarSelection.things)
                }
                sidebarPrimaryRow(.channels)
                    .tag(SidebarSelection.channels)
                sidebarPrimaryRow(.settings)
                    .tag(SidebarSelection.settings)
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .tint(Color.appSelectionFill)
        }
    }

    private func sidebarPrimaryRow(_ tab: MainTab) -> some View {
        return HStack(spacing: SidebarLayout.rowSpacing) {
            Label(tab.localizedTitle(using: localizationManager), systemImage: tab.systemImageName)
                .font(.headline.weight(.semibold))
            Spacer(minLength: 8)
            if tab == .messages {
                SidebarUnreadBadge()
            }
        }
        .padding(.horizontal, SidebarLayout.rowHorizontalPadding)
        .padding(.vertical, SidebarLayout.primaryRowVerticalPadding)
        .accessibilityIdentifier("sidebar-\(tab.accessibilityIdentifier)")
        .listRowInsets(
            EdgeInsets(
                top: SidebarLayout.rowInsetVertical,
                leading: SidebarLayout.rowInsetHorizontal,
                bottom: SidebarLayout.rowInsetVertical,
                trailing: SidebarLayout.rowInsetHorizontal
            )
        )
        .listRowSeparator(.hidden)
    }

    private enum SidebarLayout {
        static let rowInsetHorizontal: CGFloat = 8
        static let rowInsetVertical: CGFloat = 2
        static let rowHorizontalPadding: CGFloat = 10
        static let primaryRowVerticalPadding: CGFloat = 7
        static let rowSpacing: CGFloat = 10
    }
    @ViewBuilder
    private var detailContent: some View {
        detailView(for: activeTab)
    }

    @ViewBuilder
    private func detailView(for tab: MainTab) -> some View {
        switch tab {
        case .messages:
            MessageSplitScreen(
                messageListViewModel: messageListViewModel,
                searchViewModel: searchViewModel,
                selection: $selectedMessageId,
                selectedMessageSnapshot: $selectedMessageSnapshot,
                openMessageId: environment.pendingMessageToOpen,
                onOpenMessageHandled: {
                    environment.pendingMessageToOpen = nil
                }
            )
        case .events:
            EventSplitScreen(
                viewModel: entityViewModel,
                selection: $selectedEventId,
                openEventId: environment.pendingEventToOpen,
                onOpenEventHandled: {
                    environment.pendingEventToOpen = nil
                }
            )
        case .things:
            ThingSplitScreen(
                viewModel: entityViewModel,
                selection: $selectedThingId,
                openThingId: environment.pendingThingToOpen,
                onOpenThingHandled: {
                    environment.pendingThingToOpen = nil
                }
            )
        case .channels:
            ChannelManagementView()
        case .settings:
            SettingsView()
        }
    }

    private func openPendingEntityIfNeeded() {
        if environment.pendingThingToOpen != nil {
            environment.pendingEventToOpen = nil
            sidebarSelection = .things
            return
        }
        if environment.pendingEventToOpen != nil {
            environment.pendingThingToOpen = nil
            sidebarSelection = .events
        }
    }

    private var messagesSidebarSelection: SidebarSelection {
        return .messagesAll
    }

    private func applySidebarSelection(previous _: SidebarSelection?, current: SidebarSelection?) {
        let nextTab = current?.mainTab ?? .messages
        environment.updateActiveTab(nextTab)
        guard nextTab == .messages else { return }
        switch current ?? .messagesAll {
        case .messagesAll:
            if !messageListViewModel.selectedChannels.isEmpty {
                messageListViewModel.clearChannelSelection()
            }
        case .events, .things, .channels, .settings:
            break
        case .messagesChannel:
            if !messageListViewModel.selectedChannels.isEmpty {
                messageListViewModel.clearChannelSelection()
            }
        }
    }

    private var showsMessagesEntry: Bool {
        environment.isMessagePageEnabled
    }

    private var showsEventsEntry: Bool {
        environment.isEventPageEnabled
    }

    private var showsThingsEntry: Bool {
        environment.isThingPageEnabled
    }

    private var visibleNavigationSignature: String {
        "\(showsMessagesEntry)|\(showsEventsEntry)|\(showsThingsEntry)"
    }

    private func ensureSidebarSelectionIsVisible() {
        let visibleTabs: Set<MainTab> = {
            var tabs: Set<MainTab> = [.channels, .settings]
            if showsMessagesEntry {
                tabs.insert(.messages)
            }
            if showsEventsEntry {
                tabs.insert(.events)
            }
            if showsThingsEntry {
                tabs.insert(.things)
            }
            return tabs
        }()

        if let current = sidebarSelection, visibleTabs.contains(current.mainTab) {
            if current.mainTab == .messages, !showsMessagesEntry {
                sidebarSelection = .channels
            }
            return
        }

        if showsMessagesEntry {
            sidebarSelection = messagesSidebarSelection
        } else if showsEventsEntry {
            sidebarSelection = .events
        } else if showsThingsEntry {
            sidebarSelection = .things
        } else {
            sidebarSelection = .channels
        }
    }
}

private struct SidebarUnreadBadge: View {
    @Environment(AppEnvironment.self) private var environment: AppEnvironment

    private var displayText: String? {
        let unreadCount = environment.unreadMessageCount
        guard unreadCount > 0 else { return nil }
        if unreadCount > 99 {
            return "99+"
        }
        return "\(unreadCount)"
    }

    var body: some View {
        if let displayText {
            Text(displayText)
                .font(.caption2.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(Color.appAccentPrimary)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .frame(minWidth: 22)
                .background(
                    Capsule(style: .continuous)
                        .fill(Color.appOverlayForeground)
                        .overlay(
                            Capsule(style: .continuous)
                                .stroke(Color.appBorderSubtle, lineWidth: 0.8)
                        )
                )
                .accessibilityLabel(LocalizedStringKey("unread"))
                .accessibilityValue(Text(displayText))
        }
    }
}

enum SidebarSelection: Hashable {
    case messagesAll
    case messagesChannel(MessageChannelKey)
    case events
    case things
    case channels
    case settings

    var mainTab: MainTab {
        switch self {
        case .messagesAll, .messagesChannel:
            .messages
        case .events:
            .events
        case .things:
            .things
        case .channels:
            .channels
        case .settings:
            .settings
        }
    }
}
