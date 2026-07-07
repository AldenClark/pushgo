import Foundation
import WidgetKit

@available(iOS 26.0, macOS 26.0, watchOS 26.0, *)
struct PushGoWidgetPushHandler: WidgetPushHandler {
    init() {}

    func pushTokenDidChange(_ pushInfo: WidgetPushInfo, widgets: [WidgetInfo]) {
        PushGoWidgetPushTokenStore.save(
            tokenData: pushInfo.token,
            widgets: widgets.map {
                PushGoWidgetPushTokenRecord.Widget(
                    kind: $0.kind,
                    family: String(describing: $0.family)
                )
            }
        )
        Task {
            await PushGoWidgetPushTokenStore.syncSavedTokenIfPossible()
        }
    }
}
