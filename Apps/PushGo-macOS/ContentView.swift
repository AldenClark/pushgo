
import SwiftUI

struct ContentView: View {
    @Environment(AppEnvironment.self) private var environment: AppEnvironment

    var body: some View {
        Group {
            if environment.isMainWindowVisible {
                RootView()
            } else {
                Color.clear
            }
        }
        .frame(minWidth: 1100, minHeight: 640)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(MainWindowAccessor())
    }
}
