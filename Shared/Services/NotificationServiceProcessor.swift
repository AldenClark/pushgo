import Foundation
import UserNotifications

final class NotificationServiceProcessor {
    private static let sharedNotificationIngressInbox = NotificationIngressInbox.shared

    private let contentPreparer: NotificationContentPreparer
    private let notificationIngressInbox: NotificationIngressInbox

    init(
        notificationIngressInbox: NotificationIngressInbox = NotificationServiceProcessor.sharedNotificationIngressInbox,
        contentPreparer: NotificationContentPreparer = NotificationContentPreparer()
    ) {
        self.notificationIngressInbox = notificationIngressInbox
        self.contentPreparer = contentPreparer
    }

    func process(
        request: UNNotificationRequest,
        content: UNMutableNotificationContent
    ) async -> UNNotificationContent {
        let sanitizedPayload = UserInfoSanitizer.sanitize(request.content.userInfo)
        if let deliveryID = NotificationHandling.providerWakeupPullDeliveryId(
            from: sanitizedPayload
        ) {
            let durableHint = await notificationIngressInbox.enqueueWithResult(
                codablePayload: codablePayloadDictionary(from: sanitizedPayload),
                requestIdentifier: deliveryID,
                source: "nse.wakeup_hint"
            )
            if durableHint.accepted {
                DarwinNotificationPoster.post(
                    name: AppConstants.notificationIngressChangedNotificationName
                )
            }
            // A notification service extension owns presentation only. Once the
            // hint is durable, return fallback content immediately and let the
            // host/BG worker own every provider network request.
            let unresolved = NotificationIngressResolution.unresolvedWakeup(
                payload: sanitizedPayload,
                requestIdentifier: deliveryID
            )
            let preparedContent = await prepareContentForPersistence(
                content: content,
                ingress: unresolved
            )
            if durableHint.accepted {
                await updateProjectionAndBadge(
                    content: preparedContent,
                    requestIdentifier: deliveryID,
                    insertedUnread: durableHint.inserted
                )
            }
            return preparedContent
        }
        let ingress = NotificationIngressResolution.direct(
            payload: sanitizedPayload,
            requestIdentifier: NotificationHandling.providerIngressRequestIdentifier(
                from: sanitizedPayload
            )
        )
        let content = await prepareContentForPersistence(content: content, ingress: ingress)
        let enqueueResult = await enqueueIngressInboxEntry(
            for: request,
            ingress: ingress,
            preparedContent: content
        )
        if enqueueResult.accepted {
            await updateProjectionAndBadge(
                content: content,
                requestIdentifier: requestIdentifier(for: request, ingress: ingress),
                insertedUnread: enqueueResult.inserted
            )
            DarwinNotificationPoster.post(name: AppConstants.notificationIngressChangedNotificationName)
        }
        // Presentation stops at the durable ingress boundary. ACK,
        // notification de-duplication and media enrichment are
        // recoverable/background work and must not consume the NSE deadline.
        return content
    }

    private func updateProjectionAndBadge(
        content: UNMutableNotificationContent,
        requestIdentifier: String,
        insertedUnread: Bool
    ) async {
        guard let update = await PushGoNotificationProjectionUpdater.update(
            content: content,
            requestIdentifier: requestIdentifier,
            insertedUnread: insertedUnread
        ) else {
            return
        }

        // setBadgeCount updates the badge immediately when the extension runs;
        // embedding the same value in the delivered content lets the system
        // apply it even if the host app remains suspended.
        content.badge = NSNumber(value: update.unreadCount)
    }

    func prepareContentForPersistence(
        content: UNMutableNotificationContent,
        ingress: NotificationIngressResolution
    ) async -> UNMutableNotificationContent {
        applyIngressPayloadIfNeeded(ingress, to: content)
        return await contentPreparer.prepare(content, includeMediaAttachments: false)
    }

    @discardableResult
    private func enqueueIngressInboxEntry(
        for request: UNNotificationRequest,
        ingress: NotificationIngressResolution,
        preparedContent: UNMutableNotificationContent
    ) async -> NotificationIngressInbox.EnqueueResult {
        let codablePayload = codablePayloadDictionary(from: preparedContent.userInfo)
        let ackIdentity: ProviderDeliveryAckFailureStore.DeliveryIdentity?
        let requiredEntryState: String
        switch ingress {
        case let .direct(payload, _):
            ackIdentity = NotificationHandling.providerWakeupPullDeliveryId(from: payload) == nil
                ? ProviderDeliveryAckFailureStore.DeliveryIdentity.direct(
                    from: UserInfoSanitizer.sanitize(payload)
                )
                : nil
            requiredEntryState = "durable"
        case let .pulled(_, deliveryID, context):
            ackIdentity = context.requiresAck
                ? ProviderDeliveryAckFailureStore.DeliveryIdentity(
                    deliveryId: deliveryID,
                    baseURL: context.baseURL,
                    deviceKey: context.deviceKey,
                    ackContract: .v2Batch
                )
                : nil
            requiredEntryState = "terminal_local"
        case .claimedByPeer, .unresolvedWakeup:
            ackIdentity = nil
            requiredEntryState = "durable"
        }
        let result = await notificationIngressInbox.enqueueWithResult(
            codablePayload: codablePayload,
            requestIdentifier: requestIdentifier(for: request, ingress: ingress),
            source: "nse",
            ackIdentity: ackIdentity,
            requiredEntryState: requiredEntryState
        )
        return result
    }

    private func requestIdentifier(
        for request: UNNotificationRequest,
        ingress: NotificationIngressResolution
    ) -> String {
        let requestIdentifier: String?
        switch ingress {
        case let .direct(_, ingressRequestIdentifier):
            requestIdentifier = ingressRequestIdentifier
        case let .pulled(_, ingressRequestIdentifier, _):
            requestIdentifier = ingressRequestIdentifier
        case let .claimedByPeer(_, ingressRequestIdentifier):
            requestIdentifier = ingressRequestIdentifier
        case let .unresolvedWakeup(_, ingressRequestIdentifier):
            requestIdentifier = ingressRequestIdentifier
        }
        return requestIdentifier ?? request.identifier
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
        _ ingress: NotificationIngressResolution,
        to content: UNMutableNotificationContent
    ) {
        switch ingress {
        case let .pulled(payload, _, _):
            NotificationHandling.applyResolvedPayload(payload, to: content)
        case let .claimedByPeer(payload, _):
            if let fallbackPayload = NotificationHandling.wakeupFallbackDisplayPayload(from: payload) {
                NotificationHandling.applyResolvedPayload(fallbackPayload, to: content)
            } else {
                content.userInfo = UserInfoSanitizer.sanitize(payload)
                applyUnresolvedWakeupNotice(to: content)
            }
        case let .unresolvedWakeup(payload, _):
            if let fallbackPayload = NotificationHandling.wakeupFallbackDisplayPayload(from: payload) {
                NotificationHandling.applyResolvedPayload(fallbackPayload, to: content)
            } else {
                content.userInfo = UserInfoSanitizer.sanitize(payload)
                applyUnresolvedWakeupNotice(to: content)
            }
        case let .direct(payload, _):
            NotificationHandling.applyResolvedPayload(payload, to: content)
        }
    }

    private func applyUnresolvedWakeupNotice(to content: UNMutableNotificationContent) {
        content.title = "收到消息"
        content.body = "收到无法解析的消息。"
        var userInfo = content.userInfo
        userInfo["_skip_persist"] = "1"
        userInfo["_wakeup_unresolved"] = "1"
        content.userInfo = userInfo
    }

    private func deduplicateEntityNotificationsIfNeeded(
        currentRequestIdentifier: String,
        payload: [AnyHashable: Any]
    ) async {
        guard Self.shouldDeduplicateEntityNotification(payload: payload),
              let deliveryId = Self.normalizedPayloadString(payload["delivery_id"])
        else {
            return
        }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            UNUserNotificationCenter.current().getDeliveredNotifications { delivered in
                let deliveredDuplicates = delivered.compactMap { notification -> String? in
                    guard notification.request.identifier != currentRequestIdentifier else { return nil }
                    guard Self.shouldDeduplicateEntityNotification(
                        payload: notification.request.content.userInfo
                    ) else {
                        return nil
                    }
                    let candidateDeliveryId = Self.normalizedPayloadString(
                        notification.request.content.userInfo["delivery_id"]
                    )
                    return candidateDeliveryId == deliveryId ? notification.request.identifier : nil
                }
                if !deliveredDuplicates.isEmpty {
                    UNUserNotificationCenter.current().removeDeliveredNotifications(
                        withIdentifiers: deliveredDuplicates
                    )
                }

                UNUserNotificationCenter.current().getPendingNotificationRequests { pending in
                    let pendingDuplicates = pending.compactMap { request -> String? in
                        guard request.identifier != currentRequestIdentifier else { return nil }
                        guard Self.shouldDeduplicateEntityNotification(
                            payload: request.content.userInfo
                        ) else {
                            return nil
                        }
                        let candidateDeliveryId = Self.normalizedPayloadString(
                            request.content.userInfo["delivery_id"]
                        )
                        return candidateDeliveryId == deliveryId ? request.identifier : nil
                    }
                    if !pendingDuplicates.isEmpty {
                        UNUserNotificationCenter.current().removePendingNotificationRequests(
                            withIdentifiers: pendingDuplicates
                        )
                    }
                    continuation.resume()
                }
            }
        }
    }

    private static func shouldDeduplicateEntityNotification(payload: [AnyHashable: Any]) -> Bool {
        guard let entityType = normalizedPayloadString(payload["entity_type"])?.lowercased() else {
            return false
        }
        return entityType == "event" || entityType == "thing"
    }

    private static func normalizedPayloadString(_ value: Any?) -> String? {
        let trimmed = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

}
