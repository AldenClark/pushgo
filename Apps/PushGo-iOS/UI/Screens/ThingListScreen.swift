import SwiftUI

struct ThingListScreen: View {
    private enum OverlayState {
        case onboarding
        case searchPlaceholder
    }

    @Environment(AppEnvironment.self) private var environment: AppEnvironment
    @Environment(LocalizationManager.self) private var localizationManager: LocalizationManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let viewModel: EntityProjectionViewModel
    var openThingId: String? = nil
    var scrollToTopToken: Int = 0
    var onOpenThingHandled: (() -> Void)? = nil
    @State private var selectedThing: ThingProjection?
    @State private var selectedThingIds: Set<String> = []
    @State private var searchQuery: String = ""
    @State private var selectedChannelId: String?
    @State private var selectedTag: String?
    @State private var isFilterPopoverPresented = false
    @State private var isBatchModeActive = false

    var body: some View {
        let filteredThingsSnapshot = filteredThings
        let baseContent = listContainer(filteredThings: filteredThingsSnapshot)
        let content = applySearchIfNeeded(baseContent)
        .accessibilityIdentifier("screen.things.list")
        .refreshable {
            await handlePullToRefresh()
        }
        .task(id: searchAutoloadTrigger(filteredThingsCount: filteredThingsSnapshot.count)) {
            await autoloadSearchResultsIfNeeded(filteredThingsCount: filteredThingsSnapshot.count)
        }
        .navigationTitle(localizationManager.localized("push_type_thing"))
        .navigationBarTitleDisplayMode(.large)
        .toolbar { toolbarContent }
        .toolbar(isBatchMode ? .hidden : .visible, for: .tabBar)
        .onAppear {
            environment.updateThingListPosition(isAtTop: true)
            openThingIfNeeded()
#if DEBUG
            publishAutomationState()
#endif
        }
        .onChange(of: viewModel.things) { _, _ in
            syncSelectedThingSnapshot()
            openThingIfNeeded()
#if DEBUG
            publishAutomationState()
#endif
        }
        .onChange(of: openThingId) { _, _ in
            openThingIfNeeded()
#if DEBUG
            publishAutomationState()
#endif
        }
        .onChange(of: selectedThing?.id) { _, _ in
#if DEBUG
            publishAutomationState()
#endif
        }
        .onChange(of: isBatchMode) { _, active in
            if active {
                selectedThing = nil
            } else {
                selectedThingIds.removeAll()
                openThingIfNeeded()
            }
        }
        .onChange(of: environment.pendingLocalDeletionController.pendingDeletion) { _, _ in
            if let selectedThing, isPendingLocalDeletion(selectedThing) {
                self.selectedThing = nil
            }
            let visibleIDs = Set(filteredThings.map(\.id))
            selectedThingIds = selectedThingIds.intersection(visibleIDs)
        }
        .sheet(item: $selectedThing) { thing in
            ThingDetailScreen(
                thing: thing,
                onCommitDelete: {
                    try await viewModel.deleteThing(thingId: thing.id)
                },
                onPrepareDelete: {
                    selectedThing = nil
                }
            )
            .accessibilityIdentifier("sheet.thing.detail")
        }
        content
    }

    @ViewBuilder
    private func listContainer(filteredThings: [ThingProjection]) -> some View {
        let overlayState = overlayState(for: filteredThings)
        ZStack {
            thingList(filteredThings: filteredThings)
                .opacity(overlayState == nil ? 1 : 0.001)
                .allowsHitTesting(overlayState == nil)
                .accessibilityHidden(overlayState != nil)

            switch overlayState {
            case .onboarding:
                EntityOnboardingEmptyView(kind: .things)
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
    private func thingList(filteredThings: [ThingProjection]) -> some View {
        ScrollViewReader { proxy in
            List(selection: batchSelectionBinding) {
                ForEach(filteredThings.indices, id: \.self) { index in
                    let thing = filteredThings[index]
                    Group {
                        if isBatchMode {
                            ThingListRow(thing: thing)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            Button {
                                selectThing(thing)
                            } label: {
                                ThingListRow(thing: thing)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .id(thing.id)
                    .accessibilityIdentifier("thing.row.\(thing.id)")
                    .tag(thing.id)
                    .listRowInsets(EdgeInsets(
                        top: EntityVisualTokens.listRowInsetVertical,
                        leading: EntityVisualTokens.listRowInsetHorizontal,
                        bottom: EntityVisualTokens.listRowInsetVertical,
                        trailing: EntityVisualTokens.listRowInsetHorizontal
                    ))
                    .listRowBackground(
                        EntitySelectionBackground(isSelected: isBatchMode ? selectedThingIds.contains(thing.id) : selectedThing?.id == thing.id)
                    )
                    .listRowSeparator(index == 0 ? .hidden : .visible, edges: .top)
                    .listRowSeparator(index == filteredThings.count - 1 ? .hidden : .visible, edges: .bottom)
                    .onAppear {
                        guard index == filteredThings.count - 1 else { return }
                        Task { await viewModel.loadMoreThings() }
                    }
                }
                if viewModel.isLoadingMoreThings {
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
                ThingListTopObserverModifier(enabled: true) { topOffset in
                    updateThingListTopState(
                        topOffset: topOffset,
                        filteredThingsCount: filteredThings.count
                    )
                }
            )
            .environment(\.editMode, isBatchMode ? .constant(.active) : .constant(.inactive))
            .scrollContentBackground(.hidden)
            .background(EntityVisualTokens.pageBackground)
            .onChange(of: scrollToTopToken) { _, _ in
                scrollToTopIfNeeded(proxy, filteredThings: filteredThings)
            }
        }
    }

    private func overlayState(for filteredThings: [ThingProjection]) -> OverlayState? {
        if viewModel.things.isEmpty {
            .onboarding
        } else if filteredThings.isEmpty {
            .searchPlaceholder
        } else {
            nil
        }
    }

#if DEBUG
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

    @ViewBuilder
    private func applySearchIfNeeded<Content: View>(_ content: Content) -> some View {
        if viewModel.things.isEmpty || isBatchMode {
            content
        } else {
            content.searchable(
                text: $searchQuery,
                placement: .navigationBarDrawer(displayMode: .automatic),
                prompt: Text(localizationManager.localized("search_objects"))
            )
        }
    }

    private var availableChannelIds: [String] {
        Array(
            Set(viewModel.things.compactMap { normalizedChannel($0.channelId) })
        ).sorted()
    }

    private var availableTags: [String] {
        var tags = Set<String>()
        for thing in viewModel.things {
            for tag in thing.tags {
                let normalized = normalizedTag(tag)
                if !normalized.isEmpty {
                    tags.insert(normalized)
                }
            }
        }
        return tags.sorted()
    }

    private var filteredThings: [ThingProjection] {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let matched = viewModel.things.filter { thing in
            guard !isPendingLocalDeletion(thing) else { return false }
            let channelMatched = selectedChannelId == nil || normalizedChannel(thing.channelId) == selectedChannelId
            guard channelMatched else { return false }
            if let selectedTag {
                let hasTag = thing.tags.contains { normalizedTag($0) == selectedTag }
                guard hasTag else { return false }
            }
            guard !query.isEmpty else { return true }
            return searchableText(for: thing).contains(query)
        }
        return matched.sorted { lhs, rhs in
            let lhsRank = thingSortPriority(lhs)
            let rhsRank = thingSortPriority(rhs)
            if lhsRank != rhsRank {
                return lhsRank < rhsRank
            }
            return lhs.updatedAt > rhs.updatedAt
        }
    }

    private func searchAutoloadTrigger(filteredThingsCount: Int) -> String {
        "\(normalizedSearchQuery)|\(selectedChannelId ?? "_")|\(selectedTag ?? "_")|\(viewModel.things.count)|\(filteredThingsCount)|\(viewModel.hasMoreThings)|\(viewModel.isLoadingMoreThings)"
    }

    private var normalizedSearchQuery: String {
        searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func shouldAutoloadSearchResults(filteredThingsCount: Int) -> Bool {
        let hasActiveFilter = !normalizedSearchQuery.isEmpty
            || selectedChannelId != nil
            || selectedTag != nil
        return hasActiveFilter
            && filteredThingsCount == 0
            && viewModel.hasMoreThings
            && !viewModel.isLoadingMoreThings
    }

    private func autoloadSearchResultsIfNeeded(filteredThingsCount: Int) async {
        guard shouldAutoloadSearchResults(filteredThingsCount: filteredThingsCount) else { return }
        await viewModel.loadMoreThings()
    }

    private func updateThingListTopState(topOffset: CGFloat, filteredThingsCount: Int) {
        let isAtTop = filteredThingsCount == 0 || topOffset <= ThingListTopMetrics.topTolerance
        environment.updateThingListPosition(isAtTop: isAtTop)
    }

    private func searchableText(for thing: ThingProjection) -> String {
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
    }

    private func handlePullToRefresh() async {
        _ = await environment.syncProviderIngress(reason: "things_pull_to_refresh")
        await viewModel.reload()
        syncSelectedThingSnapshot()
        openThingIfNeeded()
    }

    private func scrollToTopIfNeeded(_ proxy: ScrollViewProxy, filteredThings: [ThingProjection]) {
        guard let firstId = filteredThings.first?.id else { return }
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
                    toggleSelectAllThings()
                } label: {
                    Image(systemName: areAllVisibleThingsSelected ? "checkmark.rectangle.stack.fill" : "checkmark.rectangle.stack")
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
                    Task { await scheduleDeletion(for: selectedBatchThings) }
                } label: {
                    Image(systemName: "trash")
                }
                .accessibilityLabel(localizationManager.localized("delete"))
                .disabled(selectedThingIds.isEmpty)
            }
        }
    }

    private var isBatchMode: Bool {
        isBatchModeActive
    }

    private var batchSelectionBinding: Binding<Set<String>> {
        if isBatchMode {
            return $selectedThingIds
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

    private func openThingIfNeeded() {
        guard !isBatchMode else { return }
        let target = openThingId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !target.isEmpty else { return }
        if let matched = viewModel.things.first(where: { $0.id == target }) {
            if let channelId = normalizedChannel(matched.channelId) {
                selectedChannelId = channelId
            }
            if selectedTag != nil {
                selectedTag = nil
            }
            if !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                searchQuery = ""
            }
            selectThing(matched)
            onOpenThingHandled?()
            return
        }

        Task { @MainActor in
            await viewModel.ensureThingDetailsLoaded(thingId: target)
            guard let hydrated = viewModel.things.first(where: { $0.id == target }) else { return }
            if let channelId = normalizedChannel(hydrated.channelId) {
                selectedChannelId = channelId
            }
            if selectedTag != nil {
                selectedTag = nil
            }
            if !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                searchQuery = ""
            }
            selectThing(hydrated)
            onOpenThingHandled?()
        }
    }

    private func selectThing(_ thing: ThingProjection) {
        guard !isBatchMode else { return }
        selectedThing = thing
        Task { @MainActor in
            await viewModel.ensureThingDetailsLoaded(thingId: thing.id)
            syncSelectedThingSnapshot()
        }
    }

    @MainActor
    private func exitBatchModeAfterFlushingPendingDeletion() async {
        await environment.pendingLocalDeletionController.commitCurrentIfNeeded()
        isBatchModeActive = false
    }

    private func syncSelectedThingSnapshot() {
        guard let selectedId = selectedThing?.id else { return }
        if let refreshed = viewModel.things.first(where: { $0.id == selectedId }) {
            selectedThing = refreshed
        }
    }

    private var selectedBatchThings: [ThingProjection] {
        let selectedIds = selectedThingIds
        guard !selectedIds.isEmpty else { return [] }
        return filteredThings.filter { selectedIds.contains($0.id) }
    }

    private func isPendingLocalDeletion(_ thing: ThingProjection) -> Bool {
        environment.pendingLocalDeletionController.suppressesThing(
            id: thing.id,
            channelId: thing.channelId
        )
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

        if let selectedThing, scope.suppressesThing(id: selectedThing.id, channelId: selectedThing.channelId) {
            self.selectedThing = nil
        }
        selectedThingIds.subtract(scope.thingIDs)
    }

    @ViewBuilder
    private var channelFilterMenuContent: some View {
        EmptyView()
    }

    private var isFilterMenuHighlighted: Bool {
        selectedChannelId != nil || selectedTag != nil
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

            if !availableChannelIds.isEmpty {
                Rectangle()
                    .fill(Color.appDividerSubtle.opacity(0.9))
                    .frame(height: 0.5)
                    .padding(.vertical, 2)

                Text("Channels")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                ThingFilterChipFlowLayout(horizontalSpacing: 8, verticalSpacing: 8) {
                    filterCloudChip(
                        title: localizationManager.localized("all_groups"),
                        isSelected: selectedChannelId == nil
                    ) {
                        selectedChannelId = nil
                    }
                    ForEach(availableChannelIds, id: \.self) { channelId in
                        filterCloudChip(
                            title: environment.channelDisplayName(for: channelId) ?? channelId,
                            isSelected: selectedChannelId == channelId
                        ) {
                            selectedChannelId = channelId
                        }
                    }
                }
            }

            if !availableTags.isEmpty {
                Rectangle()
                    .fill(Color.appDividerSubtle.opacity(0.9))
                    .frame(height: 0.5)
                    .padding(.vertical, 2)

                Text("Tags")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                ThingFilterChipFlowLayout(horizontalSpacing: 8, verticalSpacing: 8) {
                    ForEach(availableTags, id: \.self) { tag in
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
        let isSelected = selectedTag == tag
        return filterCloudChip(title: tag, isSelected: isSelected) {
            selectedTag = isSelected ? nil : tag
        }
    }

    private func filterCloudChip(title: String, isSelected: Bool, onTap: @escaping () -> Void) -> some View {
        Button {
            onTap()
            isFilterPopoverPresented = false
        } label: {
            Text(title)
                .lineLimit(1)
                .truncationMode(.tail)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(minWidth: 60, maxWidth: 208, alignment: .leading)
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

    private var allVisibleThingIDs: Set<String> {
        Set(filteredThings.map(\.id))
    }

    private var areAllVisibleThingsSelected: Bool {
        let visibleIDs = allVisibleThingIDs
        return !visibleIDs.isEmpty && selectedThingIds == visibleIDs
    }

    private func toggleSelectAllThings() {
        let visibleIDs = allVisibleThingIDs
        guard !visibleIDs.isEmpty else { return }
        selectedThingIds = areAllVisibleThingsSelected ? [] : visibleIDs
    }
}

private struct ThingFilterChipFlowLayout: Layout {
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

private struct ThingListTopObserverModifier: ViewModifier {
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

private enum ThingListTopMetrics {
    static let topTolerance: CGFloat = 2
}

private func thingSortPriority(_ thing: ThingProjection) -> Int {
    switch thingLifecycleState(from: thing.state) {
    case .active:
        return 0
    case .archived:
        return 1
    case .deleted:
        return 2
    case .unknown:
        return 3
    }
}

private struct ThingListRow: View {
    @Environment(AppEnvironment.self) private var environment: AppEnvironment
    @Environment(LocalizationManager.self) private var localizationManager: LocalizationManager

    private enum Layout {
        static let primaryImageSize: CGFloat = 44
        static let attachmentImageSize: CGFloat = 42
        static let attachmentImageSpacing: CGFloat = 6
        static let attachmentPreviewFallback: Int = 4
    }

    let thing: ThingProjection

    private var primaryImageURL: URL? {
        thing.imageURL
    }

    private var previewImageAttachments: [URL] {
        var deduped: [URL] = []
        for url in thing.imageURLs where isLikelyImageAttachmentURL(url) {
            if !deduped.contains(where: { $0.absoluteString == url.absoluteString }) {
                deduped.append(url)
            }
        }
        if let primaryImageURL {
            deduped.removeAll { $0.absoluteString == primaryImageURL.absoluteString }
        }
        return deduped
    }

    private var metadataEntries: [EntityDisplayAttribute] {
        parseEntityAttributes(from: thing.attrsJSON)
    }

    private var locationLabel: String? {
        guard let value = thing.locationValue,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        if let type = thing.locationType?.uppercased(), !type.isEmpty {
            return "\(type): \(value)"
        }
        return value
    }

    private var metadataFallbackText: String? {
        if let locationLabel {
            return locationLabel
        }
        if let firstExternal = thing.externalIDs
            .sorted(by: { $0.key.localizedStandardCompare($1.key) == .orderedAscending })
            .first
        {
            return "\(firstExternal.key): \(firstExternal.value)"
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: EntityVisualTokens.stackSpacing) {
            HStack(alignment: .top, spacing: 10) {
                EntityThumbnail(
                    url: primaryImageURL,
                    size: Layout.primaryImageSize,
                    placeholderSystemImage: "cube.box",
                    showsBorder: false
                )
                VStack(alignment: .leading, spacing: 7) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(thing.title)
                            .font(.headline.weight(.semibold))
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Text(EntityDateFormatter.relativeText(thing.updatedAt))
                            .font(.caption)
                            .foregroundStyle(Color.appTextSecondary)
                    }

                    ThingMetadataSummary(entries: metadataEntries, fallbackText: metadataFallbackText)
                }
            }

            if !thing.tags.isEmpty {
                Text(thing.tags.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(Color.appTextSecondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: 8) {
                if let channelId = thing.channelId?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !channelId.isEmpty
                {
                    EntityMetaChip(
                        systemImage: "bubble.left.and.bubble.right",
                        text: environment.channelDisplayName(for: channelId) ?? channelId
                    )
                }
                if let descriptor = entityDecryptionBadgeDescriptor(
                    state: thing.decryptionState,
                    localizationManager: localizationManager
                ) {
                    EntityMetaChip(
                        systemImage: descriptor.icon,
                        text: descriptor.text,
                        color: descriptor.tone.foreground
                    )
                }
            }
            .font(.caption2)
            .foregroundStyle(Color.appTextSecondary)

            if !previewImageAttachments.isEmpty {
                GeometryReader { proxy in
                    let visibleCount = visibleAttachmentCount(for: proxy.size.width)
                    let visibleAttachments = Array(previewImageAttachments.prefix(visibleCount))
                    HStack(spacing: Layout.attachmentImageSpacing) {
                        ForEach(visibleAttachments, id: \.absoluteString) { url in
                            RemoteImageView(url: url, rendition: .listThumbnail) { image in
                                image
                                    .resizable()
                                    .scaledToFill()
                            } placeholder: {
                                Rectangle()
                                    .fill(EntityVisualTokens.secondarySurface)
                            }
                            .frame(width: Layout.attachmentImageSize, height: Layout.attachmentImageSize)
                            .clipShape(
                                RoundedRectangle(cornerRadius: EntityVisualTokens.radiusSmall, style: .continuous)
                            )
                        }
                        if previewImageAttachments.count > visibleCount {
                            Text("+\(previewImageAttachments.count - visibleCount)")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Color.appTextSecondary)
                                .padding(.leading, 4)
                        }
                    }
                }
                .frame(height: Layout.attachmentImageSize)
            }
        }
        .padding(.vertical, EntityVisualTokens.rowVerticalPadding)
    }

    private func visibleAttachmentCount(for availableWidth: CGFloat) -> Int {
        guard availableWidth > 0 else { return Layout.attachmentPreviewFallback }
        let unit = Layout.attachmentImageSize + Layout.attachmentImageSpacing
        let computed = Int(((availableWidth + Layout.attachmentImageSpacing) / unit).rounded(.down))
        return max(1, computed)
    }
}

private struct ThingMetadataSummary: View {
    let entries: [EntityDisplayAttribute]
    let fallbackText: String?

    var body: some View {
        if !entries.isEmpty {
            let visibleEntries = Array(entries.prefix(3))
            let segments = visibleEntries.map { "\($0.displayLabel): \($0.value)" }
            let overflow = max(0, entries.count - visibleEntries.count)
            Text(
                overflow > 0
                    ? "\(segments.joined(separator: " · ")) · +\(overflow)"
                    : segments.joined(separator: " · ")
            )
            .font(.caption2)
            .foregroundStyle(Color.appTextSecondary)
            .lineLimit(2)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if let fallbackText, !fallbackText.isEmpty {
            Text(fallbackText)
                .font(.caption2)
                .foregroundStyle(Color.appTextSecondary)
                .lineLimit(1)
        }
    }
}
