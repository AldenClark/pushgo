
import SwiftUI

@main
struct pushgomacApp: App {
    @NSApplicationDelegateAdaptor(PushGoAppDelegate.self) private var appDelegate

    @Environment(\.openWindow) private var openWindow
    @State private var environment = AppEnvironment.shared
    @State private var appState = AppState()
    @State private var localizationManager = LocalizationManager.shared

    var body: some Scene {
        Window("PushGo", id: "main") {
            ContentView()
                .environment(\.appEnvironment, environment)
                .environment(appState)
                .environment(localizationManager)
                .withAppContext(
                    environment: environment,
                    appState: appState,
                    localizationManager: localizationManager,
                    bootstrap: true
                )
        }
        .commands { appCommands }
        .windowToolbarStyle(.unified)

        Settings {
            SettingsView()
                .environment(\.appEnvironment, environment)
                .environment(appState)
                .environment(localizationManager)
                .withAppContext(
                    environment: environment,
                    appState: appState,
                    localizationManager: localizationManager,
                    bootstrap: false
                )
                .frame(minWidth: 520, minHeight: 420)
        }

        MenuBarExtra("PushGo", systemImage: "bell.badge") {
            MacMenuBarContentView()
                .environment(\.appEnvironment, environment)
                .environment(appState)
                .environment(localizationManager)
                .withAppContext(
                    environment: environment,
                    appState: appState,
                    localizationManager: localizationManager,
                    bootstrap: false
                )
        }
        .menuBarExtraStyle(.window)
    }

    @CommandsBuilder
    private var appCommands: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button(localizationManager.localized("settings")) {
                openSettings()
            }
            .keyboardShortcut(",", modifiers: [.command])
        }

        CommandMenu("PushGo") {
            Button(localizationManager.localized("open_main_window")) {
                openMainWindow()
            }
            .keyboardShortcut("m", modifiers: [.command, .shift])

            Button(localizationManager.localized("settings")) {
                openSettings()
            }
            .keyboardShortcut(",", modifiers: [.command])

            Divider()

            Button(localizationManager.localized("refresh_messages")) {
                Task { @MainActor in
                    await environment.reloadMessagesFromStore()
                }
            }
            .keyboardShortcut("r", modifiers: [.command])
        }
    }

    private func openMainWindow() {
        MainWindowController.shared.prepareForShowingMainWindow()
        if MainWindowController.shared.focusMainWindowIfExists() {
            return
        }
        openWindow(id: "main")
    }

    private func openSettings() {
        openMainWindow()
        Task { @MainActor in
            await Task.yield()
            NotificationCenter.default.post(name: .pushgoOpenSettingsFromMenuBar, object: nil)
        }
    }
}
