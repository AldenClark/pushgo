import BackgroundTasks
import SwiftUI
import UserNotifications

import UIKit

private enum PrivateAckBackgroundTaskPlan {
    static let identifier = "io.ethan.pushgo.private-ack-outbox"

    static func preferredDate(for outcome: PrivateWakeupAckDrainOutcome?) -> Date {
        Date().addingTimeInterval(
            PrivateWakeupAckSemantics.backgroundInterval(for: outcome)
        )
    }

    static func success(for outcome: PrivateWakeupAckDrainOutcome) -> Bool {
        PrivateWakeupAckSemantics.backgroundTaskShouldSucceed(for: outcome)
    }
}

@MainActor
private final class BackgroundExecutionLease {
    private let application: UIApplication
    private var identifier: UIBackgroundTaskIdentifier = .invalid

    init(application: UIApplication, name: String) {
        self.application = application
        identifier = application.beginBackgroundTask(withName: name) { [weak self] in
            Task { @MainActor in
                self?.end()
            }
        }
    }

    func end() {
        guard identifier != .invalid else { return }
        application.endBackgroundTask(identifier)
        self.identifier = .invalid
    }

}

@MainActor
private final class PrivateAckBackgroundTaskController {
    static let shared = PrivateAckBackgroundTaskController()

    private struct ActiveTask {
        let task: BGAppRefreshTask
        let worker: Task<Void, Never>
    }

    private var activeTasks: [ObjectIdentifier: ActiveTask] = [:]

    func register() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: PrivateAckBackgroundTaskPlan.identifier,
            using: .main
        ) { task in
            guard let refreshTask = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            self.start(refreshTask)
        }
    }

    func schedule(preferredDate: Date? = nil) {
        let request = BGAppRefreshTaskRequest(identifier: PrivateAckBackgroundTaskPlan.identifier)
        request.earliestBeginDate = preferredDate ?? PrivateAckBackgroundTaskPlan.preferredDate(for: nil)
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: PrivateAckBackgroundTaskPlan.identifier)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
        }
    }

    private func start(_ task: BGAppRefreshTask) {
        let id = ObjectIdentifier(task)
        let worker = Task { @MainActor [weak self] in
            guard let self else { return }
            let outcome = await AppEnvironment.shared.drainPrivateWakeupAckOutboxForSystemWake()
            self.complete(id: id, outcome: outcome)
        }
        activeTasks[id] = ActiveTask(task: task, worker: worker)
        task.expirationHandler = { [weak self] in
            Task { @MainActor in
                self?.cancel(id: id)
            }
        }
    }

    private func complete(id: ObjectIdentifier, outcome: PrivateWakeupAckDrainOutcome) {
        guard let active = activeTasks.removeValue(forKey: id) else { return }
        active.worker.cancel()
        schedule(preferredDate: PrivateAckBackgroundTaskPlan.preferredDate(for: outcome))
        active.task.setTaskCompleted(success: PrivateAckBackgroundTaskPlan.success(for: outcome))
    }

    private func cancel(id: ObjectIdentifier) {
        guard let active = activeTasks.removeValue(forKey: id) else { return }
        active.worker.cancel()
        active.task.setTaskCompleted(success: false)
    }
}

final class PushGoAppDelegate: NSObject, UIApplicationDelegate, @preconcurrency UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions _: [UIApplication.LaunchOptionsKey: Any]? = nil,
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        _ = AppEnvironment.shared
        WatchTokenReceiver.shared.activateIfNeeded()
        registerPrivateAckBackgroundTask()
        PrivateAckBackgroundTaskController.shared.schedule()
        
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
        if isPurePrivateWakeupPayload(notification.request.content.userInfo) {
            Task { @MainActor in
                await AppEnvironment.shared.triggerPrivateWakeupPull(presentLocalNotifications: true)
                completionHandler([])
            }
            return
        }
        Task { @MainActor in
            let persistenceOutcome = await AppEnvironment.shared.persistNotificationIfNeeded(notification)
            let persisted: Bool
            switch persistenceOutcome {
            case .persisted:
                persisted = true
            case .skipped, .duplicateRequest, .duplicateMessage, .failed:
                persisted = false
            }
            guard persisted else {
                completionHandler([])
                return
            }
            await AppEnvironment.shared.reloadMessagesFromStore()
            let shouldPresent = AppEnvironment.shared.shouldPresentForegroundNotification(
                payload: notification.request.content.userInfo
            )
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
            let lease = BackgroundExecutionLease(
                application: UIApplication.shared,
                name: "private-ack-outbox-remote-notification"
            )
            defer { lease.end() }
            await handleRemoteNotification(userInfo)
            let outcome = await AppEnvironment.shared.drainPrivateWakeupAckOutboxForSystemWake()
            PrivateAckBackgroundTaskController.shared.schedule(
                preferredDate: PrivateAckBackgroundTaskPlan.preferredDate(for: outcome)
            )
            completionHandler(.newData)
        }
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        Task { @MainActor in
            let lease = BackgroundExecutionLease(
                application: application,
                name: "private-ack-outbox-enter-background"
            )
            defer { lease.end() }
            let outcome = await AppEnvironment.shared.drainPrivateWakeupAckOutboxForSystemWake()
            PrivateAckBackgroundTaskController.shared.schedule(
                preferredDate: PrivateAckBackgroundTaskPlan.preferredDate(for: outcome)
            )
        }
    }

    func applicationWillEnterForeground(_: UIApplication) {
        Task { @MainActor in
            _ = await AppEnvironment.shared.drainPrivateWakeupAckOutboxForSystemWake()
            PrivateAckBackgroundTaskController.shared.schedule()
        }
    }

    func userNotificationCenter(
        _: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if isPurePrivateWakeupPayload(response.notification.request.content.userInfo) {
            Task { @MainActor in
                await AppEnvironment.shared.triggerPrivateWakeupPull(presentLocalNotifications: false)
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

    private func handleRemoteNotification(_ userInfo: [AnyHashable: Any]) async {
        if isPurePrivateWakeupPayload(userInfo) {
            await AppEnvironment.shared.triggerPrivateWakeupPull(presentLocalNotifications: true)
            return
        }
        guard let normalized = NotificationHandling.normalizeRemoteNotification(userInfo) else {
            return
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
        guard persisted else { return }
        await AppEnvironment.shared.reloadMessagesFromStore()
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

    private nonisolated func isPrivateWakeupPayload(_ payload: [AnyHashable: Any]) -> Bool {
        NotificationHandling.isPrivateWakeupPayload(payload)
    }

    private nonisolated func isPurePrivateWakeupPayload(_ payload: [AnyHashable: Any]) -> Bool {
        NotificationHandling.isPurePrivateWakeupPayload(payload)
    }

    private nonisolated func registerPrivateAckBackgroundTask() {
        Task { @MainActor in
            PrivateAckBackgroundTaskController.shared.register()
        }
    }

}
