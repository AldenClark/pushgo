#if os(iOS)
import ActivityKit
import SwiftUI
import WidgetKit

struct PushGoEventLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: PushGoEventActivityAttributes.self) { context in
            PushGoLiveActivityView(
                title: context.state.title,
                subtitle: context.state.state ?? context.attributes.channelID ?? "Event",
                severity: context.state.severity
            )
            .widgetURL(eventURL(context.attributes.eventID))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Text(context.state.severity ?? "event")
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.state.state ?? "")
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text(context.state.title)
                        .lineLimit(2)
                }
            } compactLeading: {
                Image(systemName: "bolt.badge.exclamationmark")
            } compactTrailing: {
                Text(context.state.severity?.prefix(1).uppercased() ?? "E")
            } minimal: {
                Image(systemName: "bolt.badge.exclamationmark")
            }
            .widgetURL(eventURL(context.attributes.eventID))
        }
    }

    private func eventURL(_ eventID: String) -> URL? {
        PushGoWidgetOpenTarget(
            kind: .event,
            identifier: eventID,
            source: .widget,
            destination: .detail
        ).url()
    }
}

struct PushGoLiveActivityView: View {
    let title: String
    let subtitle: String
    let severity: String?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: severity == "critical" ? "exclamationmark.triangle.fill" : "bolt.badge.exclamationmark")
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding()
        .activityBackgroundTint(Color(.systemBackground))
        .activitySystemActionForegroundColor(.primary)
    }
}
#endif
