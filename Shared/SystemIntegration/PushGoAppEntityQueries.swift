import Foundation

#if canImport(AppIntents)
import AppIntents

struct PushGoMessageEntityQuery: EntityQuery {
    func entities(for identifiers: [PushGoMessageEntity.ID]) async throws -> [PushGoMessageEntity] {
        let store = LocalDataStore()
        let settings = await store.loadSystemIntegrationSettings()
        guard settings.systemSearchEnabled else { return [] }
        let messages = try await store.loadMessages(ids: identifiers.compactMap(UUID.init(uuidString:)))
        return messages
            .map { PushGoSystemSummaryBuilder.summary(for: $0, settings: settings) }
            .filter(\.privacy.mayIndexTitle)
            .map(PushGoMessageEntity.init(summary:))
    }

    func suggestedEntities() async throws -> [PushGoMessageEntity] {
        let store = LocalDataStore()
        let settings = await store.loadSystemIntegrationSettings()
        guard settings.systemSearchEnabled else { return [] }
        let messages = try await store.loadMessagesPage(
            before: nil,
            limit: 40,
            filter: .all,
            channel: nil,
            tag: nil,
            sortMode: .timeDescending
        )
        let prioritized = messages
            .filter { !$0.isRead || $0.severity == .high || $0.severity == .critical }
            .prefix(40)
        return prioritized
            .map { PushGoSystemSummaryBuilder.summary(for: $0, settings: settings) }
            .filter(\.privacy.mayIndexTitle)
            .map(PushGoMessageEntity.init(summary:))
    }
}

struct PushGoEventEntityQuery: EntityQuery {
    func entities(for identifiers: [PushGoEventEntity.ID]) async throws -> [PushGoEventEntity] {
        let store = LocalDataStore()
        let settings = await store.loadSystemIntegrationSettings()
        guard settings.systemSearchEnabled, settings.indexEventsAndThings else { return [] }
        var output: [PushGoEventEntity] = []
        for identifier in identifiers {
            let detail = try await store.loadEventProjectionDetail(eventId: identifier)
            if let summary = PushGoProjectionSummaryBuilder.eventSummary(
                from: detail,
                eventID: identifier,
                settings: settings
            ),
               summary.privacy.mayIndexTitle
            {
                output.append(PushGoEventEntity(summary: summary))
            }
        }
        return output
    }

    func suggestedEntities() async throws -> [PushGoEventEntity] {
        let store = LocalDataStore()
        let settings = await store.loadSystemIntegrationSettings()
        guard settings.systemSearchEnabled, settings.indexEventsAndThings else { return [] }
        let messages = try await store.loadEventMessagesForProjectionPage(before: nil, limit: 40)
        var seen = Set<String>()
        var output: [PushGoEventEntity] = []
        for message in messages {
            guard let eventID = message.eventId,
                  seen.insert(eventID).inserted
            else {
                continue
            }
            let detail = try await store.loadEventProjectionDetail(eventId: eventID)
            if let summary = PushGoProjectionSummaryBuilder.eventSummary(
                from: detail,
                eventID: eventID,
                settings: settings
            ),
               summary.privacy.mayIndexTitle
            {
                output.append(PushGoEventEntity(summary: summary))
            }
        }
        return output
    }
}

struct PushGoThingEntityQuery: EntityQuery {
    func entities(for identifiers: [PushGoThingEntity.ID]) async throws -> [PushGoThingEntity] {
        let store = LocalDataStore()
        let settings = await store.loadSystemIntegrationSettings()
        guard settings.systemSearchEnabled, settings.indexEventsAndThings else { return [] }
        var output: [PushGoThingEntity] = []
        for identifier in identifiers {
            let detail = try await store.loadThingProjectionDetail(thingId: identifier)
            if let summary = PushGoProjectionSummaryBuilder.thingSummary(
                from: detail,
                thingID: identifier,
                settings: settings
            ),
               summary.privacy.mayIndexTitle
            {
                output.append(PushGoThingEntity(summary: summary))
            }
        }
        return output
    }

    func suggestedEntities() async throws -> [PushGoThingEntity] {
        let store = LocalDataStore()
        let settings = await store.loadSystemIntegrationSettings()
        guard settings.systemSearchEnabled, settings.indexEventsAndThings else { return [] }
        let messages = try await store.loadThingMessagesForProjectionPage(before: nil, limit: 40)
        var seen = Set<String>()
        var output: [PushGoThingEntity] = []
        for message in messages {
            guard let thingID = message.thingId,
                  seen.insert(thingID).inserted
            else {
                continue
            }
            let detail = try await store.loadThingProjectionDetail(thingId: thingID)
            if let summary = PushGoProjectionSummaryBuilder.thingSummary(
                from: detail,
                thingID: thingID,
                settings: settings
            ),
               summary.privacy.mayIndexTitle
            {
                output.append(PushGoThingEntity(summary: summary))
            }
        }
        return output
    }
}
#endif
