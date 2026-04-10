import Foundation
@preconcurrency import UserNotifications

private final class NotificationServiceDeliveryState: @unchecked Sendable {
    private let lock = NSLock()
    private var delivered = false

    func markDeliveredIfNeeded() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !delivered else { return false }
        delivered = true
        return true
    }
}

@preconcurrency
final class NotificationService: UNNotificationServiceExtension {
    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var bestAttemptContent: UNMutableNotificationContent?
    private var processingTask: Task<Void, Never>?
    private var deliveryState = NotificationServiceDeliveryState()

    override func didReceive(
        _ request: UNNotificationRequest,
        withContentHandler contentHandler: @escaping @Sendable (UNNotificationContent) -> Void
    ) {
        let deliveryState = NotificationServiceDeliveryState()
        self.deliveryState = deliveryState
        self.contentHandler = contentHandler
        bestAttemptContent = (request.content.mutableCopy() as? UNMutableNotificationContent)

        guard let content = bestAttemptContent else {
            if deliveryState.markDeliveredIfNeeded() {
                contentHandler(request.content)
            }
            return
        }
        let request = request
        let mutableContent = content

        processingTask?.cancel()
        processingTask = Task(priority: .userInitiated) {
            let processor = NotificationServiceProcessor()
            let result = await processor.process(request: request, content: mutableContent)
            guard !Task.isCancelled else { return }
            if deliveryState.markDeliveredIfNeeded() {
                contentHandler(result)
            }
        }
    }

    override func serviceExtensionTimeWillExpire() {
        if let contentHandler, let bestAttemptContent, deliveryState.markDeliveredIfNeeded() {
            contentHandler(bestAttemptContent)
        }
    }
}
