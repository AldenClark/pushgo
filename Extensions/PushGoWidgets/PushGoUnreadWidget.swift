import SwiftUI
import WidgetKit

#if !os(watchOS)
struct PushGoUnreadWidget: Widget {
    let kind = "io.ethan.pushgo.widgets.unread"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: PushGoWidgetProvider()) { entry in
            PushGoUnreadWidgetView(entry: entry)
                .widgetURL(PushGoWidgetOpenTarget.list(kind: .message).url())
        }
        .configurationDisplayName("PushGo Unread")
        .description("Shows unread PushGo messages.")
        #if os(macOS)
        .supportedFamilies([.systemSmall, .systemMedium])
        #else
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular])
        #endif
    }
}

struct PushGoUnreadWidgetView: View {
    let entry: PushGoWidgetEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        case .accessoryCircular:
            Gauge(value: Double(entry.snapshot.counts.unreadMessages), in: 0...max(1, Double(entry.snapshot.counts.totalMessages))) {
                Image(systemName: "envelope.badge")
            } currentValueLabel: {
                Text("\(entry.snapshot.counts.unreadMessages)")
            }
        case .accessoryRectangular:
            VStack(alignment: .leading) {
                Text("Unread")
                Text("\(entry.snapshot.counts.unreadMessages) messages")
            }
        default:
            PushGoWidgetPanel(title: "Unread", systemImage: "envelope.badge") {
                PushGoWidgetCountBadge(count: entry.snapshot.counts.unreadMessages, label: "unread")
                PushGoWidgetItemList(items: entry.snapshot.unreadMessages, emptyTitle: "No unread messages")
            }
            .padding()
        }
    }
}
#endif
