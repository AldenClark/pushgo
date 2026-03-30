import SwiftUI

struct ThingSplitScreen: View {
    @Environment(AppEnvironment.self) private var environment: AppEnvironment
    @Environment(LocalizationManager.self) private var localizationManager: LocalizationManager

    @Bindable var viewModel: EntityProjectionViewModel
    @Binding var selection: String?
    var openThingId: String? = nil
    var onOpenThingHandled: (() -> Void)? = nil
    @State private var searchQuery: String = ""
    @State private var selectedChannelId: String?
    @State private var hydrationRequestedThingIDs: Set<String> = []
    @State private var isBatchMode: Bool = false
    @State private var batchSelection: Set<String> = []
    private let fixedListWidth: CGFloat = 300

    var body: some View {
        navigationContainer {
            HSplitView {
                thingListPane
                thingDetailPane
            }
            .navigationTitle(localizationManager.localized("push_type_thing"))
            .onAppear {
                syncSelection()
            }
            .onChange(of: viewModel.things) { _, _ in
                syncSelection()
            }
            .onChange(of: searchQuery) { _, _ in
                syncSelection()
            }
            .onChange(of: openThingId) { _, _ in
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
                Task { await viewModel.ensureThingDetailsLoaded(thingId: id) }
            }
        }
#if DEBUG
        .task(id: automationStateSignature) {
            publishAutomationState()
        }
#endif
    }

    private var thingListPane: some View {
        navigationContainer {
            if isBatchMode {
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
            } else {
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
                .searchable(
                    text: $searchQuery,
                    prompt: Text(localizationManager.localized("search_objects"))
                )
                .frame(minWidth: fixedListWidth, idealWidth: fixedListWidth, maxWidth: fixedListWidth)
            }
        }
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
        guard let selection else { return }
        Task {
            do {
                try await viewModel.deleteThing(thingId: selection)
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

    private func deleteSelectedThings() {
        let ids = Array(batchSelection)
        guard !ids.isEmpty else { return }
        Task {
            do {
                for thingId in ids {
                    try await viewModel.deleteThing(thingId: thingId)
                }
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
