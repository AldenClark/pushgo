import Foundation
import Testing
@testable import PushGoAppleCore

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
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        #expect(service.testingTokenWaiterCount == 2)
        service.handleDeviceToken(Data([0xde, 0xad, 0xbe, 0xef]))

        let firstToken = try await first.value
        let secondToken = try await second.value

        #expect(firstToken == "deadbeef")
        #expect(secondToken == "deadbeef")
        #expect(service.apnsToken == "deadbeef")
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

        await Task.yield()
        service.handleRegistrationError(AppError.unknown("network"))

        await #expect(throws: AppError.apnsDenied) {
            try await pending.value
        }
        #expect(service.authorizationState == .denied)
        #expect(service.apnsToken == nil)
    }
}
