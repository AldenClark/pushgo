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
        let directDeliveryId = providerIngressDeliveryId(from: request.content.userInfo)
        let isProviderWakeup = NotificationHandling.providerWakeupPullDeliveryId(
            from: request.content.userInfo
        ) != nil
        let content = await prepareContentForPersistence(request: request, content: content)
        let shouldSkipPersist = (content.userInfo["_skip_persist"] as? String) == "1"
        var shouldAckDirect = false
        if !shouldSkipPersist {
            shouldAckDirect = await persistMessage(for: request, content: content)
        }
        if !isProviderWakeup,
           shouldAckDirect,
           let deliveryId = directDeliveryId
        {
            fireAndForgetProviderDirectAck(deliveryId: deliveryId)
        }
        guard !Task.isCancelled else { return content }
        let persistenceFailed = (content.userInfo["_persist_failed"] as? String) == "1"
        guard !persistenceFailed else { return content }
        return await contentPreparer.enrichMediaIfNeeded(content)
    }

    func prepareContentForPersistence(
        request: UNNotificationRequest,
        content: UNMutableNotificationContent
    ) async -> UNMutableNotificationContent {
        await resolveProviderWakeupIfNeeded(content: content)
        return await contentPreparer.prepare(content, includeMediaAttachments: false)
    }

    private func resolveProviderWakeupIfNeeded(content: UNMutableNotificationContent) async {
        let resolution = await NotificationHandling.resolveProviderWakeup(
            from: content.userInfo,
            dataStore: localDataStore,
            channelSubscriptionService: channelSubscriptionService
        )
        if case let .pulled(payload, _) = resolution {
            NotificationHandling.applyResolvedPayload(payload, to: content)
        }
        switch resolution {
        case .notWakeup:
            break
        case .unresolvedWakeup:
            applyUnresolvedWakeupNotice(to: content)
        case .pulled:
            break
        }
    }

    private func persistMessage(
        for request: UNNotificationRequest,
        content: UNMutableNotificationContent
    ) async -> Bool {
        let store = localDataStore
        var unreadCount = 1
        var persistenceFailed = false
        var shouldNotifyStoreChanged = false
        var shouldAckDirect = false
        do {
            let outcome = await NotificationPersistenceCoordinator.persistIfNeeded(
                request: request,
                content: content,
                dataStore: store
            )
            switch outcome {
            case .duplicate, .persistedPending:
                await store.flushWrites()
                shouldNotifyStoreChanged = true
                let counts = try await store.messageCounts()
                unreadCount = counts.unread
                shouldAckDirect = true
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
                shouldAckDirect = true
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
        return shouldAckDirect
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

    private func providerIngressDeliveryId(from payload: [AnyHashable: Any]) -> String? {
        let sanitized = UserInfoSanitizer.sanitize(payload)
        let trimmed = (sanitized["delivery_id"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private func fireAndForgetProviderDirectAck(deliveryId: String) {
        let normalizedDeliveryId = deliveryId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedDeliveryId.isEmpty else { return }
        Task(priority: .utility) {
            let dataStore = LocalDataStore()
            guard let config = try? await dataStore.loadServerConfig() else {
                return
            }
            let platform = NotificationServiceProcessor.providerPullPlatformIdentifier()
            let scopedKey = await dataStore.cachedProviderDeviceKey(
                for: platform,
                channelType: "apns"
            )?.trimmingCharacters(in: .whitespacesAndNewlines)
            let legacyKey = await dataStore.cachedProviderDeviceKey(
                for: platform
            )?.trimmingCharacters(in: .whitespacesAndNewlines)
            let deviceKey = (scopedKey?.isEmpty == false ? scopedKey : legacyKey) ?? ""
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
}
