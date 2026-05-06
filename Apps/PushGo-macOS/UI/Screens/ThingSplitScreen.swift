import SwiftUI

struct ThingSplitScreen: View {
    @Environment(AppEnvironment.self) private var environment: AppEnvironment
    @Environment(LocalizationManager.self) private var localizationManager: LocalizationManager

    let viewModel: EntityProjectionViewModel
    @Binding var selection: String?
    var openThingId: String? = nil
    var onOpenThingHandled: (() -> Void)? = nil
    @State private var searchQuery: String = ""
    @State private var selectedChannelId: String?
    @State private var hydrationRequestedThingIDs: Set<String> = []
    @State private var isBatchMode: Bool = false
    @State private var batchSelection: Set<String> = []
    @State private var searchFieldText: String = ""
    private let fixedListWidth: CGFloat = 300

    var body: some View {
        configuredSplitView
    }

    @ViewBuilder
    private var configuredSplitView: some View {
#if DEBUG
        splitView
            .task(id: automationStateSignature) {
                publishAutomationState()
            }
#else
        splitView
#endif
    }

    private var splitView: some View {
        HSplitView {
            thingListPane
            thingDetailPane
        }
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
        .onChange(of: viewModel.things) { _, _ in
            syncSelection()
        }
        .onChange(of: isBatchMode) { _, isActive in
            searchFieldText = isActive ? "" : searchQuery
        }
        .onChange(of: searchQuery) { _, _ in
            syncSelection()
        }
        .onChange(of: openThingId) { _, _ in
            syncSelection()
        }
        .onChange(of: selection) { _, id in
            guard !isBatchMode else { return }
            guard let id else { return }
            Task { await viewModel.ensureThingDetailsLoaded(thingId: id) }
        }
        .onChange(of: environment.pendingLocalDeletionController.pendingDeletion) { _, _ in
            let visibleIDs = Set(filteredThings.map(\.id))
            batchSelection = batchSelection.intersection(visibleIDs)
            syncSelection()
        }
    }

    @ViewBuilder
    private var thingListPane: some View {
        navigationContainer {
            ThingListScreen(
                things: filteredThings,
                selection: $selection,
                batchSelection: $batchSelection,
                isBatchMode: $isBatchMode,
                isLoadingMore: viewModel.isLoadingMoreThings,
                onReachEnd: {
                    Task { await viewModel.loadMoreThings() }
                }
            )
            .frame(minWidth: fixedListWidth, idealWidth: fixedListWidth, maxWidth: fixedListWidth)
            .refreshable {
                await handleProviderIngressPullRefresh()
            }
            .searchable(
                text: $searchFieldText,
                placement: .toolbar,
                prompt: Text(localizationManager.localized("search_objects"))
            )
            .navigationTitle(localizationManager.localized("push_type_thing"))
        }
        .pendingLocalDeletionBarHost(environment: environment)
        .toolbar { listToolbarContent }
    }

    private var thingDetailPane: some View {
        navigationContainer {
            ThingDetailScreen(thing: selectedThing)
        }
        .toolbar { detailToolbarContent }
    }

#if DEBUG
    private var automationStateSignature: String {
        [
            selection ?? "",
            openThingId ?? "",
            "\(filteredThings.count)",
        ].joined(separator: "|")
    }

    private func publishAutomationState() {
        PushGoAutomationRuntime.shared.publishState(
            environment: environment,
            activeTab: "things",
            visibleScreen: selectedThing == nil ? "screen.things.list" : "screen.things.detail",
            openedEntityType: selectedThing == nil ? nil : "thing",
            openedEntityId: selectedThing?.id
        )
    }
#endif

    private var filteredThings: [ThingProjection] {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let filtered = viewModel.things.filter { thing in
            guard !isPendingLocalDeletion(thing) else { return false }
            if let selectedChannelId {
                let thingChannelId = thing.channelId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if thingChannelId != selectedChannelId {
                    return false
                }
            }
            guard !query.isEmpty else { return true }
            let externalValues = thing.externalIDs
                .sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
                .map { "\($0.key) \($0.value)" }
                .joined(separator: " ")
            return [
                thing.title,
                thing.summary ?? "",
                thing.tags.joined(separator: " "),
                thing.id,
                normalizedThingState(thing.state),
                thing.channelId ?? "",
                thing.locationType ?? "",
                thing.locationValue ?? "",
                externalValues,
                thing.attrsJSON ?? "",
                thing.relatedMessages.map(\.title).joined(separator: " "),
                thing.relatedMessages.compactMap(\.summary).joined(separator: " "),
            ]
            .joined(separator: " ")
            .lowercased()
            .contains(query)
        }
        return filtered.sorted { lhs, rhs in
            let lhsRank = stateSortPriority(lhs.state)
            let rhsRank = stateSortPriority(rhs.state)
            if lhsRank != rhsRank {
                return lhsRank < rhsRank
            }
            return lhs.updatedAt > rhs.updatedAt
        }
    }

    private var channelOptions: [(id: String, name: String)] {
        let channelIds = Set(viewModel.things.compactMap {
            let trimmed = $0.channelId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed.isEmpty ? nil : trimmed
        })
        return channelIds
            .map { id in (id: id, name: environment.channelDisplayName(for: id) ?? id) }
            .sorted { lhs, rhs in
                lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
    }

    private func stateSortPriority(_ state: String?) -> Int {
        switch normalizedThingState(state) {
        case "ACTIVE":
            return 0
        case "ARCHIVED":
            return 1
        case "DELETED":
            return 2
        default:
            return 3
        }
    }

    private var selectedThing: ThingProjection? {
        guard !isBatchMode else { return nil }
        guard let selection else { return nil }
        return filteredThings.first(where: { $0.id == selection })
    }

    private func isPendingLocalDeletion(_ thing: ThingProjection) -> Bool {
        environment.pendingLocalDeletionController.suppressesThing(
            id: thing.id,
            channelId: thing.channelId
        )
    }

    @MainActor
    private func handleProviderIngressPullRefresh() async {
        _ = await environment.syncProviderIngress(reason: "things_pull_to_refresh")
        await viewModel.reload()
        syncSelection()
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
                    deleteSelectedThings()
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
            Button(role: .destructive) {
                deleteSelectedThing()
            } label: {
                Image(systemName: "trash")
            }
            .help(localizationManager.localized("delete"))
            .disabled(selectedThing == nil || isBatchMode)
        }
    }

    private func setBatchMode(_ enabled: Bool) {
        isBatchMode = enabled
        if enabled {
            selection = nil
        } else {
            batchSelection.removeAll()
        }
    }

    private func deleteSelectedThing() {
        guard let selectedThing else { return }
        Task { await scheduleDeletion(for: [selectedThing]) }
    }

    private func deleteSelectedThings() {
        Task { await scheduleDeletion(for: selectedBatchThings) }
    }

    private var selectedBatchThings: [ThingProjection] {
        let ids = batchSelection
        guard !ids.isEmpty else { return [] }
        return filteredThings.filter { ids.contains($0.id) }
    }

    @MainActor
    private func scheduleDeletion(for things: [ThingProjection]) async {
        let uniqueThings = Array(
            Dictionary(uniqueKeysWithValues: things.map { ($0.id, $0) }).values
        )
        guard !uniqueThings.isEmpty else { return }

        let summary: String = {
            if uniqueThings.count == 1,
               let first = uniqueThings.first
            {
                let title = first.title.trimmingCharacters(in: .whitespacesAndNewlines)
                return title.isEmpty ? localizationManager.localized("push_type_thing") : title
            }
            return "\(uniqueThings.count) × \(localizationManager.localized("push_type_thing"))"
        }()

        let scope = PendingLocalDeletionController.Scope(
            thingIDs: Set(uniqueThings.map(\.id))
        )

        await environment.pendingLocalDeletionController.schedule(
            summary: summary,
            undoLabel: localizationManager.localized("cancel"),
            scope: scope
        ) {
            for thing in uniqueThings {
                try await viewModel.deleteThing(thingId: thing.id)
            }
        } onCompletion: { [environment, localizationManager] result in
            guard case let .failure(error) = result else { return }
            environment.showToast(
                message: "\(localizationManager.localized("operation_failed")): \(error.localizedDescription)",
                style: .error,
                duration: 2
            )
        }

        if let selectedThing,
           scope.suppressesThing(id: selectedThing.id, channelId: selectedThing.channelId)
        {
            selection = nil
        }
        batchSelection.subtract(scope.thingIDs)
        if uniqueThings.count > 1 {
            setBatchMode(false)
        }
    }

    private func syncSelection() {
        if isBatchMode {
            selection = nil
            return
        }
        if let target = openThingId?.trimmingCharacters(in: .whitespacesAndNewlines),
           !target.isEmpty
        {
            if filteredThings.contains(where: { $0.id == target }) {
                selection = target
                hydrationRequestedThingIDs.remove(target)
                onOpenThingHandled?()
                return
            }
            if !hydrationRequestedThingIDs.contains(target) {
                hydrationRequestedThingIDs.insert(target)
                Task { @MainActor in
                    await viewModel.ensureThingDetailsLoaded(thingId: target)
                    syncSelection()
                }
                return
            }
        }

        if selection != nil,
           filteredThings.isEmpty,
           (viewModel.isLoadingMoreThings || viewModel.hasMoreThings)
        {
            return
        }

        if let selection,
           filteredThings.contains(where: { $0.id == selection }) {
            return
        }
        selection = filteredThings.first?.id
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
