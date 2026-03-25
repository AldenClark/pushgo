import Foundation
import Security

enum KeychainStoreError: LocalizedError, Equatable {
    case unexpectedData
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

    init(service: String, accessGroup: String? = nil, synchronizable: Bool? = nil) {
        self.service = service
        self.accessGroup = accessGroup
        self.synchronizable = synchronizable
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
        if let synchronizable {
            if synchronizable {
                query[kSecAttrSynchronizable] = kSecAttrSynchronizableAny
            } else {
                query[kSecAttrSynchronizable] = kCFBooleanFalse
            }
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

        var query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        if let accessGroup {
            query[kSecAttrAccessGroup] = accessGroup
        }
        if let synchronizable {
            query[kSecAttrSynchronizable] = synchronizable ? kCFBooleanTrue : kCFBooleanFalse
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
        if let synchronizable {
            query[kSecAttrSynchronizable] = synchronizable ? kCFBooleanTrue : kCFBooleanFalse
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
            kSecReturnData: true,
        ]
        if let accessGroup {
            query[kSecAttrAccessGroup] = accessGroup
        }
        if let synchronizable {
            query[kSecAttrSynchronizable] = synchronizable ? kCFBooleanTrue : kCFBooleanFalse
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

        return rawItems.compactMap { entry in
            guard let account = entry[kSecAttrAccount] as? String,
                  let data = entry[kSecValueData] as? Data
            else { return nil }
            return (account: account, data: data)
        }
    }

    static func accessGroup(matchingSuffix suffix: String) -> String? {
        if let value = Bundle.main.object(forInfoDictionaryKey: "PushGoKeychainAccessGroup") as? String,
           value.hasSuffix(suffix) {
            return value
        }
        if let values = Bundle.main.object(forInfoDictionaryKey: "PushGoKeychainAccessGroups") as? [String] {
            return values.first { $0.hasSuffix(suffix) }
        }
        return nil
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

struct ManualKeyPreferences: Codable, Hashable {
    var encoding: String?
}

struct LocalKeychainConfigStore {
    private static let service = "io.ethan.pushgo.device.config"
    private static let serverConfigAccount = "server.config"
    private static let manualKeyPrefsAccount = "manual.key.preferences"
    private static let accessGroupSuffix = "io.ethan.pushgo.shared"

    private let keychain: KeychainStore
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init() {
        keychain = KeychainStore(
            service: Self.service,
            accessGroup: KeychainStore.accessGroup(matchingSuffix: Self.accessGroupSuffix),
            synchronizable: false
        )
        encoder = JSONEncoder()
        decoder = JSONDecoder()
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    func loadServerConfig() throws -> ServerConfig? {
        guard let data = try keychain.read(account: Self.serverConfigAccount) else {
            return nil
        }
        return try decoder.decode(ServerConfig.self, from: data)
    }

    func saveServerConfig(_ config: ServerConfig?) throws {
        guard let config else {
            try keychain.delete(account: Self.serverConfigAccount)
            return
        }
        let data = try encoder.encode(config)
        try keychain.write(account: Self.serverConfigAccount, data: data)
    }

    func loadManualKeyPreferences() throws -> ManualKeyPreferences {
        guard let data = try keychain.read(account: Self.manualKeyPrefsAccount) else {
            return ManualKeyPreferences(encoding: nil)
        }
        return try decoder.decode(ManualKeyPreferences.self, from: data)
    }

    func saveManualKeyPreferences(_ preferences: ManualKeyPreferences) throws {
        let hasValue = preferences.encoding != nil
        guard hasValue else {
            try keychain.delete(account: Self.manualKeyPrefsAccount)
            return
        }
        let data = try encoder.encode(preferences)
        try keychain.write(account: Self.manualKeyPrefsAccount, data: data)
    }
}

struct ProviderDeviceKeyStore {
    private static let service = "io.ethan.pushgo.provider.device-key"
    private static let accountPrefix = "provider.device_key."
    private static let accessGroupSuffix = "io.ethan.pushgo.shared"

    private let keychain: KeychainStore

    init() {
        keychain = KeychainStore(
            service: Self.service,
            accessGroup: KeychainStore.accessGroup(matchingSuffix: Self.accessGroupSuffix),
            synchronizable: false
        )
    }

    func load(platform: String) -> String? {
        let account = accountName(platform: platform)
        guard let data = try? keychain.read(account: account),
              let value = String(data: data, encoding: .utf8)
        else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func save(deviceKey: String?, platform: String) {
        let account = accountName(platform: platform)
        let trimmed = deviceKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else {
            try? keychain.delete(account: account)
            return
        }
        guard let data = trimmed.data(using: .utf8) else { return }
        try? keychain.write(account: account, data: data)
    }

    private func accountName(platform: String) -> String {
        let normalized = platform.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return Self.accountPrefix + normalized
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

struct ServerTokenStore {
    private static let service = "io.ethan.pushgo.server-tokens"
    private static let tokenAccount = "server.token"
    private static let keyMaterialAccount = "server.notificationKeyMaterial"

    private let keychain: KeychainStore
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init() {
        keychain = KeychainStore(service: Self.service)
        encoder = JSONEncoder()
        decoder = JSONDecoder()
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    func loadToken() throws -> String? {
        guard let data = try keychain.read(account: Self.tokenAccount) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func saveToken(_ token: String?) throws {
        let trimmed = token?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else {
            try keychain.delete(account: Self.tokenAccount)
            return
        }
        let data = Data(trimmed.utf8)
        try keychain.write(account: Self.tokenAccount, data: data)
    }

    func loadNotificationKeyMaterial() throws -> ServerConfig.NotificationKeyMaterial? {
        guard let data = try keychain.read(account: Self.keyMaterialAccount) else { return nil }
        return try decoder.decode(ServerConfig.NotificationKeyMaterial.self, from: data)
    }

    func saveNotificationKeyMaterial(_ material: ServerConfig.NotificationKeyMaterial?) throws {
        guard let material, material.isConfigured else {
            try keychain.delete(account: Self.keyMaterialAccount)
            return
        }
        let data = try encoder.encode(material)
        try keychain.write(account: Self.keyMaterialAccount, data: data)
    }
}
