import Foundation

struct PushMessage: Identifiable, Codable, Equatable {
    enum Status: String, Codable {
        case normal
        case missing
        case partiallyDecrypted
        case decrypted
    }

    enum DecryptionState: String, Codable {
        case notConfigured
        case algMismatch
        case decryptOk
        case decryptFailed
    }

    struct ResolvedBody: Equatable {
        let rawText: String
        let isMarkdown: Bool
        let source: BodySource
    }

    enum BodySource: String, Codable {
        case ciphertextBody
        case body
    }

    var id: UUID
    var messageId: UUID?
    var title: String
    var body: String
    var channel: String?
    var url: URL?
    var isRead: Bool
    var receivedAt: Date
    var rawPayload: [String: AnyCodable]
    var status: Status
    var decryptionState: DecryptionState?

    init(
        id: UUID = UUID(),
        messageId: UUID?,
        title: String,
        body: String,
        channel: String? = nil,
        url: URL? = nil,
        isRead: Bool = false,
        receivedAt: Date = Date(),
        rawPayload: [String: AnyCodable] = [:],
        status: Status = .normal,
        decryptionState: DecryptionState? = nil,
    ) {
        self.id = id
        self.messageId = messageId
        self.title = title
        self.body = body
        self.channel = channel
        self.url = url
        self.isRead = isRead
        self.receivedAt = receivedAt
        self.rawPayload = rawPayload
        self.status = status
        self.decryptionState = decryptionState
    }
}

extension PushMessage: @unchecked Sendable {}

extension PushMessage {
    var originalUserInfoPayload: [String: AnyCodable]? {
        guard let raw = rawPayload["_originalUserInfo"]?.value as? [String: Any] else {
            return nil
        }
        return raw.reduce(into: [String: AnyCodable]()) { result, element in
            result[element.key] = AnyCodable(element.value)
        }
    }
    var payloadForDisplay: [String: AnyCodable] {
        originalUserInfoPayload ?? rawPayload
    }

    var resolvedBody: ResolvedBody {
        let ciphertextBody = stringValue(forKeys: ["ciphertext_body"], in: rawPayload)
        let isMarkdownOverride = rawPayload["body_render_is_markdown"]?.value as? Bool

        return MessageBodyResolver.resolve(
            ciphertextBody: ciphertextBody,
            envelopeBody: body,
            isMarkdownOverride: isMarkdownOverride,
        )
    }

    var iconURL: URL? {
        urlValue(forKeys: ["icon", "iconUrl", "icon_url"])
    }

    var imageURL: URL? {
        urlValue(forKeys: ["image", "imageUrl", "image_url", "picture", "pic"])
    }

    var isEncrypted: Bool {
        if decryptionState != nil { return true }
        let encryptedKeys = ["ciphertext", "encrypted"]
        return encryptedKeys.contains { rawPayload[$0] != nil || metaValue(forKey: $0) != nil }
    }

    private func urlValue(forKeys keys: [String]) -> URL? {
        guard let text = stringValue(forKeys: keys),
              let url = URLSanitizer.resolveHTTPSURL(from: text)
        else {
            return nil
        }
        return url
    }

    private func stringValue(
        forKeys keys: [String],
        in payload: [String: AnyCodable],
    ) -> String? {
        keys.compactMap { key in
            (payload[key]?.value as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        .first(where: { !$0.isEmpty })
    }


    private func stringValue(forKeys keys: [String]) -> String? {
        if let value = keys.compactMap({ key in
            (rawPayload[key]?.value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        }).first(where: { !$0.isEmpty }) {
            return value
        }

        if let meta = rawPayload["meta"]?.value as? [String: AnyCodable],
           let value = keys.compactMap({ key in
               (meta[key]?.value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
           }).first(where: { !$0.isEmpty })
        {
            return value
        }

        if let meta = rawPayload["meta"]?.value as? [String: Any],
           let value = keys.compactMap({ key in
               (meta[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
           }).first(where: { !$0.isEmpty })
        {
            return value
        }

        if let value = apsValue(forKeys: keys) {
            return value
        }

        return nil
    }

    private func apsValue(forKeys keys: [String], in aps: [String: AnyCodable]) -> String? {
        keys.compactMap { key in
            (aps[key]?.value as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        .first(where: { !$0.isEmpty })
    }

    private func apsValue(forKeys keys: [String]) -> String? {
        if let aps = rawPayload["aps"]?.value as? [String: AnyCodable],
           let value = apsValue(forKeys: keys, in: aps)
        {
            return value
        }

        if let aps = rawPayload["aps"]?.value as? [String: Any],
           let value = keys.compactMap({ key in
               (aps[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
           }).first(where: { !$0.isEmpty })
        {
            return value
        }

        return nil
    }

    private func metaValue(forKey key: String) -> Any? {
        if let meta = rawPayload["meta"]?.value as? [String: AnyCodable] {
            return meta[key]?.value
        }
        if let meta = rawPayload["meta"]?.value as? [String: Any] {
            return meta[key]
        }
        return nil
    }

    var notificationRequestId: String? {
        rawPayload["_notificationRequestId"]?.value as? String
    }
}

enum MessageBodyResolver {
    static func resolve(
        ciphertextBody: String?,
        envelopeBody: String,
        isMarkdownOverride: Bool?,
    ) -> PushMessage.ResolvedBody {
        if let cipherBody = trimmed(ciphertextBody) {
            let isMarkdown = isMarkdownOverride ?? PushGoMarkdownDetector.containsMarkdownSyntax(cipherBody)
            return PushMessage.ResolvedBody(
                rawText: cipherBody,
                isMarkdown: isMarkdown,
                source: .ciphertextBody,
            )
        }

        let rawText = trimmed(envelopeBody) ?? ""
        let isMarkdown = isMarkdownOverride ?? PushGoMarkdownDetector.containsMarkdownSyntax(rawText)
        return PushMessage.ResolvedBody(rawText: rawText, isMarkdown: isMarkdown, source: .body)
    }

    private static func trimmed(_ value: String?) -> String? {
        guard let raw = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty
        else {
            return nil
        }
        return raw
    }
}

enum PushGoMarkdownDetector {
    static func containsMarkdownSyntax(_ text: String) -> Bool {
        let raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return false }

        if raw.contains("```") { return true }

        if InlineRegex.bold.firstMatch(in: raw, options: [], range: raw.nsRange) != nil { return true }
        if InlineRegex.italicAsterisk.firstMatch(in: raw, options: [], range: raw.nsRange) != nil { return true }
        if InlineRegex.italicUnderscore.firstMatch(in: raw, options: [], range: raw.nsRange) != nil { return true }
        if InlineRegex.strikethrough.firstMatch(in: raw, options: [], range: raw.nsRange) != nil { return true }
        if InlineRegex.highlight.firstMatch(in: raw, options: [], range: raw.nsRange) != nil { return true }
        if InlineRegex.inlineCode.firstMatch(in: raw, options: [], range: raw.nsRange) != nil { return true }
        if InlineRegex.link.firstMatch(in: raw, options: [], range: raw.nsRange) != nil { return true }

        let lines = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            if BlockRegex.heading.firstMatch(in: line, options: [], range: line.nsRange) != nil { return true }
            if BlockRegex.callout.firstMatch(in: line, options: [], range: line.nsRange) != nil { return true }
            if BlockRegex.blockquote.firstMatch(in: line, options: [], range: line.nsRange) != nil { return true }
            if BlockRegex.unorderedList.firstMatch(in: line, options: [], range: line.nsRange) != nil { return true }
            if BlockRegex.orderedList.firstMatch(in: line, options: [], range: line.nsRange) != nil { return true }
            if BlockRegex.horizontalRule.firstMatch(in: line, options: [], range: line.nsRange) != nil { return true }
        }

        if lines.count >= 2 {
            for index in 0 ..< (lines.count - 1) {
                let headerLine = lines[index]
                let separatorLine = lines[index + 1]
                if headerLine.contains("|"),
                   BlockRegex.tableSeparator.firstMatch(in: separatorLine, options: [], range: separatorLine.nsRange) != nil
                {
                    return true
                }
            }
        }

        return false
    }
}

private enum InlineRegex {
    static let noMatchRegex = makeNoMatchRegex()
    static let bold = make(#"(?:\*\*|__)(?=\S).+?(?<=\S)(?:\*\*|__)"#, options: [])
    static let italicAsterisk = make(#"(?<!\*)\*(?=\S)[^*\n]+?(?<=\S)\*(?!\*)"#, options: [])
    static let italicUnderscore = make(#"(?<!_)_(?=\S)[^_\n]+?(?<=\S)_(?!_)"#, options: [])
    static let strikethrough = make(#"~~(?=\S).+?(?<=\S)~~"#, options: [])
    static let highlight = make(#"==(?=\S).+?(?<=\S)=="#, options: [])
    static let inlineCode = make(#"`[^`\n]+`"#, options: [])
    static let link = make(#"\[[^\]\n]+\]\(([^)\s]+)\)"#, options: [])

    private static func make(_ pattern: String, options: NSRegularExpression.Options) -> NSRegularExpression {
        do {
            return try NSRegularExpression(pattern: pattern, options: options)
        } catch {
            return noMatchRegex
        }
    }

    private static func makeNoMatchRegex() -> NSRegularExpression {
        if let regex = try? NSRegularExpression(pattern: "(?!)") { return regex }
        if let regex = try? NSRegularExpression(pattern: "a^") { return regex }
        return try! NSRegularExpression(pattern: "(?!)")
    }
}

private enum BlockRegex {
    static let noMatchRegex = makeNoMatchRegex()
    static let heading = make(#"^\s{0,3}#{1,6}\s+.+$"#, options: [])
    static let callout = make(#"^\s{0,3}>\s*\[\!(info|success|warning|error)\]\s*.*$"#, options: [.caseInsensitive])
    static let blockquote = make(#"^\s{0,3}>\s?.+$"#, options: [])
    static let unorderedList = make(#"^\s{0,3}[-*]\s+.+$"#, options: [])
    static let orderedList = make(#"^\s{0,3}\d+\.\s+.+$"#, options: [])
    static let horizontalRule = make(#"^\s{0,3}(([-*_])\s*){3,}$"#, options: [])
    static let tableSeparator = make(#"^\s*\|?\s*-+\s*(\|\s*-+\s*)+\|?\s*$"#, options: [])

    private static func make(_ pattern: String, options: NSRegularExpression.Options) -> NSRegularExpression {
        do {
            return try NSRegularExpression(pattern: pattern, options: options)
        } catch {
            return noMatchRegex
        }
    }

    private static func makeNoMatchRegex() -> NSRegularExpression {
        if let regex = try? NSRegularExpression(pattern: "(?!)") { return regex }
        if let regex = try? NSRegularExpression(pattern: "a^") { return regex }
        return try! NSRegularExpression(pattern: "(?!)")
    }
}

private extension String {
    var nsRange: NSRange { NSRange(location: 0, length: utf16.count) }
}
