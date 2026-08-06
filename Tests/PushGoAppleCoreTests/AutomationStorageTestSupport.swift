import Foundation
@testable import PushGoAppleCore

func withIsolatedAutomationStorage<T: Sendable>(
    _ body: @Sendable (URL, String) async throws -> T
) async rethrows -> T {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("pushgo-apple-core-tests", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let appGroupIdentifier = "group.ethan.pushgo.tests.\(UUID().uuidString.lowercased())"

    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    do {
        let result = try await PushGoAutomationContext.$storageRootOverrideURL.withValue(root) {
            try await body(root, appGroupIdentifier)
        }
        LocalDataStore.releaseSharedResourcesForTesting(storageRootURL: root)
        return result
    } catch {
        LocalDataStore.releaseSharedResourcesForTesting(storageRootURL: root)
        throw error
    }
}

func withIsolatedLocalDataStore<T: Sendable>(
    // Unit tests that do not explicitly exercise Spotlight must not wait on the
    // host indexing daemon. System-search tests pass their deterministic fake
    // indexer explicitly below this boundary.
    spotlightIndexer: PushGoSpotlightIndexing? = nil,
    _ body: @Sendable (LocalDataStore, String) async throws -> T
) async rethrows -> T {
    try await withIsolatedAutomationStorage { _, appGroupIdentifier in
        let store = LocalDataStore(
            appGroupIdentifier: appGroupIdentifier,
            spotlightIndexer: spotlightIndexer
        )
        return try await body(store, appGroupIdentifier)
    }
}
