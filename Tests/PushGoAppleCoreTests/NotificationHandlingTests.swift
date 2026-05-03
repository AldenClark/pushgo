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
    func providerWakeupPullDeliveryIdRequiresWakeupMarkers() {
        #expect(
            NotificationHandling.providerWakeupPullDeliveryId(
                from: [
                    "provider_wakeup": "1",
                    "provider_mode": "wakeup",
                    "delivery_id": "delivery-wakeup-001",
                ]
            ) == "delivery-wakeup-001"
        )
        #expect(
            NotificationHandling.providerWakeupPullDeliveryId(
                from: [
                    "delivery_id": "delivery-wakeup-001",
                ]
            ) == nil
        )
        #expect(
            NotificationHandling.providerWakeupPullDeliveryId(
                from: [
                    "provider_wakeup": "1",
                    "provider_mode": "direct",
                    "delivery_id": "delivery-wakeup-001",
                ]
            ) == nil
        )
    }

    @Test
    func providerIngressAckDeliveryIdOnlyAcknowledgesDirectPayloads() {
        let directIngress = NotificationIngressResolution.direct(
            payload: [
                "delivery_id": "delivery-direct-001",
                "message_id": "msg-direct-001",
            ],
            requestIdentifier: "delivery-direct-001"
        )
        let pulledIngress = NotificationIngressResolution.pulled(
            payload: [
                "delivery_id": "delivery-pulled-001",
                "message_id": "msg-pulled-001",
                "body": "Pulled body",
            ],
            requestIdentifier: "delivery-pulled-001"
        )
        let unresolvedIngress = NotificationIngressResolution.unresolvedWakeup(
            payload: [
                "provider_wakeup": "1",
                "provider_mode": "wakeup",
                "delivery_id": "delivery-wakeup-ack-001",
            ],
            requestIdentifier: "delivery-wakeup-ack-001"
        )

        #expect(
            NotificationHandling.providerIngressAckDeliveryId(
                for: directIngress,
                outcome: .persistedMain(
                    PushMessage(messageId: "msg-direct-001", title: "Direct", body: "Body")
                )
            ) == "delivery-direct-001"
        )
        #expect(
            NotificationHandling.providerIngressAckDeliveryId(
                for: directIngress,
                outcome: .duplicate
            ) == nil
        )
        #expect(
            NotificationHandling.providerIngressAckDeliveryId(
                for: pulledIngress,
                outcome: .duplicate
            ) == nil
        )
        #expect(
            NotificationHandling.providerIngressAckDeliveryId(
                for: unresolvedIngress,
                outcome: .persistedMain(
                    PushMessage(messageId: "msg-wakeup-ack-001", title: "Wakeup", body: "Body")
                )
            ) == nil
        )
    }

    @Test
    func resolveNotificationIngressSurfacesUnresolvedWakeupWithDeliveryIdentity() async throws {
        await withIsolatedLocalDataStore { store, _ in
            let payload: [AnyHashable: Any] = [
                "provider_wakeup": "1",
                "provider_mode": "wakeup",
                "delivery_id": "delivery-wakeup-unresolved-001",
                "message_id": "msg-wakeup-unresolved-001",
            ]

            let resolution = await NotificationHandling.resolveNotificationIngress(
                from: payload,
                dataStore: store,
                channelSubscriptionService: ChannelSubscriptionService()
            )

            guard case let .unresolvedWakeup(unresolvedPayload, requestIdentifier) = resolution else {
                Issue.record("Expected wakeup ingress without server candidates to remain unresolved.")
                return
            }
            #expect(requestIdentifier == "delivery-wakeup-unresolved-001")
            #expect(unresolvedPayload["delivery_id"] as? String == "delivery-wakeup-unresolved-001")
            #expect(unresolvedPayload["message_id"] as? String == "msg-wakeup-unresolved-001")
        }
    }

    @Test
    func normalizeRemoteNotificationForDisplayKeepsWakeupAlertTitleForLongMessageFallback() {
        let payload: [AnyHashable: Any] = [
            "provider_wakeup": "1",
            "provider_mode": "wakeup",
            "delivery_id": "delivery-long-message-001",
            "message_id": "msg-long-message-001",
            "entity_type": "message",
            "entity_id": "msg-long-message-001",
            "aps": [
                "alert": [
                    "title": "这是一条超长消息",
                    "body": "这是长消息的预览正文",
                ],
            ],
            "_skip_persist": "1",
        ]

        let normalized = NotificationHandling.normalizeRemoteNotificationForDisplay(payload)

        #expect(normalized?.title == "这是一条超长消息")
        #expect(normalized?.body == "这是长消息的预览正文")
        #expect(normalized?.messageId == "msg-long-message-001")
        #expect(normalized?.entityType == "message")
    }

    @Test
    func wakeupFallbackDisplayPayloadCarriesResolvedBodyIntoTopLevelPayload() {
        let payload: [AnyHashable: Any] = [
            "provider_wakeup": "1",
            "provider_mode": "wakeup",
            "delivery_id": "delivery-nse-fallback-001",
            "message_id": "msg-nse-fallback-001",
            "entity_type": "message",
            "entity_id": "msg-nse-fallback-001",
            "aps": [
                "alert": [
                    "title": "Fallback title",
                    "body": "Fallback body preview",
                ],
            ],
            "_skip_persist": "1",
        ]

        let fallbackPayload = NotificationHandling.wakeupFallbackDisplayPayload(from: payload)

        #expect(fallbackPayload?["title"] as? String == "Fallback title")
        #expect(fallbackPayload?["body"] as? String == "Fallback body preview")
        #expect(fallbackPayload?["_skip_persist"] == nil)
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
    func normalizeRemoteNotificationAcceptsSnakeCaseDecryptionState() {
        let payload: [AnyHashable: Any] = [
            "entity_type": "message",
            "message_id": "msg-crypto-002",
            "entity_id": "msg-crypto-002",
            "decryption_state": "decrypt_failed",
            "title": "Encrypted",
            "body": "Body",
        ]

        let normalized = NotificationHandling.normalizeRemoteNotification(payload)

        #expect(normalized?.decryptionState == .decryptFailed)
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
            "title": "Battery Sensor",
            "description": "Workshop sensor needs calibration",
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
    func persistPreparedContentIfNeededPrefersIngressRequestIdentifier() async throws {
        try await withIsolatedLocalDataStore { store, _ in
            let content = UNMutableNotificationContent()
            content.title = "Direct title"
            content.body = "Direct body"
            content.userInfo = [
                "message_id": "msg-direct-ingress-001",
                "title": "Direct title",
                "body": "Direct body",
                "sent_at": "2026-03-10T03:04:05Z",
            ]

            let outcome = await NotificationPersistenceCoordinator.persistPreparedContentIfNeeded(
                content: content,
                requestIdentifier: "delivery-direct-ingress-001",
                fallbackRequestIdentifier: "apple-request-ignored-001",
                dataStore: store
            )

            guard case let .persistedMain(stored) = outcome else {
                Issue.record("Expected explicit ingress request identifier to persist direct notification content.")
                return
            }
            #expect(stored.notificationRequestId == "delivery-direct-ingress-001")
            let loaded = try await store.loadMessage(notificationRequestId: "delivery-direct-ingress-001")
            #expect(loaded?.messageId == "msg-direct-ingress-001")
            #expect(loaded?.notificationRequestId == "delivery-direct-ingress-001")
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
                "message": "profile body",
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
    func persistIfNeededFallsBackToStoredThingTitleWhenTitleIsNotExplicit() async throws {
        try await withIsolatedLocalDataStore { store, _ in
            let seededThing = makeEntityRecord(
                messageId: "thing-title-fallback-seed-001",
                notificationRequestId: "req-thing-title-fallback-seed-001",
                title: "Stored thing title from DB",
                body: "seed body",
                rawPayload: [
                    "entity_type": "thing",
                    "entity_id": "thing-title-fallback-001",
                    "thing_id": "thing-title-fallback-001",
                    "projection_destination": "thing_head",
                ]
            )
            try await store.saveEntityRecords([seededThing])

            let content = UNMutableNotificationContent()
            content.title = ""
            content.body = "fallback thing body from content"
            content.userInfo = [
                "message_id": "msg-thing-title-fallback-001",
                "entity_type": "thing",
                "entity_id": "thing-title-fallback-001",
                "thing_id": "thing-title-fallback-001",
                "attrs": "{\"temperature\":\"24\"}",
                "severity": "normal",
            ]
            let request = UNNotificationRequest(
                identifier: "req-thing-title-fallback-001",
                content: content,
                trigger: nil
            )

            let outcome = await NotificationPersistenceCoordinator.persistIfNeeded(
                request: request,
                content: content,
                dataStore: store
            )

            guard case let .persistedMain(stored) = outcome else {
                Issue.record("Expected thing payload to persist with stored title fallback.")
                return
            }
            #expect(stored.title == "Stored thing title from DB")
            #expect(stored.rawPayload["title"]?.value as? String == "Stored thing title from DB")
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
    func persistRemotePayloadIfNeededAcceptsWideFieldMatrixWithoutFailure() async {
        await withIsolatedLocalDataStore { store, _ in
            var failedCases: [String] = []
            var rejectedCases: [String] = []

            for slot in 0..<18 {
                let payload = makeNSECoveragePayload(slot: slot)
                let requestIdentifier = "nse-matrix-\(slot)"
                let outcome = await NotificationPersistenceCoordinator.persistRemotePayloadIfNeeded(
                    payload,
                    requestIdentifier: requestIdentifier,
                    dataStore: store
                )

                switch outcome {
                case .failed:
                    failedCases.append(requestIdentifier)
                case .rejected:
                    rejectedCases.append(requestIdentifier)
                case .persistedMain, .persistedPending, .duplicate:
                    break
                }
            }

            #expect(
                failedCases.isEmpty,
                "persistRemotePayloadIfNeeded should not fail for coverage payloads: \(failedCases)"
            )
            #expect(
                rejectedCases.isEmpty,
                "persistRemotePayloadIfNeeded should not reject valid coverage payloads: \(rejectedCases)"
            )
        }
    }

    @Test
    func persistPreparedContentIfNeededHandlesConcurrentIngressWithoutFailure() async {
        await withIsolatedLocalDataStore { store, _ in
            let outcomes = await withTaskGroup(
                of: (String, NotificationPersistenceOutcome).self,
                returning: [(String, NotificationPersistenceOutcome)].self
            ) { group in
                for slot in 0..<40 {
                    group.addTask {
                        let messageId = "nse-concurrent-msg-\(slot)"
                        let requestId = "nse-concurrent-req-\(slot)"
                        let content = UNMutableNotificationContent()
                        content.title = "NSE Concurrent \(slot)"
                        content.body = "Concurrent body \(slot)"
                        content.userInfo = [
                            "message_id": messageId,
                            "entity_type": "message",
                            "entity_id": messageId,
                            "delivery_id": requestId,
                            "decryption_state": "decryptOk",
                            "metadata": "{\"suite\":\"nse-concurrency\",\"slot\":\(slot)}",
                        ]
                        let outcome =
                            await NotificationPersistenceCoordinator.persistPreparedContentIfNeeded(
                                content: content,
                                requestIdentifier: requestId,
                                fallbackRequestIdentifier: requestId,
                                dataStore: store
                            )
                        return (requestId, outcome)
                    }
                }

                var aggregated: [(String, NotificationPersistenceOutcome)] = []
                for await item in group {
                    aggregated.append(item)
                }
                return aggregated
            }

            let failed = outcomes.compactMap { entry -> String? in
                guard case .failed = entry.1 else { return nil }
                return entry.0
            }
            let rejected = outcomes.compactMap { entry -> String? in
                guard case .rejected = entry.1 else { return nil }
                return entry.0
            }

            #expect(failed.isEmpty, "concurrent NSE persistence should not fail: \(failed)")
            #expect(rejected.isEmpty, "concurrent NSE persistence should not reject: \(rejected)")
        }
    }

    @Test
    func persistRemotePayloadIfNeededWithConcurrentLocalStoreInitializersDoesNotFail() async {
        await withIsolatedAutomationStorage { _, appGroupIdentifier in
            let results = await withTaskGroup(
                of: (slot: Int, available: Bool, outcome: NotificationPersistenceOutcome).self,
                returning: [(slot: Int, available: Bool, outcome: NotificationPersistenceOutcome)].self
            ) { group in
                for slot in 0..<40 {
                    group.addTask {
                        let store = LocalDataStore(appGroupIdentifier: appGroupIdentifier)
                        let available: Bool
                        switch store.storageState.mode {
                        case .persistent:
                            available = true
                        case .unavailable:
                            available = false
                        }
                        let payload: [AnyHashable: Any] = [
                            "message_id": "nse-store-init-msg-\(slot)",
                            "entity_type": "message",
                            "entity_id": "nse-store-init-msg-\(slot)",
                            "delivery_id": "nse-store-init-delivery-\(slot)",
                            "title": "Store Init \(slot)",
                            "body": "Store init body \(slot)",
                            "metadata": "{\"suite\":\"nse-store-init\",\"slot\":\(slot)}",
                            "decryption_state": "decryptOk",
                        ]
                        let outcome = await NotificationPersistenceCoordinator.persistRemotePayloadIfNeeded(
                            payload,
                            requestIdentifier: "nse-store-init-delivery-\(slot)",
                            dataStore: store
                        )
                        return (slot: slot, available: available, outcome: outcome)
                    }
                }

                var aggregated: [(slot: Int, available: Bool, outcome: NotificationPersistenceOutcome)] = []
                for await item in group {
                    aggregated.append(item)
                }
                return aggregated
            }

            let unavailableSlots = results.compactMap { result -> Int? in
                result.available ? nil : result.slot
            }
            let failedSlots = results.compactMap { result -> Int? in
                guard case .failed = result.outcome else { return nil }
                return result.slot
            }
            let rejectedSlots = results.compactMap { result -> Int? in
                guard case .rejected = result.outcome else { return nil }
                return result.slot
            }

            #expect(
                unavailableSlots.isEmpty,
                "LocalDataStore should stay available under concurrent initialization: \(unavailableSlots)"
            )
            #expect(
                failedSlots.isEmpty,
                "concurrent LocalDataStore initialization should not fail persistence: \(failedSlots)"
            )
            #expect(
                rejectedSlots.isEmpty,
                "concurrent LocalDataStore initialization should not reject valid payloads: \(rejectedSlots)"
            )
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
            "message": "fallback body",
        ]

        let explicit = NotificationHandling.normalizeRemoteNotification(explicitPayload)
        let fallback = NotificationHandling.normalizeRemoteNotification(fallbackPayload)

        #expect(explicit?.hasExplicitTitle == true)
        #expect(explicit?.title == "Explicit event title")
        #expect(fallback?.hasExplicitTitle == false)
        #expect(fallback?.title == "push_type_event evt-fallback-title-001")
    }

    @Test
    func normalizeRemoteNotificationUsesDeterministicEntityFallbackBodyWithoutDatabase() {
        let eventPayload: [AnyHashable: Any] = [
            "entity_type": "event",
            "entity_id": "evt-fallback-body-001",
            "event_id": "evt-fallback-body-001",
        ]
        let thingPayload: [AnyHashable: Any] = [
            "entity_type": "thing",
            "entity_id": "thing-fallback-body-001",
            "thing_id": "thing-fallback-body-001",
        ]

        let normalizedEvent = NotificationHandling.normalizeRemoteNotification(eventPayload)
        let normalizedThing = NotificationHandling.normalizeRemoteNotification(thingPayload)

        #expect(normalizedEvent?.title == "push_type_event evt-fallback-body-001")
        #expect(normalizedEvent?.body == NotificationPayloadSemantics.gatewayFallbackEventBody)
        #expect(normalizedThing?.title == "push_type_thing thing-fallback-body-001")
        #expect(normalizedThing?.body == NotificationPayloadSemantics.gatewayFallbackThingBody)
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

    @Test
    func foregroundPresentationDecisionReloadsCountsForDuplicateAlert() {
        let payload: [AnyHashable: Any] = [
            "entity_type": "message",
            "message_id": "msg-foreground-duplicate-001",
            "entity_id": "msg-foreground-duplicate-001",
            "title": "Foreground message",
            "body": "Duplicate payload should still refresh badge and present",
        ]

        let decision = NotificationHandling.foregroundPresentationDecision(
            persistenceOutcome: .duplicate,
            payload: payload
        )

        #expect(decision.shouldReloadCounts)
        #expect(decision.shouldPresentAlert)
    }

    @Test
    func foregroundPresentationDecisionSuppressesRejectedPayloads() {
        let payload: [AnyHashable: Any] = [
            "_skip_persist": "1",
            "entity_type": "message",
            "message_id": "msg-foreground-rejected-001",
            "entity_id": "msg-foreground-rejected-001",
            "title": "Bypassed",
            "body": "Should not present",
        ]

        let decision = NotificationHandling.foregroundPresentationDecision(
            persistenceOutcome: .rejected,
            payload: payload
        )

        #expect(!decision.shouldReloadCounts)
        #expect(!decision.shouldPresentAlert)
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

private func makeNSECoveragePayload(slot: Int) -> [AnyHashable: Any] {
    let entityKind = slot % 3
    let runStamp = "nse-matrix-\(slot)"
    let basePayload: [AnyHashable: Any] = [
        "title": "NSE Matrix Title \(slot)",
        "body": String(repeating: "segment-\(slot)-", count: (slot % 4) + 8),
        "url": "https://enc.pushgo.dev/nse/\(slot)",
        "images": [
            "https://img.cdn1.vip/i/69b57f804c59b_1773502336.webp",
            "https://img.cdn1.vip/i/69a021729fde1_1772102002.jpeg",
        ],
        "tags": ["suite:nse", "slot:\(slot)", "entity:\(entityKind)"],
        "metadata":
            "{\"suite\":\"nse-matrix\",\"slot\":\(slot),\"trace\":\"\(runStamp)\",\"source\":\"notification-service\"}",
        "decryption_state": "decryptOk",
        "delivery_id": "nse-delivery-\(slot)",
        "channel_id": "WW4PETB9DXWWKZ92WS434350DC",
    ]

    switch entityKind {
    case 0:
        var messagePayload = basePayload
        let messageId = "nse-msg-\(slot)"
        messagePayload["message_id"] = messageId
        messagePayload["entity_type"] = "message"
        messagePayload["entity_id"] = messageId
        return messagePayload
    case 1:
        var eventPayload = basePayload
        let eventId = "nse-evt-\(slot)"
        eventPayload["event_id"] = eventId
        eventPayload["entity_type"] = "event"
        eventPayload["entity_id"] = eventId
        eventPayload["event_state"] = slot % 2 == 0 ? "open" : "closed"
        eventPayload["status"] = slot % 2 == 0 ? "open" : "closed"
        eventPayload["message"] = "event-message-\(slot)"
        eventPayload["started_at"] = 1_777_170_000_000 + slot * 1000
        eventPayload["ended_at"] = 1_777_170_500_000 + slot * 1000
        eventPayload["attrs"] =
            "{\"operator\":\"nse-test\",\"revision\":\(slot),\"phase\":\"event\"}"
        return eventPayload
    default:
        var thingPayload = basePayload
        let thingId = "nse-thing-\(slot)"
        thingPayload["thing_id"] = thingId
        thingPayload["entity_type"] = "thing"
        thingPayload["entity_id"] = thingId
        thingPayload["state"] = slot % 2 == 0 ? "active" : "archived"
        thingPayload["primary_image"] = "https://img.cdn1.vip/i/69b57f34abd6a_1773502260.webp"
        thingPayload["external_ids"] = "{\"serial\":\"nse-\(slot)\",\"asset\":\"asset-\(slot)\"}"
        thingPayload["location_type"] = slot % 2 == 0 ? "geo" : "logical"
        thingPayload["location_value"] =
            slot % 2 == 0 ? "31.2304,121.4737" : "region-\(slot)/rack-\(slot)"
        thingPayload["attrs"] =
            "{\"firmware\":\"nse-\(slot)\",\"temperature\":\(20 + slot),\"online\":true}"
        return thingPayload
    }
}
