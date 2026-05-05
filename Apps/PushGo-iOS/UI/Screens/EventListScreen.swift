import SwiftUI

struct EventListScreen: View {
    private enum OverlayState {
        case onboarding
        case searchPlaceholder
    }

    @Environment(AppEnvironment.self) private var environment: AppEnvironment
    @Environment(LocalizationManager.self) private var localizationManager: LocalizationManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let viewModel: EntityProjectionViewModel
    var openEventId: String? = nil
    var scrollToTopToken: Int = 0
    var onOpenEventHandled: (() -> Void)? = nil
    @State private var selectedEvent: EventProjection?
    @State private var selectedEventIds: Set<String> = []
    @State private var showBatchDeleteConfirmation = false
    @State private var searchQuery: String = ""
    @State private var selectedChannelId: String?
    @State private var isBatchModeActive = false

    var body: some View {
        let filteredEventsSnapshot = filteredEvents
        let baseContent = listContainer(filteredEvents: filteredEventsSnapshot)
        let content = applySearchIfNeeded(baseContent)
        .accessibilityIdentifier("screen.events.list")
        .refreshable {
            await handlePullToRefresh()
        }
        .task(id: searchAutoloadTrigger(filteredEventsCount: filteredEventsSnapshot.count)) {
            await autoloadSearchResultsIfNeeded(filteredEventsCount: filteredEventsSnapshot.count)
        }
        .navigationTitle(localizationManager.localized("thing_detail_tab_events"))
        .navigationBarTitleDisplayMode(.large)
        .toolbar { toolbarContent }
        .toolbar(isBatchMode ? .hidden : .visible, for: .tabBar)
        .alert(
            localizationManager.localized("delete"),
            isPresented: $showBatchDeleteConfirmation,
        ) {
            Button(localizationManager.localized("delete"), role: .destructive) {
                Task { await deleteSelectedEvents() }
            }
            Button(localizationManager.localized("cancel"), role: .cancel) {}
        } message: {
            Text(localizationManager.localized("batch_delete_selected_events_confirm", selectedEventIds.count))
        }
        .onAppear {
            environment.updateEventListPosition(isAtTop: true)
            openEventIfNeeded()
#if DEBUG
            publishAutomationState()
#endif
        }
        .onChange(of: viewModel.events) { _, _ in
            syncSelectedEventSnapshot()
            openEventIfNeeded()
#if DEBUG
            publishAutomationState()
#endif
        }
        .onChange(of: openEventId) { _, _ in
            openEventIfNeeded()
#if DEBUG
            publishAutomationState()
#endif
        }
        .onChange(of: selectedEvent?.id) { _, _ in
#if DEBUG
            publishAutomationState()
#endif
        }
        .onChange(of: isBatchMode) { _, active in
            if active {
                selectedEvent = nil
            } else {
                selectedEventIds.removeAll()
                openEventIfNeeded()
            }
        }
        .sheet(item: $selectedEvent) { event in
            EventDetailScreen(
                event: event,
                onDelete: {
                    Task { await deleteEvent(eventId: event.id) }
                },
                onCloseEvent: {
                    Task { await closeEvent(event: event) }
                }
            )
            .accessibilityIdentifier("sheet.event.detail")
        }
        content
    }

    @ViewBuilder
    private func listContainer(filteredEvents: [EventProjection]) -> some View {
        let overlayState = overlayState(for: filteredEvents)
        ZStack {
            eventList(filteredEvents: filteredEvents)
                .opacity(overlayState == nil ? 1 : 0.001)
                .allowsHitTesting(overlayState == nil)
                .accessibilityHidden(overlayState != nil)

            switch overlayState {
            case .onboarding:
                EntityOnboardingEmptyView(kind: .events)
            case .searchPlaceholder:
                MessageSearchPlaceholderView(
                    imageName: "questionmark.circle",
                    title: "no_matching_results",
                    detailKey: "try_changing_a_keyword_or_clear_the_filter_conditions"
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 24)
            case nil:
                EmptyView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func eventList(filteredEvents: [EventProjection]) -> some View {
        ScrollViewReader { proxy in
            List(selection: batchSelectionBinding) {
                ForEach(filteredEvents.indices, id: \.self) { index in
                    let event = filteredEvents[index]
                    Group {
                        if isBatchMode {
                            EventListRow(event: event)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            Button {
                                selectEvent(event)
                            } label: {
                                EventListRow(event: event)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .id(event.id)
                    .accessibilityIdentifier("event.row.\(event.id)")
                    .tag(event.id)
                    .listRowInsets(EdgeInsets(
                        top: EntityVisualTokens.listRowInsetVertical,
                        leading: EntityVisualTokens.listRowInsetHorizontal,
                        bottom: EntityVisualTokens.listRowInsetVertical,
                        trailing: EntityVisualTokens.listRowInsetHorizontal
                    ))
                    .listRowBackground(
                        EntitySelectionBackground(isSelected: isBatchMode ? selectedEventIds.contains(event.id) : selectedEvent?.id == event.id)
                    )
                    .listRowSeparator(index == 0 ? .hidden : .visible, edges: .top)
                    .listRowSeparator(index == filteredEvents.count - 1 ? .hidden : .visible, edges: .bottom)
                    .onAppear {
                        guard index == filteredEvents.count - 1 else { return }
                        Task { await viewModel.loadMoreEvents() }
                    }
                }
                if viewModel.isLoadingMoreEvents {
                    HStack {
                        Spacer()
                        ProgressView()
                            .controlSize(.small)
                        Spacer()
                    }
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                }
            }
            .listStyle(.plain)
            .modifier(
                EventListTopObserverModifier(enabled: true) { topOffset in
                    updateEventListTopState(
                        topOffset: topOffset,
                        filteredEventsCount: filteredEvents.count
                    )
                }
            )
            .environment(\.editMode, isBatchMode ? .constant(.active) : .constant(.inactive))
            .scrollContentBackground(.hidden)
            .background(EntityVisualTokens.pageBackground)
            .onChange(of: scrollToTopToken) { _, _ in
                scrollToTopIfNeeded(proxy, filteredEvents: filteredEvents)
            }
        }
    }

    private func overlayState(for filteredEvents: [EventProjection]) -> OverlayState? {
        if viewModel.events.isEmpty {
            .onboarding
        } else if filteredEvents.isEmpty {
            .searchPlaceholder
        } else {
            nil
        }
    }

#if DEBUG
    private func publishAutomationState() {
        PushGoAutomationRuntime.shared.publishState(
            environment: environment,
            activeTab: "events",
            visibleScreen: selectedEvent == nil ? "screen.events.list" : "screen.events.detail",
            openedEntityType: selectedEvent == nil ? nil : "event",
            openedEntityId: selectedEvent?.id
        )
    }
#endif

    @ViewBuilder
    private func applySearchIfNeeded<Content: View>(_ content: Content) -> some View {
        if viewModel.events.isEmpty || isBatchMode {
            content
        } else {
            content.searchable(
                text: $searchQuery,
                placement: .navigationBarDrawer(displayMode: .automatic),
                prompt: Text(localizationManager.localized("search_events"))
            )
        }
    }

    private var availableChannelIds: [String] {
        Array(
            Set(viewModel.events.compactMap { normalizedChannel($0.channelId) })
        ).sorted()
    }

    private var filteredEvents: [EventProjection] {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let matched = viewModel.events.filter { event in
            let channelMatched = selectedChannelId == nil || normalizedChannel(event.channelId) == selectedChannelId
            guard channelMatched else { return false }
            guard !query.isEmpty else { return true }
            return searchableText(for: event).contains(query)
        }
        return matched.sorted { lhs, rhs in
            let lhsRank = stateSortPriority(eventLifecycleState(from: lhs.state))
            let rhsRank = stateSortPriority(eventLifecycleState(from: rhs.state))
            if lhsRank != rhsRank {
                return lhsRank < rhsRank
            }
            return lhs.updatedAt > rhs.updatedAt
        }
    }

    private func searchAutoloadTrigger(filteredEventsCount: Int) -> String {
        "\(normalizedSearchQuery)|\(selectedChannelId ?? "_")|\(viewModel.events.count)|\(filteredEventsCount)|\(viewModel.hasMoreEvents)|\(viewModel.isLoadingMoreEvents)"
    }

    private var normalizedSearchQuery: String {
        searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func shouldAutoloadSearchResults(filteredEventsCount: Int) -> Bool {
        let hasActiveFilter = !normalizedSearchQuery.isEmpty || selectedChannelId != nil
        return hasActiveFilter
            && filteredEventsCount == 0
            && viewModel.hasMoreEvents
            && !viewModel.isLoadingMoreEvents
    }

    private func autoloadSearchResultsIfNeeded(filteredEventsCount: Int) async {
        guard shouldAutoloadSearchResults(filteredEventsCount: filteredEventsCount) else { return }
        await viewModel.loadMoreEvents()
    }

    private func updateEventListTopState(topOffset: CGFloat, filteredEventsCount: Int) {
        let isAtTop = filteredEventsCount == 0 || topOffset <= EventListTopMetrics.topTolerance
        environment.updateEventListPosition(isAtTop: isAtTop)
    }

    private func searchableText(for event: EventProjection) -> String {
        [
            event.title,
            event.summary ?? "",
            event.severity ?? "",
            event.tags.joined(separator: " "),
            event.id,
            eventLifecycleState(from: event.state).rawValue,
            event.thingId ?? "",
            event.channelId ?? "",
        ]
        .joined(separator: " ")
        .lowercased()
    }

    private func stateSortPriority(_ state: EventLifecycleState) -> Int {
        switch state {
        case .ongoing:
            return 0
        case .closed:
            return 1
        case .unknown:
            return 2
        }
    }

    private func handlePullToRefresh() async {
        _ = await environment.syncProviderIngress(reason: "events_pull_to_refresh")
        await viewModel.reload()
        syncSelectedEventSnapshot()
        openEventIfNeeded()
    }

    private func scrollToTopIfNeeded(_ proxy: ScrollViewProxy, filteredEvents: [EventProjection]) {
        guard let firstId = filteredEvents.first?.id else { return }
        if reduceMotion {
            proxy.scrollTo(firstId, anchor: .top)
        } else {
            withAnimation(.easeInOut(duration: 0.2)) {
                proxy.scrollTo(firstId, anchor: .top)
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button {
                isBatchModeActive.toggle()
            } label: {
                Image(systemName: isBatchMode ? "checkmark" : "checklist.unchecked")
            }
            .accessibilityLabel(isBatchMode ? localizationManager.localized("done") : localizationManager.localized("edit"))
        }
        ToolbarItemGroup(placement: .primaryAction) {
            if !isBatchMode {
                Menu {
                    channelFilterMenuContent
                } label: {
                    Image(systemName: selectedChannelId == nil ? "line.3.horizontal.decrease" : "line.3.horizontal.decrease.circle.fill")
                }
                .accessibilityLabel(localizationManager.localized("channel"))
            }
        }
        if isBatchMode {
            ToolbarItemGroup(placement: .bottomBar) {
                Spacer()
                Button(role: .destructive) {
                    showBatchDeleteConfirmation = true
                } label: {
                    Image(systemName: "trash")
                }
                .accessibilityLabel(localizationManager.localized("delete"))
                .disabled(selectedEventIds.isEmpty)
            }
        }
    }

    private var isBatchMode: Bool {
        isBatchModeActive
    }

    private var batchSelectionBinding: Binding<Set<String>> {
        if isBatchMode {
            return $selectedEventIds
        }
        return .constant([])
    }

    private func normalizedChannel(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private func openEventIfNeeded() {
        guard !isBatchMode else { return }
        let target = openEventId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !target.isEmpty else { return }
        if let matched = viewModel.events.first(where: { $0.id == target }) {
            if let channelId = normalizedChannel(matched.channelId) {
                selectedChannelId = channelId
            }
            if !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                searchQuery = ""
            }
            selectEvent(matched)
            onOpenEventHandled?()
            return
        }

        Task { @MainActor in
            await viewModel.ensureEventDetailsLoaded(eventId: target)
            guard let hydrated = viewModel.events.first(where: { $0.id == target }) else { return }
            if let channelId = normalizedChannel(hydrated.channelId) {
                selectedChannelId = channelId
            }
            if !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                searchQuery = ""
            }
            selectEvent(hydrated)
            onOpenEventHandled?()
        }
    }

    private func selectEvent(_ event: EventProjection) {
        guard !isBatchMode else { return }
        selectedEvent = event
        Task { @MainActor in
            await viewModel.ensureEventDetailsLoaded(eventId: event.id)
            syncSelectedEventSnapshot()
        }
    }

    private func syncSelectedEventSnapshot() {
        guard let selectedId = selectedEvent?.id else { return }
        if let refreshed = viewModel.events.first(where: { $0.id == selectedId }) {
            selectedEvent = refreshed
        }
    }

    private func deleteEvent(eventId: String) async {
        do {
            try await viewModel.deleteEvent(eventId: eventId)
            selectedEvent = nil
        } catch {
            environment.showToast(
                message: "\(localizationManager.localized("operation_failed")): \(error.localizedDescription)",
                style: .error,
                duration: 2
            )
        }
    }

    private func closeEvent(event: EventProjection) async {
        do {
            try await viewModel.closeEvent(event: event)
            selectedEvent = nil
        } catch {
            environment.showToast(
                message: "\(localizationManager.localized("operation_failed")): \(error.localizedDescription)",
                style: .error,
                duration: 2
            )
        }
    }

    private func deleteSelectedEvents() async {
        let ids = Array(selectedEventIds)
        guard !ids.isEmpty else { return }
        do {
            _ = try await viewModel.deleteEvents(eventIds: ids)
            selectedEventIds.removeAll()
            isBatchModeActive = false
        } catch {
            environment.showToast(
                message: "\(localizationManager.localized("operation_failed")): \(error.localizedDescription)",
                style: .error,
                duration: 2
            )
        }
    }

    @ViewBuilder
    private var channelFilterMenuContent: some View {
        Button {
            selectedChannelId = nil
        } label: {
            channelFilterMenuItemLabel(
                title: localizationManager.localized("all_groups"),
                isSelected: selectedChannelId == nil
            )
        }

        ForEach(availableChannelIds, id: \.self) { channelId in
            Button {
                selectedChannelId = channelId
            } label: {
                channelFilterMenuItemLabel(
                    title: environment.channelDisplayName(for: channelId) ?? channelId,
                    isSelected: selectedChannelId == channelId
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
}

private struct EventListTopObserverModifier: ViewModifier {
    let enabled: Bool
    let onChange: (CGFloat) -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled {
            content.onScrollGeometryChange(
                for: CGFloat.self,
                of: { geometry in
                    geometry.contentOffset.y
                },
                action: { _, newValue in
                    onChange(newValue)
                }
            )
        } else {
            content
        }
    }
}

private enum EventListTopMetrics {
    static let topTolerance: CGFloat = 2
}

struct EventListRow: View {
    @Environment(AppEnvironment.self) private var environment: AppEnvironment
    @Environment(LocalizationManager.self) private var localizationManager: LocalizationManager

    let event: EventProjection

    private var severity: EventSeverity? {
        normalizedEventSeverity(event.severity)
    }

    private var lifecycleState: EventLifecycleState {
        eventLifecycleState(from: event.state)
    }

    private var isClosed: Bool {
        lifecycleState == .closed
    }

    private var statusLabel: String {
        normalizedEventStatus(event.status) ?? localizedDefaultCreatedEventStatus()
    }

    private var statusTone: AppSemanticTone {
        eventSeverityTone(severity) ?? eventStateTone(event.state)
    }

    private var previewImageAttachments: [URL] {
        Array(imageAttachments.prefix(3))
    }

    private var imageAttachments: [URL] {
        event.imageURLs.filter(isLikelyImageAttachmentURL)
    }

    private var remainingImageAttachmentCount: Int {
        max(0, imageAttachments.count - previewImageAttachments.count)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: EntityVisualTokens.stackSpacing) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(event.title)
                    .font(.headline.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(isClosed ? .secondary : .primary)
                    .layoutPriority(0)

                EntityStateBadge(text: statusLabel, tone: statusTone)
                    .fixedSize(horizontal: true, vertical: true)
                    .layoutPriority(2)

                Spacer(minLength: 8)
                Text(EntityDateFormatter.relativeText(event.updatedAt))
                    .font(.caption)
                    .foregroundStyle(Color.appTextSecondary)
                    .lineLimit(1)
                    .layoutPriority(-1)
            }

            if let summary = event.summary, !summary.isEmpty {
                Text(summary)
                    .font(.subheadline)
                    .foregroundStyle(isClosed ? .tertiary : .secondary)
                    .lineLimit(3)
            }

            if let statusMessage = event.message, !statusMessage.isEmpty {
                EntityInlineAlert(
                    text: statusMessage,
                    systemImage: eventSeveritySymbol(severity) ?? "info.circle.fill",
                    tone: isClosed ? .neutral : (eventSeverityTone(severity) ?? .warning)
                )
            }

            HStack(spacing: 8) {
                if let thingId = event.thingId, !thingId.isEmpty {
                    Label(String(thingId.prefix(20)), systemImage: "cube")
                        .font(.caption2)
                        .foregroundStyle(Color.appTextSecondary)
                }
                if let channelId = event.channelId?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !channelId.isEmpty
                {
                    EntityMetaChip(
                        systemImage: "bubble.left.and.bubble.right",
                        text: environment.channelDisplayName(for: channelId) ?? channelId
                    )
                }
                if let descriptor = entityDecryptionBadgeDescriptor(
                    state: event.decryptionState,
                    localizationManager: localizationManager
                ) {
                    EntityMetaChip(
                        systemImage: descriptor.icon,
                        text: descriptor.text,
                        color: descriptor.tone.foreground
                    )
                }
            }

            if !previewImageAttachments.isEmpty {
                HStack(spacing: 6) {
                    ForEach(previewImageAttachments, id: \.absoluteString) { url in
                        RemoteImageView(url: url, rendition: .listThumbnail) { image in
                            image
                                .resizable()
                                .scaledToFill()
                        } placeholder: {
                            Rectangle()
                                .fill(EntityVisualTokens.secondarySurface)
                        }
                        .frame(width: 48, height: 48)
                        .clipShape(RoundedRectangle(cornerRadius: EntityVisualTokens.radiusSmall, style: .continuous))
                    }
                    if remainingImageAttachmentCount > 0 {
                        Text("+\(remainingImageAttachmentCount)")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.appTextSecondary)
                            .padding(.leading, 4)
                    }
                }
                .padding(.top, 2)
            }
        }
        .padding(.vertical, EntityVisualTokens.rowVerticalPadding)
    }
}
