import Foundation
import Testing
@testable import PushGoAppleCore

private actor BackgroundRefreshStageProbe {
    private var mergeStarted = false
    private var mergeContinuation: CheckedContinuation<Void, Never>?
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var mergeCalls = 0
    private(set) var ackCalls = 0
    private(set) var derivedCalls = 0

    func merge() async {
        mergeCalls += 1
        mergeStarted = true
        let waiters = startWaiters
        startWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        await withCheckedContinuation { mergeContinuation = $0 }
    }

    func acknowledgements() { ackCalls += 1 }
    func derivedWork() { derivedCalls += 1 }

    func waitUntilMergeStarted() async {
        if mergeStarted { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func releaseMerge() {
        mergeContinuation?.resume()
        mergeContinuation = nil
    }
}

private actor BackgroundRefreshDerivedLifetimeProbe {
    private var derivedStarted = false
    private var derivedContinuation: CheckedContinuation<Void, Never>?
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var runnerOutcome: IngressBackgroundRefreshRunner.Outcome?

    func drainDerivedWork() async {
        derivedStarted = true
        let waiters = startWaiters
        startWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        await withCheckedContinuation { derivedContinuation = $0 }
    }

    func waitUntilDerivedStarted() async {
        if derivedStarted { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func releaseDerivedWork() {
        derivedContinuation?.resume()
        derivedContinuation = nil
    }

    func record(_ outcome: IngressBackgroundRefreshRunner.Outcome) {
        runnerOutcome = outcome
    }
}

struct IngressBackgroundRefreshLifecycleTests {
    @Test @MainActor
    func cancellationAfterMergeStartsPreventsAckAndDerivedStages() async {
        let probe = BackgroundRefreshStageProbe()
        let runner = IngressBackgroundRefreshRunner(
            mergeIngress: {
                await probe.merge()
                return .succeeded
            },
            drainAcknowledgements: {
                await probe.acknowledgements()
                return .succeeded
            },
            drainDerivedWork: {
                await probe.derivedWork()
                return .succeeded
            }
        )
        let work = Task { @MainActor in await runner.run() }

        await probe.waitUntilMergeStarted()
        work.cancel()
        await probe.releaseMerge()

        #expect(await work.value == .cancelled)
        #expect(await probe.mergeCalls == 1)
        #expect(await probe.ackCalls == 0)
        #expect(await probe.derivedCalls == 0)
    }

    @Test @MainActor
    func canonicalFailureReportsFailedAndStopsDependentStages() async {
        let probe = BackgroundRefreshStageProbe()
        let runner = IngressBackgroundRefreshRunner(
            mergeIngress: { .failed },
            drainAcknowledgements: {
                await probe.acknowledgements()
                return .succeeded
            },
            drainDerivedWork: {
                await probe.derivedWork()
                return .succeeded
            }
        )

        #expect(await runner.run() == .failed(.canonicalIngress))
        #expect(await probe.ackCalls == 0)
        #expect(await probe.derivedCalls == 0)
    }

    @Test @MainActor
    func acknowledgementFailureReportsFailedAndStopsDerivedStage() async {
        let probe = BackgroundRefreshStageProbe()
        let runner = IngressBackgroundRefreshRunner(
            mergeIngress: { .succeeded },
            drainAcknowledgements: {
                await probe.acknowledgements()
                return .failed
            },
            drainDerivedWork: {
                await probe.derivedWork()
                return .succeeded
            }
        )

        #expect(await runner.run() == .failed(.acknowledgements))
        #expect(await probe.ackCalls == 1)
        #expect(await probe.derivedCalls == 0)
    }

    @Test @MainActor
    func runnerAwaitsDerivedWorkBeforeReportingSuccess() async {
        let probe = BackgroundRefreshDerivedLifetimeProbe()
        let runner = IngressBackgroundRefreshRunner(
            mergeIngress: { .succeeded },
            drainAcknowledgements: { .succeeded },
            drainDerivedWork: {
                await probe.drainDerivedWork()
                return .succeeded
            }
        )
        let work = Task { @MainActor in
            let outcome = await runner.run()
            await probe.record(outcome)
        }

        await probe.waitUntilDerivedStarted()
        #expect(await probe.runnerOutcome == nil)
        await probe.releaseDerivedWork()
        await work.value
        #expect(await probe.runnerOutcome == .succeeded)
    }

    @Test
    func sceneBackgroundTransitionSchedulesIngressRefresh() throws {
        let source = try readSource("Apps/PushGo-iOS/App/AppEnvironment.swift")
        let backgroundCase = try section(
            in: source,
            from: "case .background:",
            to: "case .inactive:"
        )

        #expect(
            backgroundCase.contains(
                "PushGoAppDelegate.scheduleIngressBackgroundRefresh(source: \"scene_background\")"
            )
        )
    }

    @Test
    func launchHandlerReschedulesBeforeStartingRefreshWork() throws {
        let source = try readSource("Apps/PushGo-iOS/App/PushGoAppDelegate.swift")
        let registration = try section(
            in: source,
            from: "private func registerIngressBackgroundRefresh()",
            to: "static func scheduleIngressBackgroundRefresh"
        )
        let reschedule = try #require(
            registration.range(
                of: "Self.scheduleIngressBackgroundRefresh(source: \"handler_start\")"
            )
        )
        let work = try #require(registration.range(of: "let work = Task"))

        #expect(reschedule.lowerBound < work.lowerBound)
        #expect(!registration.contains("Self.scheduleIngressBackgroundRefresh()"))
    }

    @Test
    func expirationAndNormalFinishShareAnExactlyOnceCompletionGate() throws {
        let source = try readSource("Apps/PushGo-iOS/App/PushGoAppDelegate.swift")
        let gate = try section(
            in: source,
            from: "private final class IngressBackgroundRefreshCompletionGate",
            to: "final class PushGoAppDelegate"
        )
        let registration = try section(
            in: source,
            from: "private func registerIngressBackgroundRefresh()",
            to: "static func scheduleIngressBackgroundRefresh"
        )

        #expect(gate.contains("IngressBackgroundRefreshCompletionGate: Sendable"))
        #expect(gate.contains("OSAllocatedUnfairLock(initialState: false)"))
        #expect(gate.contains("func claimCompletion() -> Bool"))
        #expect(gate.contains("guard !completed else { return false }"))
        #expect(
            registration.components(separatedBy: "completionGate.claimCompletion()").count - 1 == 2
        )
        #expect(
            registration.components(separatedBy: "refreshTask.setTaskCompleted").count - 1 == 2
        )
    }

    @Test
    func controllerOwnsOneRearmingIngressAndAckRetryWakeTask() throws {
        let source = try readSource("Shared/Application/NotificationIngressController.swift")

        #expect(source.contains("private var ingressRetryWakeTask: Task<Void, Never>?"))
        #expect(source.contains("private var ingressRetryWakeDate: Date?"))
        #expect(source.contains("async let ingressDue = notificationIngressInbox.nextRetryDate()"))
        #expect(source.contains("async let ackDue = ackFailureStore.nextAttemptDate()"))
        #expect(source.contains("ingressRetryWakeTask?.cancel()"))
        #expect(source.contains("await ingressRetryWakeFired(expectedDate: due, source: source)"))
        #expect(!source.contains("ackRetryWakeTask"))
    }

    @Test
    func registrationAndSubmissionFailuresAreObservable() throws {
        let source = try readSource("Apps/PushGo-iOS/App/PushGoAppDelegate.swift")
        let registration = try section(
            in: source,
            from: "private func registerIngressBackgroundRefresh()",
            to: "static func scheduleIngressBackgroundRefresh"
        )
        let scheduling = try section(
            in: source,
            from: "static func scheduleIngressBackgroundRefresh",
            to: "private func remoteFetchResult"
        )

        #expect(registration.contains("let registered = BGTaskScheduler.shared.register"))
        #expect(registration.contains("Failed to register ingress background refresh handler"))
        #expect(scheduling.contains("try BGTaskScheduler.shared.submit(request)"))
        #expect(scheduling.contains("Failed to schedule ingress background refresh"))
        #expect(!scheduling.contains("try? BGTaskScheduler.shared.submit"))
    }

    private func readSource(_ relativePath: String) throws -> String {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: repositoryRoot.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    private func section(in source: String, from start: String, to end: String) throws -> Substring {
        let startRange = try #require(source.range(of: start))
        let endRange = try #require(
            source.range(of: end, range: startRange.upperBound..<source.endIndex)
        )
        return source[startRange.lowerBound..<endRange.lowerBound]
    }
}
