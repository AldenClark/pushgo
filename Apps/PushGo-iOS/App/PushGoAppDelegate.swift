import SwiftUI
import UserNotifications

import UIKit
import BackgroundTasks
import OSLog
import os

private final class IngressBackgroundRefreshCompletionGate: Sendable {
    private let didComplete = OSAllocatedUnfairLock(initialState: false)

    func claimCompletion() -> Bool {
        didComplete.withLock { completed in
            guard !completed else { return false }
            completed = true
            return true
        }
    }
}

@MainActor
final class PushGoAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    private static let ingressRefreshIdentifier = "io.ethan.pushgo.ingress-reconcile"
    private static let ingressRefreshLogger = Logger(
        subsystem: "io.ethan.pushgo",
        category: "IngressBackgroundRefresh"
    )
    private let channelSubscriptionService = ChannelSubscriptionService()

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions _: [UIApplication.LaunchOptionsKey: Any]? = nil,
    ) -> Bool {
        PushGoAnimatedImageRuntime.bootstrapIfNeeded()
        registerIngressBackgroundRefresh()
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

    func applicationDidEnterBackground(_: UIApplication) {
        Self.scheduleIngressBackgroundRefresh(source: "application_delegate_background")
    }

    func applicationWillEnterForeground(_: UIApplication) {
        Task { @MainActor in
            _ = await AppEnvironment.shared.mergeNotificationIngressInbox(
                reason: "ios_will_enter_foreground",
                allowWakeupSync: true
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
        case PushGoNotificationActionPolicy.deleteMessageActionIdentifier,
             PushGoNotificationActionPolicy.deleteEntityReminderActionIdentifier:
            Task {
                await AppEnvironment.shared.requestNotificationDeletion(
                    notificationRequestId: requestId,
                    messageId: messageId,
                    notification: response.notification
                )
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
            allowWakeupSync: true
        )
        let sanitizedPayload = UserInfoSanitizer.sanitize(payload)
        let ingress = await NotificationHandling.resolveNotificationIngress(
            from: sanitizedPayload,
            dataStore: environment.dataStore,
            fallbackServerConfig: environment.serverConfig,
            channelSubscriptionService: channelSubscriptionService,
            allowNetwork: !environment.shouldDeferStartupWakeupPulls
        )
        switch ingress {
        case let .failed(error):
            environment.notificationIngressController.recordResolutionFailure(error, source: "provider.remote_notification.origin.ios")
            return .failed
        case let .processedDuplicate(knownPayload):
            await environment.ackDirectProviderIngressIfNeeded(payload: knownPayload, outcome: .duplicate,
                source: "provider.remote_notification.known.ios")
            return inboxApplied > 0 ? .newData : .noData
        case .claimedByPeer:
            return inboxApplied > 0 ? .newData : .noData
        case let .unresolvedWakeup(_, _, error):
            if let error { environment.notificationIngressController.recordResolutionFailure(error, source: "provider.remote_notification.targeted.ios") }
            return inboxApplied > 0 ? .newData : .noData
        case let .pulled(resolvedPayload, requestIdentifier, context):
            let outcome = await environment.persistPulledProviderIngress(
                payload: resolvedPayload,
                deliveryId: requestIdentifier,
                context: context,
                source: "provider.remote_notification.pulled.ios"
            )
            return remoteFetchResult(inboxApplied: inboxApplied, persistenceOutcome: outcome)
        case .direct:
            return inboxApplied > 0 ? .newData : .noData
        }
    }

    private func registerIngressBackgroundRefresh() {
        let registered = BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.ingressRefreshIdentifier,
            using: nil
        ) { task in
            Self.scheduleIngressBackgroundRefresh(source: "handler_start")
            guard let refreshTask = task as? BGAppRefreshTask else {
                Self.ingressRefreshLogger.error(
                    "Received unexpected task type for ingress background refresh"
                )
                task.setTaskCompleted(success: false)
                return
            }
            let completionGate = IngressBackgroundRefreshCompletionGate()
            let work = Task { @MainActor in
                let environment = AppEnvironment.shared
                let runner = IngressBackgroundRefreshRunner(
                    mergeIngress: {
                        await environment.mergeNotificationIngressInboxOutcome(
                            reason: "ios_bg_app_refresh",
                            allowWakeupSync: true
                        ).stageOutcome
                    },
                    drainAcknowledgements: {
                        await environment.drainProviderDeliveryAckFailuresOutcome(
                            source: "provider.bg_refresh.ack_failure.ios"
                        )
                    },
                    drainDerivedWork: {
                        await environment.dataStore.drainDerivedWorkForBackgroundRefresh()
                            ? .succeeded
                            : .failed
                    }
                )
                return await runner.run()
            }
            refreshTask.expirationHandler = {
                work.cancel()
                guard completionGate.claimCompletion() else { return }
                Task { @MainActor in
                    refreshTask.setTaskCompleted(success: false)
                }
            }
            Task { @MainActor in
                let outcome = await work.value
                guard completionGate.claimCompletion() else { return }
                refreshTask.setTaskCompleted(success: outcome.isSuccessful)
            }
        }
        if registered {
            Self.ingressRefreshLogger.info("Registered ingress background refresh handler")
        } else {
            Self.ingressRefreshLogger.error(
                "Failed to register ingress background refresh handler; verify permitted identifiers"
            )
        }
    }

    static func scheduleIngressBackgroundRefresh(source: String) {
        let request = BGAppRefreshTaskRequest(identifier: ingressRefreshIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        do {
            try BGTaskScheduler.shared.submit(request)
            ingressRefreshLogger.info(
                "Scheduled ingress background refresh from \(source, privacy: .public)"
            )
        } catch {
            ingressRefreshLogger.error(
                "Failed to schedule ingress background refresh from \(source, privacy: .public): \(String(describing: error), privacy: .public)"
            )
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
        case .identityConflict, .failed:
            return .failed
        }
    }
}
