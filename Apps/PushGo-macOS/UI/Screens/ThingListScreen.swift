import SwiftUI

struct ThingListScreen: View {
    @Environment(LocalizationManager.self) private var localizationManager: LocalizationManager

    private enum Layout {
        static let rowInsets = EdgeInsets(
            top: EntityVisualTokens.listRowInsetVertical,
            leading: EntityVisualTokens.listRowInsetHorizontal,
            bottom: EntityVisualTokens.listRowInsetVertical,
            trailing: EntityVisualTokens.listRowInsetHorizontal
        )
    }

    let things: [ThingProjection]
    @Binding var selection: String?
    @Binding var batchSelection: Set<String>
    @Binding var isBatchMode: Bool
    var isLoadingMore: Bool = false
    var onReachEnd: (() -> Void)? = nil

    var body: some View {
        Group {
            if things.isEmpty {
                EntityEmptyView(
                    iconName: "shippingbox",
                    title: localizationManager.localized("things_empty_title"),
                    subtitle: localizationManager.localized("things_empty_hint")
                )
            } else if isBatchMode {
                List {
                    ForEach(Array(things.enumerated()), id: \.element.id) { index, thing in
                        Button {
                            toggleBatchSelection(thing.id)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: batchSelection.contains(thing.id) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(batchSelection.contains(thing.id) ? .accent : .secondary)
                                ThingListRow(thing: thing)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("thing.row.\(thing.id)")
                        .listRowInsets(Layout.rowInsets)
                        .alignmentGuide(.listRowSeparatorLeading) { dimensions in
                            dimensions[.leading]
                        }
                        .alignmentGuide(.listRowSeparatorTrailing) { dimensions in
                            dimensions[.trailing] - Layout.rowInsets.trailing
                        }
                        .listRowBackground(Color.clear)
                        .listRowSeparator(index == 0 ? .hidden : .visible, edges: .top)
                        .listRowSeparator(index == things.count - 1 ? .hidden : .visible, edges: .bottom)
                        .onAppear {
                            guard index == things.count - 1 else { return }
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
                List(selection: $selection) {
                    ForEach(Array(things.enumerated()), id: \.element.id) { index, thing in
                        ThingListRow(thing: thing)
                            .accessibilityIdentifier("thing.row.\(thing.id)")
                            .tag(thing.id)
                            .listRowInsets(Layout.rowInsets)
                            .alignmentGuide(.listRowSeparatorLeading) { dimensions in
                                dimensions[.leading]
                            }
                            .alignmentGuide(.listRowSeparatorTrailing) { dimensions in
                                dimensions[.trailing] - Layout.rowInsets.trailing
                            }
                            .listRowBackground(Color.clear)
                            .listRowSeparator(index == 0 ? .hidden : .visible, edges: .top)
                            .listRowSeparator(index == things.count - 1 ? .hidden : .visible, edges: .bottom)
                            .onAppear {
                                guard index == things.count - 1 else { return }
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
        .accessibilityIdentifier("screen.things.list")
    }

    private func toggleBatchSelection(_ thingId: String) {
        if batchSelection.contains(thingId) {
            batchSelection.remove(thingId)
        } else {
            batchSelection.insert(thingId)
        }
    }
}

private struct ThingListRow: View {
    private enum Layout {
        static let primaryImageSize: CGFloat = 46
        static let attachmentImageSize: CGFloat = 42
        static let attachmentImageSpacing: CGFloat = 6
        static let attachmentPreviewFallback: Int = 4
    }

    let thing: ThingProjection

    private var primaryImageURL: URL? {
        thing.imageURL
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
            HStack(alignment: .top, spacing: EntityVisualTokens.stackSpacing) {
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
                            .foregroundStyle(.secondary)
                    }

                    ThingMetadataSummary(entries: metadataEntries, fallbackText: metadataFallbackText)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if !thing.tags.isEmpty {
                Text(thing.tags.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
                                .foregroundStyle(.secondary)
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
            .foregroundStyle(.secondary)
            .lineLimit(2)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if let fallbackText, !fallbackText.isEmpty {
            Text(fallbackText)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}
