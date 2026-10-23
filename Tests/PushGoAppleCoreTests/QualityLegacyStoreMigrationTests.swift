import Foundation
import GRDB
import Testing
@testable import PushGoAppleCore

struct QualityLegacyStoreMigrationTests {
    @Test
    func legacyV17QualityFixtureMigratesWatchWindowOnceAndPreservesContentOnReopen() async throws {
        try await withIsolatedAutomationStorage { root, appGroupIdentifier in
            let directory = try AppConstants.appLocalDatabaseDirectory(appGroupIdentifier: appGroupIdentifier)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let databaseURL = directory.appendingPathComponent(AppConstants.databaseStoreFilename)
            try LocalDataStore.prepareQualityLegacyStoreForTesting(storeURL: databaseURL)
            let database = try DatabaseQueue(path: databaseURL.path)
            let legacyHasWatchColumn = try await database.read { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM pragma_table_info('app_settings') WHERE name = 'watch_alert_window_minutes'") != 0
            }
            #expect(!legacyHasWatchColumn)

            let store = LocalDataStore(appGroupIdentifier: appGroupIdentifier, spotlightIndexer: nil)
            #expect(store.storageState.mode == .persistent)
            let legacy = try await store.loadMessage(messageId: "quality-legacy-v17-message")
            #expect(legacy?.title == "Legacy Upgrade Message")
            #expect(legacy?.body == "Preserved through the production database migration.")
            let migrationCount = try await database.read { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM grdb_migrations WHERE identifier = 'v27_watch_standalone_alert_window'")
            }
            #expect(migrationCount == 1)
            let deliveryIndexCount = try await database.read { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sqlite_master WHERE type = 'index' AND name = 'idx_operation_ledger_delivery_only_expiry'")
            }
            #expect(deliveryIndexCount == 1)
            let watchColumnCount = try await database.read { db in
                // The production Store migrated through another connection;
                // read SQLite directly rather than this connection's schema cache.
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM pragma_table_info('app_settings') WHERE name = 'watch_alert_window_minutes'")
            }
            #expect(watchColumnCount == 1)
            LocalDataStore.releaseSharedResourcesForTesting(storageRootURL: root)
            let reopened = LocalDataStore(appGroupIdentifier: appGroupIdentifier, spotlightIndexer: nil)
            #expect(reopened.storageState.mode == .persistent)
            #expect(try await reopened.loadMessage(messageId: "quality-legacy-v17-message")?.body == legacy?.body)
            #expect(try await database.read { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM grdb_migrations WHERE identifier = 'v28_delivery_only_processed_retention'")
            } == 1)
        }
    }

}
