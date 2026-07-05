import Foundation

#if canImport(ActivityKit) && os(iOS)
import ActivityKit
#endif

enum PushGoLiveActivityCoordinator {
    static func handlePersistedMessages(_ messages: [PushMessage]) async {
        for message in messages {
            await handlePersistedMessage(message)
        }
    }

    static func handlePersistedMessage(_ message: PushMessage) async {
        #if canImport(ActivityKit) && os(iOS)
        guard #available(iOS 16.2, *) else { return }
        guard let eventID = normalized(message.eventId ?? eventIDFromEntity(message)) else { return }
        guard shouldUseLiveActivity(for: message) else { return }
        let summary = PushGoSystemSummaryBuilder.summary(for: message)
        guard summary.privacy.mayIndexTitle, !summary.privacy.isEncryptedOrSensitive else { return }
        let state = normalized(summary.status)
        let title = normalized(summary.title) ?? eventID
        let content = PushGoEventActivityAttributes.ContentState(
            title: title,
            state: state,
            severity: normalized(summary.severity),
            updatedAt: message.receivedAt
        )
        if isClosedState(state) {
            await end(eventID: eventID, content: content)
        } else if let existing = activity(eventID: eventID) {
            await existing.update(ActivityContent(state: content, staleDate: nil))
        } else {
            await start(
                eventID: eventID,
                channelID: normalized(message.channel),
                content: content
            )
        }
        #endif
    }

    #if canImport(ActivityKit) && os(iOS)
    @available(iOS 16.2, *)
    private static func start(
        eventID: String,
        channelID: String?,
        content: PushGoEventActivityAttributes.ContentState
    ) async {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let attributes = PushGoEventActivityAttributes(eventID: eventID, channelID: channelID)
        guard let activity = try? Activity.request(
            attributes: attributes,
            content: ActivityContent(state: content, staleDate: nil),
            pushType: .token
        ) else { return }
        observePushTokenUpdates(
            for: activity,
            activityKey: activityKey(eventID: eventID),
            channelID: channelID
        )
    }

    @available(iOS 16.2, *)
    private static func end(
        eventID: String,
        content: PushGoEventActivityAttributes.ContentState
    ) async {
        guard let existing = activity(eventID: eventID) else { return }
        await PushGoLiveActivityTokenRegistrationService.unregister(activityKey: activityKey(eventID: eventID))
        await existing.end(
            ActivityContent(state: content, staleDate: Date().addingTimeInterval(60)),
            dismissalPolicy: .after(Date().addingTimeInterval(60))
        )
    }

    @available(iOS 16.2, *)
    private static func activity(eventID: String) -> Activity<PushGoEventActivityAttributes>? {
        Activity<PushGoEventActivityAttributes>.activities.first { activity in
            activity.attributes.eventID == eventID
        }
    }

    @available(iOS 16.2, *)
    private static func observePushTokenUpdates(
        for activity: Activity<PushGoEventActivityAttributes>,
        activityKey: String,
        channelID: String?
    ) {
        let activityID = activity.id
        Task { [activityID, activityKey, channelID] in
            guard let activity = Activity<PushGoEventActivityAttributes>.activities.first(where: { $0.id == activityID }) else {
                return
            }
            for await tokenData in activity.pushTokenUpdates {
                await PushGoLiveActivityTokenRegistrationService.register(
                    activityKey: activityKey,
                    channelID: channelID,
                    tokenData: tokenData
                )
            }
        }
    }
    #endif

    static func shouldUseLiveActivity(for message: PushMessage) -> Bool {
        let privacy = PushGoSystemPrivacyPolicy.privacy(for: message)
        guard privacy.mayIndexTitle, !privacy.isEncryptedOrSensitive else { return false }
        if normalized(message.entityType) == "event" {
            return true
        }
        return normalized(message.thingId) != nil && normalized(message.eventId) != nil
    }

    private static func eventIDFromEntity(_ message: PushMessage) -> String? {
        normalized(message.entityType) == "event" ? message.entityId : nil
    }

    private static func isClosedState(_ value: String?) -> Bool {
        switch normalized(value) {
        case "closed", "close", "resolved", "ended", "done", "completed", "cancelled", "canceled":
            return true
        default:
            return false
        }
    }

    private static func normalized(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func activityKey(eventID: String) -> String {
        "event:\(eventID)"
    }
}
