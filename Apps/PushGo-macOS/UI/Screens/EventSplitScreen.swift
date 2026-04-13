import SwiftUI

struct EventSplitScreen: View {
    @Environment(AppEnvironment.self) private var environment: AppEnvironment
    @Environment(LocalizationManager.self) private var localizationManager: LocalizationManager

    @Bindable var viewModel: EntityProjectionViewModel
    @Binding var selection: String?
    var openEventId: String? = nil
    var onOpenEventHandled: (() -> Void)? = nil
    @State private var searchQuery: String = ""
    @State private var selectedChannelId: String?
    @State private var hydrationRequestedEventIDs: Set<String> = []
    @State private var showCloseConfirmation = false
    @State private var isBatchMode: Bool = false
    @State private var batchSelection: Set<String> = []
    @State private var searchFieldText: String = ""
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
        .onChange(of: environment.messageStoreRevision) { _, _ in
            Task { @MainActor in
                await viewModel.reload()
                syncSelection()
            }
        }
        .onChange(of: selection) { _, id in
            guard !isBatchMode else { return }
            guard let id else { return }
            Task { await viewModel.ensureEventDetailsLoaded(eventId: id) }
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
            .navigationTitle(localizationManager.localized("push_type_event"))
        }
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
            if let selectedChannelId {
                let eventChannelId = event.channelId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if eventChannelId != selectedChannelId {
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
        let channelIds = Set(viewModel.events.compactMap {
            let trimmed = $0.channelId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
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
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                setBatchMode(!isBatchMode)
            } label: {
                Image(systemName: isBatchMode ? "checkmark" : "checklist.unchecked")
            }
            .help(isBatchMode ? localizationManager.localized("done") : localizationManager.localized("edit"))
            .accessibilityLabel(isBatchMode ? localizationManager.localized("done") : localizationManager.localized("edit"))
            if isBatchMode {
                Button(role: .destructive) {
                    deleteSelectedEvents()
                } label: {
                    Image(systemName: "trash")
                }
                .help(localizationManager.localized("delete"))
                .accessibilityLabel(localizationManager.localized("delete"))
                .disabled(batchSelection.isEmpty)
            } else {
                Menu {
                    channelFilterMenuContent
                } label: {
                    Image(systemName: selectedChannelId == nil ? "line.3.horizontal.decrease" : "line.3.horizontal.decrease.circle.fill")
                }
                .menuIndicator(.hidden)
                .help(localizationManager.localized("channel"))
                .accessibilityLabel(localizationManager.localized("channel"))
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

    private func closeSelectedEvent() {
        guard let selectedEvent else { return }
        Task {
            do {
                try await viewModel.closeEvent(event: selectedEvent)
            } catch {
                await MainActor.run {
                    environment.showToast(
                        message: "\(localizationManager.localized("operation_failed")): \(error.localizedDescription)",
                        style: .error,
                        duration: 2
                    )
                }
            }
        }
    }

    private func deleteSelectedEvent() {
        guard let selection else { return }
        Task {
            do {
                try await viewModel.deleteEvent(eventId: selection)
                await MainActor.run {
                    self.selection = nil
                }
            } catch {
                await MainActor.run {
                    environment.showToast(
                        message: "\(localizationManager.localized("operation_failed")): \(error.localizedDescription)",
                        style: .error,
                        duration: 2
                    )
                }
            }
        }
    }

    private func deleteSelectedEvents() {
        let ids = Array(batchSelection)
        guard !ids.isEmpty else { return }
        Task {
            do {
                _ = try await viewModel.deleteEvents(eventIds: ids)
                await MainActor.run {
                    batchSelection.removeAll()
                    setBatchMode(false)
                }
            } catch {
                await MainActor.run {
                    environment.showToast(
                        message: "\(localizationManager.localized("operation_failed")): \(error.localizedDescription)",
                        style: .error,
                        duration: 2
                    )
                }
            }
        }
    }

    private func syncSelection() {
        if isBatchMode {
            selection = nil
            return
        }
        if let target = openEventId?.trimmingCharacters(in: .whitespacesAndNewlines),
           !target.isEmpty
        {
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

        ForEach(channelOptions, id: \.id) { option in
            Button {
                selectedChannelId = option.id
            } label: {
                channelFilterMenuItemLabel(
                    title: option.name,
                    isSelected: selectedChannelId == option.id
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
