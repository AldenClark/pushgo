import SwiftUI

enum AppearanceMode: String, CaseIterable, Identifiable {
    case followSystem
    case light
    case dark

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .followSystem:
            return LocalizationProvider.localized("follow_the_system")
        case .light:
            return LocalizationProvider.localized("light_color")
        case .dark:
            return LocalizationProvider.localized("dark")
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .followSystem:
            nil
        case .light:
            .light
        case .dark:
            .dark
        }
    }
}

enum AppAppearance {
    private static let storageKey = "settings.appearance"

    static func currentMode() -> AppearanceMode {
        let storedValue = UserDefaults.standard.string(forKey: storageKey) ?? AppearanceMode.followSystem.rawValue
        return AppearanceMode(rawValue: storedValue) ?? .followSystem
    }

    static func store(_ mode: AppearanceMode) {
        UserDefaults.standard.set(mode.rawValue, forKey: storageKey)
    }
}
