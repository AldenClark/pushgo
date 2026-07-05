import Foundation
import SQLite3
import WidgetKit

enum PushGoWidgetActionExecutor {
    @discardableResult
    static func markLatestUnreadMessageRead() -> Bool {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: PushGoWidgetSnapshotStore.appGroupIdentifier
        ) else {
            return false
        }
        let databaseURL = container
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("pushgo.db", isDirectory: false)
        let changedMessageID = markLatestUnreadMessageRead(in: databaseURL)
        guard let changedMessageID else { return false }
        updateSnapshotAfterMarkRead(messageID: changedMessageID)
        WidgetCenter.shared.reloadAllTimelines()
        return true
    }

    private static func markLatestUnreadMessageRead(in databaseURL: URL) -> String? {
        guard FileManager.default.fileExists(atPath: databaseURL.path) else { return nil }
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(databaseURL.path, &db, flags, nil) == SQLITE_OK, let db else {
            if let db { sqlite3_close(db) }
            return nil
        }
        defer { sqlite3_close(db) }
        _ = sqlite3_busy_timeout(db, 3000)
        guard let messageID = latestUnreadMessageID(db: db) else { return nil }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(
            db,
            "UPDATE messages SET is_read = 1 WHERE id = ? AND is_read = 0;",
            -1,
            &statement,
            nil
        ) == SQLITE_OK else {
            return nil
        }
        sqlite3_bind_text(statement, 1, messageID, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(statement) == SQLITE_DONE else { return nil }
        return sqlite3_changes(db) > 0 ? messageID : nil
    }

    private static func latestUnreadMessageID(db: OpaquePointer) -> String? {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(
            db,
            """
            SELECT id
            FROM messages
            WHERE is_top_level_message = 1 AND is_read = 0
            ORDER BY received_at DESC, id DESC
            LIMIT 1;
            """,
            -1,
            &statement,
            nil
        ) == SQLITE_OK else {
            return nil
        }
        guard sqlite3_step(statement) == SQLITE_ROW,
              let text = sqlite3_column_text(statement, 0)
        else {
            return nil
        }
        return String(cString: text)
    }

    private static func updateSnapshotAfterMarkRead(messageID: String) {
        let snapshot = PushGoWidgetSnapshotStore.load()
        guard snapshot.schemaVersion == PushGoWidgetSnapshot.schemaVersion else { return }
        let unreadMessages = snapshot.unreadMessages.filter { item in
            item.openTarget?.identifier != messageID && item.id != "message:\(messageID)"
        }
        let recentMessages = snapshot.recentMessages.map { item -> PushGoWidgetSnapshot.Item in
            guard item.openTarget?.identifier == messageID || item.id == "message:\(messageID)" else {
                return item
            }
            return item.withStatus("read")
        }
        let updated = snapshot.replacing(
            counts: PushGoWidgetSnapshot.Counts(
                totalMessages: snapshot.counts.totalMessages,
                unreadMessages: max(0, snapshot.counts.unreadMessages - 1),
                criticalEvents: snapshot.counts.criticalEvents,
                objectWarnings: snapshot.counts.objectWarnings
            ),
            recentMessages: recentMessages,
            unreadMessages: unreadMessages
        )
        PushGoWidgetSnapshotStore.write(updated)
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
