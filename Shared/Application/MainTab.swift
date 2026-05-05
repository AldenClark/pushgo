import Foundation

enum MainTab: Hashable, CaseIterable {
    case messages
    case events
    case things
    case channels
#if os(macOS)
    case settings
#endif

    var title: String {
        switch self {
        case .messages:
            "messages"
        case .events:
#if os(macOS)
            "push_type_event"
#else
            "thing_detail_tab_events"
#endif
        case .things:
            "push_type_thing"
        case .channels:
            "channels"
#if os(macOS)
        case .settings:
            "settings"
#endif
        }
    }

    @MainActor
    func localizedTitle(using localizationManager: LocalizationManager) -> String {
        localizationManager.localized(title)
    }

    var systemImageName: String {
        switch self {
        case .messages:
            "tray.full"
        case .events:
            "waveform.path.ecg"
        case .things:
            "cpu"
        case .channels:
            "dot.radiowaves.left.and.right"
#if os(macOS)
        case .settings:
            "gearshape"
#endif
        }
    }

    var accessibilityIdentifier: String {
        switch self {
        case .messages:
            "messages"
        case .events:
            "events"
        case .things:
            "things"
        case .channels:
            "channels"
#if os(macOS)
        case .settings:
            "settings"
#endif
        }
    }

#if DEBUG
    init?(automationIdentifier: String) {
        switch automationIdentifier {
        case "messages":
            self = .messages
        case "events":
            self = .events
        case "things":
            self = .things
        case "channels":
            self = .channels
#if os(macOS)
        case "settings":
            self = .settings
#endif
        default:
            return nil
        }
    }

    var automationIdentifier: String {
        switch self {
        case .messages:
            "messages"
        case .events:
            "events"
        case .things:
            "things"
        case .channels:
            "channels"
#if os(macOS)
        case .settings:
            "settings"
#endif
        }
    }

    var automationVisibleScreen: String {
        switch self {
        case .messages:
            "screen.messages.list"
        case .events:
            "screen.events.list"
        case .things:
            "screen.things.list"
        case .channels:
            "screen.channels"
#if os(macOS)
        case .settings:
            "screen.settings"
#endif
        }
    }

    var automationPublishesFromRoot: Bool {
        switch self {
#if os(macOS)
        case .events, .things, .settings:
            return false
#else
        case .events, .things:
            return false
#endif
        case .messages, .channels:
            return true
        }
    }
#endif
}
