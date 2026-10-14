import Foundation
import UserNotifications
import WatchKit

@MainActor
final class PushGoWatchAppDelegate: NSObject, WKApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching() {
        PushGoAnimatedImageRuntime.bootstrapIfNeeded()
        UNUserNotificationCenter.current().delegate = self

        _ = AppEnvironment.shared
#if DEBUG
        guard !WatchQualityRuntime.isHermeticRequested else { return }
#endif
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
            let shouldDropDuplicate = if AppEnvironment.shared.isStandaloneMode,
                                        response.actionIdentifier != PushGoNotificationActionPolicy.deleteMessageActionIdentifier {
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
            let lightMessage: WatchLightMessage? = if actionID == PushGoNotificationActionPolicy.deleteMessageActionIdentifier {
                nil
            } else {
                await resolveLightMessage(for: response.notification)
            }
            if AppEnvironment.shared.isStandaloneMode,
               actionID != PushGoNotificationActionPolicy.deleteMessageActionIdentifier {
                await AppEnvironment.shared.persistNotificationIfNeeded(response.notification)
            }

            switch actionID {
            case UNNotificationDismissActionIdentifier:
                if entityTarget != nil {
                    removeDeliveredNotification(requestId: requestId)
                } else if let lightMessage {
                        _ = try? await AppEnvironment.shared.dataStore.markWatchLightMessageRead(
                            messageId: lightMessage.messageId
                        )
                    await AppEnvironment.shared.refreshWatchLightCountsAndNotify()
                } else {
                    removeDeliveredNotification(requestId: requestId)
                }
            case PushGoNotificationActionPolicy.markReadActionIdentifier:
                if let lightMessage {
                        _ = try? await AppEnvironment.shared.dataStore.markWatchLightMessageRead(
                            messageId: lightMessage.messageId
                        )
                    removeDeliveredNotification(requestId: requestId)
                    await AppEnvironment.shared.refreshWatchLightCountsAndNotify()
                } else {
                    removeDeliveredNotification(requestId: requestId)
                }
            case PushGoNotificationActionPolicy.deleteMessageActionIdentifier:
                await AppEnvironment.shared.requestNotificationDeletion(response.notification)
                removeDeliveredNotification(requestId: requestId)
            case PushGoNotificationActionPolicy.openEntityActionIdentifier,
                 PushGoNotificationActionPolicy.openRelatedEntityActionIdentifier:
                if let entityTarget {
                    await AppEnvironment.shared.handleNotificationOpen(
                        entityType: entityTarget.entityType,
                        entityId: entityTarget.entityId
                    )
                } else {
                    await AppEnvironment.shared.handleNotificationOpen(notificationRequestId: requestId)
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
        try? await AppEnvironment.shared.loadNotificationMessage(for: notification)
    }

}
