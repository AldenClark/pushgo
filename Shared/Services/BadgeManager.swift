import Foundation
import UserNotifications

#if canImport(AppKit)
    import AppKit
#endif

enum BadgeManager {
    static func unreadCount(from messages: [PushMessage]) -> Int {
        messages.count(where: { !$0.isRead })
    }

    @MainActor
    @available(iOSApplicationExtension, unavailable)
    @available(macCatalystApplicationExtension, unavailable)
    @available(macOSApplicationExtension, unavailable)
    static func syncAppBadge(using messages: [PushMessage]) {
        applyAppBadge(unreadCount(from: messages))
    }

    @MainActor
    @available(iOSApplicationExtension, unavailable)
    @available(macCatalystApplicationExtension, unavailable)
    @available(macOSApplicationExtension, unavailable)
    static func syncAppBadge(unreadCount: Int) {
        applyAppBadge(unreadCount)
    }

    @MainActor
    @available(iOSApplicationExtension, unavailable)
    @available(macCatalystApplicationExtension, unavailable)
    @available(macOSApplicationExtension, unavailable)
    private static func applyAppBadge(_ count: Int) {
        #if os(macOS)
            if let app = NSApp {
                app.dockTile.badgeLabel = count > 0 ? "\(count)" : ""
            }
        #elseif os(iOS)
            UNUserNotificationCenter.current().setBadgeCount(count)
        #endif
    }

    @MainActor
    static func syncExtensionBadge(using messages: [PushMessage]) {
        #if os(iOS)
            UNUserNotificationCenter.current().setBadgeCount(unreadCount(from: messages))
        #endif
    }

    @MainActor
    static func syncExtensionBadge(unreadCount: Int) {
        #if os(iOS)
            UNUserNotificationCenter.current().setBadgeCount(unreadCount)
        #endif
    }
}
