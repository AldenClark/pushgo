import AppKit
import SwiftUI

@MainActor
final class MainWindowController {
    static let shared = MainWindowController()

    private(set) weak var mainWindow: NSWindow?
    private var preventAccessoryUntil: Date?

    private let mainWindowIdentifier = NSUserInterfaceItemIdentifier("PushGoMainWindow")

    var shouldPreventAccessory: Bool {
        guard let preventAccessoryUntil else { return false }
        return preventAccessoryUntil > Date()
    }

    func captureMainWindow(_ window: NSWindow) {
        if mainWindow !== window {
            mainWindow = window
            window.identifier = mainWindowIdentifier
            window.contentMinSize = NSSize(width: 1100, height: 640)
        }
        configureWindowChrome(window)
    }
    func prepareForShowingMainWindow() {
        preventAccessoryUntil = Date().addingTimeInterval(2.0)
        NotificationCenter.default.post(name: .pushgoCloseMenuBarPopover, object: nil)

        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func focusMainWindowIfExists() -> Bool {
        guard let window = resolveMainWindow() else { return false }
        captureMainWindow(window)
        window.makeKeyAndOrderFront(nil)
        Task { @MainActor in
            self.configureWindowChrome(window)
        }
        return true
    }
    func showMainWindow() {
        prepareForShowingMainWindow()
        _ = focusMainWindowIfExists()
    }

    private func resolveMainWindow() -> NSWindow? {
        if let mainWindow {
            return mainWindow
        }
        return NSApp.windows.first(where: { $0.identifier == mainWindowIdentifier })
    }

    private func configureWindowChrome(_ window: NSWindow) {
        window.titleVisibility = .hidden
        window.toolbarStyle = .unified
        if #available(macOS 26.0, *) {
            window.styleMask.insert(.fullSizeContentView)
            window.titlebarAppearsTransparent = true
            window.backgroundColor = NSColor.windowBackgroundColor
        } else {
            window.styleMask.insert(.fullSizeContentView)
            window.titlebarAppearsTransparent = true
            window.backgroundColor = NSColor.windowBackgroundColor
        }
        window.titlebarSeparatorStyle = .none
        if #unavailable(macOS 15.0) {
            window.toolbar?.showsBaselineSeparator = false
        }
        window.isOpaque = true
    }
}

struct MainWindowAccessor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        AccessorView()
    }

    func updateNSView(_: NSView, context _: Context) {}

    private final class AccessorView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            Task { @MainActor in
                MainWindowController.shared.captureMainWindow(window)
            }
        }
    }
}
