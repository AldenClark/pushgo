import Foundation

struct NotificationContextSnapshot: Codable, Equatable, Sendable {
    struct EventContext: Codable, Equatable, Sendable {
        let eventId: String
        let title: String?
        let body: String?
        let state: String?
        let channel: String?
        let thingId: String?
        let messageId: String?
        let decryptionStateRaw: String?
        let updatedAtEpochMs: Int64
    }

    struct ThingContext: Codable, Equatable, Sendable {
        let thingId: String
        let title: String?
        let body: String?
        let state: String?
        let channel: String?
        let eventId: String?
        let messageId: String?
        let primaryImage: String?
        let images: [String]
        let decryptionStateRaw: String?
        let updatedAtEpochMs: Int64
    }

    static let schemaVersion = 1

    let schemaVersion: Int
    let generatedAtEpochMs: Int64
    let source: String
    let events: [String: EventContext]
    let things: [String: ThingContext]

    func eventContext(eventId: String?) -> EventContext? {
        guard let normalized = Self.normalizedText(eventId) else { return nil }
        return events[normalized]
    }

    func thingContext(thingId: String?) -> ThingContext? {
        guard let normalized = Self.normalizedText(thingId) else { return nil }
        return things[normalized]
    }

    private static func normalizedText(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}

struct NotificationContextProjectionInput: Sendable {
    let eventId: String?
    let thingId: String?
    let entityId: String?
    let title: String
    let body: String
    let channel: String?
    let messageId: String?
    let decryptionStateRaw: String?
    let eventState: String?
    let receivedAt: Date
    let rawPayload: [String: AnyCodable]
    let imageURLs: [URL]
}

enum NotificationContextSnapshotStore {
    private static let directoryName = "notification-context-snapshot"
    private static let fileName = "snapshot.bin"

    static func snapshotFileURL(
        fileManager: FileManager = .default,
        appGroupIdentifier: String = AppConstants.appGroupIdentifier
    ) -> URL? {
        guard let containerURL = AppConstants.appGroupContainerURL(
            fileManager: fileManager,
            identifier: appGroupIdentifier
        ) else {
            return nil
        }
        return containerURL
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent(directoryName, isDirectory: true)
            .appendingPathComponent(fileName, isDirectory: false)
    }

    static func load(
        fileManager: FileManager = .default,
        appGroupIdentifier: String = AppConstants.appGroupIdentifier
    ) -> NotificationContextSnapshot? {
        guard let fileURL = snapshotFileURL(
            fileManager: fileManager,
            appGroupIdentifier: appGroupIdentifier
        ) else {
            return nil
        }
        return load(from: fileURL, fileManager: fileManager)
    }

    static func load(
        from fileURL: URL,
        fileManager: FileManager = .default
    ) -> NotificationContextSnapshot? {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return nil
        }
        do {
            let data = try Data(contentsOf: fileURL)
            let snapshot = try PropertyListDecoder().decode(NotificationContextSnapshot.self, from: data)
            guard snapshot.schemaVersion == NotificationContextSnapshot.schemaVersion else {
                return nil
            }
            return snapshot
        } catch {
            // Drop corrupted snapshot so future writes/read can self-heal.
            try? fileManager.removeItem(at: fileURL)
            return nil
        }
    }

    @discardableResult
    static func write(
        _ snapshot: NotificationContextSnapshot,
        fileManager: FileManager = .default,
        appGroupIdentifier: String = AppConstants.appGroupIdentifier
    ) -> Bool {
        guard let fileURL = snapshotFileURL(
            fileManager: fileManager,
            appGroupIdentifier: appGroupIdentifier
        ) else {
            return false
        }
        return write(snapshot, to: fileURL, fileManager: fileManager)
    }

    @discardableResult
    static func write(
        _ snapshot: NotificationContextSnapshot,
        to fileURL: URL,
        fileManager: FileManager = .default
    ) -> Bool {
        let directoryURL = fileURL.deletingLastPathComponent()
        do {
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            let data = try encoder.encode(snapshot)
            let temporaryURL = directoryURL.appendingPathComponent(
                ".\(fileName).tmp-\(UUID().uuidString.lowercased())",
                isDirectory: false
            )
            try data.write(to: temporaryURL, options: [])
            if fileManager.fileExists(atPath: fileURL.path) {
                _ = try fileManager.replaceItemAt(
                    fileURL,
                    withItemAt: temporaryURL,
                    backupItemName: nil,
                    options: [.usingNewMetadataOnly]
                )
            } else {
                try fileManager.moveItem(at: temporaryURL, to: fileURL)
            }
            return true
        } catch {
            return false
        }
    }

    @discardableResult
    static func clear(
        fileManager: FileManager = .default,
        appGroupIdentifier: String = AppConstants.appGroupIdentifier
    ) -> Bool {
        guard let fileURL = snapshotFileURL(
            fileManager: fileManager,
            appGroupIdentifier: appGroupIdentifier
        ) else {
            return false
        }
        return clear(at: fileURL, fileManager: fileManager)
    }

    @discardableResult
    static func clear(
        at fileURL: URL,
        fileManager: FileManager = .default
    ) -> Bool {
        guard fileManager.fileExists(atPath: fileURL.path) else { return true }
        do {
            try fileManager.removeItem(at: fileURL)
            return true
        } catch {
            return false
        }
    }
}

enum NotificationContextSnapshotProjector {
    static func rebuild(
        eventMessages: [NotificationContextProjectionInput],
        thingMessages: [NotificationContextProjectionInput],
        source: String,
        now: Date = Date()
    ) -> NotificationContextSnapshot {
        let eventContexts = mergeEventContexts(
            existing: [:],
            messages: eventMessages
        )
        let thingContexts = mergeThingContexts(
            existing: [:],
            messages: thingMessages
        )
        return NotificationContextSnapshot(
            schemaVersion: NotificationContextSnapshot.schemaVersion,
            generatedAtEpochMs: epochMilliseconds(now),
            source: normalizedText(source) ?? "unknown",
            events: eventContexts,
            things: thingContexts
        )
    }

    static func merge(
        existing: NotificationContextSnapshot?,
        eventMessages: [NotificationContextProjectionInput],
        thingMessages: [NotificationContextProjectionInput],
        source: String,
        now: Date = Date()
    ) -> NotificationContextSnapshot {
        let mergedEvents = mergeEventContexts(
            existing: existing?.events ?? [:],
            messages: eventMessages
        )
        let mergedThings = mergeThingContexts(
            existing: existing?.things ?? [:],
            messages: thingMessages
        )
        return NotificationContextSnapshot(
            schemaVersion: NotificationContextSnapshot.schemaVersion,
            generatedAtEpochMs: epochMilliseconds(now),
            source: normalizedText(source) ?? "unknown",
            events: mergedEvents,
            things: mergedThings
        )
    }

    private static func mergeEventContexts(
        existing: [String: NotificationContextSnapshot.EventContext],
        messages: [NotificationContextProjectionInput]
    ) -> [String: NotificationContextSnapshot.EventContext] {
        var output = existing
        for message in messages {
            guard let eventId = normalizedText(message.eventId ?? message.entityId) else { continue }
            let candidate = NotificationContextSnapshot.EventContext(
                eventId: eventId,
                title: normalizedText(message.title),
                body: normalizedBodyForEvent(message.body),
                state: eventState(from: message),
                channel: normalizedText(message.channel),
                thingId: normalizedText(message.thingId),
                messageId: normalizedText(message.messageId),
                decryptionStateRaw: normalizedText(message.decryptionStateRaw),
                updatedAtEpochMs: epochMilliseconds(message.receivedAt)
            )
            if let current = output[eventId] {
                output[eventId] = mergeEventContext(current: current, candidate: candidate)
            } else {
                output[eventId] = candidate
            }
        }
        return output
    }

    private static func mergeThingContexts(
        existing: [String: NotificationContextSnapshot.ThingContext],
        messages: [NotificationContextProjectionInput]
    ) -> [String: NotificationContextSnapshot.ThingContext] {
        var output = existing
        for message in messages {
            guard let thingId = normalizedText(message.thingId ?? message.entityId) else { continue }
            let imageList = normalizedImageURLs(from: message)
            let candidate = NotificationContextSnapshot.ThingContext(
                thingId: thingId,
                title: normalizedText(message.title),
                body: normalizedBodyForThing(message.body),
                state: thingState(from: message),
                channel: normalizedText(message.channel),
                eventId: normalizedText(message.eventId),
                messageId: normalizedText(message.messageId),
                primaryImage: normalizedPrimaryImage(from: message, fallbackImages: imageList),
                images: imageList,
                decryptionStateRaw: normalizedText(message.decryptionStateRaw),
                updatedAtEpochMs: epochMilliseconds(message.receivedAt)
            )
            if let current = output[thingId] {
                output[thingId] = mergeThingContext(current: current, candidate: candidate)
            } else {
                output[thingId] = candidate
            }
        }
        return output
    }

    private static func mergeEventContext(
        current: NotificationContextSnapshot.EventContext,
        candidate: NotificationContextSnapshot.EventContext
    ) -> NotificationContextSnapshot.EventContext {
        let candidateIsNewer = candidate.updatedAtEpochMs >= current.updatedAtEpochMs
        if candidateIsNewer {
            return NotificationContextSnapshot.EventContext(
                eventId: current.eventId,
                title: candidate.title ?? current.title,
                body: preferredBody(
                    candidate: candidate.body,
                    current: current.body,
                    fallback: NotificationPayloadSemantics.gatewayFallbackEventBody
                ),
                state: candidate.state ?? current.state,
                channel: candidate.channel ?? current.channel,
                thingId: candidate.thingId ?? current.thingId,
                messageId: candidate.messageId ?? current.messageId,
                decryptionStateRaw: candidate.decryptionStateRaw ?? current.decryptionStateRaw,
                updatedAtEpochMs: candidate.updatedAtEpochMs
            )
        }
        return NotificationContextSnapshot.EventContext(
            eventId: current.eventId,
            title: current.title ?? candidate.title,
            body: preferredBody(
                candidate: current.body,
                current: candidate.body,
                fallback: NotificationPayloadSemantics.gatewayFallbackEventBody
            ),
            state: current.state ?? candidate.state,
            channel: current.channel ?? candidate.channel,
            thingId: current.thingId ?? candidate.thingId,
            messageId: current.messageId ?? candidate.messageId,
            decryptionStateRaw: current.decryptionStateRaw ?? candidate.decryptionStateRaw,
            updatedAtEpochMs: current.updatedAtEpochMs
        )
    }

    private static func mergeThingContext(
        current: NotificationContextSnapshot.ThingContext,
        candidate: NotificationContextSnapshot.ThingContext
    ) -> NotificationContextSnapshot.ThingContext {
        let candidateIsNewer = candidate.updatedAtEpochMs >= current.updatedAtEpochMs
        if candidateIsNewer {
            return NotificationContextSnapshot.ThingContext(
                thingId: current.thingId,
                title: candidate.title ?? current.title,
                body: preferredBody(
                    candidate: candidate.body,
                    current: current.body,
                    fallback: NotificationPayloadSemantics.gatewayFallbackThingBody
                ),
                state: candidate.state ?? current.state,
                channel: candidate.channel ?? current.channel,
                eventId: candidate.eventId ?? current.eventId,
                messageId: candidate.messageId ?? current.messageId,
                primaryImage: candidate.primaryImage ?? current.primaryImage,
                images: candidate.images.isEmpty ? current.images : candidate.images,
                decryptionStateRaw: candidate.decryptionStateRaw ?? current.decryptionStateRaw,
                updatedAtEpochMs: candidate.updatedAtEpochMs
            )
        }
        return NotificationContextSnapshot.ThingContext(
            thingId: current.thingId,
            title: current.title ?? candidate.title,
            body: preferredBody(
                candidate: current.body,
                current: candidate.body,
                fallback: NotificationPayloadSemantics.gatewayFallbackThingBody
            ),
            state: current.state ?? candidate.state,
            channel: current.channel ?? candidate.channel,
            eventId: current.eventId ?? candidate.eventId,
            messageId: current.messageId ?? candidate.messageId,
            primaryImage: current.primaryImage ?? candidate.primaryImage,
            images: current.images.isEmpty ? candidate.images : current.images,
            decryptionStateRaw: current.decryptionStateRaw ?? candidate.decryptionStateRaw,
            updatedAtEpochMs: current.updatedAtEpochMs
        )
    }

    private static func preferredBody(
        candidate: String?,
        current: String?,
        fallback: String
    ) -> String? {
        let normalizedCandidate = normalizedText(candidate)
        let normalizedCurrent = normalizedText(current)
        switch (normalizedCandidate, normalizedCurrent) {
        case let (candidate?, current?):
            if candidate == fallback, current != fallback {
                return current
            }
            return candidate
        case let (candidate?, nil):
            return candidate
        case let (nil, current?):
            return current
        case (nil, nil):
            return nil
        }
    }

    private static func eventState(from message: NotificationContextProjectionInput) -> String? {
        normalizedText(message.eventState)
            ?? payloadString(["status"], in: message.rawPayload)
    }

    private static func thingState(from message: NotificationContextProjectionInput) -> String? {
        payloadString(["state", "status"], in: message.rawPayload)
    }

    private static func normalizedPrimaryImage(
        from message: NotificationContextProjectionInput,
        fallbackImages: [String]
    ) -> String? {
        payloadString(["primary_image"], in: message.rawPayload)
            ?? fallbackImages.first
    }

    private static func normalizedImageURLs(from message: NotificationContextProjectionInput) -> [String] {
        var dedupe = Set<String>()
        var output: [String] = []
        for url in message.imageURLs {
            let text = normalizedText(url.absoluteString) ?? ""
            guard !text.isEmpty, dedupe.insert(text).inserted else { continue }
            output.append(text)
            if output.count >= 6 { break }
        }
        return output
    }

    private static func payloadString(
        _ keys: [String],
        in payload: [String: AnyCodable]
    ) -> String? {
        keys.compactMap { key in
            (payload[key]?.value as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        .first(where: { !$0.isEmpty })
    }

    private static func normalizedBodyForEvent(_ body: String) -> String? {
        let normalized = normalizedText(body)
        guard normalized != NotificationPayloadSemantics.gatewayFallbackEventBody else {
            return normalized
        }
        return normalized
    }

    private static func normalizedBodyForThing(_ body: String) -> String? {
        let normalized = normalizedText(body)
        guard normalized != NotificationPayloadSemantics.gatewayFallbackThingBody else {
            return normalized
        }
        return normalized
    }

    private static func normalizedText(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func epochMilliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000).rounded())
    }
}
