import Foundation

enum MainTab: Hashable {
    case messages
    case events
    case things
    case health

    init?(automationIdentifier: String) {
        switch automationIdentifier {
        case "messages", "tab.messages":
            self = .messages
        case "events", "tab.events":
            self = .events
        case "things", "tab.things":
            self = .things
        case "health", "tab.health", "receiver", "tab.receiver":
            self = .health
        default:
            return nil
        }
    }

    var automationIdentifier: String {
        switch self {
        case .messages:
            return "tab.messages"
        case .events:
            return "tab.events"
        case .things:
            return "tab.things"
        case .health:
            return "tab.health"
        }
    }

    var automationVisibleScreen: String {
        switch self {
        case .messages:
            return "screen.messages.list"
        case .events:
            return "screen.events.list"
        case .things:
            return "screen.things.list"
        case .health:
            return "screen.receiver.health"
        }
    }
}
