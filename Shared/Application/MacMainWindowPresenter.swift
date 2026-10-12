#if os(macOS)
import AppKit

/// Owns the AppKit part of the singleton main-window lifecycle.
///
/// A status-item app must keep its main window alive after the user closes it.
/// Otherwise a later status-item click has no window to restore, and an AppKit
/// controller cannot manufacture SwiftUI scene content safely on its own.
@MainActor
final class MacMainWindowPresenter {
    static let mainWindowIdentifier = NSUserInterfaceItemIdentifier("PushGoMainWindow")

    private(set) var capturedWindow: NSWindow?

    func capture(_ window: NSWindow) {
        capturedWindow = window
        window.identifier = Self.mainWindowIdentifier
        window.isReleasedWhenClosed = false
    }

    func resolve(from applicationWindows: [NSWindow]) -> NSWindow? {
        capturedWindow
            ?? applicationWindows.first(where: { $0.identifier == Self.mainWindowIdentifier })
    }

    @discardableResult
    func focusExistingWindow(from applicationWindows: [NSWindow]) -> NSWindow? {
        guard let window = resolve(from: applicationWindows) else { return nil }
        capture(window)
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        window.makeKeyAndOrderFront(nil)
        return window
    }
}
#endif
