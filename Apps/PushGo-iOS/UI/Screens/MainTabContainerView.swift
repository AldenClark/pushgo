import SwiftUI

struct MainTabContainerView: View {
    @Environment(\.appEnvironment) private var environment: AppEnvironment
    @Environment(LocalizationManager.self) private var localizationManager: LocalizationManager

    @State private var messageListViewModel = MessageListViewModel()
    @State private var searchViewModel = MessageSearchViewModel()
    @State private var selection: MainTab = .messages
    @State private var didRefreshAuthorizationStatus: Bool = false

    var body: some View {
        tabLayout
            .environment(searchViewModel)
            .task {
                guard !didRefreshAuthorizationStatus else { return }
                didRefreshAuthorizationStatus = true
                await environment.pushRegistrationService.refreshAuthorizationStatus()
                environment.updateActiveTab(selection)
                if environment.pendingMessageToOpen != nil {
                    selection = .messages
                }
            }
            .onChange(of: environment.pendingMessageToOpen) { _, id in
                if id != nil {
                    selection = .messages
                }
            }
            .onChange(of: selection) { _, newValue in
                environment.updateActiveTab(newValue)
            }
    }

    @ViewBuilder
    private var tabLayout: some View {
        if #available(iOS 18, *) {
            TabView(selection: $selection) {
                let unreadCount = messageListViewModel.unreadMessageCount
                Tab(LocalizationManager.localizedSync("messages"), systemImage: "tray.full", value: MainTab.messages) {
                    MessageListScreen(viewModel: messageListViewModel)
                }
                .badge(unreadCount > 0 ? Text("\(unreadCount)") : nil)

                Tab(LocalizationManager.localizedSync("push"), systemImage: "link", value: MainTab.devices) {
                    PushScreen()
                }

                Tab(LocalizationManager.localizedSync("settings"), systemImage: "gearshape", value: MainTab.settings) {
                    SettingsView()
                }

                if #available(iOS 26, *) {
                    Tab(
                        LocalizationManager.localizedSync("search"),
                        systemImage: "magnifyingglass",
                        value: MainTab.search,
                        role: .search,
                    ) {
                        MessageSearchScreen()
                    }
                }
            }
        } else {
            legacyTabLayout
        }
    }

    @ViewBuilder
    private var legacyTabLayout: some View {
        let unreadCount = messageListViewModel.unreadMessageCount
        TabView(selection: $selection) {
            MessageListScreen(viewModel: messageListViewModel)
                .tabItem { Label(localizationManager.localized("messages"), systemImage: "tray.full") }
                .tag(MainTab.messages)
                .applyBadgeIfNeeded(unreadCount)

            PushScreen()
                .tabItem { Label(localizationManager.localized("push"), systemImage: "link") }
                .tag(MainTab.devices)

            SettingsView()
                .tabItem { Label(localizationManager.localized("settings"), systemImage: "gearshape") }
                .tag(MainTab.settings)
        }
    }
}

private extension View {
    @ViewBuilder
    func applyBadgeIfNeeded(_ count: Int) -> some View {
        if count > 0 {
            self.badge(count)
        } else {
            self
        }
    }
}

enum MainTab: Hashable, CaseIterable {
    case messages
    case devices
    case settings
    case search

    var title: String {
        switch self {
        case .messages:
            "messages"
        case .devices:
            "push"
        case .settings:
            "settings"
        case .search:
            "search"
        }
    }

    func localizedTitle(using localizationManager: LocalizationManager) -> String {
        localizationManager.localized(title)
    }

    var systemImageName: String {
        switch self {
        case .messages:
            "tray.full"
        case .devices:
            "link"
        case .settings:
            "gearshape"
        case .search:
            "magnifyingglass"
        }
    }

    var accessibilityIdentifier: String {
        switch self {
        case .messages:
            "messages"
        case .devices:
            "devices"
        case .settings:
            "settings"
        case .search:
            "search"
        }
    }
}
