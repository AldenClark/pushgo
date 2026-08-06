import Foundation
import os
import Testing
@testable import PushGoAppleCore

final class ChannelServiceURLProtocol: URLProtocol {
    typealias Handler = @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)

    private static let handlers = OSAllocatedUnfairLock(initialState: [String: Handler]())

    static func register(host: String, handler: @escaping Handler) {
        handlers.withLock { $0[host] = handler }
    }

    static func unregister(host: String) {
        _ = handlers.withLock { $0.removeValue(forKey: host) }
    }

    static func bodyData(from request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1_024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let host = request.url?.host else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let handler = Self.handlers.withLock { $0[host] }
        guard let handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

struct ChannelSubscriptionServiceTests {
    @Test
    func deviceRouteEndpointsMatchGatewayContract() {
        #expect(ChannelSubscriptionService.deviceRegisterPath == "/device/register")
        #expect(ChannelSubscriptionService.deviceRoutePath == "/channel/device")
        #expect(ChannelSubscriptionService.deviceChannelDeletePath == "/channel/device/delete")
        #expect(ChannelSubscriptionService.providerTokenRetirePath == "/channel/device/provider-token/retire")
        #expect(ChannelSubscriptionService.pullV2Path == "/v2/messages/pull")
        #expect(ChannelSubscriptionService.pullLegacyPath == "/messages/pull")
        #expect(ChannelSubscriptionService.ackPath == "/messages/ack")
        #expect(ChannelSubscriptionService.batchAckV2Path == "/v2/messages/ack")
    }

    @Test
    func deviceRegisterRequestEncodesExpectedGatewayKeys() throws {
        let request = ChannelSubscriptionService.DeviceRegisterRequest(
            deviceKey: "dev-001",
            platform: "ios"
        )

        let data = try JSONEncoder().encode(request)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(object["device_key"] as? String == "dev-001")
        #expect(object["platform"] as? String == "ios")
        #expect(object["channel_type"] == nil)
        #expect(object["provider_token"] == nil)
    }

    @Test
    func deviceChannelUpsertRequestEncodesExpectedGatewayKeys() throws {
        let request = ChannelSubscriptionService.DeviceChannelUpsertRequest(
            deviceKey: "dev-001",
            platform: "ios",
            channelType: "apns",
            providerToken: "token-001"
        )

        let data = try JSONEncoder().encode(request)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(object["device_key"] as? String == "dev-001")
        #expect(object["platform"] as? String == "ios")
        #expect(object["channel_type"] as? String == "apns")
        #expect(object["provider_token"] as? String == "token-001")
    }

    @Test
    func deviceChannelDeleteRequestEncodesSnakeCaseKeys() throws {
        let request = ChannelSubscriptionService.DeviceChannelDeleteRequest(
            deviceKey: "dev-001",
            channelType: "private"
        )

        let data = try JSONEncoder().encode(request)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(object["device_key"] as? String == "dev-001")
        #expect(object["channel_type"] as? String == "private")
    }

    @Test
    func providerTokenRetireRequestEncodesSnakeCaseKeys() throws {
        let request = ChannelSubscriptionService.ProviderTokenRetireRequest(
            platform: "ios",
            providerToken: "token-001"
        )

        let data = try JSONEncoder().encode(request)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(object["platform"] as? String == "ios")
        #expect(object["provider_token"] as? String == "token-001")
    }

    @Test
    func syncRequestEncodesDeviceKeyAndChannels() throws {
        let request = ChannelSubscriptionService.SyncRequest(
            deviceKey: "dev-001",
            channels: [
                .init(channelId: "channel-001", password: "pw-001"),
                .init(channelId: "channel-002", password: "pw-002"),
            ]
        )

        let data = try JSONEncoder().encode(request)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let channels = try #require(object["channels"] as? [[String: Any]])

        #expect(object["device_key"] as? String == "dev-001")
        #expect(object["channel_type"] == nil)
        #expect(channels.count == 2)
        #expect(channels[0]["channel_id"] as? String == "channel-001")
        #expect(channels[0]["password"] as? String == "pw-001")
        #expect(channels[1]["channel_id"] as? String == "channel-002")
        #expect(channels[1]["password"] as? String == "pw-002")
    }

    @Test
    func pullRequestEncodesDeviceKeyAndOptionalDeliveryId() throws {
        let full = ChannelSubscriptionService.PullRequest(
            deviceKey: "dev-001",
            deliveryId: "delivery-001"
        )
        let fullData = try JSONEncoder().encode(full)
        let fullObject = try #require(JSONSerialization.jsonObject(with: fullData) as? [String: Any])
        #expect(fullObject["device_key"] as? String == "dev-001")
        #expect(fullObject["delivery_id"] as? String == "delivery-001")

        let all = ChannelSubscriptionService.PullRequest(
            deviceKey: "dev-001",
            deliveryId: nil
        )
        let allData = try JSONEncoder().encode(all)
        let allObject = try #require(JSONSerialization.jsonObject(with: allData) as? [String: Any])
        #expect(allObject["device_key"] as? String == "dev-001")
        #expect(allObject["delivery_id"] == nil)
    }

    @Test
    func ackRequestEncodesExpectedGatewayKeys() throws {
        let request = ChannelSubscriptionService.AckRequest(
            deviceKey: "dev-001",
            deliveryId: "delivery-001"
        )
        let data = try JSONEncoder().encode(request)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["device_key"] as? String == "dev-001")
        #expect(object["delivery_id"] as? String == "delivery-001")
    }

    @Test
    func batchAckRequestEncodesMutuallyExclusiveDeliveryIdsField() throws {
        let request = ChannelSubscriptionService.BatchAckRequest(
            deviceKey: "dev-001",
            deliveryIds: ["delivery-001", "delivery-002"]
        )
        let data = try JSONEncoder().encode(request)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["device_key"] as? String == "dev-001")
        #expect(object["delivery_ids"] as? [String] == ["delivery-001", "delivery-002"])
        #expect(object["delivery_id"] == nil)
    }

    @Test
    func pullResponseDecodesDeliveryItems() throws {
        let raw = """
        {
          "items": [
            {
              "delivery_id": "delivery-001",
              "payload": { "title": "hello" }
            },
            {
              "delivery_id": "delivery-002",
              "payload": { "title": "world" }
            }
          ]
        }
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(ChannelSubscriptionService.PullResponse.self, from: raw)
        #expect(decoded.items.count == 2)
        #expect(decoded.items[0].deliveryId == "delivery-001")
        #expect(decoded.items[0].payload["title"] == "hello")
        #expect(decoded.items[1].deliveryId == "delivery-002")
        #expect(decoded.items[1].payload["title"] == "world")
    }

    @Test
    func ackResponseDecodesRemovedFlag() throws {
        let raw = """
        {
          "removed": true
        }
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(ChannelSubscriptionService.AckResponse.self, from: raw)
        #expect(decoded.removed)
    }

    @Test
    func v2PullAndBatchAckUseIndependentRoutesAndValidateCounts() async throws {
        let host = "apple-v2-\(UUID().uuidString.lowercased()).example"
        let baseURL = try #require(URL(string: "https://\(host)/GatewayA"))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ChannelServiceURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer {
            session.invalidateAndCancel()
            ChannelServiceURLProtocol.unregister(host: host)
        }

        ChannelServiceURLProtocol.register(host: host) { request in
            let path = request.url?.path
            let payload: String
            if path == "/GatewayA/v2/messages/pull" {
                payload = """
                {"success":true,"data":{"items":[{"delivery_id":"outer-001","payload":{"delivery_id":"inner-wrong","title":"hello"}}],"has_more":true}}
                """
            } else if path == "/GatewayA/v2/messages/ack" {
                let body = try #require(ChannelServiceURLProtocol.bodyData(from: request))
                let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
                #expect(object["delivery_id"] == nil)
                #expect(object["delivery_ids"] as? [String] == ["outer-001", "outer-002"])
                payload = """
                {"success":true,"data":{"removed":true,"requested_count":2,"removed_count":1}}
                """
            } else {
                throw URLError(.unsupportedURL)
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data(payload.utf8))
        }

        let service = ChannelSubscriptionService(session: session)
        let result = try await service.pullMessages(
            baseURL: baseURL,
            token: "token",
            deviceKey: "device"
        )
        #expect(result.contract == .v2)
        #expect(result.requiresAck)
        #expect(result.hasMore)
        #expect(result.items.first?.deliveryId == "outer-001")

        let ack = try await service.ackMessages(
            baseURL: baseURL,
            token: "token",
            deviceKey: "device",
            deliveryIds: ["outer-002", "outer-001", "outer-001"]
        )
        #expect(ack.requestedCount == 2)
        #expect(ack.removedCount == 1)
    }

    @Test
    func exactRouteNotFoundFallsBackToDestructiveLegacyPullWithoutAckRequirement() async throws {
        let host = "apple-legacy-\(UUID().uuidString.lowercased()).example"
        let baseURL = try #require(URL(string: "https://\(host)/GatewayA"))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ChannelServiceURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer {
            session.invalidateAndCancel()
            ChannelServiceURLProtocol.unregister(host: host)
        }

        ChannelServiceURLProtocol.register(host: host) { request in
            let path = request.url?.path
            let status: Int
            let payload: String
            if path == "/GatewayA/v2/messages/pull" {
                status = 404
                payload = """
                {"success":false,"error_code":"route_not_found","problem":{"code":"route_not_found","category":"not_found","status":404,"title":"Not found","retryable":false}}
                """
            } else if path == "/GatewayA/messages/pull" {
                status = 200
                payload = """
                {"success":true,"data":{"items":[{"delivery_id":"legacy-001","payload":{"title":"legacy"}}]}}
                """
            } else {
                throw URLError(.unsupportedURL)
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            return (response, Data(payload.utf8))
        }

        let result = try await ChannelSubscriptionService(session: session).pullMessages(
            baseURL: baseURL,
            token: nil,
            deviceKey: "device"
        )
        #expect(result.contract == .legacy)
        #expect(!result.requiresAck)
        #expect(!result.hasMore)
        #expect(result.items.map(\.deliveryId) == ["legacy-001"])
    }

    @Test
    func decodeGatewayResponsePreservesStructuredProblem() throws {
        let data = """
        {
          "success": false,
          "error": "device_key not found",
          "error_code": "device_key_not_found",
          "problem": {
            "code": "device_key_not_found",
            "category": "not_found",
            "status": 400,
            "title": "Resource not found",
            "detail": "device_key not found",
            "localized_message": "当前设备注册已失效，请重试。",
            "locale": "zh-CN",
            "retryable": false
          }
        }
        """.data(using: .utf8)!
        let response = HTTPURLResponse(
            url: URL(string: "https://pushgo.app/channel/device")!,
            statusCode: 400,
            httpVersion: nil,
            headerFields: nil
        )!

        #expect(throws: AppError.gateway(.init(
            code: "device_key_not_found",
            category: .notFound,
            status: 400,
            title: "Resource not found",
            detail: "device_key not found",
            localizedMessage: "当前设备注册已失效，请重试。",
            locale: "zh-CN",
            retryable: false,
            requestId: nil
        ))) {
            _ = try ChannelSubscriptionService.decodeGatewayResponse(
                ChannelSubscriptionService.EmptyPayload.self,
                data: data,
                response: response
            )
        }
    }

    @Test
    func gatewayErrorExposesGatewayCodeMatcher() {
        let error = AppError.gateway(
            GatewayProblemPayload(
                code: "device_key_not_found",
                category: .notFound,
                status: 400,
                title: nil,
                detail: "device_key not found",
                localizedMessage: nil,
                locale: nil,
                retryable: false,
                requestId: nil
            )
        )

        #expect(error.gatewayCode == "device_key_not_found")
        #expect(error.matchesGatewayCode("device_key_not_found"))
    }

    @Test
    func gatewayErrorUsesSpecificChannelNotFoundMessageWithoutLocalizedPayload() {
        let error = AppError.gateway(
            GatewayProblemPayload(
                code: "channel_not_found",
                category: .notFound,
                status: 404,
                title: nil,
                detail: "channel not found on gateway",
                localizedMessage: nil,
                locale: nil,
                retryable: false,
                requestId: nil
            )
        )

        #expect(error.errorDescription == LocalizationProvider.localized("channel_not_found"))
    }

    @Test
    func legacyGatewayDetailInfersChannelNotFoundCode() {
        let error = ChannelSubscriptionService.buildGatewayError(
            statusCode: 404,
            legacyError: "channel not found on gateway",
            errorCode: nil,
            problem: nil
        )

        #expect(error.gatewayCode == "channel_not_found")
        #expect(error.errorDescription == LocalizationProvider.localized("channel_not_found"))
    }

    @Test
    func gatewayErrorPrefersLocalCodeMappingOverForeignLocalizedMessage() {
        let error = AppError.gateway(
            GatewayProblemPayload(
                code: "password_mismatch",
                category: .conflict,
                status: 403,
                title: nil,
                detail: "invalid channel password",
                localizedMessage: "The channel password is incorrect. Please verify it and try again.",
                locale: "en",
                retryable: false,
                requestId: "req-001"
            )
        )

        #expect(error.errorDescription == LocalizationProvider.localized("channel_password_incorrect"))
    }

    @Test
    func gatewayAcceptLanguageNormalizesSimplifiedChineseForGateway() {
        let header = ChannelSubscriptionService.buildGatewayAcceptLanguageValue(
            preferredLanguages: ["zh-Hans-CN", "en-US"],
            currentIdentifier: "en_US"
        )

        #expect(header == "zh-CN, zh-Hans-CN, en-US, en")
    }
}
