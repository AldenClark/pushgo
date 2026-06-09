import Foundation
import Observation

@MainActor
@Observable
final class MessageSearchViewModel {
    var query: String = ""
    private(set) var sortMode: MessageListSortMode = MessageListSortMode.loadPreference()
    private(set) var displayedResultsIdentityRevision: UInt64 = 0
    private(set) var displayedResults: [PushMessageSummary] = [] {
        didSet {
            guard messageIDsChanged(from: oldValue, to: displayedResults) else { return }
            displayedResultsIdentityRevision &+= 1
        }
    }
    private(set) var totalResults: Int = 0
    private(set) var hasSearched: Bool = false

    private let pageSize: Int = 20
    private let maxCachedResults: Int = 200
    private var nextCursor: MessagePageCursor?
    private var hasMoreResults: Bool = false
    private var isLoading: Bool = false

    private let environment: AppEnvironment
    private let dataStore: LocalDataStore
    private var searchTask: Task<Void, Never>?
    private var debounceTask: Task<Void, Never>?
    private var lastIssuedQuery: String?

    init(environment: AppEnvironment? = nil) {
        self.environment = environment ?? AppEnvironment.shared
        dataStore = self.environment.dataStore
    }
    func updateQuery(_ text: String) {
        query = text
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            resetResults()
            return
        }
        hasSearched = true
        scheduleSearch(with: trimmed)
    }
    func applySearchTextImmediately(_ text: String) {
        query = text
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            resetResults()
            lastIssuedQuery = nil
            return
        }
        hasSearched = true
        guard lastIssuedQuery != trimmed else { return }
        lastIssuedQuery = trimmed
        performSearch(with: trimmed)
    }
    func refreshMessagesIfNeeded() {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        scheduleSearch(with: trimmed)
    }

    func refreshMessagesImmediatelyIfNeeded() {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        debounceTask?.cancel()
        lastIssuedQuery = trimmed
        performSearch(with: trimmed)
    }
    func loadMoreIfNeeded(currentItem: PushMessageSummary) {
        guard hasMoreResults, !isLoading else { return }
        guard displayedResults.last?.id == currentItem.id else { return }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        Task { @MainActor in
            await loadNextPage(trimmedQuery: trimmed)
        }
    }

    func setSortMode(_ sortMode: MessageListSortMode, persist: Bool = false) {
        guard self.sortMode != sortMode else { return }
        self.sortMode = sortMode
        if persist {
            sortMode.persist()
        }
        refreshMessagesIfNeeded()
    }

    var hasMore: Bool {
        hasMoreResults
    }

    private func performSearch(with trimmedQuery: String) {
        searchTask?.cancel()
        searchTask = Task(priority: .userInitiated) { @MainActor [weak self] in
            await self?.loadFirstPage(trimmedQuery: trimmedQuery)
        }
    }

    private func scheduleSearch(with trimmedQuery: String) {
        debounceTask?.cancel()
        let pendingQuery = trimmedQuery
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled, let self else { return }
            await MainActor.run { self.performSearch(with: pendingQuery) }
        }
    }

    private func resetResults() {
        hasSearched = false
        nextCursor = nil
        hasMoreResults = false
        isLoading = false
        totalResults = 0
        displayedResults = []
    }

    private func loadFirstPage(trimmedQuery: String) async {
        guard !trimmedQuery.isEmpty else { return }
        isLoading = true
        defer { isLoading = false }
        nextCursor = nil
        displayedResults = []
        hasMoreResults = false

        do {
            let count = try await dataStore.searchMessagesCount(query: trimmedQuery)
            let page = try await loadVisiblePage(
                trimmedQuery: trimmedQuery,
                before: nil,
                targetVisibleCount: pageSize
            )
            guard !Task.isCancelled else { return }
            totalResults = count
            displayedResults = page.messages
            nextCursor = page.nextCursor
            hasMoreResults = page.hasMoreResults
        } catch {
            totalResults = 0
            displayedResults = []
            hasMoreResults = false
        }
    }

    private func loadNextPage(trimmedQuery: String) async {
        guard hasMoreResults, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let page = try await loadVisiblePage(
                trimmedQuery: trimmedQuery,
                before: nextCursor,
                targetVisibleCount: pageSize
            )
            guard !page.messages.isEmpty else {
                hasMoreResults = false
                return
            }
            displayedResults.append(contentsOf: page.messages)
            nextCursor = page.nextCursor
            trimCachedResultsIfNeeded()
            hasMoreResults = page.hasMoreResults
        } catch {
            hasMoreResults = false
        }
    }

    private func trimCachedResultsIfNeeded() {
        let overflow = displayedResults.count - maxCachedResults
        guard overflow > 0 else { return }
        displayedResults.removeFirst(overflow)
    }

    private func loadVisiblePage(
        trimmedQuery: String,
        before cursor: MessagePageCursor?,
        targetVisibleCount: Int
    ) async throws -> (messages: [PushMessageSummary], nextCursor: MessagePageCursor?, hasMoreResults: Bool) {
        guard targetVisibleCount > 0 else {
            return ([], cursor, false)
        }

        var results: [PushMessageSummary] = []
        var currentCursor = cursor

        while results.count < targetVisibleCount {
            let page = try await dataStore.searchMessageSummariesPage(
                query: trimmedQuery,
                before: currentCursor,
                limit: pageSize,
                sortMode: sortMode
            )
            guard !page.isEmpty else {
                return (results, currentCursor, false)
            }

            currentCursor = page.last.map {
                MessagePageCursor(receivedAt: $0.receivedAt, id: $0.id, isRead: $0.isRead)
            }

            let visiblePage = page.filter(self.isVisible)
            let needed = targetVisibleCount - results.count
            results.append(contentsOf: visiblePage.prefix(needed))

            if page.count < pageSize {
                return (results, currentCursor, false)
            }
        }

        return (results, currentCursor, true)
    }

    private func isVisible(_ message: PushMessageSummary) -> Bool {
        !environment.pendingLocalDeletionController.suppressesMessage(id: message.id, channelId: message.channel)
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
