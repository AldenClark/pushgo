import SwiftUI

enum WatchSemanticTone {
    case info
    case neutral
    case warning

    var foreground: Color {
        switch self {
        case .info:
            return .appStateInfoForeground
        case .neutral:
            return .appStateNeutralForeground
        case .warning:
            return .appStateWarningForeground
        }
    }

    var background: Color {
        switch self {
        case .info:
            return .appStateInfoBackground
        case .neutral:
            return .appStateNeutralBackground
        case .warning:
            return .appStateWarningBackground
        }
    }

    var mutedForeground: Color {
        switch self {
        case .info, .neutral, .warning:
            return .appTextSecondary
        }
    }
}

enum WatchEntityVisualTokens {
    static let subtleFill = Color.appSurfaceRaised
    static let subtleFillSoft = Color.appSurfaceSunken
    static let subtleStroke = Color.appBorderSubtle
    static let chipFillSelected = Color.appSelectionFill
    static let chipFillUnselected = Color.appSurfaceSunken

    static let rowVerticalPadding: CGFloat = 4
    static let stackSpacing: CGFloat = 8
    static let sectionSpacing: CGFloat = 8

    static let radiusSmall: CGFloat = 8
}

struct WatchEntityAvatar: View {
    let url: URL?
    var size: CGFloat = 32

    var body: some View {
        Group {
            if let url {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case let .success(image):
                        image
                            .resizable()
                            .scaledToFill()
                    default:
                        Image(systemName: "cube")
                            .font(.caption)
                            .foregroundStyle(Color.appTextSecondary)
                    }
                }
            } else {
                Image(systemName: "cube")
                    .font(.caption)
                    .foregroundStyle(Color.appTextSecondary)
            }
        }
        .frame(width: size, height: size)
        .background(WatchEntityVisualTokens.subtleFillSoft)
        .clipShape(RoundedRectangle(cornerRadius: WatchEntityVisualTokens.radiusSmall, style: .continuous))
    }
}

struct WatchEntityStateBadge: View {
    let text: String
    let tone: WatchSemanticTone

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(tone.foreground)
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(tone.background, in: Capsule())
    }
}

struct WatchEntityInlineAlert: View {
    let text: String
    var tone: WatchSemanticTone = .warning

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.caption2)
                .foregroundStyle(tone.mutedForeground)
                .padding(.top, 1)
            Text(text)
                .font(.caption2)
                .foregroundStyle(Color.appTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 1)
    }
}

struct WatchEntityEmptyState: View {
    let icon: String
    let text: String

    var body: some View {
        VStack(spacing: WatchEntityVisualTokens.sectionSpacing) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(Color.appTextSecondary)
            Text(text)
                .font(.footnote)
                .foregroundStyle(Color.appTextSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, WatchEntityVisualTokens.rowVerticalPadding + 6)
    }
}

struct WatchEntityMissingState: View {
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(Color.appTextSecondary)
            Text("Entry not found")
                .font(.footnote)
                .foregroundStyle(Color.appTextSecondary)
        }
    }
}

func watchDateText(_ date: Date) -> String {
    date.formatted(date: .abbreviated, time: .shortened)
}

func watchEventStateTone(_ state: String?) -> WatchSemanticTone {
    let normalized = state?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() ?? ""
    switch normalized {
    case "ONGOING":
        return .info
    case "CLOSED":
        return .neutral
    default:
        return .neutral
    }
}

func watchEventStateColor(_ state: String?) -> Color {
    watchEventStateTone(state).foreground
}

func normalizedWatchEventStatus(_ status: String?) -> String? {
    let trimmed = status?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return trimmed.isEmpty ? nil : trimmed
}

func localizedDefaultWatchCreatedEventStatus() -> String {
    LocalizationManager.localizedSync("watch_event_status_created")
}

struct WatchEntityDisplayAttribute: Identifiable, Hashable {
    let key: String
    let label: String
    let value: String

    var displayLabel: String {
        label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? key : label
    }

    var id: String { "\(key):\(label):\(value)" }
}

func parseWatchEntityAttributes(from jsonText: String?) -> [WatchEntityDisplayAttribute] {
    guard let jsonText,
          !jsonText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          let data = jsonText.data(using: .utf8),
          let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    else {
        return []
    }

    return object
        .sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
        .map { key, value in
            WatchEntityDisplayAttribute(
                key: key,
                label: key,
                value: watchAttributeDisplayValue(value)
            )
        }
}

func hasNonEmptyWatchEntityAttributes(from jsonText: String?) -> Bool {
    !parseWatchEntityAttributes(from: jsonText).isEmpty
}

func watchDisplayAttributes(from metadata: [String: String]) -> [WatchEntityDisplayAttribute] {
    metadata
        .filter { !$0.key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        .sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
        .map { key, value in
            WatchEntityDisplayAttribute(key: key, label: key, value: value)
        }
}

func isLikelyWatchImageAttachmentURL(_ url: URL) -> Bool {
    let path = url.path.lowercased()
    let imageExtensions = [".png", ".jpg", ".jpeg", ".gif", ".webp", ".bmp", ".heic", ".heif"]
    if imageExtensions.contains(where: { path.hasSuffix($0) }) {
        return true
    }
    return !url.lastPathComponent.contains(".")
}

private func watchAttributeDisplayValue(_ value: Any) -> String {
    switch value {
    case let text as String:
        return text
    case let number as NSNumber:
        if CFGetTypeID(number) == CFBooleanGetTypeID() {
            return number.boolValue ? "true" : "false"
        }
        return number.stringValue
    case let dict as [String: Any]:
        return watchCompactJSONString(from: dict) ?? "{}"
    case let array as [Any]:
        return watchCompactJSONString(from: array) ?? "[]"
    case _ as NSNull:
        return "null"
    default:
        return String(describing: value)
    }
}

private func nonEmptyWatchAttributeText(_ value: Any?) -> String? {
    guard let text = value as? String else { return nil }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}

private func watchCompactJSONString(from value: Any) -> String? {
    guard JSONSerialization.isValidJSONObject(value),
          let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
          let text = String(data: data, encoding: .utf8)
    else {
        return nil
    }
    return text
}
