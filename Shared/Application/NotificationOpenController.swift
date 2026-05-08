import Foundation
import Observation

@MainActor
@Observable
final class NotificationOpenController {
    typealias MessageStateCoordinatorProvider = @MainActor () -> MessageStateCoordinator?
    typealias RefreshCountsAndNotify = @MainActor () async -> Void
    typealias DeliveredNotificationRemover = @MainActor (PushMessage) -> Void
    typealias DataPageEnabler = @MainActor (String) -> Void
    typealias ToastPresenter = @MainActor (String) -> Void

    private let dataStore: LocalDataStore
    @ObservationIgnored private let localizationManager: LocalizationManager
    @ObservationIgnored private let messageStateCoordinatorProvider: MessageStateCoordinatorProvider
    @ObservationIgnored private let refreshCountsAndNotify: RefreshCountsAndNotify
    @ObservationIgnored private let removeDeliveredNotificationIfNeeded: DeliveredNotificationRemover
    @ObservationIgnored private let autoEnableDataPage: DataPageEnabler
    @ObservationIgnored private let showToast: ToastPresenter

    var pendingMessageToOpen: UUID?
    var pendingEventToOpen: String?
    var pendingThingToOpen: String?

    init(
        dataStore: LocalDataStore,
        localizationManager: LocalizationManager,
        messageStateCoordinatorProvider: @escaping MessageStateCoordinatorProvider,
        refreshCountsAndNotify: @escaping RefreshCountsAndNotify,
        removeDeliveredNotificationIfNeeded: @escaping DeliveredNotificationRemover,
        autoEnableDataPage: @escaping DataPageEnabler,
        showToast: @escaping ToastPresenter
    ) {
        self.dataStore = dataStore
        self.localizationManager = localizationManager
        self.messageStateCoordinatorProvider = messageStateCoordinatorProvider
        self.refreshCountsAndNotify = refreshCountsAndNotify
        self.removeDeliveredNotificationIfNeeded = removeDeliveredNotificationIfNeeded
        self.autoEnableDataPage = autoEnableDataPage
        self.showToast = showToast
    }

    func handleNotificationOpen(notificationRequestId: String) async {
        await handleNotificationOpenInternal(
            notificationRequestId: notificationRequestId,
            markAsReadInStore: true,
            removeFromNotificationCenter: true
        )
    }

    func handleNotificationOpen(messageId: String) async {
        await handleNotificationOpenInternal(
            messageId: messageId,
            markAsReadInStore: true,
            removeFromNotificationCenter: true
        )
    }

    func handleNotificationOpen(entityType: String, entityId: String) async {
        await handleEntityOpenTarget(
            EntityOpenTarget(entityType: entityType, entityId: entityId)
        )
    }

    private func handleNotificationOpenInternal(
        notificationRequestId: String,
        markAsReadInStore: Bool,
        removeFromNotificationCenter: Bool
    ) async {
        do {
            if let target = try await dataStore.loadMessage(notificationRequestId: notificationRequestId) {
                await handleNotificationOpenTarget(
                    target,
                    markAsReadInStore: markAsReadInStore,
                    removeFromNotificationCenter: removeFromNotificationCenter
                )
                return
            }
            if let entityTarget = try await dataStore.loadEntityOpenTarget(notificationRequestId: notificationRequestId) {
                await handleEntityOpenTarget(entityTarget)
                return
            }
        } catch {
            let wrapped = AppError.wrap(
                error,
                fallbackMessage: localizationManager.localized("operation_failed"),
                code: "message_load_failed"
            )
            showToast(wrapped.errorDescription ?? localizationManager.localized("operation_failed"))
        }
    }

    private func handleNotificationOpenInternal(
        messageId: String,
        markAsReadInStore: Bool,
        removeFromNotificationCenter: Bool
    ) async {
        do {
            if let target = try await dataStore.loadMessage(messageId: messageId) {
                await handleNotificationOpenTarget(
                    target,
                    markAsReadInStore: markAsReadInStore,
                    removeFromNotificationCenter: removeFromNotificationCenter
                )
                return
            }
            if let entityTarget = try await dataStore.loadEntityOpenTarget(messageId: messageId) {
                await handleEntityOpenTarget(entityTarget)
                return
            }
        } catch {
            let wrapped = AppError.wrap(
                error,
                fallbackMessage: localizationManager.localized("operation_failed"),
                code: "message_load_failed"
            )
            showToast(wrapped.errorDescription ?? localizationManager.localized("operation_failed"))
        }
    }

    private func handleNotificationOpenTarget(
        _ target: PushMessage,
        markAsReadInStore: Bool,
        removeFromNotificationCenter: Bool
    ) async {
        let targetId = target.id

        if markAsReadInStore {
            _ = try? await messageStateCoordinatorProvider()?.markRead(messageId: targetId)
        } else {
            await refreshCountsAndNotify()
            if removeFromNotificationCenter {
                removeDeliveredNotificationIfNeeded(target)
            }
        }
        autoEnableDataPage("message")

        pendingEventToOpen = nil
        pendingThingToOpen = nil
        pendingMessageToOpen = targetId
    }

    private func handleEntityOpenTarget(_ target: EntityOpenTarget) async {
        pendingMessageToOpen = nil
        if target.entityType == "event" {
            autoEnableDataPage("event")
            pendingThingToOpen = nil
            pendingEventToOpen = target.entityId
        } else if target.entityType == "thing" {
            autoEnableDataPage("thing")
            pendingEventToOpen = nil
            pendingThingToOpen = target.entityId
        }
    }
}
