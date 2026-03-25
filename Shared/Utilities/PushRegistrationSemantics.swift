import Foundation
import UserNotifications

enum PushRegistrationSemantics {
    enum AuthorizationState: Equatable {
        case notDetermined
        case authorized
        case denied
    }

    struct BootstrapState: Equatable {
        let authorizationState: AuthorizationState
        let apnsToken: String?
    }

    static func authorizationState(for status: UNAuthorizationStatus) -> AuthorizationState {
        switch status {
        case .authorized, .provisional, .ephemeral:
            return .authorized
        case .denied:
            return .denied
        case .notDetermined:
            return .notDetermined
        @unknown default:
            return .notDetermined
        }
    }

    static func bootstrapState(
        providerToken: String?,
        bypassPushAuthorizationPrompt: Bool,
    ) -> BootstrapState {
        if let providerToken, !providerToken.isEmpty {
            return BootstrapState(
                authorizationState: .authorized,
                apnsToken: providerToken
            )
        }
        if bypassPushAuthorizationPrompt {
            return BootstrapState(
                authorizationState: .authorized,
                apnsToken: nil
            )
        }
        return BootstrapState(
            authorizationState: .notDetermined,
            apnsToken: nil
        )
    }

    static func hexEncodedToken(_ deviceToken: Data) -> String {
        deviceToken.map { String(format: "%02.2hhx", $0) }.joined()
    }
}
