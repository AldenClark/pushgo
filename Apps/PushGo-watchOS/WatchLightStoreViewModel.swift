import Foundation
import Observation

@MainActor
@Observable
final class WatchLightStoreViewModel {
    private let environment: AppEnvironment
    private let dataStore: LocalDataStore
    @ObservationIgnored private var reloadTask: Task<Void, Never>?

    private(set) var messages: [WatchLightMessage] = []
    private(set) var events: [WatchLightEvent] = []
    private(set) var things: [WatchLightThing] = []
    private(set) var messageError: AppError?
    private(set) var eventError: AppError?
    private(set) var thingError: AppError?

    init() {
        self.environment = AppEnvironment.shared
        dataStore = AppEnvironment.shared.dataStore
    }

    init(environment: AppEnvironment) {
        self.environment = environment
        dataStore = environment.dataStore
    }

    func reload() async {
        if let reloadTask {
            await reloadTask.value
            return
        }

        let task = Task { @MainActor in
            await self.performReload()
        }
        reloadTask = task
        await task.value
        reloadTask = nil
    }

    private func performReload() async {
        await reloadMessages()
        await reloadEvents()
        await reloadThings()
    }

    private func reloadMessages() async {
        do {
            messages = try await dataStore.loadWatchLightMessages()
            messageError = nil
        } catch let appError as AppError {
            messageError = appError
        } catch {
            messageError = wrappedLoadError(error)
        }
    }

    private func reloadEvents() async {
        do {
            events = try await dataStore.loadWatchLightEvents()
            eventError = nil
        } catch let appError as AppError {
            eventError = appError
        } catch {
            eventError = wrappedLoadError(error)
        }
    }

    private func reloadThings() async {
        do {
            things = try await dataStore.loadWatchLightThings()
            thingError = nil
        } catch let appError as AppError {
            thingError = appError
        } catch {
            thingError = wrappedLoadError(error)
        }
    }

    private func wrappedLoadError(_ error: Error) -> AppError {
        AppError.wrap(
            error,
            fallbackMessage: environment.localizationManager.localized(
                "unable_to_read_local_data_placeholder",
                environment.localizationManager.localized("operation_failed")
            ),
            code: "watch_light_load_failed",
            category: .local
        )
    }

    func message(messageId: String) -> WatchLightMessage? {
        messages.first(where: { $0.messageId == messageId })
    }

    func event(eventId: String) -> WatchLightEvent? {
        events.first(where: { $0.eventId == eventId })
    }

    func thing(thingId: String) -> WatchLightThing? {
        things.first(where: { $0.thingId == thingId })
    }

    func markMessageRead(_ message: WatchLightMessage) async {
        do {
            _ = try await dataStore.markWatchLightMessageRead(messageId: message.messageId)
            await environment.refreshWatchLightCountsAndNotify()
            await reload()
        } catch let appError as AppError {
            messageError = appError
        } catch {
            messageError = AppError.wrap(
                error,
                fallbackMessage: environment.localizationManager.localized("failed_to_save_message_status"),
                code: "watch_light_mark_read_failed",
                category: .local
            )
        }
    }

    private(set) var deletionInProgress = false

    func deleteMessage(_ target: WatchMessageDeletionTarget) async {
        guard !deletionInProgress else { return }
        deletionInProgress = true
        defer { deletionInProgress = false }

        do {
#if DEBUG
            WatchQualityRuntime.recordDeletionDiagnostic([
                "stage": "viewModel.confirm", "scope_matches": target.context == environment.messageDeletionContext,
                "configuration_matches": target.config == environment.serverConfig?.normalized()
            ])
#endif
            guard target.context == environment.messageDeletionContext,
                  target.config == environment.serverConfig?.normalized(),
                  try await dataStore.deleteWatchLightMessage(matching: target.message, context: target.context, config: target.config)
            else {
                messageError = AppError.wrap(
                    NSError(domain: "WatchMessageDeletion", code: 1),
                    fallbackMessage: environment.localizationManager.localized("operation_failed"),
                    code: "watch_light_delete_target_changed",
                    category: .local
                )
                return
            }
            await environment.refreshWatchLightCountsAndNotify()
            await reload()
        } catch let appError as AppError {
#if DEBUG
            WatchQualityRuntime.recordDeletionDiagnostic(["stage": "viewModel.error", "error": String(describing: appError)])
#endif
            messageError = appError
        } catch {
#if DEBUG
            WatchQualityRuntime.recordDeletionDiagnostic(["stage": "viewModel.error", "error": String(describing: error)])
#endif
            messageError = AppError.wrap(
                error,
                fallbackMessage: environment.localizationManager.localized("operation_failed"),
                code: "watch_light_delete_failed",
                category: .local
            )
        }
    }
}

// A confirmation belongs to the displayed content and current Watch configuration.
// Read status is independent of destructive identity and can change on detail open.
struct WatchMessageDeletionTarget: Identifiable {
    let id = UUID()
    let message: WatchLightMessage
    let context: WatchControlContext
    let config: ServerConfig?
}

extension WatchLightMessage {
    func matchesDeletionContent(_ other: WatchLightMessage) -> Bool {
        messageId == other.messageId && title == other.title && body == other.body
            && imageURL == other.imageURL && url == other.url && severity == other.severity
            && receivedAt == other.receivedAt && entityType == other.entityType
            && entityId == other.entityId && notificationRequestId == other.notificationRequestId
    }
}
