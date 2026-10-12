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

    @Test("provider device-key rollback removes the legacy fallback and verifies absence")
    func providerDeviceKeyRemovalClearsLegacyFallbackAndVerifiesCanonicalAbsence() async throws {
        try await withIsolatedAutomationStorage { _, _ in
            let account = ProviderDeviceKeyStore.accountName(for: "macOS")
            let legacyStore = KeychainStore(
                service: "io.ethan.pushgo.provider.device-key",
                accessGroup: nil,
                synchronizable: false,
                usesDataProtectionKeychain: false
            )
            try legacyStore.write(account: account, data: Data("legacy-device-key".utf8))

            let store = ProviderDeviceKeyStore()
            let result = store.save(deviceKey: nil, platform: "macOS")

            #expect(result.error == nil)
            #expect(!result.didPersist)
            #expect(try legacyStore.read(account: account) == nil)
            #expect(store.loadResult(platform: "macOS").deviceKey == nil)
        }
    }

    @Test("gateway transition journal keeps protected rollback state across restart")
    func gatewayTransitionJournalPersistsProtectedSnapshotAndPhase() async throws {
        try await withIsolatedAutomationStorage { _, _ in
            let previousURL = try #require(URL(string: "https://old-gateway.example/api"))
            let nextURL = try #require(URL(string: "https://new-gateway.example/api"))
            let journal = GatewayTransitionJournal()
            var record = GatewayTransitionJournal.Record(
                platform: "iOS",
                previousConfig: ServerConfig(baseURL: previousURL, token: "old-gateway-token"),
                previousDeviceKey: " old-device-key ",
                nextConfig: ServerConfig(baseURL: nextURL, token: "new-gateway-token"),
                nextDeviceKey: " new-device-key "
            )

            try journal.save(record)
            #expect(try journal.load(platform: "ios")?.phase == .prepared)
            #expect(try journal.load(platform: "ios")?.previousConfig?.baseURL == previousURL)
            #expect(try journal.load(platform: "ios")?.previousDeviceKey == "old-device-key")

            try journal.advance(&record, to: .deviceKeyPersisted)
            let relaunchedJournal = GatewayTransitionJournal()
            #expect(try relaunchedJournal.load(platform: "ios")?.phase == .deviceKeyPersisted)
            #expect(try relaunchedJournal.load(platform: "ios")?.nextConfig.baseURL == nextURL)
            #expect(try relaunchedJournal.load(platform: "ios")?.nextDeviceKey == "new-device-key")

            try relaunchedJournal.advance(&record, to: .committed)
            #expect(try relaunchedJournal.load(platform: "ios")?.phase == .committed)
            try relaunchedJournal.clear(platform: "ios")
            #expect(try relaunchedJournal.load(platform: "ios") == nil)
        }
    }

    @Test("stale gateway cleanup cannot clear a newer transition")
    func staleGatewayCleanupCannotClearNewerTransition() async throws {
        try await withIsolatedAutomationStorage { _, _ in
            let oldURL = try #require(URL(string: "https://old-gateway.example/api"))
            let newURL = try #require(URL(string: "https://new-gateway.example/api"))
            let journal = GatewayTransitionJournal()
            let old = GatewayTransitionJournal.Record(
                platform: "ios",
                previousConfig: ServerConfig(baseURL: oldURL, token: "old-token"),
                previousDeviceKey: "old-device",
                nextConfig: ServerConfig(baseURL: newURL, token: "new-token"),
                nextDeviceKey: "new-device",
                phase: .committed
            )
            let newer = GatewayTransitionJournal.Record(
                platform: "ios",
                previousConfig: ServerConfig(baseURL: newURL, token: "new-token"),
                previousDeviceKey: "new-device",
                nextConfig: ServerConfig(baseURL: oldURL, token: "newer-token"),
                nextDeviceKey: "newer-device",
                phase: .committed
            )

            try journal.save(old)
            #expect(try journal.clear(platform: "ios", expectedTransitionID: newer.transitionID) == false)
            #expect(try journal.load(platform: "ios")?.transitionID == old.transitionID)
            try journal.save(newer)
            #expect(try journal.clear(platform: "ios", expectedTransitionID: old.transitionID) == false)
            #expect(try journal.load(platform: "ios")?.transitionID == newer.transitionID)
            #expect(try journal.clear(platform: "ios", expectedTransitionID: newer.transitionID) == true)
            #expect(try journal.load(platform: "ios") == nil)
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
