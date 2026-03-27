import SwiftUI

struct WatchThingDetailScreen: View {
    @Environment(LocalizationManager.self) private var localizationManager: LocalizationManager

    let thingId: String
    let viewModel: WatchLightStoreViewModel

    private var thing: WatchLightThing? {
        viewModel.thing(thingId: thingId)
    }

    var body: some View {
        List {
            if let thing {
                Section {
                    HStack(alignment: .top, spacing: 10) {
                        WatchEntityAvatar(url: thing.imageURL, size: 44)
                        VStack(alignment: .leading, spacing: WatchEntityVisualTokens.sectionSpacing) {
                            Text(thing.title)
                                .font(.headline)
                                .lineLimit(2)
                            if let summary = thing.summary, !summary.isEmpty {
                                Text(summary)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Text(watchDateText(thing.updatedAt))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, WatchEntityVisualTokens.rowVerticalPadding)
                }

                Section(localizationManager.localized("Attributes")) {
                    if let attrsJSON = thing.attrsJSON, !attrsJSON.isEmpty {
                        Text(attrsJSON)
                            .font(.system(.caption2, design: .monospaced))
                    } else {
                        Text(localizationManager.localized("No attributes"))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                Section {
                    WatchEntityMissingState()
                }
            }
        }
        .navigationTitle(thing?.title ?? "")
    }
}
