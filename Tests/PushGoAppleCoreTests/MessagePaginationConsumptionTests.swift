import Foundation
import Testing
@testable import PushGoAppleCore

@Suite("Message pagination consumption")
struct MessagePaginationConsumptionTests {
    @Test
    func partialOverlapPreservesTheUnconsumedRemainderForTheNextPage() throws {
        var seenIDs = Set(0..<20)
        var cursor: Int?

        let first = try consumeUniqueMessagePage(
            Array(0..<50),
            targetRemaining: 50,
            seenIDs: &seenIDs,
            currentCursor: &cursor,
            id: { $0 },
            cursor: { $0 },
            isVisible: { _ in true }
        )
        #expect(first.appended == Array(20..<50))
        #expect(!first.reachedTarget)
        #expect(cursor == 49)

        let second = try consumeUniqueMessagePage(
            Array(50..<100),
            targetRemaining: 20,
            seenIDs: &seenIDs,
            currentCursor: &cursor,
            id: { $0 },
            cursor: { $0 },
            isVisible: { _ in true }
        )
        #expect(second.appended == Array(50..<70))
        #expect(second.reachedTarget)
        #expect(cursor == 69)

        var nextResults: [Int] = []
        let remainder = try consumeUniqueMessagePage(
            Array(70..<100),
            targetRemaining: 50,
            seenIDs: &seenIDs,
            currentCursor: &cursor,
            id: { $0 },
            cursor: { $0 },
            isVisible: { _ in true }
        )
        nextResults.append(contentsOf: remainder.appended)
        #expect(!remainder.reachedTarget)
        #expect(cursor == 99)

        let followingPage = try consumeUniqueMessagePage(
            Array(100..<120),
            targetRemaining: 50 - nextResults.count,
            seenIDs: &seenIDs,
            currentCursor: &cursor,
            id: { $0 },
            cursor: { $0 },
            isVisible: { _ in true }
        )
        nextResults.append(contentsOf: followingPage.appended)

        #expect(nextResults == Array(70..<120))
        #expect(followingPage.reachedTarget)
        #expect(cursor == 119)
        #expect(seenIDs == Set(0..<120))
    }
}
