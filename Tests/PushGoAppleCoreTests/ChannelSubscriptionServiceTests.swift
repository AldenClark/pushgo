import Foundation
import Testing
@testable import PushGoAppleCore

struct ChannelSubscriptionServiceTests {
    @Test
    func deviceRouteEndpointsMatchGatewayContract() {
        #expect(ChannelSubscriptionService.deviceRegisterPath == "/device/register")
        #expect(ChannelSubscriptionService.deviceRoutePath == "/channel/device")
        #expect(ChannelSubscriptionService.deviceChannelDeletePath == "/channel/device/delete")
        #expect(ChannelSubscriptionService.providerTokenRetirePath == "/channel/device/provider-token/retire")
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
