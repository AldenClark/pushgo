import SwiftUI

struct ThingDetailScreen: View {
    @Environment(LocalizationManager.self) private var localizationManager: LocalizationManager

    let thing: ThingProjection?

    var body: some View {
        Group {
            if let thing {
                ThingDetailPanel(thing: thing)
            } else {
                EntityEmptyView(
                    iconName: "shippingbox",
                    title: localizationManager.localized("things_empty_title"),
                    subtitle: localizationManager.localized("things_empty_hint")
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("screen.things.detail")
    }
}

private struct ThingDetailPanel: View {
    @Environment(AppEnvironment.self) private var environment: AppEnvironment
    private enum Tab: String, CaseIterable, Identifiable {
        case events
        case messages
        case updates

        var id: String { rawValue }

        var titleKey: String {
            switch self {
            case .events:
                return "thing_detail_tab_events"
            case .messages:
                return "thing_detail_tab_messages"
            case .updates:
                return "thing_detail_tab_updates"
            }
        }
    }

    @Environment(LocalizationManager.self) private var localizationManager: LocalizationManager

    let thing: ThingProjection
    @State private var previewImageItem: ThingImagePreviewItem?
    @State private var selectedTab: Tab = .events
    @State private var selectedEvent: EventProjection?
    @State private var selectedMessage: ThingRelatedMessage?
    @State private var selectedUpdate: ThingRelatedUpdate?
    @State private var showMetadataSheet = false

    private var attrsEntries: [EntityDisplayAttribute] {
        parseEntityAttributes(from: thing.attrsJSON)
    }

    private var metadataEntries: [EntityDisplayAttribute] {
        metadataDisplayAttributes(from: thing.metadata)
    }

    private var stateLabel: String {
        normalizedThingState(thing.state)
    }

    private var stateTone: AppSemanticTone {
        thingStateTone(thing.state)
    }

    private var imageAttachments: [URL] {
        var images: [URL] = []
        if let primary = thing.imageURL, isLikelyImageAttachmentURL(primary) {
            images.append(primary)
        }
        for url in thing.imageURLs where isLikelyImageAttachmentURL(url) {
            if !images.contains(where: { $0.absoluteString == url.absoluteString }) {
                images.append(url)
            }
        }
        return images
    }

    private var primaryImageURL: URL? {
        thing.imageURL
    }

    private var secondaryImageURLs: [URL] {
        guard let primaryImageURL else { return imageAttachments }
        return imageAttachments.filter { $0.absoluteString != primaryImageURL.absoluteString }
    }

    private var locationSummary: String? {
        guard let value = thing.locationValue,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        if let type = thing.locationType?.uppercased(), !type.isEmpty {
            return "\(type): \(value)"
        }
        return value
    }

    private var externalIDEntries: [EntityDisplayAttribute] {
        thing.externalIDs
            .sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
            .map { key, value in
                EntityDisplayAttribute(key: key, label: key, value: value)
            }
    }

    private var relatedEvents: [EventProjection] {
        thing.relatedEvents.map(\.event).sorted { $0.updatedAt > $1.updatedAt }
    }

    private var relatedMessages: [ThingRelatedMessage] {
        thing.relatedMessages.sorted { $0.happenedAt > $1.happenedAt }
    }

    private var relatedUpdates: [ThingRelatedUpdate] {
        thing.relatedUpdates.sorted { $0.happenedAt > $1.happenedAt }
    }

    private var lifecycleStateToken: String {
        normalizedThingState(thing.state)
    }

    private var lifecycleTimeLabel: String {
        switch lifecycleStateToken {
        case "ARCHIVED":
            return localizationManager.localized("Archived")
        case "DELETED":
            return localizationManager.localized("Deleted")
        default:
            return localizationManager.localized("Updated")
        }
    }

    private var lifecycleTime: Date {
        if lifecycleStateToken == "DELETED", let deletedAt = thing.deletedAt {
            return deletedAt
        }
        return thing.updatedAt
    }

    private var lifecycleTimeIcon: String {
        switch lifecycleStateToken {
        case "ARCHIVED":
            return "archivebox"
        case "DELETED":
            return "trash"
        default:
            return "arrow.triangle.2.circlepath"
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: EntityVisualTokens.detailSectionSpacing) {
                basicInfoSection

                if !thing.tags.isEmpty {
                    ThingTagChipRow(tags: thing.tags)
                }

                if let summary = thing.summary, !summary.isEmpty {
                    Text(summary)
                        .font(.subheadline)
                        .foregroundStyle(Color.appTextSecondary)
                        .lineLimit(4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                    if !secondaryImageURLs.isEmpty {
                        ThingAttachmentImageStrip(
                            urls: secondaryImageURLs,
                            onTap: { previewImageItem = ThingImagePreviewItem(url: $0) }
                        )
                    }

                AppInsetDivider(verticalPadding: 4)

                Picker("", selection: $selectedTab) {
                    ForEach(Tab.allCases) { tab in
                        Text(localizationManager.localized(tab.titleKey)).tag(tab)
                    }
                }
                .pickerStyle(.segmented)

                tabSection
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, EntityVisualTokens.detailPaddingHorizontal)
            .padding(.vertical, EntityVisualTokens.detailPaddingVertical)
        }
        .background(EntityVisualTokens.pageBackground)
        .pushgoImagePreviewOverlay(previewItem: $previewImageItem, imageURL: \.url)
        .sheet(item: $selectedEvent) { event in
            ThingSecondaryDetailSheet {
                EventDetailScreen(event: event)
            }
        }
        .sheet(item: $selectedMessage) { message in
            ThingSecondaryDetailSheet {
                MessageDetailScreen(
                    messageId: message.id,
                    message: nil,
                    useNavigationContainer: false
                )
            }
        }
        .sheet(item: $selectedUpdate) { update in
            ThingSecondaryDetailSheet {
                ThingRelatedUpdateDetailScreen(update: update)
            }
        }
        .sheet(isPresented: $showMetadataSheet) {
            ThingMetadataSheet(
                title: localizationManager.localized("metadata"),
                entries: metadataEntries
            )
        }
    }

    private var basicInfoSection: some View {
        VStack(alignment: .leading, spacing: EntityVisualTokens.stackSpacing) {
            HStack(alignment: .center, spacing: EntityVisualTokens.stackSpacing) {
                if let primaryImageURL {
                    RemoteImageView(url: primaryImageURL, rendition: .listThumbnail) { image in
                        Button {
                            previewImageItem = ThingImagePreviewItem(url: primaryImageURL)
                        } label: {
                            image
                                .resizable()
                                .scaledToFill()
                                .frame(width: 88, height: 88)
                                .clipShape(
                                    RoundedRectangle(
                                        cornerRadius: EntityVisualTokens.radiusSmall,
                                        style: .continuous
                                    )
                                )
                        }
                        .buttonStyle(.plain)
                    } placeholder: {
                        EntityThumbnail(
                            url: nil,
                            size: 88,
                            placeholderSystemImage: "cube.box",
                            showsBorder: false
                        )
                    }
                } else {
                    EntityThumbnail(
                        url: nil,
                        size: 88,
                        placeholderSystemImage: "cube.box",
                        showsBorder: false
                    )
                }
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(thing.title)
                            .font(.title3.weight(.semibold))
                            .lineLimit(2)
                        if lifecycleStateToken == "ARCHIVED" {
                            EntityStateBadge(text: stateLabel, tone: stateTone)
                                .fixedSize(horizontal: true, vertical: true)
                        }
                    }
                    if !metadataEntries.isEmpty {
                        Button {
                            showMetadataSheet = true
                        } label: {
                            Label(localizationManager.localized("thing_detail_metadata_button"), systemImage: "square.stack.3d.up")
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(
                                    Capsule(style: .continuous)
                                        .fill(EntityVisualTokens.secondarySurface)
                                )
                                .overlay(
                                    Capsule(style: .continuous)
                                        .stroke(EntityVisualTokens.subtleStroke, lineWidth: 0.8)
                                )
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(localizationManager.localized("thing_detail_metadata_button"))
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if !attrsEntries.isEmpty {
                ThingAttributeStateGrid(entries: attrsEntries)
            } else if let attrs = thing.attrsJSON,
                      !attrs.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                Text(attrs)
                    .font(.system(.footnote, design: .monospaced))
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: EntityVisualTokens.radiusSmall, style: .continuous)
                            .fill(EntityVisualTokens.secondarySurface)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: EntityVisualTokens.radiusSmall, style: .continuous)
                            .stroke(EntityVisualTokens.subtleStroke, lineWidth: 0.8)
                    )
            }

            HStack(alignment: .center, spacing: 12) {
                if let createdAt = thing.createdAt {
                    Label(
                        String(
                            format: localizationManager.localized("Created %@"),
                            EntityDateFormatter.text(createdAt)
                        ),
                        systemImage: "calendar"
                    )
                        .lineLimit(1)
                }
                Label("\(lifecycleTimeLabel) \(EntityDateFormatter.text(lifecycleTime))", systemImage: lifecycleTimeIcon)
                    .lineLimit(1)
            }
            .font(.caption)
            .foregroundStyle(Color.appTextSecondary)

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

            if let locationSummary {
                Label(locationSummary, systemImage: "mappin.and.ellipse")
                    .font(.caption)
                    .foregroundStyle(Color.appTextSecondary)
            }

            if !externalIDEntries.isEmpty {
                EntityKeyValueRows(entries: externalIDEntries)
            }
        }
    }

    @ViewBuilder
    private var tabSection: some View {
        switch selectedTab {
        case .events:
            relatedEventsSection
        case .messages:
            relatedMessagesSection
        case .updates:
            relatedUpdatesSection
        }
    }

    private var relatedEventsSection: some View {
        Group {
            if relatedEvents.isEmpty {
                EntityEmptyView(
                    iconName: "bolt.horizontal.circle",
                    title: localizationManager.localized("thing_detail_empty_events_title"),
                    subtitle: localizationManager.localized("thing_detail_empty_events_subtitle"),
                    fillsAvailableSpace: false,
                    topPadding: 12
                )
            } else {
                ThingDetailList(items: relatedEvents) { event in
                    Button {
                        selectedEvent = event
                    } label: {
                        EventListRow(event: event)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var relatedMessagesSection: some View {
        Group {
            if relatedMessages.isEmpty {
                EntityEmptyView(
                    iconName: "tray",
                    title: localizationManager.localized("thing_detail_empty_messages_title"),
                    subtitle: localizationManager.localized("thing_detail_empty_messages_subtitle"),
                    fillsAvailableSpace: false,
                    topPadding: 12
                )
            } else {
                ThingDetailList(items: relatedMessages) { message in
                    Button {
                        selectedMessage = message
                    } label: {
                        ThingRelatedMessageRow(message: message)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var relatedUpdatesSection: some View {
        Group {
            if relatedUpdates.isEmpty {
                EntityEmptyView(
                    iconName: "clock.arrow.circlepath",
                    title: localizationManager.localized("thing_detail_empty_updates_title"),
                    subtitle: localizationManager.localized("thing_detail_empty_updates_subtitle"),
                    fillsAvailableSpace: false,
                    topPadding: 12
                )
            } else {
                ThingDetailList(items: relatedUpdates) { update in
                    Button {
                        selectedUpdate = update
                    } label: {
                        ThingRelatedUpdateRow(update: update)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

private struct ThingAttachmentImageStrip: View {
    let urls: [URL]
    let onTap: (URL) -> Void

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(urls, id: \.absoluteString) { url in
                    RemoteImageView(url: url, rendition: .listThumbnail) { image in
                        Button {
                            onTap(url)
                        } label: {
                            image
                                .resizable()
                                .scaledToFill()
                                .frame(width: 88, height: 88)
                                .clipShape(
                                    RoundedRectangle(
                                        cornerRadius: EntityVisualTokens.radiusSmall,
                                        style: .continuous
                                    )
                                )
                        }
                        .buttonStyle(.plain)
                    } placeholder: {
                        Rectangle()
                            .fill(EntityVisualTokens.secondarySurface)
                            .frame(width: 88, height: 88)
                            .clipShape(
                                RoundedRectangle(
                                    cornerRadius: EntityVisualTokens.radiusSmall,
                                    style: .continuous
                                )
                            )
                    }
                }
            }
        }
        .scrollIndicators(.hidden)
    }
}

private struct ThingTagChipRow: View {
    let tags: [String]

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(tags.indices, id: \.self) { index in
                    let tag = tags[index]
                    EntityMetaChip(systemImage: "tag", text: tag)
                }
            }
        }
        .scrollIndicators(.hidden)
    }
}

private struct ThingAttributeStateGrid: View {
    private let columns = [
        GridItem(.adaptive(minimum: 96, maximum: 180), spacing: 6, alignment: .leading)
    ]

    let entries: [EntityDisplayAttribute]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 6) {
            ForEach(entries) { entry in
                ThingAttributeStateCard(entry: entry)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ThingAttributeStateCard: View {
    let entry: EntityDisplayAttribute

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(entry.displayLabel)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Color.appTextSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Text(entry.value)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 7)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: EntityVisualTokens.radiusSmall, style: .continuous)
                .fill(EntityVisualTokens.subtleFillSoft)
        )
        .overlay(
            RoundedRectangle(cornerRadius: EntityVisualTokens.radiusSmall, style: .continuous)
                .stroke(EntityVisualTokens.subtleStroke, lineWidth: 0.8)
        )
    }
}

private struct ThingMetadataSheet: View {
    @Environment(LocalizationManager.self) private var localizationManager: LocalizationManager
    let title: String
    let entries: [EntityDisplayAttribute]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)
            if entries.isEmpty {
                Text(localizationManager.localized("thing_detail_no_metadata"))
                    .font(.subheadline)
                    .foregroundStyle(Color.appTextSecondary)
            } else {
                EntityKeyValueRows(entries: entries)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(20)
        .background(EntityVisualTokens.pageBackground)
    }
}

private struct ThingDetailList<Item: Identifiable, RowContent: View>: View {
    let items: [Item]
    @ViewBuilder var row: (Item) -> RowContent

    var body: some View {
        VStack(spacing: 0) {
            ForEach(items.indices, id: \.self) { index in
                let item = items[index]
                row(item)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, EntityVisualTokens.listRowInsetVertical)
                if index != items.count - 1 {
                    AppInsetDivider()
                }
            }
        }
    }
}

private struct ThingImagePreviewItem: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

private struct ThingRelatedMessageRow: View {
    let message: ThingRelatedMessage

    var body: some View {
        VStack(alignment: .leading, spacing: EntityVisualTokens.stackSpacing) {
            HStack(alignment: .firstTextBaseline) {
                Text(message.title)
                    .font(.headline.weight(.semibold))
                    .lineLimit(2)
                Spacer(minLength: 8)
                Text(EntityDateFormatter.relativeText(message.happenedAt))
                    .font(.caption)
                    .foregroundStyle(Color.appTextSecondary)
            }

            if let summary = message.summary, !summary.isEmpty {
                Text(summary)
                    .font(.subheadline)
                    .foregroundStyle(Color.appTextSecondary)
                    .lineLimit(3)
            }
        }
    }
}

private struct ThingRelatedUpdateRow: View {
    let update: ThingRelatedUpdate

    private var operationTone: AppSemanticTone {
        switch update.operation.uppercased() {
        case "ARCHIVE":
            return thingStateTone("archived")
        case "DELETE":
            return thingStateTone("deleted")
        default:
            return thingStateTone("active")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: EntityVisualTokens.stackSpacing) {
            HStack(alignment: .firstTextBaseline) {
                Text(update.title)
                    .font(.headline.weight(.semibold))
                    .lineLimit(2)
                Spacer(minLength: 8)
                Text(EntityDateFormatter.relativeText(update.happenedAt))
                    .font(.caption)
                    .foregroundStyle(Color.appTextSecondary)
            }

            HStack(spacing: 8) {
                EntityStateBadge(text: update.operation.uppercased(), tone: operationTone)
                Text(EntityDateFormatter.text(update.happenedAt))
                    .font(.caption)
                    .foregroundStyle(Color.appTextSecondary)
                    .lineLimit(1)
            }

            if let summary = update.summary, !summary.isEmpty {
                Text(summary)
                    .font(.subheadline)
                    .foregroundStyle(Color.appTextSecondary)
                    .lineLimit(3)
            }
        }
    }
}

private struct ThingSecondaryDetailSheet<Content: View>: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(LocalizationManager.self) private var localizationManager: LocalizationManager

    @ViewBuilder let content: Content

    var body: some View {
        navigationContainer {
            content
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(localizationManager.localized("close")) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }
        }
    }
}

private struct ThingRelatedUpdateDetailScreen: View {
    @Environment(LocalizationManager.self) private var localizationManager: LocalizationManager

    let update: ThingRelatedUpdate

    private var operationTone: AppSemanticTone {
        switch update.operation.uppercased() {
        case "ARCHIVE":
            return thingStateTone("archived")
        case "DELETE":
            return thingStateTone("deleted")
        default:
            return thingStateTone("active")
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Text(update.title)
                        .font(.title3.weight(.semibold))
                        .lineLimit(2)
                    Spacer(minLength: 8)
                    EntityStateBadge(text: update.operation.uppercased(), tone: operationTone)
                }

                Label(EntityDateFormatter.text(update.happenedAt), systemImage: "clock")
                    .font(.caption)
                    .foregroundStyle(Color.appTextSecondary)

                if let state = update.state, !state.isEmpty {
                    Text(
                        String(
                            format: localizationManager.localized("State: %@"),
                            normalizedThingState(state)
                        )
                    )
                        .font(.caption)
                        .foregroundStyle(Color.appTextSecondary)
                }

                if let summary = update.summary, !summary.isEmpty {
                    Text(summary)
                        .font(.body)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
        .frame(minWidth: 520, minHeight: 420)
    }
}
