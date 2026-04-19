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
}
