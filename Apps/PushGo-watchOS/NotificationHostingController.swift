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
    @Published var isMarkdown = false
    @Published var markdownPayload: MarkdownRenderPayload?
    @Published var image: CGImage?

    func update(with notification: UNNotification) {
        let content = notification.request.content
        title = content.title

        let resolvedBody = resolveBody(content: content)
        let shouldRenderMarkdown = shouldUseMarkdown(content: content, resolvedBody: resolvedBody)
        body = resolvedBody.rawText
        isMarkdown = shouldRenderMarkdown

        if shouldRenderMarkdown,
           let payloadText = content.userInfo[AppConstants.markdownRenderPayloadKey] as? String,
           let payload = MarkdownRenderPayload.decode(from: payloadText)
        {
            markdownPayload = payload
        } else {
            markdownPayload = nil
        }

        image = loadAttachmentImage(from: content.attachments)
        markReadIfNeeded(for: content)
        loadMessageForDisplayIfNeeded(for: content)
    }

    private func resolveBody(content: UNNotificationContent) -> ResolvedBody {
        let ciphertextBody = stringValue(forKeys: ["ciphertext_body"], in: content.userInfo)
        let envelopeBody = stringValue(forKeys: ["body"], in: content.userInfo) ?? content.body
        let resolved = MessageBodyResolver.resolve(
            ciphertextBody: ciphertextBody,
            envelopeBody: envelopeBody,
            isMarkdownOverride: markdownOverride(from: content.userInfo)
        )
        return ResolvedBody(rawText: resolved.rawText, isMarkdown: resolved.isMarkdown)
    }

    private func shouldUseMarkdown(content: UNNotificationContent, resolvedBody: ResolvedBody) -> Bool {
        if content.categoryIdentifier == AppConstants.nceMarkdownCategoryIdentifier {
            return true
        }
        if let override = markdownOverride(from: content.userInfo) {
            return override
        }
        return resolvedBody.isMarkdown
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

    private func markdownOverride(from userInfo: [AnyHashable: Any]) -> Bool? {
        guard let value = userInfo["body_render_is_markdown"] else { return nil }
        if let flag = value as? Bool { return flag }
        if let number = value as? NSNumber { return number.boolValue }
        if let string = value as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if trimmed == "true" || trimmed == "1" || trimmed == "yes" { return true }
            if trimmed == "false" || trimmed == "0" || trimmed == "no" { return false }
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

    private func markReadIfNeeded(for content: UNNotificationContent) {
        guard let messageId = extractMessageId(from: content.userInfo) else { return }
        Task { @MainActor in
            _ = try? await AppEnvironment.shared.messageStateCoordinator.markRead(messageId: messageId)
        }
    }

    private func loadMessageForDisplayIfNeeded(for content: UNNotificationContent) {
        guard let messageId = extractMessageId(from: content.userInfo) else { return }
        Task { @MainActor in
            let dataStore = AppEnvironment.shared.dataStore
            guard let message = try? await dataStore.loadMessage(messageId: messageId) else {
                return
            }
            let resolved = message.resolvedBody
            guard !resolved.rawText.isEmpty else { return }
            body = resolved.rawText
            isMarkdown = resolved.isMarkdown
            if resolved.isMarkdown,
               let payloadText = message.rawPayload[AppConstants.markdownRenderPayloadKey]?.value as? String,
               let payload = MarkdownRenderPayload.decode(from: payloadText)
            {
                markdownPayload = payload
            } else {
                markdownPayload = nil
            }
        }
    }

    private func extractMessageId(from payload: [AnyHashable: Any]) -> UUID? {
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
        let isMarkdown: Bool
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

                if model.isMarkdown {
                    if let payload = model.markdownPayload {
                        MarkdownRenderPayloadView(payload: payload)
                    } else {
                        let document = PushGoMarkdownParser().parse(model.body)
                        if document.blocks.isEmpty {
                            Text(model.body)
                                .font(.body)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            PushGoMarkdownView(document: document)
                        }
                    }
                } else {
                    Text(model.body.isEmpty ? " " : model.body)
                        .font(.body)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

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

struct MarkdownRenderPayloadView: View {
    let payload: MarkdownRenderPayload
    var textStyle: Font.TextStyle = .body
    var foreground: Color = .primary

    var body: some View {
        Text(payload.attributedString(textStyle: textStyle))
            .font(.system(textStyle))
            .foregroundColor(foreground)
            .lineLimit(nil)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
