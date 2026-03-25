import Foundation
import Testing
import UserNotifications
@testable import PushGoAppleCore

struct PushRegistrationSemanticsTests {
    @Test
    func authorizationStateTreatsProvisionalAsAuthorized() {
        #expect(
            PushRegistrationSemantics.authorizationState(for: .provisional) == .authorized
        )
    }

    @Test
    func authorizationStateTreatsDeniedAsDenied() {
        #expect(
            PushRegistrationSemantics.authorizationState(for: .denied) == .denied
        )
    }

    @Test
    func bootstrapStateUsesAutomationTokenWhenPresent() {
        #expect(
            PushRegistrationSemantics.bootstrapState(
                providerToken: "provider-token-001",
                bypassPushAuthorizationPrompt: false
            ) == .init(
                authorizationState: .authorized,
                apnsToken: "provider-token-001"
            )
        )
    }

    @Test
    func bootstrapStateUsesBypassWithoutInventingToken() {
        #expect(
            PushRegistrationSemantics.bootstrapState(
                providerToken: nil,
                bypassPushAuthorizationPrompt: true
            ) == .init(
                authorizationState: .authorized,
                apnsToken: nil
            )
        )
    }

    @Test
    func hexEncodedTokenProducesLowercaseZeroPaddedOutput() {
        let token = PushRegistrationSemantics.hexEncodedToken(
            Data([0x00, 0x0f, 0xa4, 0xff])
        )
        #expect(token == "000fa4ff")
    }
}
