import Foundation
@preconcurrency import UserNotifications

@preconcurrency
final class NotificationService: UNNotificationServiceExtension {
    private let processor = NotificationServiceProcessor()
    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var bestAttemptContent: UNMutableNotificationContent?

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

        let processor = processor
        let request = request
        let contentHandler = contentHandler
        let mutableContent = content

        Task {
            let result = await processor.process(request: request, content: mutableContent)
            contentHandler(result)
        }
    }

    override func serviceExtensionTimeWillExpire() {
        if let contentHandler, let bestAttemptContent {
            contentHandler(bestAttemptContent)
        }
    }
}
