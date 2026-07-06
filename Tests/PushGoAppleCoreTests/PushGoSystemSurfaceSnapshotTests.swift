import Foundation
import Testing
import UserNotifications
@testable import PushGoAppleCore

struct PushGoSystemSurfaceSnapshotTests {
    @Test
    func snapshotStoreRoundTripAndCorruptionRecovery() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("pushgo-system-snapshot-tests-\(UUID().uuidString)", isDirectory: true)
        let fileURL = temporaryRoot
            .appendingPathComponent("snapshot", isDirectory: true)
            .appendingPathComponent("snapshot.bin", isDirectory: false)
        let item = PushGoSystemSurfaceSnapshot.Item(
            id: "message:msg-001",
            kind: .message,
            title: "Status update",
            subtitle: "ops",
            bodyPreview: "Everything is healthy",
            status: "unread",
            severity: nil,
            channelID: "ops",
            eventID: nil,
            thingID: nil,
            updatedAtEpochMs: 1_742_000_000_000,
            imageURL: nil,
            accessibilityLabel: "Unread message, Status update",
            accessibilityValue: nil,
            openTarget: PushGoSystemOpenTarget.message(identifier: "msg-001", source: .widget)
        )
        let snapshot = PushGoSystemSurfaceSnapshot(
            schemaVersion: PushGoSystemSurfaceSnapshot.schemaVersion,
            generatedAtEpochMs: 1_742_000_000_000,
            source: "tests",
            counts: .init(totalMessages: 1, unreadMessages: 1, criticalEvents: 0, objectWarnings: 0),
            focusState: .default(now: Date(timeIntervalSince1970: 1_742_000_000)),
            recentMessages: [item],
            unreadMessages: [item],
            criticalEvents: [],
            objectWarnings: [],
            latestObjectStates: []
        )

        #expect(PushGoSystemSnapshotStore.write(snapshot, to: fileURL))
        #expect(PushGoSystemSnapshotStore.load(from: fileURL) == snapshot)

        try Data([0x00, 0x13, 0x37]).write(to: fileURL, options: .atomic)
        #expect(PushGoSystemSnapshotStore.load(from: fileURL) == nil)
        #expect(FileManager.default.fileExists(atPath: fileURL.path) == false)
    }

    @Test
    func projectorRedactsSensitiveAndDecryptFailedContent() {
        let sensitive = PushMessage(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000222")!,
            messageId: "msg-sensitive",
            title: "Encrypted alert",
            body: "raw secret body should not appear",
            channel: "security",
            receivedAt: Date(timeIntervalSince1970: 200),
            rawPayload: ["ciphertext": AnyCodable("abc")],
            status: .partiallyDecrypted,
            decryptionState: .decryptFailed
        )
        let normal = PushMessage(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000223")!,
            messageId: "msg-normal",
            title: "Normal alert",
            body: "safe summary",
            channel: "ops",
            receivedAt: Date(timeIntervalSince1970: 201)
        )
        let snapshot = PushGoSystemSnapshotProjector.rebuild(
            recentMessages: [
                PushGoSystemSummaryBuilder.summary(for: sensitive),
                PushGoSystemSummaryBuilder.summary(for: normal),
            ],
            eventSummaries: [],
            thingSummaries: [],
            counts: .init(totalMessages: 2, unreadMessages: 2, criticalEvents: 0, objectWarnings: 0),
            source: "tests"
        )

        #expect(snapshot.recentMessages.map(\.title) == ["Normal alert"])
        #expect(!String(describing: snapshot).contains("raw secret body"))
    }

    @Test
    func projectorIncludesSuccessfullyDecryptedMessageSummary() {
        let decrypted = PushMessage(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000225")!,
            messageId: "msg-decrypted",
            title: "Decrypted alert",
            body: "safe decrypted body",
            channel: "ops",
            receivedAt: Date(timeIntervalSince1970: 202),
            rawPayload: ["ciphertext": AnyCodable("abc")],
            status: .decrypted,
            decryptionState: .decryptOk
        )
        let snapshot = PushGoSystemSnapshotProjector.rebuild(
            recentMessages: [
                PushGoSystemSummaryBuilder.summary(for: decrypted),
            ],
            eventSummaries: [],
            thingSummaries: [],
            counts: .init(totalMessages: 1, unreadMessages: 1, criticalEvents: 0, objectWarnings: 0),
            source: "tests"
        )

        #expect(snapshot.recentMessages.map(\.title) == ["Decrypted alert"])
        #expect(snapshot.recentMessages.first?.bodyPreview?.contains("safe decrypted body") == true)
    }

    @Test
    func nseProjectionMergesUnreadMessageIntoSnapshot() {
        let content = UNMutableNotificationContent()
        content.title = "Build failed"
        content.body = "iOS release build failed on signing"
        content.userInfo = [
            "message_id": "msg-nse-projection-001",
            "delivery_id": "delivery-nse-projection-001",
            "entity_type": "message",
            "title": "Build failed",
            "body": "iOS release build failed on signing",
            "channel_id": "ci",
            "severity": "high",
        ]

        let update = PushGoNotificationProjectionUpdater.makeUpdate(
            content: content,
            requestIdentifier: "req-nse-projection-001",
            existingSnapshot: .empty(source: "tests", now: Date(timeIntervalSince1970: 100)),
            now: Date(timeIntervalSince1970: 200)
        )

        #expect(update?.snapshot.counts.totalMessages == 1)
        #expect(update?.snapshot.counts.unreadMessages == 1)
        #expect(update?.snapshot.recentMessages.first?.title == "Build failed")
        #expect(update?.snapshot.recentMessages.first?.bodyPreview?.contains("signing") == true)
        #expect(update?.snapshot.recentMessages.first?.openTarget?.identifier == "msg-nse-projection-001")
        #expect(update?.summary?.stableID == "msg-nse-projection-001")
    }

    @Test
    func widgetSnapshotSchemaDecodesNotificationProjectionSnapshot() throws {
        let localMessageID = UUID(uuidString: "00000000-0000-0000-0000-000000000321")!
        let item = PushGoSystemSurfaceSnapshot.Item(
            id: "message:msg-widget-compat",
            kind: .message,
            title: "Widget compatibility",
            subtitle: "ops",
            bodyPreview: "Unread message should be visible",
            status: "unread",
            severity: "high",
            channelID: "ops",
            eventID: nil,
            thingID: nil,
            updatedAtEpochMs: 1_742_000_000_000,
            imageURL: nil,
            accessibilityLabel: "Unread message, Widget compatibility",
            accessibilityValue: nil,
            openTarget: PushGoSystemOpenTarget.message(
                identifier: "msg-widget-compat",
                localMessageID: localMessageID,
                source: .notification
            )
        )
        let snapshot = PushGoSystemSurfaceSnapshot(
            schemaVersion: PushGoSystemSurfaceSnapshot.schemaVersion,
            generatedAtEpochMs: 1_742_000_000_000,
            source: "nse-projection",
            counts: .init(totalMessages: 1, unreadMessages: 1, criticalEvents: 0, objectWarnings: 0),
            focusState: .default(now: Date(timeIntervalSince1970: 1_742_000_000)),
            recentMessages: [item],
            unreadMessages: [item],
            criticalEvents: [],
            objectWarnings: [],
            latestObjectStates: []
        )
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let data = try encoder.encode(snapshot)

        let decoded = try PropertyListDecoder().decode(WidgetSnapshotCompatibility.self, from: data)

        #expect(decoded.schemaVersion == PushGoSystemSurfaceSnapshot.schemaVersion)
        #expect(decoded.counts.unreadMessages == 1)
        #expect(decoded.unreadMessages.first?.title == "Widget compatibility")
        #expect(decoded.unreadMessages.first?.openTarget?.identifier == "msg-widget-compat")
        #expect(decoded.unreadMessages.first?.openTarget?.localMessageID == localMessageID)
        #expect(decoded.unreadMessages.first?.openTarget?.source == .notification)
    }

    @Test
    func nseProjectionDeduplicatesExistingUnreadMessage() {
        let content = UNMutableNotificationContent()
        content.title = "Duplicate alert"
        content.body = "Second delivery attempt"
        content.userInfo = [
            "message_id": "msg-nse-projection-dedupe",
            "entity_type": "message",
            "title": "Duplicate alert",
            "body": "Second delivery attempt",
        ]
        let first = PushGoNotificationProjectionUpdater.makeUpdate(
            content: content,
            requestIdentifier: "req-dedupe-1",
            existingSnapshot: .empty(source: "tests"),
            now: Date(timeIntervalSince1970: 300)
        )
        let second = PushGoNotificationProjectionUpdater.makeUpdate(
            content: content,
            requestIdentifier: "req-dedupe-2",
            existingSnapshot: first?.snapshot,
            now: Date(timeIntervalSince1970: 301)
        )

        #expect(first?.insertedUnread == true)
        #expect(second?.insertedUnread == false)
        #expect(second?.snapshot.counts.totalMessages == 1)
        #expect(second?.snapshot.counts.unreadMessages == 1)
        #expect(second?.snapshot.unreadMessages.count == 1)
    }

    @Test
    func nseProjectionRedactsDecryptFailedContentButStillCountsUnread() {
        let content = UNMutableNotificationContent()
        content.title = "Encrypted alert"
        content.body = "raw secret should not leak"
        content.userInfo = [
            "message_id": "msg-nse-sensitive-001",
            "entity_type": "message",
            "title": "Encrypted alert",
            "body": "raw secret should not leak",
            "ciphertext": "abc",
            "decryption_state": "decryptFailed",
        ]

        let update = PushGoNotificationProjectionUpdater.makeUpdate(
            content: content,
            requestIdentifier: "req-sensitive-001",
            existingSnapshot: .empty(source: "tests"),
            now: Date(timeIntervalSince1970: 400)
        )

        #expect(update?.snapshot.counts.unreadMessages == 1)
        #expect(update?.snapshot.recentMessages.first?.title == "PushGo message")
        #expect(update?.snapshot.recentMessages.first?.bodyPreview == nil)
        #expect(update?.summary == nil)
        let snapshotDescription = String(describing: update?.snapshot)
        #expect(!snapshotDescription.contains("raw secret should not leak"))
    }

    @Test
    func projectorRedactsEntitySummariesWithUnsuccessfulDecryptionState() {
        let event = eventSummary(
            id: "evt-not-configured",
            title: "Encrypted entity event",
            summary: "entity secret should not appear",
            severity: "critical",
            decryptionState: .notConfigured,
            updatedAt: Date(timeIntervalSince1970: 220)
        )
        let thing = thingSummary(
            id: "thing-alg-mismatch",
            title: "Encrypted object",
            summary: "object secret should not appear",
            state: "warning",
            decryptionState: .algMismatch,
            updatedAt: Date(timeIntervalSince1970: 221)
        )
        let snapshot = PushGoSystemSnapshotProjector.rebuild(
            recentMessages: [],
            eventSummaries: [event],
            thingSummaries: [thing],
            counts: .init(totalMessages: 0, unreadMessages: 0, criticalEvents: 1, objectWarnings: 1),
            source: "tests"
        )

        #expect(snapshot.criticalEvents.isEmpty)
        #expect(snapshot.objectWarnings.isEmpty)
        #expect(snapshot.latestObjectStates.isEmpty)
        #expect(!String(describing: snapshot).contains("entity secret should not appear"))
        #expect(!String(describing: snapshot).contains("object secret should not appear"))
    }

    @Test
    func projectorSortsCriticalEventsBeforeHighAndNewest() {
        let lowTimeCritical = eventSummary(
            id: "evt-critical-old",
            severity: "critical",
            updatedAt: Date(timeIntervalSince1970: 100)
        )
        let newerHigh = eventSummary(
            id: "evt-high-new",
            severity: "high",
            updatedAt: Date(timeIntervalSince1970: 300)
        )
        let newerCritical = eventSummary(
            id: "evt-critical-new",
            severity: "critical",
            updatedAt: Date(timeIntervalSince1970: 400)
        )
        let snapshot = PushGoSystemSnapshotProjector.rebuild(
            recentMessages: [],
            eventSummaries: [newerHigh, lowTimeCritical, newerCritical],
            thingSummaries: [],
            counts: .init(totalMessages: 0, unreadMessages: 0, criticalEvents: 3, objectWarnings: 0),
            source: "tests"
        )

        #expect(snapshot.criticalEvents.map(\.eventID) == [
            "evt-critical-new",
            "evt-critical-old",
            "evt-high-new",
        ])
    }

    @Test
    func localDataStoreWritesSystemSurfaceSnapshot() async throws {
        try await withIsolatedLocalDataStore { store, appGroupIdentifier in
            let message = PushMessage(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000224")!,
                messageId: "msg-system-snapshot",
                title: "Snapshot message",
                body: "snapshot body",
                channel: "ops",
                receivedAt: Date(timeIntervalSince1970: 500)
            )
            try await store.saveMessage(message)
            await store.rebuildSystemSurfaceSnapshot(now: Date(timeIntervalSince1970: 600))

            let snapshot = try #require(PushGoSystemSnapshotStore.load(appGroupIdentifier: appGroupIdentifier))
            #expect(snapshot.counts.totalMessages == 1)
            #expect(snapshot.counts.unreadMessages == 1)
            #expect(snapshot.recentMessages.first?.title == "Snapshot message")
            #expect(snapshot.recentMessages.first?.openTarget?.destination == .detail)
        }
    }

    @Test
    func focusStateStoreRoundTripsModes() {
        let defaults = UserDefaults(suiteName: "pushgo.focus.test.\(UUID().uuidString)")!
        defer {
            defaults.removePersistentDomain(forName: defaults.dictionaryRepresentation().description)
        }
        let state = PushGoSystemSurfaceSnapshot.FocusState(
            mode: .priorityOnly,
            updatedAtEpochMs: 1_742_000_000_000
        )

        PushGoFocusStateStore.save(state, defaults: defaults)

        #expect(PushGoFocusStateStore.load(defaults: defaults) == state)
    }

    private func eventSummary(
        id: String,
        title: String? = nil,
        summary: String? = nil,
        severity: String,
        decryptionState: PushMessage.DecryptionState? = nil,
        updatedAt: Date
    ) -> PushGoSystemSummary {
        PushGoSystemSummaryBuilder.summary(for: EventProjection(
            id: id,
            title: title ?? id,
            summary: summary ?? "summary",
            status: "open",
            message: nil,
            severity: severity,
            tags: [],
            state: "open",
            thingId: nil,
            channelId: "ops",
            decryptionState: decryptionState,
            imageURL: nil,
            imageURLs: [],
            attrsJSON: nil,
            updatedAt: updatedAt,
            timeline: []
        ))
    }

    private func thingSummary(
        id: String,
        title: String,
        summary: String,
        state: String?,
        decryptionState: PushMessage.DecryptionState?,
        updatedAt: Date
    ) -> PushGoSystemSummary {
        PushGoSystemSummaryBuilder.summary(for: ThingProjection(
            id: id,
            title: title,
            summary: summary,
            tags: [],
            state: state,
            createdAt: nil,
            deletedAt: nil,
            channelId: "ops",
            decryptionState: decryptionState,
            locationType: nil,
            locationValue: nil,
            externalIDs: [:],
            imageURL: nil,
            imageURLs: [],
            metadata: [:],
            attrsJSON: nil,
            attrsCount: 0,
            updatedAt: updatedAt,
            relatedEvents: [],
            relatedMessages: [],
            relatedUpdates: []
        ))
    }

    private struct WidgetSnapshotCompatibility: Codable {
        struct Counts: Codable {
            let totalMessages: Int
            let unreadMessages: Int
            let criticalEvents: Int
            let objectWarnings: Int
        }

        struct FocusState: Codable {
            let mode: String
            let updatedAtEpochMs: Int64
        }

        struct Item: Codable {
            let id: String
            let kind: EntityKind
            let title: String
            let subtitle: String?
            let bodyPreview: String?
            let status: String?
            let severity: String?
            let channelID: String?
            let eventID: String?
            let thingID: String?
            let updatedAtEpochMs: Int64
            let imageURL: String?
            let accessibilityLabel: String
            let accessibilityValue: String?
            let openTarget: OpenTarget?
        }

        enum EntityKind: String, Codable {
            case message
            case event
            case thing
        }

        struct OpenTarget: Codable {
            enum Source: String, Codable {
                case notification
                case spotlight
                case appIntent
                case shortcut
                case userActivity
                case widget
                case deepLink
                case automation
            }

            enum Destination: String, Codable {
                case detail
                case list
            }

            let kind: EntityKind
            let identifier: String
            let localMessageID: UUID?
            let source: Source
            let destination: Destination
        }

        let schemaVersion: Int
        let generatedAtEpochMs: Int64
        let source: String
        let counts: Counts
        let focusState: FocusState
        let recentMessages: [Item]
        let unreadMessages: [Item]
        let criticalEvents: [Item]
        let objectWarnings: [Item]
        let latestObjectStates: [Item]
    }
}
