import SwiftUI
import UserNotifications

import AppKit
@MainActor
final class PushGoAppDelegate: NSObject, NSApplicationDelegate, @preconcurrency UNUserNotificationCenterDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private var privateAckDrainScheduler: NSBackgroundActivityScheduler?

    func applicationWillFinishLaunching(_: Notification) {
        activateForAutomationIfNeeded()
    }

    func applicationDidFinishLaunching(_: Notification) {
        NSApp.setActivationPolicy(.regular)
        activateForAutomationIfNeeded()
        UNUserNotificationCenter.current().delegate = self
        _ = AppEnvironment.shared
        bootstrapAutomationRuntimeIfNeeded()
        configureStatusItem()

        NSApp.registerForRemoteNotifications(matching: [.alert, .badge, .sound])
        Task {
            await PushRegistrationService.shared.refreshAuthorizationStatus()
        }

        Task { @MainActor in
            for await _ in NotificationCenter.default.notifications(
                named: NSApplication.didBecomeActiveNotification
            ) {
                ensureMainWindowKey(retries: 8, delay: 0.06)
            }
        }
        Task { @MainActor in
            await Task.yield()
            activateForAutomationIfNeeded()
            if PushGoAutomationContext.forceForegroundApp {
                MainWindowController.shared.showMainWindow()
            }
            ensureMainWindowKey(retries: 25, delay: 0.08)
            observeWindowLifecycle()
        }
        configurePrivateAckDrainScheduler()
    }

    private func bootstrapAutomationRuntimeIfNeeded() {
#if DEBUG
        Task { @MainActor in
            PushGoAutomationRuntime.shared.configureFromProcessEnvironment()
            PushGoAutomationRuntime.shared.recordBootstrapCheckpoint("macos.app_delegate.did_finish_launching.enter")
            guard PushGoAutomationContext.isActive else { return }
            let environment = AppEnvironment.shared
            PushGoAutomationRuntime.shared.recordBootstrapCheckpoint("macos.app_delegate.bootstrap.begin")
            await environment.bootstrap()
            if PushGoAutomationContext.forceForegroundApp {
                MainWindowController.shared.showMainWindow()
                ensureMainWindowKey(retries: 25, delay: 0.08)
            }
            await Task.yield()
            PushGoAutomationRuntime.shared.recordBootstrapCheckpoint("macos.app_delegate.before_fixture_import")
            await PushGoAutomationRuntime.shared.importStartupFixtureIfNeeded(environment: environment)
            PushGoAutomationRuntime.shared.recordBootstrapCheckpoint("macos.app_delegate.after_fixture_import")
            await PushGoAutomationRuntime.shared.executeStartupRequestIfNeeded(environment: environment)
            PushGoAutomationRuntime.shared.recordBootstrapCheckpoint("macos.app_delegate.after_request_execute")
        }
#endif
    }

    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool {
        if PushGoAutomationContext.forceForegroundApp {
            AppEnvironment.shared.updateMainWindowVisibility(isVisible: false)
            return false
        }
        if MainWindowController.shared.shouldPreventAccessory {
            return false
        }
        NSApp.setActivationPolicy(.accessory)
        AppEnvironment.shared.updateMainWindowVisibility(isVisible: false)
        return false
    }

    func application(_: NSApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Task { @MainActor in
            PushRegistrationService.shared.handleDeviceToken(deviceToken)
            AppEnvironment.shared.handlePushTokenUpdate()
        }
    }

    func application(_: NSApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        Task { @MainActor in
            PushRegistrationService.shared.handleRegistrationError(error)
        }
    }

    func application(
        _: NSApplication,
        didReceiveRemoteNotification userInfo: [String: Any]
    ) {
        Task { @MainActor in
            await handleRemoteNotification(userInfo)
            _ = await AppEnvironment.shared.drainPrivateWakeupAckOutboxForSystemWake()
        }
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
            let outcome = await persistNotificationAndSyncEntityIfNeeded(notification)
            guard case .persisted = outcome else {
                completionHandler([])
                return
            }
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

    func userNotificationCenter(
        _: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if isPurePrivateWakeupPayload(response.notification.request.content.userInfo) {
            Task { @MainActor in
                await AppEnvironment.shared.triggerPrivateWakeupPull(presentLocalNotifications: true)
                completionHandler()
            }
            return
        }
        Task {
            let actionID = response.actionIdentifier
            let userInfo = response.notification.request.content.userInfo
            let messageId = extractMessageId(from: userInfo)
            let entityTarget = NotificationHandling.entityOpenTargetComponents(from: userInfo)
            let requestId = response.notification.request.identifier
            let persistenceOutcome = await persistNotificationAndSyncEntityIfNeeded(response.notification)
            if await shouldAbortActionForPersistenceFailure(persistenceOutcome) {
                completionHandler()
                return
            }
            switch actionID {
            case UNNotificationDismissActionIdentifier:
                if entityTarget != nil {
                    removeDeliveredNotification(requestId: requestId)
                } else {
                    await handleDismiss(response: response, messageId: messageId)
                }
                completionHandler()
            case UNNotificationDefaultActionIdentifier:
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
            default:
                completionHandler()
            }
        }
    }

    private func shouldAbortActionForPersistenceFailure(
        _ outcome: NotificationPersistenceOutcome
    ) async -> Bool {
        guard case .failed = outcome else {
            return false
        }
        await AppEnvironment.shared.triggerPrivateWakeupPull()
        return true
    }

    private func handleRemoteNotification(_ userInfo: [String: Any]) async {
        if isPurePrivateWakeupPayload(userInfo) {
            await AppEnvironment.shared.triggerPrivateWakeupPull(presentLocalNotifications: true)
            return
        }
        guard let normalized = NotificationHandling.normalizeRemoteNotification(userInfo) else {
            return
        }
        if normalized.entityType == "event" || normalized.entityType == "thing" {
            await AppEnvironment.shared.triggerPrivateWakeupPull()
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

    private nonisolated func extractMessageId(from payload: [AnyHashable: Any]) -> String? {
        NotificationHandling.extractMessageId(from: payload)
    }

    private nonisolated func extractMessageId(from payload: [String: Any]) -> String? {
        MessageIdExtractor.extract(from: payload)
    }

    private nonisolated func isPrivateWakeupPayload(_ payload: [AnyHashable: Any]) -> Bool {
        if let mode = payload["private_mode"] as? String, mode == "wakeup" {
            return true
        }
        if let wakeup = payload["private_wakeup"] as? String, wakeup == "1" || wakeup.lowercased() == "true" {
            return true
        }
        if let wakeup = payload["private_wakeup"] as? NSNumber, wakeup.intValue == 1 {
            return true
        }
        if let wakeup = payload["private_wakeup"] as? Bool, wakeup {
            return true
        }
        return false
    }

    private nonisolated func isPrivateWakeupPayload(_ payload: [String: Any]) -> Bool {
        isPrivateWakeupPayload(payload as [AnyHashable: Any])
    }

    private nonisolated func isPurePrivateWakeupPayload(_ payload: [AnyHashable: Any]) -> Bool {
        NotificationHandling.isPurePrivateWakeupPayload(payload)
    }

    private nonisolated func isPurePrivateWakeupPayload(_ payload: [String: Any]) -> Bool {
        isPurePrivateWakeupPayload(payload as [AnyHashable: Any])
    }

    private func persistNotificationAndSyncEntityIfNeeded(
        _ notification: UNNotification
    ) async -> NotificationPersistenceOutcome {
        let outcome = await AppEnvironment.shared.persistNotificationIfNeeded(notification)
        let isEntity = isEntityPayload(notification.request.content.userInfo)
        if isEntity {
            await AppEnvironment.shared.triggerPrivateWakeupPull()
        }
        return outcome
    }

    private nonisolated func isEntityPayload(_ payload: [AnyHashable: Any]) -> Bool {
        guard let normalized = NotificationHandling.normalizeRemoteNotification(payload) else {
            return false
        }
        return normalized.entityType == "event" || normalized.entityType == "thing"
    }

    private func configureStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = item.button else {
            return
        }

        if let icon = NSImage(named: "menubar") {
            icon.isTemplate = true
            button.image = icon
        } else {
            button.image = NSImage(
                systemSymbolName: "bell.badge",
                accessibilityDescription: "PushGo"
            )
        }
        button.action = #selector(handleStatusItemClick(_:))
        button.target = self
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem = item
    }

    private func activateForAutomationIfNeeded() {
        guard PushGoAutomationContext.forceForegroundApp else { return }
        MainWindowController.shared.prepareForShowingMainWindow()
        NSApp.setActivationPolicy(.regular)
        NSRunningApplication.current.activate(options: [.activateAllWindows])
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc
    private func handleStatusItemClick(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            guard let statusItem else { return }
            let menu = makeStatusItemContextMenu()
            menu.delegate = self
            statusItem.menu = menu
            statusItem.button?.performClick(nil)
            return
        }
        MainWindowController.shared.showMainWindow()
    }

    private func makeStatusItemContextMenu() -> NSMenu {
        let menu = NSMenu()
        let openMainItem = NSMenuItem(
            title: LocalizationManager.shared.localized("open_main_window"),
            action: #selector(handleOpenMainWindowFromStatusItemMenu),
            keyEquivalent: ""
        )
        openMainItem.target = self
        menu.addItem(openMainItem)

        let quitItem = NSMenuItem(
            title: LocalizationManager.shared.localized("quit_application"),
            action: #selector(handleQuitFromStatusItemMenu),
            keyEquivalent: ""
        )
        quitItem.target = self
        menu.addItem(quitItem)
        return menu
    }

    @objc
    private func handleOpenMainWindowFromStatusItemMenu() {
        MainWindowController.shared.showMainWindow()
    }

    @objc
    private func handleQuitFromStatusItemMenu() {
        NSApp.terminate(nil)
    }

    func menuDidClose(_ menu: NSMenu) {
        if statusItem?.menu === menu {
            statusItem?.menu = nil
        }
    }

    @MainActor
    private func makeMainWindowKey() {
        MainWindowController.shared.showMainWindow()
    }

    @MainActor
    private func ensureMainWindowKey(retries: Int, delay: TimeInterval) {
        if NSApp.keyWindow != nil {
            return
        }

        if let mainWindow =
            MainWindowController.shared.mainWindow
            ?? NSApp.windows.first(where: { $0.identifier?.rawValue == "PushGoMainWindow" })
            ?? NSApp.windows.first(where: { candidate in
                candidate.isVisible
                    && !candidate.isMiniaturized
                    && candidate.canBecomeKey
                    && !String(describing: type(of: candidate)).contains("NSStatusBarWindow")
            })
        {
            MainWindowController.shared.captureMainWindow(mainWindow)
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            mainWindow.makeKeyAndOrderFront(nil)
            return
        }

        makeMainWindowKey()

        guard retries > 0 else { return }
        Task { @MainActor [weak self] in
            let nanoseconds = UInt64(delay * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanoseconds)
            self?.ensureMainWindowKey(retries: retries - 1, delay: delay)
        }
    }

    private func observeWindowLifecycle() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleWindowNotification),
            name: NSWindow.didBecomeKeyNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleWindowNotification),
            name: NSWindow.didBecomeMainNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleWindowNotification),
            name: NSWindow.didResignKeyNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleWindowNotification),
            name: NSWindow.didResignMainNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleWindowNotification),
            name: NSWindow.didMiniaturizeNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleWindowNotification),
            name: NSWindow.didDeminiaturizeNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleWindowNotification),
            name: NSWindow.willCloseNotification,
            object: nil
        )
    }

    private func configurePrivateAckDrainScheduler() {
        let scheduler = NSBackgroundActivityScheduler(identifier: "io.ethan.pushgo.private-ack-outbox")
        scheduler.repeats = true
        scheduler.interval = 5 * 60
        scheduler.tolerance = 60
        scheduler.qualityOfService = .utility
        privateAckDrainScheduler = scheduler
        scheduler.schedule { completion in
            Task { @MainActor in
                let outcome = await AppEnvironment.shared.drainPrivateWakeupAckOutboxForSystemWake()
                completion(outcome == .failed ? .deferred : .finished)
            }
        }
    }

    @objc
    private func handleWindowNotification(_ notification: Notification) {
        switch notification.name {
        case NSWindow.didBecomeKeyNotification,
             NSWindow.didBecomeMainNotification,
             NSWindow.didDeminiaturizeNotification:
            updateMainWindowVisibilityIfNeeded(isVisible: true, window: notification.object as? NSWindow)
        case NSWindow.didMiniaturizeNotification,
             NSWindow.willCloseNotification:
            updateMainWindowVisibilityIfNeeded(isVisible: false, window: notification.object as? NSWindow)
        case NSWindow.didResignKeyNotification,
             NSWindow.didResignMainNotification:
            return
        default:
            return
        }
    }

    private func updateMainWindowVisibilityIfNeeded(isVisible: Bool, window: NSWindow?) {
        guard isMainWindow(notificationWindow: window) else { return }
        AppEnvironment.shared.updateMainWindowVisibility(isVisible: isVisible)
    }

    private func isMainWindow(notificationWindow: NSWindow?) -> Bool {
        notificationWindow?.identifier?.rawValue == "PushGoMainWindow"
    }
}
