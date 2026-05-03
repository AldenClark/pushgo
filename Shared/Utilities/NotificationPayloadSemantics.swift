import Foundation

struct NotificationPayloadSemantics {
    static let gatewayFallbackAlertTitle = "PushGo"
    static let gatewayFallbackEventBody = "Event updated."
    static let gatewayFallbackThingBody = "Object updated."

    struct ProfileSnapshot {
        let title: String?
        let description: String?
        let message: String?
    }

    struct ThingAttributesSnapshot {
        let thingName: String?
        let pairs: [(name: String, value: String)]
    }

    struct EntityOpenTargetComponents: Equatable {
        let entityType: String
        let entityId: String
    }

    struct NormalizedPayload {
        let title: String
        let body: String
        let hasExplicitTitle: Bool
        let channel: String?
        let url: URL?
        let rawPayload: [String: Any]
        let decryptionStateRaw: String?
        let messageId: String?
        let operationId: String?
        let entityType: String
        let entityId: String?
        let eventId: String?
        let thingId: String?
    }

    static func extractMessageId(from payload: [AnyHashable: Any]) -> String? {
        let mapped = payload.reduce(into: [String: Any]()) { result, element in
            guard let key = element.key as? String else { return }
            result[key] = element.value
        }
        return stringValue(forKeys: ["message_id"], in: mapped)
    }

    static func shouldPresentUserAlert(
        from payload: [AnyHashable: Any],
        now: Date = Date()
    ) -> Bool {
        let sanitized = UserInfoSanitizer.sanitize(payload)
        guard !isPayloadExpired(sanitized, now: now) else { return false }
        let entityType = normalizedEntityType(sanitized["entity_type"] as? String)
        if entityType == "event" || entityType == "thing" || entityType == "message" {
            return true
        }
        return false
    }

    static func normalizeRemoteNotification(
        _ userInfo: [AnyHashable: Any],
        contextSnapshot: NotificationContextSnapshot? = nil,
        localizeTypeLabel: (String) -> String,
        localizeThingAttributeUpdateBody: (String) -> String,
        localizeThingAttributePair: (String, String) -> String
    ) -> NormalizedPayload? {
        var sanitized = UserInfoSanitizer.sanitize(userInfo)
        let entityType = normalizedEntityType(sanitized["entity_type"] as? String)
        sanitized = sanitizeVisibleURLFields(payload: sanitized)
        let aps = sanitized["aps"] as? [String: Any]
        var title = stringValue(forKeys: ["title"], in: sanitized) ?? ""
        var body = stringValue(forKeys: ["body"], in: sanitized) ?? ""
        let apsAlert = alertText(from: aps?["alert"])

        if !isGatewayFallbackAlertCandidate(
            entityType: entityType,
            title: apsAlert.title,
            body: apsAlert.body
        ) {
            if title.isEmpty {
                title = apsAlert.title ?? ""
            }
            if body.isEmpty {
                body = apsAlert.body ?? ""
            }
        }
        let hasExplicitTitle = !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        if entityType == "event" || entityType == "thing" {
            let profile = profilePayload(entityType: entityType, payload: sanitized)
            let thingAttributes = entityType == "thing"
                ? parseThingAttributesSnapshot(payload: sanitized)
                : nil
            let eventContext = entityType == "event"
                ? contextSnapshot?.eventContext(
                    eventId: stringValue(forKeys: ["event_id", "entity_id"], in: sanitized)
                )
                : nil
            let thingContext = entityType == "thing"
                ? contextSnapshot?.thingContext(
                    thingId: stringValue(forKeys: ["thing_id", "entity_id"], in: sanitized)
                )
                : nil

            if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                title = resolvedEntityFallbackTitle(
                    entityType: entityType,
                    payload: sanitized,
                    profile: profile,
                    thingAttributes: thingAttributes,
                    eventContext: eventContext,
                    thingContext: thingContext,
                    localizeTypeLabel: localizeTypeLabel
                )
            }

            if body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                body = resolvedEntityFallbackBody(
                    entityType: entityType,
                    payload: sanitized,
                    profile: profile,
                    thingAttributes: thingAttributes,
                    eventContext: eventContext,
                    thingContext: thingContext,
                    localizeThingAttributeUpdateBody: localizeThingAttributeUpdateBody,
                    localizeThingAttributePair: localizeThingAttributePair
                ) ?? body
            }
        }
        body = URLSanitizer.rewriteVisibleURLsInMarkdown(body)

        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let identity = canonicalIdentity(entityType: entityType, payload: sanitized) else {
            return nil
        }
        let messageHasPersistableContent = entityType == "message"
            && hasPersistableMessageContent(payload: sanitized, title: trimmedTitle, body: trimmedBody)
        if entityType == "message",
           !messageHasPersistableContent
        {
            return nil
        }
        guard messageHasPersistableContent || !trimmedTitle.isEmpty || !trimmedBody.isEmpty else {
            return nil
        }

        let channelIdentifier = ((sanitized["channel_id"] as? String)
            ?? (aps?["thread-id"] as? String))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let channel = channelIdentifier?.isEmpty == true ? nil : channelIdentifier

        let url = (sanitized["url"] as? String).flatMap { URLSanitizer.resolveExternalOpenURL(from: $0) }
        let decryptionStateRaw = (sanitized["decryption_state"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
        let messageId = stringValue(forKeys: ["message_id"], in: sanitized)
        let operationId = stringValue(forKeys: ["op_id"], in: sanitized)

        var payload = sanitized
        if payload["title"] == nil {
            payload["title"] = trimmedTitle
        }
        if payload["body"] == nil {
            payload["body"] = trimmedBody
        }
        payload["entity_type"] = identity.entityType
        payload["entity_id"] = identity.entityId
        if let messageId = identity.messageId {
            payload["message_id"] = messageId
        }
        if let eventId = identity.eventId {
            payload["event_id"] = eventId
        }
        if let thingId = identity.thingId {
            payload["thing_id"] = thingId
        }
        if let channel, payload["channel_id"] == nil {
            payload["channel_id"] = channel
        }
        if let url, payload["url"] == nil {
            payload["url"] = url.absoluteString
        }

        return NormalizedPayload(
            title: trimmedTitle,
            body: trimmedBody,
            hasExplicitTitle: hasExplicitTitle,
            channel: channel,
            url: url,
            rawPayload: payload,
            decryptionStateRaw: decryptionStateRaw,
            messageId: identity.messageId ?? messageId,
            operationId: operationId,
            entityType: identity.entityType,
            entityId: identity.entityId,
            eventId: identity.eventId,
            thingId: identity.thingId
        )
    }

    static func entityOpenTargetComponents(
        from payload: [AnyHashable: Any]
    ) -> EntityOpenTargetComponents? {
        entityOpenTargetComponents(fromSanitizedPayload: UserInfoSanitizer.sanitize(payload))
    }

    static func notificationThreadIdentifier(
        from payload: [AnyHashable: Any]
    ) -> String? {
        notificationThreadIdentifier(fromSanitizedPayload: UserInfoSanitizer.sanitize(payload))
    }

    static func isGatewayFallbackAlertCandidate(
        entityType: String,
        title: String?,
        body: String?
    ) -> Bool {
        let normalizedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedBody = body?.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackBody: String? = switch entityType {
        case "event":
            gatewayFallbackEventBody
        case "thing":
            gatewayFallbackThingBody
        default:
            nil
        }

        guard let fallbackBody else { return false }
        guard normalizedBody == fallbackBody else { return false }
        guard let normalizedTitle else { return true }
        return normalizedTitle.isEmpty || normalizedTitle == gatewayFallbackAlertTitle
    }

    private static func alertText(from rawAlert: Any?) -> (title: String?, body: String?) {
        if let alertText = rawAlert as? String {
            return (nil, alertText.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty)
        }
        if let alertDict = rawAlert as? [String: Any] {
            return (
                stringValue(forKeys: ["title", "subtitle"], in: alertDict),
                stringValue(forKeys: ["body"], in: alertDict)
            )
        }
        return (nil, nil)
    }

    private static func hasPersistableMessageContent(
        payload: [String: Any],
        title: String,
        body: String
    ) -> Bool {
        if !title.isEmpty || !body.isEmpty {
            return true
        }
        if hasNonEmptyValue(payload["ciphertext"]) {
            return true
        }
        if hasNonEmptyValue(payload["url"]) {
            return true
        }
        if hasNonEmptyValue(payload["images"]) {
            return true
        }
        return false
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

    private static func isPayloadExpired(_ payload: [String: Any], now: Date) -> Bool {
        guard let ttl = epochSeconds(from: payload["ttl"]) else {
            return false
        }
        let current = Int64(now.timeIntervalSince1970)
        return current > ttl
    }

    private static func epochSeconds(from value: Any?) -> Int64? {
        PayloadTimeParser.epochSeconds(from: value)
    }

    private static func hasNonEmptyValue(_ value: Any?) -> Bool {
        switch value {
        case let string as String:
            return !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case let values as [Any]:
            return !values.isEmpty
        default:
            return false
        }
    }

    private static func normalizedEntityType(_ raw: String?) -> String {
        let normalized = raw?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        switch normalized {
        case "event", "thing", "message":
            return normalized
        default:
            return "message"
        }
    }

    private static func entityOpenTargetComponents(
        fromSanitizedPayload payload: [String: Any]
    ) -> EntityOpenTargetComponents? {
        guard let identity = canonicalIdentity(
            entityType: normalizedEntityType(payload["entity_type"] as? String),
            payload: payload
        ) else {
            return nil
        }
        guard identity.entityType == "event" || identity.entityType == "thing" else {
            return nil
        }
        return EntityOpenTargetComponents(entityType: identity.entityType, entityId: identity.entityId)
    }

    private static func profilePayload(
        entityType: String,
        payload: [String: Any]
    ) -> ProfileSnapshot? {
        guard entityType == "event" || entityType == "thing" else {
            return nil
        }
        let title = stringValue(forKeys: ["title"], in: payload)
        let description = stringValue(forKeys: ["description"], in: payload)
        let message = stringValue(forKeys: ["message"], in: payload)
        if title == nil, description == nil, message == nil {
            return nil
        }
        return ProfileSnapshot(
            title: title,
            description: description,
            message: message
        )
    }

    private static func notificationThreadIdentifier(
        fromSanitizedPayload payload: [String: Any]
    ) -> String? {
        let entityType = normalizedEntityType(payload["entity_type"] as? String)
        let channel = stringValue(forKeys: ["channel_id"], in: payload)
        let eventId = stringValue(forKeys: ["event_id"], in: payload)
        let thingId = stringValue(forKeys: ["thing_id"], in: payload)
        var parts: [String] = []
        switch entityType {
        case "event":
            parts.append("event")
        case "thing":
            parts.append("thing")
        default:
            parts.append("message")
        }
        if let channel {
            parts.append("channel=\(channel)")
        }
        if entityType == "event" || entityType == "thing", let eventId {
            parts.append("event=\(eventId)")
        }
        if entityType == "thing", let thingId {
            parts.append("thing=\(thingId)")
        }
        guard parts.count > 1 else {
            return nil
        }
        return parts.joined(separator: "|")
    }

    private static func parseThingAttributesSnapshot(
        payload: [String: Any]
    ) -> ThingAttributesSnapshot? {
        let object: [String: Any]
        if let inline = payload["attrs"] as? [String: Any] {
            object = inline
        } else if let raw = payload["attrs"] as? String,
                  let data = raw.data(using: .utf8),
                  let decoded = try? JSONSerialization.jsonObject(with: data),
                  let parsed = decoded as? [String: Any]
        {
            object = parsed
        } else {
            return nil
        }

        var thingName: String?
        var pairs: [(name: String, value: String)] = []
        pairs.reserveCapacity(min(object.count, 6))

        let orderedKeys = object.keys.sorted { lhs, rhs in
            let lhsPriority = attributeSortPriority(lhs)
            let rhsPriority = attributeSortPriority(rhs)
            if lhsPriority != rhsPriority {
                return lhsPriority < rhsPriority
            }
            return lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
        }
        for key in orderedKeys {
            guard let value = object[key] else { continue }
            guard let pair = attributePair(name: key, value: value) else { continue }
            if thingName == nil {
                let normalizedKey = key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if normalizedKey == "name" || normalizedKey == "thing_name" || key == "名称" {
                    thingName = pair.value
                }
            }
            pairs.append(pair)
            if pairs.count >= 6 { break }
        }

        guard !pairs.isEmpty else { return nil }
        return ThingAttributesSnapshot(thingName: thingName, pairs: pairs)
    }

    private static func attributeSortPriority(_ rawKey: String) -> Int {
        let normalized = rawKey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized == "name" || normalized == "thing_name" || rawKey == "名称" {
            return 0
        }
        return 1
    }

    private static func attributePair(
        name: String,
        value: Any
    ) -> (name: String, value: String)? {
        let fallbackName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !fallbackName.isEmpty else { return nil }

        guard let normalizedValue = normalizedAttributeValue(value) else {
            return nil
        }
        return (name: fallbackName, value: normalizedValue)
    }

    private static func normalizedAttributeValue(_ value: Any) -> String? {
        switch value {
        case let text as String:
            return text.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        case let int as Int:
            return String(int)
        case let int64 as Int64:
            return String(int64)
        case let double as Double:
            return String(double)
        case let bool as Bool:
            return bool ? "true" : "false"
        case let number as NSNumber:
            return number.stringValue
        default:
            return nil
        }
    }

    private static func formatThingAttributeUpdateBody(
        snapshot: ThingAttributesSnapshot?,
        localizeThingAttributeUpdateBody: (String) -> String,
        localizeThingAttributePair: (String, String) -> String
    ) -> String? {
        let details = snapshot?.pairs
            .map { localizeThingAttributePair($0.name, $0.value) }
            .joined(separator: ", ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let details, !details.isEmpty else { return nil }
        return localizeThingAttributeUpdateBody(details)
    }

    private static func resolvedEntityFallbackTitle(
        entityType: String,
        payload: [String: Any],
        profile: ProfileSnapshot?,
        thingAttributes: ThingAttributesSnapshot?,
        eventContext: NotificationContextSnapshot.EventContext?,
        thingContext: NotificationContextSnapshot.ThingContext?,
        localizeTypeLabel: (String) -> String
    ) -> String {
        if entityType == "thing",
           let thingName = thingAttributes?.thingName,
           !thingName.isEmpty
        {
            return thingName
        }
        if let title = profile?.title, !title.isEmpty {
            return title
        }
        if entityType == "event",
           let title = eventContext?.title,
           !title.isEmpty
        {
            return title
        }
        if entityType == "thing",
           let title = thingContext?.title,
           !title.isEmpty
        {
            return title
        }
        let fallbackId = stringValue(
            forKeys: entityType == "event" ? ["event_id", "entity_id"] : ["thing_id", "entity_id"],
            in: payload
        ) ?? "unknown"
        return "\(localizeTypeLabel(entityType)) \(fallbackId)"
    }

    private static func resolvedEntityFallbackBody(
        entityType: String,
        payload: [String: Any],
        profile: ProfileSnapshot?,
        thingAttributes: ThingAttributesSnapshot?,
        eventContext: NotificationContextSnapshot.EventContext?,
        thingContext: NotificationContextSnapshot.ThingContext?,
        localizeThingAttributeUpdateBody: (String) -> String,
        localizeThingAttributePair: (String, String) -> String
    ) -> String? {
        if let message = profile?.message, !message.isEmpty {
            return message
        }
        if entityType == "thing",
           let formatted = formatThingAttributeUpdateBody(
               snapshot: thingAttributes,
               localizeThingAttributeUpdateBody: localizeThingAttributeUpdateBody,
               localizeThingAttributePair: localizeThingAttributePair
           ),
           !formatted.isEmpty
        {
            return formatted
        }
        if let description = profile?.description, !description.isEmpty {
            return description
        }
        if entityType == "event",
           let eventState = stringValue(forKeys: ["event_state", "status"], in: payload),
           !eventState.isEmpty
        {
            return eventState
        }
        if entityType == "thing",
           let thingState = stringValue(forKeys: ["state", "status"], in: payload),
           !thingState.isEmpty
        {
            return thingState
        }
        if entityType == "event",
           let eventBody = eventContext?.body,
           !eventBody.isEmpty
        {
            return eventBody
        }
        if entityType == "event",
           let eventState = eventContext?.state,
           !eventState.isEmpty
        {
            return eventState
        }
        if entityType == "thing",
           let thingBody = thingContext?.body,
           !thingBody.isEmpty
        {
            return thingBody
        }
        if entityType == "thing",
           let thingState = thingContext?.state,
           !thingState.isEmpty
        {
            return thingState
        }
        switch entityType {
        case "event":
            return gatewayFallbackEventBody
        case "thing":
            return gatewayFallbackThingBody
        default:
            return nil
        }
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let text = value as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private struct CanonicalIdentity {
        let entityType: String
        let entityId: String
        let messageId: String?
        let eventId: String?
        let thingId: String?
    }

    private static func canonicalIdentity(
        entityType: String,
        payload: [String: Any]
    ) -> CanonicalIdentity? {
        switch entityType {
        case "message":
            guard let messageId = stringValue(forKeys: ["message_id"], in: payload) else {
                return nil
            }
            let entityId = stringValue(forKeys: ["entity_id"], in: payload) ?? messageId
            guard entityId == messageId else { return nil }
            return CanonicalIdentity(
                entityType: entityType,
                entityId: entityId,
                messageId: messageId,
                eventId: nil,
                thingId: nil
            )
        case "event":
            guard let eventId = stringValue(forKeys: ["event_id"], in: payload) else {
                return nil
            }
            let entityId = stringValue(forKeys: ["entity_id"], in: payload) ?? eventId
            guard entityId == eventId else { return nil }
            return CanonicalIdentity(
                entityType: entityType,
                entityId: entityId,
                messageId: nil,
                eventId: eventId,
                thingId: stringValue(forKeys: ["thing_id"], in: payload)
            )
        case "thing":
            guard let thingId = stringValue(forKeys: ["thing_id"], in: payload) else {
                return nil
            }
            let entityId = stringValue(forKeys: ["entity_id"], in: payload) ?? thingId
            guard entityId == thingId else { return nil }
            return CanonicalIdentity(
                entityType: entityType,
                entityId: entityId,
                messageId: nil,
                eventId: nil,
                thingId: thingId
            )
        default:
            return nil
        }
    }

    private static func sanitizeVisibleURLFields(payload: [String: Any]) -> [String: Any] {
        var sanitized = payload
        if let raw = sanitized["url"] as? String {
            if let safe = URLSanitizer.resolveExternalOpenURL(from: raw)?.absoluteString {
                sanitized["url"] = safe
            } else {
                sanitized.removeValue(forKey: "url")
            }
        }
        sanitizeImagesField(payload: &sanitized, key: "images")
        return sanitized
    }

    private static func sanitizeImagesField(payload: inout [String: Any], key: String) {
        let urls = normalizedImageURLs(from: payload[key])
        if urls.isEmpty {
            payload.removeValue(forKey: key)
            return
        }
        if let data = try? JSONSerialization.data(withJSONObject: urls),
           let encoded = String(data: data, encoding: .utf8)
        {
            payload[key] = encoded
        } else {
            payload.removeValue(forKey: key)
        }
    }

    private static func normalizedImageURLs(from raw: Any?) -> [String] {
        guard let raw else { return [] }
        var values: [String] = []
        switch raw {
        case let value as String:
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { return [] }
            if let data = trimmed.data(using: .utf8),
               let decoded = try? JSONSerialization.jsonObject(with: data) as? [Any]
            {
                values = decoded.compactMap { $0 as? String }
            } else {
                values = [trimmed]
            }
        case let value as [Any]:
            values = value.compactMap { $0 as? String }
        default:
            return []
        }
        var output: [String] = []
        var seen = Set<String>()
        for value in values {
            guard let safe = URLSanitizer.resolveHTTPSURL(from: value)?.absoluteString else { continue }
            if seen.insert(safe).inserted {
                output.append(safe)
            }
        }
        return output
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
