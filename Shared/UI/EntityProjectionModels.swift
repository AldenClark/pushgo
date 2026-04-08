import Foundation

struct EventTimelinePoint: Identifiable, Hashable {
    let id: UUID
    let title: String
    let displayTitle: String?
    let summary: String?
    let displaySummary: String?
    let status: String?
    let message: String?
    let severity: String?
    let tags: [String]
    let state: String?
    let thingId: String?
    let channelId: String?
    let imageURL: URL?
    let imageURLs: [URL]
    let metadata: [String: String]
    let attrsJSON: String?
    let happenedAt: Date
}

struct EventProjection: Identifiable, Hashable {
    let id: String
    let title: String
    let summary: String?
    let status: String?
    let message: String?
    let severity: String?
    let tags: [String]
    let state: String?
    let thingId: String?
    let channelId: String?
    let imageURL: URL?
    let imageURLs: [URL]
    let attrsJSON: String?
    let updatedAt: Date
    let timeline: [EventTimelinePoint]
}

struct ThingRelatedEvent: Identifiable, Hashable {
    let event: EventProjection

    var id: String { event.id }
    var eventId: String { event.id }
    var title: String { event.title }
    var state: String? { event.state }
    var attrsJSON: String? { event.attrsJSON }
    var metadata: [String: String] { event.timeline.first?.metadata ?? [:] }
    var happenedAt: Date { event.updatedAt }
}

struct ThingRelatedMessage: Identifiable, Hashable {
    let message: PushMessageSummary

    var id: UUID { message.id }
    var title: String { message.title }
    var summary: String? {
        let trimmed = message.bodyPreview.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
    var channelId: String? { message.channel }
    var happenedAt: Date { message.receivedAt }
    var messageIdentity: String {
        let messageId = message.messageId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return messageId.isEmpty ? message.id.uuidString : messageId
    }
}

struct ThingRelatedUpdate: Identifiable, Hashable {
    let id: UUID
    let operation: String
    let title: String
    let summary: String?
    let state: String?
    let opId: String?
    let happenedAt: Date
}

struct ThingProjection: Identifiable, Hashable {
    let id: String
    let title: String
    let summary: String?
    let tags: [String]
    let state: String?
    let createdAt: Date?
    let deletedAt: Date?
    let channelId: String?
    let locationType: String?
    let locationValue: String?
    let externalIDs: [String: String]
    let imageURL: URL?
    let imageURLs: [URL]
    let metadata: [String: String]
    let attrsJSON: String?
    let attrsCount: Int
    let updatedAt: Date
    let relatedEvents: [ThingRelatedEvent]
    let relatedMessages: [ThingRelatedMessage]
    let relatedUpdates: [ThingRelatedUpdate]
}

