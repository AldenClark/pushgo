import SwiftUI
import WidgetKit

#if !os(watchOS)
struct PushGoCriticalEventWidget: Widget {
    let kind = "io.ethan.pushgo.widgets.critical-events"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: PushGoWidgetProvider()) { entry in
            PushGoCriticalEventWidgetView(entry: entry)
                .widgetURL(PushGoWidgetOpenTarget.list(kind: .event).url())
        }
        .configurationDisplayName("PushGo Critical Events")
        .description("Shows high priority PushGo events.")
        #if os(macOS)
        .supportedFamilies([.systemSmall, .systemMedium])
        #else
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular])
        #endif
    }
}

struct PushGoCriticalEventWidgetView: View {
    let entry: PushGoWidgetEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                Text("\(entry.snapshot.counts.criticalEvents)")
                    .font(.headline)
            }
        case .accessoryRectangular:
            VStack(alignment: .leading) {
                Text("Critical Events")
                Text("\(entry.snapshot.counts.criticalEvents) active")
            }
        default:
            PushGoWidgetPanel(title: "Critical Events", systemImage: "bolt.badge.exclamationmark") {
                PushGoWidgetCountBadge(count: entry.snapshot.counts.criticalEvents, label: "events")
                PushGoWidgetItemList(items: entry.snapshot.criticalEvents, emptyTitle: "No high priority events")
            }
            .padding()
        }
    }
}
#endif
