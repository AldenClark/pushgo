import SwiftUI

struct RootView: View {
    @Environment(AppState.self) private var appState: AppState

    var body: some View {
        mainContent
            .preferredColorScheme(appState.preferredColorScheme)
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
