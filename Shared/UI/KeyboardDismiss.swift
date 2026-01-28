import SwiftUI
#if os(iOS)
import UIKit
#endif

@MainActor
func dismissKeyboard() {
#if os(iOS)
    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
#endif
}

@MainActor
@ViewBuilder
func navigationContainer(@ViewBuilder _ content: () -> some View) -> some View {
    NavigationStack { content() }
}
