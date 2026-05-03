import Foundation
import os
import Security

enum KeychainStoreError: LocalizedError, Equatable {
    case unexpectedData
    case missingAccessGroup(String)
    case osStatus(Int32)

    var statusCode: Int32? {
        if case let .osStatus(status) = self {
            return status
        }
        return nil
    }

    var errorDescription: String? {
        switch self {
        case .unexpectedData:
            return LocalizationProvider.localized("keychain_unexpected_data")
        case let .missingAccessGroup(suffix):
            return "Keychain access group is not configured for \(suffix)."
        case let .osStatus(status):
            return LocalizationProvider.localized("keychain_operation_failed_placeholder", status)
        }
    }
}

struct KeychainStore {
    private struct AutomationStoredItem: Codable {
        let account: String
        let dataBase64: String
    }

    let service: String
    let accessGroup: String?
    let synchronizable: Bool?
    let usesDataProtectionKeychain: Bool

    init(
        service: String,
        accessGroup: String? = nil,
        synchronizable: Bool? = nil,
        usesDataProtectionKeychain: Bool = true
    ) {
        self.service = service
        self.accessGroup = accessGroup
        self.synchronizable = synchronizable
        self.usesDataProtectionKeychain = usesDataProtectionKeychain
    }

    func read(account: String) throws -> Data? {
        if let itemURL = automationItemURL(account: account) {
            guard FileManager.default.fileExists(atPath: itemURL.path) else {
                return nil
            }
            let data = try Data(contentsOf: itemURL)
            let stored = try JSONDecoder().decode(AutomationStoredItem.self, from: data)
            guard let decoded = Data(base64Encoded: stored.dataBase64) else {
                throw KeychainStoreError.unexpectedData
            }
            return decoded
        }

        var query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecMatchLimit: kSecMatchLimitOne,
            kSecReturnData: true,
        ]
        if let accessGroup {
            query[kSecAttrAccessGroup] = accessGroup
        }
        if usesDataProtectionKeychain {
            query[kSecUseDataProtectionKeychain] = kCFBooleanTrue
        }
        if synchronizable == true {
            query[kSecAttrSynchronizable] = kSecAttrSynchronizableAny
        }

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw KeychainStoreError.osStatus(status)
        }
        guard let data = item as? Data else {
            throw KeychainStoreError.unexpectedData
        }
        return data
    }

    func write(account: String, data: Data) throws {
        if let itemURL = automationItemURL(account: account) {
            let directory = itemURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let stored = AutomationStoredItem(account: account, dataBase64: data.base64EncodedString())
            let encoded = try JSONEncoder().encode(stored)
            try encoded.write(to: itemURL, options: [.atomic])
            return
        }

        if accessGroup != nil {
            do {
                try add(account: account, data: data)
                return
            } catch let error as KeychainStoreError {
                guard error.statusCode == errSecDuplicateItem else {
                    throw error
                }
            }
        }

        var query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        if let accessGroup {
            query[kSecAttrAccessGroup] = accessGroup
        }
        if usesDataProtectionKeychain {
            query[kSecUseDataProtectionKeychain] = kCFBooleanTrue
        }
        if synchronizable == true {
            query[kSecAttrSynchronizable] = kCFBooleanTrue
        }

        let attributes: [CFString: Any] = [
            kSecValueData: data,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlock,
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }
        if updateStatus != errSecItemNotFound {
            throw KeychainStoreError.osStatus(updateStatus)
        }

        var addQuery = query
        attributes.forEach { addQuery[$0.key] = $0.value }
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainStoreError.osStatus(addStatus)
        }
    }

    func add(account: String, data: Data) throws {
        if let itemURL = automationItemURL(account: account) {
            if FileManager.default.fileExists(atPath: itemURL.path) {
                throw KeychainStoreError.osStatus(errSecDuplicateItem)
            }
            let directory = itemURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let stored = AutomationStoredItem(account: account, dataBase64: data.base64EncodedString())
            let encoded = try JSONEncoder().encode(stored)
            try encoded.write(to: itemURL, options: [.atomic])
            return
        }

        var addQuery: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecValueData: data,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlock,
        ]
        if let accessGroup {
            addQuery[kSecAttrAccessGroup] = accessGroup
        }
        if usesDataProtectionKeychain {
            addQuery[kSecUseDataProtectionKeychain] = kCFBooleanTrue
        }
        if synchronizable == true {
            addQuery[kSecAttrSynchronizable] = kCFBooleanTrue
        }

        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainStoreError.osStatus(status)
        }
    }

    func delete(account: String) throws {
        if let itemURL = automationItemURL(account: account) {
            if FileManager.default.fileExists(atPath: itemURL.path) {
                try FileManager.default.removeItem(at: itemURL)
            }
            return
        }

        var query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        if let accessGroup {
            query[kSecAttrAccessGroup] = accessGroup
        }
        if usesDataProtectionKeychain {
            query[kSecUseDataProtectionKeychain] = kCFBooleanTrue
        }
        if synchronizable == true {
            query[kSecAttrSynchronizable] = kSecAttrSynchronizableAny
        }
        let status = SecItemDelete(query as CFDictionary)
        if status == errSecSuccess || status == errSecItemNotFound {
            return
        }
        throw KeychainStoreError.osStatus(status)
    }

    func readAll() throws -> [(account: String, data: Data)] {
        if let directory = automationServiceDirectoryURL {
            guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
            let urls = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
            return try urls.compactMap { url in
                let data = try Data(contentsOf: url)
                let stored = try JSONDecoder().decode(AutomationStoredItem.self, from: data)
                guard let decoded = Data(base64Encoded: stored.dataBase64) else {
                    throw KeychainStoreError.unexpectedData
                }
                return (account: stored.account, data: decoded)
            }
        }

        var query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecMatchLimit: kSecMatchLimitAll,
            kSecReturnAttributes: true,
        ]
        if let accessGroup {
            query[kSecAttrAccessGroup] = accessGroup
        }
        if usesDataProtectionKeychain {
            query[kSecUseDataProtectionKeychain] = kCFBooleanTrue
        }
        if synchronizable == true {
            query[kSecAttrSynchronizable] = kSecAttrSynchronizableAny
        }

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return []
        }
        guard status == errSecSuccess else {
            throw KeychainStoreError.osStatus(status)
        }

        guard let rawItems = item as? [[CFString: Any]] else {
            throw KeychainStoreError.unexpectedData
        }

        return try rawItems.compactMap { entry in
            guard let account = entry[kSecAttrAccount] as? String else {
                return nil
            }
            guard let data = try read(account: account) else {
                return nil
            }
            return (account: account, data: data)
        }
    }

    static func sharedAccessGroup(matchingSuffix suffix: String) -> String? {
        accessGroup(matchingSuffix: suffix)
    }

    static func accessGroup(matchingSuffix suffix: String) -> String? {
        var candidates: [String] = []
        if let value = Bundle.main.object(forInfoDictionaryKey: "PushGoKeychainAccessGroup") as? String {
            candidates.append(value)
        }
        if let values = Bundle.main.object(forInfoDictionaryKey: "PushGoKeychainAccessGroups") as? [String] {
            candidates.append(contentsOf: values)
        }

        for candidate in candidates {
            if let resolved = resolveAccessGroupCandidate(
                candidate,
                matchingSuffix: suffix
            ) {
                return resolved
            }
        }

        guard let prefix = appIdentifierPrefix() else {
            return nil
        }
        return prefix + suffix
    }

    private static func resolveAccessGroupCandidate(
        _ candidate: String,
        matchingSuffix suffix: String
    ) -> String? {
        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasSuffix(suffix) {
            if let prefix = appIdentifierPrefix() {
                return trimmed.replacingOccurrences(of: "$(AppIdentifierPrefix)", with: prefix)
            }
            return trimmed
        }
        return nil
    }

    private static func appIdentifierPrefix() -> String? {
        let rawPrefix = Bundle.main.object(forInfoDictionaryKey: "AppIdentifierPrefix") as? String
        let trimmedPrefix = rawPrefix?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmedPrefix.isEmpty else { return nil }
        if trimmedPrefix.hasSuffix(".") {
            return trimmedPrefix
        }
        return "\(trimmedPrefix)."
    }

    private var automationServiceDirectoryURL: URL? {
        PushGoAutomationContext.keychainDirectoryURL?
            .appendingPathComponent(Self.filesystemComponent(service), isDirectory: true)
    }

    private func automationItemURL(account: String) -> URL? {
        automationServiceDirectoryURL?
            .appendingPathComponent(Self.filesystemComponent(account))
            .appendingPathExtension("json")
    }

    private static func filesystemComponent(_ value: String) -> String {
        Data(value.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "")
    }
}

enum KeychainSharedAccessMigration {
    private struct DiagnosticRecord: Codable {
        let timestampISO8601: String
        let phase: String
        let service: String?
        let account: String?
        let statusCode: Int32?
        let error: String?
    }

    private static let accessGroupSuffix = "io.ethan.pushgo.shared"
    private static let diagnosticsFilename = "keychain_shared_access_migration.jsonl"
    private static let sharedServices = [
        "io.ethan.pushgo.device.config",
        "io.ethan.pushgo.provider.device-key",
        "io.ethan.pushgo.push-token",
        "io.ethan.pushgo.channel.subscriptions",
    ]
    private static let removedServices = [
        "io.ethan.pushgo.server-tokens",
    ]
    private static let didAttemptMigration = OSAllocatedUnfairLock(initialState: false)

    // Must be called from app-owned startup paths only. NSE paths may read legacy
    // 1.2.1 items as fallback, but must not mutate Keychain layout.
    static func migrateLegacyItemsToSharedAccessGroup() {
        guard PushGoAutomationContext.keychainDirectoryURL == nil else {
            return
        }
        let shouldRun = didAttemptMigration.withLock { didAttempt in
            guard !didAttempt else { return false }
            didAttempt = true
            return true
        }
        guard shouldRun else { return }
        guard let sharedAccessGroup = KeychainStore.sharedAccessGroup(
            matchingSuffix: accessGroupSuffix
        ) else {
            recordDiagnostic(
                phase: "shared_access_group_unavailable",
                service: nil,
                account: nil,
                error: nil
            )
            return
        }

        for service in sharedServices {
            migrateService(service, sharedAccessGroup: sharedAccessGroup)
        }
        for service in removedServices {
            removeService(service, accessGroup: nil)
            removeService(service, accessGroup: sharedAccessGroup)
        }
    }

    private static func migrateService(
        _ service: String,
        sharedAccessGroup: String
    ) {
        let legacyStore = KeychainStore(
            service: service,
            accessGroup: nil,
            synchronizable: false,
            usesDataProtectionKeychain: false
        )
        let sharedStore = KeychainStore(
            service: service,
            accessGroup: sharedAccessGroup,
            synchronizable: false
        )

        let legacyItems: [(account: String, data: Data)]
        do {
            legacyItems = try legacyStore.readAll()
        } catch {
            recordDiagnostic(
                phase: "legacy_read_failed",
                service: service,
                account: nil,
                error: error
            )
            return
        }
        guard !legacyItems.isEmpty else {
            return
        }

        for item in legacyItems {
            do {
                if try sharedStore.read(account: item.account) != nil {
                    recordDiagnostic(
                        phase: "legacy_preserved_after_existing_shared_item",
                        service: service,
                        account: item.account,
                        error: nil
                    )
                    continue
                }

                do {
                    try sharedStore.add(account: item.account, data: item.data)
                } catch let error as KeychainStoreError where error.statusCode == errSecDuplicateItem {
                    recordDiagnostic(
                        phase: "shared_duplicate_preserved_legacy",
                        service: service,
                        account: item.account,
                        error: error
                    )
                }

                guard try sharedStore.read(account: item.account) != nil else {
                    recordDiagnostic(
                        phase: "shared_verify_failed",
                        service: service,
                        account: item.account,
                        error: nil
                    )
                    continue
                }

                recordDiagnostic(
                    phase: "migrated_to_shared_access_group_preserved_legacy",
                    service: service,
                    account: item.account,
                    error: nil
                )
            } catch {
                recordDiagnostic(
                    phase: "migration_failed",
                    service: service,
                    account: item.account,
                    error: error
                )
            }
        }
    }

    private static func removeService(
        _ service: String,
        accessGroup: String?
    ) {
        let store = KeychainStore(
            service: service,
            accessGroup: accessGroup,
            synchronizable: false,
            usesDataProtectionKeychain: accessGroup != nil
        )
        guard let items = try? store.readAll() else { return }
        for item in items {
            do {
                try store.delete(account: item.account)
                recordDiagnostic(
                    phase: "removed_deprecated_service_item",
                    service: service,
                    account: item.account,
                    error: nil
                )
            } catch {
                recordDiagnostic(
                    phase: "deprecated_service_item_remove_failed",
                    service: service,
                    account: item.account,
                    error: error
                )
            }
        }
    }

    private static func recordDiagnostic(
        phase: String,
        service: String?,
        account: String?,
        error: Error?
    ) {
        let statusCode = (error as? KeychainStoreError)?.statusCode
        let record = DiagnosticRecord(
            timestampISO8601: ISO8601DateFormatter().string(from: Date()),
            phase: phase,
            service: service,
            account: account,
            statusCode: statusCode,
            error: error.map { String(describing: $0) }
        )
        guard let appGroupURL = AppConstants.appGroupContainerURL(
            fileManager: .default,
            identifier: AppConstants.appGroupIdentifier
        ) else {
            return
        }
        let diagnosticsURL = appGroupURL
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("storage-diagnostics", isDirectory: true)
        let fileURL = diagnosticsURL.appendingPathComponent(diagnosticsFilename)
        do {
            try FileManager.default.createDirectory(at: diagnosticsURL, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(record)
            if FileManager.default.fileExists(atPath: fileURL.path),
               let handle = try? FileHandle(forWritingTo: fileURL)
            {
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
                try handle.write(contentsOf: Data([0x0A]))
                try handle.close()
            } else {
                var output = data
                output.append(0x0A)
                try output.write(to: fileURL, options: [.atomic])
            }
        } catch {}
    }
}

struct ManualKeyPreferences: Codable, Hashable {
    var encoding: String?
}

struct LocalKeychainConfigStore {
    private static let service = "io.ethan.pushgo.device.config"
    private static let serverConfigAccount = "server.config"
    private static let manualKeyPrefsAccount = "manual.key.preferences"
    private static let accessGroupSuffix = "io.ethan.pushgo.shared"

    private let keychain: KeychainStore
    private let legacyKeychain: KeychainStore?
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init() {
        let sharedAccessGroup = KeychainStore.accessGroup(matchingSuffix: Self.accessGroupSuffix)
        keychain = KeychainStore(
            service: Self.service,
            accessGroup: sharedAccessGroup,
            synchronizable: false
        )
        legacyKeychain = sharedAccessGroup == nil
            ? nil
            : KeychainStore(
                service: Self.service,
                accessGroup: nil,
                synchronizable: false,
                usesDataProtectionKeychain: false
            )
        encoder = JSONEncoder()
        decoder = JSONDecoder()
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    func loadServerConfig() throws -> ServerConfig? {
        guard let data = try readSharedOrLegacy(account: Self.serverConfigAccount) else {
            return nil
        }
        return try decoder.decode(ServerConfig.self, from: data)
    }

    func saveServerConfig(_ config: ServerConfig?) throws {
        guard let config else {
            try keychain.delete(account: Self.serverConfigAccount)
            try? legacyKeychain?.delete(account: Self.serverConfigAccount)
            return
        }
        let data = try encoder.encode(config)
        try keychain.write(account: Self.serverConfigAccount, data: data)
    }

    func loadManualKeyPreferences() throws -> ManualKeyPreferences {
        guard let data = try readSharedOrLegacy(account: Self.manualKeyPrefsAccount) else {
            return ManualKeyPreferences(encoding: nil)
        }
        return try decoder.decode(ManualKeyPreferences.self, from: data)
    }

    func saveManualKeyPreferences(_ preferences: ManualKeyPreferences) throws {
        let hasValue = preferences.encoding != nil
        guard hasValue else {
            try keychain.delete(account: Self.manualKeyPrefsAccount)
            try? legacyKeychain?.delete(account: Self.manualKeyPrefsAccount)
            return
        }
        let data = try encoder.encode(preferences)
        try keychain.write(account: Self.manualKeyPrefsAccount, data: data)
    }

    private func readSharedOrLegacy(account: String) throws -> Data? {
        if let data = try keychain.read(account: account) {
            return data
        }
        return try legacyKeychain?.read(account: account)
    }
}

struct ProviderDeviceKeyStore {
    struct LoadResult: Equatable {
        let platform: String
        let account: String
        let accessGroup: String?
        let deviceKey: String?
        let error: KeychainStoreError?
    }

    struct SaveResult: Equatable {
        let platform: String
        let account: String
        let accessGroup: String?
        let didPersist: Bool
        let error: KeychainStoreError?
    }

    private static let service = "io.ethan.pushgo.provider.device-key"
    private static let accountPrefix = "provider.device_key."
    private static let accessGroupSuffix = "io.ethan.pushgo.shared"

    private let keychain: KeychainStore
    private let legacyKeychain: KeychainStore?

    init() {
        let sharedAccessGroup = KeychainStore.accessGroup(matchingSuffix: Self.accessGroupSuffix)
        keychain = KeychainStore(
            service: Self.service,
            accessGroup: sharedAccessGroup,
            synchronizable: false
        )
        legacyKeychain = sharedAccessGroup == nil
            ? nil
            : KeychainStore(
                service: Self.service,
                accessGroup: nil,
                synchronizable: false,
                usesDataProtectionKeychain: false
            )
    }

    func load(platform: String) -> String? {
        loadResult(platform: platform).deviceKey
    }

    func loadResult(platform: String) -> LoadResult {
        let account = accountName(platform: platform)
        if keychain.accessGroup == nil, PushGoAutomationContext.keychainDirectoryURL == nil {
            return LoadResult(
                platform: platform,
                account: account,
                accessGroup: nil,
                deviceKey: nil,
                error: .missingAccessGroup(Self.accessGroupSuffix)
            )
        }
        do {
            guard let data = try keychain.read(account: account) else {
                if let legacyResult = loadLegacyDeviceKey(account: account, platform: platform) {
                    return legacyResult
                }
                return LoadResult(
                    platform: platform,
                    account: account,
                    accessGroup: keychain.accessGroup,
                    deviceKey: nil,
                    error: nil
                )
            }
            guard let value = String(data: data, encoding: .utf8) else {
                return LoadResult(
                    platform: platform,
                    account: account,
                    accessGroup: keychain.accessGroup,
                    deviceKey: nil,
                    error: .unexpectedData
                )
            }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return LoadResult(
                platform: platform,
                account: account,
                accessGroup: keychain.accessGroup,
                deviceKey: trimmed.isEmpty ? nil : trimmed,
                error: nil
            )
        } catch let error as KeychainStoreError {
            if let legacyResult = loadLegacyDeviceKey(account: account, platform: platform) {
                return legacyResult
            }
            return LoadResult(
                platform: platform,
                account: account,
                accessGroup: keychain.accessGroup,
                deviceKey: nil,
                error: error
            )
        } catch {
            if let legacyResult = loadLegacyDeviceKey(account: account, platform: platform) {
                return legacyResult
            }
            return LoadResult(
                platform: platform,
                account: account,
                accessGroup: keychain.accessGroup,
                deviceKey: nil,
                error: .unexpectedData
            )
        }
    }

    @discardableResult
    func save(deviceKey: String?, platform: String) -> SaveResult {
        let account = accountName(platform: platform)
        let trimmed = deviceKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else {
            do {
                try keychain.delete(account: account)
                try? legacyKeychain?.delete(account: account)
                return SaveResult(
                    platform: platform,
                    account: account,
                    accessGroup: keychain.accessGroup,
                    didPersist: false,
                    error: nil
                )
            } catch let error as KeychainStoreError {
                return SaveResult(
                    platform: platform,
                    account: account,
                    accessGroup: keychain.accessGroup,
                    didPersist: false,
                    error: error
                )
            } catch {
                return SaveResult(
                    platform: platform,
                    account: account,
                    accessGroup: keychain.accessGroup,
                    didPersist: false,
                    error: .unexpectedData
                )
            }
        }
        if keychain.accessGroup == nil, PushGoAutomationContext.keychainDirectoryURL == nil {
            return SaveResult(
                platform: platform,
                account: account,
                accessGroup: nil,
                didPersist: false,
                error: .missingAccessGroup(Self.accessGroupSuffix)
            )
        }
        guard let data = trimmed.data(using: .utf8) else {
            return SaveResult(
                platform: platform,
                account: account,
                accessGroup: keychain.accessGroup,
                didPersist: false,
                error: .unexpectedData
            )
        }
        do {
            try keychain.write(account: account, data: data)
            guard try keychain.read(account: account) == data else {
                return SaveResult(
                    platform: platform,
                    account: account,
                    accessGroup: keychain.accessGroup,
                    didPersist: false,
                    error: .unexpectedData
                )
            }
            return SaveResult(
                platform: platform,
                account: account,
                accessGroup: keychain.accessGroup,
                didPersist: true,
                error: nil
            )
        } catch let error as KeychainStoreError {
            return SaveResult(
                platform: platform,
                account: account,
                accessGroup: keychain.accessGroup,
                didPersist: false,
                error: error
            )
        } catch {
            return SaveResult(
                platform: platform,
                account: account,
                accessGroup: keychain.accessGroup,
                didPersist: false,
                error: .unexpectedData
            )
        }
    }

    static func accountName(for platform: String) -> String {
        let normalized = platform.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return Self.accountPrefix + normalized
    }

    private func accountName(platform: String) -> String {
        Self.accountName(for: platform)
    }

    private func loadLegacyDeviceKey(account: String, platform: String) -> LoadResult? {
        guard let legacyKeychain else { return nil }
        do {
            guard let data = try legacyKeychain.read(account: account) else {
                return nil
            }
            guard let value = String(data: data, encoding: .utf8) else {
                return LoadResult(
                    platform: platform,
                    account: account,
                    accessGroup: legacyKeychain.accessGroup,
                    deviceKey: nil,
                    error: .unexpectedData
                )
            }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return LoadResult(
                platform: platform,
                account: account,
                accessGroup: legacyKeychain.accessGroup,
                deviceKey: trimmed,
                error: nil
            )
        } catch let error as KeychainStoreError {
            return LoadResult(
                platform: platform,
                account: account,
                accessGroup: legacyKeychain.accessGroup,
                deviceKey: nil,
                error: error
            )
        } catch {
            return LoadResult(
                platform: platform,
                account: account,
                accessGroup: legacyKeychain.accessGroup,
                deviceKey: nil,
                error: .unexpectedData
            )
        }
    }
}

struct PushTokenStore {
    private static let service = "io.ethan.pushgo.push-token"
    private static let accountPrefix = "push.token."
    private static let accessGroupSuffix = "io.ethan.pushgo.shared"

    private let keychain: KeychainStore

    init() {
        keychain = KeychainStore(
            service: Self.service,
            accessGroup: KeychainStore.accessGroup(matchingSuffix: Self.accessGroupSuffix),
            synchronizable: false
        )
    }

    func load(platform: String) throws -> String? {
        let account = accountName(platform: platform)
        guard let data = try keychain.read(account: account),
              let value = String(data: data, encoding: .utf8)
        else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func save(token: String?, platform: String) throws {
        let account = accountName(platform: platform)
        let trimmed = token?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else {
            try keychain.delete(account: account)
            return
        }
        guard let data = trimmed.data(using: .utf8) else { return }
        try keychain.write(account: account, data: data)
    }

    private func accountName(platform: String) -> String {
        let normalized = platform.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return Self.accountPrefix + normalized
    }
}

struct KeychainChannelSubscription: Codable, Hashable {
    var channelId: String
    var displayName: String
    var password: String
    var updatedAt: Date
    var lastSyncedAt: Date?
    var isDeleted: Bool
    var deletedAt: Date?

    enum CodingKeys: String, CodingKey {
        case channelId
        case displayName
        case password
        case updatedAt
        case lastSyncedAt
        case isDeleted
        case deletedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        channelId = (try? container.decode(String.self, forKey: .channelId)) ?? ""
        displayName = (try? container.decode(String.self, forKey: .displayName)) ?? ""
        password = (try? container.decode(String.self, forKey: .password)) ?? ""
        updatedAt = (try? container.decode(Date.self, forKey: .updatedAt)) ?? Date.distantPast
        lastSyncedAt = try? container.decodeIfPresent(Date.self, forKey: .lastSyncedAt)
        isDeleted = (try? container.decode(Bool.self, forKey: .isDeleted)) ?? false
        deletedAt = try? container.decodeIfPresent(Date.self, forKey: .deletedAt)
    }

    init(
        channelId: String,
        displayName: String,
        password: String,
        updatedAt: Date,
        lastSyncedAt: Date?,
        isDeleted: Bool,
        deletedAt: Date?
    ) {
        self.channelId = channelId
        self.displayName = displayName
        self.password = password
        self.updatedAt = updatedAt
        self.lastSyncedAt = lastSyncedAt
        self.isDeleted = isDeleted
        self.deletedAt = deletedAt
    }
}

struct ChannelSubscriptionStore {
    private static let service = "io.ethan.pushgo.channel.subscriptions"
    private static let accessGroupSuffix = "io.ethan.pushgo.shared"

    private let keychain: KeychainStore
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init() {
        let accessGroup = KeychainStore.accessGroup(matchingSuffix: Self.accessGroupSuffix)
        keychain = KeychainStore(
            service: Self.service,
            accessGroup: accessGroup,
            synchronizable: false
        )
        encoder = JSONEncoder()
        decoder = JSONDecoder()
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    private func withRetry<T>(
        attempts: Int = 3,
        delay: TimeInterval = 0.02,
        operation: () throws -> T
    ) throws -> T {
        var lastError: Error?
        for attempt in 0..<attempts {
            do {
                return try operation()
            } catch {
                lastError = error
                if attempt + 1 < attempts {
                    Thread.sleep(forTimeInterval: delay)
                }
            }
        }
        throw lastError ?? KeychainStoreError.unexpectedData
    }

    func saveSubscriptions(
        gatewayKey: String,
        subscriptions: [KeychainChannelSubscription]
    ) throws {
        let trimmedGateway = normalizeGatewayKey(gatewayKey)
        guard !trimmedGateway.isEmpty else { return }
        let data = try encoder.encode(subscriptions)
        try withRetry(operation: { try keychain.write(account: trimmedGateway, data: data) })
    }

    func loadSubscriptions(
        gatewayKey: String
    ) throws -> [KeychainChannelSubscription] {
        let trimmedGateway = normalizeGatewayKey(gatewayKey)
        guard !trimmedGateway.isEmpty else { return [] }
        guard let data = try withRetry(operation: { try keychain.read(account: trimmedGateway) }) else { return [] }
        do {
            return try decoder.decode([KeychainChannelSubscription].self, from: data)
        } catch {
            try? withRetry(operation: { try keychain.delete(account: trimmedGateway) })
            return []
        }
    }

    private func normalizeGatewayKey(_ gatewayKey: String) -> String {
        gatewayKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
