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
        .contentMarginsDisabled()
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
            PushGoUnreadWidgetContent(
                unreadCount: entry.snapshot.counts.unreadMessages,
                messages: entry.snapshot.unreadMessages,
                family: family
            )
        }
    }
}

private struct PushGoUnreadWidgetContent: View {
    let unreadCount: Int
    let messages: [PushGoWidgetSnapshot.Item]
    let family: WidgetFamily
    @Environment(\.widgetContentMargins) private var contentMargins

    private var displayedMessages: ArraySlice<PushGoWidgetSnapshot.Item> {
        messages.prefix(3)
    }

    private var foregroundInsets: PushGoWidgetHorizontalInsets {
        PushGoWidgetHorizontalInsets(contentMargins: contentMargins)
    }

    var body: some View {
        GeometryReader { proxy in
            VStack(spacing: 0) {
                PushGoUnreadWidgetHeader(
                    unreadCount: unreadCount,
                    insets: foregroundInsets
                )
                PushGoUnreadWidgetDottedDivider()
                if family == .systemSmall {
                    PushGoUnreadWidgetCountOnly(unreadCount: unreadCount)
                } else {
                    PushGoUnreadWidgetMessageList(
                        messages: displayedMessages,
                        insets: foregroundInsets
                    )
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
        }
        .containerBackground(for: .widget) {
            PushGoWidgetSurfaceColors.contentBackground
        }
        .accessibilityElement(children: .contain)
    }
}

private struct PushGoUnreadWidgetHeader: View {
    let unreadCount: Int
    let insets: PushGoWidgetHorizontalInsets

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "tray.full")
                .font(.system(size: 14, weight: .semibold))
            Text("PushGo")
                .font(.system(size: 15, weight: .semibold))
                .lineLimit(1)
            Spacer(minLength: 8)
            Text("\(unreadCount)")
                .font(.system(size: 15, weight: .semibold, design: .rounded).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .accessibilityLabel(Text("\(unreadCount) unread messages"))
        }
        .foregroundStyle(.white)
        .padding(.leading, insets.leading)
        .padding(.trailing, insets.trailing)
        .frame(maxWidth: .infinity)
        .frame(height: 40)
        .background(PushGoWidgetSurfaceColors.accent)
    }
}

private struct PushGoUnreadWidgetDottedDivider: View {
    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<48, id: \.self) { _ in
                Circle()
                    .fill(Color.black.opacity(0.12))
                    .frame(width: 3, height: 3)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 13)
        .padding(.horizontal, 6)
        .clipped()
        .background(PushGoWidgetSurfaceColors.contentBackground)
    }
}

private struct PushGoUnreadWidgetCountOnly: View {
    let unreadCount: Int

    var body: some View {
        VStack(spacing: 3) {
            Text("\(unreadCount)")
                .font(.system(size: 40, weight: .semibold, design: .rounded).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text("unread")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(PushGoWidgetSurfaceColors.contentBackground)
        .accessibilityLabel(Text("\(unreadCount) unread messages"))
    }
}

private struct PushGoUnreadWidgetMessageList: View {
    let messages: ArraySlice<PushGoWidgetSnapshot.Item>
    let insets: PushGoWidgetHorizontalInsets

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if messages.isEmpty {
                Text("No unread messages")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.82)
                    .padding(.leading, insets.leading)
                    .padding(.trailing, insets.trailing)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(.top, 8)
            } else {
                ForEach(Array(messages.enumerated()), id: \.element.id) { index, message in
                    PushGoUnreadWidgetMessageRow(
                        title: message.title,
                        accessibilityLabel: message.accessibilityLabel,
                        insets: insets
                    )
                    if index < messages.count - 1 {
                        Divider()
                            .padding(.leading, insets.leading)
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .background(PushGoWidgetSurfaceColors.contentBackground)
    }
}

private struct PushGoUnreadWidgetMessageRow: View {
    let title: String
    let accessibilityLabel: String
    let insets: PushGoWidgetHorizontalInsets

    var body: some View {
        Text(title)
            .font(.system(size: 13))
            .foregroundStyle(.primary)
            .lineLimit(1)
            .minimumScaleFactor(0.86)
            .allowsTightening(true)
            .truncationMode(.tail)
            .padding(.leading, insets.leading)
            .padding(.trailing, insets.trailing)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 35)
            .accessibilityLabel(Text(accessibilityLabel))
    }
}

#endif
