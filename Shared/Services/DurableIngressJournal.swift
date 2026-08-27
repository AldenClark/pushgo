import CryptoKit
import Darwin
import Foundation
import SQLite3

private let ingressSQLiteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Cross-process, App Group durable handoff used by notification extensions and
/// host applications. It intentionally owns only ingress/retry state; canonical
/// Message/Event/Thing data remains in LocalDataStore.
actor DurableIngressJournal {
    enum JournalError: Error {
        case unavailable
        case unsupportedSchema(Int)
        case sqlite(String)
        case encoding
    }

    static let shared = DurableIngressJournal()

    private static let schemaVersion = 1
    private static let directoryName = "PushGoIngress"
    private static let databaseName = "ingress.sqlite"
    private static let emergencyDirectoryName = "EmergencyIngress"
    private static let emergencyFileExtension = "ingress-emergency"
    private static let supportedApplyStates = "'pending','retry_wait','applying','applied','discarded','quarantined'"
    private static let contentionRetryCount = 2
    private static let pendingScanTotalBudget = 10_000
    private static let legacyRollbackShadowRetentionMilliseconds: Int64 = 35 * 24 * 60 * 60 * 1_000

    private let fileManager: FileManager
    private let appGroupIdentifier: String
    private let busyTimeoutMilliseconds: Int32
    private let pendingScanWindowLimit: Int?
    private let durabilitySynchronizer: @Sendable (URL) -> Bool
    private let rollbackShadowWriteAllowed: @Sendable (URL) -> Bool
    private let encoder: PropertyListEncoder
    private let decoder = PropertyListDecoder()
    private var lastMaintenanceAtMilliseconds: Int64 = 0

    private struct EmergencyIngressRecord: Codable {
        let schemaVersion: Int
        let codablePayload: [String: AnyCodable]
        let requestIdentifier: String?
        let source: String
        let ackIdentity: ProviderDeliveryAckFailureStore.DeliveryIdentity?
        let requiredEntryState: String
        let entryID: String
        let payloadFingerprint: String
        let createdAtEpochMs: Int64
    }

    struct MaintenanceResult: Sendable, Equatable {
        let ackRows: Int
        let ingressRows: Int
        let pullClaimRows: Int

        static let none = MaintenanceResult(ackRows: 0, ingressRows: 0, pullClaimRows: 0)

        var total: Int { ackRows + ingressRows + pullClaimRows }
    }

    struct EnqueueResult: Sendable, Equatable {
        let accepted: Bool
        let inserted: Bool

        static let rejected = EnqueueResult(accepted: false, inserted: false)
    }

    struct DurabilityPragmas: Sendable, Equatable {
        let journalMode: String
        let synchronous: Int
        let fullfsync: Int
    }

    struct RollbackShadowHealth: Sendable, Equatable {
        let failureCount: Int
        let lastKind: String?
        let lastReason: String?
        let lastFailureAt: Date?

        static let healthy = RollbackShadowHealth(
            failureCount: 0,
            lastKind: nil,
            lastReason: nil,
            lastFailureAt: nil
        )
    }

    init(
        fileManager: FileManager = .default,
        appGroupIdentifier: String = AppConstants.appGroupIdentifier,
        busyTimeoutMilliseconds: Int32 = 200,
        pendingScanWindowLimit: Int? = nil,
        durabilitySynchronizer: (@Sendable (URL) -> Bool)? = nil,
        rollbackShadowWriteAllowed: @escaping @Sendable (URL) -> Bool = { _ in true }
    ) {
        self.fileManager = fileManager
        self.appGroupIdentifier = appGroupIdentifier
        self.busyTimeoutMilliseconds = max(1, busyTimeoutMilliseconds)
        self.pendingScanWindowLimit = pendingScanWindowLimit.map { max(1, $0) }
        self.durabilitySynchronizer = durabilitySynchronizer ?? Self.fullSynchronize
        self.rollbackShadowWriteAllowed = rollbackShadowWriteAllowed
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        self.encoder = encoder
    }

    var databaseURL: URL? {
        guard let containerURL = AppConstants.appGroupContainerURL(
            fileManager: fileManager,
            identifier: appGroupIdentifier
        ) else { return nil }
        return containerURL
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent(Self.directoryName, isDirectory: true)
            .appendingPathComponent(Self.databaseName, isDirectory: false)
    }

    func durabilityPragmas() -> DurabilityPragmas? {
        try? withDatabase(write: true) { db in
            guard let journalMode = try pragmaText(db, name: "journal_mode"),
                  let synchronous = try pragmaInt(db, name: "synchronous"),
                  let fullfsync = try pragmaInt(db, name: "fullfsync")
            else { throw JournalError.unavailable }
            return DurabilityPragmas(
                journalMode: journalMode.lowercased(),
                synchronous: synchronous,
                fullfsync: fullfsync
            )
        }
    }

    func rollbackShadowHealth() -> RollbackShadowHealth {
        (try? withDatabase(write: false) { db in
            let statement = try prepare(
                db,
                """
                SELECT failure_count, last_kind, last_reason, last_failure_at_ms
                FROM rollback_shadow_health WHERE singleton_id = 1;
                """
            )
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW else { return .healthy }
            let timestamp = sqlite3_column_type(statement, 3) == SQLITE_NULL
                ? nil
                : Date(
                    timeIntervalSince1970: TimeInterval(sqlite3_column_int64(statement, 3)) / 1_000
                )
            return RollbackShadowHealth(
                failureCount: Int(sqlite3_column_int64(statement, 0)),
                lastKind: columnText(statement, 1),
                lastReason: columnText(statement, 2),
                lastFailureAt: timestamp
            )
        }) ?? .healthy
    }

    /// Same-release, read-only compatibility importer for the three legacy file
    /// stores. Successful imports are removed only after the SQLite write is
    /// durable. Unreadable/newer files are quarantined instead of silently
    /// discarded, and the importer is idempotent across processes.
    func importLegacyStateIfNeeded() {
        guard let containerURL = AppConstants.appGroupContainerURL(
            fileManager: fileManager,
            identifier: appGroupIdentifier
        ) else { return }
        let applicationSupport = containerURL
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
        let inboxDirectory = applicationSupport.appendingPathComponent(
            "notification-ingress-inbox",
            isDirectory: true
        )
        let ackDirectory = applicationSupport.appendingPathComponent(
            "provider-delivery-ack-failures",
            isDirectory: true
        )
        let claimDirectory = applicationSupport.appendingPathComponent(
            "provider-wakeup-pull-claims",
            isDirectory: true
        )
        importLegacyInbox(at: inboxDirectory)
        importLegacyAckMarkers(at: ackDirectory)
        importLegacyPullClaims(at: claimDirectory)
        // The compatibility window is intentionally not a one-shot scan. An
        // older extension may write a legacy file after the host's first empty
        // scan, and that late file must remain discoverable in this process.
        importEmergencyIngress()
    }

    @discardableResult
    func enqueueIngress(
        codablePayload: [String: AnyCodable],
        requestIdentifier: String?,
        source: String,
        ackIdentity: ProviderDeliveryAckFailureStore.DeliveryIdentity? = nil,
        requiredEntryState: String = "durable",
        postChangeNotification: Bool = true
    ) -> Bool {
        enqueueIngressResult(
            codablePayload: codablePayload,
            requestIdentifier: requestIdentifier,
            source: source,
            ackIdentity: ackIdentity,
            requiredEntryState: requiredEntryState,
            trackNotificationProjection: false,
            postChangeNotification: postChangeNotification
        ).accepted
    }

    func enqueueIngressResult(
        codablePayload: [String: AnyCodable],
        requestIdentifier: String?,
        source: String,
        ackIdentity: ProviderDeliveryAckFailureStore.DeliveryIdentity? = nil,
        requiredEntryState: String = "durable",
        trackNotificationProjection: Bool = true,
        postChangeNotification: Bool = true
    ) -> EnqueueResult {
        let payload: Data
        do {
            payload = try encoder.encode(codablePayload)
        } catch {
            return .rejected
        }
        let payloadFingerprint = Self.fingerprint(payload)
        let deliveryID = normalized(codablePayload["delivery_id"]?.value as? String)
        let messageID = normalized(codablePayload["message_id"]?.value as? String)
        let entityType = normalized(codablePayload["entity_type"]?.value as? String)
        let entityID = normalized(codablePayload["entity_id"]?.value as? String)
        let emergency = EmergencyIngressRecord(
            schemaVersion: Self.schemaVersion,
            codablePayload: codablePayload,
            requestIdentifier: normalized(requestIdentifier),
            source: normalized(source) ?? "unknown",
            ackIdentity: ackIdentity,
            requiredEntryState: requiredEntryState,
            entryID: Self.entryID(
                ackIdentity: ackIdentity,
                deliveryID: deliveryID,
                payloadBaseURL: normalized(codablePayload["base_url"]?.value as? String),
                payloadDeviceKey: normalized(codablePayload["provider_device_key"]?.value as? String),
                payloadFingerprint: payloadFingerprint
            ),
            payloadFingerprint: payloadFingerprint,
            createdAtEpochMs: Self.epochMilliseconds(Date())
        )
        let projectionIdentity = trackNotificationProjection
            ? Self.projectionIdentity(
                messageID: messageID,
                ingressEntryID: emergency.entryID
            )
            : nil
        do {
            let result = try persistIngressWithContentionRetry(
                emergency,
                payload: payload,
                deliveryID: deliveryID,
                messageID: messageID,
                entityType: entityType,
                entityID: entityID,
                projectionIdentity: projectionIdentity
            )
            if result.accepted { persistLegacyRollbackShadows(emergency) }
            if postChangeNotification { postIngressChangedNotification() }
            return result
        } catch {
            // Once the payload is encoded, every thrown primary-store failure
            // gets the same atomic sidecar fallback. A normal `false` result
            // (for example, an identity conflict) never enters this path.
            guard persistEmergencyIngress(emergency) else { return .rejected }
            persistLegacyRollbackShadows(emergency)
            if postChangeNotification { postIngressChangedNotification() }
            // The sidecar path cannot atomically prove whether another process
            // already persisted the same delivery. Keep the badge conservative;
            // the host's canonical snapshot rebuild will reconcile the count.
            return EnqueueResult(accepted: true, inserted: false)
        }
    }

    private func persistIngressWithContentionRetry(
        _ emergency: EmergencyIngressRecord,
        payload: Data,
        deliveryID: String?,
        messageID: String?,
        entityType: String?,
        entityID: String?,
        projectionIdentity: String? = nil
    ) throws -> EnqueueResult {
        var attempt = 0
        while true {
            do {
                return try persistIngress(
                    emergency,
                    payload: payload,
                    deliveryID: deliveryID,
                    messageID: messageID,
                    entityType: entityType,
                    entityID: entityID,
                    projectionIdentity: projectionIdentity
                )
            } catch {
                guard isContentionError(error), attempt < Self.contentionRetryCount else {
                    throw error
                }
                let exponentialMilliseconds = 8 * (1 << attempt)
                let jitterMilliseconds = Int.random(in: 3...13)
                Thread.sleep(
                    forTimeInterval: Double(exponentialMilliseconds + jitterMilliseconds) / 1_000
                )
                attempt += 1
            }
        }
    }

    private func persistIngress(
        _ emergency: EmergencyIngressRecord,
        payload: Data,
        deliveryID: String?,
        messageID: String?,
        entityType: String?,
        entityID: String?,
        projectionIdentity: String? = nil
    ) throws -> EnqueueResult {
        let now = emergency.createdAtEpochMs
        return try withDatabase(write: true) { db in
                try execute(db, "BEGIN IMMEDIATE;")
                do {
                    let previousFingerprint = try ingressFingerprint(
                        db,
                        entryID: emergency.entryID
                    )
                    let statement = try prepare(
                        db,
                        """
                        INSERT INTO ingress_entry (
                            entry_id, schema_version, source, source_base_url, source_device_key,
                            resolution_state, request_identifier, delivery_id, message_id,
                            entity_type, entity_id, payload_plist, validation_state, apply_state,
                            lease_generation, apply_attempts, next_apply_at_ms, created_at_ms,
                            payload_fingerprint
                        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'validated', 'pending', 0, 0, ?, ?, ?)
                        ON CONFLICT(entry_id) DO UPDATE SET
                            source = excluded.source,
                            request_identifier = COALESCE(excluded.request_identifier, ingress_entry.request_identifier),
                            source_base_url = COALESCE(ingress_entry.source_base_url, excluded.source_base_url),
                            source_device_key = COALESCE(ingress_entry.source_device_key, excluded.source_device_key),
                            schema_version = CASE
                                WHEN ingress_entry.source = 'ack_import'
                                  AND ingress_entry.validation_state = 'rejected_deterministic'
                                  AND ingress_entry.apply_state = 'discarded'
                                  AND ingress_entry.payload_plist IS NULL
                                THEN excluded.schema_version ELSE ingress_entry.schema_version END,
                            message_id = CASE
                                WHEN ingress_entry.source = 'ack_import'
                                  AND ingress_entry.validation_state = 'rejected_deterministic'
                                  AND ingress_entry.apply_state = 'discarded'
                                  AND ingress_entry.payload_plist IS NULL
                                THEN excluded.message_id ELSE ingress_entry.message_id END,
                            entity_type = CASE
                                WHEN ingress_entry.source = 'ack_import'
                                  AND ingress_entry.validation_state = 'rejected_deterministic'
                                  AND ingress_entry.apply_state = 'discarded'
                                  AND ingress_entry.payload_plist IS NULL
                                THEN excluded.entity_type ELSE ingress_entry.entity_type END,
                            entity_id = CASE
                                WHEN ingress_entry.source = 'ack_import'
                                  AND ingress_entry.validation_state = 'rejected_deterministic'
                                  AND ingress_entry.apply_state = 'discarded'
                                  AND ingress_entry.payload_plist IS NULL
                                THEN excluded.entity_id ELSE ingress_entry.entity_id END,
                            payload_plist = CASE
                                WHEN ingress_entry.source = 'ack_import'
                                  AND ingress_entry.validation_state = 'rejected_deterministic'
                                  AND ingress_entry.apply_state = 'discarded'
                                  AND ingress_entry.payload_plist IS NULL
                                THEN excluded.payload_plist ELSE ingress_entry.payload_plist END,
                            validation_state = CASE
                                WHEN ingress_entry.source = 'ack_import'
                                  AND ingress_entry.validation_state = 'rejected_deterministic'
                                  AND ingress_entry.apply_state = 'discarded'
                                  AND ingress_entry.payload_plist IS NULL
                                THEN 'validated' ELSE ingress_entry.validation_state END,
                            apply_state = CASE
                                WHEN ingress_entry.source = 'ack_import'
                                  AND ingress_entry.validation_state = 'rejected_deterministic'
                                  AND ingress_entry.apply_state = 'discarded'
                                  AND ingress_entry.payload_plist IS NULL
                                THEN 'pending' ELSE ingress_entry.apply_state END,
                            discard_reason = CASE
                                WHEN ingress_entry.source = 'ack_import'
                                  AND ingress_entry.validation_state = 'rejected_deterministic'
                                  AND ingress_entry.apply_state = 'discarded'
                                  AND ingress_entry.payload_plist IS NULL
                                THEN NULL ELSE ingress_entry.discard_reason END,
                            payload_fingerprint = CASE
                                WHEN ingress_entry.source = 'ack_import'
                                  AND ingress_entry.validation_state = 'rejected_deterministic'
                                  AND ingress_entry.apply_state = 'discarded'
                                  AND ingress_entry.payload_plist IS NULL
                                THEN excluded.payload_fingerprint ELSE ingress_entry.payload_fingerprint END
                        WHERE ingress_entry.payload_fingerprint = excluded.payload_fingerprint
                           OR (ingress_entry.source = 'ack_import'
                               AND ingress_entry.schema_version <= ?
                               AND ingress_entry.validation_state = 'rejected_deterministic'
                               AND ingress_entry.apply_state = 'discarded'
                               AND ingress_entry.payload_plist IS NULL
                               AND ingress_entry.discard_reason = 'legacy_ack_import'
                               AND ingress_entry.payload_fingerprint = ?
                               AND ingress_entry.source_base_url = excluded.source_base_url
                               AND ingress_entry.source_device_key = excluded.source_device_key
                               AND ingress_entry.delivery_id = excluded.delivery_id
                               AND ingress_entry.resolution_state = excluded.resolution_state);
                        """
                    )
                    defer { sqlite3_finalize(statement) }
                    bindText(statement, 1, emergency.entryID)
                    sqlite3_bind_int(statement, 2, Int32(Self.schemaVersion))
                    bindText(statement, 3, emergency.source)
                    bindText(
                        statement,
                        4,
                        emergency.ackIdentity?.baseURLString
                            ?? normalized(emergency.codablePayload["base_url"]?.value as? String)
                    )
                    bindText(
                        statement,
                        5,
                        emergency.ackIdentity?.deviceKey
                            ?? normalized(emergency.codablePayload["provider_device_key"]?.value as? String)
                    )
                    bindText(statement, 6, emergency.ackIdentity?.ackContract == .v2Batch ? "pulled" : "direct")
                    bindText(statement, 7, emergency.requestIdentifier)
                    bindText(statement, 8, deliveryID ?? emergency.ackIdentity?.deliveryId)
                    bindText(statement, 9, messageID)
                    bindText(statement, 10, entityType)
                    bindText(statement, 11, entityID)
                    bindBlob(statement, 12, payload)
                    sqlite3_bind_int64(statement, 13, now)
                    sqlite3_bind_int64(statement, 14, now)
                    bindText(statement, 15, emergency.payloadFingerprint)
                    sqlite3_bind_int(statement, 16, Int32(Self.schemaVersion))
                    bindText(
                        statement,
                        17,
                        emergency.ackIdentity.map {
                            Self.fingerprint(Data($0.deliveryId.utf8))
                        }
                    )
                    try stepDone(db, statement)

                    guard try ingressFingerprint(db, entryID: emergency.entryID) == emergency.payloadFingerprint else {
                        try quarantineIngressIdentityConflict(
                            db,
                            entryID: emergency.entryID,
                            now: now
                        )
                        try incrementGeneration(db)
                        try execute(db, "COMMIT;")
                        return .rejected
                    }

                    if let ackIdentity = emergency.ackIdentity {
                        try upsertAck(
                            db,
                            identity: ackIdentity,
                            entryID: emergency.entryID,
                            requiredEntryState: emergency.requiredEntryState,
                            source: emergency.source,
                            now: now
                        )
                    }
                    let projectionInserted = try projectionIdentity.map {
                        try insertNotificationProjectionReceipt(
                            db,
                            identity: $0,
                            createdAt: now
                        )
                    }
                    try incrementGeneration(db)
                    try execute(db, "COMMIT;")
                    return EnqueueResult(
                        accepted: true,
                        inserted: projectionInserted
                            ?? (previousFingerprint != emergency.payloadFingerprint)
                    )
                } catch {
                    _ = try? execute(db, "ROLLBACK;")
                    throw error
                }
        }
    }

    func pendingIngressEntries(
        limit: Int?,
        now: Date = Date()
    ) -> [NotificationIngressInbox.PendingEntry] {
        importEmergencyIngress()
        let requestedLimit = min(10_000, max(1, limit ?? 10_000))
        let defaultWindow = min(10_000, max(256, requestedLimit * 8))
        let configuredWindow = min(Self.pendingScanTotalBudget, pendingScanWindowLimit ?? defaultWindow)
        var remainingBudget = Self.pendingScanTotalBudget
        var entries: [NotificationIngressInbox.PendingEntry] = []
        var madeQuarantineProgress = false

        while entries.count < requestedLimit, remainingBudget > 0 {
            do {
                let scanLimit = min(configuredWindow, remainingBudget)
                let result: ([NotificationIngressInbox.PendingEntry], [(String, String)], Int) = try withDatabase(write: false) { db in
                    let sql = """
                        SELECT entry_id, schema_version, created_at_ms, source, request_identifier,
                               payload_plist, payload_fingerprint
                        FROM ingress_entry
                        WHERE apply_state IN ('pending','retry_wait') AND next_apply_at_ms <= ?
                        ORDER BY created_at_ms ASC, entry_id ASC LIMIT ?;
                        """
                    let statement = try prepare(db, sql)
                    defer { sqlite3_finalize(statement) }
                    sqlite3_bind_int64(statement, 1, Self.epochMilliseconds(now))
                    sqlite3_bind_int64(statement, 2, Int64(scanLimit))
                    var windowEntries: [NotificationIngressInbox.PendingEntry] = []
                    var invalidRows: [(String, String)] = []
                    var scanned = 0
                    while sqlite3_step(statement) == SQLITE_ROW {
                        scanned += 1
                        guard let entryID = columnText(statement, 0) else { continue }
                        let schemaVersion = Int(sqlite3_column_int(statement, 1))
                        guard schemaVersion <= Self.schemaVersion else {
                            invalidRows.append((entryID, "unsupported_schema_\(schemaVersion)"))
                            continue
                        }
                        guard let source = columnText(statement, 3),
                              let payloadData = columnBlob(statement, 5),
                              let expectedFingerprint = columnText(statement, 6),
                              Self.fingerprint(payloadData) == expectedFingerprint,
                              let payload = try? decoder.decode([String: AnyCodable].self, from: payloadData)
                        else {
                            invalidRows.append((entryID, "malformed_or_fingerprint_mismatch"))
                            continue
                        }
                        let record = NotificationIngressInbox.StoredEntry(
                            schemaVersion: schemaVersion,
                            entryId: entryID,
                            createdAtEpochMs: sqlite3_column_int64(statement, 2),
                            source: source,
                            requestIdentifier: columnText(statement, 4),
                            payload: payload
                        )
                        windowEntries.append(
                            NotificationIngressInbox.PendingEntry(
                                fileName: entryID,
                                fileURL: databaseURL ?? URL(fileURLWithPath: "/dev/null"),
                                record: record
                            )
                        )
                        if entries.count + windowEntries.count >= requestedLimit { break }
                    }
                    return (windowEntries, invalidRows, scanned)
                }
                remainingBudget -= result.2
                entries.append(contentsOf: result.0)
                let quarantined = quarantineInvalidIngressRows(result.1)
                madeQuarantineProgress = madeQuarantineProgress || quarantined > 0

                // Pending rows remain query-visible until the caller applies
                // them. Once this pass found usable work, return it instead of
                // scanning the same prefix again and duplicating entries.
                if !entries.isEmpty || result.2 < scanLimit { break }
                if result.1.isEmpty || quarantined == 0 { break }
            } catch {
                break
            }
        }

        if madeQuarantineProgress, entries.isEmpty, remainingBudget == 0 {
            // The caller interprets an empty batch as drained. Re-trigger a later
            // bounded pass when this pass spent its entire budget quarantining.
            postIngressChangedNotification()
        }
        return entries
    }

    func ingressQueueCounts(
        now: Date = Date()
    ) -> NotificationIngressInbox.QueueCounts {
        let nowMilliseconds = Self.epochMilliseconds(now)
        return (try? withDatabase(write: false) { db in
            let statement = try prepare(
                db,
                """
                SELECT
                    COALESCE(SUM(CASE
                        WHEN apply_state IN ('pending','retry_wait')
                             AND next_apply_at_ms <= ? THEN 1
                        WHEN apply_state = 'applying'
                             AND COALESCE(lease_until_ms, 0) <= ? THEN 1
                        ELSE 0
                    END), 0),
                    COUNT(*)
                FROM ingress_entry
                WHERE apply_state IN ('pending','retry_wait','applying');
                """
            )
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_int64(statement, 1, nowMilliseconds)
            sqlite3_bind_int64(statement, 2, nowMilliseconds)
            guard sqlite3_step(statement) == SQLITE_ROW else {
                return .zero
            }
            return NotificationIngressInbox.QueueCounts(
                due: Int(sqlite3_column_int64(statement, 0)),
                outstanding: Int(sqlite3_column_int64(statement, 1))
            )
        }) ?? .zero
    }

    func claimPendingIngressEntries(
        owner: String,
        leaseDuration: TimeInterval,
        limit: Int,
        now: Date = Date()
    ) -> [NotificationIngressInbox.ClaimedEntry] {
        importEmergencyIngress()
        let normalizedOwner = normalized(owner) ?? "app.ingress.unknown"
        let requestedLimit = min(512, max(1, limit))
        let nowMilliseconds = Self.epochMilliseconds(now)
        let leaseUntil = Self.epochMilliseconds(
            now.addingTimeInterval(max(1, leaseDuration))
        )

        // A killed owner leaves `applying` rows behind. Rearming is a separate
        // short transaction so ordinary pending scanning can keep its poison-row
        // quarantine behavior; the later claim CAS still arbitrates peers.
        try? withDatabase(write: true) { db in
            let statement = try prepare(
                db,
                """
                UPDATE ingress_entry
                SET apply_state = 'retry_wait', lease_owner = NULL,
                    lease_until_ms = NULL, next_apply_at_ms = ?
                WHERE apply_state = 'applying'
                  AND COALESCE(lease_until_ms, 0) <= ?;
                """
            )
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_int64(statement, 1, nowMilliseconds)
            sqlite3_bind_int64(statement, 2, nowMilliseconds)
            try stepDone(db, statement)
        }

        let candidates = pendingIngressEntries(limit: requestedLimit, now: now)
        guard !candidates.isEmpty else { return [] }
        return (try? withDatabase(write: true) { db in
            try execute(db, "BEGIN IMMEDIATE;")
            do {
                let update = try prepare(
                    db,
                    """
                    UPDATE ingress_entry
                    SET apply_state = 'applying', lease_owner = ?,
                        lease_until_ms = ?, lease_generation = lease_generation + 1,
                        apply_attempts = apply_attempts + 1
                    WHERE entry_id = ?
                      AND apply_state IN ('pending','retry_wait')
                      AND next_apply_at_ms <= ?;
                    """
                )
                defer { sqlite3_finalize(update) }
                let generationQuery = try prepare(
                    db,
                    "SELECT lease_generation FROM ingress_entry WHERE entry_id = ? AND apply_state = 'applying' AND lease_owner = ?;"
                )
                defer { sqlite3_finalize(generationQuery) }
                var claimed: [NotificationIngressInbox.ClaimedEntry] = []
                claimed.reserveCapacity(candidates.count)
                for candidate in candidates {
                    sqlite3_reset(update)
                    sqlite3_clear_bindings(update)
                    bindText(update, 1, normalizedOwner)
                    sqlite3_bind_int64(update, 2, leaseUntil)
                    bindText(update, 3, candidate.record.entryId)
                    sqlite3_bind_int64(update, 4, nowMilliseconds)
                    try stepDone(db, update)
                    guard sqlite3_changes(db) == 1 else { continue }

                    sqlite3_reset(generationQuery)
                    sqlite3_clear_bindings(generationQuery)
                    bindText(generationQuery, 1, candidate.record.entryId)
                    bindText(generationQuery, 2, normalizedOwner)
                    guard sqlite3_step(generationQuery) == SQLITE_ROW else { continue }
                    claimed.append(
                        NotificationIngressInbox.ClaimedEntry(
                            entry: candidate,
                            owner: normalizedOwner,
                            leaseGeneration: sqlite3_column_int64(generationQuery, 0)
                        )
                    )
                }
                if !claimed.isEmpty { try incrementGeneration(db) }
                try execute(db, "COMMIT;")
                return claimed
            } catch {
                _ = try? execute(db, "ROLLBACK;")
                throw error
            }
        }) ?? []
    }

    /// Returns the earliest durable canonical-apply retry. The host uses this
    /// deadline to wake itself even when no later notification or lifecycle
    /// event arrives to trigger another inbox merge.
    func nextIngressRetryDate(now: Date = Date()) -> Date? {
        do {
            return try withDatabase(write: false) { db in
                let statement = try prepare(
                    db,
                    """
                    SELECT MIN(next_apply_at_ms)
                    FROM ingress_entry
                    WHERE apply_state = 'retry_wait'
                      AND schema_version <= \(Self.schemaVersion);
                    """
                )
                defer { sqlite3_finalize(statement) }
                guard sqlite3_step(statement) == SQLITE_ROW,
                      sqlite3_column_type(statement, 0) != SQLITE_NULL
                else { return nil }
                let due = sqlite3_column_int64(statement, 0)
                return Date(
                    timeIntervalSince1970: TimeInterval(
                        max(due, Self.epochMilliseconds(now))
                    ) / 1_000
                )
            }
        } catch {
            return nil
        }
    }

    func durableIngressPayload(
        identity: ProviderDeliveryAckFailureStore.DeliveryIdentity
    ) -> [String: AnyCodable]? {
        do {
            return try withDatabase(write: false) { db in
                let statement = try prepare(
                    db,
                    """
                    SELECT payload_plist FROM ingress_entry
                    WHERE source_base_url = ? AND source_device_key = ? AND delivery_id = ?
                      AND resolution_state = ?
                      AND validation_state = 'validated' AND apply_state != 'quarantined'
                      AND payload_plist IS NOT NULL
                    LIMIT 1;
                    """
                )
                defer { sqlite3_finalize(statement) }
                bindText(statement, 1, identity.baseURLString)
                bindText(statement, 2, identity.deviceKey)
                bindText(statement, 3, identity.deliveryId)
                bindText(statement, 4, identity.ackContract == .v2Batch ? "pulled" : "direct")
                guard sqlite3_step(statement) == SQLITE_ROW,
                      let payload = columnBlob(statement, 0)
                else { return nil }
                return try decoder.decode([String: AnyCodable].self, from: payload)
            }
        } catch {
            return nil
        }
    }

    func markIngressCompleted(entryID: String) {
        let now = Self.epochMilliseconds(Date())
        try? withDatabase(write: true) { db in
            let statement = try prepare(
                db,
                "UPDATE ingress_entry SET apply_state = 'applied', canonical_applied_at_ms = ?, lease_owner = NULL, lease_until_ms = NULL WHERE entry_id = ? AND apply_state IN ('pending','retry_wait','applying');"
            )
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_int64(statement, 1, now)
            bindText(statement, 2, entryID)
            try stepDone(db, statement)
        }
    }

    func markIngressCompleted(
        entryID: String,
        owner: String,
        leaseGeneration: Int64
    ) -> Bool {
        let now = Self.epochMilliseconds(Date())
        return (try? withDatabase(write: true) { db in
            let statement = try prepare(
                db,
                """
                UPDATE ingress_entry
                SET apply_state = 'applied', canonical_applied_at_ms = ?,
                    lease_owner = NULL, lease_until_ms = NULL
                WHERE entry_id = ? AND apply_state = 'applying'
                  AND lease_owner = ? AND lease_generation = ?;
                """
            )
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_int64(statement, 1, now)
            bindText(statement, 2, entryID)
            bindText(statement, 3, owner)
            sqlite3_bind_int64(statement, 4, leaseGeneration)
            try stepDone(db, statement)
            return sqlite3_changes(db) == 1
        }) ?? false
    }

    func markIngressCompleted(
        _ claimedEntries: [NotificationIngressInbox.ClaimedEntry]
    ) -> Int {
        guard !claimedEntries.isEmpty else { return 0 }
        let now = Self.epochMilliseconds(Date())
        return (try? withDatabase(write: true) { db in
            try execute(db, "BEGIN IMMEDIATE;")
            do {
                let statement = try prepare(
                    db,
                    """
                    UPDATE ingress_entry
                    SET apply_state = 'applied', canonical_applied_at_ms = ?,
                        lease_owner = NULL, lease_until_ms = NULL
                    WHERE entry_id = ? AND apply_state = 'applying'
                      AND lease_owner = ? AND lease_generation = ?;
                    """
                )
                defer { sqlite3_finalize(statement) }
                var completed = 0
                for claimed in claimedEntries {
                    sqlite3_reset(statement)
                    sqlite3_clear_bindings(statement)
                    sqlite3_bind_int64(statement, 1, now)
                    bindText(statement, 2, claimed.record.entryId)
                    bindText(statement, 3, claimed.owner)
                    sqlite3_bind_int64(statement, 4, claimed.leaseGeneration)
                    try stepDone(db, statement)
                    completed += Int(sqlite3_changes(db))
                }
                try execute(db, "COMMIT;")
                return completed
            } catch {
                _ = try? execute(db, "ROLLBACK;")
                throw error
            }
        }) ?? 0
    }

    func markIngressRetry(entryID: String, reason: String, retryAfter: Date) {
        let now = Self.epochMilliseconds(Date())
        try? withDatabase(write: true) { db in
            let statement = try prepare(
                db,
                """
                UPDATE ingress_entry SET apply_state = 'retry_wait', apply_attempts = apply_attempts + 1,
                    next_apply_at_ms = ?, quarantine_reason = ?, lease_owner = NULL,
                    lease_until_ms = NULL
                WHERE entry_id = ? AND apply_state IN ('pending','retry_wait','applying');
                """
            )
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_int64(statement, 1, max(now, Self.epochMilliseconds(retryAfter)))
            bindText(statement, 2, normalized(reason).map { String($0.prefix(128)) })
            bindText(statement, 3, entryID)
            try stepDone(db, statement)
        }
    }

    func markIngressRetry(
        entryID: String,
        owner: String,
        leaseGeneration: Int64,
        reason: String,
        retryAfter: Date
    ) -> Bool {
        let now = Self.epochMilliseconds(Date())
        return (try? withDatabase(write: true) { db in
            let statement = try prepare(
                db,
                """
                UPDATE ingress_entry
                SET apply_state = 'retry_wait', next_apply_at_ms = ?,
                    quarantine_reason = ?, lease_owner = NULL, lease_until_ms = NULL
                WHERE entry_id = ? AND apply_state = 'applying'
                  AND lease_owner = ? AND lease_generation = ?;
                """
            )
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_int64(statement, 1, max(now, Self.epochMilliseconds(retryAfter)))
            bindText(statement, 2, normalized(reason).map { String($0.prefix(128)) })
            bindText(statement, 3, entryID)
            bindText(statement, 4, owner)
            sqlite3_bind_int64(statement, 5, leaseGeneration)
            try stepDone(db, statement)
            return sqlite3_changes(db) == 1
        }) ?? false
    }

    func markIngressTerminal(
        identity: ProviderDeliveryAckFailureStore.DeliveryIdentity,
        discarded: Bool,
        reason: String? = nil
    ) {
        let now = Self.epochMilliseconds(Date())
        let terminalCommitted = (try? withDatabase(write: true) { db in
            let statement = try prepare(
                db,
                """
                UPDATE ingress_entry SET apply_state = ?, canonical_applied_at_ms = ?,
                    discard_reason = ?, lease_owner = NULL, lease_until_ms = NULL
                WHERE source_base_url = ? AND source_device_key = ? AND delivery_id = ?
                  AND resolution_state = ?
                  AND apply_state IN ('pending','retry_wait','applying');
                """
            )
            defer { sqlite3_finalize(statement) }
            bindText(statement, 1, discarded ? "discarded" : "applied")
            sqlite3_bind_int64(statement, 2, now)
            bindText(statement, 3, discarded ? (normalized(reason) ?? "deterministic_reject") : nil)
            bindText(statement, 4, identity.baseURLString)
            bindText(statement, 5, identity.deviceKey)
            bindText(statement, 6, identity.deliveryId)
            bindText(statement, 7, identity.ackContract == .v2Batch ? "pulled" : "direct")
            try stepDone(db, statement)
            let selected = try prepare(
                db,
                "SELECT apply_state FROM ingress_entry WHERE source_base_url = ? AND source_device_key = ? AND delivery_id = ? AND resolution_state = ? LIMIT 1;"
            )
            defer { sqlite3_finalize(selected) }
            bindText(selected, 1, identity.baseURLString)
            bindText(selected, 2, identity.deviceKey)
            bindText(selected, 3, identity.deliveryId)
            bindText(selected, 4, identity.ackContract == .v2Batch ? "pulled" : "direct")
            guard sqlite3_step(selected) == SQLITE_ROW,
                  let state = columnText(selected, 0)
            else { return false }
            return state == "applied" || state == "discarded"
        }) ?? false
        if terminalCommitted, identity.ackContract == .v2Batch {
            // The N-1 ACK worker has no terminal-local gate. Publish its
            // rollback artifact only after the canonical transition commits.
            persistLegacyAckShadow(
                identity: identity,
                stage: .inboxDurable,
                attempts: 0,
                retryAfter: nil,
                source: discarded ? "rollback.terminal_discard" : "rollback.terminal_applied"
            )
        }
    }

#if DEBUG
    func purgeTerminalIngressEntriesForPerformanceTesting(source: String) -> (rows: Int, shadows: Int) {
        let normalizedSource = normalized(source)
        guard normalizedSource == "debug.ingress_performance" else { return (0, 0) }
        let shadowRecords: [(kind: String, fileName: String)] = (try? withDatabase(write: false) { db in
            let statement = try prepare(
                db,
                """
                SELECT kind, file_name FROM rollback_shadow
                WHERE identity_key IN (
                    SELECT entry_id FROM ingress_entry
                    WHERE source = ? AND apply_state IN ('applied','discarded','quarantined')
                );
                """
            )
            defer { sqlite3_finalize(statement) }
            bindText(statement, 1, normalizedSource)
            var records: [(String, String)] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                if let kind = columnText(statement, 0), let fileName = columnText(statement, 1) {
                    records.append((kind, fileName))
                }
            }
            return records
        }) ?? []
        let removedRows = (try? withDatabase(write: true) { db in
            try execute(db, "BEGIN IMMEDIATE;")
            do {
                let deleteShadows = try prepare(
                    db,
                    """
                    DELETE FROM rollback_shadow
                    WHERE identity_key IN (
                        SELECT entry_id FROM ingress_entry
                        WHERE source = ? AND apply_state IN ('applied','discarded','quarantined')
                    );
                    """
                )
                defer { sqlite3_finalize(deleteShadows) }
                bindText(deleteShadows, 1, normalizedSource)
                try stepDone(db, deleteShadows)

                let deleteEntries = try prepare(
                    db,
                    "DELETE FROM ingress_entry WHERE source = ? AND apply_state IN ('applied','discarded','quarantined');"
                )
                defer { sqlite3_finalize(deleteEntries) }
                bindText(deleteEntries, 1, normalizedSource)
                try stepDone(db, deleteEntries)
                let rows = Int(sqlite3_changes(db))
                try incrementGeneration(db)
                try execute(db, "COMMIT;")
                return rows
            } catch {
                _ = try? execute(db, "ROLLBACK;")
                throw error
            }
        }) ?? 0

        var removedShadows = 0
        for record in shadowRecords {
            let directoryName: String
            switch record.kind {
            case "inbox": directoryName = "notification-ingress-inbox"
            case "ack": directoryName = "provider-delivery-ack-failures"
            default: continue
            }
            guard let fileURL = legacyApplicationSupportDirectory()?
                .appendingPathComponent(directoryName, isDirectory: true)
                .appendingPathComponent(record.fileName, isDirectory: false)
            else { continue }
            do {
                try fileManager.removeItem(at: fileURL)
                removedShadows += 1
            } catch CocoaError.fileNoSuchFile {
                continue
            } catch {
                continue
            }
        }
        return (removedRows, removedShadows)
    }
#endif

    @discardableResult
    func markAck(
        identity: ProviderDeliveryAckFailureStore.DeliveryIdentity,
        stage: ProviderDeliveryAckFailureStore.Stage,
        source: String,
        retryAfter: Date? = nil
    ) -> Bool {
        if stage == .preparing { return true }
        let now = Self.epochMilliseconds(Date())
        do {
            let changed = try withDatabase(write: true) { db in
                let entryID = Self.entryID(
                    ackIdentity: identity,
                    deliveryID: identity.deliveryId,
                    payloadBaseURL: nil,
                    payloadDeviceKey: nil,
                    payloadFingerprint: identity.storageKey
                )
                try execute(db, "BEGIN IMMEDIATE;")
                do {
                    if try ackState(db, ackID: identity.storageKey).map({
                        $0 == "leased" || $0 == "completed" || $0 == "superseded"
                    }) == true {
                        try execute(db, "COMMIT;")
                        return false
                    }
                    try ensureAckAnchor(db, entryID: entryID, identity: identity, now: now)
                    try upsertAck(
                        db,
                        identity: identity,
                        entryID: entryID,
                        requiredEntryState: identity.ackContract == .v2Batch ? "terminal_local" : "durable",
                        source: source,
                        now: now,
                        nextAttemptAt: retryAfter.map(Self.epochMilliseconds)
                    )
                    try execute(db, "COMMIT;")
                    return true
                } catch {
                    _ = try? execute(db, "ROLLBACK;")
                    throw error
                }
            }
            if changed, identity.ackContract == .legacySingle {
                persistLegacyAckShadow(
                    identity: identity,
                    stage: .inboxDurable,
                    attempts: 0,
                    retryAfter: retryAfter,
                    source: "rollback.\(source)"
                )
            }
            return changed
        } catch {
            return false
        }
    }

    func pendingAckMarkers(
        limit: Int?,
        minimumAge: TimeInterval,
        now: Date
    ) -> [ProviderDeliveryAckFailureStore.PendingMarker] {
        do {
            return try withDatabase(write: false) { db in
                let nowMs = Self.epochMilliseconds(now)
                let minimumCreated = nowMs - Int64(max(0, minimumAge) * 1_000)
                let statement = try prepare(
                    db,
                    """
                    SELECT a.delivery_id, a.base_url, a.device_key, a.ack_contract, a.attempts,
                           a.state, a.lease_owner, a.lease_until_ms, a.next_attempt_at_ms,
                           a.created_at_ms, a.updated_at_ms, a.source, a.lease_generation
                    FROM ack_outbox a JOIN ingress_entry i ON i.entry_id = a.entry_id
                    WHERE a.state IN ('pending','retry_wait')
                      AND a.next_attempt_at_ms <= ? AND a.created_at_ms <= ?
                      AND i.schema_version <= \(Self.schemaVersion)
                      AND i.apply_state != 'quarantined'
                      AND (a.required_entry_state = 'durable' OR i.apply_state IN ('applied','discarded'))
                    ORDER BY a.next_attempt_at_ms ASC, a.created_at_ms ASC LIMIT ?;
                    """
                )
                defer { sqlite3_finalize(statement) }
                sqlite3_bind_int64(statement, 1, nowMs)
                sqlite3_bind_int64(statement, 2, minimumCreated)
                sqlite3_bind_int64(statement, 3, Int64(max(1, limit ?? 10_000)))
                var markers: [ProviderDeliveryAckFailureStore.PendingMarker] = []
                while sqlite3_step(statement) == SQLITE_ROW {
                    guard let marker = decodeAckMarker(statement) else { continue }
                    markers.append(marker)
                }
                return markers
            }
        } catch {
            return []
        }
    }

    func nextAckAttemptDate(now: Date = Date()) -> Date? {
        do {
            return try withDatabase(write: false) { db in
                let statement = try prepare(
                    db,
                    """
                    SELECT MIN(CASE WHEN a.state = 'leased'
                                    THEN COALESCE(a.lease_until_ms, a.next_attempt_at_ms)
                                    ELSE a.next_attempt_at_ms END)
                    FROM ack_outbox a JOIN ingress_entry i ON i.entry_id = a.entry_id
                    WHERE a.state IN ('pending','retry_wait','leased')
                      AND i.schema_version <= \(Self.schemaVersion)
                      AND i.apply_state != 'quarantined'
                      AND (a.required_entry_state = 'durable'
                           OR i.apply_state IN ('applied','discarded'));
                    """
                )
                defer { sqlite3_finalize(statement) }
                guard sqlite3_step(statement) == SQLITE_ROW,
                      sqlite3_column_type(statement, 0) != SQLITE_NULL
                else { return nil }
                let due = sqlite3_column_int64(statement, 0)
                return Date(
                    timeIntervalSince1970: TimeInterval(max(due, Self.epochMilliseconds(now))) / 1_000
                )
            }
        } catch {
            return nil
        }
    }

    func acquireAckLease(
        identity: ProviderDeliveryAckFailureStore.DeliveryIdentity,
        owner: String,
        leaseDuration: TimeInterval,
        now: Date
    ) -> ProviderDeliveryAckFailureStore.PendingMarker? {
        let nowMs = Self.epochMilliseconds(now)
        let leaseUntil = Self.epochMilliseconds(now.addingTimeInterval(max(1, leaseDuration)))
        do {
            return try withDatabase(write: true) { db in
                try execute(db, "BEGIN IMMEDIATE;")
                do {
                    guard try validateAckIngressForLease(
                        db,
                        identity: identity,
                        now: nowMs
                    ) else {
                        try execute(db, "COMMIT;")
                        return nil
                    }
                    let statement = try prepare(
                        db,
                        """
                        UPDATE ack_outbox SET state = 'leased', lease_owner = ?, lease_until_ms = ?,
                            lease_generation = lease_generation + 1, updated_at_ms = ?
                        WHERE ack_id = ? AND (
                            (state IN ('pending','retry_wait') AND next_attempt_at_ms <= ?)
                            OR (state = 'leased' AND lease_until_ms <= ?)
                        ) AND EXISTS (
                            SELECT 1 FROM ingress_entry i
                            WHERE i.entry_id = ack_outbox.entry_id
                              AND i.schema_version <= \(Self.schemaVersion)
                              AND i.apply_state != 'quarantined'
                              AND (ack_outbox.required_entry_state = 'durable'
                                   OR i.apply_state IN ('applied','discarded'))
                        );
                        """
                    )
                    defer { sqlite3_finalize(statement) }
                    bindText(statement, 1, owner)
                    sqlite3_bind_int64(statement, 2, leaseUntil)
                    sqlite3_bind_int64(statement, 3, nowMs)
                    bindText(statement, 4, identity.storageKey)
                    sqlite3_bind_int64(statement, 5, nowMs)
                    sqlite3_bind_int64(statement, 6, nowMs)
                    try stepDone(db, statement)
                    guard sqlite3_changes(db) == 1 else {
                        try execute(db, "COMMIT;")
                        return nil
                    }
                    let selected = try prepare(
                        db,
                        """
                        SELECT delivery_id, base_url, device_key, ack_contract, attempts,
                               state, lease_owner, lease_until_ms, next_attempt_at_ms,
                               created_at_ms, updated_at_ms, source, lease_generation
                        FROM ack_outbox WHERE ack_id = ?;
                        """
                    )
                    defer { sqlite3_finalize(selected) }
                    bindText(selected, 1, identity.storageKey)
                    let marker = sqlite3_step(selected) == SQLITE_ROW ? decodeAckMarker(selected) : nil
                    try execute(db, "COMMIT;")
                    return marker
                } catch {
                    _ = try? execute(db, "ROLLBACK;")
                    throw error
                }
            }
        } catch {
            return nil
        }
    }

    func markAckFailed(
        marker: ProviderDeliveryAckFailureStore.PendingMarker,
        source: String,
        retryAfter: Date?
    ) {
        guard let identity = marker.identity,
              let owner = marker.record.owner,
              let generation = marker.record.leaseGeneration
        else { return }
        let now = Self.epochMilliseconds(Date())
        let retry = retryAfter.map(Self.epochMilliseconds) ?? now + 30_000
        let changed = (try? withDatabase(write: true) { db in
            let statement = try prepare(
                db,
                """
                UPDATE ack_outbox SET state = 'retry_wait', attempts = attempts + 1,
                    next_attempt_at_ms = ?, last_error_code = 'network_or_contract', source = ?,
                    lease_owner = NULL, lease_until_ms = NULL, updated_at_ms = ?
                WHERE ack_id = ? AND state = 'leased' AND lease_owner = ? AND lease_generation = ?;
                """
            )
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_int64(statement, 1, retry)
            bindText(statement, 2, source)
            sqlite3_bind_int64(statement, 3, now)
            bindText(statement, 4, identity.storageKey)
            bindText(statement, 5, owner)
            sqlite3_bind_int64(statement, 6, generation)
            try stepDone(db, statement)
            return sqlite3_changes(db) == 1
        }) ?? false
        if changed {
            persistLegacyAckShadow(
                identity: identity,
                stage: .inboxDurable,
                attempts: (marker.record.attemptCount ?? 0) + 1,
                retryAfter: retryAfter ?? Date(timeIntervalSince1970: TimeInterval(retry) / 1_000),
                source: "rollback.\(source)"
            )
        }
    }

    func markAckCompleted(marker: ProviderDeliveryAckFailureStore.PendingMarker) {
        guard let identity = marker.identity else { return }
        markAckCompleted(
            identity: identity,
            owner: marker.record.owner,
            generation: marker.record.leaseGeneration
        )
    }

    func markAckCompleted(identity: ProviderDeliveryAckFailureStore.DeliveryIdentity) {
        markAckCompleted(identity: identity, owner: nil, generation: nil)
    }

    func acquirePullClaim(
        identity: ProviderDeliveryAckFailureStore.DeliveryIdentity,
        owner: String,
        leaseDuration: TimeInterval,
        now: Date
    ) -> ProviderWakeupPullClaimStore.ClaimLease? {
        let nowMs = Self.epochMilliseconds(now)
        let until = Self.epochMilliseconds(now.addingTimeInterval(max(1, leaseDuration)))
        do {
            return try withDatabase(write: true) { db in
                try execute(db, "BEGIN IMMEDIATE;")
                do {
                    let insert = try prepare(
                        db,
                        """
                        INSERT INTO pull_claim (
                            claim_id, delivery_id, base_url, device_key, pull_contract, state,
                            lease_owner, lease_until_ms, lease_generation, attempts,
                            next_attempt_at_ms, created_at_ms, updated_at_ms
                        ) VALUES (?, ?, ?, ?, ?, 'pending', NULL, NULL, 0, 0, ?, ?, ?)
                        ON CONFLICT(base_url, device_key, delivery_id, pull_contract) DO NOTHING;
                        """
                    )
                    defer { sqlite3_finalize(insert) }
                    bindText(insert, 1, identity.storageKey)
                    bindText(insert, 2, identity.deliveryId)
                    bindText(insert, 3, identity.baseURLString)
                    bindText(insert, 4, identity.deviceKey)
                    bindText(insert, 5, identity.ackContract.rawValue)
                    sqlite3_bind_int64(insert, 6, nowMs)
                    sqlite3_bind_int64(insert, 7, nowMs)
                    sqlite3_bind_int64(insert, 8, nowMs)
                    try stepDone(db, insert)

                    let update = try prepare(
                        db,
                        """
                        UPDATE pull_claim SET state = 'leased', lease_owner = ?, lease_until_ms = ?,
                            lease_generation = lease_generation + 1, updated_at_ms = ?
                        WHERE claim_id = ? AND (
                            (state IN ('pending','retry_wait') AND next_attempt_at_ms <= ?)
                            OR (state = 'leased' AND lease_until_ms <= ?)
                            OR (state = 'completed' AND updated_at_ms <= ?)
                        );
                        """
                    )
                    defer { sqlite3_finalize(update) }
                    bindText(update, 1, owner)
                    sqlite3_bind_int64(update, 2, until)
                    sqlite3_bind_int64(update, 3, nowMs)
                    bindText(update, 4, identity.storageKey)
                    sqlite3_bind_int64(update, 5, nowMs)
                    sqlite3_bind_int64(update, 6, nowMs)
                    sqlite3_bind_int64(update, 7, nowMs - 600_000)
                    try stepDone(db, update)
                    guard sqlite3_changes(db) == 1 else {
                        try execute(db, "COMMIT;")
                        return nil
                    }
                    let selected = try prepare(
                        db,
                        """
                        SELECT delivery_id, base_url, device_key, pull_contract, state,
                               lease_owner, lease_until_ms, created_at_ms, updated_at_ms, lease_generation
                        FROM pull_claim WHERE claim_id = ?;
                        """
                    )
                    defer { sqlite3_finalize(selected) }
                    bindText(selected, 1, identity.storageKey)
                    let lease = sqlite3_step(selected) == SQLITE_ROW ? decodePullClaim(selected) : nil
                    try execute(db, "COMMIT;")
                    return lease
                } catch {
                    _ = try? execute(db, "ROLLBACK;")
                    throw error
                }
            }
        } catch {
            return nil
        }
    }

    func completePullClaim(_ lease: ProviderWakeupPullClaimStore.ClaimLease, now: Date) {
        transitionPullClaim(lease, state: "completed", delete: false, now: now)
    }

    func releasePullClaim(_ lease: ProviderWakeupPullClaimStore.ClaimLease, now: Date) {
        transitionPullClaim(lease, state: "pending", delete: true, now: now)
    }

    func pullClaimState(
        identity: ProviderDeliveryAckFailureStore.DeliveryIdentity,
        now: Date
    ) -> ProviderWakeupPullClaimStore.ClaimState {
        do {
            return try withDatabase(write: false) { db in
                let statement = try prepare(
                    db,
                    "SELECT state, lease_until_ms, updated_at_ms FROM pull_claim WHERE claim_id = ?;"
                )
                defer { sqlite3_finalize(statement) }
                bindText(statement, 1, identity.storageKey)
                guard sqlite3_step(statement) == SQLITE_ROW,
                      let state = columnText(statement, 0)
                else { return .available }
                let nowMs = Self.epochMilliseconds(now)
                switch state {
                case "completed":
                    return nowMs - sqlite3_column_int64(statement, 2) < 600_000 ? .completed : .available
                case "leased":
                    return sqlite3_column_int64(statement, 1) > nowMs ? .claimed : .available
                default:
                    return .available
                }
            }
        } catch {
            return .available
        }
    }

    func diagnostics() -> (pendingIngress: Int, pendingAck: Int, quarantined: Int) {
        (try? withDatabase(write: false) { db in
            (
                try scalarCount(db, "SELECT COUNT(*) FROM ingress_entry WHERE apply_state IN ('pending','retry_wait','applying');"),
                try scalarCount(db, "SELECT COUNT(*) FROM ack_outbox WHERE state IN ('pending','retry_wait','leased','blocked_auth');"),
                try scalarCount(db, "SELECT COUNT(*) FROM ingress_entry WHERE apply_state = 'quarantined';")
            )
        }) ?? (0, 0, 0)
    }

    /// Host-app-only bounded maintenance. Terminal identities are retained for
    /// longer than Gateway's maximum provider TTL so an APNs redelivery still
    /// observes the completed state instead of recreating work. SQLite pages
    /// are intentionally left reusable instead of running VACUUM in a latency-
    /// sensitive foreground/background reconciliation window.
    func performMaintenance(
        now: Date = Date(),
        force: Bool = false,
        batchLimit: Int = 512
    ) -> MaintenanceResult {
        let nowMs = Self.epochMilliseconds(now)
        let minimumIntervalMs: Int64 = 6 * 60 * 60 * 1_000
        guard force || nowMs - lastMaintenanceAtMilliseconds >= minimumIntervalMs else {
            return .none
        }
        let terminalRetentionMs: Int64 = 35 * 24 * 60 * 60 * 1_000
        let completedClaimRetentionMs: Int64 = 24 * 60 * 60 * 1_000
        let terminalBefore = nowMs - terminalRetentionMs
        let completedClaimBefore = nowMs - completedClaimRetentionMs
        let limit = max(1, min(batchLimit, 2_048))

        do {
            let result = try withDatabase(write: true) { db in
                try execute(db, "BEGIN IMMEDIATE;")
                do {
                    let pullClaims = try deleteBounded(
                        db,
                        sql: """
                        DELETE FROM pull_claim WHERE claim_id IN (
                            SELECT claim_id FROM pull_claim
                            WHERE state = 'completed' AND updated_at_ms <= ?
                            ORDER BY updated_at_ms ASC LIMIT ?
                        );
                        """,
                        before: completedClaimBefore,
                        limit: limit
                    )
                    let ackRows = try deleteBounded(
                        db,
                        sql: """
                        DELETE FROM ack_outbox WHERE ack_id IN (
                            SELECT ack_id FROM ack_outbox
                            WHERE state IN ('completed','superseded') AND updated_at_ms <= ?
                            ORDER BY updated_at_ms ASC LIMIT ?
                        );
                        """,
                        before: terminalBefore,
                        limit: limit
                    )
                    let projectionRows = try deleteBounded(
                        db,
                        sql: """
                        DELETE FROM notification_projection_receipt WHERE projection_id IN (
                            SELECT projection_id FROM notification_projection_receipt
                            WHERE created_at_ms <= ?
                            ORDER BY created_at_ms ASC LIMIT ?
                        );
                        """,
                        before: terminalBefore,
                        limit: limit
                    )
                    let ingressRows = try deleteBounded(
                        db,
                        sql: """
                        DELETE FROM ingress_entry WHERE entry_id IN (
                            SELECT i.entry_id FROM ingress_entry i
                            WHERE i.apply_state IN ('applied','discarded')
                              AND COALESCE(i.canonical_applied_at_ms, i.created_at_ms) <= ?
                              AND NOT EXISTS (SELECT 1 FROM ack_outbox a WHERE a.entry_id = i.entry_id)
                              AND NOT EXISTS (SELECT 1 FROM pull_claim p WHERE p.resolved_entry_id = i.entry_id)
                            ORDER BY COALESCE(i.canonical_applied_at_ms, i.created_at_ms) ASC
                            LIMIT ?
                        );
                        """,
                        before: terminalBefore,
                        limit: limit
                    )
                    if pullClaims + ackRows + projectionRows + ingressRows > 0 {
                        try incrementGeneration(db)
                    }
                    try execute(db, "COMMIT;")
                    return MaintenanceResult(
                        ackRows: ackRows,
                        ingressRows: ingressRows,
                        pullClaimRows: pullClaims
                    )
                } catch {
                    _ = try? execute(db, "ROLLBACK;")
                    throw error
                }
            }
            cleanupExpiredRollbackShadows(nowMilliseconds: nowMs, batchLimit: limit)
            lastMaintenanceAtMilliseconds = nowMs
            return result
        } catch {
            // A transient extension/app-group lock must keep maintenance
            // retryable; correctness rows are never deleted on failure.
            return .none
        }
    }

    private func importLegacyInbox(at directory: URL) {
        for fileURL in legacyFiles(at: directory, extension: "inboxbin") {
            if rollbackShadowIsRegistered(kind: "inbox", fileName: fileURL.lastPathComponent) {
                continue
            }
            guard let data = try? Data(contentsOf: fileURL),
                  let record = try? decoder.decode(NotificationIngressInbox.StoredEntry.self, from: data),
                  record.schemaVersion <= 1
            else {
                quarantineLegacyFile(fileURL, reason: "invalid_inbox")
                continue
            }
            let plainPayload = record.payload.reduce(into: [String: Any]()) {
                $0[$1.key] = $1.value.value
            }
            let ackIdentity = ProviderDeliveryAckFailureStore.DeliveryIdentity.direct(from: plainPayload)
            let imported = enqueueIngress(
                codablePayload: record.payload,
                requestIdentifier: record.requestIdentifier,
                source: "legacy.\(record.source)",
                ackIdentity: ackIdentity,
                requiredEntryState: "durable"
            )
            if imported {
                try? fileManager.removeItem(at: fileURL)
            }
        }
    }

    private func persistEmergencyIngress(_ record: EmergencyIngressRecord) -> Bool {
        guard let databaseURL else { return false }
        let directory = databaseURL.deletingLastPathComponent()
            .appendingPathComponent(Self.emergencyDirectoryName, isDirectory: true)
        let stateFingerprint = Self.fingerprint(Data(record.requiredEntryState.utf8))
        let destination = directory.appendingPathComponent(
            "\(record.entryID).\(record.payloadFingerprint).\(stateFingerprint).\(Self.emergencyFileExtension)",
            isDirectory: false
        )
        let temporary = directory.appendingPathComponent(
            ".\(UUID().uuidString.lowercased()).tmp",
            isDirectory: false
        )
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            #if os(iOS) || os(watchOS)
            try? fileManager.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: directory.path
            )
            #endif
            if fileManager.fileExists(atPath: destination.path),
               emergencyIngressFileMatches(destination, expected: record)
            {
                return durabilitySynchronizer(destination)
                    && durabilitySynchronizer(directory)
                    && durabilitySynchronizer(directory.deletingLastPathComponent())
            }
            try encoder.encode(record).write(to: temporary, options: .atomic)
            guard durabilitySynchronizer(temporary) else { throw JournalError.unavailable }
            let renamed = temporary.path.withCString { source in
                destination.path.withCString { target in
                    Darwin.rename(source, target) == 0
                }
            }
            guard renamed else { throw JournalError.unavailable }
            guard durabilitySynchronizer(destination),
                  durabilitySynchronizer(directory),
                  durabilitySynchronizer(directory.deletingLastPathComponent())
            else { throw JournalError.unavailable }
            try? (destination as NSURL).setResourceValue(true, forKey: .isExcludedFromBackupKey)
            return true
        } catch {
            try? fileManager.removeItem(at: temporary)
            return false
        }
    }

    private func emergencyIngressFileMatches(
        _ fileURL: URL,
        expected: EmergencyIngressRecord
    ) -> Bool {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? decoder.decode(EmergencyIngressRecord.self, from: data),
              decoded.schemaVersion == expected.schemaVersion,
              decoded.entryID == expected.entryID,
              decoded.payloadFingerprint == expected.payloadFingerprint,
              decoded.requiredEntryState == expected.requiredEntryState,
              decoded.ackIdentity == expected.ackIdentity,
              let payload = try? encoder.encode(decoded.codablePayload),
              Self.fingerprint(payload) == expected.payloadFingerprint
        else { return false }
        return true
    }

    private func importEmergencyIngress() {
        guard let databaseURL else { return }
        let directory = databaseURL.deletingLastPathComponent()
            .appendingPathComponent(Self.emergencyDirectoryName, isDirectory: true)
        let files = ((try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? [])
            .filter { $0.pathExtension == Self.emergencyFileExtension }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .prefix(256)

        for fileURL in files {
            guard let data = try? Data(contentsOf: fileURL),
                  let record = try? decoder.decode(EmergencyIngressRecord.self, from: data),
                  record.schemaVersion <= Self.schemaVersion,
                  let payload = try? encoder.encode(record.codablePayload),
                  Self.fingerprint(payload) == record.payloadFingerprint
            else {
                quarantineEmergencyFile(fileURL, reason: "malformed")
                continue
            }
            let deliveryID = normalized(record.codablePayload["delivery_id"]?.value as? String)
            let expectedEntryID = Self.entryID(
                ackIdentity: record.ackIdentity,
                deliveryID: deliveryID,
                payloadBaseURL: normalized(record.codablePayload["base_url"]?.value as? String),
                payloadDeviceKey: normalized(record.codablePayload["provider_device_key"]?.value as? String),
                payloadFingerprint: record.payloadFingerprint
            )
            guard expectedEntryID == record.entryID else {
                quarantineEmergencyFile(fileURL, reason: "identity_mismatch")
                continue
            }
            do {
                let result = try persistIngressWithContentionRetry(
                    record,
                    payload: payload,
                    deliveryID: deliveryID,
                    messageID: normalized(record.codablePayload["message_id"]?.value as? String),
                    entityType: normalized(record.codablePayload["entity_type"]?.value as? String),
                    entityID: normalized(record.codablePayload["entity_id"]?.value as? String)
                )
                if result.accepted {
                    try? fileManager.removeItem(at: fileURL)
                } else {
                    quarantineEmergencyFile(fileURL, reason: "identity_conflict")
                }
            } catch {
                // Keep the atomic sidecar intact for the next process/restart.
                return
            }
        }
    }

    private func quarantineEmergencyFile(_ fileURL: URL, reason: String) {
        guard let databaseURL else { return }
        let directory = databaseURL.deletingLastPathComponent()
            .appendingPathComponent("EmergencyQuarantine", isDirectory: true)
        let destination = directory.appendingPathComponent(
            "\(fileURL.lastPathComponent).\(reason).quarantine",
            isDirectory: false
        )
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: fileURL)
            } else {
                try fileManager.moveItem(at: fileURL, to: destination)
            }
        } catch {
            // Preserve source when quarantine itself is uncertain.
        }
    }

    private static func fullSynchronize(_ url: URL) -> Bool {
        let descriptor = url.path.withCString { open($0, O_RDONLY) }
        guard descriptor >= 0 else { return false }
        defer { _ = Darwin.close(descriptor) }
        return Darwin.fcntl(descriptor, F_FULLFSYNC) == 0
    }

    private func importLegacyAckMarkers(at directory: URL) {
        for fileURL in legacyFiles(at: directory, extension: "ackbin") {
            if rollbackShadowIsRegistered(kind: "ack", fileName: fileURL.lastPathComponent) {
                continue
            }
            guard let data = try? Data(contentsOf: fileURL),
                  let marker = try? decoder.decode(
                      ProviderDeliveryAckFailureStore.StoredMarker.self,
                      from: data
                  ),
                  marker.schemaVersion <= 3,
                  let rawBaseURL = marker.baseURLString,
                  let baseURL = URLSanitizer.validatedServerURL(from: rawBaseURL),
                  let deviceKey = normalized(marker.deviceKey),
                  let contract = marker.ackContract,
                  let identity = ProviderDeliveryAckFailureStore.DeliveryIdentity(
                      deliveryId: marker.deliveryId,
                      baseURL: baseURL,
                      deviceKey: deviceKey,
                      ackContract: contract
                  )
            else {
                quarantineLegacyFile(fileURL, reason: "invalid_ack")
                continue
            }
            switch marker.stage {
            case .preparing:
                // Preparing alone was never proof of a durable payload. A
                // matching imported inbox record will atomically create its ACK.
                try? fileManager.removeItem(at: fileURL)
            case .inboxDurable, .ackInFlight:
                let retryAfter = [marker.retryAfterEpochMs, marker.leaseUntilEpochMs]
                    .compactMap { $0 }
                    .max()
                    .map { Date(timeIntervalSince1970: Double($0) / 1_000) }
                if markAck(
                    identity: identity,
                    stage: .inboxDurable,
                    source: "legacy.\(marker.source)",
                    retryAfter: retryAfter
                ) {
                    try? fileManager.removeItem(at: fileURL)
                }
            case .completed:
                if markAck(
                    identity: identity,
                    stage: .inboxDurable,
                    source: "legacy.completed"
                ) {
                    markAckCompleted(identity: identity)
                    try? fileManager.removeItem(at: fileURL)
                } else if ackIsTerminal(identity: identity) {
                    try? fileManager.removeItem(at: fileURL)
                }
            }
        }
    }

    private func importLegacyPullClaims(at directory: URL) {
        for fileURL in legacyFiles(at: directory, extension: "pullclaim") {
            guard let data = try? Data(contentsOf: fileURL),
                  let claim = try? decoder.decode(
                      ProviderWakeupPullClaimStore.StoredClaim.self,
                      from: data
                  ),
                  claim.schemaVersion <= 2,
                  let rawBaseURL = claim.baseURLString,
                  let baseURL = URLSanitizer.validatedServerURL(from: rawBaseURL),
                  let deviceKey = normalized(claim.deviceKey),
                  let contract = claim.ackContract,
                  let identity = ProviderDeliveryAckFailureStore.DeliveryIdentity(
                      deliveryId: claim.deliveryId,
                      baseURL: baseURL,
                      deviceKey: deviceKey,
                      ackContract: contract
                  )
            else {
                quarantineLegacyFile(fileURL, reason: "invalid_pull_claim")
                continue
            }
            if case .completed = claim.state,
               !importCompletedPullClaim(identity: identity, updatedAt: claim.updatedAtEpochMs)
            {
                continue
            }
            // Active legacy leases are deliberately released. The owning old
            // process can disappear during upgrade; idempotent pull is safer
            // than preserving an unfenced cross-version lease.
            try? fileManager.removeItem(at: fileURL)
        }
    }

    private func importCompletedPullClaim(
        identity: ProviderDeliveryAckFailureStore.DeliveryIdentity,
        updatedAt: Int64
    ) -> Bool {
        let now = Self.epochMilliseconds(Date())
        do {
            try withDatabase(write: true) { db in
                let statement = try prepare(
                    db,
                    """
                    INSERT INTO pull_claim (
                        claim_id, delivery_id, base_url, device_key, pull_contract, state,
                        lease_generation, attempts, next_attempt_at_ms, created_at_ms, updated_at_ms
                    ) VALUES (?, ?, ?, ?, ?, 'completed', 0, 0, ?, ?, ?)
                    ON CONFLICT(base_url, device_key, delivery_id, pull_contract) DO UPDATE SET
                        state = CASE WHEN pull_claim.state = 'leased' THEN pull_claim.state ELSE 'completed' END,
                        updated_at_ms = CASE WHEN pull_claim.state = 'leased' THEN pull_claim.updated_at_ms ELSE excluded.updated_at_ms END;
                    """
                )
                defer { sqlite3_finalize(statement) }
                bindText(statement, 1, identity.storageKey)
                bindText(statement, 2, identity.deliveryId)
                bindText(statement, 3, identity.baseURLString)
                bindText(statement, 4, identity.deviceKey)
                bindText(statement, 5, identity.ackContract.rawValue)
                sqlite3_bind_int64(statement, 6, now)
                sqlite3_bind_int64(statement, 7, min(updatedAt, now))
                sqlite3_bind_int64(statement, 8, min(updatedAt, now))
                try stepDone(db, statement)
            }
            return true
        } catch {
            return false
        }
    }

    private func ackIsTerminal(
        identity: ProviderDeliveryAckFailureStore.DeliveryIdentity
    ) -> Bool {
        (try? withDatabase(write: false) { db in
            guard let state = try ackState(db, ackID: identity.storageKey) else { return false }
            return state == "completed" || state == "superseded"
        }) ?? false
    }

    private func legacyFiles(at directory: URL, extension fileExtension: String) -> [URL] {
        ((try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? [])
            .filter { $0.pathExtension == fileExtension }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    // MARK: - Bounded N-1 rollback shadows

    /// For one 35-day migration window, mirror the N writer's durable handoff
    /// into the exact file formats understood by the N-1 reader. SQLite remains
    /// authoritative; registry rows stop this release from importing/deleting
    /// its own rollback shadows.
    private func persistLegacyRollbackShadows(_ record: EmergencyIngressRecord) {
        let inboxMirrored = persistLegacyInboxShadow(record)
        if inboxMirrored,
           let identity = record.ackIdentity,
           record.requiredEntryState == "durable"
        {
            persistLegacyAckShadow(
                identity: identity,
                stage: .inboxDurable,
                attempts: 0,
                retryAfter: nil,
                source: "rollback.\(record.source)"
            )
        }
    }

    private func persistLegacyInboxShadow(_ emergency: EmergencyIngressRecord) -> Bool {
        guard let directory = legacyApplicationSupportDirectory()?.appendingPathComponent(
            "notification-ingress-inbox",
            isDirectory: true
        ) else { return false }
        // N-1 accepts every decodable `.inboxbin`; it does not require its old
        // delivery-only filename. Use the N full identity so different
        // Gateway/device/contract owners never alias during rollback.
        let legacyEntryID = "rollback-\(emergency.entryID)-\(emergency.payloadFingerprint)"
        let fileName = "\(legacyEntryID).inboxbin"
        let legacy = NotificationIngressInbox.StoredEntry(
            schemaVersion: 1,
            entryId: legacyEntryID,
            createdAtEpochMs: emergency.createdAtEpochMs,
            source: "rollback.\(emergency.source)",
            requestIdentifier: emergency.requestIdentifier,
            payload: emergency.codablePayload
        )
        guard let data = try? encoder.encode(legacy) else { return false }
        return persistRollbackShadowFile(
            data,
            directory: directory,
            kind: "inbox",
            fileName: fileName,
            identityKey: emergency.entryID
        )
    }

    private func persistLegacyAckShadow(
        identity: ProviderDeliveryAckFailureStore.DeliveryIdentity,
        stage: ProviderDeliveryAckFailureStore.Stage,
        attempts: Int,
        retryAfter: Date?,
        source: String
    ) {
        guard let directory = legacyApplicationSupportDirectory()?.appendingPathComponent(
            "provider-delivery-ack-failures",
            isDirectory: true
        ) else { return }
        let now = Self.epochMilliseconds(Date())
        let fileName = "\(identity.storageKey).ackbin"
        let marker = ProviderDeliveryAckFailureStore.StoredMarker(
            schemaVersion: 3,
            deliveryId: identity.deliveryId,
            baseURLString: identity.baseURLString,
            deviceKey: identity.deviceKey,
            ackContract: identity.ackContract,
            attemptCount: max(0, attempts),
            stage: stage,
            owner: nil,
            leaseUntilEpochMs: nil,
            retryAfterEpochMs: retryAfter.map(Self.epochMilliseconds),
            createdAtEpochMs: now,
            updatedAtEpochMs: now,
            source: source,
            leaseGeneration: nil
        )
        guard let data = try? encoder.encode(marker) else { return }
        persistRollbackShadowFile(
            data,
            directory: directory,
            kind: "ack",
            fileName: fileName,
            identityKey: identity.storageKey,
            allowSameIdentityReplacement: true
        )
    }

    @discardableResult
    private func persistRollbackShadowFile(
        _ data: Data,
        directory: URL,
        kind: String,
        fileName: String,
        identityKey: String,
        allowSameIdentityReplacement: Bool = false
    ) -> Bool {
        let destination = directory.appendingPathComponent(fileName, isDirectory: false)
        if fileManager.fileExists(atPath: destination.path),
           !allowSameIdentityReplacement,
           !rollbackShadowIsRegistered(kind: kind, fileName: fileName, identityKey: identityKey)
        {
            // N-1 used delivery-only inbox names. Never overwrite an unrelated
            // legacy writer or another Gateway's colliding delivery identity.
            return false
        }
        guard registerRollbackShadow(kind: kind, fileName: fileName, identityKey: identityKey) else {
            return false
        }
        guard rollbackShadowWriteAllowed(destination) else {
            unregisterRollbackShadow(kind: kind, fileName: fileName, identityKey: identityKey)
            recordRollbackShadowFailure(kind: kind, reason: "injected_write_failure")
            return false
        }
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: destination, options: .atomic)
            if let handle = try? FileHandle(forWritingTo: destination) {
                try? handle.synchronize()
                try? handle.close()
            }
            guard durabilitySynchronizer(directory) else {
                recordRollbackShadowFailure(kind: kind, reason: "directory_sync_failed")
                return false
            }
            return true
        } catch {
            unregisterRollbackShadow(kind: kind, fileName: fileName, identityKey: identityKey)
            recordRollbackShadowFailure(kind: kind, reason: "filesystem_write_failed")
            return false
        }
    }

    private func recordRollbackShadowFailure(kind: String, reason: String) {
        let now = Self.epochMilliseconds(Date())
        try? withDatabase(write: true) { db in
            let statement = try prepare(
                db,
                """
                INSERT INTO rollback_shadow_health(
                    singleton_id, failure_count, last_kind, last_reason, last_failure_at_ms
                ) VALUES (1, 1, ?, ?, ?)
                ON CONFLICT(singleton_id) DO UPDATE SET
                    failure_count = rollback_shadow_health.failure_count + 1,
                    last_kind = excluded.last_kind,
                    last_reason = excluded.last_reason,
                    last_failure_at_ms = excluded.last_failure_at_ms;
                """
            )
            defer { sqlite3_finalize(statement) }
            bindText(statement, 1, kind)
            bindText(statement, 2, reason)
            sqlite3_bind_int64(statement, 3, now)
            try stepDone(db, statement)
        }
    }

    private func registerRollbackShadow(
        kind: String,
        fileName: String,
        identityKey: String
    ) -> Bool {
        let now = Self.epochMilliseconds(Date())
        return (try? withDatabase(write: true) { db in
            guard let started = try rollbackShadowStartedAt(db) else { return false }
            let expiryResult = started.addingReportingOverflow(
                Self.legacyRollbackShadowRetentionMilliseconds
            )
            let expiresAt = expiryResult.overflow ? Int64.max : expiryResult.partialValue
            guard now <= expiresAt else { return false }
            let existing = try prepare(
                db,
                "SELECT identity_key FROM rollback_shadow WHERE kind = ? AND file_name = ?;"
            )
            defer { sqlite3_finalize(existing) }
            bindText(existing, 1, kind)
            bindText(existing, 2, fileName)
            if sqlite3_step(existing) == SQLITE_ROW,
               columnText(existing, 0) != identityKey
            {
                return false
            }
            let statement = try prepare(
                db,
                """
                INSERT INTO rollback_shadow(kind, file_name, identity_key, created_at_ms, expires_at_ms)
                VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(kind, file_name) DO UPDATE SET
                    expires_at_ms = excluded.expires_at_ms
                WHERE rollback_shadow.identity_key = excluded.identity_key;
                """
            )
            defer { sqlite3_finalize(statement) }
            bindText(statement, 1, kind)
            bindText(statement, 2, fileName)
            bindText(statement, 3, identityKey)
            sqlite3_bind_int64(statement, 4, now)
            sqlite3_bind_int64(
                statement,
                5,
                expiresAt
            )
            try stepDone(db, statement)
            return true
        }) ?? false
    }

    private func rollbackShadowStartedAt(_ db: OpaquePointer) throws -> Int64? {
        let statement = try prepare(
            db,
            "SELECT value FROM ingress_meta WHERE key = 'legacy_rollback_shadow_started_at_ms';"
        )
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW,
              let raw = columnText(statement, 0)
        else { return nil }
        return Int64(raw)
    }

    private func rollbackShadowIsRegistered(
        kind: String,
        fileName: String,
        identityKey: String? = nil
    ) -> Bool {
        (try? withDatabase(write: false) { db in
            let statement = try prepare(
                db,
                "SELECT identity_key FROM rollback_shadow WHERE kind = ? AND file_name = ?;"
            )
            defer { sqlite3_finalize(statement) }
            bindText(statement, 1, kind)
            bindText(statement, 2, fileName)
            guard sqlite3_step(statement) == SQLITE_ROW else { return false }
            return identityKey == nil || columnText(statement, 0) == identityKey
        }) ?? false
    }

    private func unregisterRollbackShadow(kind: String, fileName: String, identityKey: String) {
        try? withDatabase(write: true) { db in
            let statement = try prepare(
                db,
                "DELETE FROM rollback_shadow WHERE kind = ? AND file_name = ? AND identity_key = ?;"
            )
            defer { sqlite3_finalize(statement) }
            bindText(statement, 1, kind)
            bindText(statement, 2, fileName)
            bindText(statement, 3, identityKey)
            try stepDone(db, statement)
        }
    }

    private func legacyApplicationSupportDirectory() -> URL? {
        AppConstants.appGroupContainerURL(
            fileManager: fileManager,
            identifier: appGroupIdentifier
        )?
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
    }

    private func cleanupExpiredRollbackShadows(nowMilliseconds: Int64, batchLimit: Int) {
        guard let applicationSupport = legacyApplicationSupportDirectory() else { return }
        let expired: [(String, String)] = (try? withDatabase(write: false) { db in
            let statement = try prepare(
                db,
                "SELECT kind, file_name FROM rollback_shadow WHERE expires_at_ms <= ? ORDER BY expires_at_ms ASC, kind ASC, file_name ASC LIMIT ?;"
            )
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_int64(statement, 1, nowMilliseconds)
            sqlite3_bind_int64(statement, 2, Int64(max(1, batchLimit)))
            var rows: [(String, String)] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let kind = columnText(statement, 0),
                      let fileName = columnText(statement, 1)
                else { continue }
                rows.append((kind, fileName))
            }
            return rows
        }) ?? []

        for (kind, fileName) in expired {
            let directoryName = kind == "inbox"
                ? "notification-ingress-inbox"
                : "provider-delivery-ack-failures"
            let fileURL = applicationSupport
                .appendingPathComponent(directoryName, isDirectory: true)
                .appendingPathComponent(fileName, isDirectory: false)
            if fileManager.fileExists(atPath: fileURL.path) {
                try? fileManager.removeItem(at: fileURL)
            }
            guard !fileManager.fileExists(atPath: fileURL.path) else { continue }
            try? withDatabase(write: true) { db in
                let statement = try prepare(
                    db,
                    "DELETE FROM rollback_shadow WHERE kind = ? AND file_name = ? AND expires_at_ms <= ?;"
                )
                defer { sqlite3_finalize(statement) }
                bindText(statement, 1, kind)
                bindText(statement, 2, fileName)
                sqlite3_bind_int64(statement, 3, nowMilliseconds)
                try stepDone(db, statement)
            }
        }
    }


    private func quarantineLegacyFile(_ fileURL: URL, reason: String) {
        guard let databaseURL else { return }
        let directory = databaseURL.deletingLastPathComponent()
            .appendingPathComponent("LegacyQuarantine", isDirectory: true)
        let boundedReason = reason.replacingOccurrences(of: "/", with: "_")
        let destination = directory.appendingPathComponent(
            "\(fileURL.lastPathComponent).\(boundedReason).quarantine",
            isDirectory: false
        )
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: fileURL)
            } else {
                try fileManager.moveItem(at: fileURL, to: destination)
            }
        } catch {
            // Leave the source in place so a later foreground reconciliation
            // can retry the quarantine operation. Never delete on uncertainty.
        }
    }

    private func markAckCompleted(
        identity: ProviderDeliveryAckFailureStore.DeliveryIdentity,
        owner: String?,
        generation: Int64?
    ) {
        let now = Self.epochMilliseconds(Date())
        let changed = (try? withDatabase(write: true) { db in
            var sql = """
                UPDATE ack_outbox SET state = 'completed', completed_at_ms = ?,
                    lease_owner = NULL, lease_until_ms = NULL, updated_at_ms = ?
                WHERE ack_id = ?
                """
            if owner != nil, generation != nil {
                sql += " AND state = 'leased' AND lease_owner = ? AND lease_generation = ?"
            }
            sql += ";"
            let statement = try prepare(db, sql)
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_int64(statement, 1, now)
            sqlite3_bind_int64(statement, 2, now)
            bindText(statement, 3, identity.storageKey)
            if let owner, let generation {
                bindText(statement, 4, owner)
                sqlite3_bind_int64(statement, 5, generation)
            }
            try stepDone(db, statement)
            return sqlite3_changes(db) == 1
        }) ?? false
        if changed {
            persistLegacyAckShadow(
                identity: identity,
                stage: .completed,
                attempts: 0,
                retryAfter: nil,
                source: "rollback.completed"
            )
        }
    }

    private func transitionPullClaim(
        _ lease: ProviderWakeupPullClaimStore.ClaimLease,
        state: String,
        delete: Bool,
        now: Date
    ) {
        guard let identity = lease.identity,
              let owner = lease.record.owner,
              let generation = lease.record.leaseGeneration
        else { return }
        try? withDatabase(write: true) { db in
            let sql = delete
                ? "DELETE FROM pull_claim WHERE claim_id = ? AND state = 'leased' AND lease_owner = ? AND lease_generation = ?;"
                : "UPDATE pull_claim SET state = ?, lease_owner = NULL, lease_until_ms = NULL, updated_at_ms = ? WHERE claim_id = ? AND state = 'leased' AND lease_owner = ? AND lease_generation = ?;"
            let statement = try prepare(db, sql)
            defer { sqlite3_finalize(statement) }
            if delete {
                bindText(statement, 1, identity.storageKey)
                bindText(statement, 2, owner)
                sqlite3_bind_int64(statement, 3, generation)
            } else {
                bindText(statement, 1, state)
                sqlite3_bind_int64(statement, 2, Self.epochMilliseconds(now))
                bindText(statement, 3, identity.storageKey)
                bindText(statement, 4, owner)
                sqlite3_bind_int64(statement, 5, generation)
            }
            try stepDone(db, statement)
        }
    }

    private func decodeAckMarker(
        _ statement: OpaquePointer
    ) -> ProviderDeliveryAckFailureStore.PendingMarker? {
        guard let deliveryID = columnText(statement, 0),
              let baseURL = columnText(statement, 1),
              let deviceKey = columnText(statement, 2),
              let contractRaw = columnText(statement, 3),
              let contract = ProviderDeliveryAckFailureStore.AckContract(rawValue: contractRaw),
              let state = columnText(statement, 5)
        else { return nil }
        let stage: ProviderDeliveryAckFailureStore.Stage = state == "leased" ? .ackInFlight : .inboxDurable
        let record = ProviderDeliveryAckFailureStore.StoredMarker(
            schemaVersion: 4,
            deliveryId: deliveryID,
            baseURLString: baseURL,
            deviceKey: deviceKey,
            ackContract: contract,
            attemptCount: Int(sqlite3_column_int(statement, 4)),
            stage: stage,
            owner: columnText(statement, 6),
            leaseUntilEpochMs: columnOptionalInt64(statement, 7),
            retryAfterEpochMs: columnOptionalInt64(statement, 8),
            createdAtEpochMs: sqlite3_column_int64(statement, 9),
            updatedAtEpochMs: sqlite3_column_int64(statement, 10),
            source: columnText(statement, 11) ?? "durable_ingress_v2",
            leaseGeneration: sqlite3_column_int64(statement, 12)
        )
        let identity = ProviderDeliveryAckFailureStore.DeliveryIdentity(
            deliveryId: deliveryID,
            baseURL: URL(string: baseURL)!,
            deviceKey: deviceKey,
            ackContract: contract
        )
        return ProviderDeliveryAckFailureStore.PendingMarker(
            fileName: identity?.storageKey ?? deliveryID,
            fileURL: databaseURL ?? URL(fileURLWithPath: "/dev/null"),
            record: record
        )
    }

    private func decodePullClaim(
        _ statement: OpaquePointer
    ) -> ProviderWakeupPullClaimStore.ClaimLease? {
        guard let deliveryID = columnText(statement, 0),
              let baseURL = columnText(statement, 1),
              let deviceKey = columnText(statement, 2),
              let contractRaw = columnText(statement, 3),
              let contract = ProviderDeliveryAckFailureStore.AckContract(rawValue: contractRaw),
              let stateRaw = columnText(statement, 4)
        else { return nil }
        let record = ProviderWakeupPullClaimStore.StoredClaim(
            schemaVersion: 3,
            deliveryId: deliveryID,
            baseURLString: baseURL,
            deviceKey: deviceKey,
            ackContract: contract,
            state: stateRaw == "completed" ? .completed : .claimed,
            owner: columnText(statement, 5),
            leaseUntilEpochMs: columnOptionalInt64(statement, 6),
            createdAtEpochMs: sqlite3_column_int64(statement, 7),
            updatedAtEpochMs: sqlite3_column_int64(statement, 8),
            leaseGeneration: sqlite3_column_int64(statement, 9)
        )
        let identity = ProviderDeliveryAckFailureStore.DeliveryIdentity(
            deliveryId: deliveryID,
            baseURL: URL(string: baseURL)!,
            deviceKey: deviceKey,
            ackContract: contract
        )
        return ProviderWakeupPullClaimStore.ClaimLease(
            fileName: identity?.storageKey ?? deliveryID,
            fileURL: databaseURL ?? URL(fileURLWithPath: "/dev/null"),
            record: record
        )
    }

    private func ensureAckAnchor(
        _ db: OpaquePointer,
        entryID: String,
        identity: ProviderDeliveryAckFailureStore.DeliveryIdentity,
        now: Int64
    ) throws {
        let statement = try prepare(
            db,
            """
            INSERT INTO ingress_entry (
                entry_id, schema_version, source, source_base_url, source_device_key,
                resolution_state, delivery_id, validation_state, apply_state,
                lease_generation, apply_attempts, next_apply_at_ms, created_at_ms,
                discard_reason, payload_fingerprint
            ) VALUES (?, ?, 'ack_import', ?, ?, ?, ?, 'rejected_deterministic',
                      'discarded', 0, 0, ?, ?, 'legacy_ack_import', ?)
            ON CONFLICT(entry_id) DO NOTHING;
            """
        )
        defer { sqlite3_finalize(statement) }
        bindText(statement, 1, entryID)
        sqlite3_bind_int(statement, 2, Int32(Self.schemaVersion))
        bindText(statement, 3, identity.baseURLString)
        bindText(statement, 4, identity.deviceKey)
        bindText(statement, 5, identity.ackContract == .v2Batch ? "pulled" : "direct")
        bindText(statement, 6, identity.deliveryId)
        sqlite3_bind_int64(statement, 7, now)
        sqlite3_bind_int64(statement, 8, now)
        bindText(statement, 9, Self.fingerprint(Data(identity.deliveryId.utf8)))
        try stepDone(db, statement)
    }

    private func upsertAck(
        _ db: OpaquePointer,
        identity: ProviderDeliveryAckFailureStore.DeliveryIdentity,
        entryID: String,
        requiredEntryState: String,
        source: String,
        now: Int64,
        nextAttemptAt: Int64? = nil
    ) throws {
        let statement = try prepare(
            db,
            """
            INSERT INTO ack_outbox (
                ack_id, entry_id, delivery_id, base_url, device_key, ack_contract,
                required_entry_state, state, lease_generation, attempts,
                next_attempt_at_ms, created_at_ms, updated_at_ms, source
            ) VALUES (?, ?, ?, ?, ?, ?, ?, 'pending', 0, 0, ?, ?, ?, ?)
            ON CONFLICT(base_url, device_key, delivery_id, ack_contract) DO UPDATE SET
                entry_id = excluded.entry_id,
                required_entry_state = CASE
                    WHEN excluded.required_entry_state = 'terminal_local' THEN 'terminal_local'
                    ELSE ack_outbox.required_entry_state
                END,
                next_attempt_at_ms = MIN(ack_outbox.next_attempt_at_ms, excluded.next_attempt_at_ms),
                source = excluded.source,
                updated_at_ms = excluded.updated_at_ms
            WHERE ack_outbox.state NOT IN ('completed','leased');
            """
        )
        defer { sqlite3_finalize(statement) }
        bindText(statement, 1, identity.storageKey)
        bindText(statement, 2, entryID)
        bindText(statement, 3, identity.deliveryId)
        bindText(statement, 4, identity.baseURLString)
        bindText(statement, 5, identity.deviceKey)
        bindText(statement, 6, identity.ackContract.rawValue)
        bindText(statement, 7, requiredEntryState)
        sqlite3_bind_int64(statement, 8, nextAttemptAt ?? now)
        sqlite3_bind_int64(statement, 9, now)
        sqlite3_bind_int64(statement, 10, now)
        bindText(statement, 11, normalized(source) ?? "unknown")
        try stepDone(db, statement)

        if identity.ackContract == .v2Batch {
            let supersede = try prepare(
                db,
                """
                UPDATE ack_outbox SET state = 'superseded', updated_at_ms = ?
                WHERE base_url = ? AND device_key = ? AND delivery_id = ?
                  AND ack_contract = 'legacySingle' AND state IN ('pending','retry_wait');
                """
            )
            defer { sqlite3_finalize(supersede) }
            sqlite3_bind_int64(supersede, 1, now)
            bindText(supersede, 2, identity.baseURLString)
            bindText(supersede, 3, identity.deviceKey)
            bindText(supersede, 4, identity.deliveryId)
            try stepDone(db, supersede)
        }
    }

    private func incrementGeneration(_ db: OpaquePointer) throws {
        try execute(
            db,
            """
            INSERT INTO ingress_meta(key, value) VALUES ('generation', '1')
            ON CONFLICT(key) DO UPDATE SET value = CAST(CAST(value AS INTEGER) + 1 AS TEXT);
            """
        )
    }

    private func withDatabase<T>(write: Bool, _ body: (OpaquePointer) throws -> T) throws -> T {
        guard let databaseURL else { throw JournalError.unavailable }
        if write {
            let directory = databaseURL.deletingLastPathComponent()
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try? (databaseURL as NSURL).setResourceValue(true, forKey: .isExcludedFromBackupKey)
            #if os(iOS) || os(watchOS)
            try? fileManager.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: directory.path
            )
            #endif
        }
        var database: OpaquePointer?
        let flags = write
            ? SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
            : SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
        let result = sqlite3_open_v2(databaseURL.path, &database, flags, nil)
        guard result == SQLITE_OK, let database else {
            if let database { sqlite3_close(database) }
            throw JournalError.unavailable
        }
        defer { sqlite3_close(database) }
        _ = sqlite3_busy_timeout(database, busyTimeoutMilliseconds)
        if write {
            try configureAndMigrate(database)
        } else {
            try verifySchema(database)
        }
        return try body(database)
    }

    private func configureAndMigrate(_ db: OpaquePointer) throws {
        // A newer writer owns its schema. Reject it before journal-mode changes,
        // DDL, or index migration so this binary can only append an emergency
        // sidecar and leave the future database untouched.
        try rejectUnsupportedSchemaIfPresent(db)
        try execute(db, "PRAGMA journal_mode = DELETE;")
        try execute(db, "PRAGMA synchronous = EXTRA;")
        try execute(db, "PRAGMA fullfsync = ON;")
        try execute(db, "PRAGMA foreign_keys = ON;")
        try execute(db, "PRAGMA temp_store = MEMORY;")
        guard try pragmaText(db, name: "journal_mode")?.lowercased() == "delete",
              try pragmaInt(db, name: "synchronous") == 3,
              try pragmaInt(db, name: "fullfsync") == 1
        else {
            throw JournalError.sqlite("required durability pragmas were not applied")
        }
        try execute(
            db,
            """
            CREATE TABLE IF NOT EXISTS ingress_meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS ingress_entry (
                entry_id TEXT PRIMARY KEY,
                schema_version INTEGER NOT NULL,
                source TEXT NOT NULL,
                source_base_url TEXT,
                source_device_key TEXT,
                resolution_state TEXT NOT NULL,
                request_identifier TEXT,
                delivery_id TEXT,
                message_id TEXT,
                entity_type TEXT,
                entity_id TEXT,
                payload_plist BLOB,
                validation_state TEXT NOT NULL,
                apply_state TEXT NOT NULL DEFAULT 'pending',
                lease_owner TEXT,
                lease_until_ms INTEGER,
                lease_generation INTEGER NOT NULL DEFAULT 0,
                apply_attempts INTEGER NOT NULL DEFAULT 0,
                next_apply_at_ms INTEGER NOT NULL,
                created_at_ms INTEGER NOT NULL,
                canonical_applied_at_ms INTEGER,
                quarantine_reason TEXT,
                discard_reason TEXT,
                payload_fingerprint TEXT,
                expires_at_ms INTEGER
            );
            CREATE INDEX IF NOT EXISTS ingress_due_idx
                ON ingress_entry(apply_state, next_apply_at_ms, created_at_ms);
            CREATE TABLE IF NOT EXISTS notification_projection_receipt (
                projection_id TEXT PRIMARY KEY,
                created_at_ms INTEGER NOT NULL
            );
            CREATE INDEX IF NOT EXISTS notification_projection_receipt_age_idx
                ON notification_projection_receipt(created_at_ms);
            CREATE TABLE IF NOT EXISTS ack_outbox (
                ack_id TEXT PRIMARY KEY,
                entry_id TEXT NOT NULL REFERENCES ingress_entry(entry_id),
                delivery_id TEXT NOT NULL,
                base_url TEXT NOT NULL,
                device_key TEXT NOT NULL,
                ack_contract TEXT NOT NULL,
                required_entry_state TEXT NOT NULL,
                state TEXT NOT NULL DEFAULT 'pending',
                lease_owner TEXT,
                lease_until_ms INTEGER,
                lease_generation INTEGER NOT NULL DEFAULT 0,
                attempts INTEGER NOT NULL DEFAULT 0,
                next_attempt_at_ms INTEGER NOT NULL,
                last_error_code TEXT,
                completed_at_ms INTEGER,
                created_at_ms INTEGER NOT NULL,
                updated_at_ms INTEGER NOT NULL,
                source TEXT NOT NULL,
                UNIQUE(base_url, device_key, delivery_id, ack_contract)
            );
            CREATE INDEX IF NOT EXISTS ack_due_idx
                ON ack_outbox(state, next_attempt_at_ms, lease_until_ms);
            CREATE TABLE IF NOT EXISTS pull_claim (
                claim_id TEXT PRIMARY KEY,
                delivery_id TEXT NOT NULL,
                base_url TEXT NOT NULL,
                device_key TEXT NOT NULL,
                pull_contract TEXT NOT NULL,
                state TEXT NOT NULL,
                lease_owner TEXT,
                lease_until_ms INTEGER,
                lease_generation INTEGER NOT NULL DEFAULT 0,
                attempts INTEGER NOT NULL DEFAULT 0,
                next_attempt_at_ms INTEGER NOT NULL,
                resolved_entry_id TEXT REFERENCES ingress_entry(entry_id),
                last_error_code TEXT,
                created_at_ms INTEGER NOT NULL,
                updated_at_ms INTEGER NOT NULL,
                UNIQUE(base_url, device_key, delivery_id, pull_contract)
            );
            CREATE TABLE IF NOT EXISTS rollback_shadow (
                kind TEXT NOT NULL,
                file_name TEXT NOT NULL,
                identity_key TEXT NOT NULL,
                created_at_ms INTEGER NOT NULL,
                expires_at_ms INTEGER NOT NULL,
                PRIMARY KEY(kind, file_name)
            );
            CREATE INDEX IF NOT EXISTS rollback_shadow_expiry_idx
                ON rollback_shadow(expires_at_ms);
            CREATE TABLE IF NOT EXISTS rollback_shadow_health (
                singleton_id INTEGER PRIMARY KEY CHECK(singleton_id = 1),
                failure_count INTEGER NOT NULL DEFAULT 0,
                last_kind TEXT,
                last_reason TEXT,
                last_failure_at_ms INTEGER
            );
            INSERT INTO ingress_meta(key, value) VALUES ('schema_version', '1')
                ON CONFLICT(key) DO NOTHING;
            INSERT INTO ingress_meta(key, value) VALUES ('generation', '0')
                ON CONFLICT(key) DO NOTHING;
            INSERT INTO ingress_meta(key, value) VALUES (
                'legacy_rollback_shadow_started_at_ms',
                CAST(strftime('%s','now') AS INTEGER) * 1000
            ) ON CONFLICT(key) DO NOTHING;
            """
        )
        try migrateIngressDeliveryIndex(db)
        try verifySchema(db)
    }

    private func rejectUnsupportedSchemaIfPresent(_ db: OpaquePointer) throws {
        let table = try prepare(
            db,
            "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'ingress_meta' LIMIT 1;"
        )
        defer { sqlite3_finalize(table) }
        guard sqlite3_step(table) == SQLITE_ROW else { return }

        let statement = try prepare(
            db,
            "SELECT value FROM ingress_meta WHERE key = 'schema_version';"
        )
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW,
              let raw = columnText(statement, 0),
              let version = Int(raw),
              version > Self.schemaVersion
        else { return }
        throw JournalError.unsupportedSchema(version)
    }

    private func migrateIngressDeliveryIndex(_ db: OpaquePointer) throws {
        let lookup = try prepare(
            db,
            "SELECT sql FROM sqlite_master WHERE type = 'index' AND name = 'ingress_delivery_uidx';"
        )
        defer { sqlite3_finalize(lookup) }
        let currentSQL = sqlite3_step(lookup) == SQLITE_ROW ? columnText(lookup, 0) : nil
        if currentSQL?.localizedCaseInsensitiveContains("resolution_state") != true {
            // Contract is part of provider delivery ownership. Rebuild the v1
            // index because its three-column form aliases direct and v2 rows.
            try execute(db, "DROP INDEX IF EXISTS ingress_delivery_uidx;")
        }
        try execute(
            db,
            """
            CREATE UNIQUE INDEX IF NOT EXISTS ingress_delivery_uidx
                ON ingress_entry(source_base_url, source_device_key, delivery_id, resolution_state)
                WHERE source_base_url IS NOT NULL AND source_device_key IS NOT NULL AND delivery_id IS NOT NULL;
            """
        )
    }

    private func verifySchema(_ db: OpaquePointer) throws {
        let statement = try prepare(db, "SELECT value FROM ingress_meta WHERE key = 'schema_version';")
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW,
              let raw = columnText(statement, 0),
              let version = Int(raw)
        else { throw JournalError.unavailable }
        guard version <= Self.schemaVersion else { throw JournalError.unsupportedSchema(version) }
    }

    private func scalarCount(_ db: OpaquePointer, _ sql: String) throws -> Int {
        let statement = try prepare(db, sql)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(statement, 0))
    }

    private func pragmaText(_ db: OpaquePointer, name: String) throws -> String? {
        let statement = try prepare(db, "PRAGMA \(name);")
        defer { sqlite3_finalize(statement) }
        return sqlite3_step(statement) == SQLITE_ROW ? columnText(statement, 0) : nil
    }

    private func pragmaInt(_ db: OpaquePointer, name: String) throws -> Int? {
        let statement = try prepare(db, "PRAGMA \(name);")
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return Int(sqlite3_column_int(statement, 0))
    }

    private func deleteBounded(
        _ db: OpaquePointer,
        sql: String,
        before: Int64,
        limit: Int
    ) throws -> Int {
        let statement = try prepare(db, sql)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, before)
        sqlite3_bind_int64(statement, 2, Int64(limit))
        try stepDone(db, statement)
        return Int(sqlite3_changes(db))
    }

    private func ackState(_ db: OpaquePointer, ackID: String) throws -> String? {
        let statement = try prepare(db, "SELECT state FROM ack_outbox WHERE ack_id = ?;")
        defer { sqlite3_finalize(statement) }
        bindText(statement, 1, ackID)
        return sqlite3_step(statement) == SQLITE_ROW ? columnText(statement, 0) : nil
    }

    private func ingressFingerprint(_ db: OpaquePointer, entryID: String) throws -> String? {
        let statement = try prepare(
            db,
            "SELECT payload_fingerprint FROM ingress_entry WHERE entry_id = ?;"
        )
        defer { sqlite3_finalize(statement) }
        bindText(statement, 1, entryID)
        return sqlite3_step(statement) == SQLITE_ROW ? columnText(statement, 0) : nil
    }

    private func insertNotificationProjectionReceipt(
        _ db: OpaquePointer,
        identity: String,
        createdAt: Int64
    ) throws -> Bool {
        let statement = try prepare(
            db,
            "INSERT OR IGNORE INTO notification_projection_receipt (projection_id, created_at_ms) VALUES (?, ?);"
        )
        defer { sqlite3_finalize(statement) }
        bindText(statement, 1, identity)
        sqlite3_bind_int64(statement, 2, createdAt)
        try stepDone(db, statement)
        return sqlite3_changes(db) == 1
    }

    private func quarantineIngressIdentityConflict(
        _ db: OpaquePointer,
        entryID: String,
        now: Int64
    ) throws {
        let ingress = try prepare(
            db,
            """
            UPDATE ingress_entry SET validation_state = 'identity_conflict',
                apply_state = 'quarantined', quarantine_reason = 'payload_identity_conflict',
                lease_owner = NULL, lease_until_ms = NULL
            WHERE entry_id = ?;
            """
        )
        defer { sqlite3_finalize(ingress) }
        bindText(ingress, 1, entryID)
        try stepDone(db, ingress)

        let ack = try prepare(
            db,
            """
            UPDATE ack_outbox SET required_entry_state = 'conflict_blocked',
                state = CASE WHEN state = 'leased' THEN state ELSE 'retry_wait' END,
                next_attempt_at_ms = ?, updated_at_ms = ?
            WHERE entry_id = ? AND state NOT IN ('completed','superseded');
            """
        )
        defer { sqlite3_finalize(ack) }
        sqlite3_bind_int64(ack, 1, Int64.max)
        sqlite3_bind_int64(ack, 2, now)
        bindText(ack, 3, entryID)
        try stepDone(db, ack)
    }

    /// ACK leasing is the destructive network boundary. Re-validate the exact
    /// durable bytes here instead of trusting an earlier scan or writer process.
    /// This also protects an older host from ACKing a row written by a newer NSE.
    private func validateAckIngressForLease(
        _ db: OpaquePointer,
        identity: ProviderDeliveryAckFailureStore.DeliveryIdentity,
        now: Int64
    ) throws -> Bool {
        let statement = try prepare(
            db,
            """
            SELECT i.entry_id, i.schema_version, i.payload_plist, i.validation_state,
                   i.apply_state, i.payload_fingerprint, a.delivery_id, a.base_url,
                   a.device_key, a.ack_contract, i.source, i.source_base_url,
                   i.source_device_key, i.delivery_id, i.resolution_state,
                   i.discard_reason
            FROM ack_outbox a JOIN ingress_entry i ON i.entry_id = a.entry_id
            WHERE a.ack_id = ? LIMIT 1;
            """
        )
        defer { sqlite3_finalize(statement) }
        bindText(statement, 1, identity.storageKey)
        guard sqlite3_step(statement) == SQLITE_ROW,
              let entryID = columnText(statement, 0),
              let validationState = columnText(statement, 3),
              let applyState = columnText(statement, 4)
        else { return false }

        let schemaVersion = Int(sqlite3_column_int(statement, 1))
        let payload = columnBlob(statement, 2)
        let expectedFingerprint = columnText(statement, 5)
        let identityMatches = columnText(statement, 6) == identity.deliveryId
            && columnText(statement, 7) == identity.baseURLString
            && columnText(statement, 8) == identity.deviceKey
            && columnText(statement, 9) == identity.ackContract.rawValue
        let ingressIdentityMatches = columnText(statement, 11) == identity.baseURLString
            && columnText(statement, 12) == identity.deviceKey
            && columnText(statement, 13) == identity.deliveryId
            && columnText(statement, 14) == (identity.ackContract == .v2Batch ? "pulled" : "direct")
        let isDeterministicAnchor = schemaVersion <= Self.schemaVersion
            && payload == nil
            && validationState == "rejected_deterministic"
            && applyState == "discarded"
            && expectedFingerprint == Self.fingerprint(Data(identity.deliveryId.utf8))
            && columnText(statement, 10) == "ack_import"
            && ingressIdentityMatches
            && columnText(statement, 15) == "legacy_ack_import"
        let hasValidatedPayload: Bool
        if schemaVersion <= Self.schemaVersion,
           validationState == "validated",
           applyState != "quarantined",
           let payload,
           let expectedFingerprint,
           Self.fingerprint(payload) == expectedFingerprint,
           ingressIdentityMatches,
           (try? decoder.decode([String: AnyCodable].self, from: payload)) != nil
        {
            hasValidatedPayload = true
        } else {
            hasValidatedPayload = false
        }
        guard identityMatches, isDeterministicAnchor || hasValidatedPayload else {
            try quarantineAckIngressForInvalidPayload(
                db,
                entryID: entryID,
                reason: !identityMatches
                    ? "ack_identity_mismatch"
                    : schemaVersion > Self.schemaVersion
                        ? "unsupported_schema_\(schemaVersion)"
                        : "ack_payload_validation_failed",
                now: now
            )
            return false
        }
        return true
    }

    private func quarantineAckIngressForInvalidPayload(
        _ db: OpaquePointer,
        entryID: String,
        reason: String,
        now: Int64
    ) throws {
        let ingress = try prepare(
            db,
            """
            UPDATE ingress_entry SET validation_state = 'invalid',
                apply_state = 'quarantined', quarantine_reason = ?,
                lease_owner = NULL, lease_until_ms = NULL
            WHERE entry_id = ? AND apply_state != 'quarantined';
            """
        )
        defer { sqlite3_finalize(ingress) }
        bindText(ingress, 1, String(reason.prefix(128)))
        bindText(ingress, 2, entryID)
        try stepDone(db, ingress)

        let ack = try prepare(
            db,
            """
            UPDATE ack_outbox SET required_entry_state = 'invalid_blocked',
                state = CASE WHEN state = 'leased' THEN state ELSE 'retry_wait' END,
                next_attempt_at_ms = ?, updated_at_ms = ?
            WHERE entry_id = ? AND state NOT IN ('completed','superseded');
            """
        )
        defer { sqlite3_finalize(ack) }
        sqlite3_bind_int64(ack, 1, Int64.max)
        sqlite3_bind_int64(ack, 2, now)
        bindText(ack, 3, entryID)
        try stepDone(db, ack)
        try incrementGeneration(db)
    }

    @discardableResult
    private func quarantineInvalidIngressRows(_ invalidRows: [(String, String)]) -> Int {
        guard !invalidRows.isEmpty else { return 0 }
        return (try? withDatabase(write: true) { db in
            try execute(db, "BEGIN IMMEDIATE;")
            do {
                let statement = try prepare(
                    db,
                    """
                    UPDATE ingress_entry SET validation_state = 'invalid',
                        apply_state = 'quarantined', quarantine_reason = ?,
                        lease_owner = NULL, lease_until_ms = NULL
                    WHERE entry_id = ? AND apply_state IN ('pending','retry_wait');
                    """
                )
                defer { sqlite3_finalize(statement) }
                let blockAck = try prepare(
                    db,
                    """
                    UPDATE ack_outbox SET required_entry_state = 'invalid_blocked',
                        state = CASE WHEN state = 'leased' THEN state ELSE 'retry_wait' END,
                        next_attempt_at_ms = ?, updated_at_ms = ?
                    WHERE entry_id = ? AND state NOT IN ('completed','superseded');
                    """
                )
                defer { sqlite3_finalize(blockAck) }
                var changed = 0
                let now = Self.epochMilliseconds(Date())
                for (entryID, reason) in invalidRows.prefix(10_000) {
                    sqlite3_reset(statement)
                    sqlite3_clear_bindings(statement)
                    bindText(statement, 1, String(reason.prefix(128)))
                    bindText(statement, 2, entryID)
                    try stepDone(db, statement)
                    changed += Int(sqlite3_changes(db))

                    sqlite3_reset(blockAck)
                    sqlite3_clear_bindings(blockAck)
                    sqlite3_bind_int64(blockAck, 1, Int64.max)
                    sqlite3_bind_int64(blockAck, 2, now)
                    bindText(blockAck, 3, entryID)
                    try stepDone(db, blockAck)
                }
                if changed > 0 { try incrementGeneration(db) }
                try execute(db, "COMMIT;")
                return changed
            } catch {
                _ = try? execute(db, "ROLLBACK;")
                throw error
            }
        }) ?? 0
    }

    private func isContentionError(_ error: Error) -> Bool {
        guard case let JournalError.sqlite(message) = error else { return false }
        let normalizedMessage = message.lowercased()
        return normalizedMessage.contains("locked") || normalizedMessage.contains("busy")
    }

    private func execute(_ db: OpaquePointer, _ sql: String) throws {
        var errorPointer: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(db, sql, nil, nil, &errorPointer)
        if result != SQLITE_OK {
            let message = errorPointer.map { String(cString: $0) }
                ?? String(cString: sqlite3_errmsg(db))
            sqlite3_free(errorPointer)
            throw JournalError.sqlite(message)
        }
    }

    private func prepare(_ db: OpaquePointer, _ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK,
              let statement
        else { throw JournalError.sqlite(String(cString: sqlite3_errmsg(db))) }
        return statement
    }

    private func stepDone(_ db: OpaquePointer, _ statement: OpaquePointer) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw JournalError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
    }

    private func bindText(_ statement: OpaquePointer, _ index: Int32, _ value: String?) {
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }
        _ = value.withCString { pointer in
            sqlite3_bind_text(statement, index, pointer, -1, ingressSQLiteTransient)
        }
    }

    private func bindBlob(_ statement: OpaquePointer, _ index: Int32, _ data: Data) {
        _ = data.withUnsafeBytes { bytes in
            sqlite3_bind_blob(statement, index, bytes.baseAddress, Int32(bytes.count), ingressSQLiteTransient)
        }
    }

    private func columnText(_ statement: OpaquePointer, _ index: Int32) -> String? {
        guard let text = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: text)
    }

    private func columnBlob(_ statement: OpaquePointer, _ index: Int32) -> Data? {
        guard let bytes = sqlite3_column_blob(statement, index) else { return nil }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, index)))
    }

    private func columnOptionalInt64(_ statement: OpaquePointer, _ index: Int32) -> Int64? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        return sqlite3_column_int64(statement, index)
    }

    private func normalized(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func entryID(
        ackIdentity: ProviderDeliveryAckFailureStore.DeliveryIdentity?,
        deliveryID: String?,
        payloadBaseURL: String?,
        payloadDeviceKey: String?,
        payloadFingerprint: String
    ) -> String {
        let material: String
        if let ackIdentity {
            material = [
                ackIdentity.baseURLString,
                ackIdentity.deviceKey,
                ackIdentity.ackContract.rawValue,
                ackIdentity.deliveryId,
            ]
                .joined(separator: "\u{0}")
        } else if let deliveryID, let payloadBaseURL, let payloadDeviceKey {
            material = [payloadBaseURL, payloadDeviceKey, "legacySingle", deliveryID]
                .joined(separator: "\u{0}")
        } else {
            // Partial ownership is not a safe delivery identity. Folding only
            // on delivery_id could destroy an unrelated gateway/device row, so
            // exact payload identity is the strongest safe idempotency key.
            material = "payload\u{0}\(payloadFingerprint)"
        }
        return fingerprint(Data(material.utf8))
    }

    private static func projectionIdentity(
        messageID: String?,
        ingressEntryID: String
    ) -> String {
        if let messageID {
            return "message:\(messageID)"
        }
        return "ingress:\(ingressEntryID)"
    }

    private static func fingerprint(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func epochMilliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000).rounded())
    }

    private func postIngressChangedNotification() {
        DarwinNotificationPoster.post(name: AppConstants.notificationIngressChangedNotificationName)
    }
}
