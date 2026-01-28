import Foundation
import SwiftUI

struct MarkdownRenderer: View {
    let text: String
    var maxNewlines: Int? = nil
    var font: Font = .body
    var foreground: Color = .primary

    private var displayText: String {
        guard let max = maxNewlines else { return text }
        return limitText(text, toFirstNewlines: max)
    }

    var body: some View {
        let document = PushGoMarkdownParser().parse(displayText)
        Group {
            if document.blocks.isEmpty {
                Text(displayText)
            } else {
                PushGoMarkdownView(document: document)
            }
        }
        .font(font)
        .foregroundColor(foreground)
        .multilineTextAlignment(.leading)
        .lineLimit(nil)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private func limitText(_ text: String, toFirstNewlines max: Int) -> String {
    guard max > 0 else { return text }
    var newlineCount = 0
    for (idx, char) in text.enumerated() {
        if char == "\n" {
            newlineCount += 1
            if newlineCount >= max {
                let cutoff = text.index(text.startIndex, offsetBy: idx)
                return String(text[text.startIndex ..< cutoff])
            }
        }
    }
    return text
}

struct PushGoMarkdownView: View {
    let document: PushGoMarkdownDocument
    private(set) var allowsMultilineTables: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(document.blocks.enumerated()), id: \.0) { index, block in
                blockView(for: block, at: index)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func blockView(for block: MarkdownBlock, at _: Int) -> some View {
        switch block {
        case let .heading(level, content):
            inlineText(content)
                .font(headingFont(for: level).weight(.semibold))
        case let .paragraph(inlines):
            inlineText(inlines)
        case let .bulletList(items):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.0) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•")
                            .foregroundColor(.secondary)
                        inlineText(item.content)
                    }
                }
            }
        case let .orderedList(items):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.0) { index, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(index + 1).")
                            .foregroundColor(.secondary)
                        inlineText(item.content)
                    }
                }
            }
        case let .blockquote(inlines):
            blockquoteView(inlines: inlines)
        case .horizontalRule:
            Divider()
        case let .table(table):
            MarkdownTableView(table: table)
        case let .callout(type, content):
            calloutView(type: type, content: content)
        }
    }

    private func inlineText(_ inlines: [MarkdownInline]) -> some View {
        Text(attributedString(for: inlines))
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func blockquoteView(inlines: [MarkdownInline]) -> some View {
        MarkdownBlockquoteView(text: attributedString(for: inlines))
    }

    private func headingFont(for level: Int) -> Font {
        switch level {
        case 1:
            .title2
        case 2:
            .title3
        case 3:
            .headline
        default:
            .subheadline
        }
    }

    private func calloutView(type: MarkdownCalloutType, content: [MarkdownInline]) -> some View {
        MarkdownCalloutView(
            type: type,
            icon: MarkdownTheme.calloutIcon(for: type),
            content: attributedString(for: content),
            colors: MarkdownTheme.calloutColors(for: type)
        )
    }
}

private enum MarkdownTheme {
    static let surface = Color.primary.opacity(0.03)
    static let divider = Color.primary.opacity(0.08)
    static let blockquoteBar = Color.primary.opacity(0.14)
    static let blockquoteSurface = Color.primary.opacity(0.02)

    static func calloutColors(for type: MarkdownCalloutType) -> (accent: Color, background: Color) {
        let accent: Color = {
            switch type {
            case .info:
                return .accentColor
            case .success:
                return .green
            case .warning:
                return .orange
            case .error:
                return .red
            }
        }()
        return (accent, accent.opacity(0.12))
    }

    static func calloutIcon(for type: MarkdownCalloutType) -> String {
        switch type {
        case .info:
            return "info.circle.fill"
        case .success:
            return "checkmark.circle.fill"
        case .warning:
            return "exclamationmark.triangle.fill"
        case .error:
            return "xmark.octagon.fill"
        }
    }
}

private struct MarkdownBlockquoteView: View {
    let text: AttributedString

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(MarkdownTheme.blockquoteBar)
                .frame(width: 4)
            Text(text)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(MarkdownTheme.blockquoteSurface)
        )
    }
}

private struct MarkdownCalloutView: View {
    let type: MarkdownCalloutType
    let icon: String
    let content: AttributedString
    let colors: (accent: Color, background: Color)

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.headline)
                .foregroundColor(colors.accent)
                .padding(.top, 1)

            Text(content)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(colors.background)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(MarkdownTheme.divider, lineWidth: 0.6)
        )
    }
}

private struct MarkdownTableView: View {
    let table: MarkdownTable

    private var columnCount: Int {
        let longestRow = table.rows.map(\.count).max() ?? 0
        return max(max(table.headers.count, longestRow), 1)
    }

    private var columns: [GridItem] {
        Array(
            repeating: GridItem(.flexible(minimum: 60), spacing: 12, alignment: .leading),
            count: columnCount
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                ForEach(0 ..< columnCount, id: \.self) { index in
                    if index < table.headers.count {
                        cellText(table.headers[index])
                            .font(.subheadline.weight(.semibold))
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Text("")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }

            Divider()

            LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                ForEach(Array(table.rows.enumerated()), id: \.0) { _, row in
                    ForEach(0 ..< columnCount, id: \.self) { index in
                        if index < row.count {
                            cellText(row[index])
                                .multilineTextAlignment(.leading)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            Text("")
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(MarkdownTheme.surface)
        )
    }

    @ViewBuilder
    private func cellText(_ inlines: [MarkdownInline]) -> some View {
        Text(attributedString(for: inlines))
    }
}

private func attributedString(for inlines: [MarkdownInline]) -> AttributedString {
    inlines.reduce(into: AttributedString()) { result, inline in
        result += attributedString(for: inline)
    }
}

private func attributedString(for inline: MarkdownInline) -> AttributedString {
    switch inline {
    case let .text(text):
        return AttributedString(text)
    case let .bold(inlines):
        var string = attributedString(for: inlines)
        string.inlinePresentationIntent = .stronglyEmphasized
        return string
    case let .italic(inlines):
        var string = attributedString(for: inlines)
        string.inlinePresentationIntent = .emphasized
        return string
    case let .strikethrough(inlines):
        var string = attributedString(for: inlines)
        string.strikethroughStyle = .single
        return string
    case let .highlight(inlines):
        var string = attributedString(for: inlines)
        string.backgroundColor = Color.yellow.opacity(0.25)
        return string
    case let .code(text):
        var string = AttributedString(text)
        string.font = .system(.body, design: .monospaced)
        string.backgroundColor = Color.primary.opacity(0.08)
        return string
    case let .link(text: linkText, url: urlString):
        var string = attributedString(for: linkText)
        if let url = URL(string: urlString) {
            string.link = url
        }
        string.foregroundColor = .accentColor
        return string
    case let .mention(value):
        var string = AttributedString("@\(value)")
        string.foregroundColor = .accentColor
        return string
    case let .tag(value):
        var string = AttributedString("#\(value)")
        string.foregroundColor = .secondary
        return string
    case let .autolink(link):
        var string = AttributedString(link.value)
        if let url = link.urlValue {
            string.link = url
        }
        string.foregroundColor = .accentColor
        return string
    }
}

extension MarkdownRenderPayload {
    func attributedString(textStyle: Font.TextStyle) -> AttributedString {
        let highlightColor = Color.accentColor.opacity(0.14)
        let codeBackground = Color.primary.opacity(0.06)
        let tagBackground = Color.secondary.opacity(0.12)

        return runs.reduce(into: AttributedString()) { result, run in
            var chunk = AttributedString(run.text)
            var intents: InlinePresentationIntent = []
            if run.isBold {
                intents.insert(.stronglyEmphasized)
            }
            if run.isItalic {
                intents.insert(.emphasized)
            }
            if run.isCode {
                intents.insert(.code)
            }
            if !intents.isEmpty {
                chunk.inlinePresentationIntent = intents
            }
            if run.isStrikethrough {
                chunk.strikethroughStyle = .single
            }
            if run.isHighlight {
                chunk.backgroundColor = highlightColor
            }
            if run.isCode {
                chunk.font = .system(textStyle, design: .monospaced)
                chunk.backgroundColor = codeBackground
                chunk.foregroundColor = .primary
            }
            if let link = run.link, let url = URL(string: link) {
                chunk.link = url
                chunk.foregroundColor = .accentColor
                chunk.underlineStyle = .single
            } else if run.role == .mention {
                chunk.foregroundColor = .accentColor
            } else if run.role == .tag {
                chunk.foregroundColor = .secondary
                chunk.backgroundColor = tagBackground
            }
            if run.isStrikethrough, run.link == nil, run.role == nil {
                chunk.foregroundColor = .secondary
            }
            result += chunk
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
            .multilineTextAlignment(.leading)
            .lineLimit(nil)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
