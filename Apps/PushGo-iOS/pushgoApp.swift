
import SwiftUI

@main
struct pushgoApp: App {
    @UIApplicationDelegateAdaptor(PushGoAppDelegate.self) var appDelegate
    
    @State private var environment = AppEnvironment.shared
    @State private var appState = AppState()
    @State private var localizationManager = LocalizationManager.shared
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .withAppContext(
                    environment: environment,
                    appState: appState,
                    localizationManager: localizationManager,
                    bootstrap: true,
                )
        }
    }
}
