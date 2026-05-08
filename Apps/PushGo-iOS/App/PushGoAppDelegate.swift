import SwiftUI
import UserNotifications

import UIKit

final class PushGoAppDelegate: NSObject, UIApplicationDelegate, @preconcurrency UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions _: [UIApplication.LaunchOptionsKey: Any]? = nil,
    ) -> Bool {
        PushGoAnimatedImageRuntime.bootstrapIfNeeded()
        AppEnvironment.shared.beginProviderIngressBootstrapRecovery()
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
                let userInfo = notification.request.content.userInfo
                let persistenceOutcome = await AppEnvironment.shared.persistNotificationIfNeeded(
                    notification
                )
                let decision = NotificationHandling.foregroundPresentationDecision(
                    persistenceOutcome: persistenceOutcome,
                    payload: userInfo
                )
                if decision.shouldReloadCounts {
                    await AppEnvironment.shared.reloadMessagesFromStore()
                }
                guard decision.shouldPresentAlert else {
                    completionHandler([])
                    return
                }
                let shouldPresent = AppEnvironment.shared.shouldPresentForegroundNotification(
                    payload: userInfo
                )
                let options: UNNotificationPresentationOptions = shouldPresent ? [.banner, .list, .sound, .badge] : []
                completionHandler(options)
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

    func applicationDidEnterBackground(_: UIApplication) {}

    func applicationWillEnterForeground(_: UIApplication) {}

    func userNotificationCenter(
        _: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let actionID = response.actionIdentifier
        let userInfo = response.notification.request.content.userInfo
        let messageId = extractMessageId(from: userInfo)
        let entityTarget = NotificationHandling.entityOpenTargetComponents(from: userInfo)
        let requestId = response.notification.request.identifier

        switch actionID {
        case UNNotificationDismissActionIdentifier:
            Task {
                await AppEnvironment.shared.persistNotificationIfNeeded(response.notification)
                if entityTarget != nil {
                    removeDeliveredNotification(requestId: requestId)
                } else {
                    await handleDismiss(response: response, messageId: messageId)
                }
                completionHandler()
            }
        case UNNotificationDefaultActionIdentifier:
            Task {
                await AppEnvironment.shared.persistNotificationIfNeeded(response.notification)
                if let entityTarget {
                    await AppEnvironment.shared.handleNotificationOpen(
                        entityType: entityTarget.entityType,
                        entityId: entityTarget.entityId
                    )
                } else if let messageId {
                    await AppEnvironment.shared.handleNotificationOpen(messageId: messageId)
                } else {
                    await AppEnvironment.shared.handleNotificationOpen(
                        notificationRequestId: requestId
                    )
                }
                completionHandler()
            }
        default:
            completionHandler()
        }
    }

    private func handleDismiss(response: UNNotificationResponse, messageId: String?) async {
        let identifier = response.notification.request.identifier
        do {
            _ = try await AppEnvironment.shared.messageStateCoordinator
                .markRead(notificationRequestId: identifier, messageId: messageId)
        } catch {
        }
    }

    private func removeDeliveredNotification(requestId: String) {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [requestId])
    }

    private nonisolated func extractMessageId(from payload: [String: Any]) -> String? {
        MessageIdExtractor.extract(from: payload)
    }

    private nonisolated func extractMessageId(from userInfo: [AnyHashable: Any]) -> String? {
        NotificationHandling.extractMessageId(from: userInfo)
    }

}
