import Foundation

#if canImport(CoreSpotlight)
@preconcurrency import CoreSpotlight
#endif

enum PushGoUserActivityBuilder {
    static let messageActivityType = "io.pushgo.message.view"
    static let eventActivityType = "io.pushgo.event.view"
    static let thingActivityType = "io.pushgo.thing.view"

    static let kindUserInfoKey = "kind"
    static let identifierUserInfoKey = "id"
    static let localMessageIDUserInfoKey = "local_message_id"
    static let messageIDUserInfoKey = "message_id"
    static let eventIDUserInfoKey = "event_id"
    static let thingIDUserInfoKey = "thing_id"

    static func activity(
        for summary: PushGoSystemSummary,
        systemSearchEnabled: Bool = SystemIntegrationSettings.loadSharedDefaults().systemSearchEnabled
    ) -> NSUserActivity {
        let activity = NSUserActivity(activityType: activityType(for: summary.kind))
        configure(activity, for: summary, systemSearchEnabled: systemSearchEnabled)
        return activity
    }

    static func configure(
        _ activity: NSUserActivity,
        for summary: PushGoSystemSummary,
        systemSearchEnabled: Bool = SystemIntegrationSettings.loadSharedDefaults().systemSearchEnabled
    ) {
        activity.title = summary.title
        activity.isEligibleForSearch = systemSearchEnabled && summary.privacy.mayIndexTitle
        #if os(iOS) || os(watchOS)
        activity.isEligibleForPrediction = systemSearchEnabled && summary.privacy.mayIndexTitle
        #endif
        activity.userInfo = userInfo(for: summary)
        activity.webpageURL = nil
    }

    static func openTarget(from activity: NSUserActivity) -> PushGoSystemOpenTarget? {
        #if canImport(CoreSpotlight)
        if activity.activityType == CSSearchableItemActionType,
           let raw = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String,
           let identifier = PushGoSpotlightIdentifier(uniqueIdentifier: raw)
        {
            return identifier.openTarget
        }
        #endif

        guard let userInfo = activity.userInfo else { return nil }
        let kind = PushGoSystemEntityKind(
            normalizedRawValue: stringValue(userInfo[kindUserInfoKey])
        ) ?? kind(fromActivityType: activity.activityType)
        guard let kind else { return nil }

        let identifier = stringValue(userInfo[identifierUserInfoKey])
            ?? identifierValue(for: kind, userInfo: userInfo)
        guard let identifier else { return nil }
        let localMessageID = stringValue(userInfo[localMessageIDUserInfoKey]).flatMap(UUID.init(uuidString:))
        return PushGoSystemOpenTarget(
            kind: kind,
            identifier: identifier,
            localMessageID: localMessageID,
            source: .userActivity
        )
    }

    private static func userInfo(for summary: PushGoSystemSummary) -> [String: Any] {
        var userInfo: [String: Any] = [
            kindUserInfoKey: summary.kind.rawValue,
            identifierUserInfoKey: summary.stableID,
        ]
        if let localMessageID = summary.localMessageID {
            userInfo[localMessageIDUserInfoKey] = localMessageID.uuidString
        }
        if let eventID = summary.eventID {
            userInfo[eventIDUserInfoKey] = eventID
        }
        if let thingID = summary.thingID {
            userInfo[thingIDUserInfoKey] = thingID
        }
        return userInfo
    }

    static func activityType(for kind: PushGoSystemEntityKind) -> String {
        switch kind {
        case .message:
            return messageActivityType
        case .event:
            return eventActivityType
        case .thing:
            return thingActivityType
        }
    }

    private static func kind(fromActivityType activityType: String) -> PushGoSystemEntityKind? {
        switch activityType {
        case messageActivityType:
            return .message
        case eventActivityType:
            return .event
        case thingActivityType:
            return .thing
        default:
            return nil
        }
    }

    private static func identifierValue(
        for kind: PushGoSystemEntityKind,
        userInfo: [AnyHashable: Any]
    ) -> String? {
        switch kind {
        case .message:
            return stringValue(userInfo[localMessageIDUserInfoKey])
                ?? stringValue(userInfo[messageIDUserInfoKey])
        case .event:
            return stringValue(userInfo[eventIDUserInfoKey])
        case .thing:
            return stringValue(userInfo[thingIDUserInfoKey])
        }
    }

    private static func stringValue(_ value: Any?) -> String? {
        let trimmed = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}
