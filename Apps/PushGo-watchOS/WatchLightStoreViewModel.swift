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
    var error: AppError?

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
        do {
            async let loadedMessages = dataStore.loadWatchLightMessages()
            async let loadedEvents = dataStore.loadWatchLightEvents()
            async let loadedThings = dataStore.loadWatchLightThings()
            messages = try await loadedMessages
            events = try await loadedEvents
            things = try await loadedThings
            error = nil
        } catch let appError as AppError {
            error = appError
        } catch {
            self.error = AppError.wrap(
                error,
                fallbackMessage: environment.localizationManager.localized(
                    "unable_to_read_local_data_placeholder",
                    environment.localizationManager.localized("operation_failed")
                ),
                code: "watch_light_load_failed",
                category: .local
            )
        }
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
            error = appError
        } catch {
            self.error = AppError.wrap(
                error,
                fallbackMessage: environment.localizationManager.localized("failed_to_save_message_status"),
                code: "watch_light_mark_read_failed",
                category: .local
            )
        }
    }

    func deleteMessage(_ message: WatchLightMessage) async {
        do {
            try await dataStore.deleteWatchLightMessage(messageId: message.messageId)
            await environment.refreshWatchLightCountsAndNotify()
            await reload()
        } catch let appError as AppError {
            error = appError
        } catch {
            self.error = AppError.wrap(
                error,
                fallbackMessage: environment.localizationManager.localized("operation_failed"),
                code: "watch_light_delete_failed",
                category: .local
            )
        }
    }
}
