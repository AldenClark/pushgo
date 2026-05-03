import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

actor WatchLightNotificationStore {
    private enum StoreError: Error {
        case missingAppGroup(String)
        case sqliteOpenFailed(code: Int32)
        case sqlitePrepareFailed(message: String)
        case sqliteStepFailed(message: String)
    }

    private let decoder: JSONDecoder
    private var db: OpaquePointer?

    init(
        fileManager: FileManager = .default,
        appGroupIdentifier: String = AppConstants.appGroupIdentifier
    ) throws {
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let storeURL = try Self.storeURL(
            fileManager: fileManager,
            appGroupIdentifier: appGroupIdentifier,
            filename: AppConstants.databaseStoreFilename
        )

        var openedDb: OpaquePointer?
        let openFlags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        let openResult = sqlite3_open_v2(storeURL.path, &openedDb, openFlags, nil)
        guard openResult == SQLITE_OK, let openedDb else {
            if let openedDb {
                sqlite3_close(openedDb)
            }
            throw StoreError.sqliteOpenFailed(code: openResult)
        }
        try Self.execute("PRAGMA journal_mode = WAL;", db: openedDb)
        try Self.execute("PRAGMA synchronous = NORMAL;", db: openedDb)
        try Self.execute("PRAGMA foreign_keys = ON;", db: openedDb)
        try Self.execute("PRAGMA busy_timeout = 5000;", db: openedDb)
        try Self.createSchemaIfNeeded(db: openedDb)
        db = openedDb
    }

    func upsert(_ payload: WatchLightPayload) throws {
        switch payload {
        case let .message(message):
            let sql = """
                INSERT INTO watch_light_messages (
                    message_id, title, body, image_url, url, severity, received_at, is_read,
                    entity_type, entity_id, notification_request_id
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(message_id) DO UPDATE SET
                    title = excluded.title,
                    body = excluded.body,
                    image_url = excluded.image_url,
                    url = excluded.url,
                    severity = excluded.severity,
                    received_at = excluded.received_at,
                    is_read = excluded.is_read,
                    entity_type = excluded.entity_type,
                    entity_id = excluded.entity_id,
                    notification_request_id = excluded.notification_request_id;
                """
            let statement = try prepare(sql)
            defer { sqlite3_finalize(statement) }
            try bindText(statement, index: 1, value: message.messageId)
            try bindText(statement, index: 2, value: message.title)
            try bindText(statement, index: 3, value: message.body)
            try bindText(statement, index: 4, value: message.imageURL?.absoluteString)
            try bindText(statement, index: 5, value: message.url?.absoluteString)
            try bindText(statement, index: 6, value: message.severity)
            sqlite3_bind_double(statement, 7, message.receivedAt.timeIntervalSince1970)
            sqlite3_bind_int(statement, 8, message.isRead ? 1 : 0)
            try bindText(statement, index: 9, value: message.entityType)
            try bindText(statement, index: 10, value: message.entityId)
            try bindText(statement, index: 11, value: message.notificationRequestId)
            try stepDone(statement)

        case let .event(event):
            let sql = """
                INSERT INTO watch_light_events (
                    event_id, title, summary, state, severity, image_url, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(event_id) DO UPDATE SET
                    title = excluded.title,
                    summary = excluded.summary,
                    state = excluded.state,
                    severity = excluded.severity,
                    image_url = excluded.image_url,
                    updated_at = excluded.updated_at;
                """
            let statement = try prepare(sql)
            defer { sqlite3_finalize(statement) }
            try bindText(statement, index: 1, value: event.eventId)
            try bindText(statement, index: 2, value: event.title)
            try bindText(statement, index: 3, value: event.summary)
            try bindText(statement, index: 4, value: event.state)
            try bindText(statement, index: 5, value: event.severity)
            try bindText(statement, index: 6, value: event.imageURL?.absoluteString)
            sqlite3_bind_double(statement, 7, event.updatedAt.timeIntervalSince1970)
            try stepDone(statement)

        case let .thing(thing):
            let sql = """
                INSERT INTO watch_light_things (
                    thing_id, title, summary, attrs_json, image_url, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(thing_id) DO UPDATE SET
                    title = excluded.title,
                    summary = excluded.summary,
                    attrs_json = excluded.attrs_json,
                    image_url = excluded.image_url,
                    updated_at = excluded.updated_at;
                """
            let statement = try prepare(sql)
            defer { sqlite3_finalize(statement) }
            try bindText(statement, index: 1, value: thing.thingId)
            try bindText(statement, index: 2, value: thing.title)
            try bindText(statement, index: 3, value: thing.summary)
            try bindText(statement, index: 4, value: thing.attrsJSON)
            try bindText(statement, index: 5, value: thing.imageURL?.absoluteString)
            sqlite3_bind_double(statement, 6, thing.updatedAt.timeIntervalSince1970)
            try stepDone(statement)
        }

        DarwinNotificationPoster.post(name: AppConstants.messageSyncNotificationName)
    }

    func unreadCount() throws -> Int {
        let statement = try prepare("SELECT COUNT(*) FROM watch_light_messages WHERE is_read = 0;")
        defer { sqlite3_finalize(statement) }
        let result = sqlite3_step(statement)
        guard result == SQLITE_ROW else {
            throw StoreError.sqliteStepFailed(message: lastSQLiteMessage())
        }
        return Int(sqlite3_column_int64(statement, 0))
    }

    func loadProvisioningServerConfig() throws -> ServerConfig? {
        let statement = try prepare(
            "SELECT watch_provisioning_server_config_data_base64 FROM app_settings WHERE id = 'default' LIMIT 1;"
        )
        defer { sqlite3_finalize(statement) }
        let result = sqlite3_step(statement)
        if result == SQLITE_DONE {
            return nil
        }
        guard result == SQLITE_ROW else {
            throw StoreError.sqliteStepFailed(message: lastSQLiteMessage())
        }
        guard let cString = sqlite3_column_text(statement, 0) else {
            return nil
        }
        let base64 = String(cString: cString)
        guard let data = Data(base64Encoded: base64) else {
            return nil
        }
        return try decoder.decode(ServerConfig.self, from: data)
    }

    private func createSchemaIfNeeded() throws {
        try execute("""
            CREATE TABLE IF NOT EXISTS watch_light_messages (
                message_id TEXT PRIMARY KEY NOT NULL,
                title TEXT NOT NULL,
                body TEXT NOT NULL,
                image_url TEXT,
                url TEXT,
                severity TEXT,
                received_at REAL NOT NULL,
                is_read INTEGER NOT NULL,
                entity_type TEXT NOT NULL,
                entity_id TEXT,
                notification_request_id TEXT,
                CHECK (length(trim(message_id)) > 0)
            );
            """)
        try execute("CREATE INDEX IF NOT EXISTS idx_watch_light_messages_received_at ON watch_light_messages(received_at DESC, message_id DESC);")
        try execute("CREATE INDEX IF NOT EXISTS idx_watch_light_messages_notification_request_id ON watch_light_messages(notification_request_id);")

        try execute("""
            CREATE TABLE IF NOT EXISTS watch_light_events (
                event_id TEXT PRIMARY KEY NOT NULL,
                title TEXT NOT NULL,
                summary TEXT,
                state TEXT,
                severity TEXT,
                image_url TEXT,
                updated_at REAL NOT NULL,
                CHECK (length(trim(event_id)) > 0)
            );
            """)
        try execute("CREATE INDEX IF NOT EXISTS idx_watch_light_events_updated_at ON watch_light_events(updated_at DESC, event_id DESC);")

        try execute("""
            CREATE TABLE IF NOT EXISTS watch_light_things (
                thing_id TEXT PRIMARY KEY NOT NULL,
                title TEXT NOT NULL,
                summary TEXT,
                attrs_json TEXT,
                image_url TEXT,
                updated_at REAL NOT NULL,
                CHECK (length(trim(thing_id)) > 0)
            );
            """)
        try execute("CREATE INDEX IF NOT EXISTS idx_watch_light_things_updated_at ON watch_light_things(updated_at DESC, thing_id DESC);")

        try execute("""
            CREATE TABLE IF NOT EXISTS app_settings (
                id TEXT PRIMARY KEY NOT NULL,
                watch_provisioning_server_config_data_base64 TEXT,
                updated_at REAL NOT NULL
            );
            """)
        try ensureAppSettingsProvisioningColumn()
    }

    private static func createSchemaIfNeeded(db: OpaquePointer) throws {
        try execute("""
            CREATE TABLE IF NOT EXISTS watch_light_messages (
                message_id TEXT PRIMARY KEY NOT NULL,
                title TEXT NOT NULL,
                body TEXT NOT NULL,
                image_url TEXT,
                url TEXT,
                severity TEXT,
                received_at REAL NOT NULL,
                is_read INTEGER NOT NULL,
                entity_type TEXT NOT NULL,
                entity_id TEXT,
                notification_request_id TEXT,
                CHECK (length(trim(message_id)) > 0)
            );
            """, db: db)
        try execute("CREATE INDEX IF NOT EXISTS idx_watch_light_messages_received_at ON watch_light_messages(received_at DESC, message_id DESC);", db: db)
        try execute("CREATE INDEX IF NOT EXISTS idx_watch_light_messages_notification_request_id ON watch_light_messages(notification_request_id);", db: db)

        try execute("""
            CREATE TABLE IF NOT EXISTS watch_light_events (
                event_id TEXT PRIMARY KEY NOT NULL,
                title TEXT NOT NULL,
                summary TEXT,
                state TEXT,
                severity TEXT,
                image_url TEXT,
                updated_at REAL NOT NULL,
                CHECK (length(trim(event_id)) > 0)
            );
            """, db: db)
        try execute("CREATE INDEX IF NOT EXISTS idx_watch_light_events_updated_at ON watch_light_events(updated_at DESC, event_id DESC);", db: db)

        try execute("""
            CREATE TABLE IF NOT EXISTS watch_light_things (
                thing_id TEXT PRIMARY KEY NOT NULL,
                title TEXT NOT NULL,
                summary TEXT,
                attrs_json TEXT,
                image_url TEXT,
                updated_at REAL NOT NULL,
                CHECK (length(trim(thing_id)) > 0)
            );
            """, db: db)
        try execute("CREATE INDEX IF NOT EXISTS idx_watch_light_things_updated_at ON watch_light_things(updated_at DESC, thing_id DESC);", db: db)

        try execute("""
            CREATE TABLE IF NOT EXISTS app_settings (
                id TEXT PRIMARY KEY NOT NULL,
                watch_provisioning_server_config_data_base64 TEXT,
                updated_at REAL NOT NULL
            );
            """, db: db)
        try ensureAppSettingsProvisioningColumn(db: db)
    }

    private func ensureAppSettingsProvisioningColumn() throws {
        let statement = try prepare("PRAGMA table_info(app_settings);")
        defer { sqlite3_finalize(statement) }
        var hasColumn = false
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let cString = sqlite3_column_text(statement, 1) else { continue }
            if String(cString: cString) == "watch_provisioning_server_config_data_base64" {
                hasColumn = true
                break
            }
        }
        if !hasColumn {
            try execute("ALTER TABLE app_settings ADD COLUMN watch_provisioning_server_config_data_base64 TEXT;")
        }
    }

    private static func ensureAppSettingsProvisioningColumn(db: OpaquePointer) throws {
        let statement = try prepare("PRAGMA table_info(app_settings);", db: db)
        defer { sqlite3_finalize(statement) }
        var hasColumn = false
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let cString = sqlite3_column_text(statement, 1) else { continue }
            if String(cString: cString) == "watch_provisioning_server_config_data_base64" {
                hasColumn = true
                break
            }
        }
        if !hasColumn {
            try execute("ALTER TABLE app_settings ADD COLUMN watch_provisioning_server_config_data_base64 TEXT;", db: db)
        }
    }

    private func execute(_ sql: String) throws {
        guard let db else { throw StoreError.sqliteOpenFailed(code: SQLITE_MISUSE) }
        var errorPointer: UnsafeMutablePointer<CChar>?
        defer {
            if let errorPointer {
                sqlite3_free(errorPointer)
            }
        }
        let result = sqlite3_exec(db, sql, nil, nil, &errorPointer)
        guard result == SQLITE_OK else {
            let message = errorPointer.map { String(cString: $0) } ?? lastSQLiteMessage()
            throw StoreError.sqliteStepFailed(message: message)
        }
    }

    private static func execute(_ sql: String, db: OpaquePointer) throws {
        var errorPointer: UnsafeMutablePointer<CChar>?
        defer {
            if let errorPointer {
                sqlite3_free(errorPointer)
            }
        }
        let result = sqlite3_exec(db, sql, nil, nil, &errorPointer)
        guard result == SQLITE_OK else {
            let message = errorPointer.map { String(cString: $0) } ?? lastSQLiteMessage(db: db)
            throw StoreError.sqliteStepFailed(message: message)
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        guard let db else { throw StoreError.sqliteOpenFailed(code: SQLITE_MISUSE) }
        var statement: OpaquePointer?
        let result = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
        guard result == SQLITE_OK, let statement else {
            throw StoreError.sqlitePrepareFailed(message: lastSQLiteMessage())
        }
        return statement
    }

    private static func prepare(_ sql: String, db: OpaquePointer) throws -> OpaquePointer {
        var statement: OpaquePointer?
        let result = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
        guard result == SQLITE_OK, let statement else {
            throw StoreError.sqlitePrepareFailed(message: lastSQLiteMessage(db: db))
        }
        return statement
    }

    private func stepDone(_ statement: OpaquePointer?) throws {
        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE else {
            throw StoreError.sqliteStepFailed(message: lastSQLiteMessage())
        }
    }

    private func bindText(_ statement: OpaquePointer?, index: Int32, value: String?) throws {
        let result: Int32
        if let value {
            result = value.withCString { pointer in
                sqlite3_bind_text(statement, index, pointer, -1, SQLITE_TRANSIENT)
            }
        } else {
            result = sqlite3_bind_null(statement, index)
        }
        guard result == SQLITE_OK else {
            throw StoreError.sqliteStepFailed(message: lastSQLiteMessage())
        }
    }

    private func lastSQLiteMessage() -> String {
        guard let db, let cMessage = sqlite3_errmsg(db) else {
            return "Unknown SQLite error"
        }
        return String(cString: cMessage)
    }

    private static func lastSQLiteMessage(db: OpaquePointer) -> String {
        guard let cMessage = sqlite3_errmsg(db) else {
            return "Unknown SQLite error"
        }
        return String(cString: cMessage)
    }

    private static func storeURL(
        fileManager: FileManager,
        appGroupIdentifier: String,
        filename: String
    ) throws -> URL {
        let directory = try AppConstants.appLocalDatabaseDirectory(
            fileManager: fileManager,
            appGroupIdentifier: appGroupIdentifier
        )
        return directory.appendingPathComponent(filename)
    }
}
