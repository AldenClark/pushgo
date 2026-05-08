import Foundation

actor ProviderDeliveryAckFailureStore {
    enum Stage: String, Codable, Sendable {
        case preparing
        case inboxDurable
        case ackInFlight
        case completed
    }

    struct StoredMarker: Codable, Sendable {
        let schemaVersion: Int
        let deliveryId: String
        let baseURLString: String?
        let deviceKeyAccount: String?
        let routeGeneration: String?
        let stage: Stage
        let owner: String?
        let leaseUntilEpochMs: Int64?
        let retryAfterEpochMs: Int64?
        let createdAtEpochMs: Int64
        let updatedAtEpochMs: Int64
        let source: String
    }

    struct PendingMarker: Sendable {
        let fileName: String
        let fileURL: URL
        let record: StoredMarker

        var baseURL: URL? {
            guard let raw = record.baseURLString else { return nil }
            return URLSanitizer.validatedServerURL(from: raw)
        }
    }

    static let shared = ProviderDeliveryAckFailureStore()

    private static let schemaVersion = 2
    private static let fileExtension = "ackbin"
    private static let mutationLockExtension = "lock"
    private static let directoryName = "provider-delivery-ack-failures"
    private static let completedMarkerRetention: TimeInterval = 10 * 60
    private static let mutationLockStaleAge: TimeInterval = 30

    private let fileManager: FileManager
    private let appGroupIdentifier: String
    private let encoder: PropertyListEncoder
    private let decoder: PropertyListDecoder

    init(
        fileManager: FileManager = .default,
        appGroupIdentifier: String = AppConstants.appGroupIdentifier
    ) {
        self.fileManager = fileManager
        self.appGroupIdentifier = appGroupIdentifier

        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        self.encoder = encoder
        decoder = PropertyListDecoder()
    }

    @discardableResult
    func markPreparing(
        deliveryId: String,
        baseURL: URL?,
        deviceKeyAccount: String?,
        routeGeneration: String? = nil,
        source: String,
        postNotification: Bool = false
    ) async -> Bool {
        await writeMarker(
            deliveryId: deliveryId,
            baseURL: baseURL,
            deviceKeyAccount: deviceKeyAccount,
            routeGeneration: routeGeneration,
            stage: .preparing,
            owner: nil,
            leaseUntil: nil,
            retryAfter: nil,
            source: source,
            postNotification: postNotification
        )
    }

    @discardableResult
    func markInboxDurable(
        deliveryId: String,
        baseURL: URL?,
        deviceKeyAccount: String?,
        routeGeneration: String? = nil,
        source: String,
        retryAfter: Date? = nil,
        postNotification: Bool = true
    ) async -> Bool {
        await writeMarker(
            deliveryId: deliveryId,
            baseURL: baseURL,
            deviceKeyAccount: deviceKeyAccount,
            routeGeneration: routeGeneration,
            stage: .inboxDurable,
            owner: nil,
            leaseUntil: nil,
            retryAfter: retryAfter,
            source: source,
            postNotification: postNotification
        )
    }

    func pendingMarkers(
        limit: Int? = nil,
        minimumAge: TimeInterval = 0,
        now: Date = Date()
    ) -> [PendingMarker] {
        let nowEpochMs = Self.epochMilliseconds(now)
        let minimumAgeMs = Int64((minimumAge * 1_000).rounded())
        let fileURLs = markerFileURLs()

        var markers: [PendingMarker] = []
        markers.reserveCapacity(fileURLs.count)
        for fileURL in fileURLs {
            if let max = limit, markers.count >= max {
                break
            }
            guard let marker = loadMarker(fileURL: fileURL) else {
                continue
            }
            guard isEligibleForAppAck(marker.record, nowEpochMs: nowEpochMs, minimumAgeMs: minimumAgeMs) else {
                continue
            }
            markers.append(marker)
        }
        return markers
    }

    func acquireAckLease(
        _ marker: PendingMarker,
        owner: String,
        leaseDuration: TimeInterval,
        now: Date = Date()
    ) async -> PendingMarker? {
        await acquireAckLease(
            deliveryId: marker.record.deliveryId,
            owner: owner,
            leaseDuration: leaseDuration,
            now: now
        )
    }

    func acquireAckLease(
        deliveryId: String,
        owner: String,
        leaseDuration: TimeInterval,
        now: Date = Date()
    ) async -> PendingMarker? {
        guard let normalizedDeliveryId = normalizedText(deliveryId),
              let directoryURL = markerDirectoryURL()
        else {
            return nil
        }
        guard await acquireMutationLock(deliveryId: normalizedDeliveryId, directoryURL: directoryURL, now: now) else {
            return nil
        }
        defer {
            releaseMutationLock(deliveryId: normalizedDeliveryId, directoryURL: directoryURL)
        }
        let fileURL = directoryURL.appendingPathComponent(
            Self.markerFileName(deliveryId: normalizedDeliveryId),
            isDirectory: false
        )
        guard let current = loadMarker(fileURL: fileURL) else {
            return nil
        }

        let nowEpochMs = Self.epochMilliseconds(now)
        if current.record.stage == .completed {
            if isCompletedMarkerFresh(current.record, nowEpochMs: nowEpochMs) {
                return nil
            }
            try? fileManager.removeItem(at: fileURL)
            return nil
        }
        guard canAcquire(current.record, nowEpochMs: nowEpochMs) else {
            return nil
        }

        let updated = StoredMarker(
            schemaVersion: Self.schemaVersion,
            deliveryId: current.record.deliveryId,
            baseURLString: current.record.baseURLString,
            deviceKeyAccount: current.record.deviceKeyAccount,
            routeGeneration: current.record.routeGeneration,
            stage: .ackInFlight,
            owner: normalizedText(owner),
            leaseUntilEpochMs: Self.epochMilliseconds(now.addingTimeInterval(leaseDuration)),
            retryAfterEpochMs: nil,
            createdAtEpochMs: current.record.createdAtEpochMs,
            updatedAtEpochMs: nowEpochMs,
            source: current.record.source
        )
        guard write(updated, to: fileURL, postNotification: false) else {
            return nil
        }
        return PendingMarker(fileName: fileURL.lastPathComponent, fileURL: fileURL, record: updated)
    }

    func markAckFailed(
        _ marker: PendingMarker,
        source: String,
        retryAfter: Date? = Date().addingTimeInterval(30),
        postNotification: Bool = true
    ) async {
        _ = await writeMarker(
            deliveryId: marker.record.deliveryId,
            baseURL: marker.baseURL,
            deviceKeyAccount: marker.record.deviceKeyAccount,
            routeGeneration: marker.record.routeGeneration,
            stage: .inboxDurable,
            owner: nil,
            leaseUntil: nil,
            retryAfter: retryAfter,
            source: source,
            postNotification: postNotification,
            allowActiveLeaseOverride: true
        )
    }

    func markCompleted(_ marker: PendingMarker) async {
        guard let directoryURL = markerDirectoryURL() else { return }
        let now = Date()
        guard await acquireMutationLock(
            deliveryId: marker.record.deliveryId,
            directoryURL: directoryURL,
            now: now
        ) else {
            return
        }
        defer {
            releaseMutationLock(deliveryId: marker.record.deliveryId, directoryURL: directoryURL)
        }
        let completed = completedMarker(
            from: marker.record,
            deliveryId: marker.record.deliveryId,
            now: now
        )
        _ = write(completed, to: marker.fileURL, postNotification: false)
    }

    func markCompleted(deliveryId: String) async {
        guard let normalizedDeliveryId = normalizedText(deliveryId),
              let directoryURL = markerDirectoryURL()
        else {
            return
        }
        let now = Date()
        guard await acquireMutationLock(
            deliveryId: normalizedDeliveryId,
            directoryURL: directoryURL,
            now: now
        ) else {
            return
        }
        defer {
            releaseMutationLock(deliveryId: normalizedDeliveryId, directoryURL: directoryURL)
        }
        let fileURL = directoryURL.appendingPathComponent(
            Self.markerFileName(deliveryId: normalizedDeliveryId),
            isDirectory: false
        )
        let completed = completedMarker(
            from: loadMarker(fileURL: fileURL)?.record,
            deliveryId: normalizedDeliveryId,
            now: now
        )
        _ = write(completed, to: fileURL, postNotification: false)
    }

    @discardableResult
    private func writeMarker(
        deliveryId: String,
        baseURL: URL?,
        deviceKeyAccount: String?,
        routeGeneration: String?,
        stage: Stage,
        owner: String?,
        leaseUntil: Date?,
        retryAfter: Date?,
        source: String,
        postNotification: Bool,
        allowActiveLeaseOverride: Bool = false
    ) async -> Bool {
        guard let normalizedDeliveryId = normalizedText(deliveryId),
              let directoryURL = markerDirectoryURL()
        else {
            return false
        }
        let now = Date()
        guard await acquireMutationLock(
            deliveryId: normalizedDeliveryId,
            directoryURL: directoryURL,
            now: now
        ) else {
            return false
        }
        defer {
            releaseMutationLock(deliveryId: normalizedDeliveryId, directoryURL: directoryURL)
        }
        let fileName = Self.markerFileName(deliveryId: normalizedDeliveryId)
        let finalURL = directoryURL.appendingPathComponent(fileName, isDirectory: false)
        let nowEpochMs = Self.epochMilliseconds(now)
        var existing = loadMarker(fileURL: finalURL)?.record
        if let current = existing, current.stage == .completed {
            guard !isCompletedMarkerFresh(current, nowEpochMs: nowEpochMs) else {
                return false
            }
            try? fileManager.removeItem(at: finalURL)
            existing = nil
        }
        if let existing,
           existing.stage == .ackInFlight,
           let leaseUntil = existing.leaseUntilEpochMs,
           leaseUntil > nowEpochMs,
           stage != .ackInFlight,
           !allowActiveLeaseOverride
        {
            return false
        }
        if let existing,
           existing.stage == .inboxDurable,
           stage == .preparing
        {
            return true
        }
        let marker = StoredMarker(
            schemaVersion: Self.schemaVersion,
            deliveryId: normalizedDeliveryId,
            baseURLString: baseURL?.absoluteString ?? existing?.baseURLString,
            deviceKeyAccount: normalizedText(deviceKeyAccount) ?? existing?.deviceKeyAccount,
            routeGeneration: normalizedText(routeGeneration) ?? existing?.routeGeneration,
            stage: stage,
            owner: normalizedText(owner),
            leaseUntilEpochMs: leaseUntil.map(Self.epochMilliseconds),
            retryAfterEpochMs: retryAfter.map(Self.epochMilliseconds),
            createdAtEpochMs: existing?.createdAtEpochMs ?? nowEpochMs,
            updatedAtEpochMs: nowEpochMs,
            source: normalizedText(source) ?? existing?.source ?? "unknown"
        )
        return write(marker, to: finalURL, postNotification: postNotification)
    }

    private func write(
        _ marker: StoredMarker,
        to finalURL: URL,
        postNotification: Bool
    ) -> Bool {
        guard let directoryURL = markerDirectoryURL(),
              let data = try? encoder.encode(marker)
        else {
            return false
        }
        let tempURL = directoryURL.appendingPathComponent(
            ".\(finalURL.lastPathComponent).tmp-\(UUID().uuidString.lowercased())",
            isDirectory: false
        )

        do {
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            try data.write(to: tempURL, options: [])
            if fileManager.fileExists(atPath: finalURL.path) {
                _ = try fileManager.replaceItemAt(
                    finalURL,
                    withItemAt: tempURL,
                    backupItemName: nil,
                    options: [.usingNewMetadataOnly]
                )
            } else {
                try fileManager.moveItem(at: tempURL, to: finalURL)
            }
            if postNotification {
                DarwinNotificationPoster.post(name: AppConstants.notificationIngressChangedNotificationName)
            }
            return true
        } catch {
            try? fileManager.removeItem(at: tempURL)
            return false
        }
    }

    private func markerFileURLs() -> [URL] {
        guard let directoryURL = markerDirectoryURL(),
              let contents = try? fileManager.contentsOfDirectory(
                  at: directoryURL,
                  includingPropertiesForKeys: nil,
                  options: [.skipsHiddenFiles]
              )
        else {
            return []
        }
        purgeExpiredCompletedMarkers(directoryURL: directoryURL, now: Date())
        return contents
            .filter { $0.pathExtension == Self.fileExtension }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func loadMarker(fileURL: URL) -> PendingMarker? {
        guard let data = try? Data(contentsOf: fileURL),
              let record = try? decoder.decode(StoredMarker.self, from: data),
              record.schemaVersion == Self.schemaVersion,
              normalizedText(record.deliveryId) != nil
        else {
            try? fileManager.removeItem(at: fileURL)
            return nil
        }
        return PendingMarker(
            fileName: fileURL.lastPathComponent,
            fileURL: fileURL,
            record: record
        )
    }

    private func isEligibleForAppAck(
        _ record: StoredMarker,
        nowEpochMs: Int64,
        minimumAgeMs: Int64
    ) -> Bool {
        if let retryAfter = record.retryAfterEpochMs, retryAfter > nowEpochMs {
            return false
        }
        guard nowEpochMs - record.updatedAtEpochMs >= minimumAgeMs else {
            return false
        }
        switch record.stage {
        case .inboxDurable:
            return true
        case .ackInFlight:
            guard let leaseUntil = record.leaseUntilEpochMs else { return true }
            return leaseUntil <= nowEpochMs
        case .preparing, .completed:
            return false
        }
    }

    private func canAcquire(_ record: StoredMarker, nowEpochMs: Int64) -> Bool {
        if let retryAfter = record.retryAfterEpochMs, retryAfter > nowEpochMs {
            return false
        }
        switch record.stage {
        case .inboxDurable:
            return true
        case .ackInFlight:
            guard let leaseUntil = record.leaseUntilEpochMs else { return true }
            return leaseUntil <= nowEpochMs
        case .preparing, .completed:
            return false
        }
    }

    private func markerDirectoryURL() -> URL? {
        guard let containerURL = AppConstants.appGroupContainerURL(
            fileManager: fileManager,
            identifier: appGroupIdentifier
        ) else {
            return nil
        }
        return containerURL
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent(Self.directoryName, isDirectory: true)
    }

    private static func markerFileName(deliveryId: String) -> String {
        let escaped = Data(deliveryId.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "")
        return "\(escaped).\(fileExtension)"
    }

    private static func mutationLockDirectoryName(deliveryId: String) -> String {
        ".\(markerFileName(deliveryId: deliveryId)).\(mutationLockExtension)"
    }

    private func acquireMutationLock(
        deliveryId: String,
        directoryURL: URL,
        now: Date
    ) async -> Bool {
        let lockURL = directoryURL.appendingPathComponent(
            Self.mutationLockDirectoryName(deliveryId: deliveryId),
            isDirectory: true
        )
        for attempt in 0..<5 {
            do {
                try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
                try fileManager.createDirectory(at: lockURL, withIntermediateDirectories: false)
                return true
            } catch {
                let attemptNow = attempt == 0 ? now : Date()
                if isStaleLock(lockURL, now: attemptNow) {
                    try? fileManager.removeItem(at: lockURL)
                    continue
                }
                guard attempt < 4 else { return false }
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
        }
        return false
    }

    private func releaseMutationLock(deliveryId: String, directoryURL: URL) {
        let lockURL = directoryURL.appendingPathComponent(
            Self.mutationLockDirectoryName(deliveryId: deliveryId),
            isDirectory: true
        )
        try? fileManager.removeItem(at: lockURL)
    }

    private func isStaleLock(_ lockURL: URL, now: Date) -> Bool {
        guard let attributes = try? fileManager.attributesOfItem(atPath: lockURL.path),
              let modifiedAt = attributes[.modificationDate] as? Date
        else {
            return false
        }
        return now.timeIntervalSince(modifiedAt) >= Self.mutationLockStaleAge
    }

    private func completedMarker(
        from existing: StoredMarker?,
        deliveryId: String,
        now: Date
    ) -> StoredMarker {
        let nowEpochMs = Self.epochMilliseconds(now)
        return StoredMarker(
            schemaVersion: Self.schemaVersion,
            deliveryId: deliveryId,
            baseURLString: existing?.baseURLString,
            deviceKeyAccount: existing?.deviceKeyAccount,
            routeGeneration: existing?.routeGeneration,
            stage: .completed,
            owner: nil,
            leaseUntilEpochMs: nil,
            retryAfterEpochMs: nil,
            createdAtEpochMs: existing?.createdAtEpochMs ?? nowEpochMs,
            updatedAtEpochMs: nowEpochMs,
            source: existing?.source ?? "completed"
        )
    }

    private func isCompletedMarkerFresh(
        _ marker: StoredMarker,
        nowEpochMs: Int64
    ) -> Bool {
        guard marker.stage == .completed else { return false }
        let retentionMs = Int64((Self.completedMarkerRetention * 1_000).rounded())
        return nowEpochMs - marker.updatedAtEpochMs < retentionMs
    }

    private func purgeExpiredCompletedMarkers(directoryURL: URL, now: Date) {
        let nowEpochMs = Self.epochMilliseconds(now)
        let contents = (try? fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        for url in contents where url.pathExtension == Self.fileExtension {
            guard let record = loadMarker(fileURL: url)?.record,
                  record.stage == .completed
            else { continue }
            if !isCompletedMarkerFresh(record, nowEpochMs: nowEpochMs) {
                try? fileManager.removeItem(at: url)
            }
        }
    }

    private static func epochMilliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000).rounded())
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
        let state: State
        let owner: String?
        let leaseUntilEpochMs: Int64?
        let createdAtEpochMs: Int64
        let updatedAtEpochMs: Int64
    }

    struct ClaimLease: Sendable {
        let fileName: String
        let fileURL: URL
        let record: StoredClaim
    }

    static let shared = ProviderWakeupPullClaimStore()

    private static let schemaVersion = 1
    private static let fileExtension = "pullclaim"
    private static let lockExtension = "lock"
    private static let directoryName = "provider-wakeup-pull-claims"
    private static let completedRetention: TimeInterval = 10 * 60
    private static let mutationLockStaleAge: TimeInterval = 30

    private let fileManager: FileManager
    private let appGroupIdentifier: String
    private let encoder: PropertyListEncoder
    private let decoder: PropertyListDecoder

    init(
        fileManager: FileManager = .default,
        appGroupIdentifier: String = AppConstants.appGroupIdentifier
    ) {
        self.fileManager = fileManager
        self.appGroupIdentifier = appGroupIdentifier

        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        self.encoder = encoder
        decoder = PropertyListDecoder()
    }

    func acquireLease(
        deliveryId: String,
        owner: String,
        leaseDuration: TimeInterval,
        now: Date = Date()
    ) async -> ClaimLease? {
        guard let normalizedDeliveryId = normalizedText(deliveryId),
              let normalizedOwner = normalizedText(owner),
              let directoryURL = claimsDirectoryURL()
        else {
            return nil
        }
        guard await acquireMutationLock(
            deliveryId: normalizedDeliveryId,
            directoryURL: directoryURL,
            now: now
        ) else {
            return nil
        }
        defer {
            releaseMutationLock(deliveryId: normalizedDeliveryId, directoryURL: directoryURL)
        }

        let fileURL = directoryURL.appendingPathComponent(
            Self.claimFileName(deliveryId: normalizedDeliveryId),
            isDirectory: false
        )
        let nowEpochMs = Self.epochMilliseconds(now)
        if let current = loadClaim(fileURL: fileURL) {
            switch current.record.state {
            case .completed:
                if isCompletedClaimFresh(current.record, nowEpochMs: nowEpochMs) {
                    return nil
                }
            case .claimed:
                if let leaseUntilEpochMs = current.record.leaseUntilEpochMs,
                   leaseUntilEpochMs > nowEpochMs
                {
                    return nil
                }
            }
        }

        let claim = StoredClaim(
            schemaVersion: Self.schemaVersion,
            deliveryId: normalizedDeliveryId,
            state: .claimed,
            owner: normalizedOwner,
            leaseUntilEpochMs: Self.epochMilliseconds(now.addingTimeInterval(leaseDuration)),
            createdAtEpochMs: loadClaim(fileURL: fileURL)?.record.createdAtEpochMs ?? nowEpochMs,
            updatedAtEpochMs: nowEpochMs
        )
        guard write(claim, to: fileURL) else {
            return nil
        }
        return ClaimLease(fileName: fileURL.lastPathComponent, fileURL: fileURL, record: claim)
    }

    func markCompleted(_ lease: ClaimLease, now: Date = Date()) async {
        let deliveryId = lease.record.deliveryId
        guard let directoryURL = claimsDirectoryURL() else { return }
        guard await acquireMutationLock(deliveryId: deliveryId, directoryURL: directoryURL, now: now) else {
            return
        }
        defer {
            releaseMutationLock(deliveryId: deliveryId, directoryURL: directoryURL)
        }
        let fileURL = directoryURL.appendingPathComponent(
            Self.claimFileName(deliveryId: deliveryId),
            isDirectory: false
        )
        let completed = StoredClaim(
            schemaVersion: Self.schemaVersion,
            deliveryId: deliveryId,
            state: .completed,
            owner: normalizedText(lease.record.owner),
            leaseUntilEpochMs: nil,
            createdAtEpochMs: loadClaim(fileURL: fileURL)?.record.createdAtEpochMs ?? lease.record.createdAtEpochMs,
            updatedAtEpochMs: Self.epochMilliseconds(now)
        )
        _ = write(completed, to: fileURL)
    }

    func releaseLease(_ lease: ClaimLease, now: Date = Date()) async {
        let deliveryId = lease.record.deliveryId
        guard let directoryURL = claimsDirectoryURL() else { return }
        guard await acquireMutationLock(deliveryId: deliveryId, directoryURL: directoryURL, now: now) else {
            return
        }
        defer {
            releaseMutationLock(deliveryId: deliveryId, directoryURL: directoryURL)
        }
        let fileURL = directoryURL.appendingPathComponent(
            Self.claimFileName(deliveryId: deliveryId),
            isDirectory: false
        )
        try? fileManager.removeItem(at: fileURL)
    }

    func waitForPeerCompletion(
        deliveryId: String,
        timeout: TimeInterval,
        pollInterval: TimeInterval = 0.05,
        now: Date = Date()
    ) async -> Bool {
        guard let normalizedDeliveryId = normalizedText(deliveryId) else {
            return false
        }
        let deadline = now.addingTimeInterval(timeout)
        let sleepNanoseconds = UInt64(max(0.01, pollInterval) * 1_000_000_000)
        var current = now
        while current <= deadline {
            switch claimState(deliveryId: normalizedDeliveryId, now: current) {
            case .completed:
                return true
            case .claimed:
                do {
                    try await Task.sleep(nanoseconds: sleepNanoseconds)
                } catch {
                    return false
                }
                current = Date()
            case .available:
                return false
            }
        }
        return claimState(deliveryId: normalizedDeliveryId, now: Date()) == .completed
    }

    private func claimsDirectoryURL() -> URL? {
        guard let containerURL = AppConstants.appGroupContainerURL(
            fileManager: fileManager,
            identifier: appGroupIdentifier
        ) else {
            return nil
        }
        return containerURL
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent(Self.directoryName, isDirectory: true)
    }

    private func loadClaim(fileURL: URL) -> ClaimLease? {
        guard let data = try? Data(contentsOf: fileURL),
              let claim = try? decoder.decode(StoredClaim.self, from: data)
        else {
            return nil
        }
        return ClaimLease(fileName: fileURL.lastPathComponent, fileURL: fileURL, record: claim)
    }

    private func claimState(deliveryId: String, now: Date) -> ClaimState {
        guard let directoryURL = claimsDirectoryURL() else {
            return .available
        }
        let fileURL = directoryURL.appendingPathComponent(
            Self.claimFileName(deliveryId: deliveryId),
            isDirectory: false
        )
        guard let current = loadClaim(fileURL: fileURL) else {
            return .available
        }
        let nowEpochMs = Self.epochMilliseconds(now)
        switch current.record.state {
        case .completed:
            return isCompletedClaimFresh(current.record, nowEpochMs: nowEpochMs) ? .completed : .available
        case .claimed:
            if let leaseUntilEpochMs = current.record.leaseUntilEpochMs,
               leaseUntilEpochMs > nowEpochMs
            {
                return .claimed
            }
            return .available
        }
    }

    private func write(_ claim: StoredClaim, to fileURL: URL) -> Bool {
        guard let data = try? encoder.encode(claim) else {
            return false
        }
        let directoryURL = fileURL.deletingLastPathComponent()
        let tempURL = directoryURL.appendingPathComponent(
            ".\(fileURL.lastPathComponent).tmp-\(UUID().uuidString.lowercased())",
            isDirectory: false
        )
        do {
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            try data.write(to: tempURL, options: [])
            if fileManager.fileExists(atPath: fileURL.path) {
                _ = try fileManager.replaceItemAt(
                    fileURL,
                    withItemAt: tempURL,
                    backupItemName: nil,
                    options: [.usingNewMetadataOnly]
                )
            } else {
                try fileManager.moveItem(at: tempURL, to: fileURL)
            }
            return true
        } catch {
            try? fileManager.removeItem(at: tempURL)
            return false
        }
    }

    private func acquireMutationLock(
        deliveryId: String,
        directoryURL: URL,
        now: Date
    ) async -> Bool {
        let lockURL = directoryURL.appendingPathComponent(
            Self.lockFileName(deliveryId: deliveryId),
            isDirectory: false
        )

        do {
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        } catch {
            return false
        }

        do {
            try fileManager.createDirectory(at: lockURL, withIntermediateDirectories: false)
            return true
        } catch {
            guard let attributes = try? fileManager.attributesOfItem(atPath: lockURL.path),
                  let modifiedAt = attributes[.modificationDate] as? Date
            else {
                return false
            }
            guard now.timeIntervalSince(modifiedAt) >= Self.mutationLockStaleAge else {
                return false
            }
            try? fileManager.removeItem(at: lockURL)
            do {
                try fileManager.createDirectory(at: lockURL, withIntermediateDirectories: false)
                return true
            } catch {
                return false
            }
        }
    }

    private func releaseMutationLock(deliveryId: String, directoryURL: URL) {
        let lockURL = directoryURL.appendingPathComponent(
            Self.lockFileName(deliveryId: deliveryId),
            isDirectory: false
        )
        try? fileManager.removeItem(at: lockURL)
    }

    private func isCompletedClaimFresh(_ record: StoredClaim, nowEpochMs: Int64) -> Bool {
        nowEpochMs - record.updatedAtEpochMs < Int64((Self.completedRetention * 1_000).rounded())
    }

    private func normalizedText(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func claimFileName(deliveryId: String) -> String {
        "\(filesystemComponent(deliveryId)).\(fileExtension)"
    }

    private static func lockFileName(deliveryId: String) -> String {
        "\(filesystemComponent(deliveryId)).\(lockExtension)"
    }

    private static func filesystemComponent(_ value: String) -> String {
        Data(value.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func epochMilliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000).rounded())
    }

}
