
import SwiftUI
#if canImport(CoreSpotlight)
import CoreSpotlight
#endif

@main
struct pushgoApp: App {
    @UIApplicationDelegateAdaptor(PushGoAppDelegate.self) var appDelegate
    
    @State private var environment = AppEnvironment.shared
    @State private var localizationManager = LocalizationManager.shared
    @State private var intentRouter = PushGoSystemIntentRouter.shared
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .withAppContext(
                    environment: environment,
                    localizationManager: localizationManager,
                    bootstrap: true,
                )
                .onOpenURL { url in
                    Task { @MainActor in
                        await environment.openDeepLink(url)
                    }
                }
                .onContinueUserActivity(PushGoUserActivityBuilder.messageActivityType) { activity in
                    continueSystemActivity(activity)
                }
                .onContinueUserActivity(PushGoUserActivityBuilder.eventActivityType) { activity in
                    continueSystemActivity(activity)
                }
                .onContinueUserActivity(PushGoUserActivityBuilder.thingActivityType) { activity in
                    continueSystemActivity(activity)
                }
                #if canImport(CoreSpotlight)
                .onContinueUserActivity(CSSearchableItemActionType) { activity in
                    continueSystemActivity(activity)
                }
                #endif
                .task {
                    await consumePendingIntentTarget()
                }
                .onChange(of: intentRouter.revision) { _, _ in
                    Task { @MainActor in
                        await consumePendingIntentTarget()
                    }
                }
        }
    }

    private func continueSystemActivity(_ activity: NSUserActivity) {
        guard let target = PushGoUserActivityBuilder.openTarget(from: activity) else { return }
        Task { @MainActor in
            await environment.openSystemTarget(target)
        }
    }

    @MainActor
    private func consumePendingIntentTarget() async {
        guard let target = PushGoSystemIntentRouter.shared.consumePendingTarget() else { return }
        await environment.openSystemTarget(target)
    }
}
