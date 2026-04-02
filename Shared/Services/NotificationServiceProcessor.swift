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
        let content = await prepareContent(request: request, content: content)
        let shouldSkipPersist = (content.userInfo["_skip_persist"] as? String) == "1"
        if !shouldSkipPersist {
            await persistMessage(for: request, content: content)
        }
        return content
    }

    func prepareContent(
        request: UNNotificationRequest,
        content: UNMutableNotificationContent
    ) async -> UNMutableNotificationContent {
        await pullProviderWakeupIfNeeded(content: content)
        return await contentPreparer.prepare(content)
    }

    private func pullProviderWakeupIfNeeded(content: UNMutableNotificationContent) async {
        guard let deliveryId = NotificationHandling.providerWakeupPullDeliveryId(
            from: content.userInfo
        ) else {
            return
        }
        guard let config = try? await localDataStore.loadServerConfig() else {
            return
        }
        guard let item = try? await channelSubscriptionService.pullMessage(
            baseURL: config.baseURL,
            token: config.token,
            deliveryId: deliveryId
        ) else {
            return
        }
        NotificationHandling.applyPulledPayload(item.payload, to: content)
    }

    private func persistMessage(for request: UNNotificationRequest, content: UNMutableNotificationContent) async {
        let store = localDataStore
        var unreadCount = 1
        var persistenceFailed = false
        var shouldNotifyStoreChanged = false
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
    }

    private func applyPersistenceFailureNotice(to content: UNMutableNotificationContent) {
        content.title = "收到消息"
        content.body = "消息已收到，但入库失败。"
        var userInfo = content.userInfo
        userInfo["_skip_persist"] = "1"
        userInfo["_persist_failed"] = "1"
        content.userInfo = userInfo
    }
}
