import Foundation
import Observation

@MainActor
@Observable
final class PendingLocalDeletionController {
    struct PendingDeletion: Identifiable, Equatable {
        let id: UUID
        let summary: String
        let undoLabel: String
        let deadline: Date
        let frozenTimeRemaining: TimeInterval
        let isCountdownActive: Bool
        let scope: Scope

        func timeRemaining(at date: Date) -> TimeInterval {
            if isCountdownActive {
                return max(0, deadline.timeIntervalSince(date))
            }
            return max(0, frozenTimeRemaining)
        }
    }

    struct Scope: Equatable {
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

    typealias CommitOperation = @Sendable () async throws -> Void
    typealias CompletionHandler = @MainActor (Result<Void, Error>) -> Void

    private struct ScheduledDeletion {
        let id: UUID
        let summary: String
        let undoLabel: String
        let scope: Scope
        let commit: CommitOperation
        let onCompletion: CompletionHandler?
        var remainingDuration: TimeInterval
        var deadline: Date?
    }

    private let timeout: TimeInterval
    @ObservationIgnored private var commitTask: Task<Void, Never>?
    @ObservationIgnored private var queuedDeletions: [ScheduledDeletion] = []
    @ObservationIgnored private var committingScopes: [UUID: Scope] = [:]
    @ObservationIgnored private var interactionActive = true

    private(set) var pendingDeletion: PendingDeletion?
    private(set) var effectiveScope: Scope = Scope()

    init(timeout: TimeInterval = 5) {
        self.timeout = max(0, timeout)
    }

    deinit {
        commitTask?.cancel()
    }

    func schedule(
        summary: String,
        undoLabel: String,
        scope: Scope,
        commit: @escaping CommitOperation,
        onCompletion: CompletionHandler? = nil
    ) async {
        queuedDeletions.append(ScheduledDeletion(
            id: UUID(),
            summary: summary,
            undoLabel: undoLabel,
            scope: scope,
            commit: commit,
            onCompletion: onCompletion,
            remainingDuration: timeout,
            deadline: nil
        ))

        if queuedDeletions.count == 1 {
            activateCurrentDeletion()
        } else {
            publishEffectiveScope()
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
        scope: ([Item]) -> Scope,
        commit: @escaping @Sendable ([ID]) async throws -> Void,
        onCompletion: CompletionHandler? = nil
    ) async -> (items: [Item], scope: Scope)? {
        let uniqueItems = uniquePreservingOrder(items, identity: identity)
        guard !uniqueItems.isEmpty else { return nil }
        let uniqueIDs = uniqueItems.map(identity)

        let summary: String
        if uniqueItems.count == 1, let first = uniqueItems.first {
            let resolvedTitle = title(first).trimmingCharacters(in: .whitespacesAndNewlines)
            summary = resolvedTitle.isEmpty ? fallbackSingleSummary : resolvedTitle
        } else {
            summary = "\(uniqueItems.count) × \(multipleSummaryTitle)"
        }

        let resolvedScope = scope(uniqueItems)
        await schedule(
            summary: summary,
            undoLabel: undoLabel,
            scope: resolvedScope,
            commit: {
                try await commit(uniqueIDs)
            },
            onCompletion: onCompletion
        )
        return (uniqueItems, resolvedScope)
    }

    func setInteractionActive(_ active: Bool) {
        guard interactionActive != active else { return }
        interactionActive = active
        if active {
            activateCurrentDeletion()
        } else {
            pauseCurrentDeletion()
        }
    }

    func undoCurrent() {
        guard !queuedDeletions.isEmpty else { return }
        commitTask?.cancel()
        commitTask = nil
        queuedDeletions.removeFirst()
        activateCurrentDeletion()
    }

    func commitCurrentIfNeeded() async {
        guard let expectedID = queuedDeletions.first?.id else { return }
        await commitScheduledDeletion(expectedID: expectedID, cancelCountdownTask: true)
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

    private func activateCurrentDeletion() {
        commitTask?.cancel()
        commitTask = nil
        guard !queuedDeletions.isEmpty else {
            pendingDeletion = nil
            publishEffectiveScope()
            return
        }

        let now = Date()
        if interactionActive {
            queuedDeletions[0].deadline = now.addingTimeInterval(queuedDeletions[0].remainingDuration)
        } else {
            queuedDeletions[0].deadline = nil
        }
        publishPendingDeletion(now: now)
        publishEffectiveScope()
        guard interactionActive else { return }
        armCommitTask(for: queuedDeletions[0])
    }

    private func pauseCurrentDeletion() {
        commitTask?.cancel()
        commitTask = nil
        guard !queuedDeletions.isEmpty else { return }
        let now = Date()
        if let deadline = queuedDeletions[0].deadline {
            queuedDeletions[0].remainingDuration = max(0, deadline.timeIntervalSince(now))
        }
        queuedDeletions[0].deadline = nil
        publishPendingDeletion(now: now)
    }

    private func publishPendingDeletion(now: Date = Date()) {
        guard let entry = queuedDeletions.first else {
            pendingDeletion = nil
            return
        }
        pendingDeletion = PendingDeletion(
            id: entry.id,
            summary: entry.summary,
            undoLabel: entry.undoLabel,
            deadline: entry.deadline ?? now.addingTimeInterval(entry.remainingDuration),
            frozenTimeRemaining: entry.remainingDuration,
            isCountdownActive: interactionActive,
            scope: entry.scope
        )
    }

    private func armCommitTask(for deletion: ScheduledDeletion) {
        let duration = deletion.remainingDuration
        commitTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled else { return }
            await self.commitScheduledDeletion(expectedID: deletion.id, cancelCountdownTask: false)
        }
    }

    private func commitScheduledDeletion(
        expectedID: UUID,
        cancelCountdownTask: Bool
    ) async {
        guard let scheduledDeletion = claimCurrentDeletion(
            expectedID: expectedID,
            cancelCountdownTask: cancelCountdownTask
        ) else { return }

        let result: Result<Void, Error>
        do {
            try await scheduledDeletion.commit()
            result = .success(())
        } catch {
            result = .failure(error)
        }

        committingScopes.removeValue(forKey: expectedID)
        publishEffectiveScope()
        scheduledDeletion.onCompletion?(result)
    }

    private func claimCurrentDeletion(
        expectedID: UUID,
        cancelCountdownTask: Bool
    ) -> ScheduledDeletion? {
        guard queuedDeletions.first?.id == expectedID else { return nil }
        if cancelCountdownTask {
            commitTask?.cancel()
        }
        commitTask = nil
        let entry = queuedDeletions.removeFirst()
        committingScopes[entry.id] = entry.scope
        activateCurrentDeletion()
        return entry
    }

    private func publishEffectiveScope() {
        let scopes = queuedDeletions.map(\.scope) + Array(committingScopes.values)
        effectiveScope = Scope(
            messageIDs: scopes.reduce(into: Set<UUID>()) { $0.formUnion($1.messageIDs) },
            eventIDs: scopes.reduce(into: Set<String>()) { $0.formUnion($1.eventIDs) },
            thingIDs: scopes.reduce(into: Set<String>()) { $0.formUnion($1.thingIDs) },
            channelIDs: scopes.reduce(into: Set<String>()) { $0.formUnion($1.channelIDs) }
        )
    }

    private func uniquePreservingOrder<Item, ID: Hashable>(
        _ items: [Item],
        identity: (Item) -> ID
    ) -> [Item] {
        var seen = Set<ID>()
        var result: [Item] = []
        result.reserveCapacity(items.count)
        for item in items where seen.insert(identity(item)).inserted {
            result.append(item)
        }
        return result
    }
}
