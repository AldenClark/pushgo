import Foundation
import Observation

enum MessageChannelKey: Hashable, Identifiable {
    case named(String)
    case ungrouped

    var id: String {
        switch self {
        case let .named(value):
            "channel-\(value)"
        case .ungrouped:
            "channel-ungrouped"
        }
    }

    var displayName: String {
        switch self {
        case let .named(value):
            value
        case .ungrouped:
            LocalizationManager.localizedSync("not_grouped")
        }
    }

    static func from(_ rawValue: String?) -> MessageChannelKey {
        let trimmed = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return .ungrouped }
        return .named(trimmed)
    }
}

struct MessageChannelSummary: Identifiable, Hashable {
    let key: MessageChannelKey
    let totalCount: Int
    let unreadCount: Int
    let latestReceivedAt: Date?
    let latestUnreadAt: Date?

    var id: String { key.id }
    var title: String { key.displayName }

    var hasUnread: Bool { unreadCount > 0 }
}

@MainActor
@Observable
final class MessageListViewModel {
    private struct ReloadRequest {
        let resetPaging: Bool
        let clearBeforeLoading: Bool
        let reconcileUnreadSession: Bool

        func merged(with other: ReloadRequest) -> ReloadRequest {
            ReloadRequest(
                resetPaging: resetPaging || other.resetPaging,
                clearBeforeLoading: clearBeforeLoading || other.clearBeforeLoading,
                reconcileUnreadSession: reconcileUnreadSession || other.reconcileUnreadSession
            )
        }
    }

    private(set) var filteredMessagesIdentityRevision: UInt64 = 0
    private(set) var filteredMessages: [PushMessageSummary] = [] {
        didSet {
            guard messageIDsChanged(from: oldValue, to: filteredMessages) else { return }
            filteredMessagesIdentityRevision &+= 1
        }
    }
    private(set) var sortMode: MessageListSortMode = MessageListSortMode.loadPreference()
    private(set) var selectedFilter: MessageFilter = .all
    private(set) var selectedChannel: MessageChannelKey?
    private(set) var selectedTag: String?
    private(set) var channelSummaries: [MessageChannelSummary] = []
    private(set) var hasLoadedOnce: Bool = false
    private(set) var totalMessageCount: Int = 0
    private(set) var unreadMessageCount: Int = 0
    private(set) var unreadSessionRetainedReadCount: Int = 0
    private(set) var hasMorePages: Bool = false
    private(set) var isLoadingPage: Bool = false
    var error: AppError?

    private let environment: AppEnvironment
    private let dataStore: LocalDataStore
    private let pageSize: Int = 50
    private let maxCachedMessages: Int = {
        #if os(watchOS)
        return 500
        #else
        return 400
        #endif
    }()
    private var nextCursor: MessagePageCursor?
    private var channelOrderById: [String: Int] = [:]
    @ObservationIgnored private var shouldLoadChannelSummaries = false
    @ObservationIgnored private var isRefreshingCountsAndChannels = false
    @ObservationIgnored private var pendingCountsAndChannels = false
    @ObservationIgnored private var reloadTask: Task<Void, Never>?
    @ObservationIgnored private var pendingReloadRequest: ReloadRequest?
    @ObservationIgnored private var unreadFilterSession: UnreadFilterSessionState?

    private struct RefreshSnapshot {
        let messages: [PushMessageSummary]
        let nextCursor: MessagePageCursor?
        let hasMorePages: Bool
    }

    init(environment: AppEnvironment? = nil) {
        if let environment {
            self.environment = environment
        } else {
            self.environment = AppEnvironment.shared
        }
        dataStore = self.environment.dataStore
    }

    func loadMessages() async {
        await enqueueReload(resetPaging: true, clearBeforeLoading: false, reconcileUnreadSession: false)
    }

    func refresh() async {
        await enqueueReload(resetPaging: true, clearBeforeLoading: false, reconcileUnreadSession: false)
    }

    func reconcileUnreadFilterSession() async {
        guard isUnreadOnlyFilterActive else {
            await refresh()
            return
        }
        await enqueueReload(resetPaging: true, clearBeforeLoading: false, reconcileUnreadSession: true)
    }

    func enableChannelSummaries() {
        guard shouldLoadChannelSummaries == false else { return }
        shouldLoadChannelSummaries = true
        Task { @MainActor in
            await refreshCountsAndChannels()
        }
    }

    func setFilter(_ filter: MessageFilter) {
        guard selectedFilter != filter else { return }
        selectedFilter = filter
        resetUnreadFilterSessionIfNeeded(for: filter)
        Task { @MainActor in
            await enqueueReload(resetPaging: true, clearBeforeLoading: false, reconcileUnreadSession: false)
        }
    }

    func setSortMode(_ sortMode: MessageListSortMode) {
        guard self.sortMode != sortMode else { return }
        self.sortMode = sortMode
        sortMode.persist()
        Task { @MainActor in
            await enqueueReload(resetPaging: true, clearBeforeLoading: false, reconcileUnreadSession: false)
        }
    }

    func toggleChannelSelection(_ key: MessageChannelKey) {
        if selectedChannel == key {
            selectedChannel = nil
        } else {
            selectedChannel = key
        }
        Task { @MainActor in
            await enqueueReload(resetPaging: true, clearBeforeLoading: false, reconcileUnreadSession: false)
        }
    }

    func clearChannelSelection() {
        guard selectedChannel != nil else { return }
        selectedChannel = nil
        Task { @MainActor in
            await enqueueReload(resetPaging: true, clearBeforeLoading: false, reconcileUnreadSession: false)
        }
    }

    func toggleTagSelection(_ rawTag: String) {
        guard let normalized = Self.normalizedTag(rawTag) else { return }
        if selectedTag == normalized {
            selectedTag = nil
        } else {
            selectedTag = normalized
        }
        Task { @MainActor in
            await enqueueReload(resetPaging: true, clearBeforeLoading: false, reconcileUnreadSession: false)
        }
    }

    func clearTagSelection() {
        guard selectedTag != nil else { return }
        selectedTag = nil
        Task { @MainActor in
            await enqueueReload(resetPaging: true, clearBeforeLoading: false, reconcileUnreadSession: false)
        }
    }

    var isUnreadOnlyFilterActive: Bool {
        selectedFilter == .unread
    }

    var shouldShowUnreadSessionRefreshHint: Bool {
        isUnreadOnlyFilterActive && unreadSessionRetainedReadCount > 0
    }

    func toggleUnreadOnlyFilter() {
        setFilter(isUnreadOnlyFilterActive ? .all : .unread)
    }

    func markRead(_ message: PushMessageSummary, isRead: Bool) async {
        guard isRead else { return }
        do {
            _ = try await environment.messageStateCoordinator.markRead(messageId: message.id)
            if let index = filteredMessages.firstIndex(where: { $0.id == message.id }) {
                filteredMessages[index].isRead = isRead
                retainUnreadSessionMessageIfNeeded(filteredMessages[index])
            }
            await refreshCountsAndChannels()
        } catch let appError as AppError {
            self.error = appError
        } catch {
            self.error = AppError.wrap(
                error,
                fallbackMessage: LocalizationProvider.localized("operation_failed"),
                code: "message_mark_read_failed"
            )
        }
    }

    func markRead(_ messages: [PushMessageSummary]) async {
        let unreadIDs = Set(messages.lazy.filter { !$0.isRead }.map(\.id))
        guard !unreadIDs.isEmpty else { return }
        do {
            let changed = try await environment.messageStateCoordinator.markRead(messageIds: Array(unreadIDs))
            guard changed > 0 else { return }
            for index in filteredMessages.indices where unreadIDs.contains(filteredMessages[index].id) {
                filteredMessages[index].isRead = true
                retainUnreadSessionMessageIfNeeded(filteredMessages[index])
            }
            await refreshCountsAndChannels()
        } catch let appError as AppError {
            self.error = appError
        } catch {
            self.error = AppError.wrap(
                error,
                fallbackMessage: LocalizationProvider.localized("operation_failed"),
                code: "message_bulk_mark_read_failed"
            )
        }
    }

    func delete(_ message: PushMessageSummary) async {
        do {
            try await environment.messageStateCoordinator.deleteMessage(messageId: message.id)
            filteredMessages.removeAll { $0.id == message.id }
            forgetUnreadSessionMessageIfNeeded(messageId: message.id)
            await refreshCountsAndChannels()
        } catch let appError as AppError {
            self.error = appError
        } catch {
            self.error = AppError.wrap(
                error,
                fallbackMessage: LocalizationProvider.localized("operation_failed"),
                code: "message_delete_failed"
            )
        }
    }

    func messagesForCurrentChannel() -> [PushMessageSummary] {
        filteredMessages
    }

    func currentQueryFilter() -> MessageQueryFilter {
        mapFilter(selectedFilter)
    }

    func currentChannelRawValue() -> String? {
        selectedChannel?.rawChannelValue
    }
    func markCurrentChannelAsRead() async -> Int {
        do {
            let changed = try await environment.messageStateCoordinator.markMessagesRead(
                filter: currentQueryFilter(),
                channel: currentChannelRawValue()
            )
            guard changed > 0 else { return 0 }
            for index in filteredMessages.indices {
                filteredMessages[index].isRead = true
                retainUnreadSessionMessageIfNeeded(filteredMessages[index])
            }
            await refreshCountsAndChannels()
            return changed
        } catch let appError as AppError {
            self.error = appError
        } catch {
            self.error = AppError.wrap(
                error,
                fallbackMessage: LocalizationProvider.localized("operation_failed"),
                code: "message_bulk_mark_read_failed"
            )
        }
        return 0
    }

    enum ChannelCleanupKind {
        case clearAll
        case clearRead

        var readState: Bool? {
            switch self {
            case .clearAll:
                nil
            case .clearRead:
                true
            }
        }
    }

    func cleanupCurrentChannel(kind: ChannelCleanupKind) async -> Int {
        let channel = selectedChannel?.rawChannelValue
        do {
            let deleted = try await environment.messageStateCoordinator.deleteMessages(
                channel: channel,
                readState: kind.readState
            )
            if deleted > 0 {
                await refreshCountsAndChannels()
            }
            return deleted
        } catch let appError as AppError {
            self.error = appError
        } catch {
            self.error = AppError.wrap(
                error,
                fallbackMessage: LocalizationProvider.localized("operation_failed"),
                code: "message_channel_cleanup_failed"
            )
        }
        return 0
    }

    func cleanupReadMessages() async -> Int {
        let channel = selectedChannel?.rawChannelValue
        do {
            let deleted = try await environment.messageStateCoordinator.deleteMessages(
                channel: channel,
                readState: true
            )
            if deleted > 0 {
                await refreshCountsAndChannels()
            }
            return deleted
        } catch let appError as AppError {
            self.error = appError
        } catch {
            self.error = AppError.wrap(
                error,
                fallbackMessage: LocalizationProvider.localized("operation_failed"),
                code: "message_read_cleanup_failed"
            )
        }
        return 0
    }

    func loadMoreIfNeeded(currentItem: PushMessageSummary) async {
        guard hasMorePages, !isLoadingPage else { return }
        guard filteredMessages.last?.id == currentItem.id else { return }
        await loadNextPage()
    }

    private func enqueueReload(
        resetPaging: Bool,
        clearBeforeLoading: Bool,
        reconcileUnreadSession: Bool
    ) async {
        let request = ReloadRequest(
            resetPaging: resetPaging,
            clearBeforeLoading: clearBeforeLoading,
            reconcileUnreadSession: reconcileUnreadSession
        )

        if let reloadTask {
            pendingReloadRequest = mergePendingReloadRequest(with: request)
            await reloadTask.value
            return
        }

        var nextRequest: ReloadRequest? = request
        while let currentRequest = nextRequest {
            pendingReloadRequest = nil
            let task = Task { @MainActor in
                await self.reloadFromStore(
                    resetPaging: currentRequest.resetPaging,
                    clearBeforeLoading: currentRequest.clearBeforeLoading,
                    reconcileUnreadSession: currentRequest.reconcileUnreadSession
                )
            }
            reloadTask = task
            await task.value
            reloadTask = nil
            nextRequest = pendingReloadRequest
        }
    }

    private func mergePendingReloadRequest(with request: ReloadRequest) -> ReloadRequest {
        if let pendingReloadRequest {
            return pendingReloadRequest.merged(with: request)
        }
        return request
    }

    private func reloadFromStore(
        resetPaging: Bool,
        clearBeforeLoading: Bool,
        reconcileUnreadSession: Bool
    ) async {
        if resetPaging {
            if clearBeforeLoading {
                nextCursor = nil
                filteredMessages = []
                hasMorePages = false
            }
            await refreshCountsAndChannels()
            if isUnreadOnlyFilterActive {
                await refreshUnreadFilterSessionSnapshot(
                    reconcile: reconcileUnreadSession || unreadFilterSession == nil
                )
            } else {
                await refreshFirstPagesKeepingListStable()
            }
            hasLoadedOnce = true
            return
        }

        await refreshCountsAndChannels()
        if isUnreadOnlyFilterActive {
            await refreshUnreadFilterSessionSnapshot(reconcile: reconcileUnreadSession)
        } else {
            await loadNextPage()
        }
        hasLoadedOnce = true
    }

    private func refreshUnreadFilterSessionSnapshot(reconcile: Bool) async {
        guard !isLoadingPage else {
            pendingReloadRequest = mergePendingReloadRequest(
                with: ReloadRequest(
                    resetPaging: true,
                    clearBeforeLoading: false,
                    reconcileUnreadSession: reconcile
                )
            )
            return
        }
        isLoadingPage = true
        defer { isLoadingPage = false }

        let targetCount = min(max(pageSize, filteredMessages.count), maxCachedMessages)
        do {
            let snapshot = try await loadRefreshSnapshot(targetCount: targetCount)
            nextCursor = snapshot.nextCursor
            hasMorePages = snapshot.hasMorePages

            if reconcile || unreadFilterSession == nil {
                filteredMessages = snapshot.messages
                unreadFilterSession = UnreadFilterSessionState()
                syncUnreadFilterSessionSummary()
                return
            }

            if let unreadFilterSession {
                filteredMessages = unreadFilterSession.mergedMessages(
                    currentMessages: filteredMessages,
                    liveUnreadMessages: snapshot.messages
                )
            } else {
                filteredMessages = snapshot.messages
            }
            syncUnreadFilterSessionSummary()
        } catch let appError as AppError {
            self.error = appError
        } catch {
            self.error = AppError.wrap(
                error,
                fallbackMessage: LocalizationProvider.localized("operation_failed"),
                code: "message_reload_failed"
            )
        }
    }

    private func refreshFirstPagesKeepingListStable() async {
        guard !isLoadingPage else {
            pendingReloadRequest = mergePendingReloadRequest(
                with: ReloadRequest(
                    resetPaging: true,
                    clearBeforeLoading: false,
                    reconcileUnreadSession: false
                )
            )
            return
        }
        isLoadingPage = true
        defer { isLoadingPage = false }

        let targetCount = min(max(pageSize, filteredMessages.count), maxCachedMessages)
        do {
            let snapshot = try await loadRefreshSnapshot(targetCount: targetCount)
            filteredMessages = snapshot.messages
            nextCursor = snapshot.nextCursor
            hasMorePages = snapshot.hasMorePages
        } catch let appError as AppError {
            self.error = appError
        } catch {
            self.error = AppError.wrap(
                error,
                fallbackMessage: LocalizationProvider.localized("operation_failed"),
                code: "message_snapshot_refresh_failed"
            )
        }
    }

    private func loadRefreshSnapshot(targetCount: Int) async throws -> RefreshSnapshot {
        var results: [PushMessageSummary] = []
        var cursor: MessagePageCursor?
        var lastPageCount = 0

        while results.count < targetCount {
            let page = try await dataStore.loadMessageSummariesPage(
                before: cursor,
                limit: pageSize,
                filter: mapFilter(selectedFilter),
                channel: selectedChannel?.rawChannelValue,
                tag: selectedTag,
                sortMode: sortMode
            )
            lastPageCount = page.count

            if page.isEmpty {
                break
            }

            if results.count + page.count <= targetCount {
                results.append(contentsOf: page)
                cursor = page.last.map {
                    MessagePageCursor(receivedAt: $0.receivedAt, id: $0.id, isRead: $0.isRead)
                }
                if page.count < pageSize {
                    return RefreshSnapshot(messages: results, nextCursor: cursor, hasMorePages: false)
                }
            } else {
                let needed = targetCount - results.count
                results.append(contentsOf: page.prefix(needed))
                cursor = results.last.map {
                    MessagePageCursor(receivedAt: $0.receivedAt, id: $0.id, isRead: $0.isRead)
                }
                return RefreshSnapshot(messages: results, nextCursor: cursor, hasMorePages: true)
            }
        }

        let next = results.last.map {
            MessagePageCursor(receivedAt: $0.receivedAt, id: $0.id, isRead: $0.isRead)
        }
        let mayHaveMore = results.count >= targetCount && lastPageCount == pageSize
        return RefreshSnapshot(messages: results, nextCursor: next, hasMorePages: mayHaveMore)
    }

    private func loadNextPage() async {
        guard !isLoadingPage else { return }
        isLoadingPage = true
        defer { isLoadingPage = false }

        do {
            let page = try await dataStore.loadMessageSummariesPage(
                before: nextCursor,
                limit: pageSize,
                filter: mapFilter(selectedFilter),
                channel: selectedChannel?.rawChannelValue,
                tag: selectedTag,
                sortMode: sortMode
            )
            if resetStaleSelectionIfNeeded() {
                return
            }
            filteredMessages.append(contentsOf: page)
            nextCursor = page.last.map {
                MessagePageCursor(receivedAt: $0.receivedAt, id: $0.id, isRead: $0.isRead)
            }
            hasMorePages = page.count == pageSize
            trimCachedMessagesIfNeeded()
        } catch let appError as AppError {
            self.error = appError
        } catch {
            self.error = AppError.wrap(
                error,
                fallbackMessage: LocalizationProvider.localized("operation_failed"),
                code: "message_page_load_failed"
            )
        }
    }

    private func refreshCounts() async {
        do {
            let counts = try await dataStore.messageCounts()
            totalMessageCount = counts.total
            unreadMessageCount = counts.unread
        } catch {
            totalMessageCount = 0
            unreadMessageCount = 0
        }
    }

    private func refreshCountsAndChannels() async {
        if isRefreshingCountsAndChannels {
            pendingCountsAndChannels = true
            return
        }

        isRefreshingCountsAndChannels = true
        defer { isRefreshingCountsAndChannels = false }

        repeat {
            pendingCountsAndChannels = false
            do {
                let counts = try await dataStore.messageCounts()
                totalMessageCount = counts.total
                unreadMessageCount = counts.unread

                if shouldLoadChannelSummaries {
                    let rawChannels = try await dataStore.messageChannelCounts()
                    channelSummaries = buildChannelSummaries(from: rawChannels)
                    if let selectedChannel, channelSummaries.contains(where: { $0.key == selectedChannel }) == false {
                        self.selectedChannel = nil
                    }
                }
            } catch {
                await refreshCounts()
                channelSummaries = []
            }
        } while pendingCountsAndChannels
    }

    private func trimCachedMessagesIfNeeded() {
        let overflow = filteredMessages.count - maxCachedMessages
        guard overflow > 0 else { return }
#if os(macOS)
        filteredMessages.removeLast(overflow)
        nextCursor = filteredMessages.last.map {
            MessagePageCursor(receivedAt: $0.receivedAt, id: $0.id, isRead: $0.isRead)
        }
#else
        if environment.isMessageListAtTop {
            filteredMessages.removeLast(overflow)
            nextCursor = filteredMessages.last.map {
                MessagePageCursor(receivedAt: $0.receivedAt, id: $0.id, isRead: $0.isRead)
            }
        } else {
            filteredMessages.removeFirst(overflow)
        }
#endif
        hasMorePages = true
    }

    private func buildChannelSummaries(from groups: [MessageChannelCount]) -> [MessageChannelSummary] {
        let summaries = groups.map { item in
            MessageChannelSummary(
                key: MessageChannelKey.from(item.channel),
                totalCount: item.totalCount,
                unreadCount: item.unreadCount,
                latestReceivedAt: item.latestReceivedAt,
                latestUnreadAt: item.latestUnreadAt,
            )
        }

        let previousOrder = channelOrderById
        let now = Date()
        let sorted = summaries.sorted { lhs, rhs in
            let lhsKey = sortKey(for: lhs, now: now)
            let rhsKey = sortKey(for: rhs, now: now)
            if lhsKey != rhsKey {
                return lhsKey > rhsKey
            }

            let lhsRank = previousOrder[lhs.id] ?? .max
            let rhsRank = previousOrder[rhs.id] ?? .max
            if lhsRank != rhsRank {
                return lhsRank < rhsRank
            }

            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }

        channelOrderById = Dictionary(uniqueKeysWithValues: sorted.enumerated().map { ($0.element.id, $0.offset) })
        return sorted
    }

    private struct ChannelSortKey: Equatable, Comparable {
        let unreadPriority: Int
        let recencyBucket: Int
        let unreadBucket: Int
        let totalBucket: Int

        static func < (lhs: ChannelSortKey, rhs: ChannelSortKey) -> Bool {
            if lhs.unreadPriority != rhs.unreadPriority {
                return lhs.unreadPriority < rhs.unreadPriority
            }
            if lhs.recencyBucket != rhs.recencyBucket {
                return lhs.recencyBucket < rhs.recencyBucket
            }
            if lhs.unreadBucket != rhs.unreadBucket {
                return lhs.unreadBucket < rhs.unreadBucket
            }
            if lhs.totalBucket != rhs.totalBucket {
                return lhs.totalBucket < rhs.totalBucket
            }
            return false
        }
    }

    private func sortKey(for summary: MessageChannelSummary, now: Date) -> ChannelSortKey {
        let unreadPriority = summary.hasUnread ? 1 : 0
        let recencyBucket = recencyBucket(for: summary.latestReceivedAt, now: now)
        let unreadBucket = countBucket(summary.unreadCount, thresholds: [1, 3, 6, 10, 20])
        let totalBucket = countBucket(summary.totalCount, thresholds: [5, 10, 20, 50, 100, 200])
        return ChannelSortKey(
            unreadPriority: unreadPriority,
            recencyBucket: recencyBucket,
            unreadBucket: unreadBucket,
            totalBucket: totalBucket
        )
    }

    private func recencyBucket(for date: Date?, now: Date) -> Int {
        guard let date else { return 0 }
        let hours = max(0, now.timeIntervalSince(date) / 3600)
        switch hours {
        case ..<1:
            return 6
        case ..<6:
            return 5
        case ..<24:
            return 4
        case ..<72:
            return 3
        case ..<168:
            return 2
        case ..<336:
            return 1
        default:
            return 0
        }
    }

    private func countBucket(_ count: Int, thresholds: [Int]) -> Int {
        var bucket = 0
        for threshold in thresholds where count >= threshold {
            bucket += 1
        }
        return bucket
    }

    private static func normalizedTag(_ rawTag: String) -> String? {
        let normalized = rawTag.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.isEmpty ? nil : normalized
    }

    private func mapFilter(_ filter: MessageFilter) -> MessageQueryFilter {
        switch filter {
        case .all:
            .all
        case .unread:
            .unreadOnly
        case .read:
            .readOnly
        case .withURL:
            .withURLOnly
        case let .byServer(serverId):
            .byServer(serverId)
        }
    }

    private func resetUnreadFilterSessionIfNeeded(for filter: MessageFilter) {
        if filter == .unread {
            unreadFilterSession = UnreadFilterSessionState()
        } else {
            unreadFilterSession = nil
        }
        syncUnreadFilterSessionSummary()
    }

    private func retainUnreadSessionMessageIfNeeded(_ message: PushMessageSummary) {
        guard isUnreadOnlyFilterActive, message.isRead else { return }
        if unreadFilterSession == nil {
            unreadFilterSession = UnreadFilterSessionState()
        }
        unreadFilterSession?.retain(message)
        syncUnreadFilterSessionSummary()
    }

    private func forgetUnreadSessionMessageIfNeeded(messageId: UUID) {
        unreadFilterSession?.forget(messageId: messageId)
        syncUnreadFilterSessionSummary()
    }

    private func syncUnreadFilterSessionSummary() {
        unreadSessionRetainedReadCount = unreadFilterSession?.retainedReadCount ?? 0
    }

    private func resetStaleSelectionIfNeeded() -> Bool {
        false
    }

    private func messageIDsChanged(
        from previous: [PushMessageSummary],
        to current: [PushMessageSummary]
    ) -> Bool {
        guard previous.count == current.count else { return true }
        for (lhs, rhs) in zip(previous, current) where lhs.id != rhs.id {
            return true
        }
        return false
    }
}

extension MessageChannelKey {
    var rawChannelValue: String? {
        switch self {
        case let .named(value):
            return value
        case .ungrouped:
            return ""
        }
    }
}
