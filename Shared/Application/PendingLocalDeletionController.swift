import Foundation
import Observation

struct PendingChannelRemovalTarget: Codable, Equatable, Sendable {
    let channelID: String
    let originalConfig: ServerConfig
    let expectedUpdatedAt: Date
    let password: String
    var originalDeviceKey: String? = nil
    var historySnapshot: [String]? = nil
    var keepHistory: Bool
}

enum PendingLocalDeletionIntent: Codable, Equatable, Sendable {
    case messages(ids: [UUID])
    case events(ids: [String])
    case things(ids: [String])
    case channelHistory(channelID: String, expectedGateway: String, expectedUpdatedAt: Date)
    case channelRemoval(target: PendingChannelRemovalTarget)

    var deduplicationKey: String {
        switch self {
        case let .messages(ids):
            return "messages:" + Set(ids).map(\.uuidString).sorted().joined(separator: ",")
        case let .events(ids):
            return "events:" + normalized(ids).sorted().joined(separator: ",")
        case let .things(ids):
            return "things:" + normalized(ids).sorted().joined(separator: ",")
        case let .channelRemoval(target):
            return "remote-channel:\(target.originalConfig.gatewayKey):\(target.channelID):\(target.expectedUpdatedAt.timeIntervalSince1970):\(target.keepHistory)"
        case let .channelHistory(channelID, gateway, updatedAt):
            let normalizedGateway = gateway.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedChannel = channelID.trimmingCharacters(in: .whitespacesAndNewlines)
            return "channel:\(normalizedGateway):\(normalizedChannel):\(updatedAt.timeIntervalSince1970)"
        }
    }

    private func normalized(_ values: [String]) -> Set<String> {
        Set(values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
    }
}

/// An ephemeral, read-only confirmation. Its snapshot is validated inside the deletion transaction.
struct LocalDeletionConfirmation: Sendable {
    let id = UUID()
    let intent: PendingLocalDeletionIntent
    let snapshot: [String]
    let summary: String
    let persistedConfiguration: ServerConfig?
}

enum PendingLocalDeletionState: String, Codable, Equatable, Sendable {
    case queued
    case undoable
    case executing
    case retryWaiting = "retry_waiting"
    case cleanupPending = "cleanup_pending"
    case reconciliationRequired = "reconciliation_required"

}

struct PendingLocalDeletionCleanup: Codable, Equatable, Sendable {
    var messageIDs: [UUID] = []
    var notificationRequestIDs: [String] = []
    var imageURLs: [URL] = []
    var eventIDs: [String] = []
    var thingIDs: [String] = []
    var rebuildSystemSearchIndex = false
    var deletedRecordCount = 0
}

struct PendingLocalDeletionRecord: Codable, Equatable, Identifiable, Sendable {
    let sequence: Int64
    let id: UUID
    let summary: String
    let undoLabel: String
    let intent: PendingLocalDeletionIntent
    let state: PendingLocalDeletionState
    let createdAt: Date
    let deadline: Date?
    let retryAfter: Date?
    let attemptCount: Int
    let leaseOwner: String?
    let leaseUntil: Date?
    let cleanup: PendingLocalDeletionCleanup?
    let lastErrorCode: String?
}

@MainActor
@Observable
final class PendingLocalDeletionController {
    typealias ChannelCommitHandler = @Sendable (
        _ record: PendingLocalDeletionRecord,
        _ leaseOwner: String
    ) async throws -> PendingLocalDeletionCleanup
    typealias CleanupHandler = @Sendable (PendingLocalDeletionCleanup) async -> Void
    typealias FailureHandler = @MainActor (Error) -> Void

    private let dataStore: LocalDataStore
    private let leaseDuration: TimeInterval
    private let channelCommitHandler: ChannelCommitHandler?
    private let cleanupHandler: CleanupHandler?
    private let failureHandler: FailureHandler?
    private let dateProvider: @Sendable () -> Date
    private let leaseOwner = UUID().uuidString

    @ObservationIgnored private var wakeTask: Task<Void, Never>?
    @ObservationIgnored private var drainTask: Task<Void, Never>?
    @ObservationIgnored private var records: [PendingLocalDeletionRecord] = []

    private(set) var isDormant = false
    private(set) var recoveryRequiredCount = 0
    private(set) var recoveryErrorCodes: [String] = []

    init(
        dataStore: LocalDataStore,
        leaseDuration: TimeInterval = 30,
        dateProvider: @escaping @Sendable () -> Date = { Date() },
        channelCommitHandler: ChannelCommitHandler? = nil,
        cleanupHandler: CleanupHandler? = nil,
        failureHandler: FailureHandler? = nil
    ) {
        self.dataStore = dataStore
        self.leaseDuration = max(1, leaseDuration)
        self.dateProvider = dateProvider
        self.channelCommitHandler = channelCommitHandler
        self.cleanupHandler = cleanupHandler
        self.failureHandler = failureHandler
    }

    deinit {
        wakeTask?.cancel()
        drainTask?.cancel()
    }

    func restoreAndReconcile() async {
        await restorePendingState()
        await processDueDeletions()
    }

    /// Legacy entry point only: old accepted intents become due immediately.
    func restorePendingState() async {
        guard !isDormant else { return }
        do {
            try await dataStore.forcePendingLocalDeletionsDue(now: dateProvider())
            await reloadAndArmWakeTask()
        } catch { failureHandler?(error) }
    }

    func sceneBecameActive() async {
        guard !isDormant else { return }
        await restoreAndReconcile()
    }

    func commitAllForBackground() async {
        guard !isDormant else { return }
        await restoreAndReconcile()
    }

    /// New canonical commits only create cleanup receipts, never delayed deletion intents.
    func reconcileCommittedCleanup() async {
        isDormant = false
        await processDueDeletions()
    }

    func retryRecovery() async {
        do {
            try await dataStore.retryPendingLocalDeletionRecovery(now: dateProvider())
            isDormant = false
            await restoreAndReconcile()
        } catch { failureHandler?(error) }
    }

    func cancelExecution() {
        drainTask?.cancel()
    }

    func processDueDeletions() async {
        if let drainTask {
            await drainTask.value
            return
        }
        let task = Task { [weak self] in
            guard let self else { return }
            await self.drainUntilIdle()
        }
        drainTask = task
        await task.value
        drainTask = nil
    }

    private func drainUntilIdle() async {
        while !Task.isCancelled {
            do {
                if let cleanup = try await dataStore.nextPendingLocalDeletionCleanup() {
                    guard await finishCleanup(cleanup) else { break }
                    continue
                }
                guard let claimed = try await dataStore.claimNextPendingLocalDeletion(
                    owner: leaseOwner,
                    leaseDuration: leaseDuration,
                    now: dateProvider()
                ) else { break }
                await reloadAndArmWakeTask()
                guard await execute(claimed) else { break }
            } catch {
                failureHandler?(error)
                break
            }
        }
        await reloadAndArmWakeTask()
    }

    private func execute(_ record: PendingLocalDeletionRecord) async -> Bool {
        do {
            let cleanup: PendingLocalDeletionCleanup
            switch record.intent {
            case .channelHistory, .channelRemoval:
                guard let channelCommitHandler else {
                    throw AppError.localStore("Channel deletion executor is unavailable.")
                }
                cleanup = try await channelCommitHandler(record, leaseOwner)
            case .messages, .events, .things:
                cleanup = try await dataStore.commitClaimedPendingLocalDeletion(
                    id: record.id,
                    owner: leaseOwner,
                    now: dateProvider()
                )
            }
            return await finishCleanup(record, cleanup: cleanup)
        } catch is CancellationError {
            try? await dataStore.retryClaimedPendingLocalDeletion(
                id: record.id,
                owner: leaseOwner,
                retryAfter: dateProvider(),
                errorCode: "cancelled"
            )
            return false
        } catch {
            let appError = error as? AppError
            if let appError, Self.requiresReconciliation(errorCode: appError.code) {
                try? await dataStore.markPendingLocalDeletionReconciliationRequired(
                    id: record.id,
                    owner: leaseOwner,
                    errorCode: appError.code
                )
            } else {
                let delay = min(300, pow(2, Double(min(record.attemptCount, 8))))
                try? await dataStore.retryClaimedPendingLocalDeletion(
                    id: record.id,
                    owner: leaseOwner,
                    retryAfter: dateProvider().addingTimeInterval(delay),
                    errorCode: appError?.code ?? "pending_deletion_failed"
                )
            }
            failureHandler?(error)
            return true
        }
    }

    private func finishCleanup(
        _ record: PendingLocalDeletionRecord,
        cleanup suppliedCleanup: PendingLocalDeletionCleanup? = nil
    ) async -> Bool {
        guard let cleanup = suppliedCleanup ?? record.cleanup else {
            try? await dataStore.markPendingLocalDeletionReconciliationRequired(
                id: record.id,
                owner: nil,
                errorCode: "missing_cleanup_payload"
            )
            return false
        }
        do {
            try await dataStore.reconcilePendingLocalDeletionCleanup(cleanup)
            await cleanupHandler?(cleanup)
            try await dataStore.completePendingLocalDeletionCleanup(id: record.id)
            return true
        } catch {
            failureHandler?(error)
            return false
        }
    }

    private func reloadAndArmWakeTask() async {
        do {
            records = try await dataStore.loadPendingLocalDeletions(now: dateProvider())
            recoveryRequiredCount = try await dataStore.pendingLocalDeletionRecoveryCount()
            recoveryErrorCodes = try await dataStore.pendingLocalDeletionRecoveryErrorCodes()
            isDormant = records.isEmpty && recoveryRequiredCount == 0
            if recoveryRequiredCount > 0 {
                let key = recoveryErrorCodes.contains("channel_history_changed_during_removal")
                    ? "channel_removal_reconfirmation_required" : "local_deletion_recovery_required"
                failureHandler?(AppError.typedLocal(code: "pending_deletion_recovery_required", category: .local,
                    message: LocalizationManager.shared.localized(key)))
            }
            armWakeTask()
        } catch {
            records = []
            wakeTask?.cancel()
            wakeTask = nil
            failureHandler?(error)
        }
    }

    private func armWakeTask() {
        wakeTask?.cancel()
        wakeTask = nil
        let now = dateProvider()
        let dates = records.compactMap { record -> Date? in
            switch record.state {
            case .undoable, .queued: return now
            case .retryWaiting: return record.retryAfter
            case .executing: return record.leaseUntil
            case .cleanupPending: return now.addingTimeInterval(2)
            case .reconciliationRequired: return nil
            }
        }
        guard let wakeDate = dates.min() else { return }
        let delay = max(0, wakeDate.timeIntervalSince(now))
        wakeTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await self?.processDueDeletions()
        }
    }

    private static func requiresReconciliation(errorCode: String) -> Bool {
        [
            "channel_history_changed_during_removal",
            "channel_removal_reconciliation_required",
            "gateway_changed_during_channel_removal",
            "channel_subscription_changed_during_removal",
            "channel_password_missing",
            "E_NO_SERVER",
        ].contains(errorCode)
    }

}
