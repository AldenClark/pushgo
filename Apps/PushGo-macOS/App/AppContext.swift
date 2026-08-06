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
        showsPendingDeletionBar: Bool = false
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
    @State private var sceneID = UUID()

    var body: some View {
        content
            .environment(environment)
            .environment(localizationManager)
            .environment(\.locale, localizationManager.swiftUILocale)
            .toastOverlay(environment: environment, showsPendingDeletionBar: true)
#if DEBUG
            .task {
                #if !os(watchOS)
                PushGoAutomationRuntime.shared.configureFromProcessEnvironment()
                PushGoAutomationRuntime.shared.recordBootstrapCheckpoint("macos.app_context.configure")
                #endif
            }
#endif
            .modifier(BootstrapTaskModifier(
                perform: bootstrap,
                environment: environment,
                scenePhase: scenePhase,
                sceneID: sceneID
            ))
            .onChange(of: scenePhase) { _, newValue in
                environment.updateScenePhase(newValue, sceneID: sceneID)
            }
            .task {
                environment.updateScenePhase(scenePhase, sceneID: sceneID)
            }
            .onDisappear {
                environment.removeScenePhase(sceneID: sceneID)
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
            content
                .overlay(alignment: .bottom) {
                    if let toast = environment.toastMessage {
                        Button {
                            environment.dismissToast(id: toast.id)
                        } label: {
                            ToastView(toast: toast)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(LocalizedStringKey("close"))
                        .padding(.horizontal, 24)
                        .padding(.bottom, 120)
                        .frame(maxWidth: .infinity)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .overlay(alignment: .bottom) {
                    if showsPendingDeletionBar,
                       environment.pendingLocalDeletionController.pendingDeletion != nil {
                        PendingLocalDeletionBar(controller: environment.pendingLocalDeletionController)
                            .padding(.horizontal, 20)
                            .padding(.bottom, 20)
                            .frame(maxWidth: .infinity)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: environment.toastMessage)
                .animation(
                    reduceMotion ? nil : .easeInOut(duration: 0.25),
                    value: environment.pendingLocalDeletionController.pendingDeletion
                )
        }
    }
}

private struct BootstrapTaskModifier: ViewModifier {
    let perform: Bool
    @Bindable var environment: AppEnvironment
    var scenePhase: ScenePhase
    let sceneID: UUID

    func body(content: Content) -> some View {
        content.task {
            guard perform else { return }
            #if DEBUG
            PushGoAutomationRuntime.shared.recordBootstrapCheckpoint("macos.bootstrap.begin")
            #endif
            await environment.bootstrap()
            environment.updateScenePhase(scenePhase, sceneID: sceneID)
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
