import Foundation
import Testing
@testable import PushGoAppleCore

struct MainTabTests {
    @Test
    func allCasesExposeSharedNavigationMatrix() {
        #expect(MainTab.allCases.contains(.messages))
        #expect(MainTab.allCases.contains(.events))
        #expect(MainTab.allCases.contains(.things))
        #expect(MainTab.allCases.contains(.channels))
        #expect(MainTab.allCases.contains(.settings))
    }

    @Test
    func automationIdentifiersRoundTripAcrossPrimaryTabs() {
        #if DEBUG
            #expect(MainTab(automationIdentifier: "messages") == .messages)
            #expect(MainTab(automationIdentifier: "events") == .events)
            #expect(MainTab(automationIdentifier: "things") == .things)
            #expect(MainTab(automationIdentifier: "channels") == .channels)
            #expect(MainTab(automationIdentifier: "settings") == .settings)
            #expect(MainTab.settings.automationIdentifier == "settings")
            #expect(MainTab.channels.automationVisibleScreen == "screen.channels")
            #expect(MainTab.messages.automationPublishesFromRoot)
            #expect(!MainTab.settings.automationPublishesFromRoot)
        #endif
    }

    @Test
    func systemImageNamesStayStableForPrimaryTabs() {
        #expect(MainTab.messages.systemImageName == "tray.full")
        #expect(MainTab.events.systemImageName == "waveform.path.ecg")
        #expect(MainTab.things.systemImageName == "cpu")
        #expect(MainTab.channels.systemImageName == "dot.radiowaves.left.and.right")
        #expect(MainTab.settings.systemImageName == "gearshape")
    }
}
