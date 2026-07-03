import Foundation
import Observation

@MainActor
@Observable
final class PushGoSystemIntentRouter {
    static let shared = PushGoSystemIntentRouter()
    private static let pendingOpenTargetDefaultsKey = "pushgo.system_integration.pending_open_target.v1"

    private(set) var revision = UUID()
    var pendingTarget: PushGoSystemOpenTarget? {
        didSet {
            if let pendingTarget {
                Self.savePendingOpenTarget(pendingTarget)
            } else {
                Self.clearPendingOpenTarget()
            }
            revision = UUID()
        }
    }

    private init() {}

    func consumePendingTarget() -> PushGoSystemOpenTarget? {
        let target = pendingTarget ?? Self.consumePendingOpenTarget()
        pendingTarget = nil
        return target
    }

    func setPendingTarget(_ target: PushGoSystemOpenTarget) {
        pendingTarget = target
    }

    static func savePendingOpenTarget(_ target: PushGoSystemOpenTarget) {
        guard let data = try? JSONEncoder().encode(target) else { return }
        AppConstants.sharedUserDefaults().set(data, forKey: pendingOpenTargetDefaultsKey)
    }

    static func clearPendingOpenTarget() {
        AppConstants.sharedUserDefaults().removeObject(forKey: pendingOpenTargetDefaultsKey)
    }

    static func consumePendingOpenTarget() -> PushGoSystemOpenTarget? {
        let defaults = AppConstants.sharedUserDefaults()
        guard let data = defaults.data(forKey: pendingOpenTargetDefaultsKey),
              let target = try? JSONDecoder().decode(PushGoSystemOpenTarget.self, from: data)
        else {
            return nil
        }
        defaults.removeObject(forKey: pendingOpenTargetDefaultsKey)
        return target
    }
}
