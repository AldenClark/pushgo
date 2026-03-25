import Foundation
import Testing
@testable import PushGoAppleCore

struct PrivateWakeupAckTests {
    @Test
    func drainPendingAcksReturnsIdleWhenOutboxIsEmpty() async {
        await withIsolatedLocalDataStore { store, _ in
            let outcome = await PrivateWakeupAckOutboxWorker.drainPendingAcks(
                dataStore: store,
                limit: 10,
                acknowledge: { deliveryIds in
                    Issue.record("Expected no ACK request when the outbox is empty, got: \(deliveryIds)")
                    return []
                }
            )

            #expect(outcome == .idle)
        }
    }

    @Test
    func drainPendingAcksMarksAckedIdsAndLeavesRemainingQueued() async throws {
        try await withIsolatedLocalDataStore { store, _ in
            try await store.markInboundDeliveryPersisted(deliveryId: "delivery-001")
            try await store.markInboundDeliveryPersisted(deliveryId: "delivery-002")
            try await store.enqueueInboundDeliveryAcks(
                deliveryIds: [" delivery-002 ", "delivery-001", "delivery-002"]
            )

            let outcome = await PrivateWakeupAckOutboxWorker.drainPendingAcks(
                dataStore: store,
                limit: 10,
                acknowledge: { deliveryIds in
                    #expect(Set(deliveryIds) == Set(["delivery-001", "delivery-002"]))
                    return ["delivery-001"]
                }
            )

            let pending = try await store.loadPendingInboundDeliveryAckIds(limit: 10)
            let firstState = try await store.inboundDeliveryState(deliveryId: "delivery-001")
            let secondState = try await store.inboundDeliveryState(deliveryId: "delivery-002")

            #expect(outcome == .partial)
            #expect(pending == ["delivery-002"])
            #expect(firstState == .acked)
            #expect(secondState == .persisted)
        }
    }

    @Test
    func drainPendingAcksFailureKeepsAllPendingIdsQueued() async throws {
        try await withIsolatedLocalDataStore { store, _ in
            try await store.markInboundDeliveryPersisted(deliveryId: "delivery-101")
            try await store.markInboundDeliveryPersisted(deliveryId: "delivery-102")
            try await store.enqueueInboundDeliveryAcks(
                deliveryIds: ["delivery-101", "delivery-102"]
            )

            let outcome = await PrivateWakeupAckOutboxWorker.drainPendingAcks(
                dataStore: store,
                limit: 10,
                acknowledge: { deliveryIds in
                    #expect(Set(deliveryIds) == Set(["delivery-101", "delivery-102"]))
                    return []
                }
            )

            let pending = try await store.loadPendingInboundDeliveryAckIds(limit: 10)
            let firstState = try await store.inboundDeliveryState(deliveryId: "delivery-101")
            let secondState = try await store.inboundDeliveryState(deliveryId: "delivery-102")

            #expect(outcome == .failed)
            #expect(Set(pending) == Set(["delivery-101", "delivery-102"]))
            #expect(firstState == .persisted)
            #expect(secondState == .persisted)
        }
    }
}
