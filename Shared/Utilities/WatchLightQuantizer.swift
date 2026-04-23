import Foundation

enum WatchLightQuantizer {
    private static let mirrorMessageLookbackDays = 7
    private static let mirrorMessageLimit = 500

    static func buildMirrorSnapshot(
        messages: [PushMessage],
        eventMessages: [PushMessage],
        thingMessages: [PushMessage],
        generation: Int64,
        exportedAt: Date = Date()
    ) -> WatchMirrorSnapshot {
        let quantizedMessages = quantizeMirrorMessages(messages)
        let quantizedEvents = quantizeEvents(eventMessages)
        let quantizedThings = quantizeThings(thingMessages)
        return WatchMirrorSnapshot(
            generation: generation,
            mode: .mirror,
            messages: quantizedMessages,
            events: quantizedEvents,
            things: quantizedThings,
            exportedAt: exportedAt,
            contentDigest: WatchMirrorSnapshot.contentDigest(
                messages: quantizedMessages,
                events: quantizedEvents,
                things: quantizedThings
            )
        )
    }

    static func quantizeMirrorMessages(_ messages: [PushMessage], now: Date = Date()) -> [WatchLightMessage] {
        let cutoff = Calendar.current.date(byAdding: .day, value: -mirrorMessageLookbackDays, to: now) ?? .distantPast
        return messages
            .filter(isTopLevelMessage)
            .sorted { $0.receivedAt > $1.receivedAt }
            .filter { $0.receivedAt >= cutoff }
            .prefix(mirrorMessageLimit)
            .compactMap(quantizeMirrorMessage)
    }

    static func quantizeMessages(_ messages: [PushMessage], now: Date = Date()) -> [WatchLightMessage] {
        let cutoff = Calendar.current.date(byAdding: .day, value: -mirrorMessageLookbackDays, to: now) ?? .distantPast
        return messages
            .filter(isTopLevelMessage)
            .sorted { $0.receivedAt > $1.receivedAt }
            .filter { $0.receivedAt >= cutoff }
            .prefix(mirrorMessageLimit)
            .compactMap(quantizeStandaloneMessageRecord)
    }

    static func quantizeEvents(_ messages: [PushMessage]) -> [WatchLightEvent] {
        let grouped = Dictionary(grouping: messages.compactMap { message -> (String, PushMessage)? in
            guard let eventId = normalizedIdentifier(message.eventId) else { return nil }
            return (eventId, message)
        }, by: \.0)

        return grouped.compactMap { eventId, pairs in
            let entries = pairs.map(\.1)
            guard let latest = entries.max(by: { eventUpdatedAt(for: $0) < eventUpdatedAt(for: $1) }) else {
                return nil
            }
            let profile = latestEventProfile(from: entries)
            let title = nonEmpty(profile?.title) ?? nonEmpty(latest.title) ?? eventId
            let summary = nonEmpty(profile?.description) ?? nonEmpty(latest.resolvedBody.rawText)
            return WatchLightEvent(
                eventId: eventId,
                title: title,
                summary: summary,
                state: nonEmpty(latest.eventState),
                severity: nonEmpty(profile?.severity) ?? latest.severity?.rawValue,
                imageURL: profile?.imageURL ?? latest.imageURL,
                updatedAt: eventUpdatedAt(for: latest)
            )
        }
        .sorted { $0.updatedAt > $1.updatedAt }
    }

    static func quantizeThings(_ messages: [PushMessage]) -> [WatchLightThing] {
        let grouped = Dictionary(grouping: messages.compactMap { message -> (String, PushMessage)? in
            guard let thingId = normalizedIdentifier(message.thingId) else { return nil }
            return (thingId, message)
        }, by: \.0)

        return grouped.compactMap { thingId, pairs in
            let entries = pairs.map(\.1).sorted { thingUpdatedAt(for: $0) < thingUpdatedAt(for: $1) }
            guard let latest = entries.last else { return nil }
            let profile = latestThingProfile(from: entries)
            let title = nonEmpty(profile?.title) ?? nonEmpty(latest.title) ?? thingId
            let summary = nonEmpty(profile?.description)
            return WatchLightThing(
                thingId: thingId,
                title: title,
                summary: summary,
                attrsJSON: mergedThingAttributes(entries),
                imageURL: profile?.imageURL ?? latest.imageURL,
                updatedAt: thingUpdatedAt(for: latest)
            )
        }
        .sorted { $0.updatedAt > $1.updatedAt }
    }

    static func quantizeStandalonePayload(_ payload: [String: String]) -> WatchLightPayload? {
        let kind = resolvedStandaloneKind(payload)
        switch kind {
        case "message":
            guard let messageId = normalizedIdentifier(payload["message_id"]) else {
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

    static func quantizeStandalonePayload(
        _ payload: [String: String],
        titleOverride: String?,
        bodyOverride: String?,
        urlOverride: URL?,
        notificationRequestId: String?
    ) -> WatchLightPayload? {
        let normalized = normalizedStandalonePayload(
            payload,
            titleOverride: titleOverride,
            bodyOverride: bodyOverride,
            urlOverride: urlOverride,
            notificationRequestId: notificationRequestId
        )
        guard let payload = quantizeStandalonePayload(normalized) else {
            return nil
        }
        return injectNotificationRequestId(notificationRequestId, into: payload)
    }

    static func stringifyPayload(_ payload: [AnyHashable: Any]) -> [String: String] {
        payload.reduce(into: [String: String]()) { result, pair in
            let key = String(describing: pair.key).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { return }
            switch pair.value {
            case let value as String:
                result[key] = value
            case let value as NSNumber:
                result[key] = value.stringValue
            case let value as Bool:
                result[key] = value ? "true" : "false"
            case let value as [String: Any]:
                if let data = try? JSONSerialization.data(withJSONObject: value),
                   let text = String(data: data, encoding: .utf8)
                {
                    result[key] = text
                }
            case let value as [Any]:
                if let data = try? JSONSerialization.data(withJSONObject: value),
                   let text = String(data: data, encoding: .utf8)
                {
                    result[key] = text
                }
            default:
                result[key] = String(describing: pair.value)
            }
        }
    }

    private static func quantizeMirrorMessage(_ message: PushMessage) -> WatchLightMessage? {
        guard let resolvedMessageId = normalizedIdentifier(message.messageId) else {
            return nil
        }
        return buildLightMessage(message, resolvedMessageId: resolvedMessageId)
    }

    private static func quantizeStandaloneMessageRecord(_ message: PushMessage) -> WatchLightMessage? {
        guard let resolvedMessageId = normalizedIdentifier(message.messageId) else {
            return nil
        }
        return buildLightMessage(message, resolvedMessageId: resolvedMessageId)
    }

    private static func buildLightMessage(_ message: PushMessage, resolvedMessageId: String) -> WatchLightMessage {
        let imageURL = message.imageURL
            ?? sanitizedURL(stringValue("image", in: message.rawPayload))
            ?? sanitizedURL(stringValue("primary_image", in: message.rawPayload))
        return WatchLightMessage(
            messageId: resolvedMessageId,
            title: message.title,
            body: message.resolvedBody.rawText,
            imageURL: imageURL,
            url: URLSanitizer.sanitizeHTTPSURL(message.url),
            severity: message.severity?.rawValue,
            receivedAt: message.receivedAt,
            isRead: message.isRead,
            entityType: normalizedEntityType(message.entityType),
            entityId: nonEmpty(message.entityId),
            notificationRequestId: nonEmpty(message.notificationRequestId)
        )
    }

    private static func isTopLevelMessage(_ message: PushMessage) -> Bool {
        let entityType = normalizedEntityType(message.entityType)
        return entityType == "message"
            && normalizedIdentifier(message.eventId) == nil
            && normalizedIdentifier(message.thingId) == nil
    }

    private static func eventUpdatedAt(for message: PushMessage) -> Date {
        payloadDate(stringValue("event_time", in: message.rawPayload))
            ?? payloadDate(stringValue("observed_at", in: message.rawPayload))
            ?? message.receivedAt
    }

    private static func thingUpdatedAt(for message: PushMessage) -> Date {
        payloadDate(stringValue("observed_at", in: message.rawPayload))
            ?? payloadDate(stringValue("event_time", in: message.rawPayload))
            ?? message.receivedAt
    }

    private static func latestEventProfile(from messages: [PushMessage]) -> WatchLightProfile? {
        messages
            .sorted { eventUpdatedAt(for: $0) > eventUpdatedAt(for: $1) }
            .compactMap { profile(from: stringValue("event_profile_json", in: $0.rawPayload)) }
            .first
    }

    private static func latestThingProfile(from messages: [PushMessage]) -> WatchLightProfile? {
        messages
            .sorted { thingUpdatedAt(for: $0) > thingUpdatedAt(for: $1) }
            .compactMap { profile(from: stringValue("thing_profile_json", in: $0.rawPayload)) }
            .first
    }

    private static func mergedThingAttributes(_ messages: [PushMessage]) -> String? {
        var attrs: [String: Any] = [:]
        for message in messages {
            if let snapshot = jsonObject(from: stringValue("thing_attrs_json", in: message.rawPayload)) {
                attrs = snapshot
            }
            if let patch = jsonObject(from: stringValue("event_attrs_json", in: message.rawPayload)) {
                for (key, value) in patch {
                    if value is NSNull {
                        attrs.removeValue(forKey: key)
                    } else {
                        attrs[key] = value
                    }
                }
            }
        }
        guard !attrs.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: attrs, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8)
        else {
            return nil
        }
        return text
    }

    private static func profile(from rawJSON: String?) -> WatchLightProfile? {
        guard let object = jsonObject(from: rawJSON) else { return nil }
        return WatchLightProfile(
            title: nonEmpty(object["title"] as? String),
            description: nonEmpty(object["description"] as? String),
            severity: nonEmpty(object["severity"] as? String),
            imageURL: sanitizedURL(object["image"] as? String)
        )
    }

    private static func jsonObject(from rawJSON: String?) -> [String: Any]? {
        guard let rawJSON = nonEmpty(rawJSON),
              let data = rawJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let map = object as? [String: Any]
        else {
            return nil
        }
        return map
    }

    private static func payloadDate(_ raw: String?) -> Date? {
        guard let text = nonEmpty(raw) else { return nil }
        if let seconds = PayloadTimeParser.epochSeconds(from: text) {
            return Date(timeIntervalSince1970: TimeInterval(seconds))
        }
        let isoFormatter = ISO8601DateFormatter()
        return isoFormatter.date(from: text)
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

    private static func stringValue(_ key: String, in payload: [String: AnyCodable]) -> String? {
        payload[key]?.value as? String
    }

    private static func normalizedStandalonePayload(
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

private struct WatchLightProfile {
    let title: String?
    let description: String?
    let severity: String?
    let imageURL: URL?
}
