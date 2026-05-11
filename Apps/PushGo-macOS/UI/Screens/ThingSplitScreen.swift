import SwiftUI

struct ThingSplitScreen: View {
    @Environment(AppEnvironment.self) private var environment: AppEnvironment
    @Environment(LocalizationManager.self) private var localizationManager: LocalizationManager

    let viewModel: EntityProjectionViewModel
    @Binding var selection: String?
    var openThingId: String? = nil
    var onOpenThingHandled: (() -> Void)? = nil
    @State private var searchQuery: String = ""
    @State private var selectedChannelIDs: Set<String> = []
    @State private var selectedTags: Set<String> = []
    @State private var hydrationRequestedThingIDs: Set<String> = []
    @State private var isBatchMode: Bool = false
    @State private var batchSelection: Set<String> = []
    @State private var searchFieldText: String = ""
    @State private var isFilterPopoverPresented = false
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
            .navigationTitle(isBatchMode ? "" : localizationManager.localized("push_type_thing"))
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
            if !selectedChannelIDs.isEmpty {
                let thingChannelId = thing.channelId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !selectedChannelIDs.contains(thingChannelId) {
                    return false
                }
            }
            if !selectedTags.isEmpty {
                let normalizedThingTags = Set(thing.tags.map(normalizedTag))
                if !selectedTags.contains(where: normalizedThingTags.contains) {
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
        let channelIds = Set(viewModel.things.compactMap { thing -> String? in
            guard !isPendingLocalDeletion(thing) else { return nil }
            let trimmed = thing.channelId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
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
        if isBatchMode {
            ToolbarItem(placement: .navigation) {
                Button {
                    toggleSelectAllVisibleThings()
                } label: {
                    Image(systemName: areAllVisibleThingsSelected ? "checkmark.rectangle.stack.fill" : "checkmark.rectangle.stack")
                }
                .help(localizationManager.localized("all"))
                .accessibilityLabel(localizationManager.localized("all"))
            }
        }

        ToolbarItemGroup(placement: .primaryAction) {
            if isBatchMode {

                Button(role: .destructive) {
                    deleteSelectedThings()
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

    @MainActor
    private func exitBatchModeAfterFlushingPendingDeletion() async {
        await environment.pendingLocalDeletionController.commitCurrentIfNeeded()
        setBatchMode(false)
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

    private var allVisibleThingIDs: Set<String> {
        Set(filteredThings.map(\.id))
    }

    private var areAllVisibleThingsSelected: Bool {
        let visibleIDs = allVisibleThingIDs
        return !visibleIDs.isEmpty && batchSelection == visibleIDs
    }

    private func toggleSelectAllVisibleThings() {
        let visibleIDs = allVisibleThingIDs
        guard !visibleIDs.isEmpty else { return }
        batchSelection = areAllVisibleThingsSelected ? [] : visibleIDs
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
            _ = try await viewModel.deleteThings(thingIds: uniqueThings.map(\.id))
        } onCompletion: { [environment] result in
            guard case let .failure(error) = result else { return }
            environment.showErrorToast(
                error,
                fallbackMessage: localizationManager.localized("operation_failed"),
                duration: 2
            )
        }

        if let selectedThing,
           scope.suppressesThing(id: selectedThing.id, channelId: selectedThing.channelId)
        {
            selection = nil
        }
        batchSelection.subtract(scope.thingIDs)
    }

    private func syncSelection() {
        if isBatchMode {
            selection = nil
            return
        }
        if let target = openThingId?.trimmingCharacters(in: .whitespacesAndNewlines),
           !target.isEmpty
        {
            if !selectedTags.isEmpty {
                selectedTags.removeAll()
                return
            }
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

                ThingSplitFilterChipFlowLayout(horizontalSpacing: 8, verticalSpacing: 8) {
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

                ThingSplitFilterChipFlowLayout(horizontalSpacing: 8, verticalSpacing: 8) {
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
        for thing in viewModel.things {
            guard !isPendingLocalDeletion(thing) else { continue }
            for tag in thing.tags {
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

private struct ThingSplitFilterChipFlowLayout: Layout {
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
