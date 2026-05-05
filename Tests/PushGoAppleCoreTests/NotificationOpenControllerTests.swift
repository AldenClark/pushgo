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
