import Foundation

@MainActor
protocol PushGoSystemTargetOpening: AnyObject {
    func openSystemTarget(_ target: PushGoSystemOpenTarget) async
}
