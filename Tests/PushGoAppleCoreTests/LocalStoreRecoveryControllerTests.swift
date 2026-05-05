import Foundation
import Testing
@testable import PushGoAppleCore

struct LocalStoreRecoveryControllerTests {
    @Test
    func repeatedUnavailabilityUnlocksRebuildAction() async throws {
        try await withIsolatedLocalDataStore { store, _ in
            let suiteName = "tests.local-store-recovery.\(UUID().uuidString)"
            defer {
                UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
            }

            let state = await Task { @MainActor in
                let controller = makeController(store: store, suiteName: suiteName)
                let unavailable = LocalDataStore.StorageState(mode: .unavailable, reason: "database is locked")
                controller.handleLocalStoreUnavailable(unavailable)
                controller.handleLocalStoreUnavailable(unavailable)
                controller.handleLocalStoreUnavailable(unavailable)
                return controller.localStoreRecoveryState
            }.value

            let resolved = try #require(state)
            #expect(resolved.canRebuild)
            #expect(resolved.message.contains("数据库锁占用"))
        }
    }

    @Test
    func clearFailureStreakResetsEscalationThreshold() async {
        await withIsolatedLocalDataStore { store, _ in
            let suiteName = "tests.local-store-recovery.\(UUID().uuidString)"
            defer {
                UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
            }

            let canRebuildAfterReset = await Task { @MainActor in
                let controller = makeController(store: store, suiteName: suiteName)
                let unavailable = LocalDataStore.StorageState(mode: .unavailable, reason: "database is locked")
                controller.handleLocalStoreUnavailable(unavailable)
                controller.handleLocalStoreUnavailable(unavailable)
                controller.handleLocalStoreUnavailable(unavailable)
                controller.clearFailureStreak()
                controller.dismissLocalStoreRecovery()
                controller.handleLocalStoreUnavailable(unavailable)
                return controller.localStoreRecoveryState?.canRebuild ?? true
            }.value

            #expect(!canRebuildAfterReset)
        }
    }

    @Test
    func dismissLocalStoreRecoveryClearsPresentedState() async {
        await withIsolatedLocalDataStore { store, _ in
            let suiteName = "tests.local-store-recovery.\(UUID().uuidString)"
            defer {
                UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
            }

            let state = await Task { @MainActor in
                let controller = makeController(store: store, suiteName: suiteName)
                controller.handleLocalStoreUnavailable(
                    LocalDataStore.StorageState(mode: .unavailable, reason: "database is locked")
                )
                controller.dismissLocalStoreRecovery()
                return controller.localStoreRecoveryState
            }.value

            #expect(state == nil)
        }
    }
}

@MainActor
private func makeController(
    store: LocalDataStore,
    suiteName: String
) -> LocalStoreRecoveryController {
    let defaults = UserDefaults(suiteName: suiteName) ?? .standard
    return LocalStoreRecoveryController(
        dataStore: store,
        localizationManager: LocalizationManager(),
        failureStreakThreshold: 3,
        failureStreakKey: "pushgo.tests.local_store.failure_streak",
        failureDefaults: defaults,
        showToast: { _ in },
        terminate: {}
    )
}
