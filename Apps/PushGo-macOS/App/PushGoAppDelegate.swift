import SwiftUI
@preconcurrency import UserNotifications

import AppKit
@MainActor
final class PushGoAppDelegate: NSObject, NSApplicationDelegate, @preconcurrency UNUserNotificationCenterDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private let channelSubscriptionService = ChannelSubscriptionService()

    func applicationWillFinishLaunching(_: Notification) {
        activateForAutomationIfNeeded()
    }

    func applicationDidFinishLaunching(_: Notification) {
        NSApp.setActivationPolicy(.regular)
        activateForAutomationIfNeeded()
        UNUserNotificationCenter.current().delegate = self
        let environment = AppEnvironment.shared
        bootstrapAutomationRuntimeIfNeeded()
        configureStatusItem()

        NSApp.registerForRemoteNotifications(matching: [.alert, .badge, .sound])
        Task {
            await PushRegistrationService.shared.refreshAuthorizationStatus()
        }
        Task { @MainActor in
            await environment.bootstrap()
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
        }
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
                _ = await AppEnvironment.shared.persistNotificationIfNeeded(response.notification)
                if entityTarget != nil {
                    removeDeliveredNotification(requestId: requestId)
                } else {
                    await handleDismiss(response: response, messageId: messageId)
                }
                completionHandler()
            }
        case UNNotificationDefaultActionIdentifier:
            Task {
                _ = await AppEnvironment.shared.persistNotificationIfNeeded(response.notification)
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

    private nonisolated func extractMessageId(from payload: [AnyHashable: Any]) -> String? {
        NotificationHandling.extractMessageId(from: payload)
    }

    private nonisolated func extractMessageId(from payload: [String: Any]) -> String? {
        MessageIdExtractor.extract(from: payload)
    }

    private func handleRemoteNotification(_ payload: [String: Any]) async {
        guard let resolved = await resolveRemoteNotificationPayload(from: payload) else {
            return
        }
        _ = await AppEnvironment.shared.persistRemotePayloadIfNeeded(
            resolved.payload,
            requestIdentifier: resolved.requestIdentifier
        )
    }

    private func resolveRemoteNotificationPayload(
        from payload: [String: Any]
    ) async -> (payload: [AnyHashable: Any], requestIdentifier: String?)? {
        let bridgedPayload: [AnyHashable: Any] = payload.reduce(into: [:]) { result, element in
            result[element.key] = element.value
        }
        let sanitizedPayload = UserInfoSanitizer.sanitize(bridgedPayload)
        guard let deliveryId = NotificationHandling.providerWakeupPullDeliveryId(from: sanitizedPayload) else {
            return (
                payload: sanitizedPayload,
                requestIdentifier: normalizedIdentifier(sanitizedPayload["delivery_id"] as? String)
            )
        }
        guard let config = await activeServerConfigForRemoteIngress() else {
            return nil
        }
        guard let item = try? await channelSubscriptionService.pullMessage(
            baseURL: config.baseURL,
            token: config.token,
            deliveryId: deliveryId
        ) else {
            return nil
        }
        let pulledPayload: [AnyHashable: Any] = item.payload.reduce(into: [:]) { result, element in
            result[element.key] = element.value
        }
        return (
            payload: UserInfoSanitizer.sanitize(pulledPayload),
            requestIdentifier: deliveryId
        )
    }

    private func activeServerConfigForRemoteIngress() async -> ServerConfig? {
        if let storedConfig = try? await AppEnvironment.shared.dataStore.loadServerConfig()?.normalized() {
            return storedConfig
        }
        return AppEnvironment.shared.serverConfig?.normalized()
    }

    private nonisolated func normalizedIdentifier(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
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
