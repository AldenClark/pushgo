
import SwiftUI

struct ContentView: View {
    var body: some View {
        RootView()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.appWindowBackground)
            .ignoresSafeArea()
    }
}

#Preview {
    ContentView()
}
