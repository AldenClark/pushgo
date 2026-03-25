
import SwiftUI

@main
struct pushgoApp: App {
    @UIApplicationDelegateAdaptor(PushGoAppDelegate.self) var appDelegate
    
    @State private var environment = AppEnvironment.shared
    @State private var localizationManager = LocalizationManager.shared
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .withAppContext(
                    environment: environment,
                    localizationManager: localizationManager,
                    bootstrap: true,
                )
        }
    }
}
