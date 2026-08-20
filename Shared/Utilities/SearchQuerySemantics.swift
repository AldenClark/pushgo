import Foundation

struct SearchQuerySemantics {
    struct IndexTextQuery: Sendable, Equatable {
        let trigramQuery: String?
        let normalizedTokens: [String]
    }

    struct ParsedQuery: Sendable, Equatable {
        let textTokens: [String]
        let tags: [String]

        var isEmpty: Bool {
            textTokens.isEmpty && tags.isEmpty
        }

        var indexTextQuery: IndexTextQuery? {
            guard !textTokens.isEmpty else { return nil }
            let normalizedTokens = textTokens
                .map(SearchQuerySemantics.normalizeText)
                .filter { !$0.isEmpty }
            guard !normalizedTokens.isEmpty else { return nil }

            var seenTrigrams: Set<String> = []
            let trigrams = normalizedTokens
                .flatMap(SearchQuerySemantics.representativeTrigrams)
                .filter { seenTrigrams.insert($0).inserted }
            let trigramQuery = trigrams.isEmpty
                ? nil
                : trigrams
                    .map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"" }
                    .joined(separator: " AND ")
            return IndexTextQuery(
                trigramQuery: trigramQuery,
                normalizedTokens: normalizedTokens
            )
        }
    }

    private static let maximumRepresentativeTrigramsPerToken = 16
    private static let normalizationLocale = Locale(identifier: "en_US_POSIX")

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

    static func normalizeText(_ raw: String) -> String {
        raw.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: normalizationLocale
        )
        .lowercased(with: normalizationLocale)
    }

    private static func representativeTrigrams(in token: String) -> [String] {
        let scalars = Array(token.unicodeScalars)
        let trigramCount = scalars.count - 2
        guard trigramCount > 0 else { return [] }

        let selectedOffsets: [Int]
        if trigramCount <= maximumRepresentativeTrigramsPerToken {
            selectedOffsets = Array(0 ..< trigramCount)
        } else {
            selectedOffsets = (0 ..< maximumRepresentativeTrigramsPerToken).map { index in
                index * (trigramCount - 1) / (maximumRepresentativeTrigramsPerToken - 1)
            }
        }

        return selectedOffsets.map { offset in
            scalars[offset ..< offset + 3].reduce(into: "") { trigram, scalar in
                trigram.unicodeScalars.append(scalar)
            }
        }
    }
}
