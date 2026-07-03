import Foundation

enum PushGoSystemEntityKind: String, Codable, CaseIterable, Hashable, Sendable {
    case message
    case event
    case thing

    init?(normalizedRawValue: String?) {
        let normalized = normalizedRawValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        self.init(rawValue: normalized)
    }

    var domainIdentifier: String {
        "io.pushgo.system.\(rawValue)"
    }

    var activityType: String {
        "io.pushgo.\(rawValue).view"
    }

    var displayName: String {
        switch self {
        case .message:
            return localized("push_type_message", fallback: "Message")
        case .event:
            return localized("push_type_event", fallback: "Event")
        case .thing:
            return localized("push_type_thing_singular", fallback: "Object")
        }
    }

    private func localized(_ key: String, fallback: String) -> String {
        let resolved = LocalizationProvider.localized(key)
        return resolved == key ? fallback : resolved
    }
}
