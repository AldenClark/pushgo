
import SwiftUI
import WatchKit

@main
struct pushgowatch_Watch_AppApp: App {
    @WKApplicationDelegateAdaptor(PushGoWatchAppDelegate.self) private var appDelegate

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
                    bootstrap: true
                )
        }
        WKNotificationScene(
            controller: NotificationHostingController.self,
            category: AppConstants.nceMarkdownCategoryIdentifier
        )
        WKNotificationScene(
            controller: NotificationHostingController.self,
            category: AppConstants.ncePlainCategoryIdentifier
        )
    }
}
