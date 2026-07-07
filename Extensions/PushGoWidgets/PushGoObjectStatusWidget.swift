import SwiftUI
import WidgetKit

#if !os(watchOS)
struct PushGoObjectStatusWidget: Widget {
    let kind = "io.ethan.pushgo.widgets.object-status"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: PushGoWidgetProvider()) { entry in
            PushGoObjectStatusWidgetView(entry: entry)
                .widgetURL(PushGoWidgetOpenTarget.list(kind: .thing).url())
        }
        .configurationDisplayName("PushGo Object Status")
        .description("Shows PushGo objects that need attention.")
        #if os(macOS)
        .supportedFamilies([.systemSmall, .systemMedium])
        #else
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular])
        #endif
        .contentMarginsDisabled()
        .pushHandler(PushGoWidgetPushHandler.self)
    }
}

struct PushGoObjectStatusWidgetView: View {
    let entry: PushGoWidgetEntry
    @Environment(\.widgetFamily) private var family

    var objectItems: [PushGoWidgetSnapshot.Item] {
        entry.snapshot.objectWarnings.isEmpty ? entry.snapshot.latestObjectStates : entry.snapshot.objectWarnings
    }

    var body: some View {
        switch family {
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                Text("\(entry.snapshot.counts.objectWarnings)")
                    .font(.headline)
            }
        case .accessoryRectangular:
            VStack(alignment: .leading) {
                Text("Objects")
                Text("\(entry.snapshot.counts.objectWarnings) need attention")
            }
        default:
            PushGoWidgetSystemListPanel(
                title: "Objects",
                systemImage: "shippingbox",
                count: entry.snapshot.counts.objectWarnings,
                countLabel: "warnings",
                items: objectItems,
                emptyTitle: "No object warnings"
            )
        }
    }
}
#endif
