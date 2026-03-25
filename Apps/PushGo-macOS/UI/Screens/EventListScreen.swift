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
            } else {
                List(selection: $selection) {
                    ForEach(Array(events.enumerated()), id: \.element.id) { index, event in
                        EventListRow(event: event)
                            .accessibilityIdentifier("event.row.\(event.id)")
                            .tag(event.id)
                            .listRowInsets(Layout.rowInsets)
                            .alignmentGuide(.listRowSeparatorLeading) { dimensions in
                                dimensions[.leading]
                            }
                            .alignmentGuide(.listRowSeparatorTrailing) { dimensions in
                                dimensions[.trailing] - Layout.rowInsets.trailing
                            }
                            .listRowBackground(Color.clear)
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
                .background(ListScrollStyleStabilizer())
            }
        }
        .accessibilityIdentifier("screen.events.list")
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
