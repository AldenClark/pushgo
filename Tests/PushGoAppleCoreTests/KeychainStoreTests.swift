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
}
