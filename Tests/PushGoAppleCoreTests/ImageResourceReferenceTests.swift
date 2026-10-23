import Foundation
import GRDB
import Testing
@testable import PushGoAppleCore

struct ImageResourceReferenceTests {
    @Test func confirmedDeletionReleasesOnlyItsOwnOriginalAndRejectsLateBind() async throws {
        try await withIsolatedLocalDataStore { store, _ in
            let first = PushMessage(messageId: "resource-first", title: "first", body: "content")
            let second = PushMessage(messageId: "resource-second", title: "second", body: "content")
            try await store.saveMessages([first, second])
            let a = try #require(await store.imageResourceSnapshot(owner: .message(localID: first.id)))
            let b = try #require(await store.imageResourceSnapshot(owner: .message(localID: second.id)))
            let data = Data("stand-in atomic original".utf8)
            let hash = imageContentHash(data)
            let file = SharedImageCache.originalFileURL(contentHash: hash)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: file, options: .atomic)
            #expect(try await store.bindImageResource(snapshot: a, requestKey: "url-first", contentHash: hash))
            #expect(try await store.bindImageResource(snapshot: b, requestKey: "url-second", contentHash: hash))
            let confirmation = try await store.prepareLocalDeletion(intent: .messages(ids: [first.id]))
            _ = try await store.deleteConfirmedLocalData(confirmation)
            #expect(try await store.imageResourceBinding(snapshot: a, requestKey: "url-first") == nil)
            #expect(!(try await store.bindImageResource(snapshot: a, requestKey: "late", contentHash: hash)))
            #expect(try await store.imageResourceBinding(snapshot: b, requestKey: "url-second") == hash)
            #expect(!(try await store.collectImageResource(contentHash: hash, remove: {})))
            let final = try await store.prepareLocalDeletion(intent: .messages(ids: [second.id]))
            _ = try await store.deleteConfirmedLocalData(final)
            #expect(try await store.collectImageResource(contentHash: hash, remove: { try? FileManager.default.removeItem(at: file) }))
            #expect(!FileManager.default.fileExists(atPath: file.path))
        }
    }

    @Test func deleteRecreateIdenticalCanonicalValuesGetsANewResourceGeneration() async throws {
        try await withIsolatedLocalDataStore { store, _ in
            let original = PushMessage(messageId: "resource-same-values", title: "same", body: "same", receivedAt: Date(timeIntervalSince1970: 1_800_000_000))
            try await store.saveMessage(original)
            let old = try #require(await store.imageResourceSnapshot(owner: .message(localID: original.id)))
            // Internal reset-style deletion intentionally has no replay tombstone.
            try await store.deleteMessage(id: original.id)
            try await store.saveMessage(original)
            let current = try #require(await store.imageResourceSnapshot(owner: .message(localID: original.id)))
            #expect(old.stamp != current.stamp)
            #expect(old.scope != current.scope)
            #expect(try await store.imageResourceBinding(snapshot: old, requestKey: "url") == nil)
            #expect(!(try await store.bindImageResource(snapshot: old, requestKey: "url", contentHash: String(repeating: "a", count: 64))))
        }
    }

    @Test func v28CacheAndCanonicalDataRemainIntactWhenResourceReferencesAreAdded() async throws {
        try await withIsolatedAutomationStorage { root, group in
            let store = LocalDataStore(appGroupIdentifier: group, spotlightIndexer: nil)
            let message = PushMessage(messageId: "resource-v28-existing", title: "existing", body: "unchanged")
            try await store.saveMessage(message)
            let expected = try #require(await store.loadMessage(id: message.id))
            _ = await store.drainDerivedWorkForBackgroundRefresh()
            let database = root.appendingPathComponent("app-local/" + group + "/Database/" + AppConstants.databaseStoreFilename)
            let queue = try DatabaseQueue(path: database.path)
            try await queue.write { db in
                try db.execute(sql: "DROP TRIGGER image_references_after_message_delete; DROP TABLE image_content_references; DROP TABLE image_resource_owners; DELETE FROM grdb_migrations WHERE identifier='v29_immutable_image_content_references';")
            }
            let legacy = root.appendingPathComponent("app-local/" + group + "/Cache/Images", isDirectory: true)
            try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
            let legacyBytes = Data("old unproven image cache must not be erased".utf8)
            let legacyFile = legacy.appendingPathComponent(String(repeating: "a", count: 64) + ".png")
            try legacyBytes.write(to: legacyFile)
            LocalDataStore.releaseSharedResourcesForTesting(storageRootURL: root)
            let reopened = LocalDataStore(appGroupIdentifier: group, spotlightIndexer: nil)
            #expect(try await reopened.loadMessage(id: message.id) == expected)
            #expect(try await reopened.imageResourceSnapshot(owner: .message(localID: message.id)) != nil)
            #expect(try Data(contentsOf: legacyFile) == legacyBytes)
            let refs = try await queue.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM image_content_references") }
            #expect(refs == 0)
        }
    }

    @Test func replayTimestampAndProvenanceEnrichmentDoNotReplaceAnAcquiredVersion() async throws {
        try await withIsolatedLocalDataStore { store, _ in
            let original = PushMessage(messageId: "resource-enrichment", title: "original", body: "body")
            try await store.saveMessage(original)
            let first = try #require(await store.imageResourceSnapshot(owner: .message(localID: original.id)))
            let bytes = Data("existing immutable original".utf8), hash = imageContentHash(bytes)
            let file = SharedImageCache.originalFileURL(contentHash: hash)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes.write(to: file, options: .atomic)
            #expect(try await store.bindImageResource(snapshot: first, requestKey: "full-url-hash", contentHash: hash))
            var enriched = original
            enriched.receivedAt = original.receivedAt.addingTimeInterval(60)
            enriched.rawPayload["base_url"] = AnyCodable("https://example.com/alpha")
            enriched.rawPayload["provider_device_key"] = AnyCodable("original-recipient")
            enriched.rawPayload["delivery_id"] = AnyCodable("proven-delivery")
            try await store.saveMessage(enriched)
            let current = try #require(await store.imageResourceSnapshot(owner: .message(localID: original.id)))
            #expect(current.stamp == first.stamp)
            #expect(current.scope != first.scope)
            #expect(try await store.imageResourceBinding(snapshot: current, requestKey: "full-url-hash") == hash)
            #expect(try await store.imageResourceBinding(snapshot: first, requestKey: "full-url-hash") == nil)
            enriched.rawPayload["base_url"] = AnyCodable("https://example.com/different-origin")
            try await store.saveMessage(enriched)
            let switched = try #require(await store.imageResourceSnapshot(owner: .message(localID: original.id)))
            #expect(switched.stamp != current.stamp)
            #expect(try await store.imageResourceBinding(snapshot: switched, requestKey: "full-url-hash") == nil)
        }
    }

    @Test func resourceOwnerUsesStoredGatewayRecipientAndRetainsFullSourceScope() async throws {
        try await withIsolatedLocalDataStore { store, _ in
            let a = PushMessage(messageId: "resource-scope-a", title: "a", body: "a", rawPayload: [
                "base_url": AnyCodable("https://example.com/alpha"),
                "provider_device_key": AnyCodable("device-a")])
            let b = PushMessage(messageId: "resource-scope-b", title: "b", body: "b", rawPayload: [
                "base_url": AnyCodable("https://example.com/beta"),
                "provider_device_key": AnyCodable("device-a")])
            try await store.saveMessages([a, b])
            let first = try #require(await store.imageResourceSnapshot(owner: .message(localID: a.id)))
            let repeatSnapshot = try #require(await store.imageResourceSnapshot(owner: .message(localID: a.id)))
            let other = try #require(await store.imageResourceSnapshot(owner: .message(localID: b.id)))
            #expect(first == repeatSnapshot)
            #expect(first.scope != other.scope)
            #expect(first.canonicalID == a.id.uuidString)
        }
    }
}
