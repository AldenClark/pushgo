import CryptoKit
import Foundation

func normalizedProviderGatewayURL(_ baseURL: URL) -> URL? {
    guard let validated = URLSanitizer.validatedServerURL(baseURL),
          var components = URLComponents(url: validated, resolvingAgainstBaseURL: false)
    else {
        return nil
    }
    components.scheme = components.scheme?.lowercased()
    components.host = components.host?.lowercased()
    var path = components.percentEncodedPath
    while path.hasSuffix("/") && path.count > 1 {
        path.removeLast()
    }
    if path == "/" {
        path = ""
    }
    components.percentEncodedPath = path
    return components.url
}

actor ProviderDeliveryAckFailureStore {
    enum AckContract: String, Codable, Sendable {
        case legacySingle
        case v2Batch
    }

    enum Stage: String, Codable, Sendable {
        case preparing
        case inboxDurable
        case ackInFlight
        case completed
    }

    struct DeliveryIdentity: Codable, Hashable, Sendable {
        let baseURLString: String
        let deviceKey: String
        let ackContract: AckContract
        let deliveryId: String

        init?(
            deliveryId: String,
            baseURL: URL,
            deviceKey: String,
            ackContract: AckContract
        ) {
            let normalizedDeliveryId = deliveryId.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedDeviceKey = deviceKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedDeliveryId.isEmpty,
                  !normalizedDeviceKey.isEmpty,
                  let normalizedBaseURL = normalizedProviderGatewayURL(baseURL)
            else {
                return nil
            }
            self.baseURLString = normalizedBaseURL.absoluteString
            self.deviceKey = normalizedDeviceKey
            self.ackContract = ackContract
            self.deliveryId = normalizedDeliveryId
        }

        var baseURL: URL {
            URL(string: baseURLString)!
        }

        var storageKey: String {
            let material = [
                baseURLString,
                deviceKey,
                ackContract.rawValue,
                deliveryId,
            ].joined(separator: "\u{0}")
            return SHA256.hash(data: Data(material.utf8))
                .map { String(format: "%02x", $0) }
                .joined()
        }

        static func direct(from payload: [String: Any]) -> DeliveryIdentity? {
            guard let deliveryId = normalized(payload["delivery_id"] as? String),
                  let rawBaseURL = normalized(payload["base_url"] as? String),
                  let baseURL = URLSanitizer.validatedServerURL(from: rawBaseURL),
                  let deviceKey = normalized(payload["provider_device_key"] as? String)
            else {
                return nil
            }
            return DeliveryIdentity(
                deliveryId: deliveryId,
                baseURL: baseURL,
                deviceKey: deviceKey,
                ackContract: .legacySingle
            )
        }

        private static func normalized(_ value: String?) -> String? {
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed.isEmpty ? nil : trimmed
        }
    }

    struct StoredMarker: Codable, Sendable {
        let schemaVersion: Int
        let deliveryId: String
        let baseURLString: String?
        let deviceKey: String?
        let ackContract: AckContract?
        let attemptCount: Int?
        let stage: Stage
        let owner: String?
        let leaseUntilEpochMs: Int64?
        let retryAfterEpochMs: Int64?
        let createdAtEpochMs: Int64
        let updatedAtEpochMs: Int64
        let source: String
        var leaseGeneration: Int64? = nil
    }

    struct PendingMarker: Sendable {
        let fileName: String
        let fileURL: URL
        let record: StoredMarker

        var baseURL: URL? {
            guard let raw = record.baseURLString else { return nil }
            return URLSanitizer.validatedServerURL(from: raw)
        }

        var identity: DeliveryIdentity? {
            guard let baseURL,
                  let deviceKey = record.deviceKey,
                  let ackContract = record.ackContract
            else {
                return nil
            }
            return DeliveryIdentity(
                deliveryId: record.deliveryId,
                baseURL: baseURL,
                deviceKey: deviceKey,
                ackContract: ackContract
            )
        }

        var ackContract: AckContract {
            record.ackContract ?? .legacySingle
        }

        var attemptCount: Int {
            max(0, record.attemptCount ?? 0)
        }
    }

    static let shared = ProviderDeliveryAckFailureStore()

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
    func markPreparing(
        identity: DeliveryIdentity,
        source: String,
        postNotification: Bool = false
    ) async -> Bool {
        await journal.markAck(identity: identity, stage: .preparing, source: source)
    }

    @discardableResult
    func markInboxDurable(
        identity: DeliveryIdentity,
        source: String,
        retryAfter: Date? = nil,
        postNotification: Bool = true
    ) async -> Bool {
        await journal.markAck(
            identity: identity,
            stage: .inboxDurable,
            source: source,
            retryAfter: retryAfter
        )
    }

    func pendingMarkers(
        limit: Int? = nil,
        minimumAge: TimeInterval = 0,
        now: Date = Date()
    ) async -> [PendingMarker] {
        await journal.importLegacyStateIfNeeded()
        return await journal.pendingAckMarkers(limit: limit, minimumAge: minimumAge, now: now)
    }

    func nextAttemptDate(now: Date = Date()) async -> Date? {
        await journal.nextAckAttemptDate(now: now)
    }

    func acquireAckLease(
        _ marker: PendingMarker,
        owner: String,
        leaseDuration: TimeInterval,
        now: Date = Date()
    ) async -> PendingMarker? {
        await acquireAckLease(
            identity: marker.identity,
            owner: owner,
            leaseDuration: leaseDuration,
            now: now
        )
    }

    func acquireAckLease(
        identity: DeliveryIdentity?,
        owner: String,
        leaseDuration: TimeInterval,
        now: Date = Date()
    ) async -> PendingMarker? {
        guard let identity, let owner = normalizedText(owner) else { return nil }
        return await journal.acquireAckLease(
            identity: identity,
            owner: owner,
            leaseDuration: leaseDuration,
            now: now
        )
    }

    func markAckFailed(
        _ marker: PendingMarker,
        source: String,
        retryAfter: Date? = Date().addingTimeInterval(30),
        postNotification: Bool = true
    ) async {
        await journal.markAckFailed(marker: marker, source: source, retryAfter: retryAfter)
    }

    func markCompleted(_ marker: PendingMarker) async {
        await journal.markAckCompleted(marker: marker)
    }

    func markCompleted(identity: DeliveryIdentity) async {
        await journal.markAckCompleted(identity: identity)
    }

    private func normalizedText(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

}

actor ProviderWakeupPullClaimStore {
    enum ClaimState: Equatable, Sendable {
        case available
        case claimed
        case completed
    }

    enum State: String, Codable, Sendable {
        case claimed
        case completed
    }

    struct StoredClaim: Codable, Sendable {
        let schemaVersion: Int
        let deliveryId: String
        let baseURLString: String?
        let deviceKey: String?
        let ackContract: ProviderDeliveryAckFailureStore.AckContract?
        let state: State
        let owner: String?
        let leaseUntilEpochMs: Int64?
        let createdAtEpochMs: Int64
        let updatedAtEpochMs: Int64
        var leaseGeneration: Int64? = nil
    }

    struct ClaimLease: Sendable {
        let fileName: String
        let fileURL: URL
        let record: StoredClaim

        var identity: ProviderDeliveryAckFailureStore.DeliveryIdentity? {
            guard let rawBaseURL = record.baseURLString,
                  let baseURL = URLSanitizer.validatedServerURL(from: rawBaseURL),
                  let deviceKey = record.deviceKey,
                  let ackContract = record.ackContract
            else {
                return nil
            }
            return ProviderDeliveryAckFailureStore.DeliveryIdentity(
                deliveryId: record.deliveryId,
                baseURL: baseURL,
                deviceKey: deviceKey,
                ackContract: ackContract
            )
        }
    }

    static let shared = ProviderWakeupPullClaimStore()

    private let journal: DurableIngressJournal

    init(
        fileManager: FileManager = .default,
        appGroupIdentifier: String = AppConstants.appGroupIdentifier
    ) {
        journal = DurableIngressJournal(
            appGroupIdentifier: appGroupIdentifier
        )
    }

    func acquireLease(
        identity: ProviderDeliveryAckFailureStore.DeliveryIdentity,
        owner: String,
        leaseDuration: TimeInterval,
        now: Date = Date()
    ) async -> ClaimLease? {
        guard let normalizedOwner = normalizedText(owner) else { return nil }
        await journal.importLegacyStateIfNeeded()
        return await journal.acquirePullClaim(
            identity: identity,
            owner: normalizedOwner,
            leaseDuration: leaseDuration,
            now: now
        )
    }

    func markCompleted(_ lease: ClaimLease, now: Date = Date()) async {
        await journal.completePullClaim(lease, now: now)
    }

    func releaseLease(_ lease: ClaimLease, now: Date = Date()) async {
        await journal.releasePullClaim(lease, now: now)
    }

    func durableIngressPayload(
        identity: ProviderDeliveryAckFailureStore.DeliveryIdentity
    ) async -> [String: AnyCodable]? {
        await journal.durableIngressPayload(identity: identity)
    }

    private func normalizedText(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

}
