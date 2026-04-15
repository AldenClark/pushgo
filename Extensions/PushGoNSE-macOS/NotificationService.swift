import Foundation
@preconcurrency import UserNotifications

private actor NotificationServiceDeliveryGate {
    private var hasDelivered = false

    func tryMarkDelivered() -> Bool {
        guard !hasDelivered else { return false }
        hasDelivered = true
        return true
    }
}

final class NotificationService: UNNotificationServiceExtension {
    private let stateLock = NSLock()
    private var contentHandler: (@Sendable (UNNotificationContent) -> Void)?
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
            let fallback = request.content
            Task {
                if await currentGate.tryMarkDelivered() {
                    contentHandler(fallback)
                }
            }
            return
        }

        let request = request
        let mutableContent = content
        let task = Task(priority: .userInitiated) {
            let processor = NotificationServiceProcessor()
            let result = await processor.process(request: request, content: mutableContent)
            guard !Task.isCancelled else { return }
            if await currentGate.tryMarkDelivered() {
                contentHandler(result)
            }
        }

        stateLock.lock()
        processingTask = task
        stateLock.unlock()
    }

    override func serviceExtensionTimeWillExpire() {
        let pendingTask: Task<Void, Never>?
        let handler: (@Sendable (UNNotificationContent) -> Void)?
        let fallbackContent: UNNotificationContent?
        let currentGate: NotificationServiceDeliveryGate
        stateLock.lock()
        pendingTask = processingTask
        processingTask = nil
        handler = contentHandler
        fallbackContent = bestAttemptContent
        currentGate = deliveryGate
        stateLock.unlock()

        pendingTask?.cancel()
        guard let handler, let fallbackContent else { return }
        Task {
            if await currentGate.tryMarkDelivered() {
                handler(fallbackContent)
            }
        }
    }
}
