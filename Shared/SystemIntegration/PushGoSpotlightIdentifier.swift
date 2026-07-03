import Foundation

struct PushGoSpotlightIdentifier: Equatable, Hashable, Sendable {
    static let prefix = "pushgo"

    let kind: PushGoSystemEntityKind
    let identifier: String

    init?(kind: PushGoSystemEntityKind, identifier: String) {
        let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        self.kind = kind
        self.identifier = trimmed
    }

    init?(uniqueIdentifier: String) {
        let parts = uniqueIdentifier.split(separator: ":", maxSplits: 2).map(String.init)
        guard parts.count == 3,
              parts[0] == Self.prefix,
              let kind = PushGoSystemEntityKind(normalizedRawValue: parts[1]),
              let decoded = parts[2].removingPercentEncoding,
              !decoded.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return nil
        }
        self.kind = kind
        self.identifier = decoded.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var uniqueIdentifier: String {
        let encoded = identifier.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? identifier
        return "\(Self.prefix):\(kind.rawValue):\(encoded)"
    }

    var domainIdentifier: String {
        kind.domainIdentifier
    }

    var openTarget: PushGoSystemOpenTarget? {
        PushGoSystemOpenTarget(kind: kind, identifier: identifier, source: .spotlight)
    }
}
