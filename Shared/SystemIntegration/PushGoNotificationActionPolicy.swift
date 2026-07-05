import Foundation
import UserNotifications

struct PushGoNotificationPresentationPolicy: Equatable, Hashable, Sendable {
    enum InterruptionLevel: String, Equatable, Hashable, Sendable {
        case passive
        case active
        case timeSensitive
    }

    let interruptionLevel: InterruptionLevel
    let relevanceScore: Double
}

enum PushGoNotificationActionPolicy {
    static let markReadActionIdentifier = "pushgo.notification.mark_read"
    static let deleteMessageActionIdentifier = "pushgo.notification.delete_message"
    static let openRelatedEntityActionIdentifier = "pushgo.notification.open_related_entity"
    static let openEntityActionIdentifier = "pushgo.notification.open_entity"
    static let deleteEntityReminderActionIdentifier = "pushgo.notification.delete_entity_reminder"

    static func categories() -> Set<UNNotificationCategory> {
        [
            messageCategory(),
            entityReminderCategory(),
        ]
    }

    private static func messageCategory() -> UNNotificationCategory {
        UNNotificationCategory(
            identifier: AppConstants.notificationDefaultCategoryIdentifier,
            actions: [
                UNNotificationAction(
                    identifier: markReadActionIdentifier,
                    title: LocalizationProvider.localized("mark_as_read"),
                    options: []
                ),
                UNNotificationAction(
                    identifier: openRelatedEntityActionIdentifier,
                    title: LocalizationProvider.localized("open_related_entity"),
                    options: [.foreground]
                ),
                UNNotificationAction(
                    identifier: deleteMessageActionIdentifier,
                    title: LocalizationProvider.localized("delete"),
                    options: [.destructive]
                ),
            ],
            intentIdentifiers: [],
            options: []
        )
    }

    private static func entityReminderCategory() -> UNNotificationCategory {
        UNNotificationCategory(
            identifier: AppConstants.notificationEntityReminderCategoryIdentifier,
            actions: [
                UNNotificationAction(
                    identifier: openEntityActionIdentifier,
                    title: LocalizationProvider.localized("open_link"),
                    options: [.foreground]
                ),
            ],
            intentIdentifiers: [],
            options: []
        )
    }

    static func presentationPolicy(
        severity: String?,
        settings: SystemIntegrationSettings = SystemIntegrationSettings(),
        focusState: PushGoSystemSurfaceSnapshot.FocusState = .default()
    ) -> PushGoNotificationPresentationPolicy {
        basePresentationPolicy(
            severity: normalizedSeverity(severity),
            settings: settings,
            focusState: focusState
        )
    }

    private static func basePresentationPolicy(
        severity: String,
        settings: SystemIntegrationSettings,
        focusState: PushGoSystemSurfaceSnapshot.FocusState
    ) -> PushGoNotificationPresentationPolicy {
        let base: PushGoNotificationPresentationPolicy
        switch severity {
        case "critical":
            base = PushGoNotificationPresentationPolicy(
                interruptionLevel: settings.timeSensitiveAlertsEnabled ? .timeSensitive : .active,
                relevanceScore: 0.95
            )
        case "high":
            base = PushGoNotificationPresentationPolicy(
                interruptionLevel: settings.timeSensitiveAlertsEnabled ? .timeSensitive : .active,
                relevanceScore: 0.75
            )
        case "low":
            base = PushGoNotificationPresentationPolicy(
                interruptionLevel: .passive,
                relevanceScore: 0.2
            )
        default:
            base = PushGoNotificationPresentationPolicy(
                interruptionLevel: .active,
                relevanceScore: 0.4
            )
        }
        return applyFocusState(focusState, to: base, severity: severity)
    }

    private static func applyFocusState(
        _ focusState: PushGoSystemSurfaceSnapshot.FocusState,
        to policy: PushGoNotificationPresentationPolicy,
        severity: String
    ) -> PushGoNotificationPresentationPolicy {
        switch focusState.mode {
        case .all:
            return policy
        case .priorityOnly:
            if severity == "critical" || severity == "high" {
                return policy
            }
            return PushGoNotificationPresentationPolicy(
                interruptionLevel: .passive,
                relevanceScore: min(policy.relevanceScore, 0.15)
            )
        case .quiet:
            if severity == "critical" {
                return PushGoNotificationPresentationPolicy(
                    interruptionLevel: .active,
                    relevanceScore: min(policy.relevanceScore, 0.6)
                )
            }
            return PushGoNotificationPresentationPolicy(
                interruptionLevel: .passive,
                relevanceScore: min(policy.relevanceScore, 0.1)
            )
        }
    }

    private static func normalizedSeverity(_ value: String?) -> String {
        let normalized = value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        switch normalized {
        case "critical", "high", "low":
            return normalized
        case "medium", "normal":
            return "normal"
        default:
            return "normal"
        }
    }

    static func interruptionLevel(
        for policyLevel: PushGoNotificationPresentationPolicy.InterruptionLevel
    ) -> UNNotificationInterruptionLevel {
        switch policyLevel {
        case .passive:
            return .passive
        case .active:
            return .active
        case .timeSensitive:
            return .timeSensitive
        }
    }
}
