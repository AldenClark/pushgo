import Foundation
import SQLite3
import Testing
@testable import PushGoAppleCore

/// Test-only connection deliberately held across suspension while another
/// actor exercises SQLite contention. `SQLITE_OPEN_FULLMUTEX` serializes the C
/// handle, and each instance is used by one lexical test task; `OpaquePointer`
/// cannot express that ownership to Swift's Sendable checker.
private final class SQLiteTestConnection: @unchecked Sendable {
    private var database: OpaquePointer?

    init(url: URL) throws {
        guard sqlite3_open_v2(
            url.path,
            &database,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        ) == SQLITE_OK else {
            throw NSError(domain: "SQLiteTestConnection", code: 1)
        }
    }

    deinit {
        if let database { sqlite3_close(database) }
    }

    func execute(_ sql: String) throws {
        guard let database else { throw NSError(domain: "SQLiteTestConnection", code: 2) }
        var errorPointer: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(database, sql, nil, nil, &errorPointer) == SQLITE_OK else {
            let message = errorPointer.map { String(cString: $0) } ?? "sqlite error"
            sqlite3_free(errorPointer)
            throw NSError(
                domain: "SQLiteTestConnection",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: message]
            )
        }
    }

    func scalarText(_ sql: String) throws -> String? {
        guard let database else { throw NSError(domain: "SQLiteTestConnection", code: 6) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement
        else { throw NSError(domain: "SQLiteTestConnection", code: 7) }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW,
              let value = sqlite3_column_text(statement, 0)
        else { return nil }
        return String(cString: value)
    }

    func payload(entryID: String) throws -> [String: AnyCodable]? {
        guard let database else { throw NSError(domain: "SQLiteTestConnection", code: 4) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            database,
            "SELECT payload_plist FROM ingress_entry WHERE entry_id = ?;",
            -1,
            &statement,
            nil
        ) == SQLITE_OK, let statement else {
            throw NSError(domain: "SQLiteTestConnection", code: 5)
        }
        defer { sqlite3_finalize(statement) }
        _ = entryID.withCString {
            sqlite3_bind_text(statement, 1, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
        guard sqlite3_step(statement) == SQLITE_ROW,
              let bytes = sqlite3_column_blob(statement, 0)
        else { return nil }
        let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0)))
        return try PropertyListDecoder().decode([String: AnyCodable].self, from: data)
    }
}

private func testDeliveryIdentity(
    deliveryId: String,
    baseURL: String = "https://sandbox.pushgo.dev",
    deviceKey: String = "provider-device-key",
    ackContract: ProviderDeliveryAckFailureStore.AckContract = .v2Batch
) -> ProviderDeliveryAckFailureStore.DeliveryIdentity {
    ProviderDeliveryAckFailureStore.DeliveryIdentity(
        deliveryId: deliveryId,
        baseURL: URL(string: baseURL)!,
        deviceKey: deviceKey,
        ackContract: ackContract
    )!
}

// Independent N-1 decode oracle copied from `git show HEAD` at the migration
// boundary. Keep these shapes separate from the current production reader so
// a future-compatible current decoder cannot make the rollback test vacuous.
private struct NMinusOneStoredEntry: Codable {
    let schemaVersion: Int
    let entryId: String
    let createdAtEpochMs: Int64
    let source: String
    let requestIdentifier: String?
    let payload: [String: AnyCodable]
}

private struct NMinusOneStoredAckMarker: Codable {
    let schemaVersion: Int
    let deliveryId: String
    let baseURLString: String?
    let deviceKey: String?
    let ackContract: ProviderDeliveryAckFailureStore.AckContract?
    let attemptCount: Int?
    let stage: ProviderDeliveryAckFailureStore.Stage
    let owner: String?
    let leaseUntilEpochMs: Int64?
    let retryAfterEpochMs: Int64?
    let createdAtEpochMs: Int64
    let updatedAtEpochMs: Int64
    let source: String
}

private func nMinusOneDecodeFiles<T: Decodable>(
    appGroupIdentifier: String,
    directoryName: String,
    fileExtension: String,
    as type: T.Type
) throws -> [(URL, T)] {
    let appGroupURL = try #require(
        AppConstants.appGroupContainerURL(identifier: appGroupIdentifier)
    )
    let directory = appGroupURL
        .appendingPathComponent("Library", isDirectory: true)
        .appendingPathComponent("Application Support", isDirectory: true)
        .appendingPathComponent(directoryName, isDirectory: true)
    let files = ((try? FileManager.default.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: nil,
        options: [.skipsHiddenFiles]
    )) ?? [])
        .filter { $0.pathExtension == fileExtension }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
    let decoder = PropertyListDecoder()
    return files.compactMap { fileURL in
        guard let data = try? Data(contentsOf: fileURL),
              let record = try? decoder.decode(type, from: data)
        else { return nil }
        return (fileURL, record)
    }
}

struct NotificationIngressInboxTests {
    @Test
    func enqueueResultReportsDuplicateWithoutScanningCanonicalMessages() async {
        await withIsolatedAutomationStorage { _, appGroupIdentifier in
            let inbox = NotificationIngressInbox(appGroupIdentifier: appGroupIdentifier)
            let payload: [String: AnyCodable] = [
                "message_id": AnyCodable("inbox-result-message"),
                "title": AnyCodable("Indexed identity"),
            ]
            let redeliveryPayload: [String: AnyCodable] = [
                "message_id": AnyCodable("inbox-result-message"),
                "title": AnyCodable("Indexed identity"),
                "body": AnyCodable("Provider added a display field during redelivery"),
            ]

            let first = await inbox.enqueueWithResult(
                codablePayload: payload,
                requestIdentifier: "inbox-result-request",
                source: "nse"
            )
            let duplicate = await inbox.enqueueWithResult(
                codablePayload: redeliveryPayload,
                requestIdentifier: "inbox-result-redelivery",
                source: "nse"
            )

            #expect(first == .init(accepted: true, inserted: true))
            #expect(duplicate == .init(accepted: true, inserted: false))
        }
    }

    @Test
    func concurrentRedeliveriesAdvanceTheProjectionExactlyOnce() async {
        await withIsolatedAutomationStorage { _, appGroupIdentifier in
            let results = await withTaskGroup(
                of: NotificationIngressInbox.EnqueueResult.self,
                returning: [NotificationIngressInbox.EnqueueResult].self
            ) { group in
                for attempt in 0..<16 {
                    group.addTask {
                        let inbox = NotificationIngressInbox(
                            appGroupIdentifier: appGroupIdentifier
                        )
                        return await inbox.enqueueWithResult(
                            codablePayload: [
                                "message_id": AnyCodable("concurrent-projection-message"),
                                "body": AnyCodable("attempt-\(attempt)"),
                            ],
                            requestIdentifier: "concurrent-request-\(attempt)",
                            source: "nse.concurrent-test"
                        )
                    }
                }
                return await group.reduce(into: []) { $0.append($1) }
            }

            #expect(results.filter { $0.accepted }.count == results.count)
            #expect(results.filter { $0.inserted }.count == 1)
        }
    }

    @Test
    func notificationIngressInboxPersistsEntriesInSQLiteJournal() async throws {
        try await withIsolatedAutomationStorage { _, appGroupIdentifier in
            let inbox = NotificationIngressInbox(appGroupIdentifier: appGroupIdentifier)
            let payload: [AnyHashable: Any] = [
                "message_id": "inbox-msg-001",
                "delivery_id": "inbox-delivery-001",
                "entity_type": "message",
                "title": "Inbox Title",
                "body": "Inbox Body",
                "metadata": [
                    "source": "nse",
                    "attempt": 1,
                ],
            ]

            #expect(
                await inbox.enqueue(
                    payload: payload,
                    requestIdentifier: "req-inbox-001",
                    source: "nse"
                )
            )

            let pending = await inbox.pendingEntries()
            #expect(pending.count == 1)
            guard let first = pending.first else { return }
            #expect(first.record.source == "nse")
            #expect(first.record.requestIdentifier == "req-inbox-001")
            #expect(first.payload["message_id"] as? String == "inbox-msg-001")
            #expect(first.payload["delivery_id"] as? String == "inbox-delivery-001")

            let rawData = try Data(contentsOf: first.fileURL)
            #expect(rawData.starts(with: Data("SQLite format 3\0".utf8)))

            await inbox.markCompleted(first)
            #expect(await inbox.pendingEntries().isEmpty)
        }
    }

    @Test
    func notificationIngressInboxExposesTheNextDurableCanonicalRetryDeadline() async throws {
        try await withIsolatedAutomationStorage { _, appGroupIdentifier in
            let inbox = NotificationIngressInbox(appGroupIdentifier: appGroupIdentifier)
            #expect(await inbox.enqueue(
                payload: ["message_id": "canonical-retry-deadline-001"],
                requestIdentifier: "canonical-retry-deadline-001",
                source: "retry-test"
            ))
            let entry = try #require(await inbox.pendingEntries().first)
            let now = Date()
            let retryAt = now.addingTimeInterval(30)

            await inbox.markRetry(
                entry,
                reason: "canonical-temporary-failure",
                retryAfter: retryAt
            )

            let due = try #require(await inbox.nextRetryDate(now: now))
            #expect(abs(due.timeIntervalSince(retryAt)) < 0.01)
            #expect(await inbox.pendingEntries().isEmpty)
        }
    }

    @Test
    func legacyInboxImporterDiscoversAFileWrittenAfterAnInitiallyEmptyScan() async throws {
        try await withIsolatedAutomationStorage { _, appGroupIdentifier in
            let inbox = NotificationIngressInbox(appGroupIdentifier: appGroupIdentifier)
            #expect(await inbox.pendingEntries().isEmpty)

            let appGroupURL = try #require(
                AppConstants.appGroupContainerURL(identifier: appGroupIdentifier)
            )
            let inboxDirectory = appGroupURL
                .appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent("Application Support", isDirectory: true)
                .appendingPathComponent("notification-ingress-inbox", isDirectory: true)
            try FileManager.default.createDirectory(at: inboxDirectory, withIntermediateDirectories: true)
            let legacyURL = inboxDirectory.appendingPathComponent("late.inboxbin")
            let legacy = NotificationIngressInbox.StoredEntry(
                schemaVersion: 1,
                entryId: "legacy-entry-id",
                createdAtEpochMs: Int64(Date().timeIntervalSince1970 * 1_000),
                source: "late-writer",
                requestIdentifier: "late-request",
                payload: [
                    "message_id": AnyCodable("late-message"),
                    "entity_type": AnyCodable("message"),
                ]
            )
            try PropertyListEncoder().encode(legacy).write(to: legacyURL, options: .atomic)

            let pending = await inbox.pendingEntries()
            #expect(pending.count == 1)
            #expect(pending.first?.record.source == "legacy.late-writer")
            #expect(pending.first?.payload["message_id"] as? String == "late-message")
            #expect(!FileManager.default.fileExists(atPath: legacyURL.path))
        }
    }

    @Test
    func legacyInboxImporterQuarantinesUnreadableFilesWithoutTreatingDeletionAsSuccess() async throws {
        try await withIsolatedAutomationStorage { _, appGroupIdentifier in
            let inbox = NotificationIngressInbox(appGroupIdentifier: appGroupIdentifier)

            guard let appGroupURL = AppConstants.appGroupContainerURL(identifier: appGroupIdentifier) else {
                Issue.record("Missing app-group URL for automation storage.")
                return
            }
            let inboxDirectory = appGroupURL
                .appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent("Application Support", isDirectory: true)
                .appendingPathComponent("notification-ingress-inbox", isDirectory: true)
            try FileManager.default.createDirectory(at: inboxDirectory, withIntermediateDirectories: true)

            let corruptedFileURL = inboxDirectory.appendingPathComponent("999999-bad.inboxbin", isDirectory: false)
            try Data([0x01, 0x02, 0x03, 0x04]).write(to: corruptedFileURL, options: .atomic)

            let pending = await inbox.pendingEntries()

            #expect(pending.isEmpty)
            #expect(FileManager.default.fileExists(atPath: corruptedFileURL.path) == false)
            let quarantineDirectory = appGroupURL
                .appendingPathComponent("Library/Application Support/PushGoIngress/LegacyQuarantine")
            let quarantined = (try? FileManager.default.contentsOfDirectory(
                at: quarantineDirectory,
                includingPropertiesForKeys: nil
            )) ?? []
            #expect(quarantined.count == 1)
            #expect(quarantined.first?.lastPathComponent.contains("invalid_inbox") == true)
        }
    }

    @Test
    func providerDeliveryAckFailureStorePersistsPendingOrFailedMarkersByFullIdentity() async throws {
        try await withIsolatedAutomationStorage { _, appGroupIdentifier in
            let store = ProviderDeliveryAckFailureStore(appGroupIdentifier: appGroupIdentifier)
            let identity = testDeliveryIdentity(deliveryId: "delivery-ack-failure-001")

            #expect(
                await store.markPreparing(
                    identity: identity,
                    source: "nse_preparing"
                )
            )
            #expect(await store.pendingMarkers().isEmpty)

            #expect(
                await store.markInboxDurable(
                    identity: identity,
                    source: "nse_inbox_durable"
                )
            )

            var pending = await store.pendingMarkers()
            #expect(pending.count == 1)
            #expect(pending.first?.record.deliveryId == "delivery-ack-failure-001")
            #expect(pending.first?.record.stage == .inboxDurable)
            #expect(pending.first?.record.source == "nse_inbox_durable")
            #expect(pending.first?.baseURL?.absoluteString == "https://sandbox.pushgo.dev")
            #expect(pending.first?.identity == identity)

            let first = try #require(pending.first)
            let rawData = try Data(contentsOf: first.fileURL)
            #expect(rawData.starts(with: Data("SQLite format 3\0".utf8)))

            let lease = await store.acquireAckLease(
                first,
                owner: "app.ios",
                leaseDuration: 30
            )
            #expect(lease?.record.stage == .ackInFlight)
            #expect(await store.pendingMarkers().isEmpty)

            if let lease {
                await store.markAckFailed(
                    lease,
                    source: "app.failed",
                    retryAfter: Date(timeIntervalSinceNow: -1),
                    postNotification: false
                )
            }
            pending = await store.pendingMarkers()
            #expect(pending.count == 1)
            #expect(pending.first?.record.stage == .inboxDurable)

            await store.markCompleted(identity: identity)
            pending = await store.pendingMarkers()
            #expect(pending.isEmpty)
        }
    }

    @Test
    func providerDeliveryAckFailureStoreExposesTheNextDurableRetryDeadline() async throws {
        try await withIsolatedAutomationStorage { _, appGroupIdentifier in
            let store = ProviderDeliveryAckFailureStore(appGroupIdentifier: appGroupIdentifier)
            let identity = testDeliveryIdentity(deliveryId: "delivery-retry-deadline-001")
            let now = Date()
            let retryAt = now.addingTimeInterval(30)

            #expect(await store.markInboxDurable(identity: identity, source: "retry-test"))
            let marker = try #require(await store.pendingMarkers(now: now).first)
            let lease = try #require(await store.acquireAckLease(
                marker,
                owner: "app.ios",
                leaseDuration: 30,
                now: now
            ))
            await store.markAckFailed(
                lease,
                source: "retry-test.failed",
                retryAfter: retryAt,
                postNotification: false
            )

            let due = try #require(await store.nextAttemptDate(now: now))
            #expect(abs(due.timeIntervalSince(retryAt)) < 0.01)
            #expect(await store.pendingMarkers(now: now).isEmpty)
            #expect(await store.pendingMarkers(now: retryAt.addingTimeInterval(0.01)).count == 1)
        }
    }

    @Test
    func ingressJournalMaintenanceRetainsRecentTerminalRowsAndPrunesExpiredRows() async throws {
        try await withIsolatedAutomationStorage { _, appGroupIdentifier in
            let inbox = NotificationIngressInbox(appGroupIdentifier: appGroupIdentifier)
            #expect(await inbox.enqueue(
                payload: [
                    "message_id": "maintenance-message-001",
                    "delivery_id": "maintenance-delivery-001",
                    "entity_type": "message",
                ],
                requestIdentifier: "maintenance-request-001",
                source: "maintenance-test"
            ))
            let entry = try #require(await inbox.pendingEntries().first)
            await inbox.markCompleted(entry)

            let recent = await inbox.performMaintenance(
                now: Date().addingTimeInterval(34 * 24 * 60 * 60),
                force: true
            )
            #expect(recent.ingressRows == 0)

            let expired = await inbox.performMaintenance(
                now: Date().addingTimeInterval(36 * 24 * 60 * 60),
                force: true
            )
            #expect(expired.ingressRows == 1)
            #expect(expired.total == 1)
        }
    }

    @Test
    func providerDeliveryAckFailureStoreHidesFreshInboxDurableMarkersFromAppDrain() async throws {
        await withIsolatedAutomationStorage { _, appGroupIdentifier in
            let store = ProviderDeliveryAckFailureStore(appGroupIdentifier: appGroupIdentifier)
            let identity = testDeliveryIdentity(deliveryId: "delivery-young-marker-001")
            let now = Date()

            #expect(
                await store.markInboxDurable(
                    identity: identity,
                    source: "nse_inbox_durable",
                    postNotification: false
                )
            )

            #expect(await store.pendingMarkers(minimumAge: 120, now: now).isEmpty)
            #expect(await store.pendingMarkers(minimumAge: 120, now: now.addingTimeInterval(121)).count == 1)
        }
    }

    @Test
    func providerDeliveryAckFailureStoreDoesNotRecreateRecentlyCompletedMarkers() async throws {
        try await withIsolatedAutomationStorage { _, appGroupIdentifier in
            let store = ProviderDeliveryAckFailureStore(appGroupIdentifier: appGroupIdentifier)
            let identity = testDeliveryIdentity(deliveryId: "delivery-completed-marker-001")

            #expect(
                await store.markInboxDurable(
                    identity: identity,
                    source: "nse_inbox_durable",
                    postNotification: false
                )
            )

            let marker = try #require(await store.pendingMarkers().first)
            await store.markCompleted(marker)

            #expect(
                await store.markInboxDurable(
                    identity: identity,
                    source: "second_nse_inbox_durable",
                    postNotification: false
                ) == false
            )
            #expect(await store.pendingMarkers().isEmpty)
        }
    }

    @Test
    func providerDeliveryAckFailureStoreKeepsActiveLeaseFromBeingOverwritten() async throws {
        try await withIsolatedAutomationStorage { _, appGroupIdentifier in
            let store = ProviderDeliveryAckFailureStore(appGroupIdentifier: appGroupIdentifier)
            let identity = testDeliveryIdentity(deliveryId: "delivery-active-lease-001")

            #expect(
                await store.markInboxDurable(
                    identity: identity,
                    source: "nse_inbox_durable",
                    postNotification: false
                )
            )
            let marker = try #require(await store.pendingMarkers().first)
            let lease = await store.acquireAckLease(
                marker,
                owner: "nse",
                leaseDuration: 120
            )
            #expect(lease != nil)

            #expect(
                await store.markInboxDurable(
                    identity: identity,
                    source: "second_nse_inbox_durable",
                    postNotification: false
                ) == false
            )
            #expect(await store.pendingMarkers().isEmpty)
        }
    }

    @Test
    func v2AckCannotBeClaimedBeforeReferencedIngressIsTerminal() async throws {
        await withIsolatedAutomationStorage { _, appGroupIdentifier in
            let inbox = NotificationIngressInbox(appGroupIdentifier: appGroupIdentifier)
            let ackStore = ProviderDeliveryAckFailureStore(appGroupIdentifier: appGroupIdentifier)
            let identity = testDeliveryIdentity(deliveryId: "delivery-terminal-barrier-001")

            #expect(await inbox.enqueue(
                codablePayload: [
                    "delivery_id": AnyCodable(identity.deliveryId),
                    "message_id": AnyCodable("message-terminal-barrier-001"),
                ],
                requestIdentifier: identity.deliveryId,
                source: "test.v2.page",
                ackIdentity: identity,
                requiredEntryState: "terminal_local"
            ))
            #expect(await ackStore.pendingMarkers(minimumAge: 0).isEmpty)
            #expect(await ackStore.acquireAckLease(
                identity: identity,
                owner: "premature-worker",
                leaseDuration: 30
            ) == nil)

            await inbox.markTerminal(identity: identity, discarded: false)
            #expect(await ackStore.pendingMarkers(minimumAge: 0).count == 1)
            #expect(await ackStore.acquireAckLease(
                identity: identity,
                owner: "eligible-worker",
                leaseDuration: 30
            ) != nil)
        }
    }

    @Test
    func staleAckLeaseCannotCompletePeerTakeover() async throws {
        try await withIsolatedAutomationStorage { _, appGroupIdentifier in
            let store = ProviderDeliveryAckFailureStore(appGroupIdentifier: appGroupIdentifier)
            let identity = testDeliveryIdentity(
                deliveryId: "delivery-stale-ack-lease-001",
                ackContract: .legacySingle
            )
            #expect(await store.markInboxDurable(
                identity: identity,
                source: "test.stale_ack",
                postNotification: false
            ))
            let start = Date().addingTimeInterval(0.1)
            let first = try #require(await store.acquireAckLease(
                identity: identity,
                owner: "first",
                leaseDuration: 5,
                now: start
            ))
            _ = try #require(await store.acquireAckLease(
                identity: identity,
                owner: "second",
                leaseDuration: 5,
                now: start.addingTimeInterval(6)
            ))

            await store.markCompleted(first)
            #expect(await store.acquireAckLease(
                identity: identity,
                owner: "third",
                leaseDuration: 5,
                now: start.addingTimeInterval(12)
            ) != nil)
        }
    }

    @Test
    func providerDeliveryAckFailureStoreIsolatesSameDeliveryAcrossGatewaysAndDevices() async throws {
        await withIsolatedAutomationStorage { _, appGroupIdentifier in
            let store = ProviderDeliveryAckFailureStore(appGroupIdentifier: appGroupIdentifier)
            let identityA = testDeliveryIdentity(
                deliveryId: "shared-delivery-id",
                baseURL: "https://gateway.example/GatewayA",
                deviceKey: "device-a",
                ackContract: .legacySingle
            )
            let identityB = testDeliveryIdentity(
                deliveryId: "shared-delivery-id",
                baseURL: "https://gateway.example/GatewayB",
                deviceKey: "device-b",
                ackContract: .legacySingle
            )

            #expect(await store.markInboxDurable(
                identity: identityA,
                source: "gateway-a",
                postNotification: false
            ))
            #expect(await store.markInboxDurable(
                identity: identityB,
                source: "gateway-b",
                postNotification: false
            ))
            #expect(await store.pendingMarkers().count == 2)

            await store.markCompleted(identity: identityA)
            let remaining = await store.pendingMarkers()
            #expect(remaining.count == 1)
            #expect(remaining.first?.identity == identityB)
        }
    }

    @Test
    func providerDeliveryAckFailureStoreDeletesUnattributedV2Marker() async throws {
        try await withIsolatedAutomationStorage { _, appGroupIdentifier in
            let store = ProviderDeliveryAckFailureStore(appGroupIdentifier: appGroupIdentifier)
            let appGroupURL = try #require(AppConstants.appGroupContainerURL(identifier: appGroupIdentifier))
            let directory = appGroupURL
                .appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent("Application Support", isDirectory: true)
                .appendingPathComponent("provider-delivery-ack-failures", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let fileURL = directory.appendingPathComponent("legacy-delivery.ackbin")
            let now = Int64(Date().timeIntervalSince1970 * 1_000)
            let legacy = ProviderDeliveryAckFailureStore.StoredMarker(
                schemaVersion: 2,
                deliveryId: "legacy-delivery",
                baseURLString: "https://gateway.example/GatewayA",
                deviceKey: nil,
                ackContract: nil,
                attemptCount: nil,
                stage: .inboxDurable,
                owner: nil,
                leaseUntilEpochMs: nil,
                retryAfterEpochMs: nil,
                createdAtEpochMs: now,
                updatedAtEpochMs: now,
                source: "legacy-v2"
            )
            try PropertyListEncoder().encode(legacy).write(to: fileURL)

            #expect(await store.pendingMarkers().isEmpty)
            #expect(!FileManager.default.fileExists(atPath: fileURL.path))
        }
    }

    @Test
    func providerWakeupPullClaimStoreAllowsOnlyOneActiveClaimPerIdentity() async throws {
        await withIsolatedAutomationStorage { _, appGroupIdentifier in
            let store = ProviderWakeupPullClaimStore(appGroupIdentifier: appGroupIdentifier)
            let identity = testDeliveryIdentity(deliveryId: "delivery-pull-claim-001")
            let otherGatewayIdentity = testDeliveryIdentity(
                deliveryId: "delivery-pull-claim-001",
                baseURL: "https://other.pushgo.dev",
                deviceKey: "other-device"
            )
            let firstLease = await store.acquireLease(
                identity: identity,
                owner: "nse.macos",
                leaseDuration: 30
            )
            #expect(firstLease?.record.deliveryId == "delivery-pull-claim-001")

            let secondLease = await store.acquireLease(
                identity: identity,
                owner: "app.macos",
                leaseDuration: 30
            )
            #expect(secondLease == nil)
            #expect(await store.acquireLease(
                identity: otherGatewayIdentity,
                owner: "app.other-gateway",
                leaseDuration: 30
            ) != nil)

            if let firstLease {
                await store.markCompleted(firstLease)
            }

            let completedLease = await store.acquireLease(
                identity: identity,
                owner: "app.retry",
                leaseDuration: 30
            )
            #expect(completedLease == nil)
        }
    }

    @Test
    func providerWakeupPullClaimStorePurgesLegacyDeliveryOnlyClaim() async throws {
        try await withIsolatedAutomationStorage { _, appGroupIdentifier in
            let store = ProviderWakeupPullClaimStore(appGroupIdentifier: appGroupIdentifier)
            let appGroupURL = try #require(AppConstants.appGroupContainerURL(identifier: appGroupIdentifier))
            let directory = appGroupURL
                .appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent("Application Support", isDirectory: true)
                .appendingPathComponent("provider-wakeup-pull-claims", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let legacyFileURL = directory.appendingPathComponent("legacy-delivery.pullclaim")
            let now = Int64(Date().timeIntervalSince1970 * 1_000)
            let legacy = ProviderWakeupPullClaimStore.StoredClaim(
                schemaVersion: 1,
                deliveryId: "legacy-delivery",
                baseURLString: nil,
                deviceKey: nil,
                ackContract: nil,
                state: .claimed,
                owner: "legacy",
                leaseUntilEpochMs: now + 30_000,
                createdAtEpochMs: now,
                updatedAtEpochMs: now
            )
            try PropertyListEncoder().encode(legacy).write(to: legacyFileURL)

            let identity = testDeliveryIdentity(deliveryId: "new-delivery")
            #expect(await store.acquireLease(
                identity: identity,
                owner: "new-owner",
                leaseDuration: 30
            ) != nil)
            #expect(!FileManager.default.fileExists(atPath: legacyFileURL.path))
        }
    }

    @Test
    func providerWakeupPullClaimStoreAllowsRetryAfterReleaseOrLeaseExpiry() async throws {
        try await withIsolatedAutomationStorage { _, appGroupIdentifier in
            let store = ProviderWakeupPullClaimStore(appGroupIdentifier: appGroupIdentifier)
            let retryIdentity = testDeliveryIdentity(deliveryId: "delivery-pull-claim-retry-001")

            let firstLease = try #require(
                await store.acquireLease(
                    identity: retryIdentity,
                    owner: "nse.macos",
                    leaseDuration: 30
                )
            )

            await store.releaseLease(firstLease)
            let retryLease = await store.acquireLease(
                identity: retryIdentity,
                owner: "app.macos",
                leaseDuration: 30
            )
            #expect(retryLease != nil)

            let expiredStore = ProviderWakeupPullClaimStore(appGroupIdentifier: appGroupIdentifier)
            let expiryIdentity = testDeliveryIdentity(deliveryId: "delivery-pull-claim-expiry-001")
            let leaseAtNow = try #require(
                await expiredStore.acquireLease(
                    identity: expiryIdentity,
                    owner: "nse.expiry",
                    leaseDuration: 5,
                    now: Date(timeIntervalSince1970: 1_000)
                )
            )
            #expect(leaseAtNow.record.state == .claimed)

            let takeoverLease = await expiredStore.acquireLease(
                identity: expiryIdentity,
                owner: "app.expiry",
                leaseDuration: 5,
                now: Date(timeIntervalSince1970: 1_007)
            )
            #expect(takeoverLease != nil)
        }
    }

    @Test
    func expiredPullOwnerCannotCompletePeerTakeoverAfterCrash() async throws {
        try await withIsolatedAutomationStorage { _, appGroupIdentifier in
            let store = ProviderWakeupPullClaimStore(appGroupIdentifier: appGroupIdentifier)
            let identity = testDeliveryIdentity(deliveryId: "delivery-pull-crash-001")
            let crashedLease = try #require(
                await store.acquireLease(
                    identity: identity,
                    owner: "nse.crashed",
                    leaseDuration: 5,
                    now: Date(timeIntervalSince1970: 1_000)
                )
            )
            let peerLease = try #require(
                await store.acquireLease(
                    identity: identity,
                    owner: "app.peer",
                    leaseDuration: 30,
                    now: Date(timeIntervalSince1970: 1_007)
                )
            )

            await store.markCompleted(crashedLease, now: Date(timeIntervalSince1970: 1_008))
            await store.releaseLease(peerLease, now: Date(timeIntervalSince1970: 1_009))

            let retryAfterPeerFailure = await store.acquireLease(
                identity: identity,
                owner: "app.retry",
                leaseDuration: 30,
                now: Date(timeIntervalSince1970: 1_010)
            )
            #expect(retryAfterPeerFailure != nil)
        }
    }

    @Test
    func expiredCanonicalApplyOwnerCannotCompletePeerTakeover() async throws {
        await withIsolatedAutomationStorage { _, appGroupIdentifier in
            let inbox = NotificationIngressInbox(appGroupIdentifier: appGroupIdentifier)
            let accepted = await inbox.enqueue(
                codablePayload: [
                    "message_id": AnyCodable("canonical-lease-fence-001"),
                    "title": AnyCodable("Lease fence"),
                ],
                requestIdentifier: "canonical-lease-fence-001",
                source: "test.canonical_lease"
            )
            #expect(accepted)

            let start = Date()
            let crashed = await inbox.claimPendingEntries(
                owner: "app.crashed",
                leaseDuration: 5,
                limit: 1,
                now: start
            )
            #expect(crashed.count == 1)
            #expect(await inbox.claimPendingEntries(
                owner: "app.too_early",
                leaseDuration: 5,
                limit: 1,
                now: start.addingTimeInterval(4)
            ).isEmpty)

            let peer = await inbox.claimPendingEntries(
                owner: "app.peer",
                leaseDuration: 30,
                limit: 1,
                now: start.addingTimeInterval(6)
            )
            #expect(peer.count == 1)
            #expect(peer.first?.leaseGeneration == (crashed.first?.leaseGeneration ?? 0) + 1)

            #expect(await inbox.markCompleted(crashed[0]) == false)
            #expect(await inbox.markCompleted(peer[0]))
            #expect(await inbox.pendingEntries().isEmpty)
        }
    }

    @Test
    func queueCountsSeparateImmediatelyDueWorkFromLeasedAndDelayedWork() async throws {
        await withIsolatedAutomationStorage { _, appGroupIdentifier in
            let inbox = NotificationIngressInbox(appGroupIdentifier: appGroupIdentifier)
            for index in 0..<2 {
                #expect(await inbox.enqueue(
                    codablePayload: [
                        "message_id": AnyCodable("queue-count-\(index)"),
                        "title": AnyCodable("Queue count \(index)"),
                    ],
                    requestIdentifier: "queue-count-\(index)",
                    source: "test.queue_count"
                ))
            }

            let now = Date()
            #expect(await inbox.queueCounts(now: now) == .init(due: 2, outstanding: 2))

            let firstClaim = await inbox.claimPendingEntries(
                owner: "app.queue_count",
                leaseDuration: 30,
                limit: 1,
                now: now
            )
            #expect(firstClaim.count == 1)
            #expect(await inbox.queueCounts(now: now) == .init(due: 1, outstanding: 2))
            #expect(await inbox.markCompleted(firstClaim[0]))
            #expect(await inbox.queueCounts(now: now) == .init(due: 1, outstanding: 1))

            let secondClaim = await inbox.claimPendingEntries(
                owner: "app.queue_count",
                leaseDuration: 30,
                limit: 1,
                now: now
            )
            #expect(secondClaim.count == 1)
            #expect(await inbox.markRetry(
                secondClaim[0],
                reason: "test_delayed_retry",
                retryAfter: now.addingTimeInterval(60)
            ))
            #expect(await inbox.queueCounts(now: now) == .init(due: 0, outstanding: 1))
        }
    }

    @Test
    func providerWakeupPullClaimCompletionIsDurableAcrossStoreRestart() async throws {
        try await withIsolatedAutomationStorage { _, appGroupIdentifier in
            let store = ProviderWakeupPullClaimStore(appGroupIdentifier: appGroupIdentifier)
            let identity = testDeliveryIdentity(deliveryId: "delivery-pull-claim-peer-001")
            let lease = try #require(
                await store.acquireLease(
                    identity: identity,
                    owner: "app.peer",
                    leaseDuration: 30
                )
            )

            await store.markCompleted(lease)

            let restartedStore = ProviderWakeupPullClaimStore(
                appGroupIdentifier: appGroupIdentifier
            )
            #expect(await restartedStore.acquireLease(
                identity: identity,
                owner: "app.after-restart",
                leaseDuration: 30
            ) == nil)
        }
    }

    @Test
    func notificationIngressInboxDeduplicatesOnlyAnExactlyIdenticalUnattributedPayload() async throws {
        await withIsolatedAutomationStorage { _, appGroupIdentifier in
            let inbox = NotificationIngressInbox(appGroupIdentifier: appGroupIdentifier)
            let firstPayload: [String: AnyCodable] = [
                "delivery_id": AnyCodable("delivery-idempotent-001"),
                "message_id": AnyCodable("message-stable"),
                "title": AnyCodable("Stable"),
            ]
            var secondPayload: [String: AnyCodable] = [:]
            secondPayload["title"] = AnyCodable("Stable")
            secondPayload["message_id"] = AnyCodable("message-stable")
            secondPayload["delivery_id"] = AnyCodable("delivery-idempotent-001")

            #expect(await inbox.enqueue(
                codablePayload: firstPayload,
                requestIdentifier: "delivery-idempotent-001",
                source: "nse"
            ))
            #expect(await inbox.enqueue(
                codablePayload: secondPayload,
                requestIdentifier: "delivery-idempotent-001",
                source: "nse"
            ))

            let pending = await inbox.pendingEntries()
            #expect(pending.count == 1)
            #expect(pending.first?.payload["message_id"] as? String == "message-stable")
        }
    }

    @Test
    func incompleteDeliveryOwnershipNeverMergesDifferentPayloadsByDeliveryIDAlone() async throws {
        await withIsolatedAutomationStorage { _, appGroupIdentifier in
            let inbox = NotificationIngressInbox(appGroupIdentifier: appGroupIdentifier)
            #expect(await inbox.enqueue(
                payload: ["delivery_id": "shared", "message_id": "message-a"],
                requestIdentifier: nil,
                source: "nse"
            ))
            #expect(await inbox.enqueue(
                payload: ["delivery_id": "shared", "message_id": "message-b"],
                requestIdentifier: nil,
                source: "nse"
            ))

            let ids = Set(await inbox.pendingEntries().compactMap {
                $0.payload["message_id"] as? String
            })
            #expect(ids == Set(["message-a", "message-b"]))
        }
    }

    @Test
    func sqliteContentionFallsBackToAtomicSidecarAndMergesAfterUnlock() async throws {
        try await withIsolatedAutomationStorage { _, appGroupIdentifier in
            let journal = DurableIngressJournal(
                appGroupIdentifier: appGroupIdentifier,
                busyTimeoutMilliseconds: 200
            )
            #expect(await journal.enqueueIngress(
                codablePayload: ["message_id": AnyCodable("seed")],
                requestIdentifier: "seed",
                source: "test"
            ))
            let seed = try #require(await journal.pendingIngressEntries(limit: nil).first)
            await journal.markIngressCompleted(entryID: seed.record.entryId)
            let databaseURL = try #require(await journal.databaseURL)
            let lock = try SQLiteTestConnection(url: databaseURL)
            try lock.execute("BEGIN EXCLUSIVE;")
            defer { try? lock.execute("ROLLBACK;") }

            let started = Date()
            #expect(await journal.enqueueIngress(
                codablePayload: [
                    "delivery_id": AnyCodable("locked-delivery"),
                    "message_id": AnyCodable("locked-message"),
                ],
                requestIdentifier: "locked-request",
                source: "nse.locked"
            ))
            // Keep the fallback comfortably inside the notification extension's
            // execution window while allowing for scheduler contention when the
            // complete test suite runs in parallel on a shared CI runner.
            #expect(Date().timeIntervalSince(started) < 5)

            let emergencyDirectory = databaseURL.deletingLastPathComponent()
                .appendingPathComponent("EmergencyIngress", isDirectory: true)
            let emergencyFiles = try FileManager.default.contentsOfDirectory(
                at: emergencyDirectory,
                includingPropertiesForKeys: nil
            )
            #expect(emergencyFiles.count == 1)

            try lock.execute("COMMIT;")
            let restartedJournal = DurableIngressJournal(appGroupIdentifier: appGroupIdentifier)
            let merged = await restartedJournal.pendingIngressEntries(limit: nil)
            #expect(merged.count == 1)
            #expect(merged.first?.payload["message_id"] as? String == "locked-message")
            let remainingSidecars = try FileManager.default.contentsOfDirectory(
                at: emergencyDirectory,
                includingPropertiesForKeys: nil
            )
            #expect(remainingSidecars.isEmpty)
        }
    }

    @Test
    func sqliteOpenFailureFallsBackToAtomicSidecarAndImportsAfterRecovery() async throws {
        try await withIsolatedAutomationStorage { _, appGroupIdentifier in
            let journal = DurableIngressJournal(appGroupIdentifier: appGroupIdentifier)
            let databaseURL = try #require(await journal.databaseURL)
            try FileManager.default.createDirectory(
                at: databaseURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            // A directory at the database path produces a non-busy SQLite open
            // failure while leaving the sibling emergency directory writable.
            try FileManager.default.createDirectory(at: databaseURL, withIntermediateDirectories: true)

            #expect(await journal.enqueueIngress(
                codablePayload: [
                    "delivery_id": AnyCodable("open-failure-delivery"),
                    "message_id": AnyCodable("open-failure-message"),
                ],
                requestIdentifier: "open-failure-delivery",
                source: "test.open_failure"
            ))

            let emergencyDirectory = databaseURL.deletingLastPathComponent()
                .appendingPathComponent("EmergencyIngress", isDirectory: true)
            #expect(try FileManager.default.contentsOfDirectory(
                at: emergencyDirectory,
                includingPropertiesForKeys: nil
            ).filter { $0.pathExtension == "ingress-emergency" }.count == 1)

            try FileManager.default.removeItem(at: databaseURL)
            let restarted = DurableIngressJournal(appGroupIdentifier: appGroupIdentifier)
            let recovered = await restarted.pendingIngressEntries(limit: nil)
            #expect(recovered.count == 1)
            #expect(recovered.first?.payload["message_id"] as? String == "open-failure-message")
            #expect(try FileManager.default.contentsOfDirectory(
                at: emergencyDirectory,
                includingPropertiesForKeys: nil
            ).filter { $0.pathExtension == "ingress-emergency" }.isEmpty)
        }
    }

    @Test
    func futureSchemaFallsBackWithoutMutatingDatabaseAndImportsAfterDowngrade() async throws {
        try await withIsolatedAutomationStorage { _, appGroupIdentifier in
            let journal = DurableIngressJournal(appGroupIdentifier: appGroupIdentifier)
            #expect(await journal.enqueueIngress(
                codablePayload: ["message_id": AnyCodable("future-schema-seed")],
                requestIdentifier: "future-schema-seed",
                source: "test"
            ))
            let seed = try #require(await journal.pendingIngressEntries(limit: 1).first)
            await journal.markIngressCompleted(entryID: seed.record.entryId)
            let databaseURL = try #require(await journal.databaseURL)
            let futureDatabase = try SQLiteTestConnection(url: databaseURL)
            try futureDatabase.execute(
                "CREATE TABLE future_owner_sentinel(value TEXT NOT NULL);"
            )
            try futureDatabase.execute(
                "INSERT INTO future_owner_sentinel(value) VALUES ('future-owned');"
            )
            try futureDatabase.execute(
                "UPDATE ingress_meta SET value = '2' WHERE key = 'schema_version';"
            )

            #expect(await journal.enqueueIngress(
                codablePayload: [
                    "delivery_id": AnyCodable("future-schema-delivery"),
                    "message_id": AnyCodable("future-schema-emergency"),
                ],
                requestIdentifier: "future-schema-delivery",
                source: "test.future_schema"
            ))
            #expect(try futureDatabase.scalarText(
                "SELECT value FROM ingress_meta WHERE key = 'schema_version';"
            ) == "2")
            #expect(try futureDatabase.scalarText(
                "SELECT value FROM future_owner_sentinel LIMIT 1;"
            ) == "future-owned")

            try futureDatabase.execute(
                "UPDATE ingress_meta SET value = '1' WHERE key = 'schema_version';"
            )
            let restarted = DurableIngressJournal(appGroupIdentifier: appGroupIdentifier)
            let recovered = await restarted.pendingIngressEntries(limit: nil)
            #expect(recovered.count == 1)
            #expect(recovered.first?.payload["message_id"] as? String == "future-schema-emergency")
        }
    }

    @Test
    func corruptExistingEmergencySidecarIsAtomicallyReplacedBeforeReportingDurable() async throws {
        try await withIsolatedAutomationStorage { _, appGroupIdentifier in
            let journal = DurableIngressJournal(
                appGroupIdentifier: appGroupIdentifier,
                busyTimeoutMilliseconds: 1
            )
            #expect(await journal.enqueueIngress(
                codablePayload: ["message_id": AnyCodable("corrupt-sidecar-seed")],
                requestIdentifier: "corrupt-sidecar-seed",
                source: "test"
            ))
            let seed = try #require(await journal.pendingIngressEntries(limit: 1).first)
            await journal.markIngressCompleted(entryID: seed.record.entryId)
            let databaseURL = try #require(await journal.databaseURL)
            let lock = try SQLiteTestConnection(url: databaseURL)
            try lock.execute("BEGIN EXCLUSIVE;")

            let payload: [String: AnyCodable] = [
                "delivery_id": AnyCodable("corrupt-sidecar-delivery"),
                "message_id": AnyCodable("corrupt-sidecar-message"),
            ]
            #expect(await journal.enqueueIngress(
                codablePayload: payload,
                requestIdentifier: "corrupt-sidecar-delivery",
                source: "test.corrupt_sidecar"
            ))
            let emergencyDirectory = databaseURL.deletingLastPathComponent()
                .appendingPathComponent("EmergencyIngress", isDirectory: true)
            let sidecar = try #require(
                FileManager.default.contentsOfDirectory(
                    at: emergencyDirectory,
                    includingPropertiesForKeys: nil
                ).first { $0.pathExtension == "ingress-emergency" }
            )
            try Data([0x01, 0x02, 0x03]).write(to: sidecar, options: .atomic)

            #expect(await journal.enqueueIngress(
                codablePayload: payload,
                requestIdentifier: "corrupt-sidecar-delivery",
                source: "test.corrupt_sidecar"
            ))
            try lock.execute("COMMIT;")

            let restarted = DurableIngressJournal(appGroupIdentifier: appGroupIdentifier)
            let recovered = await restarted.pendingIngressEntries(limit: nil)
            #expect(recovered.contains {
                $0.payload["message_id"] as? String == "corrupt-sidecar-message"
            })
            let remainingSidecars = try FileManager.default.contentsOfDirectory(
                at: emergencyDirectory,
                includingPropertiesForKeys: nil
            ).filter { $0.pathExtension == "ingress-emergency" }
            #expect(remainingSidecars.isEmpty)
        }
    }

    @Test
    func sqliteConnectionEnforcesPowerLossDurabilityPragmas() async {
        await withIsolatedAutomationStorage { _, appGroupIdentifier in
            let journal = DurableIngressJournal(appGroupIdentifier: appGroupIdentifier)
            #expect(
                await journal.durabilityPragmas()
                    == DurableIngressJournal.DurabilityPragmas(
                        journalMode: "delete",
                        synchronous: 3,
                        fullfsync: 1
                    )
            )
        }
    }

    @Test
    func emergencySidecarCannotReportDurableWhenStrongSynchronizationFails() async throws {
        try await withIsolatedAutomationStorage { _, appGroupIdentifier in
            let seedJournal = DurableIngressJournal(appGroupIdentifier: appGroupIdentifier)
            #expect(await seedJournal.enqueueIngress(
                codablePayload: ["message_id": AnyCodable("sidecar-sync-seed")],
                requestIdentifier: "sidecar-sync-seed",
                source: "test"
            ))
            let seed = try #require(await seedJournal.pendingIngressEntries(limit: 1).first)
            await seedJournal.markIngressCompleted(entryID: seed.record.entryId)
            let databaseURL = try #require(await seedJournal.databaseURL)
            let lock = try SQLiteTestConnection(url: databaseURL)
            try lock.execute("BEGIN EXCLUSIVE;")

            let failingJournal = DurableIngressJournal(
                appGroupIdentifier: appGroupIdentifier,
                busyTimeoutMilliseconds: 1,
                durabilitySynchronizer: { _ in false }
            )
            #expect(await failingJournal.enqueueIngress(
                codablePayload: ["message_id": AnyCodable("sidecar-sync-must-fail-closed")],
                requestIdentifier: "sidecar-sync-must-fail-closed",
                source: "test.sync_failure"
            ) == false)

            try lock.execute("COMMIT;")
            let restarted = DurableIngressJournal(appGroupIdentifier: appGroupIdentifier)
            let recovered = await restarted.pendingIngressEntries(limit: nil)
            #expect(!recovered.contains {
                $0.payload["message_id"] as? String == "sidecar-sync-must-fail-closed"
            })
        }
    }

    @Test
    func emergencySidecarCannotReportDurableWhenDirectoryStrongSynchronizationFails() async throws {
        try await withIsolatedAutomationStorage { _, appGroupIdentifier in
            let seedJournal = DurableIngressJournal(appGroupIdentifier: appGroupIdentifier)
            #expect(await seedJournal.enqueueIngress(
                codablePayload: ["message_id": AnyCodable("sidecar-directory-sync-seed")],
                requestIdentifier: "sidecar-directory-sync-seed",
                source: "test"
            ))
            let seed = try #require(await seedJournal.pendingIngressEntries(limit: 1).first)
            await seedJournal.markIngressCompleted(entryID: seed.record.entryId)
            let databaseURL = try #require(await seedJournal.databaseURL)
            let lock = try SQLiteTestConnection(url: databaseURL)
            try lock.execute("BEGIN EXCLUSIVE;")

            let failingJournal = DurableIngressJournal(
                appGroupIdentifier: appGroupIdentifier,
                busyTimeoutMilliseconds: 1,
                durabilitySynchronizer: { !$0.hasDirectoryPath }
            )
            #expect(await failingJournal.enqueueIngress(
                codablePayload: ["message_id": AnyCodable("sidecar-directory-sync-must-fail-closed")],
                requestIdentifier: "sidecar-directory-sync-must-fail-closed",
                source: "test.directory_sync_failure"
            ) == false)

            try lock.execute("COMMIT;")
            let restarted = DurableIngressJournal(appGroupIdentifier: appGroupIdentifier)
            let recovered = await restarted.pendingIngressEntries(limit: nil)
            #expect(recovered.contains {
                $0.payload["message_id"] as? String == "sidecar-directory-sync-must-fail-closed"
            })
        }
    }

    @Test
    func ingressIdentityIncludesGatewayDeviceAndContract() async throws {
        await withIsolatedAutomationStorage { _, appGroupIdentifier in
            let journal = DurableIngressJournal(appGroupIdentifier: appGroupIdentifier)
            let legacyA = testDeliveryIdentity(
                deliveryId: "same-delivery",
                baseURL: "https://gateway-a.example",
                deviceKey: "device-a",
                ackContract: .legacySingle
            )
            let v2A = testDeliveryIdentity(
                deliveryId: "same-delivery",
                baseURL: "https://gateway-a.example",
                deviceKey: "device-a",
                ackContract: .v2Batch
            )
            let legacyB = testDeliveryIdentity(
                deliveryId: "same-delivery",
                baseURL: "https://gateway-b.example",
                deviceKey: "device-b",
                ackContract: .legacySingle
            )

            for (identity, messageID) in [
                (legacyA, "legacy-a"),
                (v2A, "v2-a"),
                (legacyB, "legacy-b"),
            ] {
                #expect(await journal.enqueueIngress(
                    codablePayload: [
                        "delivery_id": AnyCodable(identity.deliveryId),
                        "message_id": AnyCodable(messageID),
                    ],
                    requestIdentifier: identity.deliveryId,
                    source: "test.identity",
                    ackIdentity: identity,
                    requiredEntryState: identity.ackContract == .v2Batch ? "terminal_local" : "durable"
                ))
            }

            let messages = Set(await journal.pendingIngressEntries(limit: nil).compactMap {
                $0.payload["message_id"] as? String
            })
            #expect(messages == Set(["legacy-a", "v2-a", "legacy-b"]))
            #expect(await journal.durableIngressPayload(identity: legacyA)?["message_id"]?.value as? String == "legacy-a")
            #expect(await journal.durableIngressPayload(identity: v2A)?["message_id"]?.value as? String == "v2-a")
            #expect(await journal.durableIngressPayload(identity: legacyB)?["message_id"]?.value as? String == "legacy-b")
        }
    }

    @Test
    func malformedAndUnsupportedRowsAreQuarantinedWithoutHeadOfLineBlocking() async throws {
        try await withIsolatedAutomationStorage { _, appGroupIdentifier in
            let journal = DurableIngressJournal(appGroupIdentifier: appGroupIdentifier)
            for messageID in ["bad-payload-a", "bad-payload-b", "future-schema", "valid-behind"] {
                #expect(await journal.enqueueIngress(
                    codablePayload: ["message_id": AnyCodable(messageID)],
                    requestIdentifier: messageID,
                    source: "test.scan"
                ))
            }
            let initial = await journal.pendingIngressEntries(limit: nil)
            let badPayloadIDs = try ["bad-payload-a", "bad-payload-b"].map { messageID in
                try #require(initial.first {
                    $0.payload["message_id"] as? String == messageID
                }?.record.entryId)
            }
            let futureSchemaID = try #require(initial.first {
                $0.payload["message_id"] as? String == "future-schema"
            }?.record.entryId)
            let validID = try #require(initial.first {
                $0.payload["message_id"] as? String == "valid-behind"
            }?.record.entryId)
            let databaseURL = try #require(await journal.databaseURL)
            let connection = try SQLiteTestConnection(url: databaseURL)
            for (index, entryID) in badPayloadIDs.enumerated() {
                try connection.execute(
                    "UPDATE ingress_entry SET payload_plist = X'010203', created_at_ms = \(index + 1) WHERE entry_id = '\(entryID)';"
                )
            }
            try connection.execute(
                "UPDATE ingress_entry SET schema_version = 999, created_at_ms = 3 WHERE entry_id = '\(futureSchemaID)';"
            )
            try connection.execute(
                "UPDATE ingress_entry SET created_at_ms = 4 WHERE entry_id = '\(validID)';"
            )

            let boundedScanner = DurableIngressJournal(
                appGroupIdentifier: appGroupIdentifier,
                pendingScanWindowLimit: 2
            )
            let pending = await boundedScanner.pendingIngressEntries(limit: 1)
            #expect(pending.count == 1)
            #expect(pending.first?.payload["message_id"] as? String == "valid-behind")
            #expect(await boundedScanner.diagnostics().quarantined == 3)
        }
    }

    @Test
    func ackLeaseAuthoritativelyRejectsFutureSchemaCorruptPayloadAndMismatchedIngressIdentity() async throws {
        try await withIsolatedAutomationStorage { _, appGroupIdentifier in
            let journal = DurableIngressJournal(appGroupIdentifier: appGroupIdentifier)
            let ackStore = ProviderDeliveryAckFailureStore(appGroupIdentifier: appGroupIdentifier)
            let futureIdentity = testDeliveryIdentity(
                deliveryId: "future-lease",
                ackContract: .legacySingle
            )
            let corruptIdentity = testDeliveryIdentity(
                deliveryId: "corrupt-lease",
                ackContract: .legacySingle
            )
            let mismatchedIdentity = testDeliveryIdentity(
                deliveryId: "mismatched-ingress-lease",
                ackContract: .legacySingle
            )
            for identity in [futureIdentity, corruptIdentity, mismatchedIdentity] {
                #expect(await journal.enqueueIngress(
                    codablePayload: [
                        "delivery_id": AnyCodable(identity.deliveryId),
                        "message_id": AnyCodable("message-\(identity.deliveryId)"),
                    ],
                    requestIdentifier: identity.deliveryId,
                    source: "test.authoritative-lease",
                    ackIdentity: identity,
                    requiredEntryState: "durable"
                ))
            }

            // Discover identifiers before fault injection, then deliberately do
            // not run pendingEntries again before the lease attempts.
            let original = await journal.pendingIngressEntries(limit: nil)
            let futureEntryID = try #require(original.first {
                $0.payload["delivery_id"] as? String == futureIdentity.deliveryId
            }?.record.entryId)
            let corruptEntryID = try #require(original.first {
                $0.payload["delivery_id"] as? String == corruptIdentity.deliveryId
            }?.record.entryId)
            let mismatchedEntryID = try #require(original.first {
                $0.payload["delivery_id"] as? String == mismatchedIdentity.deliveryId
            }?.record.entryId)
            let databaseURL = try #require(await journal.databaseURL)
            let connection = try SQLiteTestConnection(url: databaseURL)
            try connection.execute(
                "UPDATE ingress_entry SET schema_version = 999 WHERE entry_id = '\(futureEntryID)';"
            )
            try connection.execute(
                "UPDATE ingress_entry SET payload_plist = X'010203' WHERE entry_id = '\(corruptEntryID)';"
            )
            try connection.execute(
                "UPDATE ingress_entry SET source_device_key = 'different-device' WHERE entry_id = '\(mismatchedEntryID)';"
            )

            #expect(await ackStore.acquireAckLease(
                identity: futureIdentity,
                owner: "must-not-http-future",
                leaseDuration: 30
            ) == nil)
            #expect(await ackStore.acquireAckLease(
                identity: corruptIdentity,
                owner: "must-not-http-corrupt",
                leaseDuration: 30
            ) == nil)
            #expect(await ackStore.acquireAckLease(
                identity: mismatchedIdentity,
                owner: "must-not-http-identity-mismatch",
                leaseDuration: 30
            ) == nil)
            #expect(await journal.diagnostics().quarantined == 3)
            #expect(await ackStore.pendingMarkers(minimumAge: 0).isEmpty)
        }
    }

    @Test
    func legacyTerminalTransitionUsesFullIdentityBeyondCoordinatorDrainCap() async throws {
        try await withIsolatedAutomationStorage { _, appGroupIdentifier in
            let inbox = NotificationIngressInbox(appGroupIdentifier: appGroupIdentifier)
            let identity = testDeliveryIdentity(
                deliveryId: "legacy-terminal-cap-plus-one",
                baseURL: "https://legacy-cap.example/GatewayA",
                deviceKey: "legacy-cap-device",
                ackContract: .legacySingle
            )
            #expect(await inbox.enqueue(
                codablePayload: [
                    "delivery_id": AnyCodable(identity.deliveryId),
                    "message_id": AnyCodable("legacy-terminal-message"),
                    "base_url": AnyCodable(identity.baseURLString),
                    "provider_device_key": AnyCodable(identity.deviceKey),
                    ProviderLegacyDestructivePullMetadata.markerKey:
                        AnyCodable(ProviderLegacyDestructivePullMetadata.markerValue),
                ],
                requestIdentifier: identity.deliveryId,
                source: "test.legacy-terminal-cap"
            ))
            let target = try #require(await inbox.pendingEntries(limit: 1).first)
            let databaseURL = try #require(
                AppConstants.appGroupContainerURL(identifier: appGroupIdentifier)?
                    .appendingPathComponent("Library/Application Support/PushGoIngress/ingress.sqlite")
            )
            let connection = try SQLiteTestConnection(url: databaseURL)
            try connection.execute(
                """
                WITH RECURSIVE sequence(value) AS (
                    SELECT 1 UNION ALL SELECT value + 1 FROM sequence WHERE value < 8192
                )
                INSERT INTO ingress_entry (
                    entry_id, schema_version, source, resolution_state, request_identifier,
                    message_id, payload_plist, validation_state, apply_state, lease_generation,
                    apply_attempts, next_apply_at_ms, created_at_ms, payload_fingerprint
                )
                SELECT printf('legacy-cap-filler-%05d', value), schema_version, 'test.filler',
                       'direct', printf('filler-%05d', value), printf('filler-%05d', value),
                       payload_plist, validation_state, 'pending', 0, 0, next_apply_at_ms,
                       created_at_ms - 100000 + value, payload_fingerprint
                FROM sequence CROSS JOIN ingress_entry WHERE entry_id = '\(target.record.entryId)';
                """
            )

            await inbox.markTerminal(identity: identity, discarded: false)

            let remaining = await inbox.pendingEntries(limit: 10_000)
            #expect(remaining.count == 8_192)
            #expect(remaining.allSatisfy {
                $0.payload["delivery_id"] as? String != identity.deliveryId
                    || $0.record.entryId != target.record.entryId
            })
        }
    }

    @Test
    func payloadLessDirectAckAnchorAtomicallyPromotesOnceButCannotOverwriteRealPayload() async throws {
        try await withIsolatedAutomationStorage { _, appGroupIdentifier in
            let journal = DurableIngressJournal(appGroupIdentifier: appGroupIdentifier)
            let ackStore = ProviderDeliveryAckFailureStore(appGroupIdentifier: appGroupIdentifier)
            let identity = testDeliveryIdentity(
                deliveryId: "anchor-promotion",
                ackContract: .legacySingle
            )
            #expect(await ackStore.markInboxDurable(
                identity: identity,
                source: "foreground.canonical-first",
                postNotification: false
            ))

            let first: [String: AnyCodable] = [
                "delivery_id": AnyCodable(identity.deliveryId),
                "message_id": AnyCodable("anchor-real-message"),
                "title": AnyCodable("Original"),
            ]
            #expect(await journal.enqueueIngress(
                codablePayload: first,
                requestIdentifier: identity.deliveryId,
                source: "nse.after-foreground",
                ackIdentity: identity,
                requiredEntryState: "durable"
            ))
            #expect(await journal.durableIngressPayload(identity: identity)?["title"]?.value as? String == "Original")
            let entryID = try #require(
                await journal.pendingIngressEntries(limit: nil).first?.record.entryId
            )

            var conflict = first
            conflict["title"] = AnyCodable("Conflicting")
            #expect(await journal.enqueueIngress(
                codablePayload: conflict,
                requestIdentifier: identity.deliveryId,
                source: "nse.conflict",
                ackIdentity: identity,
                requiredEntryState: "durable"
            ) == false)
            let databaseURL = try #require(await journal.databaseURL)
            let persisted = try SQLiteTestConnection(url: databaseURL).payload(entryID: entryID)
            #expect(persisted?["title"]?.value as? String == "Original")
        }
    }

    @Test
    func nWriterRollbackShadowsDecodeWithActualNMinusOneReaderAndSurviveCurrentImport() async throws {
        try await withIsolatedAutomationStorage { _, appGroupIdentifier in
            let journal = DurableIngressJournal(appGroupIdentifier: appGroupIdentifier)
            let identityA = testDeliveryIdentity(
                deliveryId: "rollback-shared-delivery",
                baseURL: "https://gateway-a.example",
                deviceKey: "device-a",
                ackContract: .legacySingle
            )
            let identityB = testDeliveryIdentity(
                deliveryId: "rollback-shared-delivery",
                baseURL: "https://gateway-b.example",
                deviceKey: "device-b",
                ackContract: .legacySingle
            )
            for (identity, messageID) in [(identityA, "rollback-a"), (identityB, "rollback-b")] {
                #expect(await journal.enqueueIngress(
                    codablePayload: [
                        "delivery_id": AnyCodable(identity.deliveryId),
                        "message_id": AnyCodable(messageID),
                    ],
                    requestIdentifier: identity.deliveryId,
                    source: "test.n-writer",
                    ackIdentity: identity,
                    requiredEntryState: "durable"
                ))
            }

            // Current-N scanning must skip, not consume, its rollback-only files.
            await journal.importLegacyStateIfNeeded()
            #expect(await journal.pendingIngressEntries(limit: nil).count == 2)
            let oldInbox = try nMinusOneDecodeFiles(
                appGroupIdentifier: appGroupIdentifier,
                directoryName: "notification-ingress-inbox",
                fileExtension: "inboxbin",
                as: NMinusOneStoredEntry.self
            )
            #expect(oldInbox.count == 2)
            #expect(Set(oldInbox.compactMap { $0.1.payload["message_id"]?.value as? String }) == Set(["rollback-a", "rollback-b"]))
            #expect(Set(oldInbox.map { $0.0.lastPathComponent }).count == 2)

            let oldAck = try nMinusOneDecodeFiles(
                appGroupIdentifier: appGroupIdentifier,
                directoryName: "provider-delivery-ack-failures",
                fileExtension: "ackbin",
                as: NMinusOneStoredAckMarker.self
            )
            #expect(oldAck.count == 2)
            #expect(Set(oldAck.compactMap { $0.1.baseURLString }) == Set([identityA.baseURLString, identityB.baseURLString]))
            #expect(oldAck.allSatisfy { $0.1.schemaVersion == 3 && $0.1.stage == .inboxDurable })

            let databaseURL = try #require(await journal.databaseURL)
            try SQLiteTestConnection(url: databaseURL).execute(
                "UPDATE rollback_shadow SET expires_at_ms = 0;"
            )
            _ = await journal.performMaintenance(force: true, batchLimit: 16)
            #expect(try nMinusOneDecodeFiles(
                appGroupIdentifier: appGroupIdentifier,
                directoryName: "notification-ingress-inbox",
                fileExtension: "inboxbin",
                as: NMinusOneStoredEntry.self
            ).isEmpty)
            #expect(try nMinusOneDecodeFiles(
                appGroupIdentifier: appGroupIdentifier,
                directoryName: "provider-delivery-ack-failures",
                fileExtension: "ackbin",
                as: NMinusOneStoredAckMarker.self
            ).isEmpty)
        }
    }

    @Test
    func rollbackShadowWriteFailureIsObservableWithoutRejectingCurrentIngress() async {
        await withIsolatedAutomationStorage { _, appGroupIdentifier in
            let journal = DurableIngressJournal(
                appGroupIdentifier: appGroupIdentifier,
                rollbackShadowWriteAllowed: { _ in false }
            )

            #expect(await journal.enqueueIngress(
                codablePayload: [
                    "delivery_id": AnyCodable("rollback-shadow-failure-001"),
                    "message_id": AnyCodable("rollback-shadow-message-001"),
                ],
                requestIdentifier: "rollback-shadow-failure-001",
                source: "test.rollback_shadow_failure"
            ))

            let pending = await journal.pendingIngressEntries(limit: 1)
            #expect(pending.count == 1)
            #expect(pending.first?.payload["message_id"] as? String == "rollback-shadow-message-001")

            let health = await journal.rollbackShadowHealth()
            #expect(health.failureCount == 1)
            #expect(health.lastKind == "inbox")
            #expect(health.lastReason == "injected_write_failure")
            #expect(health.lastFailureAt != nil)

            let restarted = DurableIngressJournal(appGroupIdentifier: appGroupIdentifier)
            #expect(await restarted.rollbackShadowHealth() == health)
        }
    }

    @Test
    func nMinusOneV2AckShadowAppearsOnlyAfterCanonicalTerminalCommit() async throws {
        try await withIsolatedAutomationStorage { _, appGroupIdentifier in
            let journal = DurableIngressJournal(appGroupIdentifier: appGroupIdentifier)
            let identity = testDeliveryIdentity(deliveryId: "rollback-v2-terminal")
            #expect(await journal.enqueueIngress(
                codablePayload: [
                    "delivery_id": AnyCodable(identity.deliveryId),
                    "message_id": AnyCodable("rollback-v2-message"),
                ],
                requestIdentifier: identity.deliveryId,
                source: "test.n-writer-v2",
                ackIdentity: identity,
                requiredEntryState: "terminal_local"
            ))
            #expect(try nMinusOneDecodeFiles(
                appGroupIdentifier: appGroupIdentifier,
                directoryName: "provider-delivery-ack-failures",
                fileExtension: "ackbin",
                as: NMinusOneStoredAckMarker.self
            ).isEmpty)

            await journal.markIngressTerminal(identity: identity, discarded: false)
            let oldAck = try nMinusOneDecodeFiles(
                appGroupIdentifier: appGroupIdentifier,
                directoryName: "provider-delivery-ack-failures",
                fileExtension: "ackbin",
                as: NMinusOneStoredAckMarker.self
            )
            #expect(oldAck.count == 1)
            #expect(oldAck.first?.1.deliveryId == identity.deliveryId)
            #expect(oldAck.first?.1.stage == .inboxDurable)
        }
    }

    @Test
    func conflictingPayloadForFullIdentityNeverOverwritesTheDurableBytes() async throws {
        try await withIsolatedAutomationStorage { _, appGroupIdentifier in
            let journal = DurableIngressJournal(appGroupIdentifier: appGroupIdentifier)
            let identity = testDeliveryIdentity(
                deliveryId: "immutable-delivery",
                ackContract: .legacySingle
            )
            #expect(await journal.enqueueIngress(
                codablePayload: [
                    "delivery_id": AnyCodable(identity.deliveryId),
                    "message_id": AnyCodable("immutable-message"),
                    "title": AnyCodable("Before"),
                ],
                requestIdentifier: identity.deliveryId,
                source: "test.first",
                ackIdentity: identity
            ))
            let entryID = try #require(
                await journal.pendingIngressEntries(limit: nil).first?.record.entryId
            )

            #expect(await journal.enqueueIngress(
                codablePayload: [
                    "delivery_id": AnyCodable(identity.deliveryId),
                    "message_id": AnyCodable("immutable-message"),
                    "title": AnyCodable("After"),
                ],
                requestIdentifier: identity.deliveryId,
                source: "test.conflict",
                ackIdentity: identity
            ) == false)

            let databaseURL = try #require(await journal.databaseURL)
            let persisted = try SQLiteTestConnection(url: databaseURL).payload(entryID: entryID)
            #expect(persisted?["title"]?.value as? String == "Before")
            #expect(await journal.pendingIngressEntries(limit: nil).isEmpty)
            #expect(await journal.diagnostics().quarantined == 1)
        }
    }
}
