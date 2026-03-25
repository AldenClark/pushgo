import Foundation
import Observation

@MainActor
@Observable
final class LocalizationManager {
    static let shared = LocalizationManager()

    var swiftUILocale: Locale { .autoupdatingCurrent }

    private let bundle: Bundle

    init(bundle: Bundle = .main) {
        self.bundle = bundle
    }

    func localized(_ key: String, _ arguments: CVarArg...) -> String {
        localized(key, arguments: arguments)
    }

    nonisolated static func localizedSync(_ key: String, _ arguments: CVarArg...) -> String {
        LocalizationProvider.localized(key, arguments)
    }

    func localized(_ key: String, arguments: [CVarArg]) -> String {
        let template = resolveString(forKey: key)
        guard !arguments.isEmpty else { return template }
        return String(format: template, locale: .autoupdatingCurrent, arguments: arguments)
    }

    private func resolveString(forKey key: String) -> String {
        bundle.localizedString(forKey: key, value: key, table: nil)
    }
}
