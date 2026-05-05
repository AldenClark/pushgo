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

struct UnreadFilterSessionState {
    private(set) var retainedReadMessageIDs: Set<UUID> = []

    var retainedReadCount: Int {
        retainedReadMessageIDs.count
    }

    mutating func retain(_ message: PushMessageSummary) {
        guard message.isRead else { return }
        retainedReadMessageIDs.insert(message.id)
    }

    mutating func forget(messageId: UUID) {
        retainedReadMessageIDs.remove(messageId)
    }

    mutating func reset() {
        retainedReadMessageIDs.removeAll()
    }

    func mergedMessages(
        currentMessages: [PushMessageSummary],
        liveUnreadMessages: [PushMessageSummary]
    ) -> [PushMessageSummary] {
        var remainingLiveUnreadByID = Dictionary(
            uniqueKeysWithValues: liveUnreadMessages.map { ($0.id, $0) }
        )
        var seenIDs = Set<UUID>()
        var mergedCurrent: [PushMessageSummary] = []

        for current in currentMessages {
            if let live = remainingLiveUnreadByID.removeValue(forKey: current.id) {
                mergedCurrent.append(live)
                seenIDs.insert(live.id)
                continue
            }

            guard retainedReadMessageIDs.contains(current.id) else { continue }
            var retained = current
            retained.isRead = true
            mergedCurrent.append(retained)
            seenIDs.insert(retained.id)
        }

        let insertedUnreadMessages = liveUnreadMessages.filter { !seenIDs.contains($0.id) }
        return insertedUnreadMessages + mergedCurrent
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
