import Foundation

#if canImport(AppIntents)
import AppIntents

struct PushGoAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: SummarizeRecentPushGoMessagesIntent(),
            phrases: [
                "What's new in \(.applicationName)",
                "Summarize recent \(.applicationName) messages",
                "What new messages are in \(.applicationName)",
                "\(.applicationName) 最近有什么新消息",
                "最近 \(.applicationName) 中有什么新消息",
                "最近 \(.applicationName) 有些什么新消息",
            ],
            shortTitle: "Recent Messages",
            systemImageName: "text.bubble"
        )
        AppShortcut(
            intent: SummarizeUnreadPushGoMessagesIntent(),
            phrases: [
                "Summarize unread \(.applicationName) messages",
                "What unread messages are in \(.applicationName)",
                "How many unread messages are in \(.applicationName)",
                "\(.applicationName) 有哪些未读消息",
                "\(.applicationName) 有多少未读消息",
                "读一下 \(.applicationName) 未读消息",
            ],
            shortTitle: "Unread Summary",
            systemImageName: "envelope.badge"
        )
        AppShortcut(
            intent: SummarizeRecentCriticalPushGoEventsIntent(),
            phrases: [
                "Summarize critical \(.applicationName) events",
                "What critical events are in \(.applicationName)",
                "\(.applicationName) 有哪些严重事件",
                "最近 \(.applicationName) 有什么严重事件",
                "\(.applicationName) 有多少严重事件",
            ],
            shortTitle: "Critical Events",
            systemImageName: "bolt.badge.exclamationmark"
        )
        AppShortcut(
            intent: SummarizePushGoObjectStatusIntent(),
            phrases: [
                "Summarize \(.applicationName) object status",
                "What objects need attention in \(.applicationName)",
                "\(.applicationName) 对象状态怎么样",
                "\(.applicationName) 有哪些对象异常",
            ],
            shortTitle: "Object Status",
            systemImageName: "shippingbox.and.arrow.backward"
        )
        AppShortcut(
            intent: QueryPushGoObjectStatusIntent(),
            phrases: [
                "What is the status of \(\.$object) in \(.applicationName)",
                "Check \(\.$object) in \(.applicationName)",
                "查询 \(.applicationName) 中 \(\.$object) 的状态",
                "\(.applicationName) 里 \(\.$object) 状态怎么样",
            ],
            shortTitle: "Object Query",
            systemImageName: "shippingbox.circle"
        )
        AppShortcut(
            intent: OpenBestMatchingPushGoItemIntent(),
            phrases: [
                "Open the latest important item in \(.applicationName)",
                "Open recent critical event in \(.applicationName)",
                "打开 \(.applicationName) 最近的严重事件",
                "打开 \(.applicationName) 最新重要内容",
            ],
            shortTitle: "Open Match",
            systemImageName: "arrow.up.forward.app"
        )
        AppShortcut(
            intent: GetPushGoUnreadCountIntent(),
            phrases: [
                "Count unread \(.applicationName) messages",
                "\(.applicationName) 未读消息数量",
            ],
            shortTitle: "Unread Count",
            systemImageName: "number.circle"
        )
        AppShortcut(
            intent: OpenPushGoMessageListIntent(),
            phrases: [
                "Open \(.applicationName) messages",
                "Open message list in \(.applicationName)",
                "打开 \(.applicationName) 消息列表",
                "用 \(.applicationName) 打开消息列表",
            ],
            shortTitle: "Messages",
            systemImageName: "tray.full"
        )
        AppShortcut(
            intent: OpenPushGoEventListIntent(),
            phrases: [
                "Open \(.applicationName) events",
                "Open event list in \(.applicationName)",
                "打开 \(.applicationName) 事件列表",
            ],
            shortTitle: "Events",
            systemImageName: "waveform.path.ecg"
        )
        AppShortcut(
            intent: OpenPushGoObjectListIntent(),
            phrases: [
                "Open \(.applicationName) objects",
                "Open object list in \(.applicationName)",
                "打开 \(.applicationName) 对象列表",
            ],
            shortTitle: "Objects",
            systemImageName: "shippingbox"
        )
    }
}
#endif
