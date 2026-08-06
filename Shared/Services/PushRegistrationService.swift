import Foundation
import Observation
import UserNotifications

#if os(iOS) || os(macOS) || os(watchOS)
    @MainActor
    @Observable
    final class PushRegistrationService {
        private struct TokenWaiter {
            let continuation: CheckedContinuation<String, Error>
            var timeoutTask: Task<Void, Never>?
        }

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
        private var tokenWaiters: [UUID: TokenWaiter] = [:]
#if DEBUG
        private var testingBeforeTokenWaiterInstall: (() -> Void)?
#endif

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

        func setTestingBeforeTokenWaiterInstall(_ action: (() -> Void)?) {
            testingBeforeTokenWaiterInstall = action
        }
#endif

        func awaitToken(timeout: TimeInterval = 10) async throws -> String {
            if let token = apnsToken {
                return token
            }
#if DEBUG
            let beforeInstall = testingBeforeTokenWaiterInstall
            testingBeforeTokenWaiterInstall = nil
            beforeInstall?()
#endif
            return try await enqueueTokenWaiter(timeout: timeout)
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

        private func enqueueTokenWaiter(timeout: TimeInterval) async throws -> String {
            let waiterId = UUID()
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    tokenWaiters[waiterId] = TokenWaiter(
                        continuation: continuation,
                        timeoutTask: nil
                    )

                    if let token = apnsToken {
                        completeWaiter(id: waiterId, with: .success(token))
                        return
                    }
                    if Task.isCancelled {
                        completeWaiter(id: waiterId, with: .failure(CancellationError()))
                        return
                    }

                    let normalizedTimeout = max(0, timeout)
                    let timeoutTask = Task { [weak self, waiterId] in
                        do {
                            try await Task.sleep(for: .seconds(normalizedTimeout))
                        } catch {
                            return
                        }
                        self?.completeWaiter(
                            id: waiterId,
                            with: .failure(Self.registrationTimedOutError)
                        )
                    }
                    guard var waiter = tokenWaiters[waiterId] else {
                        timeoutTask.cancel()
                        return
                    }
                    waiter.timeoutTask = timeoutTask
                    tokenWaiters[waiterId] = waiter
                }
            } onCancel: { [weak self, waiterId] in
                Task { @MainActor in
                    self?.completeWaiter(id: waiterId, with: .failure(CancellationError()))
                }
            }
        }

        private func completeWaiter(id: UUID, with result: Result<String, Error>) {
            guard let waiter = tokenWaiters.removeValue(forKey: id) else { return }
            waiter.timeoutTask?.cancel()
            switch result {
            case let .success(token):
                waiter.continuation.resume(returning: token)
            case let .failure(error):
                waiter.continuation.resume(throwing: error)
            }
        }

        private func resolveWaiters(with result: Result<String, Error>) {
            let waiters = Array(tokenWaiters.values)
            tokenWaiters.removeAll()
            for waiter in waiters {
                waiter.timeoutTask?.cancel()
                switch result {
                case let .success(token):
                    waiter.continuation.resume(returning: token)
                case let .failure(error):
                    waiter.continuation.resume(throwing: error)
                }
            }
        }

        static var registrationTimedOutError: AppError {
            .typedLocal(
                code: "apns_registration_timed_out",
                category: .local,
                message: LocalizationProvider.localized("operation_failed"),
                detail: "timed out waiting for APNs device token"
            )
        }

        private static func normalizedAutomationProviderToken(_ token: String?) -> String? {
            guard let token else { return nil }
            let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
    }

#endif
