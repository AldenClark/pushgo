import Foundation
import SwiftData
import UserNotifications

struct MessagePageCursor: Hashable, Sendable {
    let receivedAt: Date
}

enum MessageQueryFilter: Hashable, Sendable {
    case all
    case unreadOnly
    case readOnly
    case withURLOnly
    case byServer(UUID)
}

struct MessageChannelCount: Hashable, Sendable {
    let channel: String?
    let totalCount: Int
    let unreadCount: Int
    let latestReceivedAt: Date?
    let latestUnreadAt: Date?
}

struct AppSettingsSnapshot: Hashable, Sendable {
    var manualKeyLength: Int?
    var manualKeyEncoding: String?
    var launchAtLoginEnabled: Bool?
    var autoCleanupEnabled: Bool?
    var pushTokenData: Data?
    var legacyMigrationVersion: Int

    static let empty = AppSettingsSnapshot(
        manualKeyLength: nil,
        manualKeyEncoding: nil,
        launchAtLoginEnabled: nil,
        autoCleanupEnabled: nil,
        pushTokenData: nil,
        legacyMigrationVersion: 0
    )
}

actor LocalDataStore {
    struct StorageState: Sendable, Equatable {
        enum Mode: Sendable {
            case persistent
            case inMemory
            case unavailable
        }

        let mode: Mode
        let reason: String?
    }

    nonisolated let storageState: StorageState
    private let backend: SwiftDataStore?
    private let searchIndex: MessageSearchIndex?
    private let channelSubscriptionStore = ChannelSubscriptionStore()
    private let localConfigStore = LocalKeychainConfigStore()
    private let pendingInsertBatchSize: Int = 20
    private let pendingInsertFlushDelay: TimeInterval = 0.2
    private var pendingInsertFlushTask: Task<Void, Never>?
    private var pendingInsertById: [UUID: PushMessage] = [:]
    private var pendingInsertMessageIdIndex: [UUID: UUID] = [:]
    private var pendingInsertRequestIdIndex: [String: UUID] = [:]

    init(
        fileManager: FileManager = .default,
        encoder: JSONEncoder = JSONEncoder(),
        decoder: JSONDecoder = JSONDecoder(),
        appGroupIdentifier: String = AppConstants.appGroupIdentifier,
    ) {
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601

        let resolvedBackend: SwiftDataStore?
        let resolvedStorageState: StorageState
        do {
            resolvedBackend = try SwiftDataStore(
                fileManager: fileManager,
                encoder: encoder,
                decoder: decoder,
                appGroupIdentifier: appGroupIdentifier,
            )
            resolvedStorageState = StorageState(mode: .persistent, reason: nil)
        } catch {
            let persistentReason = error.localizedDescription
            do {
                resolvedBackend = try SwiftDataStore.inMemory(
                    encoder: encoder,
                    decoder: decoder,
                )
                resolvedStorageState = StorageState(mode: .inMemory, reason: persistentReason)
            } catch {
                let inMemoryReason = error.localizedDescription
                let combined = persistentReason == inMemoryReason
                    ? persistentReason
                    : "\(persistentReason) | \(inMemoryReason)"
                resolvedBackend = nil
                resolvedStorageState = StorageState(mode: .unavailable, reason: combined)
            }
        }
        backend = resolvedBackend
        storageState = resolvedStorageState

        searchIndex = try? MessageSearchIndex(
            appGroupIdentifier: appGroupIdentifier
        )
    }

    private var storeUnavailableError: AppError {
        AppError.localStore(storageState.reason ?? "Local store unavailable.")
    }

    private func requireBackend() throws -> SwiftDataStore {
        guard let backend else {
            throw storeUnavailableError
        }
        return backend
    }

    private func decodePushTokenMap(_ data: Data?) -> [String: String] {
        guard let data else { return [:] }
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }

    private func encodePushTokenMap(_ map: [String: String]) -> Data? {
        guard !map.isEmpty else { return nil }
        return try? JSONEncoder().encode(map)
    }

    func flushWrites() async {
        await flushPendingInserts()
    }

    private func enqueuePendingInsert(_ message: PushMessage) {
        if let messageId = message.messageId,
           pendingInsertMessageIdIndex[messageId] != nil
        {
            return
        }
        if pendingInsertById[message.id] != nil {
            removePendingIndexes(for: message.id)
        }
        pendingInsertById[message.id] = message
        if let messageId = message.messageId {
            pendingInsertMessageIdIndex[messageId] = message.id
        }
        if let requestId = message.notificationRequestId {
            pendingInsertRequestIdIndex[requestId] = message.id
        }

        if pendingInsertById.count >= pendingInsertBatchSize {
            pendingInsertFlushTask?.cancel()
            pendingInsertFlushTask = Task { [weak self] in
                await self?.flushPendingInserts()
            }
            return
        }

        schedulePendingInsertFlush()
    }

    private func schedulePendingInsertFlush() {
        guard pendingInsertFlushTask == nil else { return }
        let delay = pendingInsertFlushDelay
        pendingInsertFlushTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            await self?.flushPendingInserts()
        }
    }

    private func flushPendingInserts() async {
        pendingInsertFlushTask?.cancel()
        pendingInsertFlushTask = nil
        guard !pendingInsertById.isEmpty else { return }

        let batch = Array(pendingInsertById.values)
        pendingInsertById.removeAll(keepingCapacity: true)
        pendingInsertMessageIdIndex.removeAll(keepingCapacity: true)
        pendingInsertRequestIdIndex.removeAll(keepingCapacity: true)

        do {
            let backend = try requireBackend()
            let start = DispatchTime.now().uptimeNanoseconds
            try await backend.saveMessagesBatch(batch)
            let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
            await PerformanceMonitor.shared.record(operation: .writeBatch, durationMs: elapsedMs)
            if let searchIndex {
                let entries = batch.map { message in
                    MessageSearchIndex.Entry(
                        id: message.id,
                        title: message.title,
                        body: message.resolvedBody.rawText,
                        channel: message.channel,
                        receivedAt: message.receivedAt
                    )
                }
                try? await searchIndex.bulkUpsert(entries: entries)
            }
            await pruneMessagesIfNeededDuringFlush(
                maxCount: AppConstants.maxStoredMessages,
                batchSize: AppConstants.pruneBatchSize
            )
        } catch {
            batch.forEach { pending in
                pendingInsertById[pending.id] = pending
                if let messageId = pending.messageId {
                    pendingInsertMessageIdIndex[messageId] = pending.id
                }
                if let requestId = pending.notificationRequestId {
                    pendingInsertRequestIdIndex[requestId] = pending.id
                }
            }
            if backend != nil {
                schedulePendingInsertFlush()
            }
        }
    }

    private func applyPendingInserts(
        to messages: [PushMessage],
        includePending: Bool,
        limit: Int?
    ) -> [PushMessage] {
        guard includePending, !pendingInsertById.isEmpty else {
            return messages
        }
        let pending = pendingInsertById.values
        var combined = pending + messages.filter { pendingInsertById[$0.id] == nil }
        combined.sort { $0.receivedAt > $1.receivedAt }
        guard let limit, limit > 0 else { return combined }
        return Array(combined.prefix(limit))
    }

    private func applyPendingInsertsToSummaries(
        base summaries: [PushMessageSummary],
        includePending: Bool,
        limit: Int?
    ) -> [PushMessageSummary] {
        guard includePending, !pendingInsertById.isEmpty else {
            return summaries
        }
        let pending = pendingInsertById.values.map { PushMessageSummary(message: $0) }
        var combined = pending + summaries.filter { pendingInsertById[$0.id] == nil }
        combined.sort { $0.receivedAt > $1.receivedAt }
        guard let limit, limit > 0 else { return combined }
        return Array(combined.prefix(limit))
    }

    private func applyPendingInserts(
        to counts: [MessageChannelCount]
    ) -> [MessageChannelCount] {
        guard !pendingInsertById.isEmpty else { return counts }
        var map = Dictionary(uniqueKeysWithValues: counts.map { ($0.channel ?? "", $0) })
        let existingKeys = Set(map.keys)
        for message in pendingInsertById.values {
            let key = normalizeChannelKey(message.channel)
            let mapKey = key ?? ""
            if let existing = map[mapKey] {
                let total = existing.totalCount + 1
                let unread = existing.unreadCount + (message.isRead ? 0 : 1)
                let latestReceivedAt = max(existing.latestReceivedAt ?? message.receivedAt, message.receivedAt)
                let latestUnreadAt: Date? = {
                    guard !message.isRead else { return existing.latestUnreadAt }
                    return max(existing.latestUnreadAt ?? message.receivedAt, message.receivedAt)
                }()
                map[mapKey] = MessageChannelCount(
                    channel: existing.channel,
                    totalCount: total,
                    unreadCount: unread,
                    latestReceivedAt: latestReceivedAt,
                    latestUnreadAt: latestUnreadAt
                )
            } else {
                map[mapKey] = MessageChannelCount(
                    channel: key,
                    totalCount: 1,
                    unreadCount: message.isRead ? 0 : 1,
                    latestReceivedAt: message.receivedAt,
                    latestUnreadAt: message.isRead ? nil : message.receivedAt
                )
            }
        }
        var result: [MessageChannelCount] = []
        result.reserveCapacity(map.count)
        for item in counts {
            let mapKey = item.channel ?? ""
            if let updated = map[mapKey] {
                result.append(updated)
            }
        }
        for (key, value) in map where !existingKeys.contains(key) {
            result.append(value)
        }
        return result
    }

    private func normalizeChannelKey(_ channel: String?) -> String? {
        let trimmed = channel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private func removePendingIndexes(for id: UUID) {
        if let messageId = pendingInsertMessageIdIndex.first(where: { $0.value == id })?.key {
            pendingInsertMessageIdIndex[messageId] = nil
        }
        if let requestId = pendingInsertRequestIdIndex.first(where: { $0.value == id })?.key {
            pendingInsertRequestIdIndex[requestId] = nil
        }
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
        removeDeliveredNotifications(identifiers: notificationRequestIds(from: candidates))
    }

    func loadServerConfig() async throws -> ServerConfig? {
        try localConfigStore.loadServerConfig()
    }

    func saveServerConfig(_ config: ServerConfig?) async throws {
        try localConfigStore.saveServerConfig(config)
    }

    private func normalizeGatewayKey(_ gateway: String) -> String {
        gateway.trimmingCharacters(in: .whitespacesAndNewlines)
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
            lastSyncedAt: item.lastSyncedAt,
            autoCleanupEnabled: item.autoCleanupEnabled
        )
    }

    func loadChannelSubscriptions(
        gateway: String,
        includeDeleted: Bool = false
    ) async throws -> [ChannelSubscription] {
        let trimmedGateway = normalizeGatewayKey(gateway)
        guard !trimmedGateway.isEmpty else { return [] }
        let stored = try channelSubscriptionStore.loadSubscriptions(
            gatewayKey: trimmedGateway
        )
        let filtered = includeDeleted ? stored : stored.filter { !$0.isDeleted }
        return filtered
            .map { mapToDomain($0, gateway: trimmedGateway) }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    func loadChannelSubscriptions(includeDeleted: Bool) async throws -> [ChannelSubscription] {
        guard let backend else {
            throw storeUnavailableError
        }
        return try await backend.loadChannelSubscriptions(includeDeleted: includeDeleted)
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
        let trimmedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedName = trimmedName.isEmpty ? trimmedChannelId : trimmedName
        let trimmedPassword = (password ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let existing = items.first(where: { $0.channelId == trimmedChannelId })
        let updated = KeychainChannelSubscription(
            channelId: trimmedChannelId,
            displayName: resolvedName,
            password: trimmedPassword,
            updatedAt: now,
            lastSyncedAt: lastSyncedAt,
            autoCleanupEnabled: existing?.autoCleanupEnabled ?? true,
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
        return ChannelSubscription(
            gateway: trimmedGateway,
            channelId: trimmedChannelId,
            displayName: resolvedName,
            updatedAt: now,
            lastSyncedAt: lastSyncedAt,
            autoCleanupEnabled: updated.autoCleanupEnabled
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

    func setChannelAutoCleanupEnabled(
        gateway: String,
        channelId: String,
        isEnabled: Bool
    ) async throws -> ChannelSubscription? {
        let trimmedGateway = normalizeGatewayKey(gateway)
        guard !trimmedGateway.isEmpty else { throw AppError.noServer }
        var items = try channelSubscriptionStore.loadSubscriptions(
            gatewayKey: trimmedGateway
        )
        let trimmedChannelId = channelId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let index = items.firstIndex(where: { $0.channelId == trimmedChannelId }) else {
            return nil
        }
        items[index].autoCleanupEnabled = isEnabled
        items[index].updatedAt = Date()
        try channelSubscriptionStore.saveSubscriptions(
            gatewayKey: trimmedGateway,
            subscriptions: items
        )
        return mapToDomain(items[index], gateway: trimmedGateway)
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
        guard let backend else { return nil }
        guard let settings = try? await backend.loadAppSettings() else { return nil }
        return decodePushTokenMap(settings.pushTokenData)[platform]
    }

    func saveCachedPushToken(_ token: String?, for platform: String) async {
        guard let backend else { return }
        var settings = (try? await backend.loadAppSettings()) ?? .empty
        var tokens = decodePushTokenMap(settings.pushTokenData)
        if let trimmed = token?.trimmingCharacters(in: .whitespacesAndNewlines),
           !trimmed.isEmpty
        {
            tokens[platform] = trimmed
        } else {
            tokens.removeValue(forKey: platform)
        }
        settings.pushTokenData = encodePushTokenMap(tokens)
        try? await backend.saveAppSettings(settings)
    }

    func loadManualKeyPreferences() async -> (length: Int?, encoding: String?) {
        let prefs = (try? localConfigStore.loadManualKeyPreferences())
            ?? ManualKeyPreferences(length: nil, encoding: nil)
        return (prefs.length, prefs.encoding)
    }

    func saveManualKeyPreferences(length: Int?, encoding: String?) async {
        let prefs = ManualKeyPreferences(length: length, encoding: encoding)
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

    func loadAutoCleanupPreference() async -> Bool? {
        guard let backend else { return nil }
        guard let settings = try? await backend.loadAppSettings() else { return nil }
        if let cached = settings.autoCleanupEnabled {
            cacheAutoCleanupPreference(cached)
        }
        return settings.autoCleanupEnabled
    }

    func saveAutoCleanupPreference(_ isEnabled: Bool) async {
        cacheAutoCleanupPreference(isEnabled)
        guard let backend else { return }
        var settings = (try? await backend.loadAppSettings()) ?? .empty
        settings.autoCleanupEnabled = isEnabled
        try? await backend.saveAppSettings(settings)
    }

    nonisolated func cachedAutoCleanupPreference() -> Bool? {
        let defaults = UserDefaults(suiteName: AppConstants.appGroupIdentifier)
        guard let object = defaults?.object(forKey: AppConstants.autoCleanupEnabledKey) else { return nil }
        return object as? Bool
    }

    private func cacheAutoCleanupPreference(_ isEnabled: Bool) {
        UserDefaults(suiteName: AppConstants.appGroupIdentifier)?
            .set(isEnabled, forKey: AppConstants.autoCleanupEnabledKey)
    }

    func loadDefaultRingtoneFilename() async -> String? {
        UserDefaults(suiteName: AppConstants.appGroupIdentifier)?
            .string(forKey: AppConstants.defaultRingtoneFilenameKey)
    }

    func saveDefaultRingtoneFilename(_ filename: String?) async {
        let defaults = UserDefaults(suiteName: AppConstants.appGroupIdentifier)
        let trimmed = filename?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty {
            defaults?.removeObject(forKey: AppConstants.defaultRingtoneFilenameKey)
        } else {
            defaults?.set(trimmed, forKey: AppConstants.defaultRingtoneFilenameKey)
        }
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
    ) async throws -> [PushMessage] {
        let backend = try requireBackend()
        let messages = try await backend.loadMessages(filter: filter, channel: channel)
        return applyPendingInserts(
            to: messages,
            includePending: true,
            limit: nil
        )
    }

    func loadMessage(id: UUID) async throws -> PushMessage? {
        if let pending = pendingInsertById[id] {
            return pending
        }
        let backend = try requireBackend()
        return try await backend.loadMessage(id: id)
    }

    func loadMessage(messageId: UUID) async throws -> PushMessage? {
        if let pendingId = pendingInsertMessageIdIndex[messageId],
           let pending = pendingInsertById[pendingId]
        {
            return pending
        }
        let backend = try requireBackend()
        return try await backend.loadMessage(messageId: messageId)
    }

    func loadMessage(notificationRequestId: String) async throws -> PushMessage? {
        if let pendingId = pendingInsertRequestIdIndex[notificationRequestId],
           let pending = pendingInsertById[pendingId]
        {
            return pending
        }
        let backend = try requireBackend()
        return try await backend.loadMessage(notificationRequestId: notificationRequestId)
    }

    func loadMessagesPage(
        before cursor: MessagePageCursor?,
        limit: Int,
        filter: MessageQueryFilter = .all,
        channel: String? = nil,
    ) async throws -> [PushMessage] {
        let backend = try requireBackend()
        let messages = try await backend.loadMessagesPage(
            before: cursor,
            limit: limit,
            filter: filter,
            channel: channel
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
    ) async throws -> [PushMessageSummary] {
        let backend = try requireBackend()
        let summaries = try await backend.loadMessageSummariesPage(
            before: cursor,
            limit: limit,
            filter: filter,
            channel: channel
        )
        return applyPendingInsertsToSummaries(
            base: summaries,
            includePending: cursor == nil,
            limit: limit
        )
    }

    func messageChannelCounts() async throws -> [MessageChannelCount] {
        let backend = try requireBackend()
        let baseCounts = try await backend.messageChannelCounts()
        return applyPendingInserts(to: baseCounts)
    }

    func messageCounts() async throws -> (total: Int, unread: Int) {
        let backend = try requireBackend()
        let base = try await backend.messageCounts()
        let pendingUnread = pendingInsertById.values.filter { !$0.isRead }.count
        return (total: base.total + pendingInsertById.count, unread: base.unread + pendingUnread)
    }

    func searchMessagesCount(query: String) async throws -> Int {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return 0 }
        if let searchIndex {
            await ensureSearchIndexReady()
            let ftsQuery = Self.searchIndexQuery(from: trimmed)
            if let count = try? await searchIndex.count(query: ftsQuery) {
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
    ) async throws -> [PushMessage] {
        let backend = try requireBackend()
        return try await backend.searchMessagesPage(query: query, before: cursor, limit: limit)
    }

    func searchMessageSummariesPage(
        query: String,
        before cursor: MessagePageCursor?,
        limit: Int,
    ) async throws -> [PushMessageSummary] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let backend = try requireBackend()
        if let searchIndex {
            await ensureSearchIndexReady()
            let ftsQuery = Self.searchIndexQuery(from: trimmed)
            if let ids = try? await searchIndex.searchIDs(query: ftsQuery, before: cursor?.receivedAt, limit: limit),
               !ids.isEmpty
            {
                return try await backend.loadMessageSummaries(ids: ids)
            }
        }
        return try await backend.searchMessageSummariesFallback(query: trimmed, before: cursor, limit: limit)
    }

    func saveMessages(_ messages: [PushMessage]) async throws {
        await flushWrites()
        let backend = try requireBackend()
        try await backend.saveMessages(messages)
        await rebuildSearchIndex(with: messages)
    }

    func saveMessage(_ message: PushMessage) async throws {
        enqueuePendingInsert(message)
    }

    func saveMessagesBatch(_ messages: [PushMessage]) async throws {
        guard !messages.isEmpty else { return }
        messages.forEach { enqueuePendingInsert($0) }
    }

    func setMessageReadState(id: UUID, isRead: Bool) async throws {
        if let pending = pendingInsertById[id] {
            var updated = pending
            updated.isRead = isRead
            pendingInsertById[id] = updated
            return
        }
        await flushWrites()
        let backend = try requireBackend()
        try await backend.setMessageReadState(id: id, isRead: isRead)
    }

    func markMessagesRead(
        filter: MessageQueryFilter,
        channel: String?
    ) async throws -> Int {
        await flushWrites()
        let backend = try requireBackend()
        return try await backend.markMessagesRead(filter: filter, channel: channel)
    }

    func deleteMessage(id: UUID) async throws {
        if pendingInsertById.removeValue(forKey: id) != nil {
            removePendingIndexes(for: id)
            return
        }
        await flushWrites()
        let backend = try requireBackend()
        try await backend.deleteMessage(id: id)
        if let searchIndex {
            try? await searchIndex.remove(id: id)
        }
    }

    func deleteMessage(notificationRequestId: String) async throws {
        if let pendingId = pendingInsertRequestIdIndex[notificationRequestId] {
            _ = pendingInsertById.removeValue(forKey: pendingId)
            removePendingIndexes(for: pendingId)
            return
        }
        await flushWrites()
        let backend = try requireBackend()
        if let message = try await backend.loadMessage(notificationRequestId: notificationRequestId) {
            try await backend.deleteMessage(notificationRequestId: notificationRequestId)
            if let searchIndex {
                try? await searchIndex.remove(id: message.id)
            }
        } else {
            try await backend.deleteMessage(notificationRequestId: notificationRequestId)
        }
    }

    func deleteAllMessages() async throws {
        await flushWrites()
        let backend = try requireBackend()
        try await backend.deleteAllMessages()
        pendingInsertById.removeAll(keepingCapacity: true)
        pendingInsertMessageIdIndex.removeAll(keepingCapacity: true)
        pendingInsertRequestIdIndex.removeAll(keepingCapacity: true)
        if let searchIndex {
            try? await searchIndex.clear()
        }
    }

    func deleteMessages(readState: Bool?, before cutoff: Date?) async throws -> Int {
        await flushWrites()
        let backend = try requireBackend()
        if readState == nil && cutoff == nil {
            let total = (try? await backend.messageCounts().total) ?? 0
            try await backend.deleteAllMessages()
            if let searchIndex {
                try? await searchIndex.clear()
            }
            return total
        }

        let deletedIds = try await backend.deleteMessages(readState: readState, before: cutoff)
        if let searchIndex, !deletedIds.isEmpty {
            try? await searchIndex.bulkRemove(ids: deletedIds)
        }
        return deletedIds.count
    }

    func deleteMessages(channel: String) async throws -> Int {
        await flushWrites()
        let backend = try requireBackend()
        let deletedIds = try await backend.deleteMessages(channel: channel)
        if let searchIndex, !deletedIds.isEmpty {
            try? await searchIndex.bulkRemove(ids: deletedIds)
        }
        return deletedIds.count
    }

    func deleteMessages(channel: String?, readState: Bool?) async throws -> Int {
        await flushWrites()
        let backend = try requireBackend()
        let deletedIds = try await backend.deleteMessages(channel: channel, readState: readState)
        if let searchIndex, !deletedIds.isEmpty {
            try? await searchIndex.bulkRemove(ids: deletedIds)
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
        await flushWrites()
        let backend = try requireBackend()
        let deletedIds = try await backend.deleteOldestReadMessages(
            limit: limit,
            excludingChannels: excludingChannels
        )
        if let searchIndex, !deletedIds.isEmpty {
            try? await searchIndex.bulkRemove(ids: deletedIds)
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
        return deletedIds.count
    }
    func warmCachesIfNeeded() async {
        await flushWrites()
        guard let backend else { return }
        await backend.prepareStatsIfNeeded(progressive: true)
        await rebuildSearchIndexIfNeeded(batchSize: 200, yieldBetweenBatches: true)
    }

    private func rebuildSearchIndex(with messages: [PushMessage]) async {
        guard let searchIndex else { return }
        try? await searchIndex.clear()
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
            cursor = entries.last.map { MessagePageCursor(receivedAt: $0.receivedAt) }
            if entries.count < batchSize { break }
            if yieldBetweenBatches {
                await Task.yield()
            }
        }
    }

    private static func searchIndexQuery(from raw: String) -> String {
        let tokens = raw.split(whereSeparator: { $0.isWhitespace })
        if tokens.isEmpty { return raw }
        return tokens
            .map { String($0).replacingOccurrences(of: "\"", with: "") }
            .map { "\"\($0)\"" }
            .joined(separator: " AND ")
    }
}

private final class SwiftDataStore {
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let modelContainer: ModelContainer
    private let appSettingsId = "default"

    init(
        fileManager: FileManager,
        encoder: JSONEncoder,
        decoder: JSONDecoder,
        appGroupIdentifier: String,
    ) throws {
        self.encoder = encoder
        self.decoder = decoder

        let schema = Schema([
            StoredPushMessage.self,
            StoredServerConfig.self,
            StoredChannelSubscription.self,
            StoredAppSettings.self,
            StoredMessageStats.self,
            StoredMessageChannelStats.self,
        ])
        let storeURL = try Self.storeURL(
            fileManager: fileManager,
            appGroupIdentifier: appGroupIdentifier,
        )
        let configuration = ModelConfiguration(schema: schema, url: storeURL)
        modelContainer = try ModelContainer(for: schema, configurations: [configuration])
    }

    static func inMemory(
        encoder: JSONEncoder,
        decoder: JSONDecoder,
    ) throws -> SwiftDataStore {
        let schema = Schema([
            StoredPushMessage.self,
            StoredServerConfig.self,
            StoredChannelSubscription.self,
            StoredAppSettings.self,
            StoredMessageStats.self,
            StoredMessageChannelStats.self,
        ])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = (try? ModelContainer(for: schema, configurations: [configuration]))
            ?? (try? ModelContainer(for: schema))
        guard let container else {
            throw AppError.localStore("SwiftData ModelContainer initialization failed.")
        }
        return SwiftDataStore(
            encoder: encoder,
            decoder: decoder,
            modelContainer: container
        )
    }

    private init(
        encoder: JSONEncoder,
        decoder: JSONDecoder,
        modelContainer: ModelContainer,
    ) {
        self.encoder = encoder
        self.decoder = decoder
        self.modelContainer = modelContainer
    }

    func loadServerConfig() async throws -> ServerConfig? {
        let modelContext = ModelContext(modelContainer)
        let descriptor = FetchDescriptor<StoredServerConfig>(
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)],
        )
        let stored = try modelContext.fetch(descriptor).first
        return try stored?.toDomain(decoder: decoder)
    }

    func saveServerConfig(_ config: ServerConfig?) async throws {
        let modelContext = ModelContext(modelContainer)

        guard let config else {
            let existing = try modelContext.fetch(FetchDescriptor<StoredServerConfig>())
            existing.forEach { modelContext.delete($0) }
            if modelContext.hasChanges {
                do {
                    try modelContext.save()
                } catch {
                    throw error
                }
            }
            return
        }

        let descriptor = FetchDescriptor<StoredServerConfig>(
            predicate: #Predicate { $0.id == config.id },
        )
        if let stored = try modelContext.fetch(descriptor).first {
            try stored.update(from: config, encoder: encoder)
        } else {
            try modelContext.insert(StoredServerConfig(from: config, encoder: encoder))
        }

        let stale = try modelContext.fetch(
            FetchDescriptor<StoredServerConfig>(predicate: #Predicate { $0.id != config.id }),
        )
        stale.forEach { modelContext.delete($0) }

        if modelContext.hasChanges {
            do {
                try modelContext.save()
            } catch {
                throw error
            }
        }
    }

    func loadChannelSubscriptions(includeDeleted: Bool) async throws -> [ChannelSubscription] {
        let modelContext = ModelContext(modelContainer)
        let sort = SortDescriptor(\StoredChannelSubscription.updatedAt, order: .reverse)
        let descriptor: FetchDescriptor<StoredChannelSubscription>
        if includeDeleted {
            descriptor = FetchDescriptor(sortBy: [sort])
        } else {
            descriptor = FetchDescriptor(
                predicate: #Predicate { $0.isDeleted == false },
                sortBy: [sort]
            )
        }
        let stored = try modelContext.fetch(descriptor)
        return stored.map { $0.toDomain() }
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
        let modelContext = ModelContext(modelContainer)
        let descriptor = FetchDescriptor<StoredChannelSubscription>(
            predicate: #Predicate { $0.channelId == channelId },
        )
        if let stored = try modelContext.fetch(descriptor).first {
            stored.gateway = gateway
            stored.displayName = displayName
            stored.password = password
            stored.lastSyncedAt = lastSyncedAt
            stored.updatedAt = updatedAt
            stored.isDeleted = isDeleted
            stored.deletedAt = deletedAt
        } else {
            modelContext.insert(StoredChannelSubscription(
                channelId: channelId,
                gateway: gateway,
                displayName: displayName,
                password: password,
                updatedAt: updatedAt,
                lastSyncedAt: lastSyncedAt,
                autoCleanupEnabled: true,
                isDeleted: isDeleted,
                deletedAt: deletedAt
            ))
        }
        if modelContext.hasChanges {
            try modelContext.save()
        }
    }

    func updateChannelAutoCleanupEnabled(channelId: String, isEnabled: Bool) async throws {
        let modelContext = ModelContext(modelContainer)
        let descriptor = FetchDescriptor<StoredChannelSubscription>(
            predicate: #Predicate { $0.channelId == channelId },
        )
        guard let stored = try modelContext.fetch(descriptor).first else { return }
        stored.autoCleanupEnabled = isEnabled
        stored.updatedAt = Date()
        if modelContext.hasChanges {
            try modelContext.save()
        }
    }

    func updateChannelDisplayName(
        channelId: String,
        displayName: String,
        updatedAt: Date
    ) async throws {
        let modelContext = ModelContext(modelContainer)
        let descriptor = FetchDescriptor<StoredChannelSubscription>(
            predicate: #Predicate { $0.channelId == channelId },
        )
        guard let stored = try modelContext.fetch(descriptor).first else { return }
        stored.displayName = displayName
        stored.updatedAt = updatedAt
        if stored.isDeleted {
            stored.isDeleted = false
            stored.deletedAt = nil
        }
        if modelContext.hasChanges {
            try modelContext.save()
        }
    }

    func updateChannelLastSynced(channelId: String, date: Date) async throws {
        let modelContext = ModelContext(modelContainer)
        let descriptor = FetchDescriptor<StoredChannelSubscription>(
            predicate: #Predicate { $0.channelId == channelId },
        )
        guard let stored = try modelContext.fetch(descriptor).first else { return }
        stored.lastSyncedAt = date
        if modelContext.hasChanges {
            try modelContext.save()
        }
    }

    func softDeleteChannelSubscription(channelId: String, deletedAt: Date) async throws {
        let modelContext = ModelContext(modelContainer)
        let descriptor = FetchDescriptor<StoredChannelSubscription>(
            predicate: #Predicate { $0.channelId == channelId },
        )
        guard let stored = try modelContext.fetch(descriptor).first else { return }
        stored.isDeleted = true
        stored.deletedAt = deletedAt
        stored.password = nil
        if modelContext.hasChanges {
            try modelContext.save()
        }
    }

    func softDeleteChannelSubscription(
        gateway: String,
        channelId: String,
        deletedAt: Date
    ) async throws {
        let modelContext = ModelContext(modelContainer)
        let descriptor = FetchDescriptor<StoredChannelSubscription>(
            predicate: #Predicate { $0.channelId == channelId && $0.gateway == gateway },
        )
        guard let stored = try modelContext.fetch(descriptor).first else { return }
        stored.isDeleted = true
        stored.deletedAt = deletedAt
        stored.password = nil
        if modelContext.hasChanges {
            try modelContext.save()
        }
    }

    func loadChannelPassword(channelId: String) async throws -> String? {
        let modelContext = ModelContext(modelContainer)
        let descriptor = FetchDescriptor<StoredChannelSubscription>(
            predicate: #Predicate { $0.channelId == channelId },
        )
        guard let stored = try modelContext.fetch(descriptor).first else { return nil }
        guard stored.isDeleted == false else { return nil }
        return stored.password
    }

    func loadActiveChannelCredentials() async throws -> [(channelId: String, password: String)] {
        let modelContext = ModelContext(modelContainer)
        let descriptor = FetchDescriptor<StoredChannelSubscription>(
            predicate: #Predicate { $0.isDeleted == false },
        )
        let stored = try modelContext.fetch(descriptor)
        var results: [(channelId: String, password: String)] = []
        results.reserveCapacity(stored.count)

        for entry in stored {
            if let password = entry.password,
               !password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                results.append((channelId: entry.channelId, password: password))
            }
        }

        return results
    }

    func loadAppSettings() async throws -> AppSettingsSnapshot? {
        let modelContext = ModelContext(modelContainer)
        let descriptor = FetchDescriptor<StoredAppSettings>(
            predicate: #Predicate { $0.id == appSettingsId },
        )
        guard let stored = try modelContext.fetch(descriptor).first else { return nil }
        return AppSettingsSnapshot(
            manualKeyLength: stored.manualKeyLength,
            manualKeyEncoding: stored.manualKeyEncoding,
            launchAtLoginEnabled: stored.launchAtLoginEnabled,
            autoCleanupEnabled: stored.autoCleanupEnabled,
            pushTokenData: stored.pushTokenData,
            legacyMigrationVersion: stored.legacyMigrationVersion
        )
    }

    func saveAppSettings(_ snapshot: AppSettingsSnapshot) async throws {
        let modelContext = ModelContext(modelContainer)
        let descriptor = FetchDescriptor<StoredAppSettings>(
            predicate: #Predicate { $0.id == appSettingsId },
        )
        if let stored = try modelContext.fetch(descriptor).first {
            stored.manualKeyLength = snapshot.manualKeyLength
            stored.manualKeyEncoding = snapshot.manualKeyEncoding
            stored.launchAtLoginEnabled = snapshot.launchAtLoginEnabled
            stored.autoCleanupEnabled = snapshot.autoCleanupEnabled
            stored.pushTokenData = snapshot.pushTokenData
            stored.legacyMigrationVersion = snapshot.legacyMigrationVersion
        } else {
            modelContext.insert(StoredAppSettings(
                id: appSettingsId,
                manualKeyLength: snapshot.manualKeyLength,
                manualKeyEncoding: snapshot.manualKeyEncoding,
                launchAtLoginEnabled: snapshot.launchAtLoginEnabled,
                autoCleanupEnabled: snapshot.autoCleanupEnabled,
                pushTokenData: snapshot.pushTokenData,
                legacyMigrationVersion: snapshot.legacyMigrationVersion
            ))
        }
        if modelContext.hasChanges {
            try modelContext.save()
        }
    }

    func saveMessage(_ message: PushMessage) async throws {
        let modelContext = ModelContext(modelContainer)
        try saveMessagesBatch([message], in: modelContext)
    }

    func saveMessagesBatch(_ messages: [PushMessage]) async throws {
        guard !messages.isEmpty else { return }
        let modelContext = ModelContext(modelContainer)
        try saveMessagesBatch(messages, in: modelContext)
    }

    fileprivate func saveMessagesBatch(
        _ messages: [PushMessage],
        in modelContext: ModelContext
    ) throws {
        guard !messages.isEmpty else { return }
        let idSet = Set(messages.map(\.id))
        let descriptor = FetchDescriptor<StoredPushMessage>(
            predicate: #Predicate { idSet.contains($0.id) },
        )
        let existing = try modelContext.fetch(descriptor)
        let existingById = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })

        for message in messages {
            if let stored = existingById[message.id] {
                let snapshot = StoredMessageSnapshot(
                    channelKey: normalizeChannelKey(stored.channel),
                    isRead: stored.isRead,
                    receivedAt: stored.receivedAt
                )
                try stored.update(from: message, encoder: encoder)
                try updateStatsForUpdate(
                    snapshot: snapshot,
                    newMessage: message,
                    modelContext: modelContext
                )
            } else {
                try modelContext.insert(StoredPushMessage(from: message, encoder: encoder))
                try updateStatsForInsert(message: message, modelContext: modelContext)
            }
        }

        if modelContext.hasChanges {
            do {
                try modelContext.save()
            } catch {
                throw error
            }
        }
    }

    func loadMessages() async throws -> [PushMessage] {
        let modelContext = ModelContext(modelContainer)
        let descriptor = FetchDescriptor<StoredPushMessage>(
            sortBy: [SortDescriptor(\.receivedAt, order: .reverse)],
        )
        let stored = try modelContext.fetch(descriptor)
        return try stored.map { try $0.toDomain(decoder: decoder) }
    }

    func loadMessage(id: UUID) async throws -> PushMessage? {
        let modelContext = ModelContext(modelContainer)
        var descriptor = FetchDescriptor<StoredPushMessage>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first.map { try $0.toDomain(decoder: decoder) }
    }

    func loadMessage(messageId: UUID) async throws -> PushMessage? {
        let modelContext = ModelContext(modelContainer)
        var descriptor = FetchDescriptor<StoredPushMessage>(
            predicate: #Predicate { $0.messageId == messageId },
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first.map { try $0.toDomain(decoder: decoder) }
    }

    func loadMessage(notificationRequestId: String) async throws -> PushMessage? {
        let modelContext = ModelContext(modelContainer)
        var descriptor = FetchDescriptor<StoredPushMessage>(
            predicate: #Predicate { $0.notificationRequestId == notificationRequestId },
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first.map { try $0.toDomain(decoder: decoder) }
    }

    func loadMessagesPage(
        before cursor: MessagePageCursor?,
        limit: Int,
        filter: MessageQueryFilter,
        channel: String?,
    ) async throws -> [PushMessage] {
        let modelContext = ModelContext(modelContainer)
        let predicate = buildMessagesPagePredicate(
            cursor: cursor,
            filter: filter,
            channel: channel,
        )
        var descriptor = FetchDescriptor<StoredPushMessage>(
            predicate: predicate,
            sortBy: [SortDescriptor(\.receivedAt, order: .reverse)],
        )
        descriptor.fetchLimit = max(0, limit)
        let stored = try modelContext.fetch(descriptor)
        return try stored.map { try $0.toDomain(decoder: decoder) }
    }

    func loadMessageSummariesPage(
        before cursor: MessagePageCursor?,
        limit: Int,
        filter: MessageQueryFilter,
        channel: String?,
    ) async throws -> [PushMessageSummary] {
        let modelContext = ModelContext(modelContainer)
        let predicate = buildMessagesPagePredicate(
            cursor: cursor,
            filter: filter,
            channel: channel,
        )
        var descriptor = FetchDescriptor<StoredPushMessage>(
            predicate: predicate,
            sortBy: [SortDescriptor(\.receivedAt, order: .reverse)],
        )
        descriptor.fetchLimit = max(0, limit)
        let stored = try modelContext.fetch(descriptor)
        let summaries = stored.map { $0.toSummary() }
        if modelContext.hasChanges {
            try modelContext.save()
        }
        return summaries
    }

    func loadMessageSummaries(ids: [UUID]) async throws -> [PushMessageSummary] {
        guard !ids.isEmpty else { return [] }
        let modelContext = ModelContext(modelContainer)
        let idSet = Set(ids)
        let descriptor = FetchDescriptor<StoredPushMessage>(
            predicate: #Predicate { idSet.contains($0.id) },
        )
        let stored = try modelContext.fetch(descriptor)
        let summaries = stored.map { $0.toSummary() }
        if modelContext.hasChanges {
            try modelContext.save()
        }
        let byId = Dictionary(uniqueKeysWithValues: summaries.map { ($0.id, $0) })
        return ids.compactMap { byId[$0] }
    }

    func loadMessages(
        filter: MessageQueryFilter,
        channel: String?,
    ) async throws -> [PushMessage] {
        let modelContext = ModelContext(modelContainer)
        let predicate = buildMessagesPagePredicate(
            cursor: nil,
            filter: filter,
            channel: channel,
        )
        let descriptor = FetchDescriptor<StoredPushMessage>(
            predicate: predicate,
            sortBy: [SortDescriptor(\.receivedAt, order: .reverse)],
        )
        let stored = try modelContext.fetch(descriptor)
        return try stored.map { try $0.toDomain(decoder: decoder) }
    }

    func searchIndexEntriesPage(
        before cursor: MessagePageCursor?,
        limit: Int,
    ) async throws -> [MessageSearchIndex.Entry] {
        let modelContext = ModelContext(modelContainer)
        let cutoff = cursor?.receivedAt ?? Date.distantFuture
        var descriptor = FetchDescriptor<StoredPushMessage>(
            predicate: #Predicate { $0.receivedAt < cutoff },
            sortBy: [SortDescriptor(\.receivedAt, order: .reverse)],
        )
        descriptor.fetchLimit = max(0, limit)
        let stored = try modelContext.fetch(descriptor)
        return stored.map { message in
            MessageSearchIndex.Entry(
                id: message.id,
                title: message.title,
                body: message.resolvedBodyText,
                channel: message.channel,
                receivedAt: message.receivedAt
            )
        }
    }

    func prepareStatsIfNeeded(progressive: Bool) async {
        do {
            let hasStats: Bool
            do {
                let modelContext = ModelContext(modelContainer)
                hasStats = try modelContext.fetch(FetchDescriptor<StoredMessageStats>()).first != nil
            }
            if hasStats {
                return
            }
            let total: Int
            do {
                let modelContext = ModelContext(modelContainer)
                total = try modelContext.fetchCount(FetchDescriptor<StoredPushMessage>())
            }
            if total == 0 {
                let modelContext = ModelContext(modelContainer)
                modelContext.insert(StoredMessageStats(totalCount: 0, unreadCount: 0))
                if modelContext.hasChanges {
                    try modelContext.save()
                }
                return
            }

            if progressive {
                _ = try await rebuildStatsProgressively(pageSize: 500)
            } else {
                let modelContext = ModelContext(modelContainer)
                _ = try rebuildStats(modelContext)
                if modelContext.hasChanges {
                    try modelContext.save()
                }
            }
        } catch {
            return
        }
    }

    func messageCounts() async throws -> (total: Int, unread: Int) {
        let modelContext = ModelContext(modelContainer)
        let preparation = try ensureStatsReady(modelContext)
        if modelContext.hasChanges {
            try modelContext.save()
        }
        return (total: preparation.stats.totalCount, unread: preparation.stats.unreadCount)
    }

    func messageChannelCounts() async throws -> [MessageChannelCount] {
        let modelContext = ModelContext(modelContainer)
        _ = try ensureStatsReady(modelContext)
        let stored = try modelContext.fetch(FetchDescriptor<StoredMessageChannelStats>())
        if modelContext.hasChanges {
            try modelContext.save()
        }
        return stored.map { item in
            MessageChannelCount(
                channel: item.channelKey.isEmpty ? nil : item.channelKey,
                totalCount: item.totalCount,
                unreadCount: item.unreadCount,
                latestReceivedAt: item.latestReceivedAt,
                latestUnreadAt: item.latestUnreadAt,
            )
        }
    }

    func searchMessagesCount(query: String) async throws -> Int {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return 0 }
        let modelContext = ModelContext(modelContainer)
        let predicate = buildSearchPredicate(query: trimmed, cursor: nil)
        return try modelContext.fetchCount(FetchDescriptor<StoredPushMessage>(predicate: predicate))
    }

    func searchMessagesPage(query: String, before cursor: MessagePageCursor?, limit: Int) async throws -> [PushMessage] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let modelContext = ModelContext(modelContainer)
        let predicate = buildSearchPredicate(query: trimmed, cursor: cursor)
        var descriptor = FetchDescriptor<StoredPushMessage>(
            predicate: predicate,
            sortBy: [SortDescriptor(\.receivedAt, order: .reverse)],
        )
        descriptor.fetchLimit = max(0, limit)
        let stored = try modelContext.fetch(descriptor)
        return try stored.map { try $0.toDomain(decoder: decoder) }
    }

    func searchMessageSummariesFallback(
        query: String,
        before cursor: MessagePageCursor?,
        limit: Int,
    ) async throws -> [PushMessageSummary] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let modelContext = ModelContext(modelContainer)
        let predicate = buildSearchPredicate(query: trimmed, cursor: cursor)
        var descriptor = FetchDescriptor<StoredPushMessage>(
            predicate: predicate,
            sortBy: [SortDescriptor(\.receivedAt, order: .reverse)],
        )
        descriptor.fetchLimit = max(0, limit)
        let stored = try modelContext.fetch(descriptor)
        let summaries = stored.map { $0.toSummary() }
        if modelContext.hasChanges {
            try modelContext.save()
        }
        return summaries
    }

    func saveMessages(_ messages: [PushMessage]) async throws {
        try await deleteAllMessages()
        guard !messages.isEmpty else { return }

        let modelContext = ModelContext(modelContainer)
        let batchSize = 500
        var index = 0
        while index < messages.count {
            let upper = min(messages.count, index + batchSize)
            let slice = messages[index..<upper]
            for message in slice {
                try modelContext.insert(StoredPushMessage(from: message, encoder: encoder))
            }
            if modelContext.hasChanges {
                try modelContext.save()
            }
            index = upper
        }

        _ = try rebuildStats(modelContext)

        if modelContext.hasChanges {
            try modelContext.save()
        }
    }

    func setMessageReadState(id: UUID, isRead: Bool) async throws {
        let modelContext = ModelContext(modelContainer)
        try setMessageReadState(id: id, isRead: isRead, in: modelContext)
    }

    fileprivate func setMessageReadState(
        id: UUID,
        isRead: Bool,
        in modelContext: ModelContext
    ) throws {
        let descriptor = FetchDescriptor<StoredPushMessage>(predicate: #Predicate { $0.id == id })
        guard let stored = try modelContext.fetch(descriptor).first else { return }
        let snapshot = StoredMessageSnapshot(
            channelKey: normalizeChannelKey(stored.channel),
            isRead: stored.isRead,
            receivedAt: stored.receivedAt
        )
        stored.isRead = isRead
        try updateStatsForReadChange(
            snapshot: snapshot,
            newIsRead: isRead,
            modelContext: modelContext
        )
        if modelContext.hasChanges {
            try modelContext.save()
        }
    }

    func markMessagesRead(
        filter: MessageQueryFilter,
        channel: String?
    ) async throws -> Int {
        let modelContext = ModelContext(modelContainer)
        let batchSize = 500
        var changed = 0
        var touchedChannels = Set<String>()

        while true {
            var descriptor = FetchDescriptor<StoredPushMessage>(
                predicate: buildUnreadMessagesPredicate(filter: filter, channel: channel),
                sortBy: [SortDescriptor(\.receivedAt, order: .forward)],
            )
            descriptor.fetchLimit = batchSize
            let matches = try modelContext.fetch(descriptor)
            guard !matches.isEmpty else { break }

            for stored in matches {
                stored.isRead = true
                changed += 1
                touchedChannels.insert(normalizeChannelKey(stored.channel))
            }

            if modelContext.hasChanges {
                try modelContext.save()
            }
        }

        guard changed > 0 else { return 0 }
        let statsContext = ModelContext(modelContainer)
        try updateStatsForBulkReadChange(
            readCount: changed,
            channelKeys: touchedChannels,
            modelContext: statsContext
        )
        if statsContext.hasChanges {
            try statsContext.save()
        }
        return changed
    }

    func deleteMessage(id: UUID) async throws {
        let modelContext = ModelContext(modelContainer)
        try deleteMessage(id: id, in: modelContext)
    }

    fileprivate func deleteMessage(id: UUID, in modelContext: ModelContext) throws {
        let descriptor = FetchDescriptor<StoredPushMessage>(predicate: #Predicate { $0.id == id })
        let matches = try modelContext.fetch(descriptor)
        for stored in matches {
            let snapshot = StoredMessageSnapshot(
                channelKey: normalizeChannelKey(stored.channel),
                isRead: stored.isRead,
                receivedAt: stored.receivedAt
            )
            modelContext.delete(stored)
            try updateStatsForDelete(snapshot: snapshot, modelContext: modelContext)
        }
        if modelContext.hasChanges {
            try modelContext.save()
        }
    }

    func deleteMessage(notificationRequestId: String) async throws {
        let modelContext = ModelContext(modelContainer)
        try deleteMessage(notificationRequestId: notificationRequestId, in: modelContext)
    }

    fileprivate func deleteMessage(
        notificationRequestId: String,
        in modelContext: ModelContext
    ) throws {
        let descriptor = FetchDescriptor<StoredPushMessage>(
            predicate: #Predicate { $0.notificationRequestId == notificationRequestId },
        )
        let matches = try modelContext.fetch(descriptor)
        for stored in matches {
            let snapshot = StoredMessageSnapshot(
                channelKey: normalizeChannelKey(stored.channel),
                isRead: stored.isRead,
                receivedAt: stored.receivedAt
            )
            modelContext.delete(stored)
            try updateStatsForDelete(snapshot: snapshot, modelContext: modelContext)
        }
        if modelContext.hasChanges {
            try modelContext.save()
        }
    }

    func deleteAllMessages() async throws {
        let modelContext = ModelContext(modelContainer)
        let batchSize = 500
        while true {
            var descriptor = FetchDescriptor<StoredPushMessage>(
                sortBy: [SortDescriptor(\.receivedAt, order: .forward)]
            )
            descriptor.fetchLimit = batchSize
            let existing = try modelContext.fetch(descriptor)
            guard !existing.isEmpty else { break }
            existing.forEach { modelContext.delete($0) }
            if modelContext.hasChanges {
                try modelContext.save()
            }
        }
        let stats = try modelContext.fetch(FetchDescriptor<StoredMessageStats>())
        stats.forEach { modelContext.delete($0) }
        let groups = try modelContext.fetch(FetchDescriptor<StoredMessageChannelStats>())
        groups.forEach { modelContext.delete($0) }
        if modelContext.hasChanges {
            try modelContext.save()
        }
    }

    func deleteMessages(
        readState: Bool?,
        before cutoff: Date?
    ) async throws -> [UUID] {
        let modelContext = ModelContext(modelContainer)
        let batchSize = 500
        var deletedIds: [UUID] = []
        var removedTotal = 0
        var removedUnread = 0
        var touchedChannels = Set<String>()

        while true {
            var descriptor = FetchDescriptor<StoredPushMessage>(
                predicate: buildDeletePredicate(readState: readState, before: cutoff),
                sortBy: [SortDescriptor(\.receivedAt, order: .forward)]
            )
            descriptor.fetchLimit = batchSize
            let matches = try modelContext.fetch(descriptor)
            guard !matches.isEmpty else { break }

            for stored in matches {
                deletedIds.append(stored.id)
                removedTotal += 1
                if !stored.isRead {
                    removedUnread += 1
                }
                touchedChannels.insert(normalizeChannelKey(stored.channel))
                modelContext.delete(stored)
            }

            if modelContext.hasChanges {
                try modelContext.save()
            }
        }

        guard !deletedIds.isEmpty else { return [] }
        let statsContext = ModelContext(modelContainer)
        try updateStatsForBulkDelete(
            totalRemoved: removedTotal,
            unreadRemoved: removedUnread,
            channelKeys: touchedChannels,
            modelContext: statsContext
        )
        if statsContext.hasChanges {
            try statsContext.save()
        }
        return deletedIds
    }

    func deleteMessages(channel: String) async throws -> [UUID] {
        let modelContext = ModelContext(modelContainer)
        let batchSize = 500
        var deletedIds: [UUID] = []
        var removedTotal = 0
        var removedUnread = 0
        var touchedChannels = Set<String>()

        while true {
            var descriptor = FetchDescriptor<StoredPushMessage>(
                predicate: #Predicate { $0.channel == channel },
                sortBy: [SortDescriptor(\.receivedAt, order: .forward)]
            )
            descriptor.fetchLimit = batchSize
            let matches = try modelContext.fetch(descriptor)
            guard !matches.isEmpty else { break }

            for stored in matches {
                deletedIds.append(stored.id)
                removedTotal += 1
                if !stored.isRead {
                    removedUnread += 1
                }
                touchedChannels.insert(normalizeChannelKey(stored.channel))
                modelContext.delete(stored)
            }

            if modelContext.hasChanges {
                try modelContext.save()
            }
        }

        guard !deletedIds.isEmpty else { return [] }
        let statsContext = ModelContext(modelContainer)
        try updateStatsForBulkDelete(
            totalRemoved: removedTotal,
            unreadRemoved: removedUnread,
            channelKeys: touchedChannels,
            modelContext: statsContext
        )
        if statsContext.hasChanges {
            try statsContext.save()
        }
        return deletedIds
    }

    func deleteMessages(channel: String?, readState: Bool?) async throws -> [UUID] {
        let modelContext = ModelContext(modelContainer)
        let batchSize = 500
        var deletedIds: [UUID] = []
        var removedTotal = 0
        var removedUnread = 0
        var touchedChannels = Set<String>()

        while true {
            var descriptor = FetchDescriptor<StoredPushMessage>(
                predicate: buildDeletePredicate(channel: channel, readState: readState),
                sortBy: [SortDescriptor(\.receivedAt, order: .forward)]
            )
            descriptor.fetchLimit = batchSize
            let matches = try modelContext.fetch(descriptor)
            guard !matches.isEmpty else { break }

            for stored in matches {
                deletedIds.append(stored.id)
                removedTotal += 1
                if !stored.isRead {
                    removedUnread += 1
                }
                touchedChannels.insert(normalizeChannelKey(stored.channel))
                modelContext.delete(stored)
            }

            if modelContext.hasChanges {
                try modelContext.save()
            }
        }

        guard !deletedIds.isEmpty else { return [] }
        let statsContext = ModelContext(modelContainer)
        try updateStatsForBulkDelete(
            totalRemoved: removedTotal,
            unreadRemoved: removedUnread,
            channelKeys: touchedChannels,
            modelContext: statsContext
        )
        if statsContext.hasChanges {
            try statsContext.save()
        }
        return deletedIds
    }

    func loadOldestReadMessages(
        limit: Int,
        excludingChannels: [String]
    ) async throws -> [PushMessage] {
        let modelContext = ModelContext(modelContainer)
        let trimmedExclusions = excludingChannels
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let predicate: Predicate<StoredPushMessage>
        if trimmedExclusions.isEmpty {
            predicate = #Predicate { $0.isRead }
        } else {
            predicate = #Predicate { $0.isRead && !trimmedExclusions.contains($0.channel ?? "") }
        }
        var descriptor = FetchDescriptor<StoredPushMessage>(
            predicate: predicate,
            sortBy: [SortDescriptor(\.receivedAt, order: .forward)]
        )
        descriptor.fetchLimit = limit
        let matches = try modelContext.fetch(descriptor)
        guard !matches.isEmpty else { return [] }
        return try matches.map { try $0.toDomain(decoder: decoder) }
    }

    func deleteOldestReadMessages(
        limit: Int,
        excludingChannels: [String]
    ) async throws -> [UUID] {
        let modelContext = ModelContext(modelContainer)
        let trimmedExclusions = excludingChannels
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let predicate: Predicate<StoredPushMessage>
        if trimmedExclusions.isEmpty {
            predicate = #Predicate { $0.isRead }
        } else {
            predicate = #Predicate { $0.isRead && !trimmedExclusions.contains($0.channel ?? "") }
        }
        var descriptor = FetchDescriptor<StoredPushMessage>(
            predicate: predicate,
            sortBy: [SortDescriptor(\.receivedAt, order: .forward)]
        )
        descriptor.fetchLimit = limit
        let matches = try modelContext.fetch(descriptor)
        guard !matches.isEmpty else { return [] }

        var deletedIds: [UUID] = []
        deletedIds.reserveCapacity(matches.count)
        var removedTotal = 0
        var removedUnread = 0
        var touchedChannels = Set<String>()

        for stored in matches {
            deletedIds.append(stored.id)
            removedTotal += 1
            if !stored.isRead {
                removedUnread += 1
            }
            touchedChannels.insert(normalizeChannelKey(stored.channel))
            modelContext.delete(stored)
        }

        if modelContext.hasChanges {
            try modelContext.save()
        }

        let statsContext = ModelContext(modelContainer)
        try updateStatsForBulkDelete(
            totalRemoved: removedTotal,
            unreadRemoved: removedUnread,
            channelKeys: touchedChannels,
            modelContext: statsContext
        )
        if statsContext.hasChanges {
            try statsContext.save()
        }
        return deletedIds
    }

    func loadPruneCandidates(
        maxCount: Int,
        batchSize: Int
    ) async throws -> [PushMessage] {
        let modelContext = ModelContext(modelContainer)
        let total = try modelContext.fetchCount(FetchDescriptor<StoredPushMessage>())
        let overflow = total - maxCount
        guard overflow > 0 else { return [] }

        var descriptor = FetchDescriptor<StoredPushMessage>(
            sortBy: [SortDescriptor(\.receivedAt, order: .forward)]
        )
        descriptor.fetchLimit = min(overflow, batchSize)
        let matches = try modelContext.fetch(descriptor)
        guard !matches.isEmpty else { return [] }
        return try matches.map { try $0.toDomain(decoder: decoder) }
    }

    func pruneMessagesIfNeeded(
        maxCount: Int,
        batchSize: Int
    ) async throws -> [UUID] {
        let modelContext = ModelContext(modelContainer)
        let total = try modelContext.fetchCount(FetchDescriptor<StoredPushMessage>())
        let overflow = total - maxCount
        guard overflow > 0 else { return [] }

        var descriptor = FetchDescriptor<StoredPushMessage>(
            sortBy: [SortDescriptor(\.receivedAt, order: .forward)]
        )
        descriptor.fetchLimit = min(overflow, batchSize)
        let toDelete = try modelContext.fetch(descriptor)
        guard !toDelete.isEmpty else { return [] }

        var deletedIds: [UUID] = []
        deletedIds.reserveCapacity(toDelete.count)

        for stored in toDelete {
            let snapshot = StoredMessageSnapshot(
                channelKey: normalizeChannelKey(stored.channel),
                isRead: stored.isRead,
                receivedAt: stored.receivedAt
            )
            deletedIds.append(stored.id)
            modelContext.delete(stored)
            try updateStatsForDelete(snapshot: snapshot, modelContext: modelContext)
        }

        if modelContext.hasChanges {
            try modelContext.save()
        }

        return deletedIds
    }

    private struct StoredMessageSnapshot {
        let channelKey: String
        let isRead: Bool
        let receivedAt: Date
    }

    private struct StatsPreparation {
        let stats: StoredMessageStats
        let didRebuild: Bool
    }

    private struct StatsSample {
        let channel: String?
        let isRead: Bool
        let receivedAt: Date
    }

    private struct ChannelAccumulator {
        var totalCount: Int = 0
        var unreadCount: Int = 0
        var latestReceivedAt: Date?
        var latestUnreadAt: Date?
    }

    private func fetchStoredMessagesPage(
        modelContext: ModelContext? = nil,
        before cursor: MessagePageCursor?,
        limit: Int,
    ) throws -> [StoredPushMessage] {
        let context = modelContext ?? ModelContext(modelContainer)
        let cutoff = cursor?.receivedAt ?? Date.distantFuture
        var descriptor = FetchDescriptor<StoredPushMessage>(
            predicate: #Predicate { $0.receivedAt < cutoff },
            sortBy: [SortDescriptor(\.receivedAt, order: .reverse)],
        )
        descriptor.fetchLimit = max(0, limit)
        return try context.fetch(descriptor)
    }

    private func buildMessagesPagePredicate(
        cursor: MessagePageCursor?,
        filter: MessageQueryFilter,
        channel: String?,
    ) -> Predicate<StoredPushMessage> {
        let cutoff = cursor?.receivedAt ?? Date.distantFuture
        enum ChannelFilter {
            case none
            case ungrouped
            case named(String)
        }

        let channelFilter: ChannelFilter = {
            guard let channel else { return .none }
            let trimmed = channel.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? .ungrouped : .named(trimmed)
        }()

        switch (filter, channelFilter) {
        case (.all, .none):
            return #Predicate<StoredPushMessage> { $0.receivedAt < cutoff }
        case (.all, .ungrouped):
            return #Predicate<StoredPushMessage> { $0.receivedAt < cutoff && ($0.channel == nil || $0.channel == "") }
        case let (.all, .named(channelId)):
            return #Predicate<StoredPushMessage> { $0.receivedAt < cutoff && $0.channel == channelId }
        case (.unreadOnly, .none):
            return #Predicate<StoredPushMessage> { $0.receivedAt < cutoff && !$0.isRead }
        case (.unreadOnly, .ungrouped):
            return #Predicate<StoredPushMessage> { $0.receivedAt < cutoff && !$0.isRead && ($0.channel == nil || $0.channel == "") }
        case let (.unreadOnly, .named(channelId)):
            return #Predicate<StoredPushMessage> { $0.receivedAt < cutoff && !$0.isRead && $0.channel == channelId }
        case (.readOnly, .none):
            return #Predicate<StoredPushMessage> { $0.receivedAt < cutoff && $0.isRead }
        case (.readOnly, .ungrouped):
            return #Predicate<StoredPushMessage> { $0.receivedAt < cutoff && $0.isRead && ($0.channel == nil || $0.channel == "") }
        case let (.readOnly, .named(channelId)):
            return #Predicate<StoredPushMessage> { $0.receivedAt < cutoff && $0.isRead && $0.channel == channelId }
        case (.withURLOnly, .none):
            return #Predicate<StoredPushMessage> { $0.receivedAt < cutoff && $0.url != nil }
        case (.withURLOnly, .ungrouped):
            return #Predicate<StoredPushMessage> { $0.receivedAt < cutoff && $0.url != nil && ($0.channel == nil || $0.channel == "") }
        case let (.withURLOnly, .named(channelId)):
            return #Predicate<StoredPushMessage> { $0.receivedAt < cutoff && $0.url != nil && $0.channel == channelId }
        case let (.byServer(messageId), .none):
            return #Predicate<StoredPushMessage> { $0.receivedAt < cutoff && $0.messageId == messageId }
        case let (.byServer(messageId), .ungrouped):
            return #Predicate<StoredPushMessage> { $0.receivedAt < cutoff && $0.messageId == messageId && ($0.channel == nil || $0.channel == "") }
        case let (.byServer(messageId), .named(channelId)):
            return #Predicate<StoredPushMessage> { $0.receivedAt < cutoff && $0.messageId == messageId && $0.channel == channelId }
        }
    }

    private func buildSearchPredicate(
        query: String,
        cursor: MessagePageCursor?,
    ) -> Predicate<StoredPushMessage> {
        let cutoff = cursor?.receivedAt ?? Date.distantFuture
        return #Predicate<StoredPushMessage> { message in
            message.receivedAt < cutoff &&
                (message.title.localizedStandardContains(query) ||
                    message.resolvedBodyText.localizedStandardContains(query) ||
                    (message.channel?.localizedStandardContains(query) == true))
        }
    }

    private func buildUnreadMessagesPredicate(
        filter: MessageQueryFilter,
        channel: String?
    ) -> Predicate<StoredPushMessage> {
        enum ChannelFilter {
            case none
            case ungrouped
            case named(String)
        }

        let channelFilter: ChannelFilter = {
            guard let channel else { return .none }
            let trimmed = channel.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? .ungrouped : .named(trimmed)
        }()

        switch (filter, channelFilter) {
        case (.all, .none):
            return #Predicate<StoredPushMessage> { !$0.isRead }
        case (.all, .ungrouped):
            return #Predicate<StoredPushMessage> { !$0.isRead && ($0.channel == nil || $0.channel == "") }
        case let (.all, .named(channelId)):
            return #Predicate<StoredPushMessage> { !$0.isRead && $0.channel == channelId }
        case (.unreadOnly, .none):
            return #Predicate<StoredPushMessage> { !$0.isRead }
        case (.unreadOnly, .ungrouped):
            return #Predicate<StoredPushMessage> { !$0.isRead && ($0.channel == nil || $0.channel == "") }
        case let (.unreadOnly, .named(channelId)):
            return #Predicate<StoredPushMessage> { !$0.isRead && $0.channel == channelId }
        case (.readOnly, .none):
            return #Predicate<StoredPushMessage> { _ in false }
        case (.readOnly, .ungrouped):
            return #Predicate<StoredPushMessage> { _ in false }
        case (.readOnly, .named(_)):
            return #Predicate<StoredPushMessage> { _ in false }
        case (.withURLOnly, .none):
            return #Predicate<StoredPushMessage> { !$0.isRead && $0.url != nil }
        case (.withURLOnly, .ungrouped):
            return #Predicate<StoredPushMessage> { !$0.isRead && $0.url != nil && ($0.channel == nil || $0.channel == "") }
        case let (.withURLOnly, .named(channelId)):
            return #Predicate<StoredPushMessage> { !$0.isRead && $0.url != nil && $0.channel == channelId }
        case let (.byServer(messageId), .none):
            return #Predicate<StoredPushMessage> { !$0.isRead && $0.messageId == messageId }
        case let (.byServer(messageId), .ungrouped):
            return #Predicate<StoredPushMessage> {
                !$0.isRead && $0.messageId == messageId && ($0.channel == nil || $0.channel == "")
            }
        case let (.byServer(messageId), .named(channelId)):
            return #Predicate<StoredPushMessage> { !$0.isRead && $0.messageId == messageId && $0.channel == channelId }
        }
    }

    private func buildDeletePredicate(
        readState: Bool?,
        before cutoff: Date?
    ) -> Predicate<StoredPushMessage>? {
        switch (readState, cutoff) {
        case (nil, nil):
            return nil
        case let (state?, nil):
            return #Predicate<StoredPushMessage> { $0.isRead == state }
        case (nil, let date?):
            return #Predicate<StoredPushMessage> { $0.receivedAt < date }
        case let (state?, date?):
            return #Predicate<StoredPushMessage> { $0.isRead == state && $0.receivedAt < date }
        }
    }

    private func buildDeletePredicate(
        channel: String?,
        readState: Bool?
    ) -> Predicate<StoredPushMessage>? {
        let trimmed = channel?.trimmingCharacters(in: .whitespacesAndNewlines)
        switch (trimmed, readState) {
        case (nil, nil):
            return nil
        case let (value?, nil) where value.isEmpty:
            return #Predicate<StoredPushMessage> { $0.channel == nil || $0.channel == "" }
        case let (value?, nil):
            return #Predicate<StoredPushMessage> { $0.channel == value }
        case (nil, let state?):
            return #Predicate<StoredPushMessage> { $0.isRead == state }
        case let (value?, state?) where value.isEmpty:
            return #Predicate<StoredPushMessage> { $0.isRead == state && ($0.channel == nil || $0.channel == "") }
        case let (value?, state?):
            return #Predicate<StoredPushMessage> { $0.isRead == state && $0.channel == value }
        }
    }

    private func normalizeChannelKey(_ channel: String?) -> String {
        (channel ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func ensureStatsReady(_ modelContext: ModelContext) throws -> StatsPreparation {
        if let stats = try modelContext.fetch(FetchDescriptor<StoredMessageStats>()).first {
            return StatsPreparation(stats: stats, didRebuild: false)
        }
        let total = try modelContext.fetchCount(FetchDescriptor<StoredPushMessage>())
        if total == 0 {
            let stats = StoredMessageStats(totalCount: 0, unreadCount: 0)
            modelContext.insert(stats)
            return StatsPreparation(stats: stats, didRebuild: false)
        }
        let rebuilt = try rebuildStats(modelContext)
        return StatsPreparation(stats: rebuilt, didRebuild: true)
    }

    private func rebuildStats(_ modelContext: ModelContext) throws -> StoredMessageStats {
        let pageSize = 1000
        var cursor: MessagePageCursor?
        var accumulators: [String: ChannelAccumulator] = [:]
        var hasMore = true
        var total = 0
        var unread = 0

        while hasMore {
            let page = try fetchStoredMessagesPage(
                modelContext: modelContext,
                before: cursor,
                limit: pageSize
            )
            if page.isEmpty { break }
            for message in page {
                total += 1
                if !message.isRead {
                    unread += 1
                }
                let channelKey = normalizeChannelKey(message.channel)
                var stats = accumulators[channelKey] ?? ChannelAccumulator()
                stats.totalCount += 1
                if !message.isRead {
                    stats.unreadCount += 1
                }
                if let latest = stats.latestReceivedAt {
                    if message.receivedAt > latest { stats.latestReceivedAt = message.receivedAt }
                } else {
                    stats.latestReceivedAt = message.receivedAt
                }
                if !message.isRead {
                    if let latestUnread = stats.latestUnreadAt {
                        if message.receivedAt > latestUnread { stats.latestUnreadAt = message.receivedAt }
                    } else {
                        stats.latestUnreadAt = message.receivedAt
                    }
                }
                accumulators[channelKey] = stats
            }
            cursor = page.last.map { MessagePageCursor(receivedAt: $0.receivedAt) }
            hasMore = page.count == pageSize
        }

        let existingStats = try modelContext.fetch(FetchDescriptor<StoredMessageStats>())
        existingStats.forEach { modelContext.delete($0) }
        let existingGroups = try modelContext.fetch(FetchDescriptor<StoredMessageChannelStats>())
        existingGroups.forEach { modelContext.delete($0) }

        let stats = StoredMessageStats(totalCount: total, unreadCount: unread)
        modelContext.insert(stats)
        for (channelKey, channelStats) in accumulators where channelStats.totalCount > 0 {
            modelContext.insert(
                StoredMessageChannelStats(
                    channelKey: channelKey,
                    totalCount: channelStats.totalCount,
                    unreadCount: channelStats.unreadCount,
                    latestReceivedAt: channelStats.latestReceivedAt,
                    latestUnreadAt: channelStats.latestUnreadAt
                )
            )
        }
        return stats
    }

    private func rebuildStatsProgressively(
        pageSize: Int
    ) async throws -> StoredMessageStats {
        var cursor: MessagePageCursor?
        var accumulators: [String: ChannelAccumulator] = [:]
        var hasMore = true
        var total = 0
        var unread = 0

        while hasMore {
            let page = try fetchStatsSamplesPage(before: cursor, limit: pageSize)
            if page.isEmpty { break }
            for message in page {
                total += 1
                if !message.isRead {
                    unread += 1
                }
                let channelKey = normalizeChannelKey(message.channel)
                var stats = accumulators[channelKey] ?? ChannelAccumulator()
                stats.totalCount += 1
                if !message.isRead {
                    stats.unreadCount += 1
                }
                if let latest = stats.latestReceivedAt {
                    if message.receivedAt > latest { stats.latestReceivedAt = message.receivedAt }
                } else {
                    stats.latestReceivedAt = message.receivedAt
                }
                if !message.isRead {
                    if let latestUnread = stats.latestUnreadAt {
                        if message.receivedAt > latestUnread { stats.latestUnreadAt = message.receivedAt }
                    } else {
                        stats.latestUnreadAt = message.receivedAt
                    }
                }
                accumulators[channelKey] = stats
            }
            cursor = page.last.map { MessagePageCursor(receivedAt: $0.receivedAt) }
            hasMore = page.count == pageSize
            if Task.isCancelled {
                throw CancellationError()
            }
            await Task.yield()
        }

        return try persistStats(accumulators: accumulators, total: total, unread: unread)
    }

    private func fetchStatsSamplesPage(
        before cursor: MessagePageCursor?,
        limit: Int
    ) throws -> [StatsSample] {
        let modelContext = ModelContext(modelContainer)
        let cutoff = cursor?.receivedAt ?? Date.distantFuture
        var descriptor = FetchDescriptor<StoredPushMessage>(
            predicate: #Predicate { $0.receivedAt < cutoff },
            sortBy: [SortDescriptor(\.receivedAt, order: .reverse)],
        )
        descriptor.fetchLimit = max(0, limit)
        let stored = try modelContext.fetch(descriptor)
        return stored.map { message in
            StatsSample(
                channel: message.channel,
                isRead: message.isRead,
                receivedAt: message.receivedAt
            )
        }
    }

    private func persistStats(
        accumulators: [String: ChannelAccumulator],
        total: Int,
        unread: Int
    ) throws -> StoredMessageStats {
        let modelContext = ModelContext(modelContainer)
        let existingStats = try modelContext.fetch(FetchDescriptor<StoredMessageStats>())
        existingStats.forEach { modelContext.delete($0) }
        let existingGroups = try modelContext.fetch(FetchDescriptor<StoredMessageChannelStats>())
        existingGroups.forEach { modelContext.delete($0) }

        let stats = StoredMessageStats(totalCount: total, unreadCount: unread)
        modelContext.insert(stats)
        for (channelKey, channelStats) in accumulators where channelStats.totalCount > 0 {
            modelContext.insert(
                StoredMessageChannelStats(
                    channelKey: channelKey,
                    totalCount: channelStats.totalCount,
                    unreadCount: channelStats.unreadCount,
                    latestReceivedAt: channelStats.latestReceivedAt,
                    latestUnreadAt: channelStats.latestUnreadAt
                )
            )
        }
        if modelContext.hasChanges {
            try modelContext.save()
        }
        return stats
    }

    private func updateStatsForInsert(
        message: PushMessage,
        modelContext: ModelContext,
    ) throws {
        let preparation = try ensureStatsReady(modelContext)
        if preparation.didRebuild { return }
        let stats = preparation.stats
        stats.totalCount += 1
        if !message.isRead {
            stats.unreadCount += 1
        }
        stats.updatedAt = Date()

        let channelKey = normalizeChannelKey(message.channel)
        if let channelStats = try fetchChannelStats(modelContext, channelKey: channelKey) {
            channelStats.totalCount += 1
            if !message.isRead {
                channelStats.unreadCount += 1
            }
            if let latest = channelStats.latestReceivedAt {
                if message.receivedAt > latest { channelStats.latestReceivedAt = message.receivedAt }
            } else {
                channelStats.latestReceivedAt = message.receivedAt
            }
            if !message.isRead {
                if let latestUnread = channelStats.latestUnreadAt {
                    if message.receivedAt > latestUnread { channelStats.latestUnreadAt = message.receivedAt }
                } else {
                    channelStats.latestUnreadAt = message.receivedAt
                }
            }
        } else {
            modelContext.insert(
                StoredMessageChannelStats(
                    channelKey: channelKey,
                    totalCount: 1,
                    unreadCount: message.isRead ? 0 : 1,
                    latestReceivedAt: message.receivedAt,
                    latestUnreadAt: message.isRead ? nil : message.receivedAt
                )
            )
        }
    }

    private func updateStatsForUpdate(
        snapshot: StoredMessageSnapshot,
        newMessage: PushMessage,
        modelContext: ModelContext,
    ) throws {
        let preparation = try ensureStatsReady(modelContext)
        if preparation.didRebuild { return }
        let stats = preparation.stats
        if snapshot.isRead != newMessage.isRead {
            stats.unreadCount += newMessage.isRead ? -1 : 1
        }
        stats.updatedAt = Date()

        let newChannelKey = normalizeChannelKey(newMessage.channel)
        if snapshot.channelKey != newChannelKey {
            try recalculateChannelStats(modelContext, channelKey: snapshot.channelKey)
            try recalculateChannelStats(modelContext, channelKey: newChannelKey)
        } else if snapshot.isRead != newMessage.isRead || snapshot.receivedAt != newMessage.receivedAt {
            try recalculateChannelStats(modelContext, channelKey: newChannelKey)
        }
    }

    private func updateStatsForReadChange(
        snapshot: StoredMessageSnapshot,
        newIsRead: Bool,
        modelContext: ModelContext,
    ) throws {
        guard snapshot.isRead != newIsRead else { return }
        let preparation = try ensureStatsReady(modelContext)
        if preparation.didRebuild { return }
        let stats = preparation.stats
        stats.unreadCount += newIsRead ? -1 : 1
        stats.updatedAt = Date()

        guard let channelStats = try fetchChannelStats(modelContext, channelKey: snapshot.channelKey) else {
            try recalculateChannelStats(modelContext, channelKey: snapshot.channelKey)
            return
        }

        if newIsRead {
            channelStats.unreadCount = max(0, channelStats.unreadCount - 1)
            if channelStats.unreadCount == 0 {
                channelStats.latestUnreadAt = nil
            } else if channelStats.latestUnreadAt == snapshot.receivedAt {
                let unreadPredicate = channelPredicate(channelKey: snapshot.channelKey, unreadOnly: true)
                channelStats.latestUnreadAt = try latestReceivedAt(modelContext, predicate: unreadPredicate)
            }
        } else {
            channelStats.unreadCount += 1
            if let latestUnread = channelStats.latestUnreadAt {
                if snapshot.receivedAt > latestUnread {
                    channelStats.latestUnreadAt = snapshot.receivedAt
                }
            } else {
                channelStats.latestUnreadAt = snapshot.receivedAt
            }
        }
    }

    private func updateStatsForDelete(
        snapshot: StoredMessageSnapshot,
        modelContext: ModelContext,
    ) throws {
        let preparation = try ensureStatsReady(modelContext)
        if preparation.didRebuild { return }
        let stats = preparation.stats
        stats.totalCount = max(0, stats.totalCount - 1)
        if !snapshot.isRead {
            stats.unreadCount = max(0, stats.unreadCount - 1)
        }
        stats.updatedAt = Date()
        try recalculateChannelStats(modelContext, channelKey: snapshot.channelKey)
    }

    private func updateStatsForBulkReadChange(
        readCount: Int,
        channelKeys: Set<String>,
        modelContext: ModelContext,
    ) throws {
        guard readCount > 0 else { return }
        let preparation = try ensureStatsReady(modelContext)
        if preparation.didRebuild { return }
        let stats = preparation.stats
        stats.unreadCount = max(0, stats.unreadCount - readCount)
        stats.updatedAt = Date()

        for channelKey in channelKeys {
            try recalculateChannelStats(modelContext, channelKey: channelKey)
        }
    }

    private func updateStatsForBulkDelete(
        totalRemoved: Int,
        unreadRemoved: Int,
        channelKeys: Set<String>,
        modelContext: ModelContext,
    ) throws {
        guard totalRemoved > 0 else { return }
        let preparation = try ensureStatsReady(modelContext)
        if preparation.didRebuild { return }
        let stats = preparation.stats
        stats.totalCount = max(0, stats.totalCount - totalRemoved)
        stats.unreadCount = max(0, stats.unreadCount - unreadRemoved)
        stats.updatedAt = Date()

        for channelKey in channelKeys {
            try recalculateChannelStats(modelContext, channelKey: channelKey)
        }
    }

    private func fetchChannelStats(
        _ modelContext: ModelContext,
        channelKey: String,
    ) throws -> StoredMessageChannelStats? {
        let descriptor = FetchDescriptor<StoredMessageChannelStats>(
            predicate: #Predicate { $0.channelKey == channelKey },
        )
        return try modelContext.fetch(descriptor).first
    }

    private func recalculateChannelStats(
        _ modelContext: ModelContext,
        channelKey: String,
    ) throws {
        let predicate = channelPredicate(channelKey: channelKey, unreadOnly: false)
        let total = try modelContext.fetchCount(FetchDescriptor<StoredPushMessage>(predicate: predicate))
        if total == 0 {
            if let existing = try fetchChannelStats(modelContext, channelKey: channelKey) {
                modelContext.delete(existing)
            }
            return
        }
        let unreadPredicate = channelPredicate(channelKey: channelKey, unreadOnly: true)
        let unread = try modelContext.fetchCount(FetchDescriptor<StoredPushMessage>(predicate: unreadPredicate))
        let latestReceivedDate = try latestReceivedAt(
            modelContext,
            predicate: predicate
        )
        let latestUnreadDate = unread > 0
            ? try latestReceivedAt(modelContext, predicate: unreadPredicate)
            : nil

        if let stats = try fetchChannelStats(modelContext, channelKey: channelKey) {
            stats.totalCount = total
            stats.unreadCount = unread
            stats.latestReceivedAt = latestReceivedDate
            stats.latestUnreadAt = latestUnreadDate
        } else {
            modelContext.insert(
                StoredMessageChannelStats(
                    channelKey: channelKey,
                    totalCount: total,
                    unreadCount: unread,
                    latestReceivedAt: latestReceivedDate,
                    latestUnreadAt: latestUnreadDate
                )
            )
        }
    }

    private func channelPredicate(
        channelKey: String,
        unreadOnly: Bool,
    ) -> Predicate<StoredPushMessage> {
        if channelKey.isEmpty {
            if unreadOnly {
                return #Predicate<StoredPushMessage> { !$0.isRead && ($0.channel == nil || $0.channel == "") }
            }
            return #Predicate<StoredPushMessage> { $0.channel == nil || $0.channel == "" }
        }
        if unreadOnly {
            return #Predicate<StoredPushMessage> { !$0.isRead && $0.channel == channelKey }
        }
        return #Predicate<StoredPushMessage> { $0.channel == channelKey }
    }

    private func latestReceivedAt(
        _ modelContext: ModelContext,
        predicate: Predicate<StoredPushMessage>,
    ) throws -> Date? {
        var descriptor = FetchDescriptor<StoredPushMessage>(
            predicate: predicate,
            sortBy: [SortDescriptor(\.receivedAt, order: .reverse)],
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first?.receivedAt
    }

    private static func storeURL(
        fileManager: FileManager,
        appGroupIdentifier: String,
    ) throws -> URL {
        guard let url = fileManager.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier) else {
            throw AppError.missingAppGroup(appGroupIdentifier)
        }
        let directory = url.appendingPathComponent("Database", isDirectory: true)
        if !fileManager.fileExists(atPath: directory.path) {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return directory.appendingPathComponent("pushgo.store")
    }
}
