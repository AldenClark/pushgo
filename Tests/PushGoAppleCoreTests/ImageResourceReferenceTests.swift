import Foundation
import GRDB
import Testing
@testable import PushGoAppleCore

struct ImageResourceReferenceTests {
    @Test func conflictingNotificationCannotBypassIdentityChecksThroughTheWaitingArea() async throws {
        try await withIsolatedAutomationStorage { root, group in
            let store = LocalDataStore(appGroupIdentifier: group, spotlightIndexer: nil)
            let original = PushMessage(messageId: "visible-before-parent-spoof", title: "Original", body: "Saved body",
                receivedAt: Date(timeIntervalSince1970: 1_800_000_000), rawPayload: [
                    "base_url": AnyCodable("https://gateway.invalid/a"), "provider_device_key": AnyCodable("recipient"),
                    "delivery_id": AnyCodable("parent-spoof-delivery"), "_notificationRequestId": AnyCodable("parent-spoof-request")])
            _ = try await store.persistNotificationMessageIfNeeded(original)
            let owner = try #require(await store.imageResourceSnapshot(owner: .message(localID: original.id)))
            var conflict = original
            conflict.rawPayload["thing_id"] = AnyCodable("missing-parent-must-not-own-this-delivery")
            let healthy = PushMessage(messageId: "healthy-beside-parent-spoof", title: "Healthy", body: "Persisted independently")
            let outcomes = try await store.persistNotificationMessagesIfNeeded([conflict, healthy], isolatingIdentityConflicts: true)
            if case .identityConflict = outcomes[0] {} else {
                Issue.record("A changed parent cannot turn a conflicting existing notification into ACK-safe pending responsibility.")
            }
            guard case .persisted = outcomes[1] else { Issue.record("The independent healthy item must persist."); return }
            let queue = try DatabaseQueue(path: root.appendingPathComponent("app-local/" + group + "/Database/" + AppConstants.databaseStoreFilename).path)
            let pending = try await queue.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM pending_inbound_messages") }
            #expect(pending == 0)
            #expect(try await store.loadMessage(id: original.id)?.body == original.body)
            #expect(try await store.imageResourceSnapshot(owner: owner.owner) == owner)
        }
    }

    @Test func remoteNotificationReplayCannotReplaceCanonicalContentOrBindings() async throws {
        try await withIsolatedLocalDataStore { store, _ in
            let original = PushMessage(messageId: "fixed-remote-image", title: "Original title", body: "Original body",
                receivedAt: Date(timeIntervalSince1970: 1_800_000_000), rawPayload: [
                    "base_url": AnyCodable("https://gateway.invalid/one"),
                    "provider_device_key": AnyCodable("recipient"),
                    "delivery_id": AnyCodable("fixed-delivery"),
                    "_notificationRequestId": AnyCodable("fixed-request"),
                    "images": AnyCodable("[\"https://images.invalid/a.png?signature=one\"]"),
                ])
            #expect(original.imageURLs.count == 1)
            _ = try await store.persistNotificationMessageIfNeeded(original)
            let snapshot = try #require(await store.imageResourceSnapshot(owner: .message(localID: original.id)))
            let data = Data("original bytes acquired for the old message".utf8), hash = imageContentHash(data)
            let file = SharedImageCache.originalFileURL(contentHash: hash)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: file, options: .atomic)
            #expect(try await store.bindImageResource(snapshot: snapshot, requestKey: "original-url", contentHash: hash))

            var replay = original
            replay.title = "Conflicting title"
            replay.body = "Conflicting body"
            replay.receivedAt = replay.receivedAt.addingTimeInterval(60)
            replay.rawPayload["images"] = AnyCodable("[\"https://images.invalid/b.png?signature=two\"]")
            await #expect(throws: (any Error).self) {
                _ = try await store.persistNotificationMessageIfNeeded(replay)
            }
            let stored = try #require(await store.loadMessage(id: original.id))
            #expect(stored.title == original.title)
            #expect(stored.body == original.body)
            #expect(stored.imageURLs == original.imageURLs)
            #expect(try await store.imageResourceSnapshot(owner: .message(localID: original.id)) == snapshot)
            #expect(try await store.imageResourceBinding(snapshot: snapshot, requestKey: "original-url") == hash)
        }
    }

    @Test func unchangedReplayAndIsolatedConflictsKeepTheOriginalVersionThroughReopen() async throws {
        try await withIsolatedAutomationStorage { root, group in
            let store = LocalDataStore(appGroupIdentifier: group, spotlightIndexer: nil)
            let original = PushMessage(messageId: "immutable-reopen", title: "Saved title", body: "Saved Markdown ![image](https://example.com/image.png)",
                receivedAt: Date(timeIntervalSince1970: 1_800_000_000), rawPayload: [
                    "base_url": AnyCodable("https://gateway.invalid/a"), "provider_device_key": AnyCodable("device"),
                    "delivery_id": AnyCodable("reopen-delivery"), "_notificationRequestId": AnyCodable("reopen-request"),
                    "images": AnyCodable("[\"https://example.com/image.png?signature=original\"]")])
            _ = try await store.persistNotificationMessageIfNeeded(original)
            try await store.setMessageReadState(id: original.id, isRead: true)
            let snapshot = try #require(await store.imageResourceSnapshot(owner: .message(localID: original.id)))
            var replay = original
            replay.id = UUID()
            replay.receivedAt = replay.receivedAt.addingTimeInterval(600)
            guard case let .duplicateRequest(existing) = try await store.persistNotificationMessageIfNeeded(replay) else {
                Issue.record("The same content must remain an ACK-safe duplicate."); return
            }
            #expect(existing.id == original.id && existing.isRead)
            #expect(existing.receivedAt == original.receivedAt)

            for change in 0..<3 {
                var conflict = replay
                if change == 0 { conflict.body = "Changed bytes with the SAME image URL" }
                if change == 1 { conflict.rawPayload["images"] = AnyCodable("[\"https://example.com/new.png?signature=new\"]") }
                if change == 2 { conflict.messageId = "different-message-with-the-same-notification" }
                let independent = PushMessage(messageId: "healthy-\(change)", title: "healthy", body: "healthy")
                let results = try await store.persistNotificationMessagesIfNeeded([conflict, independent], isolatingIdentityConflicts: true)
                guard case .identityConflict = results[0], case .persisted = results[1] else {
                    Issue.record("Only the conflicting identity must remain unACKed; the healthy item must persist."); return
                }
            }
            var conflicting = replay
            conflicting.body = "A batch may not partially commit before this conflict"
            await #expect(throws: (any Error).self) {
                _ = try await store.persistNotificationMessagesIfNeeded([
                    PushMessage(messageId: "rolled-back-healthy", title: "rolled back", body: "absent"), conflicting])
            }
            #expect(try await store.loadMessage(messageId: "rolled-back-healthy") == nil)
            LocalDataStore.releaseSharedResourcesForTesting(storageRootURL: root)
            let reopened = LocalDataStore(appGroupIdentifier: group, spotlightIndexer: nil)
            let final = try #require(await reopened.loadMessage(id: original.id))
            #expect(final.body == original.body && final.imageURLs == original.imageURLs && final.isRead)
            #expect(try await reopened.imageResourceSnapshot(owner: .message(localID: original.id)) == snapshot)
        }
    }

    @Test func legalLocalImageUpdateRetiresOnlyItsOwnBindingsAtomically() async throws {
        try await withIsolatedAutomationStorage { root, group in
            let store = LocalDataStore(appGroupIdentifier: group, spotlightIndexer: nil)
            let first = PushMessage(messageId: "local-image-update", title: "first", body: "Before local decryption/recovery",
                receivedAt: Date(timeIntervalSince1970: 1_800_000_000))
            let peer = PushMessage(messageId: "shared-original-peer", title: "peer", body: "peer")
            try await store.saveMessages([first, peer])
            let old = try #require(await store.imageResourceSnapshot(owner: .message(localID: first.id)))
            let other = try #require(await store.imageResourceSnapshot(owner: .message(localID: peer.id)))
            let bytes = Data("shared original".utf8), hash = imageContentHash(bytes)
            let file = SharedImageCache.originalFileURL(contentHash: hash)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes.write(to: file, options: .atomic)
            #expect(try await store.bindImageResource(snapshot: old, requestKey: "same-url", contentHash: hash))
            #expect(try await store.bindImageResource(snapshot: other, requestKey: "same-url", contentHash: hash))
            let path = root.appendingPathComponent("app-local/" + group + "/Database/" + AppConstants.databaseStoreFilename)
            let queue = try DatabaseQueue(path: path.path)
            try await queue.write { db in
                try db.execute(sql: "CREATE TRIGGER reject_local_content_update BEFORE UPDATE OF body ON messages BEGIN SELECT RAISE(ABORT, 'controlled-write-failure'); END;")
            }
            var updated = first
            updated.body = "Recovered ![image](https://example.com/other.png)"
            updated.receivedAt = first.receivedAt.addingTimeInterval(1)
            await #expect(throws: (any Error).self) { try await store.saveMessage(updated) }
            #expect(try await store.imageResourceSnapshot(owner: old.owner) == old)
            #expect(try await store.imageResourceBinding(snapshot: old, requestKey: "same-url") == hash)
            try await queue.write { db in try db.execute(sql: "DROP TRIGGER reject_local_content_update;") }
            try await store.saveMessage(updated)
            // Check via an independent connection before any later snapshot
            // read can repair metadata: the original commit must release it.
            let ownRefCount = try await queue.read { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM image_content_references WHERE message_id=?", arguments: [first.id.uuidString])
            }
            #expect(ownRefCount == 0)
            #expect(!(try await store.bindImageResource(snapshot: old, requestKey: "late-download", contentHash: hash)))
            let current = try #require(await store.imageResourceSnapshot(owner: old.owner))
            #expect(current.stamp != old.stamp)
            #expect(try await store.imageResourceBinding(snapshot: other, requestKey: "same-url") == hash)
            #expect(!(try await store.collectImageResource(contentHash: hash, remove: {})))
            LocalDataStore.releaseSharedResourcesForTesting(storageRootURL: root)
            let reopened = LocalDataStore(appGroupIdentifier: group, spotlightIndexer: nil)
            #expect(try await reopened.imageResourceSnapshot(owner: current.owner) == current)
            #expect(!(try await reopened.bindImageResource(snapshot: old, requestKey: "late-after-restart", contentHash: hash)))
            #expect(try await reopened.loadMessage(id: first.id)?.body == updated.body)
            _ = try await reopened.deleteConfirmedLocalData(try await reopened.prepareLocalDeletion(intent: .messages(ids: [peer.id])))
            #expect(try await reopened.collectImageResource(contentHash: hash, remove: {}))
        }
    }

    @Test func localTextEnrichmentAndRetainedURLsKeepAcquiredBytes() async throws {
        try await withIsolatedLocalDataStore { store, _ in
            let a = "https://example.com/a.png?signature=one"
            let b = "https://example.com/b.png?signature=two"
            let c = "https://example.com/c.png?signature=three"
            var message = PushMessage(messageId: "retained-image-inputs", title: "title", body: "![A](\(a))\n![B](\(b))",
                receivedAt: Date(timeIntervalSince1970: 1_800_000_000))
            try await store.saveMessage(message)
            let first = try #require(await store.imageResourceSnapshot(owner: .message(localID: message.id)))
            let bytes = Data("already acquired A and B bytes".utf8), hash = imageContentHash(bytes)
            let file = SharedImageCache.originalFileURL(contentHash: hash)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes.write(to: file, options: .atomic)
            let keyA = imageContentHash(Data(a.utf8)), keyB = imageContentHash(Data(b.utf8))
            #expect(try await store.bindImageResource(snapshot: first, requestKey: keyA, contentHash: hash))
            #expect(try await store.bindImageResource(snapshot: first, requestKey: keyB, contentHash: hash))
            message.body = "Local decoded text changes, image dependencies stay fixed.\n![B](\(b))\n![A](\(a))"
            message.receivedAt = message.receivedAt.addingTimeInterval(1)
            try await store.saveMessage(message)
            #expect(try await store.imageResourceSnapshot(owner: first.owner) == first)
            #expect(try await store.imageResourceBinding(snapshot: first, requestKey: keyA) == hash)
            message.body = "![A](\(a))\n![C](\(c))"
            message.receivedAt = message.receivedAt.addingTimeInterval(1)
            try await store.saveMessage(message)
            let second = try #require(await store.imageResourceSnapshot(owner: first.owner))
            #expect(second.stamp != first.stamp)
            #expect(try await store.imageResourceBinding(snapshot: second, requestKey: keyA) == hash)
            #expect(try await store.imageResourceBinding(snapshot: second, requestKey: keyB) == nil)
            #expect(!(try await store.bindImageResource(snapshot: first, requestKey: keyB, contentHash: hash)))
            #expect(!(try await store.collectImageResource(contentHash: hash, remove: {})))
        }
    }

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
            // Fixed exactly representable time keeps this scope oracle apart
            // from a Date -> stored milliseconds -> Date rounding difference.
            let original = PushMessage(messageId: "resource-enrichment", title: "original", body: "body",
                                       receivedAt: Date(timeIntervalSince1970: 1_800_000_000.125))
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
            let storedAfterSwitch = try #require(await store.loadMessage(id: original.id))
            #expect(storedAfterSwitch.providerSourceBaseURL == "https://example.com/different-origin")
            let switched = try #require(await store.imageResourceSnapshot(owner: .message(localID: original.id)))
            #expect(switched.stamp != current.stamp)
            #expect(try await store.imageResourceBinding(snapshot: switched, requestKey: "full-url-hash") == nil)
        }
    }

    @Test func resourceOwnerUsesStoredGatewayRecipientAndRetainsFullSourceScope() async throws {
        try await withIsolatedLocalDataStore { store, _ in
            // Distinct legitimate deliveries enter the real ingress adapter;
            // changing current settings is not proof of stored ownership.
            let outcomes = await NotificationPersistenceCoordinator.persistRemotePayloadsIfNeeded([
                .init(payload: ["entity_type": "message", "message_id": "resource-scope-a",
                    "delivery_id": "resource-delivery-a", "title": "a", "body": "a",
                    "base_url": "https://example.com/alpha", "provider_device_key": "device-a"], requestIdentifier: "resource-delivery-a"),
                .init(payload: ["entity_type": "message", "message_id": "resource-scope-b",
                    "delivery_id": "resource-delivery-b", "title": "b", "body": "b",
                    "base_url": "https://example.com/beta", "provider_device_key": "device-a"], requestIdentifier: "resource-delivery-b"),
            ], dataStore: store)
            #expect(outcomes.count == 2 && outcomes.allSatisfy { ProviderIngressPersistenceResult($0).allowsAck })
            let a = try #require(await store.loadMessage(messageId: "resource-scope-a"))
            let b = try #require(await store.loadMessage(messageId: "resource-scope-b"))
            let first = try #require(await store.imageResourceSnapshot(owner: .message(localID: a.id)))
            let repeatSnapshot = try #require(await store.imageResourceSnapshot(owner: .message(localID: a.id)))
            let other = try #require(await store.imageResourceSnapshot(owner: .message(localID: b.id)))
            #expect(first == repeatSnapshot)
            #expect(first.scope != other.scope)
            #expect(first.canonicalID == a.id.uuidString)
            let bytes = Data("scope-specific-acquired-content".utf8), hash = imageContentHash(bytes)
            let file = SharedImageCache.originalFileURL(contentHash: hash)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes.write(to: file, options: .atomic)
            #expect(try await store.bindImageResource(snapshot: first, requestKey: "same-full-url", contentHash: hash))
            #expect(try await store.imageResourceBinding(snapshot: other, requestKey: "same-full-url") == nil)
        }
    }
}
