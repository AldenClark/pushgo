import SwiftUI

struct ThingDetailScreen: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(LocalizationManager.self) private var localizationManager: LocalizationManager

    let thing: ThingProjection
    var onDelete: (() -> Void)? = nil
    @State private var showDeleteConfirmation = false

    var body: some View {
        navigationContainer {
            ThingDetailPanel(thing: thing)
                .navigationTitle("")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { toolbarContent }
        }
        .pushgoSheetSizing(.detail)
        .accessibilityIdentifier("screen.things.detail")
        .alert(
            localizationManager.localized("are_you_sure_you_want_to_delete_this_message_once_deleted_it_cannot_be_recovered"),
            isPresented: $showDeleteConfirmation
        ) {
            Button(localizationManager.localized("delete"), role: .destructive) {
                onDelete?()
                dismiss()
            }
            Button(localizationManager.localized("cancel"), role: .cancel) {}
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .navigationBarTrailing) {
            Button(role: .destructive) {
                showDeleteConfirmation = true
            } label: {
                Image(systemName: "trash")
            }
            .accessibilityLabel(localizationManager.localized("delete"))
        }
    }
}

private struct ThingDetailPanel: View {
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
    @State private var previewImageURL: URL?
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

    private var stateColor: Color {
        thingStateColor(thing.state)
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

    private var lifecycleState: ThingLifecycleState {
        thingLifecycleState(from: thing.state)
    }

    private var lifecycleTimeLabel: String {
        switch lifecycleState {
        case .archived:
            return localizationManager.localized("Archived")
        case .deleted:
            return localizationManager.localized("Deleted")
        default:
            return localizationManager.localized("Updated")
        }
    }

    private var lifecycleTime: Date {
        if lifecycleState == .deleted, let deletedAt = thing.deletedAt {
            return deletedAt
        }
        return thing.updatedAt
    }

    private var lifecycleTimeIcon: String {
        switch lifecycleState {
        case .archived:
            return "archivebox"
        case .deleted:
            return "trash"
        default:
            return "arrow.triangle.2.circlepath"
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                basicInfoSection

                if !thing.tags.isEmpty {
                    ThingTagChipRow(tags: thing.tags)
                }

                if let summary = thing.summary, !summary.isEmpty {
                    Text(summary)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if !secondaryImageURLs.isEmpty {
                    ThingAttachmentImageStrip(
                        urls: secondaryImageURLs,
                        onTap: { previewImageURL = $0 }
                    )
                }

                Divider()

                Picker("", selection: $selectedTab) {
                    ForEach(Tab.allCases) { tab in
                        Text(localizationManager.localized(tab.titleKey)).tag(tab)
                    }
                }
                .pickerStyle(.segmented)

                tabSection
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 18)
        }
        .background(EntityVisualTokens.pageBackground)
        .pushgoImagePreviewOverlay(previewItem: Binding(
            get: { previewImageURL.map(ThingImagePreviewItem.init) },
            set: { previewImageURL = $0?.url }
        ), imageURL: \.url)
        .sheet(item: $selectedEvent) { event in
            EventDetailScreen(event: event)
        }
        .sheet(item: $selectedMessage) { message in
            MessageDetailScreen(messageId: message.id, message: nil)
                .pushgoSheetSizing(.detail)
        }
        .sheet(item: $selectedUpdate) { update in
            ThingRelatedUpdateDetailScreen(update: update)
                .pushgoSheetSizing(.detail)
        }
        .sheet(isPresented: $showMetadataSheet) {
            ThingMetadataSheet(
                title: localizationManager.localized("metadata"),
                entries: metadataEntries
            )
            .pushgoSheetSizing(.detail)
        }
    }

    private var basicInfoSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                Button {
                    if let primaryImageURL {
                        previewImageURL = primaryImageURL
                    }
                } label: {
                    EntityThumbnail(
                        url: primaryImageURL,
                        size: 88,
                        placeholderSystemImage: "cube.box",
                        showsBorder: false
                    )
                }
                .buttonStyle(.plain)
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(thing.title)
                            .font(.title3.weight(.semibold))
                            .lineLimit(2)
                        if lifecycleState == .archived {
                            EntityStateBadge(text: stateLabel, color: stateColor)
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
                                        .fill(Color(uiColor: .secondarySystemFill))
                                )
                                .overlay(
                                    Capsule(style: .continuous)
                                        .stroke(Color(uiColor: .separator).opacity(0.28), lineWidth: 0.8)
                                )
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(localizationManager.localized("thing_detail_metadata_button"))
                    }
                }
            }

            if !attrsEntries.isEmpty {
                ThingAttributeStateGrid(entries: attrsEntries)
            } else if let attrsJSON = thing.attrsJSON,
                      !attrsJSON.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                EntityCodeBlock(text: attrsJSON)
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
            .foregroundStyle(.secondary)

            if let locationSummary {
                Label(locationSummary, systemImage: "mappin.and.ellipse")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(urls, id: \.absoluteString) { url in
                    Button {
                        onTap(url)
                    } label: {
                        RemoteImageView(url: url, rendition: .listThumbnail) { image in
                            image
                                .resizable()
                                .scaledToFill()
                        } placeholder: {
                            Rectangle()
                                .fill(Color(uiColor: .secondarySystemBackground))
                        }
                        .frame(width: 88, height: 88)
                        .clipShape(RoundedRectangle(cornerRadius: EntityVisualTokens.radiusSmall, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

private struct ThingTagChipRow: View {
    let tags: [String]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(tags.enumerated()), id: \.offset) { _, tag in
                    EntityMetaChip(systemImage: "tag", text: tag)
                }
            }
        }
    }
}

private struct ThingAttributeStateGrid: View {
    private let columns = [
        GridItem(.flexible(minimum: 120), spacing: 8, alignment: .leading),
        GridItem(.flexible(minimum: 120), spacing: 8, alignment: .leading)
    ]

    let entries: [EntityDisplayAttribute]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
            ForEach(entries) { entry in
                ThingAttributeStateCard(entry: entry)
            }
        }
    }
}

private struct ThingAttributeStateCard: View {
    let entry: EntityDisplayAttribute

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(entry.displayLabel)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(entry.value)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 9)
        .padding(.vertical, 8)
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
    @Environment(\.dismiss) private var dismiss
    @Environment(LocalizationManager.self) private var localizationManager: LocalizationManager
    let title: String
    let entries: [EntityDisplayAttribute]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if entries.isEmpty {
                        Text(localizationManager.localized("thing_detail_no_metadata"))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        EntityKeyValueRows(entries: entries)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 20)
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(localizationManager.localized("Done")) { dismiss() }
                }
            }
        }
    }
}

private struct ThingDetailList<Item: Identifiable, RowContent: View>: View {
    let items: [Item]
    @ViewBuilder var row: (Item) -> RowContent

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                row(item)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, EntityVisualTokens.listRowInsetVertical)
                if index != items.count - 1 {
                    Divider()
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
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(message.title)
                    .font(.headline.weight(.semibold))
                    .lineLimit(2)
                Spacer(minLength: 8)
                Text(EntityDateFormatter.relativeText(message.happenedAt))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let summary = message.summary, !summary.isEmpty {
                Text(summary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
        }
    }
}

private struct ThingRelatedUpdateRow: View {
    let update: ThingRelatedUpdate

    private var operationColor: Color {
        switch update.operation.uppercased() {
        case "ARCHIVE":
            return thingStateColor("archived")
        case "DELETE":
            return thingStateColor("deleted")
        default:
            return thingStateColor("active")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: EntityVisualTokens.stackSpacing) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(update.title)
                    .font(.headline.weight(.semibold))
                    .lineLimit(2)
                Spacer(minLength: 8)
                Text(EntityDateFormatter.relativeText(update.happenedAt))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                EntityStateBadge(text: update.operation.uppercased(), color: operationColor)
                Text(EntityDateFormatter.text(update.happenedAt))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            if let summary = update.summary, !summary.isEmpty {
                Text(summary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
        }
    }
}

private struct ThingRelatedUpdateDetailScreen: View {
    @Environment(LocalizationManager.self) private var localizationManager: LocalizationManager

    let update: ThingRelatedUpdate

    private var operationColor: Color {
        switch update.operation.uppercased() {
        case "ARCHIVE":
            return thingStateColor("archived")
        case "DELETE":
            return thingStateColor("deleted")
        default:
            return thingStateColor("active")
        }
    }

    var body: some View {
        navigationContainer {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(update.title)
                            .font(.title3.weight(.semibold))
                            .lineLimit(2)
                        Spacer(minLength: 8)
                        EntityStateBadge(text: update.operation.uppercased(), color: operationColor)
                    }

                    Label(EntityDateFormatter.text(update.happenedAt), systemImage: "clock")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if let state = update.state, !state.isEmpty {
                        Text(
                            String(
                                format: localizationManager.localized("State: %@"),
                                normalizedThingState(state)
                            )
                        )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if let summary = update.summary, !summary.isEmpty {
                        Text(summary)
                            .font(.body)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 18)
            }
        }
    }
}
