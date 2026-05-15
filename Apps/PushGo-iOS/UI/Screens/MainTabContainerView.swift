import SwiftUI
#if os(iOS)
import UIKit
#endif

struct MainTabContainerView: View {
    @Environment(AppEnvironment.self) private var environment: AppEnvironment
    @Environment(LocalizationManager.self) private var localizationManager: LocalizationManager

    @State private var messageListViewModel = MessageListViewModel()
    @State private var searchViewModel = MessageSearchViewModel()
    @State private var entityViewModel = EntityProjectionViewModel()
    @State private var selection: MainTab = .messages
    @State private var didRefreshAuthorizationStatus: Bool = false
    @State private var messageScrollToUnreadToken: Int = 0
    @State private var messageScrollToTopToken: Int = 0
    @State private var eventScrollToTopToken: Int = 0
    @State private var thingScrollToTopToken: Int = 0
    @State private var pendingMessageReselectTask: Task<Void, Never>?
    @State private var dataRefreshTask: Task<Void, Never>?

    var body: some View {
        tabLayout
            .pushgoTabBarMinimizeOnScroll()
            .background(
                TabBarSelectionObserver(visibleTabs: visibleTabs) { tappedTab, tapKind in
                    switch tapKind {
                    case .single:
                        handleTabBarTap(for: tappedTab)
                    case .double:
                        handleTabBarDoubleTap(for: tappedTab)
                    }
                }
            )
            .environment(searchViewModel)
            .task {
                guard !didRefreshAuthorizationStatus else { return }
                didRefreshAuthorizationStatus = true
                await environment.pushRegistrationService.refreshAuthorizationStatus()
                await refreshDataForStoreChange()
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
                // Message list/detail screens already publish precise selection state.
                // Skip root-level message publish to avoid list-state overwriting detail-state.
                guard selection != .messages else { return }
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
                scheduleDataRefreshForStoreChange()
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

    @MainActor
    private func refreshDataForStoreChange() async {
        await messageListViewModel.refresh()
        searchViewModel.refreshMessagesIfNeeded()
        await entityViewModel.reload()
        ensureSelectionIsVisible()
    }

    private func scheduleDataRefreshForStoreChange() {
        dataRefreshTask?.cancel()
        dataRefreshTask = Task { @MainActor in
            await refreshDataForStoreChange()
        }
    }

    @ViewBuilder
    private var tabLayout: some View {
        let unreadCount = environment.unreadMessageCount
        TabView(selection: $selection) {
            if showsMessagesTab {
                Tab(LocalizationManager.localizedSync("messages"), systemImage: "tray.full", value: MainTab.messages) {
                    MessageListScreen(
                        viewModel: messageListViewModel,
                        scrollToUnreadToken: messageScrollToUnreadToken,
                        scrollToTopToken: messageScrollToTopToken
                    )
                }
                .badge(unreadCount > 0 ? Text("\(unreadCount)") : nil)
            }

            if showsEventsTab {
                Tab(LocalizationManager.localizedSync("thing_detail_tab_events"), systemImage: "waveform.path.ecg", value: MainTab.events) {
                    navigationContainer {
                        EventListScreen(
                            viewModel: entityViewModel,
                            openEventId: environment.pendingEventToOpen,
                            scrollToTopToken: eventScrollToTopToken,
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
                            scrollToTopToken: thingScrollToTopToken,
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

    private var visibleTabs: [MainTab] {
        var tabs: [MainTab] = []
        if showsMessagesTab {
            tabs.append(.messages)
        }
        if showsEventsTab {
            tabs.append(.events)
        }
        if showsThingsTab {
            tabs.append(.things)
        }
        tabs.append(.channels)
        return tabs
    }

    private func ensureSelectionIsVisible() {
        if !visibleTabs.contains(selection) {
            selection = visibleTabs.first ?? .channels
        }
    }

    private func handleTabBarTap(for tappedTab: MainTab) {
        guard tappedTab == selection else { return }
        pendingMessageReselectTask?.cancel()

        switch tappedTab {
        case .messages:
            let currentToken = messageScrollToUnreadToken
            pendingMessageReselectTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(280))
                guard !Task.isCancelled, messageScrollToUnreadToken == currentToken else { return }
                messageScrollToUnreadToken += 1
            }
        case .events, .things, .channels:
            break
        }
    }

    private func handleTabBarDoubleTap(for tappedTab: MainTab) {
        guard tappedTab == selection else { return }
        pendingMessageReselectTask?.cancel()
        pendingMessageReselectTask = nil

        switch tappedTab {
        case .messages:
            messageScrollToTopToken += 1
        case .events:
            eventScrollToTopToken += 1
        case .things:
            thingScrollToTopToken += 1
        case .channels:
            break
        }
    }
}

#if os(iOS)
private struct TabBarSelectionObserver: UIViewControllerRepresentable {
    let visibleTabs: [MainTab]
    let onTap: (MainTab, TabBarTapKind) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(visibleTabs: visibleTabs, onTap: onTap)
    }

    func makeUIViewController(context: Context) -> ObserverController {
        let controller = ObserverController()
        controller.coordinator = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: ObserverController, context: Context) {
        context.coordinator.visibleTabs = visibleTabs
        context.coordinator.onTap = onTap
        uiViewController.coordinator = context.coordinator
        uiViewController.bindIfNeeded()
    }

    final class Coordinator: NSObject, UITabBarControllerDelegate {
        var visibleTabs: [MainTab]
        var onTap: (MainTab, TabBarTapKind) -> Void
        private weak var tabBarController: UITabBarController?
        private weak var previousDelegate: UITabBarControllerDelegate?
        private var lastTapTab: MainTab?
        private var lastTapAt: CFTimeInterval = 0
        private var selectedIndex: Int?

        init(visibleTabs: [MainTab], onTap: @escaping (MainTab, TabBarTapKind) -> Void) {
            self.visibleTabs = visibleTabs
            self.onTap = onTap
        }

        func bind(to tabBarController: UITabBarController) {
            guard self.tabBarController !== tabBarController else { return }
            previousDelegate = tabBarController.delegate
            self.tabBarController = tabBarController
            selectedIndex = tabBarController.selectedIndex
            tabBarController.delegate = self
        }

        func tabBarController(_ tabBarController: UITabBarController, didSelect viewController: UIViewController) {
            let index = tabBarController.viewControllers?.firstIndex(of: viewController) ?? tabBarController.selectedIndex
            guard visibleTabs.indices.contains(index) else {
                previousDelegate?.tabBarController?(tabBarController, didSelect: viewController)
                return
            }

            defer {
                selectedIndex = index
                previousDelegate?.tabBarController?(tabBarController, didSelect: viewController)
            }

            guard selectedIndex == index else {
                lastTapTab = nil
                lastTapAt = 0
                return
            }

            let tappedTab = visibleTabs[index]
            let now = CACurrentMediaTime()
            let isDoubleTap = lastTapTab == tappedTab && (now - lastTapAt) <= 0.30
            lastTapTab = isDoubleTap ? nil : tappedTab
            lastTapAt = now

            if isDoubleTap {
                onTap(tappedTab, .double)
            } else {
                onTap(tappedTab, .single)
            }
        }
    }

    final class ObserverController: UIViewController {
        weak var coordinator: Coordinator?

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            bindIfNeeded()
        }

        func bindIfNeeded() {
            guard let tabBarController, let coordinator else { return }
            coordinator.bind(to: tabBarController)
        }
    }
}

private enum TabBarTapKind {
    case single
    case double
}
#endif
