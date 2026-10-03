import Foundation

actor NotificationIngressInbox {
    struct QueueCounts: Sendable, Equatable {
        let due: Int
        let outstanding: Int

        static let zero = QueueCounts(due: 0, outstanding: 0)
    }

    typealias EnqueueResult = DurableIngressJournal.EnqueueResult
    struct StoredEntry: Codable, Sendable {
        let schemaVersion: Int
        let entryId: String
        let createdAtEpochMs: Int64
        let source: String
        let requestIdentifier: String?
        let payload: [String: AnyCodable]
    }

    struct PendingEntry: Sendable {
        let fileName: String
        let fileURL: URL
        let record: StoredEntry

        var payload: [AnyHashable: Any] {
            record.payload.reduce(into: [AnyHashable: Any]()) { result, item in
                result[item.key] = item.value.value
            }
        }
    }

    struct ClaimedEntry: Sendable {
        let entry: PendingEntry
        let owner: String
        let leaseGeneration: Int64

        var payload: [AnyHashable: Any] { entry.payload }
        var record: StoredEntry { entry.record }
    }

    static let shared = NotificationIngressInbox()

    private let journal: DurableIngressJournal

    init(
        fileManager: FileManager = .default,
        appGroupIdentifier: String = AppConstants.appGroupIdentifier
    ) {
        journal = DurableIngressJournal(
            appGroupIdentifier: appGroupIdentifier
        )
    }

    @discardableResult
    func enqueue(
        payload: [AnyHashable: Any],
        requestIdentifier: String?,
        source: String
    ) async -> Bool {
        let sanitized = UserInfoSanitizer.sanitize(payload)
        let codablePayload = codablePayloadDictionary(from: sanitized)
        return await enqueue(
            codablePayload: codablePayload,
            requestIdentifier: requestIdentifier,
            source: source
        )
    }

    @discardableResult
    func enqueue(
        codablePayload: [String: AnyCodable],
        requestIdentifier: String?,
        source: String,
        ackIdentity: ProviderDeliveryAckFailureStore.DeliveryIdentity? = nil,
        requiredEntryState: String = "durable",
        postChangeNotification: Bool = true
    ) async -> Bool {
        await journal.enqueueIngress(
            codablePayload: codablePayload,
            requestIdentifier: requestIdentifier,
            source: source,
            ackIdentity: ackIdentity,
            requiredEntryState: requiredEntryState,
            postChangeNotification: postChangeNotification
        )
    }

    func enqueueWithResult(
        codablePayload: [String: AnyCodable],
        requestIdentifier: String?,
        source: String,
        ackIdentity: ProviderDeliveryAckFailureStore.DeliveryIdentity? = nil,
        requiredEntryState: String = "durable",
        postChangeNotification: Bool = true
    ) async -> EnqueueResult {
        await journal.enqueueIngressResult(
            codablePayload: codablePayload,
            requestIdentifier: requestIdentifier,
            source: source,
            ackIdentity: ackIdentity,
            requiredEntryState: requiredEntryState,
            postChangeNotification: postChangeNotification
        )
    }

    func pendingEntries(limit: Int? = nil) async -> [PendingEntry] {
        await journal.importLegacyStateIfNeeded()
        return await journal.pendingIngressEntries(limit: limit)
    }

    func prepareForDrain() async {
        await journal.importLegacyStateIfNeeded()
    }

    func queueCounts(
        now: Date = Date(),
        importLegacyState: Bool = true
    ) async -> QueueCounts {
        if importLegacyState {
            await journal.importLegacyStateIfNeeded()
        }
        return await journal.ingressQueueCounts(now: now)
    }

    func claimPendingEntries(
        owner: String,
        leaseDuration: TimeInterval = 60,
        limit: Int = 64,
        now: Date = Date(),
        importLegacyState: Bool = true
    ) async -> [ClaimedEntry] {
        if importLegacyState {
            await journal.importLegacyStateIfNeeded()
        }
        return await journal.claimPendingIngressEntries(
            owner: owner,
            leaseDuration: leaseDuration,
            limit: limit,
            now: now
        )
    }

    func nextRetryDate(now: Date = Date()) async -> Date? {
        await journal.nextIngressRetryDate(now: now)
    }

    func durablePayload(
        identity: ProviderDeliveryAckFailureStore.DeliveryIdentity
    ) async -> [String: AnyCodable]? {
        await journal.durableIngressPayload(identity: identity)
    }

    func markCompleted(_ entry: PendingEntry) async {
        await journal.markIngressCompleted(entryID: entry.record.entryId)
    }

    @discardableResult
    func markCompleted(_ claimed: ClaimedEntry) async -> Bool {
        await journal.markIngressCompleted(
            entryID: claimed.record.entryId,
            owner: claimed.owner,
            leaseGeneration: claimed.leaseGeneration
        )
    }

    @discardableResult
    func markCompleted(_ claimedEntries: [ClaimedEntry]) async -> Int {
        await journal.markIngressCompleted(claimedEntries)
    }

    func markCompleted(fileName: String) async {
        await journal.markIngressCompleted(entryID: fileName)
    }

    func markRetry(
        _ entry: PendingEntry,
        reason: String,
        retryAfter: Date = Date().addingTimeInterval(30)
    ) async {
        await journal.markIngressRetry(
            entryID: entry.record.entryId,
            reason: reason,
            retryAfter: retryAfter
        )
    }

    @discardableResult
    func markRetry(
        _ claimed: ClaimedEntry,
        reason: String,
        retryAfter: Date = Date().addingTimeInterval(30)
    ) async -> Bool {
        await journal.markIngressRetry(
            entryID: claimed.record.entryId,
            owner: claimed.owner,
            leaseGeneration: claimed.leaseGeneration,
            reason: reason,
            retryAfter: retryAfter
        )
    }

    func markTerminal(
        identity: ProviderDeliveryAckFailureStore.DeliveryIdentity,
        discarded: Bool,
        reason: String? = nil
    ) async {
        await journal.markIngressTerminal(
            identity: identity,
            discarded: discarded,
            reason: reason
        )
    }

    @discardableResult
    func performMaintenance(
        now: Date = Date(),
        force: Bool = false,
        batchLimit: Int = 512
    ) async -> DurableIngressJournal.MaintenanceResult {
        await journal.performMaintenance(now: now, force: force, batchLimit: batchLimit)
    }

#if DEBUG
    func purgePerformanceFixtures() async -> (rows: Int, shadows: Int) {
        await journal.purgeTerminalIngressEntriesForPerformanceTesting(
            source: "debug.ingress_performance"
        )
    }
#endif

    private func codablePayloadDictionary(
        from payload: [AnyHashable: Any]
    ) -> [String: AnyCodable] {
        payload.reduce(into: [String: AnyCodable]()) { result, item in
            let key: String
            if let stringKey = item.key as? String {
                key = stringKey
            } else {
                key = String(describing: item.key)
            }
            result[key] = AnyCodable(item.value)
        }
    }

}
