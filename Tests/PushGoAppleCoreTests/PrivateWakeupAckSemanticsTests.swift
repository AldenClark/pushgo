import Foundation
import Testing
@testable import PushGoAppleCore

struct PrivateWakeupAckSemanticsTests {
    @Test
    func drainOutcomeReturnsIdleWhenNothingIsPending() {
        #expect(
            PrivateWakeupAckSemantics.drainOutcome(
                pendingCount: 0,
                ackedCount: 0
            ) == .idle
        )
    }

    @Test
    func drainOutcomeReturnsFailedWhenNoAckWasAccepted() {
        #expect(
            PrivateWakeupAckSemantics.drainOutcome(
                pendingCount: 3,
                ackedCount: 0
            ) == .failed
        )
    }

    @Test
    func drainOutcomeReturnsPartialWhenOnlySubsetWasAcked() {
        #expect(
            PrivateWakeupAckSemantics.drainOutcome(
                pendingCount: 5,
                ackedCount: 2
            ) == .partial
        )
    }

    @Test
    func drainOutcomeReturnsDrainedWhenAllPendingIdsWereAcked() {
        #expect(
            PrivateWakeupAckSemantics.drainOutcome(
                pendingCount: 4,
                ackedCount: 4
            ) == .drained
        )
    }

    @Test
    func drainLimitKeepsMinimumBatchFloor() {
        #expect(PrivateWakeupAckSemantics.drainLimit(for: 3) == 200)
    }

    @Test
    func drainLimitExpandsForLargerBurst() {
        #expect(PrivateWakeupAckSemantics.drainLimit(for: 280) == 280)
    }

    @Test
    func backgroundIntervalUsesRetryWindowForPartialAndFailure() {
        #expect(
            PrivateWakeupAckSemantics.backgroundInterval(for: .partial) ==
            PrivateWakeupAckSemantics.retryBackgroundInterval
        )
        #expect(
            PrivateWakeupAckSemantics.backgroundInterval(for: .failed) ==
            PrivateWakeupAckSemantics.retryBackgroundInterval
        )
    }

    @Test
    func backgroundTaskSuccessOnlyFailsHardFailure() {
        #expect(!PrivateWakeupAckSemantics.backgroundTaskShouldSucceed(for: .failed))
        #expect(PrivateWakeupAckSemantics.backgroundTaskShouldSucceed(for: .idle))
        #expect(PrivateWakeupAckSemantics.backgroundTaskShouldSucceed(for: .partial))
        #expect(PrivateWakeupAckSemantics.backgroundTaskShouldSucceed(for: .drained))
    }
}
