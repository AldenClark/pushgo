import Foundation

struct PrivateWakeupPullItem: Sendable {
    let deliveryId: String
    let payload: [String: String]
}

enum PrivateWakeupPullCoordinator {
    static func processPulledItems(
        _ pulled: [PrivateWakeupPullItem],
        dataStore: LocalDataStore,
        processItem: (
            _ normalized: NormalizedRemoteNotification,
            _ deliveryId: String,
            _ payload: [AnyHashable: Any],
            _ deliveryState: InboundDeliveryState
        ) async -> Bool
    ) async -> Set<String> {
        guard !pulled.isEmpty else { return [] }

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
            try? await dataStore.markInboundDeliveryAcked(deliveryId: item.deliveryId)
            processedDeliveryIds.insert(item.deliveryId)
        }

        return processedDeliveryIds
    }
}
