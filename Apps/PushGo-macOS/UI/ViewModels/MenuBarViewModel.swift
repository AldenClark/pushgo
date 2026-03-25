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
        dataStore: LocalDataStore? = nil,
        environment: AppEnvironment? = nil
    ) {
        let resolvedEnvironment = environment ?? AppEnvironment.shared
        self.environment = resolvedEnvironment
        self.dataStore = dataStore ?? resolvedEnvironment.dataStore
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
