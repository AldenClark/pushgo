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
                                    .foregroundStyle(Color.appTextSecondary)
                            }
                            if let decryptText = watchDecryptionStateText(thing.decryptionState) {
                                WatchEntityStateBadge(
                                    text: decryptText,
                                    tone: watchDecryptionStateTone(thing.decryptionState)
                                )
                            }
                            Text(watchDateText(thing.updatedAt))
                                .font(.caption2)
                                .foregroundStyle(Color.appTextSecondary)
                        }
                    }
                    .padding(.vertical, WatchEntityVisualTokens.rowVerticalPadding)
                }

                Section(localizationManager.localized("attributes")) {
                    let attributes = parseWatchEntityAttributes(from: thing.attrsJSON)
                    if !attributes.isEmpty {
                        ForEach(attributes) { attribute in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(attribute.displayLabel)
                                    .font(.caption2)
                                    .foregroundStyle(Color.appTextSecondary)
                                Text(attribute.value)
                                    .font(.footnote)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    } else {
                        Text(localizationManager.localized("no_attributes"))
                            .font(.footnote)
                            .foregroundStyle(Color.appTextSecondary)
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
