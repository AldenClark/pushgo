import Foundation
import Testing
@testable import PushGoAppleCore

struct PushGoSystemIntegrationTests {
    @Test
    func systemIntegrationSettingsDefaultsMatchPlan() {
        let settings = SystemIntegrationSettings()

        #expect(settings.systemSearchEnabled)
        #expect(settings.includeMessageBodyInSearch)
        #expect(!settings.includeMetadataInSearch)
        #expect(settings.indexEventsAndThings)
        #expect(!settings.timeSensitiveAlertsEnabled)
        #expect(settings.excludedChannelIDs.isEmpty)
    }

    @Test
    func systemIntegrationSettingsNormalizesExcludedChannels() {
        let settings = SystemIntegrationSettings(
            excludedChannelIDs: [" infra ", "", "ops"]
        )

        #expect(settings.excludesChannel("infra"))
        #expect(settings.excludesChannel(" ops "))
        #expect(!settings.excludesChannel("home"))
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
        #expect(!thingSummary.searchableText.contains("db01"))
        #expect(!thingSummary.searchableText.contains("A1"))
        #expect(thingSummary.accessibilityLabel.contains("Object"))
    }

    @Test
    func metadataSearchSettingControlsMessageAndThingMetadata() {
        let disabled = SystemIntegrationSettings(includeMetadataInSearch: false)
        let enabled = SystemIntegrationSettings(includeMetadataInSearch: true)
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

        let disabledMessage = PushGoSystemSummaryBuilder.summary(for: message, settings: disabled)
        let enabledMessage = PushGoSystemSummaryBuilder.summary(for: message, settings: enabled)
        let disabledThing = PushGoSystemSummaryBuilder.summary(for: thing, settings: disabled)
        let enabledThing = PushGoSystemSummaryBuilder.summary(for: thing, settings: enabled)

        #expect(!disabledMessage.searchableText.contains("db01"))
        #expect(enabledMessage.searchableText.contains("host db01"))
        #expect(!enabledMessage.searchableText.contains(String(repeating: "x", count: SystemIntegrationSettings.metadataValueMaxLength + 1)))
        #expect(!disabledThing.searchableText.contains("db01"))
        #expect(!disabledThing.searchableText.contains("A1"))
        #expect(!disabledThing.searchableText.contains("core"))
        #expect(enabledThing.searchableText.contains("host db01"))
        #expect(enabledThing.searchableText.contains("rack"))
        #expect(enabledThing.searchableText.contains("A1"))
        #expect(enabledThing.searchableText.contains("cluster core"))
    }

    @Test
    func userActivityRespectsDisabledSystemSearchSetting() {
        let settings = SystemIntegrationSettings(systemSearchEnabled: false)
        let message = PushMessage(
            messageId: "msg-activity-disabled",
            title: "Disabled activity message",
            body: "Activity body",
            receivedAt: Date(timeIntervalSince1970: 777)
        )
        let summary = PushGoSystemSummaryBuilder.summary(for: message, settings: settings)
        let activity = PushGoUserActivityBuilder.activity(
            for: summary,
            systemSearchEnabled: settings.systemSearchEnabled
        )

        #expect(!summary.privacy.mayIndexTitle)
        #expect(!activity.isEligibleForSearch)
    }

    @Test
    func notificationPolicyRespectsTimeSensitiveSetting() {
        let disabled = SystemIntegrationSettings(timeSensitiveAlertsEnabled: false)
        let enabled = SystemIntegrationSettings(timeSensitiveAlertsEnabled: true)

        #expect(PushGoNotificationActionPolicy.presentationPolicy(severity: "low", settings: enabled).interruptionLevel == .passive)
        #expect(PushGoNotificationActionPolicy.presentationPolicy(severity: "normal", settings: enabled).relevanceScore == 0.4)
        #expect(PushGoNotificationActionPolicy.presentationPolicy(severity: "high", settings: disabled).interruptionLevel == .active)
        #expect(PushGoNotificationActionPolicy.presentationPolicy(severity: "high", settings: enabled).interruptionLevel == .timeSensitive)
        #expect(PushGoNotificationActionPolicy.presentationPolicy(severity: "critical", settings: enabled).relevanceScore == 0.95)
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
    func localDataStorePersistsSystemIntegrationSettings() async throws {
        await withIsolatedLocalDataStore { store, _ in
            let settings = SystemIntegrationSettings(
                systemSearchEnabled: false,
                includeMessageBodyInSearch: false,
                includeMetadataInSearch: true,
                indexEventsAndThings: false,
                timeSensitiveAlertsEnabled: true,
                excludedChannelIDs: ["ops"]
            )

            await store.saveSystemIntegrationSettings(settings)
            let loaded = await store.loadSystemIntegrationSettings()

            #expect(!loaded.systemSearchEnabled)
            #expect(!loaded.includeMessageBodyInSearch)
            #expect(loaded.includeMetadataInSearch)
            #expect(!loaded.indexEventsAndThings)
            #expect(loaded.timeSensitiveAlertsEnabled)
            #expect(loaded.excludesChannel("ops"))
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
    func disablingSystemSearchClearsSpotlightIndex() async throws {
        let indexer = RecordingPushGoSpotlightIndexer()
        await withIsolatedLocalDataStore(spotlightIndexer: indexer) { store, _ in
            await store.saveSystemIntegrationSettings(SystemIntegrationSettings(systemSearchEnabled: false))
        }

        let operations = await indexer.operations
        #expect(operations.contains { $0.kind == .deleteAll })
    }

    @Test
    func clearingSystemSearchIndexOnlyKeepsSettingsEnabled() async throws {
        let indexer = RecordingPushGoSpotlightIndexer()
        await withIsolatedLocalDataStore(spotlightIndexer: indexer) { store, _ in
            await store.saveSystemIntegrationSettings(SystemIntegrationSettings(systemSearchEnabled: true))
            await store.clearSystemSearchIndexOnly()
            let loaded = await store.loadSystemIntegrationSettings()

            #expect(loaded.systemSearchEnabled)
        }

        let operations = await indexer.operations
        #expect(operations.contains { $0.kind == .deleteAll })
    }
}
