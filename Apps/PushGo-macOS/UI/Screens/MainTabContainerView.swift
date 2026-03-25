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
        let taskView = AnyView(
            content
                .task {
                    guard !didRefreshAuthorizationStatus else { return }
                    didRefreshAuthorizationStatus = true
                    await environment.pushRegistrationService.refreshAuthorizationStatus()
                    await entityViewModel.reload()
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
        )

        taskView
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
            Task {
                await entityViewModel.reload()
                ensureSidebarSelectionIsVisible()
            }
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
            "\(environment.unreadMessageCount)",
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

    @ViewBuilder
    private var sidebarMenu: some View {
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
        .safeAreaInset(edge: .bottom, spacing: 0) {
            sidebarFooter
        }
    }

    @ViewBuilder
    private var sidebarFooter: some View {
        if !environment.launchAtLoginEnabled {
            launchAtLoginReminder
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, 12)
        }
    }

    private var launchAtLoginReminder: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "power.dotted")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.orange)
                    .frame(width: 30, height: 30)
                    .background(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(Color.orange.opacity(0.14))
                    )
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 4) {
                    Text("sidebar_launch_at_login_reminder_title")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text("sidebar_launch_at_login_reminder_detail")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Button {
                environment.updateLaunchAtLogin(isEnabled: true)
            } label: {
                Text("sidebar_launch_at_login_reminder_action")
                    .font(.callout.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("sidebar-enable-launch-at-login")
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(nsColor: .controlBackgroundColor),
                            Color.orange.opacity(0.08),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.orange.opacity(0.18), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.06), radius: 8, x: 0, y: 4)
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

    private enum SidebarLayout {
        static let primaryRowVerticalPadding: CGFloat = 6
    }

    private func sidebarIcon(systemImageName: String) -> some View {
        let foreground = Color.secondary
        return Image(systemName: systemImageName)
            .font(.caption.weight(.semibold))
            .foregroundColor(foreground)
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
            if messageListViewModel.selectedChannel != nil {
                messageListViewModel.clearChannelSelection()
            }
        case .events, .things, .channels, .settings:
            break
        case .messagesChannel:
            if messageListViewModel.selectedChannel != nil {
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

enum MainTab: Hashable, CaseIterable {
    case messages
    case events
    case things
    case channels
    case settings

    var title: String {
        switch self {
        case .messages:
            "messages"
        case .events:
            "push_type_event"
        case .things:
            "push_type_thing"
        case .channels:
            "channels"
        case .settings:
            "settings"
        }
    }

    @MainActor
    func localizedTitle(using localizationManager: LocalizationManager) -> String {
        localizationManager.localized(title)
    }

    var systemImageName: String {
        switch self {
        case .messages:
            "tray.full"
        case .events:
            "waveform.path.ecg"
        case .things:
            "cpu"
        case .channels:
            "dot.radiowaves.left.and.right"
        case .settings:
            "gearshape"
        }
    }

    var accessibilityIdentifier: String {
        switch self {
        case .messages:
            "messages"
        case .events:
            "events"
        case .things:
            "things"
        case .channels:
            "channels"
        case .settings:
            "settings"
        }
    }

#if DEBUG
    var automationIdentifier: String {
        switch self {
        case .messages:
            return "messages"
        case .events:
            return "events"
        case .things:
            return "things"
        case .channels:
            return "channels"
        case .settings:
            return "settings"
        }
    }

    var automationVisibleScreen: String {
        switch self {
        case .messages:
            return "screen.messages.list"
        case .events:
            return "screen.events.list"
        case .things:
            return "screen.things.list"
        case .channels:
            return "screen.channels"
        case .settings:
            return "screen.settings"
        }
    }

    var automationPublishesFromRoot: Bool {
        switch self {
        case .events, .things, .settings:
            return false
        case .messages, .channels:
            return true
        }
    }
#endif
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
