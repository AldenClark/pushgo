import SwiftUI

struct ThingListScreen: View {
    @Environment(AppEnvironment.self) private var environment: AppEnvironment
    @Environment(LocalizationManager.self) private var localizationManager: LocalizationManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @Bindable var viewModel: EntityProjectionViewModel
    var openThingId: String? = nil
    var scrollToTopToken: Int = 0
    var onOpenThingHandled: (() -> Void)? = nil
    @State private var selectedThing: ThingProjection?
    @State private var selectedThingIds: Set<String> = []
    @State private var showBatchDeleteConfirmation = false
    @State private var searchQuery: String = ""
    @State private var selectedChannelId: String?
    @State private var isBatchModeActive = false

    var body: some View {
        let filteredThingsSnapshot = filteredThings
        let baseContent = Group {
            if viewModel.things.isEmpty {
                EntityEmptyView(
                    iconName: "shippingbox",
                    title: localizationManager.localized("things_empty_title"),
                    subtitle: localizationManager.localized("things_empty_hint")
                )
            } else if filteredThingsSnapshot.isEmpty {
                MessageSearchPlaceholderView(
                    imageName: "questionmark.circle",
                    title: "no_matching_results",
                    detailKey: "try_changing_a_keyword_or_clear_the_filter_conditions"
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 24)
            } else {
                ScrollViewReader { proxy in
                    List(selection: batchSelectionBinding) {
                        ForEach(filteredThingsSnapshot.indices, id: \.self) { index in
                            let thing = filteredThingsSnapshot[index]
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
                            .listRowSeparator(index == filteredThingsSnapshot.count - 1 ? .hidden : .visible, edges: .bottom)
                            .onAppear {
                                guard index == filteredThingsSnapshot.count - 1 else { return }
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
                                filteredThingsCount: filteredThingsSnapshot.count
                            )
                        }
                    )
                    .environment(\.editMode, isBatchMode ? .constant(.active) : .constant(.inactive))
                    .scrollContentBackground(.hidden)
                    .background(EntityVisualTokens.pageBackground)
                    .onChange(of: scrollToTopToken) { _, _ in
                        scrollToTopIfNeeded(proxy, filteredThings: filteredThingsSnapshot)
                    }
                }
            }
        }
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
        .alert(
            localizationManager.localized("delete"),
            isPresented: $showBatchDeleteConfirmation,
        ) {
            Button(localizationManager.localized("delete"), role: .destructive) {
                Task { await deleteSelectedThings() }
            }
            Button(localizationManager.localized("cancel"), role: .cancel) {}
        } message: {
            Text(localizationManager.localized("batch_delete_selected_things_confirm", selectedThingIds.count))
        }
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
        .onChange(of: environment.messageStoreRevision) { _, _ in
            Task { @MainActor in
                await viewModel.reload()
                syncSelectedThingSnapshot()
                openThingIfNeeded()
            }
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
        .sheet(item: $selectedThing) { thing in
            ThingDetailScreen(thing: thing) {
                Task { await deleteThing(thingId: thing.id) }
            }
            .accessibilityIdentifier("sheet.thing.detail")
        }
        content
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

    private var filteredThings: [ThingProjection] {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let matched = viewModel.things.filter { thing in
            let channelMatched = selectedChannelId == nil || normalizedChannel(thing.channelId) == selectedChannelId
            guard channelMatched else { return false }
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
        "\(normalizedSearchQuery)|\(selectedChannelId ?? "_")|\(viewModel.things.count)|\(filteredThingsCount)|\(viewModel.hasMoreThings)|\(viewModel.isLoadingMoreThings)"
    }

    private var normalizedSearchQuery: String {
        searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func shouldAutoloadSearchResults(filteredThingsCount: Int) -> Bool {
        let hasActiveFilter = !normalizedSearchQuery.isEmpty
            || selectedChannelId != nil
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

    private func openThingIfNeeded() {
        guard !isBatchMode else { return }
        let target = openThingId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !target.isEmpty else { return }
        if let matched = viewModel.things.first(where: { $0.id == target }) {
            if let channelId = normalizedChannel(matched.channelId) {
                selectedChannelId = channelId
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

    private func syncSelectedThingSnapshot() {
        guard let selectedId = selectedThing?.id else { return }
        if let refreshed = viewModel.things.first(where: { $0.id == selectedId }) {
            selectedThing = refreshed
        }
    }

    private func deleteThing(thingId: String) async {
        do {
            try await viewModel.deleteThing(thingId: thingId)
            selectedThing = nil
        } catch {
            environment.showToast(
                message: "\(localizationManager.localized("operation_failed")): \(error.localizedDescription)",
                style: .error,
                duration: 2
            )
        }
    }

    private func deleteSelectedThings() async {
        let ids = Array(selectedThingIds)
        guard !ids.isEmpty else { return }
        do {
            for thingId in ids {
                try await viewModel.deleteThing(thingId: thingId)
            }
            selectedThingIds.removeAll()
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
