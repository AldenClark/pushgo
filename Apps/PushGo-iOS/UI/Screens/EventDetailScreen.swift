import SwiftUI

struct EventDetailScreen: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(LocalizationManager.self) private var localizationManager: LocalizationManager

    private enum ConfirmationKind: String, Identifiable {
        case delete
        case close

        var id: String { rawValue }
    }

    let event: EventProjection
    var onDelete: (() -> Void)? = nil
    var onCloseEvent: (() -> Void)? = nil
    @State private var activeConfirmation: ConfirmationKind?

    var body: some View {
        navigationContainer {
            EventDetailPanel(event: event)
                .navigationTitle("")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { toolbarContent }
        }
        .pushgoSheetSizing(.detail)
        .accessibilityIdentifier("screen.events.detail")
        .alert(item: $activeConfirmation) { kind in
            switch kind {
            case .delete:
                Alert(
                    title: Text(localizationManager.localized("are_you_sure_you_want_to_delete_this_message_once_deleted_it_cannot_be_recovered")),
                    primaryButton: .destructive(Text(localizationManager.localized("delete"))) {
                        onDelete?()
                        dismiss()
                    },
                    secondaryButton: .cancel(Text(localizationManager.localized("cancel")))
                )
            case .close:
                Alert(
                    title: Text("\(localizationManager.localized("close")) \(localizationManager.localized("push_type_event"))?"),
                    primaryButton: .default(Text(localizationManager.localized("confirm"))) {
                        onCloseEvent?()
                        dismiss()
                    },
                    secondaryButton: .cancel(Text(localizationManager.localized("cancel")))
                )
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            if canShowCloseAction {
                Button {
                    activeConfirmation = .close
                } label: {
                    Image(systemName: "checkmark.circle")
                }
                .accessibilityLabel(localizationManager.localized("close"))
            }

            if onDelete != nil {
                Button(role: .destructive) {
                    activeConfirmation = .delete
                } label: {
                    Image(systemName: "trash")
                }
                .accessibilityLabel(localizationManager.localized("delete"))
            }
        }
    }

    private var canShowCloseAction: Bool {
        guard onCloseEvent != nil else { return false }
        return eventLifecycleState(from: event.state) != .closed
    }
}

private struct EventDetailPanel: View {
    @Environment(AppEnvironment.self) private var environment: AppEnvironment
    @Environment(LocalizationManager.self) private var localizationManager: LocalizationManager

    let event: EventProjection
    @State private var previewImageItem: EventImagePreviewItem?

    private var severity: EventSeverity? {
        normalizedEventSeverity(event.severity)
    }

    private var orderedTimeline: [EventTimelinePoint] {
        event.timeline.sorted { $0.happenedAt > $1.happenedAt }
    }

    private var createdAt: Date? {
        event.timeline.min { $0.happenedAt < $1.happenedAt }?.happenedAt
    }

    private var latestAt: Date {
        orderedTimeline.first?.happenedAt ?? event.updatedAt
    }

    private var isEnded: Bool {
        eventLifecycleState(from: event.state) == .closed
    }

    private var statusLabel: String {
        normalizedEventStatus(event.status) ?? localizedDefaultCreatedEventStatus()
    }

    private var statusTone: AppSemanticTone {
        eventSeverityTone(severity) ?? eventStateTone(event.state)
    }

    private var attrsEntries: [EntityDisplayAttribute] {
        parseEntityAttributes(from: event.attrsJSON)
    }

    private var imageAttachments: [URL] {
        event.imageURLs.filter(isLikelyImageAttachmentURL)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(event.title)
                            .font(.title3.weight(.semibold))
                            .lineLimit(2)
                        Spacer(minLength: 8)
                        EntityStateBadge(text: statusLabel, tone: statusTone)
                    }
                    if let summary = event.summary, !summary.isEmpty {
                        Text(summary)
                            .font(.subheadline)
                            .foregroundStyle(Color.appTextSecondary)
                    }
                    if let statusMessage = event.message, !statusMessage.isEmpty {
                        EntityInlineAlert(
                            text: statusMessage,
                            systemImage: eventSeveritySymbol(severity) ?? "info.circle.fill",
                            tone: eventSeverityTone(severity) ?? .warning
                        )
                    }

                    HStack(spacing: 12) {
                        if let createdAt {
                            Label(EntityDateFormatter.text(createdAt), systemImage: "clock")
                                .lineLimit(1)
                        }
                        Label(
                            EntityDateFormatter.text(latestAt),
                            systemImage: isEnded ? "checkmark.circle" : "arrow.triangle.2.circlepath"
                        )
                        .lineLimit(1)
                    }
                    .font(.caption)
                    .foregroundStyle(Color.appTextSecondary)

                    HStack(spacing: 8) {
                        if let thingId = event.thingId, !thingId.isEmpty {
                            Text(String(format: localizationManager.localized("Object %@"), thingId))
                                .lineLimit(1)
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
                    .font(.caption)
                    .foregroundStyle(Color.appTextSecondary)

                    if !event.tags.isEmpty {
                        Text(event.tags.joined(separator: " · "))
                            .font(.caption)
                            .foregroundStyle(Color.appTextSecondary)
                    }

                    if !attrsEntries.isEmpty {
                        EntityKeyValueRows(entries: attrsEntries)
                    }

                    if !imageAttachments.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            EventAttachmentImageStrip(
                                urls: imageAttachments,
                                onTap: { previewImageItem = EventImagePreviewItem(url: $0) }
                            )
                        }
                    }
                }

                if orderedTimeline.isEmpty {
                    EntityEmptyView(
                        iconName: "clock.arrow.circlepath",
                        title: "No history records.",
                        subtitle: "Updates will appear here when this event receives new actions.",
                        fillsAvailableSpace: false,
                        topPadding: 12
                    )
                } else {
                    VStack(spacing: 0) {
                        ForEach(orderedTimeline.indices, id: \.self) { index in
                            let point = orderedTimeline[index]
                            EventTimelineRow(
                                point: point,
                                isFirst: index == 0,
                                isLast: index == orderedTimeline.count - 1
                            )
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 18)
        }
        .background(EntityVisualTokens.pageBackground)
        .pushgoImagePreviewOverlay(previewItem: $previewImageItem, imageURL: \.url)
    }
}

private struct EventImagePreviewItem: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

private struct EventAttachmentImageStrip: View {
    let urls: [URL]
    let onTap: (URL) -> Void

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(minimum: 60), spacing: 8), count: 3)
    }

    var body: some View {
        LazyVGrid(columns: columns, spacing: 8) {
            ForEach(urls, id: \.absoluteString) { url in
                RemoteImageView(url: url, rendition: .listThumbnail) { image in
                    Button {
                        onTap(url)
                    } label: {
                        image
                            .resizable()
                            .scaledToFill()
                            .frame(height: 82)
                            .clipShape(RoundedRectangle(cornerRadius: EntityVisualTokens.radiusSmall, style: .continuous))
                    }
                    .buttonStyle(.plain)
                } placeholder: {
                    Rectangle()
                        .fill(EntityVisualTokens.secondarySurface)
                        .frame(height: 82)
                        .clipShape(RoundedRectangle(cornerRadius: EntityVisualTokens.radiusSmall, style: .continuous))
                }
            }
        }
    }
}


private struct EventTimelineRow: View {
    @Environment(LocalizationManager.self) private var localizationManager: LocalizationManager

    let point: EventTimelinePoint
    let isFirst: Bool
    let isLast: Bool

    private var severity: EventSeverity? {
        normalizedEventSeverity(point.severity)
    }

    private var statusTone: AppSemanticTone {
        eventSeverityTone(severity) ?? eventStateTone(point.state)
    }

    private var attrsEntries: [EntityDisplayAttribute] {
        parseEntityAttributes(from: point.attrsJSON)
    }

    private var metadataEntries: [EntityDisplayAttribute] {
        metadataDisplayAttributes(from: point.metadata)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            EntityTimelineMarker(tone: .neutral, isFirst: isFirst, isLast: isLast)
                .padding(.vertical, 6)

            VStack(alignment: .leading, spacing: EntityVisualTokens.stackSpacing) {
                HStack(alignment: .center) {
                    Text(EntityDateFormatter.text(point.happenedAt))
                        .font(.caption)
                        .foregroundStyle(Color.appTextSecondary)
                    Spacer(minLength: 8)
                    if let status = normalizedEventStatus(point.status) {
                        EntityStateBadge(text: status, tone: statusTone)
                    }
                }

                if let title = point.displayTitle, !title.isEmpty {
                    Text(title)
                        .font(.body.weight(.semibold))
                }

                if let summary = point.displaySummary, !summary.isEmpty {
                    Text(summary)
                        .font(.subheadline)
                        .foregroundStyle(Color.appTextSecondary)
                }
                if let statusMessage = point.message, !statusMessage.isEmpty {
                    EntityInlineAlert(
                        text: statusMessage,
                        systemImage: eventSeveritySymbol(severity) ?? "info.circle.fill",
                        tone: eventSeverityTone(severity) ?? .warning
                    )
                }

                HStack(spacing: 8) {
                    if let thingId = point.thingId, !thingId.isEmpty {
                        Text(String(format: localizationManager.localized("Object %@"), thingId))
                            .lineLimit(1)
                    }
                    if !point.tags.isEmpty {
                        Text(point.tags.joined(separator: " · "))
                            .lineLimit(1)
                    }
                    if let descriptor = entityDecryptionBadgeDescriptor(
                        state: point.decryptionState,
                        localizationManager: localizationManager
                    ) {
                        EntityMetaChip(
                            systemImage: descriptor.icon,
                            text: descriptor.text,
                            color: descriptor.tone.foreground
                        )
                    }
                }
                .font(.caption)
                .foregroundStyle(Color.appTextSecondary)

                if !attrsEntries.isEmpty {
                    EventTimelineAttributeRows(
                        title: localizationManager.localized("attrs"),
                        entries: attrsEntries
                    )
                }

                if !metadataEntries.isEmpty {
                    EventTimelineMetadataRows(
                        title: localizationManager.localized("metadata"),
                        entries: metadataEntries
                    )
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: EntityVisualTokens.radiusMedium, style: .continuous)
                    .fill(EntityVisualTokens.secondarySurface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: EntityVisualTokens.radiusMedium, style: .continuous)
                    .stroke(EntityVisualTokens.subtleStroke, lineWidth: 0.8)
            )
        }
        .padding(.bottom, isLast ? 0 : 10)
    }
}

private struct EventTimelineAttributeRows: View {
    let title: String
    let entries: [EntityDisplayAttribute]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: "slider.horizontal.3")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.appTextSecondary)
                .lineLimit(1)
            EntityKeyValueRows(entries: entries)
        }
    }
}

private struct EventTimelineMetadataRows: View {
    let title: String
    let entries: [EntityDisplayAttribute]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: "square.stack.3d.up")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.appTextSecondary)
                .lineLimit(1)

            VStack(spacing: 0) {
                ForEach(entries.indices, id: \.self) { index in
                    let entry = entries[index]
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(entry.displayLabel)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.appTextSecondary)
                        Text(entry.value)
                            .font(.caption)
                            .foregroundStyle(.primary)
                            .textSelection(.enabled)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
                    if index < entries.count - 1 {
                        AppInsetDivider()
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: EntityVisualTokens.radiusMedium, style: .continuous)
                    .fill(EntityVisualTokens.subtleFillSoft)
            )
        }
    }
}
