import Foundation
import SwiftUI

enum EntityVisualTokens {
    static let pageBackground = Color(uiColor: .systemBackground)
    static let secondarySurface = Color(uiColor: .secondarySystemBackground)
    static let tertiarySurface = Color(uiColor: .tertiarySystemBackground)
    static let subtleFill = Color.primary.opacity(0.04)
    static let subtleFillSoft = Color.primary.opacity(0.02)
    static let subtleStroke = Color.primary.opacity(0.08)
    static let subtleStrokeStrong = Color.primary.opacity(0.1)
    static let chipFillSelected = Color.primary.opacity(0.12)
    static let chipFillUnselected = Color.primary.opacity(0.06)

    static let listRowInsetHorizontal: CGFloat = 12
    static let listRowInsetVertical: CGFloat = 10
    static let rowVerticalPadding: CGFloat = 6
    static let stackSpacing: CGFloat = 10
    static let detailSectionSpacing: CGFloat = 16
    static let detailPaddingHorizontal: CGFloat = 16
    static let detailPaddingVertical: CGFloat = 16
    static let chipPaddingVertical: CGFloat = 6

    static let radiusSmall: CGFloat = 10
    static let radiusMedium: CGFloat = 12
    static let radiusLarge: CGFloat = 16
}

struct EntityThumbnail: View {
    let url: URL?
    var size: CGFloat = 44
    var placeholderSystemImage: String = "cube.fill"
    var showsBorder: Bool = true

    var body: some View {
        RemoteImageView(url: url, rendition: .listThumbnail) { image in
            image
                .resizable()
                .scaledToFill()
        } placeholder: {
            ZStack {
                RoundedRectangle(cornerRadius: EntityVisualTokens.radiusSmall, style: .continuous)
                    .fill(EntityVisualTokens.secondarySurface)
                Image(systemName: placeholderSystemImage)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: EntityVisualTokens.radiusSmall, style: .continuous))
        .overlay {
            if showsBorder {
                RoundedRectangle(cornerRadius: EntityVisualTokens.radiusSmall, style: .continuous)
                    .stroke(EntityVisualTokens.subtleStrokeStrong, lineWidth: 0.8)
            }
        }
    }
}

struct EntityStateBadge: View {
    let text: String
    var color: Color = .accentColor

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule(style: .continuous)
                    .fill(color.opacity(0.14))
            )
            .foregroundStyle(color)
    }
}

struct EntityInlineAlert: View {
    let text: String
    var systemImage: String = "exclamationmark.circle.fill"
    var tint: Color = .orange

    var body: some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: systemImage)
                .font(.caption)
                .foregroundStyle(tint.opacity(0.7))
                .padding(.top, 1)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 1)
    }
}

struct EntityMetaChip: View {
    let systemImage: String
    let text: String
    var color: Color = .secondary

    var body: some View {
        Label {
            Text(text)
                .lineLimit(1)
        } icon: {
            Image(systemName: systemImage)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            Capsule(style: .continuous)
                .fill(EntityVisualTokens.tertiarySurface)
        )
    }
}

struct EntityCard<Content: View>: View {
    let tint: Color
    let content: Content

    init(tint: Color, @ViewBuilder content: () -> Content) {
        self.tint = tint
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            content
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: EntityVisualTokens.radiusLarge, style: .continuous)
                .fill(EntityVisualTokens.secondarySurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: EntityVisualTokens.radiusLarge, style: .continuous)
                .stroke(EntityVisualTokens.subtleStroke, lineWidth: 0.8)
        )
    }
}

struct EntityTimelineMarker: View {
    let color: Color
    let isFirst: Bool
    let isLast: Bool

    var body: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(isFirst ? Color.clear : Color.secondary.opacity(0.32))
                .frame(width: 2)
            Circle()
                .fill(Color.primary.opacity(0.72))
                .frame(width: 10, height: 10)
                .overlay(
                    Circle()
                        .stroke(Color(uiColor: .systemBackground), lineWidth: 2)
                )
            Rectangle()
                .fill(isLast ? Color.clear : Color.secondary.opacity(0.32))
                .frame(width: 2)
        }
        .frame(width: 14)
    }
}

struct EntityDisplayAttribute: Identifiable, Hashable {
    let key: String
    let label: String
    let value: String

    var displayLabel: String {
        label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? key : label
    }

    var id: String { "\(key):\(label):\(value)" }
}

struct EntityKeyValueRows: View {
    let entries: [EntityDisplayAttribute]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                Text("\(entry.displayLabel) - \(entry.value)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(.vertical, EntityVisualTokens.rowVerticalPadding)
                if index < entries.count - 1 {
                    Divider()
                        .opacity(0.55)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: EntityVisualTokens.radiusMedium, style: .continuous)
                .fill(EntityVisualTokens.subtleFill)
        )
    }
}

struct EntityCodeBlock: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(.footnote, design: .monospaced))
            .foregroundStyle(.secondary)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: EntityVisualTokens.radiusMedium, style: .continuous)
                    .fill(EntityVisualTokens.subtleFill)
            )
            .textSelection(.enabled)
    }
}

struct EntityEmptyView: View {
    let iconName: String
    let title: String
    let subtitle: String
    var subtitleMaxWidth: CGFloat? = nil
    var fillsAvailableSpace: Bool = true
    var topPadding: CGFloat = 48
    var horizontalPadding: CGFloat = 24

    init(
        iconName: String = "tray",
        title: String,
        subtitle: String,
        subtitleMaxWidth: CGFloat? = nil,
        fillsAvailableSpace: Bool = true,
        topPadding: CGFloat = 48,
        horizontalPadding: CGFloat = 24
    ) {
        self.iconName = iconName
        self.title = title
        self.subtitle = subtitle
        self.subtitleMaxWidth = subtitleMaxWidth
        self.fillsAvailableSpace = fillsAvailableSpace
        self.topPadding = topPadding
        self.horizontalPadding = horizontalPadding
    }

    var body: some View {
        let textBlock = VStack(spacing: 12) {
            Image(systemName: iconName)
                .font(.largeTitle)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(title)
                .font(.headline)
            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: subtitleMaxWidth)
        }

        Group {
            if fillsAvailableSpace {
                VStack(spacing: 24) {
                    textBlock
                        .frame(maxWidth: .infinity)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            } else {
                VStack(spacing: 24) {
                    textBlock
                        .frame(maxWidth: .infinity)
                }
                .frame(maxWidth: .infinity, alignment: .top)
            }
        }
        .padding(.top, topPadding)
        .padding(.horizontal, horizontalPadding)
    }
}

enum EntityDateFormatter {
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.dateStyle = .short
        formatter.timeStyle = .medium
        return formatter
    }()

    static func text(_ date: Date) -> String {
        formatter.string(from: date)
    }

    static func relativeText(_ date: Date) -> String {
        date.formatted(
            .relative(
                presentation: .named,
                unitsStyle: .abbreviated
            )
        )
    }
}

enum EventSeverity: String {
    case critical = "critical"
    case high = "high"
    case normal = "normal"
    case low = "low"

    init?(rawValueNormalized value: String?) {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self.init(rawValue: normalized)
    }
}

enum EventLifecycleState: String {
    case ongoing = "ONGOING"
    case closed = "CLOSED"
    case unknown = "UNKNOWN"
}

enum ThingLifecycleState: String {
    case active = "ACTIVE"
    case archived = "ARCHIVED"
    case deleted = "DELETED"
    case unknown = "UNKNOWN"
}

func eventLifecycleState(from raw: String?) -> EventLifecycleState {
    switch raw?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() {
    case "ONGOING":
        return .ongoing
    case "CLOSED":
        return .closed
    default:
        return .unknown
    }
}

func thingLifecycleState(from raw: String?) -> ThingLifecycleState {
    switch raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
    case "active":
        return .active
    case "inactive", "archived":
        return .archived
    case "deleted", "decommissioned":
        return .deleted
    default:
        return .unknown
    }
}

func normalizedThingState(_ state: String?) -> String {
    thingLifecycleState(from: state).rawValue
}

func thingStateColor(_ state: String?) -> Color {
    switch thingLifecycleState(from: state) {
    case .active:
        return .green
    case .archived:
        return .orange
    case .deleted:
        return .red
    case .unknown:
        return .secondary
    }
}

func eventStateColor(_ state: String?) -> Color {
    switch eventLifecycleState(from: state) {
    case .ongoing:
        return .blue
    case .closed:
        return .secondary
    case .unknown:
        return .secondary
    }
}

func normalizedEventSeverity(_ severity: String?) -> EventSeverity? {
    EventSeverity(rawValueNormalized: severity)
}

func eventSeverityColor(_ severity: EventSeverity?) -> Color? {
    switch severity {
    case .critical:
        return .red
    case .high:
        return .orange
    case .normal:
        return .blue
    case .low:
        return .indigo
    case nil:
        return nil
    }
}

func eventSeverityColor(_ severity: String?) -> Color? {
    eventSeverityColor(normalizedEventSeverity(severity))
}

func eventSeveritySymbol(_ severity: EventSeverity?) -> String? {
    switch severity {
    case .critical:
        return "exclamationmark.triangle.fill"
    case .high:
        return "exclamationmark.circle.fill"
    case .normal:
        return "info.circle.fill"
    case .low:
        return "arrow.down.circle.fill"
    case nil:
        return nil
    }
}

func eventSeveritySymbol(_ severity: String?) -> String? {
    eventSeveritySymbol(normalizedEventSeverity(severity))
}

func normalizedEventState(_ state: String?) -> String {
    eventLifecycleState(from: state).rawValue
}

func normalizedEventStatus(_ status: String?) -> String? {
    let trimmed = status?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return trimmed.isEmpty ? nil : trimmed
}

func localizedDefaultCreatedEventStatus() -> String {
    LocalizationManager.localizedSync("event_status_created_default")
}

func parseEntityAttributes(from jsonText: String?) -> [EntityDisplayAttribute] {
    guard let jsonText,
          !jsonText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          let data = jsonText.data(using: .utf8),
          let value = try? JSONSerialization.jsonObject(with: data)
    else {
        return []
    }

    if let object = value as? [String: Any] {
        return object
            .sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
            .map { key, value in
                displayAttribute(key: key, rawValue: value)
            }
    }

    if let array = value as? [Any] {
        return array.enumerated().compactMap { index, item in
            guard let object = item as? [String: Any] else {
                let fallbackKey = "item_\(index + 1)"
                return EntityDisplayAttribute(
                    key: fallbackKey,
                    label: fallbackKey,
                    value: attributeDisplayValue(item)
                )
            }
            let fallbackKey = nonEmptyAttributeText(object["key"]) ?? "item_\(index + 1)"
            let rawLabel = nonEmptyAttributeText(object["label"])
            let value = object.keys.contains("value")
                ? attributeDisplayValue(object["value"] as Any)
                : compactJSONString(from: object) ?? "{}"
            return EntityDisplayAttribute(
                key: fallbackKey,
                label: rawLabel ?? fallbackKey,
                value: value
            )
        }
    }

    return []
}

private func displayAttribute(key: String, rawValue: Any) -> EntityDisplayAttribute {
    if let object = rawValue as? [String: Any], object.keys.contains("value") {
        return EntityDisplayAttribute(
            key: key,
            label: nonEmptyAttributeText(object["label"]) ?? key,
            value: attributeDisplayValue(object["value"] as Any)
        )
    }

    return EntityDisplayAttribute(
        key: key,
        label: key,
        value: attributeDisplayValue(rawValue)
    )
}

func hasNonEmptyEntityAttributes(from jsonText: String?) -> Bool {
    !parseEntityAttributes(from: jsonText).isEmpty
}

func metadataDisplayAttributes(from metadata: [String: String]) -> [EntityDisplayAttribute] {
    metadata
        .sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
        .map { key, value in
            EntityDisplayAttribute(key: key, label: key, value: value)
        }
}

func isLikelyImageAttachmentURL(_ url: URL) -> Bool {
    let path = url.path.lowercased()
    let imageExtensions = [".png", ".jpg", ".jpeg", ".gif", ".webp", ".bmp", ".heic", ".heif"]
    if imageExtensions.contains(where: { path.hasSuffix($0) }) {
        return true
    }
    return !url.lastPathComponent.contains(".")
}

private func attributeDisplayValue(_ value: Any) -> String {
    switch value {
    case let text as String:
        return text
    case let number as NSNumber:
        if CFGetTypeID(number) == CFBooleanGetTypeID() {
            return number.boolValue ? "true" : "false"
        }
        return number.stringValue
    case let dict as [String: Any]:
        return compactJSONString(from: dict) ?? "{}"
    case let array as [Any]:
        return compactJSONString(from: array) ?? "[]"
    case _ as NSNull:
        return "null"
    default:
        return String(describing: value)
    }
}

private func nonEmptyAttributeText(_ value: Any?) -> String? {
    guard let text = value as? String else { return nil }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}

private func compactJSONString(from value: Any) -> String? {
    guard JSONSerialization.isValidJSONObject(value),
          let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
          let text = String(data: data, encoding: .utf8)
    else {
        return nil
    }
    return text
}
