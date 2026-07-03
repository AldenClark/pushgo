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
        PushGoAnimatedImageRuntime.bootstrapIfNeeded()
        NSApp.setActivationPolicy(.regular)
        activateForAutomationIfNeeded()
        let environment = AppEnvironment.shared
        environment.beginProviderIngressBootstrapRecovery()
        UNUserNotificationCenter.current().delegate = self
        bootstrapAutomationRuntimeIfNeeded()
        configureStatusItem()

        NSApp.registerForRemoteNotifications(matching: [.alert, .badge, .sound])
        Task {
            await PushRegistrationService.shared.refreshAuthorizationStatus()
        }
        Task { @MainActor in
            await environment.bootstrap()
        }

        MainWindowLifecycleController.shared.startApplicationActivationObserver()
        Task { @MainActor in
            activateForAutomationIfNeeded()
            MainWindowLifecycleController.shared.prepareInitialWindowState()
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
                MainWindowLifecycleController.shared.ensureMainWindowKey(retries: 25, delay: 0.08)
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
        if NSApp.activationPolicy() != .accessory {
            NSApp.setActivationPolicy(.accessory)
        }
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
        case PushGoNotificationActionPolicy.markReadActionIdentifier:
            Task {
                _ = await AppEnvironment.shared.persistNotificationIfNeeded(response.notification)
                await markNotificationMessageRead(requestId: requestId, messageId: messageId)
                completionHandler()
            }
        case PushGoNotificationActionPolicy.deleteMessageActionIdentifier:
            Task {
                _ = await AppEnvironment.shared.persistNotificationIfNeeded(response.notification)
                await deleteNotificationMessage(requestId: requestId, messageId: messageId)
                completionHandler()
            }
        case PushGoNotificationActionPolicy.openEntityActionIdentifier,
             PushGoNotificationActionPolicy.openRelatedEntityActionIdentifier:
            Task {
                _ = await AppEnvironment.shared.persistNotificationIfNeeded(response.notification)
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

    private nonisolated func extractMessageId(from payload: [AnyHashable: Any]) -> String? {
        NotificationHandling.extractMessageId(from: payload)
    }

    private nonisolated func extractMessageId(from payload: [String: Any]) -> String? {
        MessageIdExtractor.extract(from: payload)
    }

    private func handleRemoteNotification(_ payload: [String: Any]) async {
        _ = await AppEnvironment.shared.mergeNotificationIngressInbox(
            reason: "macos_remote_notification",
            allowFallbackPull: true
        )
        let bridgedPayload: [AnyHashable: Any] = payload.reduce(into: [:]) { result, element in
            result[element.key] = element.value
        }
        let sanitizedPayload = UserInfoSanitizer.sanitize(bridgedPayload)
        let ingress = await NotificationHandling.resolveNotificationIngress(
            from: sanitizedPayload,
            dataStore: AppEnvironment.shared.dataStore,
            fallbackServerConfig: AppEnvironment.shared.serverConfig,
            channelSubscriptionService: channelSubscriptionService
        )
        switch ingress {
        case .claimedByPeer:
            return
        case let .unresolvedWakeup(resolvedPayload, requestIdentifier):
            guard !AppEnvironment.shared.shouldDeferStartupWakeupPulls else {
                return
            }
            let unresolvedDeliveryId = requestIdentifier
                ?? NotificationHandling.providerWakeupPullDeliveryId(from: resolvedPayload)
            if let unresolvedDeliveryId {
                _ = await AppEnvironment.shared.syncProviderIngress(
                    deliveryId: unresolvedDeliveryId,
                    reason: "did_receive_remote_notification_unresolved",
                    skipInboxMerge: true
                )
            }
        case let .pulled(resolvedPayload, requestIdentifier):
            _ = await AppEnvironment.shared.persistRemotePayloadIfNeeded(
                resolvedPayload,
                requestIdentifier: requestIdentifier
            )
        case let .direct(resolvedPayload, requestIdentifier):
            _ = await AppEnvironment.shared.persistRemotePayloadIfNeeded(
                resolvedPayload,
                requestIdentifier: requestIdentifier
            )
        }
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
                accessibilityDescription: LocalizationProvider.localized("pushgo_app_name")
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


}
