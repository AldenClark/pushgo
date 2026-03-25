import Foundation

enum WatchStandaloneLightQuantizer {
    static func quantizePayload(_ payload: [String: String]) -> WatchLightPayload? {
        let kind = resolvedStandaloneKind(payload)
        switch kind {
        case "message":
            guard let messageId = normalizedIdentifier(payload["message_id"] ?? payload["delivery_id"]) else {
                return nil
            }
            let title = nonEmpty(payload["title"]) ?? messageId
            let body = payload["body"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return .message(
                WatchLightMessage(
                    messageId: messageId,
                    title: title,
                    body: body,
                    imageURL: sanitizedURL(payload["image"]),
                    url: sanitizedURL(payload["url"]),
                    severity: nonEmpty(payload["severity"]),
                    receivedAt: payloadDate(payload["sent_at"]) ?? Date(),
                    isRead: false,
                    entityType: normalizedEntityType(payload["entity_type"]),
                    entityId: nonEmpty(payload["entity_id"]),
                    notificationRequestId: nil
                )
            )
        case "event":
            guard let eventId = normalizedIdentifier(payload["event_id"] ?? payload["entity_id"]) else {
                return nil
            }
            return .event(
                WatchLightEvent(
                    eventId: eventId,
                    title: nonEmpty(payload["title"]) ?? eventId,
                    summary: nonEmpty(payload["body"]),
                    state: nonEmpty(payload["event_state"]),
                    severity: nonEmpty(payload["severity"]),
                    imageURL: sanitizedURL(payload["image"]),
                    updatedAt: payloadDate(payload["sent_at"]) ?? Date()
                )
            )
        case "thing":
            guard let thingId = normalizedIdentifier(payload["thing_id"] ?? payload["entity_id"]) else {
                return nil
            }
            return .thing(
                WatchLightThing(
                    thingId: thingId,
                    title: nonEmpty(payload["title"]) ?? thingId,
                    summary: nonEmpty(payload["body"]),
                    attrsJSON: nonEmpty(payload["thing_attrs_json"]),
                    imageURL: sanitizedURL(payload["image"]),
                    updatedAt: payloadDate(payload["observed_at"] ?? payload["sent_at"]) ?? Date()
                )
            )
        default:
            return nil
        }
    }

    static func quantizePayload(
        _ payload: [String: String],
        titleOverride: String?,
        bodyOverride: String?,
        urlOverride: URL?,
        notificationRequestId: String?
    ) -> WatchLightPayload? {
        let normalized = normalizedPayload(
            payload,
            titleOverride: titleOverride,
            bodyOverride: bodyOverride,
            urlOverride: urlOverride,
            notificationRequestId: notificationRequestId
        )
        guard let payload = quantizePayload(normalized) else {
            return nil
        }
        return injectNotificationRequestId(notificationRequestId, into: payload)
    }

    static func stringifyPayload(_ payload: [AnyHashable: Any]) -> [String: String] {
        payload.reduce(into: [String: String]()) { result, pair in
            let key = String(describing: pair.key).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { return }
            switch pair.value {
            case let text as String:
                result[key] = text
            case let url as URL:
                result[key] = url.absoluteString
            case let number as NSNumber:
                result[key] = number.stringValue
            case let values as [String]:
                if let data = try? JSONSerialization.data(withJSONObject: values, options: []),
                   let text = String(data: data, encoding: .utf8)
                {
                    result[key] = text
                }
            case let map as [String: Any]:
                if let data = try? JSONSerialization.data(withJSONObject: map, options: [.sortedKeys]),
                   let text = String(data: data, encoding: .utf8)
                {
                    result[key] = text
                }
            default:
                break
            }
        }
    }

    private static func normalizedPayload(
        _ payload: [String: String],
        titleOverride: String?,
        bodyOverride: String?,
        urlOverride: URL?,
        notificationRequestId: String?
    ) -> [String: String] {
        var normalized = payload.reduce(into: [String: String]()) { result, pair in
            let key = pair.key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { return }
            result[key] = pair.value
        }
        if let titleOverride = nonEmpty(titleOverride) {
            normalized["title"] = titleOverride
        }
        if let bodyOverride = nonEmpty(bodyOverride) {
            normalized["body"] = bodyOverride
        }
        if let urlOverride {
            normalized["url"] = urlOverride.absoluteString
        }
        if let notificationRequestId = nonEmpty(notificationRequestId) {
            normalized["_notificationRequestId"] = notificationRequestId
        }
        return normalized
    }

    private static func injectNotificationRequestId(
        _ notificationRequestId: String?,
        into payload: WatchLightPayload
    ) -> WatchLightPayload {
        guard let notificationRequestId = nonEmpty(notificationRequestId) else {
            return payload
        }
        switch payload {
        case let .message(message):
            return .message(
                WatchLightMessage(
                    messageId: message.messageId,
                    title: message.title,
                    body: message.body,
                    imageURL: message.imageURL,
                    url: message.url,
                    severity: message.severity,
                    receivedAt: message.receivedAt,
                    isRead: message.isRead,
                    entityType: message.entityType,
                    entityId: message.entityId,
                    notificationRequestId: notificationRequestId
                )
            )
        case .event, .thing:
            return payload
        }
    }

    private static func payloadDate(_ raw: String?) -> Date? {
        guard let text = nonEmpty(raw) else { return nil }
        if let seconds = Double(text) {
            return Date(timeIntervalSince1970: seconds)
        }
        let formatter = ISO8601DateFormatter()
        return formatter.date(from: text)
    }

    private static func normalizedIdentifier(_ raw: String?) -> String? {
        nonEmpty(raw)
    }

    private static func normalizedEntityType(_ raw: String?) -> String {
        switch nonEmpty(raw)?.lowercased() {
        case "event":
            return "event"
        case "thing":
            return "thing"
        default:
            return "message"
        }
    }

    private static func resolvedStandaloneKind(_ payload: [String: String]) -> String? {
        if let explicit = nonEmpty(payload["watch_light_kind"])?.lowercased() {
            return explicit
        }
        let entityType = normalizedEntityType(payload["entity_type"])
        if entityType == "event" || payload["event_id"] != nil {
            return "event"
        }
        if entityType == "thing" || payload["thing_id"] != nil {
            return "thing"
        }
        if payload["message_id"] != nil || payload["delivery_id"] != nil {
            return "message"
        }
        return nil
    }

    private static func nonEmpty(_ raw: String?) -> String? {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func sanitizedURL(_ raw: String?) -> URL? {
        guard let raw else { return nil }
        return URLSanitizer.resolveHTTPSURL(from: raw)
    }
}

enum WatchLightPayload: Sendable {
    case message(WatchLightMessage)
    case event(WatchLightEvent)
    case thing(WatchLightThing)
}
