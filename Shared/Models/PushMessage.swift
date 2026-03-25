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

    enum Severity: String, Codable {
        case low
        case medium
        case high
        case critical

        static func from(raw: String?) -> Severity? {
            switch raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "low":
                return .low
            case "medium", "normal":
                return .medium
            case "high":
                return .high
            case "critical":
                return .critical
            default:
                return nil
            }
        }
    }

    struct ResolvedBody: Equatable {
        let rawText: String
        let isMarkdown: Bool
        let source: BodySource
    }

    enum BodySource: String, Codable {
        case body
    }

    typealias Metadata = [String: String]

    var id: UUID
    var messageId: String?
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
        messageId: String?,
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

extension PushMessage {
    var resolvedBody: ResolvedBody {
        MessageBodyResolver.resolve(envelopeBody: body)
    }

    var imageURLs: [URL] {
        var urls: [URL] = []
        appendURLValues(forKeys: ["images"], into: &urls)
        return urls
    }

    var imageURL: URL? {
        imageURLs.first
    }

    var isEncrypted: Bool {
        if decryptionState != nil { return true }
        return rawPayload["ciphertext"] != nil
    }

    var metadata: Metadata {
        guard let raw = rawPayload["metadata"]?.value else { return [:] }
        return Self.decodeMetadataMap(from: raw)
    }

    var tags: [String] {
        guard let raw = rawPayload["tags"]?.value else { return [] }
        return Self.decodeTags(from: raw)
    }

    var severity: Severity? {
        Severity.from(raw: stringValue(forKeys: ["severity"]))
    }

    private func urlValue(forKeys keys: [String]) -> URL? {
        guard let text = stringValue(forKeys: keys),
              let url = URLSanitizer.resolveExternalOpenURL(from: text)
        else {
            return nil
        }
        return url
    }

    private func appendURLValues(forKeys keys: [String], into urls: inout [URL]) {
        for key in keys {
            guard let raw = rawPayload[key]?.value else { continue }
            Self.appendResolvedURLs(from: raw, into: &urls)
        }
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
        keys.compactMap { key in
            (rawPayload[key]?.value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        .first(where: { !$0.isEmpty })
    }

    var notificationRequestId: String? {
        rawPayload["_notificationRequestId"]?.value as? String
    }

    var deliveryId: String? {
        stringValue(forKeys: ["delivery_id"])
    }

    var operationId: String? {
        stringValue(forKeys: ["op_id"])
    }

    var entityType: String {
        resolvedEntityType()
    }

    var entityId: String? {
        stringValue(forKeys: ["entity_id"])
    }

    var eventId: String? {
        stringValue(forKeys: ["event_id"])
    }

    var thingId: String? {
        stringValue(forKeys: ["thing_id"])
    }

    var projectionDestination: String? {
        stringValue(forKeys: ["projection_destination"])
    }

    var eventState: String? {
        stringValue(forKeys: ["event_state"])
    }

    private static func decodeMetadataMap(from raw: Any) -> Metadata {
        guard let text = raw as? String else { return [:] }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return [:] }
        guard let decoded = try? JSONSerialization.jsonObject(with: data, options: []) else {
            return [:]
        }
        return decodeMetadataMap(fromJSONObject: decoded)
    }

    private static func decodeMetadataMap(fromJSONObject raw: Any) -> Metadata {
        if let object = raw as? [String: Any] {
            var output: Metadata = [:]
            for (rawKey, rawValue) in object {
                let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !key.isEmpty, let value = metadataValueString(rawValue) else { continue }
                output[key] = value
            }
            return output
        }
        return [:]
    }

    private static func decodeTags(from raw: Any) -> [String] {
        let values: [String]
        switch raw {
        case let raw as String:
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return [] }
            if let data = trimmed.data(using: .utf8),
               let decoded = try? JSONSerialization.jsonObject(with: data, options: [])
            {
                if let array = decoded as? [Any] {
                    values = array.compactMap(metadataValueString)
                } else {
                    values = []
                }
            } else {
                values = []
            }
        default:
            values = []
        }

        var output: [String] = []
        output.reserveCapacity(values.count)
        var seen = Set<String>()
        for value in values {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { continue }
            output.append(trimmed)
        }
        return output
    }

    private static func metadataValueString(_ raw: Any?) -> String? {
        switch raw {
        case let value as String:
            return value.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        case let value as Int:
            return String(value)
        case let value as Int64:
            return String(value)
        case let value as Double:
            return String(value)
        case let value as Bool:
            return value ? "true" : "false"
        default:
            return nil
        }
    }

    private static func appendResolvedURLs(from raw: Any, into urls: inout [URL]) {
        switch raw {
        case let value as String:
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            if let data = trimmed.data(using: .utf8),
               let decoded = try? JSONSerialization.jsonObject(with: data),
               let array = decoded as? [Any]
            {
                for item in array {
                    appendResolvedURLs(from: item, into: &urls)
                }
                return
            }
            if let url = URLSanitizer.resolveHTTPSURL(from: trimmed),
               !urls.contains(where: { $0.absoluteString == url.absoluteString })
            {
                urls.append(url)
            }
        default:
            return
        }
    }

    private func resolvedEntityType() -> String {
        switch stringValue(forKeys: ["entity_type"])?.lowercased() {
        case "event":
            return "event"
        case "thing":
            return "thing"
        default:
            return "message"
        }
    }
}

enum MessageBodyResolver {
    static func resolve(envelopeBody: String) -> PushMessage.ResolvedBody {
        let rawText = trimmed(envelopeBody) ?? ""
        return PushMessage.ResolvedBody(rawText: rawText, isMarkdown: true, source: .body)
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
        fatalError("Failed to compile internal fallback regex patterns for inline markdown detection.")
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
        fatalError("Failed to compile internal fallback regex patterns for block markdown detection.")
    }
}

private extension String {
    var nsRange: NSRange { NSRange(location: 0, length: utf16.count) }

    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
