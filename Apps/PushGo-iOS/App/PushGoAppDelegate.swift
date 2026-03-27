import SwiftUI
import UserNotifications

import UIKit

final class PushGoAppDelegate: NSObject, UIApplicationDelegate, @preconcurrency UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions _: [UIApplication.LaunchOptionsKey: Any]? = nil,
    ) -> Bool {
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
        AppleNotificationDelegateFlow.handleWillPresent(
            notification: notification,
            onPureWakeup: { [notification] in
                await AppEnvironment.shared.triggerPrivateWakeupPull(
                    presentLocalNotifications: false,
                    deliveryId: NotificationHandling.extractDeliveryId(
                        from: notification.request.content.userInfo
                    )
                )
            },
            onRegularNotification: { [notification] in
                let persistenceOutcome = await AppEnvironment.shared.persistNotificationIfNeeded(
                    notification
                )
                let persisted: Bool
                switch persistenceOutcome {
                case .persistedMain:
                    persisted = true
                case .persistedPending, .duplicate, .rejected, .failed:
                    persisted = false
                }
                guard persisted else { return nil }
                await AppEnvironment.shared.reloadMessagesFromStore()
                let shouldPresent = AppEnvironment.shared.shouldPresentForegroundNotification(
                    payload: notification.request.content.userInfo
                )
                return shouldPresent ? [.banner, .list, .sound, .badge] : nil
            },
            completionHandler: completionHandler
        )
    }

    private func remoteNotificationCorePersist(
        _ userInfo: [AnyHashable: Any]
    ) async -> Bool {
        guard let normalized = NotificationHandling.normalizeRemoteNotification(userInfo) else {
            return false
        }
        let persisted = await AppEnvironment.shared.addLocalMessage(
            title: normalized.title,
            body: normalized.body,
            channel: normalized.channel,
            url: normalized.url,
            rawPayload: normalized.rawPayload,
            decryptionState: normalized.decryptionState,
            messageId: normalized.messageId,
            operationId: normalized.operationId,
            titleWasExplicit: normalized.hasExplicitTitle
        )
        if persisted {
            await AppEnvironment.shared.reloadMessagesFromStore()
        }
        return persisted
    }

    private func remoteNotificationPureWakeupPull(
        _ userInfo: [AnyHashable: Any]
    ) async {
        await AppEnvironment.shared.triggerPrivateWakeupPull(
            presentLocalNotifications: false,
            deliveryId: NotificationHandling.extractDeliveryId(from: userInfo)
        )
    }

    private func handleRemoteNotification(_ userInfo: [AnyHashable: Any]) async {
        await AppleNotificationDelegateFlow.handleRemoteNotification(
            userInfo: userInfo,
            onPureWakeup: { [userInfo] in
                await self.remoteNotificationPureWakeupPull(userInfo)
            },
            onRegularNotification: { [self] payload in
                await self.remoteNotificationCorePersist(payload)
            },
            onRegularNotificationFailed: { [self] in
                await self.postPersistenceFailureNotification()
            }
        )
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

    func applicationDidEnterBackground(_: UIApplication) {}

    func applicationWillEnterForeground(_: UIApplication) {}

    func userNotificationCenter(
        _: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if NotificationHandling.isPurePrivateWakeupPayload(response.notification.request.content.userInfo) {
            let deliveryId = NotificationHandling.extractDeliveryId(
                from: response.notification.request.content.userInfo
            )
            Task { @MainActor in
                await AppEnvironment.shared.triggerPrivateWakeupPull(
                    presentLocalNotifications: false,
                    deliveryId: deliveryId
                )
                await handlePurePrivateWakeupResponse(response)
                completionHandler()
            }
            return
        }
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

    private func postPersistenceFailureNotification() async {
        let content = UNMutableNotificationContent()
        content.title = "收到消息"
        content.body = "消息已收到，但入库失败。"
        content.sound = .default
        content.categoryIdentifier = AppConstants.notificationDefaultCategoryIdentifier
        content.userInfo = [
            "_skip_persist": "1",
            "_persist_failed": "1",
            "_notification_source": "persistence_failure"
        ]
        let request = UNNotificationRequest(
            identifier: "persistence.failure.\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        try? await UNUserNotificationCenter.current().add(request)
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

    private func handlePurePrivateWakeupResponse(_ response: UNNotificationResponse) async {
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier else { return }
        let userInfo = response.notification.request.content.userInfo
        if let entityTarget = NotificationHandling.entityOpenTargetComponents(from: userInfo) {
            await AppEnvironment.shared.handleNotificationOpen(
                entityType: entityTarget.entityType,
                entityId: entityTarget.entityId
            )
            return
        }
        if let messageId = extractMessageId(from: userInfo) {
            await AppEnvironment.shared.handleNotificationOpen(messageId: messageId)
            return
        }
        await AppEnvironment.shared.handleNotificationOpen(
            notificationRequestId: response.notification.request.identifier
        )
    }

    private nonisolated func extractMessageId(from payload: [String: Any]) -> String? {
        MessageIdExtractor.extract(from: payload)
    }

    private nonisolated func extractMessageId(from userInfo: [AnyHashable: Any]) -> String? {
        NotificationHandling.extractMessageId(from: userInfo)
    }

}
