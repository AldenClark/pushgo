import Foundation
import Testing
@testable import PushGoAppleCore

private actor CommitRecorder {
    private(set) var count = 0
    private(set) var entries: [String] = []

    func increment() {
        count += 1
    }

    func append(_ value: String) {
        entries.append(value)
    }
}

@MainActor
struct PendingLocalDeletionControllerTests {
    private func waitUntil(
        timeout: Duration = .seconds(2),
        interval: Duration = .milliseconds(10),
        _ condition: @escaping @MainActor () async -> Bool
    ) async -> Bool {
        let start = ContinuousClock.now
        while ContinuousClock.now - start < timeout {
            if await condition() {
                return true
            }
            try? await Task.sleep(for: interval)
        }
        return await condition()
    }

    @Test
    func commitCurrentIfNeededCommitsImmediatelyAndClearsPendingDeletion() async {
        let controller = PendingLocalDeletionController(timeout: 5)
        let messageID = UUID()
        let recorder = CommitRecorder()

        await controller.schedule(
            summary: "message",
            undoLabel: "undo",
            scope: PendingLocalDeletionController.Scope(messageIDs: [messageID])
        ) {
            await recorder.increment()
        }

        #expect(controller.pendingDeletion != nil)

        await controller.commitCurrentIfNeeded()

        #expect(await recorder.count == 1)
        #expect(controller.pendingDeletion == nil)
    }

    @Test
    func schedulingNewDeletionCommitsExistingPendingBeforeReplacingIt() async {
        let controller = PendingLocalDeletionController(timeout: 5)
        let firstID = UUID()
        let secondID = UUID()
        let recorder = CommitRecorder()

        await controller.schedule(
            summary: "first",
            undoLabel: "undo",
            scope: PendingLocalDeletionController.Scope(messageIDs: [firstID])
        ) {
            await recorder.append("first")
        }

        await controller.schedule(
            summary: "second",
            undoLabel: "undo",
            scope: PendingLocalDeletionController.Scope(messageIDs: [secondID])
        ) {
            await recorder.append("second")
        }

        #expect(await recorder.entries == ["first"])
        #expect(controller.pendingDeletion?.scope.messageIDs == Set([secondID]))
    }

    @Test
    func undoCurrentCancelsPendingDeletionWithoutCommitting() async {
        let controller = PendingLocalDeletionController(timeout: 0.05)
        let messageID = UUID()
        let recorder = CommitRecorder()

        await controller.schedule(
            summary: "message",
            undoLabel: "undo",
            scope: PendingLocalDeletionController.Scope(messageIDs: [messageID])
        ) {
            await recorder.increment()
        }

        controller.undoCurrent()
        try? await Task.sleep(for: .milliseconds(80))

        #expect(await recorder.count == 0)
        #expect(controller.pendingDeletion == nil)
    }

    @Test
    func countdownExpiryCommitsPendingDeletionAutomatically() async {
        let controller = PendingLocalDeletionController(timeout: 0.03)
        let messageID = UUID()
        let recorder = CommitRecorder()

        await controller.schedule(
            summary: "message",
            undoLabel: "undo",
            scope: PendingLocalDeletionController.Scope(messageIDs: [messageID])
        ) {
            await recorder.increment()
        }

        let completed = await waitUntil {
            await recorder.count == 1 && controller.pendingDeletion == nil
        }

        #expect(completed)
        #expect(await recorder.count == 1)
        #expect(controller.pendingDeletion == nil)
    }
}
