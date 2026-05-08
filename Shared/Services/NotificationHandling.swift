import CryptoKit
import Foundation
import UserNotifications

struct NormalizedRemoteNotification {
    let title: String
    let body: String
    let hasExplicitTitle: Bool
    let channel: String?
    let url: URL?
    let rawPayload: [String: Any]
    let decryptionState: PushMessage.DecryptionState?
    let messageId: String?
    let operationId: String?
    let entityType: String
    let entityId: String?
    let thingId: String?
}

enum ProviderWakeupResolution {
    case notWakeup
    case pulled(payload: [AnyHashable: Any], requestIdentifier: String)
    case claimedByPeer(payload: [AnyHashable: Any], requestIdentifier: String?)
    case unresolvedWakeup(payload: [AnyHashable: Any], requestIdentifier: String?)
}

enum NotificationIngressResolution {
    case direct(payload: [AnyHashable: Any], requestIdentifier: String?)
    case pulled(payload: [AnyHashable: Any], requestIdentifier: String)
    case claimedByPeer(payload: [AnyHashable: Any], requestIdentifier: String?)
    case unresolvedWakeup(payload: [AnyHashable: Any], requestIdentifier: String?)
}

private struct WakeupServerCandidate {
    let config: ServerConfig
    let source: String
}

#if !os(watchOS)
enum NotificationPersistenceOutcome {
    case persistedMain(PushMessage)
    case persistedPending(PushMessage)
    case duplicate
    case rejected
    case failed
}

#if !NSE_NO_DATABASE
enum NotificationPersistenceCoordinator {
    static func persistRemotePayloadIfNeeded(
        _ payload: [AnyHashable: Any],
        requestIdentifier: String? = nil,
        dataStore: LocalDataStore,
        beforeSave: (@Sendable (PushMessage) async -> Void)? = nil
    ) async -> NotificationPersistenceOutcome {
        if NotificationHandling.shouldSkipPersistence(for: payload) {
            return .rejected
        }
        let preparedContent = await preparedContentForPersistence(from: payload)
        let resolvedFallbackRequestIdentifier = normalizedText(requestIdentifier)
            ?? normalizedText(preparedContent.userInfo["delivery_id"] as? String)
            ?? UUID().uuidString

        return await persistPreparedContentIfNeeded(
            content: preparedContent,
            requestIdentifier: requestIdentifier,
            fallbackRequestIdentifier: resolvedFallbackRequestIdentifier,
            dataStore: dataStore,
            beforeSave: beforeSave
        )
    }

    static func persistIfNeeded(
        _ notification: UNNotification,
        dataStore: LocalDataStore,
        beforeSave: (@Sendable (PushMessage) async -> Void)? = nil
    ) async -> NotificationPersistenceOutcome {
        await persistIfNeeded(
            request: notification.request,
            content: notification.request.content,
            dataStore: dataStore,
            beforeSave: beforeSave
        )
    }

    static func persistIfNeeded(
        request: UNNotificationRequest,
        content: UNNotificationContent,
        dataStore: LocalDataStore,
        beforeSave: (@Sendable (PushMessage) async -> Void)? = nil
    ) async -> NotificationPersistenceOutcome {
        await persistPreparedContentIfNeeded(
            content: content,
            requestIdentifier: nil,
            fallbackRequestIdentifier: request.identifier,
            dataStore: dataStore,
            beforeSave: beforeSave
        )
    }

    static func persistPreparedContentIfNeeded(
        content: UNNotificationContent,
        requestIdentifier: String?,
        fallbackRequestIdentifier: String,
        dataStore: LocalDataStore,
        beforeSave: (@Sendable (PushMessage) async -> Void)? = nil
    ) async -> NotificationPersistenceOutcome {
        let preparedContent = await preparedContentForPersistence(from: content)
        if NotificationHandling.shouldSkipPersistence(for: preparedContent.userInfo) {
            return .rejected
        }

        let resolvedRequestIdentifier = normalizedText(requestIdentifier)
            ?? normalizedText(fallbackRequestIdentifier)
            ?? UUID().uuidString
        let normalized = NotificationPayloadNormalizer.normalize(
            content: preparedContent,
            requestId: resolvedRequestIdentifier
        )
        return await persistNormalizedPayload(
            title: normalized.title,
            body: normalized.body,
            hasExplicitTitle: normalized.hasExplicitTitle,
            channel: normalized.channel,
            url: normalized.url,
            decryptionState: normalized.decryptionState,
            rawPayload: normalized.rawPayload,
            messageId: normalized.messageId,
            dataStore: dataStore,
            beforeSave: beforeSave
        )
    }

    private static func persistNormalizedPayload(
        title: String,
        body: String,
        hasExplicitTitle: Bool,
        channel: String?,
        url: URL?,
        decryptionState: PushMessage.DecryptionState?,
        rawPayload: [String: AnyCodable],
        messageId: String?,
        dataStore: LocalDataStore,
        beforeSave: (@Sendable (PushMessage) async -> Void)? = nil
    ) async -> NotificationPersistenceOutcome {
        let now = Date()
        var resolvedTitle = title
        var resolvedRawPayload = rawPayload
        if !hasExplicitTitle,
           let storedTitle = await resolveStoredEntityTitle(
               from: resolvedRawPayload,
               dataStore: dataStore
           )
        {
            resolvedTitle = storedTitle
            resolvedRawPayload["title"] = AnyCodable(storedTitle)
        }

        let receivedAt = PayloadTimeParser.date(from: resolvedRawPayload["sent_at"]) ?? now
        let message = PushMessage(
            messageId: messageId,
            title: resolvedTitle,
            body: body,
            channel: channel,
            url: url,
            isRead: false,
            receivedAt: receivedAt,
            rawPayload: resolvedRawPayload,
            status: .normal,
            decryptionState: decryptionState
        )
        await beforeSave?(message)

        do {
            switch try await dataStore.persistNotificationMessageIfNeeded(message) {
            case let .persisted(stored):
                return .persistedMain(stored)
            case let .persistedPending(stored):
                return .persistedPending(stored)
            case .duplicateRequest(_):
                return .duplicate
            case .duplicateMessage(_):
                return .duplicate
            }
        } catch {
            return .failed
        }
    }

    private static func resolveStoredEntityTitle(
        from payload: [String: AnyCodable],
        dataStore: LocalDataStore
    ) async -> String? {
        let entityType = payloadText(payload, keys: ["entity_type"])?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        if entityType == "thing",
           let thingId = payloadText(payload, keys: ["thing_id", "entity_id"])
        {
            let normalizedThingId = thingId.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedThingId.isEmpty else { return nil }
            let messages = try? await dataStore.loadThingMessagesForProjection(thingId: normalizedThingId)
            return messages?
                .lazy
                .map { $0.title.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first(where: { !$0.isEmpty })
        }

        if entityType == "event" || (entityType == nil && payloadText(payload, keys: ["event_id"]) != nil),
           let eventId = payloadText(payload, keys: ["event_id", "entity_id"])
        {
            let normalizedEventId = eventId.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedEventId.isEmpty else { return nil }
            let messages = try? await dataStore.loadEventMessagesForProjection(eventId: normalizedEventId)
            return messages?
                .lazy
                .map { $0.title.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first(where: { !$0.isEmpty })
        }

        if let messageId = payloadText(payload, keys: ["message_id"]) {
            let normalizedMessageId = messageId.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedMessageId.isEmpty else { return nil }
            let message = try? await dataStore.loadMessage(messageId: normalizedMessageId)
            let title = message?.title.trimmingCharacters(in: .whitespacesAndNewlines)
            if let title, !title.isEmpty {
                return title
            }
        }

        return nil
    }

    private static func payloadText(
        _ payload: [String: AnyCodable],
        keys: [String]
    ) -> String? {
        keys.compactMap { key in
            (payload[key]?.value as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        .first(where: { !$0.isEmpty })
    }

    private static func preparedContentForPersistence(
        from payload: [AnyHashable: Any]
    ) async -> UNNotificationContent {
        let sanitizedPayload = UserInfoSanitizer.sanitize(payload)
        let mutableContent = UNMutableNotificationContent()
        mutableContent.userInfo = sanitizedPayload
        mutableContent.title = (sanitizedPayload["title"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        mutableContent.body = (sanitizedPayload["body"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return prepareDecryptedContentForPersistence(from: mutableContent)
    }

    private static func preparedContentForPersistence(
        from content: UNNotificationContent
    ) async -> UNNotificationContent {
        guard let mutableContent = content.mutableCopy() as? UNMutableNotificationContent else {
            return content
        }
        return prepareDecryptedContentForPersistence(from: mutableContent)
    }

    private static func prepareDecryptedContentForPersistence(
        from content: UNMutableNotificationContent
    ) -> UNNotificationContent {
        let material = try? LocalKeychainConfigStore().loadServerConfig()?.notificationKeyMaterial
        let hasCiphertext = (content.userInfo["ciphertext"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty == false
        let likelyEncrypted = hasCiphertext
            || InlineCipherEnvelope.looksLikeCiphertext(content.title)
            || InlineCipherEnvelope.looksLikeCiphertext(content.body)

        guard let material, material.isConfigured else {
            if likelyEncrypted {
                content.userInfo["decryption_state"] = "notConfigured"
            }
            return content
        }

        guard material.algorithm == .aesGcm else {
            if likelyEncrypted {
                content.userInfo["decryption_state"] = "algMismatch"
            }
            return content
        }

        guard [16, 24, 32].contains(material.keyData.count) else {
            if likelyEncrypted {
                content.userInfo["decryption_state"] = "decryptFailed"
            }
            return content
        }

        let key = SymmetricKey(data: material.keyData)
        var decryptSucceeded = false
        var decryptFailed = false

        if let decryptedTitle = decryptInlineFieldIfNeeded(content.title, key: key, failed: &decryptFailed) {
            content.title = decryptedTitle
            content.userInfo["title"] = decryptedTitle
            decryptSucceeded = true
        }
        if let decryptedBody = decryptInlineFieldIfNeeded(content.body, key: key, failed: &decryptFailed) {
            content.body = decryptedBody
            content.userInfo["body"] = decryptedBody
            decryptSucceeded = true
        }
        if applyCiphertextPayloadIfNeeded(content: content, key: key, failed: &decryptFailed) {
            decryptSucceeded = true
        }

        if decryptFailed {
            content.userInfo["decryption_state"] = "decryptFailed"
        } else if decryptSucceeded {
            content.userInfo["decryption_state"] = "decryptOk"
        }
        return content
    }

    private static func decryptInlineFieldIfNeeded(
        _ value: String,
        key: SymmetricKey,
        failed: inout Bool
    ) -> String? {
        guard let envelope = InlineCipherEnvelope(from: value) else {
            return nil
        }
        do {
            let nonce = try AES.GCM.Nonce(data: envelope.iv)
            let sealedBox = try AES.GCM.SealedBox(
                nonce: nonce,
                ciphertext: envelope.ciphertext,
                tag: envelope.tag
            )
            let decrypted = try AES.GCM.open(sealedBox, using: key)
            guard let text = String(data: decrypted, encoding: .utf8) else {
                failed = true
                return nil
            }
            return text
        } catch {
            failed = true
            return nil
        }
    }

    private static func applyCiphertextPayloadIfNeeded(
        content: UNMutableNotificationContent,
        key: SymmetricKey,
        failed: inout Bool
    ) -> Bool {
        guard let ciphertext = content.userInfo["ciphertext"] as? String,
              let envelope = InlineCipherEnvelope(from: ciphertext)
        else {
            return false
        }
        do {
            let nonce = try AES.GCM.Nonce(data: envelope.iv)
            let sealedBox = try AES.GCM.SealedBox(
                nonce: nonce,
                ciphertext: envelope.ciphertext,
                tag: envelope.tag
            )
            let decrypted = try AES.GCM.open(sealedBox, using: key)
            guard let jsonText = String(data: decrypted, encoding: .utf8) else {
                failed = true
                return false
            }
            guard let data = jsonText.data(using: .utf8),
                  let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                failed = true
                return false
            }

            var applied = false
            if let title = (object["title"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                !title.isEmpty
            {
                content.title = title
                content.userInfo["title"] = title
                applied = true
            }
            if let body = (object["body"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                !body.isEmpty
            {
                content.body = body
                content.userInfo["body"] = body
                applied = true
            }
            if let url = (object["url"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                !url.isEmpty
            {
                content.userInfo["url"] = url
                applied = true
            }
            if let images = normalizedImages(from: object["images"]), !images.isEmpty {
                content.userInfo["images"] = images
                applied = true
            }
            if let tags = normalizedJSONArrayString(from: object["tags"]) {
                content.userInfo["tags"] = tags
                applied = true
            }
            if let metadata = normalizedJSONObjectString(from: object["metadata"]) {
                content.userInfo["metadata"] = metadata
                applied = true
            }
            if let description = (object["description"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                !description.isEmpty
            {
                content.userInfo["description"] = description
                applied = true
            }
            if let status = (object["status"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                !status.isEmpty
            {
                content.userInfo["status"] = status
                applied = true
            }
            if let message = (object["message"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                !message.isEmpty
            {
                content.userInfo["message"] = message
                applied = true
            }
            if let attrs = normalizedJSONObjectString(from: object["attrs"]) {
                content.userInfo["attrs"] = attrs
                applied = true
            }
            if let startedAt = normalizedInt64(from: object["started_at"]) {
                content.userInfo["started_at"] = startedAt
                applied = true
            }
            if let endedAt = normalizedInt64(from: object["ended_at"]) {
                content.userInfo["ended_at"] = endedAt
                applied = true
            }
            if let primaryImage = (object["primary_image"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                !primaryImage.isEmpty
            {
                content.userInfo["primary_image"] = primaryImage
                applied = true
            }
            if let state = (object["state"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                !state.isEmpty
            {
                content.userInfo["state"] = state
                applied = true
            }
            if let createdAt = normalizedInt64(from: object["created_at"]) {
                content.userInfo["created_at"] = createdAt
                applied = true
            }
            if let deletedAt = normalizedInt64(from: object["deleted_at"]) {
                content.userInfo["deleted_at"] = deletedAt
                applied = true
            }
            if let externalIds = normalizedJSONObjectString(from: object["external_ids"]) {
                content.userInfo["external_ids"] = externalIds
                applied = true
            }
            if let locationType = (object["location_type"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                !locationType.isEmpty
            {
                content.userInfo["location_type"] = locationType
                applied = true
            }
            if let locationValue = (object["location_value"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                !locationValue.isEmpty
            {
                content.userInfo["location_value"] = locationValue
                applied = true
            }
            if let location = normalizedJSONObjectString(from: object["location"]) {
                content.userInfo["location"] = location
                applied = true
            }
            return applied
        } catch {
            failed = true
            return false
        }
    }

    private static func normalizedImages(from raw: Any?) -> [String]? {
        if let values = raw as? [String] {
            return values
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }
        if let text = (raw as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !text.isEmpty,
           let data = text.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data),
           let values = object as? [String]
        {
            return values
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }
        return nil
    }

    private static func normalizedJSONObjectString(from raw: Any?) -> String? {
        if let object = raw as? [String: Any],
           JSONSerialization.isValidJSONObject(object),
           let data = try? JSONSerialization.data(withJSONObject: object),
           let text = String(data: data, encoding: .utf8)
        {
            return text
        }
        if let text = (raw as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !text.isEmpty,
           let data = text.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           JSONSerialization.isValidJSONObject(object),
           let normalized = try? JSONSerialization.data(withJSONObject: object)
        {
            return String(data: normalized, encoding: .utf8)
        }
        return nil
    }

    private static func normalizedJSONArrayString(from raw: Any?) -> String? {
        var values: [String] = []
        if let array = raw as? [Any] {
            values = array.compactMap { value in
                guard let text = (value as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                    !text.isEmpty
                else {
                    return nil
                }
                return text
            }
        } else if let text = (raw as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !text.isEmpty,
            let data = text.data(using: .utf8),
            let decoded = try? JSONSerialization.jsonObject(with: data) as? [Any]
        {
            values = decoded.compactMap { value in
                guard let text = (value as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                    !text.isEmpty
                else {
                    return nil
                }
                return text
            }
        }
        var deduped: [String] = []
        for value in values where !deduped.contains(value) {
            deduped.append(value)
        }
        guard !deduped.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: deduped),
              let text = String(data: data, encoding: .utf8)
        else {
            return nil
        }
        return text
    }

    private static func normalizedInt64(from raw: Any?) -> Int64? {
        switch raw {
        case let value as Int64:
            return value
        case let value as Int:
            return Int64(value)
        case let value as NSNumber:
            return value.int64Value
        case let value as String:
            return Int64(value.trimmingCharacters(in: .whitespacesAndNewlines))
        default:
            return nil
        }
    }

    private struct InlineCipherEnvelope {
        let ciphertext: Data
        let tag: Data
        let iv: Data

        init?(from base64: String) {
            let trimmed = base64.trimmingCharacters(in: .whitespacesAndNewlines)
            guard Self.looksLikeCiphertext(trimmed),
                  let decoded = Data(base64Encoded: trimmed)
            else {
                return nil
            }
            guard decoded.count >= 29 else { return nil }
            let iv = decoded.suffix(12)
            let cipherAndTag = decoded.prefix(decoded.count - 12)
            guard cipherAndTag.count > 16 else { return nil }
            let tag = cipherAndTag.suffix(16)
            let ciphertext = cipherAndTag.prefix(cipherAndTag.count - 16)
            self.ciphertext = ciphertext
            self.tag = tag
            self.iv = iv
        }

        static func looksLikeCiphertext(_ value: String) -> Bool {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed.count % 4 == 0, trimmed.count >= 40 else {
                return false
            }
            let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=")
            return trimmed.rangeOfCharacter(from: allowed.inverted) == nil
        }
    }

    private static func normalizedText(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}
#endif
#endif

enum NotificationHandling {
#if !os(watchOS)
    struct ForegroundPresentationDecision: Equatable {
        let shouldReloadCounts: Bool
        let shouldPresentAlert: Bool
    }
#endif

    struct EntityOpenTargetComponents: Equatable {
        let entityType: String
        let entityId: String
    }

    static func extractMessageId(from payload: [AnyHashable: Any]) -> String? {
        NotificationPayloadSemantics.extractMessageId(from: payload)
    }

    static func shouldPresentUserAlert(from payload: [AnyHashable: Any]) -> Bool {
        NotificationPayloadSemantics.shouldPresentUserAlert(from: payload)
    }

#if !os(watchOS) && !NSE_NO_DATABASE
    static func foregroundPresentationDecision(
        persistenceOutcome: NotificationPersistenceOutcome,
        payload: [AnyHashable: Any]
    ) -> ForegroundPresentationDecision {
        let shouldReloadCounts: Bool
        switch persistenceOutcome {
        case .persistedMain, .persistedPending, .duplicate:
            shouldReloadCounts = true
        case .rejected, .failed:
            shouldReloadCounts = false
        }
        let shouldPresentAlert: Bool
        switch persistenceOutcome {
        case .rejected:
            shouldPresentAlert = false
        case .persistedMain, .persistedPending, .duplicate, .failed:
            shouldPresentAlert = shouldPresentUserAlert(from: payload)
        }
        return ForegroundPresentationDecision(
            shouldReloadCounts: shouldReloadCounts,
            shouldPresentAlert: shouldPresentAlert
        )
    }
#endif

    static func normalizeRemoteNotification(
        _ userInfo: [AnyHashable: Any]
    ) -> NormalizedRemoteNotification? {
        let contextSnapshot = NotificationContextSnapshotStore.load()
        guard let normalized = NotificationPayloadSemantics.normalizeRemoteNotification(
            userInfo,
            contextSnapshot: contextSnapshot,
            localizeTypeLabel: { entityType in
                entityType == "event"
                    ? LocalizationProvider.localized("push_type_event")
                    : LocalizationProvider.localized("push_type_thing")
            },
            localizeThingAttributeUpdateBody: { details in
                LocalizationProvider.localized(
                    "thing_attribute_update_notification_template",
                    details
                )
            },
            localizeThingAttributePair: { name, value in
                LocalizationProvider.localized(
                    "thing_attribute_update_pair_template",
                    name,
                    value
                )
            }
        ) else {
            return nil
        }

        return NormalizedRemoteNotification(
            title: normalized.title,
            body: normalized.body,
            hasExplicitTitle: normalized.hasExplicitTitle,
            channel: normalized.channel,
            url: normalized.url,
            rawPayload: normalized.rawPayload,
            decryptionState: PushMessage.DecryptionState.from(raw: normalized.decryptionStateRaw),
            messageId: normalized.messageId,
            operationId: normalized.operationId,
            entityType: normalized.entityType,
            entityId: normalized.entityId,
            thingId: normalized.thingId
        )
    }

    static func normalizeRemoteNotificationForDisplay(
        _ userInfo: [AnyHashable: Any]
    ) -> NormalizedRemoteNotification? {
        normalizeRemoteNotification(userInfo) ?? fallbackNormalizedRemoteNotification(userInfo)
    }

    static func fallbackNormalizedRemoteNotification(
        _ userInfo: [AnyHashable: Any]
    ) -> NormalizedRemoteNotification? {
        let sanitized = UserInfoSanitizer.sanitize(userInfo)
        if providerWakeupPullDeliveryId(from: sanitized) != nil {
            return nil
        }
        let hasCiphertext = (sanitized["ciphertext"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty == false
        guard hasCiphertext else {
            return nil
        }
        let rawPayload = sanitized
        let deliveryId = (sanitized["delivery_id"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let messageId = (sanitized["message_id"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let contextSnapshot = NotificationContextSnapshotStore.load()
        let snapshotFallback = fallbackDisplayFromContextSnapshot(
            payload: sanitized,
            snapshot: contextSnapshot
        )
        let title = (sanitized["title"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedTitle: String
        if let title, !title.isEmpty {
            normalizedTitle = title
        } else if let snapshotTitle = snapshotFallback.title {
            normalizedTitle = snapshotTitle
        } else {
            normalizedTitle = "收到消息"
        }
        let body = (sanitized["body"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedBody: String
        if let body, !body.isEmpty {
            normalizedBody = body
        } else if let snapshotBody = snapshotFallback.body {
            normalizedBody = snapshotBody
        } else {
            normalizedBody = "消息已收到，等待解密。"
        }
        let channel = normalizedPayloadString(sanitized["channel"])
        let entityType = ((sanitized["entity_type"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased())
        let normalizedEntityType = (entityType?.isEmpty == false ? entityType : nil) ?? "message"
        let entityId = normalizedPayloadString(sanitized["entity_id"]) ?? messageId ?? deliveryId
        let thingId = normalizedPayloadString(sanitized["thing_id"])
        let decryptionState = ((sanitized["decryption_state"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines))
            .flatMap(PushMessage.DecryptionState.from(raw:))
        return NormalizedRemoteNotification(
            title: normalizedTitle,
            body: normalizedBody,
            hasExplicitTitle: true,
            channel: channel,
            url: nil,
            rawPayload: rawPayload,
            decryptionState: decryptionState,
            messageId: messageId,
            operationId: nil,
            entityType: normalizedEntityType,
            entityId: entityId,
            thingId: thingId
        )
    }

    private static func fallbackDisplayFromContextSnapshot(
        payload: [String: Any],
        snapshot: NotificationContextSnapshot?
    ) -> (title: String?, body: String?) {
        func trimmedNonEmpty(_ value: String?) -> String? {
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed.isEmpty ? nil : trimmed
        }

        guard let snapshot else { return (nil, nil) }
        let entityType = ((payload["entity_type"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased())
        if entityType == "event" {
            let eventId = normalizedPayloadString(payload["event_id"])
                ?? normalizedPayloadString(payload["entity_id"])
            let context = snapshot.eventContext(eventId: eventId)
            return (
                trimmedNonEmpty(context?.title),
                trimmedNonEmpty(context?.body) ?? trimmedNonEmpty(context?.state)
            )
        }
        if entityType == "thing" {
            let thingId = normalizedPayloadString(payload["thing_id"])
                ?? normalizedPayloadString(payload["entity_id"])
            let context = snapshot.thingContext(thingId: thingId)
            return (
                trimmedNonEmpty(context?.title),
                trimmedNonEmpty(context?.body) ?? trimmedNonEmpty(context?.state)
            )
        }
        return (nil, nil)
    }

    static func shouldSkipPersistence(for payload: [AnyHashable: Any]) -> Bool {
        let sanitized = UserInfoSanitizer.sanitize(payload)
        return normalizedPayloadBoolean(sanitized["_skip_persist"]) == true
    }

#if !NSE_NO_DATABASE
    static func resolveNotificationIngress(
        from payload: [AnyHashable: Any],
        dataStore: LocalDataStore,
        fallbackServerConfig: ServerConfig? = nil,
        channelSubscriptionService: ChannelSubscriptionService
    ) async -> NotificationIngressResolution {
        let sanitized = UserInfoSanitizer.sanitize(payload)
        let resolution = await resolveProviderWakeup(
            from: sanitized,
            dataStore: dataStore,
            fallbackServerConfig: fallbackServerConfig,
            channelSubscriptionService: channelSubscriptionService
        )
        switch resolution {
        case .notWakeup:
            return .direct(
                payload: sanitized,
                requestIdentifier: providerIngressRequestIdentifier(from: sanitized)
            )
        case let .pulled(resolvedPayload, requestIdentifier):
            return .pulled(payload: resolvedPayload, requestIdentifier: requestIdentifier)
        case let .claimedByPeer(unresolvedPayload, requestIdentifier):
            return .claimedByPeer(
                payload: unresolvedPayload,
                requestIdentifier: requestIdentifier
            )
        case let .unresolvedWakeup(unresolvedPayload, requestIdentifier):
            return .unresolvedWakeup(
                payload: unresolvedPayload,
                requestIdentifier: requestIdentifier
            )
        }
    }
#endif

    static func providerIngressRequestIdentifier(from payload: [AnyHashable: Any]) -> String? {
        let sanitized = UserInfoSanitizer.sanitize(payload)
        return normalizedPayloadString(sanitized["delivery_id"])
    }

#if !os(watchOS) && !NSE_NO_DATABASE
    static func providerIngressAckDeliveryId(
        for ingress: NotificationIngressResolution,
        outcome: NotificationPersistenceOutcome
    ) -> String? {
        switch outcome {
        case .persistedMain, .persistedPending:
            break
        case .duplicate, .rejected, .failed:
            return nil
        }

        switch ingress {
        case let .direct(payload, requestIdentifier):
            if providerWakeupPullDeliveryId(from: payload) != nil {
                return nil
            }
            return requestIdentifier ?? providerIngressRequestIdentifier(from: payload)
        case .pulled:
            return nil
        case .claimedByPeer:
            return nil
        case .unresolvedWakeup:
            return nil
        }
    }
#endif

    static func wakeupFallbackDisplayPayload(
        from payload: [AnyHashable: Any]
    ) -> [AnyHashable: Any]? {
        let sanitized = UserInfoSanitizer.sanitize(payload)
        guard providerWakeupPullDeliveryId(from: sanitized) != nil,
              let normalized = normalizeRemoteNotificationForDisplay(sanitized)
        else {
            return nil
        }

        var rawPayload: [AnyHashable: Any] = normalized.rawPayload.reduce(into: [:]) { result, element in
            result[element.key] = element.value
        }
        if normalizedPayloadString(rawPayload["title"]) == nil {
            rawPayload["title"] = normalized.title
        }
        if normalizedPayloadString(rawPayload["body"]) == nil {
            rawPayload["body"] = normalized.body
        }
        rawPayload.removeValue(forKey: "_skip_persist")
        return UserInfoSanitizer.sanitize(rawPayload)
    }

    static func providerWakeupPullDeliveryId(from payload: [AnyHashable: Any]) -> String? {
        let sanitized = UserInfoSanitizer.sanitize(payload)
        guard normalizedPayloadBoolean(sanitized["provider_wakeup"]) == true else {
            return nil
        }
        let mode = (sanitized["provider_mode"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard mode == nil || mode == "wakeup" else {
            return nil
        }
        let deliveryId = (sanitized["delivery_id"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let deliveryId, !deliveryId.isEmpty else {
            return nil
        }
        return deliveryId
    }

#if !NSE_NO_DATABASE
    static func resolveProviderWakeup(
        from payload: [AnyHashable: Any],
        dataStore: LocalDataStore,
        fallbackServerConfig: ServerConfig? = nil,
        channelSubscriptionService: ChannelSubscriptionService
    ) async -> ProviderWakeupResolution {
        let sanitized = UserInfoSanitizer.sanitize(payload)
        guard let deliveryId = providerWakeupPullDeliveryId(from: sanitized) else {
            return .notWakeup
        }
        let candidates = await activeServerConfigsForWakeupIngress(
            dataStore: dataStore,
            payload: sanitized,
            fallbackServerConfig: fallbackServerConfig
        )
        guard !candidates.isEmpty else {
            return .unresolvedWakeup(payload: sanitized, requestIdentifier: deliveryId)
        }
        guard let deviceKey = await activeProviderDeviceKeyForWakeupIngress(dataStore: dataStore) else {
            return .unresolvedWakeup(payload: sanitized, requestIdentifier: deliveryId)
        }
        let claimStore = ProviderWakeupPullClaimStore.shared
        let owner = "app_wakeup_resolver"
        let leaseDuration: TimeInterval = 30
        let lease: ProviderWakeupPullClaimStore.ClaimLease
        if let acquiredLease = await claimStore.acquireLease(
            deliveryId: deliveryId,
            owner: owner,
            leaseDuration: leaseDuration
        ) {
            lease = acquiredLease
        } else if await claimStore.waitForPeerCompletion(
            deliveryId: deliveryId,
            timeout: 1.5
        ) {
            return .claimedByPeer(payload: sanitized, requestIdentifier: deliveryId)
        } else if let retryLease = await claimStore.acquireLease(
            deliveryId: deliveryId,
            owner: owner,
            leaseDuration: leaseDuration
        ) {
            lease = retryLease
        } else {
            return .unresolvedWakeup(payload: sanitized, requestIdentifier: deliveryId)
        }

        for candidate in candidates {
            do {
                let items = try await channelSubscriptionService.pullMessages(
                    baseURL: candidate.config.baseURL,
                    token: candidate.config.token,
                    deviceKey: deviceKey,
                    deliveryId: deliveryId
                )
                guard let item = items.first else {
                    continue
                }
                let pulledPayload: [AnyHashable: Any] = item.payload.reduce(into: [:]) { result, element in
                    result[element.key] = element.value
                }
                await claimStore.markCompleted(lease)
                return .pulled(
                    payload: UserInfoSanitizer.sanitize(pulledPayload),
                    requestIdentifier: normalizedPayloadString(item.deliveryId) ?? deliveryId
                )
            } catch {
                continue
            }
        }

        await claimStore.releaseLease(lease)
        return .unresolvedWakeup(payload: sanitized, requestIdentifier: deliveryId)
    }
#endif

    static func applyResolvedPayload(
        _ payload: [AnyHashable: Any],
        to content: UNMutableNotificationContent
    ) {
        let userInfo = UserInfoSanitizer.sanitize(payload)
        content.userInfo = userInfo
        if let normalized = normalizeRemoteNotificationForDisplay(userInfo) {
            content.title = normalized.title
            content.body = normalized.body
        } else {
            content.title = normalizedPayloadString(userInfo["title"]) ?? ""
            content.body = normalizedPayloadString(userInfo["body"]) ?? ""
        }
        content.threadIdentifier = NotificationPayloadSemantics.notificationThreadIdentifier(
            from: userInfo
        ) ?? ""
        content.categoryIdentifier = notificationCategoryIdentifier(for: userInfo)
    }

    static func isEntityReminderPayload(_ payload: [AnyHashable: Any]) -> Bool {
        entityOpenTargetComponents(from: payload) != nil
    }

    static func notificationCategoryIdentifier(for payload: [AnyHashable: Any]) -> String {
        isEntityReminderPayload(payload)
            ? AppConstants.notificationEntityReminderCategoryIdentifier
            : AppConstants.notificationDefaultCategoryIdentifier
    }

    static func entityOpenTargetComponents(
        from payload: [AnyHashable: Any]
    ) -> EntityOpenTargetComponents? {
        NotificationPayloadSemantics.entityOpenTargetComponents(from: payload)
            .map { EntityOpenTargetComponents(entityType: $0.entityType, entityId: $0.entityId) }
    }

    private static func normalizedPayloadBoolean(_ value: Any?) -> Bool? {
        switch value {
        case let bool as Bool:
            return bool
        case let number as NSNumber:
            return number.intValue != 0
        case let string as String:
            let normalized = string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if normalized == "1" || normalized == "true" || normalized == "yes" || normalized == "on" {
                return true
            }
            if normalized == "0" || normalized == "false" || normalized == "no" || normalized == "off" {
                return false
            }
            return nil
        default:
            return nil
        }
    }

#if !NSE_NO_DATABASE
    private static func activeServerConfigsForWakeupIngress(
        dataStore: LocalDataStore,
        payload: [String: Any],
        fallbackServerConfig: ServerConfig?
    ) async -> [WakeupServerCandidate] {
        var candidates: [WakeupServerCandidate] = []
        var dedupe = Set<String>()
        func appendCandidate(baseURL: URL, token: String?, source: String) {
            let normalizedConfig = ServerConfig(
                baseURL: baseURL,
                token: token,
                notificationKeyMaterial: nil
            ).normalized()
            let dedupeKey = "\(normalizedConfig.baseURL.absoluteString.lowercased())|\(normalizedConfig.token ?? "")"
            guard dedupe.insert(dedupeKey).inserted else {
                return
            }
            candidates.append(WakeupServerCandidate(config: normalizedConfig, source: source))
        }

        if let channelId = normalizedPayloadString(payload["channel_id"]) {
            let subscriptions = (try? await dataStore.loadChannelSubscriptions(includeDeleted: true)) ?? []
            for subscription in subscriptions where subscription.channelId == channelId {
                guard let url = URLSanitizer.validatedServerURL(from: subscription.gateway) else {
                    continue
                }
                appendCandidate(
                    baseURL: url,
                    token: nil,
                    source: "channel_subscriptions.channel_id"
                )
            }
        }

        if let gatewayURL = wakeupGatewayURL(from: payload) {
            appendCandidate(
                baseURL: gatewayURL,
                token: nil,
                source: "payload.base_url"
            )
        }

        if let fallbackServerConfig {
            let normalized = fallbackServerConfig.normalized()
            appendCandidate(
                baseURL: normalized.baseURL,
                token: normalized.token,
                source: "fallback_server_config"
            )
        }

        if let persistedServerConfig = (try? await dataStore.loadServerConfig())?.normalized() {
            appendCandidate(
                baseURL: persistedServerConfig.baseURL,
                token: persistedServerConfig.token,
                source: "data_store.server_config"
            )
        }

        return candidates
    }

    private static func activeProviderDeviceKeyForWakeupIngress(
        dataStore: LocalDataStore
    ) async -> String? {
        let platform = providerPullPlatformIdentifier()
        let deviceKey = await dataStore.cachedDeviceKey(for: platform)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return deviceKey?.isEmpty == false ? deviceKey : nil
    }

    private static func providerPullPlatformIdentifier() -> String {
        #if os(iOS)
        return "ios"
        #elseif os(macOS)
        return "macos"
        #elseif os(watchOS)
        return "watchos"
        #else
        return "apple"
        #endif
    }
#endif

    private static func normalizedPayloadString(_ value: Any?) -> String? {
        let trimmed = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func wakeupGatewayURL(from payload: [String: Any]) -> URL? {
        let candidates = [
            normalizedPayloadString(payload["gateway"]),
            normalizedPayloadString(payload["gateway_url"]),
            normalizedPayloadString(payload["base_url"]),
            normalizedPayloadString(payload["server"]),
            normalizedPayloadString(payload["server_url"]),
        ]
        for candidate in candidates {
            guard let candidate else { continue }
            if let url = URLSanitizer.validatedServerURL(from: candidate) {
                return url
            }
        }
        return nil
    }
}
