import Foundation
import os
@preconcurrency import UserNotifications

private final class NotificationServiceDeliveryGate: Sendable {
    private let hasDelivered = OSAllocatedUnfairLock(initialState: false)

    func tryMarkDelivered() -> Bool {
        hasDelivered.withLock { delivered in
            guard !delivered else { return false }
            delivered = true
            return true
        }
    }
}

@preconcurrency
final class NotificationService: UNNotificationServiceExtension {
    private let stateLock = NSLock()
    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var bestAttemptContent: UNMutableNotificationContent?
    private var processingTask: Task<Void, Never>?
    private var deliveryGate = NotificationServiceDeliveryGate()

    override func didReceive(
        _ request: UNNotificationRequest,
        withContentHandler contentHandler: @escaping @Sendable (UNNotificationContent) -> Void
    ) {
        let copiedContent = (request.content.mutableCopy() as? UNMutableNotificationContent)
        let previousTask: Task<Void, Never>?
        let currentGate: NotificationServiceDeliveryGate
        stateLock.lock()
        self.contentHandler = contentHandler
        bestAttemptContent = copiedContent
        previousTask = processingTask
        processingTask = nil
        deliveryGate = NotificationServiceDeliveryGate()
        currentGate = deliveryGate
        stateLock.unlock()
        previousTask?.cancel()

        guard let content = copiedContent else {
            if currentGate.tryMarkDelivered() { contentHandler(request.content) }
            return
        }

        let request = request
        let contentHandler = contentHandler
        let mutableContent = content

        let task = Task { @MainActor in
            let processor = WatchNotificationServiceProcessor()
            let result = await processor.process(request: request, content: mutableContent)
            guard !Task.isCancelled else { return }
            if currentGate.tryMarkDelivered() { contentHandler(result) }
        }
        stateLock.lock()
        processingTask = task
        stateLock.unlock()
    }

    override func serviceExtensionTimeWillExpire() {
        let pendingTask: Task<Void, Never>?
        let handler: ((UNNotificationContent) -> Void)?
        let fallback: UNNotificationContent?
        let currentGate: NotificationServiceDeliveryGate
        stateLock.lock()
        pendingTask = processingTask
        processingTask = nil
        handler = contentHandler
        fallback = bestAttemptContent
        currentGate = deliveryGate
        stateLock.unlock()
        pendingTask?.cancel()
        guard let handler, let fallback else { return }
        if currentGate.tryMarkDelivered() { handler(fallback) }
    }
}
