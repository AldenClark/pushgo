import Foundation

struct SearchQuerySemantics {
    struct ParsedQuery: Sendable, Equatable {
        let textTokens: [String]
        let tags: [String]

        var isEmpty: Bool {
            textTokens.isEmpty && tags.isEmpty
        }

        var textQueryForFTS: String? {
            guard !textTokens.isEmpty else { return nil }
            return textTokens
                .map { "\"\($0.replacingOccurrences(of: "\"", with: ""))\"" }
                .joined(separator: " AND ")
        }
    }

    static func normalizedSearchIndexQuery(from raw: String) -> String {
        parse(raw).textQueryForFTS ?? raw
    }

    static func parse(_ raw: String) -> ParsedQuery {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return ParsedQuery(textTokens: [], tags: [])
        }

        var textTokens: [String] = []
        var tagSet: Set<String> = []
        var tags: [String] = []

        for rawToken in trimmed.split(whereSeparator: { $0.isWhitespace }).map(String.init) {
            let token = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !token.isEmpty else { continue }

            if let tag = parseTagToken(token), tagSet.insert(tag).inserted {
                tags.append(tag)
                continue
            }

            let textToken = token.replacingOccurrences(of: "\"", with: "")
            guard !textToken.isEmpty else { continue }
            textTokens.append(textToken)
        }

        return ParsedQuery(textTokens: textTokens, tags: tags)
    }

    private static func parseTagToken(_ token: String) -> String? {
        if token.hasPrefix("#") {
            return normalizeTagValue(String(token.dropFirst()))
        }

        let lowercased = token.lowercased()
        if lowercased.hasPrefix("tag:") {
            let suffix = String(token.dropFirst(4))
            return normalizeTagValue(suffix)
        }
        return nil
    }

    private static func normalizeTagValue(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.lowercased()
    }
}
