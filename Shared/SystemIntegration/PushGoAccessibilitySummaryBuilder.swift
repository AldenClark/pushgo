import Foundation

enum PushGoAccessibilitySummaryBuilder {
    static func label(for summary: PushGoSystemSummary) -> String {
        var parts: [String] = []
        if summary.kind == .message, summary.status == "unread" {
            parts.append(localized("unread"))
        }
        if let severity = normalized(summary.severity) {
            parts.append(
                localized(
                    "accessibility_priority_placeholder",
                    fallback: "%@ priority",
                    localizedSeverity(severity)
                )
            )
        }
        parts.append(summary.kind.displayName)
        parts.append(summary.title)
        if let status = normalized(summary.status), summary.kind != .message || status != "unread" {
            parts.append(localized("accessibility_state_placeholder", fallback: "State %@", status))
        }
        if let thingID = normalized(summary.thingID), summary.kind != .thing {
            parts.append(
                localized(
                    "accessibility_related_object_placeholder",
                    fallback: "Related object %@",
                    thingID
                )
            )
        }
        if let channelID = normalized(summary.channelID) {
            parts.append(localized("accessibility_channel_placeholder", fallback: "Channel %@", channelID))
        }
        return parts.joined(separator: ". ")
    }

    static func value(for summary: PushGoSystemSummary) -> String? {
        let values = [
            normalized(summary.bodyPreview),
            normalized(summary.eventID).map {
                localized("accessibility_event_id_placeholder", fallback: "Event ID %@", $0)
            },
            normalized(summary.thingID).map {
                localized("accessibility_object_id_placeholder", fallback: "Object ID %@", $0)
            },
        ].compactMap { $0 }
        return values.isEmpty ? nil : values.joined(separator: ". ")
    }

    private static func localizedSeverity(_ severity: String) -> String {
        switch severity.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "critical":
            return localized("message_severity_critical", fallback: "Critical")
        case "high":
            return localized("message_severity_high", fallback: "High")
        case "low":
            return localized("message_severity_low", fallback: "Low")
        case "medium", "normal":
            return localized("message_severity_medium", fallback: "Medium")
        default:
            return severity
        }
    }

    private static func localized(_ key: String, fallback: String? = nil, _ args: CVarArg...) -> String {
        var template = LocalizationProvider.localized(key)
        if template == key, let fallback {
            template = fallback
        }
        guard !args.isEmpty else { return template }
        return String(format: template, locale: .autoupdatingCurrent, arguments: args)
    }

    private static func normalized(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}
