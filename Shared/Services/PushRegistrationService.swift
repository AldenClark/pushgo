import Foundation
import Observation
import UserNotifications

#if os(iOS) || os(macOS) || os(watchOS)
    @MainActor
    @Observable
    final class PushRegistrationService {
        enum AuthorizationState {
            case notDetermined
            case authorized
            case denied

            init(status: UNAuthorizationStatus) {
                switch PushRegistrationSemantics.authorizationState(for: status) {
                case .authorized:
                    self = .authorized
                case .denied:
                    self = .denied
                case .notDetermined:
                    self = .notDetermined
                }
            }
        }

        static let shared = PushRegistrationService()

        private(set) var authorizationState: AuthorizationState = .notDetermined
        private(set) var apnsToken: String?

        private let automationProviderToken: String?
        private let bypassPushAuthorizationPrompt: Bool
        private var tokenWaiters: [UUID: CheckedContinuation<String, Error>] = [:]

        private init(
            automationProviderToken: String? = PushGoAutomationContext.providerToken,
            bypassPushAuthorizationPrompt: Bool = PushGoAutomationContext.bypassPushAuthorizationPrompt
        ) {
            let normalizedAutomationProviderToken = Self.normalizedAutomationProviderToken(automationProviderToken)
            self.automationProviderToken = normalizedAutomationProviderToken
            self.bypassPushAuthorizationPrompt = bypassPushAuthorizationPrompt
            let bootstrap = PushRegistrationSemantics.bootstrapState(
                providerToken: normalizedAutomationProviderToken,
                bypassPushAuthorizationPrompt: bypassPushAuthorizationPrompt
            )
            apnsToken = bootstrap.apnsToken
            switch bootstrap.authorizationState {
            case .authorized:
                authorizationState = .authorized
            case .denied:
                authorizationState = .denied
            case .notDetermined:
                authorizationState = .notDetermined
            }
        }

#if DEBUG
        static func testing(
            automationProviderToken: String? = nil,
            bypassPushAuthorizationPrompt: Bool = false,
            bootstrapStateOverride: PushRegistrationSemantics.BootstrapState? = nil
        ) -> PushRegistrationService {
            let service = PushRegistrationService(
                automationProviderToken: automationProviderToken,
                bypassPushAuthorizationPrompt: bypassPushAuthorizationPrompt
            )
            if let bootstrapStateOverride {
                switch bootstrapStateOverride.authorizationState {
                case .authorized:
                    service.authorizationState = .authorized
                case .denied:
                    service.authorizationState = .denied
                case .notDetermined:
                    service.authorizationState = .notDetermined
                }
                service.apnsToken = bootstrapStateOverride.apnsToken
            }
            return service
        }

        var testingTokenWaiterCount: Int {
            tokenWaiters.count
        }
#endif

        func awaitToken(timeout: TimeInterval = 10) async throws -> String {
            if let token = apnsToken {
                return token
            }

            return try await withThrowingTaskGroup(of: String.self) { group in
                group.addTask { [weak self] in
                    guard let self else { throw AppError.apnsDenied }
                    return try await enqueueTokenWaiter()
                }

                group.addTask {
                    try await Task.sleep(for: .seconds(timeout))
                    throw AppError.apnsDenied
                }

                let result = try await group.next()!
                group.cancelAll()
                return result
            }
        }

        func refreshAuthorizationStatus() async {
            if bypassPushAuthorizationPrompt {
                authorizationState = .authorized
                if apnsToken == nil {
                    apnsToken = automationProviderToken
                }
                return
            }
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            authorizationState = AuthorizationState(status: settings.authorizationStatus)
        }

        func requestAuthorization() async throws {
            if bypassPushAuthorizationPrompt {
                authorizationState = .authorized
                if apnsToken == nil {
                    apnsToken = automationProviderToken
                }
                return
            }
            do {
                let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [
                    .alert,
                    .sound,
                    .badge,
                ])
                authorizationState = granted ? .authorized : .denied
                if !granted {
                    throw AppError.apnsDenied
                }
            } catch {
                authorizationState = .denied
                throw AppError.apnsDenied
            }
        }

        func handleDeviceToken(_ deviceToken: Data) {
            if let automationProviderToken {
                apnsToken = automationProviderToken
                resolveWaiters(with: .success(automationProviderToken))
                return
            }
            let token = PushRegistrationSemantics.hexEncodedToken(deviceToken)
            apnsToken = token
            resolveWaiters(with: .success(token))
        }

        func handleRegistrationError(_: Error) {
            authorizationState = .denied
            resolveWaiters(with: .failure(AppError.apnsDenied))
        }

        private func enqueueTokenWaiter() async throws -> String {
            let waiterId = UUID()
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    tokenWaiters[waiterId] = continuation
                }
            } onCancel: { [weak self, waiterId] in
                let service = self
                Task { @MainActor in
                    service?.cancelWaiter(id: waiterId)
                }
            }
        }

        private func cancelWaiter(id: UUID) {
            let continuation = tokenWaiters.removeValue(forKey: id)
            continuation?.resume(throwing: CancellationError())
        }

        private func resolveWaiters(with result: Result<String, Error>) {
            let waiters = Array(tokenWaiters.values)
            tokenWaiters.removeAll()
            for waiter in waiters {
                switch result {
                case let .success(token):
                    waiter.resume(returning: token)
                case let .failure(error):
                    waiter.resume(throwing: error)
                }
            }
        }

        private static func normalizedAutomationProviderToken(_ token: String?) -> String? {
            guard let token else { return nil }
            let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
    }

#endif
