import Foundation

enum PushGoMarkdownDisplayMode: String, Equatable {
    case structuredText = "structured_text"
    case inlineText = "inline_text"
    case plainText = "plain_text"

    var automationLoadSource: String {
        switch self {
        case .structuredText:
            return "structured_text"
        case .inlineText:
            return "inline_text"
        case .plainText:
            return "plain_text_fallback"
        }
    }
}

func pushGoPlainTextDisplaySegments(
    for text: String,
    maxChunkBytes: Int = 16 * 1024,
    maxChunkLines: Int = 160
) -> [String] {
    guard !text.isEmpty else { return [""] }
    guard maxChunkBytes > 0, maxChunkLines > 0 else { return [text] }

    let rawLines = text.split(separator: "\n", omittingEmptySubsequences: false)
    let lines = rawLines.enumerated().map { index, line in
        index < rawLines.count - 1 ? "\(line)\n" : String(line)
    }
    guard lines.count > maxChunkLines || text.lengthOfBytes(using: .utf8) > maxChunkBytes else {
        return [text]
    }

    var segments: [String] = []
    var currentLines: [String] = []
    var currentBytes = 0

    func flushCurrentLines() {
        guard !currentLines.isEmpty else { return }
        segments.append(currentLines.joined())
        currentLines.removeAll(keepingCapacity: true)
        currentBytes = 0
    }

    for line in lines {
        let lineBytes = line.lengthOfBytes(using: .utf8)
        let wouldExceedBytes = currentBytes + lineBytes > maxChunkBytes
        let wouldExceedLines = currentLines.count >= maxChunkLines
        if wouldExceedBytes || wouldExceedLines {
            flushCurrentLines()
        }
        currentLines.append(line)
        currentBytes += lineBytes
    }

    flushCurrentLines()
    return segments.isEmpty ? [text] : segments
}

func pushGoMarkdownDisplayMode(for text: String) -> PushGoMarkdownDisplayMode {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return .plainText }

#if os(macOS)
    let utf8ByteCount = trimmed.lengthOfBytes(using: .utf8)
    let newlineCount = trimmed.reduce(into: 0) { partialResult, character in
        if character == "\n" {
            partialResult += 1
        }
    }
    if utf8ByteCount > 512 * 1024 || newlineCount > 20_000 {
        return .plainText
    }
#endif

    if trimmed.contains("\n") { return .structuredText }
    if trimmed.contains("![") { return .structuredText }
    if trimmed.contains("```") { return .structuredText }
    if trimmed.hasPrefix("#") || trimmed.hasPrefix(">") { return .structuredText }
    if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") { return .structuredText }
    if let first = trimmed.first, first.isNumber, trimmed.contains(". ") {
        return .structuredText
    }
    if trimmed.contains("|") { return .structuredText }
    return .inlineText
}

struct PushGoMarkdownDocument: Equatable {
    let blocks: [MarkdownBlock]
}

enum MarkdownBlock: Equatable {
    case heading(level: Int, content: [MarkdownInline])
    case paragraph([MarkdownInline])
    case bulletList([MarkdownListItem])
    case orderedList([MarkdownListItem])
    case blockquote([MarkdownInline])
    case horizontalRule
    case table(MarkdownTable)
    case callout(type: MarkdownCalloutType, content: [MarkdownInline])
}

struct MarkdownListItem: Equatable {
    let content: [MarkdownInline]
    let ordinal: Int?

    init(content: [MarkdownInline], ordinal: Int? = nil) {
        self.content = content
        self.ordinal = ordinal
    }
}

struct MarkdownTable: Equatable {
    let headers: [[MarkdownInline]]
    let rows: [[[MarkdownInline]]]
}

enum MarkdownCalloutType: String, Equatable {
    case info
    case success
    case warning
    case error
}

enum MarkdownInline: Equatable {
    case text(String)
    case bold([MarkdownInline])
    case italic([MarkdownInline])
    case strikethrough([MarkdownInline])
    case highlight([MarkdownInline])
    case code(String)
    case link(text: [MarkdownInline], url: String)
    case mention(String)
    case tag(String)
    case autolink(Autolink)
}

struct Autolink: Equatable {
    enum Kind: Equatable {
        case url
        case email
        case phone
    }

    let kind: Kind
    let value: String

    var urlValue: URL? {
        switch kind {
        case .url:
            return URL(string: value)
        case .email:
            return URL(string: "mailto:\(value)")
        case .phone:
            let compact = value
                .replacingOccurrences(of: " ", with: "")
                .replacingOccurrences(of: "-", with: "")
            return URL(string: "tel:\(compact)")
        }
    }
}

struct MarkdownRenderPayload: Codable, Equatable, Hashable, Sendable {
    static let currentVersion = 2

    let version: Int
    let runs: [MarkdownRenderRun]

    init(version: Int = MarkdownRenderPayload.currentVersion, runs: [MarkdownRenderRun]) {
        self.version = version
        self.runs = runs
    }

    private enum CodingKeys: String, CodingKey {
        case version = "v"
        case runs = "r"
    }
}

struct MarkdownRenderRun: Codable, Equatable, Hashable, Sendable {
    let text: String
    let isBold: Bool
    let isItalic: Bool
    let isStrikethrough: Bool
    let isHighlight: Bool
    let isCode: Bool
    let link: String?
    let role: MarkdownInlineRole?

    init(
        text: String,
        isBold: Bool,
        isItalic: Bool,
        isStrikethrough: Bool,
        isHighlight: Bool,
        isCode: Bool,
        link: String?,
        role: MarkdownInlineRole?
    ) {
        self.text = text
        self.isBold = isBold
        self.isItalic = isItalic
        self.isStrikethrough = isStrikethrough
        self.isHighlight = isHighlight
        self.isCode = isCode
        self.link = link
        self.role = role
    }

    private enum CodingKeys: String, CodingKey {
        case text = "t"
        case flags = "f"
        case link = "l"
        case role = "r"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        text = try container.decode(String.self, forKey: .text)
        let flags = (try? container.decode(Int.self, forKey: .flags)) ?? 0
        isBold = (flags & 1) != 0
        isItalic = (flags & 2) != 0
        isStrikethrough = (flags & 4) != 0
        isHighlight = (flags & 8) != 0
        isCode = (flags & 16) != 0
        link = try container.decodeIfPresent(String.self, forKey: .link)
        role = try container.decodeIfPresent(MarkdownInlineRole.self, forKey: .role)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(text, forKey: .text)
        let flags = styleFlags
        if flags != 0 {
            try container.encode(flags, forKey: .flags)
        }
        try container.encodeIfPresent(link, forKey: .link)
        try container.encodeIfPresent(role, forKey: .role)
    }
}

enum MarkdownInlineRole: String, Codable, Equatable, Hashable, Sendable {
    case mention
    case tag
}

struct MarkdownRenderBudget: Equatable, Hashable, Sendable {
    let maxCharacters: Int?
    let maxListItems: Int?
    let maxTableRows: Int?
}

extension MarkdownRenderPayload {
    static func buildIfMarkdown(
        text: String,
        isMarkdown: Bool,
        maxCharacters: Int?,
    ) -> MarkdownRenderPayload? {
        let budget = MarkdownRenderBudget(
            maxCharacters: maxCharacters,
            maxListItems: nil,
            maxTableRows: nil
        )
        return buildIfMarkdown(text: text, isMarkdown: isMarkdown, budget: budget)
    }

    static func buildIfMarkdown(
        text: String,
        isMarkdown: Bool,
        budget: MarkdownRenderBudget
    ) -> MarkdownRenderPayload? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isMarkdown, !trimmed.isEmpty else { return nil }
        return MarkdownRenderBuilder(budget: budget).build(from: trimmed)
    }

    static func decode(from jsonString: String) -> MarkdownRenderPayload? {
        guard let data = jsonString.data(using: .utf8),
              let payload = try? JSONDecoder().decode(MarkdownRenderPayload.self, from: data),
              payload.version == MarkdownRenderPayload.currentVersion
        else {
            return nil
        }
        return payload
    }

    func encodeToJSONString() -> String? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

private struct MarkdownRenderStyle: Equatable {
    var isBold = false
    var isItalic = false
    var isStrikethrough = false
    var isHighlight = false
    var isCode = false
    var link: String?
    var role: MarkdownInlineRole?
}

private struct MarkdownRenderBuilder {
    let maxCharacters: Int?
    let maxListItems: Int?
    let maxTableRows: Int?
    private var runs: [MarkdownRenderRun] = []
    private var characterCount = 0
    private var isTruncated = false

    init(budget: MarkdownRenderBudget) {
        maxCharacters = budget.maxCharacters
        maxListItems = budget.maxListItems
        maxTableRows = budget.maxTableRows
    }

    func build(from text: String) -> MarkdownRenderPayload {
        var builder = self
        let document = PushGoMarkdownParser().parse(text)
        if document.blocks.isEmpty {
            builder.appendText(text, style: MarkdownRenderStyle())
            return MarkdownRenderPayload(runs: builder.runs)
        }

        for (index, block) in document.blocks.enumerated() {
            if builder.isTruncated { break }
            builder.appendBlock(block)
            if index < document.blocks.count - 1 {
                builder.appendLineBreakIfNeeded()
            }
        }

        return MarkdownRenderPayload(runs: builder.runs)
    }

    private mutating func appendBlock(_ block: MarkdownBlock) {
        switch block {
        case let .heading(_, content):
            var headerStyle = MarkdownRenderStyle()
            headerStyle.isBold = true
            appendInlines(content, style: headerStyle)
            appendLineBreakIfNeeded()
        case let .paragraph(inlines):
            appendInlines(inlines, style: MarkdownRenderStyle())
            appendLineBreakIfNeeded()
        case let .bulletList(items):
            let limit = maxListItems.map { min($0, items.count) } ?? items.count
            for item in items.prefix(limit) {
                if isTruncated { break }
                appendText("- ", style: MarkdownRenderStyle())
                appendInlines(item.content, style: MarkdownRenderStyle())
                appendText("\n", style: MarkdownRenderStyle())
            }
            if items.count > limit {
                appendEllipsisLine()
            }
        case let .orderedList(items):
            let limit = maxListItems.map { min($0, items.count) } ?? items.count
            for (index, item) in items.prefix(limit).enumerated() {
                if isTruncated { break }
                let ordinal = item.ordinal ?? (index + 1)
                appendText("\(ordinal). ", style: MarkdownRenderStyle())
                appendInlines(item.content, style: MarkdownRenderStyle())
                appendText("\n", style: MarkdownRenderStyle())
            }
            if items.count > limit {
                appendEllipsisLine()
            }
        case let .blockquote(inlines):
            appendText("> ", style: MarkdownRenderStyle())
            var quoteStyle = MarkdownRenderStyle()
            quoteStyle.isItalic = true
            appendInlines(inlines, style: quoteStyle)
            appendLineBreakIfNeeded()
        case .horizontalRule:
            appendText("----", style: MarkdownRenderStyle())
            appendLineBreakIfNeeded()
        case let .table(table):
            appendTable(table)
        case let .callout(type, content):
            var labelStyle = MarkdownRenderStyle()
            labelStyle.isBold = true
            appendText("[\(type.rawValue.uppercased())] ", style: labelStyle)
            var calloutStyle = MarkdownRenderStyle()
            calloutStyle.isHighlight = true
            appendInlines(content, style: calloutStyle)
            appendLineBreakIfNeeded()
        }
    }

    private mutating func appendTable(_ table: MarkdownTable) {
        let rowLimit = maxTableRows.map { min($0, table.rows.count) } ?? table.rows.count
        let columnCount = max(table.headers.count, table.rows.map(\.count).max() ?? 0)
        appendTableRow(table.headers, isHeader: true)
        appendTableSeparator(columnCount: max(columnCount, 1))
        for row in table.rows.prefix(rowLimit) {
            if isTruncated { break }
            appendTableRow(row, isHeader: false)
        }
        if table.rows.count > rowLimit {
            appendEllipsisLine()
        }
    }

    private mutating func appendTableRow(_ row: [[MarkdownInline]], isHeader: Bool) {
        let style: MarkdownRenderStyle = {
            var style = MarkdownRenderStyle()
            style.isBold = isHeader
            return style
        }()
        appendText("| ", style: MarkdownRenderStyle())
        for (index, cell) in row.enumerated() {
            if isTruncated { break }
            appendInlines(cell, style: style)
            if index < row.count - 1 {
                appendText(" | ", style: MarkdownRenderStyle())
            }
        }
        appendText(" |", style: MarkdownRenderStyle())
        appendText("\n", style: MarkdownRenderStyle())
    }

    private mutating func appendTableSeparator(columnCount: Int) {
        guard columnCount > 0 else { return }
        appendText("|", style: MarkdownRenderStyle())
        for index in 0..<columnCount {
            appendText("---", style: MarkdownRenderStyle())
            appendText(index == columnCount - 1 ? "|" : "|", style: MarkdownRenderStyle())
        }
        appendText("\n", style: MarkdownRenderStyle())
    }

    private mutating func appendInlines(_ inlines: [MarkdownInline], style: MarkdownRenderStyle) {
        for inline in inlines {
            if isTruncated { break }
            appendInline(inline, style: style)
        }
    }

    private mutating func appendInline(_ inline: MarkdownInline, style: MarkdownRenderStyle) {
        switch inline {
        case let .text(text):
            appendText(text, style: style)
        case let .bold(inlines):
            var updated = style
            updated.isBold = true
            appendInlines(inlines, style: updated)
        case let .italic(inlines):
            var updated = style
            updated.isItalic = true
            appendInlines(inlines, style: updated)
        case let .strikethrough(inlines):
            var updated = style
            updated.isStrikethrough = true
            appendInlines(inlines, style: updated)
        case let .highlight(inlines):
            var updated = style
            updated.isHighlight = true
            appendInlines(inlines, style: updated)
        case let .code(text):
            var updated = style
            updated.isCode = true
            appendText(text, style: updated)
        case let .link(text: linkText, url: urlString):
            var updated = style
            updated.link = urlString
            appendInlines(linkText, style: updated)
        case let .mention(value):
            var updated = style
            updated.role = .mention
            appendText("@\(value)", style: updated)
        case let .tag(value):
            var updated = style
            updated.role = .tag
            appendText("#\(value)", style: updated)
        case let .autolink(link):
            var updated = style
            updated.link = link.urlValue?.absoluteString
            appendText(link.value, style: updated)
        }
    }

    private mutating func appendLineBreakIfNeeded() {
        guard let last = runs.last else { return }
        guard !last.text.hasSuffix("\n") else { return }
        appendText("\n", style: MarkdownRenderStyle())
    }

    private mutating func appendEllipsisLine() {
        guard !isTruncated else { return }
        appendText("...", style: MarkdownRenderStyle())
        appendText("\n", style: MarkdownRenderStyle())
    }

    @discardableResult
    private mutating func appendText(_ text: String, style: MarkdownRenderStyle) -> Bool {
        guard !text.isEmpty, !isTruncated else { return false }

        if let maxCharacters {
            let remaining = maxCharacters - characterCount
            if remaining <= 0 {
                isTruncated = true
                return false
            }
            if text.count > remaining {
                let truncatedText = truncate(text, remaining: remaining)
                appendRun(truncatedText, style: style)
                characterCount += truncatedText.count
                isTruncated = true
                return false
            }
        }

        appendRun(text, style: style)
        characterCount += text.count
        return true
    }

    private mutating func appendRun(_ text: String, style: MarkdownRenderStyle) {
        let run = MarkdownRenderRun(text: text, style: style)
        if let last = runs.last, last.canMerge(with: run) {
            runs[runs.count - 1] = last.merged(with: run)
        } else {
            runs.append(run)
        }
    }

    private func truncate(_ text: String, remaining: Int) -> String {
        guard remaining > 0 else { return "" }
        if remaining <= 3 {
            return String(text.prefix(remaining))
        }
        let prefix = text.prefix(remaining - 3)
        return String(prefix) + "..."
    }
}

private extension MarkdownRenderRun {
    var styleFlags: Int {
        var flags = 0
        if isBold { flags |= 1 }
        if isItalic { flags |= 2 }
        if isStrikethrough { flags |= 4 }
        if isHighlight { flags |= 8 }
        if isCode { flags |= 16 }
        return flags
    }

    init(text: String, style: MarkdownRenderStyle) {
        self.text = text
        isBold = style.isBold
        isItalic = style.isItalic
        isStrikethrough = style.isStrikethrough
        isHighlight = style.isHighlight
        isCode = style.isCode
        link = style.link
        role = style.role
    }

    func canMerge(with other: MarkdownRenderRun) -> Bool {
        isBold == other.isBold &&
            isItalic == other.isItalic &&
            isStrikethrough == other.isStrikethrough &&
            isHighlight == other.isHighlight &&
            isCode == other.isCode &&
            link == other.link &&
            role == other.role
    }

    func merged(with other: MarkdownRenderRun) -> MarkdownRenderRun {
        MarkdownRenderRun(
            text: text + other.text,
            isBold: isBold,
            isItalic: isItalic,
            isStrikethrough: isStrikethrough,
            isHighlight: isHighlight,
            isCode: isCode,
            link: link,
            role: role
        )
    }
}

struct PushGoMarkdownParser {
    func parse(_ text: String) -> PushGoMarkdownDocument {
        var blocks: [MarkdownBlock] = []
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var index = 0

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                index += 1
                continue
            }

            if isHorizontalRule(trimmed) {
                blocks.append(.horizontalRule)
                index += 1
                continue
            }

            if let heading = parseHeading(line) {
                blocks.append(heading)
                index += 1
                continue
            }

            if let callout = parseCallout(from: lines, startIndex: &index) {
                blocks.append(callout)
                continue
            }

            if let tableResult = parseTable(from: lines, startIndex: &index) {
                blocks.append(.table(tableResult))
                continue
            }

            if let list = parseList(from: lines, startIndex: &index) {
                blocks.append(list)
                continue
            }

            if let quote = parseBlockquote(from: lines, startIndex: &index) {
                blocks.append(quote)
                continue
            }

            if let paragraph = parseParagraph(from: lines, startIndex: &index) {
                blocks.append(paragraph)
                continue
            }

            index += 1
        }

        return PushGoMarkdownDocument(blocks: blocks)
    }

    private func parseHeading(_ line: String) -> MarkdownBlock? {
        let match = MarkdownRegex.heading.firstMatch(in: line, options: [], range: line.nsRange)
        guard let match,
              let levelRange = Range(match.range(at: 1), in: line),
              let textRange = Range(match.range(at: 2), in: line)
        else {
            return nil
        }
        let level = min(max(line[levelRange].count, 1), 6)
        let content = String(line[textRange]).trimmingCharacters(in: .whitespaces)
        return .heading(level: level, content: parseInlines(content))
    }

    private func parseCallout(from lines: [String], startIndex: inout Int) -> MarkdownBlock? {
        guard startIndex < lines.count else { return nil }
        let line = lines[startIndex]
        guard let match = MarkdownRegex.callout.firstMatch(in: line, options: [], range: line.nsRange),
              let typeRange = Range(match.range(at: 1), in: line)
        else {
            return nil
        }

        let typeText = line[typeRange].lowercased()
        guard let type = MarkdownCalloutType(rawValue: typeText) else { return nil }
        let initialTextRange = Range(match.range(at: 2), in: line)
        var contentLines: [String] = []
        if let initialTextRange {
            contentLines.append(String(line[initialTextRange]).trimmingCharacters(in: .whitespaces))
        }

        startIndex += 1
        while startIndex < lines.count {
            let peek = lines[startIndex]
            if MarkdownRegex.callout.firstMatch(in: peek, options: [], range: peek.nsRange) != nil {
                break
            }
            if MarkdownRegex.calloutContinuation.firstMatch(in: peek, options: [], range: peek.nsRange) == nil {
                break
            }
            let cleaned = MarkdownRegex.leadingQuote.stringByReplacingMatches(
                in: peek,
                options: [],
                range: peek.nsRange,
                withTemplate: ""
            )
            contentLines.append(cleaned.trimmingCharacters(in: .whitespaces))
            startIndex += 1
        }

        let joined = contentLines.joined(separator: "\n")
        return .callout(type: type, content: parseInlines(joined))
    }

    private func parseTable(from lines: [String], startIndex: inout Int) -> MarkdownTable? {
        guard startIndex + 1 < lines.count else { return nil }
        let headerLine = lines[startIndex]
        let separatorLine = lines[startIndex + 1]

        guard MarkdownRegex.tableSeparator
            .firstMatch(in: separatorLine, options: [], range: separatorLine.nsRange) != nil
        else {
            return nil
        }

        guard headerLine.contains("|") else { return nil }

        let headers = parseTableRow(headerLine)
        guard headers.count >= 1 else { return nil }
        let columnLimit = min(max(headers.count, 1), 6)
        let parsedHeaders = Array(headers.prefix(columnLimit)).map { parseInlines($0) }

        var rows: [[[MarkdownInline]]] = []
        var current = startIndex + 2
        while current < lines.count {
            let rowLine = lines[current]
            let trimmed = rowLine.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || !rowLine.contains("|") || MarkdownRegex.heading.firstMatch(
                in: rowLine,
                options: [],
                range: rowLine.nsRange
            ) != nil {
                break
            }
            let cells = parseTableRow(rowLine)
            if cells.isEmpty { break }
            rows.append(Array(cells.prefix(columnLimit)).map { parseInlines($0) })
            current += 1
            if rows.count >= 30 { break }
        }

        startIndex = current
        return MarkdownTable(headers: parsedHeaders, rows: rows)
    }

    private func parseTableRow(_ line: String) -> [String] {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }

        let content: Substring = {
            var start = trimmed.startIndex
            var end = trimmed.endIndex
            if trimmed[start] == "|" {
                start = trimmed.index(after: start)
            }
            if start < end, trimmed[trimmed.index(before: end)] == "|" {
                end = trimmed.index(before: end)
            }
            return trimmed[start..<end]
        }()

        var cells: [String] = []
        var buffer = ""
        var bracketDepth = 0
        var parenDepth = 0
        var inCode = false
        var isEscaped = false

        for char in content {
            if isEscaped {
                buffer.append(char)
                isEscaped = false
                continue
            }

            if char == "\\" {
                isEscaped = true
                buffer.append(char)
                continue
            }

            if char == "`" {
                inCode.toggle()
                buffer.append(char)
                continue
            }

            if !inCode {
                if char == "[" {
                    bracketDepth += 1
                } else if char == "]" {
                    bracketDepth = max(0, bracketDepth - 1)
                } else if char == "(" {
                    parenDepth += 1
                } else if char == ")" {
                    parenDepth = max(0, parenDepth - 1)
                } else if char == "|" && bracketDepth == 0 && parenDepth == 0 {
                    cells.append(buffer.trimmingCharacters(in: .whitespaces))
                    buffer.removeAll(keepingCapacity: true)
                    continue
                }
            }

            buffer.append(char)
        }

        cells.append(buffer.trimmingCharacters(in: .whitespaces))
        return cells
    }

    private func parseList(from lines: [String], startIndex: inout Int) -> MarkdownBlock? {
        guard startIndex < lines.count else { return nil }
        let line = lines[startIndex]

        if MarkdownRegex.unorderedList.firstMatch(in: line, options: [], range: line.nsRange) != nil {
            var items: [MarkdownListItem] = []
            var current = startIndex
            while current < lines.count {
                let candidate = lines[current]
                guard let match = MarkdownRegex.unorderedList.firstMatch(
                    in: candidate,
                    options: [],
                    range: candidate.nsRange
                ),
                    let range = Range(match.range(at: 2), in: candidate)
                else {
                    break
                }
                let text = String(candidate[range]).trimmingCharacters(in: .whitespaces)
                items.append(MarkdownListItem(content: parseInlines(text)))
                current += 1
                if current < lines.count, lines[current].trimmingCharacters(in: .whitespaces).isEmpty {
                    break
                }
            }
            startIndex = current
            return .bulletList(items)
        }

        if MarkdownRegex.orderedList.firstMatch(in: line, options: [], range: line.nsRange) != nil {
            var items: [MarkdownListItem] = []
            var current = startIndex
            while current < lines.count {
                let candidate = lines[current]
                guard let match = MarkdownRegex.orderedList.firstMatch(
                    in: candidate,
                    options: [],
                    range: candidate.nsRange
                ),
                    let ordinalRange = Range(match.range(at: 1), in: candidate),
                    let range = Range(match.range(at: 2), in: candidate)
                else {
                    break
                }
                let text = String(candidate[range]).trimmingCharacters(in: .whitespaces)
                let ordinal = Int(candidate[ordinalRange])
                items.append(MarkdownListItem(content: parseInlines(text), ordinal: ordinal))
                current += 1
                if current < lines.count, lines[current].trimmingCharacters(in: .whitespaces).isEmpty {
                    break
                }
            }
            startIndex = current
            return .orderedList(items)
        }

        return nil
    }

    private func parseBlockquote(from lines: [String], startIndex: inout Int) -> MarkdownBlock? {
        guard startIndex < lines.count else { return nil }
        let line = lines[startIndex]
        guard MarkdownRegex.blockquote.firstMatch(in: line, options: [], range: line.nsRange) != nil else {
            return nil
        }
        var contentLines: [String] = []
        var current = startIndex
        while current < lines.count {
            let candidate = lines[current]
            guard MarkdownRegex.blockquote.firstMatch(in: candidate, options: [], range: candidate.nsRange) != nil
            else {
                break
            }
            let stripped = MarkdownRegex.leadingQuote.stringByReplacingMatches(
                in: candidate,
                options: [],
                range: candidate.nsRange,
                withTemplate: ""
            )
            contentLines.append(stripped.trimmingCharacters(in: .whitespaces))
            current += 1
        }
        startIndex = current
        let joined = contentLines.joined(separator: "\n")
        return .blockquote(parseInlines(joined))
    }

    private func parseParagraph(from lines: [String], startIndex: inout Int) -> MarkdownBlock? {
        guard startIndex < lines.count else { return nil }
        var contentLines: [String] = []
        var current = startIndex

        while current < lines.count {
            let candidate = lines[current]
            let trimmed = candidate.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || isBlockBoundary(candidate) {
                break
            }
            contentLines.append(candidate)
            current += 1
        }

        if contentLines.isEmpty {
            return nil
        }
        startIndex = current
        let joined = contentLines.joined(separator: "\n")
        return .paragraph(parseInlines(joined))
    }

    private func isBlockBoundary(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return true }
        if isHorizontalRule(trimmed) { return true }
        if MarkdownRegex.heading.firstMatch(in: line, options: [], range: line.nsRange) != nil { return true }
        if MarkdownRegex.callout.firstMatch(in: line, options: [], range: line.nsRange) != nil { return true }
        if MarkdownRegex.unorderedList.firstMatch(in: line, options: [], range: line.nsRange) != nil { return true }
        if MarkdownRegex.orderedList.firstMatch(in: line, options: [], range: line.nsRange) != nil { return true }
        if MarkdownRegex.blockquote.firstMatch(in: line, options: [], range: line.nsRange) != nil { return true }
        if line.contains("|"),
           MarkdownRegex.tableSeparator.firstMatch(in: line, options: [], range: line.nsRange) != nil { return true }
        return false
    }

    private func isHorizontalRule(_ line: String) -> Bool {
        MarkdownRegex.horizontalRule.firstMatch(in: line, options: [], range: line.nsRange) != nil
    }

    private func parseInlines(_ text: String) -> [MarkdownInline] {
        var result: [MarkdownInline] = []
        var index = text.startIndex
        var buffer = ""

        func flushBuffer() {
            if !buffer.isEmpty {
                result.append(.text(buffer))
                buffer.removeAll()
            }
        }

        while index < text.endIndex {
            if text[index] == "\\" {
                let nextIndex = text.index(after: index)
                if nextIndex < text.endIndex {
                    buffer.append(text[nextIndex])
                    index = text.index(after: nextIndex)
                    continue
                } else {
                    buffer.append(text[index])
                    index = nextIndex
                    continue
                }
            }

            if text.hasPrefix("**", from: index) {
                if let closing = text.range(of: "**", range: text.index(index, offsetBy: 2) ..< text.endIndex) {
                    flushBuffer()
                    let inner = String(text[text.index(index, offsetBy: 2) ..< closing.lowerBound])
                    result.append(.bold(parseInlines(inner)))
                    index = closing.upperBound
                    continue
                }
            }

            if text.hasPrefix("~~", from: index) {
                if let closing = text.range(of: "~~", range: text.index(index, offsetBy: 2) ..< text.endIndex) {
                    flushBuffer()
                    let inner = String(text[text.index(index, offsetBy: 2) ..< closing.lowerBound])
                    result.append(.strikethrough(parseInlines(inner)))
                    index = closing.upperBound
                    continue
                }
            }

            if text.hasPrefix("==", from: index) {
                if let closing = text.range(of: "==", range: text.index(index, offsetBy: 2) ..< text.endIndex) {
                    flushBuffer()
                    let inner = String(text[text.index(index, offsetBy: 2) ..< closing.lowerBound])
                    result.append(.highlight(parseInlines(inner)))
                    index = closing.upperBound
                    continue
                }
            }

            if text[index] == "*" {
                let next = text.index(after: index)
                if next < text.endIndex,
                   let closing = text.range(of: "*", range: next ..< text.endIndex)
                {
                    flushBuffer()
                    let inner = String(text[next ..< closing.lowerBound])
                    result.append(.italic(parseInlines(inner)))
                    index = closing.upperBound
                    continue
                }
            }

            if text[index] == "`" {
                let next = text.index(after: index)
                if let closing = text.range(of: "`", range: next ..< text.endIndex) {
                    flushBuffer()
                    let inner = String(text[next ..< closing.lowerBound])
                    result.append(.code(inner))
                    index = closing.upperBound
                    continue
                }
            }

            if text[index] == "[",
               let linkMatch = parseLink(in: text, from: index)
            {
                let urlText = linkMatch.destination
                if urlText.lowercased().hasPrefix("http://") || urlText.lowercased().hasPrefix("https://") {
                    flushBuffer()
                    result.append(.link(text: parseInlines(linkMatch.label), url: urlText))
                    index = linkMatch.nextIndex
                    continue
                }
            }

            buffer.append(text[index])
            index = text.index(after: index)
        }

        flushBuffer()
        return tokenizeSpecials(inlines: result)
    }

    private func parseLink(in text: String, from start: String.Index) -> (label: String, destination: String, nextIndex: String.Index)? {
        guard text[start] == "[" else { return nil }

        let labelStart = text.index(after: start)
        var index = labelStart
        var bracketDepth = 1
        var isEscaped = false

        while index < text.endIndex {
            let char = text[index]
            if isEscaped {
                isEscaped = false
            } else if char == "\\" {
                isEscaped = true
            } else if char == "[" {
                bracketDepth += 1
            } else if char == "]" {
                bracketDepth -= 1
                if bracketDepth == 0 {
                    break
                }
            }
            index = text.index(after: index)
        }

        guard index < text.endIndex else { return nil }
        let closingBracket = index
        let openParen = text.index(after: closingBracket)
        guard openParen < text.endIndex, text[openParen] == "(" else { return nil }

        let destinationStart = text.index(after: openParen)
        index = destinationStart
        var parenDepth = 1
        isEscaped = false

        while index < text.endIndex {
            let char = text[index]
            if isEscaped {
                isEscaped = false
            } else if char == "\\" {
                isEscaped = true
            } else if char == "(" {
                parenDepth += 1
            } else if char == ")" {
                parenDepth -= 1
                if parenDepth == 0 {
                    let label = String(text[labelStart..<closingBracket])
                    let destination = String(text[destinationStart..<index]).trimmingCharacters(in: .whitespacesAndNewlines)
                    return (label: label, destination: destination, nextIndex: text.index(after: index))
                }
            }
            index = text.index(after: index)
        }

        return nil
    }

    private func tokenizeSpecials(inlines: [MarkdownInline]) -> [MarkdownInline] {
        var pendingMatches: [(range: NSRange, inline: MarkdownInline)] = []
        let flattened = inlines.flatMap { inline -> [MarkdownInline] in
            guard case let .text(text) = inline else { return [inline] }

            let nsText = text as NSString
            let fullRange = NSRange(location: 0, length: nsText.length)

            for match in MarkdownRegex.url.matches(in: text, options: [], range: fullRange) {
                if let range1 = Range(match.range(at: 1), in: text) {
                    let value = String(text[range1])
                    pendingMatches.append((match.range(at: 1), .autolink(Autolink(kind: .url, value: value))))
                }
            }

            for match in MarkdownRegex.email.matches(in: text, options: [], range: fullRange) {
                if let range1 = Range(match.range(at: 1), in: text) {
                    let value = String(text[range1])
                    pendingMatches.append((match.range(at: 1), .autolink(Autolink(kind: .email, value: value))))
                }
            }

            for match in MarkdownRegex.phone.matches(in: text, options: [], range: fullRange) {
                if let range1 = Range(match.range(at: 1), in: text) {
                    let value = String(text[range1])
                    pendingMatches.append((match.range(at: 1), .autolink(Autolink(kind: .phone, value: value))))
                }
            }

            for match in MarkdownRegex.mention.matches(in: text, options: [], range: fullRange) {
                if let range1 = Range(match.range(at: 1), in: text) {
                    let value = String(text[range1])
                    pendingMatches.append((match.range(at: 0), .mention(value)))
                }
            }

            for match in MarkdownRegex.tag.matches(in: text, options: [], range: fullRange) {
                if let range1 = Range(match.range(at: 1), in: text) {
                    let value = String(text[range1])
                    pendingMatches.append((match.range(at: 0), .tag(value)))
                }
            }

            pendingMatches.sort {
                if $0.range.location == $1.range.location {
                    return $0.range.length > $1.range.length
                }
                return $0.range.location < $1.range.location
            }
            var occupiedRanges = [NSRange]()
            var filtered: [(NSRange, MarkdownInline)] = []
            for candidate in pendingMatches {
                if occupiedRanges.contains(where: { $0.intersection(candidate.range) != nil }) { continue }
                occupiedRanges.append(candidate.range)
                filtered.append((candidate.range, candidate.inline))
            }
            filtered.sort { $0.0.location < $1.0.location }

            var rebuilt: [MarkdownInline] = []
            var cursor = 0
            for (range, inline) in filtered {
                if range.location > cursor {
                    let nsRange = NSRange(location: cursor, length: range.location - cursor)
                    let chunk = nsText.substring(with: nsRange)
                    if !chunk.isEmpty { rebuilt.append(.text(chunk)) }
                }
                rebuilt.append(inline)
                cursor = range.location + range.length
            }
            if cursor < nsText.length {
                let nsRange = NSRange(location: cursor, length: nsText.length - cursor)
                let chunk = nsText.substring(with: nsRange)
                if !chunk.isEmpty { rebuilt.append(.text(chunk)) }
            }
            pendingMatches.removeAll(keepingCapacity: true)
            return rebuilt
        }
        return flattened
    }
}

private enum MarkdownRegex {
    static let noMatchRegex = makeNoMatchRegex()

    static let heading = make(#"^\s{0,3}(#{1,6})\s+(.*)$"#, options: [])
    static let callout = make(#"^\s{0,3}>\s*\[\!(info|success|warning|error)\]\s*(.*)$"#, options: [.caseInsensitive])
    static let calloutContinuation = make(#"^\s{0,3}>\s+(.+)$"#, options: [])
    static let blockquote = make(#"^\s{0,3}>\s?.+$"#, options: [])
    static let unorderedList = make(#"^\s{0,3}([-*])\s+(.+)$"#, options: [])
    static let orderedList = make(#"^\s{0,3}(\d+)\.\s+(.+)$"#, options: [])
    static let horizontalRule = make(#"^\s{0,3}(([-*_])\s*){3,}$"#, options: [])
    static let tableSeparator = make(#"^\s*\|?\s*-+\s*(\|\s*-+\s*)+\|?\s*$"#, options: [])
    static let leadingQuote = make(#"^\s{0,3}>\s?"#, options: [])

    static let url = make(#"(?i)\b(https?://[^\s<>()]+)"#, options: [])
    static let email = make(#"(?i)\b([A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,})"#, options: [])
    static let phone = make(#"(?i)(?<!\w)(\+?[0-9][0-9\-\s]{6,}[0-9])(?!\w)"#, options: [])
    static let mention = make(#"(?<!\w)@([A-Za-z0-9_]{1,30})"#, options: [])
    static let tag = make(#"(?<!\w)#([A-Za-z0-9_\p{Han}]{1,30})"#, options: [])

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
        fatalError("Failed to compile internal fallback regex patterns for markdown parser.")
    }
}

private extension String {
    var nsRange: NSRange { NSRange(location: 0, length: utf16.count) }

    func hasPrefix(_ prefix: String, from index: Index) -> Bool {
        guard let end = self.index(index, offsetBy: prefix.count, limitedBy: endIndex) else {
            return false
        }
        return self[index ..< end] == prefix
    }
}
