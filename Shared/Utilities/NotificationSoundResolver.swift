import Foundation

struct NotificationSoundResolution: Equatable, Sendable {
    let filename: String?
    let prefersCriticalSoundAPI: Bool
    let usesSystemDefault: Bool

    static var systemDefault: NotificationSoundResolution {
        NotificationSoundResolution(
            filename: nil,
            prefersCriticalSoundAPI: false,
            usesSystemDefault: true
        )
    }

    static func named(
        _ filename: String,
        prefersCriticalSoundAPI: Bool = false
    ) -> NotificationSoundResolution {
        NotificationSoundResolution(
            filename: filename,
            prefersCriticalSoundAPI: prefersCriticalSoundAPI,
            usesSystemDefault: false
        )
    }
}

enum NotificationSoundResolver {
    static func resolve(for level: NotificationSoundLevel) -> NotificationSoundResolution? {
        resolve(for: level, settings: NotificationSoundSharedState.loadEffectiveSettingsForNotifications())
    }

    static func resolve(
        for level: NotificationSoundLevel,
        settings: NotificationSoundSettings?
    ) -> NotificationSoundResolution? {
        if let settings {
            return configuredResolution(for: level, settings: settings)
        }
        return defaultResolution(for: level)
    }

    private static func defaultResolution(for level: NotificationSoundLevel) -> NotificationSoundResolution? {
        if level.defaultMode == .systemDefault {
            return .systemDefault
        }
        if level.defaultMode == .silent {
            return nil
        }
        if let filename = validatedCompiledFilename(compiledFilename(for: level)) {
            return .named(filename)
        }
        guard let defaultBuiltin = NotificationBuiltinSoundCatalog.sound(id: level.defaultBuiltinSoundID) else {
            return nil
        }
        return .named(defaultBuiltin.filename, prefersCriticalSoundAPI: level == .critical)
    }

    private static func configuredResolution(
        for level: NotificationSoundLevel,
        settings: NotificationSoundSettings
    ) -> NotificationSoundResolution? {
        let rule = settings.rule(for: level)
        switch rule.mode {
        case .systemDefault:
            return .systemDefault
        case .silent:
            return level == .low ? nil : defaultResolution(for: level)
        case .builtin:
            if let filename = configuredCompiledFilename(rule.compiledFilename) {
                return .named(filename)
            }
            #if os(macOS)
            return nil
            #else
            guard let builtin = NotificationBuiltinSoundCatalog.sound(id: rule.builtinSoundID ?? level.defaultBuiltinSoundID) else {
                return nil
            }
            return .named(builtin.filename, prefersCriticalSoundAPI: level == .critical)
            #endif
        case .custom:
            guard let filename = configuredCompiledFilename(rule.compiledFilename) else {
                return nil
            }
            return .named(filename)
        }
    }

    private static func configuredCompiledFilename(_ filename: String?) -> String? {
        #if os(macOS)
        sanitizedFilename(filename)
        #else
        validatedCompiledFilename(filename)
        #endif
    }

    private static func validatedCompiledFilename(_ filename: String?) -> String? {
        guard let filename = sanitizedFilename(filename) else {
            return nil
        }
        if let compiledDirectory = try? NotificationSoundStorage.compiledSoundsDirectory(),
           FileManager.default.fileExists(atPath: compiledDirectory.appendingPathComponent(filename).path) {
            return filename
        }
        return nil
    }

    private static func sanitizedFilename(_ filename: String?) -> String? {
        guard let filename = filename?.trimmingCharacters(in: .whitespacesAndNewlines),
              !filename.isEmpty,
              !filename.contains("/"),
              !filename.contains("\\")
        else {
            return nil
        }
        return filename
    }

    private static func compiledFilename(for level: NotificationSoundLevel) -> String {
        "pushgo-\(level.rawValue).caf"
    }
}
