import Foundation
import UserNotifications
import WatchKit

final class PushGoWatchAppDelegate: NSObject, WKApplicationDelegate, @preconcurrency UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching() {
        UNUserNotificationCenter.current().delegate = self

        _ = AppEnvironment.shared
        WatchSessionBridge.shared.activateIfNeeded()
    }

    func didRegisterForRemoteNotifications(withDeviceToken deviceToken: Data) {
        Task { @MainActor in
            guard AppEnvironment.shared.isStandaloneMode else { return }
            PushRegistrationService.shared.handleDeviceToken(deviceToken)
            await AppEnvironment.shared.syncWatchTokenToPhone()
        }
    }

    func didFailToRegisterForRemoteNotificationsWithError(_ error: Error) {
        Task { @MainActor in
            PushRegistrationService.shared.handleRegistrationError(error)
        }
    }

    func handle(_ backgroundTasks: Set<WKRefreshBackgroundTask>) {
        for task in backgroundTasks {
            guard let refreshTask = task as? WKApplicationRefreshBackgroundTask else {
                task.setTaskCompletedWithSnapshot(false)
                continue
            }
            Task { @MainActor in
                refreshTask.setTaskCompletedWithSnapshot(false)
            }
        }
    }

    func userNotificationCenter(
        _: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        Task { @MainActor in
            if !AppEnvironment.shared.isStandaloneMode {
                let shouldPresent = AppEnvironment.shared.shouldPresentForegroundNotification(
                    payload: notification.request.content.userInfo
                )
                completionHandler(shouldPresent ? [.banner, .list, .sound, .badge] : [])
                return
            }
            if await shouldDropDuplicateNotification(notification) {
                completionHandler([])
                return
            }
            let persisted = await AppEnvironment.shared.persistNotificationIfNeeded(notification)
            guard persisted else {
                completionHandler([])
                return
            }
            let shouldPresent = AppEnvironment.shared.shouldPresentForegroundNotification(
                payload: notification.request.content.userInfo
            )
            completionHandler(shouldPresent ? [.banner, .list, .sound, .badge] : [])
        }
    }

    func userNotificationCenter(
        _: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        Task {
            let shouldDropDuplicate = if AppEnvironment.shared.isStandaloneMode {
                await shouldDropDuplicateNotification(response.notification)
            } else {
                false
            }
            if shouldDropDuplicate {
                UNUserNotificationCenter.current().removeDeliveredNotifications(
                    withIdentifiers: [response.notification.request.identifier]
                )
                completionHandler()
                return
            }
            let actionID = response.actionIdentifier
            let requestId = response.notification.request.identifier
            let userInfo = response.notification.request.content.userInfo
            let entityTarget = NotificationHandling.entityOpenTargetComponents(from: userInfo)
            let lightMessage = await resolveLightMessage(for: response.notification)
            if AppEnvironment.shared.isStandaloneMode {
                await AppEnvironment.shared.persistNotificationIfNeeded(response.notification)
            }

            switch actionID {
            case UNNotificationDismissActionIdentifier:
                if entityTarget != nil {
                    removeDeliveredNotification(requestId: requestId)
                } else if let lightMessage {
                    if AppEnvironment.shared.isStandaloneMode {
                        _ = try? await AppEnvironment.shared.dataStore.markWatchLightMessageRead(
                            messageId: lightMessage.messageId
                        )
                    } else {
                        try? await AppEnvironment.shared.enqueueMirrorMessageAction(
                            kind: .read,
                            messageId: lightMessage.messageId
                        )
                    }
                    await AppEnvironment.shared.refreshWatchLightCountsAndNotify()
                } else {
                    removeDeliveredNotification(requestId: requestId)
                }
            default:
                if let entityTarget {
                    await AppEnvironment.shared.handleNotificationOpen(
                        entityType: entityTarget.entityType,
                        entityId: entityTarget.entityId
                    )
                } else if let lightMessage {
                    await AppEnvironment.shared.handleNotificationOpen(messageId: lightMessage.messageId)
                } else {
                    await AppEnvironment.shared.handleNotificationOpen(notificationRequestId: requestId)
                }
            }
            completionHandler()
        }
    }

    private func removeDeliveredNotification(requestId: String) {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [requestId])
    }

    private func shouldDropDuplicateNotification(_ notification: UNNotification) async -> Bool {
        guard AppEnvironment.shared.isStandaloneMode else { return false }
        if await resolveLightMessage(for: notification) != nil {
            return true
        }
        guard let entityTarget = NotificationHandling.entityOpenTargetComponents(
            from: notification.request.content.userInfo
        ) else {
            return false
        }
        if entityTarget.entityType == "event" {
            return (try? await AppEnvironment.shared.dataStore.loadWatchLightEvent(
                eventId: entityTarget.entityId
            )) != nil
        }
        if entityTarget.entityType == "thing" {
            return (try? await AppEnvironment.shared.dataStore.loadWatchLightThing(
                thingId: entityTarget.entityId
            )) != nil
        }
        return false
    }

    private func resolveLightMessage(for notification: UNNotification) async -> WatchLightMessage? {
        if let messageId = extractMessageId(from: notification.request.content.userInfo),
           let message = try? await AppEnvironment.shared.dataStore.loadWatchLightMessage(messageId: messageId)
        {
            return message
        }
        let requestId = notification.request.identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !requestId.isEmpty else {
            return nil
        }
        if let message = try? await AppEnvironment.shared.dataStore.loadWatchLightMessage(
            notificationRequestId: requestId
        ) {
            return message
        }
        if let messageId = extractMessageId(from: notification.request.content.userInfo),
           let message = try? await AppEnvironment.shared.dataStore.loadWatchLightMessage(
            notificationRequestId: messageId
           )
        {
            return message
        }
        return nil
    }

    private func extractMessageId(from payload: [AnyHashable: Any]) -> String? {
        let mapped = payload.reduce(into: [String: Any]()) { result, element in
            guard let key = element.key as? String else { return }
            result[key] = element.value
        }
        return MessageIdExtractor.extract(from: mapped)
    }

}
