import SwiftUI

struct EventSplitScreen: View {
    @Environment(AppEnvironment.self) private var environment: AppEnvironment
    @Environment(LocalizationManager.self) private var localizationManager: LocalizationManager

    let viewModel: EntityProjectionViewModel
    @Binding var selection: String?
    var openEventId: String? = nil
    var onOpenEventHandled: (() -> Void)? = nil
    @State private var searchQuery: String = ""
    @State private var selectedChannelIDs: Set<String> = []
    @State private var selectedTags: Set<String> = []
    @State private var hydrationRequestedEventIDs: Set<String> = []
    @State private var showCloseConfirmation = false
    @State private var isBatchMode: Bool = false
    @State private var batchSelection: Set<String> = []
    @State private var searchFieldText: String = ""
    @State private var isFilterPopoverPresented = false
    private let fixedListWidth: CGFloat = 300

    var body: some View {
        HSplitView {
            eventListPane
            eventDetailPane
        }
        .alert(
            "\(localizationManager.localized("close")) \(localizationManager.localized("push_type_event"))?",
            isPresented: $showCloseConfirmation
        ) {
            Button(localizationManager.localized("confirm")) {
                closeSelectedEvent()
            }
            Button(localizationManager.localized("cancel"), role: .cancel) {}
        }
#if DEBUG
        .task(id: automationStateSignature) {
            publishAutomationState()
        }
#endif
        .onAppear {
            if searchFieldText != searchQuery {
                searchFieldText = searchQuery
            }
            syncSelection()
        }
        .onChange(of: searchFieldText) { _, newValue in
            guard !isBatchMode else { return }
            guard searchQuery != newValue else { return }
            searchQuery = newValue
        }
        .onChange(of: viewModel.events) { _, _ in
            syncSelection()
        }
        .onChange(of: isBatchMode) { _, isActive in
            searchFieldText = isActive ? "" : searchQuery
        }
        .onChange(of: searchQuery) { _, _ in
            syncSelection()
        }
        .onChange(of: openEventId) { _, _ in
            syncSelection()
        }
        .onChange(of: selection) { _, id in
            guard !isBatchMode else { return }
            guard let id else { return }
            Task { await viewModel.ensureEventDetailsLoaded(eventId: id) }
        }
        .onChange(of: environment.pendingLocalDeletionController.pendingDeletion) { _, _ in
            let visibleIDs = Set(filteredEvents.map(\.id))
            batchSelection = batchSelection.intersection(visibleIDs)
            syncSelection()
        }
    }

    @ViewBuilder
    private var eventListPane: some View {
        navigationContainer {
            EventListScreen(
                events: filteredEvents,
                selection: $selection,
                batchSelection: $batchSelection,
                isBatchMode: $isBatchMode,
                isLoadingMore: viewModel.isLoadingMoreEvents,
                onReachEnd: {
                    Task { await viewModel.loadMoreEvents() }
                }
            )
            .frame(minWidth: fixedListWidth, idealWidth: fixedListWidth, maxWidth: fixedListWidth)
            .refreshable {
                await handleProviderIngressPullRefresh()
            }
            .searchable(
                text: $searchFieldText,
                placement: .toolbar,
                prompt: Text(localizationManager.localized("search_events"))
            )
            .navigationTitle(isBatchMode ? "" : localizationManager.localized("push_type_event"))
        }
        .pendingLocalDeletionBarHost(environment: environment)
        .toolbar { listToolbarContent }
    }

    private var eventDetailPane: some View {
        navigationContainer {
            EventDetailScreen(event: selectedEvent)
        }
        .toolbar { detailToolbarContent }
    }

#if DEBUG
    private var automationStateSignature: String {
        [
            selection ?? "",
            openEventId ?? "",
            "\(filteredEvents.count)",
        ].joined(separator: "|")
    }

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

    private var filteredEvents: [EventProjection] {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return viewModel.events.filter { event in
            guard !isPendingLocalDeletion(event) else { return false }
            if !selectedChannelIDs.isEmpty {
                let eventChannelId = event.channelId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !selectedChannelIDs.contains(eventChannelId) {
                    return false
                }
            }
            if !selectedTags.isEmpty {
                let normalizedEventTags = Set(event.tags.map(normalizedTag))
                if !selectedTags.contains(where: normalizedEventTags.contains) {
                    return false
                }
            }
            guard !query.isEmpty else { return true }
            return [
                event.title,
                event.summary ?? "",
                event.severity ?? "",
                event.tags.joined(separator: " "),
                event.id,
                event.state ?? "",
                event.thingId ?? "",
                event.channelId ?? "",
            ]
            .joined(separator: " ")
            .lowercased()
            .contains(query)
        }
    }

    private var selectedEvent: EventProjection? {
        guard !isBatchMode else { return nil }
        guard let selection else { return nil }
        return filteredEvents.first(where: { $0.id == selection })
    }

    private var channelOptions: [(id: String, name: String)] {
        let channelIds = Set(viewModel.events.compactMap { event -> String? in
            guard !isPendingLocalDeletion(event) else { return nil }
            let trimmed = event.channelId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed.isEmpty ? nil : trimmed
        })
        return channelIds
            .map { id in (id: id, name: environment.channelDisplayName(for: id) ?? id) }
            .sorted { lhs, rhs in
                lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
    }

    @ToolbarContentBuilder
    private var listToolbarContent: some ToolbarContent {
        if isBatchMode {
            ToolbarItem(placement: .navigation) {
                Button {
                    toggleSelectAllVisibleEvents()
                } label: {
                    Image(systemName: areAllVisibleEventsSelected ? "checkmark.rectangle.stack.fill" : "checkmark.rectangle.stack")
                }
                .help(localizationManager.localized("all"))
                .accessibilityLabel(localizationManager.localized("all"))
            }
        }

        ToolbarItemGroup(placement: .primaryAction) {
            if isBatchMode {
                Button(role: .destructive) {
                    deleteSelectedEvents()
                } label: {
                    Image(systemName: "trash")
                }
                .help(localizationManager.localized("delete"))
                .accessibilityLabel(localizationManager.localized("delete"))
                .disabled(batchSelection.isEmpty)
                
                Button {
                    Task { await exitBatchModeAfterFlushingPendingDeletion() }
                } label: {
                    batchDoneToolbarIcon()
                }
                .help(localizationManager.localized("done"))
                .accessibilityLabel(localizationManager.localized("done"))
            } else {
                Button {
                    isFilterPopoverPresented = true
                } label: {
                    filterToolbarIcon(isHighlighted: isFilterMenuHighlighted)
                }
                .help(localizationManager.localized("channel"))
                .accessibilityLabel(localizationManager.localized("channel"))
                .popover(isPresented: $isFilterPopoverPresented, arrowEdge: .top) {
                    filterPopoverContent
                }
            }
        }
    }

    @ToolbarContentBuilder
    private var detailToolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .secondaryAction) {
            if canCloseSelectedEvent {
                Button {
                    showCloseConfirmation = true
                } label: {
                    Image(systemName: "checkmark.circle")
                }
                .help(localizationManager.localized("close"))
            }

            Button(role: .destructive) {
                deleteSelectedEvent()
            } label: {
                Image(systemName: "trash")
            }
            .help(localizationManager.localized("delete"))
            .disabled(selectedEvent == nil || isBatchMode)
        }
    }

    private var canCloseSelectedEvent: Bool {
        guard let selectedEvent else { return false }
        return eventLifecycleState(from: selectedEvent.state) != .closed
    }

    private func isPendingLocalDeletion(_ event: EventProjection) -> Bool {
        environment.pendingLocalDeletionController.suppressesEvent(
            id: event.id,
            channelId: event.channelId
        )
    }

    @MainActor
    private func handleProviderIngressPullRefresh() async {
        _ = await environment.syncProviderIngress(reason: "events_pull_to_refresh")
        await viewModel.reload()
        syncSelection()
    }

    private func setBatchMode(_ enabled: Bool) {
        isBatchMode = enabled
        if enabled {
            selection = nil
        } else {
            batchSelection.removeAll()
        }
    }

    @MainActor
    private func exitBatchModeAfterFlushingPendingDeletion() async {
        await environment.pendingLocalDeletionController.commitCurrentIfNeeded()
        setBatchMode(false)
    }

    private func closeSelectedEvent() {
        guard let selectedEvent else { return }
        Task {
            do {
                try await viewModel.closeEvent(event: selectedEvent)
            } catch {
                await MainActor.run {
                    environment.showErrorToast(
                        error,
                        fallbackMessage: localizationManager.localized("operation_failed"),
                        duration: 2
                    )
                }
            }
        }
    }

    private func deleteSelectedEvent() {
        guard let selectedEvent else { return }
        Task { await scheduleDeletion(for: [selectedEvent]) }
    }

    private func deleteSelectedEvents() {
        Task { await scheduleDeletion(for: selectedBatchEvents) }
    }

    private var selectedBatchEvents: [EventProjection] {
        let ids = batchSelection
        guard !ids.isEmpty else { return [] }
        return filteredEvents.filter { ids.contains($0.id) }
    }

    private var allVisibleEventIDs: Set<String> {
        Set(filteredEvents.map(\.id))
    }

    private var areAllVisibleEventsSelected: Bool {
        let visibleIDs = allVisibleEventIDs
        return !visibleIDs.isEmpty && batchSelection == visibleIDs
    }

    private func toggleSelectAllVisibleEvents() {
        let visibleIDs = allVisibleEventIDs
        guard !visibleIDs.isEmpty else { return }
        batchSelection = areAllVisibleEventsSelected ? [] : visibleIDs
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

        if let selectedEvent,
           scope.suppressesEvent(id: selectedEvent.id, channelId: selectedEvent.channelId)
        {
            selection = nil
        }
        batchSelection.subtract(scope.eventIDs)
    }

    private func syncSelection() {
        if isBatchMode {
            selection = nil
            return
        }
        if let target = openEventId?.trimmingCharacters(in: .whitespacesAndNewlines),
           !target.isEmpty
        {
            if !selectedTags.isEmpty {
                selectedTags.removeAll()
                return
            }
            if filteredEvents.contains(where: { $0.id == target }) {
                selection = target
                hydrationRequestedEventIDs.remove(target)
                onOpenEventHandled?()
                return
            }
            if !hydrationRequestedEventIDs.contains(target) {
                hydrationRequestedEventIDs.insert(target)
                Task { @MainActor in
                    await viewModel.ensureEventDetailsLoaded(eventId: target)
                    syncSelection()
                }
                return
            }
        }

        if selection != nil,
           filteredEvents.isEmpty,
           viewModel.isLoadingMoreEvents
        {
            return
        }

        if let selection,
           filteredEvents.contains(where: { $0.id == selection }) {
            return
        }
        selection = filteredEvents.first?.id
    }

    private var filterPopoverContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            Button {
                setBatchMode(true)
                isFilterPopoverPresented = false
            } label: {
                filterMenuSelectionRow(
                    title: "选择",
                    systemImage: "checklist",
                    isSelected: isBatchMode
                )
            }
            .buttonStyle(.plain)
            .padding(.vertical, 2)

            if !channelOptions.isEmpty {
                Rectangle()
                    .fill(Color.appDividerSubtle.opacity(0.9))
                    .frame(height: 0.5)
                    .padding(.vertical, 2)

                Text("Channels")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                EventSplitFilterChipFlowLayout(horizontalSpacing: 8, verticalSpacing: 8) {
                    filterCloudChip(
                        title: localizationManager.localized("all_groups"),
                        isSelected: selectedChannelIDs.isEmpty
                    ) {
                        selectedChannelIDs.removeAll()
                    }
                    ForEach(channelOptions, id: \.id) { option in
                        filterCloudChip(
                            title: option.name,
                            isSelected: selectedChannelIDs.contains(option.id)
                        ) {
                            if selectedChannelIDs.contains(option.id) {
                                selectedChannelIDs.remove(option.id)
                            } else {
                                selectedChannelIDs.insert(option.id)
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

                EventSplitFilterChipFlowLayout(horizontalSpacing: 8, verticalSpacing: 8) {
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

    private var availableTags: [String] {
        allTags
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

    private func normalizedTag(_ rawTag: String) -> String {
        rawTag.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private var isFilterMenuHighlighted: Bool {
        !selectedChannelIDs.isEmpty || !selectedTags.isEmpty
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

}

private struct EventSplitFilterChipFlowLayout: Layout {
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
