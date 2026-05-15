import Foundation
@testable import PushGoAppleCore

enum RuntimeQualityPlatform: String, CaseIterable {
    case iOS
    case macOS
    case watchOS
}

enum RuntimeQualityScenario: String, CaseIterable, Hashable {
    case normal
    case emptyFields
    case longMarkdown
    case unicodeMixed
    case rtlText
    case sameTimestamp
    case outOfOrderTimestamp
    case futureTimestamp
    case oldTimestamp
    case duplicateIdentity
    case missingOptionalFields
    case invalidOptionalFields
    case repeatedEntityUpdates
    case deletedEntityHistory
    case concurrentArrival
}

struct RuntimeQualityDataset {
    let messages: [PushMessage]
    let topLevelMessageCount: Int
    let unreadTopLevelMessageCount: Int
    let urlTopLevelMessageCount: Int
    let eventProjectionCount: Int
    let thingProjectionCount: Int
    let taskLikeMessageCount: Int
    let runtimeQualitySearchCount: Int
    let expectedFirstSummaryIDs: [UUID]
}

struct RuntimeQualityFixtureGenerator {
    let seed: UInt64
    let platform: RuntimeQualityPlatform
    let scenarios: Set<RuntimeQualityScenario>

    static let supportedScales = [0, 1, 10, 100, 1_000, 10_000, 100_000]

    init(
        seed: UInt64,
        platform: RuntimeQualityPlatform,
        scenarios: Set<RuntimeQualityScenario> = Set(RuntimeQualityScenario.allCases)
    ) {
        self.seed = seed
        self.platform = platform
        self.scenarios = scenarios
    }

    func makeDataset(count: Int) -> RuntimeQualityDataset {
        var messages: [PushMessage] = []
        messages.reserveCapacity(count)

        for index in 0 ..< count {
            messages.append(makeMessage(index: index))
        }

        let topLevelMessages = messages.filter { message in
            message.entityType == "message" && message.eventId == nil && message.thingId == nil
        }
        let eventProjections = messages.filter { message in
            message.entityType == "event" && message.eventId != nil && message.thingId == nil
        }
        let thingProjections = messages.filter { message in
            message.thingId != nil
        }
        let expectedFirstIDs = topLevelMessages
            .sorted {
                if $0.receivedAt != $1.receivedAt {
                    return $0.receivedAt > $1.receivedAt
                }
                return $0.id.uuidString > $1.id.uuidString
            }
            .prefix(50)
            .map(\.id)

        return RuntimeQualityDataset(
            messages: messages,
            topLevelMessageCount: topLevelMessages.count,
            unreadTopLevelMessageCount: topLevelMessages.filter { !$0.isRead }.count,
            urlTopLevelMessageCount: topLevelMessages.filter { $0.url != nil }.count,
            eventProjectionCount: eventProjections.count,
            thingProjectionCount: thingProjections.count,
            taskLikeMessageCount: topLevelMessages.filter { $0.tags.contains("task") }.count,
            runtimeQualitySearchCount: topLevelMessages.filter {
                $0.title.localizedCaseInsensitiveContains("runtimequality")
                    || $0.body.localizedCaseInsensitiveContains("runtimequality")
                    || ($0.channel?.localizedCaseInsensitiveContains("runtimequality") ?? false)
            }.count,
            expectedFirstSummaryIDs: Array(expectedFirstIDs)
        )
    }

    func makeStaleDuplicatePair() -> (newer: PushMessage, stale: PushMessage) {
        let messageID = "runtime-quality-stale-duplicate-\(seed)"
        let newerDate = Date(timeIntervalSince1970: 1_800_000_000)
        let staleDate = Date(timeIntervalSince1970: 1_700_000_000)
        let newer = makeMessage(
            index: 4,
            forcedMessageID: messageID,
            forcedTitle: "Newer stored title",
            forcedBody: "Newer stored body",
            forcedReceivedAt: newerDate
        )
        let stale = makeMessage(
            index: 5,
            forcedMessageID: messageID,
            forcedTitle: "Stale late title",
            forcedBody: "Stale late body",
            forcedReceivedAt: staleDate
        )
        return (newer, stale)
    }

    func makeWatchSnapshot(messageCount: Int, eventCount: Int, thingCount: Int) -> WatchMirrorSnapshot {
        let messages = (0 ..< messageCount).map { index in
            WatchLightMessage(
                messageId: "watch-message-\(seed)-\(index)",
                title: "Watch message \(index)",
                body: body(index: index),
                imageURL: index.isMultiple(of: 31) ? URL(string: "https://example.com/watch/\(index).webp") : nil,
                url: index.isMultiple(of: 13) ? URL(string: "https://example.com/watch/message/\(index)") : nil,
                severity: severity(index: index),
                receivedAt: receivedAt(index: index),
                isRead: index.isMultiple(of: 5),
                entityType: "message",
                entityId: "watch-message-\(index)",
                notificationRequestId: "watch-request-\(seed)-\(index)"
            )
        }
        let events = (0 ..< eventCount).map { index in
            WatchLightEvent(
                eventId: "watch-event-\(seed)-\(index)",
                title: "Watch event \(index)",
                summary: index.isMultiple(of: 7) ? nil : "Event summary \(index)",
                state: ["open", "ack", "resolved"][index % 3],
                severity: severity(index: index),
                decryptionState: nil,
                imageURL: index.isMultiple(of: 37) ? URL(string: "https://example.com/watch/event/\(index).png") : nil,
                updatedAt: receivedAt(index: index)
            )
        }
        let things = (0 ..< thingCount).map { index in
            WatchLightThing(
                thingId: "watch-thing-\(seed)-\(index)",
                title: "Watch thing \(index)",
                summary: "Thing state \(index)",
                attrsJSON: #"{"status":"ok","index":"\#(index)"}"#,
                decryptionState: nil,
                imageURL: index.isMultiple(of: 41) ? URL(string: "https://example.com/watch/thing/\(index).jpg") : nil,
                updatedAt: receivedAt(index: index)
            )
        }
        return WatchMirrorSnapshot(
            generation: Int64(seed & 0x7FFF_FFFF),
            mode: .mirror,
            messages: messages,
            events: events,
            things: things,
            exportedAt: Date(timeIntervalSince1970: 1_800_100_000),
            contentDigest: WatchMirrorSnapshot.contentDigest(messages: messages, events: events, things: things)
        )
    }

    private func makeMessage(
        index: Int,
        forcedMessageID: String? = nil,
        forcedTitle: String? = nil,
        forcedBody: String? = nil,
        forcedReceivedAt: Date? = nil
    ) -> PushMessage {
        let kind = kind(index: index)
        let id = deterministicUUID(index: index)
        let messageID = forcedMessageID ?? "\(platform.rawValue.lowercased())-\(kind)-\(seed)-\(index)"
        let channel = channel(index: index)
        let receivedAt = forcedReceivedAt ?? receivedAt(index: index)
        var payload: [String: Any] = [
            "message_id": messageID,
            "_notificationRequestId": "runtime-quality-request-\(seed)-\(index)",
            "delivery_id": "delivery-\(seed)-\(index)",
            "op_id": operationID(index: index),
            "channel_id": channel,
            "severity": severity(index: index),
            "tags": tagsJSON(index: index, kind: kind),
            "metadata": metadataJSON(index: index, kind: kind),
        ]

        switch kind {
        case "event":
            let eventID = "event-\(seed)-\(index / 10)"
            payload["entity_type"] = "event"
            payload["entity_id"] = eventID
            payload["event_id"] = eventID
            payload["event_state"] = ["open", "acknowledged", "resolved", "muted"][index % 4]
            payload["event_time"] = "\(Int64(receivedAt.timeIntervalSince1970 * 1_000))"
            if scenarios.contains(.repeatedEntityUpdates) {
                payload["observed_time"] = "\(Int64((receivedAt.timeIntervalSince1970 + Double(index % 5)) * 1_000))"
            }
        case "thing":
            let thingID = "thing-\(seed)-\(index / 10)"
            payload["entity_type"] = "thing"
            payload["entity_id"] = thingID
            payload["thing_id"] = thingID
            payload["attrs"] = #"{"temperature":"\#(20 + index % 10)","phase":"\#(index % 4)"}"#
            payload["observed_time"] = "\(Int64(receivedAt.timeIntervalSince1970 * 1_000))"
        case "thing_message":
            let thingID = "thing-\(seed)-\(max(0, (index - 3) / 10))"
            payload["entity_type"] = "message"
            payload["entity_id"] = "thing-message-\(seed)-\(index)"
            payload["thing_id"] = thingID
            payload["projection_destination"] = "thing"
            payload["occurred_at"] = "\(Int64(receivedAt.timeIntervalSince1970 * 1_000))"
        case "task":
            payload["entity_type"] = "message"
            payload["entity_id"] = "task-\(seed)-\(index / 10)"
            payload["task_id"] = "task-\(seed)-\(index / 10)"
            payload["task_state"] = ["todo", "doing", "blocked", "done"][index % 4]
        default:
            payload["entity_type"] = "message"
            payload["entity_id"] = "message-\(seed)-\(index)"
        }

        if index.isMultiple(of: 17) {
            payload["open_url"] = "https://example.com/runtime-quality/\(index)"
        }
        if index.isMultiple(of: 29) {
            payload["images"] = #"["https://example.com/images/\#(index).webp","https://example.com/images/\#(index).png"]"#
        }
        if scenarios.contains(.invalidOptionalFields), index.isMultiple(of: 97) {
            payload["expires_at"] = "not-a-date"
            payload["event_time"] = "invalid-event-time"
        }
        if scenarios.contains(.missingOptionalFields), index.isMultiple(of: 53) {
            payload.removeValue(forKey: "delivery_id")
            payload.removeValue(forKey: "op_id")
        }

        return PushMessage(
            id: id,
            messageId: messageID,
            title: forcedTitle ?? title(index: index, kind: kind),
            body: forcedBody ?? body(index: index),
            channel: channel,
            url: index.isMultiple(of: 17) ? URL(string: "https://example.com/runtime-quality/\(index)") : nil,
            isRead: index.isMultiple(of: 5),
            receivedAt: receivedAt,
            rawPayload: payload.reduce(into: [String: AnyCodable]()) { result, item in
                result[item.key] = AnyCodable(item.value)
            }
        )
    }

    private func kind(index: Int) -> String {
        switch index % 10 {
        case 0:
            return "thing"
        case 1:
            return "event"
        case 2:
            return "task"
        case 3:
            return "thing_message"
        default:
            return "message"
        }
    }

    private func title(index: Int, kind: String) -> String {
        if scenarios.contains(.emptyFields), index.isMultiple(of: 211) {
            return ""
        }
        return "Runtime Quality \(kind) \(index) \(platform.rawValue)"
    }

    private func body(index: Int) -> String {
        if scenarios.contains(.emptyFields), index.isMultiple(of: 223) {
            return ""
        }
        if scenarios.contains(.longMarkdown), index.isMultiple(of: 257) {
            return """
            # Runtime quality markdown \(index)

            | column | value |
            | --- | --- |
            | seed | \(seed) |
            | platform | \(platform.rawValue) |

            ```swift
            let metric = "runtime-quality-\(index)"
            print(metric)
            ```

            - [dashboard](https://example.com/dashboard/\(index))
            - ![preview](https://example.com/assets/\(index).gif)
            """
        }
        if scenarios.contains(.rtlText), index.isMultiple(of: 43) {
            return "runtimequality تنبيه حالة \(index) 混排消息"
        }
        if scenarios.contains(.unicodeMixed), index.isMultiple(of: 19) {
            return "runtimequality 中文 日本語 English emoji ✅ index \(index)"
        }
        return "runtimequality body \(index) channel \(channel(index: index))"
    }

    private func channel(index: Int) -> String {
        "channel-\((index + Int(seed % 11)) % 16)"
    }

    private func receivedAt(index: Int) -> Date {
        let base = TimeInterval(1_800_000_000 + Int(seed % 10_000))
        if scenarios.contains(.sameTimestamp), index.isMultiple(of: 31) {
            return Date(timeIntervalSince1970: base)
        }
        if scenarios.contains(.futureTimestamp), index.isMultiple(of: 89) {
            return Date(timeIntervalSince1970: base + 86_400 * 180 + TimeInterval(index % 10))
        }
        if scenarios.contains(.oldTimestamp), index.isMultiple(of: 83) {
            return Date(timeIntervalSince1970: base - 86_400 * 365 * 8 - TimeInterval(index % 10))
        }
        let offset = scenarios.contains(.outOfOrderTimestamp)
            ? ((index * 37) % 100_000)
            : index
        return Date(timeIntervalSince1970: base - TimeInterval(offset))
    }

    private func operationID(index: Int) -> String {
        if scenarios.contains(.duplicateIdentity), index.isMultiple(of: 101) {
            return "duplicate-op-\(index / 101)"
        }
        return "op-\(seed)-\(index)"
    }

    private func severity(index: Int) -> String {
        ["low", "medium", "high", "critical"][index % 4]
    }

    private func tagsJSON(index: Int, kind: String) -> String {
        var tags = ["runtimequality", platform.rawValue.lowercased(), kind]
        if kind == "task" {
            tags.append("task")
        }
        if index.isMultiple(of: 23) {
            tags.append("edge")
        }
        return "[\(tags.map { "\"\($0)\"" }.joined(separator: ","))]"
    }

    private func metadataJSON(index: Int, kind: String) -> String {
        #"{"kind":"\#(kind)","platform":"\#(platform.rawValue)","bucket":"\#(index % 64)"}"#
    }

    private func deterministicUUID(index: Int) -> UUID {
        let a = UInt32(truncatingIfNeeded: seed)
        let b = UInt16(truncatingIfNeeded: seed >> 32)
        let c = UInt16(truncatingIfNeeded: index >> 16)
        let d = UInt16(truncatingIfNeeded: index)
        let e = UInt64(truncatingIfNeeded: (seed &* 1_099_511_628_211) ^ UInt64(index))
        let raw = String(format: "%08X-%04X-%04X-%04X-%012llX", a, b, c, d, e & 0xFFFF_FFFF_FFFF)
        return UUID(uuidString: raw)!
    }
}
