import SwiftUI

struct RootView: View {
    @Environment(AppEnvironment.self) private var environment: AppEnvironment
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
#if os(iOS)
        @Bindable var bindableEnvironment = environment
#endif
        mainContent
#if DEBUG
            .qualityRuntimeReadinessOverlay(
                environment: environment,
                dynamicTypeSize: dynamicTypeSize
            )
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
    func qualityRuntimeReadinessOverlay(
        environment: AppEnvironment,
        dynamicTypeSize: DynamicTypeSize
    ) -> some View {
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
                .accessibilityLabel(
                    "Quality runtime \(status); dynamic type \(qualityDynamicTypeName(dynamicTypeSize))"
                )
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

    private func qualityDynamicTypeName(_ size: DynamicTypeSize) -> String {
        switch size {
        case .xSmall: "xSmall"
        case .small: "small"
        case .medium: "medium"
        case .large: "large"
        case .xLarge: "xLarge"
        case .xxLarge: "xxLarge"
        case .xxxLarge: "xxxLarge"
        case .accessibility1: "accessibility1"
        case .accessibility2: "accessibility2"
        case .accessibility3: "accessibility3"
        case .accessibility4: "accessibility4"
        case .accessibility5: "accessibility5"
        @unknown default: "unknown"
        }
    }
}
#endif
