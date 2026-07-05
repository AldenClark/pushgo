import Foundation

enum PushGoSystemPendingAction: String, Codable, Sendable {
    case markLatestUnreadMessageRead
}

enum PushGoSystemPendingActionStore {
    static let defaultsKey = "pushgo.system_integration.pending_action.v1"

    static func save(
        _ action: PushGoSystemPendingAction,
        defaults: UserDefaults = AppConstants.sharedUserDefaults()
    ) {
        guard let data = try? JSONEncoder().encode(action) else { return }
        defaults.set(data, forKey: defaultsKey)
    }

    static func consume(
        defaults: UserDefaults = AppConstants.sharedUserDefaults()
    ) -> PushGoSystemPendingAction? {
        guard let data = defaults.data(forKey: defaultsKey),
              let action = try? JSONDecoder().decode(PushGoSystemPendingAction.self, from: data)
        else {
            return nil
        }
        defaults.removeObject(forKey: defaultsKey)
        return action
    }
}
