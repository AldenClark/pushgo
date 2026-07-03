import Foundation

struct PushGoSystemSummary: Equatable, Hashable, Sendable {
    struct Privacy: Equatable, Hashable, Sendable {
        let mayIndexTitle: Bool
        let mayIndexBody: Bool
        let mayExposeMetadata: Bool
        let isEncryptedOrSensitive: Bool
    }

    let kind: PushGoSystemEntityKind
    let stableID: String
    let localMessageID: UUID?
    let title: String
    let subtitle: String?
    let bodyPreview: String?
    let status: String?
    let severity: String?
    let tags: [String]
    let channelID: String?
    let eventID: String?
    let thingID: String?
    let updatedAt: Date
    let imageURL: URL?
    let searchableText: String
    let accessibilityLabel: String
    let accessibilityValue: String?
    let privacy: Privacy

    var openTarget: PushGoSystemOpenTarget? {
        PushGoSystemOpenTarget(
            kind: kind,
            identifier: stableID,
            localMessageID: localMessageID,
            source: .automation
        )
    }
}
