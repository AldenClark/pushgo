import Foundation
import GRDB

private enum MessageIndexDatabase {
    private static let busyTimeoutSeconds: TimeInterval = 5

    static func makeQueue(at url: URL) throws -> DatabaseQueue {
        var configuration = Configuration()
        configuration.busyMode = .timeout(busyTimeoutSeconds)
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA journal_mode=WAL;")
            try db.execute(sql: "PRAGMA synchronous=NORMAL;")
            try db.execute(sql: "PRAGMA temp_store=MEMORY;")
        }
        return try DatabaseQueue(path: url.path, configuration: configuration)
    }
}

actor MessageSearchIndex {
    struct Entry: Sendable {
        let id: UUID
        let title: String
        let body: String
        let channel: String?
        let receivedAt: Date
    }

    private let dbQueue: DatabaseQueue

    init(
        fileManager: FileManager = .default,
        appGroupIdentifier: String = AppConstants.appGroupIdentifier,
    ) throws {
        try AppConstants.migrateLegacyDatabaseArtifacts(
            fileManager: fileManager,
            appGroupIdentifier: appGroupIdentifier
        )
        let base = try MessageSearchIndex.databaseDirectory(
            fileManager: fileManager,
            appGroupIdentifier: appGroupIdentifier
        )
        let dbURL = base.appendingPathComponent(Self.indexDatabaseFilename)
        dbQueue = try MessageIndexDatabase.makeQueue(at: dbURL)
        try dbQueue.write { db in
            try Self.createTablesIfNeeded(db: db)
        }
    }

    func isEmpty() throws -> Bool {
        try dbQueue.read { db in
            let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM message_search;") ?? 0
            return count == 0
        }
    }

    func clear() throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM message_search;")
        }
    }

    func bulkUpsert(entries: [Entry]) throws {
        guard !entries.isEmpty else { return }
        try dbQueue.write { db in
            try db.inTransaction(.immediate) {
                for entry in entries {
                    try db.execute(
                        sql: """
                        INSERT INTO message_search (id, title, body, channel_id, received_at)
                        VALUES (?, ?, ?, ?, ?);
                        """,
                        arguments: [
                            entry.id.uuidString,
                            entry.title,
                            entry.body,
                            Self.normalizedChannel(entry.channel),
                            entry.receivedAt.timeIntervalSince1970,
                        ]
                    )
                }
                return .commit
            }
        }
    }

    func upsert(entry: Entry) throws {
        try dbQueue.write { db in
            try db.inTransaction(.immediate) {
                try db.execute(
                    sql: "DELETE FROM message_search WHERE id = ?;",
                    arguments: [entry.id.uuidString]
                )
                try db.execute(
                    sql: """
                    INSERT INTO message_search (id, title, body, channel_id, received_at)
                    VALUES (?, ?, ?, ?, ?);
                    """,
                    arguments: [
                        entry.id.uuidString,
                        entry.title,
                        entry.body,
                        Self.normalizedChannel(entry.channel),
                        entry.receivedAt.timeIntervalSince1970,
                    ]
                )
                return .commit
            }
        }
    }

    func remove(id: UUID) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "DELETE FROM message_search WHERE id = ?;",
                arguments: [id.uuidString]
            )
        }
    }

    func bulkRemove(ids: [UUID]) throws {
        guard !ids.isEmpty else { return }
        try dbQueue.write { db in
            try db.inTransaction(.immediate) {
                for id in ids {
                    try db.execute(
                        sql: "DELETE FROM message_search WHERE id = ?;",
                        arguments: [id.uuidString]
                    )
                }
                return .commit
            }
        }
    }

    func count(query: String) throws -> Int {
        try dbQueue.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM message_search WHERE message_search MATCH ?;",
                arguments: [query]
            ) ?? 0
        }
    }

    func searchIDs(
        query: String,
        before: Date?,
        beforeID: UUID?,
        limit: Int,
    ) throws -> [UUID] {
        let cutoff = before?.timeIntervalSince1970 ?? Date.distantFuture.timeIntervalSince1970
        let cutoffID = beforeID?.uuidString ?? "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF"
        let sql = """
            SELECT id FROM message_search
            WHERE message_search MATCH ?
              AND (received_at < ? OR (received_at = ? AND id < ?))
            ORDER BY received_at DESC, id DESC
            LIMIT ?;
            """

        return try dbQueue.read { db in
            let idStrings = try String.fetchAll(
                db,
                sql: sql,
                arguments: [query, cutoff, cutoff, cutoffID, max(0, limit)]
            )
            return idStrings.compactMap(UUID.init(uuidString:))
        }
    }

    private static func normalizedChannel(_ channel: String?) -> String? {
        guard let channel else { return nil }
        let trimmed = channel.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func createTablesIfNeeded(db: Database) throws {
        try resetSearchTableIfNeeded(db: db)
        try db.execute(sql: """
            CREATE VIRTUAL TABLE IF NOT EXISTS message_search USING fts5(
                id UNINDEXED,
                title,
                body,
                channel_id,
                received_at UNINDEXED,
                tokenize = 'unicode61'
            );
            """)
    }

    private static func resetSearchTableIfNeeded(db: Database) throws {
        do {
            _ = try Row.fetchCursor(db, sql: "SELECT channel_id FROM message_search LIMIT 1;")
        } catch {
            try db.execute(sql: "DROP TABLE IF EXISTS message_search;")
        }
    }

    private static func databaseDirectory(
        fileManager: FileManager,
        appGroupIdentifier: String,
    ) throws -> URL {
        guard let base = AppConstants.appGroupContainerURL(
            fileManager: fileManager,
            identifier: appGroupIdentifier
        ) else {
            throw AppError.missingAppGroup(appGroupIdentifier)
        }
        let directory = base.appendingPathComponent("Database", isDirectory: true)
        if !fileManager.fileExists(atPath: directory.path) {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return directory
    }

    fileprivate static var indexDatabaseFilename: String {
        AppConstants.messageIndexDatabaseFilename
    }
}

actor MessageMetadataIndex {
    struct Entry: Sendable {
        let id: UUID
        let receivedAt: Date
        let items: [String: String]
    }

    private struct Row: Hashable {
        let keyName: String
        let valueNorm: String
    }

    private let dbQueue: DatabaseQueue

    init(
        fileManager: FileManager = .default,
        appGroupIdentifier: String = AppConstants.appGroupIdentifier,
    ) throws {
        try AppConstants.migrateLegacyDatabaseArtifacts(
            fileManager: fileManager,
            appGroupIdentifier: appGroupIdentifier
        )
        let base = try MessageMetadataIndex.databaseDirectory(
            fileManager: fileManager,
            appGroupIdentifier: appGroupIdentifier
        )
        let dbURL = base.appendingPathComponent(MessageSearchIndex.indexDatabaseFilename)
        dbQueue = try MessageIndexDatabase.makeQueue(at: dbURL)
        try dbQueue.write { db in
            try Self.createTablesIfNeeded(db: db)
        }
    }

    func isEmpty() throws -> Bool {
        try dbQueue.read { db in
            let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM message_metadata_index;") ?? 0
            return count == 0
        }
    }

    func clear() throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM message_metadata_index;")
        }
    }

    func bulkReplace(entries: [Entry]) throws {
        guard !entries.isEmpty else { return }
        try dbQueue.write { db in
            try db.inTransaction(.immediate) {
                for entry in entries {
                    try db.execute(
                        sql: "DELETE FROM message_metadata_index WHERE message_id = ?;",
                        arguments: [entry.id.uuidString]
                    )
                    let rows = Self.normalizedRows(from: entry.items)
                    for row in rows {
                        try db.execute(
                            sql: """
                            INSERT INTO message_metadata_index (message_id, key_name, value_norm, received_at)
                            VALUES (?, ?, ?, ?);
                            """,
                            arguments: [
                                entry.id.uuidString,
                                row.keyName,
                                row.valueNorm,
                                entry.receivedAt.timeIntervalSince1970,
                            ]
                        )
                    }
                }
                return .commit
            }
        }
    }

    func remove(id: UUID) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "DELETE FROM message_metadata_index WHERE message_id = ?;",
                arguments: [id.uuidString]
            )
        }
    }

    func bulkRemove(ids: [UUID]) throws {
        guard !ids.isEmpty else { return }
        try dbQueue.write { db in
            try db.inTransaction(.immediate) {
                for id in ids {
                    try db.execute(
                        sql: "DELETE FROM message_metadata_index WHERE message_id = ?;",
                        arguments: [id.uuidString]
                    )
                }
                return .commit
            }
        }
    }

    private static func createTablesIfNeeded(db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS message_metadata_index (
                message_id TEXT NOT NULL,
                key_name TEXT NOT NULL,
                value_norm TEXT NOT NULL,
                received_at REAL NOT NULL,
                PRIMARY KEY (message_id, key_name, value_norm)
            );
            CREATE INDEX IF NOT EXISTS idx_metadata_key_value_time
                ON message_metadata_index(key_name, value_norm, received_at DESC);
            CREATE INDEX IF NOT EXISTS idx_metadata_message
                ON message_metadata_index(message_id);
            """)
    }

    private static func normalizedRows(from items: [String: String]) -> [Row] {
        var rows: [Row] = []
        var seen: Set<String> = []
        for (rawKey, rawValue) in items {
            let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !key.isEmpty, !value.isEmpty else { continue }
            let dedupe = "\(key)\u{1F}\(value)"
            guard seen.insert(dedupe).inserted else { continue }
            rows.append(Row(keyName: key, valueNorm: value))
        }
        return rows
    }

    private static func databaseDirectory(
        fileManager: FileManager,
        appGroupIdentifier: String,
    ) throws -> URL {
        guard let base = AppConstants.appGroupContainerURL(
            fileManager: fileManager,
            identifier: appGroupIdentifier
        ) else {
            throw AppError.missingAppGroup(appGroupIdentifier)
        }
        let directory = base.appendingPathComponent("Database", isDirectory: true)
        if !fileManager.fileExists(atPath: directory.path) {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return directory
    }
}
