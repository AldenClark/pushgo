import SwiftUI
import UserNotifications

import UIKit

final class PushGoAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions _: [UIApplication.LaunchOptionsKey: Any]? = nil,
    ) -> Bool {
        LocalizationProvider.installTranslator { key, args in
            LocalizationManager.shared.localized(key, arguments: args)
        }
        UNUserNotificationCenter.current().delegate = self
        _ = AppEnvironment.shared
        WatchTokenReceiver.shared.activateIfNeeded()
        
        application.registerForRemoteNotifications()
        Task {
            await PushRegistrationService.shared.refreshAuthorizationStatus()
        }
        return true
    }

    func userNotificationCenter(
        _: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        Task { @MainActor in
            await AppEnvironment.shared.persistNotificationIfNeeded(notification)
            let shouldPresent = AppEnvironment.shared.shouldPresentForegroundNotification()
            if shouldPresent {
                completionHandler([.banner, .list, .sound, .badge])
            } else {
                completionHandler([])
            }
        }
    }

    func application(
        _: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data,
    ) {
        Task { @MainActor in
            PushRegistrationService.shared.handleDeviceToken(deviceToken)
            AppEnvironment.shared.handlePushTokenUpdate()
        }
    }

    func application(
        _: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error,
    ) {
        Task { @MainActor in
            PushRegistrationService.shared.handleRegistrationError(error)
        }
    }

    func application(
        _: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        Task { @MainActor in
            await handleRemoteNotification(userInfo)
            completionHandler(.newData)
        }
    }

    func userNotificationCenter(
        _: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let actionID = response.actionIdentifier
        let messageId = extractMessageId(from: response.notification.request.content.userInfo)

        switch actionID {
        case AppConstants.actionCopyIdentifier:
            Task {
                await AppEnvironment.shared.persistNotificationIfNeeded(response.notification)
                await MainActor.run {
                    self.copyFullText(from: response.notification)
                }
                if let messageId {
                    await AppEnvironment.shared.handleNotificationOpen(messageId: messageId)
                } else {
                    await AppEnvironment.shared.handleNotificationOpenFromCopy(
                        notificationRequestId: response.notification.request.identifier
                    )
                }
                await MainActor.run {
                    AppEnvironment.shared.showToast(
                        message: LocalizationManager.shared.localized("message_content_copied"),
                        style: .success,
                        duration: 1.2
                    )
                }
                completionHandler()
            }
        case AppConstants.actionMarkReadIdentifier:
            Task {
                await AppEnvironment.shared.persistNotificationIfNeeded(response.notification)
                await handleMarkRead(response: response, messageId: messageId)
                completionHandler()
            }
        case AppConstants.actionDeleteIdentifier:
            Task {
                await AppEnvironment.shared.persistNotificationIfNeeded(response.notification)
                await handleDelete(response: response, messageId: messageId)
                completionHandler()
            }
        case UNNotificationDismissActionIdentifier:
            Task {
                await AppEnvironment.shared.persistNotificationIfNeeded(response.notification)
                await handleDismiss(response: response, messageId: messageId)
                completionHandler()
            }
        case UNNotificationDefaultActionIdentifier:
            Task {
                await AppEnvironment.shared.persistNotificationIfNeeded(response.notification)
                if let messageId {
                    await AppEnvironment.shared.handleNotificationOpen(messageId: messageId)
                } else {
                    await AppEnvironment.shared.handleNotificationOpen(
                        notificationRequestId: response.notification.request.identifier
                    )
                }
                completionHandler()
            }
        default:
            completionHandler()
        }
    }

    private func copyFullText(from notification: UNNotification) {
        guard let text = NotificationHandling.notificationTextForCopy(from: notification.request.content) else {
            return
        }
        UIPasteboard.general.string = text
    }

    private func handleRemoteNotification(_ userInfo: [AnyHashable: Any]) async {
        guard let normalized = NotificationHandling.normalizeRemoteNotification(userInfo) else { return }
        await AppEnvironment.shared.addLocalMessage(
            title: normalized.title,
            body: normalized.body,
            channel: normalized.channel,
            url: normalized.url,
            rawPayload: normalized.rawPayload,
            decryptionState: normalized.decryptionState,
            messageId: normalized.messageId
        )
    }

    private func handleMarkRead(response: UNNotificationResponse, messageId: UUID?) async {
        let identifier = response.notification.request.identifier
        do {
            _ = try await AppEnvironment.shared.messageStateCoordinator
                .markRead(notificationRequestId: identifier, messageId: messageId)
        } catch {
        }
    }

    private func handleDelete(response: UNNotificationResponse, messageId: UUID?) async {
        let identifier = response.notification.request.identifier
        do {
            try await AppEnvironment.shared.messageStateCoordinator
                .deleteMessage(notificationRequestId: identifier, messageId: messageId)
        } catch {
        }
    }

    private func handleDismiss(response: UNNotificationResponse, messageId: UUID?) async {
        let identifier = response.notification.request.identifier
        do {
            _ = try await AppEnvironment.shared.messageStateCoordinator
                .markRead(notificationRequestId: identifier, messageId: messageId)
        } catch {
        }
    }

    private nonisolated func extractMessageId(from payload: [String: Any]) -> UUID? {
        MessageIdExtractor.extract(from: payload)
    }

    private nonisolated func extractMessageId(from userInfo: [AnyHashable: Any]) -> UUID? {
        NotificationHandling.extractMessageId(from: userInfo)
    }

}
