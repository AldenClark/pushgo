import Foundation
import UserNotifications

struct NormalizedRemoteNotification {
    let title: String
    let body: String
    let channel: String?
    let url: URL?
    let rawPayload: [String: Any]
    let decryptionState: PushMessage.DecryptionState?
    let messageId: UUID?
}

enum NotificationHandling {
    static func extractMessageId(from payload: [AnyHashable: Any]) -> UUID? {
        let mapped = payload.reduce(into: [String: Any]()) { result, element in
            guard let key = element.key as? String else { return }
            result[key] = element.value
        }
        return MessageIdExtractor.extract(from: mapped)
    }

    static func notificationTextForCopy(from content: UNNotificationContent) -> String? {
        let body = resolveBody(from: content)

        var lines: [String] = []
        let title = (content.userInfo["title"] as? String ?? content.title)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty {
            lines.append(title)
        }
        let cleanedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanedBody.isEmpty {
            lines.append(cleanedBody)
        }
        let text = lines.joined(separator: "\n")
        return text.isEmpty ? nil : text
    }

    static func normalizeRemoteNotification(
        _ userInfo: [AnyHashable: Any]
    ) -> NormalizedRemoteNotification? {
        let sanitized = UserInfoSanitizer.sanitize(userInfo)
        let aps = sanitized["aps"] as? [String: Any]

        var title = stringValue(forKeys: ["title"], in: sanitized) ?? ""
        var body = stringValue(forKeys: ["body", "ciphertext_body"], in: sanitized) ?? ""

        if let alertPayload = aps?["alert"] {
            if let alertText = alertPayload as? String {
                if body.isEmpty { body = alertText }
            } else if let alertDict = alertPayload as? [String: Any] {
                if title.isEmpty {
                    title = stringValue(forKeys: ["title", "subtitle"], in: alertDict) ?? ""
                }
                if body.isEmpty {
                    body = stringValue(forKeys: ["body"], in: alertDict) ?? ""
                }
            }
        }

        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty || !trimmedBody.isEmpty else { return nil }

        let channelIdentifier = ((sanitized["channel_id"] as? String)
            ?? (sanitized["channel"] as? String)
            ?? (aps?["thread-id"] as? String))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let channel = channelIdentifier?.isEmpty == true ? nil : channelIdentifier

        let url = (sanitized["url"] as? String).flatMap(URL.init(string:))
        let stateRaw = sanitized["decryptionState"] as? String
        let decryptionState = stateRaw.flatMap(PushMessage.DecryptionState.init(rawValue:))
        let messageId = MessageIdExtractor.extract(from: sanitized)

        var payload = sanitized
        if payload["title"] == nil {
            payload["title"] = trimmedTitle
        }
        if payload["body"] == nil {
            payload["body"] = trimmedBody
        }
        if let channel, payload["channel_id"] == nil {
            payload["channel_id"] = channel
        }
        if let url, payload["url"] == nil {
            payload["url"] = url.absoluteString
        }

        return NormalizedRemoteNotification(
            title: trimmedTitle,
            body: trimmedBody,
            channel: channel,
            url: url,
            rawPayload: payload,
            decryptionState: decryptionState,
            messageId: messageId
        )
    }

    private static func resolveBody(from content: UNNotificationContent) -> String {
        if let cipher = stringValue(forKeys: ["ciphertext_body"], in: content.userInfo) {
            return cipher
        }
        return content.body
    }

    private static func stringValue(forKeys keys: [String], in userInfo: [AnyHashable: Any]) -> String? {
        keys.compactMap { key in
            (userInfo[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        .first(where: { !$0.isEmpty })
    }

    private static func stringValue(forKeys keys: [String], in payload: [String: Any]) -> String? {
        keys.compactMap { key in
            (payload[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        .first(where: { !$0.isEmpty })
    }
}
