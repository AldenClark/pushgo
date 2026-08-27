import Foundation
import Observation

struct PendingLocalDeletionScope: Codable, Equatable, Hashable, Sendable {
    let messageIDs: Set<UUID>
    let eventIDs: Set<String>
    let thingIDs: Set<String>
    let channelIDs: Set<String>

    init(
        messageIDs: Set<UUID> = [],
        eventIDs: Set<String> = [],
        thingIDs: Set<String> = [],
        channelIDs: Set<String> = []
    ) {
        self.messageIDs = messageIDs
        self.eventIDs = eventIDs
        self.thingIDs = thingIDs
        self.channelIDs = Set(channelIDs.compactMap(Self.normalizeChannelID))
    }

    func suppressesMessage(id: UUID, channelId: String?) -> Bool {
        messageIDs.contains(id) || containsChannel(channelId)
    }

    func suppressesEvent(id: String, channelId: String?) -> Bool {
        eventIDs.contains(id) || containsChannel(channelId)
    }

    func suppressesThing(id: String, channelId: String?) -> Bool {
        thingIDs.contains(id) || containsChannel(channelId)
    }

    private func containsChannel(_ channelId: String?) -> Bool {
        guard let normalized = Self.normalizeChannelID(channelId) else { return false }
        return channelIDs.contains(normalized)
    }

    private static func normalizeChannelID(_ channelId: String?) -> String? {
        let trimmed = channelId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}

enum PendingLocalDeletionIntent: Codable, Equatable, Sendable {
    case messages(ids: [UUID])
    case events(ids: [String])
    case things(ids: [String])
    case channelHistory(channelID: String, expectedGateway: String, expectedUpdatedAt: Date)

    var scope: PendingLocalDeletionScope {
        switch self {
        case let .messages(ids):
            return PendingLocalDeletionScope(messageIDs: Set(ids))
        case let .events(ids):
            return PendingLocalDeletionScope(eventIDs: Set(ids))
        case let .things(ids):
            return PendingLocalDeletionScope(thingIDs: Set(ids))
        case let .channelHistory(channelID, _, _):
            return PendingLocalDeletionScope(channelIDs: [channelID])
        }
    }

    var deduplicationKey: String {
        switch self {
        case let .messages(ids):
            return "messages:" + Set(ids).map(\.uuidString).sorted().joined(separator: ",")
        case let .events(ids):
            return "events:" + normalized(ids).sorted().joined(separator: ",")
        case let .things(ids):
            return "things:" + normalized(ids).sorted().joined(separator: ",")
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

enum PendingLocalDeletionState: String, Codable, Equatable, Sendable {
    case queued
    case undoable
    case executing
    case retryWaiting = "retry_waiting"
    case cleanupPending = "cleanup_pending"
    case reconciliationRequired = "reconciliation_required"

    var suppressesContent: Bool {
        self != .reconciliationRequired
    }
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
    typealias Scope = PendingLocalDeletionScope
    typealias CompletionHandler = @MainActor (Result<Void, Error>) -> Void
    typealias ChannelCommitHandler = @Sendable (
        _ record: PendingLocalDeletionRecord,
        _ leaseOwner: String
    ) async throws -> PendingLocalDeletionCleanup
    typealias CleanupHandler = @Sendable (PendingLocalDeletionCleanup) async -> Void
    typealias FailureHandler = @MainActor (Error) -> Void

    struct PendingDeletion: Identifiable, Equatable {
        let id: UUID
        let summary: String
        let undoLabel: String
        let deadline: Date
        let scope: Scope

        func timeRemaining(at date: Date) -> TimeInterval {
            max(0, deadline.timeIntervalSince(date))
        }
    }

    private let dataStore: LocalDataStore
    private let timeout: TimeInterval
    private let leaseDuration: TimeInterval
    private let channelCommitHandler: ChannelCommitHandler?
    private let cleanupHandler: CleanupHandler?
    private let failureHandler: FailureHandler?
    private let dateProvider: @Sendable () -> Date
    private let leaseOwner = UUID().uuidString

    @ObservationIgnored private var wakeTask: Task<Void, Never>?
    @ObservationIgnored private var drainTask: Task<Void, Never>?
    @ObservationIgnored private var records: [PendingLocalDeletionRecord] = []
    @ObservationIgnored private var completionHandlers: [UUID: CompletionHandler] = [:]

    private(set) var pendingDeletion: PendingDeletion?
    private(set) var effectiveScope = Scope()
    private(set) var isUndoInFlight = false

    init(
        dataStore: LocalDataStore,
        timeout: TimeInterval = 5,
        leaseDuration: TimeInterval = 30,
        dateProvider: @escaping @Sendable () -> Date = { Date() },
        channelCommitHandler: ChannelCommitHandler? = nil,
        cleanupHandler: CleanupHandler? = nil,
        failureHandler: FailureHandler? = nil
    ) {
        self.dataStore = dataStore
        self.timeout = max(0, timeout)
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

    @discardableResult
    func schedule(
        summary: String,
        undoLabel: String,
        intent: PendingLocalDeletionIntent,
        onCompletion: CompletionHandler? = nil
    ) async -> Bool {
        do {
            let record = try await dataStore.enqueuePendingLocalDeletion(
                summary: summary,
                undoLabel: undoLabel,
                intent: intent,
                timeout: timeout,
                now: dateProvider()
            )
            if let onCompletion {
                completionHandlers[record.id] = onCompletion
            }
            await reloadAndArmWakeTask()
            return true
        } catch {
            failureHandler?(error)
            onCompletion?(.failure(error))
            return false
        }
    }

    @discardableResult
    func scheduleItems<Item, ID: Hashable & Sendable>(
        _ items: [Item],
        identity: (Item) -> ID,
        title: (Item) -> String,
        fallbackSingleSummary: String,
        multipleSummaryTitle: String,
        undoLabel: String,
        intent: ([ID]) -> PendingLocalDeletionIntent,
        onCompletion: CompletionHandler? = nil
    ) async -> [Item]? {
        let uniqueItems = uniquePreservingOrder(items, identity: identity)
        guard !uniqueItems.isEmpty else { return nil }
        let summary: String
        if uniqueItems.count == 1, let first = uniqueItems.first {
            let resolved = title(first).trimmingCharacters(in: .whitespacesAndNewlines)
            summary = resolved.isEmpty ? fallbackSingleSummary : resolved
        } else {
            summary = "\(uniqueItems.count) × \(multipleSummaryTitle)"
        }
        let scheduled = await schedule(
            summary: summary,
            undoLabel: undoLabel,
            intent: intent(uniqueItems.map(identity)),
            onCompletion: onCompletion
        )
        return scheduled ? uniqueItems : nil
    }

    func restoreAndReconcile() async {
        await restorePendingState()
        await processDueDeletions()
    }

    /// Restores the suppression scope needed to render cached content safely.
    /// Executing due deletions is intentionally separate so launch can present
    /// the restored local state before reconciliation performs I/O or networking.
    func restorePendingState() async {
        await reloadAndArmWakeTask()
    }

    func sceneBecameActive() async {
        await reloadAndArmWakeTask()
        await processDueDeletions()
    }

    func commitAllForBackground() async {
        do {
            try await dataStore.forcePendingLocalDeletionsDue(now: dateProvider())
            await reloadAndArmWakeTask()
            await processDueDeletions()
        } catch {
            failureHandler?(error)
        }
    }

    func cancelExecution() {
        drainTask?.cancel()
    }

    func undoCurrent() {
        guard let id = pendingDeletion?.id, !isUndoInFlight else { return }
        isUndoInFlight = true
        Task { [weak self] in
            guard let self else { return }
            defer { self.isUndoInFlight = false }
            do {
                let undone = try await self.dataStore.undoPendingLocalDeletion(
                    id: id,
                    timeout: self.timeout,
                    now: self.dateProvider()
                )
                if undone { self.completionHandlers.removeValue(forKey: id) }
                await self.reloadAndArmWakeTask()
                if !undone { await self.processDueDeletions() }
            } catch {
                self.failureHandler?(error)
                await self.reloadAndArmWakeTask()
            }
        }
    }

    func commitCurrentIfNeeded() async {
        guard let id = pendingDeletion?.id else { return }
        do {
            _ = try await dataStore.forcePendingLocalDeletionDue(
                id: id,
                timeout: timeout,
                now: dateProvider()
            )
        } catch {
            failureHandler?(error)
        }
        await reloadAndArmWakeTask()
        await processDueDeletions()
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

    func suppressesMessage(id: UUID, channelId: String?) -> Bool {
        effectiveScope.suppressesMessage(id: id, channelId: channelId)
    }

    func suppressesEvent(id: String, channelId: String?) -> Bool {
        effectiveScope.suppressesEvent(id: id, channelId: channelId)
    }

    func suppressesThing(id: String, channelId: String?) -> Bool {
        effectiveScope.suppressesThing(id: id, channelId: channelId)
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
                    timeout: timeout,
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
            case .channelHistory:
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
            if let appError, Self.abandonsIntent(errorCode: appError.code) {
                try? await dataStore.abandonClaimedPendingLocalDeletion(id: record.id, owner: leaseOwner)
                completionHandlers.removeValue(forKey: record.id)?(.failure(error))
                failureHandler?(error)
                return true
            }
            if let appError, appError.code == "channel_removal_reconciliation_required" {
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
            completionHandlers.removeValue(forKey: record.id)?(.failure(error))
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
            completionHandlers.removeValue(forKey: record.id)?(.success(()))
            return true
        } catch {
            failureHandler?(error)
            return false
        }
    }

    private func reloadAndArmWakeTask() async {
        do {
            records = try await dataStore.loadPendingLocalDeletions(now: dateProvider())
            publishState()
            armWakeTask()
        } catch {
            records = []
            publishState()
            wakeTask?.cancel()
            wakeTask = nil
            failureHandler?(error)
        }
    }

    private func publishState() {
        if let current = records.first(where: { $0.state == .undoable }), let deadline = current.deadline {
            pendingDeletion = PendingDeletion(
                id: current.id,
                summary: current.summary,
                undoLabel: current.undoLabel,
                deadline: deadline,
                scope: current.intent.scope
            )
        } else {
            pendingDeletion = nil
        }
        let scopes = records.filter { $0.state.suppressesContent }.map { $0.intent.scope }
        effectiveScope = Scope(
            messageIDs: scopes.reduce(into: Set<UUID>()) { $0.formUnion($1.messageIDs) },
            eventIDs: scopes.reduce(into: Set<String>()) { $0.formUnion($1.eventIDs) },
            thingIDs: scopes.reduce(into: Set<String>()) { $0.formUnion($1.thingIDs) },
            channelIDs: scopes.reduce(into: Set<String>()) { $0.formUnion($1.channelIDs) }
        )
    }

    private func armWakeTask() {
        wakeTask?.cancel()
        wakeTask = nil
        let now = dateProvider()
        let dates = records.compactMap { record -> Date? in
            switch record.state {
            case .undoable: return record.deadline
            case .retryWaiting: return record.retryAfter
            case .executing: return record.leaseUntil
            case .cleanupPending: return now.addingTimeInterval(2)
            case .queued, .reconciliationRequired: return nil
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

    private static func abandonsIntent(errorCode: String) -> Bool {
        [
            "gateway_changed_during_channel_removal",
            "channel_subscription_changed_during_removal",
            "channel_password_missing",
            "E_NO_SERVER",
        ].contains(errorCode)
    }

    private func uniquePreservingOrder<Item, ID: Hashable>(
        _ items: [Item],
        identity: (Item) -> ID
    ) -> [Item] {
        var seen = Set<ID>()
        return items.filter { seen.insert(identity($0)).inserted }
    }
}
