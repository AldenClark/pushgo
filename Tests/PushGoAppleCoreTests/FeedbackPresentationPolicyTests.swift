import Testing
@testable import PushGoAppleCore

struct FeedbackPresentationPolicyTests {
    @Test
    func formErrorsAreInlineBecauseTheyRequireUserCorrectionInPlace() {
        #expect(FeedbackPresentationPolicy.presentation(for: .formValidationError) == .inline)
        #expect(FeedbackPresentationPolicy.presentation(for: .formSubmissionError) == .inline)
    }

    @Test
    func contextualEntrySyncErrorsAreInlineInsteadOfGlobalToast() {
        #expect(FeedbackPresentationPolicy.presentation(for: .contextualSyncError) == .inline)
    }

    @Test
    func backgroundAndSuccessFeedbackRemainTransientToast() {
        #expect(FeedbackPresentationPolicy.presentation(for: .backgroundSyncError) == .toast)
        #expect(FeedbackPresentationPolicy.presentation(for: .mutationSuccess) == .toast)
    }

    @Test
    func destructiveUndoUsesDedicatedPendingDeletionBar() {
        #expect(FeedbackPresentationPolicy.presentation(for: .destructiveUndoAvailable) == .pendingLocalDeletionBar)
    }
}
