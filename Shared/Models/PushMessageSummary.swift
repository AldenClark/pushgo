import Foundation

struct PushMessageSummary: Identifiable, Hashable, Sendable {
    let id: UUID
    let messageId: String?
    let title: String
    let bodyPreview: String
    let channel: String?
    let url: URL?
    var isRead: Bool
    let receivedAt: Date
    let status: PushMessage.Status
    let decryptionState: PushMessage.DecryptionState?
    let imageURL: URL?
    let imageURLs: [URL]
    let tags: [String]
    let severity: PushMessage.Severity?
    let secondaryText: String
    let isEncrypted: Bool
    let entityType: String
    let entityId: String?
    let eventId: String?
    let thingId: String?
    let eventState: String?

    var rowLayoutKey: String {
        [
            id.uuidString,
            title,
            bodyPreview,
            channel ?? "",
            secondaryText,
            imageURLs.map(\.absoluteString).joined(separator: ","),
            isRead ? "1" : "0",
        ].joined(separator: "|")
    }
}

extension PushMessageSummary {
    init(message: PushMessage) {
        self.init(
            id: message.id,
            messageId: message.messageId,
            title: message.title,
            bodyPreview: message.bodyPreview,
            channel: message.channel,
            url: message.url,
            isRead: message.isRead,
            receivedAt: message.receivedAt,
            status: message.status,
            decryptionState: message.decryptionState,
            imageURL: message.imageURL,
            imageURLs: message.imageURLs,
            tags: message.tags,
            severity: message.severity,
            secondaryText: Self.secondaryText(from: message),
            isEncrypted: message.isEncrypted,
            entityType: message.entityType,
            entityId: message.entityId,
            eventId: message.eventId,
            thingId: message.thingId,
            eventState: message.eventState
        )
    }

    private static func secondaryText(from message: PushMessage) -> String {
        if let thread = message.rawPayload["aps"]?.value as? [String: Any],
           let threadId = (thread["thread-id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !threadId.isEmpty
        {
            return threadId
        }
        return message.messageId ?? ""
    }
}
