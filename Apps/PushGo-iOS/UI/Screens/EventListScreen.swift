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
    @State private var searchQuery: String = ""
    @State private var selectedChannelIDs: Set<String> = []
    @State private var selectedTags: Set<String> = []
    @State private var isFilterPopoverPresented = false
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
        .onChange(of: environment.pendingLocalDeletionController.pendingDeletion) { _, _ in
            if let selectedEvent, isPendingLocalDeletion(selectedEvent) {
                self.selectedEvent = nil
            }
            let visibleIDs = Set(filteredEvents.map(\.id))
            selectedEventIds = selectedEventIds.intersection(visibleIDs)
        }
        .sheet(item: $selectedEvent) { event in
            EventDetailScreen(
                event: event,
                onCommitDelete: {
                    try await viewModel.deleteEvent(eventId: event.id)
                },
                onPrepareDelete: {
                    selectedEvent = nil
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

    private var allChannelIds: [String] {
        let ids = viewModel.events.compactMap { event -> String? in
            guard !isPendingLocalDeletion(event) else { return nil }
            return normalizedChannel(event.channelId)
        }
        return Array(Set(ids)).sorted()
    }

    private var allTags: [String] {
        var tags = Set<String>()
        for event in viewModel.events {
            guard !isPendingLocalDeletion(event) else { continue }
            for tag in event.tags {
                let normalized = normalizedTag(tag)
                if !normalized.isEmpty {
                    tags.insert(normalized)
                }
            }
        }
        return tags.sorted()
    }

    private var filteredEvents: [EventProjection] {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let matched = viewModel.events.filter { event in
            guard !isPendingLocalDeletion(event) else { return false }
            let channelMatched = selectedChannelIDs.isEmpty || selectedChannelIDs.contains(normalizedChannel(event.channelId) ?? "")
            guard channelMatched else { return false }
            if !selectedTags.isEmpty {
                let normalizedEventTags = Set(event.tags.map(normalizedTag))
                guard selectedTags.contains(where: normalizedEventTags.contains) else { return false }
            }
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
        let channelsSignature = selectedChannelIDs.sorted().joined(separator: ",")
        let tagsSignature = selectedTags.sorted().joined(separator: ",")
        return "\(normalizedSearchQuery)|\(channelsSignature)|\(tagsSignature)|\(viewModel.events.count)|\(filteredEventsCount)|\(viewModel.hasMoreEvents)|\(viewModel.isLoadingMoreEvents)"
    }

    private var normalizedSearchQuery: String {
        searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func shouldAutoloadSearchResults(filteredEventsCount: Int) -> Bool {
        let hasActiveFilter = !normalizedSearchQuery.isEmpty || !selectedChannelIDs.isEmpty || !selectedTags.isEmpty
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
        if isBatchMode {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    toggleSelectAllEvents()
                } label: {
                    Image(systemName: areAllVisibleEventsSelected ? "checkmark.rectangle.stack.fill" : "checkmark.rectangle.stack")
                }
                .accessibilityLabel(localizationManager.localized("all"))
            }
        }
        ToolbarItemGroup(placement: .primaryAction) {
            if isBatchMode {
                Button {
                    Task { await exitBatchModeAfterFlushingPendingDeletion() }
                } label: {
                    batchDoneToolbarIcon()
                }
                .accessibilityLabel(localizationManager.localized("done"))
            } else {
                Button {
                    isFilterPopoverPresented = true
                } label: {
                    filterToolbarIcon(isHighlighted: isFilterMenuHighlighted)
                }
                .accessibilityLabel(localizationManager.localized("channel"))
                .popover(isPresented: $isFilterPopoverPresented, arrowEdge: .top) {
                    if #available(iOS 16.4, *) {
                        filterPopoverContent
                            .presentationCompactAdaptation(.popover)
                    } else {
                        filterPopoverContent
                    }
                }
            }
        }
        if isBatchMode {
            ToolbarItemGroup(placement: .bottomBar) {
                Spacer()
                Button(role: .destructive) {
                    Task { await scheduleDeletion(for: selectedBatchEvents) }
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

    private func normalizedTag(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func openEventIfNeeded() {
        guard !isBatchMode else { return }
        let target = openEventId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !target.isEmpty else { return }
        if let matched = viewModel.events.first(where: { $0.id == target }) {
            if let channelId = normalizedChannel(matched.channelId) {
                selectedChannelIDs = [channelId]
            }
            if !selectedTags.isEmpty {
                selectedTags.removeAll()
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
                selectedChannelIDs = [channelId]
            }
            if !selectedTags.isEmpty {
                selectedTags.removeAll()
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

    private func closeEvent(event: EventProjection) async {
        do {
            try await viewModel.closeEvent(event: event)
            selectedEvent = nil
        } catch {
            environment.showErrorToast(
                error,
                fallbackMessage: localizationManager.localized("operation_failed"),
                duration: 2
            )
        }
    }

    @MainActor
    private func exitBatchModeAfterFlushingPendingDeletion() async {
        await environment.pendingLocalDeletionController.commitCurrentIfNeeded()
        isBatchModeActive = false
    }

    private var selectedBatchEvents: [EventProjection] {
        let selectedIds = selectedEventIds
        guard !selectedIds.isEmpty else { return [] }
        return filteredEvents.filter { selectedIds.contains($0.id) }
    }

    private func isPendingLocalDeletion(_ event: EventProjection) -> Bool {
        environment.pendingLocalDeletionController.suppressesEvent(
            id: event.id,
            channelId: event.channelId
        )
    }

    @MainActor
    private func scheduleDeletion(for events: [EventProjection]) async {
        let uniqueEvents = Array(
            Dictionary(uniqueKeysWithValues: events.map { ($0.id, $0) }).values
        )
        guard !uniqueEvents.isEmpty else { return }

        let summary: String = {
            if uniqueEvents.count == 1,
               let first = uniqueEvents.first
            {
                let title = first.title.trimmingCharacters(in: .whitespacesAndNewlines)
                return title.isEmpty ? localizationManager.localized("push_type_event") : title
            }
            return "\(uniqueEvents.count) × \(localizationManager.localized("push_type_event"))"
        }()

        let scope = PendingLocalDeletionController.Scope(
            eventIDs: Set(uniqueEvents.map(\.id))
        )

        await environment.pendingLocalDeletionController.schedule(
            summary: summary,
            undoLabel: localizationManager.localized("cancel"),
            scope: scope
        ) {
            _ = try await viewModel.deleteEvents(eventIds: uniqueEvents.map(\.id))
        } onCompletion: { [environment] result in
            guard case let .failure(error) = result else { return }
            environment.showErrorToast(
                error,
                fallbackMessage: localizationManager.localized("operation_failed"),
                duration: 2
            )
        }

        if let selectedEvent, scope.suppressesEvent(id: selectedEvent.id, channelId: selectedEvent.channelId) {
            self.selectedEvent = nil
        }
        selectedEventIds.subtract(scope.eventIDs)
    }

    @ViewBuilder
    private var channelFilterMenuContent: some View {
        EmptyView()
    }

    private var isFilterMenuHighlighted: Bool {
        !selectedChannelIDs.isEmpty || !selectedTags.isEmpty
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

    private var filterPopoverContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            Button {
                isBatchModeActive.toggle()
                isFilterPopoverPresented = false
            } label: {
                filterMenuSelectionRow(
                    title: "选择",
                    systemImage: "checklist",
                    isSelected: isBatchModeActive
                )
            }
            .buttonStyle(.plain)
            .padding(.vertical, 2)

            if !allChannelIds.isEmpty {
                Rectangle()
                    .fill(Color.appDividerSubtle.opacity(0.9))
                    .frame(height: 0.5)
                    .padding(.vertical, 2)

                Text("Channels")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                EventFilterChipFlowLayout(horizontalSpacing: 8, verticalSpacing: 8) {
                    filterCloudChip(
                        title: localizationManager.localized("all_groups"),
                        isSelected: selectedChannelIDs.isEmpty
                    ) {
                        selectedChannelIDs.removeAll()
                    }
                    ForEach(allChannelIds, id: \.self) { channelId in
                        filterCloudChip(
                            title: environment.channelDisplayName(for: channelId) ?? channelId,
                            isSelected: selectedChannelIDs.contains(channelId)
                        ) {
                            if selectedChannelIDs.contains(channelId) {
                                selectedChannelIDs.remove(channelId)
                            } else {
                                selectedChannelIDs.insert(channelId)
                            }
                        }
                    }
                }
            }

            if !allTags.isEmpty {
                Rectangle()
                    .fill(Color.appDividerSubtle.opacity(0.9))
                    .frame(height: 0.5)
                    .padding(.vertical, 2)

                Text("Tags")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                EventFilterChipFlowLayout(horizontalSpacing: 8, verticalSpacing: 8) {
                    ForEach(allTags, id: \.self) { tag in
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

    private func tagCloudChip(tag: String) -> some View {
        let isSelected = selectedTags.contains(tag)
        return filterCloudChip(title: tag, isSelected: isSelected) {
            if isSelected {
                selectedTags.remove(tag)
            } else {
                selectedTags.insert(tag)
            }
        }
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

    private var allVisibleEventIDs: Set<String> {
        Set(filteredEvents.map(\.id))
    }

    private var areAllVisibleEventsSelected: Bool {
        let visibleIDs = allVisibleEventIDs
        return !visibleIDs.isEmpty && selectedEventIds == visibleIDs
    }

    private func toggleSelectAllEvents() {
        let visibleIDs = allVisibleEventIDs
        guard !visibleIDs.isEmpty else { return }
        selectedEventIds = areAllVisibleEventsSelected ? [] : visibleIDs
    }
}

private struct EventFilterChipFlowLayout: Layout {
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
