import Foundation
import GRDB

actor WatchLightNotificationStore {
    private enum StoreError: Error {
        case missingAppGroup(String)
    }

    private let dbQueue: DatabaseQueue
    private let decoder: JSONDecoder

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

        var configuration = Configuration()
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA journal_mode = WAL;")
            try db.execute(sql: "PRAGMA synchronous = NORMAL;")
            try db.execute(sql: "PRAGMA foreign_keys = ON;")
            try db.execute(sql: "PRAGMA busy_timeout = 5000;")
        }

        dbQueue = try DatabaseQueue(path: storeURL.path, configuration: configuration)
        try Self.migrator.migrate(dbQueue)
    }

    func upsert(_ payload: WatchLightPayload) throws {
        try dbQueue.write { db in
            switch payload {
            case let .message(message):
                try db.execute(
                    sql: """
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
                        """,
                    arguments: [
                        message.messageId,
                        message.title,
                        message.body,
                        message.imageURL?.absoluteString,
                        message.url?.absoluteString,
                        message.severity,
                        message.receivedAt.timeIntervalSince1970,
                        message.isRead ? 1 : 0,
                        message.entityType,
                        message.entityId,
                        message.notificationRequestId,
                    ]
                )
            case let .event(event):
                try db.execute(
                    sql: """
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
                        """,
                    arguments: [
                        event.eventId,
                        event.title,
                        event.summary,
                        event.state,
                        event.severity,
                        event.imageURL?.absoluteString,
                        event.updatedAt.timeIntervalSince1970,
                    ]
                )
            case let .thing(thing):
                try db.execute(
                    sql: """
                        INSERT INTO watch_light_things (
                            thing_id, title, summary, attrs_json, image_url, updated_at
                        ) VALUES (?, ?, ?, ?, ?, ?)
                        ON CONFLICT(thing_id) DO UPDATE SET
                            title = excluded.title,
                            summary = excluded.summary,
                            attrs_json = excluded.attrs_json,
                            image_url = excluded.image_url,
                            updated_at = excluded.updated_at;
                        """,
                    arguments: [
                        thing.thingId,
                        thing.title,
                        thing.summary,
                        thing.attrsJSON,
                        thing.imageURL?.absoluteString,
                        thing.updatedAt.timeIntervalSince1970,
                    ]
                )
            }
        }
        DarwinNotificationPoster.post(name: AppConstants.messageSyncNotificationName)
    }

    func unreadCount() throws -> Int {
        try dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM watch_light_messages WHERE is_read = 0;") ?? 0
        }
    }

    func loadProvisioningServerConfig() throws -> ServerConfig? {
        try dbQueue.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT watch_provisioning_server_config_data_base64 FROM app_settings WHERE id = 'default' LIMIT 1;"
            ) else {
                return nil
            }
            let base64: String? = row["watch_provisioning_server_config_data_base64"]
            guard let base64,
                  let data = Data(base64Encoded: base64)
            else {
                return nil
            }
            return try decoder.decode(ServerConfig.self, from: data)
        }
    }

    private static let migrator: DatabaseMigrator = {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("watch_nse_light_store_v1") { db in
            try db.execute(sql: """
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
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_watch_light_messages_received_at ON watch_light_messages(received_at DESC, message_id DESC);")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_watch_light_messages_notification_request_id ON watch_light_messages(notification_request_id);")

            try db.execute(sql: """
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
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_watch_light_events_updated_at ON watch_light_events(updated_at DESC, event_id DESC);")

            try db.execute(sql: """
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
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_watch_light_things_updated_at ON watch_light_things(updated_at DESC, thing_id DESC);")

            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS app_settings (
                    id TEXT PRIMARY KEY NOT NULL,
                    watch_provisioning_server_config_data_base64 TEXT,
                    updated_at REAL NOT NULL
                );
                """)
        }
        migrator.registerMigration("watch_nse_light_store_v2_provisioning_columns") { db in
            let existingColumns = Set(try Row.fetchAll(db, sql: "PRAGMA table_info(app_settings);").compactMap {
                $0["name"] as String?
            })
            let pendingColumns: [(name: String, sqlType: String)] = [
                ("watch_provisioning_server_config_data_base64", "TEXT"),
            ]
            for column in pendingColumns where !existingColumns.contains(column.name) {
                try db.execute(sql: "ALTER TABLE app_settings ADD COLUMN \(column.name) \(column.sqlType);")
            }
        }
        migrator.registerMigration("watch_nse_light_store_v3_rebuild_snake_case_schema") { db in
            // No backward-compatibility for legacy camelCase local schema.
            try db.execute(sql: "DROP TABLE IF EXISTS watch_light_things;")
            try db.execute(sql: "DROP TABLE IF EXISTS watch_light_events;")
            try db.execute(sql: "DROP TABLE IF EXISTS watch_light_messages;")
            try db.execute(sql: "DROP TABLE IF EXISTS app_settings;")

            try db.execute(sql: """
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
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_watch_light_messages_received_at ON watch_light_messages(received_at DESC, message_id DESC);")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_watch_light_messages_notification_request_id ON watch_light_messages(notification_request_id);")

            try db.execute(sql: """
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
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_watch_light_events_updated_at ON watch_light_events(updated_at DESC, event_id DESC);")

            try db.execute(sql: """
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
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_watch_light_things_updated_at ON watch_light_things(updated_at DESC, thing_id DESC);")

            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS app_settings (
                    id TEXT PRIMARY KEY NOT NULL,
                    watch_provisioning_server_config_data_base64 TEXT,
                    updated_at REAL NOT NULL
                );
                """)
        }
        return migrator
    }()

    private static func storeURL(
        fileManager: FileManager,
        appGroupIdentifier: String,
        filename: String
    ) throws -> URL {
        guard let root = AppConstants.appGroupContainerURL(
            fileManager: fileManager,
            identifier: appGroupIdentifier
        ) else {
            throw StoreError.missingAppGroup(appGroupIdentifier)
        }
        let directory = root.appendingPathComponent("Database", isDirectory: true)
        if !fileManager.fileExists(atPath: directory.path) {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return directory.appendingPathComponent(filename)
    }
}
