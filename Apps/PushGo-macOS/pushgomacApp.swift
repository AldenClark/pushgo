
import SwiftUI

@main
struct pushgomacApp: App {
    @NSApplicationDelegateAdaptor(PushGoAppDelegate.self) private var appDelegate

    @State private var environment = AppEnvironment.shared
    @State private var localizationManager = LocalizationManager.shared

    var body: some Scene {
        Window("PushGo", id: "main") {
            ContentView()
                .environment(environment)
                .environment(localizationManager)
                .withAppContext(
                    environment: environment,
                    localizationManager: localizationManager,
                    bootstrap: true
                )
        }
        .commands {
            CommandGroup(replacing: .appSettings) {}
        }
        .windowToolbarStyle(.unified)

        Settings {
            SettingsView()
                .environment(environment)
                .environment(localizationManager)
                .withAppContext(
                    environment: environment,
                    localizationManager: localizationManager,
                    bootstrap: false
                )
                .frame(minWidth: 520, minHeight: 420)
        }
    }
}
