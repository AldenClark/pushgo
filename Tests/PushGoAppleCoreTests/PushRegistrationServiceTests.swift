import Foundation
import Testing
import UserNotifications
@testable import PushGoAppleCore

@MainActor
private final class AuthorizationStatusStub {
    var status: UNAuthorizationStatus
    private(set) var readCount = 0

    init(status: UNAuthorizationStatus) {
        self.status = status
    }

    func read() -> UNAuthorizationStatus {
        readCount += 1
        return status
    }
}

@MainActor
private final class SuspendedAuthorizationStatusStub {
    private var continuations: [CheckedContinuation<UNAuthorizationStatus, Never>] = []

    var pendingReadCount: Int { continuations.count }

    func read() async -> UNAuthorizationStatus {
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func resolveRead(at index: Int, with status: UNAuthorizationStatus) {
        continuations[index].resume(returning: status)
    }
}

@MainActor
private final class SuspendedAuthorizationRequestStub {
    enum Outcome {
        case granted(Bool)
        case failed
    }

    private var continuation: CheckedContinuation<Outcome, Never>?
    private(set) var requestCount = 0
    var isPending: Bool { continuation != nil }

    func request(_: UNAuthorizationOptions) async throws -> Bool {
        requestCount += 1
        let outcome = await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
        switch outcome {
        case let .granted(granted):
            return granted
        case .failed:
            throw AppError.unknown("authorization request failed")
        }
    }

    func resolve(_ outcome: Outcome) {
        continuation?.resume(returning: outcome)
        continuation = nil
    }
}

@MainActor
struct PushRegistrationServiceTests {
    @Test
    func bootstrapWithAutomationTokenMarksAuthorizedAndReturnsTrimmedToken() async throws {
        let service = PushRegistrationService.testing(
            automationProviderToken: "  provider-token-001 \n"
        )

        #expect(service.authorizationState == .authorized)
        #expect(try await service.awaitToken(timeout: 0.01) == "provider-token-001")
    }

    @Test
    func refreshAuthorizationStatusBypassBackfillsMissingAutomationToken() async {
        let service = PushRegistrationService.testing(
            automationProviderToken: "provider-token-002",
            bypassPushAuthorizationPrompt: true,
            bootstrapStateOverride: .init(
                authorizationState: .notDetermined,
                apnsToken: nil
            )
        )

        await service.refreshAuthorizationStatus()

        #expect(service.authorizationState == .authorized)
        #expect(service.apnsToken == "provider-token-002")
    }

    @Test
    func applicationBecomingActiveRefreshesDeniedAuthorizationToAuthorized() async {
        let systemStatus = AuthorizationStatusStub(status: .denied)
        let service = PushRegistrationService.testing(
            bootstrapStateOverride: .init(
                authorizationState: .notDetermined,
                apnsToken: nil
            ),
            authorizationStatusProvider: { systemStatus.read() }
        )

        await service.applicationDidBecomeActive()
        #expect(service.authorizationState == .denied)
        #expect(systemStatus.readCount == 1)

        systemStatus.status = .authorized
        await service.applicationDidBecomeActive()
        #expect(service.authorizationState == .authorized)
        #expect(systemStatus.readCount == 2)
    }

    @Test
    func latestAuthorizationRefreshWinsWhenOlderSystemQueryCompletesLast() async {
        let systemStatus = SuspendedAuthorizationStatusStub()
        let service = PushRegistrationService.testing(
            bootstrapStateOverride: .init(
                authorizationState: .notDetermined,
                apnsToken: nil
            ),
            authorizationStatusProvider: { await systemStatus.read() }
        )

        let olderRefresh = Task { await service.applicationDidBecomeActive() }
        while systemStatus.pendingReadCount < 1 { await Task.yield() }
        let latestRefresh = Task { await service.applicationDidBecomeActive() }
        while systemStatus.pendingReadCount < 2 { await Task.yield() }

        systemStatus.resolveRead(at: 1, with: .authorized)
        await latestRefresh.value
        systemStatus.resolveRead(at: 0, with: .denied)
        await olderRefresh.value

        #expect(service.authorizationState == .authorized)
    }

    @Test
    func olderRefreshCannotOverwriteSuccessfulAuthorizationRequest() async throws {
        let systemStatus = SuspendedAuthorizationStatusStub()
        let service = PushRegistrationService.testing(
            bootstrapStateOverride: .init(
                authorizationState: .notDetermined,
                apnsToken: nil
            ),
            authorizationStatusProvider: { await systemStatus.read() },
            authorizationRequestProvider: { _ in true }
        )

        let olderRefresh = Task { await service.applicationDidBecomeActive() }
        while systemStatus.pendingReadCount < 1 { await Task.yield() }
        try await service.requestAuthorization()
        #expect(service.authorizationState == .authorized)

        systemStatus.resolveRead(at: 0, with: .denied)
        await olderRefresh.value
        #expect(service.authorizationState == .authorized)
    }

    @Test
    func deniedRequestIsNotSwallowedWhenActiveRefreshCompletesDuringPrompt() async {
        let request = SuspendedAuthorizationRequestStub()
        let service = PushRegistrationService.testing(
            bootstrapStateOverride: .init(
                authorizationState: .notDetermined,
                apnsToken: nil
            ),
            authorizationStatusProvider: { .authorized },
            authorizationRequestProvider: { try await request.request($0) }
        )

        let pendingRequest = Task { try await service.requestAuthorization() }
        while !request.isPending { await Task.yield() }
        await service.applicationDidBecomeActive()
        #expect(service.authorizationState == .authorized)

        request.resolve(.granted(false))
        await #expect(throws: AppError.apnsDenied) {
            try await pendingRequest.value
        }
        #expect(service.authorizationState == .denied)
    }

    @Test
    func failedRequestIsNotSwallowedWhenActiveRefreshCompletesDuringPrompt() async {
        let request = SuspendedAuthorizationRequestStub()
        let service = PushRegistrationService.testing(
            bootstrapStateOverride: .init(
                authorizationState: .notDetermined,
                apnsToken: nil
            ),
            authorizationStatusProvider: { .authorized },
            authorizationRequestProvider: { try await request.request($0) }
        )

        let pendingRequest = Task { try await service.requestAuthorization() }
        while !request.isPending { await Task.yield() }
        await service.applicationDidBecomeActive()
        request.resolve(.failed)

        await #expect(throws: AppError.apnsDenied) {
            try await pendingRequest.value
        }
        #expect(service.authorizationState == .denied)
    }

    @Test
    func requestAuthorizationBypassBackfillsMissingAutomationToken() async throws {
        let service = PushRegistrationService.testing(
            automationProviderToken: "provider-token-003",
            bypassPushAuthorizationPrompt: true,
            bootstrapStateOverride: .init(
                authorizationState: .notDetermined,
                apnsToken: nil
            )
        )

        try await service.requestAuthorization()

        #expect(service.authorizationState == .authorized)
        #expect(service.apnsToken == "provider-token-003")
    }

    @Test
    func handleDeviceTokenResolvesAllPendingWaiters() async throws {
        let service = PushRegistrationService.testing(
            bootstrapStateOverride: .init(
                authorizationState: .notDetermined,
                apnsToken: nil
            )
        )

        let first = Task { @MainActor in
            try await service.awaitToken(timeout: 2)
        }
        let second = Task { @MainActor in
            try await service.awaitToken(timeout: 2)
        }

        for _ in 0..<40 {
            if service.testingTokenWaiterCount == 2 {
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(service.testingTokenWaiterCount == 2)
        service.handleDeviceToken(Data([0xde, 0xad, 0xbe, 0xef]))

        let firstToken = try await first.value
        let secondToken = try await second.value

        #expect(firstToken == "deadbeef")
        #expect(secondToken == "deadbeef")
        #expect(service.apnsToken == "deadbeef")
        #expect(service.testingTokenWaiterCount == 0)
    }

    @Test
    func handleDeviceTokenKeepsAutomationProviderTokenStable() async throws {
        let service = PushRegistrationService.testing(
            automationProviderToken: "automation-token",
            bypassPushAuthorizationPrompt: true,
            bootstrapStateOverride: .init(
                authorizationState: .authorized,
                apnsToken: nil
            )
        )

        let pending = Task { @MainActor in
            try await service.awaitToken(timeout: 2)
        }

        for _ in 0..<40 {
            if service.testingTokenWaiterCount == 1 {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(service.testingTokenWaiterCount == 1)
        service.handleDeviceToken(Data([0xde, 0xad, 0xbe, 0xef]))

        #expect(try await pending.value == "automation-token")
        #expect(service.apnsToken == "automation-token")
        #expect(service.testingTokenWaiterCount == 0)
    }

    @Test
    func handleRegistrationErrorRejectsPendingWaitersAndMarksDenied() async {
        let service = PushRegistrationService.testing(
            bootstrapStateOverride: .init(
                authorizationState: .notDetermined,
                apnsToken: nil
            )
        )

        let pending = Task { @MainActor in
            try await service.awaitToken(timeout: 2)
        }

        for _ in 0..<40 {
            if service.testingTokenWaiterCount == 1 {
                break
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(service.testingTokenWaiterCount == 1)
        service.handleRegistrationError(AppError.unknown("network"))

        await #expect(throws: AppError.apnsDenied) {
            try await pending.value
        }
        #expect(service.authorizationState == .denied)
        #expect(service.apnsToken == nil)
        #expect(service.testingTokenWaiterCount == 0)
    }

    @Test
    func tokenArrivingBetweenInitialCheckAndWaiterInstallIsNeverLost() async throws {
        for value in 0..<100 {
            let service = PushRegistrationService.testing(
                bootstrapStateOverride: .init(
                    authorizationState: .authorized,
                    apnsToken: nil
                )
            )
            let byte = UInt8(value)
            service.setTestingBeforeTokenWaiterInstall {
                service.handleDeviceToken(Data([byte]))
            }

            #expect(try await service.awaitToken(timeout: 0.01) == String(format: "%02x", byte))
            #expect(service.testingTokenWaiterCount == 0)
        }
    }

    @Test
    func tokenWaiterTimeoutIsDistinctFromAuthorizationDeniedAndCompletesOnce() async {
        let service = PushRegistrationService.testing(
            bootstrapStateOverride: .init(
                authorizationState: .authorized,
                apnsToken: nil
            )
        )

        await #expect(throws: PushRegistrationService.registrationTimedOutError) {
            try await service.awaitToken(timeout: 0.01)
        }
        #expect(PushRegistrationService.registrationTimedOutError != AppError.apnsDenied)
        #expect(service.testingTokenWaiterCount == 0)
        service.handleRegistrationError(AppError.unknown("late-error"))
        #expect(service.testingTokenWaiterCount == 0)
    }

    @Test
    func tokenWaiterCancellationCompletesOnceAndIgnoresLateToken() async {
        let service = PushRegistrationService.testing(
            bootstrapStateOverride: .init(
                authorizationState: .authorized,
                apnsToken: nil
            )
        )
        let pending = Task { @MainActor in
            try await service.awaitToken(timeout: 2)
        }
        for _ in 0..<40 {
            if service.testingTokenWaiterCount == 1 {
                break
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(service.testingTokenWaiterCount == 1)

        pending.cancel()
        await #expect(throws: CancellationError.self) {
            try await pending.value
        }
        #expect(service.testingTokenWaiterCount == 0)
        service.handleDeviceToken(Data([0xca, 0xfe]))
        #expect(service.apnsToken == "cafe")
        #expect(service.testingTokenWaiterCount == 0)
    }
}
