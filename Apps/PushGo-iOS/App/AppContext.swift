import Observation
import SwiftUI

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
                isPresented: Binding(
                    get: { environment.localStoreRecoveryState != nil },
                    set: { presented in
                        if !presented {
                            environment.dismissLocalStoreRecovery()
                        }
                    }
                ),
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
                isPresented: Binding(
                    get: { environment.shouldPresentNotificationPermissionAlert },
                    set: { presented in
                        if !presented {
                            environment.dismissNotificationPermissionAlert()
                        }
                    }
                )
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
#if DEBUG
            #if !os(watchOS)
            await PushGoAutomationRuntime.shared.importStartupFixtureIfNeeded(environment: environment)
            await PushGoAutomationRuntime.shared.executeStartupRequestIfNeeded(environment: environment)
            #endif
#endif
        }
    }
}
