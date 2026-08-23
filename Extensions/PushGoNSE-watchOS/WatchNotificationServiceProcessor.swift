import Foundation
import UserNotifications

private enum WatchNotificationIngressResolution {
    case direct(payload: [AnyHashable: Any], requestIdentifier: String?)
    case unresolvedWakeup(payload: [AnyHashable: Any], requestIdentifier: String?)
}

@MainActor
final class WatchNotificationServiceProcessor {
    private let contentPreparer = NotificationContentPreparer()
    private let notificationIngressInbox: NotificationIngressInbox

    init(
        notificationIngressInbox: NotificationIngressInbox = .shared
    ) {
        self.notificationIngressInbox = notificationIngressInbox
    }

    func process(
        request: UNNotificationRequest,
        content: UNMutableNotificationContent
    ) async -> UNNotificationContent {
        let sanitizedPayload = UserInfoSanitizer.sanitize(request.content.userInfo)
        if let deliveryID = providerWakeupDeliveryId(from: sanitizedPayload) {
            let durableHint = codablePayloadDictionary(from: sanitizedPayload)
            let enqueued = await notificationIngressInbox.enqueue(
                codablePayload: durableHint,
                requestIdentifier: deliveryID,
                source: "watch_nse.wakeup_hint",
                ackIdentity: nil,
                requiredEntryState: "durable"
            )
            if enqueued {
                DarwinNotificationPoster.post(name: AppConstants.notificationIngressChangedNotificationName)
            }
            // watchOS NSE presentation must not wait on Gateway I/O. The host
            // durable worker resolves both v2 and legacy provider payloads.
            let ingress = WatchNotificationIngressResolution.unresolvedWakeup(
                payload: sanitizedPayload,
                requestIdentifier: deliveryID
            )
            applyIngressPayloadIfNeeded(ingress, to: content)
            return await contentPreparer.prepare(content, includeMediaAttachments: false)
        }
        let ingress = WatchNotificationIngressResolution.direct(
            payload: sanitizedPayload,
            requestIdentifier: directRequestIdentifier(from: sanitizedPayload)
        )
        applyIngressPayloadIfNeeded(ingress, to: content)
        // The cross-process journal is the recovery boundary. Media download
        // is optional enrichment and must never consume the NSE budget before
        // the payload is durable.
        let content = await contentPreparer.prepare(content, includeMediaAttachments: false)
        let enqueued = await enqueueIngressInboxEntry(
            for: request,
            ingress: ingress,
            content: content
        )
        if enqueued {
            DarwinNotificationPoster.post(name: AppConstants.notificationIngressChangedNotificationName)
        }

        return content
    }

    @discardableResult
    private func enqueueIngressInboxEntry(
        for request: UNNotificationRequest,
        ingress: WatchNotificationIngressResolution,
        content: UNNotificationContent
    ) async -> Bool {
        let ingressRequestIdentifier: String?
        switch ingress {
        case let .direct(_, requestIdentifier):
            ingressRequestIdentifier = requestIdentifier
        case let .unresolvedWakeup(_, requestIdentifier):
            ingressRequestIdentifier = requestIdentifier
        }
        let codablePayload = codablePayloadDictionary(from: content.userInfo)
        let ackIdentity: ProviderDeliveryAckFailureStore.DeliveryIdentity?
        let requiredEntryState: String
        switch ingress {
        case let .direct(payload, _):
            ackIdentity = providerWakeupDeliveryId(from: UserInfoSanitizer.sanitize(payload)) == nil
                ? ProviderDeliveryAckFailureStore.DeliveryIdentity.direct(
                    from: UserInfoSanitizer.sanitize(payload)
                )
                : nil
            requiredEntryState = "durable"
        case .unresolvedWakeup:
            ackIdentity = nil
            requiredEntryState = "durable"
        }
        return await notificationIngressInbox.enqueue(
            codablePayload: codablePayload,
            requestIdentifier: ingressRequestIdentifier ?? request.identifier,
            source: "watch_nse",
            ackIdentity: ackIdentity,
            requiredEntryState: requiredEntryState
        )
    }

    private func codablePayloadDictionary(
        from payload: [AnyHashable: Any]
    ) -> [String: AnyCodable] {
        let sanitized = UserInfoSanitizer.sanitize(payload)
        return sanitized.reduce(into: [String: AnyCodable]()) { result, item in
            result[item.key] = AnyCodable(item.value)
        }
    }

    private func applyIngressPayloadIfNeeded(
        _ ingress: WatchNotificationIngressResolution,
        to content: UNMutableNotificationContent
    ) {
        switch ingress {
        case let .unresolvedWakeup(payload, _):
            if let fallbackPayload = wakeupFallbackDisplayPayload(from: payload) {
                applyResolvedPayload(fallbackPayload, to: content)
            } else {
                content.userInfo = UserInfoSanitizer.sanitize(payload)
                if content.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   content.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                {
                    content.title = "收到消息"
                    content.body = "消息已收到，正在同步。"
                }
            }
        case .direct:
            break
        }
    }

    private func applyResolvedPayload(
        _ payload: [AnyHashable: Any],
        to content: UNMutableNotificationContent
    ) {
        let sanitized = UserInfoSanitizer.sanitize(payload)
        content.userInfo = sanitized
        if let normalized = normalizeDisplayPayload(sanitized) {
            content.title = normalized.title
            content.body = normalized.body
        } else {
            if let title = nonEmpty(sanitized["title"] as? String) {
                content.title = title
            }
            if let body = nonEmpty(sanitized["body"] as? String) {
                content.body = body
            }
        }
    }

    private func normalizeDisplayPayload(
        _ payload: [AnyHashable: Any]
    ) -> NotificationPayloadSemantics.NormalizedPayload? {
        let contextSnapshot = NotificationContextSnapshotStore.load()
        return NotificationPayloadSemantics.normalizeRemoteNotification(
            payload,
            contextSnapshot: contextSnapshot,
            localizeTypeLabel: { entityType in
                switch entityType {
                case "event":
                    "事件"
                case "thing":
                    "对象"
                default:
                    "消息"
                }
            },
            localizeThingAttributeUpdateBody: { _ in
                "属性已更新"
            },
            localizeThingAttributePair: { name, value in
                "\(name): \(value)"
            },
            localizeThingUpdatedBody: {
                "已更新"
            },
            localizeThingArchivedBody: {
                "已归档"
            },
            localizeThingDeletedBody: {
                "已删除"
            }
        )
    }

    private func wakeupFallbackDisplayPayload(
        from payload: [AnyHashable: Any]
    ) -> [AnyHashable: Any]? {
        let sanitized = UserInfoSanitizer.sanitize(payload)
        var displayPayload: [AnyHashable: Any] = sanitized.reduce(into: [:]) { result, entry in
            result[entry.key] = entry.value
        }
        if nonEmpty(displayPayload["title"] as? String) == nil,
           let title = fallbackAlertText(from: sanitized).title
        {
            displayPayload["title"] = title
        }
        if nonEmpty(displayPayload["body"] as? String) == nil,
           let body = fallbackAlertText(from: sanitized).body
        {
            displayPayload["body"] = body
        }
        guard nonEmpty(displayPayload["title"] as? String) != nil
            || nonEmpty(displayPayload["body"] as? String) != nil
        else {
            return nil
        }
        return displayPayload
    }

    private func fallbackAlertText(
        from payload: [String: Any]
    ) -> (title: String?, body: String?) {
        let aps = payload["aps"] as? [String: Any]
        let alert = aps?["alert"]
        if let text = alert as? String {
            return (nil, nonEmpty(text))
        }
        if let dict = alert as? [String: Any] {
            return (
                nonEmpty(dict["title"] as? String) ?? nonEmpty(dict["subtitle"] as? String),
                nonEmpty(dict["body"] as? String)
            )
        }
        return (nil, nil)
    }

    private func providerWakeupDeliveryId(from payload: [String: Any]) -> String? {
        guard normalizedBoolean(payload["provider_wakeup"]) == true else {
            return nil
        }
        let mode = nonEmpty(payload["provider_mode"] as? String)?.lowercased()
        guard mode == nil || mode == "wakeup" else {
            return nil
        }
        return nonEmpty(payload["delivery_id"] as? String)
    }

    private func directRequestIdentifier(from payload: [String: Any]) -> String? {
        nonEmpty(payload["delivery_id"] as? String)
    }

    private func nonEmpty(_ raw: String?) -> String? {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private func normalizedBoolean(_ value: Any?) -> Bool? {
        switch value {
        case let bool as Bool:
            return bool
        case let number as NSNumber:
            return number.intValue != 0
        case let string as String:
            let normalized = string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            switch normalized {
            case "1", "true", "yes", "on":
                return true
            case "0", "false", "no", "off":
                return false
            default:
                return nil
            }
        default:
            return nil
        }
    }
}
