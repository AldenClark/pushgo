import Foundation
@preconcurrency import UserNotifications

@preconcurrency
@MainActor
final class NotificationService: UNNotificationServiceExtension {
    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var bestAttemptContent: UNMutableNotificationContent?
    private var processingTask: Task<Void, Never>?
    private var hasDeliveredContent = false

    private func deliverIfNeeded(
        _ content: UNNotificationContent,
        using handler: (UNNotificationContent) -> Void
    ) {
        guard !hasDeliveredContent else { return }
        hasDeliveredContent = true
        handler(content)
    }

    override func didReceive(
        _ request: UNNotificationRequest,
        withContentHandler contentHandler: @escaping @Sendable (UNNotificationContent) -> Void
    ) {
        hasDeliveredContent = false
        self.contentHandler = contentHandler
        bestAttemptContent = (request.content.mutableCopy() as? UNMutableNotificationContent)

        guard let content = bestAttemptContent else {
            deliverIfNeeded(request.content, using: contentHandler)
            return
        }
        let request = request
        let mutableContent = content

        processingTask?.cancel()
        processingTask = Task(priority: .userInitiated) { [weak self] in
            let processor = NotificationServiceProcessor()
            let result = await processor.process(request: request, content: mutableContent)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self else { return }
                self.deliverIfNeeded(result, using: contentHandler)
            }
        }
    }

    override func serviceExtensionTimeWillExpire() {
        if let contentHandler, let bestAttemptContent {
            deliverIfNeeded(bestAttemptContent, using: contentHandler)
        }
    }
}
