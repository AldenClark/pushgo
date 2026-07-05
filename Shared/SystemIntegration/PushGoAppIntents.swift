import Foundation

#if canImport(AppIntents)
import AppIntents

struct OpenPushGoMessageIntent: AppIntent {
    static let title: LocalizedStringResource = "Open PushGo Message"
    static let description = IntentDescription("Open a PushGo message detail.")
    static let openAppWhenRun = true

    @Parameter(title: "Message")
    var message: PushGoMessageEntity

    func perform() async throws -> some IntentResult {
        guard let target = PushGoSystemOpenTarget(
            kind: .message,
            identifier: message.id,
            localMessageID: message.localMessageID ?? UUID(uuidString: message.id),
            source: .appIntent
        ) else { return .result() }
        await PushGoSystemIntentRouter.shared.setPendingTarget(target)
        return .result()
    }
}

struct OpenPushGoMessageListIntent: AppIntent {
    static let title: LocalizedStringResource = "Open PushGo Messages"
    static let description = IntentDescription("Open the PushGo message list.")
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult & ProvidesDialog {
        await PushGoSystemIntentRouter.shared.setPendingTarget(
            PushGoSystemOpenTarget.list(kind: .message, source: .appIntent)
        )
        return .result(dialog: "Opening PushGo messages.")
    }
}

struct OpenPushGoEventListIntent: AppIntent {
    static let title: LocalizedStringResource = "Open PushGo Events"
    static let description = IntentDescription("Open the PushGo event list.")
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult & ProvidesDialog {
        await PushGoSystemIntentRouter.shared.setPendingTarget(
            PushGoSystemOpenTarget.list(kind: .event, source: .appIntent)
        )
        return .result(dialog: "Opening PushGo events.")
    }
}

struct OpenPushGoObjectListIntent: AppIntent {
    static let title: LocalizedStringResource = "Open PushGo Objects"
    static let description = IntentDescription("Open the PushGo object list.")
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult & ProvidesDialog {
        await PushGoSystemIntentRouter.shared.setPendingTarget(
            PushGoSystemOpenTarget.list(kind: .thing, source: .appIntent)
        )
        return .result(dialog: "Opening PushGo objects.")
    }
}

enum PushGoSection: String, AppEnum {
    case messages
    case events
    case objects

    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(name: "PushGo Section")
    }

    static var caseDisplayRepresentations: [PushGoSection: DisplayRepresentation] {
        [
            .messages: DisplayRepresentation(title: "Messages"),
            .events: DisplayRepresentation(title: "Events"),
            .objects: DisplayRepresentation(title: "Objects"),
        ]
    }

    var systemKind: PushGoSystemEntityKind {
        switch self {
        case .messages:
            return .message
        case .events:
            return .event
        case .objects:
            return .thing
        }
    }

    var displayName: String {
        switch self {
        case .messages:
            return "messages"
        case .events:
            return "events"
        case .objects:
            return "objects"
        }
    }
}

struct OpenPushGoSectionIntent: AppIntent {
    static let title: LocalizedStringResource = "Open PushGo Section"
    static let description = IntentDescription("Open a PushGo list section.")
    static let openAppWhenRun = true

    @Parameter(title: "Section")
    var section: PushGoSection

    func perform() async throws -> some IntentResult & ProvidesDialog {
        await PushGoSystemIntentRouter.shared.setPendingTarget(
            PushGoSystemOpenTarget.list(kind: section.systemKind, source: .appIntent)
        )
        return .result(dialog: IntentDialog(stringLiteral: "Opening PushGo \(section.displayName)."))
    }
}

struct OpenPushGoEventIntent: AppIntent {
    static let title: LocalizedStringResource = "Open PushGo Event"
    static let description = IntentDescription("Open a PushGo event detail.")
    static let openAppWhenRun = true

    @Parameter(title: "Event")
    var event: PushGoEventEntity

    func perform() async throws -> some IntentResult {
        guard let target = PushGoSystemOpenTarget(kind: .event, identifier: event.id, source: .appIntent) else {
            return .result()
        }
        await PushGoSystemIntentRouter.shared.setPendingTarget(target)
        return .result()
    }
}

struct OpenPushGoThingIntent: AppIntent {
    static let title: LocalizedStringResource = "Open PushGo Object"
    static let description = IntentDescription("Open a PushGo object detail.")
    static let openAppWhenRun = true

    @Parameter(title: "Object")
    var thing: PushGoThingEntity

    func perform() async throws -> some IntentResult {
        guard let target = PushGoSystemOpenTarget(kind: .thing, identifier: thing.id, source: .appIntent) else {
            return .result()
        }
        await PushGoSystemIntentRouter.shared.setPendingTarget(target)
        return .result()
    }
}

struct SummarizeRecentPushGoMessagesIntent: AppIntent {
    static let title: LocalizedStringResource = "Summarize Recent PushGo Messages"
    static let description = IntentDescription("Summarize recent PushGo messages without opening the app.")
    static let openAppWhenRun = false

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let summary = await PushGoSiriSummaryProvider.recentMessagesSummary()
        return .result(value: summary, dialog: IntentDialog(stringLiteral: summary))
    }
}

struct SummarizeUnreadPushGoMessagesIntent: AppIntent {
    static let title: LocalizedStringResource = "Summarize Unread PushGo Messages"
    static let description = IntentDescription("Summarize unread PushGo messages without opening the app.")
    static let openAppWhenRun = false

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let summary = await PushGoSiriSummaryProvider.unreadMessagesSummary()
        return .result(value: summary, dialog: IntentDialog(stringLiteral: summary))
    }
}

struct SummarizeRecentCriticalPushGoEventsIntent: AppIntent {
    static let title: LocalizedStringResource = "Summarize Critical PushGo Events"
    static let description = IntentDescription("Summarize recent high or critical PushGo events without opening the app.")
    static let openAppWhenRun = false

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let summary = await PushGoSiriSummaryProvider.criticalEventsSummary()
        return .result(value: summary, dialog: IntentDialog(stringLiteral: summary))
    }
}

struct GetPushGoUnreadCountIntent: AppIntent {
    static let title: LocalizedStringResource = "Get PushGo Unread Count"
    static let description = IntentDescription("Return the PushGo unread message count.")
    static let openAppWhenRun = false

    func perform() async throws -> some IntentResult & ReturnsValue<Int> & ProvidesDialog {
        let count = await PushGoSiriSummaryProvider.unreadCount()
        return .result(
            value: count,
            dialog: IntentDialog(stringLiteral: "PushGo has \(count) unread messages.")
        )
    }
}

struct GetPushGoCriticalEventCountIntent: AppIntent {
    static let title: LocalizedStringResource = "Get PushGo Critical Event Count"
    static let description = IntentDescription("Return the PushGo high priority event count.")
    static let openAppWhenRun = false

    func perform() async throws -> some IntentResult & ReturnsValue<Int> & ProvidesDialog {
        let count = await PushGoSiriSummaryProvider.criticalEventCount()
        return .result(
            value: count,
            dialog: IntentDialog(stringLiteral: "PushGo has \(count) high priority events.")
        )
    }
}

struct GetPushGoObjectWarningCountIntent: AppIntent {
    static let title: LocalizedStringResource = "Get PushGo Object Warning Count"
    static let description = IntentDescription("Return the number of PushGo objects that need attention.")
    static let openAppWhenRun = false

    func perform() async throws -> some IntentResult & ReturnsValue<Int> & ProvidesDialog {
        let count = await PushGoSiriSummaryProvider.objectWarningCount()
        return .result(
            value: count,
            dialog: IntentDialog(stringLiteral: "PushGo has \(count) objects that need attention.")
        )
    }
}

struct SummarizePushGoObjectStatusIntent: AppIntent {
    static let title: LocalizedStringResource = "Summarize PushGo Object Status"
    static let description = IntentDescription("Summarize PushGo object states without opening the app.")
    static let openAppWhenRun = false

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let summary = await PushGoSiriSummaryProvider.objectStatusSummary()
        return .result(value: summary, dialog: IntentDialog(stringLiteral: summary))
    }
}

struct OpenRecentCriticalPushGoEventIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Recent Critical PushGo Event"
    static let description = IntentDescription("Open the most recent high or critical PushGo event.")
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult {
        let store = LocalDataStore()
        let settings = await store.loadSystemIntegrationSettings()
        guard settings.systemSearchEnabled, settings.indexEventsAndThings else {
            return .result()
        }
        let messages = try await store.loadEventMessagesForProjectionPage(before: nil, limit: 80)
        let candidates = messages
            .sorted { lhs, rhs in
                intentPriority(for: lhs) < intentPriority(for: rhs)
            }
        for message in candidates {
            guard let eventID = message.eventId,
                  let detail = try? await store.loadEventProjectionDetail(eventId: eventID),
                  let summary = PushGoProjectionSummaryBuilder.eventSummary(
                    from: detail,
                    eventID: eventID,
                    settings: settings
                  ),
                  summary.privacy.mayIndexTitle,
                  let target = PushGoSystemOpenTarget.event(identifier: eventID, source: .appIntent)
            else {
                continue
            }
            await PushGoSystemIntentRouter.shared.setPendingTarget(target)
            break
        }
        return .result()
    }

    private func intentPriority(for message: PushMessage) -> Int {
        switch message.severity {
        case .critical:
            return 0
        case .high:
            return 1
        default:
            return 2
        }
    }
}

struct MarkPushGoMessageReadIntent: AppIntent {
    static let title: LocalizedStringResource = "Mark PushGo Message as Read"
    static let description = IntentDescription("Mark a PushGo message as read without opening the app.")
    static let openAppWhenRun = false

    @Parameter(title: "Message")
    var message: PushGoMessageEntity

    func perform() async throws -> some IntentResult {
        guard let uuid = message.localMessageID ?? UUID(uuidString: message.id) else {
            return .result()
        }
        let store = LocalDataStore()
        let coordinator = await MainActor.run {
            MessageStateCoordinator(dataStore: store) {}
        }
        try await coordinator.markRead(messageId: uuid)
        return .result()
    }
}

private enum PushGoSiriSummaryProvider {
    static func unreadCount() async -> Int {
        await snapshot().counts.unreadMessages
    }

    static func criticalEventCount() async -> Int {
        await snapshot().counts.criticalEvents
    }

    static func objectWarningCount() async -> Int {
        await snapshot().counts.objectWarnings
    }

    static func recentMessagesSummary(limit: Int = 5) async -> String {
        let currentSnapshot = await snapshot()
        if !currentSnapshot.recentMessages.isEmpty {
            return PushGoSystemSnapshotProjector.summaryText(
                for: .recentMessages,
                snapshot: currentSnapshot,
                limit: 3
            )
        }
        let store = LocalDataStore()
        let settings = await store.loadSystemIntegrationSettings()
        let messages = ((try? await store.loadMessagesPage(
            before: nil,
            limit: limit,
            filter: .all,
            channel: nil,
            tag: nil,
            sortMode: .timeDescending
        )) ?? [])
            .map { PushGoSystemSummaryBuilder.summary(for: $0, settings: settings) }
            .filter(\.privacy.mayIndexTitle)
        guard !messages.isEmpty else {
            return "PushGo has no recent messages."
        }
        return summary(
            prefix: "Recent PushGo messages",
            summaries: messages,
            includeUnreadCount: ((try? await store.messageCounts().unread) ?? 0)
        )
    }

    static func unreadMessagesSummary(limit: Int = 5) async -> String {
        let currentSnapshot = await snapshot()
        if !currentSnapshot.unreadMessages.isEmpty || currentSnapshot.counts.unreadMessages == 0 {
            return PushGoSystemSnapshotProjector.summaryText(
                for: .unreadMessages,
                snapshot: currentSnapshot,
                limit: 3
            )
        }
        let store = LocalDataStore()
        let settings = await store.loadSystemIntegrationSettings()
        let messages = ((try? await store.loadMessagesPage(
            before: nil,
            limit: limit,
            filter: .unreadOnly,
            channel: nil,
            tag: nil,
            sortMode: .timeDescending
        )) ?? [])
            .map { PushGoSystemSummaryBuilder.summary(for: $0, settings: settings) }
            .filter(\.privacy.mayIndexTitle)
        let unreadCount = (try? await store.messageCounts().unread) ?? messages.count
        guard !messages.isEmpty else {
            return "PushGo has no unread messages."
        }
        return summary(prefix: "\(unreadCount) unread PushGo messages", summaries: messages)
    }

    static func criticalEventsSummary(limit: Int = 5) async -> String {
        let currentSnapshot = await snapshot()
        if !currentSnapshot.criticalEvents.isEmpty || currentSnapshot.counts.criticalEvents == 0 {
            return PushGoSystemSnapshotProjector.summaryText(
                for: .criticalEvents,
                snapshot: currentSnapshot,
                limit: 3
            )
        }
        let store = LocalDataStore()
        let settings = await store.loadSystemIntegrationSettings()
        let messages = ((try? await store.loadEventMessagesForProjectionPage(before: nil, limit: 80)) ?? [])
            .filter { $0.severity == .critical || $0.severity == .high }
            .sorted { lhs, rhs in
                eventPriority(lhs) < eventPriority(rhs)
            }
        var summaries: [PushGoSystemSummary] = []
        for message in messages {
            guard let eventID = message.eventId,
                  let detail = try? await store.loadEventProjectionDetail(eventId: eventID),
                  let summary = PushGoProjectionSummaryBuilder.eventSummary(
                    from: detail,
                    eventID: eventID,
                    settings: settings
                  ),
                  summary.privacy.mayIndexTitle
            else {
                continue
            }
            summaries.append(summary)
            if summaries.count >= limit { break }
        }
        guard !summaries.isEmpty else {
            return "PushGo has no recent high priority events."
        }
        return summary(prefix: "Recent high priority PushGo events", summaries: summaries)
    }

    static func objectStatusSummary() async -> String {
        PushGoSystemSnapshotProjector.summaryText(for: .objectStatus, snapshot: await snapshot(), limit: 3)
    }

    private static func snapshot() async -> PushGoSystemSurfaceSnapshot {
        if let existing = PushGoSystemSnapshotStore.load() {
            return existing
        }
        let store = LocalDataStore()
        await store.rebuildSystemSurfaceSnapshot()
        return PushGoSystemSnapshotStore.load() ?? .empty(source: "siri")
    }

    private static func summary(
        prefix: String,
        summaries: [PushGoSystemSummary],
        includeUnreadCount: Int? = nil
    ) -> String {
        let titles = summaries
            .prefix(3)
            .map(\.title)
            .joined(separator: "; ")
        if let includeUnreadCount {
            return "\(prefix): \(titles). Unread: \(includeUnreadCount)."
        }
        return "\(prefix): \(titles)."
    }

    private static func eventPriority(_ message: PushMessage) -> Int {
        switch message.severity {
        case .critical:
            return 0
        case .high:
            return 1
        default:
            return 2
        }
    }
}
#endif
