import Foundation
import SQLite3

actor MessageSearchIndex {
    struct Entry: Sendable {
        let id: UUID
        let title: String
        let body: String
        let channel: String?
        let receivedAt: Date
    }

    private enum SearchIndexError: Error {
        case openFailed
        case statementFailed
        case executeFailed
    }

    private let dbURL: URL
    private var db: OpaquePointer?
    private let transientDestructor = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(
        fileManager: FileManager = .default,
        appGroupIdentifier: String = AppConstants.appGroupIdentifier,
    ) throws {
        let base = try MessageSearchIndex.databaseDirectory(
            fileManager: fileManager,
            appGroupIdentifier: appGroupIdentifier
        )
        dbURL = base.appendingPathComponent("pushgo.search.sqlite")
        let database = try Self.openDatabase(at: dbURL)
        db = database
        try Self.createTablesIfNeeded(db: database)
    }

    func isEmpty() throws -> Bool {
        let sql = "SELECT COUNT(*) FROM message_search;"
        let count = try querySingleInt(sql: sql)
        return count == 0
    }

    func clear() throws {
        try execute(sql: "DELETE FROM message_search;")
    }

    func bulkUpsert(entries: [Entry]) throws {
        guard !entries.isEmpty else { return }
        guard let db else { throw SearchIndexError.openFailed }
        try execute(sql: "BEGIN IMMEDIATE TRANSACTION;")
        do {
            let insertSQL = """
                INSERT INTO message_search (id, title, body, channel_id, received_at)
                VALUES (?, ?, ?, ?, ?);
                """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, insertSQL, -1, &statement, nil) == SQLITE_OK else {
                throw SearchIndexError.statementFailed
            }
            defer { sqlite3_finalize(statement) }

            for entry in entries {
                bindText(statement, index: 1, value: entry.id.uuidString)
                bindText(statement, index: 2, value: entry.title)
                bindText(statement, index: 3, value: entry.body)
                if let channel = entry.channel, !channel.isEmpty {
                    bindText(statement, index: 4, value: channel)
                } else {
                    sqlite3_bind_null(statement, 4)
                }
                sqlite3_bind_double(statement, 5, entry.receivedAt.timeIntervalSince1970)

                guard sqlite3_step(statement) == SQLITE_DONE else {
                    throw SearchIndexError.executeFailed
                }
                sqlite3_reset(statement)
            }
            try execute(sql: "COMMIT;")
        } catch {
            _ = try? execute(sql: "ROLLBACK;")
            throw error
        }
    }

    func upsert(entry: Entry) throws {
        try execute(sql: "DELETE FROM message_search WHERE id = ?;", bindings: [entry.id.uuidString])
        try bulkUpsert(entries: [entry])
    }

    func remove(id: UUID) throws {
        try execute(sql: "DELETE FROM message_search WHERE id = ?;", bindings: [id.uuidString])
    }

    func bulkRemove(ids: [UUID]) throws {
        guard !ids.isEmpty else { return }
        guard let db else { throw SearchIndexError.openFailed }
        try execute(sql: "BEGIN IMMEDIATE TRANSACTION;")
        do {
            let sql = "DELETE FROM message_search WHERE id = ?;"
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                throw SearchIndexError.statementFailed
            }
            defer { sqlite3_finalize(statement) }

            for id in ids {
                bindText(statement, index: 1, value: id.uuidString)
                guard sqlite3_step(statement) == SQLITE_DONE else {
                    throw SearchIndexError.executeFailed
                }
                sqlite3_reset(statement)
            }
            try execute(sql: "COMMIT;")
        } catch {
            _ = try? execute(sql: "ROLLBACK;")
            throw error
        }
    }

    func count(query: String) throws -> Int {
        let sql = "SELECT COUNT(*) FROM message_search WHERE message_search MATCH ?;"
        return try querySingleInt(sql: sql, bindings: [query])
    }

    func searchIDs(
        query: String,
        before: Date?,
        limit: Int,
    ) throws -> [UUID] {
        guard let db else { throw SearchIndexError.openFailed }
        let cutoff = before?.timeIntervalSince1970 ?? Date.distantFuture.timeIntervalSince1970
        let sql = """
            SELECT id FROM message_search
            WHERE message_search MATCH ? AND received_at < ?
            ORDER BY received_at DESC
            LIMIT ?;
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw SearchIndexError.statementFailed
        }
        defer { sqlite3_finalize(statement) }

        bindText(statement, index: 1, value: query)
        sqlite3_bind_double(statement, 2, cutoff)
        sqlite3_bind_int(statement, 3, Int32(max(0, limit)))

        var ids: [UUID] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let cString = sqlite3_column_text(statement, 0) else { continue }
            let value = String(cString: cString)
            if let uuid = UUID(uuidString: value) {
                ids.append(uuid)
            }
        }
        return ids
    }

    private func execute(sql: String, bindings: [String?] = []) throws {
        guard let db else { throw SearchIndexError.openFailed }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw SearchIndexError.statementFailed
        }
        defer { sqlite3_finalize(statement) }

        for (index, value) in bindings.enumerated() {
            let position = Int32(index + 1)
            if let value {
                bindText(statement, index: position, value: value)
            } else {
                sqlite3_bind_null(statement, position)
            }
        }

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw SearchIndexError.executeFailed
        }
    }

    private func querySingleInt(sql: String, bindings: [String?] = []) throws -> Int {
        guard let db else { throw SearchIndexError.openFailed }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw SearchIndexError.statementFailed
        }
        defer { sqlite3_finalize(statement) }

        for (index, value) in bindings.enumerated() {
            let position = Int32(index + 1)
            if let value {
                bindText(statement, index: position, value: value)
            } else {
                sqlite3_bind_null(statement, position)
            }
        }

        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw SearchIndexError.executeFailed
        }
        return Int(sqlite3_column_int(statement, 0))
    }

    private func bindText(_ statement: OpaquePointer?, index: Int32, value: String) {
        _ = value.withCString { cString in
            sqlite3_bind_text(statement, index, cString, -1, transientDestructor)
        }
    }

    private static func openDatabase(at url: URL) throws -> OpaquePointer? {
        var database: OpaquePointer?
        guard sqlite3_open(url.path, &database) == SQLITE_OK else {
            if let database {
                sqlite3_close(database)
            }
            throw SearchIndexError.openFailed
        }
        return database
    }

    private static func createTablesIfNeeded(db: OpaquePointer?) throws {
        guard let db else { throw SearchIndexError.openFailed }
        try resetSearchTableIfNeeded(db: db)
        let ftsSQL = """
            CREATE VIRTUAL TABLE IF NOT EXISTS message_search USING fts5(
                id UNINDEXED,
                title,
                body,
                channel_id,
                received_at UNINDEXED,
                tokenize = 'unicode61'
            );
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, ftsSQL, -1, &statement, nil) == SQLITE_OK else {
            throw SearchIndexError.statementFailed
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw SearchIndexError.executeFailed
        }
    }

    private static func resetSearchTableIfNeeded(db: OpaquePointer?) throws {
        guard let db else { throw SearchIndexError.openFailed }
        var statement: OpaquePointer?
        let checkSQL = "SELECT channel_id FROM message_search LIMIT 1;"
        if sqlite3_prepare_v2(db, checkSQL, -1, &statement, nil) != SQLITE_OK {
            sqlite3_finalize(statement)
            let dropSQL = "DROP TABLE IF EXISTS message_search;"
            guard sqlite3_exec(db, dropSQL, nil, nil, nil) == SQLITE_OK else {
                throw SearchIndexError.executeFailed
            }
            return
        }
        sqlite3_finalize(statement)
    }

    private static func databaseDirectory(
        fileManager: FileManager,
        appGroupIdentifier: String,
    ) throws -> URL {
        guard let base = fileManager.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
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
