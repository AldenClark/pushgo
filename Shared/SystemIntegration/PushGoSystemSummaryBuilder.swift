import Foundation

enum PushGoSystemSummaryBuilder {
    static func summary(
        for message: PushMessage,
        settings: SystemIntegrationSettings = SystemIntegrationSettings()
    ) -> PushGoSystemSummary {
        let privacy = PushGoSystemPrivacyPolicy.privacy(for: message, settings: settings)
        let stableID = message.id.uuidString
        let bodyPreview = privacy.mayIndexBody ? normalized(message.bodyPreview) : nil
        let severity = message.severity?.rawValue
        let status = message.isRead ? "read" : "unread"
        let title = normalized(message.title) ?? "Message"
        let subtitle = normalized(message.channel)
        let searchableText = searchableText([
            privacy.mayIndexTitle ? title : nil,
            bodyPreview,
            subtitle,
            severity,
            message.messageId,
            message.eventId,
            message.thingId,
            message.tags.joined(separator: " "),
            privacy.mayExposeMetadata
                ? SystemIntegrationSettings.metadataSearchText(from: message.metadata)
                : nil,
        ])
        let base = PushGoSystemSummary(
            kind: .message,
            stableID: stableID,
            localMessageID: message.id,
            title: title,
            subtitle: subtitle,
            bodyPreview: bodyPreview,
            status: status,
            severity: severity,
            tags: message.tags,
            channelID: normalized(message.channel),
            eventID: normalized(message.eventId),
            thingID: normalized(message.thingId),
            updatedAt: message.receivedAt,
            imageURL: message.imageURL,
            searchableText: searchableText,
            accessibilityLabel: "",
            accessibilityValue: nil,
            privacy: privacy
        )
        return base.withAccessibility()
    }

    static func summary(
        for event: EventProjection,
        settings: SystemIntegrationSettings = SystemIntegrationSettings()
    ) -> PushGoSystemSummary {
        let privacy = PushGoSystemPrivacyPolicy.privacy(
            kind: .event,
            channelID: event.channelId,
            decryptionState: event.decryptionState,
            settings: settings
        )
        let title = normalized(event.title) ?? event.id
        let bodyPreview = privacy.mayIndexBody
            ? normalized(event.summary) ?? normalized(event.message)
            : nil
        let searchableText = searchableText([
            privacy.mayIndexTitle ? title : nil,
            bodyPreview,
            event.status,
            event.state,
            event.severity,
            event.thingId,
            event.channelId,
            event.tags.joined(separator: " "),
            privacy.mayExposeMetadata
                ? SystemIntegrationSettings.metadataSearchText(
                    from: event.timeline.reduce(into: [String: String]()) { result, point in
                        result.merge(point.metadata) { _, latest in latest }
                    }
                )
                : nil,
        ])
        let base = PushGoSystemSummary(
            kind: .event,
            stableID: event.id,
            localMessageID: nil,
            title: title,
            subtitle: normalized(event.status) ?? normalized(event.state),
            bodyPreview: bodyPreview,
            status: normalized(event.state) ?? normalized(event.status),
            severity: normalized(event.severity),
            tags: event.tags,
            channelID: normalized(event.channelId),
            eventID: event.id,
            thingID: normalized(event.thingId),
            updatedAt: event.updatedAt,
            imageURL: event.imageURL,
            searchableText: searchableText,
            accessibilityLabel: "",
            accessibilityValue: nil,
            privacy: privacy
        )
        return base.withAccessibility()
    }

    static func summary(
        for thing: ThingProjection,
        settings: SystemIntegrationSettings = SystemIntegrationSettings()
    ) -> PushGoSystemSummary {
        let privacy = PushGoSystemPrivacyPolicy.privacy(
            kind: .thing,
            channelID: thing.channelId,
            decryptionState: thing.decryptionState,
            settings: settings
        )
        let title = normalized(thing.title) ?? thing.id
        let bodyPreview = privacy.mayIndexBody ? normalized(thing.summary) : nil
        let externalIDs = privacy.mayExposeMetadata
            ? SystemIntegrationSettings.metadataSearchText(from: thing.externalIDs)
            : nil
        let searchableText = searchableText([
            privacy.mayIndexTitle ? title : nil,
            bodyPreview,
            thing.state,
            thing.channelId,
            privacy.mayExposeMetadata ? thing.locationType : nil,
            privacy.mayExposeMetadata ? thing.locationValue : nil,
            externalIDs,
            thing.tags.joined(separator: " "),
            privacy.mayExposeMetadata
                ? SystemIntegrationSettings.metadataSearchText(from: thing.metadata)
                : nil,
        ])
        let base = PushGoSystemSummary(
            kind: .thing,
            stableID: thing.id,
            localMessageID: nil,
            title: title,
            subtitle: normalized(thing.state),
            bodyPreview: bodyPreview,
            status: normalized(thing.state),
            severity: nil,
            tags: thing.tags,
            channelID: normalized(thing.channelId),
            eventID: nil,
            thingID: thing.id,
            updatedAt: thing.updatedAt,
            imageURL: thing.imageURL,
            searchableText: searchableText,
            accessibilityLabel: "",
            accessibilityValue: nil,
            privacy: privacy
        )
        return base.withAccessibility()
    }

    private static func normalized(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func searchableText(_ values: [String?]) -> String {
        values.compactMap(normalized).joined(separator: " ")
    }
}

private extension PushGoSystemSummary {
    func withAccessibility() -> PushGoSystemSummary {
        PushGoSystemSummary(
            kind: kind,
            stableID: stableID,
            localMessageID: localMessageID,
            title: title,
            subtitle: subtitle,
            bodyPreview: bodyPreview,
            status: status,
            severity: severity,
            tags: tags,
            channelID: channelID,
            eventID: eventID,
            thingID: thingID,
            updatedAt: updatedAt,
            imageURL: imageURL,
            searchableText: searchableText,
            accessibilityLabel: PushGoAccessibilitySummaryBuilder.label(for: self),
            accessibilityValue: PushGoAccessibilitySummaryBuilder.value(for: self),
            privacy: privacy
        )
    }
}
