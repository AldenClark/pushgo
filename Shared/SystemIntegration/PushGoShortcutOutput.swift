import Foundation

struct PushGoShortcutSummary: Codable, Equatable, Sendable {
    let id: String
    let title: String
    let text: String
    let unreadCount: Int
    let criticalEventCount: Int
    let generatedAt: Date

    init(
        id: String = UUID().uuidString,
        title: String,
        text: String,
        unreadCount: Int,
        criticalEventCount: Int,
        generatedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.text = text
        self.unreadCount = unreadCount
        self.criticalEventCount = criticalEventCount
        self.generatedAt = generatedAt
    }
}
