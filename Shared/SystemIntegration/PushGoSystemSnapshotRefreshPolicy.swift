import Foundation

struct PushGoSystemSnapshotRefreshPolicy: Sendable {
    static let defaultsKey = "pushgo.system_surface_snapshot.last_refresh.v1"
    static let defaultMinimumInterval: TimeInterval = 10
    static let healthCheckMaximumAge: TimeInterval = 60 * 60 * 6

    let minimumInterval: TimeInterval

    init(minimumInterval: TimeInterval = defaultMinimumInterval) {
        self.minimumInterval = minimumInterval
    }

    func shouldRefresh(
        now: Date = Date(),
        reason: PushGoSystemSnapshotRefreshReason,
        defaults: UserDefaults = AppConstants.sharedUserDefaults()
    ) -> Bool {
        switch reason {
        case .healthCheck:
            return true
        case .delete, .settingsChanged, .warmCache:
            return true
        case .write:
            guard let lastRun = defaults.object(forKey: Self.defaultsKey) as? Date else {
                return true
            }
            return now.timeIntervalSince(lastRun) >= minimumInterval
        }
    }

    func recordRefresh(
        now: Date = Date(),
        defaults: UserDefaults = AppConstants.sharedUserDefaults()
    ) {
        defaults.set(now, forKey: Self.defaultsKey)
    }
}

enum PushGoSystemSnapshotRefreshReason: String, Sendable {
    case write
    case delete
    case settingsChanged
    case warmCache
    case healthCheck
}

enum PushGoShortcutSummaryKind: String, CaseIterable, Sendable {
    case recentMessages
    case unreadMessages
    case criticalEvents
    case objectStatus
}
