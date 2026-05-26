import SwiftUI

struct RootView: View {
    @Environment(AppEnvironment.self) private var environment: AppEnvironment

    var body: some View {
#if os(iOS)
        @Bindable var bindableEnvironment = environment
#endif
        mainContent
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
        MainTabContainerView()
        #endif
    }
}
