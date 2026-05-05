import Foundation
import Observation

@MainActor
@Observable
final class DataPageVisibilityController {
    private let dataStore: LocalDataStore

    private(set) var isMessagePageEnabled = true
    private(set) var isEventPageEnabled = true
    private(set) var isThingPageEnabled = true

    init(dataStore: LocalDataStore) {
        self.dataStore = dataStore
    }

    func setMessagePageEnabled(_ isEnabled: Bool) {
        updateDataPageVisibility(messageEnabled: isEnabled)
    }

    func setEventPageEnabled(_ isEnabled: Bool) {
        updateDataPageVisibility(eventEnabled: isEnabled)
    }

    func setThingPageEnabled(_ isEnabled: Bool) {
        updateDataPageVisibility(thingEnabled: isEnabled)
    }

    func loadPersistedState() async {
        let visibility = await dataStore.loadDataPageVisibility()
        applyDataPageVisibility(visibility, persist: false)
    }

    func autoEnableDataPageIfNeeded(for message: PushMessage) {
        let normalized = message.entityType
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        switch normalized {
        case "event", "thing":
            autoEnableDataPage(for: normalized)
        default:
            autoEnableDataPage(for: "message")
        }
    }

    func autoEnableDataPage(for entityType: String) {
        switch entityType {
        case "event":
            if !isEventPageEnabled {
                updateDataPageVisibility(eventEnabled: true)
            }
        case "thing":
            if !isThingPageEnabled {
                updateDataPageVisibility(thingEnabled: true)
            }
        default:
            if !isMessagePageEnabled {
                updateDataPageVisibility(messageEnabled: true)
            }
        }
    }

    private func updateDataPageVisibility(
        messageEnabled: Bool? = nil,
        eventEnabled: Bool? = nil,
        thingEnabled: Bool? = nil
    ) {
        var next = DataPageVisibilitySnapshot(
            messageEnabled: isMessagePageEnabled,
            eventEnabled: isEventPageEnabled,
            thingEnabled: isThingPageEnabled
        )
        if let messageEnabled {
            next.messageEnabled = messageEnabled
        }
        if let eventEnabled {
            next.eventEnabled = eventEnabled
        }
        if let thingEnabled {
            next.thingEnabled = thingEnabled
        }
        applyDataPageVisibility(next, persist: true)
    }

    private func applyDataPageVisibility(
        _ visibility: DataPageVisibilitySnapshot,
        persist: Bool
    ) {
        let changed = isMessagePageEnabled != visibility.messageEnabled
            || isEventPageEnabled != visibility.eventEnabled
            || isThingPageEnabled != visibility.thingEnabled
        guard changed else { return }
        isMessagePageEnabled = visibility.messageEnabled
        isEventPageEnabled = visibility.eventEnabled
        isThingPageEnabled = visibility.thingEnabled
        if persist {
            let store = dataStore
            Task(priority: .utility) {
                await store.saveDataPageVisibility(visibility)
            }
        }
    }
}
