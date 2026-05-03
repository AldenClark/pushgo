import Foundation
import Testing
@testable import PushGoAppleCore

struct NotificationContextSnapshotTests {
    @Test
    func snapshotStoreRoundTripAndCorruptionRecovery() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("pushgo-snapshot-tests-\(UUID().uuidString)", isDirectory: true)
        let fileURL = temporaryRoot
            .appendingPathComponent("snapshot", isDirectory: true)
            .appendingPathComponent("snapshot.bin", isDirectory: false)

        let snapshot = NotificationContextSnapshot(
            schemaVersion: NotificationContextSnapshot.schemaVersion,
            generatedAtEpochMs: 1_742_000_000_000,
            source: "tests",
            events: [
                "evt-001": .init(
                    eventId: "evt-001",
                    title: "Event title",
                    body: "Event body",
                    state: "open",
                    channel: "infra",
                    thingId: nil,
                    messageId: "msg-evt-001",
                    decryptionStateRaw: nil,
                    updatedAtEpochMs: 1_742_000_000_000
                ),
            ],
            things: [:]
        )

        #expect(NotificationContextSnapshotStore.write(snapshot, to: fileURL))
        let loaded = NotificationContextSnapshotStore.load(from: fileURL)
        #expect(loaded == snapshot)

        let garbage = Data([0x00, 0x13, 0x37, 0x7F])
        try garbage.write(to: fileURL, options: .atomic)
        #expect(NotificationContextSnapshotStore.load(from: fileURL) == nil)
        #expect(FileManager.default.fileExists(atPath: fileURL.path) == false)
    }

    @Test
    func projectorMergePreservesRicherBodyAgainstGatewayFallback() {
        let existing = NotificationContextSnapshot(
            schemaVersion: NotificationContextSnapshot.schemaVersion,
            generatedAtEpochMs: 1_742_000_000_000,
            source: "tests",
            events: [
                "evt-merge-001": .init(
                    eventId: "evt-merge-001",
                    title: "Disk Pressure",
                    body: "node-9 above threshold",
                    state: "open",
                    channel: "infra",
                    thingId: nil,
                    messageId: "msg-old",
                    decryptionStateRaw: nil,
                    updatedAtEpochMs: 1_742_000_000_000
                ),
            ],
            things: [:]
        )

        let fallbackEventUpdate = PushMessage(
            messageId: "msg-new",
            title: "Disk Pressure",
            body: NotificationPayloadSemantics.gatewayFallbackEventBody,
            channel: "infra",
            receivedAt: Date(timeIntervalSince1970: 1_742_000_999),
            rawPayload: [
                "entity_type": AnyCodable("event"),
                "event_id": AnyCodable("evt-merge-001"),
                "entity_id": AnyCodable("evt-merge-001"),
                "event_state": AnyCodable("closed"),
            ]
        )

        let merged = NotificationContextSnapshotProjector.merge(
            existing: existing,
            eventMessages: [projectionInput(from: fallbackEventUpdate)],
            thingMessages: [],
            source: "tests-merge"
        )

        let event = merged.events["evt-merge-001"]
        #expect(event?.title == "Disk Pressure")
        #expect(event?.body == "node-9 above threshold")
        #expect(event?.state == "closed")
        #expect(event?.messageId == "msg-new")
    }

    @Test
    func projectorRebuildIncludesThingImagesAndPrimaryImageFallback() {
        let thingMessage = PushMessage(
            messageId: "msg-thing-001",
            title: "Kitchen Fridge",
            body: "temperature normal",
            channel: "iot",
            receivedAt: Date(timeIntervalSince1970: 1_742_123_456),
            rawPayload: [
                "entity_type": AnyCodable("thing"),
                "thing_id": AnyCodable("thing-001"),
                "entity_id": AnyCodable("thing-001"),
                "images": AnyCodable(#"["https://example.com/a.jpg","https://example.com/b.jpg"]"#),
            ]
        )

        let rebuilt = NotificationContextSnapshotProjector.rebuild(
            eventMessages: [],
            thingMessages: [projectionInput(from: thingMessage)],
            source: "tests-rebuild"
        )

        let thing = rebuilt.things["thing-001"]
        #expect(thing?.title == "Kitchen Fridge")
        #expect(thing?.body == "temperature normal")
        #expect(thing?.images.count == 2)
        #expect(thing?.primaryImage == "https://example.com/a.jpg")
    }
}

private func projectionInput(from message: PushMessage) -> NotificationContextProjectionInput {
    NotificationContextProjectionInput(
        eventId: message.eventId,
        thingId: message.thingId,
        entityId: message.entityId,
        title: message.title,
        body: message.body,
        channel: message.channel,
        messageId: message.messageId,
        decryptionStateRaw: message.decryptionState?.rawValue,
        eventState: message.eventState,
        receivedAt: message.receivedAt,
        rawPayload: message.rawPayload,
        imageURLs: message.imageURLs
    )
}
