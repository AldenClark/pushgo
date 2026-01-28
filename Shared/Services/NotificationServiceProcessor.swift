import AVFAudio
import CryptoKit
import Foundation
#if canImport(Intents)
import Intents
#endif
import UniformTypeIdentifiers
import UserNotifications

actor NotificationServiceProcessor {
    private enum DecryptionError: Error {
        case invalidKeyMaterial
    }

    private lazy var customSoundsDirectoryURL: URL? = {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: AppConstants.appGroupIdentifier)?
            .appendingPathComponent(AppConstants.customRingtoneRelativePath, isDirectory: true)
    }()

    private lazy var longSoundsDirectoryURL: URL? = {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: AppConstants.appGroupIdentifier)?
            .appendingPathComponent(AppConstants.longRingtoneRelativePath, isDirectory: true)
    }()

    func process(
        request: UNNotificationRequest,
        content: UNMutableNotificationContent
    ) async -> UNNotificationContent {
        var content = content
        let hasCiphertext = content.userInfo["ciphertext"] != nil
        let likelyEncrypted = AlertField.containsEncryptedField(in: content) || hasCiphertext
        let isConfigMissing = await (try? loadKeyMaterial()) == nil
        if likelyEncrypted, isConfigMissing {
            content.userInfo["decryptionState"] = PushMessage.DecryptionState.notConfigured.rawValue
        }

        var decryptResults: DecryptResults?
        do {
            if let result = try await handleDecryptionIfNeeded(for: content, likelyEncrypted: likelyEncrypted) {
                decryptResults = result
                if result.inline == .failure {
                    content.userInfo["decryptionState"] = PushMessage.DecryptionState.decryptFailed.rawValue
                } else if result.cipher.status == .failure {
                    content.userInfo["decryptionState"] = PushMessage.DecryptionState.decryptFailed.rawValue
                } else if result.inline == .success || result.cipher.status == .success {
                    content.userInfo["decryptionState"] = PushMessage.DecryptionState.decryptOk.rawValue
                }
            }
        } catch {
            if likelyEncrypted {
                content.userInfo["decryptionState"] = PushMessage.DecryptionState.decryptFailed.rawValue
            }
        }
        let decryptedCipherBody = decryptResults?.cipher.body
            ?? (content.userInfo["ciphertext_body"] as? String)?.trimmedNonEmpty
        let plainBodyForNotificationCenter = decryptedCipherBody ?? content.body
        content.body = plainBodyForNotificationCenter
        let resolvedBody = MessageBodyResolver.resolve(
            ciphertextBody: (content.userInfo["ciphertext_body"] as? String)?.trimmedNonEmpty
                ?? decryptedCipherBody,
            envelopeBody: plainBodyForNotificationCenter,
            isMarkdownOverride: nil
        )
        let fullBody = resolvedBody.rawText
        let previewBody = makeNotificationBodyPreview(from: fullBody)

        if !fullBody.isEmpty {
            content.userInfo["body"] = fullBody
        }
        content.body = previewBody.isEmpty ? fullBody : previewBody

        let category = resolvedBody.isMarkdown
            ? AppConstants.nceMarkdownCategoryIdentifier
            : AppConstants.ncePlainCategoryIdentifier
        content.categoryIdentifier = category
        content.userInfo["category"] = category
        content.userInfo["body_render_is_markdown"] = resolvedBody.isMarkdown
        content.userInfo["body_render_source"] = resolvedBody.source.rawValue
        if let payloadJSON = buildRenderPayloadJSON(
            text: resolvedBody.rawText,
            isMarkdown: resolvedBody.isMarkdown
        ) {
            content.userInfo[AppConstants.markdownRenderPayloadKey] = payloadJSON
        }

        await persistMessage(for: request, content: content)
        await attachMediaIfNeeded(to: content)
        #if canImport(Intents)
        if #available(iOSApplicationExtension 15.0, macOSApplicationExtension 12.0, *) {
            if let updated = await applyCommunicationStyleIfPossible(to: content),
               let mutableUpdated = updated.mutableCopy() as? UNMutableNotificationContent
            {
                content = mutableUpdated
            }
        }
        #endif

        content = applyDefaultRingtoneIfNeeded(to: content)
        content = applyLongRingtoneIfNeeded(to: content)
        return content
    }

    private func applyDefaultRingtoneIfNeeded(to content: UNMutableNotificationContent) -> UNMutableNotificationContent {
        if let requested = extractRequestedSoundName(from: content.userInfo),
           let resolved = resolveRingtoneFilename(named: requested)
        {
            return applySound(named: resolved, to: content)
        }

        guard let fallback = resolveDefaultRingtoneFilename() else {
            return content
        }

        return applySound(named: fallback, to: content)
    }

    private func applySound(named filename: String, to content: UNMutableNotificationContent) -> UNMutableNotificationContent {
        var aps = (content.userInfo["aps"] as? [String: Any]) ?? [:]
        aps["sound"] = filename
        content.userInfo["aps"] = aps

        #if os(iOS)
        if content.interruptionLevel == .critical {
            content.sound = UNNotificationSound.criticalSoundNamed(UNNotificationSoundName(filename))
        } else {
            content.sound = UNNotificationSound(named: UNNotificationSoundName(filename))
        }
        #elseif os(watchOS)
        // watchOS: rely on aps["sound"]; UNNotificationSound(named:) is unavailable in SDK.
        #else
        content.sound = UNNotificationSound(named: UNNotificationSoundName(filename))
        #endif

        return content
    }

    private func extractRequestedSoundName(from userInfo: [AnyHashable: Any]) -> String? {
        guard let aps = userInfo["aps"] as? [String: Any] else {
            return nil
        }

        if let soundString = aps["sound"] as? String {
            let trimmed = soundString.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }

        if let soundDict = aps["sound"] as? [String: Any],
           let name = soundDict["name"] as? String
        {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }

        return nil
    }

    private func resolveRingtoneFilename(named requested: String) -> String? {
        let trimmed = requested.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let candidate = trimmed.contains(".") ? trimmed : "\(trimmed).caf"

        if let customSoundsDirectoryURL {
            let customURL = customSoundsDirectoryURL.appendingPathComponent(candidate)
            if FileManager.default.fileExists(atPath: customURL.path) {
                return candidate
            }
        }

        let resourceName = (candidate as NSString).deletingPathExtension
        let resourceExt = (candidate as NSString).pathExtension
        if Bundle.main.url(forResource: resourceName, withExtension: resourceExt) != nil {
            return candidate
        }

        return nil
    }

    private func resolveDefaultRingtoneFilename() -> String? {
        let stored = UserDefaults(suiteName: AppConstants.appGroupIdentifier)?
            .string(forKey: AppConstants.defaultRingtoneFilenameKey)
        let trimmed = stored?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let candidate = trimmed.isEmpty ? AppConstants.fallbackRingtoneFilename : trimmed
        if let resolved = resolveRingtoneFilename(named: candidate) {
            return resolved
        }
        if candidate != AppConstants.fallbackRingtoneFilename {
            return resolveRingtoneFilename(named: AppConstants.fallbackRingtoneFilename)
        }
        return nil
    }

    private func makeNotificationBodyPreview(from text: String) -> String {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let firstLine = normalized
            .split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            .first
            .map(String.init) ?? ""
        let trimmed = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let stripped = stripMarkdown(from: trimmed)
        return stripped.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func stripMarkdown(from text: String) -> String {
        var result = text
        result = replace(#"\[([^\]]+)\]\([^)]+\)"#, in: result, with: "$1")
        result = replace(#"`([^`]+)`"#, in: result, with: "$1")
        result = replace(#"\*\*([^*]+)\*\*"#, in: result, with: "$1")
        result = replace(#"__([^_]+)__"#, in: result, with: "$1")
        result = replace(#"\*([^*\n]+)\*"#, in: result, with: "$1")
        result = replace(#"_([^_\n]+)_"#, in: result, with: "$1")
        result = replace(#"~~([^~]+)~~"#, in: result, with: "$1")
        result = replace(#"==([^=]+)=="#, in: result, with: "$1")
        result = replace(#"^\\s{0,3}#{1,6}\\s+"#, in: result, with: "")
        result = replace(#"^\\s{0,3}>\\s+"#, in: result, with: "")
        result = replace(#"^\\s{0,3}[-*+]\\s+"#, in: result, with: "")
        result = replace(#"^\\s{0,3}\\d+\\.\\s+"#, in: result, with: "")
        result = result.replacingOccurrences(of: "\\s{2,}", with: " ", options: .regularExpression)
        return result
    }

    private func replace(_ pattern: String, in text: String, with template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: template)
    }

    private func ensureDirectoryExists(at url: URL) -> Bool {
        if FileManager.default.fileExists(atPath: url.path) {
            return true
        }
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return true
        } catch {
            return false
        }
    }

    private func relativeSoundName(for fileURL: URL, baseDirectory: URL?) -> String {
        guard
            let baseDirectory,
            fileURL.path.hasPrefix(baseDirectory.path)
        else {
            return fileURL.lastPathComponent
        }

        let trimmed = fileURL.path.dropFirst(baseDirectory.path.count)
        let normalized = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return normalized.isEmpty ? fileURL.lastPathComponent : String(normalized)
    }

    private func migrateLegacyLongRingtoneIfNeeded(
        named fileName: String,
        legacyDirectory: URL,
        destinationDirectory: URL
    ) -> URL? {
        let legacyURL = legacyDirectory.appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: legacyURL.path) else {
            return nil
        }

        let destinationURL = destinationDirectory.appendingPathComponent(fileName)
        if !ensureDirectoryExists(at: destinationDirectory) {
            return legacyURL
        }

        do {
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                try FileManager.default.removeItem(at: destinationURL)
            }
            try FileManager.default.moveItem(at: legacyURL, to: destinationURL)
            return destinationURL
        } catch {
            return legacyURL
        }
    }

    private func applyLongRingtoneIfNeeded(to content: UNMutableNotificationContent) -> UNMutableNotificationContent {
        guard shouldUseLongRingtone(from: content.userInfo) else {
            return content
        }

        guard let longSoundURL = getLongSoundURL(for: content) else {
            return content
        }

        let soundName = relativeSoundName(
            for: longSoundURL,
            baseDirectory: customSoundsDirectoryURL ?? longSoundsDirectoryURL
        )

        #if os(iOS)
        if content.interruptionLevel == .critical {
            content.sound = UNNotificationSound.criticalSoundNamed(
                UNNotificationSoundName(soundName)
            )
        } else {
            content.sound = UNNotificationSound(
                named: UNNotificationSoundName(soundName)
            )
        }
        #elseif os(watchOS)
        // watchOS: rely on aps["sound"]; UNNotificationSound(named:) is unavailable in SDK.
        #else
        content.sound = UNNotificationSound(named: UNNotificationSoundName(soundName))
        #endif

        return content
    }

    private func shouldUseLongRingtone(from userInfo: [AnyHashable: Any]) -> Bool {
        if let mode = userInfo["ring_mode"] as? String {
            let trimmed = mode.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.lowercased() == "long" {
                return true
            }
        }
        return false
    }

    private func getLongSoundURL(for content: UNMutableNotificationContent) -> URL? {
        guard
            let customSoundsDirectoryURL,
            let longSoundsDirectoryURL
        else {
            return nil
        }
        guard let (soundName, soundType) = resolveSoundNameAndType(from: content.userInfo) else {
            return nil
        }

        let longSoundFileName = "\(AppConstants.longRingtonePrefix)\(soundName).\(soundType)"
        let longSoundURL = longSoundsDirectoryURL.appendingPathComponent(longSoundFileName)
        _ = ensureDirectoryExists(at: longSoundsDirectoryURL)
        if FileManager.default.fileExists(atPath: longSoundURL.path) {
            return longSoundURL
        }
        if let migrated = migrateLegacyLongRingtoneIfNeeded(
            named: longSoundFileName,
            legacyDirectory: customSoundsDirectoryURL,
            destinationDirectory: longSoundsDirectoryURL
        ) {
            if FileManager.default.fileExists(atPath: migrated.path) {
                return migrated
            }
        }
        var candidateURLs: [URL] = []
        let sharedSoundURL = customSoundsDirectoryURL.appendingPathComponent("\(soundName).\(soundType)")
        candidateURLs.append(sharedSoundURL)

        if let bundlePath = Bundle.main.path(forResource: soundName, ofType: soundType) {
            candidateURLs.append(URL(fileURLWithPath: bundlePath))
        }

        guard let sourceURL = candidateURLs.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
            return nil
        }

        return mergeCAFFilesToDuration(
            inputFile: sourceURL,
            outputDirectory: longSoundsDirectoryURL,
            outputFileName: longSoundFileName
        )
    }

    private func resolveSoundNameAndType(from userInfo: [AnyHashable: Any]) -> (String, String)? {
        guard let aps = userInfo["aps"] as? [String: Any] else {
            return nil
        }
        if let soundString = aps["sound"] as? String {
            let parts = soundString.split(separator: ".")
            if parts.count == 2 {
                return (String(parts[0]), String(parts[1]))
            } else if parts.count == 1 {
                return (soundString, "caf")
            }
        }
        if let soundDict = aps["sound"] as? [String: Any],
           let name = soundDict["name"] as? String
        {
            let parts = name.split(separator: ".")
            if parts.count == 2 {
                return (String(parts[0]), String(parts[1]))
            } else if parts.count == 1 {
                return (name, "caf")
            }
        }

        return nil
    }

    private func mergeCAFFilesToDuration(
        inputFile: URL,
        outputDirectory: URL,
        outputFileName: String,
        targetDuration: TimeInterval = 30
    ) -> URL? {
        guard ensureDirectoryExists(at: outputDirectory) else {
            return nil
        }

        let longSoundPath = outputDirectory.appendingPathComponent(outputFileName)
        if FileManager.default.fileExists(atPath: longSoundPath.path) {
            return longSoundPath
        }

        do {
            let audioFile = try AVAudioFile(forReading: inputFile)
            let audioFormat = audioFile.processingFormat
            let sampleRate = audioFormat.sampleRate
            let targetFrames = AVAudioFramePosition(targetDuration * sampleRate)
            var currentFrames: AVAudioFramePosition = 0
            let outputAudioFile = try AVAudioFile(forWriting: longSoundPath, settings: audioFormat.settings)
            while currentFrames < targetFrames {
                let remainingFrames = targetFrames - currentFrames
                let frameCapacity = AVAudioFrameCount(min(audioFile.length, remainingFrames))
                guard let buffer = AVAudioPCMBuffer(pcmFormat: audioFormat, frameCapacity: frameCapacity) else {
                    return nil
                }

                try audioFile.read(into: buffer)
                guard buffer.frameLength > 0 else {
                    break
                }

                if AVAudioFramePosition(buffer.frameLength) > remainingFrames {
                    guard let truncatedBuffer = AVAudioPCMBuffer(
                        pcmFormat: buffer.format,
                        frameCapacity: AVAudioFrameCount(remainingFrames)
                    ) else {
                        return nil
                    }

                    let channelCount = Int(buffer.format.channelCount)
                    for channel in 0 ..< channelCount {
                        guard
                            let sourcePointer = buffer.floatChannelData?[channel],
                            let destinationPointer = truncatedBuffer.floatChannelData?[channel]
                        else {
                            return nil
                        }
                        memcpy(
                            destinationPointer,
                            sourcePointer,
                            Int(remainingFrames) * MemoryLayout<Float>.size
                        )
                    }
                    truncatedBuffer.frameLength = AVAudioFrameCount(remainingFrames)
                    try outputAudioFile.write(from: truncatedBuffer)
                    currentFrames += remainingFrames
                    break
                } else {
                    try outputAudioFile.write(from: buffer)
                    currentFrames += AVAudioFramePosition(buffer.frameLength)
                }
                audioFile.framePosition = 0
            }

            return longSoundPath
        } catch {
            return nil
        }
    }

    private func handleDecryptionIfNeeded(
        for content: UNMutableNotificationContent,
        likelyEncrypted: Bool
    ) async throws -> DecryptResults? {
        let material = try await loadKeyMaterial()
        guard let material else {
            return nil
        }

        guard material.algorithm == .aesGcm else {
            if likelyEncrypted {
                content.userInfo["decryptionState"] = PushMessage.DecryptionState.algMismatch.rawValue
            }
            return nil
        }

        let key = try symmetricKey(from: material)
        let inlineResult = decryptInlineFields(content: content, key: key)
        let cipherResult = decryptCiphertextPayload(content: content, key: key)
        return DecryptResults(inline: inlineResult, cipher: cipherResult)
    }

    private func symmetricKey(from material: ServerConfig.NotificationKeyMaterial) throws -> SymmetricKey {
        guard let keyData = Data(base64Encoded: material.keyBase64) else {
            throw DecryptionError.invalidKeyMaterial
        }
        return SymmetricKey(data: keyData)
    }

    private func decryptInlineFields(
        content: UNMutableNotificationContent,
        key: SymmetricKey
    ) -> InlineDecryptResult {
        var decryptedAnyField = false

        for field in AlertField.allCases {
            let currentValue = field.currentValue(from: content)
            guard !currentValue.isEmpty else {
                continue
            }
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
                content.userInfo["ciphertext_body"] = body
                decryptedBody = body
                applied = true
            }
            if let image = payload.image?.trimmedNonEmpty {
                content.userInfo["image"] = image
                applied = true
            }
            if let icon = payload.icon?.trimmedNonEmpty {
                content.userInfo["icon"] = icon
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

    private func persistMessage(for request: UNNotificationRequest, content: UNMutableNotificationContent) async {
        let receivedAt = Date()
        let originalPayload = UserInfoSanitizer.sanitize(request.content.userInfo)
        var sanitizedPayload = UserInfoSanitizer.sanitize(content.userInfo)
        sanitizedPayload["_notificationRequestId"] = request.identifier
        sanitizedPayload["_receivedAt"] = Self.makeISOFormatter().string(from: receivedAt)
        if !originalPayload.isEmpty {
            sanitizedPayload["_originalUserInfo"] = originalPayload
        }

        let rawPayload = sanitizedPayload.reduce(into: [String: AnyCodable]()) { result, element in
            result[element.key] = AnyCodable(element.value)
        }

        let channelIdentifier = !content.threadIdentifier.isEmpty
            ? content.threadIdentifier
            : ((sanitizedPayload["channel_id"] as? String)
                ?? (sanitizedPayload["channel"] as? String))
        let channel = channelIdentifier?.trimmedNonEmpty
        let url = (sanitizedPayload["url"] as? String)
            .flatMap(URL.init(string:))
            .flatMap { URLSanitizer.isAllowedRemoteURL($0) ? $0 : nil }
        let stateRaw = sanitizedPayload["decryptionState"] as? String
        let decryptionState = stateRaw.flatMap(PushMessage.DecryptionState.init(rawValue:))
        let messageId = MessageIdExtractor.extract(from: sanitizedPayload)

        let storedBody = (sanitizedPayload["body"] as? String)?.trimmedNonEmpty ?? content.body
        let message = PushMessage(
            messageId: messageId,
            title: content.title.isEmpty ? ((sanitizedPayload["title"] as? String)?.trimmedNonEmpty ?? "") : content.title,
            body: storedBody,
            channel: channel,
            url: url,
            isRead: false,
            receivedAt: receivedAt,
            rawPayload: rawPayload,
            status: .normal,
            decryptionState: decryptionState
        )

        let store = LocalDataStore(appGroupIdentifier: AppConstants.appGroupIdentifier)
        var unreadCount = 1
        do {
            if let messageId, let _ = try? await store.loadMessage(messageId: messageId) {
                let counts = try await store.messageCounts()
                unreadCount = counts.unread
            } else if let _ = try? await store.loadMessage(notificationRequestId: request.identifier) {
                let counts = try await store.messageCounts()
                unreadCount = counts.unread
            } else {
                try await store.saveMessage(message)
                await store.flushWrites()
                let counts = try await store.messageCounts()
                unreadCount = counts.unread
                DarwinNotificationPoster.post(name: AppConstants.messageSyncNotificationName)
            }
        } catch {
        }
        content.badge = NSNumber(value: unreadCount)
    }

    private static func makeISOFormatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }

    private func attachMediaIfNeeded(to content: UNMutableNotificationContent) async {
        guard content.attachments.isEmpty else { return }
        let candidates: [(key: String, identifier: String)] = [
            ("image", "image"),
        ]
        let attachments = await NotificationMediaResolver.attachments(
            from: content.userInfo,
            candidates: candidates
        )
        if !attachments.isEmpty {
            content.attachments = attachments
        }
    }

    private func buildRenderPayloadJSON(text: String, isMarkdown: Bool) -> String? {
        MarkdownRenderPayloadSizing.userInfoPayloadJSONString(
            text: text,
            isMarkdown: isMarkdown
        )
    }

    #if canImport(Intents)
    @available(iOSApplicationExtension 15.0, macOSApplicationExtension 12.0, *)
    private func applyCommunicationStyleIfPossible(
        to content: UNMutableNotificationContent
    ) async -> UNNotificationContent? {
        guard let senderName = resolveSenderName(from: content) else {
            return nil
        }
        let iconURL = NotificationMediaResolver.urlValue(
            in: content.userInfo,
            keys: ["icon", "icon_url", "iconUrl"]
        )
        let imageURL = NotificationMediaResolver.urlValue(
            in: content.userInfo,
            keys: ["image", "image_url", "imageUrl", "picture", "pic"]
        )
        let conversationIdentifier: String = {
            if !content.threadIdentifier.isEmpty {
                return content.threadIdentifier
            }
            if let channelId = (content.userInfo["channel_id"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !channelId.isEmpty
            {
                return channelId
            }
            if let channel = (content.userInfo["channel"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !channel.isEmpty
            {
                return channel
            }
            return senderName
        }()

        async let iconImage: INImage? = {
            guard let iconURL else { return nil }
            return await Self.downloadINImage(from: iconURL, maxBytes: AppConstants.maxMessageImageBytes)
        }()

        async let intentAttachment: INSendMessageAttachment? = {
            guard let imageURL else { return nil }
            return await Self.downloadIntentAttachment(from: imageURL, maxBytes: AppConstants.maxMessageImageBytes)
        }()

        let resolvedIcon = await iconImage
        let resolvedAttachment = await intentAttachment
        let intentAttachments = resolvedAttachment.map { [$0] }
        var nameComponents = PersonNameComponents()
        nameComponents.nickname = senderName
        let senderHandle = INPersonHandle(value: senderName, type: .unknown)
        let senderPerson = INPerson(
            personHandle: senderHandle,
            nameComponents: nameComponents,
            displayName: senderName,
            image: resolvedIcon,
            contactIdentifier: nil,
            customIdentifier: nil,
            isMe: false,
            suggestionType: .none
        )
        let mePerson = INPerson(
            personHandle: INPersonHandle(value: "", type: .unknown),
            nameComponents: nil,
            displayName: nil,
            image: nil,
            contactIdentifier: nil,
            customIdentifier: nil,
            isMe: true,
            suggestionType: .none
        )

        let groupName: INSpeakableString? = nil

        // Keep a stable conversation identifier so the system can thread related notifications.
        let intent = INSendMessageIntent(
            recipients: [mePerson],
            outgoingMessageType: .outgoingMessageText,
            content: content.body,
            speakableGroupName: groupName,
            conversationIdentifier: conversationIdentifier,
            serviceName: nil,
            sender: senderPerson,
            attachments: intentAttachments
        )
        #if os(iOS)
        if let iconImage = resolvedIcon {
            intent.setImage(iconImage, forParameterNamed: \.sender)
            intent.setImage(iconImage, forParameterNamed: \.recipients)
            if groupName != nil {
                intent.setImage(iconImage, forParameterNamed: \.speakableGroupName)
            }
        }
        #endif
        let interaction = INInteraction(intent: intent, response: nil)
        interaction.direction = .incoming
        do {
            let updated = try content.updating(from: intent)
            return updated
        } catch {
            return nil
        }
    }

    private func resolveSenderName(from content: UNNotificationContent) -> String? {
        let candidates: [String?] = [
            (content.userInfo["sender"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
            (content.userInfo["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
            content.title.trimmingCharacters(in: .whitespacesAndNewlines),
        ]
        for value in candidates {
            if let text = value, !text.isEmpty {
                return text
            }
        }
        return nil
    }

    @available(iOSApplicationExtension 15.0, macOSApplicationExtension 12.0, *)
    private static func downloadINImage(from url: URL, maxBytes: Int64) async -> INImage? {
        guard URLSanitizer.isAllowedRemoteURL(url) else { return nil }
        do {
            if let cachedURL = SharedImageCache.cachedFileURL(for: url) {
                if let cachedData = try? Data(contentsOf: cachedURL) {
                    return INImage(imageData: cachedData)
                }
            }
            let data = try await SharedImageCache.fetchData(from: url, maxBytes: maxBytes, timeout: 10)
            let ext = url.pathExtension.isEmpty ? "img" : url.pathExtension
            let targetURL = await SharedImageCache.store(data: data, for: url)
                ?? FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).\(ext)")
            if !FileManager.default.fileExists(atPath: targetURL.path) {
                try? data.write(to: targetURL, options: [.atomic])
            }

            return INImage(imageData: data)
        } catch {
            return nil
        }
    }

    @available(iOSApplicationExtension 15.0, macOSApplicationExtension 12.0, *)
    private static func downloadIntentAttachment(from url: URL, maxBytes: Int64) async -> INSendMessageAttachment? {
        guard URLSanitizer.isAllowedRemoteURL(url) else { return nil }
        do {
            let data = try await SharedImageCache.fetchData(from: url, maxBytes: maxBytes, timeout: 10)
            guard NotificationMediaResolver.isImageData(data) else { return nil }
            let filename = url.lastPathComponent.isEmpty ? "image" : url.lastPathComponent
            let utType = UTType(filenameExtension: url.pathExtension) ?? .image
            let targetURL = SharedImageCache.cachedFileURL(for: url)
                ?? FileManager.default.temporaryDirectory.appendingPathComponent(filename)
            if !FileManager.default.fileExists(atPath: targetURL.path) {
                try? data.write(to: targetURL, options: [.atomic])
            }
            let file = INFile(data: data, filename: filename, typeIdentifier: utType.identifier)
            return INSendMessageAttachment(audioMessageFile: file)
        } catch {
            return nil
        }
    }
    #endif

    private func loadKeyMaterial() async throws -> ServerConfig.NotificationKeyMaterial? {
        let store = LocalDataStore(appGroupIdentifier: AppConstants.appGroupIdentifier)
        return try await store.loadServerConfig()?.notificationKeyMaterial
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
}

private struct CiphertextPayload: Decodable {
    let title: String?
    let body: String?
    let image: String?
    let icon: String?

    enum CodingKeys: String, CodingKey {
        case title
        case body
        case image
        case icon
    }
}

private extension String {
    var trimmedNonEmpty: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
