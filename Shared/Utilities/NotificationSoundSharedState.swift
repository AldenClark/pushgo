import Foundation
#if canImport(Darwin)
import Darwin
#endif

enum NotificationSoundSharedState {
    static let settingsDefaultsKey = "io.ethan.pushgo.notification_sound_settings.v1"
    #if os(macOS)
    static let macOSUserSoundsBookmarkDefaultsKey = "io.ethan.pushgo.notification_sound_macos_user_sounds_bookmark.v1"
    #endif

    static func loadSettings(
        suiteName: String = AppConstants.appGroupIdentifier
    ) -> NotificationSoundSettings? {
        guard let data = AppConstants.sharedUserDefaults(suiteName: suiteName)
            .data(forKey: settingsDefaultsKey)
        else {
            return nil
        }
        guard let settings = try? JSONDecoder().decode(NotificationSoundSettings.self, from: data),
              settings.schemaVersion == NotificationSoundSettings.schemaVersion
        else {
            return nil
        }
        return settings
    }

    static func saveSettings(
        _ settings: NotificationSoundSettings?,
        suiteName: String = AppConstants.appGroupIdentifier
    ) {
        let defaults = AppConstants.sharedUserDefaults(suiteName: suiteName)
        guard let settings else {
            defaults.removeObject(forKey: settingsDefaultsKey)
            return
        }
        if let data = try? JSONEncoder().encode(settings) {
            defaults.set(data, forKey: settingsDefaultsKey)
        }
    }

    static func loadEffectiveSettingsForNotifications(
        appGroupIdentifier: String = AppConstants.appGroupIdentifier
    ) -> NotificationSoundSettings? {
        loadEffectiveSettingsManifest(appGroupIdentifier: appGroupIdentifier)?.settings
            ?? loadSettings(suiteName: appGroupIdentifier)
    }

    static func loadEffectiveSettingsManifest(
        fileManager: FileManager = .default,
        appGroupIdentifier: String = AppConstants.appGroupIdentifier
    ) -> NotificationSoundEffectiveSettingsManifest? {
        guard let url = try? NotificationSoundStorage.effectiveSettingsManifestURL(
            fileManager: fileManager,
            appGroupIdentifier: appGroupIdentifier,
            createDirectory: false
        ),
            let data = try? Data(contentsOf: url),
            let manifest = try? JSONDecoder().decode(NotificationSoundEffectiveSettingsManifest.self, from: data),
            manifest.schemaVersion == NotificationSoundEffectiveSettingsManifest.schemaVersion,
            manifest.settings.schemaVersion == NotificationSoundSettings.schemaVersion
        else {
            return nil
        }
        return manifest
    }

    static func saveEffectiveSettingsManifest(
        _ settings: NotificationSoundSettings?,
        fileManager: FileManager = .default,
        appGroupIdentifier: String = AppConstants.appGroupIdentifier
    ) throws {
        let url = try NotificationSoundStorage.effectiveSettingsManifestURL(
            fileManager: fileManager,
            appGroupIdentifier: appGroupIdentifier,
            createDirectory: true
        )
        guard let settings else {
            if fileManager.fileExists(atPath: url.path) {
                try fileManager.removeItem(at: url)
            }
            return
        }
        let manifest = NotificationSoundEffectiveSettingsManifest(settings: settings)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(manifest)
        try data.write(to: url, options: .atomic)
    }

    #if os(macOS)
    static func loadMacOSUserSoundsBookmark(
        suiteName: String = AppConstants.appGroupIdentifier
    ) -> Data? {
        AppConstants.sharedUserDefaults(suiteName: suiteName)
            .data(forKey: macOSUserSoundsBookmarkDefaultsKey)
    }

    static func saveMacOSUserSoundsBookmark(
        _ bookmark: Data?,
        suiteName: String = AppConstants.appGroupIdentifier
    ) {
        let defaults = AppConstants.sharedUserDefaults(suiteName: suiteName)
        guard let bookmark else {
            defaults.removeObject(forKey: macOSUserSoundsBookmarkDefaultsKey)
            return
        }
        defaults.set(bookmark, forKey: macOSUserSoundsBookmarkDefaultsKey)
    }
    #endif
}

enum NotificationSoundStorage {
    private static let originalsDirectoryName = "notification-sounds"
    private static let effectiveSettingsManifestFilename = "effective-settings.json"
    private static let errorDomain = "io.ethan.pushgo.notification-sound"

    static func appGroupSoundsDirectory(
        fileManager: FileManager = .default,
        appGroupIdentifier: String = AppConstants.appGroupIdentifier
    ) throws -> URL {
        guard let containerURL = AppConstants.appGroupContainerURL(
            fileManager: fileManager,
            identifier: appGroupIdentifier
        ) else {
            throw missingAppGroupError(appGroupIdentifier)
        }
        let directory = containerURL
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Sounds", isDirectory: true)
        try ensureDirectory(directory, fileManager: fileManager)
        return directory
    }

    static func compiledSoundsDirectory(
        fileManager: FileManager = .default,
        appGroupIdentifier: String = AppConstants.appGroupIdentifier
    ) throws -> URL {
        #if os(macOS)
        try macOSUserSoundsDirectory(fileManager: fileManager)
        #else
        try appGroupSoundsDirectory(
            fileManager: fileManager,
            appGroupIdentifier: appGroupIdentifier
        )
        #endif
    }

    static func withCompiledSoundsDirectoryAccess<T>(
        fileManager: FileManager = .default,
        appGroupIdentifier: String = AppConstants.appGroupIdentifier,
        _ body: (URL) throws -> T
    ) throws -> T {
        #if os(macOS)
        let directory = try macOSUserSoundsDirectory(fileManager: fileManager)
        let didAccess = directory.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                directory.stopAccessingSecurityScopedResource()
            }
        }
        try ensureDirectory(directory, fileManager: fileManager)
        return try body(directory)
        #else
        let directory = try appGroupSoundsDirectory(
            fileManager: fileManager,
            appGroupIdentifier: appGroupIdentifier
        )
        return try body(directory)
        #endif
    }

    static func appGroupOriginalsDirectory(
        fileManager: FileManager = .default,
        appGroupIdentifier: String = AppConstants.appGroupIdentifier
    ) throws -> URL {
        try appGroupNotificationSoundSupportDirectory(
            fileManager: fileManager,
            appGroupIdentifier: appGroupIdentifier,
            createDirectory: true
        )
    }

    static func effectiveSettingsManifestURL(
        fileManager: FileManager = .default,
        appGroupIdentifier: String = AppConstants.appGroupIdentifier,
        createDirectory: Bool
    ) throws -> URL {
        let directory = try appGroupNotificationSoundSupportDirectory(
            fileManager: fileManager,
            appGroupIdentifier: appGroupIdentifier,
            createDirectory: createDirectory
        )
        return directory.appendingPathComponent(effectiveSettingsManifestFilename, isDirectory: false)
    }

    static func appGroupNotificationSoundSupportDirectory(
        fileManager: FileManager = .default,
        appGroupIdentifier: String = AppConstants.appGroupIdentifier,
        createDirectory: Bool
    ) throws -> URL {
        guard let containerURL = AppConstants.appGroupContainerURL(
            fileManager: fileManager,
            identifier: appGroupIdentifier
        ) else {
            throw missingAppGroupError(appGroupIdentifier)
        }
        let directory = containerURL
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent(originalsDirectoryName, isDirectory: true)
        if createDirectory {
            try ensureDirectory(directory, fileManager: fileManager)
        }
        return directory
    }

    static func isSafeFilename(_ filename: String) -> Bool {
        let trimmed = filename.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty
            && trimmed == filename
            && !filename.contains("/")
            && !filename.contains("\\")
    }

    static func ensureDirectory(_ url: URL, fileManager: FileManager = .default) throws {
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else {
                try fileManager.removeItem(at: url)
                try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
                return
            }
        } else {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }

    static func removeExtendedAttribute(_ name: String, from url: URL) {
#if canImport(Darwin)
        url.withUnsafeFileSystemRepresentation { representation in
            guard let representation else { return }
            _ = name.withCString { attributeName in
                removexattr(representation, attributeName, 0)
            }
        }
#endif
    }

    #if os(macOS)
    static func macOSUserSoundsDirectoryURL(
        fileManager: FileManager = .default
    ) -> URL {
        realUserHomeDirectory(fileManager: fileManager)
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Sounds", isDirectory: true)
    }

    static func macOSUserSoundsDirectory(
        fileManager: FileManager = .default
    ) throws -> URL {
        let targetURL = macOSUserSoundsDirectoryURL(fileManager: fileManager)
        guard let bookmark = NotificationSoundSharedState.loadMacOSUserSoundsBookmark() else {
            throw macOSUserSoundsPermissionError()
        }
        var isStale = false
        let resolvedURL = try URL(
            resolvingBookmarkData: bookmark,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
        guard resolvedURL.standardizedFileURL.path == targetURL.standardizedFileURL.path else {
            throw macOSUserSoundsPermissionError()
        }
        let didAccess = resolvedURL.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                resolvedURL.stopAccessingSecurityScopedResource()
            }
        }
        guard canReadWriteDirectory(resolvedURL, fileManager: fileManager) else {
            throw macOSUserSoundsPermissionError()
        }
        if isStale {
            let refreshedBookmark = try resolvedURL.bookmarkData(options: [.withSecurityScope])
            NotificationSoundSharedState.saveMacOSUserSoundsBookmark(refreshedBookmark)
        }
        return resolvedURL
    }

    static func saveMacOSUserSoundsBookmark(for directoryURL: URL) throws {
        let targetURL = macOSUserSoundsDirectoryURL().standardizedFileURL
        let selectedURL = directoryURL.standardizedFileURL
        guard isMacOSUserSoundsDirectory(selectedURL, targetURL: targetURL) else {
            throw NSError(
                domain: errorDomain,
                code: 12,
                userInfo: [NSLocalizedDescriptionKey: "Please select ~/Library/Sounds."]
            )
        }
        let didAccess = selectedURL.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                selectedURL.stopAccessingSecurityScopedResource()
            }
        }
        guard canReadWriteDirectory(selectedURL, fileManager: .default) else {
            throw macOSUserSoundsPermissionError()
        }
        let bookmark = try selectedURL.bookmarkData(options: [.withSecurityScope])
        NotificationSoundSharedState.saveMacOSUserSoundsBookmark(bookmark)
    }

    static func hasMacOSUserSoundsDirectoryAccess(
        fileManager: FileManager = .default
    ) -> Bool {
        (try? withCompiledSoundsDirectoryAccess(fileManager: fileManager) { directory in
            canReadWriteDirectory(directory, fileManager: fileManager)
        }) == true
    }

    private static func realUserHomeDirectory(
        fileManager: FileManager
    ) -> URL {
        if let passwordEntry = getpwuid(getuid()),
           let home = passwordEntry.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: home), isDirectory: true)
        }
        return fileManager.homeDirectoryForCurrentUser
    }

    private static func isMacOSUserSoundsDirectory(
        _ selectedURL: URL,
        targetURL: URL
    ) -> Bool {
        let selectedPath = selectedURL
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
        let targetPath = targetURL
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
        return selectedPath == targetPath
    }

    private static func canReadWriteDirectory(
        _ directoryURL: URL,
        fileManager: FileManager
    ) -> Bool {
        do {
            try ensureDirectory(directoryURL, fileManager: fileManager)
            let probeURL = directoryURL.appendingPathComponent(
                ".pushgo-permission-\(UUID().uuidString)",
                isDirectory: false
            )
            try Data().write(to: probeURL, options: .atomic)
            try? fileManager.removeItem(at: probeURL)
            return true
        } catch {
            return false
        }
    }

    private static func macOSUserSoundsPermissionError() -> NSError {
        NSError(
            domain: errorDomain,
            code: 13,
            userInfo: [NSLocalizedDescriptionKey: "PushGo needs permission to write ~/Library/Sounds."]
        )
    }
    #endif

    private static func missingAppGroupError(_ identifier: String) -> NSError {
        NSError(
            domain: errorDomain,
            code: 11,
            userInfo: [NSLocalizedDescriptionKey: "Missing app group container for \(identifier)."]
        )
    }
}
