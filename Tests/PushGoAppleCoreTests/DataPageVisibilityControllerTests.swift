import Foundation
import Testing
@testable import PushGoAppleCore

struct DataPageVisibilityControllerTests {
    @Test
    func persistedVisibilityReloadsFromStore() async {
        await withIsolatedAutomationStorage { _, appGroupIdentifier in
            let store = LocalDataStore(appGroupIdentifier: appGroupIdentifier)
            _ = await Task { @MainActor in
                let controller = DataPageVisibilityController(dataStore: store)
                controller.setEventPageEnabled(false)
                controller.setThingPageEnabled(false)
            }.value

            await store.flushWrites()

            let reloadedState = await Task { @MainActor in
                let reloadedStore = LocalDataStore(appGroupIdentifier: appGroupIdentifier)
                let controller = DataPageVisibilityController(dataStore: reloadedStore)
                await controller.loadPersistedState()
                return (
                    controller.isMessagePageEnabled,
                    controller.isEventPageEnabled,
                    controller.isThingPageEnabled
                )
            }.value

            #expect(reloadedState.0)
            #expect(!reloadedState.1)
            #expect(!reloadedState.2)
        }
    }

    @Test
    func autoEnablePromotesOnlyTargetedPage() async {
        await withIsolatedLocalDataStore { store, _ in
            let state = await Task { @MainActor in
                let controller = DataPageVisibilityController(dataStore: store)
                controller.setMessagePageEnabled(false)
                controller.setEventPageEnabled(false)
                controller.setThingPageEnabled(false)
                controller.autoEnableDataPageIfNeeded(for: makeMessage(entityType: "event"))
                return (
                    controller.isMessagePageEnabled,
                    controller.isEventPageEnabled,
                    controller.isThingPageEnabled
                )
            }.value

            #expect(!state.0)
            #expect(state.1)
            #expect(!state.2)
        }
    }

    @Test
    func autoEnableFallsBackToMessagePageForUnknownEntityType() async {
        await withIsolatedLocalDataStore { store, _ in
            let state = await Task { @MainActor in
                let controller = DataPageVisibilityController(dataStore: store)
                controller.setMessagePageEnabled(false)
                controller.setEventPageEnabled(false)
                controller.setThingPageEnabled(false)
                controller.autoEnableDataPageIfNeeded(for: makeMessage(entityType: "message"))
                return (
                    controller.isMessagePageEnabled,
                    controller.isEventPageEnabled,
                    controller.isThingPageEnabled
                )
            }.value

            #expect(state.0)
            #expect(!state.1)
            #expect(!state.2)
        }
    }
}

private func makeMessage(entityType: String) -> PushMessage {
    PushMessage(
        messageId: "msg-\(entityType)-001",
        title: "Title",
        body: "Body",
        rawPayload: [
            "entity_type": AnyCodable(entityType),
            "entity_id": AnyCodable("\(entityType)-001"),
        ]
    )
}
