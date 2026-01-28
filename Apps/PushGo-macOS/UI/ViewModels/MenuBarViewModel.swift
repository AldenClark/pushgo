import Foundation
import Observation
import AppKit

@MainActor
@Observable
final class MenuBarViewModel {
    private(set) var unreadMessages: [PushMessageSummary] = []
    private let dataStore: LocalDataStore
    private let environment: AppEnvironment

    init(
        dataStore: LocalDataStore = LocalDataStore(),
        environment: AppEnvironment? = nil
    ) {
        self.dataStore = dataStore
        if let environment {
            self.environment = environment
        } else {
            self.environment = AppEnvironment.shared
        }
    }

    func refreshUnread(maxCount: Int = 8) async {
        let page = try? await dataStore.loadMessageSummariesPage(
            before: nil,
            limit: maxCount,
            filter: .unreadOnly,
            channel: nil,
        )
        unreadMessages = page ?? []
    }

    func openMainApp() {
        NSApp.activate(ignoringOtherApps: true)
    }
}
