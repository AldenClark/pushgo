import SwiftUI
import UserNotifications

import AppKit
import ObjectiveC.runtime
@MainActor
final class PushGoAppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_: Notification) {
        LocalizationProvider.installTranslator { key, args in
            LocalizationManager.shared.localized(key, arguments: args)
        }
        NSApp.setActivationPolicy(.regular)
        configureGlobalScrollAppearance()
        UNUserNotificationCenter.current().delegate = self
        _ = AppEnvironment.shared

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
            ensureMainWindowKey(retries: 25, delay: 0.08)
            try? await Task.sleep(nanoseconds: 300_000_000)
            NSScrollView.pushgoApplyOverlayStyleInExistingWindows()
            observeWindowLifecycle()
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool {
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
            await AppEnvironment.shared.persistNotificationIfNeeded(notification)
            let shouldPresent = AppEnvironment.shared.shouldPresentForegroundNotification()
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
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    private func handleRemoteNotification(_ userInfo: [String: Any]) async {
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

    private nonisolated func extractMessageId(from payload: [AnyHashable: Any]) -> UUID? {
        NotificationHandling.extractMessageId(from: payload)
    }

    private nonisolated func extractMessageId(from payload: [String: Any]) -> UUID? {
        MessageIdExtractor.extract(from: payload)
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

private extension PushGoAppDelegate {
    func configureGlobalScrollAppearance() {
        NSScrollView.pushgoInstallOverlayStyleHook()
    }
}

private extension NSScrollView {
    private static var pushgoHasInstalledOverlayHook = false
    private static let pushgoMainWindowIdentifier = "PushGoMainWindow"

    static func pushgoInstallOverlayStyleHook() {
        guard !pushgoHasInstalledOverlayHook else { return }
        pushgoHasInstalledOverlayHook = true

        let cls: AnyClass = NSScrollView.self
        let originalSelector = #selector(NSScrollView.viewDidMoveToWindow)
        let swizzledSelector = #selector(NSScrollView.pushgo_viewDidMoveToWindow)

        guard
            let originalMethod = class_getInstanceMethod(cls, originalSelector),
            let swizzledMethod = class_getInstanceMethod(cls, swizzledSelector)
        else {
            return
        }

        let didAddMethod = class_addMethod(
            cls,
            originalSelector,
            method_getImplementation(swizzledMethod),
            method_getTypeEncoding(swizzledMethod),
        )

        if didAddMethod {
            class_replaceMethod(
                cls,
                swizzledSelector,
                method_getImplementation(originalMethod),
                method_getTypeEncoding(originalMethod),
            )
        } else {
            method_exchangeImplementations(originalMethod, swizzledMethod)
        }
    }

    static func pushgoApplyOverlayStyleInExistingWindows() {
        for window in NSApp.windows {
            guard window.identifier?.rawValue == pushgoMainWindowIdentifier else { continue }
            applyOverlayStyle(in: window.contentView)
        }
    }

    @objc
    func pushgo_viewDidMoveToWindow() {
        pushgo_viewDidMoveToWindow()
        Task { @MainActor [weak self] in
            await Task.yield()
            self?.applyPushGoOverlayScrollerStyleIfNeeded()
        }
    }

    private func applyPushGoOverlayScrollerStyleIfNeeded() {
        guard shouldApplyPushGoOverlayStyle else { return }
        var didChange = false

        if scrollerStyle != .overlay {
            scrollerStyle = .overlay
            didChange = true
        }
        if usesPredominantAxisScrolling != true {
            usesPredominantAxisScrolling = true
            didChange = true
        }
        if autohidesScrollers != true {
            autohidesScrollers = true
            didChange = true
        }
        if verticalScroller?.controlSize != .mini {
            verticalScroller?.controlSize = .mini
            didChange = true
        }
        if horizontalScroller?.controlSize != .mini {
            horizontalScroller?.controlSize = .mini
            didChange = true
        }

        if didChange {
            needsLayout = true
        }
    }

    private var shouldApplyPushGoOverlayStyle: Bool {
        guard let window else { return false }
        return window.identifier?.rawValue == Self.pushgoMainWindowIdentifier
    }

    private static func applyOverlayStyle(in view: NSView?) {
        guard let view else { return }

        if let scrollView = view as? NSScrollView {
            scrollView.applyPushGoOverlayScrollerStyleIfNeeded()
        }
        view.subviews.forEach { applyOverlayStyle(in: $0) }
    }
}
