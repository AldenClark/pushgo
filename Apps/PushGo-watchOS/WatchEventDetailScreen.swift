import SwiftUI

struct WatchEventDetailScreen: View {
    let event: WatchLightEvent

    @State private var previewImageURL: URL?

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text(event.title)
                        .font(.headline)
                        .lineLimit(2)
                    if let summary = event.summary, !summary.isEmpty {
                        Text(summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    HStack(spacing: 8) {
                        WatchEntityStateBadge(
                            text: normalizedWatchEventStatus(event.state) ?? localizedDefaultWatchCreatedEventStatus(),
                            color: watchEventStateColor(event.state)
                        )
                        if let severity = event.severity, !severity.isEmpty {
                            Text(severity)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text("Last updated: \(watchDateText(event.updatedAt))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }

            if let imageURL = event.imageURL {
                Section("Image") {
                    Button {
                        previewImageURL = imageURL
                    } label: {
                        AsyncImage(url: imageURL) { phase in
                            switch phase {
                            case let .success(image):
                                image
                                    .resizable()
                                    .scaledToFit()
                            default:
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(Color.secondary.opacity(0.2))
                                    .frame(height: 90)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .navigationTitle(event.title)
        .sheet(item: Binding(
            get: { previewImageURL.map(WatchEventImagePreviewItem.init) },
            set: { previewImageURL = $0?.url }
        )) { item in
            NavigationStack {
                ZStack {
                    Color.black.ignoresSafeArea()
                    AsyncImage(url: item.url) { phase in
                        switch phase {
                        case let .success(image):
                            image
                                .resizable()
                                .scaledToFit()
                        case .failure:
                            Image(systemName: "photo")
                                .foregroundStyle(.white)
                        default:
                            ProgressView().tint(.white)
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
