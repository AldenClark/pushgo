import Foundation
enum LocalizationProvider {
    static func localized(_ key: String, _ args: CVarArg...) -> String {
        localized(key, arguments: args)
    }

    static func localized(_ key: String, arguments: [CVarArg] = []) -> String {
        let template = Bundle.main.localizedString(forKey: key, value: key, table: nil)
        guard !arguments.isEmpty else { return template }
        return String(format: template, locale: .autoupdatingCurrent, arguments: arguments)
    }
}
