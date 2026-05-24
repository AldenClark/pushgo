import Foundation

enum FeedbackPresentationPolicy {
    enum Event: Equatable {
        case formValidationError
        case formSubmissionError
        case contextualSyncError
        case backgroundSyncError
        case mutationSuccess
        case destructiveUndoAvailable
        case passiveStatus
    }

    enum Presentation: Equatable {
        case inline
        case toast
        case pendingLocalDeletionBar
        case none
    }

    static func presentation(for event: Event) -> Presentation {
        switch event {
        case .formValidationError, .formSubmissionError, .contextualSyncError:
            return .inline
        case .backgroundSyncError, .mutationSuccess:
            return .toast
        case .destructiveUndoAvailable:
            return .pendingLocalDeletionBar
        case .passiveStatus:
            return .none
        }
    }
}
