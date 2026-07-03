import Foundation

#if canImport(AppIntents)
import AppIntents

struct PushGoAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: OpenPushGoMessageIntent(),
            phrases: [
                "Open message in \(.applicationName)",
                "用 \(.applicationName) 打开消息",
            ],
            shortTitle: "Open Message",
            systemImageName: "message"
        )
        AppShortcut(
            intent: OpenPushGoEventIntent(),
            phrases: [
                "Open event in \(.applicationName)",
                "用 \(.applicationName) 打开事件",
            ],
            shortTitle: "Open Event",
            systemImageName: "exclamationmark.triangle"
        )
        AppShortcut(
            intent: OpenPushGoThingIntent(),
            phrases: [
                "Open object in \(.applicationName)",
                "用 \(.applicationName) 打开对象",
            ],
            shortTitle: "Open Object",
            systemImageName: "shippingbox"
        )
        AppShortcut(
            intent: OpenRecentCriticalPushGoEventIntent(),
            phrases: [
                "Open recent critical event in \(.applicationName)",
                "用 \(.applicationName) 打开最近严重事件",
            ],
            shortTitle: "Critical Event",
            systemImageName: "bolt.badge.exclamationmark"
        )
        AppShortcut(
            intent: MarkPushGoMessageReadIntent(),
            phrases: [
                "Mark \(.applicationName) message as read",
                "将 \(.applicationName) 消息标为已读",
            ],
            shortTitle: "Mark Read",
            systemImageName: "checkmark.message"
        )
    }
}
#endif
