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
        #if os(iOS) || os(macOS)
        PushGoOpenMessagesControl()
        PushGoOpenEventsControl()
        PushGoOpenObjectsControl()
        PushGoOpenRecentCriticalEventControl()
        PushGoMarkLatestMessageReadControl()
        #endif
        #if os(iOS)
        PushGoEventLiveActivityWidget()
        #endif
    }
}
