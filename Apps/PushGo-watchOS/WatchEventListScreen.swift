import SwiftUI

struct WatchEventListScreen: View {
    @Environment(AppEnvironment.self) private var environment: AppEnvironment
    @Environment(LocalizationManager.self) private var localizationManager: LocalizationManager

    let viewModel: WatchLightStoreViewModel
    @State private var navigationPath: [String] = []
    @State private var didLoad = false

    var body: some View {
        NavigationStack(path: $navigationPath) {
            List {
                if viewModel.events.isEmpty {
                    WatchEntityEmptyState(
                        icon: "waveform.path.ecg",
                        text: localizationManager.localized("events_empty_title")
                    )
                } else {
                    ForEach(viewModel.events) { event in
                        NavigationLink(value: event.eventId) {
                            WatchLightEventRow(event: event)
                        }
                    }
                }
            }
            .navigationTitle(localizationManager.localized("push_type_event"))
            .accessibilityIdentifier("screen.events.list")
            .navigationDestination(for: String.self) { eventId in
                if viewModel.event(eventId: eventId) != nil {
                    WatchEventDetailScreen(eventId: eventId, viewModel: viewModel)
                } else {
                    WatchEntityMissingState()
                }
            }
            .onAppear {
                guard !didLoad else {
                    openPendingEventIfNeeded()
                    return
                }
                didLoad = true
                Task { @MainActor in
                    await viewModel.reload()
                    openPendingEventIfNeeded()
                }
            }
            .onChange(of: viewModel.events) { _, _ in
                openPendingEventIfNeeded()
            }
            .onChange(of: environment.pendingEventToOpen) { _, _ in
                openPendingEventIfNeeded()
            }
            .onChange(of: environment.messageStoreRevision) { _, _ in
                Task { @MainActor in
                    await viewModel.reload()
                    openPendingEventIfNeeded()
                }
            }
#if DEBUG
            .task(id: automationStateVersion) {
                PushGoWatchAutomationRuntime.shared.publishState(
                    environment: environment,
                    activeTab: MainTab.events.automationIdentifier,
                    visibleScreen: navigationPath.last == nil ? "screen.events.list" : "screen.event.detail",
                    openedEntityType: navigationPath.last == nil ? nil : "event",
                    openedEntityId: navigationPath.last
                )
            }
#endif
        }
    }

    private func openPendingEventIfNeeded() {
        let trimmed = environment.pendingEventToOpen?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return }
        guard viewModel.events.contains(where: { $0.eventId == trimmed }) else { return }
        navigationPath = [trimmed]
        environment.pendingEventToOpen = nil
    }

    private var automationStateVersion: String {
        [
            navigationPath.last ?? "",
            environment.pendingEventToOpen ?? "",
            String(viewModel.events.count),
            String(environment.unreadMessageCount),
        ].joined(separator: "|")
    }
}

private struct WatchLightEventRow: View {
    let event: WatchLightEvent

    var body: some View {
        VStack(alignment: .leading, spacing: WatchEntityVisualTokens.sectionSpacing) {
            HStack(alignment: .center, spacing: 8) {
                Text(event.title)
                    .font(.headline)
                    .lineLimit(1)
                Spacer(minLength: 6)
                WatchEntityStateBadge(
                    text: normalizedWatchEventStatus(event.state) ?? localizedDefaultWatchCreatedEventStatus(),
                    color: watchEventStateColor(event.state)
                )
            }

            if let summary = event.summary, !summary.isEmpty {
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }

            HStack(spacing: 8) {
                if let severity = event.severity, !severity.isEmpty {
                    Label(severity, systemImage: "exclamationmark.triangle")
                }
                Text(watchDateText(event.updatedAt))
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, WatchEntityVisualTokens.rowVerticalPadding)
    }
}
