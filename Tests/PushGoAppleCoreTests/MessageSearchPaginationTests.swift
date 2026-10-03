import Foundation
import Testing
@testable import PushGoAppleCore

struct MessageSearchPaginationTests {
    @Test
    func suppressedSearchRowsPreserveUnconsumedMatchesThroughReopen() async throws {
        try await withIsolatedAutomationStorage { root, appGroupIdentifier in
            let store = LocalDataStore(appGroupIdentifier: appGroupIdentifier, spotlightIndexer: nil)
            let messages = (0..<43).map { index in
                PushMessage(
                    messageId: "search-page-\(index)",
                    title: "Paging needle \(index)",
                    body: "Canonical search result \(index)",
                    receivedAt: Date(timeIntervalSince1970: Double(1_800_000_000 - index))
                )
            }
            try await store.saveMessages(messages)
            let suppressed = Set(messages.prefix(2).map(\.id))
            let expected = Array(messages.dropFirst(2).map(\.id))

            let first = try await loadVisibleMessageSearchPage(
                before: nil, targetVisibleCount: 20, pageSize: 20,
                loadPage: { cursor, limit in
                    try await store.searchMessageSummariesPage(query: "Paging needle", before: cursor, limit: limit)
                },
                isVisible: { !suppressed.contains($0.id) }
            )
            #expect(first.messages.map(\.id) == Array(expected.prefix(20)))
            #expect(first.nextCursor?.id == expected[19])
            #expect(first.hasMoreResults)

            LocalDataStore.releaseSharedResourcesForTesting(storageRootURL: root)
            let reopened = LocalDataStore(appGroupIdentifier: appGroupIdentifier, spotlightIndexer: nil)
            var ids = first.messages.map(\.id)
            var cursor = first.nextCursor
            var hasMore = first.hasMoreResults
            for _ in 0..<3 where hasMore {
                let page = try await loadVisibleMessageSearchPage(
                    before: cursor, targetVisibleCount: 20, pageSize: 20,
                    loadPage: { cursor, limit in
                        try await reopened.searchMessageSummariesPage(query: "Paging needle", before: cursor, limit: limit)
                    },
                    isVisible: { !suppressed.contains($0.id) }
                )
                ids.append(contentsOf: page.messages.map(\.id))
                cursor = page.nextCursor
                hasMore = page.hasMoreResults
            }
            #expect(!hasMore)
            #expect(ids == expected)
            #expect(Set(ids).count == 41)
            #expect(try await reopened.searchMessagesCount(query: "Paging needle") == 43)
            #expect(try await reopened.loadMessage(id: messages[0].id)?.body == "Canonical search result 0")
        }
    }
}
