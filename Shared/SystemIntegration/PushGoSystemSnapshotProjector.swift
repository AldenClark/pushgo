import Foundation

enum PushGoSystemSnapshotProjector {
    static let defaultLimit = 5

    static func rebuild(
        recentMessages: [PushGoSystemSummary],
        eventSummaries: [PushGoSystemSummary],
        thingSummaries: [PushGoSystemSummary],
        counts: PushGoSystemSurfaceSnapshot.Counts,
        focusState: PushGoSystemSurfaceSnapshot.FocusState = .default(),
        source: String,
        now: Date = Date(),
        limit: Int = defaultLimit
    ) -> PushGoSystemSurfaceSnapshot {
        let safeRecent = safeItems(from: recentMessages, source: .automation)
            .sorted(by: newestFirst)
        let unread = safeRecent
            .filter { $0.status == "unread" }
        let criticalEvents = safeItems(from: eventSummaries, source: .automation)
            .filter(isCriticalOrHigh)
            .sorted(by: eventPriority)
        let objectStates = safeItems(from: thingSummaries, source: .automation)
            .sorted(by: newestFirst)
        let objectWarnings = objectStates
            .filter(isWarningObject)

        return PushGoSystemSurfaceSnapshot(
            schemaVersion: PushGoSystemSurfaceSnapshot.schemaVersion,
            generatedAtEpochMs: PushGoSystemSurfaceSnapshot.epochMilliseconds(now),
            source: normalizedText(source) ?? "unknown",
            counts: counts,
            focusState: focusState,
            recentMessages: Array(safeRecent.prefix(limit)),
            unreadMessages: Array(unread.prefix(limit)),
            criticalEvents: Array(criticalEvents.prefix(limit)),
            objectWarnings: Array(objectWarnings.prefix(limit)),
            latestObjectStates: Array(objectStates.prefix(limit))
        )
    }

    static func summaryText(
        for kind: PushGoShortcutSummaryKind,
        snapshot: PushGoSystemSurfaceSnapshot,
        limit: Int = 3
    ) -> String {
        switch kind {
        case .recentMessages:
            return summary(
                empty: "PushGo has no recent messages.",
                prefix: "Recent PushGo messages",
                items: snapshot.recentMessages,
                suffix: "Unread: \(snapshot.counts.unreadMessages).",
                limit: limit
            )
        case .unreadMessages:
            return summary(
                empty: "PushGo has no unread messages.",
                prefix: "\(snapshot.counts.unreadMessages) unread PushGo messages",
                items: snapshot.unreadMessages,
                suffix: nil,
                limit: limit
            )
        case .criticalEvents:
            return summary(
                empty: "PushGo has no recent high priority events.",
                prefix: "Recent high priority PushGo events",
                items: snapshot.criticalEvents,
                suffix: nil,
                limit: limit
            )
        case .objectStatus:
            return summary(
                empty: "PushGo has no object status warnings.",
                prefix: "\(snapshot.counts.objectWarnings) PushGo objects need attention",
                items: snapshot.objectWarnings.isEmpty ? snapshot.latestObjectStates : snapshot.objectWarnings,
                suffix: nil,
                limit: limit
            )
        }
    }

    private static func safeItems(
        from summaries: [PushGoSystemSummary],
        source: PushGoSystemOpenTarget.Source
    ) -> [PushGoSystemSurfaceSnapshot.Item] {
        summaries.compactMap { PushGoSystemSurfaceSnapshot.item(from: $0, source: source) }
    }

    private static func summary(
        empty: String,
        prefix: String,
        items: [PushGoSystemSurfaceSnapshot.Item],
        suffix: String?,
        limit: Int
    ) -> String {
        guard !items.isEmpty else { return empty }
        let titles = items
            .prefix(max(1, limit))
            .map(\.title)
            .joined(separator: "; ")
        var text = "\(prefix): \(titles)."
        if let suffix {
            text += " \(suffix)"
        }
        return text
    }

    private static func eventPriority(
        lhs: PushGoSystemSurfaceSnapshot.Item,
        rhs: PushGoSystemSurfaceSnapshot.Item
    ) -> Bool {
        let lhsPriority = severityPriority(lhs.severity)
        let rhsPriority = severityPriority(rhs.severity)
        if lhsPriority != rhsPriority {
            return lhsPriority < rhsPriority
        }
        return newestFirst(lhs: lhs, rhs: rhs)
    }

    private static func newestFirst(
        lhs: PushGoSystemSurfaceSnapshot.Item,
        rhs: PushGoSystemSurfaceSnapshot.Item
    ) -> Bool {
        lhs.updatedAtEpochMs > rhs.updatedAtEpochMs
    }

    private static func isCriticalOrHigh(_ item: PushGoSystemSurfaceSnapshot.Item) -> Bool {
        switch normalizedText(item.severity)?.lowercased() {
        case "critical", "high":
            return true
        default:
            return false
        }
    }

    static func isWarningObject(_ item: PushGoSystemSurfaceSnapshot.Item) -> Bool {
        switch normalizedText(item.status)?.lowercased() {
        case "warning", "warn", "degraded", "critical", "high", "open", "failed", "failure", "error", "offline":
            return true
        default:
            return false
        }
    }

    private static func severityPriority(_ value: String?) -> Int {
        switch normalizedText(value)?.lowercased() {
        case "critical":
            return 0
        case "high":
            return 1
        case "medium", "normal":
            return 2
        case "low":
            return 3
        default:
            return 4
        }
    }

    private static func normalizedText(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}
