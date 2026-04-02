
import SwiftUI

struct ContentView: View {
    var body: some View {
        RootView()
            .frame(minWidth: 1100, minHeight: 640)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(MainWindowAccessor())
    }
}
