import Foundation
@preconcurrency import UserNotifications

@preconcurrency
final class NotificationService: UNNotificationServiceExtension {
    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var bestAttemptContent: UNMutableNotificationContent?
    private var processingTask: Task<Void, Never>?

    override func didReceive(
        _ request: UNNotificationRequest,
        withContentHandler contentHandler: @escaping @Sendable (UNNotificationContent) -> Void
    ) {
        self.contentHandler = contentHandler
        bestAttemptContent = (request.content.mutableCopy() as? UNMutableNotificationContent)

        guard let content = bestAttemptContent else {
            contentHandler(request.content)
            return
        }

        let request = request
        let contentHandler = contentHandler
        let mutableContent = content

        processingTask?.cancel()
        processingTask = Task { @MainActor in
            let processor = WatchNotificationServiceProcessor()
            let result = await processor.process(request: request, content: mutableContent)
            guard !Task.isCancelled else { return }
            contentHandler(result)
        }
    }

    override func serviceExtensionTimeWillExpire() {
        processingTask?.cancel()
        processingTask = nil
        if let contentHandler, let bestAttemptContent {
            contentHandler(bestAttemptContent)
        }
    }
}
