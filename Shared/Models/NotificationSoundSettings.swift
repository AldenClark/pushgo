import Foundation

enum NotificationSoundLevel: String, Codable, CaseIterable, Identifiable, Sendable {
    case critical
    case high
    case normal
    case low

    var id: String { rawValue }

    var systemImageName: String {
        switch self {
        case .critical:
            return "exclamationmark.octagon.fill"
        case .high:
            return "bolt.badge.clock.fill"
        case .normal:
            return "bell.badge.fill"
        case .low:
            return "moon.stars.fill"
        }
    }

    var displayName: String {
        switch self {
        case .critical:
            return "Critical"
        case .high:
            return "High"
        case .normal:
            return "Normal"
        case .low:
            return "Low"
        }
    }

    var defaultBuiltinSoundID: String? {
        #if os(macOS)
        return nil
        #else
        switch self {
        case .critical:
            return "alert"
        case .high:
            return "notification-sound"
        case .normal:
            return "bubble-pop"
        case .low:
            return nil
        }
        #endif
    }

    var defaultDurationSeconds: Double? {
        #if os(macOS)
        return nil
        #else
        switch self {
        case .critical:
            return 30
        case .high:
            return 10
        case .normal, .low:
            return nil
        }
        #endif
    }

    var defaultGain: Double {
        #if os(macOS)
        return 1
        #else
        switch self {
        case .critical, .low:
            return 1
        case .high:
            return 0.8
        case .normal:
            return 0.5
        }
        #endif
    }

    var defaultMode: NotificationSoundMode {
        #if os(macOS)
        return self == .low ? .silent : .systemDefault
        #else
        defaultBuiltinSoundID == nil ? .silent : .builtin
        #endif
    }
}

enum NotificationSoundMode: String, Codable, CaseIterable, Sendable {
    case systemDefault
    case silent
    case builtin
    case custom

    var displayName: String {
        switch self {
        case .systemDefault:
            return "System Default"
        case .silent:
            return "Silent"
        case .builtin:
            return "Built-in"
        case .custom:
            return "Custom"
        }
    }
}

struct NotificationBuiltinSound: Hashable, Identifiable, Codable, Sendable {
    let id: String
    let filename: String
    let displayName: String
}

enum NotificationBuiltinSoundCatalog {
    static let sounds: [NotificationBuiltinSound] = [
        .init(id: "alert", filename: "alert.caf", displayName: "Alert Beacon"),
        .init(id: "level-up", filename: "level-up.caf", displayName: "Level Up"),
        .init(id: "bubble-pop", filename: "bubble-pop.caf", displayName: "Bubble Pop"),
        .init(id: "arcade-sound", filename: "arcade-sound.caf", displayName: "Arcade Spark"),
        .init(id: "cartoon-blinking", filename: "cartoon-blinking.caf", displayName: "Blink Bounce"),
        .init(id: "cute-chime", filename: "cute-chime.caf", displayName: "Cute Chime"),
        .init(id: "festive-chime", filename: "festive-chime.caf", displayName: "Festive Chime"),
        .init(id: "notification-sound", filename: "notification-sound.caf", displayName: "Notification Bell"),
        .init(id: "pop", filename: "pop.caf", displayName: "Pop Ping"),
        .init(id: "quick-whoosh", filename: "quick-whoosh.caf", displayName: "Quick Whoosh"),
    ]

    static func sound(id: String?) -> NotificationBuiltinSound? {
        guard let id else { return nil }
        return sounds.first { $0.id == id }
    }
}

struct NotificationCustomSoundAsset: Codable, Equatable, Hashable, Identifiable, Sendable {
    let id: String
    var displayName: String
    var originalFilename: String
    var importedAt: Date
    var sourceDurationSeconds: Double
    var sourceFileSizeBytes: Int64
    var sha256Hex: String
}

struct NotificationSoundRule: Codable, Equatable, Hashable, Sendable {
    var mode: NotificationSoundMode
    var builtinSoundID: String?
    var customAssetID: String?
    var durationSeconds: Double?
    var gain: Double
    var compiledFilename: String?
    var compilationToken: String?
    var updatedAt: Date

    static func `default`(for level: NotificationSoundLevel) -> NotificationSoundRule {
        NotificationSoundRule(
            mode: level.defaultMode,
            builtinSoundID: level.defaultBuiltinSoundID,
            customAssetID: nil,
            durationSeconds: level.defaultDurationSeconds,
            gain: level.defaultGain,
            compiledFilename: nil,
            compilationToken: nil,
            updatedAt: Date()
        )
    }
}

struct NotificationSoundSettings: Codable, Equatable, Sendable {
    static let schemaVersion = 1

    var schemaVersion: Int
    var rules: [NotificationSoundLevel: NotificationSoundRule]
    var customAssets: [NotificationCustomSoundAsset]
    var updatedAt: Date

    init(
        schemaVersion: Int = NotificationSoundSettings.schemaVersion,
        rules: [NotificationSoundLevel: NotificationSoundRule] = NotificationSoundLevel.allCases
            .reduce(into: [:]) { result, level in
                result[level] = .default(for: level)
            },
        customAssets: [NotificationCustomSoundAsset] = [],
        updatedAt: Date = Date()
    ) {
        self.schemaVersion = schemaVersion
        self.rules = rules
        self.customAssets = customAssets
        self.updatedAt = updatedAt
    }

    func rule(for level: NotificationSoundLevel) -> NotificationSoundRule {
        rules[level] ?? .default(for: level)
    }

    func customAsset(id: String?) -> NotificationCustomSoundAsset? {
        guard let id else { return nil }
        return customAssets.first { $0.id == id }
    }
}

struct NotificationSoundEffectiveSettingsManifest: Codable, Equatable, Sendable {
    static let schemaVersion = 1

    var schemaVersion: Int
    var settings: NotificationSoundSettings
    var writtenAt: Date

    init(
        schemaVersion: Int = NotificationSoundEffectiveSettingsManifest.schemaVersion,
        settings: NotificationSoundSettings,
        writtenAt: Date = Date()
    ) {
        self.schemaVersion = schemaVersion
        self.settings = settings
        self.writtenAt = writtenAt
    }
}
