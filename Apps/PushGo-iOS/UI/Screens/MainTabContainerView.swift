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
    @State private var unavailableEventTargetFeedback: String?
    @State private var unavailableThingTargetFeedback: String?
    @State private var dataRefreshTask: Task<Void, Never>?
    @State private var isDataRefreshRequested = false
    private let tabReselectLogger = Logger(subsystem: "io.ethan.pushgo", category: "TabReselection")

    var body: some View {
        tabLayout
            .overlay(alignment: .top) {
                if let feedback = environment.notificationOpenController.pendingMessageUnavailableFeedback {
                    AppInlineFeedbackBanner(
                        message: feedback,
                        tone: .danger,
                        accessibilityID: "feedback.message.target_unavailable",
                        dismissAction: {
                            environment.notificationOpenController.pendingMessageUnavailableFeedback = nil
                        }
                    )
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                }
            }
            .pushgoTabBarMinimizeOnScroll()
            .background(
                WindowTabReselectionObserver(visibleTabs: visibleTabs, selectedTab: selection) { tab, isDoubleTap in
                    handleObservedTabReselection(tab, isDoubleTap: isDoubleTap)
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
            // A Channels selection is the user-visible recovery boundary.  Do
            // the production sync/reconciliation here rather than in the
            // child screen's onAppear, which may run during TabView
            // preconstruction or be skipped when the child is reused.
            await environment.syncSubscriptionsOnChannelListEntry()
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
        TabView(selection: $selection) {
            if showsMessagesTab {
                MessageListScreen(
                    viewModel: messageListViewModel,
                    scrollToUnreadToken: messageScrollToUnreadToken,
                    scrollToTopToken: messageScrollToTopToken
                )
                .tabItem {
                    messagesTabItem(unreadCount: unreadCount)
                }
                .tag(MainTab.messages)
            }

            if showsEventsTab {
                navigationContainer {
                    EventListScreen(
                        viewModel: entityViewModel,
                        openEventId: environment.notificationOpenController.pendingEventToOpen,
                        scrollToTopToken: eventScrollToTopToken,
                        unavailableTargetFeedback: unavailableEventTargetFeedback,
                        onUnavailableTargetFeedbackChanged: { unavailableEventTargetFeedback = $0 },
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
                        unavailableTargetFeedback: unavailableThingTargetFeedback,
                        onUnavailableTargetFeedbackChanged: { unavailableThingTargetFeedback = $0 },
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

    /// The system TabView badge can cover the title and make the tab button
    /// unhittable when its capped value is `99+`. Keep the unread count in the
    /// same accessible tab element, but render the visual badge inside the
    /// icon so the title and the full-width target remain available.
    @ViewBuilder
    private func messagesTabItem(unreadCount: Int) -> some View {
        let title = LocalizationManager.localizedSync("messages")
        let badgeText = unreadCount > 99 ? "99+" : "\(unreadCount)"

        Label {
            Text(verbatim: title)
        } icon: {
            ZStack(alignment: .topTrailing) {
                Image(systemName: "tray.full")
                if unreadCount > 0 {
                    Text(verbatim: badgeText)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.red))
                        .fixedSize()
                        .offset(x: 10, y: -7)
                        .accessibilityHidden(true)
                }
            }
            .frame(width: 24, height: 24)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: title))
        .accessibilityValue(unreadCount > 0 ? Text(verbatim: badgeText) : Text(verbatim: ""))
        .accessibilityIdentifier("tab.messages")
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

    private func handleObservedTabReselection(_ tab: MainTab, isDoubleTap: Bool) {
        guard isInitialSelectionResolved, tab == selection else { return }
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
        tabReselectLogger.info("Observed single tab reselect for \(tappedTab.accessibilityIdentifier, privacy: .public)")
        switch tappedTab {
        case .messages:
            // UIKit has already ruled out a double tap before this callback.
            messageScrollToUnreadToken += 1
            tabReselectLogger.info("Committed Messages unread scroll token")
        case .events, .things, .channels:
            break
        }
    }

    private func handleTabBarDoubleTap(for tappedTab: MainTab) {
        guard tappedTab == selection else { return }
        tabReselectLogger.info("Observed double tab reselect for \(tappedTab.accessibilityIdentifier, privacy: .public)")

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
    let selectedTab: MainTab
    let onTap: (MainTab, Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(visibleTabs: visibleTabs, selectedTab: selectedTab, onTap: onTap)
    }

    func makeUIView(context: Context) -> ObserverView {
        let view = ObserverView()
        view.coordinator = context.coordinator
        return view
    }

    func updateUIView(_ uiView: ObserverView, context: Context) {
        context.coordinator.update(visibleTabs: visibleTabs, selectedTab: selectedTab)
        context.coordinator.onTap = onTap
        uiView.coordinator = context.coordinator
        uiView.bindIfNeeded()
    }

    static func dismantleUIView(_ uiView: ObserverView, coordinator: Coordinator) {
        coordinator.unbind()
        uiView.coordinator = nil
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        private var visibleTabs: [MainTab]
        private var selectedTab: MainTab
        var onTap: (MainTab, Bool) -> Void
        private weak var window: UIWindow?
        private weak var singleTapRecognizer: UITapGestureRecognizer?
        private weak var doubleTapRecognizer: UITapGestureRecognizer?

        init(visibleTabs: [MainTab], selectedTab: MainTab, onTap: @escaping (MainTab, Bool) -> Void) {
            self.visibleTabs = visibleTabs
            self.selectedTab = selectedTab
            self.onTap = onTap
        }

        func update(visibleTabs: [MainTab], selectedTab: MainTab) {
            guard self.visibleTabs != visibleTabs || self.selectedTab != selectedTab else { return }
            self.visibleTabs = visibleTabs
            self.selectedTab = selectedTab
            // A pending gesture belongs to the selection at touch-down.
            for recognizer in [singleTapRecognizer, doubleTapRecognizer] {
                recognizer?.isEnabled = false
                recognizer?.isEnabled = true
            }
        }

        func bind(to resolvedWindow: UIWindow) {
            guard window !== resolvedWindow else { return }
            unbind()
            let single = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
            let double = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
            double.numberOfTapsRequired = 2
            single.require(toFail: double)
            for recognizer in [single, double] {
                recognizer.cancelsTouchesInView = false
                recognizer.delaysTouchesBegan = false
                recognizer.delaysTouchesEnded = false
                recognizer.delegate = self
                resolvedWindow.addGestureRecognizer(recognizer)
            }
            window = resolvedWindow
            singleTapRecognizer = single
            doubleTapRecognizer = double
        }

        func unbind() {
            if let window {
                for recognizer in [singleTapRecognizer, doubleTapRecognizer] {
                    if let recognizer { window.removeGestureRecognizer(recognizer) }
                }
            }
            window = nil
            singleTapRecognizer = nil
            doubleTapRecognizer = nil
        }

        private func tab(at location: CGPoint, in window: UIWindow) -> MainTab? {
            guard window.rootViewController?.presentedViewController == nil, !visibleTabs.isEmpty else { return nil }
            let tabBarTop = window.bounds.maxY - window.safeAreaInsets.bottom - 56
            guard location.y >= tabBarTop else { return nil }
            let segmentWidth = window.bounds.width / CGFloat(visibleTabs.count)
            let index = min(visibleTabs.count - 1, max(0, Int(location.x / segmentWidth)))
            return visibleTabs[index]
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            guard let window else { return false }
            // Observe only reselection; normal controls and first tab selection
            // continue to be delivered directly to the system TabView.
            return tab(at: touch.location(in: window), in: window) == selectedTab
        }

        @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended, let window,
                  let tappedTab = tab(at: recognizer.location(in: window), in: window),
                  tappedTab == selectedTab
            else { return }
            onTap(tappedTab, recognizer.numberOfTapsRequired == 2)
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            !([singleTapRecognizer, doubleTapRecognizer].contains { $0 === otherGestureRecognizer })
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
