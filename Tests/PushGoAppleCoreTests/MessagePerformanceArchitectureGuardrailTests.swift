import Foundation
import Testing

struct MessagePerformanceArchitectureGuardrailTests {
    @Test
    func summaryProjectionQueryCannotRegressToFullMessageColumns() throws {
        let source = try readSource("Shared/Repositories/LocalDataStore.swift")
        let querySection = try section(
            in: source,
            from: "private func fetchProjectedMessageSummaries(",
            to: "private func loadMessages("
        )

        #expect(querySection.contains("JOIN message_summary_projection"))
        #expect(!querySection.contains("SELECT *"))
        #expect(!querySection.contains("m.body"))
        #expect(!querySection.contains("raw_payload_json"))
    }

    @Test
    func messageListCountsCannotRegressToLoadingFullEntities() throws {
        let source = try readSource("Shared/UI/MessageListViewModel.swift")
        let countSection = try section(
            in: source,
            from: "private func loadCurrentScopeUnreadCount()",
            to: "private func unreadMessageIDsInCurrentScope()"
        )

        #expect(countSection.contains("dataStore.unreadMessageCount"))
        #expect(!countSection.contains("loadMessages"))
        #expect(!countSection.contains("filter {"))
    }

    @Test
    func searchKeepsDisplayedResultsUntilTheCurrentRequestCommits() throws {
        let source = try readSource("Shared/UI/MessageSearchViewModel.swift")
        let queryUpdateSection = try section(
            in: source,
            from: "func updateQuery(",
            to: "func applySearchTextImmediately("
        )
        let firstPageSection = try section(
            in: source,
            from: "private func loadFirstPage(",
            to: "private func loadNextPage("
        )
        let beforeFirstFetch = try section(
            in: String(firstPageSection),
            from: "private func loadFirstPage(",
            to: "let count = try await dataStore.searchMessagesCount"
        )

        #expect(!queryUpdateSection.contains("hasSearched = true"))
        #expect(!beforeFirstFetch.contains("displayedResults = []"))
        #expect(firstPageSection.contains("guard isCurrentSearchRequest"))
        #expect(firstPageSection.contains("displayedQuery = trimmedQuery"))
        #expect(source.contains("searchDebounceDuration: Duration = .milliseconds(250)"))
    }

    private func readSource(_ relativePath: String) throws -> String {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: repositoryRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    private func section(in source: String, from start: String, to end: String) throws -> Substring {
        let startRange = try #require(source.range(of: start))
        let endRange = try #require(source.range(of: end, range: startRange.upperBound..<source.endIndex))
        return source[startRange.lowerBound..<endRange.lowerBound]
    }
}
