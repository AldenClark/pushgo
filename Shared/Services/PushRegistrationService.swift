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
                switch status {
                case .authorized, .provisional, .ephemeral:
                    self = .authorized
                case .denied:
                    self = .denied
                case .notDetermined:
                    self = .notDetermined
                @unknown default:
                    self = .notDetermined
                }
            }
        }

        static let shared = PushRegistrationService()

        private(set) var authorizationState: AuthorizationState = .notDetermined
        private(set) var apnsToken: String?

        private var tokenWaiters: [UUID: CheckedContinuation<String, Error>] = [:]

        private init() {}

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
                    let nanoseconds = UInt64(timeout * 1_000_000_000)
                    try await Task.sleep(nanoseconds: nanoseconds)
                    throw AppError.apnsDenied
                }

                let result = try await group.next()!
                group.cancelAll()
                return result
            }
        }

        func refreshAuthorizationStatus() async {
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            authorizationState = AuthorizationState(status: settings.authorizationStatus)
        }

        func requestAuthorization() async throws {
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
            let token = deviceToken.map { String(format: "%02.2hhx", $0) }.joined()
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
    }

#endif
