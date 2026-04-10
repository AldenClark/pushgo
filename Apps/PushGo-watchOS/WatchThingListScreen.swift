import SwiftUI

struct WatchThingListScreen: View {
    @Environment(AppEnvironment.self) private var environment: AppEnvironment
    @Environment(LocalizationManager.self) private var localizationManager: LocalizationManager

    let viewModel: WatchLightStoreViewModel
    @State private var navigationPath: [String] = []
    @State private var didLoad = false

    var body: some View {
        NavigationStack(path: $navigationPath) {
            List {
                Section {
                    if viewModel.things.isEmpty {
                        WatchEntityEmptyState(
                            icon: "cpu",
                            text: localizationManager.localized("things_empty_title")
                        )
                    } else {
                        ForEach(viewModel.things) { thing in
                            NavigationLink(value: thing.thingId) {
                                WatchLightThingRow(thing: thing)
                            }
                        }
                    }
                }
            }
            .navigationTitle(localizationManager.localized("push_type_thing"))
            .accessibilityIdentifier("screen.things.list")
            .navigationDestination(for: String.self) { thingId in
                if viewModel.thing(thingId: thingId) != nil {
                    WatchThingDetailScreen(thingId: thingId, viewModel: viewModel)
                } else {
                    WatchEntityMissingState()
                }
            }
            .onAppear {
                guard !didLoad else {
                    openPendingThingIfNeeded()
                    return
                }
                didLoad = true
                Task { @MainActor in
                    await viewModel.reload()
                    openPendingThingIfNeeded()
                }
            }
            .onChange(of: viewModel.things) { _, _ in
                openPendingThingIfNeeded()
            }
            .onChange(of: environment.pendingThingToOpen) { _, _ in
                openPendingThingIfNeeded()
            }
            .onChange(of: environment.messageStoreRevision) { _, _ in
                Task { @MainActor in
                    await viewModel.reload()
                    openPendingThingIfNeeded()
                }
            }
#if DEBUG
            .task(id: automationStateVersion) {
                PushGoWatchAutomationRuntime.shared.publishState(
                    environment: environment,
                    activeTab: MainTab.things.automationIdentifier,
                    visibleScreen: navigationPath.last == nil ? "screen.things.list" : "screen.thing.detail",
                    openedEntityType: navigationPath.last == nil ? nil : "thing",
                    openedEntityId: navigationPath.last
                )
            }
#endif
        }
    }

    private func openPendingThingIfNeeded() {
        let trimmed = environment.pendingThingToOpen?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return }
        guard viewModel.things.contains(where: { $0.thingId == trimmed }) else { return }
        navigationPath = [trimmed]
        environment.pendingThingToOpen = nil
    }

    private var automationStateVersion: String {
        [
            navigationPath.last ?? "",
            environment.pendingThingToOpen ?? "",
            String(viewModel.things.count),
            String(environment.unreadMessageCount),
        ].joined(separator: "|")
    }
}

private struct WatchLightThingRow: View {
    let thing: WatchLightThing

    var body: some View {
        HStack(spacing: 8) {
            WatchEntityAvatar(url: thing.imageURL)

            VStack(alignment: .leading, spacing: WatchEntityVisualTokens.sectionSpacing) {
                Text(thing.title)
                    .font(.headline)
                    .lineLimit(1)

                if let summary = thing.summary, !summary.isEmpty {
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(Color.appTextSecondary)
                        .lineLimit(2)
                }

                Text(watchDateText(thing.updatedAt))
                    .font(.caption2)
                    .foregroundStyle(Color.appTextSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, WatchEntityVisualTokens.rowVerticalPadding)
    }
}
