
import SwiftUI

struct ContentView: View {
    var body: some View {
        mainContent
            .background(MainWindowAccessor())
    }

    @ViewBuilder
    private var mainContent: some View {
        if #available(macOS 26.0, *) {
            rootContent
        } else {
            rootContent
                .toolbarBackground(.hidden, for: .windowToolbar)
        }
    }

    private var rootContent: some View {
        RootView()
            .frame(minWidth: 1100, minHeight: 640)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(backgroundLayer)
    }

    @ViewBuilder
    private var backgroundLayer: some View {
        if #available(macOS 26.0, *) {
            Color.clear
        } else {
            Color.appWindowBackground.ignoresSafeArea()
        }
    }
}

#Preview {
    ContentView()
}
