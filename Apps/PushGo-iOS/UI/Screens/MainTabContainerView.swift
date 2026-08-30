import SwiftUI
import OSLog
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
    @State private var isInitialSelectionResolved: Bool = false
    @State private var messageScrollToUnreadToken: Int = 0
    @State private var messageScrollToTopToken: Int = 0
    @State private var eventScrollToTopToken: Int = 0
    @State private var thingScrollToTopToken: Int = 0
    @State private var pendingMessageReselectTask: Task<Void, Never>?
    @State private var lastReselectedTab: MainTab?
    @State private var lastReselectAt: TimeInterval = 0
    @State private var dataRefreshTask: Task<Void, Never>?
    @State private var isDataRefreshRequested = false
    private let tabReselectLogger = Logger(subsystem: "io.ethan.pushgo", category: "TabReselection")
    private let tabDoubleTapWindow: TimeInterval = 0.32
    private let tabSingleTapCommitDelay = Duration.milliseconds(340)

    var body: some View {
        tabLayout
            .pushgoTabBarMinimizeOnScroll()
            .background(
                WindowTabReselectionObserver(visibleTabs: visibleTabs) { tab in
                    handleObservedTabReselection(tab)
                }
            )
            .environment(searchViewModel)
            .task {
                guard !didRefreshAuthorizationStatus else { return }
                didRefreshAuthorizationStatus = true
                if let pendingList = environment.pendingSystemListToOpen {
                    selection = pendingList
                    environment.pendingSystemListToOpen = nil
                } else if environment.notificationOpenController.pendingMessageToOpen != nil {
                    selection = .messages
                } else if environment.notificationOpenController.pendingThingToOpen != nil {
                    selection = .things
                } else if environment.notificationOpenController.pendingEventToOpen != nil {
                    selection = .events
                }
                ensureSelectionIsVisible()
                environment.updateActiveTab(selection)
                isInitialSelectionResolved = true
                Task {
                    await environment.pushRegistrationService.refreshAuthorizationStatus()
                }
            }
            .task(id: isInitialSelectionResolved ? selection : nil) {
                guard isInitialSelectionResolved else { return }
                let tab = selection
                await refreshData(for: tab)
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
            .onChange(of: environment.notificationOpenController.pendingMessageToOpen) { _, id in
                if id != nil {
                    selection = .messages
                }
            }
            .onChange(of: environment.notificationOpenController.pendingEventToOpen) { _, id in
                if id != nil && environment.notificationOpenController.pendingThingToOpen == nil {
                    selection = .events
                }
            }
            .onChange(of: environment.notificationOpenController.pendingThingToOpen) { _, id in
                if id != nil {
                    selection = .things
                }
            }
            .onChange(of: environment.pendingSystemListToOpen) { _, tab in
                guard let tab else { return }
                selection = tab
                environment.updateActiveTab(tab)
                environment.pendingSystemListToOpen = nil
                ensureSelectionIsVisible()
            }
            .onChange(of: selection) { _, newValue in
                pendingMessageReselectTask?.cancel()
                pendingMessageReselectTask = nil
                lastReselectedTab = nil
                lastReselectAt = 0
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
            environment.notificationOpenController.pendingMessageToOpen?.uuidString ?? "",
            environment.notificationOpenController.pendingEventToOpen ?? "",
            environment.notificationOpenController.pendingThingToOpen ?? "",
            "\(environment.unreadMessageCount)",
            "\(environment.totalMessageCount)",
        ].joined(separator: "|")
    }
#endif

    @MainActor
    private func refreshData(for tab: MainTab) async {
        switch tab {
        case .messages:
            await messageListViewModel.refresh()
            searchViewModel.refreshMessagesIfNeeded()
#if DEBUG
            environment.recordIngressPerformanceUIRefreshCompleted(
                totalMessageCount: messageListViewModel.totalMessageCount,
                visibleMessageCount: messageListViewModel.filteredMessages.count
            )
#endif
        case .events:
            await entityViewModel.reloadEvents()
        case .things:
            await entityViewModel.reloadThings()
        case .channels:
            await messageListViewModel.refreshChannelSummaries()
        }
        ensureSelectionIsVisible()
    }

    private func scheduleDataRefreshForStoreChange() {
        isDataRefreshRequested = true
        guard dataRefreshTask == nil else { return }
        dataRefreshTask = Task { @MainActor in
            repeat {
                isDataRefreshRequested = false
                await refreshData(for: selection)
            } while isDataRefreshRequested && !Task.isCancelled
            dataRefreshTask = nil
        }
    }

    @ViewBuilder
    private var tabLayout: some View {
        let unreadCount = environment.unreadMessageCount
        let unreadBadgeText = unreadCount > 99 ? "99+" : "\(unreadCount)"
        TabView(selection: $selection) {
            if showsMessagesTab {
                MessageListScreen(
                    viewModel: messageListViewModel,
                    scrollToUnreadToken: messageScrollToUnreadToken,
                    scrollToTopToken: messageScrollToTopToken
                )
                .tabItem {
                    Label(LocalizationManager.localizedSync("messages"), systemImage: "tray.full")
                        .accessibilityIdentifier("tab.messages")
                }
                .tag(MainTab.messages)
                .badge(unreadCount > 0 ? Text(verbatim: unreadBadgeText) : nil)
            }

            if showsEventsTab {
                navigationContainer {
                    EventListScreen(
                        viewModel: entityViewModel,
                        openEventId: environment.notificationOpenController.pendingEventToOpen,
                        scrollToTopToken: eventScrollToTopToken,
                        onOpenEventHandled: {
                            environment.pendingEventToOpen = nil
                        }
                    )
                }
                .tabItem {
                    Label(LocalizationManager.localizedSync("thing_detail_tab_events"), systemImage: "waveform.path.ecg")
                        .accessibilityIdentifier("tab.events")
                }
                .tag(MainTab.events)
            }

            if showsThingsTab {
                navigationContainer {
                    ThingListScreen(
                        viewModel: entityViewModel,
                        openThingId: environment.notificationOpenController.pendingThingToOpen,
                        scrollToTopToken: thingScrollToTopToken,
                        onOpenThingHandled: {
                            environment.pendingThingToOpen = nil
                        }
                    )
                }
                .tabItem {
                    Label(LocalizationManager.localizedSync("push_type_thing"), systemImage: "cpu")
                        .accessibilityIdentifier("tab.things")
                }
                .tag(MainTab.things)
            }

            ChannelManagementScreen(
                channelSummaries: messageListViewModel.channelSummaries,
                channelSummariesLoadState: messageListViewModel.channelSummariesLoadState
            )
                .tabItem {
                    Label(LocalizationManager.localizedSync("channels"), systemImage: "dot.radiowaves.left.and.right")
                        .accessibilityIdentifier("tab.channels")
                }
                .tag(MainTab.channels)
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

    private func handleObservedTabReselection(_ tab: MainTab) {
        guard isInitialSelectionResolved, tab == selection else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let isDoubleTap = lastReselectedTab == tab && now - lastReselectAt <= tabDoubleTapWindow
        lastReselectedTab = isDoubleTap ? nil : tab
        lastReselectAt = isDoubleTap ? 0 : now
        if isDoubleTap {
            handleTabBarDoubleTap(for: tab)
        } else {
            handleTabBarTap(for: tab)
        }
    }

    private func ensureSelectionIsVisible() {
        if !visibleTabs.contains(selection) {
            selection = visibleTabs.first ?? .channels
        }
    }

    private func handleTabBarTap(for tappedTab: MainTab) {
        guard tappedTab == selection else { return }
        tabReselectLogger.info("Observed single tab reselect for \(tappedTab.automationIdentifier, privacy: .public)")
        pendingMessageReselectTask?.cancel()

        switch tappedTab {
        case .messages:
            let currentToken = messageScrollToUnreadToken
            pendingMessageReselectTask = Task { @MainActor in
                // Commit only after the entire double-tap window has elapsed;
                // otherwise a late valid second tap can cause an unread→top bounce.
                try? await Task.sleep(for: tabSingleTapCommitDelay)
                guard !Task.isCancelled, messageScrollToUnreadToken == currentToken else { return }
                messageScrollToUnreadToken += 1
                pendingMessageReselectTask = nil
                lastReselectedTab = nil
                lastReselectAt = 0
                tabReselectLogger.info("Committed Messages unread scroll token")
            }
        case .events, .things, .channels:
            break
        }
    }

    private func handleTabBarDoubleTap(for tappedTab: MainTab) {
        guard tappedTab == selection else { return }
        tabReselectLogger.info("Observed double tab reselect for \(tappedTab.automationIdentifier, privacy: .public)")
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
private struct WindowTabReselectionObserver: UIViewRepresentable {
    let visibleTabs: [MainTab]
    let onTap: (MainTab) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(visibleTabs: visibleTabs, onTap: onTap)
    }

    func makeUIView(context: Context) -> ObserverView {
        let view = ObserverView()
        view.coordinator = context.coordinator
        return view
    }

    func updateUIView(_ uiView: ObserverView, context: Context) {
        context.coordinator.visibleTabs = visibleTabs
        context.coordinator.onTap = onTap
        uiView.coordinator = context.coordinator
        uiView.bindIfNeeded()
    }

    static func dismantleUIView(_ uiView: ObserverView, coordinator: Coordinator) {
        coordinator.unbind()
        uiView.coordinator = nil
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var visibleTabs: [MainTab]
        var onTap: (MainTab) -> Void
        private weak var window: UIWindow?
        private weak var tapRecognizer: UITapGestureRecognizer?

        init(visibleTabs: [MainTab], onTap: @escaping (MainTab) -> Void) {
            self.visibleTabs = visibleTabs
            self.onTap = onTap
        }

        func bind(to resolvedWindow: UIWindow) {
            guard window !== resolvedWindow else { return }
            if let window, let tapRecognizer {
                window.removeGestureRecognizer(tapRecognizer)
            }
            let recognizer = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
            recognizer.cancelsTouchesInView = false
            recognizer.delegate = self
            resolvedWindow.addGestureRecognizer(recognizer)
            window = resolvedWindow
            tapRecognizer = recognizer
        }

        func unbind() {
            if let window, let tapRecognizer {
                window.removeGestureRecognizer(tapRecognizer)
            }
            window = nil
            tapRecognizer = nil
        }

        @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended,
                  let window,
                  window.rootViewController?.presentedViewController == nil,
                  !visibleTabs.isEmpty
            else { return }
            let location = recognizer.location(in: window)
            let tabBarTop = window.bounds.maxY - window.safeAreaInsets.bottom - 56
            guard location.y >= tabBarTop else { return }
            let segmentWidth = window.bounds.width / CGFloat(visibleTabs.count)
            let index = min(visibleTabs.count - 1, max(0, Int(location.x / segmentWidth)))
            onTap(visibleTabs[index])
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            true
        }
    }

    final class ObserverView: UIView {
        weak var coordinator: Coordinator?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            bindIfNeeded()
        }

        func bindIfNeeded() {
            guard let coordinator, let window else { return }
            coordinator.bind(to: window)
        }
    }
}
#endif
