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
                .appendingPathComponent("app-local", isDirectory: true)
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
    func loadGatewayURLsForChannelUsesHistoryAndActiveFilter() async throws {
        try await withIsolatedLocalDataStore { store, _ in
            let channelId = "ops-history-001"
            try await store.upsertChannelSubscription(
                gateway: "https://old.pushgo.dev",
                channelId: channelId,
                displayName: "Ops old",
                password: nil,
                lastSyncedAt: nil,
                updatedAt: Date(timeIntervalSince1970: 1_742_000_000),
                isDeleted: true,
                deletedAt: Date(timeIntervalSince1970: 1_742_000_010)
            )
            try await store.upsertChannelSubscription(
                gateway: "https://sandbox.pushgo.dev",
                channelId: channelId,
                displayName: "Ops",
                password: nil,
                lastSyncedAt: nil,
                updatedAt: Date(timeIntervalSince1970: 1_742_000_100),
                isDeleted: false,
                deletedAt: nil
            )

            let withDeleted = await store.loadGatewayURLsForChannel(
                channelId: channelId,
                includeDeleted: true
            )
            .map(\.absoluteString)
            let activeOnly = await store.loadGatewayURLsForChannel(
                channelId: channelId,
                includeDeleted: false
            )
            .map(\.absoluteString)

            #expect(withDeleted == ["https://sandbox.pushgo.dev", "https://old.pushgo.dev"])
            #expect(activeOnly == ["https://sandbox.pushgo.dev"])
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
                        decryptionState: nil,
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
                        decryptionState: nil,
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
                            decryptionState: nil,
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
                            decryptionState: nil,
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
    func localDataStoreMigratesLegacyVersionedDatabaseArtifactsToStableFilenames() async throws {
        try await withIsolatedAutomationStorage { root, appGroupIdentifier in
            let databaseDirectory = root
                .appendingPathComponent("app-local", isDirectory: true)
                .appendingPathComponent(appGroupIdentifier, isDirectory: true)
                .appendingPathComponent("Database", isDirectory: true)
            try FileManager.default.createDirectory(at: databaseDirectory, withIntermediateDirectories: true)

            let legacyMainURL = databaseDirectory.appendingPathComponent("pushgo-v9.db")
            let legacyIndexURL = databaseDirectory.appendingPathComponent("pushgo.index.v9.sqlite")

            let legacyMainQueue = try DatabaseQueue(path: legacyMainURL.path)
            try await legacyMainQueue.write { db in
                try db.execute(sql: """
                    CREATE TABLE IF NOT EXISTS migration_probe (
                        id TEXT PRIMARY KEY NOT NULL
                    );
                    INSERT OR REPLACE INTO migration_probe(id) VALUES ('legacy-main-ok');
                    """)
            }

            let legacyIndexQueue = try DatabaseQueue(path: legacyIndexURL.path)
            try await legacyIndexQueue.write { db in
                try db.execute(sql: """
                    CREATE VIRTUAL TABLE IF NOT EXISTS message_search USING fts5(
                        id UNINDEXED,
                        title,
                        body,
                        channel_id,
                        received_at UNINDEXED,
                        tokenize = 'unicode61'
                    );
                    """)
            }

            let store = LocalDataStore(appGroupIdentifier: appGroupIdentifier)
            _ = try await store.loadMessages()

            let currentMainURL = databaseDirectory.appendingPathComponent(AppConstants.databaseStoreFilename)
            let currentIndexURL = databaseDirectory.appendingPathComponent(AppConstants.messageIndexDatabaseFilename)

            #expect(FileManager.default.fileExists(atPath: currentMainURL.path))
            #expect(FileManager.default.fileExists(atPath: currentIndexURL.path))
            #expect(!FileManager.default.fileExists(atPath: legacyMainURL.path))
            #expect(!FileManager.default.fileExists(atPath: legacyIndexURL.path))

            let migratedQueue = try DatabaseQueue(path: currentMainURL.path)
            let probeCount = try await migratedQueue.read { db in
                try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM migration_probe WHERE id = 'legacy-main-ok';"
                ) ?? 0
            }
            #expect(probeCount == 1)
        }
    }

    @Test
    func localDataStoreMigratesWildcardLocalVersionedDatabaseArtifactsToStableFilenames() async throws {
        try await withIsolatedAutomationStorage { root, appGroupIdentifier in
            let databaseDirectory = root
                .appendingPathComponent("app-local", isDirectory: true)
                .appendingPathComponent(appGroupIdentifier, isDirectory: true)
                .appendingPathComponent("Database", isDirectory: true)
            try FileManager.default.createDirectory(at: databaseDirectory, withIntermediateDirectories: true)

            let legacyMainURL = databaseDirectory.appendingPathComponent("pushgo-v11.db")
            let legacyMainQueue = try DatabaseQueue(path: legacyMainURL.path)
            try await legacyMainQueue.write { db in
                try db.execute(sql: """
                    CREATE TABLE IF NOT EXISTS migration_probe (
                        id TEXT PRIMARY KEY NOT NULL
                    );
                    INSERT OR REPLACE INTO migration_probe(id) VALUES ('legacy-main-v11-ok');
                    """)
            }

            let legacyIndexURL = databaseDirectory.appendingPathComponent("pushgo.search.v11.sqlite")
            let legacyIndexQueue = try DatabaseQueue(path: legacyIndexURL.path)
            try await legacyIndexQueue.write { db in
                try db.execute(sql: """
                    CREATE TABLE IF NOT EXISTS migration_index_probe (
                        id TEXT PRIMARY KEY NOT NULL
                    );
                    INSERT OR REPLACE INTO migration_index_probe(id) VALUES ('legacy-index-v11-ok');
                    """)
            }

            let store = LocalDataStore(appGroupIdentifier: appGroupIdentifier)
            _ = try await store.loadMessages()

            let currentMainURL = databaseDirectory.appendingPathComponent(AppConstants.databaseStoreFilename)
            let currentIndexURL = databaseDirectory.appendingPathComponent(AppConstants.messageIndexDatabaseFilename)

            #expect(FileManager.default.fileExists(atPath: currentMainURL.path))
            #expect(FileManager.default.fileExists(atPath: currentIndexURL.path))
            #expect(!FileManager.default.fileExists(atPath: legacyMainURL.path))
            #expect(!FileManager.default.fileExists(atPath: legacyIndexURL.path))

            let migratedMainQueue = try DatabaseQueue(path: currentMainURL.path)
            let mainProbeCount = try await migratedMainQueue.read { db in
                try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM migration_probe WHERE id = 'legacy-main-v11-ok';"
                ) ?? 0
            }
            #expect(mainProbeCount == 1)

            let migratedIndexQueue = try DatabaseQueue(path: currentIndexURL.path)
            let indexProbeCount = try await migratedIndexQueue.read { db in
                try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM migration_index_probe WHERE id = 'legacy-index-v11-ok';"
                ) ?? 0
            }
            #expect(indexProbeCount == 1)
        }
    }

    @Test
    func localDataStoreMigratesSharedAppGroupDatabaseIntoAppLocalDirectory() async throws {
        try await withIsolatedAutomationStorage { root, appGroupIdentifier in
            let sharedDatabaseDirectory = root
                .appendingPathComponent("app-groups", isDirectory: true)
                .appendingPathComponent(appGroupIdentifier, isDirectory: true)
                .appendingPathComponent("Database", isDirectory: true)
            try FileManager.default.createDirectory(at: sharedDatabaseDirectory, withIntermediateDirectories: true)

            let sharedMainURL = sharedDatabaseDirectory.appendingPathComponent(AppConstants.databaseStoreFilename)
            let sharedQueue = try DatabaseQueue(path: sharedMainURL.path)
            try await sharedQueue.write { db in
                try db.execute(sql: """
                    CREATE TABLE IF NOT EXISTS migration_probe (
                        id TEXT PRIMARY KEY NOT NULL
                    );
                    INSERT OR REPLACE INTO migration_probe(id) VALUES ('shared-main-ok');
                    """)
            }

            let store = LocalDataStore(appGroupIdentifier: appGroupIdentifier)
            _ = try await store.loadMessages()

            let appLocalDatabaseDirectory = root
                .appendingPathComponent("app-local", isDirectory: true)
                .appendingPathComponent(appGroupIdentifier, isDirectory: true)
                .appendingPathComponent("Database", isDirectory: true)
            let appLocalMainURL = appLocalDatabaseDirectory.appendingPathComponent(AppConstants.databaseStoreFilename)

            #expect(FileManager.default.fileExists(atPath: appLocalMainURL.path))
            #expect(FileManager.default.fileExists(atPath: sharedMainURL.path))

            let migratedQueue = try DatabaseQueue(path: appLocalMainURL.path)
            let probeCount = try await migratedQueue.read { db in
                try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM migration_probe WHERE id = 'shared-main-ok';"
                ) ?? 0
            }
            #expect(probeCount == 1)
        }
    }

    @Test
    func localDataStoreMigratesVersion121SharedStableDatabaseAndIndexIntoAppLocalDirectory() async throws {
        try await withIsolatedAutomationStorage { root, appGroupIdentifier in
            let sharedDatabaseDirectory = root
                .appendingPathComponent("app-groups", isDirectory: true)
                .appendingPathComponent(appGroupIdentifier, isDirectory: true)
                .appendingPathComponent("Database", isDirectory: true)
            try FileManager.default.createDirectory(at: sharedDatabaseDirectory, withIntermediateDirectories: true)

            let sharedMainURL = sharedDatabaseDirectory.appendingPathComponent(AppConstants.databaseStoreFilename)
            let sharedMainQueue = try DatabaseQueue(path: sharedMainURL.path)
            try await sharedMainQueue.write { db in
                try db.execute(sql: """
                    CREATE TABLE IF NOT EXISTS migration_probe (
                        id TEXT PRIMARY KEY NOT NULL
                    );
                    INSERT OR REPLACE INTO migration_probe(id) VALUES ('version-121-shared-main');
                    """)
            }

            let sharedIndexURL = sharedDatabaseDirectory.appendingPathComponent(
                AppConstants.messageIndexDatabaseFilename
            )
            let sharedIndexQueue = try DatabaseQueue(path: sharedIndexURL.path)
            try await sharedIndexQueue.write { db in
                try db.execute(sql: """
                    CREATE TABLE IF NOT EXISTS migration_index_probe (
                        id TEXT PRIMARY KEY NOT NULL
                    );
                    INSERT OR REPLACE INTO migration_index_probe(id) VALUES ('version-121-shared-index');
                    """)
            }

            let store = LocalDataStore(appGroupIdentifier: appGroupIdentifier)
            _ = try await store.loadMessages()

            let appLocalDatabaseDirectory = root
                .appendingPathComponent("app-local", isDirectory: true)
                .appendingPathComponent(appGroupIdentifier, isDirectory: true)
                .appendingPathComponent("Database", isDirectory: true)
            let appLocalMainURL = appLocalDatabaseDirectory.appendingPathComponent(AppConstants.databaseStoreFilename)
            let appLocalIndexURL = appLocalDatabaseDirectory.appendingPathComponent(
                AppConstants.messageIndexDatabaseFilename
            )

            #expect(FileManager.default.fileExists(atPath: appLocalMainURL.path))
            #expect(FileManager.default.fileExists(atPath: appLocalIndexURL.path))
            #expect(FileManager.default.fileExists(atPath: sharedMainURL.path))
            #expect(FileManager.default.fileExists(atPath: sharedIndexURL.path))

            let migratedMainQueue = try DatabaseQueue(path: appLocalMainURL.path)
            let mainProbeCount = try await migratedMainQueue.read { db in
                try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM migration_probe WHERE id = 'version-121-shared-main';"
                ) ?? 0
            }
            #expect(mainProbeCount == 1)

            let migratedIndexQueue = try DatabaseQueue(path: appLocalIndexURL.path)
            let indexProbeCount = try await migratedIndexQueue.read { db in
                try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM migration_index_probe WHERE id = 'version-121-shared-index';"
                ) ?? 0
            }
            #expect(indexProbeCount == 1)
        }
    }

    @Test
    func localDataStoreMigratesHighestSharedVersionedDatabaseIntoAppLocalDirectory() async throws {
        try await withIsolatedAutomationStorage { root, appGroupIdentifier in
            let sharedDatabaseDirectory = root
                .appendingPathComponent("app-groups", isDirectory: true)
                .appendingPathComponent(appGroupIdentifier, isDirectory: true)
                .appendingPathComponent("Database", isDirectory: true)
            try FileManager.default.createDirectory(at: sharedDatabaseDirectory, withIntermediateDirectories: true)

            let legacyV10URL = sharedDatabaseDirectory.appendingPathComponent("pushgo-v10.db")
            let legacyV11URL = sharedDatabaseDirectory.appendingPathComponent("pushgo-v11.db")

            let v10Queue = try DatabaseQueue(path: legacyV10URL.path)
            try await v10Queue.write { db in
                try db.execute(sql: """
                    CREATE TABLE IF NOT EXISTS migration_probe (
                        id TEXT PRIMARY KEY NOT NULL
                    );
                    INSERT OR REPLACE INTO migration_probe(id) VALUES ('legacy-v10');
                    """)
            }

            let v11Queue = try DatabaseQueue(path: legacyV11URL.path)
            try await v11Queue.write { db in
                try db.execute(sql: """
                    CREATE TABLE IF NOT EXISTS migration_probe (
                        id TEXT PRIMARY KEY NOT NULL
                    );
                    INSERT OR REPLACE INTO migration_probe(id) VALUES ('legacy-v11');
                    """)
            }

            let store = LocalDataStore(appGroupIdentifier: appGroupIdentifier)
            _ = try await store.loadMessages()

            let appLocalDatabaseDirectory = root
                .appendingPathComponent("app-local", isDirectory: true)
                .appendingPathComponent(appGroupIdentifier, isDirectory: true)
                .appendingPathComponent("Database", isDirectory: true)
            let appLocalMainURL = appLocalDatabaseDirectory.appendingPathComponent(AppConstants.databaseStoreFilename)

            #expect(FileManager.default.fileExists(atPath: appLocalMainURL.path))

            let migratedQueue = try DatabaseQueue(path: appLocalMainURL.path)
            let v11Count = try await migratedQueue.read { db in
                try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM migration_probe WHERE id = 'legacy-v11';"
                ) ?? 0
            }
            let v10Count = try await migratedQueue.read { db in
                try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM migration_probe WHERE id = 'legacy-v10';"
                ) ?? 0
            }

            #expect(v11Count == 1)
            #expect(v10Count == 0)
        }
    }

    @Test
    func localDataStorePrefersSharedStableDatabaseOverLegacyVersionedDatabase() async throws {
        try await withIsolatedAutomationStorage { root, appGroupIdentifier in
            let sharedDatabaseDirectory = root
                .appendingPathComponent("app-groups", isDirectory: true)
                .appendingPathComponent(appGroupIdentifier, isDirectory: true)
                .appendingPathComponent("Database", isDirectory: true)
            try FileManager.default.createDirectory(at: sharedDatabaseDirectory, withIntermediateDirectories: true)

            let sharedStableURL = sharedDatabaseDirectory.appendingPathComponent(AppConstants.databaseStoreFilename)
            let sharedLegacyURL = sharedDatabaseDirectory.appendingPathComponent("pushgo-v99.db")

            let stableQueue = try DatabaseQueue(path: sharedStableURL.path)
            try await stableQueue.write { db in
                try db.execute(sql: """
                    CREATE TABLE IF NOT EXISTS migration_probe (
                        id TEXT PRIMARY KEY NOT NULL
                    );
                    INSERT OR REPLACE INTO migration_probe(id) VALUES ('shared-stable');
                    """)
            }

            let legacyQueue = try DatabaseQueue(path: sharedLegacyURL.path)
            try await legacyQueue.write { db in
                try db.execute(sql: """
                    CREATE TABLE IF NOT EXISTS migration_probe (
                        id TEXT PRIMARY KEY NOT NULL
                    );
                    INSERT OR REPLACE INTO migration_probe(id) VALUES ('shared-legacy');
                    """)
            }

            let store = LocalDataStore(appGroupIdentifier: appGroupIdentifier)
            _ = try await store.loadMessages()

            let appLocalDatabaseDirectory = root
                .appendingPathComponent("app-local", isDirectory: true)
                .appendingPathComponent(appGroupIdentifier, isDirectory: true)
                .appendingPathComponent("Database", isDirectory: true)
            let appLocalMainURL = appLocalDatabaseDirectory.appendingPathComponent(AppConstants.databaseStoreFilename)

            let migratedQueue = try DatabaseQueue(path: appLocalMainURL.path)
            let stableCount = try await migratedQueue.read { db in
                try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM migration_probe WHERE id = 'shared-stable';"
                ) ?? 0
            }
            let legacyCount = try await migratedQueue.read { db in
                try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM migration_probe WHERE id = 'shared-legacy';"
                ) ?? 0
            }

            #expect(stableCount == 1)
            #expect(legacyCount == 0)
        }
    }

    @Test
    func localDataStoreMigratesSharedLegacyIndexDatabaseFromWildcardVersion() async throws {
        try await withIsolatedAutomationStorage { root, appGroupIdentifier in
            let sharedDatabaseDirectory = root
                .appendingPathComponent("app-groups", isDirectory: true)
                .appendingPathComponent(appGroupIdentifier, isDirectory: true)
                .appendingPathComponent("Database", isDirectory: true)
            try FileManager.default.createDirectory(at: sharedDatabaseDirectory, withIntermediateDirectories: true)

            let sharedMainURL = sharedDatabaseDirectory.appendingPathComponent(AppConstants.databaseStoreFilename)
            let sharedMainQueue = try DatabaseQueue(path: sharedMainURL.path)
            try await sharedMainQueue.write { db in
                try db.execute(sql: """
                    CREATE TABLE IF NOT EXISTS migration_probe (
                        id TEXT PRIMARY KEY NOT NULL
                    );
                    INSERT OR REPLACE INTO migration_probe(id) VALUES ('shared-main-for-index');
                    """)
            }

            let sharedLegacyIndexURL = sharedDatabaseDirectory.appendingPathComponent("pushgo.search.v12.sqlite")
            let legacyIndexQueue = try DatabaseQueue(path: sharedLegacyIndexURL.path)
            try await legacyIndexQueue.write { db in
                try db.execute(sql: """
                    CREATE TABLE IF NOT EXISTS migration_index_probe (
                        id TEXT PRIMARY KEY NOT NULL
                    );
                    INSERT OR REPLACE INTO migration_index_probe(id) VALUES ('index-v12');
                    """)
            }

            let store = LocalDataStore(appGroupIdentifier: appGroupIdentifier)
            _ = try await store.loadMessages()

            let appLocalDatabaseDirectory = root
                .appendingPathComponent("app-local", isDirectory: true)
                .appendingPathComponent(appGroupIdentifier, isDirectory: true)
                .appendingPathComponent("Database", isDirectory: true)
            let appLocalIndexURL = appLocalDatabaseDirectory.appendingPathComponent(
                AppConstants.messageIndexDatabaseFilename
            )

            #expect(FileManager.default.fileExists(atPath: appLocalIndexURL.path))

            let migratedIndexQueue = try DatabaseQueue(path: appLocalIndexURL.path)
            let probeCount = try await migratedIndexQueue.read { db in
                try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM migration_index_probe WHERE id = 'index-v12';"
                ) ?? 0
            }
            #expect(probeCount == 1)
        }
    }

    @Test
    func localDataStoreMigratesSharedLegacyMetadataIndexDatabaseFromWildcardVersion() async throws {
        try await withIsolatedAutomationStorage { root, appGroupIdentifier in
            let sharedDatabaseDirectory = root
                .appendingPathComponent("app-groups", isDirectory: true)
                .appendingPathComponent(appGroupIdentifier, isDirectory: true)
                .appendingPathComponent("Database", isDirectory: true)
            try FileManager.default.createDirectory(at: sharedDatabaseDirectory, withIntermediateDirectories: true)

            let sharedMainURL = sharedDatabaseDirectory.appendingPathComponent(AppConstants.databaseStoreFilename)
            let sharedMainQueue = try DatabaseQueue(path: sharedMainURL.path)
            try await sharedMainQueue.write { db in
                try db.execute(sql: """
                    CREATE TABLE IF NOT EXISTS migration_probe (
                        id TEXT PRIMARY KEY NOT NULL
                    );
                    INSERT OR REPLACE INTO migration_probe(id) VALUES ('shared-main-for-metadata-index');
                    """)
            }

            let sharedLegacyIndexURL = sharedDatabaseDirectory.appendingPathComponent("pushgo.metadata.v13.sqlite")
            let legacyIndexQueue = try DatabaseQueue(path: sharedLegacyIndexURL.path)
            try await legacyIndexQueue.write { db in
                try db.execute(sql: """
                    CREATE TABLE IF NOT EXISTS migration_index_probe (
                        id TEXT PRIMARY KEY NOT NULL
                    );
                    INSERT OR REPLACE INTO migration_index_probe(id) VALUES ('metadata-index-v13');
                    """)
            }

            let store = LocalDataStore(appGroupIdentifier: appGroupIdentifier)
            _ = try await store.loadMessages()

            let appLocalDatabaseDirectory = root
                .appendingPathComponent("app-local", isDirectory: true)
                .appendingPathComponent(appGroupIdentifier, isDirectory: true)
                .appendingPathComponent("Database", isDirectory: true)
            let appLocalIndexURL = appLocalDatabaseDirectory.appendingPathComponent(
                AppConstants.messageIndexDatabaseFilename
            )

            #expect(FileManager.default.fileExists(atPath: appLocalIndexURL.path))

            let migratedIndexQueue = try DatabaseQueue(path: appLocalIndexURL.path)
            let probeCount = try await migratedIndexQueue.read { db in
                try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM migration_index_probe WHERE id = 'metadata-index-v13';"
                ) ?? 0
            }
            #expect(probeCount == 1)
        }
    }

    @Test
    func localDataStorePrefersSharedStableIndexDatabaseOverLegacyVersionedIndexDatabase() async throws {
        try await withIsolatedAutomationStorage { root, appGroupIdentifier in
            let sharedDatabaseDirectory = root
                .appendingPathComponent("app-groups", isDirectory: true)
                .appendingPathComponent(appGroupIdentifier, isDirectory: true)
                .appendingPathComponent("Database", isDirectory: true)
            try FileManager.default.createDirectory(at: sharedDatabaseDirectory, withIntermediateDirectories: true)

            let sharedMainURL = sharedDatabaseDirectory.appendingPathComponent(AppConstants.databaseStoreFilename)
            let sharedMainQueue = try DatabaseQueue(path: sharedMainURL.path)
            try await sharedMainQueue.write { db in
                try db.execute(sql: """
                    CREATE TABLE IF NOT EXISTS migration_probe (
                        id TEXT PRIMARY KEY NOT NULL
                    );
                    INSERT OR REPLACE INTO migration_probe(id) VALUES ('shared-main-for-stable-index');
                    """)
            }

            let stableIndexURL = sharedDatabaseDirectory.appendingPathComponent(
                AppConstants.messageIndexDatabaseFilename
            )
            let stableIndexQueue = try DatabaseQueue(path: stableIndexURL.path)
            try await stableIndexQueue.write { db in
                try db.execute(sql: """
                    CREATE TABLE IF NOT EXISTS migration_index_probe (
                        id TEXT PRIMARY KEY NOT NULL
                    );
                    INSERT OR REPLACE INTO migration_index_probe(id) VALUES ('shared-index-stable');
                    """)
            }

            let legacyIndexURL = sharedDatabaseDirectory.appendingPathComponent("pushgo.search.v88.sqlite")
            let legacyIndexQueue = try DatabaseQueue(path: legacyIndexURL.path)
            try await legacyIndexQueue.write { db in
                try db.execute(sql: """
                    CREATE TABLE IF NOT EXISTS migration_index_probe (
                        id TEXT PRIMARY KEY NOT NULL
                    );
                    INSERT OR REPLACE INTO migration_index_probe(id) VALUES ('shared-index-legacy');
                    """)
            }

            let store = LocalDataStore(appGroupIdentifier: appGroupIdentifier)
            _ = try await store.loadMessages()

            let appLocalDatabaseDirectory = root
                .appendingPathComponent("app-local", isDirectory: true)
                .appendingPathComponent(appGroupIdentifier, isDirectory: true)
                .appendingPathComponent("Database", isDirectory: true)
            let appLocalIndexURL = appLocalDatabaseDirectory.appendingPathComponent(
                AppConstants.messageIndexDatabaseFilename
            )

            let migratedIndexQueue = try DatabaseQueue(path: appLocalIndexURL.path)
            let stableCount = try await migratedIndexQueue.read { db in
                try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM migration_index_probe WHERE id = 'shared-index-stable';"
                ) ?? 0
            }
            let legacyCount = try await migratedIndexQueue.read { db in
                try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM migration_index_probe WHERE id = 'shared-index-legacy';"
                ) ?? 0
            }

            #expect(stableCount == 1)
            #expect(legacyCount == 0)
        }
    }

    @Test
    func appLocalDatabaseMigrationCopiesSQLiteSidecarFilesFromSharedDatabaseDirectory() async throws {
        try await withIsolatedAutomationStorage { root, appGroupIdentifier in
            let sharedDatabaseDirectory = root
                .appendingPathComponent("app-groups", isDirectory: true)
                .appendingPathComponent(appGroupIdentifier, isDirectory: true)
                .appendingPathComponent("Database", isDirectory: true)
            try FileManager.default.createDirectory(at: sharedDatabaseDirectory, withIntermediateDirectories: true)

            let sharedMainURL = sharedDatabaseDirectory.appendingPathComponent(AppConstants.databaseStoreFilename)
            let sharedQueue = try DatabaseQueue(path: sharedMainURL.path)
            try await sharedQueue.write { db in
                try db.execute(sql: """
                    CREATE TABLE IF NOT EXISTS migration_probe (
                        id TEXT PRIMARY KEY NOT NULL
                    );
                    INSERT OR REPLACE INTO migration_probe(id) VALUES ('shared-main-with-sidecars');
                    """)
            }
            let sharedWalURL = URL(fileURLWithPath: sharedMainURL.path + "-wal")
            let sharedShmURL = URL(fileURLWithPath: sharedMainURL.path + "-shm")
            FileManager.default.createFile(
                atPath: sharedWalURL.path,
                contents: Data("wal-sidecar".utf8)
            )
            FileManager.default.createFile(
                atPath: sharedShmURL.path,
                contents: Data("shm-sidecar".utf8)
            )

            let appLocalDirectory = try AppConstants.appLocalDatabaseDirectory(
                fileManager: .default,
                appGroupIdentifier: appGroupIdentifier
            )
            let appLocalMainURL = appLocalDirectory.appendingPathComponent(AppConstants.databaseStoreFilename)
            let appLocalWalURL = URL(fileURLWithPath: appLocalMainURL.path + "-wal")
            let appLocalShmURL = URL(fileURLWithPath: appLocalMainURL.path + "-shm")

            #expect(FileManager.default.fileExists(atPath: appLocalMainURL.path))
            #expect(FileManager.default.fileExists(atPath: appLocalWalURL.path))
            #expect(FileManager.default.fileExists(atPath: appLocalShmURL.path))
            #expect((try? Data(contentsOf: appLocalWalURL)) == Data("wal-sidecar".utf8))
            #expect((try? Data(contentsOf: appLocalShmURL)) == Data("shm-sidecar".utf8))
        }
    }

    @Test
    func localDataStoreRetriesAfterTransientBootstrapFailure() async throws {
        try await withIsolatedAutomationStorage { root, appGroupIdentifier in
            let appGroupRoot = root
                .appendingPathComponent("app-local", isDirectory: true)
                .appendingPathComponent(appGroupIdentifier, isDirectory: true)
            try FileManager.default.createDirectory(at: appGroupRoot, withIntermediateDirectories: true)

            let databasePathBlocker = appGroupRoot.appendingPathComponent("Database", isDirectory: false)
            let blockerWritten = FileManager.default.createFile(
                atPath: databasePathBlocker.path,
                contents: Data("blocker".utf8)
            )
            #expect(blockerWritten)

            let firstAttempt = LocalDataStore(appGroupIdentifier: appGroupIdentifier)
            switch firstAttempt.storageState.mode {
            case .persistent:
                Issue.record("Expected first attempt to fail while Database path is blocked by a file.")
            case .unavailable:
                break
            }

            try FileManager.default.removeItem(at: databasePathBlocker)

            let recoveredStore = LocalDataStore(appGroupIdentifier: appGroupIdentifier)
            switch recoveredStore.storageState.mode {
            case .persistent:
                break
            case .unavailable:
                Issue.record("Expected LocalDataStore to recover after transient bootstrap blocker is removed.")
                return
            }

            let probe = makeMessage(
                messageId: "msg-bootstrap-retry-001",
                notificationRequestId: "req-bootstrap-retry-001",
                title: "bootstrap retry title",
                body: "bootstrap retry body"
            )
            let outcome = try await recoveredStore.persistNotificationMessageIfNeeded(probe)
            guard case .persisted = outcome else {
                Issue.record("Recovered LocalDataStore should persist payloads after retry.")
                return
            }
            let persisted = try await recoveredStore.loadMessage(notificationRequestId: "req-bootstrap-retry-001")
            #expect(persisted != nil)
        }
    }

    @Test
    func localDataStoreMigratesLegacyArtifactsWhenStableFilenameExistsAsZeroBytePlaceholder() async throws {
        try await withIsolatedAutomationStorage { root, appGroupIdentifier in
            let databaseDirectory = root
                .appendingPathComponent("app-local", isDirectory: true)
                .appendingPathComponent(appGroupIdentifier, isDirectory: true)
                .appendingPathComponent("Database", isDirectory: true)
            try FileManager.default.createDirectory(at: databaseDirectory, withIntermediateDirectories: true)

            let placeholderURL = databaseDirectory.appendingPathComponent(AppConstants.databaseStoreFilename)
            FileManager.default.createFile(atPath: placeholderURL.path, contents: Data())

            let legacyMainURL = databaseDirectory.appendingPathComponent("pushgo-v9.db")
            let legacyMainQueue = try DatabaseQueue(path: legacyMainURL.path)
            try await legacyMainQueue.write { db in
                try db.execute(sql: """
                    CREATE TABLE IF NOT EXISTS migration_probe (
                        id TEXT PRIMARY KEY NOT NULL
                    );
                    INSERT OR REPLACE INTO migration_probe(id) VALUES ('legacy-overwrite-zero-byte-ok');
                    """)
            }

            let store = LocalDataStore(appGroupIdentifier: appGroupIdentifier)
            _ = try await store.loadMessages()

            let migratedQueue = try DatabaseQueue(path: placeholderURL.path)
            let probeCount = try await migratedQueue.read { db in
                try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM migration_probe WHERE id = 'legacy-overwrite-zero-byte-ok';"
                ) ?? 0
            }
            #expect(probeCount == 1)
            #expect(!FileManager.default.fileExists(atPath: legacyMainURL.path))
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

    @Test
    func channelScopedCleanupRemovesMessagesEventsAndThings() async throws {
        try await withIsolatedLocalDataStore { store, _ in
            let targetChannel = "channel-cleanup-target"
            let keepChannel = "channel-cleanup-keep"

            let targetMessage = makeMessage(
                messageId: "msg-cleanup-target-001",
                notificationRequestId: "req-cleanup-target-001",
                title: "Target message",
                body: "Target message body",
                rawPayload: [
                    "channel_id": targetChannel,
                    "entity_type": "message",
                    "entity_id": "msg-cleanup-target-001",
                ]
            )
            let keepMessage = makeMessage(
                messageId: "msg-cleanup-keep-001",
                notificationRequestId: "req-cleanup-keep-001",
                title: "Keep message",
                body: "Keep message body",
                rawPayload: [
                    "channel_id": keepChannel,
                    "entity_type": "message",
                    "entity_id": "msg-cleanup-keep-001",
                ]
            )
            try await store.saveMessages([targetMessage, keepMessage])

            let targetEvent = makeMessage(
                messageId: "evt-cleanup-target-001",
                notificationRequestId: "req-evt-cleanup-target-001",
                title: "Target event",
                body: "Target event body",
                rawPayload: [
                    "entity_type": "event",
                    "entity_id": "evt-cleanup-target-001",
                    "event_id": "evt-cleanup-target-001",
                    "projection_destination": "event_head",
                    "channel_id": targetChannel,
                ]
            )
            let targetThing = makeMessage(
                messageId: "thing-cleanup-target-001",
                notificationRequestId: "req-thing-cleanup-target-001",
                title: "Target thing",
                body: "Target thing body",
                rawPayload: [
                    "entity_type": "thing",
                    "entity_id": "thing-cleanup-target-001",
                    "thing_id": "thing-cleanup-target-001",
                    "projection_destination": "thing_head",
                    "channel_id": targetChannel,
                ]
            )
            let keepEvent = makeMessage(
                messageId: "evt-cleanup-keep-001",
                notificationRequestId: "req-evt-cleanup-keep-001",
                title: "Keep event",
                body: "Keep event body",
                rawPayload: [
                    "entity_type": "event",
                    "entity_id": "evt-cleanup-keep-001",
                    "event_id": "evt-cleanup-keep-001",
                    "projection_destination": "event_head",
                    "channel_id": keepChannel,
                ]
            )
            let keepThing = makeMessage(
                messageId: "thing-cleanup-keep-001",
                notificationRequestId: "req-thing-cleanup-keep-001",
                title: "Keep thing",
                body: "Keep thing body",
                rawPayload: [
                    "entity_type": "thing",
                    "entity_id": "thing-cleanup-keep-001",
                    "thing_id": "thing-cleanup-keep-001",
                    "projection_destination": "thing_head",
                    "channel_id": keepChannel,
                ]
            )
            try await store.saveEntityRecords([targetEvent, targetThing, keepEvent, keepThing])

            let removedMessages = try await store.deleteMessages(channel: targetChannel, readState: nil)
            let removedEvents = try await store.deleteEventRecords(channel: targetChannel)
            let removedThings = try await store.deleteThingRecords(channel: targetChannel)

            #expect(removedMessages > 0)
            #expect(removedEvents > 0)
            #expect(removedThings > 0)

            let remainingTargetMessages = try await store.loadMessages(filter: .all, channel: targetChannel)
            let remainingTargetEvents = try await store
                .loadEventMessagesForProjection()
                .filter { $0.channel == targetChannel }
            let remainingTargetThings = try await store
                .loadThingMessagesForProjection()
                .filter { $0.channel == targetChannel }

            #expect(remainingTargetMessages.isEmpty)
            #expect(remainingTargetEvents.isEmpty)
            #expect(remainingTargetThings.isEmpty)

            let remainingKeepMessages = try await store.loadMessages(filter: .all, channel: keepChannel)
            let remainingKeepEvents = try await store
                .loadEventMessagesForProjection()
                .filter { $0.channel == keepChannel }
            let remainingKeepThings = try await store
                .loadThingMessagesForProjection()
                .filter { $0.channel == keepChannel }

            #expect(remainingKeepMessages.count == 1)
            #expect(remainingKeepEvents.count == 1)
            #expect(remainingKeepThings.count == 1)
        }
    }

    @Test
    func channelScopedCleanupMatchesCanonicalChannelIdSemantics() async throws {
        try await withIsolatedLocalDataStore { store, _ in
            let canonicalChannel = "01ABCDEF23456789GHJKMNPQRS"
            let variantChannel = "01ab-cdef-2345-6789-ghjk-mnpqrs"

            let message = makeMessage(
                messageId: "msg-cleanup-canonical-001",
                notificationRequestId: "req-cleanup-canonical-001",
                title: "Canonical target message",
                body: "Canonical target message body",
                rawPayload: [
                    "channel_id": variantChannel,
                    "entity_type": "message",
                    "entity_id": "msg-cleanup-canonical-001",
                ]
            )
            try await store.saveMessages([message])

            let event = makeMessage(
                messageId: "evt-cleanup-canonical-001",
                notificationRequestId: "req-evt-cleanup-canonical-001",
                title: "Canonical target event",
                body: "Canonical target event body",
                rawPayload: [
                    "entity_type": "event",
                    "entity_id": "evt-cleanup-canonical-001",
                    "event_id": "evt-cleanup-canonical-001",
                    "projection_destination": "event_head",
                    "channel_id": variantChannel,
                ]
            )
            let thing = makeMessage(
                messageId: "thing-cleanup-canonical-001",
                notificationRequestId: "req-thing-cleanup-canonical-001",
                title: "Canonical target thing",
                body: "Canonical target thing body",
                rawPayload: [
                    "entity_type": "thing",
                    "entity_id": "thing-cleanup-canonical-001",
                    "thing_id": "thing-cleanup-canonical-001",
                    "projection_destination": "thing_head",
                    "channel_id": variantChannel,
                ]
            )
            try await store.saveEntityRecords([event, thing])

            let removedMessages = try await store.deleteMessages(channel: canonicalChannel, readState: nil)
            let removedEvents = try await store.deleteEventRecords(channel: canonicalChannel)
            let removedThings = try await store.deleteThingRecords(channel: canonicalChannel)

            #expect(removedMessages == 1)
            #expect(removedEvents == 1)
            #expect(removedThings == 1)
            #expect(try await store.loadMessages(filter: .all, channel: canonicalChannel).isEmpty)
            #expect(try await store.loadEventMessagesForProjection().isEmpty)
            #expect(try await store.loadThingMessagesForProjection().isEmpty)
        }
    }

    @Test
    func batchDeleteEventRecordsByIdsRemovesOnlyTargetEvents() async throws {
        try await withIsolatedLocalDataStore { store, _ in
            let targetTopLevelEventId = "evt-batch-delete-target-top-001"
            let targetThingScopedEventId = "evt-batch-delete-target-thing-001"
            let keepEventId = "evt-batch-delete-keep-001"
            let channel = "batch-delete-events"

            let thingParent = makeMessage(
                messageId: "thing-batch-delete-parent-001",
                notificationRequestId: "req-thing-batch-delete-parent-001",
                title: "Thing parent",
                body: "Thing parent body",
                rawPayload: [
                    "entity_type": "thing",
                    "entity_id": "thing-batch-delete-parent-001",
                    "thing_id": "thing-batch-delete-parent-001",
                    "projection_destination": "thing_head",
                    "channel_id": channel,
                ]
            )
            let targetTopLevelEvent = makeMessage(
                messageId: targetTopLevelEventId,
                notificationRequestId: "req-\(targetTopLevelEventId)",
                title: "Target top-level event",
                body: "Target top-level event body",
                rawPayload: [
                    "entity_type": "event",
                    "entity_id": targetTopLevelEventId,
                    "event_id": targetTopLevelEventId,
                    "projection_destination": "event_head",
                    "channel_id": channel,
                ]
            )
            let targetThingScopedEvent = makeMessage(
                messageId: targetThingScopedEventId,
                notificationRequestId: "req-\(targetThingScopedEventId)",
                title: "Target thing-scoped event",
                body: "Target thing-scoped event body",
                rawPayload: [
                    "entity_type": "event",
                    "entity_id": targetThingScopedEventId,
                    "event_id": targetThingScopedEventId,
                    "thing_id": "thing-batch-delete-parent-001",
                    "projection_destination": "thing_sub_event",
                    "channel_id": channel,
                ]
            )
            let keepEvent = makeMessage(
                messageId: keepEventId,
                notificationRequestId: "req-\(keepEventId)",
                title: "Keep event",
                body: "Keep event body",
                rawPayload: [
                    "entity_type": "event",
                    "entity_id": keepEventId,
                    "event_id": keepEventId,
                    "projection_destination": "event_head",
                    "channel_id": channel,
                ]
            )

            try await store.saveEntityRecords([thingParent, targetTopLevelEvent, targetThingScopedEvent, keepEvent])

            let deleted = try await store.deleteEventRecords(
                eventIds: [targetTopLevelEventId, targetThingScopedEventId, targetTopLevelEventId]
            )
            #expect(deleted == 2)

            let remainingEvents = try await store.loadEventMessagesForProjection().map(\.eventId)
            let remainingThingEvents = try await store.loadThingMessagesForProjection().map(\.eventId)

            #expect(remainingEvents.contains(targetTopLevelEventId) == false)
            #expect(remainingThingEvents.contains(targetThingScopedEventId) == false)
            #expect(remainingEvents.contains(keepEventId) == true)
        }
    }

    @Test
    func batchDeleteThingRecordsByIdsRemovesOnlyTargetThings() async throws {
        try await withIsolatedLocalDataStore { store, _ in
            let targetThingId = "thing-batch-delete-target-001"
            let keepThingId = "thing-batch-delete-keep-001"
            let channel = "batch-delete-things"

            let targetThing = makeMessage(
                messageId: targetThingId,
                notificationRequestId: "req-\(targetThingId)",
                title: "Target thing",
                body: "Target thing body",
                rawPayload: [
                    "entity_type": "thing",
                    "entity_id": targetThingId,
                    "thing_id": targetThingId,
                    "projection_destination": "thing_head",
                    "channel_id": channel,
                ]
            )
            let targetThingEvent = makeMessage(
                messageId: "evt-\(targetThingId)",
                notificationRequestId: "req-evt-\(targetThingId)",
                title: "Target thing event",
                body: "Target thing event body",
                rawPayload: [
                    "entity_type": "event",
                    "entity_id": "evt-\(targetThingId)",
                    "event_id": "evt-\(targetThingId)",
                    "thing_id": targetThingId,
                    "projection_destination": "thing_sub_event",
                    "channel_id": channel,
                ]
            )
            let keepThing = makeMessage(
                messageId: keepThingId,
                notificationRequestId: "req-\(keepThingId)",
                title: "Keep thing",
                body: "Keep thing body",
                rawPayload: [
                    "entity_type": "thing",
                    "entity_id": keepThingId,
                    "thing_id": keepThingId,
                    "projection_destination": "thing_head",
                    "channel_id": channel,
                ]
            )

            try await store.saveEntityRecords([targetThing, targetThingEvent, keepThing])

            let deleted = try await store.deleteThingRecords(
                thingIds: [targetThingId, targetThingId]
            )
            #expect(deleted == 2)

            let remainingThings = try await store.loadThingMessagesForProjection().map(\.thingId)
            #expect(remainingThings.contains(targetThingId) == false)
            #expect(remainingThings.contains(keepThingId) == true)
        }
    }

    @Test
    func notificationContextSnapshotRebuildsAfterDeleteMessageById() async throws {
        try await withIsolatedLocalDataStore { store, appGroupIdentifier in
            let eventId = "evt-snapshot-delete-id-001"
            let eventRecord = makeMessage(
                messageId: "msg-snapshot-delete-id-001",
                notificationRequestId: "req-snapshot-delete-id-001",
                title: "Snapshot event by id",
                body: "Snapshot event body",
                rawPayload: [
                    "entity_type": "event",
                    "entity_id": eventId,
                    "event_id": eventId,
                    "projection_destination": "event_head",
                    "channel_id": "snapshot-tests",
                ]
            )

            try await store.saveEntityRecords([eventRecord])

            let beforeDelete = NotificationContextSnapshotStore.load(
                fileManager: .default,
                appGroupIdentifier: appGroupIdentifier
            )
            #expect(beforeDelete?.events[eventId] != nil)

            guard let persisted = try await store.loadMessage(
                notificationRequestId: "req-snapshot-delete-id-001"
            ) else {
                Issue.record("Expected persisted entity record before delete by id.")
                return
            }
            try await store.deleteMessage(id: persisted.id)

            let afterDelete = NotificationContextSnapshotStore.load(
                fileManager: .default,
                appGroupIdentifier: appGroupIdentifier
            )
            #expect(afterDelete?.events[eventId] == nil)
        }
    }

    @Test
    func notificationContextSnapshotRebuildsAfterDeleteMessageByNotificationRequestId() async throws {
        try await withIsolatedLocalDataStore { store, appGroupIdentifier in
            let thingId = "thing-snapshot-delete-req-001"
            let thingRecord = makeMessage(
                messageId: "msg-snapshot-delete-req-001",
                notificationRequestId: "req-snapshot-delete-req-001",
                title: "Snapshot thing by request",
                body: "Snapshot thing body",
                rawPayload: [
                    "entity_type": "thing",
                    "entity_id": thingId,
                    "thing_id": thingId,
                    "projection_destination": "thing_head",
                    "channel_id": "snapshot-tests",
                ]
            )

            try await store.saveEntityRecords([thingRecord])

            let beforeDelete = NotificationContextSnapshotStore.load(
                fileManager: .default,
                appGroupIdentifier: appGroupIdentifier
            )
            #expect(beforeDelete?.things[thingId] != nil)

            try await store.deleteMessage(notificationRequestId: "req-snapshot-delete-req-001")

            let afterDelete = NotificationContextSnapshotStore.load(
                fileManager: .default,
                appGroupIdentifier: appGroupIdentifier
            )
            #expect(afterDelete?.things[thingId] == nil)
        }
    }

    @Test
    func legacyRawPayloadTagFormatsRemainDeterministicAcrossReload() async throws {
        try await withIsolatedAutomationStorage { _, appGroupIdentifier in
            let jsonTags = makeMessage(
                id: UUID(uuidString: "10000000-0000-0000-0000-000000000001")!,
                messageId: "legacy-tags-json-001",
                notificationRequestId: "req-legacy-tags-json-001",
                title: "Legacy JSON tags",
                body: "JSON string encoded tags should survive reload",
                receivedAt: Date(timeIntervalSince1970: 1_800_000_100),
                rawPayload: [
                    "tags": #"["legacy-json","stable"]"#,
                    "metadata": #"{"kind":"json","tag":"shadow-json"}"#,
                    "channel_id": "legacy-tags",
                ]
            )
            let directArrayTags = makeMessage(
                id: UUID(uuidString: "10000000-0000-0000-0000-000000000002")!,
                messageId: "legacy-tags-array-001",
                notificationRequestId: "req-legacy-tags-array-001",
                title: "Legacy direct array tags",
                body: "Direct array tags are a legacy shape",
                receivedAt: Date(timeIntervalSince1970: 1_800_000_090),
                rawPayload: [
                    "tags": ["legacy-array", "ignored"],
                    "metadata": #"{"kind":"array"}"#,
                    "channel_id": "legacy-tags",
                ]
            )
            let commaTags = makeMessage(
                id: UUID(uuidString: "10000000-0000-0000-0000-000000000003")!,
                messageId: "legacy-tags-comma-001",
                notificationRequestId: "req-legacy-tags-comma-001",
                title: "Legacy comma tags",
                body: "Comma separated tags should not be treated as parsed tags",
                receivedAt: Date(timeIntervalSince1970: 1_800_000_080),
                rawPayload: [
                    "tags": "legacy,comma",
                    "metadata": #"{"kind":"comma"}"#,
                    "channel_id": "legacy-tags",
                ]
            )
            let missingTags = makeMessage(
                id: UUID(uuidString: "10000000-0000-0000-0000-000000000004")!,
                messageId: "legacy-tags-missing-001",
                notificationRequestId: "req-legacy-tags-missing-001",
                title: "Legacy missing tags",
                body: "Missing tags stay empty",
                receivedAt: Date(timeIntervalSince1970: 1_800_000_070),
                rawPayload: [
                    "metadata": #"{"kind":"missing","tag":"shadow-missing"}"#,
                    "channel_id": "legacy-tags",
                ]
            )
            let wrongTypeTags = makeMessage(
                id: UUID(uuidString: "10000000-0000-0000-0000-000000000005")!,
                messageId: "legacy-tags-wrong-001",
                notificationRequestId: "req-legacy-tags-wrong-001",
                title: "Legacy wrong type tags",
                body: "Scalar tags stay empty",
                receivedAt: Date(timeIntervalSince1970: 1_800_000_060),
                rawPayload: [
                    "tags": 7,
                    "metadata": #"{"kind":"wrong","tag":"shadow-wrong"}"#,
                    "channel_id": "legacy-tags",
                ]
            )

            try createLegacyMainStoreFixture(
                appGroupIdentifier: appGroupIdentifier,
                messages: [jsonTags, directArrayTags, commaTags, missingTags, wrongTypeTags]
            )

            let store = LocalDataStore(appGroupIdentifier: appGroupIdentifier)

            let loadedJSON = try #require(try await store.loadMessage(messageId: jsonTags.messageId ?? ""))
            let loadedArray = try #require(try await store.loadMessage(messageId: directArrayTags.messageId ?? ""))
            let loadedComma = try #require(try await store.loadMessage(messageId: commaTags.messageId ?? ""))
            let loadedMissing = try #require(try await store.loadMessage(messageId: missingTags.messageId ?? ""))
            let loadedWrong = try #require(try await store.loadMessage(messageId: wrongTypeTags.messageId ?? ""))

            #expect(Set(loadedJSON.tags) == Set(["legacy-json", "stable"]))
            #expect(loadedArray.tags.isEmpty)
            #expect(loadedComma.tags.isEmpty)
            #expect(loadedMissing.tags.isEmpty)
            #expect(loadedWrong.tags.isEmpty)

            let jsonTagPage = try await store.loadMessageSummariesPage(
                before: nil,
                limit: 10,
                filter: .all,
                channel: nil,
                tag: "legacy-json"
            )
            #expect(jsonTagPage.map(\.id) == [jsonTags.id])

            #expect(try await store.searchMessagesCount(query: "tag:legacy-json") == 1)
            #expect(try await store.searchMessagesCount(query: "tag:legacy-array") == 0)
            #expect(try await store.searchMessagesCount(query: "tag:shadow-wrong") == 0)

            let tagCounts = try await store.messageTagCounts()
            #expect(tagCounts.first(where: { $0.tag == "legacy-json" })?.totalCount == 1)
            #expect(!tagCounts.contains(where: { $0.tag == "shadow-json" }))
            #expect(!tagCounts.contains(where: { $0.tag == "shadow-missing" }))
            #expect(!tagCounts.contains(where: { $0.tag == "shadow-wrong" }))
            #expect(!tagCounts.contains(where: { $0.tag == "legacy-array" }))
            #expect(!tagCounts.contains(where: { $0.tag == "legacy" }))
        }
    }

    @Test
    func staleLateInputsDoNotPolluteSideIndexesOrNotificationSnapshot() async throws {
        try await withIsolatedLocalDataStore { store, appGroupIdentifier in
            let topLevelNewer = makeMessage(
                id: UUID(uuidString: "20000000-0000-0000-0000-000000000001")!,
                messageId: "stale-index-top-level-001",
                notificationRequestId: "req-stale-index-top-level-001",
                title: "Fresh top level title",
                body: "Fresh top level body",
                receivedAt: Date(timeIntervalSince1970: 1_800_001_000),
                rawPayload: [
                    "entity_type": "message",
                    "entity_id": "stale-index-top-level-entity-001",
                    "tags": #"["fresh-tag"]"#,
                    "metadata": #"{"kind":"fresh"}"#,
                    "channel_id": "stale-index-tests",
                ]
            )
            let topLevelStale = makeMessage(
                id: UUID(uuidString: "20000000-0000-0000-0000-000000000002")!,
                messageId: "stale-index-top-level-001",
                notificationRequestId: "req-stale-index-top-level-001-stale",
                title: "Older compensating title",
                body: "Older compensating body",
                receivedAt: Date(timeIntervalSince1970: 1_800_000_900),
                rawPayload: [
                    "entity_type": "message",
                    "entity_id": "stale-index-top-level-entity-001",
                    "tags": #"["stale-tag"]"#,
                    "metadata": #"{"kind":"stale","patch":"richer"}"#,
                    "channel_id": "stale-index-tests",
                ]
            )
            let topLevelEqualUpdate = makeMessage(
                id: UUID(uuidString: "20000000-0000-0000-0000-000000000003")!,
                messageId: "stale-index-top-level-001",
                notificationRequestId: "req-stale-index-top-level-001-equal",
                title: "Equal timestamp accepted",
                body: "Equal timestamp accepted body",
                receivedAt: topLevelNewer.receivedAt,
                rawPayload: [
                    "entity_type": "message",
                    "entity_id": "stale-index-top-level-entity-001",
                    "tags": #"["equal-tag"]"#,
                    "metadata": #"{"kind":"equal","mode":"accepted"}"#,
                    "channel_id": "stale-index-tests",
                ]
            )
            let eventId = "evt-stale-index-001"
            let snapshotNewer = makeMessage(
                id: UUID(uuidString: "20000000-0000-0000-0000-000000000004")!,
                messageId: "stale-index-event-001",
                notificationRequestId: "req-stale-index-event-001",
                title: "Fresh event title",
                body: "Fresh event body",
                receivedAt: Date(timeIntervalSince1970: 1_800_001_000),
                rawPayload: [
                    "entity_type": "event",
                    "entity_id": eventId,
                    "event_id": eventId,
                    "projection_destination": "event_head",
                    "channel_id": "stale-index-tests",
                ]
            )
            let snapshotStale = makeMessage(
                id: UUID(uuidString: "20000000-0000-0000-0000-000000000005")!,
                messageId: "stale-index-event-001",
                notificationRequestId: "req-stale-index-event-001-stale",
                title: "Older event title",
                body: "Older event body",
                receivedAt: Date(timeIntervalSince1970: 1_800_000_900),
                rawPayload: [
                    "entity_type": "event",
                    "entity_id": eventId,
                    "event_id": eventId,
                    "projection_destination": "event_head",
                    "channel_id": "stale-index-tests",
                ]
            )
            let snapshotEqualUpdate = makeMessage(
                id: UUID(uuidString: "20000000-0000-0000-0000-000000000006")!,
                messageId: "stale-index-event-001",
                notificationRequestId: "req-stale-index-event-001-equal",
                title: "Equal event title",
                body: "Equal event body",
                receivedAt: snapshotNewer.receivedAt,
                rawPayload: [
                    "entity_type": "event",
                    "entity_id": eventId,
                    "event_id": eventId,
                    "projection_destination": "event_head",
                    "channel_id": "stale-index-tests",
                ]
            )

            try await store.saveMessagesBatch([topLevelNewer, snapshotNewer])
            try await store.saveMessagesBatch([topLevelStale, snapshotStale])

            let afterStale = try #require(try await store.loadMessage(messageId: topLevelNewer.messageId ?? ""))
            #expect(afterStale.title == "Fresh top level title")
            #expect(afterStale.body == "Fresh top level body")
            #expect(afterStale.receivedAt == topLevelNewer.receivedAt)
            #expect(afterStale.metadata["kind"] == "fresh")
            #expect(afterStale.metadata["patch"] == nil)
            #expect(afterStale.tags == ["fresh-tag"])
            #expect(try await store.searchMessagesCount(query: "Fresh top level title") == 1)
            #expect(try await store.searchMessagesCount(query: "Older compensating title") == 0)
            #expect(try await store.searchMessagesCount(query: "tag:fresh-tag") == 1)
            #expect(try await store.searchMessagesCount(query: "tag:stale-tag") == 0)
            let tagCountsAfterStale = try await store.messageTagCounts()
            #expect(tagCountsAfterStale.first(where: { $0.tag == "fresh-tag" })?.totalCount == 1)
            #expect(tagCountsAfterStale.contains(where: { $0.tag == "stale-tag" }) == false)

            let staleSnapshot = NotificationContextSnapshotStore.load(
                fileManager: .default,
                appGroupIdentifier: appGroupIdentifier
            )
            #expect(staleSnapshot?.events[eventId]?.title == "Fresh event title")
            #expect(staleSnapshot?.events[eventId]?.body == "Fresh event body")

            try await store.saveMessagesBatch([topLevelEqualUpdate, snapshotEqualUpdate])

            let afterEqual = try #require(try await store.loadMessage(messageId: topLevelNewer.messageId ?? ""))
            #expect(afterEqual.title == "Equal timestamp accepted")
            #expect(afterEqual.body == "Equal timestamp accepted body")
            #expect(afterEqual.receivedAt == topLevelNewer.receivedAt)
            #expect(afterEqual.metadata["kind"] == "equal")
            #expect(afterEqual.metadata["mode"] == "accepted")
            #expect(afterEqual.tags == ["equal-tag"])
            #expect(try await store.searchMessagesCount(query: "Equal timestamp accepted") == 1)
            #expect(try await store.searchMessagesCount(query: "Fresh top level title") == 0)
            #expect(try await store.searchMessagesCount(query: "tag:equal-tag") == 1)
            #expect(try await store.searchMessagesCount(query: "tag:fresh-tag") == 0)

            let tagCountsAfterEqual = try await store.messageTagCounts()
            #expect(tagCountsAfterEqual.first(where: { $0.tag == "equal-tag" })?.totalCount == 1)
            #expect(tagCountsAfterEqual.contains(where: { $0.tag == "fresh-tag" }) == false)

            let equalSnapshot = NotificationContextSnapshotStore.load(
                fileManager: .default,
                appGroupIdentifier: appGroupIdentifier
            )
            #expect(equalSnapshot?.events[eventId]?.title == "Equal event title")
            #expect(equalSnapshot?.events[eventId]?.body == "Equal event body")
        }
    }

    @Test
    func malformedLegacyMetadataIndexSafelyFallsBackToMainStoreData() async throws {
        try await withIsolatedAutomationStorage { _, appGroupIdentifier in
            let messages = [
                makeMessage(
                    id: UUID(uuidString: "30000000-0000-0000-0000-000000000001")!,
                    messageId: "legacy-index-fallback-001",
                    notificationRequestId: "req-legacy-index-fallback-001",
                    title: "Legacy index fallback one",
                    body: "Main store data must survive malformed metadata index",
                    receivedAt: Date(timeIntervalSince1970: 1_800_002_000),
                    rawPayload: [
                        "tags": #"["legacy-fallback"]"#,
                        "metadata": #"{"kind":"fallback","tier":"one"}"#,
                        "channel_id": "legacy-index",
                    ]
                ),
                makeMessage(
                    id: UUID(uuidString: "30000000-0000-0000-0000-000000000002")!,
                    messageId: "legacy-index-fallback-002",
                    notificationRequestId: "req-legacy-index-fallback-002",
                    title: "Legacy index fallback two",
                    body: "Malformed metadata index should not break tag fallback",
                    receivedAt: Date(timeIntervalSince1970: 1_800_001_990),
                    rawPayload: [
                        "tags": #"["legacy-fallback"]"#,
                        "metadata": #"{"kind":"fallback","tier":"two"}"#,
                        "channel_id": "legacy-index",
                    ]
                ),
            ]
            try createLegacyMainStoreFixture(
                appGroupIdentifier: appGroupIdentifier,
                messages: messages
            )

            let databaseDirectory = try AppConstants.appLocalDatabaseDirectory(
                fileManager: .default,
                appGroupIdentifier: appGroupIdentifier
            )
            let indexURL = databaseDirectory.appendingPathComponent(AppConstants.messageIndexDatabaseFilename)
            try removeSQLiteArtifacts(at: indexURL)

            let malformedIndex = try DatabaseQueue(path: indexURL.path)
            try await malformedIndex.write { db in
                try db.execute(sql: """
                    CREATE TABLE message_metadata_index (
                        message_id TEXT PRIMARY KEY NOT NULL
                    );
                    """)
                try db.execute(
                    sql: "INSERT INTO message_metadata_index(message_id) VALUES (?);",
                    arguments: [messages[0].id.uuidString]
                )
            }

            let store = LocalDataStore(appGroupIdentifier: appGroupIdentifier)
            let counts = try await store.messageCounts()
            #expect(counts.total == 2)
            #expect(counts.unread == 2)

            let fallbackTagPage = try await store.loadMessageSummariesPage(
                before: nil,
                limit: 10,
                filter: .all,
                channel: nil,
                tag: "legacy-fallback"
            )
            #expect(Set(fallbackTagPage.map(\.id)) == Set(messages.map(\.id)))
            #expect(try await store.searchMessagesCount(query: "tag:legacy-fallback") == 2)
            #expect(try await store.searchMessagesCount(query: "tag fallback") == 1)

            let tagCounts = try await store.messageTagCounts()
            #expect(tagCounts.first(where: { $0.tag == "legacy-fallback" })?.totalCount == 2)

            let survivingIDs = Set(try await store.loadMessages().map(\.id))
            #expect(survivingIDs == Set(messages.map(\.id)))
        }
    }

    @Test
    func legacyFileFixtureWithMissingIndexFilesRebuildsAndStaysStableAfterReload() async throws {
        try await withIsolatedAutomationStorage { root, appGroupIdentifier in
            let fixture = makeLegacyCompatibilityFixture()
            try createLegacyMainStoreFixture(
                appGroupIdentifier: appGroupIdentifier,
                messages: fixture.messages
            )
            try writeLegacyNotificationSnapshot(
                appGroupIdentifier: appGroupIdentifier,
                fixture: fixture
            )
            try removeSQLiteArtifacts(at: indexDatabaseURL(appGroupIdentifier: appGroupIdentifier))

            let store = LocalDataStore(appGroupIdentifier: appGroupIdentifier)
            let firstProbe = try await exerciseLegacyFixture(
                store: store,
                appGroupIdentifier: appGroupIdentifier,
                fixture: fixture
            )
            try assertCanonicalIndexContents(
                appGroupIdentifier: appGroupIdentifier,
                fixture: fixture
            )

            let reloadedAppGroupIdentifier = "group.ethan.pushgo.tests.\(UUID().uuidString.lowercased())"
            try cloneAutomationStorageFixture(
                root: root,
                sourceAppGroupIdentifier: appGroupIdentifier,
                destinationAppGroupIdentifier: reloadedAppGroupIdentifier
            )

            let reloadedStore = LocalDataStore(appGroupIdentifier: reloadedAppGroupIdentifier)
            let secondProbe = try await exerciseLegacyFixture(
                store: reloadedStore,
                appGroupIdentifier: reloadedAppGroupIdentifier,
                fixture: fixture
            )
            #expect(secondProbe == firstProbe)
            try assertCanonicalIndexContents(
                appGroupIdentifier: reloadedAppGroupIdentifier,
                fixture: fixture
            )
        }
    }

    @Test
    func emptyIndexFileRebuildsSearchAndMetadataFromCanonicalMainStore() async throws {
        try await withIsolatedAutomationStorage { _, appGroupIdentifier in
            let fixture = makeLegacyCompatibilityFixture()
            try createLegacyMainStoreFixture(
                appGroupIdentifier: appGroupIdentifier,
                messages: fixture.messages
            )
            try writeLegacyNotificationSnapshot(
                appGroupIdentifier: appGroupIdentifier,
                fixture: fixture
            )
            try createEmptyIndexFile(appGroupIdentifier: appGroupIdentifier)

            let store = LocalDataStore(appGroupIdentifier: appGroupIdentifier)
            _ = try await exerciseLegacyFixture(
                store: store,
                appGroupIdentifier: appGroupIdentifier,
                fixture: fixture
            )
            try assertCanonicalIndexContents(
                appGroupIdentifier: appGroupIdentifier,
                fixture: fixture
            )
        }
    }

    @Test
    func searchIndexSchemaCorruptionWithHealthyMetadataRebuildsWithoutBreakingTagPaths() async throws {
        try await withIsolatedAutomationStorage { _, appGroupIdentifier in
            let fixture = makeLegacyCompatibilityFixture()
            try createLegacyMainStoreFixture(
                appGroupIdentifier: appGroupIdentifier,
                messages: fixture.messages
            )
            try writeLegacyNotificationSnapshot(
                appGroupIdentifier: appGroupIdentifier,
                fixture: fixture
            )
            try createLegacySearchSchemaIndexFile(
                appGroupIdentifier: appGroupIdentifier,
                includeHealthyMetadata: true
            )

            let store = LocalDataStore(appGroupIdentifier: appGroupIdentifier)
            _ = try await exerciseLegacyFixture(
                store: store,
                appGroupIdentifier: appGroupIdentifier,
                fixture: fixture
            )
            try assertCanonicalIndexContents(
                appGroupIdentifier: appGroupIdentifier,
                fixture: fixture
            )
        }
    }

    @Test
    func metadataIndexSchemaCorruptionWithHealthySearchRebuildsWithoutBreakingSearchPaths() async throws {
        try await withIsolatedAutomationStorage { _, appGroupIdentifier in
            let fixture = makeLegacyCompatibilityFixture()
            try createLegacyMainStoreFixture(
                appGroupIdentifier: appGroupIdentifier,
                messages: fixture.messages
            )
            try writeLegacyNotificationSnapshot(
                appGroupIdentifier: appGroupIdentifier,
                fixture: fixture
            )
            try createLegacyMetadataSchemaIndexFile(
                appGroupIdentifier: appGroupIdentifier,
                includeHealthySearch: true
            )

            let store = LocalDataStore(appGroupIdentifier: appGroupIdentifier)
            _ = try await exerciseLegacyFixture(
                store: store,
                appGroupIdentifier: appGroupIdentifier,
                fixture: fixture
            )
            try assertCanonicalIndexContents(
                appGroupIdentifier: appGroupIdentifier,
                fixture: fixture
            )
        }
    }

    @Test
    func bothIndexTablesCorruptedRebuildFromMainStoreAndRemainCanonical() async throws {
        try await withIsolatedAutomationStorage { _, appGroupIdentifier in
            let fixture = makeLegacyCompatibilityFixture()
            try createLegacyMainStoreFixture(
                appGroupIdentifier: appGroupIdentifier,
                messages: fixture.messages
            )
            try writeLegacyNotificationSnapshot(
                appGroupIdentifier: appGroupIdentifier,
                fixture: fixture
            )
            try createFullyLegacySchemaIndexFile(appGroupIdentifier: appGroupIdentifier)

            let store = LocalDataStore(appGroupIdentifier: appGroupIdentifier)
            _ = try await exerciseLegacyFixture(
                store: store,
                appGroupIdentifier: appGroupIdentifier,
                fixture: fixture
            )
            try assertCanonicalIndexContents(
                appGroupIdentifier: appGroupIdentifier,
                fixture: fixture
            )
        }
    }

    @Test
    func persistentIndexInitializationFailureSafelyDegradesToCanonicalQueries() async throws {
        try await withIsolatedAutomationStorage { _, appGroupIdentifier in
            let fixture = makeLegacyCompatibilityFixture()
            try createLegacyMainStoreFixture(
                appGroupIdentifier: appGroupIdentifier,
                messages: fixture.messages
            )
            try writeLegacyNotificationSnapshot(
                appGroupIdentifier: appGroupIdentifier,
                fixture: fixture
            )
            let indexURL = try indexDatabaseURL(appGroupIdentifier: appGroupIdentifier)
            try FileManager.default.createDirectory(
                at: indexURL,
                withIntermediateDirectories: true
            )

            let store = LocalDataStore(appGroupIdentifier: appGroupIdentifier)
            _ = try await exerciseLegacyFixture(
                store: store,
                appGroupIdentifier: appGroupIdentifier,
                fixture: fixture
            )

            var isDirectory = ObjCBool(false)
            #expect(FileManager.default.fileExists(atPath: indexURL.path, isDirectory: &isDirectory))
            #expect(isDirectory.boolValue)
        }
    }

    @Test
    func transientIndexInitializationFailureRetriesThenBuildsCanonicalIndexes() async throws {
        try await withIsolatedAutomationStorage { _, appGroupIdentifier in
            let fixture = makeLegacyCompatibilityFixture()
            try createLegacyMainStoreFixture(
                appGroupIdentifier: appGroupIdentifier,
                messages: fixture.messages
            )
            try writeLegacyNotificationSnapshot(
                appGroupIdentifier: appGroupIdentifier,
                fixture: fixture
            )
            let indexURL = try indexDatabaseURL(appGroupIdentifier: appGroupIdentifier)
            try FileManager.default.createDirectory(
                at: indexURL,
                withIntermediateDirectories: true
            )

            let remover = Task.detached {
                try? await Task.sleep(nanoseconds: 30_000_000)
                try? FileManager.default.removeItem(at: indexURL)
            }
            let store = LocalDataStore(appGroupIdentifier: appGroupIdentifier)
            _ = await remover.result

            _ = try await exerciseLegacyFixture(
                store: store,
                appGroupIdentifier: appGroupIdentifier,
                fixture: fixture
            )
            try assertCanonicalIndexContents(
                appGroupIdentifier: appGroupIdentifier,
                fixture: fixture
            )
        }
    }

    @Test
    func deleteMessagesRebuildsNotificationContextSnapshotOnlyForRelevantSemanticRows() async throws {
        try await withIsolatedLocalDataStore { store, appGroupIdentifier in
            let ordinary = makeMessage(
                id: UUID(uuidString: "40000000-0000-0000-0000-000000000001")!,
                messageId: "snapshot-ordinary-001",
                notificationRequestId: "req-snapshot-ordinary-001",
                title: "Ordinary message",
                body: "Deleting this should not change semantic snapshot",
                receivedAt: Date(timeIntervalSince1970: 1_800_003_000),
                rawPayload: [
                    "entity_type": "message",
                    "entity_id": "ordinary-001",
                    "tags": #"["ordinary"]"#,
                    "channel_id": "snapshot-conditions",
                ]
            )
            let eventReference = makeMessage(
                id: UUID(uuidString: "40000000-0000-0000-0000-000000000002")!,
                messageId: "snapshot-event-ref-001",
                notificationRequestId: "req-snapshot-event-ref-001",
                title: "Event reference message",
                body: "This top-level message carries event context",
                receivedAt: Date(timeIntervalSince1970: 1_800_002_990),
                rawPayload: [
                    "entity_type": "message",
                    "entity_id": "event-ref-001",
                    "event_id": "evt-delete-conditions-001",
                    "tags": #"["eventref"]"#,
                    "channel_id": "snapshot-conditions",
                ]
            )
            let thingRecord = makeMessage(
                id: UUID(uuidString: "40000000-0000-0000-0000-000000000003")!,
                messageId: "snapshot-thing-001",
                notificationRequestId: "req-snapshot-thing-001",
                title: "Thing snapshot",
                body: "Thing body",
                receivedAt: Date(timeIntervalSince1970: 1_800_002_980),
                rawPayload: [
                    "entity_type": "thing",
                    "entity_id": "thing-delete-conditions-001",
                    "thing_id": "thing-delete-conditions-001",
                    "projection_destination": "thing_head",
                    "channel_id": "snapshot-conditions",
                ]
            )

            try await store.saveMessagesBatch([ordinary, eventReference])
            try await store.saveEntityRecords([thingRecord])

            let beforeOrdinaryDelete = try #require(
                NotificationContextSnapshotStore.snapshotFileURL(appGroupIdentifier: appGroupIdentifier)
            )
            let beforeOrdinaryData = try Data(contentsOf: beforeOrdinaryDelete)
            let beforeOrdinarySnapshot = try #require(
                NotificationContextSnapshotStore.load(
                    fileManager: .default,
                    appGroupIdentifier: appGroupIdentifier
                )
            )
            #expect(beforeOrdinarySnapshot.events["evt-delete-conditions-001"] != nil)
            #expect(beforeOrdinarySnapshot.things["thing-delete-conditions-001"] != nil)

            _ = try await store.deleteMessages(ids: [ordinary.id])

            let afterOrdinaryData = try Data(contentsOf: beforeOrdinaryDelete)
            let afterOrdinarySnapshot = try #require(
                NotificationContextSnapshotStore.load(
                    fileManager: .default,
                    appGroupIdentifier: appGroupIdentifier
                )
            )
            #expect(afterOrdinaryData == beforeOrdinaryData)
            #expect(afterOrdinarySnapshot.events["evt-delete-conditions-001"] != nil)
            #expect(afterOrdinarySnapshot.things["thing-delete-conditions-001"] != nil)

            _ = try await store.deleteMessages(ids: [eventReference.id, ordinary.id])

            let afterEventDeleteSnapshot = NotificationContextSnapshotStore.load(
                fileManager: .default,
                appGroupIdentifier: appGroupIdentifier
            )
            #expect(afterEventDeleteSnapshot?.events["evt-delete-conditions-001"] == nil)
            #expect(afterEventDeleteSnapshot?.things["thing-delete-conditions-001"] != nil)

            _ = try await store.deleteMessages(ids: [thingRecord.id, ordinary.id])

            let afterThingDeleteSnapshot = NotificationContextSnapshotStore.load(
                fileManager: .default,
                appGroupIdentifier: appGroupIdentifier
            )
            #expect(afterThingDeleteSnapshot?.things["thing-delete-conditions-001"] == nil)
        }
    }

    @Test
    func loadEntityOpenTargetResolvesEventProjectionByNotificationRequestId() async throws {
        try await withIsolatedLocalDataStore { store, _ in
            let eventId = "evt-open-target-001"
            let eventRecord = makeMessage(
                messageId: "msg-open-target-evt-001",
                notificationRequestId: "req-open-target-evt-001",
                title: "Open target event",
                body: "Open target event body",
                rawPayload: [
                    "entity_type": "event",
                    "entity_id": eventId,
                    "event_id": eventId,
                    "projection_destination": "event_head",
                    "channel_id": "open-target-tests",
                ]
            )

            try await store.saveEntityRecords([eventRecord])

            let target = try await store.loadEntityOpenTarget(
                notificationRequestId: "req-open-target-evt-001"
            )

            #expect(target == EntityOpenTarget(entityType: "event", entityId: eventId))
        }
    }

    @Test
    func loadEntityOpenTargetResolvesThingProjectionByMessageId() async throws {
        try await withIsolatedLocalDataStore { store, _ in
            let thingId = "thing-open-target-001"
            let thingRecord = makeMessage(
                messageId: "msg-open-target-thing-001",
                notificationRequestId: "req-open-target-thing-001",
                title: "Open target thing",
                body: "Open target thing body",
                rawPayload: [
                    "entity_type": "thing",
                    "entity_id": thingId,
                    "thing_id": thingId,
                    "projection_destination": "thing_head",
                    "channel_id": "open-target-tests",
                ]
            )

            try await store.saveEntityRecords([thingRecord])

            let target = try await store.loadEntityOpenTarget(
                messageId: "msg-open-target-thing-001"
            )

            #expect(target == EntityOpenTarget(entityType: "thing", entityId: thingId))
        }
    }

    @Test
    func deleteAllMessagesClearsNotificationContextSnapshotFile() async throws {
        try await withIsolatedLocalDataStore { store, appGroupIdentifier in
            let eventId = "evt-snapshot-clear-001"
            let eventRecord = makeMessage(
                messageId: "msg-snapshot-clear-001",
                notificationRequestId: "req-snapshot-clear-001",
                title: "Snapshot clear",
                body: "Snapshot clear body",
                rawPayload: [
                    "entity_type": "event",
                    "entity_id": eventId,
                    "event_id": eventId,
                    "projection_destination": "event_head",
                    "channel_id": "snapshot-tests",
                ]
            )
            try await store.saveEntityRecords([eventRecord])

            guard let snapshotURL = NotificationContextSnapshotStore.snapshotFileURL(
                appGroupIdentifier: appGroupIdentifier
            ) else {
                Issue.record("Expected notification context snapshot file URL.")
                return
            }
            #expect(FileManager.default.fileExists(atPath: snapshotURL.path))

            try await store.deleteAllMessages()

            #expect(FileManager.default.fileExists(atPath: snapshotURL.path) == false)
            let cleared = NotificationContextSnapshotStore.load(
                fileManager: .default,
                appGroupIdentifier: appGroupIdentifier
            )
            #expect(cleared == nil)
        }
    }

    @Test
    func cachedDeviceKeyFallsBackToSharedWakeupDefaultsWhenKeychainEntryIsMissing() async throws {
        try await withIsolatedAutomationStorage { root, appGroupIdentifier in
            let store = LocalDataStore(appGroupIdentifier: appGroupIdentifier)
            let saveResult = await store.saveCachedDeviceKey("device-key-defaults-001", for: "macos")
            #expect(saveResult?.didPersist == true)

            let keychainItemURL = automationKeychainItemURL(
                root: root,
                service: "io.ethan.pushgo.provider.device-key",
                account: "provider.device_key.macos"
            )
            try FileManager.default.removeItem(at: keychainItemURL)

            let reloaded = await store.cachedDeviceKey(for: "macos")
            #expect(reloaded == "device-key-defaults-001")
            #expect(
                LocalDataStore.loadWakeupIngressDeviceKeyDefaults(
                    platform: "macos",
                    suiteName: appGroupIdentifier
                ) == "device-key-defaults-001"
            )
        }
    }

    private func makeMessage(
        id: UUID = UUID(),
        messageId: String,
        notificationRequestId: String,
        title: String,
        body: String,
        receivedAt: Date = Date(timeIntervalSince1970: 1_741_572_800),
        rawPayload: [String: Any] = [:]
    ) -> PushMessage {
        var payload = rawPayload
        payload["message_id"] = messageId
        payload["_notificationRequestId"] = notificationRequestId
        return PushMessage(
            id: id,
            messageId: messageId,
            title: title,
            body: body,
            channel: (payload["channel_id"] as? String) ?? "default",
            receivedAt: receivedAt,
            rawPayload: payload.reduce(into: [String: AnyCodable]()) { result, item in
                result[item.key] = AnyCodable(item.value)
            }
        )
    }

    private func createLegacyMainStoreFixture(
        appGroupIdentifier: String,
        messages: [PushMessage]
    ) throws {
        let databaseDirectory = try AppConstants.appLocalDatabaseDirectory(
            fileManager: .default,
            appGroupIdentifier: appGroupIdentifier
        )
        try FileManager.default.createDirectory(
            at: databaseDirectory,
            withIntermediateDirectories: true
        )
        let databaseURL = databaseDirectory.appendingPathComponent(AppConstants.databaseStoreFilename)
        let dbQueue = try DatabaseQueue(path: databaseURL.path)
        try dbQueue.write { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS messages (
                    id TEXT PRIMARY KEY NOT NULL,
                    message_id TEXT NOT NULL,
                    title TEXT NOT NULL,
                    body TEXT NOT NULL,
                    channel TEXT,
                    url TEXT,
                    is_read INTEGER NOT NULL,
                    received_at REAL NOT NULL,
                    raw_payload_json TEXT NOT NULL,
                    status TEXT NOT NULL,
                    decryption_state TEXT,
                    notification_request_id TEXT,
                    delivery_id TEXT,
                    operation_id TEXT,
                    entity_type TEXT NOT NULL,
                    entity_id TEXT,
                    event_id TEXT,
                    thing_id TEXT,
                    projection_destination TEXT,
                    event_state TEXT,
                    event_time_epoch INTEGER,
                    observed_time_epoch INTEGER,
                    occurred_at_epoch INTEGER,
                    is_top_level_message INTEGER NOT NULL,
                    CHECK (length(trim(message_id)) > 0)
                );
                """)
            try db.execute(sql: "CREATE UNIQUE INDEX IF NOT EXISTS idx_messages_message_id_unique ON messages(message_id);")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_messages_received_at ON messages(received_at DESC, id DESC);")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_messages_top_level_received_at ON messages(is_top_level_message, received_at DESC, id DESC);")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_messages_notification_request_id ON messages(notification_request_id);")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_messages_channel_received_at ON messages(channel, received_at DESC, id DESC);")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_messages_read_state_received_at ON messages(is_read, received_at DESC, id DESC);")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_messages_entity_projection ON messages(entity_type, event_time_epoch DESC, occurred_at_epoch DESC, received_at DESC, id DESC);")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_messages_event_projection ON messages(event_id, event_time_epoch DESC, received_at DESC, id DESC);")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_messages_thing_projection ON messages(thing_id, occurred_at_epoch DESC, observed_time_epoch DESC, event_time_epoch DESC, received_at DESC, id DESC);")
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS grdb_migrations (
                    identifier TEXT NOT NULL PRIMARY KEY
                );
                """)
            for identifier in [
                "v1_grdb_primary_store",
                "v2_watch_sync_state_columns",
                "v3_watch_provisioning_columns",
                "v4_watch_mode_control_state_columns",
                "v5_watch_mode_control_readiness_column",
                "v6_watch_publication_digest_columns",
                "v7_watch_light_notify_columns",
                "v8_rebuild_snake_case_schema",
                "v9_message_occurred_at_epoch",
                "v10_pending_inbound_messages",
                "v11_projection_epoch_millis",
                "v12_all_epoch_millis",
                "v13_watch_light_decryption_state_columns",
                "v14_provider_delivery_ack_outbox",
                "v15_drop_provider_delivery_ack_outbox",
            ] {
                try db.execute(
                    sql: "INSERT OR REPLACE INTO grdb_migrations(identifier) VALUES (?);",
                    arguments: [identifier]
                )
            }

            for message in messages {
                try db.execute(
                    sql: """
                        INSERT INTO messages (
                            id, message_id, title, body, channel, url, is_read, received_at,
                            raw_payload_json, status, decryption_state, notification_request_id,
                            delivery_id, operation_id, entity_type, entity_id, event_id, thing_id,
                            projection_destination, event_state, event_time_epoch, observed_time_epoch,
                            occurred_at_epoch, is_top_level_message
                        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
                        """,
                    arguments: [
                        message.id.uuidString,
                        message.messageId ?? "",
                        message.title,
                        message.body,
                        message.channel,
                        message.url?.absoluteString,
                        message.isRead ? 1 : 0,
                        message.receivedAt.timeIntervalSince1970,
                        try rawPayloadJSONString(from: message.rawPayload),
                        message.status.rawValue,
                        message.decryptionState?.rawValue,
                        message.notificationRequestId,
                        message.deliveryId,
                        message.operationId,
                        message.entityType,
                        message.entityId,
                        message.eventId,
                        message.thingId,
                        message.projectionDestination,
                        message.eventState,
                        nil,
                        nil,
                        nil,
                        fixtureIsTopLevelMessage(message) ? 1 : 0,
                    ]
                )
            }
        }
    }

    private func createEmptyIndexFile(appGroupIdentifier: String) throws {
        let indexURL = try indexDatabaseURL(appGroupIdentifier: appGroupIdentifier)
        try removeSQLiteArtifacts(at: indexURL)
        let dbQueue = try DatabaseQueue(path: indexURL.path)
        try dbQueue.write { db in
            try db.execute(sql: """
                CREATE VIRTUAL TABLE message_search USING fts5(
                    id UNINDEXED,
                    title,
                    body,
                    channel_id,
                    received_at UNINDEXED,
                    tokenize = 'unicode61'
                );
                """)
            try db.execute(sql: """
                CREATE TABLE message_metadata_index (
                    message_id TEXT NOT NULL,
                    key_name TEXT NOT NULL,
                    value_norm TEXT NOT NULL,
                    received_at REAL NOT NULL,
                    PRIMARY KEY (message_id, key_name, value_norm)
                );
                CREATE INDEX idx_metadata_key_value_time
                    ON message_metadata_index(key_name, value_norm, received_at DESC);
                CREATE INDEX idx_metadata_key_value_time_message
                    ON message_metadata_index(key_name, value_norm, received_at DESC, message_id DESC);
                CREATE INDEX idx_metadata_message
                    ON message_metadata_index(message_id);
                """)
        }
    }

    private func createLegacySearchSchemaIndexFile(
        appGroupIdentifier: String,
        includeHealthyMetadata: Bool
    ) throws {
        let indexURL = try indexDatabaseURL(appGroupIdentifier: appGroupIdentifier)
        try removeSQLiteArtifacts(at: indexURL)
        let dbQueue = try DatabaseQueue(path: indexURL.path)
        try dbQueue.write { db in
            try db.execute(sql: """
                CREATE TABLE message_search (
                    id TEXT NOT NULL,
                    title TEXT NOT NULL,
                    body TEXT NOT NULL,
                    received_at REAL NOT NULL
                );
                """)
            if includeHealthyMetadata {
                try db.execute(sql: """
                    CREATE TABLE message_metadata_index (
                        message_id TEXT NOT NULL,
                        key_name TEXT NOT NULL,
                        value_norm TEXT NOT NULL,
                        received_at REAL NOT NULL,
                        PRIMARY KEY (message_id, key_name, value_norm)
                    );
                    CREATE INDEX idx_metadata_key_value_time
                        ON message_metadata_index(key_name, value_norm, received_at DESC);
                    CREATE INDEX idx_metadata_key_value_time_message
                        ON message_metadata_index(key_name, value_norm, received_at DESC, message_id DESC);
                    CREATE INDEX idx_metadata_message
                        ON message_metadata_index(message_id);
                    """)
            }
        }
    }

    private func createLegacyMetadataSchemaIndexFile(
        appGroupIdentifier: String,
        includeHealthySearch: Bool
    ) throws {
        let indexURL = try indexDatabaseURL(appGroupIdentifier: appGroupIdentifier)
        try removeSQLiteArtifacts(at: indexURL)
        let dbQueue = try DatabaseQueue(path: indexURL.path)
        try dbQueue.write { db in
            if includeHealthySearch {
                try db.execute(sql: """
                    CREATE VIRTUAL TABLE message_search USING fts5(
                        id UNINDEXED,
                        title,
                        body,
                        channel_id,
                        received_at UNINDEXED,
                        tokenize = 'unicode61'
                    );
                    """)
            }
            try db.execute(sql: """
                CREATE TABLE message_metadata_index (
                    message_id TEXT PRIMARY KEY NOT NULL
                );
                """)
            try db.execute(
                sql: "INSERT INTO message_metadata_index(message_id) VALUES ('legacy-bad-row');"
            )
        }
    }

    private func createFullyLegacySchemaIndexFile(appGroupIdentifier: String) throws {
        let indexURL = try indexDatabaseURL(appGroupIdentifier: appGroupIdentifier)
        try removeSQLiteArtifacts(at: indexURL)
        let dbQueue = try DatabaseQueue(path: indexURL.path)
        try dbQueue.write { db in
            try db.execute(sql: """
                CREATE TABLE message_search (
                    id TEXT NOT NULL,
                    title TEXT NOT NULL
                );
                """)
            try db.execute(sql: """
                CREATE TABLE message_metadata_index (
                    message_id TEXT PRIMARY KEY NOT NULL
                );
                """)
        }
    }

    private func writeLegacyNotificationSnapshot(
        appGroupIdentifier: String,
        fixture: LegacyCompatibilityFixture
    ) throws {
        #expect(
            NotificationContextSnapshotStore.write(
                fixture.snapshot,
                fileManager: .default,
                appGroupIdentifier: appGroupIdentifier
            )
        )
    }

    private func exerciseLegacyFixture(
        store: LocalDataStore,
        appGroupIdentifier: String,
        fixture: LegacyCompatibilityFixture
    ) async throws -> LegacyCompatibilityProbe {
        let counts = try await store.messageCounts()
        #expect(counts.total == fixture.topLevelIDs.count)
        #expect(counts.unread == fixture.topLevelIDs.count)

        let summaries = try await store.loadMessageSummariesPage(
            before: nil,
            limit: 10,
            filter: .all,
            channel: nil,
            tag: nil
        )
        #expect(summaries.map(\.id) == fixture.topLevelIDs)

        let tagPage = try await store.loadMessageSummariesPage(
            before: nil,
            limit: 10,
            filter: .all,
            channel: nil,
            tag: "legacy-fixture"
        )
        #expect(tagPage.map(\.id) == fixture.topLevelIDs)

        let searchCount = try await store.searchMessagesCount(query: "legacy fixture")
        #expect(searchCount == fixture.topLevelIDs.count)

        let searchPage = try await store.searchMessageSummariesPage(
            query: "legacy fixture",
            before: nil,
            limit: 10
        )
        #expect(searchPage.map(\.id) == fixture.topLevelIDs)

        let tagSearchCount = try await store.searchMessagesCount(query: "tag:legacy-fixture")
        #expect(tagSearchCount == fixture.topLevelIDs.count)
        #expect(try await store.searchMessagesCount(query: "tag:shadow-alpha") == 0)

        let tagCounts = try await store.messageTagCounts()
        #expect(tagCounts.first(where: { $0.tag == "legacy-fixture" })?.totalCount == fixture.topLevelIDs.count)
        #expect(tagCounts.contains(where: { $0.tag == "shadow-alpha" }) == false)

        let eventPage = try await store.loadEventMessagesForProjectionPage(before: nil, limit: 10)
        #expect(eventPage.map(\.id) == fixture.eventTimelineIDs)

        let eventTimeline = try await store.loadEventMessagesForProjection(eventId: fixture.eventID)
        #expect(eventTimeline.map(\.id) == fixture.eventTimelineIDs)

        let thingPage = try await store.loadThingMessagesForProjectionPage(before: nil, limit: 10)
        #expect(thingPage.map(\.id) == fixture.thingTimelineIDs)

        let thingTimeline = try await store.loadThingMessagesForProjection(thingId: fixture.thingID)
        #expect(thingTimeline.map(\.id) == fixture.thingTimelineIDs)

        let detail = try #require(try await store.loadMessage(id: fixture.topLevelIDs[0]))
        #expect(detail.title == fixture.detailTitle)

        let snapshot = try #require(
            NotificationContextSnapshotStore.load(
                fileManager: .default,
                appGroupIdentifier: appGroupIdentifier
            )
        )
        #expect(snapshot.events[fixture.eventID]?.title == fixture.snapshot.events[fixture.eventID]?.title)
        #expect(snapshot.things[fixture.thingID]?.title == fixture.snapshot.things[fixture.thingID]?.title)

        return LegacyCompatibilityProbe(
            summaryIDs: summaries.map(\.id),
            searchCount: searchCount,
            searchPageIDs: searchPage.map(\.id),
            tagSearchCount: tagSearchCount,
            tagPageIDs: tagPage.map(\.id),
            eventPageIDs: eventPage.map(\.id),
            eventTimelineIDs: eventTimeline.map(\.id),
            thingPageIDs: thingPage.map(\.id),
            thingTimelineIDs: thingTimeline.map(\.id),
            detailTitle: detail.title,
            snapshotEventTitle: snapshot.events[fixture.eventID]?.title,
            snapshotThingTitle: snapshot.things[fixture.thingID]?.title
        )
    }

    private func assertCanonicalIndexContents(
        appGroupIdentifier: String,
        fixture: LegacyCompatibilityFixture
    ) throws {
        let indexURL = try indexDatabaseURL(appGroupIdentifier: appGroupIdentifier)
        let dbQueue = try DatabaseQueue(path: indexURL.path)
        let facts = try dbQueue.read { db in
            let searchRowCount = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM message_search;"
            ) ?? 0
            let legacyTagCount = try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(DISTINCT message_id)
                    FROM message_metadata_index
                    WHERE key_name = 'tag' AND value_norm = 'legacy-fixture';
                    """
            ) ?? 0
            let shadowTagCount = try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*) FROM message_metadata_index
                    WHERE key_name = 'tag' AND value_norm = 'shadow-alpha';
                    """
            ) ?? 0
            let metadataShadowCount = try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*) FROM message_metadata_index
                    WHERE key_name = 'metadata_tag' AND value_norm = 'shadow-alpha';
                    """
            ) ?? 0
            return (searchRowCount, legacyTagCount, shadowTagCount, metadataShadowCount)
        }
        #expect(facts.0 == fixture.topLevelIDs.count)
        #expect(facts.1 == fixture.topLevelIDs.count)
        #expect(facts.2 == 0)
        #expect(facts.3 == 1)
    }

    private func makeLegacyCompatibilityFixture() -> LegacyCompatibilityFixture {
        let topAlpha = makeMessage(
            id: UUID(uuidString: "60000000-0000-0000-0000-000000000001")!,
            messageId: "legacy-compat-top-alpha",
            notificationRequestId: "req-legacy-compat-top-alpha",
            title: "Legacy fixture alpha",
            body: "legacy fixture alpha body",
            receivedAt: Date(timeIntervalSince1970: 1_800_100_000),
            rawPayload: [
                "entity_type": "message",
                "entity_id": "legacy-message-alpha",
                "tags": #"["legacy-fixture","alpha"]"#,
                "metadata": #"{"kind":"top","tag":"shadow-alpha"}"#,
                "channel_id": "legacy-compat",
            ]
        )
        let topBeta = makeMessage(
            id: UUID(uuidString: "60000000-0000-0000-0000-000000000002")!,
            messageId: "legacy-compat-top-beta",
            notificationRequestId: "req-legacy-compat-top-beta",
            title: "Legacy fixture beta",
            body: "legacy fixture beta body",
            receivedAt: Date(timeIntervalSince1970: 1_800_099_990),
            rawPayload: [
                "entity_type": "message",
                "entity_id": "legacy-message-beta",
                "tags": #"["legacy-fixture","beta"]"#,
                "metadata": #"{"kind":"top"}"#,
                "channel_id": "legacy-compat",
            ]
        )
        let eventOpened = makeMessage(
            id: UUID(uuidString: "60000000-0000-0000-0000-000000000003")!,
            messageId: "legacy-compat-event-opened",
            notificationRequestId: "req-legacy-compat-event-opened",
            title: "Legacy event opened",
            body: "legacy event timeline body 1",
            receivedAt: Date(timeIntervalSince1970: 1_800_099_980),
            rawPayload: [
                "entity_type": "event",
                "entity_id": "legacy-event-001",
                "event_id": "legacy-event-001",
                "event_time": "1800099980000",
                "event_state": "open",
                "channel_id": "legacy-compat",
            ]
        )
        let eventUpdated = makeMessage(
            id: UUID(uuidString: "60000000-0000-0000-0000-000000000004")!,
            messageId: "legacy-compat-event-updated",
            notificationRequestId: "req-legacy-compat-event-updated",
            title: "Legacy event updated",
            body: "legacy event timeline body 2",
            receivedAt: Date(timeIntervalSince1970: 1_800_099_985),
            rawPayload: [
                "entity_type": "event",
                "entity_id": "legacy-event-001",
                "event_id": "legacy-event-001",
                "event_time": "1800099985000",
                "event_state": "ack",
                "channel_id": "legacy-compat",
            ]
        )
        let thingHead = makeMessage(
            id: UUID(uuidString: "60000000-0000-0000-0000-000000000005")!,
            messageId: "legacy-compat-thing-head",
            notificationRequestId: "req-legacy-compat-thing-head",
            title: "Legacy thing head",
            body: "legacy thing head body",
            receivedAt: Date(timeIntervalSince1970: 1_800_099_970),
            rawPayload: [
                "entity_type": "thing",
                "entity_id": "legacy-thing-001",
                "thing_id": "legacy-thing-001",
                "observed_time": "1800099970000",
                "channel_id": "legacy-compat",
            ]
        )
        let thingDetail = makeMessage(
            id: UUID(uuidString: "60000000-0000-0000-0000-000000000006")!,
            messageId: "legacy-compat-thing-detail",
            notificationRequestId: "req-legacy-compat-thing-detail",
            title: "Legacy thing detail",
            body: "legacy thing timeline detail",
            receivedAt: Date(timeIntervalSince1970: 1_800_099_975),
            rawPayload: [
                "entity_type": "message",
                "entity_id": "legacy-thing-message-001",
                "thing_id": "legacy-thing-001",
                "projection_destination": "thing",
                "occurred_at": "1800099975000",
                "channel_id": "legacy-compat",
            ]
        )

        let messages = [topAlpha, topBeta, eventOpened, eventUpdated, thingHead, thingDetail]
        let snapshotInputs = messages
            .filter { $0.eventId != nil || $0.thingId != nil || $0.entityType == "thing" }
            .map { message in
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
        let snapshot = NotificationContextSnapshotProjector.rebuild(
            eventMessages: snapshotInputs.filter { $0.eventId != nil },
            thingMessages: snapshotInputs.filter { $0.thingId != nil || $0.entityId == "legacy-thing-001" },
            source: "legacy-file-fixture"
        )

        return LegacyCompatibilityFixture(
            messages: messages,
            topLevelIDs: [topAlpha.id, topBeta.id],
            eventID: "legacy-event-001",
            eventTimelineIDs: [eventUpdated.id, eventOpened.id],
            thingID: "legacy-thing-001",
            thingTimelineIDs: [thingDetail.id, thingHead.id],
            detailTitle: topAlpha.title,
            snapshot: snapshot
        )
    }

    private func cloneAutomationStorageFixture(
        root: URL,
        sourceAppGroupIdentifier: String,
        destinationAppGroupIdentifier: String
    ) throws {
        let fileManager = FileManager.default
        let sourceAppLocal = root
            .appendingPathComponent("app-local", isDirectory: true)
            .appendingPathComponent(sourceAppGroupIdentifier, isDirectory: true)
        let destinationAppLocal = root
            .appendingPathComponent("app-local", isDirectory: true)
            .appendingPathComponent(destinationAppGroupIdentifier, isDirectory: true)
        let sourceAppGroup = root
            .appendingPathComponent("app-groups", isDirectory: true)
            .appendingPathComponent(sourceAppGroupIdentifier, isDirectory: true)
        let destinationAppGroup = root
            .appendingPathComponent("app-groups", isDirectory: true)
            .appendingPathComponent(destinationAppGroupIdentifier, isDirectory: true)

        if fileManager.fileExists(atPath: destinationAppLocal.path) {
            try fileManager.removeItem(at: destinationAppLocal)
        }
        if fileManager.fileExists(atPath: destinationAppGroup.path) {
            try fileManager.removeItem(at: destinationAppGroup)
        }
        try fileManager.createDirectory(
            at: destinationAppLocal.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: destinationAppGroup.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try fileManager.copyItem(at: sourceAppLocal, to: destinationAppLocal)
        if fileManager.fileExists(atPath: sourceAppGroup.path) {
            try fileManager.copyItem(at: sourceAppGroup, to: destinationAppGroup)
        }
    }

    private func indexDatabaseURL(appGroupIdentifier: String) throws -> URL {
        try AppConstants.appLocalDatabaseDirectory(
            fileManager: .default,
            appGroupIdentifier: appGroupIdentifier
        )
        .appendingPathComponent(AppConstants.messageIndexDatabaseFilename)
    }

    private func rawPayloadJSONString(from rawPayload: [String: AnyCodable]) throws -> String {
        let jsonObject = try normalizeJSONObject(rawPayload.mapValues(\.value))
        let data = try JSONSerialization.data(withJSONObject: jsonObject, options: [.sortedKeys])
        guard let json = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return json
    }

    private func normalizeJSONObject(_ value: Any) throws -> Any {
        switch value {
        case let dictionary as [String: Any]:
            return try dictionary.mapValues { try normalizeJSONObject($0) }
        case let array as [Any]:
            return try array.map { try normalizeJSONObject($0) }
        case let string as String:
            return string
        case let number as NSNumber:
            return number
        case let bool as Bool:
            return bool
        case let int as Int:
            return int
        case let int64 as Int64:
            return int64
        case let double as Double:
            return double
        case let uuid as UUID:
            return uuid.uuidString
        case Optional<Any>.none:
            return NSNull()
        default:
            throw CocoaError(.coderInvalidValue)
        }
    }

    private func fixtureIsTopLevelMessage(_ message: PushMessage) -> Bool {
        let entityType = message.entityType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard entityType == "message" else { return false }
        return normalizedReference(message.eventId) == nil && normalizedReference(message.thingId) == nil
    }

    private func normalizedReference(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private func removeSQLiteArtifacts(at fileURL: URL) throws {
        let sidecars = [
            fileURL,
            URL(fileURLWithPath: fileURL.path + "-wal"),
            URL(fileURLWithPath: fileURL.path + "-shm"),
        ]
        for url in sidecars where FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    private struct LegacyCompatibilityFixture {
        let messages: [PushMessage]
        let topLevelIDs: [UUID]
        let eventID: String
        let eventTimelineIDs: [UUID]
        let thingID: String
        let thingTimelineIDs: [UUID]
        let detailTitle: String
        let snapshot: NotificationContextSnapshot
    }

    private struct LegacyCompatibilityProbe: Equatable {
        let summaryIDs: [UUID]
        let searchCount: Int
        let searchPageIDs: [UUID]
        let tagSearchCount: Int
        let tagPageIDs: [UUID]
        let eventPageIDs: [UUID]
        let eventTimelineIDs: [UUID]
        let thingPageIDs: [UUID]
        let thingTimelineIDs: [UUID]
        let detailTitle: String
        let snapshotEventTitle: String?
        let snapshotThingTitle: String?
    }

    private func automationKeychainItemURL(
        root: URL,
        service: String,
        account: String
    ) -> URL {
        root
            .appendingPathComponent("keychain", isDirectory: true)
            .appendingPathComponent(automationFilesystemComponent(service), isDirectory: true)
            .appendingPathComponent(automationFilesystemComponent(account), isDirectory: false)
            .appendingPathExtension("json")
    }

    private func automationFilesystemComponent(_ value: String) -> String {
        Data(value.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "")
    }
}
