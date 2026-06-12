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

    func toastOverlay(
        environment: AppEnvironment,
        showsPendingDeletionBar: Bool = true
    ) -> some View {
        modifier(ToastOverlayModifier(
            environment: environment,
            showsPendingDeletionBar: showsPendingDeletionBar
        ))
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
                isPresented: $environment.isLocalStoreRecoveryAlertPresented,
                presenting: environment.localStoreRecoveryState
            ) { state in
                if state.canRebuild {
                    Button(localizationManager.localized("rebuild_database_and_exit"), role: .destructive) {
                        environment.rebuildLocalStoreForRecoveryAndTerminate()
                    }
                }
                Button(localizationManager.localized("exit_app"), role: .destructive) {
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
    let showsPendingDeletionBar: Bool

    init(environment: AppEnvironment, showsPendingDeletionBar: Bool) {
        _environment = Bindable(environment)
        self.showsPendingDeletionBar = showsPendingDeletionBar
    }

    func body(content: Content) -> some View {
        ToastOverlayContent(
            content: content,
            environment: environment,
            showsPendingDeletionBar: showsPendingDeletionBar
        )
    }

    private struct ToastOverlayContent<Content: View>: View {
        let content: Content
        @Bindable var environment: AppEnvironment
        let showsPendingDeletionBar: Bool
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        init(
            content: Content,
            environment: AppEnvironment,
            showsPendingDeletionBar: Bool
        ) {
            self.content = content
            _environment = Bindable(environment)
            self.showsPendingDeletionBar = showsPendingDeletionBar
        }

        var body: some View {
            ZStack(alignment: .bottom) {
                content
                feedbackStack
            }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: environment.toastMessage)
            .animation(
                reduceMotion ? nil : .easeInOut(duration: 0.25),
                value: environment.pendingLocalDeletionController.pendingDeletion
            )
        }

        private var feedbackStack: some View {
            VStack(spacing: 8) {
                if let toast = environment.toastMessage {
                    Button {
                        environment.dismissToast(id: toast.id)
                    } label: {
                        ToastView(toast: toast)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(LocalizedStringKey("close"))
                    .padding(.horizontal, 24)
                    .frame(maxWidth: .infinity)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .zIndex(1000)
                }

                if showsPendingDeletionBar,
                   environment.pendingLocalDeletionController.pendingDeletion != nil {
                    PendingLocalDeletionBar(controller: environment.pendingLocalDeletionController)
                        .padding(.horizontal, 12)
                        .frame(maxWidth: .infinity)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .zIndex(999)
                }
            }
            .padding(.bottom, bottomPadding)
            .frame(maxWidth: .infinity)
        }

        private var bottomPadding: CGFloat {
            if showsPendingDeletionBar,
               environment.pendingLocalDeletionController.pendingDeletion != nil {
                return 54
            }
            return 112
        }
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
