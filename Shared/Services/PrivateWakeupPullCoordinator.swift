import Foundation

struct PrivateWakeupPullItem: Sendable {
    let deliveryId: String
    let payload: [String: String]
}

private struct PrivateWakeupAckDrainRequest: Sendable {
    let dataStore: LocalDataStore
    let limit: Int
    let acknowledge: @Sendable ([String]) async throws -> Set<String>
}

private actor PrivateWakeupAckDrainScheduler {
    private var latestRequest: PrivateWakeupAckDrainRequest?
    private var runningTask: Task<Void, Never>?
    private var rerunRequested = false

    func schedule(_ request: PrivateWakeupAckDrainRequest) {
        latestRequest = request
        guard runningTask == nil else {
            rerunRequested = true
            return
        }
        runningTask = Task(priority: .utility) { [weak self] in
            await self?.runLoop()
        }
    }

    private func runLoop() async {
        while let request = latestRequest {
            rerunRequested = false
            let outcome = await PrivateWakeupAckOutboxWorker.drainPendingAcks(
                dataStore: request.dataStore,
                limit: request.limit,
                acknowledge: request.acknowledge
            )
            if outcome == .failed {
                try? await Task.sleep(for: .seconds(2))
            }
            if !rerunRequested && outcome != .partial {
                runningTask = nil
                return
            }
        }
        runningTask = nil
    }
}

enum PrivateWakeupAckOutboxWorker {
    private static let scheduler = PrivateWakeupAckDrainScheduler()

    static func scheduleDrain(
        dataStore: LocalDataStore,
        limit: Int = 200,
        acknowledge: @escaping @Sendable ([String]) async throws -> Set<String>
    ) async {
        await scheduler.schedule(
            PrivateWakeupAckDrainRequest(
                dataStore: dataStore,
                limit: limit,
                acknowledge: acknowledge
            )
        )
    }

    static func drainPendingAcks(
        dataStore: LocalDataStore,
        limit: Int = 200,
        acknowledge: @escaping @Sendable ([String]) async throws -> Set<String>
    ) async -> PrivateWakeupAckDrainOutcome {
        let pendingDeliveryIds = (try? await dataStore.loadPendingInboundDeliveryAckIds(
            limit: limit
        )) ?? []
        guard !pendingDeliveryIds.isEmpty else { return .idle }

        let ackedDeliveryIds: Set<String>
        do {
            ackedDeliveryIds = try await acknowledge(pendingDeliveryIds)
        } catch {
            return classifyFailure(error)
        }
        let outcome = PrivateWakeupAckSemantics.drainOutcome(
            pendingCount: pendingDeliveryIds.count,
            ackedCount: ackedDeliveryIds.count
        )
        guard outcome != .failed else { return .failed }
        for deliveryId in ackedDeliveryIds {
            try? await dataStore.markInboundDeliveryAcked(deliveryId: deliveryId)
        }
        return outcome
    }

    private static func classifyFailure(_ error: Error) -> PrivateWakeupAckDrainOutcome {
        guard let appError = error as? AppError else {
            return .failed
        }
        switch appError {
        case .authFailed, .invalidURL, .noServer:
            return .blocked
        case .apnsDenied, .serverUnreachable, .decryptFailed, .saveConfig, .missingAppGroup, .localStore, .exportFailed, .unknown:
            return .failed
        }
    }
}

@MainActor
enum PrivateWakeupPullCoordinator {
    static func processPulledItems(
        _ pulled: [PrivateWakeupPullItem],
        dataStore: LocalDataStore,
        acknowledge: @escaping @Sendable ([String]) async throws -> Set<String>,
        processItem: (
            _ normalized: NormalizedRemoteNotification,
            _ deliveryId: String,
            _ payload: [AnyHashable: Any],
            _ deliveryState: InboundDeliveryState
        ) async -> Bool
    ) async -> Set<String> {
        guard !pulled.isEmpty else { return [] }

        var ackCandidates: [String] = []
        ackCandidates.reserveCapacity(pulled.count)
        var processedDeliveryIds = Set<String>()

        for item in pulled {
            let deliveryState = (try? await dataStore.inboundDeliveryState(
                deliveryId: item.deliveryId
            )) ?? .missing
            guard deliveryState != .acked else { continue }

            var payload = item.payload
            if payload["delivery_id"] == nil {
                payload["delivery_id"] = item.deliveryId
            }
            var anyPayload: [AnyHashable: Any] = [:]
            for (key, value) in payload {
                anyPayload[key] = value
            }
            guard let normalized = NotificationHandling.normalizeRemoteNotification(anyPayload) else {
                continue
            }
            guard await processItem(normalized, item.deliveryId, anyPayload, deliveryState) else {
                continue
            }
            ackCandidates.append(item.deliveryId)
            processedDeliveryIds.insert(item.deliveryId)
        }

        guard !ackCandidates.isEmpty else { return processedDeliveryIds }
        try? await dataStore.enqueueInboundDeliveryAcks(deliveryIds: ackCandidates)
        await PrivateWakeupAckOutboxWorker.scheduleDrain(
            dataStore: dataStore,
            limit: PrivateWakeupAckSemantics.drainLimit(for: ackCandidates.count),
            acknowledge: acknowledge
        )
        return processedDeliveryIds
    }
}
