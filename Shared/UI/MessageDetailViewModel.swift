import Foundation
import Observation
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

@MainActor
@Observable
final class MessageDetailViewModel {
    private(set) var message: PushMessage?
    private(set) var hasResolvedMessage = false
    var alertMessage: String?
    var formattedRawPayload: String? {
        guard let payload = message?.payloadForDisplay else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(payload),
              let text = String(data: data, encoding: .utf8)
        else {
            return nil
        }
        return text
    }

    private let environment: AppEnvironment
    private let messageId: UUID
    private let localizationManager: LocalizationManager
    private let dataStore: LocalDataStore

    init(
        environment: AppEnvironment? = nil,
        messageId: UUID,
        initialMessage: PushMessage? = nil,
        localizationManager: LocalizationManager? = nil,
    ) {
        if let environment {
            self.environment = environment
        } else {
            self.environment = AppEnvironment.shared
        }
        self.messageId = messageId
        self.message = initialMessage
        self.localizationManager = localizationManager ?? LocalizationManager.shared
        dataStore = self.environment.dataStore
        Task { @MainActor in
            await loadMessage()
        }
    }

    func refresh() {
        Task { @MainActor in
            await loadMessage()
        }
    }

    func markRead(_ isRead: Bool) async {
        guard isRead else { return }
        guard let message else { return }
        do {
            let updated = try await environment.messageStateCoordinator.markRead(messageId: message.id)
            self.message = updated ?? message
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    func markAsReadIfNeeded() async {
        if message == nil {
            message = try? await dataStore.loadMessage(id: messageId)
        }
        guard let message, message.isRead == false else { return }
        await markRead(true)
    }

    func deleteMessage() async {
        guard let message else { return }
        do {
            try await environment.messageStateCoordinator.deleteMessage(messageId: message.id)
            self.message = nil
            hasResolvedMessage = true
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    func copyBody() {
        guard let message else { return }
        Self.copyText(message.resolvedBody.rawText)
        alertMessage = localizationManager.localized("message_content_copied")
    }

    func copyLink() {
        guard let url = message?.url else { return }
        Self.copyText(url.absoluteString)
        alertMessage = localizationManager.localized("link_copied")
    }

    func copyRawPayload() {
        guard let text = formattedRawPayload else { return }
        Self.copyText(text)
        alertMessage = localizationManager.localized("original_data_copied")
    }

    private static func copyText(_ text: String) {
#if os(iOS)
        UIPasteboard.general.string = text
#elseif os(watchOS)
#else
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
#endif
    }

    private func loadMessage() async {
        message = try? await dataStore.loadMessage(id: messageId)
        hasResolvedMessage = true
    }
}
