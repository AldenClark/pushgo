import Foundation
import Observation

#if DEBUG
private enum PushGoQualityInjectedMessageSearchError: Error {
    case requestedFailure
}
#endif

@MainActor
@Observable
final class MessageSearchViewModel {
    var query: String = ""
    private(set) var sortMode: MessageListSortMode = MessageListSortMode.loadPreference()
    private(set) var displayedQuery: String = ""
    private(set) var completedSearchRevision: UInt64 = 0
    private(set) var displayedResultsIdentityRevision: UInt64 = 0
    /// Identifies the search request after debounce has actually launched.
    /// UI loading feedback must be timed from this point, not from each
    /// character-level query update.
    private(set) var activeSearchRequestRevision: UInt64?
    /// Request-local slow state owned by the search state machine. Keeping
    /// this state here prevents view lifecycle or list virtualization races
    /// from dropping the only user-visible indication before results commit.
    private(set) var isSearchLoadSlow: Bool = false
    private(set) var displayedResults: [PushMessageSummary] = [] {
        didSet {
            guard messageIDsChanged(from: oldValue, to: displayedResults) else { return }
            displayedResultsIdentityRevision &+= 1
        }
    }
    private(set) var totalResults: Int = 0
    private(set) var hasSearched: Bool = false
    private(set) var isSearching: Bool = false
    private(set) var searchFailed: Bool = false

    private let pageSize: Int = 20
    private let maxCachedResults: Int = 200
    private let searchDebounceDuration: Duration = .milliseconds(250)
    private var nextCursor: MessagePageCursor?
    private var hasMoreResults: Bool = false
    private var isLoadingMore: Bool = false

    private let environment: AppEnvironment
    private let dataStore: LocalDataStore
    private var searchTask: Task<Void, Never>?
    private var debounceTask: Task<Void, Never>?
    private var loadMoreTask: Task<Void, Never>?
    private var slowSearchTask: Task<Void, Never>?
    private var searchRequestRevision: UInt64 = 0
    private var shouldApplyQualitySearchDelay = true
#if DEBUG
    private var remainingQualitySearchFailures: Int
#endif

    init(environment: AppEnvironment? = nil) {
        self.environment = environment ?? AppEnvironment.shared
        dataStore = self.environment.dataStore
#if DEBUG
        remainingQualitySearchFailures = PushGoAutomationContext.qualitySession?.faults
            .failMessageSearchOnce == true ? 1 : 0
#endif
    }
    func updateQuery(_ text: String) {
        query = text
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            resetResults()
            return
        }
        scheduleSearch(with: trimmed)
    }
    func applySearchTextImmediately(_ text: String) {
        query = text
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            resetResults()
            return
        }
        performSearchImmediately(with: trimmed)
    }
    func refreshMessagesIfNeeded() {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        scheduleSearch(with: trimmed)
    }

    func refreshMessagesImmediatelyIfNeeded() {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        performSearchImmediately(with: trimmed)
    }

    func retrySearch() {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        performSearchImmediately(with: trimmed)
    }
    func loadMoreIfNeeded(currentItem: PushMessageSummary) {
        guard hasMoreResults, !isSearching, !isLoadingMore else { return }
        guard displayedResults.last?.id == currentItem.id else { return }
        let committedQuery = displayedQuery
        guard !committedQuery.isEmpty else { return }
        let requestRevision = searchRequestRevision
        loadMoreTask = Task { @MainActor [weak self] in
            await self?.loadNextPage(
                trimmedQuery: committedQuery,
                requestRevision: requestRevision
            )
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

    private func performSearchImmediately(with trimmedQuery: String) {
        let requestRevision = beginSearchRequest()
        launchSearch(with: trimmedQuery, requestRevision: requestRevision)
    }

    private func launchSearch(with trimmedQuery: String, requestRevision: UInt64) {
        guard requestRevision == searchRequestRevision else { return }
        activeSearchRequestRevision = requestRevision
        isSearchLoadSlow = false
        slowSearchTask?.cancel()
        slowSearchTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(1))
                try Task.checkCancellation()
                guard let self,
                      self.isSearching,
                      self.activeSearchRequestRevision == requestRevision else {
                    return
                }
                self.isSearchLoadSlow = true
            } catch {
                // Query replacement or request completion cancels this task;
                // the next request owns a fresh timer.
            }
        }
        searchTask = Task(priority: .userInitiated) { @MainActor [weak self] in
            await self?.loadFirstPage(
                trimmedQuery: trimmedQuery,
                requestRevision: requestRevision
            )
        }
    }

    private func scheduleSearch(with trimmedQuery: String) {
        let requestRevision = beginSearchRequest()
        let pendingQuery = trimmedQuery
        let debounceDuration = searchDebounceDuration
        debounceTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: debounceDuration)
            } catch {
                return
            }
            guard !Task.isCancelled,
                  let self,
                  requestRevision == self.searchRequestRevision
            else { return }
            self.debounceTask = nil
            self.launchSearch(with: pendingQuery, requestRevision: requestRevision)
        }
    }

    @discardableResult
    private func beginSearchRequest() -> UInt64 {
        searchRequestRevision &+= 1
        debounceTask?.cancel()
        debounceTask = nil
        searchTask?.cancel()
        searchTask = nil
        loadMoreTask?.cancel()
        loadMoreTask = nil
        slowSearchTask?.cancel()
        slowSearchTask = nil
        activeSearchRequestRevision = nil
        isSearchLoadSlow = false
        isLoadingMore = false
        searchFailed = false
        isSearching = true
        return searchRequestRevision
    }

    private func resetResults() {
        searchRequestRevision &+= 1
        debounceTask?.cancel()
        debounceTask = nil
        searchTask?.cancel()
        searchTask = nil
        loadMoreTask?.cancel()
        loadMoreTask = nil
        slowSearchTask?.cancel()
        slowSearchTask = nil
        activeSearchRequestRevision = nil
        isSearchLoadSlow = false
        hasSearched = false
        searchFailed = false
        isSearching = false
        isLoadingMore = false
        displayedQuery = ""
        nextCursor = nil
        hasMoreResults = false
        totalResults = 0
        displayedResults = []
    }

    private func loadFirstPage(trimmedQuery: String, requestRevision: UInt64) async {
        guard !trimmedQuery.isEmpty else { return }
        defer {
            if requestRevision == searchRequestRevision {
                isSearching = false
                searchTask = nil
                slowSearchTask?.cancel()
                slowSearchTask = nil
                activeSearchRequestRevision = nil
                isSearchLoadSlow = false
            }
        }

        do {
            try await applyQualitySearchDelayIfNeeded()
            try consumeQualitySearchFailureIfNeeded()
            let count = try await dataStore.searchMessagesCount(query: trimmedQuery)
            try Task.checkCancellation()
            let page = try await loadVisiblePage(
                trimmedQuery: trimmedQuery,
                before: nil,
                targetVisibleCount: pageSize
            )
            try Task.checkCancellation()
            guard isCurrentSearchRequest(requestRevision, query: trimmedQuery) else { return }
            displayedQuery = trimmedQuery
            totalResults = count
            displayedResults = page.messages
            nextCursor = page.nextCursor
            hasMoreResults = page.hasMoreResults
            hasSearched = true
            searchFailed = false
            completedSearchRevision &+= 1
        } catch {
            guard isCurrentSearchRequest(requestRevision, query: trimmedQuery) else { return }
            displayedQuery = trimmedQuery
            totalResults = 0
            displayedResults = []
            nextCursor = nil
            hasMoreResults = false
            hasSearched = true
            searchFailed = true
            completedSearchRevision &+= 1
        }
    }

    private func applyQualitySearchDelayIfNeeded() async throws {
        #if DEBUG
        guard shouldApplyQualitySearchDelay,
              let delay = PushGoAutomationContext.qualitySession?.faults
                .messageSearchDelayMilliseconds,
              delay > 0
        else { return }
        shouldApplyQualitySearchDelay = false
        try await Task.sleep(for: .milliseconds(delay))
        #endif
    }

    private func consumeQualitySearchFailureIfNeeded() throws {
        #if DEBUG
        guard remainingQualitySearchFailures > 0 else { return }
        remainingQualitySearchFailures -= 1
        throw PushGoQualityInjectedMessageSearchError.requestedFailure
        #endif
    }

    private func loadNextPage(trimmedQuery: String, requestRevision: UInt64) async {
        guard requestRevision == searchRequestRevision,
              trimmedQuery == displayedQuery,
              hasMoreResults,
              !isSearching,
              !isLoadingMore
        else { return }
        isLoadingMore = true
        defer {
            if requestRevision == searchRequestRevision {
                isLoadingMore = false
                loadMoreTask = nil
            }
        }
        do {
            let page = try await loadVisiblePage(
                trimmedQuery: trimmedQuery,
                before: nextCursor,
                targetVisibleCount: pageSize
            )
            try Task.checkCancellation()
            guard requestRevision == searchRequestRevision,
                  trimmedQuery == displayedQuery
            else { return }
            guard !page.messages.isEmpty else {
                hasMoreResults = false
                return
            }
            displayedResults.append(contentsOf: page.messages)
            nextCursor = page.nextCursor
            trimCachedResultsIfNeeded()
            hasMoreResults = page.hasMoreResults
        } catch {
            guard requestRevision == searchRequestRevision,
                  trimmedQuery == displayedQuery,
                  !Task.isCancelled
            else { return }
            hasMoreResults = false
        }
    }

    private func isCurrentSearchRequest(_ requestRevision: UInt64, query trimmedQuery: String) -> Bool {
        requestRevision == searchRequestRevision
            && !Task.isCancelled
            && self.query.trimmingCharacters(in: .whitespacesAndNewlines) == trimmedQuery
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
