import SwiftUI

struct EventListScreen: View {
    @Environment(AppEnvironment.self) private var environment: AppEnvironment
    @Environment(LocalizationManager.self) private var localizationManager: LocalizationManager

    @Bindable var viewModel: EntityProjectionViewModel
    var openEventId: String? = nil
    var onOpenEventHandled: (() -> Void)? = nil
    @State private var selectedEvent: EventProjection?
    @State private var searchQuery: String = ""
    @State private var selectedChannelId: String?

    var body: some View {
        let baseContent = Group {
            if viewModel.events.isEmpty {
                EntityEmptyView(
                    iconName: "bolt.horizontal.circle",
                    title: localizationManager.localized("events_empty_title"),
                    subtitle: localizationManager.localized("events_empty_hint")
                )
            } else if filteredEvents.isEmpty {
                MessageSearchPlaceholderView(
                    imageName: "questionmark.circle",
                    title: "no_matching_results",
                    detailKey: "try_changing_a_keyword_or_clear_the_filter_conditions"
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 24)
            } else {
                List {
                    ForEach(Array(filteredEvents.enumerated()), id: \.element.id) { index, event in
                        Button {
                            selectEvent(event)
                        } label: {
                            EventListRow(event: event)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("event.row.\(event.id)")
                        .listRowInsets(EdgeInsets(
                            top: EntityVisualTokens.listRowInsetVertical,
                            leading: EntityVisualTokens.listRowInsetHorizontal,
                            bottom: EntityVisualTokens.listRowInsetVertical,
                            trailing: EntityVisualTokens.listRowInsetHorizontal
                        ))
                        .listRowBackground(Color.clear)
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
                .scrollContentBackground(.hidden)
                .background(EntityVisualTokens.pageBackground)
            }
        }
        applySearchIfNeeded(baseContent)
        .accessibilityIdentifier("screen.events.list")
        .task(id: searchAutoloadTrigger) {
            await autoloadSearchResultsIfNeeded()
        }
        .navigationTitle(localizationManager.localized("push_type_event"))
        .navigationBarTitleDisplayMode(.large)
        .toolbar { toolbarContent }
        .onAppear {
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
        if viewModel.events.isEmpty {
            content
        } else {
            content.searchable(
                text: $searchQuery,
                placement: .navigationBarDrawer(displayMode: .always),
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

    private var searchAutoloadTrigger: String {
        "\(normalizedSearchQuery)|\(selectedChannelId ?? "_")|\(viewModel.events.count)|\(viewModel.hasMoreEvents)|\(viewModel.isLoadingMoreEvents)"
    }

    private var normalizedSearchQuery: String {
        searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private var shouldAutoloadSearchResults: Bool {
        let hasActiveFilter = !normalizedSearchQuery.isEmpty || selectedChannelId != nil
        return hasActiveFilter
            && filteredEvents.isEmpty
            && viewModel.hasMoreEvents
            && !viewModel.isLoadingMoreEvents
    }

    private func autoloadSearchResultsIfNeeded() async {
        guard shouldAutoloadSearchResults else { return }
        await viewModel.loadMoreEvents()
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

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Menu {
                channelFilterMenuContent
            } label: {
                Image(systemName: selectedChannelId == nil ? "line.3.horizontal.decrease" : "line.3.horizontal.decrease.circle.fill")
            }
            .accessibilityLabel(localizationManager.localized("channel"))
        }
    }

    private func normalizedChannel(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private func openEventIfNeeded() {
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

struct EventListRow: View {
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

    private var statusColor: Color {
        eventSeverityColor(severity) ?? eventStateColor(event.state)
    }

    private var previewImageAttachments: [URL] {
        event.imageURLs.filter(isLikelyImageAttachmentURL).prefix(3).map { $0 }
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

                EntityStateBadge(text: statusLabel, color: statusColor)
                    .fixedSize(horizontal: true, vertical: true)
                    .layoutPriority(2)

                Spacer(minLength: 8)
                Text(EntityDateFormatter.relativeText(event.updatedAt))
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
                    tint: isClosed ? .gray : (eventSeverityColor(severity) ?? .orange)
                )
            }

            HStack(spacing: 8) {
                if let thingId = event.thingId, !thingId.isEmpty {
                    Label(String(thingId.prefix(20)), systemImage: "cube")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
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
                    if event.imageURLs.filter(isLikelyImageAttachmentURL).count > 3 {
                        Text("+\(event.imageURLs.filter(isLikelyImageAttachmentURL).count - 3)")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.leading, 4)
                    }
                }
                .padding(.top, 2)
            }
        }
        .padding(.vertical, EntityVisualTokens.rowVerticalPadding)
    }
}
