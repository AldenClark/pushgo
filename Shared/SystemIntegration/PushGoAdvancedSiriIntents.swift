import Foundation

#if canImport(AppIntents)
import AppIntents

enum PushGoSiriQueryKind: String, AppEnum {
    case recentMessages
    case unreadMessages
    case criticalEvents
    case objectStatus

    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(name: "PushGo Query")
    }

    static var caseDisplayRepresentations: [PushGoSiriQueryKind: DisplayRepresentation] {
        [
            .recentMessages: DisplayRepresentation(title: "Recent messages"),
            .unreadMessages: DisplayRepresentation(title: "Unread messages"),
            .criticalEvents: DisplayRepresentation(title: "Critical events"),
            .objectStatus: DisplayRepresentation(title: "Object status"),
        ]
    }

    var summaryKind: PushGoShortcutSummaryKind {
        switch self {
        case .recentMessages:
            return .recentMessages
        case .unreadMessages:
            return .unreadMessages
        case .criticalEvents:
            return .criticalEvents
        case .objectStatus:
            return .objectStatus
        }
    }
}

enum PushGoSiriTimeRange: String, AppEnum {
    case latest
    case today
    case last24Hours

    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(name: "PushGo Time Range")
    }

    static var caseDisplayRepresentations: [PushGoSiriTimeRange: DisplayRepresentation] {
        [
            .latest: DisplayRepresentation(title: "Latest"),
            .today: DisplayRepresentation(title: "Today"),
            .last24Hours: DisplayRepresentation(title: "Last 24 hours"),
        ]
    }
}

enum PushGoSiriPriority: String, AppEnum {
    case any
    case high
    case critical

    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(name: "PushGo Priority")
    }

    static var caseDisplayRepresentations: [PushGoSiriPriority: DisplayRepresentation] {
        [
            .any: DisplayRepresentation(title: "Any priority"),
            .high: DisplayRepresentation(title: "High priority"),
            .critical: DisplayRepresentation(title: "Critical only"),
        ]
    }
}

struct QueryPushGoStatusIntent: AppIntent {
    static let title: LocalizedStringResource = "Query PushGo Status"
    static let description = IntentDescription("Ask PushGo about recent messages, unread messages, critical events or object status.")
    static let openAppWhenRun = false

    @Parameter(title: "Query")
    var query: PushGoSiriQueryKind

    @Parameter(title: "Time Range")
    var timeRange: PushGoSiriTimeRange?

    @Parameter(title: "Priority")
    var priority: PushGoSiriPriority?

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let snapshot = await PushGoAdvancedSiriSummaryProvider.snapshot()
        let summary = PushGoAdvancedSiriSummaryProvider.summary(
            query: query,
            timeRange: timeRange ?? .latest,
            priority: priority ?? .any,
            snapshot: snapshot
        )
        return .result(value: summary, dialog: IntentDialog(stringLiteral: summary))
    }
}

struct QueryPushGoObjectStatusIntent: AppIntent {
    static let title: LocalizedStringResource = "Query PushGo Object Status"
    static let description = IntentDescription("Ask PushGo for a safe status summary for a specific object.")
    static let openAppWhenRun = false

    @Parameter(title: "Object")
    var object: PushGoThingEntity

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let snapshot = await PushGoAdvancedSiriSummaryProvider.snapshot()
        let summary = PushGoAdvancedSiriSummaryProvider.objectStatusSummary(
            objectID: object.id,
            fallbackTitle: object.title,
            snapshot: snapshot
        )
        return .result(value: summary, dialog: IntentDialog(stringLiteral: summary))
    }
}

struct OpenBestMatchingPushGoItemIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Best Matching PushGo Item"
    static let description = IntentDescription("Open the best matching PushGo message, event or object, falling back to the matching list.")
    static let openAppWhenRun = true

    @Parameter(title: "Query")
    var query: PushGoSiriQueryKind

    @Parameter(title: "Time Range")
    var timeRange: PushGoSiriTimeRange?

    @Parameter(title: "Priority")
    var priority: PushGoSiriPriority?

    func perform() async throws -> some IntentResult {
        let snapshot = await PushGoAdvancedSiriSummaryProvider.snapshot()
        let target = PushGoAdvancedSiriSummaryProvider.bestOpenTarget(
            query: query,
            timeRange: timeRange ?? .latest,
            priority: priority ?? .any,
            snapshot: snapshot
        )
        await PushGoSystemIntentRouter.shared.setPendingTarget(target)
        return .result()
    }
}

enum PushGoAdvancedSiriSummaryProvider {
    static func snapshot() async -> PushGoSystemSurfaceSnapshot {
        if let existing = PushGoSystemSnapshotStore.load() {
            return existing
        }
        let store = LocalDataStore()
        await store.rebuildSystemSurfaceSnapshot()
        return PushGoSystemSnapshotStore.load() ?? .empty(source: "advanced-siri")
    }

    static func summary(
        query: PushGoSiriQueryKind,
        timeRange: PushGoSiriTimeRange,
        priority: PushGoSiriPriority,
        snapshot: PushGoSystemSurfaceSnapshot
    ) -> String {
        let filtered = filteredSnapshot(
            snapshot,
            query: query,
            timeRange: timeRange,
            priority: priority
        )
        return PushGoSystemSnapshotProjector.summaryText(
            for: query.summaryKind,
            snapshot: filtered,
            limit: 3
        )
    }

    static func objectStatusSummary(
        objectID: String,
        fallbackTitle: String,
        snapshot: PushGoSystemSurfaceSnapshot
    ) -> String {
        let candidates = snapshot.objectWarnings + snapshot.latestObjectStates
        if let match = candidates.first(where: { $0.thingID == objectID || $0.id == "thing:\(objectID)" }) {
            let state = match.status ?? match.severity ?? "current"
            if let subtitle = match.subtitle, !subtitle.isEmpty {
                return "\(match.title) is \(state). \(subtitle)."
            }
            return "\(match.title) is \(state)."
        }
        return "PushGo has no current status summary for \(fallbackTitle)."
    }

    static func bestOpenTarget(
        query: PushGoSiriQueryKind,
        timeRange: PushGoSiriTimeRange,
        priority: PushGoSiriPriority,
        snapshot: PushGoSystemSurfaceSnapshot
    ) -> PushGoSystemOpenTarget {
        let filtered = filteredSnapshot(
            snapshot,
            query: query,
            timeRange: timeRange,
            priority: priority
        )
        let item: PushGoSystemSurfaceSnapshot.Item?
        switch query {
        case .recentMessages:
            item = filtered.recentMessages.first
        case .unreadMessages:
            item = filtered.unreadMessages.first ?? filtered.recentMessages.first
        case .criticalEvents:
            item = filtered.criticalEvents.first
        case .objectStatus:
            item = filtered.objectWarnings.first ?? filtered.latestObjectStates.first
        }
        if let target = item?.openTarget {
            return PushGoSystemOpenTarget(
                kind: target.kind,
                identifier: target.identifier,
                localMessageID: target.localMessageID,
                source: .appIntent,
                destination: target.destination
            ) ?? listTarget(for: query)
        }
        return listTarget(for: query)
    }

    private static func filteredSnapshot(
        _ snapshot: PushGoSystemSurfaceSnapshot,
        query: PushGoSiriQueryKind,
        timeRange: PushGoSiriTimeRange,
        priority: PushGoSiriPriority
    ) -> PushGoSystemSurfaceSnapshot {
        let cutoff = cutoffDate(for: timeRange)
        let filterItems: ([PushGoSystemSurfaceSnapshot.Item]) -> [PushGoSystemSurfaceSnapshot.Item] = { items in
            items.filter { item in
                if let cutoff, item.updatedAt < cutoff {
                    return false
                }
                switch priority {
                case .any:
                    return true
                case .high:
                    return item.severity == "high" || item.severity == "critical"
                case .critical:
                    return item.severity == "critical"
                }
            }
        }
        let recent = filterItems(snapshot.recentMessages)
        let unread = filterItems(snapshot.unreadMessages)
        let critical = filterItems(snapshot.criticalEvents)
        let objectWarnings = filterItems(snapshot.objectWarnings)
        let latestObjects = filterItems(snapshot.latestObjectStates)
        let counts = PushGoSystemSurfaceSnapshot.Counts(
            totalMessages: snapshot.counts.totalMessages,
            unreadMessages: query == .unreadMessages ? unread.count : snapshot.counts.unreadMessages,
            criticalEvents: query == .criticalEvents ? critical.count : snapshot.counts.criticalEvents,
            objectWarnings: query == .objectStatus ? objectWarnings.count : snapshot.counts.objectWarnings
        )
        return PushGoSystemSurfaceSnapshot(
            schemaVersion: snapshot.schemaVersion,
            generatedAtEpochMs: snapshot.generatedAtEpochMs,
            source: snapshot.source,
            counts: counts,
            focusState: snapshot.focusState,
            recentMessages: recent,
            unreadMessages: unread,
            criticalEvents: critical,
            objectWarnings: objectWarnings,
            latestObjectStates: latestObjects
        )
    }

    private static func cutoffDate(for range: PushGoSiriTimeRange) -> Date? {
        let now = Date()
        switch range {
        case .latest:
            return nil
        case .today:
            return Calendar.current.startOfDay(for: now)
        case .last24Hours:
            return now.addingTimeInterval(-24 * 60 * 60)
        }
    }

    private static func listTarget(for query: PushGoSiriQueryKind) -> PushGoSystemOpenTarget {
        switch query {
        case .recentMessages, .unreadMessages:
            return PushGoSystemOpenTarget.list(kind: .message, source: .appIntent)
        case .criticalEvents:
            return PushGoSystemOpenTarget.list(kind: .event, source: .appIntent)
        case .objectStatus:
            return PushGoSystemOpenTarget.list(kind: .thing, source: .appIntent)
        }
    }
}
#endif
