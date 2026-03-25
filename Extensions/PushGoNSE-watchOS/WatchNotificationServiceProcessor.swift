import Foundation
import UserNotifications

@MainActor
final class WatchNotificationServiceProcessor {
    private let contentPreparer = NotificationContentPreparer()
    private let store: WatchLightNotificationStore?

    init(store: WatchLightNotificationStore? = try? WatchLightNotificationStore()) {
        self.store = store
    }

    func process(
        request: UNNotificationRequest,
        content: UNMutableNotificationContent
    ) async -> UNNotificationContent {
        let content = await contentPreparer.prepare(content)

        if !shouldSkipPersistence(for: content.userInfo),
           let payload = WatchStandaloneLightQuantizer.quantizePayload(
               WatchStandaloneLightQuantizer.stringifyPayload(content.userInfo),
               titleOverride: content.title,
               bodyOverride: content.body,
               urlOverride: nil,
               notificationRequestId: request.identifier
           ),
           let store
        {
            try? await store.upsert(payload)
        }

        if let store, let unreadCount = try? await store.unreadCount() {
            content.badge = NSNumber(value: unreadCount)
        }

        return content
    }

    private func shouldSkipPersistence(for payload: [AnyHashable: Any]) -> Bool {
        let sanitized = UserInfoSanitizer.sanitize(payload)
        return normalizedBoolean(sanitized["_skip_persist"]) == true
    }

    private func normalizedBoolean(_ value: Any?) -> Bool? {
        switch value {
        case let bool as Bool:
            return bool
        case let number as NSNumber:
            return number.intValue != 0
        case let string as String:
            let normalized = string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            switch normalized {
            case "1", "true", "yes":
                return true
            case "0", "false", "no":
                return false
            default:
                return nil
            }
        default:
            return nil
        }
    }
}
