import Foundation
import Testing
@testable import PushGoAppleCore

struct AppNavigationStateTests {
    @Test
    @MainActor
    func foregroundSuppressionRequiresMatchingActiveTabAtTop() {
        let state = AppNavigationState()
        state.setSceneActive(true)
        state.updateActiveTab(.messages)
        state.updateMessageListPosition(isAtTop: true)

        #expect(state.shouldSuppressForegroundNotifications(for: ["entity_type": "message"]))
        #expect(!state.shouldSuppressForegroundNotifications(for: ["entity_type": "event"]))
    }

    @Test
    @MainActor
    func foregroundSuppressionStopsWhenSceneIsInactive() {
        let state = AppNavigationState()
        state.setSceneActive(true)
        state.updateActiveTab(.things)
        state.updateThingListPosition(isAtTop: true)
        #expect(state.shouldSuppressForegroundNotifications(for: ["entity_type": "thing"]))

        state.setSceneActive(false)
        #expect(!state.shouldSuppressForegroundNotifications(for: ["entity_type": "thing"]))
    }
}
