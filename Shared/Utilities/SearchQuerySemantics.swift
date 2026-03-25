import Foundation

struct SearchQuerySemantics {
    static func normalizedSearchIndexQuery(from raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return raw }
        let tokens = trimmed.split(whereSeparator: { $0.isWhitespace })
        guard !tokens.isEmpty else { return raw }
        return tokens
            .map { String($0).replacingOccurrences(of: "\"", with: "") }
            .map { "\"\($0)\"" }
            .joined(separator: " AND ")
    }
}
