import Foundation
import GRDB
import Testing
@testable import PushGoAppleCore

struct LocalDataStoreTests {
    @Test
    func persistNotificationMessageUpdatesExistingRowForDuplicateRequest() async throws {
        try await withIsolatedLocalDataStore { store, _ in
            let first = makeMessage(
                messageId: "msg-duplicate-request-001",
                notificationRequestId: "req-duplicate-request-001",
                title: "Original title",
                body: "Original body"
            )
            let second = makeMessage(
                messageId: "msg-duplicate-request-002",
                notificationRequestId: "req-duplicate-request-001",
                title: "Updated title",
                body: "Updated body"
            )

            let initialOutcome = try await store.persistNotificationMessageIfNeeded(first)
            let duplicateOutcome = try await store.persistNotificationMessageIfNeeded(second)
            let stored = try await store.loadMessage(notificationRequestId: "req-duplicate-request-001")
            let messages = try await store.loadMessages()

            guard case let .persisted(initialStored) = initialOutcome else {
                Issue.record("Expected initial notification persistence to create a message row.")
                return
            }
            #expect(initialStored.title == "Original title")

            guard case let .duplicateRequest(updated) = duplicateOutcome else {
                Issue.record("Expected same notification request id to be treated as duplicateRequest.")
                return
            }
            #expect(updated.title == "Updated title")
            #expect(updated.body == "Updated body")
            #expect(stored?.title == "Updated title")
            #expect(stored?.body == "Updated body")
            #expect(messages.count == 1)
        }
    }

    @Test
    func persistNotificationMessageSkipsSecondWriteWhenOperationScopeAlreadyExists() async throws {
        try await withIsolatedLocalDataStore { store, _ in
            let first = makeMessage(
                messageId: "msg-op-scope-001",
                notificationRequestId: "req-op-scope-001",
                title: "First operation title",
                body: "First operation body",
                rawPayload: [
                    "op_id": "op-scope-001",
                    "entity_type": "message",
                    "entity_id": "entity-op-scope-001",
                    "channel_id": "ops",
                ]
            )
            let second = makeMessage(
                messageId: "msg-op-scope-002",
                notificationRequestId: "req-op-scope-002",
                title: "Second operation title",
                body: "Second operation body",
                rawPayload: [
                    "op_id": "op-scope-001",
                    "entity_type": "message",
                    "entity_id": "entity-op-scope-001",
                    "channel_id": "ops",
                ]
            )

            _ = try await store.persistNotificationMessageIfNeeded(first)
            let duplicateOutcome = try await store.persistNotificationMessageIfNeeded(second)
            let messages = try await store.loadMessages()
            let stored = try await store.loadMessage(notificationRequestId: "req-op-scope-001")

            guard case .duplicateMessage = duplicateOutcome else {
                Issue.record("Expected operation-ledger match to short-circuit as duplicateMessage.")
                return
            }
            #expect(messages.count == 1)
            #expect(stored?.title == "First operation title")
            #expect(stored?.body == "First operation body")
            #expect(try await store.loadMessage(notificationRequestId: "req-op-scope-002") == nil)
        }
    }

    @Test
    func dataPageVisibilityPersistsAcrossStoreReload() async throws {
        await withIsolatedAutomationStorage { _, appGroupIdentifier in
            let store = LocalDataStore(appGroupIdentifier: appGroupIdentifier)
            let defaultVisibility = await store.loadDataPageVisibility()
            #expect(defaultVisibility == .default)

            let savedVisibility = DataPageVisibilitySnapshot(
                messageEnabled: false,
                eventEnabled: true,
                thingEnabled: false
            )
            await store.saveDataPageVisibility(savedVisibility)

            let reloadedVisibility = await store.loadDataPageVisibility()
            #expect(reloadedVisibility == savedVisibility)
        }
    }

    @Test
    func watchModePersistsAcrossStoreReload() async throws {
        await withIsolatedAutomationStorage { _, appGroupIdentifier in
            let store = LocalDataStore(appGroupIdentifier: appGroupIdentifier)
            #expect(await store.loadWatchMode() == .mirror)

            await store.saveWatchMode(.standalone)

            let reloaded = LocalDataStore(appGroupIdentifier: appGroupIdentifier)
            #expect(await reloaded.loadWatchMode() == .standalone)
        }
    }

    @Test
    func watchModeControlStatePersistsAcrossStoreReload() async throws {
        await withIsolatedAutomationStorage { _, appGroupIdentifier in
            let store = LocalDataStore(appGroupIdentifier: appGroupIdentifier)
            let state = WatchModeControlPersistenceState(
                desiredMode: .standalone,
                effectiveMode: .mirror,
                standaloneReady: false,
                switchStatus: .switching,
                lastConfirmedControlGeneration: 9,
                lastObservedReportedGeneration: 7
            )

            await store.saveWatchModeControlState(state)

            let reloaded = LocalDataStore(appGroupIdentifier: appGroupIdentifier)
            let restored = await reloaded.loadWatchModeControlState()

            #expect(restored == state)
            #expect(restored.standaloneReady == false)
        }
    }

    @Test
    func watchPublicationStatePersistsAcrossStoreReload() async throws {
        await withIsolatedAutomationStorage { _, appGroupIdentifier in
            let store = LocalDataStore(appGroupIdentifier: appGroupIdentifier)
            let publicationState = WatchPublicationState(
                syncGenerations: WatchSyncGenerationState(
                    controlGeneration: 11,
                    mirrorSnapshotGeneration: 22,
                    standaloneProvisioningGeneration: 33,
                    mirrorActionAckGeneration: 44
                ),
                mirrorSnapshotContentDigest: "mirror-digest-22",
                standaloneProvisioningContentDigest: "standalone-digest-33"
            )

            await store.saveWatchPublicationState(publicationState)

            let reloaded = LocalDataStore(appGroupIdentifier: appGroupIdentifier)
            let restored = await reloaded.loadWatchPublicationState()

            #expect(restored == publicationState)
        }
    }

    @Test
    func watchPublicationDigestColumnsMigrateIntoExistingAppSettingsTable() async throws {
        try await withIsolatedAutomationStorage { root, appGroupIdentifier in
            let databaseURL = root
                .appendingPathComponent("app-groups", isDirectory: true)
                .appendingPathComponent(appGroupIdentifier, isDirectory: true)
                .appendingPathComponent("Database", isDirectory: true)
                .appendingPathComponent(AppConstants.databaseStoreFilename)
            try FileManager.default.createDirectory(
                at: databaseURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )

            let dbQueue = try DatabaseQueue(path: databaseURL.path)
            try await dbQueue.write { db in
                try db.execute(sql: """
                    CREATE TABLE app_settings (
                        id TEXT PRIMARY KEY NOT NULL,
                        manualKeyEncoding TEXT,
                        launchAtLoginEnabled INTEGER,
                        messagePageEnabled INTEGER,
                        eventPageEnabled INTEGER,
                        thingPageEnabled INTEGER,
                        pushTokenDataBase64 TEXT,
                        watchModeRawValue TEXT,
                        updatedAt REAL NOT NULL,
                        watchControlGeneration INTEGER,
                        watchMirrorSnapshotGeneration INTEGER,
                        watchStandaloneProvisioningGeneration INTEGER,
                        watchMirrorActionAckGeneration INTEGER,
                        watchProvisioningServerConfigDataBase64 TEXT,
                        watchProvisioningSchemaVersion INTEGER,
                        watchProvisioningGeneration INTEGER,
                        watchProvisioningContentDigest TEXT,
                        watchProvisioningAppliedAt REAL,
                        watchProvisioningModeRawValue TEXT,
                        watchProvisioningSourceControlGeneration INTEGER,
                        watchEffectiveModeRawValue TEXT,
                        watchModeSwitchStatusRawValue TEXT,
                        watchLastConfirmedControlGeneration INTEGER,
                        watchLastObservedReportedGeneration INTEGER,
                        watchStandaloneReady INTEGER
                    );
                    """)
                try db.execute(sql: """
                    CREATE TABLE grdb_migrations (
                        identifier TEXT NOT NULL PRIMARY KEY
                    );
                    """)
                for identifier in [
                    "v1_grdb_primary_store",
                    "v2_watch_sync_state_columns",
                    "v3_watch_provisioning_columns",
                    "v4_watch_mode_control_state_columns",
                    "v5_watch_mode_control_readiness_column",
                ] {
                    try db.execute(
                        sql: "INSERT INTO grdb_migrations(identifier) VALUES (?);",
                        arguments: [identifier]
                    )
                }
            }

            let store = LocalDataStore(appGroupIdentifier: appGroupIdentifier)
            let publicationState = WatchPublicationState(
                syncGenerations: WatchSyncGenerationState(
                    controlGeneration: 10,
                    mirrorSnapshotGeneration: 20,
                    standaloneProvisioningGeneration: 30,
                    mirrorActionAckGeneration: 40
                ),
                mirrorSnapshotContentDigest: "mirror-migrated-digest",
                standaloneProvisioningContentDigest: "standalone-migrated-digest"
            )

            await store.saveWatchPublicationState(publicationState)

            let restored = await store.loadWatchPublicationState()
            #expect(restored == publicationState)

            let migratedColumns = try await dbQueue.read { db in
                try Row.fetchAll(db, sql: "PRAGMA table_info(app_settings);").compactMap {
                    $0["name"] as String?
                }
            }
            #expect(migratedColumns.contains("watch_mirror_snapshot_content_digest"))
            #expect(migratedColumns.contains("watch_standalone_provisioning_content_digest"))
        }
    }

    @Test
    func channelSubscriptionWritesStayConsistentAcrossBackendAndCredentialReads() async throws {
        try await withIsolatedLocalDataStore { store, _ in
            _ = try await store.upsertChannelSubscription(
                gateway: "https://sandbox.pushgo.dev",
                channelId: "channel-001",
                displayName: "Ops",
                password: "123456789",
                lastSyncedAt: Date(timeIntervalSince1970: 1_742_000_000)
            )

            let subscriptions = try await store.loadChannelSubscriptions(
                gateway: "https://sandbox.pushgo.dev",
                includeDeleted: false
            )
            let credentials = try await store.activeChannelCredentials(gateway: "https://sandbox.pushgo.dev")

            #expect(subscriptions.map(\.channelId) == ["channel-001"])
            #expect(credentials.map(\.channelId) == ["channel-001"])
            #expect(credentials.first?.password == "123456789")
        }
    }

    @Test
    func watchProvisioningStatePersistsServerConfigAndMetadataInDatabase() async throws {
        try await withIsolatedAutomationStorage { _, appGroupIdentifier in
            let store = LocalDataStore(appGroupIdentifier: appGroupIdentifier)
            let config = ServerConfig(
                id: UUID(),
                name: "Sandbox",
                baseURL: URL(string: "https://sandbox.pushgo.dev")!,
                token: "gateway-token",
                notificationKeyMaterial: .init(
                    algorithm: .aesGcm,
                    keyData: Data(repeating: 7, count: 32),
                    ivBase64: nil,
                    updatedAt: Date(timeIntervalSince1970: 1_742_100_000)
                ),
                updatedAt: Date(timeIntervalSince1970: 1_742_100_000)
            )
            try await store.saveWatchProvisioningServerConfig(config)
            await store.saveWatchProvisioningState(
                WatchProvisioningState(
                    schemaVersion: WatchConnectivitySchema.currentVersion,
                    generation: 42,
                    contentDigest: "digest-42",
                    appliedAt: Date(timeIntervalSince1970: 1_742_100_100),
                    modeAtApply: .standalone,
                    sourceControlGeneration: 11
                )
            )

            let reloaded = LocalDataStore(appGroupIdentifier: appGroupIdentifier)
            let storedConfig = try await reloaded.loadWatchProvisioningServerConfig()
            let storedState = await reloaded.loadWatchProvisioningState()

            #expect(storedConfig?.normalizedBaseURL.absoluteString == "https://sandbox.pushgo.dev")
            #expect(storedConfig?.token == "gateway-token")
            #expect(storedConfig?.notificationKeyMaterial?.algorithm == .aesGcm)
            #expect(storedConfig?.notificationKeyMaterial?.keyData == Data(repeating: 7, count: 32))
            #expect(storedState?.generation == 42)
            #expect(storedState?.contentDigest == "digest-42")
            #expect(storedState?.modeAtApply == .standalone)
            #expect(storedState?.sourceControlGeneration == 11)
        }
    }

    @Test
    func applyWatchStandaloneProvisioningReplacesChannelsAndAdvancesProvisioningState() async throws {
        try await withIsolatedAutomationStorage { _, appGroupIdentifier in
            let store = LocalDataStore(appGroupIdentifier: appGroupIdentifier)
            _ = try await store.applyWatchStandaloneProvisioning(
                WatchStandaloneProvisioningSnapshot(
                    generation: 9,
                    mode: .standalone,
                    serverConfig: ServerConfig(
                        id: UUID(),
                        name: "Sandbox",
                        baseURL: URL(string: "https://sandbox.pushgo.dev")!,
                        token: "gateway-token",
                        notificationKeyMaterial: .init(
                            algorithm: .aesGcm,
                            keyData: Data(repeating: 3, count: 32),
                            ivBase64: nil,
                            updatedAt: Date(timeIntervalSince1970: 1_742_200_000)
                        ),
                        updatedAt: Date(timeIntervalSince1970: 1_742_200_000)
                    ),
                    notificationKeyMaterial: .init(
                        algorithm: .aesGcm,
                        keyData: Data(repeating: 3, count: 32),
                        ivBase64: nil,
                        updatedAt: Date(timeIntervalSince1970: 1_742_200_000)
                    ),
                    channels: [
                        WatchStandaloneChannelCredential(
                            gateway: "https://sandbox.pushgo.dev",
                            channelId: "channel-a",
                            displayName: "A",
                            password: "password-a",
                            updatedAt: Date(timeIntervalSince1970: 1_742_200_001)
                        ),
                    ],
                    contentDigest: "digest-9"
                ),
                sourceControlGeneration: 5
            )
            _ = try await store.applyWatchStandaloneProvisioning(
                WatchStandaloneProvisioningSnapshot(
                    generation: 10,
                    mode: .standalone,
                    serverConfig: ServerConfig(
                        id: UUID(),
                        name: "Sandbox",
                        baseURL: URL(string: "https://sandbox.pushgo.dev")!,
                        token: "gateway-token-2",
                        notificationKeyMaterial: .init(
                            algorithm: .aesGcm,
                            keyData: Data(repeating: 5, count: 32),
                            ivBase64: nil,
                            updatedAt: Date(timeIntervalSince1970: 1_742_200_100)
                        ),
                        updatedAt: Date(timeIntervalSince1970: 1_742_200_100)
                    ),
                    notificationKeyMaterial: .init(
                        algorithm: .aesGcm,
                        keyData: Data(repeating: 5, count: 32),
                        ivBase64: nil,
                        updatedAt: Date(timeIntervalSince1970: 1_742_200_100)
                    ),
                    channels: [
                        WatchStandaloneChannelCredential(
                            gateway: "https://sandbox.pushgo.dev",
                            channelId: "channel-b",
                            displayName: "B",
                            password: "password-b",
                            updatedAt: Date(timeIntervalSince1970: 1_742_200_101)
                        ),
                    ],
                    contentDigest: "digest-10"
                ),
                sourceControlGeneration: 6
            )

            let config = try await store.loadWatchProvisioningServerConfig()
            let state = await store.loadWatchProvisioningState()
            let subscriptions = try await store.loadChannelSubscriptions(
                gateway: "https://sandbox.pushgo.dev",
                includeDeleted: false
            )
            let credentials = try await store.activeChannelCredentials(gateway: "https://sandbox.pushgo.dev")

            #expect(config?.token == "gateway-token-2")
            #expect(state?.generation == 10)
            #expect(state?.contentDigest == "digest-10")
            #expect(state?.sourceControlGeneration == 6)
            #expect(subscriptions.map(\.channelId) == ["channel-b"])
            #expect(credentials.map(\.channelId) == ["channel-b"])
            #expect(credentials.first?.password == "password-b")
        }
    }

    @Test
    func watchMirrorSnapshotMergesIntoUnifiedLightTablesAndKeepsMirrorQueue() async throws {
        try await withIsolatedLocalDataStore { store, _ in
            try await store.upsertWatchLightPayload(
                .message(
                    WatchLightMessage(
                        messageId: "msg-existing",
                        title: "Existing title",
                        body: "Existing body",
                        imageURL: nil,
                        url: nil,
                        severity: "normal",
                        receivedAt: Date(timeIntervalSince1970: 10),
                        isRead: true,
                        entityType: "message",
                        entityId: "msg-existing",
                        notificationRequestId: "req-existing"
                    )
                )
            )
            try await store.upsertWatchLightPayload(
                .event(
                    WatchLightEvent(
                        eventId: "evt-existing",
                        title: "Existing event",
                        summary: nil,
                        state: "OPEN",
                        severity: "high",
                        imageURL: nil,
                        updatedAt: Date(timeIntervalSince1970: 11)
                    )
                )
            )
            try await store.upsertWatchLightPayload(
                .thing(
                    WatchLightThing(
                        thingId: "thing-existing",
                        title: "Existing thing",
                        summary: nil,
                        attrsJSON: nil,
                        imageURL: nil,
                        updatedAt: Date(timeIntervalSince1970: 12)
                    )
                )
            )
            try await store.enqueueWatchMirrorAction(
                WatchMirrorAction(
                    actionId: "action-1",
                    kind: .read,
                    messageId: "msg-queued",
                    issuedAt: Date()
                )
            )

            try await store.mergeWatchMirrorSnapshot(
                WatchMirrorSnapshot(
                    generation: 1,
                    mode: .mirror,
                    messages: [
                        WatchLightMessage(
                            messageId: "msg-1",
                            title: "Title 1",
                            body: "Body 1",
                            imageURL: nil,
                            url: nil,
                            severity: "high",
                            receivedAt: Date(timeIntervalSince1970: 1),
                            isRead: false,
                            entityType: "message",
                            entityId: "msg-1",
                            notificationRequestId: "req-1"
                        ),
                    ],
                    events: [
                        WatchLightEvent(
                            eventId: "evt-1",
                            title: "Event 1",
                            summary: "Summary",
                            state: "OPEN",
                            severity: "critical",
                            imageURL: nil,
                            updatedAt: Date(timeIntervalSince1970: 2)
                        ),
                    ],
                    things: [
                        WatchLightThing(
                            thingId: "thing-1",
                            title: "Thing 1",
                            summary: "Thing summary",
                            attrsJSON: "{\"role\":\"db\"}",
                            imageURL: nil,
                            updatedAt: Date(timeIntervalSince1970: 3)
                        ),
                    ],
                    exportedAt: Date(timeIntervalSince1970: 4),
                    contentDigest: "mirror-digest-1"
                )
            )

            #expect(Set(try await store.loadWatchLightMessages().map(\.messageId)) == ["msg-1", "msg-existing"])
            #expect(Set(try await store.loadWatchLightEvents().map(\.eventId)) == ["evt-1", "evt-existing"])
            #expect(Set(try await store.loadWatchLightThings().map(\.thingId)) == ["thing-1", "thing-existing"])
            #expect(try await store.loadWatchLightEvent(eventId: "evt-1")?.severity == "critical")
            #expect(try await store.loadWatchLightThing(thingId: "thing-1")?.attrsJSON == "{\"role\":\"db\"}")
            #expect(try await store.loadWatchMirrorActions().map(\.actionId) == ["action-1"])
        }
    }

    @Test
    func localDataStoreUsesCurrentDatabaseArtifactNameInAutomationContainer() async throws {
        try await withIsolatedAutomationStorage { _, appGroupIdentifier in
            let store = LocalDataStore(appGroupIdentifier: appGroupIdentifier)
            let probe = makeMessage(
                messageId: "msg-db-artifact-probe-001",
                notificationRequestId: "req-db-artifact-probe-001",
                title: "Database artifact probe",
                body: "Probe body"
            )
            _ = try await store.persistNotificationMessageIfNeeded(probe)

            let fileManager = FileManager.default
            let searchRoot = fileManager.temporaryDirectory
                .appendingPathComponent("pushgo-apple-core-tests", isDirectory: true)
            var databaseURL: URL?
            if let subpaths = try? fileManager.subpathsOfDirectory(atPath: searchRoot.path) {
                for subpath in subpaths {
                    guard subpath.hasSuffix("/Database/\(AppConstants.databaseStoreFilename)") else {
                        continue
                    }
                    if subpath.contains("/\(appGroupIdentifier)/") {
                        databaseURL = searchRoot.appendingPathComponent(subpath)
                        break
                    }
                }
            }

            #expect(databaseURL != nil)
            guard let databaseURL else { return }
            let databaseDirectory = databaseURL.deletingLastPathComponent()
            let legacyStoreURL = databaseDirectory.appendingPathComponent(
                "pushgo-\(AppConstants.databaseVersion).store"
            )

            #expect(databaseURL.pathExtension == "db")
            #expect(fileManager.fileExists(atPath: databaseURL.path))
            #expect(!fileManager.fileExists(atPath: legacyStoreURL.path))
        }
    }

    @Test
    func saveMessagesCanonicalizesBlankMessageIdToNonEmptyStableValue() async throws {
        try await withIsolatedLocalDataStore { store, _ in
            let blankMessageIdInput = makeMessage(
                messageId: "   ",
                notificationRequestId: "req-empty-message-id-001",
                title: "Blank message id",
                body: "Blank message id body"
            )

            try await store.saveMessages([blankMessageIdInput])

            let stored = try await store.loadMessage(notificationRequestId: "req-empty-message-id-001")
            #expect(stored != nil)
            #expect(stored?.messageId?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
            #expect(stored?.title == "Blank message id")
        }
    }

    @Test
    func saveMessagesBatchKeepsSingleRowWhenMessageIdRepeats() async throws {
        try await withIsolatedLocalDataStore { store, _ in
            let first = makeMessage(
                messageId: "msg-batch-duplicate-001",
                notificationRequestId: "req-batch-duplicate-001",
                title: "First duplicate candidate",
                body: "First duplicate body"
            )
            let second = makeMessage(
                messageId: "msg-batch-duplicate-001",
                notificationRequestId: "req-batch-duplicate-002",
                title: "Second duplicate candidate",
                body: "Second duplicate body"
            )

            try await store.saveMessagesBatch([first, second])

            let allMessages = try await store.loadMessages()
            let stored = try await store.loadMessage(messageId: "msg-batch-duplicate-001")

            #expect(allMessages.count == 1)
            #expect(stored?.title == "Second duplicate candidate")
            #expect(stored?.body == "Second duplicate body")
        }
    }

    @Test
    func saveEntityRecordsTreatsEventHeadWithinThingScopeAsTopLevelAndThingRelated() async throws {
        try await withIsolatedLocalDataStore { store, _ in
            let thingParent = makeMessage(
                messageId: "thing-event-head-001",
                notificationRequestId: "req-thing-event-head-001",
                title: "Thing parent",
                body: "Thing parent body",
                rawPayload: [
                    "entity_type": "thing",
                    "entity_id": "thing-event-head-001",
                    "thing_id": "thing-event-head-001",
                    "projection_destination": "thing_head",
                    "channel_id": "entity-projection-tests",
                ]
            )
            let eventHead = makeMessage(
                messageId: "evt-event-head-001",
                notificationRequestId: "req-event-head-001",
                title: "Thing scoped event head",
                body: "Thing scoped event head body",
                rawPayload: [
                    "entity_type": "event",
                    "entity_id": "evt-event-head-001",
                    "event_id": "evt-event-head-001",
                    "thing_id": "thing-event-head-001",
                    "projection_destination": "event_head",
                    "channel_id": "entity-projection-tests",
                ]
            )

            try await store.saveEntityRecords([thingParent, eventHead])

            let topLevelEvents = try await store.loadEventMessagesForProjection()
            let thingMessages = try await store.loadThingMessagesForProjection(thingId: "thing-event-head-001")

            #expect(topLevelEvents.count == 1)
            #expect(topLevelEvents.first?.eventId == "evt-event-head-001")
            #expect(thingMessages.contains(where: { $0.eventId == "evt-event-head-001" }))
        }
    }

    @Test
    func saveEntityRecordsKeepsThingSubEventsOutOfTopLevelEventProjection() async throws {
        try await withIsolatedLocalDataStore { store, _ in
            let thingParent = makeMessage(
                messageId: "thing-sub-001",
                notificationRequestId: "req-thing-sub-001",
                title: "Thing parent",
                body: "Thing parent body",
                rawPayload: [
                    "entity_type": "thing",
                    "entity_id": "thing-sub-001",
                    "thing_id": "thing-sub-001",
                    "projection_destination": "thing_head",
                    "channel_id": "entity-projection-tests",
                ]
            )
            let subEvent = makeMessage(
                messageId: "evt-thing-sub-001",
                notificationRequestId: "req-thing-sub-001",
                title: "Thing sub event",
                body: "Thing sub event body",
                rawPayload: [
                    "entity_type": "event",
                    "entity_id": "evt-thing-sub-001",
                    "event_id": "evt-thing-sub-001",
                    "thing_id": "thing-sub-001",
                    "projection_destination": "thing_sub_event",
                    "channel_id": "entity-projection-tests",
                ]
            )

            try await store.saveEntityRecords([thingParent, subEvent])

            let topLevelEvents = try await store.loadEventMessagesForProjection()
            let thingMessages = try await store.loadThingMessagesForProjection(thingId: "thing-sub-001")
            let subEventMessages = thingMessages.filter { $0.eventId == "evt-thing-sub-001" }

            #expect(topLevelEvents.isEmpty)
            #expect(subEventMessages.count == 1)
        }
    }

    @Test
    func saveEntityRecordsSkipsDuplicateEventHeadByStableMessageId() async throws {
        try await withIsolatedLocalDataStore { store, _ in
            let first = makeMessage(
                messageId: "evt-head-duplicate-001",
                notificationRequestId: "req-head-duplicate-001",
                title: "Original event head",
                body: "Original event body",
                rawPayload: [
                    "entity_type": "event",
                    "entity_id": "evt-head-duplicate-001",
                    "event_id": "evt-head-duplicate-001",
                    "projection_destination": "event_head",
                    "channel_id": "entity-projection-tests",
                ]
            )
            let duplicate = makeMessage(
                messageId: "evt-head-duplicate-001",
                notificationRequestId: "req-head-duplicate-002",
                title: "Duplicate event head",
                body: "Duplicate event body",
                rawPayload: [
                    "entity_type": "event",
                    "entity_id": "evt-head-duplicate-001",
                    "event_id": "evt-head-duplicate-001",
                    "projection_destination": "event_head",
                    "channel_id": "entity-projection-tests",
                ]
            )

            try await store.saveEntityRecords([first, duplicate])

            let topLevelEvents = try await store.loadEventMessagesForProjection()

            #expect(topLevelEvents.count == 1)
            #expect(topLevelEvents.first?.title == "Original event head")
            #expect(topLevelEvents.first?.body == "Original event body")
        }
    }

    @Test
    func saveEntityRecordsSkipsThingSubEventDuplicateWithinOperationScope() async throws {
        try await withIsolatedLocalDataStore { store, _ in
            let thingParent = makeMessage(
                messageId: "thing-scope-001",
                notificationRequestId: "req-thing-scope-parent-001",
                title: "Thing parent",
                body: "Thing parent body",
                rawPayload: [
                    "entity_type": "thing",
                    "entity_id": "thing-scope-001",
                    "thing_id": "thing-scope-001",
                    "projection_destination": "thing_head",
                    "channel_id": "entity-projection-tests",
                ]
            )
            let first = makeMessage(
                messageId: "evt-scope-thing-001",
                notificationRequestId: "req-scope-thing-001",
                title: "Scoped thing event",
                body: "First scoped event body",
                rawPayload: [
                    "entity_type": "event",
                    "entity_id": "evt-scope-thing-001",
                    "event_id": "evt-scope-thing-001",
                    "thing_id": "thing-scope-001",
                    "projection_destination": "thing_sub_event",
                    "op_id": "thing-scope-op-001",
                    "channel_id": "entity-projection-tests",
                ]
            )
            let duplicate = makeMessage(
                messageId: "evt-scope-thing-002",
                notificationRequestId: "req-scope-thing-002",
                title: "Scoped thing event duplicate",
                body: "Second scoped event body",
                rawPayload: [
                    "entity_type": "event",
                    "entity_id": "evt-scope-thing-001",
                    "event_id": "evt-scope-thing-001",
                    "thing_id": "thing-scope-001",
                    "projection_destination": "thing_sub_event",
                    "op_id": "thing-scope-op-001",
                    "channel_id": "entity-projection-tests",
                ]
            )

            try await store.saveEntityRecords([thingParent, first, duplicate])

            let topLevelEvents = try await store.loadEventMessagesForProjection()
            let thingMessages = try await store.loadThingMessagesForProjection(thingId: "thing-scope-001")
            let subEventMessages = thingMessages.filter { $0.eventId == "evt-scope-thing-001" }

            #expect(topLevelEvents.isEmpty)
            #expect(subEventMessages.count == 1)
            #expect(subEventMessages.first?.title == "Scoped thing event")
            #expect(subEventMessages.first?.body == "First scoped event body")
        }
    }

    private func makeMessage(
        messageId: String,
        notificationRequestId: String,
        title: String,
        body: String,
        rawPayload: [String: Any] = [:]
    ) -> PushMessage {
        var payload = rawPayload
        payload["message_id"] = messageId
        payload["_notificationRequestId"] = notificationRequestId
        return PushMessage(
            messageId: messageId,
            title: title,
            body: body,
            channel: (payload["channel_id"] as? String) ?? "default",
            receivedAt: Date(timeIntervalSince1970: 1_741_572_800),
            rawPayload: payload.reduce(into: [String: AnyCodable]()) { result, item in
                result[item.key] = AnyCodable(item.value)
            }
        )
    }
}
