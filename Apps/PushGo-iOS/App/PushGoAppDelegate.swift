import SwiftUI
import UserNotifications

import UIKit

final class PushGoAppDelegate: NSObject, UIApplicationDelegate, @preconcurrency UNUserNotificationCenterDelegate {
    private let channelSubscriptionService = ChannelSubscriptionService()

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

    func applicationWillEnterForeground(_: UIApplication) {
        Task { @MainActor in
            _ = await AppEnvironment.shared.mergeNotificationIngressInbox(
                reason: "ios_will_enter_foreground",
                allowFallbackPull: true
            )
        }
    }

    func application(
        _: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        Task { @MainActor in
            let result = await handleRemoteNotification(userInfo)
            completionHandler(result)
        }
    }

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
        case PushGoNotificationActionPolicy.markReadActionIdentifier:
            Task {
                await AppEnvironment.shared.persistNotificationIfNeeded(response.notification)
                await markNotificationMessageRead(requestId: requestId, messageId: messageId)
                completionHandler()
            }
        case PushGoNotificationActionPolicy.deleteMessageActionIdentifier:
            Task {
                await AppEnvironment.shared.persistNotificationIfNeeded(response.notification)
                await deleteNotificationMessage(requestId: requestId, messageId: messageId)
                completionHandler()
            }
        case PushGoNotificationActionPolicy.openEntityActionIdentifier,
             PushGoNotificationActionPolicy.openRelatedEntityActionIdentifier:
            Task {
                await AppEnvironment.shared.persistNotificationIfNeeded(response.notification)
                if let entityTarget {
                    await AppEnvironment.shared.handleNotificationOpen(
                        entityType: entityTarget.entityType,
                        entityId: entityTarget.entityId
                    )
                } else {
                    await AppEnvironment.shared.handleNotificationOpen(notificationRequestId: requestId)
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

    private func markNotificationMessageRead(requestId: String, messageId: String?) async {
        do {
            _ = try await AppEnvironment.shared.messageStateCoordinator
                .markRead(notificationRequestId: requestId, messageId: messageId)
        } catch {
        }
    }

    private func deleteNotificationMessage(requestId: String, messageId: String?) async {
        do {
            try await AppEnvironment.shared.messageStateCoordinator
                .deleteMessage(notificationRequestId: requestId, messageId: messageId)
        } catch {
            removeDeliveredNotification(requestId: requestId)
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

    private func handleRemoteNotification(_ payload: [AnyHashable: Any]) async -> UIBackgroundFetchResult {
        let environment = AppEnvironment.shared
        let inboxApplied = await environment.mergeNotificationIngressInbox(
            reason: "ios_remote_notification",
            allowFallbackPull: true
        )
        let sanitizedPayload = UserInfoSanitizer.sanitize(payload)
        let ingress = await NotificationHandling.resolveNotificationIngress(
            from: sanitizedPayload,
            dataStore: environment.dataStore,
            fallbackServerConfig: environment.serverConfig,
            channelSubscriptionService: channelSubscriptionService
        )
        switch ingress {
        case .claimedByPeer:
            return inboxApplied > 0 ? .newData : .noData
        case let .unresolvedWakeup(resolvedPayload, requestIdentifier):
            guard !environment.shouldDeferStartupWakeupPulls else {
                return inboxApplied > 0 ? .newData : .noData
            }
            let unresolvedDeliveryId = requestIdentifier
                ?? NotificationHandling.providerWakeupPullDeliveryId(from: resolvedPayload)
            guard let unresolvedDeliveryId else {
                return inboxApplied > 0 ? .newData : .noData
            }
            let pulled = await environment.syncProviderIngress(
                deliveryId: unresolvedDeliveryId,
                reason: "ios_remote_notification_unresolved",
                skipInboxMerge: true
            )
            return (inboxApplied + pulled) > 0 ? .newData : .noData
        case let .pulled(resolvedPayload, requestIdentifier):
            let outcome = await environment.persistRemotePayloadIfNeeded(
                resolvedPayload,
                requestIdentifier: requestIdentifier
            )
            return remoteFetchResult(inboxApplied: inboxApplied, persistenceOutcome: outcome)
        case let .direct(resolvedPayload, requestIdentifier):
            let outcome = await environment.persistRemotePayloadIfNeeded(
                resolvedPayload,
                requestIdentifier: requestIdentifier
            )
            return remoteFetchResult(inboxApplied: inboxApplied, persistenceOutcome: outcome)
        }
    }

    private func remoteFetchResult(
        inboxApplied: Int,
        persistenceOutcome: NotificationPersistenceOutcome
    ) -> UIBackgroundFetchResult {
        switch persistenceOutcome {
        case .persistedMain, .persistedPending:
            return .newData
        case .duplicate, .rejected:
            return inboxApplied > 0 ? .newData : .noData
        case .failed:
            return .failed
        }
    }
}
