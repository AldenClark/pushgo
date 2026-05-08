import Observation
import SwiftUI
import AppKit

extension View {
    func withAppContext(
        environment: AppEnvironment,
        localizationManager: LocalizationManager,
        bootstrap: Bool,
    ) -> some View {
        DynamicLocaleWrapper(
            content: self,
            environment: environment,
            localizationManager: localizationManager,
            bootstrap: bootstrap,
        )
    }

    func toastOverlay(environment: AppEnvironment) -> some View {
        modifier(ToastOverlayModifier(environment: environment))
    }
}

private struct DynamicLocaleWrapper<Content: View>: View {
    let content: Content
    @Bindable var environment: AppEnvironment
    @Bindable var localizationManager: LocalizationManager
    let bootstrap: Bool
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        content
            .environment(environment)
            .environment(localizationManager)
            .environment(\.locale, localizationManager.swiftUILocale)
            .toastOverlay(environment: environment)
            .task(id: environment.toastMessage) {
                GlobalToastOverlayPresenter.shared.update(
                    toast: environment.toastMessage,
                    anchorWindow: NSApp.keyWindow ?? MainWindowController.shared.mainWindow ?? NSApp.mainWindow
                )
            }
#if DEBUG
            .task {
                #if !os(watchOS)
                PushGoAutomationRuntime.shared.configureFromProcessEnvironment()
                PushGoAutomationRuntime.shared.recordBootstrapCheckpoint("macos.app_context.configure")
                #endif
            }
#endif
            .modifier(BootstrapTaskModifier(perform: bootstrap, environment: environment, scenePhase: scenePhase))
            .onChange(of: scenePhase) { _, newValue in
                environment.updateScenePhase(newValue)
            }
            .task {
                environment.updateScenePhase(scenePhase)
            }
            .task {
                for await _ in NotificationCenter.default.notifications(
                    named: Notification.Name(AppConstants.copyToastNotificationName)
                ) {
                    environment.showToast(
                        message: localizationManager.localized("message_content_copied"),
                        style: .success,
                        duration: 1.2
                    )
                }
            }
            .alert(
                environment.localStoreRecoveryState?.title ?? "",
                isPresented: $environment.isLocalStoreRecoveryAlertPresented,
                presenting: environment.localStoreRecoveryState
            ) { state in
                if state.canRebuild {
                    Button("重建数据库并退出", role: .destructive) {
                        environment.rebuildLocalStoreForRecoveryAndTerminate()
                    }
                }
                Button("退出应用", role: .destructive) {
                    environment.terminateForLocalStoreFailure()
                }
            } message: { state in
                Text(state.message)
            }
            .alert(
                localizationManager.localized("please_enable_notification_permission_in_system_settings_first"),
                isPresented: $environment.isNotificationPermissionAlertPresented
            ) {
                Button(localizationManager.localized("cancel"), role: .cancel) {
                    environment.dismissNotificationPermissionAlert()
                }
                Button(localizationManager.localized("settings")) {
                    environment.dismissNotificationPermissionAlert()
                    environment.openSystemNotificationSettings()
                }
            } message: {
                Text(localizationManager.localized(
                    "system_notification_permission_is_not_obtained_please_turn_on_notifications_in_the_system_settings_and_try_again"
                ))
            }
    }
}

private struct ToastOverlayModifier: ViewModifier {
    @Bindable var environment: AppEnvironment

    init(environment: AppEnvironment) {
        _environment = Bindable(environment)
    }

    func body(content: Content) -> some View {
        ToastOverlayContent(content: content, environment: environment)
    }

    private struct ToastOverlayContent<Content: View>: View {
        let content: Content
        @Bindable var environment: AppEnvironment
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        init(content: Content, environment: AppEnvironment) {
            self.content = content
            _environment = Bindable(environment)
        }

        var body: some View {
            content
        }
    }
}

@MainActor
private final class GlobalToastOverlayPresenter {
    static let shared = GlobalToastOverlayPresenter()

    private var panel: ToastOverlayPanel?
    private var hostingView: NSHostingView<GlobalToastOverlayRoot>?
    private weak var anchorWindow: NSWindow?
    private var observerTokens: [NSObjectProtocol] = []

    func update(
        toast: AppEnvironment.ToastMessage?,
        anchorWindow: NSWindow?
    ) {
        guard let toast else {
            dismiss()
            return
        }
        guard let anchorWindow else { return }

        ensurePanel(attachedTo: anchorWindow)
        hostingView?.rootView = GlobalToastOverlayRoot(toast: toast)
        syncFrame(with: anchorWindow)
        panel?.orderFront(nil)
    }

    private func dismiss() {
        observerTokens.forEach(NotificationCenter.default.removeObserver)
        observerTokens.removeAll()
        if let panel, let parent = anchorWindow {
            parent.removeChildWindow(panel)
        }
        panel?.orderOut(nil)
        panel = nil
        hostingView = nil
        anchorWindow = nil
    }

    private func ensurePanel(attachedTo window: NSWindow) {
        if anchorWindow !== window {
            if let panel, let previous = anchorWindow {
                previous.removeChildWindow(panel)
            }
            anchorWindow = window
            installObservers(for: window)
        }

        if let panel {
            if panel.parent !== window {
                window.addChildWindow(panel, ordered: .above)
            }
            return
        }

        let panel = ToastOverlayPanel(
            contentRect: window.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]

        let hostingView = NSHostingView(rootView: GlobalToastOverlayRoot(toast: nil))
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView = NSView(frame: panel.frame)
        panel.contentView?.wantsLayer = true
        panel.contentView?.layer?.backgroundColor = NSColor.clear.cgColor
        panel.contentView?.addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: panel.contentView!.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: panel.contentView!.trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: panel.contentView!.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: panel.contentView!.bottomAnchor),
        ])

        window.addChildWindow(panel, ordered: .above)
        self.panel = panel
        self.hostingView = hostingView
    }

    private func installObservers(for window: NSWindow) {
        observerTokens.forEach(NotificationCenter.default.removeObserver)
        observerTokens = [
            NotificationCenter.default.addObserver(
                forName: NSWindow.didResizeNotification,
                object: window,
                queue: .main
            ) { [weak self] note in
                guard let window = note.object as? NSWindow else { return }
                Task { @MainActor in
                    self?.syncFrame(with: window)
                }
            },
            NotificationCenter.default.addObserver(
                forName: NSWindow.didMoveNotification,
                object: window,
                queue: .main
            ) { [weak self] note in
                guard let window = note.object as? NSWindow else { return }
                Task { @MainActor in
                    self?.syncFrame(with: window)
                }
            },
        ]
    }

    private func syncFrame(with window: NSWindow) {
        panel?.setFrame(window.frame, display: true)
    }
}

private final class ToastOverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private struct GlobalToastOverlayRoot: View {
    let toast: AppEnvironment.ToastMessage?

    var body: some View {
        ZStack {
            Color.clear

            if let toast {
                VStack {
                    Spacer(minLength: 0)
                    ToastView(toast: toast)
                        .padding(.horizontal, 24)
                        .padding(.bottom, 120)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .allowsHitTesting(false)
    }
}

private struct BootstrapTaskModifier: ViewModifier {
    let perform: Bool
    @Bindable var environment: AppEnvironment
    var scenePhase: ScenePhase

    func body(content: Content) -> some View {
        content.task {
            guard perform else { return }
            #if DEBUG
            PushGoAutomationRuntime.shared.recordBootstrapCheckpoint("macos.bootstrap.begin")
            #endif
            await environment.bootstrap()
            environment.updateScenePhase(scenePhase)
#if DEBUG
            #if !os(watchOS)
            PushGoAutomationRuntime.shared.recordBootstrapCheckpoint("macos.bootstrap.after_environment")
            await PushGoAutomationRuntime.shared.importStartupFixtureIfNeeded(environment: environment)
            PushGoAutomationRuntime.shared.recordBootstrapCheckpoint("macos.bootstrap.after_fixture_import")
            await PushGoAutomationRuntime.shared.executeStartupRequestIfNeeded(environment: environment)
            PushGoAutomationRuntime.shared.recordBootstrapCheckpoint("macos.bootstrap.after_request_execute")
            #endif
#endif
        }
    }
}
