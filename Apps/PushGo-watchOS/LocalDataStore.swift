#if os(watchOS)
import Foundation
import SQLite3

private let watchSQLiteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

struct WatchPublicationState: Codable, Hashable, Sendable {
    var syncGenerations: WatchSyncGenerationState
    var mirrorSnapshotContentDigest: String?
    var standaloneProvisioningContentDigest: String?

    static let empty = WatchPublicationState(
        syncGenerations: .zero,
        mirrorSnapshotContentDigest: nil,
        standaloneProvisioningContentDigest: nil
    )
}

struct WatchModeControlPersistenceState: Codable, Hashable, Sendable {
    var desiredMode: WatchMode
    var effectiveMode: WatchMode
    var standaloneReady: Bool
    var switchStatus: WatchModeSwitchStatus
    var lastConfirmedControlGeneration: Int64
    var lastObservedReportedGeneration: Int64

    static let initial = WatchModeControlPersistenceState(
        desiredMode: .standalone,
        effectiveMode: .standalone,
        standaloneReady: false,
        switchStatus: .idle,
        lastConfirmedControlGeneration: 0,
        lastObservedReportedGeneration: 0
    )
}

struct DataPageVisibilitySnapshot: Codable, Hashable, Sendable {
    var messageEnabled: Bool
    var eventEnabled: Bool
    var thingEnabled: Bool

    static let `default` = DataPageVisibilitySnapshot(
        messageEnabled: true,
        eventEnabled: true,
        thingEnabled: true
    )
}

struct WatchProvisioningState: Hashable, Sendable, Codable {
    let schemaVersion: Int
    let generation: Int64
    let contentDigest: String
    let appliedAt: Date
    let modeAtApply: WatchMode
    let sourceControlGeneration: Int64
}

struct EntityOpenTarget: Hashable, Sendable {
    let entityType: String
    let entityId: String
}

private struct WatchLocalSettings: Codable, Sendable {
    var watchMode: WatchMode
    var watchSyncGenerations: WatchSyncGenerationState
    var watchPublicationState: WatchPublicationState
    var watchModeControlState: WatchModeControlPersistenceState
    var dataPageVisibility: DataPageVisibilitySnapshot
    var launchAtLoginEnabled: Bool?

    static let `default` = WatchLocalSettings(
        watchMode: .standalone,
        watchSyncGenerations: .zero,
        watchPublicationState: .empty,
        watchModeControlState: .initial,
        dataPageVisibility: .default,
        launchAtLoginEnabled: nil
    )
}

actor LocalDataStore {
    struct StorageState: Sendable, Equatable {
        enum Mode: Sendable {
            case persistent
            case unavailable
        }

        let mode: Mode
        let reason: String?
    }

    nonisolated let storageState: StorageState

    private let channelSubscriptionStore = ChannelSubscriptionStore()
    private let localConfigStore = LocalKeychainConfigStore()
    private let pushTokenStore = PushTokenStore()
    private let deviceKeyStore = ProviderDeviceKeyStore()
    private let sqliteStore: WatchLocalSQLiteStore?
    private let defaults: UserDefaults
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private static let settingsKey = "io.ethan.pushgo.watch.local-settings.v1"
    private static let trackedGatewaysKey = "io.ethan.pushgo.watch.tracked-gateways.v1"

    init(
        fileManager: FileManager = .default,
        appGroupIdentifier: String = AppConstants.appGroupIdentifier
    ) {
        KeychainSharedAccessMigration.migrateLegacyItemsToSharedAccessGroup()
        defaults = AppConstants.sharedUserDefaults(suiteName: appGroupIdentifier)
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601

        do {
            sqliteStore = try WatchLocalSQLiteStore(
                fileManager: fileManager,
                appGroupIdentifier: appGroupIdentifier
            )
            storageState = StorageState(mode: .persistent, reason: nil)
        } catch {
            sqliteStore = nil
            storageState = StorageState(mode: .unavailable, reason: error.localizedDescription)
        }
    }

    private var storeUnavailableError: AppError {
        AppError.localStore(storageState.reason ?? "Local store unavailable.")
    }

    private func requireSQLiteStore() throws -> WatchLocalSQLiteStore {
        guard let sqliteStore else {
            throw storeUnavailableError
        }
        return sqliteStore
    }

    func flushWrites() async {}
    func warmCachesIfNeeded() async {}

    func loadServerConfig() async throws -> ServerConfig? {
        if let config = try? localConfigStore.loadServerConfig()?.normalized() {
            return config
        }
        return try await loadWatchProvisioningServerConfig()?.normalized()
    }

    func saveServerConfig(_ config: ServerConfig?) async throws {
        try localConfigStore.saveServerConfig(config?.normalized())
    }

    func loadChannelSubscriptions(includeDeleted: Bool) async throws -> [ChannelSubscription] {
        let gateways = await allTrackedGatewayKeys(includeProvisionedGateway: true)
        var result: [ChannelSubscription] = []
        for gateway in gateways.sorted() {
            let stored = try channelSubscriptionStore.loadSubscriptions(gatewayKey: gateway)
            result.append(contentsOf: stored.compactMap { item in
                if !includeDeleted && item.isDeleted {
                    return nil
                }
                let displayName = item.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
                let channelId = item.channelId.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !channelId.isEmpty else { return nil }
                return ChannelSubscription(
                    gateway: gateway,
                    channelId: channelId,
                    displayName: displayName.isEmpty ? channelId : displayName,
                    updatedAt: item.updatedAt,
                    lastSyncedAt: item.lastSyncedAt
                )
            })
        }
        result.sort {
            if $0.updatedAt == $1.updatedAt {
                if $0.gateway == $1.gateway {
                    return $0.channelId < $1.channelId
                }
                return $0.gateway < $1.gateway
            }
            return $0.updatedAt > $1.updatedAt
        }
        return result
    }

    func updateChannelDisplayName(
        gateway: String,
        channelId: String,
        displayName: String
    ) async throws {
        try await mutateChannelSubscription(gateway: gateway, channelId: channelId) { existing in
            existing.displayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    func updateChannelLastSynced(
        gateway: String,
        channelId: String,
        date: Date
    ) async throws {
        try await mutateChannelSubscription(gateway: gateway, channelId: channelId) { existing in
            existing.lastSyncedAt = date
        }
    }

    func softDeleteChannelSubscription(gateway: String, channelId: String) async throws {
        try await mutateChannelSubscription(gateway: gateway, channelId: channelId) { existing in
            existing.isDeleted = true
            existing.deletedAt = Date()
            existing.updatedAt = existing.deletedAt ?? Date()
            existing.password = ""
        }
    }

    func softDeleteChannelSubscription(
        gateway: String,
        channelId: String,
        deletedAt: Date
    ) async throws {
        try await mutateChannelSubscription(gateway: gateway, channelId: channelId) { existing in
            existing.isDeleted = true
            existing.deletedAt = deletedAt
            existing.updatedAt = deletedAt
            existing.password = ""
        }
    }

    @discardableResult
    func upsertChannelSubscription(
        gateway: String,
        channelId: String,
        displayName: String,
        password: String?,
        lastSyncedAt: Date?,
        updatedAt: Date,
        isDeleted: Bool,
        deletedAt: Date?
    ) async throws -> ChannelSubscription {
        let normalizedGateway = gateway.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedChannelId = channelId.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedDisplayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedPassword = (password ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedGateway.isEmpty, !normalizedChannelId.isEmpty else {
            throw AppError.noServer
        }

        var stored = try channelSubscriptionStore.loadSubscriptions(gatewayKey: normalizedGateway)
        let next = KeychainChannelSubscription(
            channelId: normalizedChannelId,
            displayName: normalizedDisplayName.isEmpty ? normalizedChannelId : normalizedDisplayName,
            password: isDeleted ? "" : normalizedPassword,
            updatedAt: updatedAt,
            lastSyncedAt: lastSyncedAt,
            isDeleted: isDeleted,
            deletedAt: isDeleted ? deletedAt : nil
        )

        if let index = stored.firstIndex(where: { $0.channelId == normalizedChannelId }) {
            stored[index] = next
        } else {
            stored.append(next)
        }

        try channelSubscriptionStore.saveSubscriptions(gatewayKey: normalizedGateway, subscriptions: stored)
        await rememberTrackedGateway(normalizedGateway)
        return ChannelSubscription(
            gateway: normalizedGateway,
            channelId: normalizedChannelId,
            displayName: next.displayName,
            updatedAt: updatedAt,
            lastSyncedAt: lastSyncedAt
        )
    }

    func activeChannelCredentials(
        gateway: String
    ) async throws -> [(channelId: String, password: String)] {
        let normalizedGateway = gateway.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedGateway.isEmpty else { return [] }
        let stored = try channelSubscriptionStore.loadSubscriptions(gatewayKey: normalizedGateway)
        return stored.compactMap { item in
            let channelId = item.channelId.trimmingCharacters(in: .whitespacesAndNewlines)
            let password = item.password.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !item.isDeleted, !channelId.isEmpty, !password.isEmpty else { return nil }
            return (channelId: channelId, password: password)
        }
    }

    func cachedPushToken(for platform: String) async -> String? {
        try? pushTokenStore.load(platform: platform)
    }

    func saveCachedPushToken(_ token: String?, for platform: String) async {
        try? pushTokenStore.save(token: token, platform: platform)
    }

    func cachedDeviceKey(for platform: String) async -> String? {
        deviceKeyStore.load(platform: platform)
    }

    @discardableResult
    func saveCachedDeviceKey(
        _ deviceKey: String?,
        for platform: String
    ) async -> ProviderDeviceKeyStore.SaveResult {
        deviceKeyStore.save(deviceKey: deviceKey, platform: platform)
    }

    func loadLaunchAtLoginPreference() async -> Bool? {
        await loadSettings().launchAtLoginEnabled
    }

    func saveLaunchAtLoginPreference(_ isEnabled: Bool) async {
        var settings = await loadSettings()
        settings.launchAtLoginEnabled = isEnabled
        await saveSettings(settings)
    }

    func loadDataPageVisibility() async -> DataPageVisibilitySnapshot {
        await loadSettings().dataPageVisibility
    }

    func saveDataPageVisibility(_ visibility: DataPageVisibilitySnapshot) async {
        var settings = await loadSettings()
        settings.dataPageVisibility = visibility
        await saveSettings(settings)
    }

    func loadWatchMode() async -> WatchMode {
        await loadSettings().watchMode
    }

    func saveWatchMode(_ mode: WatchMode) async {
        var settings = await loadSettings()
        settings.watchMode = mode
        await saveSettings(settings)
    }

    func loadWatchModeControlState() async -> WatchModeControlPersistenceState {
        await loadSettings().watchModeControlState
    }

    func saveWatchModeControlState(_ state: WatchModeControlPersistenceState) async {
        var settings = await loadSettings()
        settings.watchModeControlState = state
        await saveSettings(settings)
    }

    func loadWatchSyncGenerationState() async -> WatchSyncGenerationState {
        await loadSettings().watchSyncGenerations
    }

    func saveWatchSyncGenerationState(_ state: WatchSyncGenerationState) async {
        var settings = await loadSettings()
        settings.watchSyncGenerations = state
        settings.watchPublicationState.syncGenerations = state
        await saveSettings(settings)
    }

    func loadWatchPublicationState() async -> WatchPublicationState {
        await loadSettings().watchPublicationState
    }

    func saveWatchPublicationState(_ state: WatchPublicationState) async {
        var settings = await loadSettings()
        settings.watchPublicationState = state
        settings.watchSyncGenerations = state.syncGenerations
        await saveSettings(settings)
    }

    func loadWatchProvisioningServerConfig() async throws -> ServerConfig? {
        let sqliteStore = try requireSQLiteStore()
        return try sqliteStore.loadProvisioningServerConfig()
    }

    func saveWatchProvisioningServerConfig(_ config: ServerConfig?) async throws {
        let sqliteStore = try requireSQLiteStore()
        try sqliteStore.saveProvisioningServerConfig(config?.normalized())
    }

    func loadWatchProvisioningState() async -> WatchProvisioningState? {
        guard let sqliteStore else { return nil }
        return try? sqliteStore.loadProvisioningState()
    }

    func saveWatchProvisioningState(_ state: WatchProvisioningState?) async {
        guard let sqliteStore else { return }
        try? sqliteStore.saveProvisioningState(state)
    }

    func applyWatchStandaloneProvisioning(
        _ snapshot: WatchStandaloneProvisioningSnapshot,
        sourceControlGeneration: Int64
    ) async throws -> WatchProvisioningState {
        let sqliteStore = try requireSQLiteStore()
        let normalizedConfig = snapshot.serverConfig?.normalized()
        let normalizedGateway = normalizedConfig?.gatewayKey ?? ""
        let provisioningState = WatchProvisioningState(
            schemaVersion: WatchConnectivitySchema.currentVersion,
            generation: snapshot.generation,
            contentDigest: snapshot.contentDigest,
            appliedAt: Date(),
            modeAtApply: .standalone,
            sourceControlGeneration: sourceControlGeneration
        )

        let existing = try await loadChannelSubscriptions(includeDeleted: true)
        let incomingByGateway = Dictionary(grouping: snapshot.channels) {
            $0.gateway.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        for gateway in Set(existing.map(\.gateway)).union(incomingByGateway.keys) where !gateway.isEmpty {
            let incoming = incomingByGateway[gateway] ?? []
            let incomingKeys = Set(incoming.map { $0.channelId.trimmingCharacters(in: .whitespacesAndNewlines) })
            let current = try channelSubscriptionStore.loadSubscriptions(gatewayKey: gateway)
            var next = current

            for item in incoming {
                let channelId = item.channelId.trimmingCharacters(in: .whitespacesAndNewlines)
                let password = item.password.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !channelId.isEmpty, !password.isEmpty else { continue }
                let displayName = item.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
                if let index = next.firstIndex(where: { $0.channelId == channelId }) {
                    next[index] = KeychainChannelSubscription(
                        channelId: channelId,
                        displayName: displayName,
                        password: password,
                        updatedAt: item.updatedAt,
                        lastSyncedAt: nil,
                        isDeleted: false,
                        deletedAt: nil
                    )
                } else {
                    next.append(
                        KeychainChannelSubscription(
                            channelId: channelId,
                            displayName: displayName,
                            password: password,
                            updatedAt: item.updatedAt,
                            lastSyncedAt: nil,
                            isDeleted: false,
                            deletedAt: nil
                        )
                    )
                }
            }

            let deletedAt = provisioningState.appliedAt
            for index in next.indices {
                if !incomingKeys.contains(next[index].channelId.trimmingCharacters(in: .whitespacesAndNewlines)) {
                    next[index].isDeleted = true
                    next[index].deletedAt = deletedAt
                    next[index].updatedAt = deletedAt
                    next[index].password = ""
                }
            }

            try channelSubscriptionStore.saveSubscriptions(gatewayKey: gateway, subscriptions: next)
            await rememberTrackedGateway(gateway)
        }

        if !normalizedGateway.isEmpty {
            await rememberTrackedGateway(normalizedGateway)
        }
        try sqliteStore.saveProvisioningServerConfig(normalizedConfig)
        try sqliteStore.saveProvisioningState(provisioningState)
        return provisioningState
    }

    func mergeWatchMirrorSnapshot(_ snapshot: WatchMirrorSnapshot) async throws {
        let sqliteStore = try requireSQLiteStore()
        try sqliteStore.mergeMirrorSnapshot(snapshot)
    }

    func clearWatchLightStore() async throws {
        let sqliteStore = try requireSQLiteStore()
        try sqliteStore.clearWatchLightStore()
    }

    func loadWatchLightMessages() async throws -> [WatchLightMessage] {
        let sqliteStore = try requireSQLiteStore()
        return try sqliteStore.loadWatchLightMessages()
    }

    func loadWatchLightMessage(messageId: String) async throws -> WatchLightMessage? {
        let sqliteStore = try requireSQLiteStore()
        return try sqliteStore.loadWatchLightMessage(messageId: messageId)
    }

    func loadWatchLightMessage(notificationRequestId: String) async throws -> WatchLightMessage? {
        let sqliteStore = try requireSQLiteStore()
        return try sqliteStore.loadWatchLightMessage(notificationRequestId: notificationRequestId)
    }

    func loadWatchLightEvents() async throws -> [WatchLightEvent] {
        let sqliteStore = try requireSQLiteStore()
        return try sqliteStore.loadWatchLightEvents()
    }

    func loadWatchLightEvent(eventId: String) async throws -> WatchLightEvent? {
        let sqliteStore = try requireSQLiteStore()
        return try sqliteStore.loadWatchLightEvent(eventId: eventId)
    }

    func loadWatchLightThings() async throws -> [WatchLightThing] {
        let sqliteStore = try requireSQLiteStore()
        return try sqliteStore.loadWatchLightThings()
    }

    func loadWatchLightThing(thingId: String) async throws -> WatchLightThing? {
        let sqliteStore = try requireSQLiteStore()
        return try sqliteStore.loadWatchLightThing(thingId: thingId)
    }

    func upsertWatchLightPayload(_ payload: WatchLightPayload) async throws {
        let sqliteStore = try requireSQLiteStore()
        try sqliteStore.upsertWatchLightPayload(payload)
    }

    func ingestWatchDelivery(_ record: WatchDeliveryIngestRecord) async throws -> WatchDeliveryIngestResult {
        let sqliteStore = try requireSQLiteStore()
        return try sqliteStore.ingestWatchDelivery(record)
    }

    func loadWatchDeliveryRecords() async throws -> [WatchDeliveryRecord] {
        let sqliteStore = try requireSQLiteStore()
        return try sqliteStore.loadWatchDeliveryRecords()
    }

    func markWatchLightMessageRead(messageId: String) async throws -> WatchLightMessage? {
        let sqliteStore = try requireSQLiteStore()
        return try sqliteStore.markWatchLightMessageRead(messageId: messageId)
    }

    func deleteWatchLightMessage(messageId: String) async throws {
        let sqliteStore = try requireSQLiteStore()
        try sqliteStore.deleteWatchLightMessage(messageId: messageId)
    }

    func enqueueWatchMirrorAction(_ action: WatchMirrorAction) async throws {
        let sqliteStore = try requireSQLiteStore()
        try sqliteStore.enqueueWatchMirrorAction(action)
    }

    func deleteAllMessages() async throws {
        let sqliteStore = try requireSQLiteStore()
        try sqliteStore.clearWatchLightStore()
    }

    func loadWatchMirrorActions() async throws -> [WatchMirrorAction] {
        let sqliteStore = try requireSQLiteStore()
        return try sqliteStore.loadWatchMirrorActions()
    }

    func deleteWatchMirrorActions(actionIds: [String]) async throws {
        let sqliteStore = try requireSQLiteStore()
        try sqliteStore.deleteWatchMirrorActions(actionIds: actionIds)
    }

    private func loadSettings() async -> WatchLocalSettings {
        guard let data = defaults.data(forKey: Self.settingsKey),
              let decoded = try? decoder.decode(WatchLocalSettings.self, from: data)
        else {
            return .default
        }
        return decoded
    }

    private func saveSettings(_ settings: WatchLocalSettings) async {
        guard let data = try? encoder.encode(settings) else { return }
        defaults.set(data, forKey: Self.settingsKey)
    }

    private func allTrackedGatewayKeys(includeProvisionedGateway: Bool) async -> Set<String> {
        var values = Set(defaults.stringArray(forKey: Self.trackedGatewaysKey) ?? [])
        if includeProvisionedGateway,
           let config = try? await loadWatchProvisioningServerConfig()
        {
            let gateway = config.gatewayKey.trimmingCharacters(in: .whitespacesAndNewlines)
            if !gateway.isEmpty {
                values.insert(gateway)
            }
        }
        return Set(values.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
    }

    private func rememberTrackedGateway(_ gateway: String) async {
        let normalized = gateway.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }
        var values = Set(defaults.stringArray(forKey: Self.trackedGatewaysKey) ?? [])
        values.insert(normalized)
        defaults.set(Array(values).sorted(), forKey: Self.trackedGatewaysKey)
    }

    private func mutateChannelSubscription(
        gateway: String,
        channelId: String,
        mutate: (inout KeychainChannelSubscription) -> Void
    ) async throws {
        let normalizedGateway = gateway.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedChannelId = channelId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedGateway.isEmpty, !normalizedChannelId.isEmpty else { return }
        var stored = try channelSubscriptionStore.loadSubscriptions(gatewayKey: normalizedGateway)
        if let index = stored.firstIndex(where: { $0.channelId == normalizedChannelId }) {
            mutate(&stored[index])
            if stored[index].displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                stored[index].displayName = normalizedChannelId
            }
        } else {
            var created = KeychainChannelSubscription(
                channelId: normalizedChannelId,
                displayName: normalizedChannelId,
                password: "",
                updatedAt: Date(),
                lastSyncedAt: nil,
                isDeleted: false,
                deletedAt: nil
            )
            mutate(&created)
            stored.append(created)
        }
        try channelSubscriptionStore.saveSubscriptions(gatewayKey: normalizedGateway, subscriptions: stored)
        await rememberTrackedGateway(normalizedGateway)
    }
}

private final class WatchLocalSQLiteStore {
    private struct TableColumn {
        let name: String
    }

    private enum StoreError: Error {
        case missingAppGroup(String)
        case sqliteOpenFailed(code: Int32)
        case sqlitePrepareFailed(String)
        case sqliteStepFailed(String)
    }

    private let decoder: JSONDecoder
    private let encoder: JSONEncoder
    private var db: OpaquePointer?

    init(
        fileManager: FileManager = .default,
        appGroupIdentifier: String = AppConstants.appGroupIdentifier
    ) throws {
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        let storeURL = try Self.storeURL(
            fileManager: fileManager,
            appGroupIdentifier: appGroupIdentifier,
            filename: AppConstants.databaseStoreFilename
        )

        var openedDb: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        let result = sqlite3_open_v2(storeURL.path, &openedDb, flags, nil)
        guard result == SQLITE_OK, let openedDb else {
            if let openedDb { sqlite3_close(openedDb) }
            throw StoreError.sqliteOpenFailed(code: result)
        }

        try Self.execute("PRAGMA journal_mode = WAL;", db: openedDb)
        try Self.execute("PRAGMA synchronous = NORMAL;", db: openedDb)
        try Self.execute("PRAGMA foreign_keys = ON;", db: openedDb)
        try Self.execute("PRAGMA busy_timeout = 5000;", db: openedDb)
        try Self.createSchemaIfNeeded(db: openedDb)
        db = openedDb
    }

    deinit {
        if let db {
            sqlite3_close(db)
        }
    }

    func loadProvisioningServerConfig() throws -> ServerConfig? {
        guard let data = try loadAppSetting(column: "watch_provisioning_server_config_data_base64") else {
            return nil
        }
        guard let decoded = Data(base64Encoded: data) else { return nil }
        return try decoder.decode(ServerConfig.self, from: decoded)
    }

    func saveProvisioningServerConfig(_ config: ServerConfig?) throws {
        let base64 = try config.flatMap { try encoder.encode($0).base64EncodedString() }
        try upsertAppSettings(columns: ["watch_provisioning_server_config_data_base64": base64])
    }

    func loadProvisioningState() throws -> WatchProvisioningState? {
        let row = try loadProvisioningRow()
        guard let schemaVersionText = row["watch_provisioning_schema_version"],
              let schemaVersion = Int(schemaVersionText),
              let generationText = row["watch_provisioning_generation"],
              let generation = Int64(generationText),
              let contentDigest = row["watch_provisioning_content_digest"],
              let appliedAtText = row["watch_provisioning_applied_at"],
              let appliedAtSeconds = Double(appliedAtText),
              let modeRaw = row["watch_provisioning_mode_raw_value"],
              let mode = WatchMode(rawValue: modeRaw)
        else {
            return nil
        }
        let sourceGeneration = Int64(row["watch_provisioning_source_control_generation"] ?? "0") ?? 0
        return WatchProvisioningState(
            schemaVersion: schemaVersion,
            generation: generation,
            contentDigest: contentDigest,
            appliedAt: Date(timeIntervalSince1970: appliedAtSeconds),
            modeAtApply: mode,
            sourceControlGeneration: sourceGeneration
        )
    }

    func saveProvisioningState(_ state: WatchProvisioningState?) throws {
        guard let state else {
            try upsertAppSettings(columns: [
                "watch_provisioning_schema_version": nil,
                "watch_provisioning_generation": nil,
                "watch_provisioning_content_digest": nil,
                "watch_provisioning_applied_at": nil,
                "watch_provisioning_mode_raw_value": nil,
                "watch_provisioning_source_control_generation": nil,
            ])
            return
        }
        try upsertAppSettings(columns: [
            "watch_provisioning_schema_version": String(state.schemaVersion),
            "watch_provisioning_generation": String(state.generation),
            "watch_provisioning_content_digest": state.contentDigest,
            "watch_provisioning_applied_at": String(state.appliedAt.timeIntervalSince1970),
            "watch_provisioning_mode_raw_value": state.modeAtApply.rawValue,
            "watch_provisioning_source_control_generation": String(state.sourceControlGeneration),
        ])
    }

    func mergeMirrorSnapshot(_ snapshot: WatchMirrorSnapshot) throws {
        try writeTransaction {
            for message in snapshot.messages { try upsertWatchLightMessage(message) }
            for event in snapshot.events { try upsertWatchLightEvent(event) }
            for thing in snapshot.things { try upsertWatchLightThing(thing) }
        }
        DarwinNotificationPoster.post(name: AppConstants.messageSyncNotificationName)
    }

    func clearWatchLightStore() throws {
        try writeTransaction {
            try execute("DELETE FROM watch_light_messages;")
            try execute("DELETE FROM watch_light_events;")
            try execute("DELETE FROM watch_light_things;")
            try execute("DELETE FROM watch_mirror_action_queue;")
            try execute("DELETE FROM watch_delivery_records;")
        }
        DarwinNotificationPoster.post(name: AppConstants.messageSyncNotificationName)
    }

    func loadWatchLightMessages() throws -> [WatchLightMessage] {
        let statement = try prepare("SELECT message_id, title, body, image_url, url, severity, received_at, is_read, entity_type, entity_id, notification_request_id FROM watch_light_messages ORDER BY received_at DESC, message_id DESC;")
        defer { sqlite3_finalize(statement) }
        var items: [WatchLightMessage] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            items.append(Self.decodeWatchLightMessage(statement))
        }
        return items
    }

    func loadWatchLightMessage(messageId: String) throws -> WatchLightMessage? {
        let normalized = messageId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        let statement = try prepare("SELECT message_id, title, body, image_url, url, severity, received_at, is_read, entity_type, entity_id, notification_request_id FROM watch_light_messages WHERE message_id = ? LIMIT 1;")
        defer { sqlite3_finalize(statement) }
        try bindText(statement, index: 1, value: normalized)
        return sqlite3_step(statement) == SQLITE_ROW ? Self.decodeWatchLightMessage(statement) : nil
    }

    func loadWatchLightMessage(notificationRequestId: String) throws -> WatchLightMessage? {
        let normalized = notificationRequestId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        let statement = try prepare("SELECT message_id, title, body, image_url, url, severity, received_at, is_read, entity_type, entity_id, notification_request_id FROM watch_light_messages WHERE notification_request_id = ? ORDER BY received_at DESC, message_id DESC LIMIT 1;")
        defer { sqlite3_finalize(statement) }
        try bindText(statement, index: 1, value: normalized)
        return sqlite3_step(statement) == SQLITE_ROW ? Self.decodeWatchLightMessage(statement) : nil
    }

    func loadWatchLightEvents() throws -> [WatchLightEvent] {
        let statement = try prepare("SELECT event_id, title, summary, state, severity, decryption_state, image_url, updated_at FROM watch_light_events ORDER BY updated_at DESC, event_id DESC;")
        defer { sqlite3_finalize(statement) }
        var items: [WatchLightEvent] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            items.append(Self.decodeWatchLightEvent(statement))
        }
        return items
    }

    func loadWatchLightEvent(eventId: String) throws -> WatchLightEvent? {
        let normalized = eventId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        let statement = try prepare("SELECT event_id, title, summary, state, severity, decryption_state, image_url, updated_at FROM watch_light_events WHERE event_id = ? LIMIT 1;")
        defer { sqlite3_finalize(statement) }
        try bindText(statement, index: 1, value: normalized)
        return sqlite3_step(statement) == SQLITE_ROW ? Self.decodeWatchLightEvent(statement) : nil
    }

    func loadWatchLightThings() throws -> [WatchLightThing] {
        let statement = try prepare("SELECT thing_id, title, summary, attrs_json, decryption_state, image_url, updated_at FROM watch_light_things ORDER BY updated_at DESC, thing_id DESC;")
        defer { sqlite3_finalize(statement) }
        var items: [WatchLightThing] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            items.append(Self.decodeWatchLightThing(statement))
        }
        return items
    }

    func loadWatchLightThing(thingId: String) throws -> WatchLightThing? {
        let normalized = thingId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        let statement = try prepare("SELECT thing_id, title, summary, attrs_json, decryption_state, image_url, updated_at FROM watch_light_things WHERE thing_id = ? LIMIT 1;")
        defer { sqlite3_finalize(statement) }
        try bindText(statement, index: 1, value: normalized)
        return sqlite3_step(statement) == SQLITE_ROW ? Self.decodeWatchLightThing(statement) : nil
    }

    func upsertWatchLightPayload(_ payload: WatchLightPayload) throws {
        try writeTransaction {
            switch payload {
            case let .message(message):
                try upsertWatchLightMessage(message)
            case let .event(event):
                try upsertWatchLightEvent(event)
            case let .thing(thing):
                try upsertWatchLightThing(thing)
            }
        }
        DarwinNotificationPoster.post(name: AppConstants.messageSyncNotificationName)
    }

    func ingestWatchDelivery(_ record: WatchDeliveryIngestRecord) throws -> WatchDeliveryIngestResult {
        let identity = Self.watchBusinessIdentity(for: record.payload)
        let result: WatchDeliveryIngestResult = try writeTransaction {
            if let existing = try loadWatchDeliveryRecord(
                gatewayKey: record.metadata.gatewayKey,
                deliveryId: record.metadata.deliveryId
            ) {
                let projectionPayload = Self.payloadForDuplicateDelivery(
                    record.payload,
                    existing: existing
                )
                let projectionIdentity = Self.watchBusinessIdentity(for: projectionPayload)
                switch projectionPayload {
                case let .message(message):
                    try upsertWatchLightMessage(message)
                case let .event(event):
                    try upsertWatchLightEvent(event)
                case let .thing(thing):
                    try upsertWatchLightThing(thing)
                }
                let merged = Self.mergedWatchDeliveryRecord(
                    existing: existing,
                    incoming: record.metadata,
                    identity: projectionIdentity
                )
                try upsertWatchDeliveryRecord(merged)
                return WatchDeliveryIngestResult(
                    disposition: .duplicateDelivery,
                    deliveryRecord: merged
                )
            }

            switch record.payload {
            case let .message(message):
                try upsertWatchLightMessage(message)
            case let .event(event):
                try upsertWatchLightEvent(event)
            case let .thing(thing):
                try upsertWatchLightThing(thing)
            }

            let deliveryRecord = WatchDeliveryRecord(
                deliveryId: record.metadata.deliveryId,
                gatewayKey: record.metadata.gatewayKey,
                watchDeviceKey: record.metadata.watchDeviceKey,
                messageId: identity.messageId,
                entityType: identity.entityType,
                entityId: identity.entityId,
                ingressSource: record.metadata.ingressSource,
                contentDigest: record.metadata.contentDigest,
                persistedAt: record.metadata.persistedAt,
                serverAckState: record.metadata.serverAckState
            )
            try upsertWatchDeliveryRecord(deliveryRecord)
            return WatchDeliveryIngestResult(
                disposition: .inserted,
                deliveryRecord: deliveryRecord
            )
        }
        DarwinNotificationPoster.post(name: AppConstants.messageSyncNotificationName)
        return result
    }

    func loadWatchDeliveryRecords() throws -> [WatchDeliveryRecord] {
        let statement = try prepare("SELECT gateway_key, delivery_id, watch_device_key, message_id, entity_type, entity_id, ingress_source, content_digest, persisted_at, server_ack_state FROM watch_delivery_records ORDER BY persisted_at DESC, gateway_key ASC, delivery_id ASC;")
        defer { sqlite3_finalize(statement) }
        var records: [WatchDeliveryRecord] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            records.append(Self.decodeWatchDeliveryRecord(statement))
        }
        return records
    }

    func markWatchLightMessageRead(messageId: String) throws -> WatchLightMessage? {
        let normalized = messageId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        let statement = try prepare("UPDATE watch_light_messages SET is_read = 1 WHERE message_id = ?;")
        defer { sqlite3_finalize(statement) }
        try bindText(statement, index: 1, value: normalized)
        try stepDone(statement)
        DarwinNotificationPoster.post(name: AppConstants.messageSyncNotificationName)
        return try loadWatchLightMessage(messageId: normalized)
    }

    func deleteWatchLightMessage(messageId: String) throws {
        let normalized = messageId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }
        let statement = try prepare("DELETE FROM watch_light_messages WHERE message_id = ?;")
        defer { sqlite3_finalize(statement) }
        try bindText(statement, index: 1, value: normalized)
        try stepDone(statement)
        DarwinNotificationPoster.post(name: AppConstants.messageSyncNotificationName)
    }

    func enqueueWatchMirrorAction(_ action: WatchMirrorAction) throws {
        let statement = try prepare("INSERT INTO watch_mirror_action_queue (action_id, kind, message_id, issued_at) VALUES (?, ?, ?, ?) ON CONFLICT(action_id) DO UPDATE SET kind = excluded.kind, message_id = excluded.message_id, issued_at = excluded.issued_at;")
        defer { sqlite3_finalize(statement) }
        try bindText(statement, index: 1, value: action.actionId)
        try bindText(statement, index: 2, value: action.kind.rawValue)
        try bindText(statement, index: 3, value: action.messageId)
        sqlite3_bind_double(statement, 4, action.issuedAt.timeIntervalSince1970)
        try stepDone(statement)
    }

    func loadWatchMirrorActions() throws -> [WatchMirrorAction] {
        let statement = try prepare("SELECT action_id, kind, message_id, issued_at FROM watch_mirror_action_queue ORDER BY issued_at ASC, action_id ASC;")
        defer { sqlite3_finalize(statement) }
        var items: [WatchMirrorAction] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            items.append(Self.decodeWatchMirrorAction(statement))
        }
        return items
    }

    func deleteWatchMirrorActions(actionIds: [String]) throws {
        let normalized = actionIds.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !normalized.isEmpty else { return }
        let placeholders = Array(repeating: "?", count: normalized.count).joined(separator: ", ")
        let statement = try prepare("DELETE FROM watch_mirror_action_queue WHERE action_id IN (\(placeholders));")
        defer { sqlite3_finalize(statement) }
        for (index, value) in normalized.enumerated() {
            try bindText(statement, index: Int32(index + 1), value: value)
        }
        try stepDone(statement)
    }

    private func loadAppSetting(column: String) throws -> String? {
        let statement = try prepare("SELECT \(column) FROM app_settings WHERE id = 'default' LIMIT 1;")
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return Self.columnText(statement, index: 0)
    }

    private func loadProvisioningRow() throws -> [String: String] {
        let statement = try prepare("SELECT watch_provisioning_schema_version, watch_provisioning_generation, watch_provisioning_content_digest, watch_provisioning_applied_at, watch_provisioning_mode_raw_value, watch_provisioning_source_control_generation FROM app_settings WHERE id = 'default' LIMIT 1;")
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return [:] }
        return [
            "watch_provisioning_schema_version": Self.columnText(statement, index: 0),
            "watch_provisioning_generation": Self.columnText(statement, index: 1),
            "watch_provisioning_content_digest": Self.columnText(statement, index: 2),
            "watch_provisioning_applied_at": Self.columnText(statement, index: 3),
            "watch_provisioning_mode_raw_value": Self.columnText(statement, index: 4),
            "watch_provisioning_source_control_generation": Self.columnText(statement, index: 5),
        ].compactMapValues { $0 }
    }

    private func upsertAppSettings(columns: [String: String?]) throws {
        let allColumns = Array(columns.keys).sorted()
        let insertColumns = (["id"] + allColumns).joined(separator: ", ")
        let placeholders = Array(repeating: "?", count: allColumns.count + 1).joined(separator: ", ")
        let updateClause = allColumns.map { "\($0) = excluded.\($0)" }.joined(separator: ", ")
        let sql = "INSERT INTO app_settings (\(insertColumns)) VALUES (\(placeholders)) ON CONFLICT(id) DO UPDATE SET \(updateClause), updated_at = excluded.updated_at;"
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try bindText(statement, index: 1, value: "default")
        for (offset, column) in allColumns.enumerated() {
            if column == "updated_at" {
                sqlite3_bind_double(statement, Int32(offset + 2), Date().timeIntervalSince1970)
            } else {
                try bindText(statement, index: Int32(offset + 2), value: columns[column] ?? nil)
            }
        }
        try stepDone(statement)
    }

    @discardableResult
    private func writeTransaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE TRANSACTION;")
        do {
            let result = try body()
            try execute("COMMIT;")
            return result
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    private func loadWatchDeliveryRecord(
        gatewayKey: String,
        deliveryId: String
    ) throws -> WatchDeliveryRecord? {
        let statement = try prepare("SELECT gateway_key, delivery_id, watch_device_key, message_id, entity_type, entity_id, ingress_source, content_digest, persisted_at, server_ack_state FROM watch_delivery_records WHERE gateway_key = ? AND delivery_id = ? LIMIT 1;")
        defer { sqlite3_finalize(statement) }
        try bindText(statement, index: 1, value: gatewayKey)
        try bindText(statement, index: 2, value: deliveryId)
        return sqlite3_step(statement) == SQLITE_ROW ? Self.decodeWatchDeliveryRecord(statement) : nil
    }

    private func upsertWatchDeliveryRecord(_ record: WatchDeliveryRecord) throws {
        let statement = try prepare("""
            INSERT INTO watch_delivery_records (
                gateway_key, delivery_id, watch_device_key, message_id, entity_type, entity_id,
                ingress_source, content_digest, persisted_at, server_ack_state
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(gateway_key, delivery_id) DO UPDATE SET
                watch_device_key = COALESCE(excluded.watch_device_key, watch_delivery_records.watch_device_key),
                message_id = COALESCE(excluded.message_id, watch_delivery_records.message_id),
                entity_type = COALESCE(excluded.entity_type, watch_delivery_records.entity_type),
                entity_id = COALESCE(excluded.entity_id, watch_delivery_records.entity_id),
                ingress_source = excluded.ingress_source,
                content_digest = COALESCE(excluded.content_digest, watch_delivery_records.content_digest),
                persisted_at = MIN(watch_delivery_records.persisted_at, excluded.persisted_at),
                server_ack_state = excluded.server_ack_state;
            """)
        defer { sqlite3_finalize(statement) }
        try bindText(statement, index: 1, value: record.gatewayKey)
        try bindText(statement, index: 2, value: record.deliveryId)
        try bindText(statement, index: 3, value: record.watchDeviceKey)
        try bindText(statement, index: 4, value: record.messageId)
        try bindText(statement, index: 5, value: record.entityType)
        try bindText(statement, index: 6, value: record.entityId)
        try bindText(statement, index: 7, value: record.ingressSource.rawValue)
        try bindText(statement, index: 8, value: record.contentDigest)
        sqlite3_bind_double(statement, 9, record.persistedAt.timeIntervalSince1970)
        try bindText(statement, index: 10, value: record.serverAckState.rawValue)
        try stepDone(statement)
    }

    private func upsertWatchLightMessage(_ message: WatchLightMessage) throws {
        let statement = try prepare("INSERT INTO watch_light_messages (message_id, title, body, image_url, url, severity, received_at, is_read, entity_type, entity_id, notification_request_id) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?) ON CONFLICT(message_id) DO UPDATE SET title = excluded.title, body = excluded.body, image_url = excluded.image_url, url = excluded.url, severity = excluded.severity, received_at = excluded.received_at, is_read = excluded.is_read, entity_type = excluded.entity_type, entity_id = excluded.entity_id, notification_request_id = excluded.notification_request_id;")
        defer { sqlite3_finalize(statement) }
        try bindText(statement, index: 1, value: message.messageId)
        try bindText(statement, index: 2, value: message.title)
        try bindText(statement, index: 3, value: message.body)
        try bindText(statement, index: 4, value: message.imageURL?.absoluteString)
        try bindText(statement, index: 5, value: message.url?.absoluteString)
        try bindText(statement, index: 6, value: message.severity)
        sqlite3_bind_double(statement, 7, message.receivedAt.timeIntervalSince1970)
        sqlite3_bind_int(statement, 8, message.isRead ? 1 : 0)
        try bindText(statement, index: 9, value: message.entityType)
        try bindText(statement, index: 10, value: message.entityId)
        try bindText(statement, index: 11, value: message.notificationRequestId)
        try stepDone(statement)
    }

    private func upsertWatchLightEvent(_ event: WatchLightEvent) throws {
        let statement = try prepare("INSERT INTO watch_light_events (event_id, title, summary, state, severity, decryption_state, image_url, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?) ON CONFLICT(event_id) DO UPDATE SET title = excluded.title, summary = excluded.summary, state = excluded.state, severity = excluded.severity, decryption_state = excluded.decryption_state, image_url = excluded.image_url, updated_at = excluded.updated_at;")
        defer { sqlite3_finalize(statement) }
        try bindText(statement, index: 1, value: event.eventId)
        try bindText(statement, index: 2, value: event.title)
        try bindText(statement, index: 3, value: event.summary)
        try bindText(statement, index: 4, value: event.state)
        try bindText(statement, index: 5, value: event.severity)
        try bindText(statement, index: 6, value: event.decryptionState)
        try bindText(statement, index: 7, value: event.imageURL?.absoluteString)
        sqlite3_bind_double(statement, 8, event.updatedAt.timeIntervalSince1970)
        try stepDone(statement)
    }

    private func upsertWatchLightThing(_ thing: WatchLightThing) throws {
        let statement = try prepare("INSERT INTO watch_light_things (thing_id, title, summary, attrs_json, decryption_state, image_url, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?) ON CONFLICT(thing_id) DO UPDATE SET title = excluded.title, summary = excluded.summary, attrs_json = excluded.attrs_json, decryption_state = excluded.decryption_state, image_url = excluded.image_url, updated_at = excluded.updated_at;")
        defer { sqlite3_finalize(statement) }
        try bindText(statement, index: 1, value: thing.thingId)
        try bindText(statement, index: 2, value: thing.title)
        try bindText(statement, index: 3, value: thing.summary)
        try bindText(statement, index: 4, value: thing.attrsJSON)
        try bindText(statement, index: 5, value: thing.decryptionState)
        try bindText(statement, index: 6, value: thing.imageURL?.absoluteString)
        sqlite3_bind_double(statement, 7, thing.updatedAt.timeIntervalSince1970)
        try stepDone(statement)
    }

    private func prepare(_ sql: String) throws -> OpaquePointer? {
        guard let db else { throw StoreError.sqliteOpenFailed(code: SQLITE_MISUSE) }
        var statement: OpaquePointer?
        let result = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
        guard result == SQLITE_OK else {
            throw StoreError.sqlitePrepareFailed(lastSQLiteMessage())
        }
        return statement
    }

    private func bindText(_ statement: OpaquePointer?, index: Int32, value: String?) throws {
        if let value {
            let result = sqlite3_bind_text(statement, index, value, -1, watchSQLiteTransient)
            guard result == SQLITE_OK else {
                throw StoreError.sqlitePrepareFailed(lastSQLiteMessage())
            }
        } else {
            sqlite3_bind_null(statement, index)
        }
    }

    private func stepDone(_ statement: OpaquePointer?) throws {
        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE else {
            throw StoreError.sqliteStepFailed(lastSQLiteMessage())
        }
    }

    private func execute(_ sql: String) throws {
        guard let db else { throw StoreError.sqliteOpenFailed(code: SQLITE_MISUSE) }
        try Self.execute(sql, db: db)
    }

    private static func execute(_ sql: String, db: OpaquePointer) throws {
        let result = sqlite3_exec(db, sql, nil, nil, nil)
        guard result == SQLITE_OK else {
            throw StoreError.sqliteStepFailed(String(cString: sqlite3_errmsg(db)))
        }
    }

    private func lastSQLiteMessage() -> String {
        guard let db else { return "sqlite error" }
        return String(cString: sqlite3_errmsg(db))
    }

    private static func columnText(_ statement: OpaquePointer?, index: Int32) -> String? {
        guard let value = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: value)
    }

    private static func decodeWatchLightMessage(_ statement: OpaquePointer?) -> WatchLightMessage {
        WatchLightMessage(
            messageId: columnText(statement, index: 0) ?? "",
            title: columnText(statement, index: 1) ?? "",
            body: columnText(statement, index: 2) ?? "",
            imageURL: columnText(statement, index: 3).flatMap(URL.init(string:)),
            url: columnText(statement, index: 4).flatMap(URL.init(string:)),
            severity: columnText(statement, index: 5),
            receivedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 6)),
            isRead: sqlite3_column_int(statement, 7) != 0,
            entityType: columnText(statement, index: 8) ?? "message",
            entityId: columnText(statement, index: 9),
            notificationRequestId: columnText(statement, index: 10)
        )
    }

    private static func decodeWatchLightEvent(_ statement: OpaquePointer?) -> WatchLightEvent {
        WatchLightEvent(
            eventId: columnText(statement, index: 0) ?? "",
            title: columnText(statement, index: 1) ?? "",
            summary: columnText(statement, index: 2),
            state: columnText(statement, index: 3),
            severity: columnText(statement, index: 4),
            decryptionState: columnText(statement, index: 5),
            imageURL: columnText(statement, index: 6).flatMap(URL.init(string:)),
            updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 7))
        )
    }

    private static func decodeWatchLightThing(_ statement: OpaquePointer?) -> WatchLightThing {
        WatchLightThing(
            thingId: columnText(statement, index: 0) ?? "",
            title: columnText(statement, index: 1) ?? "",
            summary: columnText(statement, index: 2),
            attrsJSON: columnText(statement, index: 3),
            decryptionState: columnText(statement, index: 4),
            imageURL: columnText(statement, index: 5).flatMap(URL.init(string:)),
            updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 6))
        )
    }

    private static func decodeWatchMirrorAction(_ statement: OpaquePointer?) -> WatchMirrorAction {
        WatchMirrorAction(
            actionId: columnText(statement, index: 0) ?? "",
            kind: WatchMirrorActionKind(rawValue: columnText(statement, index: 1) ?? "read") ?? .read,
            messageId: columnText(statement, index: 2) ?? "",
            issuedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3))
        )
    }

    private static func decodeWatchDeliveryRecord(_ statement: OpaquePointer?) -> WatchDeliveryRecord {
        let ingressSource = WatchIngressSource(rawValue: columnText(statement, index: 6) ?? "") ?? .watchAPNS
        let serverAckState = WatchServerAckState(rawValue: columnText(statement, index: 9) ?? "") ?? .pending
        return WatchDeliveryRecord(
            deliveryId: columnText(statement, index: 1) ?? "",
            gatewayKey: columnText(statement, index: 0) ?? "",
            watchDeviceKey: columnText(statement, index: 2),
            messageId: columnText(statement, index: 3),
            entityType: columnText(statement, index: 4),
            entityId: columnText(statement, index: 5),
            ingressSource: ingressSource,
            contentDigest: columnText(statement, index: 7),
            persistedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 8)),
            serverAckState: serverAckState
        )
    }

    private static func watchBusinessIdentity(
        for payload: WatchLightPayload
    ) -> (messageId: String?, entityType: String?, entityId: String?) {
        switch payload {
        case let .message(message):
            return (
                messageId: normalizeOptional(message.messageId),
                entityType: normalizeOptional(message.entityType) ?? "message",
                entityId: normalizeOptional(message.entityId) ?? normalizeOptional(message.messageId)
            )
        case let .event(event):
            return (
                messageId: nil,
                entityType: "event",
                entityId: normalizeOptional(event.eventId)
            )
        case let .thing(thing):
            return (
                messageId: nil,
                entityType: "thing",
                entityId: normalizeOptional(thing.thingId)
            )
        }
    }

    private static func mergedWatchDeliveryRecord(
        existing: WatchDeliveryRecord,
        incoming: WatchDeliveryMetadata,
        identity: (messageId: String?, entityType: String?, entityId: String?)
    ) -> WatchDeliveryRecord {
        WatchDeliveryRecord(
            deliveryId: existing.deliveryId,
            gatewayKey: existing.gatewayKey,
            watchDeviceKey: incoming.watchDeviceKey ?? existing.watchDeviceKey,
            messageId: identity.messageId ?? existing.messageId,
            entityType: identity.entityType ?? existing.entityType,
            entityId: identity.entityId ?? existing.entityId,
            ingressSource: incoming.ingressSource,
            contentDigest: incoming.contentDigest ?? existing.contentDigest,
            persistedAt: min(existing.persistedAt, incoming.persistedAt),
            serverAckState: incoming.serverAckState
        )
    }

    private static func payloadForDuplicateDelivery(
        _ payload: WatchLightPayload,
        existing: WatchDeliveryRecord
    ) -> WatchLightPayload {
        switch payload {
        case let .message(message):
            let messageId = normalizeOptional(existing.messageId) ?? message.messageId
            return .message(
                WatchLightMessage(
                    messageId: messageId,
                    title: message.title,
                    body: message.body,
                    imageURL: message.imageURL,
                    url: message.url,
                    severity: message.severity,
                    receivedAt: message.receivedAt,
                    isRead: message.isRead,
                    entityType: normalizeOptional(existing.entityType) ?? message.entityType,
                    entityId: normalizeOptional(existing.entityId) ?? message.entityId,
                    notificationRequestId: message.notificationRequestId
                )
            )
        case let .event(event):
            return .event(
                WatchLightEvent(
                    eventId: normalizeOptional(existing.entityId) ?? event.eventId,
                    title: event.title,
                    summary: event.summary,
                    state: event.state,
                    severity: event.severity,
                    decryptionState: event.decryptionState,
                    imageURL: event.imageURL,
                    updatedAt: event.updatedAt
                )
            )
        case let .thing(thing):
            return .thing(
                WatchLightThing(
                    thingId: normalizeOptional(existing.entityId) ?? thing.thingId,
                    title: thing.title,
                    summary: thing.summary,
                    attrsJSON: thing.attrsJSON,
                    decryptionState: thing.decryptionState,
                    imageURL: thing.imageURL,
                    updatedAt: thing.updatedAt
                )
            )
        }
    }

    private static func normalizeOptional(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func createSchemaIfNeeded(db: OpaquePointer) throws {
        try execute(
            """
            CREATE TABLE IF NOT EXISTS watch_light_messages (
                message_id TEXT PRIMARY KEY NOT NULL,
                title TEXT NOT NULL,
                body TEXT NOT NULL,
                image_url TEXT,
                url TEXT,
                severity TEXT,
                received_at REAL NOT NULL,
                is_read INTEGER NOT NULL,
                entity_type TEXT NOT NULL,
                entity_id TEXT,
                notification_request_id TEXT
            );
            """,
            db: db
        )
        try execute("CREATE INDEX IF NOT EXISTS idx_watch_light_messages_received_at ON watch_light_messages(received_at DESC, message_id DESC);", db: db)
        try execute("CREATE INDEX IF NOT EXISTS idx_watch_light_messages_notification_request_id ON watch_light_messages(notification_request_id);", db: db)
        try execute(
            """
            CREATE TABLE IF NOT EXISTS watch_light_events (
                event_id TEXT PRIMARY KEY NOT NULL,
                title TEXT NOT NULL,
                summary TEXT,
                state TEXT,
                severity TEXT,
                decryption_state TEXT,
                image_url TEXT,
                updated_at REAL NOT NULL
            );
            """,
            db: db
        )
        try execute("CREATE INDEX IF NOT EXISTS idx_watch_light_events_updated_at ON watch_light_events(updated_at DESC, event_id DESC);", db: db)
        try execute(
            """
            CREATE TABLE IF NOT EXISTS watch_light_things (
                thing_id TEXT PRIMARY KEY NOT NULL,
                title TEXT NOT NULL,
                summary TEXT,
                attrs_json TEXT,
                decryption_state TEXT,
                image_url TEXT,
                updated_at REAL NOT NULL
            );
            """,
            db: db
        )
        try execute("CREATE INDEX IF NOT EXISTS idx_watch_light_things_updated_at ON watch_light_things(updated_at DESC, thing_id DESC);", db: db)
        try execute(
            """
            CREATE TABLE IF NOT EXISTS watch_mirror_action_queue (
                action_id TEXT PRIMARY KEY NOT NULL,
                kind TEXT NOT NULL,
                message_id TEXT NOT NULL,
                issued_at REAL NOT NULL
            );
            """,
            db: db
        )
        try execute("CREATE INDEX IF NOT EXISTS idx_watch_mirror_action_queue_issued_at ON watch_mirror_action_queue(issued_at ASC, action_id ASC);", db: db)
        try ensureWatchDeliveryRecordsSchema(db: db)
        try execute(
            """
            CREATE TABLE IF NOT EXISTS app_settings (
                id TEXT PRIMARY KEY NOT NULL,
                updated_at REAL NOT NULL DEFAULT 0,
                watch_provisioning_server_config_data_base64 TEXT,
                watch_provisioning_schema_version INTEGER,
                watch_provisioning_generation INTEGER,
                watch_provisioning_content_digest TEXT,
                watch_provisioning_applied_at REAL,
                watch_provisioning_mode_raw_value TEXT,
                watch_provisioning_source_control_generation INTEGER
            );
            """,
            db: db
        )
        try ensureColumn("watch_provisioning_server_config_data_base64", type: "TEXT", db: db)
        try ensureColumn("watch_provisioning_schema_version", type: "INTEGER", db: db)
        try ensureColumn("watch_provisioning_generation", type: "INTEGER", db: db)
        try ensureColumn("watch_provisioning_content_digest", type: "TEXT", db: db)
        try ensureColumn("watch_provisioning_applied_at", type: "REAL", db: db)
        try ensureColumn("watch_provisioning_mode_raw_value", type: "TEXT", db: db)
        try ensureColumn("watch_provisioning_source_control_generation", type: "INTEGER", db: db)
        try ensureTableColumn(
            table: "watch_light_events",
            column: "decryption_state",
            type: "TEXT",
            db: db
        )
        try ensureTableColumn(
            table: "watch_light_things",
            column: "decryption_state",
            type: "TEXT",
            db: db
        )
    }

    private static var watchDeliveryRecordColumns: [String] {
        [
            "gateway_key",
            "delivery_id",
            "watch_device_key",
            "message_id",
            "entity_type",
            "entity_id",
            "ingress_source",
            "content_digest",
            "persisted_at",
            "server_ack_state",
        ]
    }

    private static func ensureWatchDeliveryRecordsSchema(db: OpaquePointer) throws {
        let existingColumns = try tableColumns(table: "watch_delivery_records", db: db)
        guard !existingColumns.isEmpty else {
            try createWatchDeliveryRecordsTable(db: db)
            return
        }

        let expected = Set(watchDeliveryRecordColumns)
        let actual = Set(existingColumns.map(\.name))
        guard actual == expected else {
            try rebuildWatchDeliveryRecordsTable(fromColumns: actual, db: db)
            return
        }

        try createWatchDeliveryRecordIndexes(db: db)
    }

    private static func rebuildWatchDeliveryRecordsTable(
        fromColumns sourceColumns: Set<String>,
        db: OpaquePointer
    ) throws {
        let legacyTable = "watch_delivery_records_legacy_migration"
        try execute("DROP TABLE IF EXISTS \(legacyTable);", db: db)
        try execute("DROP INDEX IF EXISTS idx_watch_delivery_records_business_identity;", db: db)
        try execute("DROP INDEX IF EXISTS idx_watch_delivery_records_persisted_at;", db: db)
        try execute("ALTER TABLE watch_delivery_records RENAME TO \(legacyTable);", db: db)
        try createWatchDeliveryRecordsTable(db: db)

        let selectExpressions = watchDeliveryRecordColumns
            .map { legacyWatchDeliveryExpression(for: $0, sourceColumns: sourceColumns) }
            .joined(separator: ", ")
        let insertColumns = watchDeliveryRecordColumns.joined(separator: ", ")
        try execute(
            """
            INSERT OR IGNORE INTO watch_delivery_records (\(insertColumns))
            SELECT \(selectExpressions)
            FROM \(legacyTable);
            """,
            db: db
        )
        try execute("DROP TABLE IF EXISTS \(legacyTable);", db: db)
    }

    private static func legacyWatchDeliveryExpression(
        for column: String,
        sourceColumns: Set<String>
    ) -> String {
        let hasColumn = sourceColumns.contains(column)
        switch column {
        case "gateway_key":
            return hasColumn ? "COALESCE(NULLIF(trim(gateway_key), ''), 'default')" : "'default'"
        case "delivery_id":
            return hasColumn ? "COALESCE(NULLIF(trim(delivery_id), ''), printf('legacy-%lld', rowid))" : "printf('legacy-%lld', rowid)"
        case "watch_device_key", "message_id", "entity_type", "entity_id", "content_digest":
            return hasColumn ? "NULLIF(\(column), '')" : "NULL"
        case "ingress_source":
            guard hasColumn else { return "'watch_apns'" }
            return "CASE ingress_source WHEN 'watch_apns' THEN ingress_source WHEN 'watch_pull' THEN ingress_source ELSE 'watch_apns' END"
        case "persisted_at":
            return hasColumn ? "COALESCE(persisted_at, strftime('%s', 'now'))" : "strftime('%s', 'now')"
        case "server_ack_state":
            guard hasColumn else { return "'pending'" }
            return "CASE server_ack_state WHEN 'pending' THEN server_ack_state WHEN 'acked_direct' THEN server_ack_state WHEN 'unknown' THEN server_ack_state ELSE 'pending' END"
        default:
            return "NULL"
        }
    }

    private static func createWatchDeliveryRecordsTable(db: OpaquePointer) throws {
        try execute(
            """
            CREATE TABLE IF NOT EXISTS watch_delivery_records (
                gateway_key TEXT NOT NULL,
                delivery_id TEXT NOT NULL,
                watch_device_key TEXT,
                message_id TEXT,
                entity_type TEXT,
                entity_id TEXT,
                ingress_source TEXT NOT NULL,
                content_digest TEXT,
                persisted_at REAL NOT NULL,
                server_ack_state TEXT NOT NULL,
                PRIMARY KEY (gateway_key, delivery_id),
                CHECK (length(trim(gateway_key)) > 0),
                CHECK (length(trim(delivery_id)) > 0)
            );
            """,
            db: db
        )
        try createWatchDeliveryRecordIndexes(db: db)
    }

    private static func createWatchDeliveryRecordIndexes(db: OpaquePointer) throws {
        try execute("CREATE INDEX IF NOT EXISTS idx_watch_delivery_records_business_identity ON watch_delivery_records(entity_type, entity_id, message_id);", db: db)
        try execute("CREATE INDEX IF NOT EXISTS idx_watch_delivery_records_persisted_at ON watch_delivery_records(persisted_at DESC);", db: db)
    }

    private static func ensureColumn(_ name: String, type: String, db: OpaquePointer) throws {
        let statement = try prepare("PRAGMA table_info(app_settings);", db: db)
        defer { sqlite3_finalize(statement) }
        var exists = false
        while sqlite3_step(statement) == SQLITE_ROW {
            if columnText(statement, index: 1) == name {
                exists = true
                break
            }
        }
        if !exists {
            try execute("ALTER TABLE app_settings ADD COLUMN \(name) \(type);", db: db)
        }
    }

    private static func ensureTableColumn(
        table: String,
        column: String,
        type: String,
        db: OpaquePointer
    ) throws {
        let statement = try prepare("PRAGMA table_info(\(table));", db: db)
        defer { sqlite3_finalize(statement) }
        var exists = false
        while sqlite3_step(statement) == SQLITE_ROW {
            if columnText(statement, index: 1) == column {
                exists = true
                break
            }
        }
        if !exists {
            try execute("ALTER TABLE \(table) ADD COLUMN \(column) \(type);", db: db)
        }
    }

    private static func tableColumns(table: String, db: OpaquePointer) throws -> [TableColumn] {
        let statement = try prepare("PRAGMA table_info(\(table));", db: db)
        defer { sqlite3_finalize(statement) }
        var columns: [TableColumn] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let name = columnText(statement, index: 1) {
                columns.append(TableColumn(name: name))
            }
        }
        return columns
    }

    private static func prepare(_ sql: String, db: OpaquePointer) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        let result = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
        guard result == SQLITE_OK else {
            throw StoreError.sqlitePrepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        return statement
    }

    private static func storeURL(
        fileManager: FileManager,
        appGroupIdentifier: String,
        filename: String
    ) throws -> URL {
        let directory = try AppConstants.appLocalDatabaseDirectory(
            fileManager: fileManager,
            appGroupIdentifier: appGroupIdentifier
        )
        return directory.appendingPathComponent(filename)
    }
}
#endif
