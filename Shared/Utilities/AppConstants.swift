import CoreFoundation
import Darwin
import Foundation
import ImageIO
import Network
import Security
import UniformTypeIdentifiers
import UserNotifications
#if canImport(SDWebImage)
import SDWebImage
#endif
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

enum PushGoAnimatedImageRuntime {
    static func bootstrapIfNeeded() {
#if canImport(SDWebImage)
        _ = didBootstrap
#endif
    }

#if canImport(SDWebImage)
    private static let didBootstrap: Void = {
        let manager = SDImageCodersManager.shared
        registerIfNeeded(SDImageGIFCoder.shared, into: manager)
        registerIfNeeded(SDImageAPNGCoder.shared, into: manager)
        registerIfNeeded(SDImageAWebPCoder.shared, into: manager)
    }()

    private static func registerIfNeeded(_ coder: any SDImageCoder, into manager: SDImageCodersManager) {
        let isAlreadyRegistered = (manager.coders ?? []).contains { existing in
            String(reflecting: type(of: existing)) == String(reflecting: type(of: coder))
        }
        if !isAlreadyRegistered {
            manager.addCoder(coder)
        }
    }
#endif
}

enum PushGoAutomationContext {
    private static let storageRootEnv = "PUSHGO_AUTOMATION_STORAGE_ROOT"
    private static let sandboxTempStoragePrefix = "sandbox-tmp:"
    private static let providerTokenEnv = "PUSHGO_AUTOMATION_PROVIDER_TOKEN"
    private static let skipPushAuthorizationEnv = "PUSHGO_AUTOMATION_SKIP_PUSH_AUTHORIZATION"
    private static let gatewayBaseURLEnv = "PUSHGO_AUTOMATION_GATEWAY_BASE_URL"
    private static let gatewayTokenEnv = "PUSHGO_AUTOMATION_GATEWAY_TOKEN"
    private static let forceForegroundAppEnv = "PUSHGO_AUTOMATION_FORCE_FOREGROUND_APP"
    private static let allowCrossAppDataAccessEnv = "PUSHGO_AUTOMATION_ALLOW_CROSS_APP_DATA_ACCESS"

    static var storageRootURL: URL? {
        normalizedURL(for: storageRootEnv)
    }

    static var keychainDirectoryURL: URL? {
        storageRootURL?.appendingPathComponent("keychain", isDirectory: true)
    }

    static var providerToken: String? {
        normalizedString(for: providerTokenEnv)
    }

    static var gatewayBaseURLString: String? {
        normalizedString(for: gatewayBaseURLEnv)
    }

    static var gatewayToken: String? {
        normalizedString(for: gatewayTokenEnv)
    }

    static var isActive: Bool {
        storageRootURL != nil
            || providerToken != nil
            || gatewayBaseURLString != nil
            || gatewayToken != nil
    }

    static var forceForegroundApp: Bool {
        guard isActive else { return false }
        guard let raw = normalizedString(for: forceForegroundAppEnv)?
            .lowercased()
        else {
            return true
        }
        if ["0", "false", "no", "off"].contains(raw) {
            return false
        }
        return true
    }

    static var bypassPushAuthorizationPrompt: Bool {
        if let raw = normalizedString(for: skipPushAuthorizationEnv)?.lowercased() {
            if ["1", "true", "yes", "on"].contains(raw) {
                return true
            }
            if ["0", "false", "no", "off"].contains(raw) {
                return false
            }
        }
        return providerToken != nil || storageRootURL != nil
    }

    static var blocksCrossAppDataAccess: Bool {
        guard isActive else { return false }
        guard let raw = normalizedString(for: allowCrossAppDataAccessEnv)?
            .lowercased()
        else {
            return true
        }
        if ["1", "true", "yes", "on"].contains(raw) {
            return false
        }
        if ["0", "false", "no", "off"].contains(raw) {
            return true
        }
        return true
    }

    static func appGroupContainerURL(identifier: String) -> URL? {
        guard let root = storageRootURL else { return nil }
        return root
            .appendingPathComponent("app-groups", isDirectory: true)
            .appendingPathComponent(identifier, isDirectory: true)
    }

    private static func normalizedURL(for envKey: String) -> URL? {
        guard let raw = normalizedString(for: envKey) else { return nil }
        if envKey == storageRootEnv, let sandboxURL = sandboxTempStorageURL(from: raw) {
            return sandboxURL
        }
        return URL(fileURLWithPath: raw, isDirectory: true)
    }

    private static func sandboxTempStorageURL(from raw: String) -> URL? {
        guard raw.hasPrefix(sandboxTempStoragePrefix) else { return nil }
        let relative = raw
            .dropFirst(sandboxTempStoragePrefix.count)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pushgo-automation-storage", isDirectory: true)
        guard !relative.isEmpty else { return url }
        let parts = relative
            .split(separator: "/")
            .map(String.init)
            .filter { !$0.isEmpty && $0 != "." && $0 != ".." }
        guard !parts.isEmpty else { return url }
        for part in parts {
            url.appendPathComponent(part, isDirectory: true)
        }
        return url
    }

    private static func normalizedString(for envKey: String) -> String? {
        let rawValue: String
        if let cString = getenv(envKey) {
            rawValue = String(cString: cString)
        } else {
            rawValue = ProcessInfo.processInfo.environment[envKey]
                ?? launchArgumentValue(for: envKey)
                ?? ""
        }
        let raw = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return raw.isEmpty ? nil : raw
    }

    private static func launchArgumentValue(for envKey: String) -> String? {
        let arguments = ProcessInfo.processInfo.arguments
        let key = "-\(envKey)"
        guard let index = arguments.firstIndex(of: key),
              arguments.indices.contains(index + 1)
        else {
            return nil
        }
        return arguments[index + 1]
    }
}

enum OpaqueId {
    static func generateHex128() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed: \(status)")
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}

enum PushGoSystemInteraction {
    static func copyTextToPasteboard(_ text: String) {
        guard !text.isEmpty else { return }
        guard !PushGoAutomationContext.blocksCrossAppDataAccess else { return }
#if os(iOS)
        UIPasteboard.general.string = text
#elseif os(macOS)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
#endif
    }

#if os(macOS)
    @discardableResult
    static func openExternalURL(_ url: URL) -> Bool {
        guard !PushGoAutomationContext.blocksCrossAppDataAccess else { return false }
        return NSWorkspace.shared.open(url)
    }
#endif
}

enum AppConstants {
    static let appGroupIdentifier = "group.ethan.pushgo.messages"
    static let serverConfigFilename = "server_config.json"
    static let messagesFilename = "messages.json"
    // Schema version is independent from on-disk filename.
    static let databaseVersion = "v9"
    static let databaseStoreFilename = "pushgo.db"
    static let messageIndexDatabaseFilename = "pushgo.index.sqlite"
    static let legacyDatabaseStoreFilenames = [
        "pushgo-v9.db",
    ]
    static let legacyMessageIndexDatabaseFilenames = [
        "pushgo.index.v9.sqlite",
        "pushgo.search.v9.sqlite",
        "pushgo.metadata.v9.sqlite",
    ]
    private static let productionServerAddress = "https://gateway.pushgo.cn"
    static let messageSyncNotificationName = "io.ethan.pushgo.message-sync"
    static let notificationIngressChangedNotificationName = "io.ethan.pushgo.notification-ingress-changed"
    static let copyToastNotificationName = "io.ethan.pushgo.copy-toast"
    static let watchProvisioningServerConfigDefaultsKey = "io.ethan.pushgo.watch.provisioning.server_config.v1"
    static let notificationDefaultCategoryIdentifier = "PUSHGO_DEFAULT"
    static let notificationEntityReminderCategoryIdentifier = "PUSHGO_ENTITY_REMINDER"
    static let maxStoredMessages = 100_000
    static let pruneBatchSize = 200
    static let maxMessageImageBytes: Int64 = 10 * 1024 * 1024
    static let deviceRegistrationTimeout: TimeInterval = 15

    static var defaultServerAddress: String {
        PushGoAutomationContext.gatewayBaseURLString ?? productionServerAddress
    }

    static var defaultServerURL: URL? {
        URL(string: defaultServerAddress)
    }

    static var defaultGatewayToken: String? {
        PushGoAutomationContext.gatewayToken
    }

    static func appGroupContainerURL(
        fileManager: FileManager = .default,
        identifier: String = appGroupIdentifier
    ) -> URL? {
        if let automationURL = PushGoAutomationContext.appGroupContainerURL(identifier: identifier) {
            return automationURL
        }
        return fileManager.containerURL(forSecurityApplicationGroupIdentifier: identifier)
    }

    static func appLocalContainerURL(
        fileManager: FileManager = .default,
        appGroupIdentifier: String = appGroupIdentifier
    ) -> URL? {
        if let automationRoot = PushGoAutomationContext.storageRootURL {
            return automationRoot
                .appendingPathComponent("app-local", isDirectory: true)
                .appendingPathComponent(appGroupIdentifier, isDirectory: true)
        }
        return fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
    }

    static func appLocalDatabaseDirectory(
        fileManager: FileManager = .default,
        appGroupIdentifier: String = appGroupIdentifier
    ) throws -> URL {
        guard let appLocalRoot = appLocalContainerURL(
            fileManager: fileManager,
            appGroupIdentifier: appGroupIdentifier
        ) else {
            throw NSError(
                domain: "io.ethan.pushgo.app-local",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Missing app local container."]
            )
        }

        if !fileManager.fileExists(atPath: appLocalRoot.path) {
            try fileManager.createDirectory(at: appLocalRoot, withIntermediateDirectories: true)
        }
        let databaseDirectory = appLocalRoot.appendingPathComponent("Database", isDirectory: true)
        if !fileManager.fileExists(atPath: databaseDirectory.path) {
            try fileManager.createDirectory(at: databaseDirectory, withIntermediateDirectories: true)
        }

        try migrateSQLiteFileFamily(
            fileManager: fileManager,
            directory: databaseDirectory,
            legacyFilenames: legacyDatabaseStoreMigrationFilenames(
                fileManager: fileManager,
                directory: databaseDirectory
            ),
            targetFilename: databaseStoreFilename
        )
        try migrateSQLiteFileFamily(
            fileManager: fileManager,
            directory: databaseDirectory,
            legacyFilenames: legacyMessageIndexDatabaseMigrationFilenames(
                fileManager: fileManager,
                directory: databaseDirectory
            ),
            targetFilename: messageIndexDatabaseFilename
        )
        try migrateSharedDatabaseArtifactsIntoAppLocal(
            fileManager: fileManager,
            appGroupIdentifier: appGroupIdentifier,
            targetDirectory: databaseDirectory
        )
        return databaseDirectory
    }

    static func migrateLegacyDatabaseArtifacts(
        fileManager: FileManager = .default,
        appGroupIdentifier: String = appGroupIdentifier
    ) throws {
        guard let root = appGroupContainerURL(
            fileManager: fileManager,
            identifier: appGroupIdentifier
        ) else {
            throw NSError(
                domain: "io.ethan.pushgo.app-group",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Missing app group container: \(appGroupIdentifier)"]
            )
        }
        let databaseDirectory = root.appendingPathComponent("Database", isDirectory: true)
        if !fileManager.fileExists(atPath: databaseDirectory.path) {
            try fileManager.createDirectory(at: databaseDirectory, withIntermediateDirectories: true)
        }

        try migrateSQLiteFileFamily(
            fileManager: fileManager,
            directory: databaseDirectory,
            legacyFilenames: legacyDatabaseStoreMigrationFilenames(
                fileManager: fileManager,
                directory: databaseDirectory
            ),
            targetFilename: databaseStoreFilename
        )
        try migrateSQLiteFileFamily(
            fileManager: fileManager,
            directory: databaseDirectory,
            legacyFilenames: legacyMessageIndexDatabaseMigrationFilenames(
                fileManager: fileManager,
                directory: databaseDirectory
            ),
            targetFilename: messageIndexDatabaseFilename
        )
    }

    private static func migrateSQLiteFileFamily(
        fileManager: FileManager,
        directory: URL,
        legacyFilenames: [String],
        targetFilename: String
    ) throws {
        let targetBaseURL = directory.appendingPathComponent(targetFilename)
        if fileManager.fileExists(atPath: targetBaseURL.path) {
            let targetSize = (try? fileManager.attributesOfItem(atPath: targetBaseURL.path)[.size] as? NSNumber)?
                .int64Value ?? 0
            if targetSize > 0 {
                return
            }
            try? fileManager.removeItem(at: targetBaseURL)
        }
        guard let sourceFilename = legacyFilenames.first(where: {
            fileManager.fileExists(atPath: directory.appendingPathComponent($0).path)
        }) else {
            return
        }

        let suffixes = ["", "-wal", "-shm", "-journal"]
        for suffix in suffixes {
            let sourceURL = directory.appendingPathComponent(sourceFilename + suffix)
            guard fileManager.fileExists(atPath: sourceURL.path) else { continue }
            let targetURL = directory.appendingPathComponent(targetFilename + suffix)
            guard !fileManager.fileExists(atPath: targetURL.path) else { continue }
            try migrateSingleFile(
                fileManager: fileManager,
                sourceURL: sourceURL,
                targetURL: targetURL
            )
        }
    }

    private static func migrateSingleFile(
        fileManager: FileManager,
        sourceURL: URL,
        targetURL: URL
    ) throws {
        do {
            try fileManager.moveItem(at: sourceURL, to: targetURL)
        } catch {
            try fileManager.copyItem(at: sourceURL, to: targetURL)
            try? fileManager.removeItem(at: sourceURL)
        }
    }

    private static func migrateSharedDatabaseArtifactsIntoAppLocal(
        fileManager: FileManager,
        appGroupIdentifier: String,
        targetDirectory: URL
    ) throws {
        guard let sharedRoot = appGroupContainerURL(
            fileManager: fileManager,
            identifier: appGroupIdentifier
        ) else {
            return
        }
        let sharedDatabaseDirectory = sharedRoot.appendingPathComponent("Database", isDirectory: true)
        guard fileManager.fileExists(atPath: sharedDatabaseDirectory.path) else {
            return
        }

        try migrateSQLiteFileFamilyBetweenDirectories(
            fileManager: fileManager,
            sourceDirectory: sharedDatabaseDirectory,
            targetDirectory: targetDirectory,
            sourceCandidates: databaseStoreSourceCandidates(
                fileManager: fileManager,
                sourceDirectory: sharedDatabaseDirectory
            ),
            targetFilename: databaseStoreFilename
        )
        try migrateSQLiteFileFamilyBetweenDirectories(
            fileManager: fileManager,
            sourceDirectory: sharedDatabaseDirectory,
            targetDirectory: targetDirectory,
            sourceCandidates: messageIndexDatabaseSourceCandidates(
                fileManager: fileManager,
                sourceDirectory: sharedDatabaseDirectory
            ),
            targetFilename: messageIndexDatabaseFilename
        )
    }

    private static func migrateSQLiteFileFamilyBetweenDirectories(
        fileManager: FileManager,
        sourceDirectory: URL,
        targetDirectory: URL,
        sourceCandidates: [String],
        targetFilename: String
    ) throws {
        let targetBaseURL = targetDirectory.appendingPathComponent(targetFilename)
        if fileManager.fileExists(atPath: targetBaseURL.path) {
            let targetSize = (try? fileManager.attributesOfItem(atPath: targetBaseURL.path)[.size] as? NSNumber)?
                .int64Value ?? 0
            if targetSize > 0 {
                return
            }
            try? fileManager.removeItem(at: targetBaseURL)
        }

        let sourceFilename = preferredSQLiteSourceFilename(
            fileManager: fileManager,
            directory: sourceDirectory,
            candidates: sourceCandidates
        )
        guard let sourceFilename else { return }

        let suffixes = ["", "-wal", "-shm", "-journal"]
        for suffix in suffixes {
            let sourceURL = sourceDirectory.appendingPathComponent(sourceFilename + suffix)
            guard fileManager.fileExists(atPath: sourceURL.path) else { continue }
            let targetURL = targetDirectory.appendingPathComponent(targetFilename + suffix)
            guard !fileManager.fileExists(atPath: targetURL.path) else { continue }
            try copySingleFile(
                fileManager: fileManager,
                sourceURL: sourceURL,
                targetURL: targetURL
            )
        }
    }

    private static func copySingleFile(
        fileManager: FileManager,
        sourceURL: URL,
        targetURL: URL
    ) throws {
        do {
            try fileManager.copyItem(at: sourceURL, to: targetURL)
        } catch {
            if fileManager.fileExists(atPath: targetURL.path) {
                return
            }
            throw error
        }
    }

    private static func preferredSQLiteSourceFilename(
        fileManager: FileManager,
        directory: URL,
        candidates: [String]
    ) -> String? {
        var fallback: String?
        for candidate in candidates {
            let candidateURL = directory.appendingPathComponent(candidate)
            guard fileManager.fileExists(atPath: candidateURL.path) else { continue }
            fallback = fallback ?? candidate
            let size = (try? fileManager.attributesOfItem(atPath: candidateURL.path)[.size] as? NSNumber)?
                .int64Value ?? 0
            if size > 0 {
                return candidate
            }
        }
        return fallback
    }

    private static func databaseStoreSourceCandidates(
        fileManager: FileManager,
        sourceDirectory: URL
    ) -> [String] {
        deduplicatedFilenames(
            [databaseStoreFilename] + legacyDatabaseStoreMigrationFilenames(
                fileManager: fileManager,
                directory: sourceDirectory
            )
        )
    }

    private static func messageIndexDatabaseSourceCandidates(
        fileManager: FileManager,
        sourceDirectory: URL
    ) -> [String] {
        deduplicatedFilenames(
            [messageIndexDatabaseFilename] + legacyMessageIndexDatabaseMigrationFilenames(
                fileManager: fileManager,
                directory: sourceDirectory
            )
        )
    }

    private static func legacyDatabaseStoreMigrationFilenames(
        fileManager: FileManager,
        directory: URL
    ) -> [String] {
        deduplicatedFilenames(
            legacyDatabaseStoreFilenames + discoveredLegacyDatabaseStoreFilenames(
                fileManager: fileManager,
                directory: directory
            )
        )
    }

    private static func legacyMessageIndexDatabaseMigrationFilenames(
        fileManager: FileManager,
        directory: URL
    ) -> [String] {
        deduplicatedFilenames(
            legacyMessageIndexDatabaseFilenames + discoveredLegacyMessageIndexDatabaseFilenames(
                fileManager: fileManager,
                directory: directory
            )
        )
    }

    private static func discoveredLegacyDatabaseStoreFilenames(
        fileManager: FileManager,
        directory: URL
    ) -> [String] {
        directoryFilenames(fileManager: fileManager, directory: directory)
            .compactMap { filename -> (name: String, version: Int)? in
                guard let version = legacyDatabaseVersion(from: filename) else { return nil }
                return (name: filename, version: version)
            }
            .sorted {
                if $0.version == $1.version {
                    return $0.name < $1.name
                }
                return $0.version > $1.version
            }
            .map(\.name)
    }

    private static func discoveredLegacyMessageIndexDatabaseFilenames(
        fileManager: FileManager,
        directory: URL
    ) -> [String] {
        directoryFilenames(fileManager: fileManager, directory: directory)
            .compactMap { filename -> (name: String, version: Int)? in
                guard let version = legacyMessageIndexVersion(from: filename) else { return nil }
                return (name: filename, version: version)
            }
            .sorted {
                if $0.version == $1.version {
                    return $0.name < $1.name
                }
                return $0.version > $1.version
            }
            .map(\.name)
    }

    private static func directoryFilenames(
        fileManager: FileManager,
        directory: URL
    ) -> [String] {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        return entries.map(\.lastPathComponent)
    }

    private static func legacyDatabaseVersion(from filename: String) -> Int? {
        guard filename.hasPrefix("pushgo-v"), filename.hasSuffix(".db") else { return nil }
        let start = filename.index(filename.startIndex, offsetBy: "pushgo-v".count)
        let end = filename.index(filename.endIndex, offsetBy: -".db".count)
        let number = String(filename[start..<end])
        return Int(number)
    }

    private static func legacyMessageIndexVersion(from filename: String) -> Int? {
        guard filename.hasSuffix(".sqlite") else { return nil }
        let prefixes = [
            "pushgo.index.v",
            "pushgo.search.v",
            "pushgo.metadata.v",
        ]
        guard let prefix = prefixes.first(where: { filename.hasPrefix($0) }) else { return nil }
        let start = filename.index(filename.startIndex, offsetBy: prefix.count)
        let end = filename.index(filename.endIndex, offsetBy: -".sqlite".count)
        let number = String(filename[start..<end])
        return Int(number)
    }

    private static func deduplicatedFilenames(_ filenames: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        result.reserveCapacity(filenames.count)
        for name in filenames where !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard seen.insert(name).inserted else { continue }
            result.append(name)
        }
        return result
    }

    static func sharedUserDefaults(
        suiteName: String = appGroupIdentifier
    ) -> UserDefaults {
        #if os(macOS) || os(iOS)
        if PushGoAutomationContext.blocksCrossAppDataAccess {
            return .standard
        }
        #endif
        return UserDefaults(suiteName: suiteName) ?? .standard
    }

    static var apnsEnvironment: String? {
#if os(macOS)
        guard let task = SecTaskCreateFromSelf(nil) else { return nil }
        let value = SecTaskCopyValueForEntitlement(task, "aps-environment" as CFString, nil)
        return value as? String
#else
        if let value = apnsEnvironmentFromMobileProvision() {
            return value
        }
#if targetEnvironment(simulator)
        return "development"
#else
        return "production"
#endif
#endif
    }

#if !os(macOS)
    private static func apnsEnvironmentFromMobileProvision() -> String? {
        guard let path = Bundle.main.path(forResource: "embedded", ofType: "mobileprovision") else {
            return nil
        }

        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let content = String(data: data, encoding: .isoLatin1)
        else {
            return nil
        }

        guard let start = content.range(of: "<?xml"),
              let end = content.range(of: "</plist>")
        else {
            return nil
        }

        let plistString = String(content[start.lowerBound..<end.upperBound])
        guard let plistData = plistString.data(using: .utf8),
              let plist = try? PropertyListSerialization.propertyList(
                  from: plistData,
                  options: [],
                  format: nil
              ) as? [String: Any],
              let entitlements = plist["Entitlements"] as? [String: Any]
        else {
            return nil
        }

        return entitlements["aps-environment"] as? String
    }
#endif
}

enum AppVersionDisplay {
    private static let displayVersionInfoKey = "PushGoDisplayVersion"

    static func current(bundle: Bundle = .main) -> String {
        let info = bundle.infoDictionary ?? [:]
        return resolve(
            displayVersion: infoValue(for: displayVersionInfoKey, in: info),
            shortVersion: infoValue(for: "CFBundleShortVersionString", in: info),
            buildVersion: infoValue(for: "CFBundleVersion", in: info)
        )
    }

    static func resolve(
        displayVersion: String?,
        shortVersion: String?,
        buildVersion: String?
    ) -> String {
        if let displayVersion = normalized(displayVersion) {
            return prefixedVersion(displayVersion)
        }
        if let shortVersion = normalized(shortVersion) {
            return prefixedVersion(shortVersion)
        }
        if let buildVersion = normalized(buildVersion) {
            return buildVersion
        }
        return "N/A"
    }

    private static func infoValue(for key: String, in info: [String: Any]) -> String? {
        if let raw = info[key] as? String {
            return raw
        }
        if let number = info[key] as? NSNumber {
            return number.stringValue
        }
        return nil
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isBuildSettingPlaceholder(trimmed) else {
            return nil
        }
        return trimmed
    }

    private static func prefixedVersion(_ value: String) -> String {
        guard let firstCharacter = value.first else { return value }
        if firstCharacter == "v" || firstCharacter == "V" {
            return value
        }
        return "v\(value)"
    }

    private static func isBuildSettingPlaceholder(_ value: String) -> Bool {
        (value.hasPrefix("$(") && value.hasSuffix(")"))
            || (value.hasPrefix("${") && value.hasSuffix("}"))
    }
}

enum MessageTimestampFormatter {
    static func listTimestamp(
        for date: Date,
        now: Date = Date(),
        calendar: Calendar = .autoupdatingCurrent,
        locale: Locale = .autoupdatingCurrent
    ) -> String {
        let startOfToday = calendar.startOfDay(for: now)
        let startOfDate = calendar.startOfDay(for: date)
        let dayDelta = calendar.dateComponents([.day], from: startOfDate, to: startOfToday).day ?? 0

        if calendar.isDate(date, inSameDayAs: now) {
            return formattedTime(date, locale: locale, calendar: calendar)
        }
        if dayDelta == 1 || dayDelta == 2 {
            return formattedRelative(date, relativeTo: now, locale: locale)
        }
        if dayDelta > 2 && dayDelta < 7 {
            return formatted(date, template: "EEE", locale: locale, calendar: calendar)
        }
        if calendar.isDate(date, equalTo: now, toGranularity: .year) {
            return formatted(date, template: "MMMd", locale: locale, calendar: calendar)
        }
        return formatted(date, template: "yMMMd", locale: locale, calendar: calendar)
    }

    private static func formattedTime(_ date: Date, locale: Locale, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private static func formattedRelative(_ date: Date, relativeTo now: Date, locale: Locale) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = locale
        formatter.unitsStyle = .full
        formatter.dateTimeStyle = .named
        return formatter.localizedString(for: date, relativeTo: now)
    }

    private static func formatted(
        _ date: Date,
        template: String,
        locale: Locale,
        calendar: Calendar
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter.string(from: date)
    }
}


enum URLSanitizer {
    private static let maxURLLength = 4096
    private static let externalOpenSchemes: Set<String> = [
        "http",
        "https",
        "ftp",
        "ftps",
        "mailto",
        "tel",
        "sms",
        "app",
        "pushgo",
    ]
    private static let blockedOpenSchemes: Set<String> = [
        "javascript",
        "data",
        "file",
        "content",
        "intent",
        "vbscript",
    ]

    static func isAllowedRemoteURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" else { return false }
        guard let host = url.host?.trimmingCharacters(in: .whitespacesAndNewlines), !host.isEmpty else {
            return false
        }
        if url.user != nil || url.password != nil {
            return false
        }
        return !isBlockedRemoteHost(host)
    }

    static func isAllowedExternalOpenURL(_ url: URL) -> Bool {
        guard let rawScheme = url.scheme?.lowercased(), !rawScheme.isEmpty else { return false }
        if blockedOpenSchemes.contains(rawScheme) { return false }
        if !externalOpenSchemes.contains(rawScheme) { return false }
        if ["http", "https", "ftp", "ftps"].contains(rawScheme) {
            guard let host = url.host?.trimmingCharacters(in: .whitespacesAndNewlines), !host.isEmpty else {
                return false
            }
            if url.user != nil || url.password != nil {
                return false
            }
        }
        return true
    }

    static func sanitizeHTTPSURL(_ url: URL?) -> URL? {
        guard let url, isAllowedRemoteURL(url) else { return nil }
        return url
    }

    static func sanitizeExternalOpenURL(_ url: URL?) -> URL? {
        guard let url, isAllowedExternalOpenURL(url) else { return nil }
        return url
    }

    static func resolveHTTPSURL(from raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= maxURLLength, let url = URL(string: trimmed) else { return nil }
        return sanitizeHTTPSURL(url)
    }

    static func resolveExternalOpenURL(from raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.count > maxURLLength { return nil }
        if containsBlockedEncodedScheme(trimmed) { return nil }

        if let direct = URL(string: trimmed), sanitizeExternalOpenURL(direct) != nil {
            return direct
        }

        // For scheme-less host-like links, only auto-upgrade to https.
        let hostCandidate = trimmed
            .split(separator: "/", maxSplits: 1, omittingEmptySubsequences: true)
            .first?
            .split(separator: ":", maxSplits: 1, omittingEmptySubsequences: true)
            .first
            .map(String.init)
            ?? ""
        guard hostCandidate.contains("."),
              hostCandidate.unicodeScalars.allSatisfy({ scalar in
                  CharacterSet.alphanumerics.contains(scalar) || scalar == "." || scalar == "-"
              }),
              let upgraded = URL(string: "https://\(trimmed)")
        else {
            return nil
        }
        return sanitizeExternalOpenURL(upgraded)
    }

    static func rewriteVisibleURLsInMarkdown(_ raw: String) -> String {
        guard !raw.isEmpty, raw.contains("](") else { return raw }

        var cursor = raw.startIndex
        var copyStart = raw.startIndex
        var rewritten = String()
        rewritten.reserveCapacity(raw.count)

        while cursor < raw.endIndex {
            guard raw[cursor] == "]" else {
                cursor = raw.index(after: cursor)
                continue
            }
            let markerNext = raw.index(after: cursor)
            guard markerNext < raw.endIndex, raw[markerNext] == "(" else {
                cursor = markerNext
                continue
            }

            let destinationStart = raw.index(after: markerNext)
            var end = destinationStart
            var depth = 0
            var matched = false
            while end < raw.endIndex {
                let ch = raw[end]
                if ch == "(" {
                    depth += 1
                } else if ch == ")" {
                    if depth == 0 {
                        matched = true
                        break
                    }
                    depth -= 1
                }
                end = raw.index(after: end)
            }
            guard matched else { break }

            rewritten.append(contentsOf: raw[copyStart..<destinationStart])
            rewritten.append(rewriteMarkdownDestination(String(raw[destinationStart..<end])))
            rewritten.append(")")

            cursor = raw.index(after: end)
            copyStart = cursor
        }

        guard copyStart != raw.startIndex else { return raw }
        rewritten.append(contentsOf: raw[copyStart..<raw.endIndex])
        return rewritten
    }

    private static func rewriteMarkdownDestination(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return raw }

        let leading = raw.firstIndex(where: { !$0.isWhitespace }) ?? raw.startIndex
        let trailingInclusive = raw.lastIndex(where: { !$0.isWhitespace }) ?? raw.index(before: raw.endIndex)
        let trailingExclusive = raw.index(after: trailingInclusive)
        let inner = raw[leading..<trailingExclusive]
        let tokenEnd = inner.firstIndex(where: \.isWhitespace) ?? inner.endIndex
        let token = String(inner[..<tokenEnd])
        let suffix = String(inner[tokenEnd...])
        let unwrapped: String
        if token.hasPrefix("<"), token.hasSuffix(">"), token.count >= 2 {
            unwrapped = String(token.dropFirst().dropLast())
        } else {
            unwrapped = token
        }

        let rewrittenToken: String
        if let safe = resolveExternalOpenURL(from: unwrapped)?.absoluteString {
            if token.hasPrefix("<"), token.hasSuffix(">") {
                rewrittenToken = "<\(safe)>"
            } else {
                rewrittenToken = safe
            }
        } else if looksLikeURLToken(unwrapped) {
            rewrittenToken = "#"
        } else {
            rewrittenToken = token
        }

        let prefix = String(raw[..<leading])
        let tail = String(raw[trailingExclusive...])
        return prefix + rewrittenToken + suffix + tail
    }

    private static func looksLikeURLToken(_ raw: String) -> Bool {
        raw.contains(":") || raw.lowercased().hasPrefix("www.")
    }

    private static func containsBlockedEncodedScheme(_ raw: String) -> Bool {
        var candidate = raw
        for _ in 0..<3 {
            if let scheme = leadingSchemeToken(candidate), blockedOpenSchemes.contains(scheme) {
                return true
            }
            guard let decoded = candidate.removingPercentEncoding, decoded != candidate else {
                break
            }
            candidate = decoded
        }
        if let scheme = leadingSchemeToken(candidate), blockedOpenSchemes.contains(scheme) {
            return true
        }
        return false
    }

    private static func leadingSchemeToken(_ raw: String) -> String? {
        let scalars = raw.unicodeScalars.drop(while: { CharacterSet.whitespacesAndNewlines.contains($0) })
        if scalars.isEmpty { return nil }
        var token = ""
        var sawColon = false
        for scalar in scalars {
            if scalar == ":" {
                sawColon = true
                break
            }
            if CharacterSet.whitespacesAndNewlines.contains(scalar)
                || CharacterSet.controlCharacters.contains(scalar)
            {
                continue
            }
            if CharacterSet.alphanumerics.contains(scalar) || scalar == "+" || scalar == "-" || scalar == "." {
                token.append(String(scalar).lowercased())
                if token.count > 32 { return nil }
                continue
            }
            return nil
        }
        guard sawColon, !token.isEmpty else { return nil }
        return token
    }

    private static func isBlockedRemoteHost(_ host: String) -> Bool {
        let normalized = host.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            .lowercased()
        guard !normalized.isEmpty else { return true }
        if normalized == "localhost" || normalized.hasSuffix(".localhost") {
            return true
        }
        if let ipv4 = IPv4Address(normalized) {
            return isBlockedIPv4(ipv4.rawValue)
        }
        if let ipv6 = IPv6Address(normalized) {
            return isBlockedIPv6(ipv6.rawValue)
        }
        return false
    }

    private static func isBlockedIPv4(_ bytes: Data) -> Bool {
        guard bytes.count == 4 else { return true }
        let octets = Array(bytes)
        let b0 = Int(octets[0])
        let b1 = Int(octets[1])
        if b0 == 0 || b0 == 10 || b0 == 127 { return true }
        if b0 == 169 && b1 == 254 { return true }
        if b0 == 172 && (16...31).contains(b1) { return true }
        if b0 == 192 && b1 == 168 { return true }
        if b0 == 100 && (64...127).contains(b1) { return true }
        if b0 >= 224 { return true }
        return false
    }

    private static func isBlockedIPv6(_ bytes: Data) -> Bool {
        guard bytes.count == 16 else { return true }
        let octets = Array(bytes)
        if octets.allSatisfy({ $0 == 0 }) { return true }
        if octets.dropLast().allSatisfy({ $0 == 0 }) && octets.last == 1 { return true } // ::1
        let b0 = Int(octets[0])
        let b1 = Int(octets[1])
        if b0 == 0xFE && (b1 & 0xC0) == 0x80 { return true } // fe80::/10
        if (b0 & 0xFE) == 0xFC { return true } // fc00::/7
        return false
    }

    static func validatedServerURL(from raw: String) -> URL? {
        guard let components = URLComponents(string: raw),
              let scheme = components.scheme?.lowercased(),
              let host = components.host, !host.isEmpty
        else { return nil }
        guard isAllowedServerURL(scheme: scheme, host: host) else { return nil }
        return components.url
    }

    static func validatedServerURL(_ baseURL: URL) -> URL? {
        guard let scheme = baseURL.scheme?.lowercased(),
              let host = baseURL.host, !host.isEmpty
        else { return nil }
        guard isAllowedServerURL(scheme: scheme, host: host) else { return nil }
        return baseURL
    }

    private static func isAllowedServerURL(scheme: String, host: String) -> Bool {
        if scheme == "https" {
            return true
        }
        guard scheme == "http", PushGoAutomationContext.isActive else {
            return false
        }
        return isLoopbackHost(host)
    }

    private static func isLoopbackHost(_ host: String) -> Bool {
        let normalized = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized == "localhost" || normalized == "127.0.0.1" || normalized == "::1"
    }
}

enum MessagePreviewExtractor {
    static func notificationPreview(from markdown: String) -> String {
        preview(from: markdown, maxLines: 1, maxCharacters: 180)
    }

    static func listPreview(from markdown: String) -> String {
        preview(from: markdown, maxLines: 6, maxCharacters: 1200)
    }

    private static func preview(from markdown: String, maxLines: Int, maxCharacters: Int) -> String {
        let normalized = preprocessMarkdownForPreview(markdown)
        let lines = plainLines(from: normalized)
        var rendered: [String] = []
        rendered.reserveCapacity(maxLines)

        for line in lines.prefix(maxLines) {
            let plain = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if !plain.isEmpty, !isPureLinkCollectionLine(plain) {
                rendered.append(plain)
            }
        }

        let joined = rendered.joined(separator: "\n")
        if joined.count <= maxCharacters {
            return joined
        }
        let truncated = joined.prefix(maxCharacters)
        return String(truncated).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func plainLines(from markdown: String) -> [String] {
        let document = PushGoMarkdownParser().parse(markdown)
        if document.blocks.isEmpty {
            return markdown
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }

        var lines: [String] = []
        for block in document.blocks {
            let blockLines = plainLines(from: block)
            for line in blockLines {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    lines.append(trimmed)
                }
            }
        }
        return lines
    }

    private static func plainLines(from block: MarkdownBlock) -> [String] {
        switch block {
        case let .heading(_, content):
            return plainPreviewLine(from: content)
        case let .paragraph(content):
            return plainPreviewLine(from: content)
        case let .blockquote(content):
            return plainPreviewLine(from: content, prefix: "> ")
        case let .callout(type, content):
            return plainPreviewLine(from: content, prefix: "[\(type.rawValue.uppercased())] ")
        case let .bulletList(items):
            return items.compactMap { plainPreviewLine(from: $0.content, prefix: "- ").first }
        case let .orderedList(items):
            return items.enumerated().compactMap { index, item in
                let ordinal = item.ordinal ?? (index + 1)
                return plainPreviewLine(from: item.content, prefix: "\(ordinal). ").first
            }
        case .table:
            return []
        case .horizontalRule:
            return []
        }
    }

    private static func plainPreviewLine(
        from inlines: [MarkdownInline],
        prefix: String = ""
    ) -> [String] {
        guard !isSkippableInlineSequence(inlines) else { return [] }
        return ["\(prefix)\(plainText(from: inlines))"]
    }

    private static func plainText(from inlines: [MarkdownInline]) -> String {
        inlines.map(plainText(from:)).joined()
    }

    private static func plainText(from inline: MarkdownInline) -> String {
        switch inline {
        case let .text(text):
            return text
        case let .bold(content):
            return plainText(from: content)
        case let .italic(content):
            return plainText(from: content)
        case let .strikethrough(content):
            return plainText(from: content)
        case let .highlight(content):
            return plainText(from: content)
        case let .code(code):
            return code
        case let .link(text, url):
            let label = plainText(from: text).trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
            if label.isEmpty {
                return ""
            }
            if label == normalizedURL {
                return label
            }
            return "\(label) (\(normalizedURL))"
        case let .mention(value):
            return "@\(value)"
        case let .tag(value):
            return "#\(value)"
        case let .autolink(autolink):
            return autolink.value
        }
    }

    private static func stripMarkdownImages(_ markdown: String) -> String {
        var output = ""
        var index = markdown.startIndex

        while index < markdown.endIndex {
            if markdown[index] == "!",
               let next = markdown.index(index, offsetBy: 1, limitedBy: markdown.endIndex),
               next < markdown.endIndex,
               markdown[next] == "[",
               let end = parseMarkdownImage(in: markdown, bangIndex: index)
            {
                index = end
                continue
            }

            output.append(markdown[index])
            index = markdown.index(after: index)
        }

        return output
    }

    private static func preprocessMarkdownForPreview(_ markdown: String) -> String {
        let normalized = markdown
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let withoutImages = stripMarkdownImages(normalized)
        let withoutCodeBlocks = stripFencedCodeBlocks(from: withoutImages)
        let withoutTables = stripMarkdownTables(from: withoutCodeBlocks)
        return stripRawHTML(from: withoutTables)
    }

    private static func stripFencedCodeBlocks(from markdown: String) -> String {
        var output: [String] = []
        var activeFence: Character?

        for line in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            let rawLine = String(line)
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if let fence = activeFence {
                if trimmed.hasPrefix(String(repeating: String(fence), count: 3)) {
                    activeFence = nil
                }
                continue
            }
            if trimmed.hasPrefix("```") {
                activeFence = "`"
                continue
            }
            if trimmed.hasPrefix("~~~") {
                activeFence = "~"
                continue
            }
            output.append(rawLine)
        }

        return output.joined(separator: "\n")
    }

    private static func stripMarkdownTables(from markdown: String) -> String {
        let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var filtered: [String] = []
        var index = 0

        while index < lines.count {
            let line = lines[index]
            if index + 1 < lines.count,
               line.contains("|"),
               isMarkdownTableSeparator(lines[index + 1])
            {
                index += 2
                while index < lines.count {
                    let row = lines[index]
                    let trimmed = row.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.isEmpty || !row.contains("|") {
                        break
                    }
                    index += 1
                }
                continue
            }

            filtered.append(line)
            index += 1
        }

        return filtered.joined(separator: "\n")
    }

    private static func isMarkdownTableSeparator(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.contains("-") else { return false }
        return trimmed.allSatisfy { char in
            char == "|" || char == "-" || char == ":" || char == " " || char == "\t"
        }
    }

    private static func stripRawHTML(from markdown: String) -> String {
        markdown
            .split(separator: "\n", omittingEmptySubsequences: false)
            .compactMap { rawLine in
                let line = String(rawLine)
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if isRawHTMLBlockLine(trimmed) {
                    return nil
                }
                return removingInlineHTMLTags(from: line)
            }
            .joined(separator: "\n")
    }

    private static func isRawHTMLBlockLine(_ line: String) -> Bool {
        guard line.hasPrefix("<"), line.contains(">") else { return false }
        if line.hasPrefix("<!--") { return true }
        return line.contains("</") || line.hasSuffix("/>") || line.hasSuffix(">")
    }

    private static func removingInlineHTMLTags(from line: String) -> String {
        var output = ""
        var insideTag = false
        for char in line {
            if char == "<" {
                insideTag = true
                continue
            }
            if char == ">" {
                insideTag = false
                continue
            }
            if !insideTag {
                output.append(char)
            }
        }
        return output
    }

    private static func isSkippableInlineSequence(_ inlines: [MarkdownInline]) -> Bool {
        if containsCodeInline(inlines) {
            return true
        }
        return isPureLinkCollection(inlines)
    }

    private static func containsCodeInline(_ inlines: [MarkdownInline]) -> Bool {
        inlines.contains { inline in
            switch inline {
            case .code:
                return true
            case let .bold(content),
                 let .italic(content),
                 let .strikethrough(content),
                 let .highlight(content):
                return containsCodeInline(content)
            case let .link(text, _):
                return containsCodeInline(text)
            default:
                return false
            }
        }
    }

    private static func isPureLinkCollection(_ inlines: [MarkdownInline]) -> Bool {
        var linkCount = 0

        func walk(_ inline: MarkdownInline) -> Bool {
            switch inline {
            case .link, .autolink:
                linkCount += 1
                return true
            case let .text(text):
                return text.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)).isEmpty
            case let .bold(content),
                 let .italic(content),
                 let .strikethrough(content),
                 let .highlight(content):
                return content.allSatisfy(walk)
            case let .mention(value):
                return value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            case let .tag(value):
                return value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            case .code:
                return false
            }
        }

        return inlines.allSatisfy(walk) && linkCount >= 2
    }

    private static func isPureLinkCollectionLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.hasPrefix("- "),
              !trimmed.hasPrefix("* "),
              !trimmed.hasPrefix("+ "),
              !hasOrderedListPrefix(trimmed)
        else {
            return false
        }

        if trimmed.contains(" | "),
           trimmed.components(separatedBy: " | ").count >= 2,
           trimmed.components(separatedBy: " (http").count > 2
        {
            return true
        }

        if isSingleLinkToken(trimmed) {
            return true
        }

        for separator in ["|", ",", ";"] {
            let parts = trimmed
                .split(separator: Character(separator), omittingEmptySubsequences: true)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            if parts.count >= 2 {
                return parts.allSatisfy(isSingleLinkToken)
            }
        }
        return false
    }

    private static func hasOrderedListPrefix(_ line: String) -> Bool {
        guard let separator = line.range(of: ". ") else { return false }
        return line[..<separator.lowerBound].allSatisfy(\.isNumber)
    }

    private static func isSingleLinkToken(_ token: String) -> Bool {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
            return !trimmed.contains(where: \.isWhitespace)
        }

        guard let open = trimmed.range(of: " (") else { return false }
        let label = trimmed[..<open.lowerBound].trimmingCharacters(in: .whitespaces)
        guard !label.isEmpty else { return false }
        let tail = trimmed[open.upperBound...]
        return (tail.hasPrefix("http://") || tail.hasPrefix("https://")) && trimmed.hasSuffix(")")
    }

    private static func parseMarkdownImage(in markdown: String, bangIndex: String.Index) -> String.Index? {
        let labelOpen = markdown.index(after: bangIndex)
        guard labelOpen < markdown.endIndex, markdown[labelOpen] == "[" else { return nil }

        var index = markdown.index(after: labelOpen)
        var bracketDepth = 1
        var escaped = false

        while index < markdown.endIndex {
            let char = markdown[index]
            if escaped {
                escaped = false
            } else if char == "\\" {
                escaped = true
            } else if char == "[" {
                bracketDepth += 1
            } else if char == "]" {
                bracketDepth -= 1
                if bracketDepth == 0 { break }
            }
            index = markdown.index(after: index)
        }

        guard index < markdown.endIndex else { return nil }
        let openParen = markdown.index(after: index)
        guard openParen < markdown.endIndex, markdown[openParen] == "(" else { return nil }

        index = markdown.index(after: openParen)
        var parenDepth = 1
        escaped = false

        while index < markdown.endIndex {
            let char = markdown[index]
            if escaped {
                escaped = false
            } else if char == "\\" {
                escaped = true
            } else if char == "(" {
                parenDepth += 1
            } else if char == ")" {
                parenDepth -= 1
                if parenDepth == 0 {
                    return markdown.index(after: index)
                }
            }
            index = markdown.index(after: index)
        }

        return nil
    }
}

enum MessageIdExtractor {
    static func extract(from payload: [String: Any]) -> String? {
        stringValue(keys: ["message_id"], from: payload)
    }

    private static func stringValue(keys: [String], from payload: [String: Any]) -> String? {
        for key in keys {
            if let raw = payload[key] as? String {
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    return trimmed
                }
            }
        }
        return nil
    }

}

enum OperationIdExtractor {
    static func extract(from payload: [String: Any]) -> String? {
        stringValue(key: "op_id", from: payload)
    }

    private static func stringValue(key: String, from payload: [String: Any]) -> String? {
        if let raw = payload[key] as? String {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        return nil
    }

}

enum PayloadTimeParser {
    private static let millisThreshold: Int64 = 1_000_000_000_000

    private static func normalizeEpochMilliseconds(_ raw: Int64) -> Int64 {
        if raw >= millisThreshold || raw <= -millisThreshold {
            return raw
        }
        return raw.saturatingMultiplication(by: 1000)
    }

    static func epochMilliseconds(from value: Any?) -> Int64? {
        switch value {
        case let number as Int:
            return normalizeEpochMilliseconds(Int64(number))
        case let number as Int64:
            return normalizeEpochMilliseconds(number)
        case let number as Double:
            return normalizeEpochMilliseconds(Int64(number))
        case let number as NSNumber:
            return normalizeEpochMilliseconds(number.int64Value)
        case let string as String:
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            guard let parsed = Int64(trimmed) else { return nil }
            return normalizeEpochMilliseconds(parsed)
        default:
            return nil
        }
    }

    static func epochMilliseconds(from value: AnyCodable?) -> Int64? {
        epochMilliseconds(from: value?.value)
    }

    static func epochSeconds(from value: Any?) -> Int64? {
        epochMilliseconds(from: value).map { $0 / 1000 }
    }

    static func epochSeconds(from value: AnyCodable?) -> Int64? {
        epochSeconds(from: value?.value)
    }

    static func date(from value: Any?) -> Date? {
        guard let milliseconds = epochMilliseconds(from: value) else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1000.0)
    }

    static func date(from value: AnyCodable?) -> Date? {
        date(from: value?.value)
    }
}

private extension Int64 {
    func saturatingMultiplication(by rhs: Int64) -> Int64 {
        let (result, overflow) = multipliedReportingOverflow(by: rhs)
        if !overflow {
            return result
        }
        return (self > 0) == (rhs > 0) ? .max : .min
    }
}

#if !os(watchOS)
struct NormalizedNotificationPayload {
    let title: String
    let body: String
    let hasExplicitTitle: Bool
    let channel: String?
    let url: URL?
    let decryptionState: PushMessage.DecryptionState?
    let rawPayload: [String: AnyCodable]
    let messageId: String?
    let operationId: String?
}

enum NotificationPayloadNormalizer {
    static func normalize(
        content: UNNotificationContent,
        requestId: String
    ) -> NormalizedNotificationPayload {
        let sanitizedPayload = UserInfoSanitizer.sanitize(content.userInfo)
        let rawEntityType = (sanitizedPayload["entity_type"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        let entityType = rawEntityType.isEmpty ? "message" : rawEntityType

        let title = content.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = content.body.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowContentAlertFallback = !NotificationPayloadSemantics.isGatewayFallbackAlertCandidate(
            entityType: entityType,
            title: title,
            body: body
        )
        let resolvedTitle = if let payloadTitle = (sanitizedPayload["title"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !payloadTitle.isEmpty
        {
            payloadTitle
        } else if allowContentAlertFallback {
            title
        } else {
            ""
        }
        let payloadBody = (sanitizedPayload["body"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedBody = if let payloadBody, !payloadBody.isEmpty {
            payloadBody
        } else if allowContentAlertFallback {
            body
        } else {
            ""
        }

        let channelIdentifier = content.threadIdentifier.isEmpty
            ? (sanitizedPayload["channel_id"] as? String)
            : content.threadIdentifier
        let trimmedChannel = channelIdentifier?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedChannel = trimmedChannel?.isEmpty == true ? nil : trimmedChannel
        let url = (sanitizedPayload["url"] as? String).flatMap { URLSanitizer.resolveExternalOpenURL(from: $0) }
        let stateRaw = sanitizedPayload["decryption_state"] as? String
        let decryptionState = PushMessage.DecryptionState.from(raw: stateRaw)

        let bridgedPayload = sanitizedPayload.reduce(into: [AnyHashable: Any]()) { result, element in
            result[element.key] = element.value
        }
        let normalizedRemote = NotificationHandling.normalizeRemoteNotification(bridgedPayload)

        var fallbackPayload = sanitizedPayload
        if fallbackPayload["title"] == nil {
            fallbackPayload["title"] = resolvedTitle
        }
        if fallbackPayload["body"] == nil {
            fallbackPayload["body"] = resolvedBody
        }
        if let resolvedChannel, fallbackPayload["channel_id"] == nil {
            fallbackPayload["channel_id"] = resolvedChannel
        }
        if let url, fallbackPayload["url"] == nil {
            fallbackPayload["url"] = url.absoluteString
        }

        let finalTitle = normalizedRemote?.title ?? resolvedTitle
        let finalBody = normalizedRemote?.body ?? resolvedBody
        let fallbackExplicitTitle = (sanitizedPayload["title"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty == false
        let hasExplicitTitle = normalizedRemote?.hasExplicitTitle ?? fallbackExplicitTitle
        let finalChannel = normalizedRemote?.channel ?? resolvedChannel
        let finalURL = normalizedRemote?.url ?? url
        let finalDecryptionState = normalizedRemote?.decryptionState ?? decryptionState
        let messageId = normalizedRemote?.messageId ?? MessageIdExtractor.extract(from: sanitizedPayload)
        let operationId = normalizedRemote?.operationId ?? OperationIdExtractor.extract(from: sanitizedPayload)

        let payloadSource = normalizedRemote?.rawPayload ?? fallbackPayload
        var rawPayload = payloadSource.reduce(into: [String: AnyCodable]()) { result, element in
            result[element.key] = AnyCodable(element.value)
        }
        rawPayload["_notificationRequestId"] = AnyCodable(requestId)

        return NormalizedNotificationPayload(
            title: finalTitle,
            body: finalBody,
            hasExplicitTitle: hasExplicitTitle,
            channel: finalChannel,
            url: finalURL,
            decryptionState: finalDecryptionState,
            rawPayload: rawPayload,
            messageId: messageId,
            operationId: operationId
        )
    }
}
#endif

enum NotificationMediaResolver {
    static func urlValue(in userInfo: [AnyHashable: Any], keys: [String]) -> URL? {
        urls(in: userInfo, keys: keys).first
    }

    static func urls(in userInfo: [AnyHashable: Any], keys: [String]) -> [URL] {
        var resolved: [URL] = []
        for key in keys {
            guard let value = userInfo[key] else { continue }
            appendResolvedURLs(from: value, into: &resolved)
        }
        return resolved
    }

    static func attachments(
        from userInfo: [AnyHashable: Any],
        candidates: [(key: String, identifier: String)],
        maxBytes: Int64 = AppConstants.maxMessageImageBytes,
        timeout: TimeInterval = 10
    ) async -> [UNNotificationAttachment] {
        for candidate in candidates {
            guard let url = urls(in: userInfo, keys: [candidate.key]).first else { continue }
            if let attachment = await downloadAttachment(
                from: url,
                identifier: candidate.identifier,
                maxBytes: maxBytes,
                timeout: timeout
            ) {
                return [attachment]
            }
        }
        return []
    }

    static func isImageData(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let type = CGImageSourceGetType(source)
        else {
            return false
        }
        if let utType = UTType(type as String) {
            return utType.conforms(to: .image)
        }
        return false
    }

    static func normalizedExtension(from url: URL, utType: UTType?) -> String {
        let ext = url.pathExtension.trimmingCharacters(in: .whitespacesAndNewlines)
        if !ext.isEmpty {
            return ext
        }
        if let preferred = utType?.preferredFilenameExtension?.trimmingCharacters(in: .whitespacesAndNewlines),
           !preferred.isEmpty
        {
            return preferred
        }
        return "jpg"
    }

    private static func downloadAttachment(
        from url: URL,
        identifier: String,
        maxBytes: Int64,
        timeout: TimeInterval
    ) async -> UNNotificationAttachment? {
        guard URLSanitizer.isAllowedRemoteURL(url) else { return nil }
        do {
            let data = try await SharedImageCache.fetchData(
                from: url,
                maxBytes: maxBytes,
                timeout: timeout
            )
            guard isImageData(data) else { return nil }

            let fileExt = normalizedExtension(from: url, utType: nil)
            let targetURL = SharedImageCache.cachedFileURL(for: url)
                ?? FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).\(fileExt)")
            if !FileManager.default.fileExists(atPath: targetURL.path) {
                try data.write(to: targetURL, options: .atomic)
            }

            let utType = UTType(filenameExtension: fileExt) ?? .image
            let typeHint = utType.identifier
            let options: [AnyHashable: Any] = [UNNotificationAttachmentOptionsTypeHintKey: typeHint]
            return try UNNotificationAttachment(identifier: identifier, url: targetURL, options: options)
        } catch {
            return nil
        }
    }

    private static func appendResolvedURLs(from raw: Any, into results: inout [URL]) {
        switch raw {
        case let text as String:
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            if let data = trimmed.data(using: .utf8),
               let decoded = try? JSONSerialization.jsonObject(with: data),
               let array = decoded as? [Any]
            {
                for item in array {
                    appendResolvedURLs(from: item, into: &results)
                }
                return
            }
            if let url = URLSanitizer.resolveHTTPSURL(from: trimmed),
               !results.contains(where: { $0.absoluteString == url.absoluteString })
            {
                results.append(url)
            }
        case let values as [Any]:
            for item in values {
                appendResolvedURLs(from: item, into: &results)
            }
        default:
            return
        }
    }
}

final class DarwinNotificationObserver {
    typealias Handler = () -> Void

    private let handler: Handler
    private var token: Int32 = 0
    private var isRegistered = false

    init(name: String, handler: @escaping Handler) {
        self.handler = handler
        var registrationToken: Int32 = 0
        let status = name.withCString { cName in
            notify_register_dispatch_shim(cName, &registrationToken, DispatchQueue.main) { [weak self] _ in
                self?.invoke()
            }
        }
        guard status == notifyStatusOK else { return }
        token = registrationToken
        isRegistered = true
    }

    deinit {
        if isRegistered {
            _ = notify_cancel_shim(token)
        }
    }

    fileprivate func invoke() {
        handler()
    }
}

enum DarwinNotificationPoster {
    static func post(name: String) {
        _ = name.withCString { cName in
            notify_post_shim(cName)
        }
    }
}

private let notifyStatusOK: Int32 = 0

@_silgen_name("notify_register_dispatch")
private func notify_register_dispatch_shim(
    _ name: UnsafePointer<CChar>,
    _ outToken: UnsafeMutablePointer<Int32>,
    _ queue: DispatchQueue,
    _ handler: @escaping @convention(block) (Int32) -> Void
) -> Int32

@_silgen_name("notify_cancel")
private func notify_cancel_shim(_ token: Int32) -> Int32

@_silgen_name("notify_post")
private func notify_post_shim(_ name: UnsafePointer<CChar>) -> Int32
