import AppIntents
import SwiftUI
import WidgetKit

#if os(iOS) || os(macOS)
struct OpenPushGoWidgetSectionIntent: AppIntent {
    static let title: LocalizedStringResource = "Open PushGo"
    static let openAppWhenRun = true

    @Parameter(title: "Section")
    var section: PushGoWidgetSection

    func perform() async throws -> some IntentResult {
        PushGoWidgetPendingOpenTargetStore.save(PushGoWidgetOpenTarget.list(kind: section.widgetKind))
        return .result()
    }
}

struct OpenPushGoMessagesWidgetIntent: AppIntent {
    static let title: LocalizedStringResource = "Open PushGo Messages"
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult {
        PushGoWidgetPendingOpenTargetStore.save(.list(kind: .message))
        return .result()
    }
}

struct OpenPushGoEventsWidgetIntent: AppIntent {
    static let title: LocalizedStringResource = "Open PushGo Events"
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult {
        PushGoWidgetPendingOpenTargetStore.save(.list(kind: .event))
        return .result()
    }
}

struct OpenPushGoObjectsWidgetIntent: AppIntent {
    static let title: LocalizedStringResource = "Open PushGo Objects"
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult {
        PushGoWidgetPendingOpenTargetStore.save(.list(kind: .thing))
        return .result()
    }
}

struct OpenRecentCriticalPushGoEventWidgetIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Recent Critical PushGo Event"
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult {
        let snapshot = PushGoWidgetSnapshotStore.load()
        if let target = snapshot.criticalEvents.first?.openTarget {
            PushGoWidgetPendingOpenTargetStore.save(target)
        } else {
            PushGoWidgetPendingOpenTargetStore.save(.list(kind: .event))
        }
        return .result()
    }
}

struct MarkLatestPushGoMessageReadWidgetIntent: AppIntent {
    static let title: LocalizedStringResource = "Mark Latest PushGo Message Read"
    static let openAppWhenRun = false

    func perform() async throws -> some IntentResult {
        PushGoWidgetActionExecutor.markLatestUnreadMessageRead()
        return .result()
    }
}

enum PushGoWidgetSection: String, AppEnum {
    case messages
    case events
    case objects

    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(name: "PushGo Section")
    }

    static var caseDisplayRepresentations: [PushGoWidgetSection: DisplayRepresentation] {
        [
            .messages: DisplayRepresentation(title: "Messages"),
            .events: DisplayRepresentation(title: "Events"),
            .objects: DisplayRepresentation(title: "Objects"),
        ]
    }

    var openURL: URL? {
        switch self {
        case .messages:
            return PushGoWidgetOpenTarget.list(kind: .message).url()
        case .events:
            return PushGoWidgetOpenTarget.list(kind: .event).url()
        case .objects:
            return PushGoWidgetOpenTarget.list(kind: .thing).url()
        }
    }

    var widgetKind: PushGoWidgetEntityKind {
        switch self {
        case .messages:
            return .message
        case .events:
            return .event
        case .objects:
            return .thing
        }
    }
}

@available(iOS 18.0, macOS 26.0, *)
struct PushGoOpenMessagesControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "io.ethan.pushgo.controls.open-messages") {
            ControlWidgetButton(action: OpenPushGoMessagesWidgetIntent()) {
                Label("Messages", systemImage: "tray.full")
            }
        }
        .displayName("PushGo Messages")
        .description("Open PushGo messages.")
    }
}

@available(iOS 18.0, macOS 26.0, *)
struct PushGoOpenEventsControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "io.ethan.pushgo.controls.open-events") {
            ControlWidgetButton(action: OpenPushGoEventsWidgetIntent()) {
                Label("Events", systemImage: "waveform.path.ecg")
            }
        }
        .displayName("PushGo Events")
        .description("Open PushGo events.")
    }
}

@available(iOS 18.0, macOS 26.0, *)
struct PushGoOpenObjectsControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "io.ethan.pushgo.controls.open-objects") {
            ControlWidgetButton(action: OpenPushGoObjectsWidgetIntent()) {
                Label("Objects", systemImage: "shippingbox")
            }
        }
        .displayName("PushGo Objects")
        .description("Open PushGo objects.")
    }
}

@available(iOS 18.0, macOS 26.0, *)
struct PushGoOpenRecentCriticalEventControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "io.ethan.pushgo.controls.open-recent-critical-event") {
            ControlWidgetButton(action: OpenRecentCriticalPushGoEventWidgetIntent()) {
                Label("Critical Event", systemImage: "bolt.badge.exclamationmark")
            }
        }
        .displayName("PushGo Critical Event")
        .description("Open the latest high priority PushGo event.")
    }
}

@available(iOS 18.0, macOS 26.0, *)
struct PushGoMarkLatestMessageReadControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "io.ethan.pushgo.controls.mark-latest-read") {
            ControlWidgetButton(action: MarkLatestPushGoMessageReadWidgetIntent()) {
                Label("Latest Message", systemImage: "checkmark.message")
            }
        }
        .displayName("PushGo Latest Message")
        .description("Mark the latest unread PushGo message as read.")
    }
}
#endif
