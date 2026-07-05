import Foundation

#if canImport(ActivityKit) && os(iOS)
import ActivityKit

struct PushGoEventActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable, Sendable {
        var title: String
        var state: String?
        var severity: String?
        var updatedAt: Date
    }

    var eventID: String
    var channelID: String?
}
#endif
