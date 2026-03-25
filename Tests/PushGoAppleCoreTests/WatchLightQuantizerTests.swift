import Foundation
import Testing
@testable import PushGoAppleCore

struct WatchLightQuantizerTests {
    @Test
    func sharedGoldenCasesStayAligned() throws {
        let fixture = try loadFixture()

        let messagePayload = try #require(fixture["message"] as? [String: Any])
        let message = makeMessage(from: try #require(messagePayload["payload"] as? [String: String]))
        let lightMessage = try #require(
            WatchLightQuantizer.quantizeMessages([message], now: Date(timeIntervalSince1970: 4_102_444_900)).first
        )
        let messageExpected = try #require(messagePayload["expected"] as? [String: String])
        #expect(lightMessage.messageId == messageExpected["message_id"])
        #expect(lightMessage.title == messageExpected["title"])
        #expect(lightMessage.body == messageExpected["body"])
        #expect(lightMessage.severity == messageExpected["severity"])
        #expect(lightMessage.url?.absoluteString == messageExpected["url"])
        #expect(lightMessage.imageURL?.absoluteString == messageExpected["image"])

        let eventPayload = try #require(fixture["event"] as? [String: Any])
        let eventMessage = makeMessage(from: try #require(eventPayload["payload"] as? [String: String]))
        let lightEvent = try #require(WatchLightQuantizer.quantizeEvents([eventMessage]).first)
        let eventExpected = try #require(eventPayload["expected"] as? [String: String])
        #expect(lightEvent.eventId == eventExpected["event_id"])
        #expect(lightEvent.title == eventExpected["title"])
        #expect(lightEvent.summary == eventExpected["body"])
        #expect(lightEvent.state == eventExpected["state"])
        #expect(lightEvent.severity == eventExpected["severity"])
        #expect(lightEvent.imageURL?.absoluteString == eventExpected["image"])

        let thingPayload = try #require(fixture["thing"] as? [String: Any])
        let thingMessage = makeMessage(from: try #require(thingPayload["payload"] as? [String: String]))
        let lightThing = try #require(WatchLightQuantizer.quantizeThings([thingMessage]).first)
        let thingExpected = try #require(thingPayload["expected"] as? [String: String])
        #expect(lightThing.thingId == thingExpected["thing_id"])
        #expect(lightThing.title == thingExpected["title"])
        #expect(lightThing.summary == thingExpected["body"])
        #expect(normalizedJSONObjectString(lightThing.attrsJSON) == normalizedJSONObjectString(thingExpected["attrs_json"]))
        #expect(lightThing.imageURL?.absoluteString == thingExpected["image"])
    }

    @Test
    func mirrorMessageWindowKeepsLastWeekAndCapsAtFiveHundred() {
        let base = Date(timeIntervalSince1970: 4_102_444_800)
        let messages = (0..<620).map { offset in
            PushMessage(
                messageId: "msg-\(offset)",
                title: "Message \(offset)",
                body: "Body \(offset)",
                channel: nil,
                url: nil,
                isRead: false,
                receivedAt: base.addingTimeInterval(TimeInterval(-offset * 60)),
                rawPayload: [
                    "entity_type": AnyCodable("message"),
                    "entity_id": AnyCodable("msg-\(offset)"),
                    "message_id": AnyCodable("msg-\(offset)"),
                ]
            )
        } + [
            PushMessage(
                messageId: "expired",
                title: "Expired",
                body: "Expired",
                channel: nil,
                url: nil,
                isRead: false,
                receivedAt: base.addingTimeInterval(-9 * 24 * 60 * 60),
                rawPayload: [
                    "entity_type": AnyCodable("message"),
                    "entity_id": AnyCodable("expired"),
                    "message_id": AnyCodable("expired"),
                ]
            )
        ]

        let quantized = WatchLightQuantizer.quantizeMessages(messages, now: base)
        #expect(quantized.count == 500)
        #expect(quantized.first?.messageId == "msg-0")
        #expect(!quantized.contains(where: { $0.messageId == "expired" }))
    }

    @Test
    func standaloneQuantizerInfersKindWhenWatchSpecificMarkerIsMissing() {
        let eventPayload: [String: String] = [
            "entity_type": "event",
            "event_id": "evt-inferred-001",
            "entity_id": "evt-inferred-001",
            "title": "Inferred event",
            "body": "opened",
        ]
        let thingPayload: [String: String] = [
            "entity_type": "thing",
            "thing_id": "thing-inferred-001",
            "entity_id": "thing-inferred-001",
            "title": "Inferred thing",
        ]
        let messagePayload: [String: String] = [
            "entity_type": "message",
            "message_id": "msg-inferred-001",
            "entity_id": "msg-inferred-001",
            "body": "inferred message",
        ]

        let event = WatchLightQuantizer.quantizeStandalonePayload(eventPayload)
        let thing = WatchLightQuantizer.quantizeStandalonePayload(thingPayload)
        let message = WatchLightQuantizer.quantizeStandalonePayload(messagePayload)

        guard case let .event(lightEvent)? = event else {
            Issue.record("Expected event payload without watch_light_kind to infer event kind.")
            return
        }
        guard case let .thing(lightThing)? = thing else {
            Issue.record("Expected thing payload without watch_light_kind to infer thing kind.")
            return
        }
        guard case let .message(lightMessage)? = message else {
            Issue.record("Expected message payload without watch_light_kind to infer message kind.")
            return
        }

        #expect(lightEvent.eventId == "evt-inferred-001")
        #expect(lightThing.thingId == "thing-inferred-001")
        #expect(lightMessage.messageId == "msg-inferred-001")
    }

    @Test
    func standaloneQuantizerRejectsMessageWithoutMessageId() {
        let messagePayload: [String: String] = [
            "entity_type": "message",
            "delivery_id": "delivery-inferred-001",
            "body": "inferred message",
        ]

        let message = WatchLightQuantizer.quantizeStandalonePayload(messagePayload)
        #expect(message == nil)
    }

    @Test
    func standaloneQuantizerKeepsEntityPayloadsWhenLegacyNotifyFieldsExist() {
        let eventPayload: [String: String] = [
            "entity_type": "event",
            "event_id": "evt-notify-001",
            "notify": #"{"enabled":false}"#,
        ]
        let thingPayload: [String: String] = [
            "entity_type": "thing",
            "thing_id": "thing-notify-001",
            "notify_enabled": "false",
        ]

        let event = WatchLightQuantizer.quantizeStandalonePayload(eventPayload)
        let thing = WatchLightQuantizer.quantizeStandalonePayload(thingPayload)

        guard case let .event(lightEvent)? = event else {
            Issue.record("Expected event payload to quantize")
            return
        }
        guard case let .thing(lightThing)? = thing else {
            Issue.record("Expected thing payload to quantize")
            return
        }
        #expect(lightEvent.eventId == "evt-notify-001")
        #expect(lightThing.thingId == "thing-notify-001")
    }

    @Test
    func mirrorQuantizerDropsTopLevelMessageWithoutMessageId() {
        let message = PushMessage(
            messageId: nil,
            title: "No semantic id",
            body: "Should not sync to watch",
            channel: nil,
            url: nil,
            isRead: false,
            receivedAt: Date(timeIntervalSince1970: 4_102_444_800),
            rawPayload: [
                "entity_type": AnyCodable("message"),
                "entity_id": AnyCodable("msg-no-semantic-id"),
                "delivery_id": AnyCodable("msg-no-semantic-id"),
            ]
        )

        let quantized = WatchLightQuantizer.quantizeMessages([message])
        #expect(quantized.isEmpty)
    }
}

private func loadFixture() throws -> [String: Any] {
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("watch-light-fixtures/watch_light_cases.json")
        .standardizedFileURL
    let data = try Data(contentsOf: url)
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw CocoaError(.coderReadCorrupt)
    }
    return object
}

private func makeMessage(from payload: [String: String]) -> PushMessage {
    let title = payload["title"] ?? payload["event_id"] ?? payload["thing_id"] ?? "fixture"
    let body = payload["body"] ?? ""
    let url = payload["url"].flatMap(URL.init(string:))
    let rawPayload = payload.reduce(into: [String: AnyCodable]()) { result, pair in
        result[pair.key] = AnyCodable(pair.value)
    }
    return PushMessage(
        messageId: payload["message_id"] ?? payload["event_id"] ?? payload["thing_id"],
        title: title,
        body: body,
        channel: payload["channel_id"],
        url: url,
        isRead: false,
        receivedAt: Date(timeIntervalSince1970: Double(payload["sent_at"] ?? "4102444800") ?? 4_102_444_800),
        rawPayload: rawPayload
    )
}

private func normalizedJSONObjectString(_ raw: String?) -> String? {
    guard let raw,
          let data = raw.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data),
          JSONSerialization.isValidJSONObject(object),
          let normalized = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    else {
        return raw
    }
    return String(data: normalized, encoding: .utf8)
}
