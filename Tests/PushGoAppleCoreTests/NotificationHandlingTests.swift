import Foundation
import Testing
import UserNotifications
@testable import PushGoAppleCore

private actor NotificationMessageCapture {
    private var message: PushMessage?

    func store(_ message: PushMessage) {
        self.message = message
    }

    func load() -> PushMessage? {
        message
    }
}

struct NotificationHandlingTests {
    @Test
    func skipPersistenceRecognizesTruthyFlagVariants() {
        #expect(NotificationHandling.shouldSkipPersistence(for: ["_skip_persist": "true"]))
        #expect(NotificationHandling.shouldSkipPersistence(for: ["_skip_persist": "1"]))
        #expect(NotificationHandling.shouldSkipPersistence(for: ["_skip_persist": "yes"]))
        #expect(NotificationHandling.shouldSkipPersistence(for: ["_skip_persist": "on"]))
        #expect(NotificationHandling.shouldSkipPersistence(for: ["_skip_persist": 1]))
        #expect(!NotificationHandling.shouldSkipPersistence(for: ["_skip_persist": "false"]))
        #expect(!NotificationHandling.shouldSkipPersistence(for: ["title": "persist me"]))
    }

    @Test
    func categoryIdentifierUsesReminderCategoryForEntityPayloads() {
        let eventPayload: [AnyHashable: Any] = [
            "entity_type": "event",
            "entity_id": "evt-001",
            "event_id": "evt-001",
        ]
        let plainPayload: [AnyHashable: Any] = [
            "message_id": "msg-001",
            "title": "Plain message",
        ]

        #expect(NotificationHandling.isEntityReminderPayload(eventPayload))
        #expect(
            NotificationHandling.notificationCategoryIdentifier(for: eventPayload) ==
                AppConstants.notificationEntityReminderCategoryIdentifier
        )
        #expect(
            NotificationHandling.notificationCategoryIdentifier(for: plainPayload) ==
                AppConstants.notificationDefaultCategoryIdentifier
        )
    }

    @Test
    func normalizeRemoteNotificationMapsDecryptionStateAndLocalizedLabels() {
        let payload: [AnyHashable: Any] = [
            "entity_type": "event",
            "event_id": "evt-crypto-001",
            "entity_id": "evt-crypto-001",
            "decryption_state": "decryptOk",
            "event_state": "open",
        ]

        let normalized = NotificationHandling.normalizeRemoteNotification(payload)

        #expect(normalized?.entityType == "event")
        #expect(normalized?.entityId == "evt-crypto-001")
        #expect(normalized?.title.contains("evt-crypto-001") == true)
        #expect(normalized?.body == "open")
        #expect(normalized?.decryptionState == .decryptOk)
    }

    @Test
    func shouldPresentUserAlertRespectsExpiryAndExplicitOverrides() {
        let expiredPayload: [AnyHashable: Any] = [
            "entity_type": "event",
            "event_id": "evt-expired-001",
            "entity_id": "evt-expired-001",
            "severity": "critical",
            "ttl": 1,
        ]
        let lowSeverityPayload: [AnyHashable: Any] = [
            "entity_type": "event",
            "event_id": "evt-low-001",
            "entity_id": "evt-low-001",
            "severity": "low",
        ]
        let explicitCriticalPayload: [AnyHashable: Any] = [
            "entity_type": "event",
            "event_id": "evt-critical-001",
            "entity_id": "evt-critical-001",
            "severity": "critical",
        ]
        let explicitSilentPayload: [AnyHashable: Any] = [
            "entity_type": "event",
            "event_id": "evt-silent-001",
            "entity_id": "evt-silent-001",
            "severity": "critical",
            "notify": ["enabled": false],
        ]

        #expect(!NotificationHandling.shouldPresentUserAlert(from: expiredPayload))
        #expect(NotificationHandling.shouldPresentUserAlert(from: lowSeverityPayload))
        #expect(NotificationHandling.shouldPresentUserAlert(from: explicitCriticalPayload))
        #expect(NotificationHandling.shouldPresentUserAlert(from: explicitSilentPayload))
    }

    @Test
    func normalizeRemoteNotificationRejectsPlainMessagesWithoutMessageId() {
        let payload: [AnyHashable: Any] = [
            "delivery_id": "delivery-aps-001",
            "entity_type": "message",
            "entity_id": "delivery-aps-001",
            "aps": [
                "thread-id": "aps-thread-001",
                "alert": [
                    "title": "APS Title",
                    "body": "APS Body",
                ],
            ],
        ]

        let normalized = NotificationHandling.normalizeRemoteNotification(payload)

        #expect(normalized == nil)
    }

    @Test
    func normalizeRemoteNotificationBuildsThingFallbackFromProfilePayload() {
        let payload: [AnyHashable: Any] = [
            "entity_type": "thing",
            "thing_id": "thing-profile-001",
            "entity_id": "thing-profile-001",
            "thing_profile_json": #"{"title":"Battery Sensor","description":"Workshop sensor needs calibration"}"#,
            "decryption_state": "decryptFailed",
        ]

        let normalized = NotificationHandling.normalizeRemoteNotification(payload)
        let target = NotificationHandling.entityOpenTargetComponents(from: payload)

        #expect(normalized?.entityType == "thing")
        #expect(normalized?.entityId == "thing-profile-001")
        #expect(normalized?.thingId == "thing-profile-001")
        #expect(normalized?.title == "Battery Sensor")
        #expect(normalized?.body == "Workshop sensor needs calibration")
        #expect(normalized?.decryptionState == .decryptFailed)
        #expect(target == .init(entityType: "thing", entityId: "thing-profile-001"))
    }

    @Test
    func persistIfNeededSkipsStorageWhenPayloadRequestsBypass() async throws {
        try await withIsolatedLocalDataStore { store, _ in
            let content = UNMutableNotificationContent()
            content.title = "Bypassed"
            content.body = "Should not persist"
            content.userInfo = [
                "_skip_persist": "yes",
                "message_id": "msg-skip-001",
                "title": "Bypassed",
                "body": "Should not persist",
            ]
            let request = UNNotificationRequest(
                identifier: "req-skip-001",
                content: content,
                trigger: nil
            )

            let outcome = await NotificationPersistenceCoordinator.persistIfNeeded(
                request: request,
                content: content,
                dataStore: store
            )

            guard case .rejected = outcome else {
                Issue.record("Expected _skip_persist payload to bypass storage.")
                return
            }
            let messages = try await store.loadMessages()
            #expect(messages.isEmpty)
        }
    }

    @Test
    func persistIfNeededSurfacesDuplicateRequestAndBeforeSaveMessage() async throws {
        try await withIsolatedLocalDataStore { store, _ in
            let firstContent = UNMutableNotificationContent()
            firstContent.title = "First title"
            firstContent.body = "First body"
            firstContent.userInfo = [
                "message_id": "msg-notification-001",
                "title": "First title",
                "body": "First body",
                "sent_at": "2026-03-10T02:03:04Z",
            ]
            let firstRequest = UNNotificationRequest(
                identifier: "req-notification-001",
                content: firstContent,
                trigger: nil
            )

            let firstOutcome = await NotificationPersistenceCoordinator.persistIfNeeded(
                request: firstRequest,
                content: firstContent,
                dataStore: store
            )
            guard case let .persistedMain(stored) = firstOutcome else {
                Issue.record("Expected first notification delivery to persist.")
                return
            }
            #expect(stored.title == "First title")
            #expect(stored.notificationRequestId == "req-notification-001")

            let secondContent = UNMutableNotificationContent()
            secondContent.title = "Updated title"
            secondContent.body = "Updated body"
            secondContent.userInfo = [
                "message_id": "msg-notification-002",
                "title": "Updated title",
                "body": "Updated body",
                "sent_at": "2026-03-10T03:04:05Z",
            ]
            let secondRequest = UNNotificationRequest(
                identifier: "req-notification-001",
                content: secondContent,
                trigger: nil
            )

            let capture = NotificationMessageCapture()
            let duplicateOutcome = await NotificationPersistenceCoordinator.persistIfNeeded(
                request: secondRequest,
                content: secondContent,
                dataStore: store,
                beforeSave: { message in
                    await capture.store(message)
                }
            )
            let beforeSaveSnapshot = await capture.load()
            let messages = try await store.loadMessages()
            let storedMessage = try await store.loadMessage(notificationRequestId: "req-notification-001")

            guard case .duplicate = duplicateOutcome else {
                Issue.record("Expected second notification delivery with same request id to surface duplicate.")
                return
            }
            #expect(beforeSaveSnapshot?.title == "Updated title")
            #expect(beforeSaveSnapshot?.body == "Updated body")
            #expect(beforeSaveSnapshot?.notificationRequestId == "req-notification-001")
            #expect(beforeSaveSnapshot?.messageId == "msg-notification-002")
            #expect(messages.count == 1)
            #expect(storedMessage?.title == "Updated title")
        }
    }

    @Test
    func persistIfNeededFallsBackToStoredEventTitleWhenTitleIsNotExplicit() async throws {
        try await withIsolatedLocalDataStore { store, _ in
            let seededEvent = makeEntityRecord(
                messageId: "evt-title-fallback-seed-001",
                notificationRequestId: "req-title-fallback-seed-001",
                title: "Stored event title from DB",
                body: "seed body",
                rawPayload: [
                    "entity_type": "event",
                    "entity_id": "evt-title-fallback-001",
                    "event_id": "evt-title-fallback-001",
                    "projection_destination": "event_head",
                ]
            )
            try await store.saveEntityRecords([seededEvent])

            let content = UNMutableNotificationContent()
            content.title = ""
            content.body = "fallback body from content"
            content.userInfo = [
                "message_id": "msg-title-fallback-001",
                "entity_type": "event",
                "entity_id": "evt-title-fallback-001",
                "event_id": "evt-title-fallback-001",
                "event_profile_json": #"{"title":"Profile fallback title","message":"profile body"}"#,
                "severity": "critical",
            ]
            let request = UNNotificationRequest(
                identifier: "req-title-fallback-001",
                content: content,
                trigger: nil
            )

            let outcome = await NotificationPersistenceCoordinator.persistIfNeeded(
                request: request,
                content: content,
                dataStore: store
            )

            guard case let .persistedMain(stored) = outcome else {
                Issue.record("Expected event payload to persist with stored title fallback.")
                return
            }
            #expect(stored.title == "Stored event title from DB")
            #expect(stored.body == "profile body")
            #expect(stored.rawPayload["title"]?.value as? String == "Stored event title from DB")
        }
    }

    @Test
    func persistRemotePayloadIfNeededPersistsEventWithoutMessageIdUsingDeliveryIdentity() async throws {
        try await withIsolatedLocalDataStore { store, _ in
            let payload: [AnyHashable: Any] = [
                "delivery_id": "delivery-event-001",
                "entity_type": "event",
                "entity_id": "evt-pull-001",
                "event_id": "evt-pull-001",
                "event_state": "open",
                "severity": "critical",
            ]

            let outcome = await NotificationPersistenceCoordinator.persistRemotePayloadIfNeeded(
                payload,
                requestIdentifier: "delivery-event-001",
                dataStore: store
            )

            guard case .persistedMain = outcome else {
                Issue.record("Expected event pull payload without message_id to persist.")
                return
            }
            let events = try await store.loadEventMessagesForProjection(eventId: "evt-pull-001")
            #expect(events.count == 1)
            #expect(events.first?.eventId == "evt-pull-001")
            #expect(events.first?.notificationRequestId == "delivery-event-001")
        }
    }

    @Test
    func normalizeRemoteNotificationTracksExplicitTitleSignal() {
        let explicitPayload: [AnyHashable: Any] = [
            "entity_type": "event",
            "entity_id": "evt-explicit-title-001",
            "event_id": "evt-explicit-title-001",
            "title": "Explicit event title",
            "body": "event body",
        ]
        let fallbackPayload: [AnyHashable: Any] = [
            "entity_type": "event",
            "entity_id": "evt-fallback-title-001",
            "event_id": "evt-fallback-title-001",
            "event_profile_json": #"{"title":"Profile fallback title","message":"fallback body"}"#,
        ]

        let explicit = NotificationHandling.normalizeRemoteNotification(explicitPayload)
        let fallback = NotificationHandling.normalizeRemoteNotification(fallbackPayload)

        #expect(explicit?.hasExplicitTitle == true)
        #expect(explicit?.title == "Explicit event title")
        #expect(fallback?.hasExplicitTitle == false)
        #expect(fallback?.title == "Profile fallback title")
    }

    @Test
    func normalizeRemoteNotificationKeepsEntitySemanticsConsistentAcrossDirectAndPullPayloads() {
        let directPayload: [AnyHashable: Any] = [
            "entity_type": "event",
            "entity_id": "evt-path-consistency-001",
            "event_id": "evt-path-consistency-001",
            "aps": [
                "alert": [
                    "title": "Path consistency title",
                    "body": "Path consistency body",
                ],
            ],
            "severity": "critical",
        ]
        let pullPayload: [AnyHashable: Any] = [
            "entity_type": "event",
            "entity_id": "evt-path-consistency-001",
            "event_id": "evt-path-consistency-001",
            "title": "Path consistency title",
            "body": "Path consistency body",
            "severity": "critical",
        ]

        let direct = NotificationHandling.normalizeRemoteNotification(directPayload)
        let pull = NotificationHandling.normalizeRemoteNotification(pullPayload)

        #expect(direct?.entityType == "event")
        #expect(pull?.entityType == "event")
        #expect(direct?.entityId == "evt-path-consistency-001")
        #expect(pull?.entityId == "evt-path-consistency-001")
        #expect(direct?.title == "Path consistency title")
        #expect(pull?.title == "Path consistency title")
        #expect(direct?.body == "Path consistency body")
        #expect(pull?.body == "Path consistency body")
        #expect(NotificationHandling.shouldPresentUserAlert(from: directPayload))
        #expect(NotificationHandling.shouldPresentUserAlert(from: pullPayload))
    }

    private func makeEntityRecord(
        messageId: String,
        notificationRequestId: String,
        title: String,
        body: String,
        rawPayload: [String: Any]
    ) -> PushMessage {
        var payload = rawPayload
        payload["message_id"] = messageId
        payload["_notificationRequestId"] = notificationRequestId
        return PushMessage(
            messageId: messageId,
            title: title,
            body: body,
            channel: "notification-tests",
            receivedAt: Date(timeIntervalSince1970: 1_741_572_800),
            rawPayload: payload.reduce(into: [String: AnyCodable]()) { result, item in
                result[item.key] = AnyCodable(item.value)
            }
        )
    }
}
