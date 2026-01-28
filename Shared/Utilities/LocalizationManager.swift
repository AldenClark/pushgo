import Foundation
import Observation

enum AppLocale: String, CaseIterable, Identifiable {
    case system
    case english = "en"
    case japanese = "ja"
    case korean = "ko"
    case chineseSimplified = "zh-Hans"
    case chineseTraditional = "zh-Hant"

    var id: String { rawValue }

    var displayNameKeyString: String {
        switch self {
        case .system:
            "system_default"
        case .english:
            "english"
        case .japanese:
            "japanese"
        case .korean:
            "korean"
        case .chineseSimplified:
            "simplified_chinese"
        case .chineseTraditional:
            "traditional_chinese"
        }
    }

    var displayNameKey: String { displayNameKeyString }

    var fallbackDisplayName: String {
        switch self {
        case .system:
            "Follow System"
        case .english:
            "English"
        case .japanese:
            "Japanese"
        case .korean:
            "Korean"
        case .chineseSimplified:
            "Simplified Chinese"
        case .chineseTraditional:
            "Traditional Chinese"
        }
    }

    var bundleName: String? {
        switch self {
        case .system:
            nil
        default:
            rawValue
        }
    }

    var foundationLocale: Locale {
        if let identifier = bundleName {
            return Locale(identifier: identifier)
        }
        return .autoupdatingCurrent
    }
}

@Observable
final class LocalizationManager: @unchecked Sendable {
    static let shared = LocalizationManager()

    private(set) var locale: AppLocale

    var swiftUILocale: Locale { locale.foundationLocale }

    private let userDefaults: UserDefaults
    private let bundle: Bundle

    private static let fallbackDisplayNames: [String: String] = Dictionary(uniqueKeysWithValues: AppLocale.allCases
        .map { (
            $0.displayNameKeyString,
            $0.fallbackDisplayName,
        ) })

    private static let legacyLocaleMap: [String: AppLocale] = [
        "en-GB": .english,
        "zh-TW": .chineseTraditional,
        "zh-HK": .chineseTraditional,
    ]

    private enum DefaultsKey {
        static let locale = "settings.language"
    }

    init(
        bundle: Bundle = .main,
        userDefaults: UserDefaults? = LocalizationManager.makeDefaults(),
    ) {
        self.bundle = bundle
        self.userDefaults = userDefaults ?? .standard

        locale = Self.resolveStoredLocale(from: self.userDefaults)
    }

    func updateLocale(_ newValue: AppLocale) {
        guard newValue != locale else { return }
        locale = newValue
        userDefaults.set(newValue.rawValue, forKey: DefaultsKey.locale)
    }

    func localized(_ key: String, _ arguments: CVarArg...) -> String {
        localized(key, arguments: arguments)
    }

    static func localizedSync(_ key: String, _ arguments: CVarArg...) -> String {
        shared.localized(key, arguments: arguments)
    }

    func localized(_ key: String, arguments: [CVarArg]) -> String {
        let template = resolveString(forKey: key)
        guard !arguments.isEmpty else { return template }
        return String(format: template, locale: locale.foundationLocale, arguments: arguments)
    }

    private func resolveString(forKey key: String) -> String {
        let activeBundle = bundle(for: locale)
        let resolved = activeBundle.localizedString(forKey: key, value: key, table: nil)
        if let fallback = Self.fallbackDisplayNames[key], resolved == key {
            return fallback
        }
        return resolved
    }

    private func bundle(for locale: AppLocale) -> Bundle {
        guard let identifier = locale.bundleName,
              let path = bundle.path(forResource: identifier, ofType: "lproj"),
              let localizedBundle = Bundle(path: path)
        else {
            return bundle
        }
        return localizedBundle
    }

    private static func resolveStoredLocale(from defaults: UserDefaults) -> AppLocale {
        guard let storedValue = defaults.string(forKey: DefaultsKey.locale) else {
            return .system
        }
        if let current = AppLocale(rawValue: storedValue) {
            return current
        }
        if let migrated = legacyLocaleMap[storedValue] {
            defaults.set(migrated.rawValue, forKey: DefaultsKey.locale)
            return migrated
        }
        return .system
    }

    private static func makeDefaults() -> UserDefaults? {
        return .standard
    }
}
