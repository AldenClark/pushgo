import Foundation
import os
import Testing
@testable import PushGoAppleCore

struct ProviderRouteControllerTests {
    @Test
    func candidateGatewayPreparationUsesFreshRemoteIdentityWithoutLocalMutation() async throws {
        try await withIsolatedLocalDataStore { store, _ in
            let oldDeviceKey = "old-gateway-device"
            _ = await store.saveCachedDeviceKey(oldDeviceKey, for: "ios")

            let host = "candidate-route-\(UUID().uuidString.lowercased()).example"
            let baseURL = try #require(URL(string: "https://\(host)/Candidate"))
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [ChannelServiceURLProtocol.self]
            let session = URLSession(configuration: configuration)
            let observedPaths = OSAllocatedUnfairLock(initialState: [String]())
            defer {
                session.invalidateAndCancel()
                ChannelServiceURLProtocol.unregister(host: host)
            }

            ChannelServiceURLProtocol.register(host: host) { request in
                let path = request.url?.path ?? ""
                observedPaths.withLock { $0.append(path) }
                let body = try #require(ChannelServiceURLProtocol.bodyData(from: request))
                let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
                let payload: String
                switch path {
                case "/Candidate/device/register":
                    #expect(object["device_key"] == nil)
                    #expect(object["platform"] as? String == "ios")
                    payload = #"{"success":true,"data":{"device_key":"candidate-device"}}"#
                case "/Candidate/channel/device":
                    #expect(object["device_key"] as? String == "candidate-device")
                    #expect(object["channel_type"] as? String == "apns")
                    #expect(object["provider_token"] as? String == "candidate-apns-token")
                    payload = #"{"success":true,"data":{"device_key":"candidate-device","channel_type":"apns","provider_token":"candidate-apns-token"}}"#
                default:
                    throw URLError(.unsupportedURL)
                }
                let response = HTTPURLResponse(
                    url: try #require(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!
                return (response, Data(payload.utf8))
            }

            let preparedDeviceKey = try await Task { @MainActor in
                let controller = ProviderRouteController(
                    platform: "ios",
                    dataStore: store,
                    channelSubscriptionService: ChannelSubscriptionService(session: session),
                    localizationManager: LocalizationManager(),
                    refreshAutomationState: {},
                    runtimeMessageRecorder: { _, _, _, _ in }
                )
                return try await controller.prepareProviderRoute(
                    config: ServerConfig(baseURL: baseURL, token: "candidate-token"),
                    providerToken: "candidate-apns-token",
                    reuseExistingDeviceKey: false
                )
            }.value

            #expect(preparedDeviceKey == "candidate-device")
            #expect(observedPaths.withLock { $0 } == [
                "/Candidate/device/register",
                "/Candidate/channel/device",
            ])
            #expect(await store.cachedDeviceKey(for: "ios") == oldDeviceKey)
        }
    }
}
