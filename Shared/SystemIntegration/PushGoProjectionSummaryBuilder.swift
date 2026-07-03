import Foundation

enum PushGoProjectionSummaryBuilder {
    static func eventSummary(
        from detail: EntityProjectionDetail,
        eventID: String,
        settings: SystemIntegrationSettings = SystemIntegrationSettings()
    ) -> PushGoSystemSummary? {
        guard let head = detail.head ?? detail.history.first else { return nil }
        let timeline = detail.messages
        let tags = orderedUnique(timeline.flatMap(\.tags))
        let title = nonEmpty(head.title) ?? eventID
        let summary = nonEmpty(head.bodyPreview) ?? nonEmpty(head.body)
        let updatedAt = timeline.map(\.receivedAt).max() ?? head.receivedAt
        let projection = EventProjection(
            id: eventID,
            title: title,
            summary: summary,
            status: head.eventState,
            message: summary,
            severity: head.severity?.rawValue,
            tags: tags,
            state: head.eventState,
            thingId: head.thingId,
            channelId: head.channel,
            decryptionState: head.decryptionState,
            imageURL: head.imageURL,
            imageURLs: orderedUniqueURLs(timeline.flatMap(\.imageURLs)),
            attrsJSON: nil,
            updatedAt: updatedAt,
            timeline: []
        )
        return PushGoSystemSummaryBuilder.summary(for: projection, settings: settings)
    }

    static func thingSummary(
        from detail: EntityProjectionDetail,
        thingID: String,
        settings: SystemIntegrationSettings = SystemIntegrationSettings()
    ) -> PushGoSystemSummary? {
        guard let head = detail.head ?? detail.history.first else { return nil }
        let timeline = detail.messages
        let tags = orderedUnique(timeline.flatMap(\.tags))
        let title = nonEmpty(head.title) ?? thingID
        let summary = nonEmpty(head.bodyPreview) ?? nonEmpty(head.body)
        let updatedAt = timeline.map(\.receivedAt).max() ?? head.receivedAt
        let projection = ThingProjection(
            id: thingID,
            title: title,
            summary: summary,
            tags: tags,
            state: head.eventState,
            createdAt: nil,
            deletedAt: nil,
            channelId: head.channel,
            decryptionState: head.decryptionState,
            locationType: nil,
            locationValue: nil,
            externalIDs: [:],
            imageURL: head.imageURL,
            imageURLs: orderedUniqueURLs(timeline.flatMap(\.imageURLs)),
            metadata: head.metadata,
            attrsJSON: nil,
            attrsCount: head.metadata.count,
            updatedAt: updatedAt,
            relatedEvents: [],
            relatedMessages: [],
            relatedUpdates: []
        )
        return PushGoSystemSummaryBuilder.summary(for: projection, settings: settings)
    }

    private static func nonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func orderedUnique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for value in values {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { continue }
            result.append(trimmed)
        }
        return result
    }

    private static func orderedUniqueURLs(_ values: [URL]) -> [URL] {
        var seen = Set<String>()
        var result: [URL] = []
        for value in values {
            let key = value.absoluteString
            guard seen.insert(key).inserted else { continue }
            result.append(value)
        }
        return result
    }
}
