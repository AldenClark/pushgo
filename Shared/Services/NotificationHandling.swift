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
        guard let normalized = NotificationHandling.normalizeRemoteNotification(payload) else {
            return .rejected
        }

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

    static func shouldSkipPersistence(for payload: [AnyHashable: Any]) -> Bool {
        let sanitized = UserInfoSanitizer.sanitize(payload)
        return normalizedPayloadBoolean(sanitized["_skip_persist"]) == true
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
}
