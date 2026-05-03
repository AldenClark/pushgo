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
