
import SwiftUI
import WatchKit

@main
struct pushgowatch_Watch_AppApp: App {
    @WKApplicationDelegateAdaptor(PushGoWatchAppDelegate.self) private var appDelegate

    @State private var environment = AppEnvironment.shared
    @State private var localizationManager = LocalizationManager.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .withAppContext(
                    environment: environment,
                    localizationManager: localizationManager,
                    bootstrap: true
                )
        }
        WKNotificationScene(
            controller: NotificationHostingController.self,
            category: AppConstants.notificationDefaultCategoryIdentifier
        )
        WKNotificationScene(
            controller: NotificationHostingController.self,
            category: AppConstants.notificationEntityReminderCategoryIdentifier
        )
    }
}
