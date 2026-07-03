import Foundation
import Testing
@testable import PushGoAppleCore

struct NotificationOpenControllerTests {
    @Test
    func openingNotificationRequestRoutesToPendingMessage() async throws {
        try await withIsolatedLocalDataStore { store, _ in
            let message = makeStoredMessage(
                messageId: "msg-open-001",
                notificationRequestId: "req-open-001"
            )
            try await store.saveMessage(message)

            let openedId = await Task { @MainActor in
                let controller = NotificationOpenController(
                    dataStore: store,
                    localizationManager: LocalizationManager(),
                    messageStateCoordinatorProvider: { nil },
                    refreshCountsAndNotify: {},
                    removeDeliveredNotificationIfNeeded: { _ in },
                    autoEnableDataPage: { _ in },
                    showToast: { _ in }
                )
                await controller.handleNotificationOpen(notificationRequestId: "req-open-001")
                return controller.pendingMessageToOpen
            }.value

            #expect(openedId == message.id)
        }
    }

    @Test
    func openingEntityTargetClearsMessageAndTracksPendingEntity() async {
        await withIsolatedLocalDataStore { store, _ in
            let opened = await Task { @MainActor in
                let controller = NotificationOpenController(
                    dataStore: store,
                    localizationManager: LocalizationManager(),
                    messageStateCoordinatorProvider: { nil },
                    refreshCountsAndNotify: {},
                    removeDeliveredNotificationIfNeeded: { _ in },
                    autoEnableDataPage: { _ in },
                    showToast: { _ in }
                )
                controller.pendingMessageToOpen = UUID()
                await controller.handleNotificationOpen(entityType: "thing", entityId: "thing-001")
                return (
                    controller.pendingMessageToOpen,
                    controller.pendingEventToOpen,
                    controller.pendingThingToOpen
                )
            }.value

            #expect(opened.0 == nil)
            #expect(opened.1 == nil)
            #expect(opened.2 == "thing-001")
        }
    }

    @Test
    func openingEventTargetClearsThingAndTracksPendingEvent() async {
        await withIsolatedLocalDataStore { store, _ in
            let opened = await Task { @MainActor in
                let controller = NotificationOpenController(
                    dataStore: store,
                    localizationManager: LocalizationManager(),
                    messageStateCoordinatorProvider: { nil },
                    refreshCountsAndNotify: {},
                    removeDeliveredNotificationIfNeeded: { _ in },
                    autoEnableDataPage: { _ in },
                    showToast: { _ in }
                )
                controller.pendingThingToOpen = "thing-001"
                await controller.handleNotificationOpen(entityType: "event", entityId: "evt-001")
                return (
                    controller.pendingMessageToOpen,
                    controller.pendingEventToOpen,
                    controller.pendingThingToOpen
                )
            }.value

            #expect(opened.0 == nil)
            #expect(opened.1 == "evt-001")
            #expect(opened.2 == nil)
        }
    }

    @Test
    func openingSystemMessageTargetUsesLocalMessageID() async throws {
        try await withIsolatedLocalDataStore { store, _ in
            let message = makeStoredMessage(
                messageId: "msg-system-001",
                notificationRequestId: "req-system-001"
            )
            try await store.saveMessage(message)

            let openedId = await Task { @MainActor in
                let controller = NotificationOpenController(
                    dataStore: store,
                    localizationManager: LocalizationManager(),
                    messageStateCoordinatorProvider: { nil },
                    refreshCountsAndNotify: {},
                    removeDeliveredNotificationIfNeeded: { _ in },
                    autoEnableDataPage: { _ in },
                    showToast: { _ in }
                )
                let target = PushGoSystemOpenTarget(
                    kind: .message,
                    identifier: message.id.uuidString,
                    source: .deepLink
                )
                await controller.openSystemTarget(target!)
                return controller.pendingMessageToOpen
            }.value

            #expect(openedId == message.id)
        }
    }

    @Test
    func openingSystemEntityTargetsRouteThroughPendingEntities() async {
        await withIsolatedLocalDataStore { store, _ in
            let opened = await Task { @MainActor in
                let controller = NotificationOpenController(
                    dataStore: store,
                    localizationManager: LocalizationManager(),
                    messageStateCoordinatorProvider: { nil },
                    refreshCountsAndNotify: {},
                    removeDeliveredNotificationIfNeeded: { _ in },
                    autoEnableDataPage: { _ in },
                    showToast: { _ in }
                )
                await controller.openSystemTarget(
                    PushGoSystemOpenTarget(kind: .event, identifier: "evt-system-001", source: .deepLink)!
                )
                let eventTarget = controller.pendingEventToOpen
                await controller.openSystemTarget(
                    PushGoSystemOpenTarget(kind: .thing, identifier: "thing-system-001", source: .spotlight)!
                )
                return (
                    eventTarget,
                    controller.pendingEventToOpen,
                    controller.pendingThingToOpen
                )
            }.value

            #expect(opened.0 == "evt-system-001")
            #expect(opened.1 == nil)
            #expect(opened.2 == "thing-system-001")
        }
    }
}

private func makeStoredMessage(
    messageId: String,
    notificationRequestId: String
) -> PushMessage {
    PushMessage(
        id: UUID(),
        messageId: messageId,
        title: "Stored title",
        body: "Stored body",
        channel: "default",
        isRead: false,
        receivedAt: Date(timeIntervalSince1970: 1_741_572_800),
        rawPayload: [
            "message_id": AnyCodable(messageId),
            "entity_type": AnyCodable("message"),
            "_notificationRequestId": AnyCodable(notificationRequestId),
        ]
    )
}
