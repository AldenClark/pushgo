import Foundation

struct PushGoSystemOpenTarget: Codable, Equatable, Hashable, Sendable {
    enum Source: String, Codable, Hashable, Sendable {
        case notification
        case spotlight
        case appIntent
        case shortcut
        case userActivity
        case widget
        case deepLink
        case automation
    }

    let kind: PushGoSystemEntityKind
    let identifier: String
    let localMessageID: UUID?
    let source: Source

    init?(
        kind: PushGoSystemEntityKind,
        identifier: String,
        localMessageID: UUID? = nil,
        source: Source
    ) {
        let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        self.kind = kind
        self.identifier = trimmed
        self.localMessageID = localMessageID
        self.source = source
    }

    static func message(
        identifier: String,
        localMessageID: UUID? = nil,
        source: Source
    ) -> PushGoSystemOpenTarget? {
        PushGoSystemOpenTarget(
            kind: .message,
            identifier: identifier,
            localMessageID: localMessageID,
            source: source
        )
    }

    static func event(
        identifier: String,
        source: Source
    ) -> PushGoSystemOpenTarget? {
        PushGoSystemOpenTarget(kind: .event, identifier: identifier, source: source)
    }

    static func thing(
        identifier: String,
        source: Source
    ) -> PushGoSystemOpenTarget? {
        PushGoSystemOpenTarget(kind: .thing, identifier: identifier, source: source)
    }
}
