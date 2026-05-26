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
        let scope: Scope
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
        let deletion: PendingDeletion
        let commit: CommitOperation
        let onCompletion: CompletionHandler?
    }

    private let timeout: TimeInterval
    @ObservationIgnored private var commitTask: Task<Void, Never>?
    @ObservationIgnored private var scheduledDeletion: ScheduledDeletion?

    private(set) var pendingDeletion: PendingDeletion?

    init(timeout: TimeInterval = 5) {
        self.timeout = timeout
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
        await commitCurrentIfNeeded()

        let deletion = PendingDeletion(
            id: UUID(),
            summary: summary,
            undoLabel: undoLabel,
            deadline: Date().addingTimeInterval(timeout),
            scope: scope
        )
        scheduledDeletion = ScheduledDeletion(
            deletion: deletion,
            commit: commit,
            onCompletion: onCompletion
        )
        pendingDeletion = deletion
        armCommitTask(for: deletion)
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

    func undoCurrent() {
        commitTask?.cancel()
        commitTask = nil
        scheduledDeletion = nil
        pendingDeletion = nil
    }

    func commitCurrentIfNeeded() async {
        guard let scheduledDeletion else { return }
        await commitScheduledDeletion(expectedID: scheduledDeletion.deletion.id)
    }

    func suppressesMessage(id: UUID, channelId: String?) -> Bool {
        pendingDeletion?.scope.suppressesMessage(id: id, channelId: channelId) ?? false
    }

    func suppressesEvent(id: String, channelId: String?) -> Bool {
        pendingDeletion?.scope.suppressesEvent(id: id, channelId: channelId) ?? false
    }

    func suppressesThing(id: String, channelId: String?) -> Bool {
        pendingDeletion?.scope.suppressesThing(id: id, channelId: channelId) ?? false
    }

    private func armCommitTask(for deletion: PendingDeletion) {
        commitTask?.cancel()
        commitTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .seconds(timeout))
            guard !Task.isCancelled else { return }
            await self.commitScheduledDeletion(expectedID: deletion.id)
        }
    }

    private func commitScheduledDeletion(expectedID: UUID) async {
        guard let scheduledDeletion, scheduledDeletion.deletion.id == expectedID else { return }

        commitTask?.cancel()
        commitTask = nil

        do {
            try await scheduledDeletion.commit()
            clearScheduledDeletionIfCurrent(expectedID: expectedID)
            scheduledDeletion.onCompletion?(.success(()))
        } catch {
            clearScheduledDeletionIfCurrent(expectedID: expectedID)
            scheduledDeletion.onCompletion?(.failure(error))
        }
    }

    private func clearScheduledDeletionIfCurrent(expectedID: UUID) {
        guard scheduledDeletion?.deletion.id == expectedID else { return }
        scheduledDeletion = nil
        pendingDeletion = nil
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
