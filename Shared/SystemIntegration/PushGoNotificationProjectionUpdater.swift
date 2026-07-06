import Foundation
import UserNotifications

struct PushGoNotificationProjectionUpdate: Equatable, Sendable {
    let snapshot: PushGoSystemSurfaceSnapshot
    let summary: PushGoSystemSummary?
    let unreadCount: Int
    let insertedUnread: Bool
}

enum PushGoNotificationProjectionUpdater {
    private static let defaultLimit = 5

    static func update(
        content: UNNotificationContent,
        requestIdentifier: String?,
        appGroupIdentifier: String = AppConstants.appGroupIdentifier,
        fileManager: FileManager = .default,
        now: Date = Date(),
        spotlightIndexer: PushGoSpotlightIndexing? = CoreSpotlightPushGoIndexer()
    ) async -> PushGoNotificationProjectionUpdate? {
        guard let update = makeUpdate(
            content: content,
            requestIdentifier: requestIdentifier,
            existingSnapshot: PushGoSystemSnapshotStore.load(
                fileManager: fileManager,
                appGroupIdentifier: appGroupIdentifier
            ),
            now: now
        ) else {
            return nil
        }

        guard PushGoSystemSnapshotStore.write(
            update.snapshot,
            fileManager: fileManager,
            appGroupIdentifier: appGroupIdentifier
        ) else {
            return nil
        }

        if let summary = update.summary {
            try? await spotlightIndexer?.index([summary])
        }

        await MainActor.run {
            BadgeManager.syncExtensionBadge(unreadCount: update.unreadCount)
        }
        return update
    }

    static func makeUpdate(
        content: UNNotificationContent,
        requestIdentifier: String?,
        existingSnapshot: PushGoSystemSurfaceSnapshot?,
        now: Date = Date(),
        limit: Int = defaultLimit
    ) -> PushGoNotificationProjectionUpdate? {
        guard !NotificationHandling.shouldSkipPersistence(for: content.userInfo),
              let summary = summary(
                  content: content,
                  requestIdentifier: requestIdentifier,
                  now: now
              )
        else {
            return nil
        }

        let existing = existingSnapshot ?? .empty(source: "nse-seed", now: now)
        let item = safeSnapshotItem(from: summary)
        let previousUnreadMessages = existing.unreadMessages.filter { $0.id != item.id }
        let insertedUnread = !existing.unreadMessages.contains { $0.id == item.id }

        let recentMessages = merged(
            item,
            into: existing.recentMessages,
            limit: limit,
            sort: newestFirst
        )
        let unreadMessages = merged(
            item,
            into: previousUnreadMessages,
            limit: limit,
            sort: newestFirst
        )
        let counts = PushGoSystemSurfaceSnapshot.Counts(
            totalMessages: max(existing.counts.totalMessages + (insertedUnread ? 1 : 0), recentMessages.count),
            unreadMessages: max(existing.counts.unreadMessages + (insertedUnread ? 1 : 0), unreadMessages.count),
            criticalEvents: existing.counts.criticalEvents,
            objectWarnings: existing.counts.objectWarnings
        )
        let snapshot = PushGoSystemSurfaceSnapshot(
            schemaVersion: PushGoSystemSurfaceSnapshot.schemaVersion,
            generatedAtEpochMs: PushGoSystemSurfaceSnapshot.epochMilliseconds(now),
            source: "nse-projection",
            counts: counts,
            focusState: existing.focusState,
            recentMessages: recentMessages,
            unreadMessages: unreadMessages,
            criticalEvents: existing.criticalEvents,
            objectWarnings: existing.objectWarnings,
            latestObjectStates: existing.latestObjectStates
        )
        return PushGoNotificationProjectionUpdate(
            snapshot: snapshot,
            summary: PushGoSystemSurfaceSnapshot.item(from: summary, source: .notification) == nil ? nil : summary,
            unreadCount: counts.unreadMessages,
            insertedUnread: insertedUnread
        )
    }

    static func summary(
        content: UNNotificationContent,
        requestIdentifier: String?,
        now: Date = Date()
    ) -> PushGoSystemSummary? {
        guard let normalized = NotificationHandling.normalizeRemoteNotificationForDisplay(content.userInfo) else {
            return nil
        }
        let rawPayload = codablePayload(from: normalized.rawPayload)
        let receivedAt = PayloadTimeParser.date(from: rawPayload["sent_at"]) ?? now
        let message = PushMessage(
            id: stableLocalID(from: normalized, requestIdentifier: requestIdentifier),
            messageId: stableMessageIdentifier(from: normalized, requestIdentifier: requestIdentifier),
            title: normalized.title,
            body: normalized.body,
            channel: normalized.channel,
            url: normalized.url,
            isRead: false,
            receivedAt: receivedAt,
            rawPayload: rawPayload,
            status: normalized.decryptionState == .decryptOk ? .decrypted : .normal,
            decryptionState: normalized.decryptionState
        )
        let privacy = PushGoSystemPrivacyPolicy.privacy(for: message)
        let stableID = message.messageId ?? message.id.uuidString
        let title = normalizedText(message.title) ?? "Message"
        let bodyPreview = privacy.mayIndexBody ? normalizedText(message.bodyPreview) : nil
        let searchableText = searchableText([
            privacy.mayIndexTitle ? title : nil,
            bodyPreview,
            normalizedText(message.channel),
            message.severity?.rawValue,
            message.messageId,
            message.eventId,
            message.thingId,
            message.tags.joined(separator: " "),
            privacy.mayExposeMetadata
                ? SystemIntegrationSettings.metadataSearchText(from: message.metadata)
                : nil,
        ])
        let summary = PushGoSystemSummary(
            kind: .message,
            stableID: stableID,
            localMessageID: message.id,
            title: title,
            subtitle: normalizedText(message.channel),
            bodyPreview: bodyPreview,
            status: "unread",
            severity: message.severity?.rawValue,
            tags: message.tags,
            channelID: normalizedText(message.channel),
            eventID: normalizedText(message.eventId),
            thingID: normalizedText(message.thingId),
            updatedAt: message.receivedAt,
            imageURL: message.imageURL,
            searchableText: searchableText,
            accessibilityLabel: "",
            accessibilityValue: nil,
            privacy: privacy
        )
        return PushGoSystemSummary(
            kind: summary.kind,
            stableID: summary.stableID,
            localMessageID: summary.localMessageID,
            title: summary.title,
            subtitle: summary.subtitle,
            bodyPreview: summary.bodyPreview,
            status: summary.status,
            severity: summary.severity,
            tags: summary.tags,
            channelID: summary.channelID,
            eventID: summary.eventID,
            thingID: summary.thingID,
            updatedAt: summary.updatedAt,
            imageURL: summary.imageURL,
            searchableText: summary.searchableText,
            accessibilityLabel: PushGoAccessibilitySummaryBuilder.label(for: summary),
            accessibilityValue: PushGoAccessibilitySummaryBuilder.value(for: summary),
            privacy: summary.privacy
        )
    }

    private static func merged(
        _ item: PushGoSystemSurfaceSnapshot.Item?,
        into existing: [PushGoSystemSurfaceSnapshot.Item],
        limit: Int,
        sort: (PushGoSystemSurfaceSnapshot.Item, PushGoSystemSurfaceSnapshot.Item) -> Bool
    ) -> [PushGoSystemSurfaceSnapshot.Item] {
        var merged = existing
        if let item {
            merged.removeAll { $0.id == item.id }
            merged.append(item)
        }
        return Array(merged.sorted(by: sort).prefix(max(1, limit)))
    }

    private static func safeSnapshotItem(from summary: PushGoSystemSummary) -> PushGoSystemSurfaceSnapshot.Item {
        if let item = PushGoSystemSurfaceSnapshot.item(from: summary, source: .notification) {
            return item
        }
        return PushGoSystemSurfaceSnapshot.Item(
            id: "\(summary.kind.rawValue):\(summary.stableID)",
            kind: summary.kind,
            title: "PushGo message",
            subtitle: nil,
            bodyPreview: nil,
            status: summary.status,
            severity: nil,
            channelID: nil,
            eventID: nil,
            thingID: nil,
            updatedAtEpochMs: PushGoSystemSurfaceSnapshot.epochMilliseconds(summary.updatedAt),
            imageURL: nil,
            accessibilityLabel: "Unread PushGo message",
            accessibilityValue: nil,
            openTarget: PushGoSystemOpenTarget(
                kind: summary.kind,
                identifier: summary.stableID,
                localMessageID: summary.localMessageID,
                source: .notification
            )
        )
    }

    private static func newestFirst(
        lhs: PushGoSystemSurfaceSnapshot.Item,
        rhs: PushGoSystemSurfaceSnapshot.Item
    ) -> Bool {
        lhs.updatedAtEpochMs > rhs.updatedAtEpochMs
    }

    private static func stableLocalID(
        from normalized: NormalizedRemoteNotification,
        requestIdentifier: String?
    ) -> UUID {
        let seed = stableMessageIdentifier(from: normalized, requestIdentifier: requestIdentifier)
        return UUID(uuidString: seed) ?? deterministicUUID(from: seed)
    }

    private static func stableMessageIdentifier(
        from normalized: NormalizedRemoteNotification,
        requestIdentifier: String?
    ) -> String {
        normalizedText(normalized.messageId)
            ?? normalizedText(normalized.entityId)
            ?? normalizedText(requestIdentifier)
            ?? UUID().uuidString.lowercased()
    }

    private static func deterministicUUID(from text: String) -> UUID {
        var hash = fnv1a128(text)
        hash[6] = (hash[6] & 0x0f) | 0x50
        hash[8] = (hash[8] & 0x3f) | 0x80
        return UUID(uuid: (
            hash[0], hash[1], hash[2], hash[3],
            hash[4], hash[5],
            hash[6], hash[7],
            hash[8], hash[9],
            hash[10], hash[11], hash[12], hash[13], hash[14], hash[15]
        ))
    }

    private static func fnv1a128(_ text: String) -> [UInt8] {
        var low: UInt64 = 0xcbf2_9ce4_8422_2325
        var high: UInt64 = 0x8422_2325_cbf2_9ce4
        for byte in text.utf8 {
            low ^= UInt64(byte)
            low &*= 0x0000_0100_0000_01b3
            high ^= UInt64(byte) &+ low
            high &*= 0x0000_0100_0000_01b3
        }
        var output: [UInt8] = []
        output.reserveCapacity(16)
        for shift in stride(from: 56, through: 0, by: -8) {
            output.append(UInt8((high >> UInt64(shift)) & 0xff))
        }
        for shift in stride(from: 56, through: 0, by: -8) {
            output.append(UInt8((low >> UInt64(shift)) & 0xff))
        }
        return output
    }

    private static func codablePayload(from payload: [AnyHashable: Any]) -> [String: AnyCodable] {
        UserInfoSanitizer.sanitize(payload).reduce(into: [String: AnyCodable]()) { result, item in
            result[item.key] = AnyCodable(item.value)
        }
    }

    private static func searchableText(_ values: [String?]) -> String {
        values.compactMap(normalizedText).joined(separator: " ")
    }

    private static func normalizedText(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}
