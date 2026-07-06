import SwiftUI
import WidgetKit

@main
struct PushGoWidgetsBundle: WidgetBundle {
    var body: some Widget {
        #if !os(watchOS)
        PushGoUnreadWidget()
        PushGoCriticalEventWidget()
        PushGoObjectStatusWidget()
        #endif
        #if os(watchOS)
        PushGoWatchComplicationWidget()
        #endif
        #if os(iOS)
        if #available(iOS 18.0, *) {
            PushGoOpenMessagesControl()
            PushGoOpenEventsControl()
            PushGoOpenObjectsControl()
            PushGoOpenRecentCriticalEventControl()
            PushGoMarkLatestMessageReadControl()
        }
        #elseif os(macOS)
        if #available(macOS 26.0, *) {
            PushGoOpenMessagesControl()
            PushGoOpenEventsControl()
            PushGoOpenObjectsControl()
            PushGoOpenRecentCriticalEventControl()
            PushGoMarkLatestMessageReadControl()
        }
        #endif
        #if os(iOS)
        PushGoEventLiveActivityWidget()
        #endif
    }
}
