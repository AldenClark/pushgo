
import SwiftUI
#if canImport(CoreSpotlight)
import CoreSpotlight
#endif

@main
struct pushgomacApp: App {
    @NSApplicationDelegateAdaptor(PushGoAppDelegate.self) private var appDelegate

    @State private var environment = AppEnvironment.shared
    @State private var localizationManager = LocalizationManager.shared
    @State private var intentRouter = PushGoSystemIntentRouter.shared

    var body: some Scene {
        Window("pushgo_app_name", id: "main") {
            ContentView()
                .environment(environment)
                .environment(localizationManager)
                .withAppContext(
                    environment: environment,
                    localizationManager: localizationManager,
                    bootstrap: true
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
