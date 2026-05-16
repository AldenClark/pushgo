import Foundation
import GRDB
import os
import UserNotifications

struct MessagePageCursor: Hashable, Sendable {
    let receivedAt: Date
    let id: UUID
    let isRead: Bool

    init(receivedAt: Date, id: UUID, isRead: Bool = false) {
        self.receivedAt = receivedAt
        self.id = id
        self.isRead = isRead
    }
}

struct EntityProjectionPageCursor: Hashable, Sendable {
    let receivedAt: Date
    let id: UUID
}

enum MessageListSortMode: String, CaseIterable, Equatable, Hashable, Sendable {
    case timeDescending = "time_desc"
    case unreadFirst = "unread_first"

    static let preferenceKey = "message_list_sort_mode"

    var titleKey: String {
        switch self {
        case .timeDescending:
            return "message_sort_time_desc"
        case .unreadFirst:
            return "message_sort_unread_first"
        }
    }

    static func loadPreference(
        defaults: UserDefaults = AppConstants.sharedUserDefaults()
    ) -> MessageListSortMode {
        guard let rawValue = defaults.string(forKey: preferenceKey),
              let mode = MessageListSortMode(rawValue: rawValue)
        else {
            return .timeDescending
        }
        if mode == .unreadFirst {
            defaults.set(MessageListSortMode.timeDescending.rawValue, forKey: preferenceKey)
            return .timeDescending
        }
        return mode
    }

    func persist(
        defaults: UserDefaults = AppConstants.sharedUserDefaults()
    ) {
        defaults.set(rawValue, forKey: Self.preferenceKey)
    }
}

enum MessageQueryFilter: Hashable, Sendable {
    case all
    case unreadOnly
    case readOnly
    case withURLOnly
    case byServer(String)
}

struct MessageChannelCount: Hashable, Sendable {
    let channel: String?
    let totalCount: Int
    let unreadCount: Int
    let latestReceivedAt: Date?
    let latestUnreadAt: Date?
}

struct MessageTagCount: Hashable, Sendable {
    let tag: String
    let totalCount: Int
    let latestReceivedAt: Date?
}

struct AppSettingsSnapshot: Hashable, Sendable {
    var manualKeyEncoding: String?
    var launchAtLoginEnabled: Bool?
    var messagePageEnabled: Bool?
    var eventPageEnabled: Bool?
    var thingPageEnabled: Bool?
    var pushTokenData: Data?
    var watchModeRawValue: String? = nil
    var watchEffectiveModeRawValue: String? = nil
    var watchStandaloneReady: Bool? = nil
    var watchModeSwitchStatusRawValue: String? = nil
    var watchLastConfirmedControlGeneration: Int64? = nil
    var watchLastObservedReportedGeneration: Int64? = nil
    var watchControlGeneration: Int64? = nil
    var watchMirrorSnapshotGeneration: Int64? = nil
    var watchStandaloneProvisioningGeneration: Int64? = nil
    var watchMirrorActionAckGeneration: Int64? = nil
    var watchMirrorSnapshotContentDigest: String? = nil
    var watchStandaloneProvisioningContentDigest: String? = nil
    var watchProvisioningServerConfigData: Data? = nil
    var watchProvisioningSchemaVersion: Int? = nil
    var watchProvisioningGeneration: Int64? = nil
    var watchProvisioningContentDigest: String? = nil
    var watchProvisioningAppliedAt: Date? = nil
    var watchProvisioningModeRawValue: String? = nil
    var watchProvisioningSourceControlGeneration: Int64? = nil

    static let empty = AppSettingsSnapshot(
        manualKeyEncoding: nil,
        launchAtLoginEnabled: nil,
        messagePageEnabled: nil,
        eventPageEnabled: nil,
        thingPageEnabled: nil,
        pushTokenData: nil,
        watchModeRawValue: nil,
        watchEffectiveModeRawValue: nil,
        watchStandaloneReady: nil,
        watchModeSwitchStatusRawValue: nil,
        watchLastConfirmedControlGeneration: nil,
        watchLastObservedReportedGeneration: nil,
        watchControlGeneration: nil,
        watchMirrorSnapshotGeneration: nil,
        watchStandaloneProvisioningGeneration: nil,
        watchMirrorActionAckGeneration: nil,
        watchMirrorSnapshotContentDigest: nil,
        watchStandaloneProvisioningContentDigest: nil,
        watchProvisioningServerConfigData: nil,
        watchProvisioningSchemaVersion: nil,
        watchProvisioningGeneration: nil,
        watchProvisioningContentDigest: nil,
        watchProvisioningAppliedAt: nil,
        watchProvisioningModeRawValue: nil,
        watchProvisioningSourceControlGeneration: nil
    )
}

struct WatchPublicationState: Hashable, Sendable {
    var syncGenerations: WatchSyncGenerationState
    var mirrorSnapshotContentDigest: String?
    var standaloneProvisioningContentDigest: String?

    static let empty = WatchPublicationState(
        syncGenerations: .zero,
        mirrorSnapshotContentDigest: nil,
        standaloneProvisioningContentDigest: nil
    )
}

struct WatchModeControlPersistenceState: Hashable, Sendable {
    var desiredMode: WatchMode
    var effectiveMode: WatchMode
    var standaloneReady: Bool
    var switchStatus: WatchModeSwitchStatus
    var lastConfirmedControlGeneration: Int64
    var lastObservedReportedGeneration: Int64

    static let initial = WatchModeControlPersistenceState(
        desiredMode: .mirror,
        effectiveMode: .mirror,
        standaloneReady: false,
        switchStatus: .idle,
        lastConfirmedControlGeneration: 0,
        lastObservedReportedGeneration: 0
    )
}

struct DataPageVisibilitySnapshot: Hashable, Sendable {
    var messageEnabled: Bool
    var eventEnabled: Bool
    var thingEnabled: Bool

    static let `default` = DataPageVisibilitySnapshot(
        messageEnabled: true,
        eventEnabled: true,
        thingEnabled: true
    )
}

struct WatchProvisioningState: Hashable, Sendable {
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

enum NotificationStoreSaveOutcome: Sendable {
    case persisted(PushMessage)
    case persistedPending(PushMessage)
    case duplicateRequest(PushMessage)
    case duplicateMessage(PushMessage)
}

private struct OperationScopeIdentity: Hashable, Sendable {
    let scopeKey: String
    let opId: String
    let channelId: String?
    let entityType: String
    let entityId: String
    let deliveryId: String?
}

private func normalizeOperationField(_ value: String?) -> String? {
    let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return trimmed.isEmpty ? nil : trimmed
}

private func resolveOperationScopeIdentity(from message: PushMessage) -> OperationScopeIdentity? {
    guard let opId = normalizeOperationField(message.operationId) else {
        return nil
    }

    let entityType = normalizeOperationField(message.entityType)?.lowercased() ?? "message"
    let entityId = normalizeOperationField(message.entityId)
        ?? normalizeOperationField(message.eventId)
        ?? normalizeOperationField(message.thingId)
        ?? normalizeOperationField(message.deliveryId)
        ?? normalizeOperationField(message.messageId)
    guard let entityId else {
        return nil
    }

    let channelId = normalizeOperationField(message.channel)
    let scopeKey = "\(channelId ?? "_")|\(entityType)|\(entityId)|\(opId)"
    return OperationScopeIdentity(
        scopeKey: scopeKey,
        opId: opId,
        channelId: channelId,
        entityType: entityType,
        entityId: entityId,
        deliveryId: normalizeOperationField(message.deliveryId)
    )
}

private func normalizeEntityReference(_ value: String?) -> String? {
    let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return trimmed.isEmpty ? nil : trimmed
}

private func isTopLevelMessage(_ message: PushMessage) -> Bool {
    let entityType = message.entityType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard entityType == "message" else { return false }
    return normalizeEntityReference(message.eventId) == nil
        && normalizeEntityReference(message.thingId) == nil
}

private func normalizedEntityType(_ message: PushMessage) -> String {
    message.entityType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
}

private func isReferencedEntityMessage(_ message: PushMessage) -> Bool {
    normalizedEntityType(message) == "message"
        && (
            normalizeEntityReference(message.eventId) != nil
                || normalizeEntityReference(message.thingId) != nil
        )
}

private func affectsNotificationContextSnapshot(_ message: PushMessage) -> Bool {
    let entityType = normalizedEntityType(message)
    return entityType == "event"
        || entityType == "thing"
        || normalizeEntityReference(message.eventId) != nil
        || normalizeEntityReference(message.thingId) != nil
}

private func isTopLevelEventProjection(_ message: PushMessage) -> Bool {
    ProjectionSemantics.isTopLevelEventProjection(
        entityType: normalizedEntityType(message),
        eventId: normalizeEntityReference(message.eventId),
        thingId: normalizeEntityReference(message.thingId),
        projectionDestination: message.projectionDestination
    )
}

private func isEntityScopedWrite(_ message: PushMessage) -> Bool {
    let entityType = normalizedEntityType(message)
    if entityType == "event" || entityType == "thing" {
        return true
    }
    return isReferencedEntityMessage(message)
}

private func referencedThingIdRequiringExistingParent(_ message: PushMessage) -> String? {
    guard normalizedEntityType(message) != "thing" else { return nil }
    return normalizeEntityReference(message.thingId)
}

private func thingParentIdentity(from message: PushMessage) -> String? {
    guard normalizedEntityType(message) == "thing" else { return nil }
    return normalizeEntityReference(message.thingId) ?? normalizeEntityReference(message.entityId)
}

private func stableMessageDedupKey(for message: PushMessage) -> String? {
    if normalizedEntityType(message) == "message" {
        return normalizeOperationField(message.messageId)
    }
    return normalizeOperationField(message.messageId)
        ?? normalizeOperationField(message.deliveryId)
}

private func canonicalizedMessageForPersistence(_ message: PushMessage) -> PushMessage {
    let stableMessageId = stableMessageDedupKey(for: message) ?? message.id.uuidString
    if message.messageId == stableMessageId {
        return message
    }
    var mutable = message
    mutable.messageId = stableMessageId
    return mutable
}

actor LocalDataStore {
    private static let tagMetadataBackfillDefaultsKey = "message_tag_metadata_backfill_v1"

    private struct SharedResourcesKey: Hashable, Sendable {
        let appGroupIdentifier: String
        let containerPath: String
    }

    private struct SharedResources: Sendable {
        let backend: GRDBStore?
        let searchIndex: MessageSearchIndex?
        let metadataIndex: MessageMetadataIndex?
        let storageState: StorageState
    }

    private static let sharedResourcesCache = OSAllocatedUnfairLock<[SharedResourcesKey: SharedResources]>(
        initialState: [:]
    )

    private struct StorageProbeSnapshot: Codable, Sendable {
        let probeVersion: Int
        let generatedAtEpochMs: Int64
        let generatedAtISO8601: String
        let source: String
        let bundleIdentifier: String
        let processName: String
        let processIdentifier: Int32
        let appGroupIdentifier: String
        let automationActive: Bool
        let automationStorageRootPath: String?
        let resolvedAppGroupURL: String?
        let diagnosticFileURL: String?
        let databaseDirectoryURL: String?
        let databaseFileURL: String?
        let databaseFileExists: Bool
        let databaseWalExists: Bool
        let databaseShmExists: Bool
        let databaseSnapshotFileURL: String?
        let databaseSnapshotWalURL: String?
        let databaseSnapshotShmURL: String?
        let databaseSnapshotFileExists: Bool
        let databaseSnapshotWalExists: Bool
        let databaseSnapshotShmExists: Bool
        let searchIndexFileURL: String?
        let metadataIndexFileURL: String?
        let storageMode: String
        let storageReason: String?
        let schemaVersion: String
        let databaseStoreFilename: String
    }

    private static let storageProbeDirectoryName = "storage-diagnostics"
    private static let storageProbeFilename = "local_store_probe.json"
    private static let storageSnapshotFilename = "local_store_snapshot.db"
    private static let storageSnapshotWalFilename = "local_store_snapshot.db-wal"
    private static let storageSnapshotShmFilename = "local_store_snapshot.db-shm"
    struct StorageState: Sendable, Equatable {
        enum Mode: Sendable {
            case persistent
            case unavailable
        }

        let mode: Mode
        let reason: String?
    }

    nonisolated let storageState: StorageState
    private let backend: GRDBStore?
    private let searchIndex: MessageSearchIndex?
    private let metadataIndex: MessageMetadataIndex?
    private let fileManager: FileManager
    private let appGroupIdentifier: String
    private let channelSubscriptionStore = ChannelSubscriptionStore()
    private let localConfigStore = LocalKeychainConfigStore()
    private let pushTokenStore = PushTokenStore()
    private let deviceKeyStore = ProviderDeviceKeyStore()
    private struct TrackedWriteTask: Sendable {
        let id: UUID
        let task: Task<Void, Never>
    }

    private static let trackedWriteTasks = OSAllocatedUnfairLock<[ObjectIdentifier: [TrackedWriteTask]]>(
        initialState: [:]
    )

    init(
        fileManager: FileManager = .default,
        appGroupIdentifier: String = AppConstants.appGroupIdentifier,
    ) {
        KeychainSharedAccessMigration.migrateLegacyItemsToSharedAccessGroup()
        self.fileManager = fileManager
        self.appGroupIdentifier = appGroupIdentifier

        let sharedResources = Self.resolveSharedResources(
            fileManager: fileManager,
            appGroupIdentifier: appGroupIdentifier
        )
        backend = sharedResources.backend
        storageState = sharedResources.storageState
        searchIndex = sharedResources.searchIndex
        metadataIndex = sharedResources.metadataIndex
        Self.writeStorageProbe(
            fileManager: fileManager,
            appGroupIdentifier: appGroupIdentifier,
            storageState: sharedResources.storageState,
            searchIndexReady: searchIndex != nil,
            metadataIndexReady: metadataIndex != nil
        )
    }

    private static func resolveSharedResources(
        fileManager: FileManager,
        appGroupIdentifier: String
    ) -> SharedResources {
        guard let key = sharedResourcesKey(
            fileManager: fileManager,
            appGroupIdentifier: appGroupIdentifier
        ) else {
            return buildSharedResources(
                fileManager: fileManager,
                appGroupIdentifier: appGroupIdentifier
            )
        }

        return sharedResourcesCache.withLockUnchecked { cache in
            if let cached = cache[key] {
                return cached
            }

            let built = buildSharedResources(
                fileManager: fileManager,
                appGroupIdentifier: appGroupIdentifier
            )
            switch built.storageState.mode {
            case .persistent:
                cache[key] = built
            case .unavailable:
                // Keep unavailable results out of the shared cache so transient
                // bootstrap failures can recover on the next initialization.
                break
            }
            return built
        }
    }

    private static func sharedResourcesKey(
        fileManager: FileManager,
        appGroupIdentifier: String
    ) -> SharedResourcesKey? {
        guard let container = AppConstants.appLocalContainerURL(
            fileManager: fileManager,
            appGroupIdentifier: appGroupIdentifier
        ) else {
            return nil
        }
        return SharedResourcesKey(
            appGroupIdentifier: appGroupIdentifier,
            containerPath: container.path
        )
    }

    private static func buildSharedResources(
        fileManager: FileManager,
        appGroupIdentifier: String
    ) -> SharedResources {
        let resolvedBackend: GRDBStore?
        let resolvedStorageState: StorageState
        do {
            let directory = try GRDBStore.databaseDirectory(
                fileManager: fileManager,
                appGroupIdentifier: appGroupIdentifier
            )
            let storeURL = directory.appendingPathComponent(AppConstants.databaseStoreFilename)
            resolvedBackend = try GRDBStore(storeURL: storeURL)
            resolvedStorageState = StorageState(mode: .persistent, reason: nil)
        } catch {
            resolvedBackend = nil
            resolvedStorageState = StorageState(mode: .unavailable, reason: error.localizedDescription)
        }

        let resolvedMetadataIndex = makeIndexResource {
            try MessageMetadataIndex(appGroupIdentifier: appGroupIdentifier)
        }
        let resolvedSearchIndex = makeIndexResource {
            try MessageSearchIndex(appGroupIdentifier: appGroupIdentifier)
        }

        return SharedResources(
            backend: resolvedBackend,
            searchIndex: resolvedSearchIndex,
            metadataIndex: resolvedMetadataIndex,
            storageState: resolvedStorageState
        )
    }

    private static func makeIndexResource<Index>(
        attempts: Int = 3,
        build: () throws -> Index
    ) -> Index? {
        for attempt in 0 ..< max(1, attempts) {
            do {
                return try build()
            } catch {
                if attempt + 1 < attempts {
                    Thread.sleep(forTimeInterval: 0.02)
                }
            }
        }
        return nil
    }

    private static func writeStorageProbe(
        fileManager: FileManager,
        appGroupIdentifier: String,
        storageState: StorageState,
        searchIndexReady: Bool,
        metadataIndexReady: Bool
    ) {
        guard let diagnosticsRootURL = AppConstants.appGroupContainerURL(
            fileManager: fileManager,
            identifier: appGroupIdentifier
        ) else {
            return
        }
        let databaseDirectoryURL = try? GRDBStore.databaseDirectory(
            fileManager: fileManager,
            appGroupIdentifier: appGroupIdentifier
        )
        let databaseFileURL = databaseDirectoryURL?.appendingPathComponent(
            AppConstants.databaseStoreFilename
        )
        let walURL = databaseFileURL.map { URL(fileURLWithPath: $0.path + "-wal") }
        let shmURL = databaseFileURL.map { URL(fileURLWithPath: $0.path + "-shm") }

        let appSupportURL = diagnosticsRootURL
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
        let diagnosticsURL = appSupportURL.appendingPathComponent(
            storageProbeDirectoryName,
            isDirectory: true
        )
        let diagnosticFileURL = diagnosticsURL.appendingPathComponent(storageProbeFilename)
        let snapshotFileURL = diagnosticsURL.appendingPathComponent(storageSnapshotFilename)
        let snapshotWalURL = diagnosticsURL.appendingPathComponent(storageSnapshotWalFilename)
        let snapshotShmURL = diagnosticsURL.appendingPathComponent(storageSnapshotShmFilename)
        let snapshotResult: (databaseCopied: Bool, walCopied: Bool, shmCopied: Bool)
        if let databaseFileURL {
            snapshotResult = copySQLiteArtifactsForDiagnostics(
                fileManager: fileManager,
                sourceBaseURL: databaseFileURL,
                destinationBaseURL: snapshotFileURL
            )
        } else {
            snapshotResult = (databaseCopied: false, walCopied: false, shmCopied: false)
        }

        let searchIndexFileURL = searchIndexReady
            ? databaseDirectoryURL?
                .appendingPathComponent(AppConstants.messageIndexDatabaseFilename)
            : nil
        let metadataIndexFileURL = metadataIndexReady
            ? databaseDirectoryURL?
                .appendingPathComponent(AppConstants.messageIndexDatabaseFilename)
            : nil

        let now = Date()
        let probe = StorageProbeSnapshot(
            probeVersion: 1,
            generatedAtEpochMs: Int64((now.timeIntervalSince1970 * 1_000).rounded()),
            generatedAtISO8601: ISO8601DateFormatter().string(from: now),
            source: "LocalDataStore.init",
            bundleIdentifier: Bundle.main.bundleIdentifier ?? "",
            processName: ProcessInfo.processInfo.processName,
            processIdentifier: ProcessInfo.processInfo.processIdentifier,
            appGroupIdentifier: appGroupIdentifier,
            automationActive: PushGoAutomationContext.isActive,
            automationStorageRootPath: PushGoAutomationContext.storageRootURL?.path,
            resolvedAppGroupURL: diagnosticsRootURL.path,
            diagnosticFileURL: diagnosticFileURL.path,
            databaseDirectoryURL: databaseDirectoryURL?.path,
            databaseFileURL: databaseFileURL?.path,
            databaseFileExists: databaseFileURL.map { fileManager.fileExists(atPath: $0.path) } ?? false,
            databaseWalExists: walURL.map { fileManager.fileExists(atPath: $0.path) } ?? false,
            databaseShmExists: shmURL.map { fileManager.fileExists(atPath: $0.path) } ?? false,
            databaseSnapshotFileURL: snapshotFileURL.path,
            databaseSnapshotWalURL: snapshotWalURL.path,
            databaseSnapshotShmURL: snapshotShmURL.path,
            databaseSnapshotFileExists: snapshotResult.databaseCopied,
            databaseSnapshotWalExists: snapshotResult.walCopied,
            databaseSnapshotShmExists: snapshotResult.shmCopied,
            searchIndexFileURL: searchIndexFileURL?.path,
            metadataIndexFileURL: metadataIndexFileURL?.path,
            storageMode: storageState.mode == .persistent ? "persistent" : "unavailable",
            storageReason: storageState.reason,
            schemaVersion: AppConstants.databaseVersion,
            databaseStoreFilename: AppConstants.databaseStoreFilename
        )

        guard let data = try? JSONEncoder().encode(probe) else { return }
        try? fileManager.createDirectory(at: diagnosticsURL, withIntermediateDirectories: true)
        try? data.write(to: diagnosticFileURL, options: .atomic)
    }

    private static func copySQLiteArtifactsForDiagnostics(
        fileManager: FileManager,
        sourceBaseURL: URL,
        destinationBaseURL: URL
    ) -> (databaseCopied: Bool, walCopied: Bool, shmCopied: Bool) {
        @inline(__always)
        func copyIfPresent(source: URL, destination: URL) -> Bool {
            guard fileManager.fileExists(atPath: source.path) else { return false }
            try? fileManager.removeItem(at: destination)
            do {
                try fileManager.copyItem(at: source, to: destination)
                return true
            } catch {
                return false
            }
        }

        let sourceWalURL = URL(fileURLWithPath: sourceBaseURL.path + "-wal")
        let sourceShmURL = URL(fileURLWithPath: sourceBaseURL.path + "-shm")
        let destinationWalURL = URL(fileURLWithPath: destinationBaseURL.path + "-wal")
        let destinationShmURL = URL(fileURLWithPath: destinationBaseURL.path + "-shm")

        let databaseCopied = copyIfPresent(source: sourceBaseURL, destination: destinationBaseURL)
        let walCopied = copyIfPresent(source: sourceWalURL, destination: destinationWalURL)
        let shmCopied = copyIfPresent(source: sourceShmURL, destination: destinationShmURL)
        return (databaseCopied, walCopied, shmCopied)
    }

    private var storeUnavailableError: AppError {
        AppError.localStore(storageState.reason ?? "Local store unavailable.")
    }

    private func requireBackend() throws -> GRDBStore {
        guard let backend else {
            throw storeUnavailableError
        }
        return backend
    }

    nonisolated func enqueueTrackedWrite(
        after predecessor: Task<Void, Never>? = nil,
        operation: @Sendable @escaping (LocalDataStore) async -> Void
    ) -> Task<Void, Never> {
        let objectId = ObjectIdentifier(self)
        let taskId = UUID()
        let task = Task(priority: .utility) {
            await predecessor?.value
            await operation(self)
            Self.trackedWriteTasks.withLockUnchecked { tasksByStore in
                guard var tasks = tasksByStore[objectId] else { return }
                tasks.removeAll { $0.id == taskId }
                if tasks.isEmpty {
                    tasksByStore.removeValue(forKey: objectId)
                } else {
                    tasksByStore[objectId] = tasks
                }
            }
        }
        Self.trackedWriteTasks.withLockUnchecked { tasksByStore in
            var tasks = tasksByStore[objectId] ?? []
            tasks.append(TrackedWriteTask(id: taskId, task: task))
            tasksByStore[objectId] = tasks
        }
        return task
    }

    func flushWrites() async {
        let objectId = ObjectIdentifier(self)
        let tasks = Self.trackedWriteTasks.withLockUnchecked { tasksByStore in
            tasksByStore[objectId] ?? []
        }
        for task in tasks {
            await task.task.value
        }
    }

    func rebuildPersistentStoresForRecovery() throws {
        let directory = try GRDBStore.databaseDirectory(
            fileManager: fileManager,
            appGroupIdentifier: appGroupIdentifier
        )
        let targets = [
            AppConstants.databaseStoreFilename,
            AppConstants.messageIndexDatabaseFilename,
        ] + AppConstants.legacyDatabaseStoreFilenames + AppConstants.legacyMessageIndexDatabaseFilenames
        for filename in targets {
            let baseURL = directory.appendingPathComponent(filename)
            try Self.removeSQLiteArtifacts(fileManager: fileManager, baseURL: baseURL)
        }
    }

    private static func removeSQLiteArtifacts(fileManager: FileManager, baseURL: URL) throws {
        let candidates = [
            baseURL,
            URL(fileURLWithPath: baseURL.path + "-wal"),
            URL(fileURLWithPath: baseURL.path + "-shm"),
            URL(fileURLWithPath: baseURL.path + "-journal"),
        ]
        for candidate in candidates where fileManager.fileExists(atPath: candidate.path) {
            try fileManager.removeItem(at: candidate)
        }
    }

    private func applyPendingInserts(
        to messages: [PushMessage],
        includePending: Bool,
        limit: Int?
    ) -> [PushMessage] {
        _ = includePending
        _ = limit
        return messages
    }

    private func applyPendingInsertsToSummaries(
        base summaries: [PushMessageSummary],
        includePending: Bool,
        limit: Int?
    ) -> [PushMessageSummary] {
        _ = includePending
        _ = limit
        return summaries
    }

    private func applyPendingInserts(
        to counts: [MessageChannelCount]
    ) -> [MessageChannelCount] {
        return counts
    }

    private func applyPendingProjectionMessages(
        to messages: [PushMessage],
        includePending: Bool,
        limit: Int?,
        where predicate: (PushMessage) -> Bool
    ) -> [PushMessage] {
        _ = includePending
        _ = limit
        return messages.filter(predicate)
    }

    private func eventTime(for message: PushMessage) -> Date? {
        PayloadTimeParser.date(from: message.rawPayload["event_time"]?.value)
    }

    private func normalizeChannelKey(_ channel: String?) -> String? {
        let trimmed = channel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private func pruneMessagesIfNeededDuringFlush(
        maxCount: Int,
        batchSize: Int
    ) async {
        guard maxCount > 0 else { return }
        guard let backend else { return }
        let candidates = (try? await backend.loadPruneCandidates(
            maxCount: maxCount,
            batchSize: batchSize
        )) ?? []
        guard let deletedIds = try? await backend.pruneMessagesIfNeeded(
            maxCount: maxCount,
            batchSize: batchSize
        ) else { return }
        guard !deletedIds.isEmpty else { return }
        if let searchIndex {
            for id in deletedIds {
                try? await searchIndex.remove(id: id)
            }
        }
        if let metadataIndex {
            try? await metadataIndex.bulkRemove(ids: deletedIds)
        }
        removeDeliveredNotifications(identifiers: notificationRequestIds(from: candidates))
    }

    func loadServerConfig() async throws -> ServerConfig? {
        if let config = try? localConfigStore.loadServerConfig()?.normalized() {
            Self.saveWakeupIngressServerConfigDefaults(
                config,
                suiteName: appGroupIdentifier
            )
            return config
        }
        return Self.loadWakeupIngressServerConfigDefaults(suiteName: appGroupIdentifier)
    }

    func saveServerConfig(_ config: ServerConfig?) async throws {
        let normalized = config?.normalized()
        try localConfigStore.saveServerConfig(normalized)
        Self.saveWakeupIngressServerConfigDefaults(
            normalized,
            suiteName: appGroupIdentifier
        )
    }

    private func normalizeGatewayKey(_ gateway: String) -> String {
        gateway.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func compareChannelSubscriptions(
        _ lhs: ChannelSubscription,
        _ rhs: ChannelSubscription
    ) -> Bool {
        let lhsChannelId = lhs.channelId.trimmingCharacters(in: .whitespacesAndNewlines)
        let rhsChannelId = rhs.channelId.trimmingCharacters(in: .whitespacesAndNewlines)
        if lhsChannelId != rhsChannelId {
            return lhsChannelId < rhsChannelId
        }
        return normalizeGatewayKey(lhs.gateway) < normalizeGatewayKey(rhs.gateway)
    }

    private func mapToDomain(
        _ item: KeychainChannelSubscription,
        gateway: String
    ) -> ChannelSubscription {
        ChannelSubscription(
            gateway: gateway,
            channelId: item.channelId,
            displayName: item.displayName,
            updatedAt: item.updatedAt,
            lastSyncedAt: item.lastSyncedAt
        )
    }

    func loadChannelSubscriptions(
        gateway: String,
        includeDeleted: Bool = false
    ) async throws -> [ChannelSubscription] {
        let trimmedGateway = normalizeGatewayKey(gateway)
        guard !trimmedGateway.isEmpty else { return [] }
        if let backend {
            let stored = try await backend.loadChannelSubscriptions(includeDeleted: includeDeleted)
            return stored
                .filter { normalizeGatewayKey($0.gateway) == trimmedGateway }
                .sorted(by: compareChannelSubscriptions)
        }
        let stored = try channelSubscriptionStore.loadSubscriptions(
            gatewayKey: trimmedGateway
        )
        let filtered = includeDeleted ? stored : stored.filter { !$0.isDeleted }
        return filtered
            .map { mapToDomain($0, gateway: trimmedGateway) }
            .sorted(by: compareChannelSubscriptions)
    }

    func loadChannelSubscriptions(includeDeleted: Bool) async throws -> [ChannelSubscription] {
        guard let backend else {
            throw storeUnavailableError
        }
        return try await backend.loadChannelSubscriptions(includeDeleted: includeDeleted)
    }

    func loadGatewayURLForChannel(
        channelId: String
    ) async -> URL? {
        await loadGatewayURLsForChannel(channelId: channelId, includeDeleted: false).first
    }

    func loadGatewayURLsForChannel(
        channelId: String,
        includeDeleted: Bool = true
    ) async -> [URL] {
        let normalizedChannelId = channelId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedChannelId.isEmpty else { return [] }
        guard let backend else { return [] }
        let subscriptions = (try? await backend.loadChannelSubscriptions(includeDeleted: includeDeleted)) ?? []
        let matched = subscriptions
            .filter { $0.channelId.trimmingCharacters(in: .whitespacesAndNewlines) == normalizedChannelId }
            .sorted {
                if $0.updatedAt != $1.updatedAt {
                    return $0.updatedAt > $1.updatedAt
                }
                return normalizeGatewayKey($0.gateway) < normalizeGatewayKey($1.gateway)
            }
        var resolved: [URL] = []
        var seen = Set<String>()
        for subscription in matched {
            guard let url = URLSanitizer.validatedServerURL(from: subscription.gateway) else {
                continue
            }
            let dedupeKey = url.absoluteString.lowercased()
            if seen.insert(dedupeKey).inserted {
                resolved.append(url)
            }
        }
        return resolved
    }

    func upsertChannelSubscription(
        gateway: String,
        channelId: String,
        displayName: String,
        password: String?,
        lastSyncedAt: Date?
    ) async throws -> ChannelSubscription {
        let trimmedGateway = normalizeGatewayKey(gateway)
        guard !trimmedGateway.isEmpty else { throw AppError.noServer }
        var items = try channelSubscriptionStore.loadSubscriptions(
            gatewayKey: trimmedGateway
        )
        let now = Date()
        let trimmedChannelId = channelId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedChannelId.isEmpty else {
            throw AppError.typedLocal(
                code: "channel_id_required",
                category: .validation,
                message: LocalizationProvider.localized("channel_id_required"),
                detail: "channel_id required for channel subscription upsert"
            )
        }
        let trimmedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedName = trimmedName.isEmpty ? trimmedChannelId : trimmedName
        let trimmedPassword = (password ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let updated = KeychainChannelSubscription(
            channelId: trimmedChannelId,
            displayName: resolvedName,
            password: trimmedPassword,
            updatedAt: now,
            lastSyncedAt: lastSyncedAt,
            isDeleted: false,
            deletedAt: nil
        )

        if let index = items.firstIndex(where: { $0.channelId == trimmedChannelId }) {
            items[index] = updated
        } else {
            items.append(updated)
        }

        try channelSubscriptionStore.saveSubscriptions(
            gatewayKey: trimmedGateway,
            subscriptions: items
        )
        if let backend {
            try await backend.upsertChannelSubscription(
                gateway: trimmedGateway,
                channelId: trimmedChannelId,
                displayName: resolvedName,
                password: trimmedPassword,
                lastSyncedAt: lastSyncedAt,
                updatedAt: now,
                isDeleted: false,
                deletedAt: nil
            )
        }
        return ChannelSubscription(
            gateway: trimmedGateway,
            channelId: trimmedChannelId,
            displayName: resolvedName,
            updatedAt: now,
            lastSyncedAt: lastSyncedAt
        )
    }

    func upsertChannelSubscription(
        gateway: String,
        channelId: String,
        displayName: String,
        password: String?,
        lastSyncedAt: Date?,
        updatedAt: Date,
        isDeleted: Bool,
        deletedAt: Date?
    ) async throws {
        guard let backend else {
            throw storeUnavailableError
        }
        try await backend.upsertChannelSubscription(
            gateway: gateway,
            channelId: channelId,
            displayName: displayName,
            password: password,
            lastSyncedAt: lastSyncedAt,
            updatedAt: updatedAt,
            isDeleted: isDeleted,
            deletedAt: deletedAt
        )
    }

    func updateChannelDisplayName(
        gateway: String,
        channelId: String,
        displayName: String
    ) async throws {
        let trimmedGateway = normalizeGatewayKey(gateway)
        guard !trimmedGateway.isEmpty else { return }
        var items = try channelSubscriptionStore.loadSubscriptions(
            gatewayKey: trimmedGateway
        )
        let trimmedChannelId = channelId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let index = items.firstIndex(where: { $0.channelId == trimmedChannelId }) else { return }
        let trimmedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedName = trimmedName.isEmpty ? trimmedChannelId : trimmedName
        var item = items[index]
        item.displayName = resolvedName
        item.updatedAt = Date()
        if item.isDeleted {
            item.isDeleted = false
            item.deletedAt = nil
        }
        items[index] = item
        try channelSubscriptionStore.saveSubscriptions(
            gatewayKey: trimmedGateway,
            subscriptions: items
        )
        if let backend {
            try await backend.updateChannelDisplayName(
                gateway: trimmedGateway,
                channelId: trimmedChannelId,
                displayName: resolvedName
            )
        }
    }

    func updateChannelLastSynced(
        gateway: String,
        channelId: String,
        date: Date
    ) async throws {
        let trimmedGateway = normalizeGatewayKey(gateway)
        guard !trimmedGateway.isEmpty else { return }
        var items = try channelSubscriptionStore.loadSubscriptions(
            gatewayKey: trimmedGateway
        )
        let trimmedChannelId = channelId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let index = items.firstIndex(where: { $0.channelId == trimmedChannelId }) else { return }
        var item = items[index]
        item.lastSyncedAt = date
        items[index] = item
        try channelSubscriptionStore.saveSubscriptions(
            gatewayKey: trimmedGateway,
            subscriptions: items
        )
        if let backend {
            try await backend.updateChannelLastSynced(
                gateway: trimmedGateway,
                channelId: trimmedChannelId,
                date: date
            )
        }
    }

    func softDeleteChannelSubscription(
        gateway: String,
        channelId: String
    ) async throws {
        let trimmedGateway = normalizeGatewayKey(gateway)
        guard !trimmedGateway.isEmpty else { return }
        var items = try channelSubscriptionStore.loadSubscriptions(
            gatewayKey: trimmedGateway
        )
        let trimmedChannelId = channelId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let index = items.firstIndex(where: { $0.channelId == trimmedChannelId }) else { return }
        var item = items[index]
        item.isDeleted = true
        item.deletedAt = Date()
        item.password = ""
        items[index] = item
        try channelSubscriptionStore.saveSubscriptions(
            gatewayKey: trimmedGateway,
            subscriptions: items
        )
        if let backend {
            try await backend.softDeleteChannelSubscription(
                gateway: trimmedGateway,
                channelId: trimmedChannelId,
                deletedAt: item.deletedAt ?? Date()
            )
        }
    }

    func softDeleteChannelSubscription(
        gateway: String,
        channelId: String,
        deletedAt: Date
    ) async throws {
        guard let backend else {
            throw storeUnavailableError
        }
        try await backend.softDeleteChannelSubscription(
            gateway: gateway,
            channelId: channelId,
            deletedAt: deletedAt
        )
    }

    func softDeleteChannelSubscription(
        channelId: String,
        deletedAt: Date
    ) async throws {
        guard let backend else {
            throw storeUnavailableError
        }
        try await backend.softDeleteChannelSubscription(
            channelId: channelId,
            deletedAt: deletedAt
        )
    }

    func channelPassword(
        gateway: String,
        for channelId: String
    ) async -> String? {
        let trimmedGateway = normalizeGatewayKey(gateway)
        guard !trimmedGateway.isEmpty else { return nil }
        let trimmedChannelId = channelId.trimmingCharacters(in: .whitespacesAndNewlines)
        if let backend,
           let credential = try? await backend.loadChannelCredentials(gateway: trimmedGateway)
            .first(where: { $0.channelId == trimmedChannelId })
        {
            return credential.password
        }
        guard let item = try? channelSubscriptionStore
            .loadSubscriptions(gatewayKey: trimmedGateway)
            .first(where: { $0.channelId == trimmedChannelId })
        else { return nil }
        guard item.isDeleted == false else { return nil }
        let trimmedPassword = item.password.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedPassword.isEmpty ? nil : trimmedPassword
    }

    func activeChannelCredentials(
        gateway: String
    ) async throws -> [(channelId: String, password: String)] {
        let trimmedGateway = normalizeGatewayKey(gateway)
        guard !trimmedGateway.isEmpty else { return [] }
        if let backend {
            return try await backend.loadChannelCredentials(gateway: trimmedGateway)
        }
        let stored = try channelSubscriptionStore.loadSubscriptions(
            gatewayKey: trimmedGateway
        )
        return stored.compactMap { item in
            guard item.isDeleted == false else { return nil }
            let trimmedId = item.channelId.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedId.isEmpty else { return nil }
            let trimmedPassword = item.password.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedPassword.isEmpty else { return nil }
            return (channelId: trimmedId, password: trimmedPassword)
        }
    }

    func cachedPushToken(for platform: String) async -> String? {
        let normalizedPlatform = platform.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedPlatform.isEmpty else { return nil }
        return try? pushTokenStore.load(platform: normalizedPlatform)
    }

    func saveCachedPushToken(_ token: String?, for platform: String) async {
        let normalizedPlatform = platform.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedPlatform.isEmpty else { return }

        let normalizedToken = token?.trimmingCharacters(in: .whitespacesAndNewlines)
        try? pushTokenStore.save(
            token: normalizedToken?.isEmpty == false ? normalizedToken : nil,
            platform: normalizedPlatform
        )
    }

    func cachedDeviceKey(for platform: String) async -> String? {
        guard let normalizedPlatform = normalizedDevicePlatform(platform) else {
            return nil
        }
        if let deviceKey = loadCanonicalDeviceKey(for: normalizedPlatform) {
            Self.saveWakeupIngressDeviceKeyDefaults(
                deviceKey,
                platform: normalizedPlatform,
                suiteName: appGroupIdentifier
            )
            return deviceKey
        }
        return Self.loadWakeupIngressDeviceKeyDefaults(
            platform: normalizedPlatform,
            suiteName: appGroupIdentifier
        )
    }

    @discardableResult
    func saveCachedDeviceKey(
        _ deviceKey: String?,
        for platform: String
    ) async -> ProviderDeviceKeyStore.SaveResult? {
        guard let normalizedPlatform = normalizedDevicePlatform(platform) else { return nil }
        let result = deviceKeyStore.save(deviceKey: deviceKey, platform: normalizedPlatform)
        Self.saveWakeupIngressDeviceKeyDefaults(
            deviceKey,
            platform: normalizedPlatform,
            suiteName: appGroupIdentifier
        )
        return result
    }

    func cachedDeviceKey(
        for platform: String,
        channelType: String
    ) async -> String? {
        _ = channelType
        return await cachedDeviceKey(for: platform)
    }

    @discardableResult
    func saveCachedDeviceKey(
        _ deviceKey: String?,
        for platform: String,
        channelType: String
    ) async -> ProviderDeviceKeyStore.SaveResult? {
        _ = channelType
        return await saveCachedDeviceKey(deviceKey, for: platform)
    }

    private func normalizedDevicePlatform(_ platform: String) -> String? {
        let normalizedPlatform = platform.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return normalizedPlatform.isEmpty ? nil : normalizedPlatform
    }

    private func loadCanonicalDeviceKey(for normalizedPlatform: String) -> String? {
        deviceKeyStore.load(platform: normalizedPlatform)
    }

    static func loadWakeupIngressServerConfigDefaults(
        suiteName: String = AppConstants.appGroupIdentifier
    ) -> ServerConfig? {
        WakeupIngressSharedState.loadServerConfig(suiteName: suiteName)
    }

    static func saveWakeupIngressServerConfigDefaults(
        _ config: ServerConfig?,
        suiteName: String = AppConstants.appGroupIdentifier
    ) {
        WakeupIngressSharedState.saveServerConfig(config, suiteName: suiteName)
    }

    static func wakeupIngressDeviceKeyDefaultsKey(for platform: String) -> String {
        WakeupIngressSharedState.deviceKeyDefaultsKey(for: platform)
    }

    static func loadWakeupIngressDeviceKeyDefaults(
        platform: String,
        suiteName: String = AppConstants.appGroupIdentifier
    ) -> String? {
        WakeupIngressSharedState.loadDeviceKey(platform: platform, suiteName: suiteName)
    }

    static func saveWakeupIngressDeviceKeyDefaults(
        _ deviceKey: String?,
        platform: String,
        suiteName: String = AppConstants.appGroupIdentifier
    ) {
        WakeupIngressSharedState.saveDeviceKey(
            deviceKey,
            platform: platform,
            suiteName: suiteName
        )
    }

    func loadManualKeyPreferences() async -> String? {
        let prefs = (try? localConfigStore.loadManualKeyPreferences())
            ?? ManualKeyPreferences(encoding: nil)
        return prefs.encoding
    }

    func saveManualKeyPreferences(encoding: String?) async {
        let prefs = ManualKeyPreferences(encoding: encoding)
        try? localConfigStore.saveManualKeyPreferences(prefs)
    }

    func loadLaunchAtLoginPreference() async -> Bool? {
        guard let backend else { return nil }
        guard let settings = try? await backend.loadAppSettings() else { return nil }
        return settings.launchAtLoginEnabled
    }

    func saveLaunchAtLoginPreference(_ isEnabled: Bool) async {
        guard let backend else { return }
        var settings = (try? await backend.loadAppSettings()) ?? .empty
        settings.launchAtLoginEnabled = isEnabled
        try? await backend.saveAppSettings(settings)
    }

    func loadDataPageVisibility() async -> DataPageVisibilitySnapshot {
        guard let backend else { return .default }
        guard let settings = try? await backend.loadAppSettings() else { return .default }
        return DataPageVisibilitySnapshot(
            messageEnabled: settings.messagePageEnabled ?? true,
            eventEnabled: settings.eventPageEnabled ?? true,
            thingEnabled: settings.thingPageEnabled ?? true
        )
    }

    func saveDataPageVisibility(_ visibility: DataPageVisibilitySnapshot) async {
        guard let backend else { return }
        var settings = (try? await backend.loadAppSettings()) ?? .empty
        settings.messagePageEnabled = visibility.messageEnabled
        settings.eventPageEnabled = visibility.eventEnabled
        settings.thingPageEnabled = visibility.thingEnabled
        try? await backend.saveAppSettings(settings)
    }

    func loadWatchMode() async -> WatchMode {
        guard let backend else { return .mirror }
        guard let settings = try? await backend.loadAppSettings(),
              let rawValue = settings.watchModeRawValue,
              let mode = WatchMode(rawValue: rawValue)
        else {
            return .mirror
        }
        return mode
    }

    func saveWatchMode(_ mode: WatchMode) async {
        guard let backend else { return }
        var settings = (try? await backend.loadAppSettings()) ?? .empty
        settings.watchModeRawValue = mode.rawValue
        try? await backend.saveAppSettings(settings)
    }

    func loadWatchModeControlState() async -> WatchModeControlPersistenceState {
        guard let backend,
              let settings = try? await backend.loadAppSettings()
        else {
            return .initial
        }
        let desiredMode = settings.watchModeRawValue.flatMap { WatchMode(rawValue: $0) } ?? .mirror
        let effectiveMode = settings.watchEffectiveModeRawValue.flatMap { WatchMode(rawValue: $0) } ?? desiredMode
        let standaloneReady = settings.watchStandaloneReady ?? false
        let switchStatus = settings.watchModeSwitchStatusRawValue
            .flatMap { WatchModeSwitchStatus(rawValue: $0) }
            ?? .idle
        return WatchModeControlPersistenceState(
            desiredMode: desiredMode,
            effectiveMode: effectiveMode,
            standaloneReady: standaloneReady,
            switchStatus: switchStatus,
            lastConfirmedControlGeneration: settings.watchLastConfirmedControlGeneration ?? 0,
            lastObservedReportedGeneration: settings.watchLastObservedReportedGeneration ?? 0
        )
    }

    func saveWatchModeControlState(_ state: WatchModeControlPersistenceState) async {
        guard let backend else { return }
        var settings = (try? await backend.loadAppSettings()) ?? .empty
        settings.watchModeRawValue = state.desiredMode.rawValue
        settings.watchEffectiveModeRawValue = state.effectiveMode.rawValue
        settings.watchStandaloneReady = state.standaloneReady
        settings.watchModeSwitchStatusRawValue = state.switchStatus.rawValue
        settings.watchLastConfirmedControlGeneration = state.lastConfirmedControlGeneration
        settings.watchLastObservedReportedGeneration = state.lastObservedReportedGeneration
        try? await backend.saveAppSettings(settings)
    }

    func loadWatchSyncGenerationState() async -> WatchSyncGenerationState {
        let publicationState = await loadWatchPublicationState()
        return publicationState.syncGenerations
    }

    func saveWatchSyncGenerationState(_ state: WatchSyncGenerationState) async {
        guard let backend else { return }
        var settings = (try? await backend.loadAppSettings()) ?? .empty
        settings.watchControlGeneration = state.controlGeneration
        settings.watchMirrorSnapshotGeneration = state.mirrorSnapshotGeneration
        settings.watchStandaloneProvisioningGeneration = state.standaloneProvisioningGeneration
        settings.watchMirrorActionAckGeneration = state.mirrorActionAckGeneration
        try? await backend.saveAppSettings(settings)
    }

    func loadWatchPublicationState() async -> WatchPublicationState {
        guard let backend,
              let settings = try? await backend.loadAppSettings()
        else {
            return .empty
        }
        return WatchPublicationState(
            syncGenerations: WatchSyncGenerationState(
                controlGeneration: settings.watchControlGeneration ?? 0,
                mirrorSnapshotGeneration: settings.watchMirrorSnapshotGeneration ?? 0,
                standaloneProvisioningGeneration: settings.watchStandaloneProvisioningGeneration ?? 0,
                mirrorActionAckGeneration: settings.watchMirrorActionAckGeneration ?? 0
            ),
            mirrorSnapshotContentDigest: settings.watchMirrorSnapshotContentDigest,
            standaloneProvisioningContentDigest: settings.watchStandaloneProvisioningContentDigest
        )
    }

    func saveWatchPublicationState(_ state: WatchPublicationState) async {
        guard let backend else { return }
        var settings = (try? await backend.loadAppSettings()) ?? .empty
        settings.watchControlGeneration = state.syncGenerations.controlGeneration
        settings.watchMirrorSnapshotGeneration = state.syncGenerations.mirrorSnapshotGeneration
        settings.watchStandaloneProvisioningGeneration = state.syncGenerations.standaloneProvisioningGeneration
        settings.watchMirrorActionAckGeneration = state.syncGenerations.mirrorActionAckGeneration
        settings.watchMirrorSnapshotContentDigest = state.mirrorSnapshotContentDigest
        settings.watchStandaloneProvisioningContentDigest = state.standaloneProvisioningContentDigest
        try? await backend.saveAppSettings(settings)
    }

    func loadWatchProvisioningServerConfig() async throws -> ServerConfig? {
        let backend = try requireBackend()
        if let persisted = try await backend.loadWatchProvisioningServerConfig()?.normalized() {
            return persisted
        }
        guard let data = AppConstants.sharedUserDefaults(suiteName: appGroupIdentifier)
            .data(forKey: AppConstants.watchProvisioningServerConfigDefaultsKey)
        else {
            return nil
        }
        return try? JSONDecoder().decode(ServerConfig.self, from: data).normalized()
    }

    func saveWatchProvisioningServerConfig(_ config: ServerConfig?) async throws {
        let backend = try requireBackend()
        let normalized = config?.normalized()
        try await backend.saveWatchProvisioningServerConfig(normalized)
        let defaults = AppConstants.sharedUserDefaults(suiteName: appGroupIdentifier)
        guard let normalized else {
            defaults.removeObject(forKey: AppConstants.watchProvisioningServerConfigDefaultsKey)
            return
        }
        if let data = try? JSONEncoder().encode(normalized) {
            defaults.set(data, forKey: AppConstants.watchProvisioningServerConfigDefaultsKey)
        }
    }

    func loadWatchProvisioningState() async -> WatchProvisioningState? {
        guard let backend else { return nil }
        return try? await backend.loadWatchProvisioningState()
    }

    func saveWatchProvisioningState(_ state: WatchProvisioningState?) async {
        guard let backend else { return }
        try? await backend.saveWatchProvisioningState(state)
    }

    func applyWatchStandaloneProvisioning(
        _ snapshot: WatchStandaloneProvisioningSnapshot,
        sourceControlGeneration: Int64
    ) async throws -> WatchProvisioningState {
        try await performBackendWrite { backend in
            try await backend.applyWatchStandaloneProvisioning(
                snapshot,
                sourceControlGeneration: sourceControlGeneration
            )
        }
    }

    func mergeWatchMirrorSnapshot(_ snapshot: WatchMirrorSnapshot) async throws {
        let backend = try requireBackend()
        try await backend.mergeWatchMirrorSnapshot(snapshot)
    }

    func clearWatchLightStore() async throws {
        let backend = try requireBackend()
        try await backend.clearWatchLightStore()
    }

    func loadWatchLightMessages() async throws -> [WatchLightMessage] {
        let backend = try requireBackend()
        return try await backend.loadWatchLightMessages()
    }

    func loadWatchLightMessage(messageId: String) async throws -> WatchLightMessage? {
        let backend = try requireBackend()
        return try await backend.loadWatchLightMessage(messageId: messageId)
    }

    func loadWatchLightMessage(notificationRequestId: String) async throws -> WatchLightMessage? {
        let backend = try requireBackend()
        return try await backend.loadWatchLightMessage(notificationRequestId: notificationRequestId)
    }

    func loadWatchLightEvents() async throws -> [WatchLightEvent] {
        let backend = try requireBackend()
        return try await backend.loadWatchLightEvents()
    }

    func loadWatchLightEvent(eventId: String) async throws -> WatchLightEvent? {
        let backend = try requireBackend()
        return try await backend.loadWatchLightEvent(eventId: eventId)
    }

    func loadWatchLightThings() async throws -> [WatchLightThing] {
        let backend = try requireBackend()
        return try await backend.loadWatchLightThings()
    }

    func loadWatchLightThing(thingId: String) async throws -> WatchLightThing? {
        let backend = try requireBackend()
        return try await backend.loadWatchLightThing(thingId: thingId)
    }

    func upsertWatchLightPayload(_ payload: WatchLightPayload) async throws {
        let backend = try requireBackend()
        try await backend.upsertWatchLightPayload(payload)
    }

    func markWatchLightMessageRead(messageId: String) async throws -> WatchLightMessage? {
        let backend = try requireBackend()
        return try await backend.markWatchLightMessageRead(messageId: messageId)
    }

    func deleteWatchLightMessage(messageId: String) async throws {
        let backend = try requireBackend()
        try await backend.deleteWatchLightMessage(messageId: messageId)
    }

    func enqueueWatchMirrorAction(_ action: WatchMirrorAction) async throws {
        let backend = try requireBackend()
        try await backend.enqueueWatchMirrorAction(action)
    }

    func loadWatchMirrorActions() async throws -> [WatchMirrorAction] {
        let backend = try requireBackend()
        return try await backend.loadWatchMirrorActions()
    }

    func deleteWatchMirrorActions(actionIds: [String]) async throws {
        let backend = try requireBackend()
        try await backend.deleteWatchMirrorActions(actionIds: actionIds)
    }

    func loadMessages() async throws -> [PushMessage] {
        let backend = try requireBackend()
        let messages = try await backend.loadMessages()
        return applyPendingInserts(
            to: messages,
            includePending: true,
            limit: nil
        )
    }

    func loadMessages(
        filter: MessageQueryFilter = .all,
        channel: String? = nil,
        tag: String? = nil,
    ) async throws -> [PushMessage] {
        let backend = try requireBackend()
        let messages = try await backend.loadMessages(filter: filter, channel: channel, tag: tag)
        return applyPendingInserts(
            to: messages,
            includePending: true,
            limit: nil
        )
    }

    func loadEventMessagesForProjection() async throws -> [PushMessage] {
        let backend = try requireBackend()
        let messages = try await backend.loadEventMessagesForProjection()
        return applyPendingProjectionMessages(
            to: messages,
            includePending: true,
            limit: nil,
            where: isTopLevelEventProjection
        )
    }

    func loadEventMessagesForProjection(eventId: String) async throws -> [PushMessage] {
        let normalized = eventId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return [] }
        let backend = try requireBackend()
        let messages = try await backend.loadEventMessagesForProjection(eventId: normalized)
        return applyPendingProjectionMessages(
            to: messages,
            includePending: true,
            limit: nil,
            where: { $0.eventId == normalized }
        )
    }

    func loadEventMessagesForProjectionPage(
        before cursor: EntityProjectionPageCursor?,
        limit: Int
    ) async throws -> [PushMessage] {
        let backend = try requireBackend()
        let messages = try await backend.loadEventMessagesForProjectionPage(before: cursor, limit: limit)
        return applyPendingProjectionMessages(
            to: messages,
            includePending: cursor == nil,
            limit: limit,
            where: isTopLevelEventProjection
        )
    }

    func loadThingMessagesForProjection() async throws -> [PushMessage] {
        let backend = try requireBackend()
        let messages = try await backend.loadThingMessagesForProjection()
        return applyPendingProjectionMessages(
            to: messages,
            includePending: true,
            limit: nil,
            where: { $0.thingId != nil }
        )
    }

    func loadThingMessagesForProjection(thingId: String) async throws -> [PushMessage] {
        let normalized = thingId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return [] }
        let backend = try requireBackend()
        let messages = try await backend.loadThingMessagesForProjection(thingId: normalized)
        return applyPendingProjectionMessages(
            to: messages,
            includePending: true,
            limit: nil,
            where: { $0.thingId == normalized }
        )
    }

    func loadThingMessagesForProjectionPage(
        before cursor: EntityProjectionPageCursor?,
        limit: Int
    ) async throws -> [PushMessage] {
        let backend = try requireBackend()
        let messages = try await backend.loadThingMessagesForProjectionPage(before: cursor, limit: limit)
        return applyPendingProjectionMessages(
            to: messages,
            includePending: cursor == nil,
            limit: limit,
            where: { $0.thingId != nil }
        )
    }

    func loadMessage(id: UUID) async throws -> PushMessage? {
        let backend = try requireBackend()
        return try await backend.loadMessage(id: id)
    }

    func loadMessages(ids: [UUID]) async throws -> [PushMessage] {
        let backend = try requireBackend()
        return try await backend.loadMessages(ids: ids)
    }

    func loadMessage(messageId: String) async throws -> PushMessage? {
        let backend = try requireBackend()
        return try await backend.loadMessage(messageId: messageId)
    }

    func loadMessage(deliveryId: String) async throws -> PushMessage? {
        let backend = try requireBackend()
        return try await backend.loadMessage(deliveryId: deliveryId)
    }

    func loadMessage(notificationRequestId: String) async throws -> PushMessage? {
        let backend = try requireBackend()
        return try await backend.loadMessage(notificationRequestId: notificationRequestId)
    }

    func loadEntityOpenTarget(notificationRequestId: String) async throws -> EntityOpenTarget? {
        let backend = try requireBackend()
        return try await backend.loadEntityOpenTarget(notificationRequestId: notificationRequestId)
    }

    func loadEntityOpenTarget(messageId: String) async throws -> EntityOpenTarget? {
        let backend = try requireBackend()
        return try await backend.loadEntityOpenTarget(messageId: messageId)
    }

    func loadMessagesPage(
        before cursor: MessagePageCursor?,
        limit: Int,
        filter: MessageQueryFilter = .all,
        channel: String? = nil,
        tag: String? = nil,
        sortMode: MessageListSortMode = .timeDescending
    ) async throws -> [PushMessage] {
        let backend = try requireBackend()
        if let indexedMessages = try await indexedTagMessagesPageIfAvailable(
            backend: backend,
            before: cursor,
            limit: limit,
            filter: filter,
            channel: channel,
            tag: tag,
            sortMode: sortMode
        ) {
            return applyPendingInserts(
                to: indexedMessages,
                includePending: cursor == nil,
                limit: limit
            )
        }
        let messages = try await backend.loadMessagesPage(
            before: cursor,
            limit: limit,
            filter: filter,
            channel: channel,
            tag: tag,
            sortMode: sortMode
        )
        return applyPendingInserts(
            to: messages,
            includePending: cursor == nil,
            limit: limit
        )
    }

    func loadMessageSummariesPage(
        before cursor: MessagePageCursor?,
        limit: Int,
        filter: MessageQueryFilter = .all,
        channel: String? = nil,
        tag: String? = nil,
        sortMode: MessageListSortMode = .timeDescending
    ) async throws -> [PushMessageSummary] {
        let backend = try requireBackend()
        if let indexedMessages = try await indexedTagMessagesPageIfAvailable(
            backend: backend,
            before: cursor,
            limit: limit,
            filter: filter,
            channel: channel,
            tag: tag,
            sortMode: sortMode
        ) {
            return applyPendingInsertsToSummaries(
                base: indexedMessages.map(PushMessageSummary.init(message:)),
                includePending: cursor == nil,
                limit: limit
            )
        }
        let summaries = try await backend.loadMessageSummariesPage(
            before: cursor,
            limit: limit,
            filter: filter,
            channel: channel,
            tag: tag,
            sortMode: sortMode
        )
        return applyPendingInsertsToSummaries(
            base: summaries,
            includePending: cursor == nil,
            limit: limit
        )
    }

    private func indexedTagMessagesPageIfAvailable(
        backend: GRDBStore,
        before cursor: MessagePageCursor?,
        limit: Int,
        filter: MessageQueryFilter,
        channel: String?,
        tag: String?,
        sortMode: MessageListSortMode
    ) async throws -> [PushMessage]? {
        guard limit > 0,
              filter == .all,
              channel == nil,
              sortMode == .timeDescending,
              let normalizedTag = Self.normalizedTagValue(tag),
              let metadataIndex
        else {
            return nil
        }

        await ensureMetadataIndexReady()
        let ids = try await metadataIndex.searchMessageIDs(
            matchingAllTags: [normalizedTag],
            textQuery: nil,
            before: cursor?.receivedAt,
            beforeID: cursor?.id,
            limit: limit
        )
        guard !ids.isEmpty else { return [] }
        return try await backend.loadMessages(ids: ids)
    }

    private static func normalizedTagValue(_ rawTag: String?) -> String? {
        guard let rawTag else { return nil }
        let normalized = rawTag.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.isEmpty ? nil : normalized
    }

    func messageChannelCounts() async throws -> [MessageChannelCount] {
        let backend = try requireBackend()
        let baseCounts = try await backend.messageChannelCounts()
        return applyPendingInserts(to: baseCounts)
    }

    func messageTagCounts() async throws -> [MessageTagCount] {
        let backend = try requireBackend()
        if let metadataIndex {
            await ensureMetadataIndexReady()
            let indexedCounts = try await metadataIndex.tagCounts()
            if !indexedCounts.isEmpty {
                return indexedCounts
            }
        }
        return try await backend.messageTagCounts()
    }

    func messageCounts() async throws -> (total: Int, unread: Int) {
        let backend = try requireBackend()
        return try await backend.messageCounts()
    }

    func searchMessagesCount(query: String) async throws -> Int {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let parsedQuery = Self.parsedSearchQuery(from: trimmed)
        guard !parsedQuery.isEmpty else { return 0 }
        if !parsedQuery.tags.isEmpty, let metadataIndex {
            await ensureMetadataIndexReady()
            let textQuery = parsedQuery.textQueryForFTS
            if textQuery == nil || searchIndex != nil {
                if let count = try? await metadataIndex.countMessages(
                    matchingAllTags: parsedQuery.tags,
                    textQuery: textQuery
                ) {
                    return count
                }
            }
        }
        if let searchIndex {
            await ensureSearchIndexReady()
            if let ftsQuery = parsedQuery.textQueryForFTS,
               let count = try? await searchIndex.count(query: ftsQuery)
            {
                if count > 0 {
                    return count
                }
            }
        }
        let backend = try requireBackend()
        return try await backend.searchMessagesCount(query: trimmed)
    }

    func searchMessagesPage(
        query: String,
        before cursor: MessagePageCursor?,
        limit: Int,
        sortMode: MessageListSortMode = .timeDescending
    ) async throws -> [PushMessage] {
        let backend = try requireBackend()
        return try await backend.searchMessagesPage(
            query: query,
            before: cursor,
            limit: limit,
            sortMode: sortMode
        )
    }

    func searchMessageSummariesPage(
        query: String,
        before cursor: MessagePageCursor?,
        limit: Int,
        sortMode: MessageListSortMode = .timeDescending
    ) async throws -> [PushMessageSummary] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let parsedQuery = Self.parsedSearchQuery(from: trimmed)
        guard !parsedQuery.isEmpty else { return [] }
        let backend = try requireBackend()
        if sortMode == .timeDescending, let searchIndex {
            await ensureSearchIndexReady()
            if parsedQuery.tags.isEmpty, let ftsQuery = parsedQuery.textQueryForFTS {
                if let ids = try? await searchIndex.searchIDs(
                    query: ftsQuery,
                    before: cursor?.receivedAt,
                    beforeID: cursor?.id,
                    limit: limit
                ),
                   !ids.isEmpty
                {
                    return try await backend.loadMessageSummaries(ids: ids)
                }
            }
        }
        if sortMode == .timeDescending, !parsedQuery.tags.isEmpty, let metadataIndex {
            await ensureMetadataIndexReady()
            let textQuery = parsedQuery.textQueryForFTS
            if textQuery == nil || searchIndex != nil {
                if let ids = try? await metadataIndex.searchMessageIDs(
                    matchingAllTags: parsedQuery.tags,
                    textQuery: textQuery,
                    before: cursor?.receivedAt,
                    beforeID: cursor?.id,
                    limit: limit
                ),
                   !ids.isEmpty
                {
                    return try await backend.loadMessageSummaries(ids: ids)
                }
            }
        }
        return try await backend.searchMessageSummariesFallback(
            query: trimmed,
            before: cursor,
            limit: limit,
            sortMode: sortMode
        )
    }

    private func performBackendWrite<T>(
        operation: StaticString = #function,
        _ action: (GRDBStore) async throws -> T
    ) async throws -> T {
        await flushWrites()
        let backend = try requireBackend()
        do {
            return try await action(backend)
        } catch {
            throw mapWriteOperationError(error, operation: operation)
        }
    }

    private func mapWriteOperationError(
        _ error: Error,
        operation: StaticString
    ) -> Error {
        if let appError = error as? AppError {
            switch appError {
            case let .localStore(message):
                let operationName = String(describing: operation)
                if message.contains(operationName) {
                    return appError
                }
                return AppError.localStore("[\(operationName)] \(message)")
            default:
                return appError
            }
        }
        let nsError = error as NSError
        let detail = nsError.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        let message = detail.isEmpty
            ? "Persistent write failed in \(String(describing: operation)). [domain=\(nsError.domain) code=\(nsError.code)]"
            : "Persistent write failed in \(String(describing: operation)): \(detail) [domain=\(nsError.domain) code=\(nsError.code)]"
        return AppError.localStore(message)
    }

    func saveMessages(_ messages: [PushMessage]) async throws {
        let canonicalMessages = messages.map(canonicalizedMessageForPersistence)
        let storedMessages = try await performBackendWrite { backend in
            try await backend.saveMessages(canonicalMessages)
        }
        let searchable = storedMessages.filter(isTopLevelMessage)
        await rebuildSearchIndex(with: searchable)
        await rebuildMetadataIndex(with: searchable)
        await mergeNotificationContextSnapshot(with: storedMessages)
    }

    func saveEntityRecords(_ messages: [PushMessage]) async throws {
        let canonicalMessages = messages.map(canonicalizedMessageForPersistence)
        try await performBackendWrite { backend in
            try await backend.saveEntityRecords(canonicalMessages)
        }
        await mergeNotificationContextSnapshot(with: canonicalMessages)
    }

    func saveMessage(_ message: PushMessage) async throws {
        let canonicalMessage = canonicalizedMessageForPersistence(message)
        let storedMessages = try await performBackendWrite { backend in
            try await backend.saveMessages([canonicalMessage])
        }
        let searchable = storedMessages.filter(isTopLevelMessage)
        await rebuildSearchIndex(with: searchable)
        await rebuildMetadataIndex(with: searchable)
        await mergeNotificationContextSnapshot(with: storedMessages)
    }

    func persistNotificationMessageIfNeeded(
        _ message: PushMessage
    ) async throws -> NotificationStoreSaveOutcome {
        let canonicalMessage = canonicalizedMessageForPersistence(message)
        let outcome = try await performBackendWrite { backend in
            try await backend.persistNotificationMessageIfNeeded(canonicalMessage)
        }
        let searchable: [PushMessage] = {
            switch outcome {
            case let .persisted(stored),
                 let .persistedPending(stored),
                 let .duplicateRequest(stored),
                 let .duplicateMessage(stored):
                return isTopLevelMessage(stored) ? [stored] : []
            }
        }()
        await rebuildSearchIndex(with: searchable)
        await rebuildMetadataIndex(with: searchable)
        switch outcome {
        case let .persisted(stored),
             let .persistedPending(stored),
             let .duplicateRequest(stored),
             let .duplicateMessage(stored):
            await mergeNotificationContextSnapshot(with: [stored])
        }
        return outcome
    }

    func saveMessagesBatch(_ messages: [PushMessage]) async throws {
        guard !messages.isEmpty else { return }
        let canonicalMessages = messages.map(canonicalizedMessageForPersistence)
        let storedMessages = try await performBackendWrite { backend in
            try await backend.saveMessages(canonicalMessages)
        }
        let searchable = storedMessages.filter(isTopLevelMessage)
        await rebuildSearchIndex(with: searchable)
        await rebuildMetadataIndex(with: searchable)
        await mergeNotificationContextSnapshot(with: storedMessages)
    }

    func setMessageReadState(id: UUID, isRead: Bool) async throws {
        try await performBackendWrite { backend in
            try await backend.setMessageReadState(id: id, isRead: isRead)
        }
    }

    func markMessagesRead(
        filter: MessageQueryFilter,
        channel: String?
    ) async throws -> Int {
        try await performBackendWrite { backend in
            try await backend.markMessagesRead(filter: filter, channel: channel)
        }
    }

    func markMessagesRead(ids: [UUID]) async throws -> Int {
        try await performBackendWrite { backend in
            try await backend.markMessagesRead(ids: ids)
        }
    }

    func deleteMessage(id: UUID) async throws {
        try await performBackendWrite { backend in
            try await backend.deleteMessage(id: id)
        }
        if let searchIndex {
            try? await searchIndex.remove(id: id)
        }
        if let metadataIndex {
            try? await metadataIndex.remove(id: id)
        }
        await rebuildNotificationContextSnapshot()
    }

    func deleteMessages(ids: [UUID]) async throws -> Int {
        let deletion = try await performBackendWrite { backend -> (ids: [UUID], affectsNotificationContextSnapshot: Bool) in
            let uniqueIds = Array(Set(ids))
            let existingMessages = try await backend.loadMessages(ids: uniqueIds)
            let deletedIds = try await backend.deleteMessages(ids: uniqueIds)
            let deletedIdSet = Set(deletedIds)
            let affectsSnapshot = existingMessages.contains { message in
                deletedIdSet.contains(message.id) && affectsNotificationContextSnapshot(message)
            }
            return (deletedIds, affectsSnapshot)
        }
        let deletedIds = deletion.ids
        if let searchIndex, !deletedIds.isEmpty {
            try? await searchIndex.bulkRemove(ids: deletedIds)
        }
        if let metadataIndex, !deletedIds.isEmpty {
            try? await metadataIndex.bulkRemove(ids: deletedIds)
        }
        if deletion.affectsNotificationContextSnapshot {
            await rebuildNotificationContextSnapshot()
        }
        return deletedIds.count
    }

    func deleteMessage(notificationRequestId: String) async throws {
        let deletedMessageId = try await performBackendWrite { backend -> UUID? in
            if let message = try await backend.loadMessage(notificationRequestId: notificationRequestId) {
                try await backend.deleteMessage(notificationRequestId: notificationRequestId)
                return message.id
            }
            try await backend.deleteMessage(notificationRequestId: notificationRequestId)
            return nil
        }
        if let deletedMessageId {
            if let searchIndex {
                try? await searchIndex.remove(id: deletedMessageId)
            }
            if let metadataIndex {
                try? await metadataIndex.remove(id: deletedMessageId)
            }
            await rebuildNotificationContextSnapshot()
        }
    }

    func deleteEventRecords(eventId: String) async throws -> Int {
        let normalized = eventId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return 0 }
        let deletedCount = try await performBackendWrite { backend in
            try await backend.deleteEventRecords(eventId: normalized)
        }
        if deletedCount > 0 {
            await rebuildNotificationContextSnapshot()
        }
        return deletedCount
    }

    func deleteEventRecords(eventIds: [String]) async throws -> Int {
        let normalized = Array(
            Set(
                eventIds
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
            )
        )
        guard !normalized.isEmpty else { return 0 }
        let deletedCount = try await performBackendWrite { backend in
            try await backend.deleteEventRecords(eventIds: normalized)
        }
        if deletedCount > 0 {
            await rebuildNotificationContextSnapshot()
        }
        return deletedCount
    }

    func deleteEventRecords(channel: String?) async throws -> Int {
        let normalized = channel?.trimmingCharacters(in: .whitespacesAndNewlines)
        let deletedCount = try await performBackendWrite { backend in
            try await backend.deleteEventRecords(channel: normalized)
        }
        if deletedCount > 0 {
            await rebuildNotificationContextSnapshot()
        }
        return deletedCount
    }

    func deleteThingRecords(thingId: String) async throws -> Int {
        let normalized = thingId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return 0 }
        let deletedCount = try await performBackendWrite { backend in
            try await backend.deleteThingRecords(thingId: normalized)
        }
        if deletedCount > 0 {
            await rebuildNotificationContextSnapshot()
        }
        return deletedCount
    }

    func deleteThingRecords(thingIds: [String]) async throws -> Int {
        let normalized = Array(
            Set(
                thingIds
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
            )
        )
        guard !normalized.isEmpty else { return 0 }
        let deletedCount = try await performBackendWrite { backend in
            try await backend.deleteThingRecords(thingIds: normalized)
        }
        if deletedCount > 0 {
            await rebuildNotificationContextSnapshot()
        }
        return deletedCount
    }

    func deleteThingRecords(channel: String?) async throws -> Int {
        let normalized = channel?.trimmingCharacters(in: .whitespacesAndNewlines)
        let deletedCount = try await performBackendWrite { backend in
            try await backend.deleteThingRecords(channel: normalized)
        }
        if deletedCount > 0 {
            await rebuildNotificationContextSnapshot()
        }
        return deletedCount
    }

    func deleteAllMessages() async throws {
        try await performBackendWrite { backend in
            try await backend.deleteAllMessages()
            try await backend.deleteAllEntityRecords()
        }
        if let searchIndex {
            try? await searchIndex.clear()
        }
        if let metadataIndex {
            try? await metadataIndex.clear()
        }
        clearNotificationContextSnapshot()
    }

    func deleteMessages(readState: Bool?, before cutoff: Date?) async throws -> Int {
        if readState == nil && cutoff == nil {
            let total = try await performBackendWrite { backend in
                let count = (try? await backend.messageCounts().total) ?? 0
                try await backend.deleteAllMessages()
                return count
            }
            if let searchIndex {
                try? await searchIndex.clear()
            }
            if let metadataIndex {
                try? await metadataIndex.clear()
            }
            if total > 0 {
                await rebuildNotificationContextSnapshot()
            }
            return total
        }

        let deletedIds = try await performBackendWrite { backend in
            try await backend.deleteMessages(readState: readState, before: cutoff)
        }
        if let searchIndex, !deletedIds.isEmpty {
            try? await searchIndex.bulkRemove(ids: deletedIds)
        }
        if let metadataIndex, !deletedIds.isEmpty {
            try? await metadataIndex.bulkRemove(ids: deletedIds)
        }
        if !deletedIds.isEmpty {
            await rebuildNotificationContextSnapshot()
        }
        return deletedIds.count
    }

    func deleteMessages(channel: String) async throws -> Int {
        let deletedIds = try await performBackendWrite { backend in
            try await backend.deleteMessages(channel: channel)
        }
        if let searchIndex, !deletedIds.isEmpty {
            try? await searchIndex.bulkRemove(ids: deletedIds)
        }
        if let metadataIndex, !deletedIds.isEmpty {
            try? await metadataIndex.bulkRemove(ids: deletedIds)
        }
        if !deletedIds.isEmpty {
            await rebuildNotificationContextSnapshot()
        }
        return deletedIds.count
    }

    func deleteMessages(channel: String?, readState: Bool?) async throws -> Int {
        let deletedIds = try await performBackendWrite { backend in
            try await backend.deleteMessages(channel: channel, readState: readState)
        }
        if let searchIndex, !deletedIds.isEmpty {
            try? await searchIndex.bulkRemove(ids: deletedIds)
        }
        if let metadataIndex, !deletedIds.isEmpty {
            try? await metadataIndex.bulkRemove(ids: deletedIds)
        }
        if !deletedIds.isEmpty {
            await rebuildNotificationContextSnapshot()
        }
        return deletedIds.count
    }

    func loadOldestReadMessages(
        limit: Int,
        excludingChannels: [String] = []
    ) async throws -> [PushMessage] {
        guard limit > 0 else { return [] }
        await flushWrites()
        let backend = try requireBackend()
        return try await backend.loadOldestReadMessages(
            limit: limit,
            excludingChannels: excludingChannels
        )
    }

    func deleteOldestReadMessages(
        limit: Int,
        excludingChannels: [String] = []
    ) async throws -> Int {
        guard limit > 0 else { return 0 }
        let deletedIds = try await performBackendWrite { backend in
            try await backend.deleteOldestReadMessages(
                limit: limit,
                excludingChannels: excludingChannels
            )
        }
        if let searchIndex, !deletedIds.isEmpty {
            try? await searchIndex.bulkRemove(ids: deletedIds)
        }
        if let metadataIndex, !deletedIds.isEmpty {
            try? await metadataIndex.bulkRemove(ids: deletedIds)
        }
        if !deletedIds.isEmpty {
            await rebuildNotificationContextSnapshot()
        }
        return deletedIds.count
    }

    func loadPruneCandidates(maxCount: Int, batchSize: Int) async throws -> [PushMessage] {
        await flushWrites()
        guard maxCount > 0 else { return [] }
        let backend = try requireBackend()
        return try await backend.loadPruneCandidates(
            maxCount: maxCount,
            batchSize: batchSize
        )
    }

    func pruneMessagesIfNeeded(maxCount: Int, batchSize: Int) async -> Int {
        await flushWrites()
        guard maxCount > 0 else { return 0 }
        guard let backend else { return 0 }
        guard let deletedIds = try? await backend.pruneMessagesIfNeeded(
            maxCount: maxCount,
            batchSize: batchSize
        ) else { return 0 }
        guard !deletedIds.isEmpty else { return 0 }
        if let searchIndex {
            for id in deletedIds {
                try? await searchIndex.remove(id: id)
            }
        }
        if let metadataIndex {
            try? await metadataIndex.bulkRemove(ids: deletedIds)
        }
        await rebuildNotificationContextSnapshot()
        return deletedIds.count
    }
    func warmCachesIfNeeded() async {
        await flushWrites()
        guard let backend else { return }
        await backend.prepareStatsIfNeeded(progressive: true)
        await rebuildSearchIndexIfNeeded(batchSize: 200, yieldBetweenBatches: true)
        await rebuildMetadataIndexIfNeeded(batchSize: 200, yieldBetweenBatches: true)
        await rebuildTagMetadataIndexIfNeeded(batchSize: 200, yieldBetweenBatches: true)
        await rebuildNotificationContextSnapshot()
    }

    private func mergeNotificationContextSnapshot(with messages: [PushMessage]) async {
        guard !messages.isEmpty else { return }
        let eventMessages = messages.filter { message in
            normalizedEntityType(message) == "event" || message.eventId != nil
        }
        .map(makeNotificationContextProjectionInput(from:))
        let thingMessages = messages.filter { message in
            normalizedEntityType(message) == "thing" || message.thingId != nil
        }
        .map(makeNotificationContextProjectionInput(from:))
        guard !eventMessages.isEmpty || !thingMessages.isEmpty else { return }

        let existing = NotificationContextSnapshotStore.load(
            fileManager: fileManager,
            appGroupIdentifier: appGroupIdentifier
        )
        let snapshot = NotificationContextSnapshotProjector.merge(
            existing: existing,
            eventMessages: eventMessages,
            thingMessages: thingMessages,
            source: snapshotSourceIdentifier()
        )
        _ = NotificationContextSnapshotStore.write(
            snapshot,
            fileManager: fileManager,
            appGroupIdentifier: appGroupIdentifier
        )
    }

    private func rebuildNotificationContextSnapshot() async {
        guard let backend else {
            clearNotificationContextSnapshot()
            return
        }
        let eventMessages = ((try? await backend.loadEventMessagesForProjection()) ?? [])
            .map(makeNotificationContextProjectionInput(from:))
        let thingMessages = ((try? await backend.loadThingMessagesForProjection()) ?? [])
            .map(makeNotificationContextProjectionInput(from:))
        if eventMessages.isEmpty, thingMessages.isEmpty {
            clearNotificationContextSnapshot()
            return
        }
        let snapshot = NotificationContextSnapshotProjector.rebuild(
            eventMessages: eventMessages,
            thingMessages: thingMessages,
            source: snapshotSourceIdentifier()
        )
        _ = NotificationContextSnapshotStore.write(
            snapshot,
            fileManager: fileManager,
            appGroupIdentifier: appGroupIdentifier
        )
    }

    private func clearNotificationContextSnapshot() {
        _ = NotificationContextSnapshotStore.clear(
            fileManager: fileManager,
            appGroupIdentifier: appGroupIdentifier
        )
    }

    private func makeNotificationContextProjectionInput(
        from message: PushMessage
    ) -> NotificationContextProjectionInput {
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

    private func snapshotSourceIdentifier() -> String {
        let processName = ProcessInfo.processInfo.processName
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let bundleIdentifier = Bundle.main.bundleIdentifier?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let bundleIdentifier, !bundleIdentifier.isEmpty {
            return processName.isEmpty ? bundleIdentifier : "\(processName):\(bundleIdentifier)"
        }
        return processName.isEmpty ? "unknown" : processName
    }

    private func rebuildSearchIndex(with messages: [PushMessage]) async {
        guard let searchIndex else { return }
        guard !messages.isEmpty else { return }
        let batchSize = 500
        var index = 0
        while index < messages.count {
            let upper = min(messages.count, index + batchSize)
            let slice = messages[index..<upper]
            let entries = slice.map { message in
                MessageSearchIndex.Entry(
                    id: message.id,
                    title: message.title,
                    body: message.resolvedBody.rawText,
                    channel: message.channel,
                    receivedAt: message.receivedAt
                )
            }
            try? await searchIndex.bulkUpsert(entries: entries)
            index = upper
        }
    }

    private func rebuildMetadataIndex(with messages: [PushMessage]) async {
        guard let metadataIndex else { return }
        guard !messages.isEmpty else { return }
        let batchSize = 500
        var index = 0
        while index < messages.count {
            let upper = min(messages.count, index + batchSize)
            let slice = messages[index..<upper]
            let entries = slice.map { message in
                MessageMetadataIndex.Entry(
                    id: message.id,
                    receivedAt: message.receivedAt,
                    items: message.metadata,
                    tags: message.tags
                )
            }
            try? await metadataIndex.bulkReplace(entries: entries)
            index = upper
        }
    }

    private func notificationRequestIds(from messages: [PushMessage]) -> [String] {
        messages.compactMap { message in
            let id = message.notificationRequestId?.trimmingCharacters(in: .whitespacesAndNewlines)
            return id?.isEmpty == false ? id : nil
        }
    }

    private func removeDeliveredNotifications(identifiers: [String]) {
        guard !identifiers.isEmpty else { return }
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: identifiers)
    }

    private func ensureSearchIndexReady() async {
        await rebuildSearchIndexIfNeeded(batchSize: 500, yieldBetweenBatches: false)
    }

    private func rebuildSearchIndexIfNeeded(
        batchSize: Int,
        yieldBetweenBatches: Bool
    ) async {
        guard let searchIndex else { return }
        guard let isEmpty = try? await searchIndex.isEmpty(), isEmpty else { return }
        guard let backend else { return }
        let total = (try? await backend.messageCounts().total) ?? 0
        guard total > 0 else { return }

        var cursor: MessagePageCursor?
        try? await searchIndex.clear()
        while true {
            let entries = try? await backend.searchIndexEntriesPage(before: cursor, limit: batchSize)
            guard let entries, !entries.isEmpty else { break }
            try? await searchIndex.bulkUpsert(entries: entries)
            cursor = entries.last.map { MessagePageCursor(receivedAt: $0.receivedAt, id: $0.id) }
            if entries.count < batchSize { break }
            if yieldBetweenBatches {
                await Task.yield()
            }
        }
    }

    private func rebuildMetadataIndexIfNeeded(
        batchSize: Int,
        yieldBetweenBatches: Bool
    ) async {
        guard let metadataIndex else { return }
        guard let isEmpty = try? await metadataIndex.isEmpty(), isEmpty else { return }
        guard let backend else { return }
        let total = (try? await backend.messageCounts().total) ?? 0
        guard total > 0 else { return }

        var cursor: MessagePageCursor?
        try? await metadataIndex.clear()
        while true {
            let messages = try? await backend.loadMessagesPage(
                before: cursor,
                limit: batchSize,
                filter: .all,
                channel: nil,
                tag: nil,
                sortMode: .timeDescending
            )
            guard let messages, !messages.isEmpty else { break }
            let entries = messages.map { message in
                MessageMetadataIndex.Entry(
                    id: message.id,
                    receivedAt: message.receivedAt,
                    items: message.metadata,
                    tags: message.tags
                )
            }
            try? await metadataIndex.bulkReplace(entries: entries)
            cursor = messages.last.map {
                MessagePageCursor(receivedAt: $0.receivedAt, id: $0.id, isRead: $0.isRead)
            }
            if messages.count < batchSize { break }
            if yieldBetweenBatches {
                await Task.yield()
            }
        }
    }

    private static func searchIndexQuery(from raw: String) -> String {
        SearchQuerySemantics.normalizedSearchIndexQuery(from: raw)
    }

    private static func parsedSearchQuery(from raw: String) -> SearchQuerySemantics.ParsedQuery {
        SearchQuerySemantics.parse(raw)
    }

    private func ensureMetadataIndexReady() async {
        await rebuildMetadataIndexIfNeeded(batchSize: 500, yieldBetweenBatches: false)
    }

    private func rebuildTagMetadataIndexIfNeeded(
        batchSize: Int,
        yieldBetweenBatches: Bool
    ) async {
        guard metadataIndex != nil else { return }
        let defaults = AppConstants.sharedUserDefaults(suiteName: appGroupIdentifier)
        if defaults.bool(forKey: Self.tagMetadataBackfillDefaultsKey) {
            return
        }

        let succeeded = await forceRebuildMetadataIndex(batchSize: batchSize, yieldBetweenBatches: yieldBetweenBatches)
        if succeeded {
            defaults.set(true, forKey: Self.tagMetadataBackfillDefaultsKey)
        }
    }

    private func forceRebuildMetadataIndex(
        batchSize: Int,
        yieldBetweenBatches: Bool
    ) async -> Bool {
        guard let metadataIndex else { return false }
        guard let backend else { return false }
        let total = (try? await backend.messageCounts().total) ?? 0
        guard total > 0 else { return true }

        do {
            var cursor: MessagePageCursor?
            try await metadataIndex.clear()
            while true {
                let messages = try await backend.loadMessagesPage(
                    before: cursor,
                    limit: batchSize,
                    filter: .all,
                    channel: nil,
                    tag: nil,
                    sortMode: .timeDescending
                )
                if messages.isEmpty {
                    break
                }
                let entries = messages.map { message in
                    MessageMetadataIndex.Entry(
                        id: message.id,
                        receivedAt: message.receivedAt,
                        items: message.metadata,
                        tags: message.tags
                    )
                }
                try await metadataIndex.bulkReplace(entries: entries)
                cursor = messages.last.map {
                    MessagePageCursor(receivedAt: $0.receivedAt, id: $0.id, isRead: $0.isRead)
                }
                if messages.count < batchSize {
                    break
                }
                if yieldBetweenBatches {
                    await Task.yield()
                }
            }
            return true
        } catch {
            return false
        }
    }
}

private struct GRDBMessageRecord {
    let id: UUID
    let messageId: String
    let title: String
    let body: String
    let channel: String?
    let url: String?
    let isRead: Bool
    let receivedAt: Date
    let rawPayloadJSON: String
    let status: String
    let decryptionState: String?
    let notificationRequestId: String?
    let deliveryId: String?
    let operationId: String?
    let entityType: String
    let entityId: String?
    let eventId: String?
    let thingId: String?
    let projectionDestination: String?
    let eventState: String?
    let eventTimeEpoch: Int64?
    let observedTimeEpoch: Int64?
    let occurredAtEpoch: Int64?
    let topLevelMessage: Bool

    init(
        id: UUID,
        messageId: String,
        title: String,
        body: String,
        channel: String?,
        url: String?,
        isRead: Bool,
        receivedAt: Date,
        rawPayloadJSON: String,
        status: String,
        decryptionState: String?,
        notificationRequestId: String?,
        deliveryId: String?,
        operationId: String?,
        entityType: String,
        entityId: String?,
        eventId: String?,
        thingId: String?,
        projectionDestination: String?,
        eventState: String?,
        eventTimeEpoch: Int64?,
        observedTimeEpoch: Int64?,
        occurredAtEpoch: Int64?,
        topLevelMessage: Bool
    ) {
        self.id = id
        self.messageId = messageId
        self.title = title
        self.body = body
        self.channel = channel
        self.url = url
        self.isRead = isRead
        self.receivedAt = receivedAt
        self.rawPayloadJSON = rawPayloadJSON
        self.status = status
        self.decryptionState = decryptionState
        self.notificationRequestId = notificationRequestId
        self.deliveryId = deliveryId
        self.operationId = operationId
        self.entityType = entityType
        self.entityId = entityId
        self.eventId = eventId
        self.thingId = thingId
        self.projectionDestination = projectionDestination
        self.eventState = eventState
        self.eventTimeEpoch = eventTimeEpoch
        self.observedTimeEpoch = observedTimeEpoch
        self.occurredAtEpoch = occurredAtEpoch
        self.topLevelMessage = topLevelMessage
    }

    init(row: Row) {
        let idString: String = row["id"]
        id = UUID(uuidString: idString) ?? UUID()
        messageId = row["message_id"]
        title = row["title"]
        body = row["body"]
        channel = row["channel"]
        url = row["url"]
        let isReadInt: Int64 = row["is_read"]
        isRead = isReadInt != 0
        let receivedAtEpoch: Double = row["received_at"]
        receivedAt = GRDBStore.dateFromStoredEpoch(receivedAtEpoch)
        rawPayloadJSON = row["raw_payload_json"]
        status = row["status"]
        decryptionState = row["decryption_state"]
        notificationRequestId = row["notification_request_id"]
        deliveryId = row["delivery_id"]
        operationId = row["operation_id"]
        entityType = row["entity_type"]
        entityId = row["entity_id"]
        eventId = row["event_id"]
        thingId = row["thing_id"]
        projectionDestination = row["projection_destination"]
        eventState = row["event_state"]
        eventTimeEpoch = row["event_time_epoch"]
        observedTimeEpoch = row["observed_time_epoch"]
        occurredAtEpoch = row["occurred_at_epoch"]
        let topLevelInt: Int64 = row["is_top_level_message"]
        topLevelMessage = topLevelInt != 0
    }

    func toPushMessage(decoder: JSONDecoder) -> PushMessage {
        let payloadData = rawPayloadJSON.data(using: .utf8) ?? Data("{}".utf8)
        let payload = (try? decoder.decode([String: AnyCodable].self, from: payloadData)) ?? [:]
        let resolvedStatus = PushMessage.Status(rawValue: status) ?? .normal
        let resolvedDecryptionState = PushMessage.DecryptionState.from(raw: decryptionState)
        return PushMessage(
            id: id,
            messageId: messageId,
            title: title,
            body: body,
            channel: channel,
            url: url.flatMap(URL.init(string:)),
            isRead: isRead,
            receivedAt: receivedAt,
            rawPayload: payload,
            status: resolvedStatus,
            decryptionState: resolvedDecryptionState
        )
    }

    func withID(_ id: UUID) -> GRDBMessageRecord {
        GRDBMessageRecord(
            id: id,
            messageId: messageId,
            title: title,
            body: body,
            channel: channel,
            url: url,
            isRead: isRead,
            receivedAt: receivedAt,
            rawPayloadJSON: rawPayloadJSON,
            status: status,
            decryptionState: decryptionState,
            notificationRequestId: notificationRequestId,
            deliveryId: deliveryId,
            operationId: operationId,
            entityType: entityType,
            entityId: entityId,
            eventId: eventId,
            thingId: thingId,
            projectionDestination: projectionDestination,
            eventState: eventState,
            eventTimeEpoch: eventTimeEpoch,
            observedTimeEpoch: observedTimeEpoch,
            occurredAtEpoch: occurredAtEpoch,
            topLevelMessage: topLevelMessage
        )
    }

    static func from(message: PushMessage, encoder: JSONEncoder) throws -> GRDBMessageRecord {
        let canonicalMessage = canonicalizedMessageForPersistence(message)
        let payloadData = try encoder.encode(canonicalMessage.rawPayload)
        let rawPayloadJSON = String(data: payloadData, encoding: .utf8) ?? "{}"
        let normalizedMessageId = canonicalMessage.messageId?.trimmingCharacters(in: .whitespacesAndNewlines)
        let entityType = canonicalMessage.entityType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if entityType == "message", normalizedMessageId?.isEmpty != false {
            throw AppError.localStore("top-level message requires message_id")
        }
        let messageId = (normalizedMessageId?.isEmpty == false)
            ? normalizedMessageId!
            : canonicalMessage.id.uuidString

        return GRDBMessageRecord(
            id: canonicalMessage.id,
            messageId: messageId,
            title: canonicalMessage.title,
            body: canonicalMessage.body,
            channel: normalizeOptional(canonicalMessage.channel),
            url: canonicalMessage.url?.absoluteString,
            isRead: canonicalMessage.isRead,
            receivedAt: canonicalMessage.receivedAt,
            rawPayloadJSON: rawPayloadJSON,
            status: canonicalMessage.status.rawValue,
            decryptionState: canonicalMessage.decryptionState?.rawValue,
            notificationRequestId: normalizeOptional(canonicalMessage.notificationRequestId),
            deliveryId: normalizeOptional(canonicalMessage.deliveryId),
            operationId: normalizeOptional(canonicalMessage.operationId),
            entityType: canonicalMessage.entityType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            entityId: normalizeOptional(canonicalMessage.entityId),
            eventId: normalizeOptional(canonicalMessage.eventId),
            thingId: normalizeOptional(canonicalMessage.thingId),
            projectionDestination: normalizeOptional(canonicalMessage.projectionDestination),
            eventState: normalizeOptional(canonicalMessage.eventState),
            eventTimeEpoch: Self.epochMilliseconds(from: canonicalMessage.rawPayload["event_time"]?.value),
            observedTimeEpoch: Self.epochMilliseconds(from: canonicalMessage.rawPayload["observed_at"]?.value),
            occurredAtEpoch: Self.epochMilliseconds(from: canonicalMessage.rawPayload["occurred_at"]?.value),
            topLevelMessage: isTopLevelMessage(canonicalMessage)
        )
    }

    private static func normalizeOptional(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func epochMilliseconds(from value: Any?) -> Int64? {
        PayloadTimeParser.epochMilliseconds(from: value)
    }
}

private struct GRDBPendingInboundMessageRecord {
    let pendingId: String
    let thingId: String
    let messageId: String
    let rawPayloadJSON: String
    let title: String
    let body: String
    let channel: String?
    let url: String?
    let receivedAt: Date
    let status: String
    let decryptionState: String?
    let notificationRequestId: String?
    let deliveryId: String?
    let operationId: String?
    let entityType: String
    let entityId: String?
    let eventId: String?
    let eventState: String?
    let eventTimeEpoch: Int64?
    let observedTimeEpoch: Int64?
    let occurredAtEpoch: Int64?

    init(row: Row) {
        pendingId = row["pending_id"]
        thingId = row["thing_id"]
        messageId = row["message_id"]
        rawPayloadJSON = row["raw_payload_json"]
        title = row["title"]
        body = row["body"]
        channel = row["channel"]
        url = row["url"]
        let receivedAtEpoch: Double = row["received_at"]
        receivedAt = GRDBStore.dateFromStoredEpoch(receivedAtEpoch)
        status = row["status"]
        decryptionState = row["decryption_state"]
        notificationRequestId = row["notification_request_id"]
        deliveryId = row["delivery_id"]
        operationId = row["operation_id"]
        entityType = row["entity_type"]
        entityId = row["entity_id"]
        eventId = row["event_id"]
        eventState = row["event_state"]
        eventTimeEpoch = row["event_time_epoch"]
        observedTimeEpoch = row["observed_time_epoch"]
        occurredAtEpoch = row["occurred_at_epoch"]
    }

    func toMessageRecord() -> GRDBMessageRecord {
        GRDBMessageRecord(
            id: UUID(),
            messageId: messageId,
            title: title,
            body: body,
            channel: channel,
            url: url,
            isRead: false,
            receivedAt: receivedAt,
            rawPayloadJSON: rawPayloadJSON,
            status: status,
            decryptionState: decryptionState,
            notificationRequestId: notificationRequestId,
            deliveryId: deliveryId,
            operationId: operationId,
            entityType: entityType,
            entityId: entityId,
            eventId: eventId,
            thingId: thingId,
            projectionDestination: nil,
            eventState: eventState,
            eventTimeEpoch: eventTimeEpoch,
            observedTimeEpoch: observedTimeEpoch,
            occurredAtEpoch: occurredAtEpoch,
            topLevelMessage: false
        )
    }
}

private struct GRDBOperationLedgerRecord {
    let scopeKey: String
    let messageId: String
    let opId: String
    let channelId: String?
    let entityType: String
    let entityId: String
    let deliveryId: String?
    let appliedAt: Date

    init(row: Row) {
        scopeKey = row["scope_key"]
        messageId = row["message_id"]
        opId = row["op_id"]
        channelId = row["channel_id"]
        entityType = row["entity_type"]
        entityId = row["entity_id"]
        deliveryId = row["delivery_id"]
        let appliedAtEpoch: Double = row["applied_at"]
        appliedAt = GRDBStore.dateFromStoredEpoch(appliedAtEpoch)
    }
}

private struct GRDBWatchLightMessageRecord {
    let messageId: String
    let title: String
    let body: String
    let imageURL: String?
    let url: String?
    let severity: String?
    let receivedAt: Date
    let isRead: Bool
    let entityType: String
    let entityId: String?
    let notificationRequestId: String?

    init(row: Row) {
        messageId = row["message_id"]
        title = row["title"]
        body = row["body"]
        imageURL = row["image_url"]
        url = row["url"]
        severity = row["severity"]
        let receivedAtEpoch: Double = row["received_at"]
        receivedAt = GRDBStore.dateFromStoredEpoch(receivedAtEpoch)
        let isReadInt: Int64 = row["is_read"]
        isRead = isReadInt != 0
        entityType = row["entity_type"]
        entityId = row["entity_id"]
        notificationRequestId = row["notification_request_id"]
    }

    func toModel() -> WatchLightMessage {
        WatchLightMessage(
            messageId: messageId,
            title: title,
            body: body,
            imageURL: imageURL.flatMap { URLSanitizer.resolveHTTPSURL(from: $0) },
            url: url.flatMap { URLSanitizer.resolveHTTPSURL(from: $0) },
            severity: severity,
            receivedAt: receivedAt,
            isRead: isRead,
            entityType: entityType,
            entityId: entityId,
            notificationRequestId: notificationRequestId
        )
    }
}

private struct GRDBWatchLightEventRecord {
    let eventId: String
    let title: String
    let summary: String?
    let state: String?
    let severity: String?
    let decryptionState: String?
    let imageURL: String?
    let updatedAt: Date

    init(row: Row) {
        eventId = row["event_id"]
        title = row["title"]
        summary = row["summary"]
        state = row["state"]
        severity = row["severity"]
        decryptionState = row["decryption_state"]
        imageURL = row["image_url"]
        let updatedAtEpoch: Double = row["updated_at"]
        updatedAt = GRDBStore.dateFromStoredEpoch(updatedAtEpoch)
    }

    func toModel() -> WatchLightEvent {
        WatchLightEvent(
            eventId: eventId,
            title: title,
            summary: summary,
            state: state,
            severity: severity,
            decryptionState: decryptionState,
            imageURL: imageURL.flatMap { URLSanitizer.resolveHTTPSURL(from: $0) },
            updatedAt: updatedAt
        )
    }
}

private struct GRDBWatchLightThingRecord {
    let thingId: String
    let title: String
    let summary: String?
    let attrsJSON: String?
    let decryptionState: String?
    let imageURL: String?
    let updatedAt: Date

    init(row: Row) {
        thingId = row["thing_id"]
        title = row["title"]
        summary = row["summary"]
        attrsJSON = row["attrs_json"]
        decryptionState = row["decryption_state"]
        imageURL = row["image_url"]
        let updatedAtEpoch: Double = row["updated_at"]
        updatedAt = GRDBStore.dateFromStoredEpoch(updatedAtEpoch)
    }

    func toModel() -> WatchLightThing {
        WatchLightThing(
            thingId: thingId,
            title: title,
            summary: summary,
            attrsJSON: attrsJSON,
            decryptionState: decryptionState,
            imageURL: imageURL.flatMap { URLSanitizer.resolveHTTPSURL(from: $0) },
            updatedAt: updatedAt
        )
    }
}

private struct GRDBWatchMirrorActionRecord {
    let actionId: String
    let kind: String
    let messageId: String
    let issuedAt: Date

    init(row: Row) {
        actionId = row["action_id"]
        kind = row["kind"]
        messageId = row["message_id"]
        let issuedAtEpoch: Double = row["issued_at"]
        issuedAt = GRDBStore.dateFromStoredEpoch(issuedAtEpoch)
    }

    func toModel() -> WatchMirrorAction? {
        guard let kind = WatchMirrorActionKind(rawValue: kind) else { return nil }
        return WatchMirrorAction(
            actionId: actionId,
            kind: kind,
            messageId: messageId,
            issuedAt: issuedAt
        )
    }
}

private actor GRDBStore {
    private static let maxCursorUUID = UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")!
    private static let sqliteBusyTimeoutSeconds: TimeInterval = 5
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let dbQueue: DatabaseQueue

    init(storeURL: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder

        var configuration = Configuration()
        configuration.busyMode = .timeout(Self.sqliteBusyTimeoutSeconds)
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA busy_timeout = 5000;")
            try Self.applyJournalModeWALIfPossible(db)
            try db.execute(sql: "PRAGMA synchronous = NORMAL;")
            try db.execute(sql: "PRAGMA foreign_keys = ON;")
        }
        dbQueue = try DatabaseQueue(path: storeURL.path, configuration: configuration)
        try Self.migrator.migrate(dbQueue)
    }

    private static func applyJournalModeWALIfPossible(_ db: Database) throws {
        do {
            try db.execute(sql: "PRAGMA journal_mode = WAL;")
        } catch let error as DatabaseError where isTransientSQLiteLock(error) {
            // Another connection may hold the lock while switching modes.
            // Keep opening the database and rely on existing journal mode.
            return
        }
    }

    private static func isTransientSQLiteLock(_ error: DatabaseError) -> Bool {
        error.resultCode == .SQLITE_BUSY || error.resultCode == .SQLITE_LOCKED
    }

    private static let migrator: DatabaseMigrator = {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1_grdb_primary_store") { db in
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
                CREATE TABLE IF NOT EXISTS pending_inbound_messages (
                    pending_id TEXT PRIMARY KEY NOT NULL,
                    thing_id TEXT NOT NULL,
                    message_id TEXT NOT NULL,
                    raw_payload_json TEXT NOT NULL,
                    title TEXT NOT NULL,
                    body TEXT NOT NULL,
                    channel TEXT,
                    url TEXT,
                    received_at REAL NOT NULL,
                    status TEXT NOT NULL,
                    decryption_state TEXT,
                    notification_request_id TEXT,
                    delivery_id TEXT,
                    operation_id TEXT,
                    entity_type TEXT NOT NULL,
                    entity_id TEXT,
                    event_id TEXT,
                    event_state TEXT,
                    event_time_epoch INTEGER,
                    observed_time_epoch INTEGER,
                    occurred_at_epoch INTEGER,
                    created_at REAL NOT NULL,
                    CHECK (length(trim(thing_id)) > 0),
                    CHECK (length(trim(message_id)) > 0)
                );
                """)
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_pending_inbound_messages_thing_order ON pending_inbound_messages(thing_id, occurred_at_epoch ASC, event_time_epoch ASC, observed_time_epoch ASC, received_at ASC, pending_id ASC);")

            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS operation_ledger (
                    scope_key TEXT PRIMARY KEY NOT NULL,
                    message_id TEXT NOT NULL,
                    op_id TEXT NOT NULL,
                    channel_id TEXT,
                    entity_type TEXT NOT NULL,
                    entity_id TEXT NOT NULL,
                    delivery_id TEXT,
                    applied_at REAL NOT NULL,
                    CHECK (length(trim(scope_key)) > 0),
                    CHECK (length(trim(message_id)) > 0)
                );
                """)
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_operation_ledger_applied_at ON operation_ledger(applied_at DESC);")

            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS channel_subscriptions (
                    gateway TEXT NOT NULL,
                    channel_id TEXT NOT NULL,
                    display_name TEXT NOT NULL,
                    password TEXT NOT NULL,
                    last_synced_at REAL,
                    updated_at REAL NOT NULL,
                    is_deleted INTEGER NOT NULL,
                    deleted_at REAL,
                    PRIMARY KEY (gateway, channel_id),
                    CHECK (length(trim(gateway)) > 0),
                    CHECK (length(trim(channel_id)) > 0)
                );
                """)
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_channel_subscriptions_updated_at ON channel_subscriptions(updated_at DESC);")

            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS app_settings (
                    id TEXT PRIMARY KEY NOT NULL,
                    manual_key_encoding TEXT,
                    launch_at_login_enabled INTEGER,
                    message_page_enabled INTEGER,
                    event_page_enabled INTEGER,
                    thing_page_enabled INTEGER,
                    push_token_data_base64 TEXT,
                    watch_mode_raw_value TEXT,
                    updated_at REAL NOT NULL
                );
                """)

            try db.execute(sql: """
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
                    notification_request_id TEXT,
                    CHECK (length(trim(message_id)) > 0)
                );
                """)
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_watch_light_messages_received_at ON watch_light_messages(received_at DESC, message_id DESC);")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_watch_light_messages_notification_request_id ON watch_light_messages(notification_request_id);")

            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS watch_light_events (
                    event_id TEXT PRIMARY KEY NOT NULL,
                    title TEXT NOT NULL,
                    summary TEXT,
                    state TEXT,
                    severity TEXT,
                    decryption_state TEXT,
                    image_url TEXT,
                    updated_at REAL NOT NULL,
                    CHECK (length(trim(event_id)) > 0)
                );
                """)
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_watch_light_events_updated_at ON watch_light_events(updated_at DESC, event_id DESC);")

            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS watch_light_things (
                    thing_id TEXT PRIMARY KEY NOT NULL,
                    title TEXT NOT NULL,
                    summary TEXT,
                    attrs_json TEXT,
                    decryption_state TEXT,
                    image_url TEXT,
                    updated_at REAL NOT NULL,
                    CHECK (length(trim(thing_id)) > 0)
                );
                """)
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_watch_light_things_updated_at ON watch_light_things(updated_at DESC, thing_id DESC);")

            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS watch_mirror_action_queue (
                    action_id TEXT PRIMARY KEY NOT NULL,
                    kind TEXT NOT NULL,
                    message_id TEXT NOT NULL,
                    issued_at REAL NOT NULL,
                    CHECK (length(trim(action_id)) > 0),
                    CHECK (length(trim(message_id)) > 0)
                );
                """)
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_watch_mirror_action_queue_issued_at ON watch_mirror_action_queue(issued_at ASC, action_id ASC);")
        }
        migrator.registerMigration("v2_watch_sync_state_columns") { db in
            let existingColumns = Set(try Row.fetchAll(db, sql: "PRAGMA table_info(app_settings);").compactMap {
                $0["name"] as String?
            })
            let pendingColumns: [(name: String, sqlType: String)] = [
                ("watch_mode_raw_value", "TEXT"),
                ("watch_control_generation", "INTEGER"),
                ("watch_mirror_snapshot_generation", "INTEGER"),
                ("watch_standalone_provisioning_generation", "INTEGER"),
                ("watch_mirror_action_ack_generation", "INTEGER"),
                ("watch_mirror_snapshot_content_digest", "TEXT"),
                ("watch_standalone_provisioning_content_digest", "TEXT"),
            ]
            for column in pendingColumns where !existingColumns.contains(column.name) {
                try db.execute(sql: "ALTER TABLE app_settings ADD COLUMN \(column.name) \(column.sqlType);")
            }
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_messages_delivery_id ON messages(delivery_id);")
        }
        migrator.registerMigration("v3_watch_provisioning_columns") { db in
            let existingColumns = Set(try Row.fetchAll(db, sql: "PRAGMA table_info(app_settings);").compactMap {
                $0["name"] as String?
            })
            let pendingColumns: [(name: String, sqlType: String)] = [
                ("watch_provisioning_server_config_data_base64", "TEXT"),
                ("watch_provisioning_schema_version", "INTEGER"),
                ("watch_provisioning_generation", "INTEGER"),
                ("watch_provisioning_content_digest", "TEXT"),
                ("watch_provisioning_applied_at", "REAL"),
                ("watch_provisioning_mode_raw_value", "TEXT"),
                ("watch_provisioning_source_control_generation", "INTEGER"),
            ]
            for column in pendingColumns where !existingColumns.contains(column.name) {
                try db.execute(sql: "ALTER TABLE app_settings ADD COLUMN \(column.name) \(column.sqlType);")
            }
        }
        migrator.registerMigration("v4_watch_mode_control_state_columns") { db in
            let existingColumns = Set(try Row.fetchAll(db, sql: "PRAGMA table_info(app_settings);").compactMap {
                $0["name"] as String?
            })
            let pendingColumns: [(name: String, sqlType: String)] = [
                ("watch_effective_mode_raw_value", "TEXT"),
                ("watch_mode_switch_status_raw_value", "TEXT"),
                ("watch_last_confirmed_control_generation", "INTEGER"),
                ("watch_last_observed_reported_generation", "INTEGER"),
            ]
            for column in pendingColumns where !existingColumns.contains(column.name) {
                try db.execute(sql: "ALTER TABLE app_settings ADD COLUMN \(column.name) \(column.sqlType);")
            }
        }
        migrator.registerMigration("v5_watch_mode_control_readiness_column") { db in
            let existingColumns = Set(try Row.fetchAll(db, sql: "PRAGMA table_info(app_settings);").compactMap {
                $0["name"] as String?
            })
            let pendingColumns: [(name: String, sqlType: String)] = [
                ("watch_standalone_ready", "INTEGER"),
            ]
            for column in pendingColumns where !existingColumns.contains(column.name) {
                try db.execute(sql: "ALTER TABLE app_settings ADD COLUMN \(column.name) \(column.sqlType);")
            }
        }
        migrator.registerMigration("v6_watch_publication_digest_columns") { db in
            let existingColumns = Set(try Row.fetchAll(db, sql: "PRAGMA table_info(app_settings);").compactMap {
                $0["name"] as String?
            })
            let pendingColumns: [(name: String, sqlType: String)] = [
                ("watch_mirror_snapshot_content_digest", "TEXT"),
                ("watch_standalone_provisioning_content_digest", "TEXT"),
            ]
            for column in pendingColumns where !existingColumns.contains(column.name) {
                try db.execute(sql: "ALTER TABLE app_settings ADD COLUMN \(column.name) \(column.sqlType);")
            }
        }
        migrator.registerMigration("v7_watch_light_notify_columns") { db in
            _ = db
        }
        migrator.registerMigration("v8_rebuild_snake_case_schema") { db in
            // No backward-compatibility for legacy camelCase local schema.
            try db.execute(sql: "DROP TABLE IF EXISTS message_search;")
            try db.execute(sql: "DROP TABLE IF EXISTS message_metadata_index;")
            try db.execute(sql: "DROP TABLE IF EXISTS watch_mirror_action_queue;")
            try db.execute(sql: "DROP TABLE IF EXISTS watch_light_things;")
            try db.execute(sql: "DROP TABLE IF EXISTS watch_light_events;")
            try db.execute(sql: "DROP TABLE IF EXISTS watch_light_messages;")
            try db.execute(sql: "DROP TABLE IF EXISTS app_settings;")
            try db.execute(sql: "DROP TABLE IF EXISTS channel_subscriptions;")
            try db.execute(sql: "DROP TABLE IF EXISTS operation_ledger;")
            try db.execute(sql: "DROP TABLE IF EXISTS messages;")

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
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_messages_delivery_id ON messages(delivery_id);")
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS pending_inbound_messages (
                    pending_id TEXT PRIMARY KEY NOT NULL,
                    thing_id TEXT NOT NULL,
                    message_id TEXT NOT NULL,
                    raw_payload_json TEXT NOT NULL,
                    title TEXT NOT NULL,
                    body TEXT NOT NULL,
                    channel TEXT,
                    url TEXT,
                    received_at REAL NOT NULL,
                    status TEXT NOT NULL,
                    decryption_state TEXT,
                    notification_request_id TEXT,
                    delivery_id TEXT,
                    operation_id TEXT,
                    entity_type TEXT NOT NULL,
                    entity_id TEXT,
                    event_id TEXT,
                    event_state TEXT,
                    event_time_epoch INTEGER,
                    observed_time_epoch INTEGER,
                    occurred_at_epoch INTEGER,
                    created_at REAL NOT NULL,
                    CHECK (length(trim(thing_id)) > 0),
                    CHECK (length(trim(message_id)) > 0)
                );
                """)
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_pending_inbound_messages_thing_order ON pending_inbound_messages(thing_id, occurred_at_epoch ASC, event_time_epoch ASC, observed_time_epoch ASC, received_at ASC, pending_id ASC);")

            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS operation_ledger (
                    scope_key TEXT PRIMARY KEY NOT NULL,
                    message_id TEXT NOT NULL,
                    op_id TEXT NOT NULL,
                    channel_id TEXT,
                    entity_type TEXT NOT NULL,
                    entity_id TEXT NOT NULL,
                    delivery_id TEXT,
                    applied_at REAL NOT NULL,
                    CHECK (length(trim(scope_key)) > 0),
                    CHECK (length(trim(message_id)) > 0)
                );
                """)
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_operation_ledger_applied_at ON operation_ledger(applied_at DESC);")

            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS channel_subscriptions (
                    gateway TEXT NOT NULL,
                    channel_id TEXT NOT NULL,
                    display_name TEXT NOT NULL,
                    password TEXT NOT NULL,
                    last_synced_at REAL,
                    updated_at REAL NOT NULL,
                    is_deleted INTEGER NOT NULL,
                    deleted_at REAL,
                    PRIMARY KEY (gateway, channel_id),
                    CHECK (length(trim(gateway)) > 0),
                    CHECK (length(trim(channel_id)) > 0)
                );
                """)
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_channel_subscriptions_updated_at ON channel_subscriptions(updated_at DESC);")

            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS app_settings (
                    id TEXT PRIMARY KEY NOT NULL,
                    manual_key_encoding TEXT,
                    launch_at_login_enabled INTEGER,
                    message_page_enabled INTEGER,
                    event_page_enabled INTEGER,
                    thing_page_enabled INTEGER,
                    push_token_data_base64 TEXT,
                    watch_mode_raw_value TEXT,
                    watch_effective_mode_raw_value TEXT,
                    watch_standalone_ready INTEGER,
                    watch_mode_switch_status_raw_value TEXT,
                    watch_last_confirmed_control_generation INTEGER,
                    watch_last_observed_reported_generation INTEGER,
                    watch_control_generation INTEGER,
                    watch_mirror_snapshot_generation INTEGER,
                    watch_standalone_provisioning_generation INTEGER,
                    watch_mirror_action_ack_generation INTEGER,
                    watch_mirror_snapshot_content_digest TEXT,
                    watch_standalone_provisioning_content_digest TEXT,
                    watch_provisioning_server_config_data_base64 TEXT,
                    watch_provisioning_schema_version INTEGER,
                    watch_provisioning_generation INTEGER,
                    watch_provisioning_content_digest TEXT,
                    watch_provisioning_applied_at REAL,
                    watch_provisioning_mode_raw_value TEXT,
                    watch_provisioning_source_control_generation INTEGER,
                    updated_at REAL NOT NULL
                );
                """)

            try db.execute(sql: """
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
                    notification_request_id TEXT,
                    CHECK (length(trim(message_id)) > 0)
                );
                """)
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_watch_light_messages_received_at ON watch_light_messages(received_at DESC, message_id DESC);")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_watch_light_messages_notification_request_id ON watch_light_messages(notification_request_id);")

            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS watch_light_events (
                    event_id TEXT PRIMARY KEY NOT NULL,
                    title TEXT NOT NULL,
                    summary TEXT,
                    state TEXT,
                    severity TEXT,
                    decryption_state TEXT,
                    image_url TEXT,
                    updated_at REAL NOT NULL,
                    CHECK (length(trim(event_id)) > 0)
                );
                """)
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_watch_light_events_updated_at ON watch_light_events(updated_at DESC, event_id DESC);")

            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS watch_light_things (
                    thing_id TEXT PRIMARY KEY NOT NULL,
                    title TEXT NOT NULL,
                    summary TEXT,
                    attrs_json TEXT,
                    decryption_state TEXT,
                    image_url TEXT,
                    updated_at REAL NOT NULL,
                    CHECK (length(trim(thing_id)) > 0)
                );
                """)
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_watch_light_things_updated_at ON watch_light_things(updated_at DESC, thing_id DESC);")

            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS watch_mirror_action_queue (
                    action_id TEXT PRIMARY KEY NOT NULL,
                    kind TEXT NOT NULL,
                    message_id TEXT NOT NULL,
                    issued_at REAL NOT NULL,
                    CHECK (length(trim(action_id)) > 0),
                    CHECK (length(trim(message_id)) > 0)
                );
                """)
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_watch_mirror_action_queue_issued_at ON watch_mirror_action_queue(issued_at ASC, action_id ASC);")
        }
        migrator.registerMigration("v9_message_occurred_at_epoch") { db in
            let existingColumns = Set(try Row.fetchAll(db, sql: "PRAGMA table_info(messages);").compactMap {
                $0["name"] as String?
            })
            if !existingColumns.contains("occurred_at_epoch") {
                try db.execute(sql: "ALTER TABLE messages ADD COLUMN occurred_at_epoch INTEGER;")
            }
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_messages_entity_projection ON messages(entity_type, event_time_epoch DESC, occurred_at_epoch DESC, received_at DESC, id DESC);")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_messages_thing_projection ON messages(thing_id, occurred_at_epoch DESC, observed_time_epoch DESC, event_time_epoch DESC, received_at DESC, id DESC);")
        }
        migrator.registerMigration("v10_pending_inbound_messages") { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS pending_inbound_messages (
                    pending_id TEXT PRIMARY KEY NOT NULL,
                    thing_id TEXT NOT NULL,
                    message_id TEXT NOT NULL,
                    raw_payload_json TEXT NOT NULL,
                    title TEXT NOT NULL,
                    body TEXT NOT NULL,
                    channel TEXT,
                    url TEXT,
                    received_at REAL NOT NULL,
                    status TEXT NOT NULL,
                    decryption_state TEXT,
                    notification_request_id TEXT,
                    delivery_id TEXT,
                    operation_id TEXT,
                    entity_type TEXT NOT NULL,
                    entity_id TEXT,
                    event_id TEXT,
                    event_state TEXT,
                    event_time_epoch INTEGER,
                    observed_time_epoch INTEGER,
                    occurred_at_epoch INTEGER,
                    created_at REAL NOT NULL,
                    CHECK (length(trim(thing_id)) > 0),
                    CHECK (length(trim(message_id)) > 0)
                );
                """)
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_pending_inbound_messages_thing_order ON pending_inbound_messages(thing_id, occurred_at_epoch ASC, event_time_epoch ASC, observed_time_epoch ASC, received_at ASC, pending_id ASC);")
        }
        migrator.registerMigration("v11_projection_epoch_millis") { db in
            let threshold = 1_000_000_000_000 as Int64
            try db.execute(
                sql: """
                    UPDATE messages
                    SET event_time_epoch = event_time_epoch * 1000
                    WHERE event_time_epoch IS NOT NULL
                      AND ABS(event_time_epoch) < ?;
                    """,
                arguments: [threshold]
            )
            try db.execute(
                sql: """
                    UPDATE messages
                    SET observed_time_epoch = observed_time_epoch * 1000
                    WHERE observed_time_epoch IS NOT NULL
                      AND ABS(observed_time_epoch) < ?;
                    """,
                arguments: [threshold]
            )
            try db.execute(
                sql: """
                    UPDATE messages
                    SET occurred_at_epoch = occurred_at_epoch * 1000
                    WHERE occurred_at_epoch IS NOT NULL
                      AND ABS(occurred_at_epoch) < ?;
                    """,
                arguments: [threshold]
            )
            try db.execute(
                sql: """
                    UPDATE pending_inbound_messages
                    SET event_time_epoch = event_time_epoch * 1000
                    WHERE event_time_epoch IS NOT NULL
                      AND ABS(event_time_epoch) < ?;
                    """,
                arguments: [threshold]
            )
            try db.execute(
                sql: """
                    UPDATE pending_inbound_messages
                    SET observed_time_epoch = observed_time_epoch * 1000
                    WHERE observed_time_epoch IS NOT NULL
                      AND ABS(observed_time_epoch) < ?;
                    """,
                arguments: [threshold]
            )
            try db.execute(
                sql: """
                    UPDATE pending_inbound_messages
                    SET occurred_at_epoch = occurred_at_epoch * 1000
                    WHERE occurred_at_epoch IS NOT NULL
                      AND ABS(occurred_at_epoch) < ?;
                    """,
                arguments: [threshold]
            )
        }
        migrator.registerMigration("v12_all_epoch_millis") { db in
            let threshold = 1_000_000_000_000 as Int64
            let targets: [(String, [String])] = [
                ("messages", ["received_at", "event_time_epoch", "observed_time_epoch", "occurred_at_epoch"]),
                ("pending_inbound_messages", ["received_at", "created_at", "event_time_epoch", "observed_time_epoch", "occurred_at_epoch"]),
                ("operation_ledger", ["applied_at"]),
                ("channel_subscriptions", ["updated_at", "last_synced_at", "deleted_at"]),
                ("app_settings", ["updated_at", "watch_provisioning_applied_at"]),
                ("watch_light_messages", ["received_at"]),
                ("watch_light_events", ["updated_at"]),
                ("watch_light_things", ["updated_at"]),
                ("watch_mirror_action_queue", ["issued_at"]),
            ]
            for (table, columns) in targets {
                for column in columns {
                    try db.execute(
                        sql: """
                            UPDATE \(table)
                            SET \(column) = \(column) * 1000
                            WHERE \(column) IS NOT NULL
                              AND ABS(\(column)) < ?;
                            """,
                        arguments: [threshold]
                    )
                }
            }
        }
        migrator.registerMigration("v13_watch_light_decryption_state_columns") { db in
            let watchEventColumns = Set(
                try Row.fetchAll(db, sql: "PRAGMA table_info(watch_light_events);")
                    .compactMap { $0["name"] as String? }
            )
            if !watchEventColumns.contains("decryption_state") {
                try db.execute(sql: "ALTER TABLE watch_light_events ADD COLUMN decryption_state TEXT;")
            }
            let watchThingColumns = Set(
                try Row.fetchAll(db, sql: "PRAGMA table_info(watch_light_things);")
                    .compactMap { $0["name"] as String? }
            )
            if !watchThingColumns.contains("decryption_state") {
                try db.execute(sql: "ALTER TABLE watch_light_things ADD COLUMN decryption_state TEXT;")
            }
        }
        migrator.registerMigration("v14_provider_delivery_ack_outbox") { db in
            _ = db
        }
        migrator.registerMigration("v15_drop_provider_delivery_ack_outbox") { db in
            try db.execute(sql: "DROP TABLE IF EXISTS provider_delivery_ack_outbox;")
        }
        return migrator
    }()

    private static func sqlQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "''"))'"
    }

    private static func sqlOptionalText(_ value: String?) -> String {
        guard let value else { return "NULL" }
        return sqlQuoted(value)
    }

    private static func sqlOptionalDouble(_ value: Double?) -> String {
        guard let value else { return "NULL" }
        return String(value)
    }

    fileprivate static func normalizeStoredEpochMillis(_ value: Double) -> Double {
        let threshold = Double(1_000_000_000_000 as Int64)
        return abs(value) >= threshold ? value : value * 1000.0
    }

    fileprivate static func storedEpoch(_ date: Date) -> Double {
        date.timeIntervalSince1970 * 1000.0
    }

    fileprivate static func dateFromStoredEpoch(_ value: Double) -> Date {
        Date(timeIntervalSince1970: normalizeStoredEpochMillis(value) / 1000.0)
    }

    private static func sqlOptionalInt64(_ value: Int64?) -> String {
        guard let value else { return "NULL" }
        return String(value)
    }

    private static func sqlOptionalBool(_ value: Bool?) -> String {
        guard let value else { return "NULL" }
        return value ? "1" : "0"
    }

    private static func normalizeOptional(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func normalizeGateway(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalizeChannelIdentifierForMatch(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let alphabet = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"
        var output = String()
        output.reserveCapacity(26)
        for ch in trimmed {
            if ch == "-" || ch.isWhitespace {
                continue
            }
            let upper = String(ch).uppercased()
            let mapped: String
            switch upper {
            case "O":
                mapped = "0"
            case "I", "L":
                mapped = "1"
            default:
                mapped = upper
            }
            guard mapped.count == 1,
                  let scalar = mapped.unicodeScalars.first,
                  scalar.isASCII,
                  alphabet.contains(mapped)
            else {
                return nil
            }
            output.append(Character(mapped))
        }
        return output.count == 26 ? output : nil
    }

    private static func canonicalChannelExpression(column: String) -> String {
        let trimmed = "trim(coalesce(\(column), ''))"
        let withoutDelimiters = "replace(replace(replace(replace(replace(\(trimmed), '-', ''), ' ', ''), char(9), ''), char(10), ''), char(13), '')"
        let uppercased = "upper(\(withoutDelimiters))"
        let mappedO = "replace(\(uppercased), 'O', '0')"
        let mappedI = "replace(\(mappedO), 'I', '1')"
        let mappedL = "replace(\(mappedI), 'L', '1')"
        return mappedL
    }

    private static func channelMatchCondition(column: String = "channel", value: String?) -> String {
        guard let value else { return "1" }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return "(\(canonicalChannelExpression(column: column)) = '')"
        }
        if let normalized = normalizeChannelIdentifierForMatch(trimmed) {
            return "(\(canonicalChannelExpression(column: column)) = \(sqlQuoted(normalized)))"
        }
        return "(\(column) = \(sqlQuoted(trimmed)))"
    }

    private func normalizedTagValue(_ rawTag: String?) -> String? {
        guard let rawTag else { return nil }
        let normalized = rawTag.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.isEmpty ? nil : normalized
    }

    private func read<T>(_ action: (Database) throws -> T) throws -> T {
        try dbQueue.read(action)
    }

    private func write<T>(_ action: (Database) throws -> T) throws -> T {
        try dbQueue.write(action)
    }

    private func loadAppSettings(_ db: Database) throws -> AppSettingsSnapshot? {
        let sql = "SELECT * FROM app_settings WHERE id = 'default' LIMIT 1;"
        guard let row = try Row.fetchOne(db, sql: sql) else { return nil }
        let manualKeyEncoding: String? = row["manual_key_encoding"]
        let launchAtLoginInt: Int64? = row["launch_at_login_enabled"]
        let messagePageInt: Int64? = row["message_page_enabled"]
        let eventPageInt: Int64? = row["event_page_enabled"]
        let thingPageInt: Int64? = row["thing_page_enabled"]
        let pushTokenDataBase64: String? = row["push_token_data_base64"]
        let watchModeRawValue: String? = row["watch_mode_raw_value"]
        let watchEffectiveModeRawValue: String? = row["watch_effective_mode_raw_value"]
        let watchStandaloneReadyInt: Int64? = row["watch_standalone_ready"]
        let watchModeSwitchStatusRawValue: String? = row["watch_mode_switch_status_raw_value"]
        let watchLastConfirmedControlGeneration: Int64? = row["watch_last_confirmed_control_generation"]
        let watchLastObservedReportedGeneration: Int64? = row["watch_last_observed_reported_generation"]
        let watchControlGeneration: Int64? = row["watch_control_generation"]
        let watchMirrorSnapshotGeneration: Int64? = row["watch_mirror_snapshot_generation"]
        let watchStandaloneProvisioningGeneration: Int64? = row["watch_standalone_provisioning_generation"]
        let watchMirrorActionAckGeneration: Int64? = row["watch_mirror_action_ack_generation"]
        let watchMirrorSnapshotContentDigest: String? = row["watch_mirror_snapshot_content_digest"]
        let watchStandaloneProvisioningContentDigest: String? = row["watch_standalone_provisioning_content_digest"]
        let watchProvisioningServerConfigDataBase64: String? = row["watch_provisioning_server_config_data_base64"]
        let watchProvisioningSchemaVersion: Int? = row["watch_provisioning_schema_version"]
        let watchProvisioningGeneration: Int64? = row["watch_provisioning_generation"]
        let watchProvisioningContentDigest: String? = row["watch_provisioning_content_digest"]
        let watchProvisioningAppliedAtEpoch: Double? = row["watch_provisioning_applied_at"]
        let watchProvisioningModeRawValue: String? = row["watch_provisioning_mode_raw_value"]
        let watchProvisioningSourceControlGeneration: Int64? = row["watch_provisioning_source_control_generation"]

        return AppSettingsSnapshot(
            manualKeyEncoding: manualKeyEncoding,
            launchAtLoginEnabled: launchAtLoginInt.map { $0 != 0 },
            messagePageEnabled: messagePageInt.map { $0 != 0 },
            eventPageEnabled: eventPageInt.map { $0 != 0 },
            thingPageEnabled: thingPageInt.map { $0 != 0 },
            pushTokenData: pushTokenDataBase64.flatMap { Data(base64Encoded: $0) },
            watchModeRawValue: watchModeRawValue,
            watchEffectiveModeRawValue: watchEffectiveModeRawValue,
            watchStandaloneReady: watchStandaloneReadyInt.map { $0 != 0 },
            watchModeSwitchStatusRawValue: watchModeSwitchStatusRawValue,
            watchLastConfirmedControlGeneration: watchLastConfirmedControlGeneration,
            watchLastObservedReportedGeneration: watchLastObservedReportedGeneration,
            watchControlGeneration: watchControlGeneration,
            watchMirrorSnapshotGeneration: watchMirrorSnapshotGeneration,
            watchStandaloneProvisioningGeneration: watchStandaloneProvisioningGeneration,
            watchMirrorActionAckGeneration: watchMirrorActionAckGeneration,
            watchMirrorSnapshotContentDigest: watchMirrorSnapshotContentDigest,
            watchStandaloneProvisioningContentDigest: watchStandaloneProvisioningContentDigest,
            watchProvisioningServerConfigData: watchProvisioningServerConfigDataBase64.flatMap { Data(base64Encoded: $0) },
            watchProvisioningSchemaVersion: watchProvisioningSchemaVersion,
            watchProvisioningGeneration: watchProvisioningGeneration,
            watchProvisioningContentDigest: watchProvisioningContentDigest,
            watchProvisioningAppliedAt: watchProvisioningAppliedAtEpoch.map(GRDBStore.dateFromStoredEpoch),
            watchProvisioningModeRawValue: watchProvisioningModeRawValue,
            watchProvisioningSourceControlGeneration: watchProvisioningSourceControlGeneration
        )
    }

    private func saveAppSettings(_ snapshot: AppSettingsSnapshot, db: Database) throws {
        let pushTokenDataBase64 = snapshot.pushTokenData?.base64EncodedString()
        let watchProvisioningServerConfigDataBase64 = snapshot.watchProvisioningServerConfigData?.base64EncodedString()
        let sql = """
            INSERT INTO app_settings (
                id, manual_key_encoding, launch_at_login_enabled, message_page_enabled,
                event_page_enabled, thing_page_enabled, push_token_data_base64, watch_mode_raw_value,
                watch_effective_mode_raw_value, watch_standalone_ready, watch_mode_switch_status_raw_value,
                watch_last_confirmed_control_generation, watch_last_observed_reported_generation,
                watch_control_generation, watch_mirror_snapshot_generation,
                watch_standalone_provisioning_generation, watch_mirror_action_ack_generation,
                watch_mirror_snapshot_content_digest, watch_standalone_provisioning_content_digest,
                watch_provisioning_server_config_data_base64, watch_provisioning_schema_version,
                watch_provisioning_generation, watch_provisioning_content_digest,
                watch_provisioning_applied_at, watch_provisioning_mode_raw_value,
                watch_provisioning_source_control_generation, updated_at
            ) VALUES (
                'default',
                \(Self.sqlOptionalText(snapshot.manualKeyEncoding)),
                \(Self.sqlOptionalBool(snapshot.launchAtLoginEnabled)),
                \(Self.sqlOptionalBool(snapshot.messagePageEnabled)),
                \(Self.sqlOptionalBool(snapshot.eventPageEnabled)),
                \(Self.sqlOptionalBool(snapshot.thingPageEnabled)),
                \(Self.sqlOptionalText(pushTokenDataBase64)),
                \(Self.sqlOptionalText(snapshot.watchModeRawValue)),
                \(Self.sqlOptionalText(snapshot.watchEffectiveModeRawValue)),
                \(Self.sqlOptionalBool(snapshot.watchStandaloneReady)),
                \(Self.sqlOptionalText(snapshot.watchModeSwitchStatusRawValue)),
                \(Self.sqlOptionalInt64(snapshot.watchLastConfirmedControlGeneration)),
                \(Self.sqlOptionalInt64(snapshot.watchLastObservedReportedGeneration)),
                \(Self.sqlOptionalInt64(snapshot.watchControlGeneration)),
                \(Self.sqlOptionalInt64(snapshot.watchMirrorSnapshotGeneration)),
                \(Self.sqlOptionalInt64(snapshot.watchStandaloneProvisioningGeneration)),
                \(Self.sqlOptionalInt64(snapshot.watchMirrorActionAckGeneration)),
                \(Self.sqlOptionalText(snapshot.watchMirrorSnapshotContentDigest)),
                \(Self.sqlOptionalText(snapshot.watchStandaloneProvisioningContentDigest)),
                \(Self.sqlOptionalText(watchProvisioningServerConfigDataBase64)),
                \(snapshot.watchProvisioningSchemaVersion.map(String.init) ?? "NULL"),
                \(Self.sqlOptionalInt64(snapshot.watchProvisioningGeneration)),
                \(Self.sqlOptionalText(snapshot.watchProvisioningContentDigest)),
                \(Self.sqlOptionalDouble(snapshot.watchProvisioningAppliedAt.map(Self.storedEpoch))),
                \(Self.sqlOptionalText(snapshot.watchProvisioningModeRawValue)),
                \(Self.sqlOptionalInt64(snapshot.watchProvisioningSourceControlGeneration)),
                \(Self.storedEpoch(Date()))
            )
            ON CONFLICT(id) DO UPDATE SET
                manual_key_encoding = excluded.manual_key_encoding,
                launch_at_login_enabled = excluded.launch_at_login_enabled,
                message_page_enabled = excluded.message_page_enabled,
                event_page_enabled = excluded.event_page_enabled,
                thing_page_enabled = excluded.thing_page_enabled,
                push_token_data_base64 = excluded.push_token_data_base64,
                watch_mode_raw_value = excluded.watch_mode_raw_value,
                watch_effective_mode_raw_value = excluded.watch_effective_mode_raw_value,
                watch_standalone_ready = excluded.watch_standalone_ready,
                watch_mode_switch_status_raw_value = excluded.watch_mode_switch_status_raw_value,
                watch_last_confirmed_control_generation = excluded.watch_last_confirmed_control_generation,
                watch_last_observed_reported_generation = excluded.watch_last_observed_reported_generation,
                watch_control_generation = excluded.watch_control_generation,
                watch_mirror_snapshot_generation = excluded.watch_mirror_snapshot_generation,
                watch_standalone_provisioning_generation = excluded.watch_standalone_provisioning_generation,
                watch_mirror_action_ack_generation = excluded.watch_mirror_action_ack_generation,
                watch_mirror_snapshot_content_digest = excluded.watch_mirror_snapshot_content_digest,
                watch_standalone_provisioning_content_digest = excluded.watch_standalone_provisioning_content_digest,
                watch_provisioning_server_config_data_base64 = excluded.watch_provisioning_server_config_data_base64,
                watch_provisioning_schema_version = excluded.watch_provisioning_schema_version,
                watch_provisioning_generation = excluded.watch_provisioning_generation,
                watch_provisioning_content_digest = excluded.watch_provisioning_content_digest,
                watch_provisioning_applied_at = excluded.watch_provisioning_applied_at,
                watch_provisioning_mode_raw_value = excluded.watch_provisioning_mode_raw_value,
                watch_provisioning_source_control_generation = excluded.watch_provisioning_source_control_generation,
                updated_at = excluded.updated_at;
            """
        try db.execute(sql: sql)
    }

    private func decodeWatchProvisioningServerConfig(
        from settings: AppSettingsSnapshot?
    ) throws -> ServerConfig? {
        guard let data = settings?.watchProvisioningServerConfigData else { return nil }
        return try decoder.decode(ServerConfig.self, from: data)
    }

    private func encodeWatchProvisioningServerConfig(_ config: ServerConfig?) throws -> Data? {
        guard let config else { return nil }
        return try encoder.encode(config)
    }

    private func localStoreError(_ message: String) -> AppError {
        AppError.localStore(message)
    }

    private func buildMessageRecord(from message: PushMessage) throws -> GRDBMessageRecord {
        try GRDBMessageRecord.from(message: message, encoder: encoder)
    }

    private func hasThingParentRecord(
        thingId: String,
        db: Database
    ) throws -> Bool {
        let sql = """
            SELECT 1
            FROM messages
            WHERE entity_type = 'thing'
              AND (
                entity_id = \(Self.sqlQuoted(thingId))
                OR thing_id = \(Self.sqlQuoted(thingId))
              )
            LIMIT 1;
            """
        return try Row.fetchOne(db, sql: sql) != nil
    }

    private func enqueuePendingInboundMessage(
        _ record: GRDBMessageRecord,
        thingId: String,
        db: Database
    ) throws {
        let sql = """
            INSERT INTO pending_inbound_messages (
                pending_id, thing_id, message_id, raw_payload_json,
                title, body, channel, url, received_at, status, decryption_state,
                notification_request_id, delivery_id, operation_id,
                entity_type, entity_id, event_id, event_state,
                event_time_epoch, observed_time_epoch, occurred_at_epoch, created_at
            ) VALUES (
                \(Self.sqlQuoted(UUID().uuidString)),
                \(Self.sqlQuoted(thingId)),
                \(Self.sqlQuoted(record.messageId)),
                \(Self.sqlQuoted(record.rawPayloadJSON)),
                \(Self.sqlQuoted(record.title)),
                \(Self.sqlQuoted(record.body)),
                \(Self.sqlOptionalText(record.channel)),
                \(Self.sqlOptionalText(record.url)),
                \(Self.storedEpoch(record.receivedAt)),
                \(Self.sqlQuoted(record.status)),
                \(Self.sqlOptionalText(record.decryptionState)),
                \(Self.sqlOptionalText(record.notificationRequestId)),
                \(Self.sqlOptionalText(record.deliveryId)),
                \(Self.sqlOptionalText(record.operationId)),
                \(Self.sqlQuoted(record.entityType)),
                \(Self.sqlOptionalText(record.entityId)),
                \(Self.sqlOptionalText(record.eventId)),
                \(Self.sqlOptionalText(record.eventState)),
                \(Self.sqlOptionalInt64(record.eventTimeEpoch)),
                \(Self.sqlOptionalInt64(record.observedTimeEpoch)),
                \(Self.sqlOptionalInt64(record.occurredAtEpoch)),
                \(Self.storedEpoch(Date()))
            );
            """
        try db.execute(sql: sql)
    }

    private func replayPendingInboundMessages(
        thingId: String,
        db: Database
    ) throws {
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT *
                FROM pending_inbound_messages
                WHERE thing_id = \(Self.sqlQuoted(thingId))
                ORDER BY occurred_at_epoch ASC, event_time_epoch ASC, observed_time_epoch ASC, received_at ASC, pending_id ASC;
                """
        )
        guard !rows.isEmpty else { return }
        for row in rows {
            let pending = GRDBPendingInboundMessageRecord(row: row)
            let record = pending.toMessageRecord()

            if try loadMessageRecordByMessageId(record.messageId, db: db) != nil {
                try db.execute(
                    sql: "DELETE FROM pending_inbound_messages WHERE pending_id = \(Self.sqlQuoted(pending.pendingId));"
                )
                continue
            }
            if let identity = resolveOperationScopeIdentity(from: record.toPushMessage(decoder: decoder)),
               try fetchOperationLedger(scopeKey: identity.scopeKey, db: db) != nil
            {
                try db.execute(
                    sql: "DELETE FROM pending_inbound_messages WHERE pending_id = \(Self.sqlQuoted(pending.pendingId));"
                )
                continue
            }

            try insertOrUpdateMessage(record, db: db, updateOnConflict: false)
            if let identity = resolveOperationScopeIdentity(from: record.toPushMessage(decoder: decoder)) {
                try upsertOperationLedger(
                    identity: identity,
                    messageId: record.messageId,
                    appliedAt: Date(),
                    db: db
                )
            }
            try db.execute(
                sql: "DELETE FROM pending_inbound_messages WHERE pending_id = \(Self.sqlQuoted(pending.pendingId));"
            )
        }
    }

    private func insertOrUpdateMessage(
        _ record: GRDBMessageRecord,
        db: Database,
        updateOnConflict: Bool
    ) throws {
        let baseInsertSQL = """
            INSERT INTO messages (
                id, message_id, title, body, channel, url, is_read, received_at,
                raw_payload_json, status, decryption_state, notification_request_id,
                delivery_id, operation_id, entity_type, entity_id, event_id, thing_id,
                projection_destination, event_state, event_time_epoch, observed_time_epoch,
                occurred_at_epoch,
                is_top_level_message
            ) VALUES (
                \(Self.sqlQuoted(record.id.uuidString)),
                \(Self.sqlQuoted(record.messageId)),
                \(Self.sqlQuoted(record.title)),
                \(Self.sqlQuoted(record.body)),
                \(Self.sqlOptionalText(record.channel)),
                \(Self.sqlOptionalText(record.url)),
                \(record.isRead ? 1 : 0),
                \(Self.storedEpoch(record.receivedAt)),
                \(Self.sqlQuoted(record.rawPayloadJSON)),
                \(Self.sqlQuoted(record.status)),
                \(Self.sqlOptionalText(record.decryptionState)),
                \(Self.sqlOptionalText(record.notificationRequestId)),
                \(Self.sqlOptionalText(record.deliveryId)),
                \(Self.sqlOptionalText(record.operationId)),
                \(Self.sqlQuoted(record.entityType)),
                \(Self.sqlOptionalText(record.entityId)),
                \(Self.sqlOptionalText(record.eventId)),
                \(Self.sqlOptionalText(record.thingId)),
                \(Self.sqlOptionalText(record.projectionDestination)),
                \(Self.sqlOptionalText(record.eventState)),
                \(Self.sqlOptionalInt64(record.eventTimeEpoch)),
                \(Self.sqlOptionalInt64(record.observedTimeEpoch)),
                \(Self.sqlOptionalInt64(record.occurredAtEpoch)),
                \(record.topLevelMessage ? 1 : 0)
            )
            """

        if updateOnConflict {
            let sql = baseInsertSQL + """
                ON CONFLICT(message_id) DO UPDATE SET
                    title = excluded.title,
                    body = excluded.body,
                    channel = excluded.channel,
                    url = excluded.url,
                    is_read = excluded.is_read,
                    received_at = excluded.received_at,
                    raw_payload_json = excluded.raw_payload_json,
                    status = excluded.status,
                    decryption_state = excluded.decryption_state,
                    notification_request_id = excluded.notification_request_id,
                    delivery_id = excluded.delivery_id,
                    operation_id = excluded.operation_id,
                    entity_type = excluded.entity_type,
                    entity_id = excluded.entity_id,
                    event_id = excluded.event_id,
                    thing_id = excluded.thing_id,
                    projection_destination = excluded.projection_destination,
                    event_state = excluded.event_state,
                    event_time_epoch = excluded.event_time_epoch,
                    observed_time_epoch = excluded.observed_time_epoch,
                    occurred_at_epoch = excluded.occurred_at_epoch,
                    is_top_level_message = excluded.is_top_level_message
                WHERE excluded.received_at >= messages.received_at;
                """
            try db.execute(sql: sql)
        } else {
            try db.execute(sql: baseInsertSQL + " ON CONFLICT(message_id) DO NOTHING;")
        }
    }

    private func loadMessageRecord(where condition: String, db: Database) throws -> GRDBMessageRecord? {
        let sql = "SELECT * FROM messages WHERE \(condition) ORDER BY received_at DESC, id DESC LIMIT 1;"
        return try Row.fetchOne(db, sql: sql).map(GRDBMessageRecord.init(row:))
    }

    private func loadMessageRecordByMessageId(_ messageId: String, db: Database) throws -> GRDBMessageRecord? {
        let trimmed = messageId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return try loadMessageRecord(where: "message_id = \(Self.sqlQuoted(trimmed))", db: db)
    }

    private func loadMessageRecordByNotificationRequestId(
        _ notificationRequestId: String,
        db: Database
    ) throws -> GRDBMessageRecord? {
        let trimmed = notificationRequestId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return try loadMessageRecord(where: "notification_request_id = \(Self.sqlQuoted(trimmed))", db: db)
    }

    private func loadMessageRecordByUUID(_ id: UUID, db: Database) throws -> GRDBMessageRecord? {
        try loadMessageRecord(where: "id = \(Self.sqlQuoted(id.uuidString))", db: db)
    }

    private func resolveEntityOpenTarget(
        entityType: String,
        entityId: String?,
        thingId: String?
    ) -> EntityOpenTarget? {
        let type = entityType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let id = entityId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if (type == "event" || type == "thing"), !id.isEmpty {
            return EntityOpenTarget(entityType: type, entityId: id)
        }
        if let normalizedThingId = normalizeEntityReference(thingId) {
            return EntityOpenTarget(entityType: "thing", entityId: normalizedThingId)
        }
        return nil
    }

    private func baseMessageConditions(
        includeTopLevelOnly: Bool,
        filter: MessageQueryFilter,
        channel: String?,
        tag: String?,
        cursor: MessagePageCursor?,
        sortMode: MessageListSortMode
    ) -> [String] {
        var conditions: [String] = []
        if includeTopLevelOnly {
            conditions.append("is_top_level_message = 1")
        }

        switch filter {
        case .all:
            break
        case .unreadOnly:
            conditions.append("is_read = 0")
        case .readOnly:
            conditions.append("is_read = 1")
        case .withURLOnly:
            conditions.append("url IS NOT NULL AND trim(url) <> ''")
        case let .byServer(messageId):
            let trimmed = messageId.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                conditions.append("0")
            } else {
                conditions.append("message_id = \(Self.sqlQuoted(trimmed))")
            }
        }

        if let channel {
            conditions.append(Self.channelMatchCondition(value: channel))
        }

        if let cursor {
            conditions.append(messageCursorCondition(cursor, sortMode: sortMode))
        }

        return conditions
    }

    private func messageCursorCondition(
        _ cursor: MessagePageCursor,
        sortMode: MessageListSortMode
    ) -> String {
        switch sortMode {
        case .timeDescending:
            return "(received_at < \(Self.storedEpoch(cursor.receivedAt)) OR (received_at = \(Self.storedEpoch(cursor.receivedAt)) AND id < \(Self.sqlQuoted(cursor.id.uuidString))))"
        case .unreadFirst:
            let readFlag = cursor.isRead ? 1 : 0
            return "(is_read > \(readFlag) OR (is_read = \(readFlag) AND (received_at < \(Self.storedEpoch(cursor.receivedAt)) OR (received_at = \(Self.storedEpoch(cursor.receivedAt)) AND id < \(Self.sqlQuoted(cursor.id.uuidString)))))"
        }
    }

    private func messageOrderBy(sortMode: MessageListSortMode) -> String {
        switch sortMode {
        case .timeDescending:
            return "received_at DESC, id DESC"
        case .unreadFirst:
            return "is_read ASC, received_at DESC, id DESC"
        }
    }

    private func messageAppearsAfterCursor(
        _ message: PushMessage,
        cursor: MessagePageCursor,
        sortMode: MessageListSortMode
    ) -> Bool {
        switch sortMode {
        case .timeDescending:
            if message.receivedAt != cursor.receivedAt {
                return message.receivedAt < cursor.receivedAt
            }
            return message.id.uuidString < cursor.id.uuidString
        case .unreadFirst:
            let messageReadFlag = message.isRead ? 1 : 0
            let cursorReadFlag = cursor.isRead ? 1 : 0
            if messageReadFlag != cursorReadFlag {
                return messageReadFlag > cursorReadFlag
            }
            if message.receivedAt != cursor.receivedAt {
                return message.receivedAt < cursor.receivedAt
            }
            return message.id.uuidString < cursor.id.uuidString
        }
    }

    private func fetchMessageRecords(
        db: Database,
        where conditions: [String],
        orderBy: String,
        limit: Int?
    ) throws -> [GRDBMessageRecord] {
        let whereClause = conditions.isEmpty ? "1" : conditions.joined(separator: " AND ")
        let limitClause: String
        if let limit {
            limitClause = " LIMIT \(max(0, limit))"
        } else {
            limitClause = ""
        }
        let sql = "SELECT * FROM messages WHERE \(whereClause) ORDER BY \(orderBy)\(limitClause);"
        return try Row.fetchAll(db, sql: sql).map(GRDBMessageRecord.init(row:))
    }

    private func fetchMessages(
        db: Database,
        where conditions: [String],
        orderBy: String,
        limit: Int?
    ) throws -> [PushMessage] {
        try fetchMessageRecords(db: db, where: conditions, orderBy: orderBy, limit: limit)
            .map { $0.toPushMessage(decoder: decoder) }
    }

    private func loadMessages(
        filter: MessageQueryFilter,
        channel: String?,
        tag: String?,
        before cursor: MessagePageCursor?,
        limit: Int?,
        sortMode: MessageListSortMode
    ) throws -> [PushMessage] {
        try read { db in
            let normalizedTag = normalizedTagValue(tag)
            let conditions = baseMessageConditions(
                includeTopLevelOnly: true,
                filter: filter,
                channel: channel,
                tag: nil,
                cursor: cursor,
                sortMode: sortMode
            )
            let sqlLimit = normalizedTag == nil ? limit : nil
            let messages = try fetchMessages(
                db: db,
                where: conditions,
                orderBy: messageOrderBy(sortMode: sortMode),
                limit: sqlLimit
            )
            guard let normalizedTag else { return messages }
            let filtered = messages.filter { $0.tags.contains(normalizedTag) }
            guard let limit else { return filtered }
            return Array(filtered.prefix(max(0, limit)))
        }
    }

    private func loadEntityProjectionMessages(
        entityConditions: [String],
        cursor: EntityProjectionPageCursor?,
        limit: Int?
    ) throws -> [PushMessage] {
        try read { db in
            var conditions = entityConditions
            if let cursor {
                conditions.append(
                    "(received_at < \(Self.storedEpoch(cursor.receivedAt)) OR (received_at = \(Self.storedEpoch(cursor.receivedAt)) AND id < \(Self.sqlQuoted(cursor.id.uuidString))))"
                )
            }
            return try fetchMessages(
                db: db,
                where: conditions,
                orderBy: "COALESCE(occurred_at_epoch, event_time_epoch, observed_time_epoch, CAST(received_at AS INTEGER)) DESC, received_at DESC, id DESC",
                limit: limit
            )
        }
    }

    private func matchesSearchQuery(
        _ message: PushMessage,
        parsedQuery: SearchQuerySemantics.ParsedQuery
    ) -> Bool {
        if !parsedQuery.tags.isEmpty {
            let normalizedMessageTags = Set(message.tags.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
            for tag in parsedQuery.tags where !normalizedMessageTags.contains(tag) {
                return false
            }
        }

        guard !parsedQuery.textTokens.isEmpty else { return true }
        let candidates = [
            message.messageId,
            message.title,
            message.body,
            message.channel,
            message.eventId,
            message.thingId,
            message.tags.joined(separator: " "),
        ]
            .compactMap { $0?.lowercased() }

        for token in parsedQuery.textTokens.map({ $0.lowercased() }) {
            var matched = false
            for candidate in candidates where candidate.contains(token) {
                matched = true
                break
            }
            if !matched {
                return false
            }
        }
        return true
    }

    private func unreadPredicateCondition(
        filter: MessageQueryFilter,
        channel: String?
    ) -> String {
        let channelCondition = Self.channelMatchCondition(value: channel)

        switch filter {
        case .all, .unreadOnly:
            return "is_read = 0 AND \(channelCondition)"
        case .readOnly:
            return "0"
        case .withURLOnly:
            return "is_read = 0 AND url IS NOT NULL AND trim(url) <> '' AND \(channelCondition)"
        case let .byServer(messageId):
            let trimmed = messageId.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                return "0"
            }
            return "is_read = 0 AND message_id = \(Self.sqlQuoted(trimmed)) AND \(channelCondition)"
        }
    }

    private func fetchOperationLedger(
        scopeKey: String,
        db: Database
    ) throws -> GRDBOperationLedgerRecord? {
        let sql = "SELECT * FROM operation_ledger WHERE scope_key = \(Self.sqlQuoted(scopeKey)) LIMIT 1;"
        return try Row.fetchOne(db, sql: sql).map(GRDBOperationLedgerRecord.init(row:))
    }

    private func upsertOperationLedger(
        identity: OperationScopeIdentity,
        messageId: String,
        appliedAt: Date,
        db: Database
    ) throws {
        let sql = """
            INSERT INTO operation_ledger (
                scope_key, message_id, op_id, channel_id, entity_type, entity_id, delivery_id, applied_at
            ) VALUES (
                \(Self.sqlQuoted(identity.scopeKey)),
                \(Self.sqlQuoted(messageId)),
                \(Self.sqlQuoted(identity.opId)),
                \(Self.sqlOptionalText(identity.channelId)),
                \(Self.sqlQuoted(identity.entityType)),
                \(Self.sqlQuoted(identity.entityId)),
                \(Self.sqlOptionalText(identity.deliveryId)),
                \(Self.storedEpoch(appliedAt))
            )
            ON CONFLICT(scope_key) DO UPDATE SET
                message_id = excluded.message_id,
                op_id = excluded.op_id,
                channel_id = excluded.channel_id,
                entity_type = excluded.entity_type,
                entity_id = excluded.entity_id,
                delivery_id = excluded.delivery_id,
                applied_at = excluded.applied_at;
            """
        try db.execute(sql: sql)
    }

    func loadChannelSubscriptions(includeDeleted: Bool) async throws -> [ChannelSubscription] {
        try read { db in
            let whereClause = includeDeleted ? "1" : "is_deleted = 0"
            let sql = """
                SELECT gateway, channel_id, display_name, updated_at, last_synced_at
                FROM channel_subscriptions
                WHERE \(whereClause)
                ORDER BY channel_id ASC, gateway ASC;
                """
            return try Row.fetchAll(db, sql: sql).map { row in
                let gateway: String = row["gateway"]
                let channelId: String = row["channel_id"]
                let displayName: String = row["display_name"]
                let updatedAtEpoch: Double = row["updated_at"]
                let lastSyncedAtEpoch: Double? = row["last_synced_at"]
                return ChannelSubscription(
                    gateway: gateway,
                    channelId: channelId,
                    displayName: displayName,
                    updatedAt: GRDBStore.dateFromStoredEpoch(updatedAtEpoch),
                    lastSyncedAt: lastSyncedAtEpoch.map(GRDBStore.dateFromStoredEpoch)
                )
            }
        }
    }

    func upsertChannelSubscription(
        gateway: String,
        channelId: String,
        displayName: String,
        password: String?,
        lastSyncedAt: Date?,
        updatedAt: Date,
        isDeleted: Bool,
        deletedAt: Date?
    ) async throws {
        let normalizedGateway = Self.normalizeGateway(gateway)
        let normalizedChannelId = channelId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedGateway.isEmpty, !normalizedChannelId.isEmpty else {
            throw localStoreError("Invalid gateway/channel_id for channel subscription upsert.")
        }

        let normalizedDisplayName: String = {
            let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? normalizedChannelId : trimmed
        }()
        let normalizedPassword = (password ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        try write { db in
            let sql = """
                INSERT INTO channel_subscriptions (
                    gateway, channel_id, display_name, password, last_synced_at, updated_at, is_deleted, deleted_at
                ) VALUES (
                    \(Self.sqlQuoted(normalizedGateway)),
                    \(Self.sqlQuoted(normalizedChannelId)),
                    \(Self.sqlQuoted(normalizedDisplayName)),
                    \(Self.sqlQuoted(normalizedPassword)),
                    \(Self.sqlOptionalDouble(lastSyncedAt.map(Self.storedEpoch))),
                    \(Self.storedEpoch(updatedAt)),
                    \(isDeleted ? 1 : 0),
                    \(Self.sqlOptionalDouble(deletedAt.map(Self.storedEpoch)))
                )
                ON CONFLICT(gateway, channel_id) DO UPDATE SET
                    display_name = excluded.display_name,
                    password = excluded.password,
                    last_synced_at = excluded.last_synced_at,
                    updated_at = excluded.updated_at,
                    is_deleted = excluded.is_deleted,
                    deleted_at = excluded.deleted_at;
                """
            try db.execute(sql: sql)
        }
    }

    func softDeleteChannelSubscription(
        gateway: String,
        channelId: String,
        deletedAt: Date
    ) async throws {
        let normalizedGateway = Self.normalizeGateway(gateway)
        let normalizedChannelId = channelId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedGateway.isEmpty, !normalizedChannelId.isEmpty else { return }

        try write { db in
            let sql = """
                UPDATE channel_subscriptions
                SET is_deleted = 1,
                    deleted_at = \(Self.storedEpoch(deletedAt)),
                    password = '',
                    updated_at = \(Self.storedEpoch(deletedAt))
                WHERE gateway = \(Self.sqlQuoted(normalizedGateway))
                  AND channel_id = \(Self.sqlQuoted(normalizedChannelId));
                """
            try db.execute(sql: sql)
        }
    }

    func softDeleteChannelSubscription(
        channelId: String,
        deletedAt: Date
    ) async throws {
        let normalizedChannelId = channelId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedChannelId.isEmpty else { return }

        try write { db in
            let sql = """
                UPDATE channel_subscriptions
                SET is_deleted = 1,
                    deleted_at = \(Self.storedEpoch(deletedAt)),
                    password = '',
                    updated_at = \(Self.storedEpoch(deletedAt))
                WHERE channel_id = \(Self.sqlQuoted(normalizedChannelId));
                """
            try db.execute(sql: sql)
        }
    }

    func loadAppSettings() async throws -> AppSettingsSnapshot? {
        try read { db in
            try loadAppSettings(db)
        }
    }

    func saveAppSettings(_ snapshot: AppSettingsSnapshot) async throws {
        try write { db in
            try saveAppSettings(snapshot, db: db)
        }
    }

    func loadWatchProvisioningServerConfig() async throws -> ServerConfig? {
        try read { db in
            try decodeWatchProvisioningServerConfig(from: try loadAppSettings(db))
        }
    }

    func saveWatchProvisioningServerConfig(_ config: ServerConfig?) async throws {
        let normalized = config?.normalized()
        try write { db in
            var settings = try loadAppSettings(db) ?? .empty
            settings.watchProvisioningServerConfigData = try encodeWatchProvisioningServerConfig(normalized)
            try saveAppSettings(settings, db: db)
        }
    }

    func loadWatchProvisioningState() async throws -> WatchProvisioningState? {
        try read { db in
            let settings = try loadAppSettings(db)
            guard let schemaVersion = settings?.watchProvisioningSchemaVersion,
                  let generation = settings?.watchProvisioningGeneration,
                  let contentDigest = settings?.watchProvisioningContentDigest,
                  let appliedAt = settings?.watchProvisioningAppliedAt,
                  let modeRawValue = settings?.watchProvisioningModeRawValue,
                  let modeAtApply = WatchMode(rawValue: modeRawValue)
            else {
                return nil
            }
            return WatchProvisioningState(
                schemaVersion: schemaVersion,
                generation: generation,
                contentDigest: contentDigest,
                appliedAt: appliedAt,
                modeAtApply: modeAtApply,
                sourceControlGeneration: settings?.watchProvisioningSourceControlGeneration ?? 0
            )
        }
    }

    func saveWatchProvisioningState(_ state: WatchProvisioningState?) async throws {
        try write { db in
            var settings = try loadAppSettings(db) ?? .empty
            settings.watchProvisioningSchemaVersion = state?.schemaVersion
            settings.watchProvisioningGeneration = state?.generation
            settings.watchProvisioningContentDigest = state?.contentDigest
            settings.watchProvisioningAppliedAt = state?.appliedAt
            settings.watchProvisioningModeRawValue = state?.modeAtApply.rawValue
            settings.watchProvisioningSourceControlGeneration = state?.sourceControlGeneration
            try saveAppSettings(settings, db: db)
        }
    }

    func applyWatchStandaloneProvisioning(
        _ snapshot: WatchStandaloneProvisioningSnapshot,
        sourceControlGeneration: Int64
    ) async throws -> WatchProvisioningState {
        let normalizedConfig = snapshot.serverConfig?.normalized()
        let normalizedChannels = snapshot.channels.map {
            (
                gateway: Self.normalizeGateway($0.gateway),
                channelId: $0.channelId.trimmingCharacters(in: .whitespacesAndNewlines),
                displayName: $0.displayName.trimmingCharacters(in: .whitespacesAndNewlines),
                password: $0.password.trimmingCharacters(in: .whitespacesAndNewlines),
                updatedAt: $0.updatedAt
            )
        }.filter { !$0.gateway.isEmpty && !$0.channelId.isEmpty && !$0.password.isEmpty }
        let provisioningState = WatchProvisioningState(
            schemaVersion: WatchConnectivitySchema.currentVersion,
            generation: snapshot.generation,
            contentDigest: snapshot.contentDigest,
            appliedAt: Date(),
            modeAtApply: .standalone,
            sourceControlGeneration: sourceControlGeneration
        )

        try write { db in
            var settings = try loadAppSettings(db) ?? .empty
            settings.watchProvisioningServerConfigData = try encodeWatchProvisioningServerConfig(normalizedConfig)
            settings.watchProvisioningSchemaVersion = provisioningState.schemaVersion
            settings.watchProvisioningGeneration = provisioningState.generation
            settings.watchProvisioningContentDigest = provisioningState.contentDigest
            settings.watchProvisioningAppliedAt = provisioningState.appliedAt
            settings.watchProvisioningModeRawValue = provisioningState.modeAtApply.rawValue
            settings.watchProvisioningSourceControlGeneration = provisioningState.sourceControlGeneration
            try saveAppSettings(settings, db: db)

            let existingRows = try Row.fetchAll(
                db,
                sql: "SELECT gateway, channel_id FROM channel_subscriptions WHERE is_deleted = 0;"
            )
            let existingKeys = existingRows.compactMap { row -> String? in
                let gateway: String? = row["gateway"]
                let channelId: String? = row["channel_id"]
                guard let gateway, let channelId else { return nil }
                return "\(Self.normalizeGateway(gateway))|\(channelId.trimmingCharacters(in: .whitespacesAndNewlines))"
            }
            let incomingKeys = Set(normalizedChannels.map { "\($0.gateway)|\($0.channelId)" })

            for channel in normalizedChannels {
                let displayName = channel.displayName.isEmpty ? channel.channelId : channel.displayName
                let sql = """
                    INSERT INTO channel_subscriptions (
                        gateway, channel_id, display_name, password, last_synced_at, updated_at, is_deleted, deleted_at
                    ) VALUES (
                        \(Self.sqlQuoted(channel.gateway)),
                        \(Self.sqlQuoted(channel.channelId)),
                        \(Self.sqlQuoted(displayName)),
                        \(Self.sqlQuoted(channel.password)),
                        NULL,
                        \(Self.storedEpoch(channel.updatedAt)),
                        0,
                        NULL
                    )
                    ON CONFLICT(gateway, channel_id) DO UPDATE SET
                        display_name = excluded.display_name,
                        password = excluded.password,
                        last_synced_at = excluded.last_synced_at,
                        updated_at = excluded.updated_at,
                        is_deleted = 0,
                        deleted_at = NULL;
                    """
                try db.execute(sql: sql)
            }

            let deletedAt = provisioningState.appliedAt
            for key in existingKeys where !incomingKeys.contains(key) {
                let parts = key.split(separator: "|", maxSplits: 1).map(String.init)
                guard parts.count == 2 else { continue }
                let sql = """
                    UPDATE channel_subscriptions
                    SET is_deleted = 1,
                        deleted_at = \(Self.storedEpoch(deletedAt)),
                        password = '',
                        updated_at = \(Self.storedEpoch(deletedAt))
                    WHERE gateway = \(Self.sqlQuoted(parts[0]))
                      AND channel_id = \(Self.sqlQuoted(parts[1]));
                    """
                try db.execute(sql: sql)
            }
        }

        return provisioningState
    }

    func updateChannelDisplayName(
        gateway: String,
        channelId: String,
        displayName: String
    ) async throws {
        let normalizedGateway = Self.normalizeGateway(gateway)
        let normalizedChannelId = channelId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedGateway.isEmpty, !normalizedChannelId.isEmpty else { return }
        let normalizedDisplayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedDisplayName = normalizedDisplayName.isEmpty ? normalizedChannelId : normalizedDisplayName
        try write { db in
            let sql = """
                UPDATE channel_subscriptions
                SET display_name = \(Self.sqlQuoted(resolvedDisplayName)),
                    updated_at = \(Self.storedEpoch(Date())),
                    is_deleted = 0,
                    deleted_at = NULL
                WHERE gateway = \(Self.sqlQuoted(normalizedGateway))
                  AND channel_id = \(Self.sqlQuoted(normalizedChannelId));
                """
            try db.execute(sql: sql)
        }
    }

    func updateChannelLastSynced(
        gateway: String,
        channelId: String,
        date: Date
    ) async throws {
        let normalizedGateway = Self.normalizeGateway(gateway)
        let normalizedChannelId = channelId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedGateway.isEmpty, !normalizedChannelId.isEmpty else { return }
        try write { db in
            let sql = """
                UPDATE channel_subscriptions
                SET last_synced_at = \(Self.storedEpoch(date))
                WHERE gateway = \(Self.sqlQuoted(normalizedGateway))
                  AND channel_id = \(Self.sqlQuoted(normalizedChannelId));
                """
            try db.execute(sql: sql)
        }
    }

    func loadChannelCredentials(
        gateway: String
    ) async throws -> [(channelId: String, password: String)] {
        let normalizedGateway = Self.normalizeGateway(gateway)
        guard !normalizedGateway.isEmpty else { return [] }
        return try read { db in
            let sql = """
                SELECT channel_id, password
                FROM channel_subscriptions
                WHERE gateway = \(Self.sqlQuoted(normalizedGateway))
                  AND is_deleted = 0
                ORDER BY updated_at DESC, channel_id ASC;
                """
            return try Row.fetchAll(db, sql: sql).compactMap { row in
                let channelId: String = row["channel_id"]
                let password: String = row["password"]
                let trimmedChannelId = channelId.trimmingCharacters(in: .whitespacesAndNewlines)
                let trimmedPassword = password.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmedChannelId.isEmpty, !trimmedPassword.isEmpty else { return nil }
                return (channelId: trimmedChannelId, password: trimmedPassword)
            }
        }
    }

    func mergeWatchMirrorSnapshot(_ snapshot: WatchMirrorSnapshot) async throws {
        try write { db in
            for message in snapshot.messages {
                try upsertWatchLightMessage(message, db: db)
            }
            for event in snapshot.events {
                try upsertWatchLightEvent(event, db: db)
            }
            for thing in snapshot.things {
                try upsertWatchLightThing(thing, db: db)
            }
        }
    }

    func clearWatchLightStore() async throws {
        try write { db in
            try db.execute(sql: "DELETE FROM watch_light_messages;")
            try db.execute(sql: "DELETE FROM watch_light_events;")
            try db.execute(sql: "DELETE FROM watch_light_things;")
            try db.execute(sql: "DELETE FROM watch_mirror_action_queue;")
        }
    }

    func loadWatchLightMessages() async throws -> [WatchLightMessage] {
        try read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT * FROM watch_light_messages
                    ORDER BY received_at DESC, message_id DESC;
                    """
            )
            return rows.map { GRDBWatchLightMessageRecord(row: $0).toModel() }
        }
    }

    func loadWatchLightMessage(messageId: String) async throws -> WatchLightMessage? {
        let normalizedMessageId = messageId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedMessageId.isEmpty else { return nil }
        return try read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT * FROM watch_light_messages
                    WHERE message_id = \(Self.sqlQuoted(normalizedMessageId))
                    LIMIT 1;
                    """
            ) else {
                return nil
            }
            return GRDBWatchLightMessageRecord(row: row).toModel()
        }
    }

    func loadWatchLightMessage(notificationRequestId: String) async throws -> WatchLightMessage? {
        let normalizedRequestId = notificationRequestId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedRequestId.isEmpty else { return nil }
        return try read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT * FROM watch_light_messages
                    WHERE notification_request_id = \(Self.sqlQuoted(normalizedRequestId))
                    ORDER BY received_at DESC, message_id DESC
                    LIMIT 1;
                    """
            ) else {
                return nil
            }
            return GRDBWatchLightMessageRecord(row: row).toModel()
        }
    }

    func loadWatchLightEvents() async throws -> [WatchLightEvent] {
        try read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT * FROM watch_light_events
                    ORDER BY updated_at DESC, event_id DESC;
                    """
            )
            return rows.map { GRDBWatchLightEventRecord(row: $0).toModel() }
        }
    }

    func loadWatchLightEvent(eventId: String) async throws -> WatchLightEvent? {
        let normalizedEventId = eventId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedEventId.isEmpty else { return nil }
        return try read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT * FROM watch_light_events
                    WHERE event_id = \(Self.sqlQuoted(normalizedEventId))
                    LIMIT 1;
                    """
            ) else {
                return nil
            }
            return GRDBWatchLightEventRecord(row: row).toModel()
        }
    }

    func loadWatchLightThings() async throws -> [WatchLightThing] {
        try read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT * FROM watch_light_things
                    ORDER BY updated_at DESC, thing_id DESC;
                    """
            )
            return rows.map { GRDBWatchLightThingRecord(row: $0).toModel() }
        }
    }

    func loadWatchLightThing(thingId: String) async throws -> WatchLightThing? {
        let normalizedThingId = thingId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedThingId.isEmpty else { return nil }
        return try read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT * FROM watch_light_things
                    WHERE thing_id = \(Self.sqlQuoted(normalizedThingId))
                    LIMIT 1;
                    """
            ) else {
                return nil
            }
            return GRDBWatchLightThingRecord(row: row).toModel()
        }
    }

    func upsertWatchLightPayload(_ payload: WatchLightPayload) async throws {
        try write { db in
            switch payload {
            case let .message(message):
                try upsertWatchLightMessage(message, db: db)
            case let .event(event):
                try upsertWatchLightEvent(event, db: db)
            case let .thing(thing):
                try upsertWatchLightThing(thing, db: db)
            }
        }
    }

    func markWatchLightMessageRead(messageId: String) async throws -> WatchLightMessage? {
        let normalizedMessageId = messageId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedMessageId.isEmpty else { return nil }
        return try write { db in
            try db.execute(
                sql: """
                    UPDATE watch_light_messages
                    SET is_read = 1
                    WHERE message_id = \(Self.sqlQuoted(normalizedMessageId));
                    """
            )
            guard let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT * FROM watch_light_messages
                    WHERE message_id = \(Self.sqlQuoted(normalizedMessageId))
                    LIMIT 1;
                    """
            ) else {
                return nil
            }
            return GRDBWatchLightMessageRecord(row: row).toModel()
        }
    }

    func deleteWatchLightMessage(messageId: String) async throws {
        let normalizedMessageId = messageId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedMessageId.isEmpty else { return }
        try write { db in
            try db.execute(
                sql: """
                    DELETE FROM watch_light_messages
                    WHERE message_id = \(Self.sqlQuoted(normalizedMessageId));
                    """
            )
        }
    }

    func enqueueWatchMirrorAction(_ action: WatchMirrorAction) async throws {
        try write { db in
            try db.execute(
                sql: """
                    INSERT INTO watch_mirror_action_queue (action_id, kind, message_id, issued_at)
                    VALUES (
                        \(Self.sqlQuoted(action.actionId)),
                        \(Self.sqlQuoted(action.kind.rawValue)),
                        \(Self.sqlQuoted(action.messageId)),
                        \(Self.storedEpoch(action.issuedAt))
                    )
                    ON CONFLICT(action_id) DO UPDATE SET
                        kind = excluded.kind,
                        message_id = excluded.message_id,
                        issued_at = excluded.issued_at;
                    """
            )
        }
    }

    func loadWatchMirrorActions() async throws -> [WatchMirrorAction] {
        try read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT * FROM watch_mirror_action_queue
                    ORDER BY issued_at ASC, action_id ASC;
                    """
            )
            return rows.compactMap { GRDBWatchMirrorActionRecord(row: $0).toModel() }
        }
    }

    func deleteWatchMirrorActions(actionIds: [String]) async throws {
        let normalized = actionIds
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !normalized.isEmpty else { return }
        let quoted = normalized.map(Self.sqlQuoted).joined(separator: ", ")
        try write { db in
            try db.execute(
                sql: """
                    DELETE FROM watch_mirror_action_queue
                    WHERE action_id IN (\(quoted));
                    """
            )
        }
    }

    private func upsertWatchLightMessage(_ message: WatchLightMessage, db: Database) throws {
        try db.execute(
            sql: """
                INSERT INTO watch_light_messages (
                    message_id, title, body, image_url, url, severity, received_at,
                    is_read, entity_type, entity_id, notification_request_id
                ) VALUES (
                    \(Self.sqlQuoted(message.messageId)),
                    \(Self.sqlQuoted(message.title)),
                    \(Self.sqlQuoted(message.body)),
                    \(Self.sqlOptionalText(message.imageURL?.absoluteString)),
                    \(Self.sqlOptionalText(message.url?.absoluteString)),
                    \(Self.sqlOptionalText(message.severity)),
                    \(Self.storedEpoch(message.receivedAt)),
                    \(message.isRead ? 1 : 0),
                    \(Self.sqlQuoted(message.entityType)),
                    \(Self.sqlOptionalText(message.entityId)),
                    \(Self.sqlOptionalText(message.notificationRequestId))
                )
                ON CONFLICT(message_id) DO UPDATE SET
                    title = excluded.title,
                    body = excluded.body,
                    image_url = excluded.image_url,
                    url = excluded.url,
                    severity = excluded.severity,
                    received_at = excluded.received_at,
                    is_read = excluded.is_read,
                    entity_type = excluded.entity_type,
                    entity_id = excluded.entity_id,
                    notification_request_id = excluded.notification_request_id;
                """
        )
    }

    private func upsertWatchLightEvent(_ event: WatchLightEvent, db: Database) throws {
        try db.execute(
            sql: """
                INSERT INTO watch_light_events (
                    event_id, title, summary, state, severity, decryption_state, image_url, updated_at
                ) VALUES (
                    \(Self.sqlQuoted(event.eventId)),
                    \(Self.sqlQuoted(event.title)),
                    \(Self.sqlOptionalText(event.summary)),
                    \(Self.sqlOptionalText(event.state)),
                    \(Self.sqlOptionalText(event.severity)),
                    \(Self.sqlOptionalText(event.decryptionState)),
                    \(Self.sqlOptionalText(event.imageURL?.absoluteString)),
                    \(Self.storedEpoch(event.updatedAt))
                )
                ON CONFLICT(event_id) DO UPDATE SET
                    title = excluded.title,
                    summary = excluded.summary,
                    state = excluded.state,
                    severity = excluded.severity,
                    decryption_state = excluded.decryption_state,
                    image_url = excluded.image_url,
                    updated_at = excluded.updated_at;
                """
        )
    }

    private func upsertWatchLightThing(_ thing: WatchLightThing, db: Database) throws {
        try db.execute(
            sql: """
                INSERT INTO watch_light_things (
                    thing_id, title, summary, attrs_json, decryption_state, image_url, updated_at
                ) VALUES (
                    \(Self.sqlQuoted(thing.thingId)),
                    \(Self.sqlQuoted(thing.title)),
                    \(Self.sqlOptionalText(thing.summary)),
                    \(Self.sqlOptionalText(thing.attrsJSON)),
                    \(Self.sqlOptionalText(thing.decryptionState)),
                    \(Self.sqlOptionalText(thing.imageURL?.absoluteString)),
                    \(Self.storedEpoch(thing.updatedAt))
                )
                ON CONFLICT(thing_id) DO UPDATE SET
                    title = excluded.title,
                    summary = excluded.summary,
                    attrs_json = excluded.attrs_json,
                    decryption_state = excluded.decryption_state,
                    image_url = excluded.image_url,
                    updated_at = excluded.updated_at;
                """
        )
    }

    func persistNotificationMessageIfNeeded(
        _ message: PushMessage
    ) async throws -> NotificationStoreSaveOutcome {
        try write { db in
            let canonicalMessage = canonicalizedMessageForPersistence(message)
            let record = try buildMessageRecord(from: canonicalMessage)
            if let thingId = referencedThingIdRequiringExistingParent(canonicalMessage),
               try !hasThingParentRecord(thingId: thingId, db: db)
            {
                try enqueuePendingInboundMessage(record, thingId: thingId, db: db)
                return .persistedPending(canonicalMessage)
            }

            if let notificationRequestId = record.notificationRequestId,
               let existing = try loadMessageRecordByNotificationRequestId(notificationRequestId, db: db)
            {
                var updatedRecord = record
                updatedRecord = GRDBMessageRecord(
                    id: existing.id,
                    messageId: existing.messageId,
                    title: record.title,
                    body: record.body,
                    channel: record.channel,
                    url: record.url,
                    isRead: record.isRead,
                    receivedAt: record.receivedAt,
                    rawPayloadJSON: record.rawPayloadJSON,
                    status: record.status,
                    decryptionState: record.decryptionState,
                    notificationRequestId: existing.notificationRequestId,
                    deliveryId: record.deliveryId,
                    operationId: record.operationId,
                    entityType: record.entityType,
                    entityId: record.entityId,
                    eventId: record.eventId,
                    thingId: record.thingId,
                    projectionDestination: record.projectionDestination,
                    eventState: record.eventState,
                    eventTimeEpoch: record.eventTimeEpoch,
                    observedTimeEpoch: record.observedTimeEpoch,
                    occurredAtEpoch: record.occurredAtEpoch,
                    topLevelMessage: record.topLevelMessage
                )
                try insertOrUpdateMessage(updatedRecord, db: db, updateOnConflict: true)
                return .duplicateRequest(updatedRecord.toPushMessage(decoder: decoder))
            }

            if let identity = resolveOperationScopeIdentity(from: canonicalMessage),
               let ledger = try fetchOperationLedger(scopeKey: identity.scopeKey, db: db),
               let existing = try loadMessageRecordByMessageId(ledger.messageId, db: db)
            {
                return .duplicateMessage(existing.toPushMessage(decoder: decoder))
            }

            if let existing = try loadMessageRecordByMessageId(record.messageId, db: db) {
                return .duplicateMessage(existing.toPushMessage(decoder: decoder))
            }

            try insertOrUpdateMessage(record, db: db, updateOnConflict: false)
            if let identity = resolveOperationScopeIdentity(from: canonicalMessage) {
                try upsertOperationLedger(
                    identity: identity,
                    messageId: record.messageId,
                    appliedAt: Date(),
                    db: db
                )
            }
            if let thingId = thingParentIdentity(from: canonicalMessage) {
                try replayPendingInboundMessages(thingId: thingId, db: db)
            }
            return .persisted(record.toPushMessage(decoder: decoder))
        }
    }

    func saveEntityRecords(_ messages: [PushMessage]) async throws {
        guard !messages.isEmpty else { return }
        try write { db in
            for message in messages {
                let canonical = canonicalizedMessageForPersistence(message)
                guard isEntityScopedWrite(canonical) else { continue }
                let record = try buildMessageRecord(from: canonical)
                if let thingId = referencedThingIdRequiringExistingParent(canonical),
                   try !hasThingParentRecord(thingId: thingId, db: db)
                {
                    try enqueuePendingInboundMessage(record, thingId: thingId, db: db)
                    continue
                }

                if try loadMessageRecordByMessageId(record.messageId, db: db) != nil {
                    continue
                }

                if let identity = resolveOperationScopeIdentity(from: canonical),
                   try fetchOperationLedger(scopeKey: identity.scopeKey, db: db) != nil
                {
                    continue
                }

                try insertOrUpdateMessage(record, db: db, updateOnConflict: false)
                if let identity = resolveOperationScopeIdentity(from: canonical) {
                    try upsertOperationLedger(
                        identity: identity,
                        messageId: record.messageId,
                        appliedAt: Date(),
                        db: db
                    )
                }
                if let thingId = thingParentIdentity(from: canonical) {
                    try replayPendingInboundMessages(thingId: thingId, db: db)
                }
            }
        }
    }

    func saveMessages(_ messages: [PushMessage]) async throws -> [PushMessage] {
        guard !messages.isEmpty else { return [] }
        var storedMessages: [PushMessage] = []
        storedMessages.reserveCapacity(messages.count)
        try write { db in
            for message in messages {
                let canonical = canonicalizedMessageForPersistence(message)
                let record = try buildMessageRecord(from: canonical)
                if let thingId = referencedThingIdRequiringExistingParent(canonical),
                   try !hasThingParentRecord(thingId: thingId, db: db)
                {
                    try enqueuePendingInboundMessage(record, thingId: thingId, db: db)
                    continue
                }
                let existing = try loadMessageRecordByMessageId(record.messageId, db: db)
                if let existing, record.receivedAt < existing.receivedAt {
                    continue
                }
                try insertOrUpdateMessage(record, db: db, updateOnConflict: true)
                if let existing {
                    storedMessages.append(record.withID(existing.id).toPushMessage(decoder: decoder))
                } else {
                    storedMessages.append(canonical)
                }
                if let thingId = thingParentIdentity(from: canonical) {
                    try replayPendingInboundMessages(thingId: thingId, db: db)
                }
            }
        }
        return storedMessages
    }

    func loadMessages() async throws -> [PushMessage] {
        try loadMessages(
            filter: .all,
            channel: nil,
            tag: nil,
            before: nil,
            limit: nil,
            sortMode: .timeDescending
        )
    }

    func loadMessages(
        filter: MessageQueryFilter,
        channel: String?,
        tag: String?
    ) async throws -> [PushMessage] {
        try loadMessages(
            filter: filter,
            channel: channel,
            tag: tag,
            before: nil,
            limit: nil,
            sortMode: .timeDescending
        )
    }

    func loadMessagesPage(
        before cursor: MessagePageCursor?,
        limit: Int,
        filter: MessageQueryFilter,
        channel: String?,
        tag: String?,
        sortMode: MessageListSortMode
    ) async throws -> [PushMessage] {
        guard limit > 0 else { return [] }
        return try loadMessages(
            filter: filter,
            channel: channel,
            tag: tag,
            before: cursor,
            limit: limit,
            sortMode: sortMode
        )
    }

    func loadMessageSummariesPage(
        before cursor: MessagePageCursor?,
        limit: Int,
        filter: MessageQueryFilter,
        channel: String?,
        tag: String?,
        sortMode: MessageListSortMode
    ) async throws -> [PushMessageSummary] {
        try await loadMessagesPage(
            before: cursor,
            limit: limit,
            filter: filter,
            channel: channel,
            tag: tag,
            sortMode: sortMode
        )
            .map(PushMessageSummary.init(message:))
    }

    func loadMessageSummaries(ids: [UUID]) async throws -> [PushMessageSummary] {
        try await loadMessages(ids: ids).map(PushMessageSummary.init(message:))
    }

    func loadEventMessagesForProjection() async throws -> [PushMessage] {
        try loadEntityProjectionMessages(entityConditions: ["entity_type = 'event'"], cursor: nil, limit: nil)
            .filter(isTopLevelEventProjection)
    }

    func loadEventMessagesForProjection(eventId: String) async throws -> [PushMessage] {
        let normalized = eventId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return [] }
        return try loadEntityProjectionMessages(
            entityConditions: [
                "entity_type = 'event'",
                "event_id = \(Self.sqlQuoted(normalized))",
            ],
            cursor: nil,
            limit: nil
        ).filter { $0.eventId == normalized }
    }

    func loadEventMessagesForProjectionPage(
        before cursor: EntityProjectionPageCursor?,
        limit: Int
    ) async throws -> [PushMessage] {
        guard limit > 0 else { return [] }
        var collected: [PushMessage] = []
        var pageCursor = cursor
        let fetchBatchSize = max(limit * 2, 80)
        while collected.count < limit {
            let batch = try loadEntityProjectionMessages(
                entityConditions: ["entity_type = 'event'"],
                cursor: pageCursor,
                limit: fetchBatchSize
            )
            if batch.isEmpty { break }
            for message in batch where isTopLevelEventProjection(message) {
                collected.append(message)
                if collected.count == limit { break }
            }
            guard let last = batch.last else { break }
            pageCursor = EntityProjectionPageCursor(receivedAt: last.receivedAt, id: last.id)
            if batch.count < fetchBatchSize { break }
        }
        return collected
    }

    func loadThingMessagesForProjection() async throws -> [PushMessage] {
        try loadEntityProjectionMessages(
            entityConditions: ["((thing_id IS NOT NULL AND trim(thing_id) <> '') OR entity_type = 'thing')"],
            cursor: nil,
            limit: nil
        ).filter { $0.thingId != nil }
    }

    func loadThingMessagesForProjection(thingId: String) async throws -> [PushMessage] {
        let normalized = thingId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return [] }
        let raw = try loadEntityProjectionMessages(
            entityConditions: [
                "((thing_id = \(Self.sqlQuoted(normalized))) OR (entity_type = 'thing' AND entity_id = \(Self.sqlQuoted(normalized))))",
            ],
            cursor: nil,
            limit: nil
        )
        return raw.filter { $0.thingId == normalized }
    }

    func loadThingMessagesForProjectionPage(
        before cursor: EntityProjectionPageCursor?,
        limit: Int
    ) async throws -> [PushMessage] {
        guard limit > 0 else { return [] }
        var collected: [PushMessage] = []
        var pageCursor = cursor
        let fetchBatchSize = max(limit * 2, 80)
        while collected.count < limit {
            let batch = try loadEntityProjectionMessages(
                entityConditions: ["((thing_id IS NOT NULL AND trim(thing_id) <> '') OR entity_type = 'thing')"],
                cursor: pageCursor,
                limit: fetchBatchSize
            )
            if batch.isEmpty { break }
            for message in batch where message.thingId != nil {
                collected.append(message)
                if collected.count == limit { break }
            }
            guard let last = batch.last else { break }
            pageCursor = EntityProjectionPageCursor(receivedAt: last.receivedAt, id: last.id)
            if batch.count < fetchBatchSize { break }
        }
        return collected
    }

    func loadMessage(id: UUID) async throws -> PushMessage? {
        try read { db in
            try loadMessageRecordByUUID(id, db: db)?.toPushMessage(decoder: decoder)
        }
    }

    func loadMessages(ids: [UUID]) async throws -> [PushMessage] {
        let uniqueIds = Array(Set(ids))
        guard !uniqueIds.isEmpty else { return [] }
        return try read { db in
            let joined = uniqueIds.map { Self.sqlQuoted($0.uuidString) }.joined(separator: ",")
            let records = try fetchMessageRecords(
                db: db,
                where: ["id IN (\(joined))"],
                orderBy: "received_at DESC, id DESC",
                limit: nil
            )
            return records.map { $0.toPushMessage(decoder: decoder) }
        }
    }

    func loadMessage(messageId: String) async throws -> PushMessage? {
        try read { db in
            try loadMessageRecordByMessageId(messageId, db: db)?.toPushMessage(decoder: decoder)
        }
    }

    func loadMessage(deliveryId: String) async throws -> PushMessage? {
        let trimmed = deliveryId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return try read { db in
            try loadMessageRecord(where: "delivery_id = \(Self.sqlQuoted(trimmed))", db: db)?
                .toPushMessage(decoder: decoder)
        }
    }

    func loadMessage(notificationRequestId: String) async throws -> PushMessage? {
        try read { db in
            try loadMessageRecordByNotificationRequestId(notificationRequestId, db: db)?.toPushMessage(decoder: decoder)
        }
    }

    func loadEntityOpenTarget(notificationRequestId: String) async throws -> EntityOpenTarget? {
        try read { db in
            guard let record = try loadMessageRecordByNotificationRequestId(notificationRequestId, db: db) else {
                return nil
            }
            return resolveEntityOpenTarget(
                entityType: record.entityType,
                entityId: record.entityId,
                thingId: record.thingId
            )
        }
    }

    func loadEntityOpenTarget(messageId: String) async throws -> EntityOpenTarget? {
        try read { db in
            guard let record = try loadMessageRecordByMessageId(messageId, db: db) else { return nil }
            return resolveEntityOpenTarget(
                entityType: record.entityType,
                entityId: record.entityId,
                thingId: record.thingId
            )
        }
    }

    func searchIndexEntriesPage(
        before cursor: MessagePageCursor?,
        limit: Int
    ) async throws -> [MessageSearchIndex.Entry] {
        guard limit > 0 else { return [] }
        let messages = try await loadMessagesPage(
            before: cursor,
            limit: limit,
            filter: .all,
            channel: nil,
            tag: nil,
            sortMode: .timeDescending
        )
        return messages.map { message in
            MessageSearchIndex.Entry(
                id: message.id,
                title: message.title,
                body: message.body,
                channel: message.channel,
                receivedAt: message.receivedAt
            )
        }
    }

    func prepareStatsIfNeeded(progressive: Bool) async {
        _ = progressive
    }

    func messageCounts() async throws -> (total: Int, unread: Int) {
        try read { db in
            let totalSql = "SELECT COUNT(*) AS count FROM messages WHERE is_top_level_message = 1;"
            let unreadSql = "SELECT COUNT(*) AS count FROM messages WHERE is_top_level_message = 1 AND is_read = 0;"
            let total = try Int.fetchOne(db, sql: totalSql) ?? 0
            let unread = try Int.fetchOne(db, sql: unreadSql) ?? 0
            return (total: total, unread: unread)
        }
    }

    func messageChannelCounts() async throws -> [MessageChannelCount] {
        try read { db in
            let sql = """
                SELECT
                    CASE
                        WHEN channel IS NULL OR trim(channel) = '' THEN NULL
                        ELSE channel
                    END AS channel_key,
                    COUNT(*) AS total_count,
                    SUM(CASE WHEN is_read = 0 THEN 1 ELSE 0 END) AS unread_count,
                    MAX(received_at) AS latest_received_at,
                    MAX(CASE WHEN is_read = 0 THEN received_at ELSE NULL END) AS latest_unread_at
                FROM messages
                WHERE is_top_level_message = 1
                GROUP BY channel_key
                ORDER BY latest_received_at DESC;
                """
            return try Row.fetchAll(db, sql: sql).map { row in
                let channel: String? = row["channel_key"]
                let totalCount: Int = row["total_count"]
                let unreadCount: Int = row["unread_count"]
                let latestReceivedAtEpoch: Double? = row["latest_received_at"]
                let latestUnreadAtEpoch: Double? = row["latest_unread_at"]
                return MessageChannelCount(
                    channel: channel,
                    totalCount: totalCount,
                    unreadCount: unreadCount,
                    latestReceivedAt: latestReceivedAtEpoch.map(GRDBStore.dateFromStoredEpoch),
                    latestUnreadAt: latestUnreadAtEpoch.map(GRDBStore.dateFromStoredEpoch)
                )
            }
        }
    }

    func messageTagCounts() async throws -> [MessageTagCount] {
        let messages = try await loadMessages()
        var aggregates: [String: (totalCount: Int, latestReceivedAt: Date?)] = [:]

        for message in messages {
            let tags = Set(
                message.tags
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                    .filter { !$0.isEmpty }
            )
            for tag in tags {
                let existing = aggregates[tag]
                let latestReceivedAt: Date
                if let existingLatest = existing?.latestReceivedAt {
                    latestReceivedAt = max(existingLatest, message.receivedAt)
                } else {
                    latestReceivedAt = message.receivedAt
                }
                aggregates[tag] = (
                    totalCount: (existing?.totalCount ?? 0) + 1,
                    latestReceivedAt: latestReceivedAt
                )
            }
        }

        return aggregates
            .map { tag, aggregate in
                MessageTagCount(
                    tag: tag,
                    totalCount: aggregate.totalCount,
                    latestReceivedAt: aggregate.latestReceivedAt
                )
            }
            .sorted { lhs, rhs in
                if lhs.totalCount != rhs.totalCount {
                    return lhs.totalCount > rhs.totalCount
                }
                return lhs.tag.localizedCaseInsensitiveCompare(rhs.tag) == .orderedAscending
            }
    }

    func searchMessagesCount(query: String) async throws -> Int {
        let parsedQuery = SearchQuerySemantics.parse(query)
        guard !parsedQuery.isEmpty else { return 0 }
        let messages = try await loadMessages()
        return messages.filter { matchesSearchQuery($0, parsedQuery: parsedQuery) }.count
    }

    func searchMessagesPage(
        query: String,
        before cursor: MessagePageCursor?,
        limit: Int,
        sortMode: MessageListSortMode
    ) async throws -> [PushMessage] {
        guard limit > 0 else { return [] }
        let parsedQuery = SearchQuerySemantics.parse(query)
        guard !parsedQuery.isEmpty else { return [] }
        let allMessages = try loadMessages(
            filter: .all,
            channel: nil,
            tag: nil,
            before: nil,
            limit: nil,
            sortMode: sortMode
        )
        let filtered = allMessages.filter { matchesSearchQuery($0, parsedQuery: parsedQuery) }
        let paged: [PushMessage]
        if let cursor {
            paged = filtered.filter { messageAppearsAfterCursor($0, cursor: cursor, sortMode: sortMode) }
        } else {
            paged = filtered
        }
        return Array(paged.prefix(limit))
    }

    func searchMessageSummariesFallback(
        query: String,
        before cursor: MessagePageCursor?,
        limit: Int,
        sortMode: MessageListSortMode
    ) async throws -> [PushMessageSummary] {
        try await searchMessagesPage(query: query, before: cursor, limit: limit, sortMode: sortMode)
            .map(PushMessageSummary.init(message:))
    }

    func setMessageReadState(id: UUID, isRead: Bool) async throws {
        try write { db in
            let sql = """
                UPDATE messages
                SET is_read = \(isRead ? 1 : 0)
                WHERE id = \(Self.sqlQuoted(id.uuidString));
                """
            try db.execute(sql: sql)
        }
    }

    func markMessagesRead(
        filter: MessageQueryFilter,
        channel: String?
    ) async throws -> Int {
        try write { db in
            let unreadCondition = unreadPredicateCondition(filter: filter, channel: channel)
            guard unreadCondition != "0" else { return 0 }

            let idsSQL = "SELECT id FROM messages WHERE is_top_level_message = 1 AND \(unreadCondition);"
            let ids = try Row.fetchAll(db, sql: idsSQL).compactMap { row -> String? in
                let id: String? = row["id"]
                return id
            }
            guard !ids.isEmpty else { return 0 }

            let joined = ids.map(Self.sqlQuoted).joined(separator: ",")
            try db.execute(sql: "UPDATE messages SET is_read = 1 WHERE id IN (\(joined));")
            return ids.count
        }
    }

    func markMessagesRead(ids: [UUID]) async throws -> Int {
        let uniqueIds = Array(Set(ids))
        guard !uniqueIds.isEmpty else { return 0 }
        return try write { db in
            let joined = uniqueIds.map { Self.sqlQuoted($0.uuidString) }.joined(separator: ",")
            let unreadSql = """
                SELECT COUNT(*)
                FROM messages
                WHERE is_top_level_message = 1
                  AND is_read = 0
                  AND id IN (\(joined));
                """
            let unreadCount = try Int.fetchOne(db, sql: unreadSql) ?? 0
            guard unreadCount > 0 else { return 0 }
            try db.execute(
                sql: """
                    UPDATE messages
                    SET is_read = 1
                    WHERE is_top_level_message = 1
                      AND is_read = 0
                      AND id IN (\(joined));
                    """
            )
            return unreadCount
        }
    }

    func deleteMessage(id: UUID) async throws {
        try write { db in
            try db.execute(sql: "DELETE FROM messages WHERE id = \(Self.sqlQuoted(id.uuidString));")
        }
    }

    func deleteMessages(ids: [UUID]) async throws -> [UUID] {
        let uniqueIds = Array(Set(ids))
        guard !uniqueIds.isEmpty else { return [] }
        return try write { db in
            let joined = uniqueIds.map { Self.sqlQuoted($0.uuidString) }.joined(separator: ",")
            let existing = try Row.fetchAll(
                db,
                sql: "SELECT id FROM messages WHERE id IN (\(joined));"
            ).compactMap { row -> UUID? in
                let raw: String? = row["id"]
                return raw.flatMap(UUID.init(uuidString:))
            }
            guard !existing.isEmpty else { return [] }
            let existingJoined = existing.map { Self.sqlQuoted($0.uuidString) }.joined(separator: ",")
            try db.execute(sql: "DELETE FROM messages WHERE id IN (\(existingJoined));")
            return existing
        }
    }

    func deleteMessage(notificationRequestId: String) async throws {
        let normalized = notificationRequestId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }
        try write { db in
            let whereClause = "notification_request_id = \(Self.sqlQuoted(normalized))"
            try db.execute(sql: "DELETE FROM messages WHERE \(whereClause);")
        }
    }

    func deleteAllMessages() async throws {
        try write { db in
            try db.execute(sql: "DELETE FROM messages;")
        }
    }

    func deleteAllEntityRecords() async throws {
        try write { db in
            try db.execute(sql: "DELETE FROM messages WHERE is_top_level_message = 0 OR entity_type <> 'message';")
            try db.execute(sql: "DELETE FROM operation_ledger;")
        }
    }

    func deleteEventRecords(eventId: String) async throws -> Int {
        let normalized = eventId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return 0 }
        return try write { db in
            let idsSQL = """
                SELECT id
                FROM messages
                WHERE event_id = \(Self.sqlQuoted(normalized))
                  AND (entity_type = 'event' OR entity_type = 'message');
                """
            let ids = try Row.fetchAll(db, sql: idsSQL).compactMap { row -> String? in
                let id: String? = row["id"]
                return id
            }
            guard !ids.isEmpty else { return 0 }
            let joined = ids.map(Self.sqlQuoted).joined(separator: ",")
            try db.execute(sql: "DELETE FROM messages WHERE id IN (\(joined));")
            return ids.count
        }
    }

    func deleteEventRecords(eventIds: [String]) async throws -> Int {
        let normalized = Array(
            Set(
                eventIds
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
            )
        )
        guard !normalized.isEmpty else { return 0 }
        return try write { db in
            let inClause = normalized.map(Self.sqlQuoted).joined(separator: ",")
            let idsSQL = """
                SELECT id
                FROM messages
                WHERE event_id IN (\(inClause))
                  AND (entity_type = 'event' OR entity_type = 'message');
                """
            let ids = try Row.fetchAll(db, sql: idsSQL).compactMap { row -> String? in
                let id: String? = row["id"]
                return id
            }
            guard !ids.isEmpty else { return 0 }
            let joined = ids.map(Self.sqlQuoted).joined(separator: ",")
            try db.execute(sql: "DELETE FROM messages WHERE id IN (\(joined));")
            return ids.count
        }
    }

    func deleteEventRecords(channel: String?) async throws -> Int {
        let normalized = channel?.trimmingCharacters(in: .whitespacesAndNewlines)
        return try write { db in
            let channelCondition = Self.channelMatchCondition(value: normalized)
            let idsSQL = """
                SELECT id
                FROM messages
                WHERE entity_type = 'event'
                  AND \(channelCondition);
                """
            let ids = try Row.fetchAll(db, sql: idsSQL).compactMap { row -> String? in
                let id: String? = row["id"]
                return id
            }
            guard !ids.isEmpty else { return 0 }
            let joined = ids.map(Self.sqlQuoted).joined(separator: ",")
            try db.execute(sql: "DELETE FROM messages WHERE id IN (\(joined));")
            return ids.count
        }
    }

    func deleteThingRecords(thingId: String) async throws -> Int {
        let normalized = thingId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return 0 }
        return try write { db in
            let idsSQL = """
                SELECT id
                FROM messages
                WHERE thing_id = \(Self.sqlQuoted(normalized))
                   OR (entity_type = 'thing' AND entity_id = \(Self.sqlQuoted(normalized)));
                """
            let ids = try Row.fetchAll(db, sql: idsSQL).compactMap { row -> String? in
                let id: String? = row["id"]
                return id
            }
            guard !ids.isEmpty else { return 0 }
            let joined = ids.map(Self.sqlQuoted).joined(separator: ",")
            try db.execute(sql: "DELETE FROM messages WHERE id IN (\(joined));")
            return ids.count
        }
    }

    func deleteThingRecords(thingIds: [String]) async throws -> Int {
        let normalized = Array(
            Set(
                thingIds
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
            )
        )
        guard !normalized.isEmpty else { return 0 }
        return try write { db in
            let inClause = normalized.map(Self.sqlQuoted).joined(separator: ",")
            let idsSQL = """
                SELECT id
                FROM messages
                WHERE thing_id IN (\(inClause))
                   OR (entity_type = 'thing' AND entity_id IN (\(inClause)));
                """
            let ids = try Row.fetchAll(db, sql: idsSQL).compactMap { row -> String? in
                let id: String? = row["id"]
                return id
            }
            guard !ids.isEmpty else { return 0 }
            let joined = ids.map(Self.sqlQuoted).joined(separator: ",")
            try db.execute(sql: "DELETE FROM messages WHERE id IN (\(joined));")
            return ids.count
        }
    }

    func deleteThingRecords(channel: String?) async throws -> Int {
        let normalized = channel?.trimmingCharacters(in: .whitespacesAndNewlines)
        return try write { db in
            let channelCondition = Self.channelMatchCondition(value: normalized)
            let idsSQL = """
                SELECT id
                FROM messages
                WHERE ((thing_id IS NOT NULL AND trim(thing_id) <> '') OR entity_type = 'thing')
                  AND \(channelCondition);
                """
            let ids = try Row.fetchAll(db, sql: idsSQL).compactMap { row -> String? in
                let id: String? = row["id"]
                return id
            }
            guard !ids.isEmpty else { return 0 }
            let joined = ids.map(Self.sqlQuoted).joined(separator: ",")
            try db.execute(sql: "DELETE FROM messages WHERE id IN (\(joined));")
            return ids.count
        }
    }

    func deleteMessages(
        readState: Bool?,
        before cutoff: Date?
    ) async throws -> [UUID] {
        try write { db in
            var conditions: [String] = ["is_top_level_message = 1"]
            if let readState {
                conditions.append("is_read = \(readState ? 1 : 0)")
            }
            if let cutoff {
                conditions.append("received_at < \(Self.storedEpoch(cutoff))")
            }
            let whereClause = conditions.joined(separator: " AND ")
            let idsSQL = "SELECT id FROM messages WHERE \(whereClause);"
            let ids = try Row.fetchAll(db, sql: idsSQL).compactMap { row -> UUID? in
                let raw: String? = row["id"]
                return raw.flatMap(UUID.init(uuidString:))
            }
            guard !ids.isEmpty else { return [] }
            let joined = ids.map { Self.sqlQuoted($0.uuidString) }.joined(separator: ",")
            try db.execute(sql: "DELETE FROM messages WHERE id IN (\(joined));")
            return ids
        }
    }

    func deleteMessages(channel: String) async throws -> [UUID] {
        let normalized = channel.trimmingCharacters(in: .whitespacesAndNewlines)
        return try await deleteMessages(channel: normalized.isEmpty ? nil : normalized, readState: nil)
    }

    func deleteMessages(channel: String?, readState: Bool?) async throws -> [UUID] {
        try write { db in
            var conditions: [String] = ["is_top_level_message = 1"]
            if let readState {
                conditions.append("is_read = \(readState ? 1 : 0)")
            }
            if let channel {
                conditions.append(Self.channelMatchCondition(value: channel))
            }
            let whereClause = conditions.joined(separator: " AND ")
            let idsSQL = "SELECT id FROM messages WHERE \(whereClause);"
            let ids = try Row.fetchAll(db, sql: idsSQL).compactMap { row -> UUID? in
                let raw: String? = row["id"]
                return raw.flatMap(UUID.init(uuidString:))
            }
            guard !ids.isEmpty else { return [] }
            let joined = ids.map { Self.sqlQuoted($0.uuidString) }.joined(separator: ",")
            try db.execute(sql: "DELETE FROM messages WHERE id IN (\(joined));")
            return ids
        }
    }

    func loadOldestReadMessages(
        limit: Int,
        excludingChannels: [String]
    ) async throws -> [PushMessage] {
        guard limit > 0 else { return [] }
        return try read { db in
            var conditions: [String] = [
                "is_top_level_message = 1",
                "is_read = 1",
            ]
            let normalizedExcluded = excludingChannels
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            if !normalizedExcluded.isEmpty {
                let inClause = normalizedExcluded.map(Self.sqlQuoted).joined(separator: ",")
                conditions.append("(channel IS NULL OR channel NOT IN (\(inClause)))")
            }
            let whereClause = conditions.joined(separator: " AND ")
            let records = try fetchMessageRecords(
                db: db,
                where: conditions,
                orderBy: "received_at ASC, id ASC",
                limit: limit
            )
            _ = whereClause
            return records.map { $0.toPushMessage(decoder: decoder) }
        }
    }

    func deleteOldestReadMessages(
        limit: Int,
        excludingChannels: [String]
    ) async throws -> [UUID] {
        let messages = try await loadOldestReadMessages(limit: limit, excludingChannels: excludingChannels)
        let ids = messages.map(\.id)
        guard !ids.isEmpty else { return [] }
        try write { db in
            let joined = ids.map { Self.sqlQuoted($0.uuidString) }.joined(separator: ",")
            try db.execute(sql: "DELETE FROM messages WHERE id IN (\(joined));")
        }
        return ids
    }

    func loadPruneCandidates(maxCount: Int, batchSize: Int) async throws -> [PushMessage] {
        guard maxCount > 0, batchSize > 0 else { return [] }
        let (total, _) = try await messageCounts()
        guard total > maxCount else { return [] }
        let removeCount = min(batchSize, total - maxCount)
        return try read { db in
            let conditions = ["is_top_level_message = 1"]
            return try fetchMessages(
                db: db,
                where: conditions,
                orderBy: "received_at ASC, id ASC",
                limit: removeCount
            )
        }
    }

    func pruneMessagesIfNeeded(maxCount: Int, batchSize: Int) async throws -> [UUID] {
        let candidates = try await loadPruneCandidates(maxCount: maxCount, batchSize: batchSize)
        let ids = candidates.map(\.id)
        guard !ids.isEmpty else { return [] }
        try write { db in
            let joined = ids.map { Self.sqlQuoted($0.uuidString) }.joined(separator: ",")
            try db.execute(sql: "DELETE FROM messages WHERE id IN (\(joined));")
        }
        return ids
    }

    static func databaseDirectory(
        fileManager: FileManager,
        appGroupIdentifier: String
    ) throws -> URL {
        try AppConstants.appLocalDatabaseDirectory(
            fileManager: fileManager,
            appGroupIdentifier: appGroupIdentifier
        )
    }

    private static func storeURL(
        fileManager: FileManager,
        appGroupIdentifier: String,
        filename: String
    ) throws -> URL {
        let directory = try databaseDirectory(
            fileManager: fileManager,
            appGroupIdentifier: appGroupIdentifier
        )
        return directory.appendingPathComponent(filename)
    }
}
