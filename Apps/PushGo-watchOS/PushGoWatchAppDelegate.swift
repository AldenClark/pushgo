import Foundation
import UserNotifications
import WatchKit

final class PushGoWatchAppDelegate: NSObject, WKApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching() {
        LocalizationProvider.installTranslator { key, args in
            LocalizationManager.shared.localized(key, arguments: args)
        }
        UNUserNotificationCenter.current().delegate = self

        _ = AppEnvironment.shared
        AppEnvironment.shared.requestRemoteNotificationsIfNeeded()
        Task {
            await PushRegistrationService.shared.refreshAuthorizationStatus()
            await AppEnvironment.shared.syncWatchTokenToPhone()
        }
    }

    func didRegisterForRemoteNotifications(withDeviceToken deviceToken: Data) {
        Task { @MainActor in
            PushRegistrationService.shared.handleDeviceToken(deviceToken)
            await AppEnvironment.shared.syncWatchTokenToPhone()
        }
    }

    func didFailToRegisterForRemoteNotificationsWithError(_ error: Error) {
        Task { @MainActor in
            PushRegistrationService.shared.handleRegistrationError(error)
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
            await AppEnvironment.shared.persistNotificationIfNeeded(notification)
            let shouldPresent = AppEnvironment.shared.shouldPresentForegroundNotification()
            completionHandler(shouldPresent ? [.banner, .list, .sound, .badge] : [])
        }
    }

    func userNotificationCenter(
        _: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        Task {
            if await shouldDropDuplicateNotification(response.notification) {
                UNUserNotificationCenter.current().removeDeliveredNotifications(
                    withIdentifiers: [response.notification.request.identifier]
                )
                completionHandler()
                return
            }
            let actionID = response.actionIdentifier
            let requestId = response.notification.request.identifier
            let messageId = extractMessageId(from: response.notification.request.content.userInfo)
            await AppEnvironment.shared.persistNotificationIfNeeded(response.notification)

            switch actionID {
            case AppConstants.actionDeleteIdentifier:
                _ = try? await AppEnvironment.shared.messageStateCoordinator
                    .deleteMessage(notificationRequestId: requestId, messageId: messageId)
            case UNNotificationDismissActionIdentifier:
                _ = try? await AppEnvironment.shared.messageStateCoordinator
                    .markRead(notificationRequestId: requestId, messageId: messageId)
            default:
                if let messageId {
                    await AppEnvironment.shared.handleNotificationOpen(messageId: messageId)
                } else {
                    await AppEnvironment.shared.handleNotificationOpen(notificationRequestId: requestId)
                }
            }
            completionHandler()
        }
    }

    private func shouldDropDuplicateNotification(_ notification: UNNotification) async -> Bool {
        guard let messageId = extractMessageId(from: notification.request.content.userInfo) else {
            return false
        }
        return (try? await AppEnvironment.shared.dataStore.loadMessage(messageId: messageId)) != nil
    }

    private func extractMessageId(from payload: [AnyHashable: Any]) -> UUID? {
        let mapped = payload.reduce(into: [String: Any]()) { result, element in
            guard let key = element.key as? String else { return }
            result[key] = element.value
        }
        return MessageIdExtractor.extract(from: mapped)
    }
}
