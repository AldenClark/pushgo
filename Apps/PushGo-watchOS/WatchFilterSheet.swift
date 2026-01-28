import SwiftUI

struct WatchFilterSheet: View {
    @Environment(\.appEnvironment) private var environment: AppEnvironment
    @Environment(LocalizationManager.self) private var localizationManager: LocalizationManager
    let selectedChannel: MessageChannelKey?
    let channelSummaries: [MessageChannelSummary]
    let onSelectChannel: (MessageChannelKey) -> Void
    let onClearChannel: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Section(localizationManager.localized("channel")) {
                    Button {
                        onClearChannel()
                    } label: {
                        HStack {
                            Text(localizationManager.localized("all"))
                            Spacer()
                            if selectedChannel == nil {
                                Image(systemName: "checkmark")
                                    .foregroundColor(.accentColor)
                            }
                        }
                    }

                    ForEach(channelSummaries) { summary in
                        Button {
                            onSelectChannel(summary.key)
                        } label: {
                            HStack {
                                Text(resolvedChannelDisplayName(for: summary.key) ?? summary.title)
                                Spacer()
                                if selectedChannel == summary.key {
                                    Image(systemName: "checkmark")
                                        .foregroundColor(.accentColor)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle(localizationManager.localized("filter"))
        }
    }

    private func resolvedChannelDisplayName(for channel: MessageChannelKey?) -> String? {
        guard let channel else { return nil }
        guard let channelId = channel.rawChannelValue else { return nil }
        if channelId == "" {
            return localizationManager.localized("not_grouped")
        }
        let displayName = environment.channelDisplayName(for: channelId) ?? channel.displayName
        if displayName == channelId {
            return channelId
        }
        return "\(displayName) (\(channelId))"
    }
}

#Preview {
    WatchFilterSheet(
        selectedChannel: nil,
        channelSummaries: [],
        onSelectChannel: { _ in },
        onClearChannel: {}
    )
}
