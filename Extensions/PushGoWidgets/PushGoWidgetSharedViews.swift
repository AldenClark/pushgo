import SwiftUI
import WidgetKit
#if os(iOS)
import UIKit
#endif
#if os(macOS)
import AppKit
#endif

struct PushGoWidgetEntry: TimelineEntry {
    let date: Date
    let snapshot: PushGoWidgetSnapshot
}

struct PushGoWidgetProvider: TimelineProvider {
    private static let refreshInterval: TimeInterval = 60

    func placeholder(in context: Context) -> PushGoWidgetEntry {
        PushGoWidgetEntry(date: Date(), snapshot: .empty)
    }

    func getSnapshot(in context: Context, completion: @escaping (PushGoWidgetEntry) -> Void) {
        completion(PushGoWidgetEntry(date: Date(), snapshot: PushGoWidgetSnapshotStore.load()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<PushGoWidgetEntry>) -> Void) {
        let entry = PushGoWidgetEntry(date: Date(), snapshot: PushGoWidgetSnapshotStore.load())
        completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(Self.refreshInterval))))
    }
}

#if !os(watchOS)
struct PushGoWidgetSystemListPanel: View {
    let title: String
    let systemImage: String
    let count: Int
    let countLabel: String
    let items: [PushGoWidgetSnapshot.Item]
    let emptyTitle: String
    @Environment(\.widgetContentMargins) private var contentMargins
    @Environment(\.widgetFamily) private var family

    private var displayedItems: ArraySlice<PushGoWidgetSnapshot.Item> {
        items.prefix(3)
    }

    private var foregroundInsets: PushGoWidgetHorizontalInsets {
        PushGoWidgetHorizontalInsets(contentMargins: contentMargins)
    }

    var body: some View {
        GeometryReader { proxy in
            VStack(spacing: 0) {
                PushGoWidgetPanelHeader(
                    title: title,
                    systemImage: systemImage,
                    count: count,
                    insets: foregroundInsets
                )
                PushGoWidgetDottedDivider()
                if family == .systemSmall {
                    PushGoWidgetCountOnly(count: count, label: countLabel)
                } else {
                    PushGoWidgetPanelItemList(
                        items: displayedItems,
                        emptyTitle: emptyTitle,
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

private struct PushGoWidgetPanelHeader: View {
    let title: String
    let systemImage: String
    let count: Int
    let insets: PushGoWidgetHorizontalInsets

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .semibold))
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Spacer(minLength: 8)
            Text("\(count)")
                .font(.system(size: 15, weight: .semibold, design: .rounded).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .foregroundStyle(.white)
        .padding(.leading, insets.leading)
        .padding(.trailing, insets.trailing)
        .frame(maxWidth: .infinity)
        .frame(height: 40)
        .background(PushGoWidgetSurfaceColors.accent)
    }
}

private struct PushGoWidgetDottedDivider: View {
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

private struct PushGoWidgetCountOnly: View {
    let count: Int
    let label: String

    var body: some View {
        VStack(spacing: 3) {
            Text("\(count)")
                .font(.system(size: 40, weight: .semibold, design: .rounded).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(PushGoWidgetSurfaceColors.contentBackground)
        .accessibilityElement(children: .combine)
    }
}

private struct PushGoWidgetPanelItemList: View {
    let items: ArraySlice<PushGoWidgetSnapshot.Item>
    let emptyTitle: String
    let insets: PushGoWidgetHorizontalInsets

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if items.isEmpty {
                Text(emptyTitle)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.82)
                    .padding(.leading, insets.leading)
                    .padding(.trailing, insets.trailing)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(.top, 8)
            } else {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    PushGoWidgetPanelItemRow(
                        title: item.title,
                        accessibilityLabel: item.accessibilityLabel,
                        insets: insets
                    )
                    if index < items.count - 1 {
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

private struct PushGoWidgetPanelItemRow: View {
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

struct PushGoWidgetHorizontalInsets {
    let leading: CGFloat
    let trailing: CGFloat

    init(contentMargins: EdgeInsets) {
        leading = max(contentMargins.leading, 16)
        trailing = max(contentMargins.trailing, 16)
    }
}

enum PushGoWidgetSurfaceColors {
    #if os(macOS)
    static let accent = Color(nsColor: NSColor(name: nil) { appearance in
        switch appearance.bestMatch(from: [.aqua, .darkAqua]) {
        case .darkAqua:
            return NSColor(srgbRed: 168.0 / 255.0, green: 199.0 / 255.0, blue: 250.0 / 255.0, alpha: 1)
        default:
            return NSColor(srgbRed: 11.0 / 255.0, green: 87.0 / 255.0, blue: 208.0 / 255.0, alpha: 1)
        }
    })
    static let contentBackground = Color(NSColor.windowBackgroundColor)
    #elseif os(iOS)
    static let accent = Color(uiColor: UIColor { traits in
        switch traits.userInterfaceStyle {
        case .dark:
            return UIColor(red: 168.0 / 255.0, green: 199.0 / 255.0, blue: 250.0 / 255.0, alpha: 1)
        default:
            return UIColor(red: 11.0 / 255.0, green: 87.0 / 255.0, blue: 208.0 / 255.0, alpha: 1)
        }
    })
    static let contentBackground = Color(.systemBackground)
    #else
    static let accent = Color(red: 11.0 / 255.0, green: 87.0 / 255.0, blue: 208.0 / 255.0)
    static let contentBackground = Color.clear
    #endif
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
