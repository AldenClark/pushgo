import SwiftUI

struct WatchEventDetailScreen: View {
    let eventId: String
    let viewModel: WatchLightStoreViewModel

    @State private var previewImageItem: WatchEventImagePreviewItem?

    private var event: WatchLightEvent? {
        viewModel.event(eventId: eventId)
    }

    var body: some View {
        List {
            if let event {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(event.title)
                            .font(.headline)
                            .lineLimit(2)
                        if let summary = event.summary, !summary.isEmpty {
                            Text(summary)
                                .font(.caption)
                                .foregroundStyle(Color.appTextSecondary)
                        }
                        HStack(spacing: 8) {
                            WatchEntityStateBadge(
                                text: normalizedWatchEventStatus(event.state) ?? localizedDefaultWatchCreatedEventStatus(),
                                tone: watchEventStateTone(event.state)
                            )
                            if let severity = event.severity, !severity.isEmpty {
                                Text(severity)
                                    .font(.caption2)
                                    .foregroundStyle(Color.appTextSecondary)
                            }
                            if let decryptText = watchDecryptionStateText(event.decryptionState) {
                                WatchEntityStateBadge(
                                    text: decryptText,
                                    tone: watchDecryptionStateTone(event.decryptionState)
                                )
                            }
                        }
                        Text(
                            String(
                                format: LocalizationManager.shared.localized("last_updated_placeholder"),
                                watchDateText(event.updatedAt)
                            )
                        )
                            .font(.caption2)
                            .foregroundStyle(Color.appTextSecondary)
                    }
                    .padding(.vertical, 4)
                }

                if let imageURL = event.imageURL {
                    Section(LocalizationManager.shared.localized("image")) {
                        WatchCachedImage(
                            url: imageURL,
                            accessibilityLabel: LocalizationManager.shared.localized("image")
                        ) { phase in
                            switch phase {
                            case let .success(image):
                                Button {
                                    previewImageItem = WatchEventImagePreviewItem(url: imageURL)
                                } label: {
                                    image
                                        .resizable()
                                        .scaledToFit()
                                        .frame(height: 90)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(LocalizationManager.shared.localized("image"))
                                .accessibilityIdentifier("image.event.\(event.eventId)")
                            case .empty, .failure:
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(Color.appSurfaceSunken)
                                    .frame(height: 90)
                            }
                        }
                    }
                }
            } else {
                Section {
                    WatchEntityMissingState()
                }
            }
        }
        .accessibilityIdentifier("screen.event.detail")
        .navigationTitle(event?.title ?? "")
        .sheet(item: $previewImageItem) { item in
            NavigationStack {
                ZStack {
                    Color.appImagePreviewScrim.ignoresSafeArea()
                    WatchCachedImage(
                        url: item.url,
                        accessibilityLabel: LocalizationManager.shared.localized("image")
                    ) { phase in
                        switch phase {
                        case let .success(image):
                            image
                                .resizable()
                                .scaledToFit()
                                .accessibilityElement()
                                .accessibilityLabel(LocalizationManager.shared.localized("image"))
                                .accessibilityIdentifier("image.event.preview")
                        case .failure:
                            Image(systemName: "photo")
                                .foregroundStyle(Color.appOverlayForeground)
                        case .empty:
                            ProgressView().tint(Color.appOverlayForeground)
                        }
                    }
                    .padding(8)
                }
            }
        }
    }
}

private struct WatchEventImagePreviewItem: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}
