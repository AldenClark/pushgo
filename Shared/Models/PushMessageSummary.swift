import Foundation

struct MessagePageCursor: Hashable, Sendable {
    let receivedAt: Date
    let id: UUID
    let isRead: Bool

    init(receivedAt: Date, id: UUID, isRead: Bool = false) {
        self.receivedAt = receivedAt
        self.id = id
        self.isRead = isRead
    }
}

enum MessagePaginationError: Error {
    case cursorDidNotAdvance
}

struct UniqueMessagePageConsumption<Element> {
    let appended: [Element]
    let reachedTarget: Bool
}

func consumeUniqueMessagePage<Element, ID: Hashable, Cursor: Equatable>(
    _ page: [Element],
    targetRemaining: Int,
    seenIDs: inout Set<ID>,
    currentCursor: inout Cursor?,
    id: (Element) -> ID,
    cursor: (Element) -> Cursor,
    isVisible: (Element) -> Bool
) throws -> UniqueMessagePageConsumption<Element> {
    precondition(targetRemaining > 0)
    var appended: [Element] = []

    for element in page {
        let advancedCursor = cursor(element)
        guard advancedCursor != currentCursor else {
            throw MessagePaginationError.cursorDidNotAdvance
        }
        currentCursor = advancedCursor

        let elementID = id(element)
        guard isVisible(element), seenIDs.insert(elementID).inserted else {
            continue
        }
        appended.append(element)
        if appended.count == targetRemaining {
            return UniqueMessagePageConsumption(appended: appended, reachedTarget: true)
        }
    }

    return UniqueMessagePageConsumption(appended: appended, reachedTarget: false)
}

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

@MainActor
func loadVisibleMessageSearchPage(
    before cursor: MessagePageCursor?,
    targetVisibleCount: Int,
    pageSize: Int,
    loadPage: (MessagePageCursor?, Int) async throws -> [PushMessageSummary],
    isVisible: (PushMessageSummary) -> Bool
) async throws -> (messages: [PushMessageSummary], nextCursor: MessagePageCursor?, hasMoreResults: Bool) {
    guard targetVisibleCount > 0 else { return ([], cursor, false) }
    var results: [PushMessageSummary] = []
    var currentCursor = cursor
    var seenIDs: Set<UUID> = []
    while results.count < targetVisibleCount {
        try Task.checkCancellation()
        let page = try await loadPage(currentCursor, pageSize)
        guard !page.isEmpty else { return (results, currentCursor, false) }
        let consumed = try consumeUniqueMessagePage(
            page,
            targetRemaining: targetVisibleCount - results.count,
            seenIDs: &seenIDs,
            currentCursor: &currentCursor,
            id: \.id,
            cursor: {
                MessagePageCursor(receivedAt: $0.receivedAt, id: $0.id, isRead: $0.isRead)
            },
            isVisible: isVisible
        )
        results.append(contentsOf: consumed.appended)
        if consumed.reachedTarget { return (results, currentCursor, true) }
        if page.count < pageSize { return (results, currentCursor, false) }
    }
    return (results, currentCursor, true)
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
