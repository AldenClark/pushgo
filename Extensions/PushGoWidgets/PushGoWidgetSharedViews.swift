import SwiftUI
import WidgetKit

struct PushGoWidgetEntry: TimelineEntry {
    let date: Date
    let snapshot: PushGoWidgetSnapshot
}

struct PushGoWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> PushGoWidgetEntry {
        PushGoWidgetEntry(date: Date(), snapshot: .empty)
    }

    func getSnapshot(in context: Context, completion: @escaping (PushGoWidgetEntry) -> Void) {
        completion(PushGoWidgetEntry(date: Date(), snapshot: PushGoWidgetSnapshotStore.load()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<PushGoWidgetEntry>) -> Void) {
        let entry = PushGoWidgetEntry(date: Date(), snapshot: PushGoWidgetSnapshotStore.load())
        completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(15 * 60))))
    }
}

struct PushGoWidgetPanel<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.caption.weight(.semibold))
                Text(title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            content
            Spacer(minLength: 0)
        }
        .containerBackground(.background, for: .widget)
    }
}

struct PushGoWidgetItemList: View {
    let items: [PushGoWidgetSnapshot.Item]
    let emptyTitle: String

    var body: some View {
        if items.isEmpty {
            Text(emptyTitle)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .minimumScaleFactor(0.8)
        } else {
            VStack(alignment: .leading, spacing: 5) {
                ForEach(items.prefix(3)) { item in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.title)
                            .font(.callout.weight(.medium))
                            .lineLimit(1)
                        if let subtitle = item.subtitle ?? item.status ?? item.severity {
                            Text(subtitle)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .accessibilityLabel(Text(item.accessibilityLabel))
                }
            }
        }
    }
}

struct PushGoWidgetCountBadge: View {
    let count: Int
    let label: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("\(count)")
                .font(.system(size: 34, weight: .bold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}
