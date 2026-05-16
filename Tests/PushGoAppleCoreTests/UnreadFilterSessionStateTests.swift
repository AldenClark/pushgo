import Foundation
import XCTest
@testable import PushGoAppleCore

final class UnreadFilterSessionStateTests: XCTestCase {
    func testMergedMessagesPreservesRetainedReadRowsUntilReconcile() {
        var session = UnreadFilterSessionState()
        let retainedRead = makeSummary(id: UUID(), title: "retained", isRead: true, receivedAt: Date(timeIntervalSince1970: 20))
        let existingUnread = makeSummary(id: UUID(), title: "existing", isRead: false, receivedAt: Date(timeIntervalSince1970: 10))
        let newUnread = makeSummary(id: UUID(), title: "new", isRead: false, receivedAt: Date(timeIntervalSince1970: 30))

        session.retain(retainedRead)

        let merged = session.mergedMessages(
            currentMessages: [retainedRead, existingUnread],
            liveUnreadMessages: [newUnread, existingUnread]
        )

        XCTAssertEqual(merged.map(\.id), [newUnread.id, retainedRead.id, existingUnread.id])
        XCTAssertEqual(merged[1].isRead, true)
    }

    func testRetainedReadCountTracksSessionMembership() {
        var session = UnreadFilterSessionState()
        let first = makeSummary(id: UUID(), title: "first", isRead: true)
        let second = makeSummary(id: UUID(), title: "second", isRead: true)

        session.retain(first)
        session.retain(second)
        XCTAssertEqual(session.retainedReadCount, 2)

        session.forget(messageId: first.id)
        XCTAssertEqual(session.retainedReadCount, 1)

        session.reset()
        XCTAssertEqual(session.retainedReadCount, 0)
    }

    func testUnreadOnlyFilterPreferencePersistsSelection() throws {
        let suiteName = "UnreadFilterPreferenceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        XCTAssertFalse(MessageUnreadOnlyFilterPreference.load(defaults: defaults))

        MessageUnreadOnlyFilterPreference.persist(true, defaults: defaults)
        XCTAssertTrue(MessageUnreadOnlyFilterPreference.load(defaults: defaults))

        MessageUnreadOnlyFilterPreference.persist(false, defaults: defaults)
        XCTAssertFalse(MessageUnreadOnlyFilterPreference.load(defaults: defaults))
    }

    private func makeSummary(
        id: UUID,
        title: String,
        isRead: Bool,
        receivedAt: Date = Date()
    ) -> PushMessageSummary {
        PushMessageSummary(
            message: PushMessage(
                id: id,
                messageId: title,
                title: title,
                body: title,
                isRead: isRead,
                receivedAt: receivedAt
            )
        )
    }
}
