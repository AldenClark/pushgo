import SwiftUI

struct MainTabContainerView: View {
    @Environment(AppEnvironment.self) private var environment: AppEnvironment
    @Environment(LocalizationManager.self) private var localizationManager: LocalizationManager

    @State private var messageListViewModel = MessageListViewModel()
    @State private var searchViewModel = MessageSearchViewModel()
    @State private var entityViewModel = EntityProjectionViewModel()
    @State private var selection: MainTab = .messages
    @State private var didRefreshAuthorizationStatus: Bool = false

    var body: some View {
        tabLayout
            .pushgoTabBarMinimizeOnScroll()
            .environment(searchViewModel)
            .task {
                guard !didRefreshAuthorizationStatus else { return }
                didRefreshAuthorizationStatus = true
                await environment.pushRegistrationService.refreshAuthorizationStatus()
                await entityViewModel.reload()
                environment.updateActiveTab(selection)
                if environment.pendingMessageToOpen != nil {
                    selection = .messages
                } else if environment.pendingThingToOpen != nil {
                    selection = .things
                } else if environment.pendingEventToOpen != nil {
                    selection = .events
                }
                ensureSelectionIsVisible()
            }
#if DEBUG
            .task {
                for await notification in NotificationCenter.default.notifications(
                    named: .pushgoAutomationSelectTab
                ) {
                    guard let requestedTab = notification.object as? String,
                          let tab = MainTab(automationIdentifier: requestedTab)
                    else {
                        continue
                    }
                    selection = tab
                    ensureSelectionIsVisible()
                }
            }
            .task(id: automationStateVersion) {
                guard selection.automationPublishesFromRoot else { return }
                PushGoAutomationRuntime.shared.publishState(
                    environment: environment,
                    activeTab: selection.automationIdentifier,
                    visibleScreen: selection.automationVisibleScreen
                )
            }
#endif
            .onChange(of: environment.pendingMessageToOpen) { _, id in
                if id != nil {
                    selection = .messages
                }
            }
            .onChange(of: environment.pendingEventToOpen) { _, id in
                if id != nil && environment.pendingThingToOpen == nil {
                    selection = .events
                }
            }
            .onChange(of: environment.pendingThingToOpen) { _, id in
                if id != nil {
                    selection = .things
                }
            }
            .onChange(of: selection) { _, newValue in
                environment.updateActiveTab(newValue)
            }
            .onChange(of: environment.messageStoreRevision) { _, _ in
                Task { @MainActor in
                    await entityViewModel.reload()
                    ensureSelectionIsVisible()
                }
            }
            .onChange(of: visibleTabsSignature) { _, _ in
                ensureSelectionIsVisible()
            }
    }

#if DEBUG
    private var automationStateVersion: String {
        [
            selection.automationIdentifier,
            environment.pendingMessageToOpen?.uuidString ?? "",
            environment.pendingEventToOpen ?? "",
            environment.pendingThingToOpen ?? "",
            "\(environment.unreadMessageCount)",
            "\(environment.totalMessageCount)",
        ].joined(separator: "|")
    }
#endif

    @ViewBuilder
    private var tabLayout: some View {
        let unreadCount = messageListViewModel.unreadMessageCount
        TabView(selection: $selection) {
            if showsMessagesTab {
                Tab(LocalizationManager.localizedSync("messages"), systemImage: "tray.full", value: MainTab.messages) {
                    MessageListScreen(viewModel: messageListViewModel)
                }
                .badge(unreadCount > 0 ? Text("\(unreadCount)") : nil)
            }

            if showsEventsTab {
                Tab(LocalizationManager.localizedSync("push_type_event"), systemImage: "waveform.path.ecg", value: MainTab.events) {
                    navigationContainer {
                        EventListScreen(
                            viewModel: entityViewModel,
                            openEventId: environment.pendingEventToOpen,
                            onOpenEventHandled: {
                                environment.pendingEventToOpen = nil
                            }
                        )
                    }
                }
            }

            if showsThingsTab {
                Tab(LocalizationManager.localizedSync("push_type_thing"), systemImage: "cpu", value: MainTab.things) {
                    navigationContainer {
                        ThingListScreen(
                            viewModel: entityViewModel,
                            openThingId: environment.pendingThingToOpen,
                            onOpenThingHandled: {
                                environment.pendingThingToOpen = nil
                            }
                        )
                    }
                }
            }

            Tab(LocalizationManager.localizedSync("channels"), systemImage: "dot.radiowaves.left.and.right", value: MainTab.channels) {
                ChannelManagementScreen()
            }
        }
    }

    private var showsMessagesTab: Bool {
        environment.isMessagePageEnabled
    }

    private var showsEventsTab: Bool {
        environment.isEventPageEnabled
    }

    private var showsThingsTab: Bool {
        environment.isThingPageEnabled
    }

    private var visibleTabsSignature: String {
        "\(showsMessagesTab)|\(showsEventsTab)|\(showsThingsTab)"
    }

    private func ensureSelectionIsVisible() {
        var visibleTabs: [MainTab] = []
        if showsMessagesTab {
            visibleTabs.append(.messages)
        }
        if showsEventsTab {
            visibleTabs.append(.events)
        }
        if showsThingsTab {
            visibleTabs.append(.things)
        }
        visibleTabs.append(.channels)
        if !visibleTabs.contains(selection) {
            selection = visibleTabs.first ?? .channels
        }
    }
}

enum MainTab: Hashable, CaseIterable {
    case messages
    case events
    case things
    case channels

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
        }
    }

    @MainActor
    func localizedTitle(using localizationManager: LocalizationManager) -> String {
        localizationManager.localized(title)
    }

    var systemImageName: String {
        switch self {
        case .messages:
            return "tray.full"
        case .events:
            return "waveform.path.ecg"
        case .things:
            return "cpu"
        case .channels:
            return "dot.radiowaves.left.and.right"
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
        }
    }

#if DEBUG
    init?(automationIdentifier: String) {
        switch automationIdentifier {
        case "messages":
            self = .messages
        case "events":
            self = .events
        case "things":
            self = .things
        case "channels":
            self = .channels
        default:
            return nil
        }
    }

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
        }
    }

    var automationPublishesFromRoot: Bool {
        switch self {
        case .channels:
            return true
        case .messages, .events, .things:
            return false
        }
    }
#endif
}
