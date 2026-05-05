import Foundation
import Observation

@MainActor
@Observable
final class AppNavigationState {
    private(set) var activeMainTab: MainTab = .messages
    private(set) var isMessageListAtTop = false
    private(set) var isEventListAtTop = false
    private(set) var isThingListAtTop = false
    private(set) var isSceneActive = false

    func setSceneActive(_ isActive: Bool) {
        isSceneActive = isActive
    }

    func updateActiveTab(_ tab: MainTab) {
        activeMainTab = tab
    }

    func updateMessageListPosition(isAtTop: Bool) {
        guard isMessageListAtTop != isAtTop else { return }
        isMessageListAtTop = isAtTop
    }

    func updateEventListPosition(isAtTop: Bool) {
        guard isEventListAtTop != isAtTop else { return }
        isEventListAtTop = isAtTop
    }

    func updateThingListPosition(isAtTop: Bool) {
        guard isThingListAtTop != isAtTop else { return }
        isThingListAtTop = isAtTop
    }

    func shouldSuppressForegroundNotifications(for payload: [AnyHashable: Any]) -> Bool {
        guard isSceneActive else { return false }
        guard let entityType = foregroundNotificationEntityType(from: payload) else {
            return false
        }
        switch (activeMainTab, entityType) {
        case (.messages, "message"):
            return isMessageListAtTop
        case (.events, "event"):
            return isEventListAtTop
        case (.things, "thing"):
            return isThingListAtTop
        default:
            return false
        }
    }

    private func foregroundNotificationEntityType(
        from payload: [AnyHashable: Any]
    ) -> String? {
        let raw = (payload["entity_type"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        switch raw {
        case "message", "event", "thing":
            return raw
        default:
            return nil
        }
    }
}
