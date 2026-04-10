import CryptoKit
import Foundation
import UserNotifications

final class NotificationContentPreparer {
    private enum DecryptionError: Error {
        case invalidKeyMaterial
    }

    private enum NotificationDecryptionState: String {
        case notConfigured
        case algMismatch
        case decryptOk
        case decryptFailed
    }

    private enum InlineDecryptResult {
        case none
        case success
        case failure
    }

    private enum CipherDecryptStatus {
        case none
        case success
        case failure
    }

    private struct CipherDecryptResult {
        let status: CipherDecryptStatus
        let body: String?
    }

    private struct DecryptResults {
        let inline: InlineDecryptResult
        let cipher: CipherDecryptResult
    }

    private enum FieldDecryptOutcome {
        case skipped
        case decrypted(String)
        case failed
    }

    private enum AlertField: CaseIterable {
        case title
        case body

        static func containsEncryptedField(in content: UNNotificationContent) -> Bool {
            allCases.contains { field in
                InlineCipherEnvelope.looksLikeCiphertext(field.currentValue(from: content))
            }
        }

        func currentValue(from content: UNNotificationContent) -> String {
            switch self {
            case .title:
                content.title
            case .body:
                content.body
            }
        }

        func update(content: UNMutableNotificationContent, with newValue: String) {
            switch self {
            case .title:
                content.title = newValue
            case .body:
                content.body = newValue
            }
        }
    }

    private struct InlineCipherEnvelope {
        let ciphertext: Data
        let tag: Data
        let iv: Data

        init?(from base64: String) {
            guard InlineCipherEnvelope.looksLikeCiphertext(base64),
                  let decoded = Data(base64Encoded: base64)
            else {
                return nil
            }
            guard decoded.count >= CryptoConstants.minimumCipherBytes else {
                return nil
            }
            let iv = decoded.suffix(CryptoConstants.ivLength)
            let cipherAndTag = decoded.prefix(decoded.count - CryptoConstants.ivLength)
            guard cipherAndTag.count > CryptoConstants.tagLength else {
                return nil
            }
            let tag = cipherAndTag.suffix(CryptoConstants.tagLength)
            let ciphertext = cipherAndTag.prefix(cipherAndTag.count - CryptoConstants.tagLength)
            self.ciphertext = ciphertext
            self.tag = tag
            self.iv = iv
        }

        static func looksLikeCiphertext(_ value: String) -> Bool {
            guard !value.isEmpty,
                  value.count % 4 == 0,
                  value.count >= CryptoConstants.minimumBase64Length
            else {
                return false
            }
            return value.rangeOfCharacter(from: CryptoConstants.invalidBase64Characters) == nil
        }
    }

    private enum CryptoConstants {
        static let ivLength = 12
        static let tagLength = 16
        static let minimumCipherBytes = ivLength + tagLength + 1
        static let base64Characters =
            CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=")
        static let invalidBase64Characters = base64Characters.inverted
        static let minimumBase64Length = ((minimumCipherBytes + 2) / 3) * 4
    }

    private static let bestEffortAttachmentTimeout: TimeInterval = 2.0
    private static let minimumAttachmentWindow: TimeInterval = 0.5

    private let keychainConfigStore = LocalKeychainConfigStore()
    private let isNotificationServiceExtensionProcess = (
        Bundle.main.bundleIdentifier?.hasSuffix(".NotificationServiceExtension") == true
    )
#if os(watchOS)
    private let watchProvisioningStore = try? WatchLightNotificationStore()
#endif

    func prepare(
        _ content: UNMutableNotificationContent,
        includeMediaAttachments: Bool = true
    ) async -> UNMutableNotificationContent {
        let content = content
        let isExpired = isPayloadExpired(content.userInfo)
        let hasCiphertext = content.userInfo["ciphertext"] != nil
        let likelyEncrypted = AlertField.containsEncryptedField(in: content) || hasCiphertext
        let isConfigMissing = (try? await loadKeyMaterial()) == nil
        if likelyEncrypted, isConfigMissing {
            content.userInfo["decryption_state"] = NotificationDecryptionState.notConfigured.rawValue
        }

        if !isNotificationServiceExtensionProcess {
            do {
                if let result = try await handleDecryptionIfNeeded(for: content, likelyEncrypted: likelyEncrypted) {
                    if result.inline == .failure || result.cipher.status == .failure {
                        content.userInfo["decryption_state"] = NotificationDecryptionState.decryptFailed.rawValue
                    } else if result.inline == .success || result.cipher.status == .success {
                        content.userInfo["decryption_state"] = NotificationDecryptionState.decryptOk.rawValue
                    }
                }
            } catch {
                if likelyEncrypted {
                    content.userInfo["decryption_state"] = NotificationDecryptionState.decryptFailed.rawValue
                }
            }
        }

        let fullBody = ((content.userInfo["body"] as? String)?.trimmedNonEmpty ?? content.body)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !fullBody.isEmpty {
            content.userInfo["body"] = fullBody
        }
        let previewBody = MessagePreviewExtractor.notificationPreview(from: fullBody)
        content.body = previewBody.isEmpty ? fullBody : previewBody

        let categoryIdentifier = NotificationPayloadSemantics.entityOpenTargetComponents(from: content.userInfo) == nil
            ? AppConstants.notificationDefaultCategoryIdentifier
            : AppConstants.notificationEntityReminderCategoryIdentifier
        content.categoryIdentifier = categoryIdentifier
        content.userInfo["category"] = categoryIdentifier
        if let threadIdentifier = NotificationPayloadSemantics.notificationThreadIdentifier(from: content.userInfo) {
            content.threadIdentifier = threadIdentifier
        }

        if includeMediaAttachments {
            guard !Task.isCancelled else { return content }
            let mediaDeadline = Date().addingTimeInterval(Self.bestEffortAttachmentTimeout)
            await attachMediaIfNeeded(to: content, deadline: mediaDeadline)
        }

        let normalizedLevel = resolveNormalizedLevel(from: content)
        let profile = NotificationLevelProfile.from(level: normalizedLevel)
        return applyLevelRingtoneIfNeeded(
            to: content,
            level: normalizedLevel,
            profile: profile,
            isExpired: isExpired
        )
    }

    private func applyLevelRingtoneIfNeeded(
        to content: UNMutableNotificationContent,
        level: String,
        profile: NotificationLevelProfile,
        isExpired: Bool
    ) -> UNMutableNotificationContent {
        if isExpired {
            content.interruptionLevel = .passive
            var aps = (content.userInfo["aps"] as? [String: Any]) ?? [:]
            aps.removeValue(forKey: "sound")
            content.userInfo["aps"] = aps
            content.sound = nil
            return content
        }

        content.interruptionLevel = interruptionLevel(for: level)

        if let filename = soundFilename(for: level) {
            return applySound(named: filename, isCritical: profile.isCritical, to: content)
        }

        var aps = (content.userInfo["aps"] as? [String: Any]) ?? [:]
        aps.removeValue(forKey: "sound")
        content.userInfo["aps"] = aps
        content.sound = nil
        return content
    }

    func enrichMediaIfNeeded(_ content: UNMutableNotificationContent) async -> UNMutableNotificationContent {
        guard !Task.isCancelled else { return content }
        let mediaDeadline = Date().addingTimeInterval(Self.bestEffortAttachmentTimeout)
        await attachMediaIfNeeded(to: content, deadline: mediaDeadline)
        return content
    }

    private func applySound(
        named filename: String,
        isCritical: Bool,
        to content: UNMutableNotificationContent
    ) -> UNMutableNotificationContent {
        var aps = (content.userInfo["aps"] as? [String: Any]) ?? [:]
        aps["sound"] = filename
        content.userInfo["aps"] = aps

        #if os(iOS)
        if isCritical {
            content.sound = UNNotificationSound.criticalSoundNamed(
                UNNotificationSoundName(filename),
                withAudioVolume: 1.0
            )
        } else {
            content.sound = UNNotificationSound(named: UNNotificationSoundName(filename))
        }
        #elseif os(watchOS)
        // watchOS relies on aps["sound"]; UNNotificationSound(named:) is unavailable.
        #else
        content.sound = UNNotificationSound(named: UNNotificationSoundName(filename))
        #endif

        return content
    }

    private func isPayloadExpired(_ userInfo: [AnyHashable: Any]) -> Bool {
        guard let ttl = PayloadTimeParser.epochSeconds(from: userInfo["ttl"]) else {
            return false
        }
        let now = Int64(Date().timeIntervalSince1970)
        return now > ttl
    }

    private func resolveNormalizedLevel(from content: UNNotificationContent) -> String {
        if let value = content.userInfo["severity"] as? String {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            switch trimmed {
            case "critical", "high", "low":
                return trimmed
            case "normal":
                return "normal"
            default:
                break
            }
        }
        return "normal"
    }

    private func interruptionLevel(for level: String) -> UNNotificationInterruptionLevel {
        switch level {
        case "critical":
            return .critical
        case "high":
            return .timeSensitive
        case "low":
            return .passive
        default:
            return .active
        }
    }

    private func soundFilename(for level: String) -> String? {
        switch level {
        case "critical":
            return "alert.caf"
        case "high":
            return "level-up.caf"
        case "normal":
            return "bubble-pop.caf"
        case "low":
            return nil
        default:
            return "bubble-pop.caf"
        }
    }

    private func handleDecryptionIfNeeded(
        for content: UNMutableNotificationContent,
        likelyEncrypted: Bool
    ) async throws -> DecryptResults? {
        guard let material = try await loadKeyMaterial(), material.isConfigured else {
            return nil
        }

        guard material.algorithm == .aesGcm else {
            if likelyEncrypted {
                content.userInfo["decryption_state"] = NotificationDecryptionState.algMismatch.rawValue
            }
            return nil
        }

        let key = try symmetricKey(from: material)
        let inlineResult = decryptInlineFields(content: content, key: key)
        let cipherResult = decryptCiphertextPayload(content: content, key: key)
        return DecryptResults(inline: inlineResult, cipher: cipherResult)
    }

    private func symmetricKey(from material: ServerConfig.NotificationKeyMaterial) throws -> SymmetricKey {
        guard !material.keyData.isEmpty, [16, 24, 32].contains(material.keyData.count) else {
            throw DecryptionError.invalidKeyMaterial
        }
        return SymmetricKey(data: material.keyData)
    }

    private func decryptInlineFields(
        content: UNMutableNotificationContent,
        key: SymmetricKey
    ) -> InlineDecryptResult {
        var decryptedAnyField = false

        for field in AlertField.allCases {
            let currentValue = field.currentValue(from: content)
            guard !currentValue.isEmpty else { continue }
            switch decryptFieldIfNeeded(currentValue, key: key) {
            case .skipped:
                continue
            case let .decrypted(plaintext):
                field.update(content: content, with: plaintext)
                decryptedAnyField = true
            case .failed:
                return .failure
            }
        }

        return decryptedAnyField ? .success : .none
    }

    private func decryptCiphertextPayload(
        content: UNMutableNotificationContent,
        key: SymmetricKey
    ) -> CipherDecryptResult {
        guard let ciphertext = content.userInfo["ciphertext"] as? String,
              let envelope = InlineCipherEnvelope(from: ciphertext)
        else {
            return CipherDecryptResult(status: .none, body: nil)
        }

        do {
            let nonce = try AES.GCM.Nonce(data: envelope.iv)
            let sealedBox = try AES.GCM.SealedBox(
                nonce: nonce,
                ciphertext: envelope.ciphertext,
                tag: envelope.tag
            )
            let decrypted = try AES.GCM.open(sealedBox, using: key)
            guard let jsonText = String(data: decrypted, encoding: .utf8) else {
                return CipherDecryptResult(status: .failure, body: nil)
            }

            let payload = try JSONDecoder().decode(CiphertextPayload.self, from: Data(jsonText.utf8))
            var applied = false
            var decryptedBody: String?

            if let title = payload.title?.trimmedNonEmpty {
                content.title = title
                content.userInfo["title"] = title
                applied = true
            }
            if let body = payload.body?.trimmedNonEmpty {
                content.userInfo["body"] = body
                content.body = body
                decryptedBody = body
                applied = true
            }
            let decodedImages = payload.normalizedImages
            if !decodedImages.isEmpty {
                content.userInfo["images"] = decodedImages
                applied = true
            }

            return CipherDecryptResult(
                status: applied ? .success : .none,
                body: decryptedBody
            )
        } catch {
            return CipherDecryptResult(status: .failure, body: nil)
        }
    }

    private func decryptFieldIfNeeded(_ value: String, key: SymmetricKey) -> FieldDecryptOutcome {
        guard let envelope = InlineCipherEnvelope(from: value) else {
            return .skipped
        }

        do {
            let nonce = try AES.GCM.Nonce(data: envelope.iv)
            let sealedBox = try AES.GCM.SealedBox(
                nonce: nonce,
                ciphertext: envelope.ciphertext,
                tag: envelope.tag
            )
            let decrypted = try AES.GCM.open(sealedBox, using: key)
            guard let text = String(data: decrypted, encoding: .utf8) else {
                return .failed
            }
            return .decrypted(text)
        } catch {
            return .failed
        }
    }

    private func attachMediaIfNeeded(
        to content: UNMutableNotificationContent,
        deadline: Date
    ) async {
        guard content.attachments.isEmpty else { return }
        guard !Task.isCancelled else { return }
        let remaining = deadline.timeIntervalSinceNow
        guard remaining > Self.minimumAttachmentWindow else { return }
        let candidates: [(key: String, identifier: String)] = [("images", "image")]
        let attachments = await NotificationMediaResolver.attachments(
            from: content.userInfo,
            candidates: candidates,
            timeout: min(remaining, Self.bestEffortAttachmentTimeout)
        )
        guard !Task.isCancelled else { return }
        if !attachments.isEmpty {
            content.attachments = attachments
        }
    }

    private func loadKeyMaterial() async throws -> ServerConfig.NotificationKeyMaterial? {
#if os(watchOS)
        return try await watchProvisioningStore?.loadProvisioningServerConfig()?.notificationKeyMaterial
#else
        return try keychainConfigStore.loadServerConfig()?.notificationKeyMaterial
#endif
    }
}

private struct CiphertextPayload: Decodable {
    let title: String?
    let body: String?
    let images: [String]

    var normalizedImages: [String] {
        var resolved: [String] = []
        for value in images {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if !resolved.contains(trimmed) {
                resolved.append(trimmed)
            }
        }
        return resolved
    }

    enum CodingKeys: String, CodingKey {
        case title
        case body
        case images
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        body = try container.decodeIfPresent(String.self, forKey: .body)
        images = Self.decodeImages(container: container)
    }

    private static func decodeImages(container: KeyedDecodingContainer<CodingKeys>) -> [String] {
        if let values = try? container.decode([String].self, forKey: .images) {
            return values
        }
        guard let raw = try? container.decode(String.self, forKey: .images) else {
            return []
        }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty,
              let data = text.data(using: .utf8),
              let decoded = try? JSONSerialization.jsonObject(with: data),
              let array = decoded as? [String]
        else {
            return []
        }
        return array
    }
}

private struct NotificationLevelProfile {
    let isCritical: Bool

    static func from(level rawValue: String) -> NotificationLevelProfile {
        let normalized = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch normalized {
        case "critical":
            return NotificationLevelProfile(isCritical: true)
        default:
            return NotificationLevelProfile(isCritical: false)
        }
    }
}

private extension String {
    var trimmedNonEmpty: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
