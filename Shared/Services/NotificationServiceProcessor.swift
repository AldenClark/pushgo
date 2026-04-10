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
        let content = await prepareContentForPersistence(request: request, content: content)
        let shouldSkipPersist = (content.userInfo["_skip_persist"] as? String) == "1"
        if !shouldSkipPersist {
            await persistMessage(for: request, content: content)
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

    private func applyUnresolvedWakeupNotice(to content: UNMutableNotificationContent) {
        content.title = "收到消息"
        content.body = "收到无法解析的消息。"
        var userInfo = content.userInfo
        userInfo["_skip_persist"] = "1"
        userInfo["_wakeup_unresolved"] = "1"
        content.userInfo = userInfo
    }
}
