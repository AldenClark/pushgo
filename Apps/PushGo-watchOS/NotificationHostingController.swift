import Combine
import Foundation
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications
import WatchKit

final class NotificationHostingController: WKUserNotificationHostingController<NotificationView> {
    private let model = NotificationViewModel()

    override var body: NotificationView {
        NotificationView(model: model)
    }

    override func didReceive(_ notification: UNNotification) {
        model.update(with: notification)
    }
}

@MainActor
final class NotificationViewModel: ObservableObject {
    @Published var title = ""
    @Published var body = ""
    @Published var image: CGImage?

    func update(with notification: UNNotification) {
        let content = notification.request.content
        title = content.title

        let resolvedBody = resolveBody(content: content)
        body = resolvedBody.rawText

        image = loadAttachmentImage(from: content.attachments)
        markReadIfNeeded(for: notification)
        loadMessageForDisplayIfNeeded(for: notification)
    }

    private func resolveBody(content: UNNotificationContent) -> ResolvedBody {
        let envelopeBody = stringValue(forKeys: ["body"], in: content.userInfo) ?? content.body
        let resolved = MessageBodyResolver.resolve(envelopeBody: envelopeBody)
        return ResolvedBody(rawText: resolved.rawText)
    }

    private func stringValue(forKeys keys: [String], in userInfo: [AnyHashable: Any]) -> String? {
        for key in keys {
            if let value = (userInfo[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !value.isEmpty
            {
                return value
            }
        }
        return nil
    }

    private func loadAttachmentImage(from attachments: [UNNotificationAttachment]) -> CGImage? {
        for attachment in attachments {
            if let cgImage = loadImage(from: attachment) {
                return cgImage
            }
        }
        return nil
    }

    private func loadImage(from attachment: UNNotificationAttachment) -> CGImage? {
        let url = attachment.url
        guard let data = try? Data(contentsOf: url) else { return nil }
        return Self.makeCGImage(from: data)
    }

    private func markReadIfNeeded(for notification: UNNotification) {
        Task { @MainActor in
            guard let message = await resolveLightMessage(for: notification) else { return }
            let dataStore = AppEnvironment.shared.dataStore
            if AppEnvironment.shared.watchMode == .mirror {
                try? await AppEnvironment.shared.enqueueMirrorMessageAction(kind: .read, messageId: message.messageId)
            } else {
                _ = try? await dataStore.markWatchLightMessageRead(messageId: message.messageId)
                await AppEnvironment.shared.refreshWatchLightCountsAndNotify()
            }
        }
    }

    private func loadMessageForDisplayIfNeeded(for notification: UNNotification) {
        Task { @MainActor in
            guard let message = await resolveLightMessage(for: notification) else { return }
            guard !message.body.isEmpty else { return }
            body = message.body
        }
    }

    private func resolveLightMessage(for notification: UNNotification) async -> WatchLightMessage? {
        let dataStore = AppEnvironment.shared.dataStore
        if let messageId = extractMessageId(from: notification.request.content.userInfo),
           let message = try? await dataStore.loadWatchLightMessage(messageId: messageId)
        {
            return message
        }
        let requestId = notification.request.identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        if !requestId.isEmpty,
           let message = try? await dataStore.loadWatchLightMessage(notificationRequestId: requestId)
        {
            return message
        }
        return nil
    }

    private func extractMessageId(from payload: [AnyHashable: Any]) -> String? {
        let mapped = payload.reduce(into: [String: Any]()) { result, element in
            guard let key = element.key as? String else { return }
            result[key] = element.value
        }
        return MessageIdExtractor.extract(from: mapped)
    }

    private static func makeCGImage(from data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return nil
        }
        guard let type = CGImageSourceGetType(source) else { return nil }
        if let utType = UTType(type as String), !utType.conforms(to: .image) {
            return nil
        }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    private struct ResolvedBody {
        let rawText: String
    }
}

struct NotificationView: View {
    @ObservedObject var model: NotificationViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                if !model.title.isEmpty {
                    Text(model.title)
                        .font(.headline)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                MarkdownRenderer(
                    text: model.body.isEmpty ? " " : model.body,
                    font: .body,
                    foreground: .primary
                )
                .frame(maxWidth: .infinity, alignment: .leading)

                if let image = model.image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
    }
}
