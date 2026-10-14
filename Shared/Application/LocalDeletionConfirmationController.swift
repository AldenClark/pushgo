import Foundation
import Observation

/// Owns only a foreground confirmation draft. Accepted local deletions commit directly.
@MainActor
@Observable
final class LocalDeletionConfirmationController {
    struct Presentation: Identifiable {
        let id: UUID
        let summary: String
        var hostID: UUID?
    }

    private let dataStore: LocalDataStore
    private let configuration: @MainActor () -> ServerConfig?
    private let reconcileCleanup: @MainActor () async -> Void
    private let failure: @MainActor (Error) -> Void
    @ObservationIgnored private var hosts: [UUID] = []
    @ObservationIgnored private var confirmation: LocalDeletionConfirmation?
    @ObservationIgnored private var capturedConfiguration: ServerConfig?
    @ObservationIgnored private var onDeleted: (@MainActor () -> Void)?
    @ObservationIgnored private var isPreparing = false
    private(set) var pendingConfirmation: Presentation?
    private(set) var isExecuting = false

    init(
        dataStore: LocalDataStore,
        configuration: @escaping @MainActor () -> ServerConfig?,
        reconcileCleanup: @escaping @MainActor () async -> Void,
        failure: @escaping @MainActor (Error) -> Void
    ) {
        self.dataStore = dataStore
        self.configuration = configuration
        self.reconcileCleanup = reconcileCleanup
        self.failure = failure
    }

    func registerHost(_ id: UUID) {
        hosts.removeAll { $0 == id }
        hosts.append(id)
        if pendingConfirmation?.hostID == nil {
            pendingConfirmation?.hostID = id
        }
    }

    func unregisterHost(_ id: UUID) {
        hosts.removeAll { $0 == id }
        if let pending = pendingConfirmation, pending.hostID == id {
            cancel(id: pending.id)
        }
    }

    func request(
        summary: String,
        intent: PendingLocalDeletionIntent,
        onDeleted: (@MainActor () -> Void)? = nil
    ) async {
        guard !isPreparing, !isExecuting, pendingConfirmation == nil else { return }
        isPreparing = true
        defer { isPreparing = false }
        let config = configuration()?.normalized()
        let host = hosts.last
        do {
            let target = try await dataStore.prepareLocalDeletion(intent: intent)
            guard config == configuration()?.normalized(), host == nil || hosts.contains(host!) else {
                throw Self.changedTargetError()
            }
            confirmation = target
            capturedConfiguration = config
            self.onDeleted = onDeleted
            pendingConfirmation = Presentation(id: target.id, summary: target.summary.isEmpty ? summary : target.summary, hostID: host ?? hosts.last)
        } catch {
            failure(error)
        }
    }

    func cancel(id: UUID) {
        guard pendingConfirmation?.id == id else { return }
        clearDraft()
    }

    func confirm(id: UUID) async {
        guard !isExecuting, pendingConfirmation?.id == id, let confirmation,
              confirmation.id == id else { return }
        let expectedConfiguration = capturedConfiguration
        let completion = onDeleted
        // Consume before the first suspension, so duplicate and stale button actions do nothing.
        clearDraft()
        isExecuting = true
        defer { isExecuting = false }
        do {
            guard expectedConfiguration == configuration()?.normalized() else {
                throw Self.changedTargetError()
            }
            _ = try await dataStore.deleteConfirmedLocalData(confirmation)
            await reconcileCleanup()
            completion?()
        } catch {
            failure(error)
        }
    }

    private func clearDraft() {
        pendingConfirmation = nil
        confirmation = nil
        capturedConfiguration = nil
        onDeleted = nil
    }

    private static func changedTargetError() -> AppError {
        AppError.typedLocal(
            code: "local_deletion_target_changed",
            category: .validation,
            message: LocalizationManager.shared.localized("operation_failed"),
            detail: "The deletion target or active configuration changed before confirmation."
        )
    }
}
