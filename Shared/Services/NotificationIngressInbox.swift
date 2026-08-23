import Foundation

actor NotificationIngressInbox {
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
        requiredEntryState: String = "durable"
    ) async -> Bool {
        await journal.enqueueIngress(
            codablePayload: codablePayload,
            requestIdentifier: requestIdentifier,
            source: source,
            ackIdentity: ackIdentity,
            requiredEntryState: requiredEntryState
        )
    }

    func enqueueWithResult(
        codablePayload: [String: AnyCodable],
        requestIdentifier: String?,
        source: String,
        ackIdentity: ProviderDeliveryAckFailureStore.DeliveryIdentity? = nil,
        requiredEntryState: String = "durable"
    ) async -> EnqueueResult {
        await journal.enqueueIngressResult(
            codablePayload: codablePayload,
            requestIdentifier: requestIdentifier,
            source: source,
            ackIdentity: ackIdentity,
            requiredEntryState: requiredEntryState
        )
    }

    func pendingEntries(limit: Int? = nil) async -> [PendingEntry] {
        await journal.importLegacyStateIfNeeded()
        return await journal.pendingIngressEntries(limit: limit)
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
