import SwiftUI
import WidgetKit

#if os(watchOS)
struct PushGoWatchComplicationWidget: Widget {
    let kind = "io.ethan.pushgo.widgets.watch-summary"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: PushGoWidgetProvider()) { entry in
            PushGoWatchComplicationView(entry: entry)
                .widgetURL(watchURL(for: entry.snapshot))
        }
        .configurationDisplayName("PushGo Summary")
        .description("Shows unread messages and priority events.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline])
        .pushHandler(PushGoWidgetPushHandler.self)
    }

    private func watchURL(for snapshot: PushGoWidgetSnapshot) -> URL? {
        if let target = snapshot.criticalEvents.first?.openTarget {
            return target.url()
        }
        if let target = snapshot.unreadMessages.first?.openTarget {
            return target.url()
        }
        if let target = snapshot.objectWarnings.first?.openTarget {
            return target.url()
        }
        return PushGoWidgetOpenTarget.list(kind: .message).url()
    }
}

struct PushGoWatchComplicationView: View {
    let entry: PushGoWidgetEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        case .accessoryInline:
            Text("PushGo \(entry.snapshot.counts.unreadMessages) unread")
        case .accessoryRectangular:
            VStack(alignment: .leading) {
                Text("PushGo")
                Text("\(entry.snapshot.counts.unreadMessages) unread, \(entry.snapshot.counts.criticalEvents) critical")
            }
        default:
            ZStack {
                AccessoryWidgetBackground()
                VStack(spacing: 0) {
                    Image(systemName: "bell.badge")
                    Text("\(entry.snapshot.counts.unreadMessages)")
                }
            }
        }
    }
}
#endif
