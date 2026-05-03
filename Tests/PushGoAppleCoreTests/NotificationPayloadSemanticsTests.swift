import Foundation
import Testing
@testable import PushGoAppleCore

struct NotificationPayloadSemanticsTests {
    private func normalize(
        _ payload: [AnyHashable: Any],
        snapshot: NotificationContextSnapshot? = nil
    ) -> NotificationPayloadSemantics.NormalizedPayload? {
        NotificationPayloadSemantics.normalizeRemoteNotification(
            payload,
            contextSnapshot: snapshot,
            localizeTypeLabel: { $0 == "event" ? "Event" : "Thing" },
            localizeThingAttributeUpdateBody: { details in "Attribute update || \(details)" },
            localizeThingAttributePair: { name, value in "\(name): \(value)" }
        )
    }

    @Test
    func eventProfileFillsMissingTitleAndBody() {
        let payload: [AnyHashable: Any] = [
            "entity_type": "event",
            "event_id": "evt-001",
            "entity_id": "evt-001",
            "title": "Disk pressure",
            "description": "node-9 is above threshold",
            "body": "   ",
        ]

        let normalized = normalize(payload)

        #expect(normalized?.entityType == "event")
        #expect(normalized?.entityId == "evt-001")
        #expect(normalized?.title == "Disk pressure")
        #expect(normalized?.body == "node-9 is above threshold")
    }

    @Test
    func eventFallbackUsesLocalizedLabelAndStateWhenProfileIsMissing() {
        let payload: [AnyHashable: Any] = [
            "entity_type": "event",
            "event_id": "evt-404",
            "entity_id": "evt-404",
            "event_state": "open",
        ]

        let normalized = normalize(payload)

        #expect(normalized?.entityType == "event")
        #expect(normalized?.title == "Event evt-404")
        #expect(normalized?.body == "open")
    }

    @Test
    func eventFallbackUsesSnapshotWhenPayloadOmitsReadableFields() {
        let payload: [AnyHashable: Any] = [
            "entity_type": "event",
            "event_id": "evt-snapshot-001",
            "entity_id": "evt-snapshot-001",
        ]
        let snapshot = NotificationContextSnapshot(
            schemaVersion: NotificationContextSnapshot.schemaVersion,
            generatedAtEpochMs: 1_742_000_000_000,
            source: "tests",
            events: [
                "evt-snapshot-001": NotificationContextSnapshot.EventContext(
                    eventId: "evt-snapshot-001",
                    title: "Snapshot Event Title",
                    body: "Snapshot Event Body",
                    state: "open",
                    channel: "infra",
                    thingId: nil,
                    messageId: "msg-snapshot-event",
                    decryptionStateRaw: nil,
                    updatedAtEpochMs: 1_742_000_000_000
                ),
            ],
            things: [:]
        )

        let normalized = normalize(payload, snapshot: snapshot)

        #expect(normalized?.title == "Snapshot Event Title")
        #expect(normalized?.body == "Snapshot Event Body")
    }

    @Test
    func eventFallbackUsesProfileMessageWhenBodyIsMissing() {
        let payload: [AnyHashable: Any] = [
            "entity_type": "event",
            "event_id": "evt-message-001",
            "entity_id": "evt-message-001",
            "title": "CPU high",
            "message": "node-9 is above threshold",
            "event_state": "open",
        ]

        let normalized = normalize(payload)

        #expect(normalized?.title == "CPU high")
        #expect(normalized?.body == "node-9 is above threshold")
    }

    @Test
    func suppressesExpiredPayloadsFromUserAlerts() {
        let payload: [AnyHashable: Any] = [
            "title": "expired",
            "ttl": "1",
        ]

        #expect(
            NotificationPayloadSemantics.shouldPresentUserAlert(
                from: payload,
                now: Date(timeIntervalSince1970: 10)
            ) == false
        )
    }

    @Test
    func eventAlertRequiresHighOrCriticalSeverity() {
        let lowPayload: [AnyHashable: Any] = [
            "entity_type": "event",
            "event_id": "evt-001",
            "entity_id": "evt-001",
            "severity": "low",
            "title": "low",
            "body": "body",
        ]
        let highPayload: [AnyHashable: Any] = [
            "entity_type": "event",
            "event_id": "evt-002",
            "entity_id": "evt-002",
            "severity": "high",
            "title": "high",
            "body": "body",
        ]

        #expect(NotificationPayloadSemantics.shouldPresentUserAlert(from: lowPayload) == true)
        #expect(NotificationPayloadSemantics.shouldPresentUserAlert(from: highPayload) == true)
    }

    @Test
    func messageAlertIgnoresLegacyLevelField() {
        let payload: [AnyHashable: Any] = [
            "entity_type": "event",
            "event_id": "evt-legacy-level",
            "entity_id": "evt-legacy-level",
            "level": "critical",
            "title": "legacy",
            "body": "body",
        ]

        #expect(NotificationPayloadSemantics.shouldPresentUserAlert(from: payload) == true)
    }

    @Test
    func notifyEnabledOverridesSeverityWhenPresent() {
        let silentPayload: [AnyHashable: Any] = [
            "entity_type": "event",
            "event_id": "evt-notify-silent-001",
            "entity_id": "evt-notify-silent-001",
            "severity": "critical",
            "notify": ["enabled": false],
        ]
        let enabledPayload: [AnyHashable: Any] = [
            "entity_type": "event",
            "event_id": "evt-notify-enabled-001",
            "entity_id": "evt-notify-enabled-001",
            "severity": "low",
            "notify": #"{"enabled":true}"#,
        ]

        #expect(NotificationPayloadSemantics.shouldPresentUserAlert(from: silentPayload) == true)
        #expect(NotificationPayloadSemantics.shouldPresentUserAlert(from: enabledPayload) == true)
    }

    @Test
    func normalizationTrimsTitleAndBodyWhitespace() {
        let payload: [AnyHashable: Any] = [
            "entity_type": "message",
            "message_id": "msg-copy-001",
            "entity_id": "msg-copy-001",
            "title": "  Copy title  ",
            "body": "  Payload body  ",
        ]

        let normalized = normalize(payload)
        #expect(normalized?.title == "Copy title")
        #expect(normalized?.body == "Payload body")
    }

    @Test
    func entityOpenTargetExtractsThingIdentifiers() {
        let payload: [AnyHashable: Any] = [
            "thing_id": "thing-001",
            "entity_id": "thing-001",
            "entity_type": "thing",
        ]

        let components = NotificationPayloadSemantics.entityOpenTargetComponents(from: payload)

        #expect(components == .init(entityType: "thing", entityId: "thing-001"))
    }

    @Test
    func entityOpenTargetRejectsMismatchedThingIdentifiers() {
        let payload: [AnyHashable: Any] = [
            "entity_type": "thing",
            "thing_id": "thing-001",
            "entity_id": "thing-002",
        ]

        #expect(NotificationPayloadSemantics.entityOpenTargetComponents(from: payload) == nil)
    }

    @Test
    func thingAttributeUpdateUsesLocalizedTemplateAndThingNameTitle() {
        let payload: [AnyHashable: Any] = [
            "entity_type": "thing",
            "thing_id": "thing-attr-001",
            "entity_id": "thing-attr-001",
            "attrs": #"{"Name":"New Fridge","Model":"X3880"}"#,
        ]

        let normalized = normalize(payload)

        #expect(normalized?.title == "New Fridge")
        #expect(normalized?.body == "Attribute update || Name: New Fridge, Model: X3880")
    }

    @Test
    func thingFallbackUsesSnapshotWhenPayloadIsSparse() {
        let payload: [AnyHashable: Any] = [
            "entity_type": "thing",
            "thing_id": "thing-snapshot-001",
            "entity_id": "thing-snapshot-001",
        ]
        let snapshot = NotificationContextSnapshot(
            schemaVersion: NotificationContextSnapshot.schemaVersion,
            generatedAtEpochMs: 1_742_000_000_000,
            source: "tests",
            events: [:],
            things: [
                "thing-snapshot-001": NotificationContextSnapshot.ThingContext(
                    thingId: "thing-snapshot-001",
                    title: "Snapshot Thing Title",
                    body: "Snapshot Thing Body",
                    state: "online",
                    channel: "iot",
                    eventId: "evt-parent-001",
                    messageId: "msg-snapshot-thing",
                    primaryImage: "https://example.com/thing.jpg",
                    images: ["https://example.com/thing.jpg"],
                    decryptionStateRaw: nil,
                    updatedAtEpochMs: 1_742_000_000_000
                ),
            ]
        )

        let normalized = normalize(payload, snapshot: snapshot)

        #expect(normalized?.title == "Snapshot Thing Title")
        #expect(normalized?.body == "Snapshot Thing Body")
    }

    @Test
    func thingNormalizationBackfillsEntityIdentifiersFromThingId() {
        let payload: [AnyHashable: Any] = [
            "entity_type": "thing",
            "thing_id": "thing-backfill-001",
            "title": "Router",
            "description": "Backfill by thing_id",
        ]

        let normalized = normalize(payload)

        #expect(normalized?.entityType == "thing")
        #expect(normalized?.thingId == "thing-backfill-001")
        #expect(normalized?.entityId == "thing-backfill-001")
        #expect(normalized?.rawPayload["entity_id"] as? String == "thing-backfill-001")
    }

    @Test
    func normalizeRemoteNotificationRejectsTopLevelMessageWithoutMessageId() {
        let payload: [AnyHashable: Any] = [
            "entity_type": "message",
            "entity_id": "msg-no-semantic-id",
            "title": "CPU alert",
            "body": "Node overloaded",
        ]

        #expect(normalize(payload) == nil)
    }

    @Test
    func normalizeRemoteNotificationKeepsCiphertextOnlyMessageWhenMessageIdExists() {
        let payload: [AnyHashable: Any] = [
            "entity_type": "message",
            "entity_id": "msg-ciphertext-001",
            "message_id": "msg-ciphertext-001",
            "ciphertext": "opaque-ciphertext",
        ]

        let normalized = normalize(payload)

        #expect(normalized?.messageId == "msg-ciphertext-001")
        #expect(normalized?.entityId == "msg-ciphertext-001")
        #expect(normalized?.rawPayload["ciphertext"] as? String == "opaque-ciphertext")
    }

    @Test
    func messagePayloadDoesNotProduceEntityOpenTarget() {
        let payload: [AnyHashable: Any] = [
            "message_id": "msg-001",
            "title": "hello",
            "body": "world",
        ]

        #expect(NotificationPayloadSemantics.entityOpenTargetComponents(from: payload) == nil)
    }

    @Test
    func extractMessageIdRequiresExplicitMessageId() {
        let payload: [AnyHashable: Any] = [
            "delivery_id": "msg-001",
            "title": "hello",
        ]

        #expect(NotificationPayloadSemantics.extractMessageId(from: payload) == nil)
    }
}

struct ImageRenderingPolicyTests {
    @Test
    func iosAndMacOSSourcesDoNotUseAsyncImageDirectly() throws {
        let fileURLs = try sourceFiles(
            roots: [
                sourceRoot.appendingPathComponent("Apps/PushGo-iOS", isDirectory: true),
                sourceRoot.appendingPathComponent("Apps/PushGo-macOS", isDirectory: true),
                sourceRoot.appendingPathComponent("Shared", isDirectory: true),
            ]
        )

        var violations: [String] = []
        for fileURL in fileURLs {
            let content = try String(contentsOf: fileURL, encoding: .utf8)
            if content.contains("AsyncImage(") {
                violations.append(fileURL.path)
            }
        }

        #expect(
            violations.isEmpty,
            "AsyncImage is only allowed on watchOS. Violations:\n\(violations.joined(separator: "\n"))"
        )
    }

    @Test
    func directSDWebImageViewsAreRestrictedToSharedRenderEntrypoints() throws {
        let fileURLs = try sourceFiles(
            roots: [
                sourceRoot.appendingPathComponent("Apps/PushGo-iOS", isDirectory: true),
                sourceRoot.appendingPathComponent("Apps/PushGo-macOS", isDirectory: true),
                sourceRoot.appendingPathComponent("Shared", isDirectory: true),
            ]
        )

        let allowedFiles: Set<String> = [
            sourceRoot.appendingPathComponent("Shared/UI/RemoteImageView.swift").path,
            sourceRoot.appendingPathComponent("Shared/UI/KeyboardDismiss.swift").path,
        ]

        var violations: [String] = []
        for fileURL in fileURLs {
            let content = try String(contentsOf: fileURL, encoding: .utf8)
            let usesDirectSDWebImage = content.contains("WebImage(") || content.contains("AnimatedImage(")
            if usesDirectSDWebImage && !allowedFiles.contains(fileURL.path) {
                violations.append(fileURL.path)
            }
        }

        #expect(
            violations.isEmpty,
            "Direct SDWebImage usage is restricted to shared rendering entrypoints. Violations:\n\(violations.joined(separator: "\n"))"
        )
    }

    @Test
    func watchOSSourcesDoNotImportSDWebImage() throws {
        let fileURLs = try sourceFiles(
            roots: [sourceRoot.appendingPathComponent("Apps/PushGo-watchOS", isDirectory: true)]
        )

        var violations: [String] = []
        for fileURL in fileURLs {
            let content = try String(contentsOf: fileURL, encoding: .utf8)
            if content.contains("SDWebImage") || content.contains("SDWebImageSwiftUI") {
                violations.append(fileURL.path)
            }
        }

        #expect(
            violations.isEmpty,
            "watchOS should stay on system image APIs without SDWebImage. Violations:\n\(violations.joined(separator: "\n"))"
        )
    }

    private var sourceRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // PushGoAppleCoreTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // pushgo
    }

    private func sourceFiles(roots: [URL]) throws -> [URL] {
        var files: [URL] = []
        let fileManager = FileManager.default

        for root in roots {
            guard fileManager.fileExists(atPath: root.path) else { continue }
            guard let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }
            for case let fileURL as URL in enumerator {
                guard fileURL.pathExtension == "swift" else { continue }
                let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey])
                guard values.isRegularFile == true else { continue }
                files.append(fileURL)
            }
        }

        return files.sorted { $0.path < $1.path }
    }
}
