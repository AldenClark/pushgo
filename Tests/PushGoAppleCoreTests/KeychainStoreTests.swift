import Foundation
import Testing
@testable import PushGoAppleCore

struct KeychainStoreTests {
    @Test
    func keychainStoreAddRejectsDuplicateAutomationItems() async throws {
        try await withIsolatedAutomationStorage { _, _ in
            let store = KeychainStore(
                service: "io.ethan.pushgo.tests.keychain",
                accessGroup: "W6H9P5MVUB.io.ethan.pushgo.shared",
                synchronizable: false
            )
            let account = "provider.device_key.macos"
            let first = try #require("first-device-key".data(using: .utf8))
            let second = try #require("second-device-key".data(using: .utf8))

            try store.add(account: account, data: first)
            #expect(try store.read(account: account) == first)

            do {
                try store.add(account: account, data: second)
                Issue.record("Expected add to reject an existing keychain item.")
            } catch let error as KeychainStoreError {
                #expect(error.statusCode == errSecDuplicateItem)
            }

            try store.write(account: account, data: second)
            #expect(try store.read(account: account) == second)
        }
    }

    @Test
    func providerDeviceKeyLoadResultCarriesAccountAndFailureDetails() async throws {
        await withIsolatedAutomationStorage { _, _ in
            let store = ProviderDeviceKeyStore()

            let missing = store.loadResult(platform: "macOS")
            #expect(missing.account == "provider.device_key.macos")
            #expect(missing.deviceKey == nil)
            #expect(missing.error == nil)

            let saveResult = store.save(deviceKey: "  provider-device-key-001  ", platform: "macOS")
            #expect(saveResult.account == "provider.device_key.macos")
            #expect(saveResult.didPersist)
            #expect(saveResult.error == nil)

            let loaded = store.loadResult(platform: "macOS")
            #expect(loaded.account == "provider.device_key.macos")
            #expect(loaded.deviceKey == "provider-device-key-001")
            #expect(loaded.error == nil)

            let deleteResult = store.save(deviceKey: nil, platform: "macOS")
            #expect(deleteResult.account == "provider.device_key.macos")
            #expect(!deleteResult.didPersist)
            #expect(deleteResult.error == nil)
            #expect(store.loadResult(platform: "macOS").deviceKey == nil)
        }
    }

    @Test
    func providerGatewayTokenStoreIsolatesNormalizedURLIncludingPathCase() async throws {
        try await withIsolatedAutomationStorage { _, _ in
            let store = ProviderGatewayTokenStore()
            let gatewayA = try #require(URL(string: "HTTPS://Gateway.EXAMPLE/GatewayA/"))
            let gatewayANormalized = try #require(URL(string: "https://gateway.example/GatewayA"))
            let gatewayLowerPath = try #require(URL(string: "https://gateway.example/gatewaya"))

            #expect(store.save(token: "  token-A  ", baseURL: gatewayA))
            #expect(store.save(token: "token-lower", baseURL: gatewayLowerPath))
            #expect(store.load(baseURL: gatewayANormalized) == "token-A")
            #expect(store.load(baseURL: gatewayLowerPath) == "token-lower")
            #expect(ProviderGatewayTokenStore.accountName(for: gatewayANormalized)
                != ProviderGatewayTokenStore.accountName(for: gatewayLowerPath))
        }
    }

    @Test
    func localConfigSaveBackfillsGatewayTokenByURL() async throws {
        try await withIsolatedAutomationStorage { _, _ in
            let baseURL = try #require(URL(string: "https://gateway.example/GatewayA"))
            try LocalKeychainConfigStore().saveServerConfig(
                ServerConfig(baseURL: baseURL, token: "stored-config-token")
            )
            #expect(ProviderGatewayTokenStore().load(baseURL: baseURL) == "stored-config-token")
        }
    }

    @Test("quality config is app-owned, session-scoped, persistent, and clearable")
    func qualityConfigUsesSessionDirectoryInsteadOfSharedKeychain() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("pushgo-quality-config-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }

        let firstSessionDirectory = root.appendingPathComponent("first", isDirectory: true)
        let secondSessionDirectory = root.appendingPathComponent("second", isDirectory: true)
        let firstStore = LocalKeychainConfigStore(
            fileManager: fileManager,
            qualityStorageDirectory: firstSessionDirectory
        )
        let secondStore = LocalKeychainConfigStore(
            fileManager: fileManager,
            qualityStorageDirectory: secondSessionDirectory
        )
        let config = ServerConfig(
            baseURL: try #require(URL(string: "https://quality-session.invalid/api")),
            token: "synthetic-session-token",
            notificationKeyMaterial: .init(
                algorithm: .aesGcm,
                keyData: Data("QualityKey123456".utf8),
                ivBase64: nil,
                updatedAt: Date()
            )
        )

        try firstStore.saveServerConfig(config)
        try firstStore.saveManualKeyPreferences(.init(encoding: "plaintext"))

        let relaunchedStore = LocalKeychainConfigStore(
            fileManager: fileManager,
            qualityStorageDirectory: firstSessionDirectory
        )
        #expect(try relaunchedStore.loadServerConfig()?.baseURL == config.normalized().baseURL)
        #expect(try relaunchedStore.loadServerConfig()?.notificationKeyMaterial?.keyData == Data("QualityKey123456".utf8))
        #expect(try relaunchedStore.loadManualKeyPreferences().encoding == "plaintext")
        #expect(try secondStore.loadServerConfig() == nil)
        #expect(try secondStore.loadManualKeyPreferences().encoding == nil)

        try fileManager.createDirectory(at: secondSessionDirectory, withIntermediateDirectories: true)
        try Data("not-json".utf8).write(
            to: secondSessionDirectory.appendingPathComponent("server.config.json"),
            options: .atomic
        )
        #expect(throws: DecodingError.self) {
            _ = try secondStore.loadServerConfig()
        }

        try firstStore.saveServerConfig(nil)
        try firstStore.saveManualKeyPreferences(.init(encoding: nil))
        #expect(try relaunchedStore.loadServerConfig() == nil)
        #expect(try relaunchedStore.loadManualKeyPreferences().encoding == nil)
    }
}
