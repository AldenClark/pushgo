import Observation
import SwiftUI
import UIKit

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
            .task(id: toastPresentationState) {
                GlobalToastOverlayPresenter.shared.update(
                    toast: environment.toastMessage,
                    additionalBottomPadding: toastPresentationState.additionalBottomPadding
                )
            }
#if DEBUG
            .task {
                #if !os(watchOS)
                PushGoAutomationRuntime.shared.configureFromProcessEnvironment()
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

    private var toastPresentationState: ToastPresentationState {
        ToastPresentationState(
            toast: environment.toastMessage,
            additionalBottomPadding: environment.pendingLocalDeletionController.pendingDeletion == nil ? 0 : 52
        )
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
            ZStack(alignment: .bottom) {
                content

                if environment.pendingLocalDeletionController.pendingDeletion != nil {
                    PendingLocalDeletionBar(
                        controller: environment.pendingLocalDeletionController
                    )
                    .padding(.horizontal, 12)
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, pendingDeletionBottomPadding)
                    .zIndex(999)
                }
            }
            .animation(
                reduceMotion ? nil : .easeInOut(duration: 0.25),
                value: environment.pendingLocalDeletionController.pendingDeletion
            )
        }
    }
}

private let pendingDeletionBottomPadding: CGFloat = 54

private struct ToastPresentationState: Equatable {
    let toast: AppEnvironment.ToastMessage?
    let additionalBottomPadding: CGFloat
}

@MainActor
private final class GlobalToastOverlayPresenter {
    static let shared = GlobalToastOverlayPresenter()

    private var window: PassthroughToastWindow?
    private var hostingController: UIHostingController<GlobalToastOverlayRoot>?
    private var observerTokens: [NSObjectProtocol] = []
    private var currentToast: AppEnvironment.ToastMessage?
    private var currentAdditionalBottomPadding: CGFloat = 0
    private var keyboardOverlap: CGFloat = 0
    private var latestKeyboardFrame: CGRect?

    private init() {
        installKeyboardObserversIfNeeded()
    }

    func update(
        toast: AppEnvironment.ToastMessage?,
        additionalBottomPadding: CGFloat
    ) {
        currentToast = toast
        currentAdditionalBottomPadding = additionalBottomPadding
        guard toast != nil else {
            dismiss()
            return
        }
        guard let windowScene = resolveWindowScene() else { return }
        ensureWindow(in: windowScene)
        recalculateKeyboardOverlap()
        refreshRootView()
        window?.isHidden = false
    }

    private func dismiss() {
        currentToast = nil
        window?.isHidden = true
        hostingController = nil
        window = nil
    }

    private func ensureWindow(in windowScene: UIWindowScene) {
        if let window, window.windowScene === windowScene {
            return
        }

        let host = UIHostingController(
            rootView: GlobalToastOverlayRoot(
                toast: nil,
                additionalBottomPadding: 0,
                keyboardOverlap: 0
            )
        )
        host.view.backgroundColor = UIColor.clear

        let overlayWindow = PassthroughToastWindow(windowScene: windowScene)
        overlayWindow.frame = windowScene.coordinateSpace.bounds
        overlayWindow.rootViewController = host
        overlayWindow.backgroundColor = .clear
        overlayWindow.windowLevel = .alert + 1
        overlayWindow.isOpaque = false
        overlayWindow.isHidden = false

        hostingController = host
        window = overlayWindow
    }

    private func refreshRootView() {
        hostingController?.rootView = GlobalToastOverlayRoot(
            toast: currentToast,
            additionalBottomPadding: currentAdditionalBottomPadding,
            keyboardOverlap: keyboardOverlap
        )
    }

    private func installKeyboardObserversIfNeeded() {
        guard observerTokens.isEmpty else { return }
        let center = NotificationCenter.default
        observerTokens = [
            center.addObserver(
                forName: UIResponder.keyboardWillChangeFrameNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                let keyboardFrame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect
                Task { @MainActor in
                    self?.handleKeyboardFrameChange(keyboardFrame)
                }
            },
            center.addObserver(
                forName: UIResponder.keyboardWillHideNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.handleKeyboardFrameChange(nil)
                }
            },
        ]
    }

    private func handleKeyboardFrameChange(_ keyboardFrame: CGRect?) {
        latestKeyboardFrame = keyboardFrame
        recalculateKeyboardOverlap()
    }

    private func recalculateKeyboardOverlap() {
        guard let window else {
            keyboardOverlap = 0
            refreshRootView()
            return
        }

        if let keyboardFrame = latestKeyboardFrame {
            let keyboardFrameInWindow = window.convert(keyboardFrame, from: nil)
            keyboardOverlap = max(0, window.bounds.intersection(keyboardFrameInWindow).height)
        } else {
            keyboardOverlap = 0
        }
        refreshRootView()
    }

    private func resolveWindowScene() -> UIWindowScene? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.first(where: { scene in
            scene.activationState == .foregroundActive && scene.windows.contains(where: \.isKeyWindow)
        }) ?? scenes.first(where: { $0.activationState == .foregroundActive })
            ?? scenes.first(where: { $0.activationState == .foregroundInactive })
            ?? scenes.first
    }
}

private final class PassthroughToastWindow: UIWindow {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        nil
    }
}

private struct GlobalToastOverlayRoot: View {
    let toast: AppEnvironment.ToastMessage?
    let additionalBottomPadding: CGFloat
    let keyboardOverlap: CGFloat

    var body: some View {
        ZStack {
            Color.clear.ignoresSafeArea()

            if let toast {
                VStack {
                    Spacer(minLength: 0)
                    ToastView(toast: toast)
                        .padding(.horizontal, 24)
                        .padding(.bottom, effectiveBottomPadding)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .allowsHitTesting(false)
    }

    private var effectiveBottomPadding: CGFloat {
        max(112 + additionalBottomPadding, keyboardOverlap + 20)
    }
}

private struct BootstrapTaskModifier: ViewModifier {
    let perform: Bool
    @Bindable var environment: AppEnvironment
    var scenePhase: ScenePhase

    func body(content: Content) -> some View {
        content.task {
            guard perform else { return }
            await environment.bootstrap()
            environment.updateScenePhase(scenePhase)
#if DEBUG
            #if !os(watchOS)
            await PushGoAutomationRuntime.shared.importStartupFixtureIfNeeded(environment: environment)
            await PushGoAutomationRuntime.shared.executeStartupRequestIfNeeded(environment: environment)
            #endif
#endif
        }
    }
}
