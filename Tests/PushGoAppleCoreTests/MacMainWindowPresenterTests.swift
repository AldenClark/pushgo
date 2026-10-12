#if os(macOS)
import AppKit
import Testing
@testable import PushGoAppleCore

@MainActor
struct MacMainWindowPresenterTests {
    @Test
    func closedMainWindowIsRestoredAsTheSameUniqueWindow() async {
        let presenter = MacMainWindowPresenter()
        let window = makeWindow()

        presenter.capture(window)
        #expect(window.identifier == MacMainWindowPresenter.mainWindowIdentifier)
        #expect(window.isReleasedWhenClosed == false)

        window.orderFront(nil)
        window.close()
        await Task.yield()

        #expect(window.isVisible == false)
        #expect(presenter.capturedWindow === window)

        let restored = presenter.focusExistingWindow(from: [])
        #expect(restored === window)
        #expect(window.isVisible)
        #expect(presenter.capturedWindow === window)

        window.orderOut(nil)
    }

    @Test
    func minimizedMainWindowIsDeminiaturizedInsteadOfDuplicated() {
        let presenter = MacMainWindowPresenter()
        let window = RecordingMiniaturizedWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        presenter.capture(window)

        #expect(window.isMiniaturized)
        let restored = presenter.focusExistingWindow(from: [])

        #expect(restored === window)
        #expect(window.isMiniaturized == false)
        #expect(window.deminiaturizeCallCount == 1)
        #expect(window.makeKeyAndOrderFrontCallCount == 1)

        window.orderOut(nil)
    }

    @Test
    func identifiedApplicationWindowIsAdoptedWhenCaptureWasLost() {
        let presenter = MacMainWindowPresenter()
        let decoy = makeWindow()
        let main = makeWindow()
        main.identifier = MacMainWindowPresenter.mainWindowIdentifier

        let restored = presenter.focusExistingWindow(from: [decoy, main])

        #expect(restored === main)
        #expect(presenter.capturedWindow === main)
        #expect(main.isReleasedWhenClosed == false)
        #expect(decoy.isVisible == false)

        main.orderOut(nil)
    }

    private func makeWindow() -> NSWindow {
        NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
    }
}

@MainActor
private final class RecordingMiniaturizedWindow: NSWindow {
    private var simulatedMiniaturized = true
    private(set) var deminiaturizeCallCount = 0
    private(set) var makeKeyAndOrderFrontCallCount = 0

    override var isMiniaturized: Bool {
        simulatedMiniaturized
    }

    override func deminiaturize(_ sender: Any?) {
        deminiaturizeCallCount += 1
        simulatedMiniaturized = false
    }

    override func makeKeyAndOrderFront(_ sender: Any?) {
        makeKeyAndOrderFrontCallCount += 1
    }
}
#endif
