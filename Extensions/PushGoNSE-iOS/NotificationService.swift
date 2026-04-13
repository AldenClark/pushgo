import Foundation
@preconcurrency import UserNotifications

@preconcurrency
final class NotificationService: UNNotificationServiceExtension, @unchecked Sendable {
    private let stateLock = NSLock()
    private var contentHandler: (@Sendable (UNNotificationContent) -> Void)?
    private var bestAttemptContent: UNMutableNotificationContent?
    private var processingTask: Task<Void, Never>?
    private var hasDeliveredContent = false

    private func deliverIfNeeded(
        _ content: UNNotificationContent,
        using handler: @Sendable (UNNotificationContent) -> Void
    ) {
        stateLock.lock()
        guard !hasDeliveredContent else {
            stateLock.unlock()
            return
        }
        hasDeliveredContent = true
        stateLock.unlock()
        handler(content)
    }

    override func didReceive(
        _ request: UNNotificationRequest,
        withContentHandler contentHandler: @escaping @Sendable (UNNotificationContent) -> Void
    ) {
        let copiedContent = (request.content.mutableCopy() as? UNMutableNotificationContent)
        let previousTask: Task<Void, Never>?
        stateLock.lock()
        hasDeliveredContent = false
        self.contentHandler = contentHandler
        bestAttemptContent = copiedContent
        previousTask = processingTask
        processingTask = nil
        stateLock.unlock()
        previousTask?.cancel()

        guard let content = copiedContent else {
            deliverIfNeeded(request.content, using: contentHandler)
            return
        }
        let request = request
        let mutableContent = content

        let task = Task(priority: .userInitiated) { [weak self] in
            let processor = NotificationServiceProcessor()
            let result = await processor.process(request: request, content: mutableContent)
            guard !Task.isCancelled else { return }
            guard let self else { return }
            self.deliverIfNeeded(result, using: contentHandler)
        }
        stateLock.lock()
        processingTask = task
        stateLock.unlock()
    }

    override func serviceExtensionTimeWillExpire() {
        let pendingTask: Task<Void, Never>?
        let handler: (@Sendable (UNNotificationContent) -> Void)?
        let fallbackContent: UNNotificationContent?
        stateLock.lock()
        pendingTask = processingTask
        processingTask = nil
        handler = contentHandler
        fallbackContent = bestAttemptContent
        stateLock.unlock()
        pendingTask?.cancel()
        if let handler, let fallbackContent {
            deliverIfNeeded(fallbackContent, using: handler)
        }
    }
}
