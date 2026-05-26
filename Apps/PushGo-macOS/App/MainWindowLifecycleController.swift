import AppKit

@MainActor
final class MainWindowLifecycleController {
    static let shared = MainWindowLifecycleController()

    private var didObserveApplicationActivation = false
    private var didObserveWindowLifecycle = false

    private init() {}

    func startApplicationActivationObserver() {
        guard !didObserveApplicationActivation else { return }
        didObserveApplicationActivation = true
        Task { @MainActor [weak self] in
            for await _ in NotificationCenter.default.notifications(
                named: NSApplication.didBecomeActiveNotification
            ) {
                self?.ensureMainWindowKey(retries: 8, delay: 0.06)
            }
        }
    }

    func prepareInitialWindowState() {
        Task { @MainActor [weak self] in
            await Task.yield()
            if PushGoAutomationContext.forceForegroundApp {
                MainWindowController.shared.showMainWindow()
            }
            self?.ensureMainWindowKey(retries: 25, delay: 0.08)
            self?.observeWindowLifecycle()
        }
    }

    func ensureMainWindowKey(retries: Int, delay: TimeInterval) {
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

        MainWindowController.shared.showMainWindow()

        guard retries > 0 else { return }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .nanoseconds(Int64(delay * 1_000_000_000)))
            self?.ensureMainWindowKey(retries: retries - 1, delay: delay)
        }
    }

    private func observeWindowLifecycle() {
        guard !didObserveWindowLifecycle else { return }
        didObserveWindowLifecycle = true
        let notifications: [Notification.Name] = [
            NSWindow.didBecomeKeyNotification,
            NSWindow.didBecomeMainNotification,
            NSWindow.didResignKeyNotification,
            NSWindow.didResignMainNotification,
            NSWindow.didMiniaturizeNotification,
            NSWindow.didDeminiaturizeNotification,
            NSWindow.willCloseNotification,
        ]
        for name in notifications {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(handleWindowNotification),
                name: name,
                object: nil
            )
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
        guard window?.identifier?.rawValue == "PushGoMainWindow" else { return }
        AppEnvironment.shared.updateMainWindowVisibility(isVisible: isVisible)
    }
}
