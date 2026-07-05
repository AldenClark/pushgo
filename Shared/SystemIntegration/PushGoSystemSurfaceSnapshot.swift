import Foundation

struct PushGoSystemSurfaceSnapshot: Codable, Equatable, Sendable {
    struct Counts: Codable, Equatable, Sendable {
        let totalMessages: Int
        let unreadMessages: Int
        let criticalEvents: Int
        let objectWarnings: Int
    }

    struct FocusState: Codable, Equatable, Sendable {
        enum Mode: String, Codable, Equatable, Sendable {
            case all
            case priorityOnly
            case quiet
        }

        let mode: Mode
        let updatedAtEpochMs: Int64

        static func `default`(now: Date = Date()) -> FocusState {
            FocusState(mode: .all, updatedAtEpochMs: PushGoSystemSurfaceSnapshot.epochMilliseconds(now))
        }
    }

    struct Item: Codable, Equatable, Identifiable, Sendable {
        let id: String
        let kind: PushGoSystemEntityKind
        let title: String
        let subtitle: String?
        let bodyPreview: String?
        let status: String?
        let severity: String?
        let channelID: String?
        let eventID: String?
        let thingID: String?
        let updatedAtEpochMs: Int64
        let imageURL: String?
        let accessibilityLabel: String
        let accessibilityValue: String?
        let openTarget: PushGoSystemOpenTarget?

        var updatedAt: Date {
            Date(timeIntervalSince1970: TimeInterval(updatedAtEpochMs) / 1_000)
        }
    }

    static let schemaVersion = 1

    let schemaVersion: Int
    let generatedAtEpochMs: Int64
    let source: String
    let counts: Counts
    let focusState: FocusState
    let recentMessages: [Item]
    let unreadMessages: [Item]
    let criticalEvents: [Item]
    let objectWarnings: [Item]
    let latestObjectStates: [Item]

    var generatedAt: Date {
        Date(timeIntervalSince1970: TimeInterval(generatedAtEpochMs) / 1_000)
    }

    static func empty(
        source: String = "empty",
        now: Date = Date(),
        focusState: FocusState = .default()
    ) -> PushGoSystemSurfaceSnapshot {
        PushGoSystemSurfaceSnapshot(
            schemaVersion: schemaVersion,
            generatedAtEpochMs: epochMilliseconds(now),
            source: source,
            counts: Counts(totalMessages: 0, unreadMessages: 0, criticalEvents: 0, objectWarnings: 0),
            focusState: focusState,
            recentMessages: [],
            unreadMessages: [],
            criticalEvents: [],
            objectWarnings: [],
            latestObjectStates: []
        )
    }

    static func item(from summary: PushGoSystemSummary, source: PushGoSystemOpenTarget.Source) -> Item? {
        guard summary.privacy.mayIndexTitle else { return nil }
        guard !summary.privacy.isEncryptedOrSensitive else { return nil }
        let target = PushGoSystemOpenTarget(
            kind: summary.kind,
            identifier: summary.stableID,
            localMessageID: summary.localMessageID,
            source: source
        )
        return Item(
            id: "\(summary.kind.rawValue):\(summary.stableID)",
            kind: summary.kind,
            title: summary.title,
            subtitle: summary.subtitle,
            bodyPreview: summary.privacy.mayIndexBody ? summary.bodyPreview : nil,
            status: summary.status,
            severity: summary.severity,
            channelID: summary.channelID,
            eventID: summary.eventID,
            thingID: summary.thingID,
            updatedAtEpochMs: epochMilliseconds(summary.updatedAt),
            imageURL: summary.imageURL?.absoluteString,
            accessibilityLabel: summary.accessibilityLabel,
            accessibilityValue: summary.accessibilityValue,
            openTarget: target
        )
    }

    static func epochMilliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000).rounded())
    }
}
