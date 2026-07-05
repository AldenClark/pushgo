import Foundation
import Testing
@testable import PushGoAppleCore

@Suite(.serialized)
struct PushGoSystemIntegrationTests {
    @Test
    func systemIntegrationSettingsDefaultsMatchPlan() {
        let settings = SystemIntegrationSettings()

        #expect(settings.systemSearchEnabled)
        #expect(settings.includeMessageBodyInSearch)
        #expect(settings.includeMetadataInSearch)
        #expect(settings.indexEventsAndThings)
        #expect(settings.timeSensitiveAlertsEnabled)
    }

    @Test
    func systemIntegrationSettingsNormalizationForcesBuiltInDefaults() {
        let settings = SystemIntegrationSettings(
            systemSearchEnabled: false,
            includeMessageBodyInSearch: false,
            includeMetadataInSearch: false,
            indexEventsAndThings: false,
            timeSensitiveAlertsEnabled: false
        ).normalized

        #expect(settings.systemSearchEnabled)
        #expect(settings.includeMessageBodyInSearch)
        #expect(settings.includeMetadataInSearch)
        #expect(settings.indexEventsAndThings)
        #expect(settings.timeSensitiveAlertsEnabled)
    }

    @Test
    func deepLinkParsesMessageEventAndThingTargets() throws {
        let messageURL = try #require(URL(string: "pushgo://open?kind=message&id=msg-001"))
        let eventURL = try #require(URL(string: "pushgo://open?kind=event&id=evt-001"))
        let thingURL = try #require(URL(string: "pushgo://open?kind=thing&id=thing-001"))

        #expect(PushGoDeepLink.parse(messageURL)?.kind == .message)
        #expect(PushGoDeepLink.parse(messageURL)?.identifier == "msg-001")
        #expect(PushGoDeepLink.parse(eventURL)?.kind == .event)
        #expect(PushGoDeepLink.parse(thingURL)?.kind == .thing)
    }

    @Test
    func deepLinkRejectsInvalidKindAndEmptyID() throws {
        let invalidKind = try #require(URL(string: "pushgo://open?kind=object&id=thing-001"))
        let emptyID = try #require(URL(string: "pushgo://open?kind=thing&id=%20%20"))

        #expect(PushGoDeepLink.parse(invalidKind) == nil)
        #expect(PushGoDeepLink.parse(emptyID) == nil)
    }

    @Test
    func spotlightIdentifierRoundTripsEscapedIdentifiers() throws {
        let original = try #require(PushGoSpotlightIdentifier(kind: .thing, identifier: "server rack/01"))
        let parsed = try #require(PushGoSpotlightIdentifier(uniqueIdentifier: original.uniqueIdentifier))

        #expect(parsed.kind == .thing)
        #expect(parsed.identifier == "server rack/01")
        #expect(parsed.domainIdentifier == "io.pushgo.system.thing")
        #expect(parsed.openTarget?.source == .spotlight)
    }

    @Test
    func userActivityBuilderRoundTripsOpenTargetsWithoutRawPayload() throws {
        let message = PushMessage(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000777")!,
            messageId: "msg-activity-001",
            title: "Activity message",
            body: "Activity body",
            receivedAt: Date(timeIntervalSince1970: 777)
        )
        let summary = PushGoSystemSummaryBuilder.summary(for: message)
        let activity = PushGoUserActivityBuilder.activity(for: summary, systemSearchEnabled: true)
        let target = try #require(PushGoUserActivityBuilder.openTarget(from: activity))

        #expect(activity.activityType == PushGoUserActivityBuilder.messageActivityType)
        #expect(activity.isEligibleForSearch)
        #expect(target.kind == .message)
        #expect(target.identifier == message.id.uuidString)
        #expect(target.localMessageID == message.id)
        #expect(activity.userInfo?["rawPayload"] == nil)
        #expect(activity.userInfo?["body"] == nil)
    }

    @Test
    func messageSummaryRedactsDecryptFailedBody() {
        let message = PushMessage(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000123")!,
            messageId: "msg-sensitive",
            title: "Secret alert",
            body: "do not index this body",
            channel: "security",
            isRead: false,
            receivedAt: Date(timeIntervalSince1970: 100),
            rawPayload: [
                "severity": AnyCodable("critical"),
                "ciphertext": AnyCodable("abc"),
            ],
            status: .partiallyDecrypted,
            decryptionState: .decryptFailed
        )

        let summary = PushGoSystemSummaryBuilder.summary(for: message)

        #expect(summary.kind == .message)
        #expect(summary.stableID == message.id.uuidString)
        #expect(summary.localMessageID == message.id)
        #expect(summary.privacy.isEncryptedOrSensitive)
        #expect(!summary.privacy.mayIndexBody)
        #expect(summary.bodyPreview == nil)
        #expect(!summary.searchableText.contains("do not index"))
        #expect(summary.accessibilityLabel.contains("Critical priority"))
    }

    @Test
    func messageSummaryTreatsEncryptedPayloadMarkersAsSensitive() {
        let message = PushMessage(
            messageId: "msg-encrypted-marker",
            title: "Encrypted Marker",
            body: "ciphertext body",
            rawPayload: ["encrypted": AnyCodable(true)]
        )

        let summary = PushGoSystemSummaryBuilder.summary(for: message)

        #expect(message.isEncrypted)
        #expect(summary.privacy.isEncryptedOrSensitive)
        #expect(summary.bodyPreview == nil)
    }

    @Test
    func messageSummaryAllowsSuccessfullyDecryptedContent() {
        let message = PushMessage(
            messageId: "msg-decrypted",
            title: "Decrypted alert",
            body: "safe decrypted summary",
            rawPayload: ["ciphertext": AnyCodable("abc")],
            status: .decrypted,
            decryptionState: .decryptOk
        )

        let summary = PushGoSystemSummaryBuilder.summary(for: message)

        #expect(message.isEncrypted)
        #expect(!summary.privacy.isEncryptedOrSensitive)
        #expect(summary.privacy.mayIndexBody)
        #expect(summary.bodyPreview?.contains("safe decrypted summary") == true)
    }

    @Test
    func liveActivityTokenRegistrationPayloadUsesGatewayContract() throws {
        let registration = PushGoLiveActivityTokenRegistration(
            activityKey: "event:evt-001",
            channelID: "ops",
            token: "abcd"
        )
        let data = try JSONEncoder().encode(registration)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(object["activity_key"] as? String == "event:evt-001")
        #expect(object["channel_id"] as? String == "ops")
        #expect(object["token"] as? String == "abcd")
        #expect(object["platform"] as? String == "ios")
        #expect(object["schema_version"] as? Int == 1)
    }

    @Test
    func liveActivityTokenRegistrationBuildsGatewayRequest() throws {
        let config = ServerConfig(
            baseURL: try #require(URL(string: "https://gateway.example.test/api/")),
            token: "  gateway-token  "
        )
        let request = try #require(PushGoLiveActivityTokenRegistrationService.makeRequest(
            config: config,
            path: "/v1/activity/register"
        ))

        #expect(request.url?.absoluteString == "https://gateway.example.test/api/v1/activity/register")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer gateway-token")
    }

    @Test
    func eventAndThingSummariesUseProjectionIdentity() {
        let event = EventProjection(
            id: "evt-001",
            title: "Disk pressure",
            summary: "Disk over 90 percent",
            status: "open",
            message: nil,
            severity: "high",
            tags: ["infra"],
            state: "open",
            thingId: "server-01",
            channelId: "ops",
            decryptionState: nil,
            imageURL: nil,
            imageURLs: [],
            attrsJSON: nil,
            updatedAt: Date(timeIntervalSince1970: 200),
            timeline: []
        )
        let thing = ThingProjection(
            id: "server-01",
            title: "Server 01",
            summary: "Primary database node",
            tags: ["db"],
            state: "warning",
            createdAt: nil,
            deletedAt: nil,
            channelId: "ops",
            decryptionState: nil,
            locationType: "rack",
            locationValue: "A1",
            externalIDs: ["host": "db01"],
            imageURL: nil,
            imageURLs: [],
            metadata: [:],
            attrsJSON: nil,
            attrsCount: 0,
            updatedAt: Date(timeIntervalSince1970: 300),
            relatedEvents: [],
            relatedMessages: [],
            relatedUpdates: []
        )

        let eventSummary = PushGoSystemSummaryBuilder.summary(for: event)
        let thingSummary = PushGoSystemSummaryBuilder.summary(for: thing)

        #expect(eventSummary.kind == .event)
        #expect(eventSummary.stableID == "evt-001")
        #expect(eventSummary.thingID == "server-01")
        #expect(eventSummary.searchableText.contains("Disk pressure"))
        #expect(thingSummary.kind == .thing)
        #expect(thingSummary.stableID == "server-01")
        #expect(thingSummary.searchableText.contains("db01"))
        #expect(thingSummary.searchableText.contains("A1"))
        #expect(thingSummary.accessibilityLabel.contains("Object"))
    }

    @Test
    func metadataSearchIndexesNonSensitiveMetadataByDefault() {
        let settings = SystemIntegrationSettings()
        let message = PushMessage(
            messageId: "msg-metadata",
            title: "Metadata message",
            body: "body",
            channel: "ops",
            rawPayload: [
                "metadata": AnyCodable([
                    "host": "db01",
                    "owner": String(repeating: "x", count: SystemIntegrationSettings.metadataValueMaxLength + 1),
                ]),
            ]
        )
        let thing = ThingProjection(
            id: "server-01",
            title: "Server 01",
            summary: "Primary database node",
            tags: [],
            state: "warning",
            createdAt: nil,
            deletedAt: nil,
            channelId: "ops",
            decryptionState: nil,
            locationType: "rack",
            locationValue: "A1",
            externalIDs: ["host": "db01"],
            imageURL: nil,
            imageURLs: [],
            metadata: ["cluster": "core"],
            attrsJSON: nil,
            attrsCount: 1,
            updatedAt: Date(timeIntervalSince1970: 300),
            relatedEvents: [],
            relatedMessages: [],
            relatedUpdates: []
        )

        let messageSummary = PushGoSystemSummaryBuilder.summary(for: message, settings: settings)
        let thingSummary = PushGoSystemSummaryBuilder.summary(for: thing, settings: settings)

        #expect(messageSummary.searchableText.contains("host db01"))
        #expect(!messageSummary.searchableText.contains(String(repeating: "x", count: SystemIntegrationSettings.metadataValueMaxLength + 1)))
        #expect(thingSummary.searchableText.contains("host db01"))
        #expect(thingSummary.searchableText.contains("rack"))
        #expect(thingSummary.searchableText.contains("A1"))
        #expect(thingSummary.searchableText.contains("cluster core"))
    }

    @Test
    func notificationPolicyUsesDefaultTimeSensitiveSetting() {
        let settings = SystemIntegrationSettings()

        #expect(PushGoNotificationActionPolicy.presentationPolicy(severity: "low", settings: settings).interruptionLevel == .passive)
        #expect(PushGoNotificationActionPolicy.presentationPolicy(severity: "normal", settings: settings).relevanceScore == 0.4)
        #expect(PushGoNotificationActionPolicy.presentationPolicy(severity: "high", settings: settings).interruptionLevel == .timeSensitive)
        #expect(PushGoNotificationActionPolicy.presentationPolicy(severity: "critical", settings: settings).relevanceScore == 0.95)
    }

    @Test
    func focusPolicyReducesNotificationInterruptionWithoutDisablingSystemSurfaces() {
        let settings = SystemIntegrationSettings()
        let priorityOnly = PushGoSystemSurfaceSnapshot.FocusState(
            mode: .priorityOnly,
            updatedAtEpochMs: 1_742_000_000_000
        )
        let quiet = PushGoSystemSurfaceSnapshot.FocusState(
            mode: .quiet,
            updatedAtEpochMs: 1_742_000_000_000
        )

        #expect(PushGoNotificationActionPolicy.presentationPolicy(
            severity: "normal",
            settings: settings,
            focusState: priorityOnly
        ).interruptionLevel == .passive)
        #expect(PushGoNotificationActionPolicy.presentationPolicy(
            severity: "high",
            settings: settings,
            focusState: priorityOnly
        ).interruptionLevel == .timeSensitive)
        #expect(PushGoNotificationActionPolicy.presentationPolicy(
            severity: "critical",
            settings: settings,
            focusState: quiet
        ).interruptionLevel == .active)
        #expect(settings.systemSearchEnabled)
        #expect(settings.indexEventsAndThings)
    }

    @Test
    func notificationCategoriesRegisterOpenRelatedEntityAction() {
        let categories = PushGoNotificationActionPolicy.categories()
        let messageCategory = categories.first {
            $0.identifier == AppConstants.notificationDefaultCategoryIdentifier
        }

        #expect(messageCategory?.actions.contains {
            $0.identifier == PushGoNotificationActionPolicy.openRelatedEntityActionIdentifier
        } == true)
    }

    @Test
    @MainActor
    func systemIntentRouterPersistsAndConsumesPendingTargets() throws {
        PushGoSystemIntentRouter.clearPendingOpenTarget()
        defer { PushGoSystemIntentRouter.clearPendingOpenTarget() }
        let target = try #require(PushGoSystemOpenTarget.event(identifier: "evt-pending", source: .appIntent))

        PushGoSystemIntentRouter.shared.setPendingTarget(target)
        let persisted = try #require(PushGoSystemIntentRouter.consumePendingOpenTarget())
        #expect(persisted == target)
        PushGoSystemIntentRouter.savePendingOpenTarget(target)
        let consumed = try #require(PushGoSystemIntentRouter.shared.consumePendingTarget())

        #expect(consumed == target)
        #expect(PushGoSystemIntentRouter.consumePendingOpenTarget() == nil)
    }

    @Test
    @MainActor
    func systemIntentRouterPersistsListTargets() throws {
        PushGoSystemIntentRouter.clearPendingOpenTarget()
        defer { PushGoSystemIntentRouter.clearPendingOpenTarget() }
        let target = PushGoSystemOpenTarget.list(kind: .message, source: .appIntent)

        PushGoSystemIntentRouter.shared.setPendingTarget(target)
        let consumed = try #require(PushGoSystemIntentRouter.shared.consumePendingTarget())

        #expect(consumed.kind == .message)
        #expect(consumed.destination == .list)
    }

    @Test
    func systemPendingActionStoreRoundTripsMarkLatestUnreadAction() {
        let defaults = UserDefaults(suiteName: "pushgo.pending-action.test.\(UUID().uuidString)")!

        PushGoSystemPendingActionStore.save(.markLatestUnreadMessageRead, defaults: defaults)
        #expect(PushGoSystemPendingActionStore.consume(defaults: defaults) == .markLatestUnreadMessageRead)
        #expect(PushGoSystemPendingActionStore.consume(defaults: defaults) == nil)
    }

    @Test
    func liveActivityScopeOnlyIncludesEventAndThingEventMessages() {
        let event = PushMessage(
            messageId: "evt-live-001",
            title: "Event",
            body: "body",
            rawPayload: [
                "entity_type": AnyCodable("event"),
                "event_id": AnyCodable("evt-live-001"),
            ]
        )
        let thingEvent = PushMessage(
            messageId: "thing-event-live-001",
            title: "Thing event",
            body: "body",
            rawPayload: [
                "entity_type": AnyCodable("message"),
                "event_id": AnyCodable("evt-live-thing-001"),
                "thing_id": AnyCodable("thing-live-001"),
            ]
        )
        let plainMessage = PushMessage(
            messageId: "msg-live-001",
            title: "Plain",
            body: "body",
            rawPayload: ["entity_type": AnyCodable("message")]
        )
        let thingUpdate = PushMessage(
            messageId: "thing-live-001",
            title: "Thing",
            body: "body",
            rawPayload: [
                "entity_type": AnyCodable("thing"),
                "thing_id": AnyCodable("thing-live-001"),
            ]
        )

        #expect(PushGoLiveActivityCoordinator.shouldUseLiveActivity(for: event))
        #expect(PushGoLiveActivityCoordinator.shouldUseLiveActivity(for: thingEvent))
        #expect(!PushGoLiveActivityCoordinator.shouldUseLiveActivity(for: plainMessage))
        #expect(!PushGoLiveActivityCoordinator.shouldUseLiveActivity(for: thingUpdate))
    }

    @Test
    func liveActivityScopeExcludesEncryptedOrDecryptFailedMessages() {
        let decryptFailedEvent = PushMessage(
            messageId: "evt-live-sensitive-001",
            title: "Sensitive Event",
            body: "ciphertext",
            rawPayload: [
                "entity_type": AnyCodable("event"),
                "event_id": AnyCodable("evt-live-sensitive-001"),
            ],
            decryptionState: .decryptFailed
        )
        let encryptedEvent = PushMessage(
            messageId: "evt-live-sensitive-002",
            title: "Encrypted Event",
            body: "ciphertext",
            rawPayload: [
                "entity_type": AnyCodable("event"),
                "event_id": AnyCodable("evt-live-sensitive-002"),
                "encrypted": AnyCodable(true),
            ]
        )

        #expect(!PushGoLiveActivityCoordinator.shouldUseLiveActivity(for: decryptFailedEvent))
        #expect(!PushGoLiveActivityCoordinator.shouldUseLiveActivity(for: encryptedEvent))
    }

    @Test
    func localDataStorePersistsSystemIntegrationSettings() async throws {
        await withIsolatedLocalDataStore { store, _ in
            let settings = SystemIntegrationSettings(
                systemSearchEnabled: false,
                includeMessageBodyInSearch: false,
                includeMetadataInSearch: true,
                indexEventsAndThings: false,
                timeSensitiveAlertsEnabled: true
            )

            await store.saveSystemIntegrationSettings(settings)
            let loaded = await store.loadSystemIntegrationSettings()

            #expect(loaded.systemSearchEnabled)
            #expect(loaded.includeMessageBodyInSearch)
            #expect(loaded.includeMetadataInSearch)
            #expect(loaded.indexEventsAndThings)
            #expect(loaded.timeSensitiveAlertsEnabled)
        }
    }

    @Test
    func localDataStoreIndexesAndDeletesMessagesInSystemSearch() async throws {
        let indexer = RecordingPushGoSpotlightIndexer()
        try await withIsolatedLocalDataStore(spotlightIndexer: indexer) { store, _ in
            let id = UUID(uuidString: "00000000-0000-0000-0000-000000000901")!
            let message = PushMessage(
                id: id,
                messageId: "msg-system-index-001",
                title: "System index message",
                body: "searchable body",
                channel: "ops",
                receivedAt: Date(timeIntervalSince1970: 900)
            )

            try await store.saveMessage(message)
            try await store.deleteMessage(id: id)
        }

        let operations = await indexer.operations
        #expect(operations.contains {
            $0.kind == .index
                && $0.identifiers.contains(PushGoSpotlightIdentifier(kind: .message, identifier: "00000000-0000-0000-0000-000000000901")!)
        })
        #expect(operations.contains {
            $0.kind == .delete
                && $0.identifiers.contains(PushGoSpotlightIdentifier(kind: .message, identifier: "00000000-0000-0000-0000-000000000901")!)
        })
    }

    @Test
    func localDataStoreIndexesEntityProjectionHeadsInSystemSearch() async throws {
        let indexer = RecordingPushGoSpotlightIndexer()
        try await withIsolatedLocalDataStore(spotlightIndexer: indexer) { store, _ in
            let event = PushMessage(
                messageId: "event-system-index-001",
                title: "System index event",
                body: "event summary",
                channel: "ops",
                receivedAt: Date(timeIntervalSince1970: 1_000),
                rawPayload: [
                    "entity_type": AnyCodable("event"),
                    "entity_id": AnyCodable("evt-system-index-001"),
                    "event_id": AnyCodable("evt-system-index-001"),
                    "event_state": AnyCodable("open"),
                    "severity": AnyCodable("high"),
                ]
            )
            let thing = PushMessage(
                messageId: "thing-system-index-001",
                title: "System index object",
                body: "object summary",
                channel: "ops",
                receivedAt: Date(timeIntervalSince1970: 1_001),
                rawPayload: [
                    "entity_type": AnyCodable("thing"),
                    "entity_id": AnyCodable("thing-system-index-001"),
                    "thing_id": AnyCodable("thing-system-index-001"),
                ]
            )

            try await store.saveEntityRecords([event, thing])
        }

        let indexedIdentifiers = await indexer.operations
            .filter { $0.kind == .index }
            .flatMap(\.identifiers)
        #expect(indexedIdentifiers.contains(PushGoSpotlightIdentifier(kind: .event, identifier: "evt-system-index-001")!))
        #expect(indexedIdentifiers.contains(PushGoSpotlightIdentifier(kind: .thing, identifier: "thing-system-index-001")!))
    }

    @Test
    func savingLegacyDisabledSystemSearchNormalizesAndRebuildsSpotlightIndex() async throws {
        let indexer = RecordingPushGoSpotlightIndexer()
        await withIsolatedLocalDataStore(spotlightIndexer: indexer) { store, _ in
            await store.saveSystemIntegrationSettings(SystemIntegrationSettings(systemSearchEnabled: false))
        }

        let operations = await indexer.operations
        #expect(operations.contains { $0.kind == .deleteAll })
        #expect(operations.contains { $0.kind == .index } || operations.count == 1)
    }

    @Test
    func systemSearchHealthCheckRebuildsIndexWhenNeeded() async throws {
        let indexer = RecordingPushGoSpotlightIndexer()

        try await withIsolatedLocalDataStore(spotlightIndexer: indexer) { store, appGroupIdentifier in
            let defaults = AppConstants.sharedUserDefaults(suiteName: appGroupIdentifier)
            defaults.removeObject(forKey: LocalDataStore.systemSearchHealthCheckDefaultsKey)
            defaults.removeObject(forKey: LocalDataStore.systemSurfaceSnapshotHealthCheckDefaultsKey)
            try await store.saveMessage(PushMessage(
                messageId: "msg-health-check",
                title: "Health check message",
                body: "body",
                receivedAt: Date(timeIntervalSince1970: 1_100)
            ))
            await store.ensureSystemSearchIndexHealthy(now: Date(timeIntervalSince1970: 10_000))
            await store.ensureSystemSearchIndexHealthy(now: Date(timeIntervalSince1970: 10_100))
        }

        let operations = await indexer.operations
        #expect(operations.filter { $0.kind == .deleteAll }.count == 1)
    }
}
