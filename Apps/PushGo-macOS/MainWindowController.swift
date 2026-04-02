import AppKit
import SwiftUI

@MainActor
final class MainWindowController {
    static let shared = MainWindowController()

    private(set) weak var mainWindow: NSWindow?
    private var preventAccessoryUntil: Date?
    private let chromeConfiguredWindows = NSHashTable<NSWindow>.weakObjects()

    private let mainWindowIdentifier = NSUserInterfaceItemIdentifier("PushGoMainWindow")
    private let fixedSidebarWidth: CGFloat = 220

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
        configureWindowChromeIfNeeded(window)
        lockSidebarSplitItemsIfNeeded(in: window)
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

    private func configureWindowChromeIfNeeded(_ window: NSWindow) {
        guard !chromeConfiguredWindows.contains(window) else { return }
        chromeConfiguredWindows.add(window)

        if window.titleVisibility != .hidden {
            window.titleVisibility = .hidden
        }
        if window.toolbarStyle != .unified {
            window.toolbarStyle = .unified
        }
        if !window.styleMask.contains(.fullSizeContentView) {
            window.styleMask.insert(.fullSizeContentView)
        }
        if !window.titlebarAppearsTransparent {
            window.titlebarAppearsTransparent = true
        }
        if window.backgroundColor != NSColor.windowBackgroundColor {
            window.backgroundColor = NSColor.windowBackgroundColor
        }
        if window.titlebarSeparatorStyle != .none {
            window.titlebarSeparatorStyle = .none
        }
        if #unavailable(macOS 15.0) {
            if window.toolbar?.showsBaselineSeparator != false {
                window.toolbar?.showsBaselineSeparator = false
            }
        }
        if !window.isOpaque {
            window.isOpaque = true
        }
    }

    private func lockSidebarSplitItemsIfNeeded(in window: NSWindow) {
        guard let rootViewController = window.contentViewController else { return }
        let splitViewControllers = collectSplitViewControllers(from: rootViewController)
        guard let rootSplitViewController = splitViewControllers.first else { return }
        guard !rootSplitViewController.splitViewItems.isEmpty else { return }

        let targetItem = rootSplitViewController.splitViewItems.first(where: { $0.behavior == .sidebar })
            ?? rootSplitViewController.splitViewItems[0]

        targetItem.minimumThickness = fixedSidebarWidth
        targetItem.maximumThickness = fixedSidebarWidth
        targetItem.automaticMaximumThickness = fixedSidebarWidth
    }

    private func collectSplitViewControllers(from root: NSViewController) -> [NSSplitViewController] {
        var results: [NSSplitViewController] = []
        if let splitViewController = root as? NSSplitViewController {
            results.append(splitViewController)
        }
        for child in root.children {
            results.append(contentsOf: collectSplitViewControllers(from: child))
        }
        return results
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
