import Observation
import SwiftUI

extension View {
    func withAppContext(
        environment: AppEnvironment,
        appState: AppState,
        localizationManager: LocalizationManager,
        bootstrap: Bool,
    ) -> some View {
        DynamicLocaleWrapper(
            content: self,
            environment: environment,
            appState: appState,
            localizationManager: localizationManager,
            bootstrap: bootstrap,
        )
    }

    func toastOverlay() -> some View {
        modifier(ToastOverlayModifier())
    }
}

private struct DynamicLocaleWrapper<Content: View>: View {
    let content: Content
    @Bindable var environment: AppEnvironment
    @Bindable var appState: AppState
    @Bindable var localizationManager: LocalizationManager
    let bootstrap: Bool
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        content
            .environment(\.appEnvironment, environment)
            .environment(appState)
            .environment(localizationManager)
            .environment(\.locale, localizationManager.swiftUILocale)
            .toastOverlay()
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
    }
}

private struct ToastOverlayModifier: ViewModifier {
    @Environment(\.appEnvironment) private var environment

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

                if let toast = environment.toastMessage {
                    ToastView(toast: toast)
                        .padding(.horizontal, 24)
                        .frame(maxWidth: .infinity)
                        .padding(.bottom, toastBottomPadding)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .onTapGesture {
                            environment.dismissToast(id: toast.id)
                        }
                        .zIndex(999)
                }
            }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: environment.toastMessage)
        }
    }
}

private let toastBottomPadding: CGFloat = 200

private struct BootstrapTaskModifier: ViewModifier {
    let perform: Bool
    @Bindable var environment: AppEnvironment
    var scenePhase: ScenePhase

    func body(content: Content) -> some View {
        content.task {
            guard perform else { return }
            await environment.bootstrap()
            environment.updateScenePhase(scenePhase)
        }
    }
}
