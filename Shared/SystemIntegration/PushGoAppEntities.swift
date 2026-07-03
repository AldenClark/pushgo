import Foundation

#if canImport(AppIntents)
import AppIntents

protocol PushGoAppEntityValue: AppEntity {
    var id: String { get }
    var title: String { get }
    var subtitle: String? { get }
    var severity: String? { get }
    var state: String? { get }
    var channelID: String? { get }
    var updatedAt: Date { get }
}

struct PushGoMessageEntity: PushGoAppEntityValue {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "PushGo Message")
    static let defaultQuery = PushGoMessageEntityQuery()

    let id: String
    let title: String
    let subtitle: String?
    let severity: String?
    let state: String?
    let channelID: String?
    let updatedAt: Date
    let localMessageID: UUID?

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(title)",
            subtitle: subtitle.map { "\($0)" }
        )
    }

    init(summary: PushGoSystemSummary) {
        id = summary.stableID
        title = summary.title
        subtitle = summary.subtitle ?? summary.bodyPreview
        severity = summary.severity
        state = summary.status
        channelID = summary.channelID
        updatedAt = summary.updatedAt
        localMessageID = summary.localMessageID
    }
}

struct PushGoEventEntity: PushGoAppEntityValue {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "PushGo Event")
    static let defaultQuery = PushGoEventEntityQuery()

    let id: String
    let title: String
    let subtitle: String?
    let severity: String?
    let state: String?
    let channelID: String?
    let updatedAt: Date

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(title)",
            subtitle: subtitle.map { "\($0)" }
        )
    }

    init(summary: PushGoSystemSummary) {
        id = summary.stableID
        title = summary.title
        subtitle = summary.subtitle ?? summary.bodyPreview
        severity = summary.severity
        state = summary.status
        channelID = summary.channelID
        updatedAt = summary.updatedAt
    }
}

struct PushGoThingEntity: PushGoAppEntityValue {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "PushGo Object")
    static let defaultQuery = PushGoThingEntityQuery()

    let id: String
    let title: String
    let subtitle: String?
    let severity: String?
    let state: String?
    let channelID: String?
    let updatedAt: Date

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(title)",
            subtitle: subtitle.map { "\($0)" }
        )
    }

    init(summary: PushGoSystemSummary) {
        id = summary.stableID
        title = summary.title
        subtitle = summary.subtitle ?? summary.bodyPreview
        severity = summary.severity
        state = summary.status
        channelID = summary.channelID
        updatedAt = summary.updatedAt
    }
}
#endif
