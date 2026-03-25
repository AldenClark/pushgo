import Foundation

enum PrivateWakeupAckDrainOutcome: Sendable, Equatable {
    case idle
    case drained
    case partial
    case failed
    case blocked
}

enum PrivateWakeupAckSemantics {
    static let minimumDrainLimit = 200
    static let normalBackgroundInterval: TimeInterval = 15 * 60
    static let retryBackgroundInterval: TimeInterval = 5 * 60

    static func drainOutcome(
        pendingCount: Int,
        ackedCount: Int,
    ) -> PrivateWakeupAckDrainOutcome {
        guard pendingCount > 0 else { return .idle }
        guard ackedCount > 0 else { return .failed }
        return ackedCount < pendingCount ? .partial : .drained
    }

    static func drainLimit(
        for ackCandidateCount: Int,
        minimum: Int = minimumDrainLimit,
    ) -> Int {
        max(ackCandidateCount, minimum)
    }

    static func backgroundInterval(for outcome: PrivateWakeupAckDrainOutcome?) -> TimeInterval {
        switch outcome {
        case .failed, .partial:
            return retryBackgroundInterval
        case .idle, .drained, .blocked, .none:
            return normalBackgroundInterval
        }
    }

    static func backgroundTaskShouldSucceed(
        for outcome: PrivateWakeupAckDrainOutcome
    ) -> Bool {
        outcome != .failed
    }
}
