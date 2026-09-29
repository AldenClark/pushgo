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

// Values are sanitized into immutable Foundation property-list leaves before
// construction. The legacy dictionary type itself cannot express Sendable.
enum ProviderWakeupResolution: @unchecked Sendable {
    case notWakeup
    case recoveredDurable(payload: [AnyHashable: Any], requestIdentifier: String)
    case pulled(payload: [AnyHashable: Any], requestIdentifier: String, context: ProviderPullContext)
    case claimedByPeer(payload: [AnyHashable: Any], requestIdentifier: String?)
    case unresolvedWakeup(payload: [AnyHashable: Any], requestIdentifier: String?)
}

enum NotificationIngressResolution: @unchecked Sendable {
    case direct(payload: [AnyHashable: Any], requestIdentifier: String?)
    case pulled(payload: [AnyHashable: Any], requestIdentifier: String, context: ProviderPullContext)
    case claimedByPeer(payload: [AnyHashable: Any], requestIdentifier: String?)
    case unresolvedWakeup(payload: [AnyHashable: Any], requestIdentifier: String?)
}

struct ProviderPullContext: Sendable {
    let contract: ChannelSubscriptionService.PullContract
    let baseURL: URL
    let token: String?
    let deviceKey: String
    let claimLease: ProviderWakeupPullClaimStore.ClaimLease

    var requiresAck: Bool { contract == .v2 }
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
    struct EncryptedMessageRecoveryReport: Equatable, Sendable {
        let examinedCount: Int
        let updatedCount: Int
        let decryptedCount: Int
    }

    struct RemotePayload: @unchecked Sendable {
        let payload: [AnyHashable: Any]
        let requestIdentifier: String?

        init(payload: [AnyHashable: Any], requestIdentifier: String?) {
            // Snapshot property-list values before the first async suspension;
            // a caller may otherwise retain mutable Foundation objects.
            self.payload = UserInfoSanitizer.sanitize(payload).reduce(
                into: [AnyHashable: Any]()
            ) { result, entry in
                result[entry.key] = entry.value
            }
            self.requestIdentifier = requestIdentifier
        }
    }

    static func persistRemotePayloadIfNeeded(
        _ payload: [AnyHashable: Any],
        requestIdentifier: String? = nil,
        dataStore: LocalDataStore,
        beforeSave: (@Sendable (PushMessage) async -> Void)? = nil
    ) async -> NotificationPersistenceOutcome {
        await persistRemotePayloadsIfNeeded(
            [RemotePayload(payload: payload, requestIdentifier: requestIdentifier)],
            dataStore: dataStore,
            beforeSave: beforeSave
        ).first ?? .failed
    }

    static func recoverEncryptedMessages(
        using material: ServerConfig.NotificationKeyMaterial,
        dataStore: LocalDataStore
    ) async throws -> EncryptedMessageRecoveryReport {
        let candidates = try await dataStore.loadMessages().filter { message in
            guard message.decryptionState != .decryptOk else { return false }
            let ciphertext = (message.rawPayload["ciphertext"]?.value as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return ciphertext?.isEmpty == false
                || InlineCipherEnvelope.looksLikeCiphertext(
                    message.rawPayload["title"]?.value as? String ?? ""
                )
                || InlineCipherEnvelope.looksLikeCiphertext(
                    message.rawPayload["body"]?.value as? String ?? ""
                )
        }
        var replacements: [PushMessage] = []
        replacements.reserveCapacity(candidates.count)
        var decryptedCount = 0

        for existing in candidates {
            let payload = Dictionary<AnyHashable, Any>(
                uniqueKeysWithValues: existing.rawPayload.map { key, value in
                    (AnyHashable(key), value.value)
                }
            )
            let content = await preparedContentForPersistence(from: payload, material: material)
            guard let reparsed = await prepareMessageForPersistence(
                content: content,
                requestIdentifier: existing.notificationRequestId,
                fallbackRequestIdentifier: existing.messageId ?? existing.id.uuidString,
                dataStore: dataStore
            ) else { continue }

            if reparsed.decryptionState == .decryptOk {
                decryptedCount += 1
            }
            replacements.append(PushMessage(
                id: existing.id,
                messageId: existing.messageId,
                title: reparsed.title,
                body: reparsed.body,
                channel: reparsed.channel,
                url: reparsed.url,
                isRead: existing.isRead,
                receivedAt: existing.receivedAt,
                rawPayload: reparsed.rawPayload,
                status: existing.status,
                decryptionState: reparsed.decryptionState
            ))
        }

        if !replacements.isEmpty {
            try await dataStore.saveMessages(replacements)
        }
        return EncryptedMessageRecoveryReport(
            examinedCount: candidates.count,
            updatedCount: replacements.count,
            decryptedCount: decryptedCount
        )
    }

    /// Prepares a bounded ingress batch outside the canonical transaction, then
    /// commits every valid message in one GRDB write while preserving an outcome
    /// for each original payload.
    static func persistRemotePayloadsIfNeeded(
        _ inputs: [RemotePayload],
        dataStore: LocalDataStore,
        beforeSave: (@Sendable (PushMessage) async -> Void)? = nil
    ) async -> [NotificationPersistenceOutcome] {
        guard !inputs.isEmpty else { return [] }
        var results = Array<NotificationPersistenceOutcome?>(
            repeating: nil,
            count: inputs.count
        )
        var prepared: [(index: Int, message: PushMessage)] = []
        prepared.reserveCapacity(inputs.count)

        for (index, input) in inputs.enumerated() {
            if NotificationHandling.shouldSkipPersistence(for: input.payload) {
                results[index] = .rejected
                continue
            }
            let content = await preparedContentForPersistence(from: input.payload)
            let fallbackRequestIdentifier = normalizedText(input.requestIdentifier)
                ?? normalizedText(content.userInfo["delivery_id"] as? String)
                ?? UUID().uuidString
            guard let message = await prepareMessageForPersistence(
                content: content,
                requestIdentifier: input.requestIdentifier,
                fallbackRequestIdentifier: fallbackRequestIdentifier,
                dataStore: dataStore,
                beforeSave: beforeSave
            ) else {
                results[index] = .rejected
                continue
            }
            prepared.append((index, message))
        }

        guard !prepared.isEmpty else {
            return results.map { $0 ?? .rejected }
        }
        do {
            let outcomes = try await dataStore.persistNotificationMessagesIfNeeded(
                prepared.map(\.message)
            )
            guard outcomes.count == prepared.count else {
                for item in prepared { results[item.index] = .failed }
                return results.map { $0 ?? .failed }
            }
            for (item, outcome) in zip(prepared, outcomes) {
                results[item.index] = persistenceOutcome(from: outcome)
            }
        } catch {
            for item in prepared { results[item.index] = .failed }
        }
        return results.map { $0 ?? .failed }
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
        guard let message = await prepareMessageForPersistence(
            content: await preparedContentForPersistence(from: content),
            requestIdentifier: requestIdentifier,
            fallbackRequestIdentifier: fallbackRequestIdentifier,
            dataStore: dataStore,
            beforeSave: beforeSave
        ) else { return .rejected }
        do {
            return persistenceOutcome(
                from: try await dataStore.persistNotificationMessageIfNeeded(message)
            )
        } catch {
            return .failed
        }
    }

    private static func prepareMessageForPersistence(
        content: UNNotificationContent,
        requestIdentifier: String?,
        fallbackRequestIdentifier: String,
        dataStore: LocalDataStore,
        beforeSave: (@Sendable (PushMessage) async -> Void)? = nil
    ) async -> PushMessage? {
        if NotificationHandling.shouldSkipPersistence(for: content.userInfo) {
            return nil
        }
        let resolvedRequestIdentifier = normalizedText(requestIdentifier)
            ?? normalizedText(fallbackRequestIdentifier)
            ?? UUID().uuidString
        let normalized = NotificationPayloadNormalizer.normalize(
            content: content,
            requestId: resolvedRequestIdentifier
        )
        var resolvedTitle = normalized.title
        if !normalized.hasExplicitTitle,
           let storedTitle = await resolveStoredEntityTitle(
               from: normalized.rawPayload,
               dataStore: dataStore
           )
        {
            resolvedTitle = storedTitle
        }

        let receivedAt = PayloadTimeParser.date(from: normalized.rawPayload["sent_at"]) ?? Date()
        let message = PushMessage(
            messageId: normalized.messageId,
            title: resolvedTitle,
            body: normalized.body,
            channel: normalized.channel,
            url: normalized.url,
            isRead: false,
            receivedAt: receivedAt,
            rawPayload: normalized.rawPayload,
            status: .normal,
            decryptionState: normalized.decryptionState
        )
        await beforeSave?(message)
        return message
    }

    private static func persistenceOutcome(
        from outcome: NotificationStoreSaveOutcome
    ) -> NotificationPersistenceOutcome {
        switch outcome {
        case let .persisted(stored):
            return .persistedMain(stored)
        case let .persistedPending(stored):
            return .persistedPending(stored)
        case .duplicateRequest, .duplicateMessage:
            return .duplicate
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
            let detail = try? await dataStore.loadThingProjectionDetail(thingId: normalizedThingId)
            return detail?.messages
                .lazy
                .map { $0.title.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first(where: { !$0.isEmpty })
        }

        if entityType == "event" || (entityType == nil && payloadText(payload, keys: ["event_id"]) != nil),
           let eventId = payloadText(payload, keys: ["event_id", "entity_id"])
        {
            let normalizedEventId = eventId.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedEventId.isEmpty else { return nil }
            let detail = try? await dataStore.loadEventProjectionDetail(eventId: normalizedEventId)
            return detail?.messages
                .lazy
                .map { $0.title.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first(where: {
                    !$0.isEmpty && !isSyntheticEntityFallbackTitle(
                        $0,
                        entityType: "event",
                        entityId: normalizedEventId
                    )
                })
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

    private static func isSyntheticEntityFallbackTitle(
        _ title: String,
        entityType: String,
        entityId: String
    ) -> Bool {
        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedEntityId = entityId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTitle.isEmpty, !normalizedEntityId.isEmpty else { return false }
        let typeLabels: [String]
        switch entityType {
        case "event":
            typeLabels = ["Event", LocalizationProvider.localized("push_type_event")]
        case "thing":
            typeLabels = ["Thing", LocalizationProvider.localized("push_type_thing")]
        default:
            typeLabels = []
        }
        return typeLabels.contains { label in
            let normalizedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
            return !normalizedLabel.isEmpty && normalizedTitle == "\(normalizedLabel) \(normalizedEntityId)"
        }
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
        await preparedContentForPersistence(
            from: payload,
            material: try? LocalKeychainConfigStore().loadServerConfig()?.notificationKeyMaterial
        )
    }

    private static func preparedContentForPersistence(
        from payload: [AnyHashable: Any],
        material: ServerConfig.NotificationKeyMaterial?
    ) async -> UNNotificationContent {
        let sanitizedPayload = UserInfoSanitizer.sanitize(payload)
        let mutableContent = UNMutableNotificationContent()
        mutableContent.userInfo = sanitizedPayload
        mutableContent.title = (sanitizedPayload["title"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        mutableContent.body = (sanitizedPayload["body"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return prepareDecryptedContentForPersistence(from: mutableContent, material: material)
    }

    private static func preparedContentForPersistence(
        from content: UNNotificationContent
    ) async -> UNNotificationContent {
        guard let mutableContent = content.mutableCopy() as? UNMutableNotificationContent else {
            return content
        }
        return prepareDecryptedContentForPersistence(
            from: mutableContent,
            material: try? LocalKeychainConfigStore().loadServerConfig()?.notificationKeyMaterial
        )
    }

    private static func prepareDecryptedContentForPersistence(
        from content: UNMutableNotificationContent,
        material: ServerConfig.NotificationKeyMaterial?
    ) -> UNNotificationContent {
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
            },
            localizeThingUpdatedBody: {
                LocalizationProvider.localized("updated")
            },
            localizeThingArchivedBody: {
                LocalizationProvider.localized("archived")
            },
            localizeThingDeletedBody: {
                LocalizationProvider.localized("deleted")
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
    @MainActor
    static func resolveNotificationIngress(
        from payload: [AnyHashable: Any],
        dataStore: LocalDataStore,
        fallbackServerConfig: ServerConfig? = nil,
        channelSubscriptionService: ChannelSubscriptionService,
        notificationIngressInbox: NotificationIngressInbox = .shared,
        allowLegacyFallback: Bool = true
    ) async -> NotificationIngressResolution {
        let sanitized = UserInfoSanitizer.sanitize(payload)
        let resolution = await resolveProviderWakeup(
            from: sanitized,
            dataStore: dataStore,
            fallbackServerConfig: fallbackServerConfig,
            channelSubscriptionService: channelSubscriptionService,
            notificationIngressInbox: notificationIngressInbox,
            allowLegacyFallback: allowLegacyFallback
        )
        switch resolution {
        case .notWakeup:
            return .direct(
                payload: sanitized,
                requestIdentifier: providerIngressRequestIdentifier(from: sanitized)
            )
        case let .recoveredDurable(resolvedPayload, requestIdentifier):
            return .direct(payload: resolvedPayload, requestIdentifier: requestIdentifier)
        case let .pulled(resolvedPayload, requestIdentifier, context):
            return .pulled(
                payload: resolvedPayload,
                requestIdentifier: requestIdentifier,
                context: context
            )
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
        case let .direct(payload, _):
            if providerWakeupPullDeliveryId(from: payload) != nil {
                return nil
            }
            return providerIngressRequestIdentifier(from: payload)
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
    @MainActor
    static func resolveProviderWakeup(
        from payload: [AnyHashable: Any],
        dataStore: LocalDataStore,
        fallbackServerConfig: ServerConfig? = nil,
        channelSubscriptionService: ChannelSubscriptionService,
        notificationIngressInbox: NotificationIngressInbox = .shared,
        allowLegacyFallback: Bool = true
    ) async -> ProviderWakeupResolution {
        let sanitized = UserInfoSanitizer.sanitize(payload)
        guard let deliveryId = providerWakeupPullDeliveryId(from: sanitized) else {
            return .notWakeup
        }
        let durableHint = sanitized.reduce(
            into: [String: AnyCodable]()
        ) { result, element in
            result[element.key] = AnyCodable(element.value)
        }
        guard await notificationIngressInbox.enqueue(
            codablePayload: durableHint,
            requestIdentifier: deliveryId,
            source: "provider.host.wakeup_hint",
            ackIdentity: nil,
            requiredEntryState: "durable"
        ) else {
            return .unresolvedWakeup(payload: sanitized, requestIdentifier: deliveryId)
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
        // A legacy pull is destructive. If a prior process already journaled
        // the returned bytes but crashed before canonical persistence, replay
        // those exact bytes before making any new provider request.
        for candidate in candidates {
            guard let legacyIdentity = ProviderDeliveryAckFailureStore.DeliveryIdentity(
                deliveryId: deliveryId,
                baseURL: candidate.config.baseURL,
                deviceKey: deviceKey,
                ackContract: .legacySingle
            ), let durable = await notificationIngressInbox.durablePayload(identity: legacyIdentity)
            else { continue }
            let recovered = durable.reduce(into: [AnyHashable: Any]()) { result, element in
                result[element.key] = element.value.value
            }
            guard recovered[ProviderLegacyDestructivePullMetadata.markerKey] as? String
                    == ProviderLegacyDestructivePullMetadata.markerValue
            else { continue }
            return .recoveredDurable(payload: recovered, requestIdentifier: deliveryId)
        }
        let owner = "app_wakeup_resolver"
        let leaseDuration: TimeInterval = 30
        let claimStore = ProviderWakeupPullClaimStore.shared
        for candidate in candidates {
            guard let identity = ProviderDeliveryAckFailureStore.DeliveryIdentity(
                deliveryId: deliveryId,
                baseURL: candidate.config.baseURL,
                deviceKey: deviceKey,
                ackContract: .v2Batch
            ) else {
                continue
            }
            let lease: ProviderWakeupPullClaimStore.ClaimLease
            if let acquiredLease = await claimStore.acquireLease(
                identity: identity,
                owner: owner,
                leaseDuration: leaseDuration
            ) {
                lease = acquiredLease
            } else {
                let durablePeerPayload = await claimStore
                    .durableIngressPayload(identity: identity)
                let peerPayload = durablePeerPayload?.reduce(
                    into: [AnyHashable: Any]()
                ) { result, element in
                    result[element.key] = element.value.value
                }
                let fallbackPayload = sanitized.reduce(
                    into: [AnyHashable: Any]()
                ) { result, element in
                    result[element.key] = element.value
                }
                return .claimedByPeer(
                    payload: peerPayload ?? fallbackPayload,
                    requestIdentifier: deliveryId
                )
            }
            do {
                let pullResult = try await channelSubscriptionService.pullMessages(
                    baseURL: candidate.config.baseURL,
                    token: candidate.config.token,
                    deviceKey: deviceKey,
                    deliveryId: deliveryId,
                    allowLegacyFallback: allowLegacyFallback
                )
                guard !pullResult.items.isEmpty else {
                    await claimStore.releaseLease(lease)
                    continue
                }
                var durableResults: [(payload: [AnyHashable: Any], requestIdentifier: String)] = []
                var allItemsDurable = true
                for item in pullResult.items {
                    var pulledPayload: [AnyHashable: Any] = item.payload.reduce(into: [:]) { result, element in
                        result[element.key] = element.value
                    }
                    pulledPayload["delivery_id"] = item.deliveryId
                    let requestIdentifier = normalizedPayloadString(item.deliveryId) ?? deliveryId
                    var durablePayload = UserInfoSanitizer.sanitize(pulledPayload)
                    // The delivery ID belongs to this Gateway. Keep its source
                    // with the canonical payload so another Gateway's restored
                    // database cannot make the same ID look like a replay.
                    durablePayload["base_url"] = candidate.config.baseURL.absoluteString
                    durablePayload["provider_device_key"] = deviceKey
                    let ackIdentity: ProviderDeliveryAckFailureStore.DeliveryIdentity?
                    let requiredEntryState: String
                    if pullResult.requiresAck {
                        ackIdentity = ProviderDeliveryAckFailureStore.DeliveryIdentity(
                            deliveryId: requestIdentifier,
                            baseURL: candidate.config.baseURL,
                            deviceKey: deviceKey,
                            ackContract: .v2Batch
                        )
                        requiredEntryState = "terminal_local"
                    } else {
                        durablePayload[ProviderLegacyDestructivePullMetadata.markerKey] =
                            ProviderLegacyDestructivePullMetadata.markerValue
                        ackIdentity = nil
                        requiredEntryState = "durable"
                    }
                    if pullResult.requiresAck, ackIdentity == nil {
                        allItemsDurable = false
                        continue
                    }
                    let codablePayload = durablePayload.reduce(
                        into: [String: AnyCodable]()
                    ) { result, element in
                        result[element.key] = AnyCodable(element.value)
                    }
                    guard await notificationIngressInbox.enqueue(
                        codablePayload: codablePayload,
                        requestIdentifier: requestIdentifier,
                        source: "provider.host.pulled",
                        ackIdentity: ackIdentity,
                        requiredEntryState: requiredEntryState
                    ) else {
                        allItemsDurable = false
                        continue
                    }
                    durableResults.append((durablePayload, requestIdentifier))
                }
                let selected = durableResults.first { $0.requestIdentifier == deliveryId }
                    ?? durableResults.first
                guard allItemsDurable, let selected else {
                    await claimStore.releaseLease(lease)
                    continue
                }
                return .pulled(
                    payload: selected.payload,
                    requestIdentifier: selected.requestIdentifier,
                    context: ProviderPullContext(
                        contract: pullResult.contract,
                        baseURL: candidate.config.baseURL,
                        token: candidate.config.token,
                        deviceKey: deviceKey,
                        claimLease: lease
                    )
                )
            } catch {
                await claimStore.releaseLease(lease)
                continue
            }
        }
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
    @MainActor
    private static func activeServerConfigsForWakeupIngress(
        dataStore: LocalDataStore,
        payload: [String: Any],
        fallbackServerConfig: ServerConfig?
    ) async -> [WakeupServerCandidate] {
        var candidates: [WakeupServerCandidate] = []
        var dedupe = Set<String>()
        let tokenStore = ProviderGatewayTokenStore()
        func appendCandidate(baseURL: URL, token: String?, source: String) {
            let normalizedConfig = ServerConfig(
                baseURL: baseURL,
                token: token ?? tokenStore.load(baseURL: baseURL),
                notificationKeyMaterial: nil
            ).normalized()
            let normalizedBaseURL = normalizedProviderGatewayURL(normalizedConfig.baseURL)
                ?? normalizedConfig.baseURL
            let dedupeKey = "\(normalizedBaseURL.absoluteString)|\(normalizedConfig.token ?? "")"
            guard dedupe.insert(dedupeKey).inserted else {
                return
            }
            candidates.append(
                WakeupServerCandidate(
                    config: ServerConfig(
                        baseURL: normalizedBaseURL,
                        token: normalizedConfig.token,
                        notificationKeyMaterial: normalizedConfig.notificationKeyMaterial
                    ),
                    source: source
                )
            )
        }

        if let gatewayURL = wakeupGatewayURL(from: payload) {
            appendCandidate(
                baseURL: gatewayURL,
                token: tokenStore.load(baseURL: gatewayURL),
                source: "payload.base_url"
            )
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
