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

#if !os(watchOS)
enum NotificationPersistenceOutcome {
    case persistedMain(PushMessage)
    case persistedPending(PushMessage)
    case duplicate
    case rejected
    case failed
}

enum ProviderWakeupResolution {
    case notWakeup
    case pulled(payload: [AnyHashable: Any], requestIdentifier: String)
    case unresolvedWakeup
}

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
        let normalized = NotificationHandling.normalizeRemoteNotification(payload)
            ?? NotificationHandling.fallbackNormalizedRemoteNotification(payload)
        guard let normalized else { return .rejected }

        var rawPayload = normalized.rawPayload.reduce(into: [String: AnyCodable]()) { result, element in
            result[element.key] = AnyCodable(element.value)
        }
        let resolvedRequestIdentifier = normalizedText(requestIdentifier)
            ?? normalizedText(rawPayload["delivery_id"]?.value as? String)
        if let resolvedRequestIdentifier {
            rawPayload["_notificationRequestId"] = AnyCodable(resolvedRequestIdentifier)
        }

        return await persistNormalizedPayload(
            title: normalized.title,
            body: normalized.body,
            hasExplicitTitle: normalized.hasExplicitTitle,
            channel: normalized.channel,
            url: normalized.url,
            decryptionState: normalized.decryptionState,
            rawPayload: rawPayload,
            messageId: normalized.messageId,
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
        if NotificationHandling.shouldSkipPersistence(for: content.userInfo) {
            return .rejected
        }

        let normalized = NotificationPayloadNormalizer.normalize(
            content: content,
            requestId: request.identifier
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
           let eventId = eventIdentifierForTitleFallback(from: resolvedRawPayload),
           let storedTitle = await resolveStoredEventTitle(eventId: eventId, dataStore: dataStore)
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

    private static func resolveStoredEventTitle(
        eventId: String,
        dataStore: LocalDataStore
    ) async -> String? {
        let normalizedEventId = eventId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedEventId.isEmpty else { return nil }
        let messages = try? await dataStore.loadEventMessagesForProjection(eventId: normalizedEventId)
        return messages?
            .lazy
            .map { $0.title.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty })
    }

    private static func eventIdentifierForTitleFallback(
        from payload: [String: AnyCodable]
    ) -> String? {
        let entityType = payloadText(payload, keys: ["entity_type"])?.lowercased()
        let eventId = payloadText(payload, keys: ["event_id"])
        guard eventId != nil else { return nil }
        if entityType == nil || entityType == "event" {
            return eventId
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

    private static func normalizedText(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}
#endif

enum NotificationHandling {
#if !os(watchOS)
    struct ForegroundPresentationDecision: Equatable {
        let shouldReloadCounts: Bool
        let shouldPresentAlert: Bool
    }

    private struct WakeupServerCandidate {
        let config: ServerConfig
        let source: String
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

#if !os(watchOS)
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
        guard let normalized = NotificationPayloadSemantics.normalizeRemoteNotification(
            userInfo,
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
            decryptionState: normalized.decryptionStateRaw.flatMap(PushMessage.DecryptionState.init(rawValue:)),
            messageId: normalized.messageId,
            operationId: normalized.operationId,
            entityType: normalized.entityType,
            entityId: normalized.entityId,
            thingId: normalized.thingId
        )
    }

    #if !os(watchOS)
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
        let title = (sanitized["title"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedTitle: String
        if let title, !title.isEmpty {
            normalizedTitle = title
        } else {
            normalizedTitle = "收到消息"
        }
        let body = (sanitized["body"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedBody: String
        if let body, !body.isEmpty {
            normalizedBody = body
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
            .flatMap(PushMessage.DecryptionState.init(rawValue:))
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
    #endif

    static func shouldSkipPersistence(for payload: [AnyHashable: Any]) -> Bool {
        let sanitized = UserInfoSanitizer.sanitize(payload)
        return normalizedPayloadBoolean(sanitized["_skip_persist"]) == true
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

#if !os(watchOS)
    static func resolveProviderWakeup(
        from payload: [AnyHashable: Any],
        dataStore: LocalDataStore,
        fallbackServerConfig _: ServerConfig? = nil,
        channelSubscriptionService: ChannelSubscriptionService
    ) async -> ProviderWakeupResolution {
        let sanitized = UserInfoSanitizer.sanitize(payload)
        guard let deliveryId = providerWakeupPullDeliveryId(from: sanitized) else {
            return .notWakeup
        }
        let candidates = await activeServerConfigsForWakeupIngress(
            dataStore: dataStore,
            payload: sanitized
        )
        guard !candidates.isEmpty else {
            return .unresolvedWakeup
        }

        for candidate in candidates {
            do {
                guard let item = try await channelSubscriptionService.pullMessage(
                    baseURL: candidate.config.baseURL,
                    token: candidate.config.token,
                    deliveryId: deliveryId
                ) else {
                    continue
                }
                let pulledPayload: [AnyHashable: Any] = item.payload.reduce(into: [:]) { result, element in
                    result[element.key] = element.value
                }
                return .pulled(
                    payload: UserInfoSanitizer.sanitize(pulledPayload),
                    requestIdentifier: normalizedPayloadString(item.deliveryId) ?? deliveryId
                )
            } catch {
                continue
            }
        }

        return .unresolvedWakeup
    }

    static func applyResolvedPayload(
        _ payload: [AnyHashable: Any],
        to content: UNMutableNotificationContent
    ) {
        let userInfo = UserInfoSanitizer.sanitize(payload)
        content.userInfo = userInfo
        if let normalized = normalizeRemoteNotification(userInfo) {
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
#endif

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

#if !os(watchOS)
    private static func activeServerConfigsForWakeupIngress(
        dataStore: LocalDataStore,
        payload: [String: Any]
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
            let urls = await dataStore.loadGatewayURLsForChannel(
                channelId: channelId,
                includeDeleted: true
            )
            for url in urls {
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

        return candidates
    }

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
#endif
}
