import SwiftUI

struct EventListScreen: View {
    @Environment(LocalizationManager.self) private var localizationManager: LocalizationManager

    private enum Layout {
        static let rowInsets = EdgeInsets(
            top: EntityVisualTokens.listRowInsetVertical,
            leading: EntityVisualTokens.listRowInsetHorizontal,
            bottom: EntityVisualTokens.listRowInsetVertical,
            trailing: EntityVisualTokens.listRowInsetHorizontal
        )
    }

    let events: [EventProjection]
    @Binding var selection: String?
    @Binding var batchSelection: Set<String>
    @Binding var isBatchMode: Bool
    var isLoadingMore: Bool = false
    var onReachEnd: (() -> Void)? = nil

    var body: some View {
        Group {
            if events.isEmpty {
                EntityEmptyView(
                    iconName: "bolt.horizontal.circle",
                    title: localizationManager.localized("events_empty_title"),
                    subtitle: localizationManager.localized("events_empty_hint")
                )
            } else if isBatchMode {
                List {
                    ForEach(events.indices, id: \.self) { index in
                        let event = events[index]
                        Button {
                            toggleBatchSelection(event.id)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: batchSelection.contains(event.id) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(batchSelection.contains(event.id) ? .accent : .secondary)
                                EventListRow(event: event)
                            }
                            .entityListRowTapTarget()
                        }
                        .buttonStyle(.plain)
                        .id(event.id)
                        .accessibilityIdentifier("event.row.\(event.id)")
                        .listRowInsets(Layout.rowInsets)
                        .alignmentGuide(.listRowSeparatorLeading) { dimensions in
                            dimensions[.leading]
                        }
                        .alignmentGuide(.listRowSeparatorTrailing) { dimensions in
                            dimensions[.trailing] - Layout.rowInsets.trailing
                        }
                        .listRowBackground(EntitySelectionBackground(isSelected: batchSelection.contains(event.id)))
                        .listRowSeparator(index == 0 ? .hidden : .visible, edges: .top)
                        .listRowSeparator(index == events.count - 1 ? .hidden : .visible, edges: .bottom)
                        .onAppear {
                            guard index == events.count - 1 else { return }
                            onReachEnd?()
                        }
                    }
                    if isLoadingMore {
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
            } else {
                List {
                    ForEach(events.indices, id: \.self) { index in
                        let event = events[index]
                        Button {
                            selection = event.id
                        } label: {
                            EventListRow(event: event)
                                .entityListRowTapTarget()
                        }
                        .buttonStyle(.plain)
                        .id(event.id)
                        .accessibilityIdentifier("event.row.\(event.id)")
                        .listRowInsets(Layout.rowInsets)
                        .alignmentGuide(.listRowSeparatorLeading) { dimensions in
                            dimensions[.leading]
                        }
                        .alignmentGuide(.listRowSeparatorTrailing) { dimensions in
                            dimensions[.trailing] - Layout.rowInsets.trailing
                        }
                        .listRowBackground(EntitySelectionBackground(isSelected: selection == event.id))
                        .listRowSeparator(index == 0 ? .hidden : .visible, edges: .top)
                        .listRowSeparator(index == events.count - 1 ? .hidden : .visible, edges: .bottom)
                        .onAppear {
                            guard index == events.count - 1 else { return }
                            onReachEnd?()
                        }
                    }
                    if isLoadingMore {
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
        .accessibilityIdentifier("screen.events.list")
    }

    private func toggleBatchSelection(_ eventId: String) {
        if batchSelection.contains(eventId) {
            batchSelection.remove(eventId)
        } else {
            batchSelection.insert(eventId)
        }
    }
}

struct EventListRow: View {
    @Environment(AppEnvironment.self) private var environment: AppEnvironment
    @Environment(LocalizationManager.self) private var localizationManager: LocalizationManager

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

    private var statusTone: AppSemanticTone {
        eventSeverityTone(severity) ?? eventStateTone(event.state)
    }

    private var previewImageAttachments: [URL] {
        Array(imageAttachments.prefix(3))
    }

    private var imageAttachments: [URL] {
        event.imageURLs.filter(isLikelyImageAttachmentURL)
    }

    private var remainingImageAttachmentCount: Int {
        max(0, imageAttachments.count - previewImageAttachments.count)
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
                EntityStateBadge(text: statusLabel, tone: statusTone)
                    .fixedSize(horizontal: true, vertical: true)
                    .layoutPriority(2)
                Spacer(minLength: 8)
                Text(EntityDateFormatter.relativeText(event.updatedAt))
                    .font(.caption)
                    .foregroundStyle(Color.appTextSecondary)
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
                    tone: isClosed ? .neutral : (eventSeverityTone(severity) ?? .warning)
                )
            }

            HStack(spacing: 8) {
                if let thingId = event.thingId, !thingId.isEmpty {
                    Label(String(thingId.prefix(20)), systemImage: "cube")
                        .font(.caption2)
                        .foregroundStyle(Color.appTextSecondary)
                }
                if let channelId = event.channelId?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !channelId.isEmpty
                {
                    EntityMetaChip(
                        systemImage: "bubble.left.and.bubble.right",
                        text: environment.channelDisplayName(for: channelId) ?? channelId
                    )
                }
                if let descriptor = entityDecryptionBadgeDescriptor(
                    state: event.decryptionState,
                    localizationManager: localizationManager
                ) {
                    EntityMetaChip(
                        systemImage: descriptor.icon,
                        text: descriptor.text,
                        color: descriptor.tone.foreground
                    )
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
                    if remainingImageAttachmentCount > 0 {
                        Text("+\(remainingImageAttachmentCount)")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.appTextSecondary)
                            .padding(.leading, 4)
                    }
                }
                .padding(.top, 2)
            }
        }
        .padding(.vertical, EntityVisualTokens.rowVerticalPadding)
    }
}
