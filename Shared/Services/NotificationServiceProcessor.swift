import Foundation
import UserNotifications

final class NotificationServiceProcessor {
    private let localDataStore = LocalDataStore()
    private let contentPreparer = NotificationContentPreparer()
    private let channelSubscriptionService = ChannelSubscriptionService()

    func process(
        request: UNNotificationRequest,
        content: UNMutableNotificationContent
    ) async -> UNNotificationContent {
        let ingress = await NotificationHandling.resolveNotificationIngress(
            from: request.content.userInfo,
            dataStore: localDataStore,
            channelSubscriptionService: channelSubscriptionService
        )
        let content = await prepareContentForPersistence(content: content, ingress: ingress)
        let outcome = await persistMessage(for: request, content: content, ingress: ingress)
        if let outcome,
           let deliveryId = NotificationHandling.providerIngressAckDeliveryId(
               for: ingress,
               outcome: outcome
           )
        {
            fireAndForgetProviderIngressAck(deliveryId: deliveryId)
        }
        guard !Task.isCancelled else { return content }
        let persistenceFailed = (content.userInfo["_persist_failed"] as? String) == "1"
        guard !persistenceFailed else { return content }
        await deduplicateEntityNotificationsIfNeeded(
            currentRequestIdentifier: request.identifier,
            payload: content.userInfo
        )
        return await contentPreparer.enrichMediaIfNeeded(content)
    }

    func prepareContentForPersistence(
        content: UNMutableNotificationContent,
        ingress: NotificationIngressResolution
    ) async -> UNMutableNotificationContent {
        applyIngressPayloadIfNeeded(ingress, to: content)
        return await contentPreparer.prepare(content, includeMediaAttachments: false)
    }

    private func applyIngressPayloadIfNeeded(
        _ ingress: NotificationIngressResolution,
        to content: UNMutableNotificationContent
    ) {
        switch ingress {
        case let .pulled(payload, _):
            NotificationHandling.applyResolvedPayload(payload, to: content)
        case let .unresolvedWakeup(payload, _):
            if let fallbackPayload = NotificationHandling.wakeupFallbackDisplayPayload(from: payload) {
                NotificationHandling.applyResolvedPayload(fallbackPayload, to: content)
            } else {
                content.userInfo = UserInfoSanitizer.sanitize(payload)
                applyUnresolvedWakeupNotice(to: content)
            }
        case .direct:
            break
        }
    }

    private func persistMessage(
        for request: UNNotificationRequest,
        content: UNMutableNotificationContent,
        ingress: NotificationIngressResolution
    ) async -> NotificationPersistenceOutcome? {
        let store = localDataStore
        var unreadCount = 1
        var persistenceFailed = false
        var shouldNotifyStoreChanged = false
        var persistenceOutcome: NotificationPersistenceOutcome?
        do {
            let outcome: NotificationPersistenceOutcome
            switch ingress {
            case let .pulled(payload, requestIdentifier):
                outcome = await NotificationPersistenceCoordinator.persistRemotePayloadIfNeeded(
                    payload,
                    requestIdentifier: requestIdentifier,
                    dataStore: store
                )
            case let .direct(_, requestIdentifier):
                outcome = await NotificationPersistenceCoordinator.persistPreparedContentIfNeeded(
                    content: content,
                    requestIdentifier: requestIdentifier,
                    fallbackRequestIdentifier: request.identifier,
                    dataStore: store
                )
            case let .unresolvedWakeup(payload, requestIdentifier):
                _ = payload
                _ = requestIdentifier
                outcome = .rejected
            }
            persistenceOutcome = outcome
            switch outcome {
            case .duplicate, .persistedPending:
                await store.flushWrites()
                shouldNotifyStoreChanged = true
                let counts = try await store.messageCounts()
                unreadCount = counts.unread
            case .rejected:
                let counts = try await store.messageCounts()
                unreadCount = counts.unread
            case .failed:
                let counts = try await store.messageCounts()
                unreadCount = counts.unread
                persistenceFailed = true
            case .persistedMain:
                await store.flushWrites()
                shouldNotifyStoreChanged = true
                let counts = try await store.messageCounts()
                unreadCount = counts.unread
            }
        } catch {
            persistenceFailed = true
        }
        if shouldNotifyStoreChanged {
            DarwinNotificationPoster.post(name: AppConstants.messageSyncNotificationName)
        }
        if persistenceFailed {
            applyPersistenceFailureNotice(to: content)
        }
        content.badge = NSNumber(value: unreadCount)
        return persistenceOutcome
    }

    private func applyPersistenceFailureNotice(to content: UNMutableNotificationContent) {
        content.title = "收到消息"
        content.body = "消息已收到，但入库失败。"
        var userInfo = content.userInfo
        userInfo["_skip_persist"] = "1"
        userInfo["_persist_failed"] = "1"
        content.userInfo = userInfo
    }

    private func applyUnresolvedWakeupNotice(to content: UNMutableNotificationContent) {
        content.title = "收到消息"
        content.body = "收到无法解析的消息。"
        var userInfo = content.userInfo
        userInfo["_skip_persist"] = "1"
        userInfo["_wakeup_unresolved"] = "1"
        content.userInfo = userInfo
    }

    private func fireAndForgetProviderIngressAck(deliveryId: String) {
        let normalizedDeliveryId = deliveryId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedDeliveryId.isEmpty else { return }
        Task(priority: .utility) {
            let dataStore = LocalDataStore()
            guard let config = try? await dataStore.loadServerConfig() else {
                return
            }
            let platform = NotificationServiceProcessor.providerPullPlatformIdentifier()
            let deviceKey = await dataStore.cachedDeviceKey(for: platform)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !deviceKey.isEmpty else { return }
            do {
                _ = try await ChannelSubscriptionService().ackMessage(
                    baseURL: config.baseURL,
                    token: config.token,
                    deviceKey: deviceKey,
                    deliveryId: normalizedDeliveryId
                )
            } catch {}
        }
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
