import Foundation

struct PushMessageSummary: Identifiable, Hashable, Sendable {
    let id: UUID
    let messageId: UUID?
    let title: String
    let bodyPreview: String
    let bodyRenderPayload: MarkdownRenderPayload?
    let channel: String?
    let url: URL?
    var isRead: Bool
    let receivedAt: Date
    let status: PushMessage.Status
    let decryptionState: PushMessage.DecryptionState?
    let iconURL: URL?
    let imageURL: URL?
    let secondaryText: String
    let isEncrypted: Bool
}

extension PushMessageSummary {
    init(message: PushMessage) {
        let resolvedBody = message.resolvedBody
        let bodyRenderPayload = Self.resolveBodyRenderPayload(
            from: message.rawPayload,
            resolvedBody: resolvedBody
        )
        self.init(
            id: message.id,
            messageId: message.messageId,
            title: message.title,
            bodyPreview: resolvedBody.rawText,
            bodyRenderPayload: bodyRenderPayload,
            channel: message.channel,
            url: message.url,
            isRead: message.isRead,
            receivedAt: message.receivedAt,
            status: message.status,
            decryptionState: message.decryptionState,
            iconURL: message.iconURL,
            imageURL: message.imageURL,
            secondaryText: Self.secondaryText(from: message),
            isEncrypted: message.isEncrypted
        )
    }

    private static func resolveBodyRenderPayload(
        from rawPayload: [String: AnyCodable],
        resolvedBody: PushMessage.ResolvedBody,
    ) -> MarkdownRenderPayload? {
        if let existing = rawPayload[AppConstants.markdownRenderPayloadKey]?.value as? String,
           let payload = MarkdownRenderPayload.decode(from: existing)
        {
            return payload
        }

        return MarkdownRenderPayloadSizing.listPayload(
            for: resolvedBody.rawText,
            isMarkdown: resolvedBody.isMarkdown
        )
    }

    private static func secondaryText(from message: PushMessage) -> String {
        if let thread = message.rawPayload["aps"]?.value as? [String: Any],
           let threadId = (thread["thread-id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !threadId.isEmpty
        {
            return threadId
        }
        return message.messageId?.uuidString ?? ""
    }
}
