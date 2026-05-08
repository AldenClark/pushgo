import Foundation
import Observation

private struct EntityProfileSnapshot {
    let title: String?
    let description: String?
    let status: String?
    let message: String?
    let severity: String?
    let tags: [String]
    let startedAt: Date?
    let endedAt: Date?
    let createdAt: Date?
    let deletedAt: Date?
    let state: String?
    let locationType: String?
    let locationValue: String?
    let externalIDs: [String: String]
    let imageURL: URL?
    let imageURLs: [URL]
}

private enum EntityProfileKind {
    case event
    case thing
}

@MainActor
@Observable
final class EntityProjectionViewModel {
    private let environment: AppEnvironment
    private let dataStore: LocalDataStore
    private let eventPageSize = 600
    private let thingPageSize = 900
    private var eventCursor: EntityProjectionPageCursor?
    private var thingCursor: EntityProjectionPageCursor?
    private var hydratedEventIDs = Set<String>()
    private var hydratedThingIDs = Set<String>()
    @ObservationIgnored private var reloadTask: Task<Void, Never>?
    @ObservationIgnored private var pendingReload = false

    private(set) var events: [EventProjection] = []
    private(set) var things: [ThingProjection] = []
    private(set) var hasMoreEvents: Bool = true
    private(set) var hasMoreThings: Bool = true
    private(set) var isLoadingMoreEvents: Bool = false
    private(set) var isLoadingMoreThings: Bool = false
    var error: AppError?

    init(environment: AppEnvironment? = nil) {
        if let environment {
            self.environment = environment
        } else {
            self.environment = AppEnvironment.shared
        }
        dataStore = self.environment.dataStore
    }

    var hasEventData: Bool { !events.isEmpty }
    var hasThingData: Bool { !things.isEmpty }

    func reload() async {
        if let reloadTask {
            pendingReload = true
            await reloadTask.value
            return
        }

        repeat {
            pendingReload = false
            let task = Task { @MainActor in
                await self.performReload()
            }
            reloadTask = task
            await task.value
            reloadTask = nil
        } while pendingReload
    }

    private func performReload() async {
        do {
            resetPaginationState()
            async let eventLoad: Void = loadMoreEventsPage(reset: true)
            async let thingLoad: Void = loadMoreThingsPage(reset: true)
            _ = try await (eventLoad, thingLoad)
            error = nil
        } catch let appError as AppError {
            self.error = appError
        } catch {
            self.error = AppError.wrap(
                error,
                fallbackMessage: LocalizationProvider.localized("operation_failed"),
                code: "entity_projection_reload_failed"
            )
        }
    }

    func loadMoreEvents() async {
        do {
            try await loadMoreEventsPage(reset: false)
            self.error = nil
        } catch let appError as AppError {
            self.error = appError
        } catch {
            self.error = AppError.wrap(
                error,
                fallbackMessage: LocalizationProvider.localized("operation_failed"),
                code: "entity_projection_load_more_events_failed"
            )
        }
    }

    func loadMoreThings() async {
        do {
            try await loadMoreThingsPage(reset: false)
            self.error = nil
        } catch let appError as AppError {
            self.error = appError
        } catch {
            self.error = AppError.wrap(
                error,
                fallbackMessage: LocalizationProvider.localized("operation_failed"),
                code: "entity_projection_load_more_things_failed"
            )
        }
    }

    func ensureEventDetailsLoaded(eventId: String) async {
        let normalized = eventId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }
        guard !hydratedEventIDs.contains(normalized) else { return }
        do {
            let messages = try await dataStore.loadEventMessagesForProjection(eventId: normalized)
            events = mergeEventProjections(events, buildEvents(messages))
            hydratedEventIDs.insert(normalized)
            self.error = nil
        } catch let appError as AppError {
            self.error = appError
        } catch {
            self.error = AppError.wrap(
                error,
                fallbackMessage: LocalizationProvider.localized("operation_failed"),
                code: "entity_event_details_load_failed"
            )
        }
    }

    func ensureThingDetailsLoaded(thingId: String) async {
        let normalized = thingId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }
        guard !hydratedThingIDs.contains(normalized) else { return }
        do {
            let messages = try await dataStore.loadThingMessagesForProjection(thingId: normalized)
            things = mergeThingProjections(things, buildThings(messages))
            hydratedThingIDs.insert(normalized)
            self.error = nil
        } catch let appError as AppError {
            self.error = appError
        } catch {
            self.error = AppError.wrap(
                error,
                fallbackMessage: LocalizationProvider.localized("operation_failed"),
                code: "entity_thing_details_load_failed"
            )
        }
    }

    private func resetPaginationState() {
        eventCursor = nil
        thingCursor = nil
        hydratedEventIDs = []
        hydratedThingIDs = []
        hasMoreEvents = true
        hasMoreThings = true
        isLoadingMoreEvents = false
        isLoadingMoreThings = false
    }

    private func loadMoreEventsPage(reset: Bool) async throws {
        if isLoadingMoreEvents {
            if reset {
                pendingReload = true
            }
            return
        }
        if !reset, !hasMoreEvents { return }
        isLoadingMoreEvents = true
        defer { isLoadingMoreEvents = false }

        if reset {
            eventCursor = nil
            hasMoreEvents = true
        }

        let page = try await dataStore.loadEventMessagesForProjectionPage(
            before: eventCursor,
            limit: eventPageSize
        )
        eventCursor = page.last.map { EntityProjectionPageCursor(receivedAt: $0.receivedAt, id: $0.id) }
        hasMoreEvents = page.count >= eventPageSize
        let pageEvents = buildEvents(page)
        events = reset ? pageEvents : mergeEventProjections(events, pageEvents)
    }

    private func loadMoreThingsPage(reset: Bool) async throws {
        if isLoadingMoreThings {
            if reset {
                pendingReload = true
            }
            return
        }
        if !reset, !hasMoreThings { return }
        isLoadingMoreThings = true
        defer { isLoadingMoreThings = false }

        if reset {
            thingCursor = nil
            hasMoreThings = true
        }

        let page = try await dataStore.loadThingMessagesForProjectionPage(
            before: thingCursor,
            limit: thingPageSize
        )
        thingCursor = page.last.map { EntityProjectionPageCursor(receivedAt: $0.receivedAt, id: $0.id) }
        hasMoreThings = page.count >= thingPageSize
        let pageThings = buildThings(page)
        things = reset ? pageThings : mergeThingProjections(things, pageThings)
    }

    private func buildEvents(
        _ messages: [PushMessage],
        includeSecondaryEvents: Bool = false
    ) -> [EventProjection] {
        let pairs: [(String, EventTimelinePoint)] = messages.compactMap { message in
            if !includeSecondaryEvents {
                guard isTopLevelEventProjection(message) else { return nil }
            }
            guard let eventId = normalizedID(message.eventId) else { return nil }
            let profile = profileSnapshot(fromPayload: message.rawPayload, kind: .event)
            let title = profile?.title
                ?? nonEmpty(message.title)
                ?? eventId
            let displayTitle = payloadString(key: "event_title", payload: message.rawPayload)
            let summary = profile?.description
            let displaySummary = payloadString(key: "event_description", payload: message.rawPayload)
            let status = profile?.status
            let statusMessage = profile?.message

            let point = EventTimelinePoint(
                id: message.id,
                title: title,
                displayTitle: displayTitle,
                summary: summary,
                displaySummary: displaySummary,
                status: status,
                message: statusMessage,
                severity: profile?.severity,
                tags: profile?.tags ?? [],
                state: message.eventState,
                thingId: message.thingId,
                channelId: nonEmpty(message.channel),
                decryptionState: message.decryptionState,
                imageURL: profile?.imageURL,
                imageURLs: profile?.imageURLs ?? [],
                metadata: message.metadata,
                attrsJSON: payloadJSONText(key: "attrs", payload: message.rawPayload),
                happenedAt: eventHappenedAt(for: message)
            )
            return (eventId, point)
        }

        let grouped = Dictionary(grouping: pairs, by: \.0)
        return grouped.compactMap { eventId, values in
            let timeline = values.map(\.1).sorted { $0.happenedAt > $1.happenedAt }
            guard let latest = timeline.first else { return nil }
            let mergedAttrsJSON = mergedEventAttributesJSON(from: timeline)
            let imageURLs = deduplicatedURLs(timeline.flatMap(\.imageURLs))
            return EventProjection(
                id: eventId,
                title: latest.title,
                summary: latest.summary,
                status: latest.status,
                message: latest.message,
                severity: latest.severity,
                tags: latest.tags,
                state: latest.state,
                thingId: latest.thingId,
                channelId: latest.channelId,
                decryptionState: latest.decryptionState,
                imageURL: latest.imageURL,
                imageURLs: imageURLs,
                attrsJSON: mergedAttrsJSON,
                updatedAt: latest.happenedAt,
                timeline: timeline
            )
        }
        .sorted { $0.updatedAt > $1.updatedAt }
    }

    private func buildThings(_ messages: [PushMessage]) -> [ThingProjection] {
        let grouped = Dictionary(grouping: messages.compactMap { message -> (String, PushMessage)? in
            guard let thingId = normalizedID(message.thingId) else { return nil }
            return (thingId, message)
        }, by: \.0)

        return grouped.compactMap { thingId, pairs in
            let entries = pairs.map(\.1).sorted { thingStreamHappenedAt(for: $0) < thingStreamHappenedAt(for: $1) }
            guard !entries.isEmpty else { return nil }

            var attrs: [String: Any] = [:]
            var lastProfile: EntityProfileSnapshot?

            for entry in entries {
                if let profile = profileSnapshot(fromPayload: entry.rawPayload, kind: .thing) {
                    lastProfile = profile
                }
                if let attrsObject = payloadJSONObject(key: "attrs", payload: entry.rawPayload) {
                    if entry.entityType == "thing" {
                        attrs = [:]
                        for (key, value) in attrsObject where (value is NSNull) == false {
                            attrs[key] = value
                        }
                    } else {
                        for (key, value) in attrsObject {
                            if value is NSNull {
                                attrs.removeValue(forKey: key)
                            } else {
                                attrs[key] = value
                            }
                        }
                    }
                }
            }

            let relatedEvents = buildEvents(entries, includeSecondaryEvents: true)
                .map { ThingRelatedEvent(event: $0) }
                .sorted { $0.happenedAt > $1.happenedAt }

            let relatedMessages = entries.compactMap { message -> ThingRelatedMessage? in
                guard message.entityType == "message" else { return nil }
                return ThingRelatedMessage(message: PushMessageSummary(message: message))
            }
            .sorted { $0.happenedAt > $1.happenedAt }
            .uniqued(on: \.messageIdentity)

            let relatedUpdates = entries.compactMap { message -> ThingRelatedUpdate? in
                guard message.entityType == "thing" else { return nil }
                let profile = profileSnapshot(fromPayload: message.rawPayload, kind: .thing)
                let operation = thingOperation(from: message, profile: profile)
                let rawTitle = nonEmpty(message.title) ?? operation
                let title = cleanedThingOperationTitle(rawTitle, operation: operation)
                let summary = nonEmpty(message.resolvedBody.rawText) ?? profile?.description
                let opId = payloadString(key: "op_id", payload: message.rawPayload)
                return ThingRelatedUpdate(
                    id: message.id,
                    operation: operation,
                    title: title,
                    summary: summary,
                    state: profile?.state,
                    opId: opId,
                    happenedAt: thingStreamHappenedAt(for: message)
                )
            }
            .sorted { $0.happenedAt > $1.happenedAt }

            guard let latest = entries.max(by: { thingStreamHappenedAt(for: $0) < thingStreamHappenedAt(for: $1) }) else {
                return nil
            }
            let title = lastProfile?.title
                ?? nonEmpty(latest.title)
                ?? thingId
            let summary = lastProfile?.description
            let attrsJSON = formattedJSON(attrs)
            return ThingProjection(
                id: thingId,
                title: title,
                summary: summary,
                tags: lastProfile?.tags ?? [],
                state: lastProfile?.state,
                createdAt: lastProfile?.createdAt,
                deletedAt: lastProfile?.deletedAt,
                channelId: nonEmpty(latest.channel),
                decryptionState: latest.decryptionState,
                locationType: lastProfile?.locationType,
                locationValue: lastProfile?.locationValue,
                externalIDs: lastProfile?.externalIDs ?? [:],
                imageURL: lastProfile?.imageURL,
                imageURLs: lastProfile?.imageURLs ?? [],
                metadata: [:],
                attrsJSON: attrsJSON,
                attrsCount: attrs.count,
                updatedAt: thingStreamHappenedAt(for: latest),
                relatedEvents: relatedEvents,
                relatedMessages: relatedMessages,
                relatedUpdates: relatedUpdates
            )
        }
        .sorted { $0.updatedAt > $1.updatedAt }
    }

    private func mergeEventProjections(
        _ existing: [EventProjection],
        _ incoming: [EventProjection]
    ) -> [EventProjection] {
        guard !incoming.isEmpty else { return existing }
        if existing.isEmpty { return incoming }

        var byID: [String: EventProjection] = Dictionary(
            uniqueKeysWithValues: existing.map { ($0.id, $0) }
        )
        for candidate in incoming {
            guard let current = byID[candidate.id] else {
                byID[candidate.id] = candidate
                continue
            }
            byID[candidate.id] = mergeEventProjection(current: current, incoming: candidate)
        }

        return byID.values.sorted { lhs, rhs in
            if lhs.updatedAt == rhs.updatedAt {
                return lhs.id > rhs.id
            }
            return lhs.updatedAt > rhs.updatedAt
        }
    }

    private func mergeEventProjection(
        current: EventProjection,
        incoming: EventProjection
    ) -> EventProjection {
        let mergedTimeline = (current.timeline + incoming.timeline)
            .sorted { $0.happenedAt > $1.happenedAt }
            .uniqued(on: \.id)
        guard let latest = mergedTimeline.first else { return current }
        return EventProjection(
            id: current.id,
            title: latest.title,
            summary: latest.summary,
            status: latest.status,
            message: latest.message,
            severity: latest.severity,
            tags: latest.tags,
            state: latest.state,
            thingId: latest.thingId,
            channelId: latest.channelId,
            decryptionState: latest.decryptionState,
            imageURL: latest.imageURL,
            imageURLs: deduplicatedURLs(mergedTimeline.flatMap(\.imageURLs)),
            attrsJSON: mergedEventAttributesJSON(from: mergedTimeline),
            updatedAt: latest.happenedAt,
            timeline: mergedTimeline
        )
    }

    private func mergeThingProjections(
        _ existing: [ThingProjection],
        _ incoming: [ThingProjection]
    ) -> [ThingProjection] {
        guard !incoming.isEmpty else { return existing }
        if existing.isEmpty { return incoming }

        var byID: [String: ThingProjection] = Dictionary(
            uniqueKeysWithValues: existing.map { ($0.id, $0) }
        )
        for candidate in incoming {
            guard let current = byID[candidate.id] else {
                byID[candidate.id] = candidate
                continue
            }
            byID[candidate.id] = mergeThingProjection(current: current, incoming: candidate)
        }

        return byID.values.sorted { lhs, rhs in
            if lhs.updatedAt == rhs.updatedAt {
                return lhs.id > rhs.id
            }
            return lhs.updatedAt > rhs.updatedAt
        }
    }

    private func mergeThingProjection(
        current: ThingProjection,
        incoming: ThingProjection
    ) -> ThingProjection {
        let latest = incoming.updatedAt >= current.updatedAt ? incoming : current
        let older = incoming.updatedAt >= current.updatedAt ? current : incoming
        let mergedRelatedEvents = (current.relatedEvents + incoming.relatedEvents)
            .sorted { $0.happenedAt > $1.happenedAt }
            .uniqued(on: \.eventId)
        let mergedRelatedMessages = (current.relatedMessages + incoming.relatedMessages)
            .sorted { $0.happenedAt > $1.happenedAt }
            .uniqued(on: \.messageIdentity)
        let mergedRelatedUpdates = (current.relatedUpdates + incoming.relatedUpdates)
            .sorted { $0.happenedAt > $1.happenedAt }
            .uniqued(on: \.id)

        return ThingProjection(
            id: current.id,
            title: latest.title,
            summary: latest.summary ?? older.summary,
            tags: latest.tags.isEmpty ? older.tags : latest.tags,
            state: latest.state,
            createdAt: current.createdAt ?? incoming.createdAt,
            deletedAt: latest.deletedAt ?? older.deletedAt,
            channelId: latest.channelId,
            decryptionState: latest.decryptionState ?? older.decryptionState,
            locationType: latest.locationType,
            locationValue: latest.locationValue,
            externalIDs: older.externalIDs.merging(latest.externalIDs) { _, latestValue in latestValue },
            imageURL: latest.imageURL,
            imageURLs: deduplicatedURLs(current.imageURLs + incoming.imageURLs),
            metadata: [:],
            attrsJSON: mergeJSONObjectStrings(base: older.attrsJSON, overlay: latest.attrsJSON),
            attrsCount: max(current.attrsCount, incoming.attrsCount),
            updatedAt: latest.updatedAt,
            relatedEvents: mergedRelatedEvents,
            relatedMessages: mergedRelatedMessages,
            relatedUpdates: mergedRelatedUpdates
        )
    }

    private func eventHappenedAt(for message: PushMessage) -> Date {
        if let eventTime = epochSeconds(payload: message.rawPayload["event_time"]?.value) {
            return Date(timeIntervalSince1970: eventTime)
        }
        return message.receivedAt
    }

    private func thingStreamHappenedAt(for message: PushMessage) -> Date {
        let entityType = message.entityType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if entityType == "thing",
           let observed = epochSeconds(payload: message.rawPayload["observed_at"]?.value)
        {
            return Date(timeIntervalSince1970: observed)
        }
        if (entityType == "event" || normalizedID(message.eventId) != nil),
           let eventTime = epochSeconds(payload: message.rawPayload["event_time"]?.value)
        {
            return Date(timeIntervalSince1970: eventTime)
        }
        if let observed = epochSeconds(payload: message.rawPayload["observed_at"]?.value) {
            return Date(timeIntervalSince1970: observed)
        }
        return message.receivedAt
    }

    private func epochSeconds(payload: Any?) -> TimeInterval? {
        guard let seconds = PayloadTimeParser.epochSeconds(from: payload) else { return nil }
        return TimeInterval(seconds)
    }

    private func nonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private func thingOperation(from message: PushMessage, profile: EntityProfileSnapshot?) -> String {
        let title = nonEmpty(message.title) ?? ""
        let lowered = title.lowercased()
        if lowered.hasPrefix("create:")
            || lowered.hasPrefix("created:")
            || title.hasPrefix("创建:")
        {
            return "CREATE"
        }
        if lowered.hasPrefix("archive:")
            || lowered.hasPrefix("archived:")
            || title.hasPrefix("存档:")
        {
            return "ARCHIVE"
        }
        if lowered.hasPrefix("delete:")
            || lowered.hasPrefix("deleted:")
            || title.hasPrefix("删除:")
        {
            return "DELETE"
        }
        if lowered.hasPrefix("update:")
            || lowered.hasPrefix("updated:")
            || title.hasPrefix("更新:")
        {
            return "UPDATE"
        }

        switch profile?.state?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "deleted":
            return "DELETE"
        case "archived", "inactive":
            return "ARCHIVE"
        case "active":
            return "UPDATE"
        default:
            return "UPDATE"
        }
    }

    private func cleanedThingOperationTitle(_ raw: String, operation: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return operation }
        let separators = [":", "："]
        for separator in separators {
            let parts = trimmed.split(separator: Character(separator), maxSplits: 1, omittingEmptySubsequences: true)
            if parts.count == 2 {
                let left = parts[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                let isOperationPrefix =
                    left == "create"
                    || left == "created"
                    || left == "update"
                    || left == "updated"
                    || left == "archive"
                    || left == "archived"
                    || left == "delete"
                    || left == "deleted"
                    || left == "创建"
                    || left == "更新"
                    || left == "存档"
                    || left == "删除"
                if isOperationPrefix {
                    let right = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !right.isEmpty {
                        return right
                    }
                }
            }
        }
        return trimmed
    }

    private func normalizedID(_ value: String?) -> String? {
        nonEmpty(value)
    }

    private func isTopLevelEventProjection(_ message: PushMessage) -> Bool {
        ProjectionSemantics.isTopLevelEventProjection(
            entityType: message.entityType,
            eventId: normalizedID(message.eventId),
            thingId: normalizedID(message.thingId),
            projectionDestination: message.projectionDestination
        )
    }

    private func payloadString(
        key: String,
        payload: [String: AnyCodable]
    ) -> String? {
        nonEmpty(payload[key]?.value as? String)
    }

    private func payloadJSONObject(
        key: String,
        payload: [String: AnyCodable]
    ) -> [String: Any]? {
        if let object = payload[key]?.value as? [String: Any] {
            return object
        }
        guard let text = payloadString(key: key, payload: payload),
              let data = text.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data),
              let object = value as? [String: Any]
        else {
            return nil
        }
        return object
    }

    private func payloadJSONText(
        key: String,
        payload: [String: AnyCodable]
    ) -> String? {
        if let object = payloadJSONObject(key: key, payload: payload) {
            return formattedJSON(object)
        }
        return payloadString(key: key, payload: payload)
    }

    private func profileSnapshot(
        fromPayload payload: [String: AnyCodable],
        kind: EntityProfileKind
    ) -> EntityProfileSnapshot? {
        var object: [String: Any] = [:]
        for key in [
            "title", "description", "status", "message", "severity", "tags", "started_at",
            "ended_at", "created_at", "deleted_at", "state", "location_type", "location_value",
            "location", "external_ids", "primary_image", "images"
        ] {
            if let value = payload[key]?.value {
                object[key] = value
            }
        }
        return profileSnapshot(from: object, kind: kind)
    }

    private func profileSnapshot(
        from object: [String: Any],
        kind: EntityProfileKind
    ) -> EntityProfileSnapshot? {
        if object.isEmpty {
            return nil
        }

        let imageURLs = resolvedURLList(from: object, kind: kind)
        let imageURL = imageURLs.first
        let locationObject = object["location"] as? [String: Any]
        let locationType = nonEmpty(locationObject?["type"] as? String)
            ?? nonEmpty(object["location_type"] as? String)
        let locationValue = nonEmpty(locationObject?["value"] as? String)
            ?? nonEmpty(object["location_value"] as? String)
        return EntityProfileSnapshot(
            title: nonEmpty(object["title"] as? String),
            description: nonEmpty(object["description"] as? String),
            status: nonEmpty(object["status"] as? String),
            message: nonEmpty(object["message"] as? String),
            severity: nonEmpty(object["severity"] as? String),
            tags: stringArray(from: object["tags"]),
            startedAt: date(fromEpoch: object["started_at"]),
            endedAt: date(fromEpoch: object["ended_at"]),
            createdAt: date(fromEpoch: object["created_at"]),
            deletedAt: date(fromEpoch: object["deleted_at"]),
            state: nonEmpty(object["state"] as? String),
            locationType: locationType,
            locationValue: locationValue,
            externalIDs: stringDictionary(from: object["external_ids"]),
            imageURL: imageURL,
            imageURLs: imageURLs
        )
    }

    private func resolvedURLList(from object: [String: Any], kind: EntityProfileKind) -> [URL] {
        var urls: [URL] = []
        switch kind {
        case .event:
            appendResolvedURLs(from: object["images"] as? [Any], into: &urls)
        case .thing:
            appendResolvedURL(from: nonEmpty(object["primary_image"] as? String), into: &urls)
            appendResolvedURLs(from: object["images"] as? [Any], into: &urls)
        }
        return deduplicatedURLs(urls)
    }

    private func appendResolvedURL(from raw: String?, into target: inout [URL]) {
        guard let raw, let resolved = URLSanitizer.resolveHTTPSURL(from: raw) else { return }
        target.append(resolved)
    }

    private func appendResolvedURLs(from raw: [Any]?, into target: inout [URL]) {
        guard let raw else { return }
        for item in raw {
            guard let text = nonEmpty(item as? String) else { continue }
            if let resolved = URLSanitizer.resolveHTTPSURL(from: text) {
                target.append(resolved)
            }
        }
    }

    private func deduplicatedURLs(_ raw: [URL]) -> [URL] {
        var seen: Set<String> = []
        var output: [URL] = []
        for url in raw {
            let key = url.absoluteString
            if seen.insert(key).inserted {
                output.append(url)
            }
        }
        return output
    }

    private func stringArray(from value: Any?) -> [String] {
        guard let raw = value as? [Any] else { return [] }
        var out: [String] = []
        for item in raw {
            guard let text = nonEmpty(item as? String) else { continue }
            if !out.contains(text) {
                out.append(text)
            }
        }
        return out
    }

    private func stringDictionary(from value: Any?) -> [String: String] {
        guard let object = value as? [String: Any] else { return [:] }
        var output: [String: String] = [:]
        for (key, rawValue) in object {
            let trimmedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedKey.isEmpty else { continue }
            guard let text = scalarDisplayValue(rawValue) else { continue }
            output[trimmedKey] = text
        }
        return output
    }

    private func scalarDisplayValue(_ value: Any) -> String? {
        switch value {
        case let text as String:
            return nonEmpty(text)
        case let value as Int:
            return String(value)
        case let value as Int64:
            return String(value)
        case let value as Double:
            return String(value)
        case let value as Bool:
            return value ? "true" : "false"
        case let value as NSNumber:
            return value.stringValue
        default:
            return nil
        }
    }

    private func date(fromEpoch value: Any?) -> Date? {
        guard let epoch = epochSeconds(payload: value) else { return nil }
        return Date(timeIntervalSince1970: epoch)
    }

    private func formattedJSON(_ object: [String: Any]) -> String? {
        guard !object.isEmpty else { return nil }
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(
                  withJSONObject: object,
                  options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
              )
        else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private func mergedEventAttributesJSON(from timeline: [EventTimelinePoint]) -> String? {
        let ordered = timeline.sorted { $0.happenedAt < $1.happenedAt }
        var merged: [String: Any] = [:]
        for point in ordered {
            guard let patch = jsonObject(from: point.attrsJSON) else { continue }
            for (key, value) in patch {
                if value is NSNull {
                    merged.removeValue(forKey: key)
                } else {
                    merged[key] = value
                }
            }
        }
        return formattedJSON(merged)
    }

    private func jsonObject(from jsonText: String?) -> [String: Any]? {
        guard let jsonText = nonEmpty(jsonText),
              let data = jsonText.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data),
              let object = json as? [String: Any]
        else {
            return nil
        }
        return object
    }

    private func mergeJSONObjectStrings(base: String?, overlay: String?) -> String? {
        let baseObject = jsonObject(from: base) ?? [:]
        let overlayObject = jsonObject(from: overlay) ?? [:]
        guard !baseObject.isEmpty || !overlayObject.isEmpty else { return nil }

        var merged = baseObject
        for (key, value) in overlayObject {
            if value is NSNull {
                merged.removeValue(forKey: key)
            } else {
                merged[key] = value
            }
        }
        return formattedJSON(merged)
    }

    func deleteEvent(eventId: String) async throws {
        let normalized = normalizedID(eventId) ?? ""
        guard !normalized.isEmpty else { return }
        _ = try await dataStore.deleteEventRecords(eventId: normalized)
        await reload()
    }

    func deleteEvents(eventIds: [String]) async throws -> Int {
        let normalized = Array(Set(eventIds.compactMap(normalizedID)))
        guard !normalized.isEmpty else { return 0 }
        var deleted = 0
        for eventId in normalized {
            deleted += try await dataStore.deleteEventRecords(eventId: eventId)
        }
        await reload()
        return deleted
    }

    func deleteEvents(channelId: String?) async throws -> Int {
        let normalized = normalizedID(channelId)
        let deleted = try await dataStore.deleteEventRecords(channel: normalized)
        await reload()
        return deleted
    }

    func closeEvent(event: EventProjection) async throws {
        let eventId = normalizedID(event.id) ?? ""
        guard !eventId.isEmpty else { return }
        guard let channelId = normalizedID(event.channelId), !channelId.isEmpty else {
            throw AppError.typedLocal(
                code: "event_missing_channel_id",
                category: .validation,
                message: LocalizationProvider.localized("operation_failed"),
                detail: "event missing channel_id"
            )
        }
        try await environment.closeEvent(
            eventId: eventId,
            thingId: normalizedID(event.thingId),
            channelId: channelId,
            severity: normalizedID(event.severity)
        )
        await reload()
    }

    func deleteThing(thingId: String) async throws {
        let normalized = normalizedID(thingId) ?? ""
        guard !normalized.isEmpty else { return }
        _ = try await dataStore.deleteThingRecords(thingId: normalized)
        await reload()
    }

    func deleteThings(channelId: String?) async throws -> Int {
        let normalized = normalizedID(channelId)
        let deleted = try await dataStore.deleteThingRecords(channel: normalized)
        await reload()
        return deleted
    }
}

private extension Array {
    func uniqued<Key: Hashable>(on keyPath: KeyPath<Element, Key>) -> [Element] {
        var seen: Set<Key> = []
        var output: [Element] = []
        output.reserveCapacity(count)
        for item in self {
            let key = item[keyPath: keyPath]
            if seen.insert(key).inserted {
                output.append(item)
            }
        }
        return output
    }
}
