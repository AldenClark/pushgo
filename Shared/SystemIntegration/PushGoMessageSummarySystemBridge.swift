import Foundation

enum PushGoMessageSummarySystemBridge {
    static func summary(for message: PushMessageSummary) -> PushGoSystemSummary {
        let bodyPreview = normalized(message.bodyPreview)
        let privacy = PushGoSystemSummary.Privacy(
            mayIndexTitle: true,
            mayIndexBody: !message.isEncrypted || message.decryptionState == .decryptOk,
            mayExposeMetadata: false,
            isEncryptedOrSensitive: message.isEncrypted
        )
        let base = PushGoSystemSummary(
            kind: .message,
            stableID: message.id.uuidString,
            localMessageID: message.id,
            title: normalized(message.title) ?? "Message",
            subtitle: normalized(message.channel),
            bodyPreview: privacy.mayIndexBody ? bodyPreview : nil,
            status: message.isRead ? "read" : "unread",
            severity: message.severity?.rawValue,
            tags: message.tags,
            channelID: normalized(message.channel),
            eventID: normalized(message.eventId),
            thingID: normalized(message.thingId),
            updatedAt: message.receivedAt,
            imageURL: message.imageURL,
            searchableText: "",
            accessibilityLabel: "",
            accessibilityValue: nil,
            privacy: privacy
        )
        return PushGoSystemSummary(
            kind: base.kind,
            stableID: base.stableID,
            localMessageID: base.localMessageID,
            title: base.title,
            subtitle: base.subtitle,
            bodyPreview: base.bodyPreview,
            status: base.status,
            severity: base.severity,
            tags: base.tags,
            channelID: base.channelID,
            eventID: base.eventID,
            thingID: base.thingID,
            updatedAt: base.updatedAt,
            imageURL: base.imageURL,
            searchableText: base.searchableText,
            accessibilityLabel: PushGoAccessibilitySummaryBuilder.label(for: base),
            accessibilityValue: PushGoAccessibilitySummaryBuilder.value(for: base),
            privacy: base.privacy
        )
    }

    private static func normalized(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}
