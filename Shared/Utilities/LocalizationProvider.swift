import Foundation
enum LocalizationProvider {
    private final class TranslatorStore: @unchecked Sendable {
        private let lock = NSLock()
        private var translate: @Sendable (String, [CVarArg]) -> String

        init(translate: @escaping @Sendable (String, [CVarArg]) -> String) {
            self.translate = translate
        }

        func set(_ newValue: @escaping @Sendable (String, [CVarArg]) -> String) {
            lock.lock()
            translate = newValue
            lock.unlock()
        }

        func resolve(_ key: String, _ args: [CVarArg]) -> String {
            lock.lock()
            let handler = translate
            lock.unlock()
            return handler(key, args)
        }
    }

    private static let store = TranslatorStore { key, args in
        guard !args.isEmpty else { return key }
        return String(format: key, locale: .current, arguments: args)
    }
    static func installTranslator(_ handler: @escaping @Sendable (String, [CVarArg]) -> String) {
        store.set(handler)
    }

    static func localized(_ key: String, _ args: CVarArg...) -> String {
        store.resolve(key, args)
    }
}
