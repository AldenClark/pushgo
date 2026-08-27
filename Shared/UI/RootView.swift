import SwiftUI

struct RootView: View {
    @Environment(AppEnvironment.self) private var environment: AppEnvironment

    var body: some View {
#if os(iOS)
        @Bindable var bindableEnvironment = environment
#endif
        mainContent
#if DEBUG
            .qualityRuntimeReadinessOverlay(environment: environment)
#endif
#if os(iOS)
            .sheet(item: $bindableEnvironment.pendingSettingsPresentation) { presentation in
                SettingsView(
                    embedInNavigationContainer: true,
                    openDecryptionOnAppear: presentation == .decryption
                )
                .toastOverlay(environment: environment, showsPendingDeletionBar: false)
            }
#endif
    }

    @ViewBuilder
    private var mainContent: some View {
        #if os(watchOS)
        EmptyView()
        #else
        if environment.isDeletionRecoveryReady {
            MainTabContainerView()
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .task {
                    await environment.bootstrap()
                }
        }
        #endif
    }
}

#if DEBUG
private extension View {
    @ViewBuilder
    func qualityRuntimeReadinessOverlay(environment: AppEnvironment) -> some View {
#if os(watchOS)
        self
#else
        if let session = PushGoAutomationContext.qualitySession {
            let status = environment.qualityRuntimeReadiness == "inactive"
                ? "initializing"
                : environment.qualityRuntimeReadiness
            overlay(alignment: .topLeading) {
                Text("Quality runtime \(status)")
                    .font(.system(size: 1))
                    .foregroundStyle(.clear)
                    .frame(width: 1, height: 1)
                    .accessibilityIdentifier("quality-runtime.\(status)")
                    .accessibilityValue(session.sessionID)
            }
        } else if PushGoAutomationContext.isActive {
            overlay(alignment: .topLeading) {
                Text("Quality runtime \(PushGoAutomationContext.qualitySessionInputStatus)")
                    .font(.system(size: 1))
                    .foregroundStyle(.clear)
                    .frame(width: 1, height: 1)
                    .accessibilityIdentifier(
                        "quality-runtime.\(PushGoAutomationContext.qualitySessionInputStatus)"
                    )
            }
        } else {
            self
        }
#endif
    }
}
#endif
