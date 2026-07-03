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
            .filter { !settings.excludesChannel($0.channel) }
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
#endif
