import Foundation
import SwiftUI

#if canImport(Textual)
import Textual
#endif

struct MarkdownRenderer: View {
    private static let textualScale: CGFloat = 0.92
    let text: String
    var maxNewlines: Int? = nil
    var font: Font = .body
    var foreground: Color = .primary

    private var displayText: String {
        guard let max = maxNewlines else { return text }
        return limitText(text, toFirstNewlines: max)
    }

    private var prefersStructuredText: Bool {
        prefersStructuredRendering(displayText)
    }

    private var normalizedText: String {
        normalizeMarkdown(displayText)
    }

    var body: some View {
        #if canImport(Textual)
        Group {
            if prefersStructuredText {
                StructuredText(markdown: normalizedText)
                    .textual.structuredTextStyle(.gitHub)
                    .textual.tableCellStyle(PushGoRefinedTableCellStyle())
                    .textual.tableStyle(PushGoRefinedTableStyle())
            } else {
                InlineText(markdown: normalizedText)
            }
        }
        .textual.fontScale(Self.textualScale)
        .textual.inlineStyle(.gitHub)
        .environment(\.openURL, OpenURLAction { incoming in
            guard let safeURL = URLSanitizer.sanitizeExternalOpenURL(incoming) else {
                return .discarded
            }
            return .systemAction(safeURL)
        })
        .font(font)
        .foregroundStyle(foreground)
        .lineLimit(nil)
        .fixedSize(horizontal: false, vertical: true)
        #else
        Text(displayText)
            .font(font)
            .foregroundStyle(foreground)
            .lineLimit(nil)
            .fixedSize(horizontal: false, vertical: true)
        #endif
    }
}

#if canImport(Textual)
private struct PushGoRefinedTableCellStyle: StructuredText.TableCellStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .fontWeight(configuration.row == 0 ? .semibold : .regular)
            .padding(.vertical, 7)
            .padding(.horizontal, 12)
            .textual.lineSpacing(.fontScaled(0.25))
    }
}
#endif

#if canImport(Textual)
private struct PushGoRefinedTableStyle: StructuredText.TableStyle {
    private static let borderWidth: CGFloat = 1
    private static let cornerRadius: CGFloat = 10
    private static let overflowRelativeWidth: CGFloat = 1.8

    private var borderColor: Color {
        Color.appBorderStrong
    }

    private var dividerColor: Color {
        Color.appBorderSubtle
    }

    private var containerFillColor: Color {
        Color.appSurfaceSunken
    }

    private var headerFillColor: Color {
        Color.appSurfaceRaised
    }

    private var stripeFillColor: Color {
        Color.appSelectionFillMuted
    }

    func makeBody(configuration: Configuration) -> some View {
        Overflow { state in
            let maxWidth = state.containerWidth.map { $0 * Self.overflowRelativeWidth }

            configuration.label
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: maxWidth, alignment: .leading)
                .textual.tableBackground { layout in
                    Canvas { context, _ in
                        guard layout.numberOfRows > 0 else { return }

                        let headerBounds = layout.rowBounds(0).integral
                        if !headerBounds.isNull {
                            context.fill(Path(headerBounds), with: .color(headerFillColor))
                        }

                        for row in layout.rowIndices.dropFirst().filter({ $0.isMultiple(of: 2) }) {
                            let rowBounds = layout.rowBounds(row).integral
                            if !rowBounds.isNull {
                                context.fill(Path(rowBounds), with: .color(stripeFillColor))
                            }
                        }
                    }
                }
                .textual.tableOverlay { layout in
                    Canvas { context, _ in
                        for divider in layout.dividers() {
                            context.fill(
                                Path(divider),
                                with: .color(dividerColor)
                            )
                        }
                    }
                }
                .padding(Self.borderWidth)
                .background(
                    RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                        .fill(containerFillColor)
                )
                .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                        .stroke(borderColor, lineWidth: Self.borderWidth)
                }
        }
        .textual.tableCellSpacing(horizontal: Self.borderWidth, vertical: Self.borderWidth)
        .textual.blockSpacing(.fontScaled(top: 1.4, bottom: 1.6))
    }
}
#endif

private func normalizeMarkdown(_ markdown: String) -> String {
    // Foundation's markdown parser does not render [![...]](...) as an image.
    // Keep this narrowly scoped: unwrap link-wrapped images and delegate all
    // other markdown semantics to Textual/Foundation.
    let pattern = #"\[(!\[[^\]]*?\]\((?:\\.|[^\\)])*?\))\]\((?:\\.|[^\\)])*?\)"#
    guard let regex = try? NSRegularExpression(pattern: pattern) else {
        return markdown
    }
    let range = NSRange(markdown.startIndex ..< markdown.endIndex, in: markdown)
    return regex.stringByReplacingMatches(in: markdown, range: range, withTemplate: "$1")
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

private func prefersStructuredRendering(_ text: String) -> Bool {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return false }
    if trimmed.contains("\n") { return true }
    if trimmed.contains("![") { return true }
    if trimmed.contains("```") { return true }
    if trimmed.hasPrefix("#") || trimmed.hasPrefix(">") { return true }
    if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") { return true }
    if let first = trimmed.first, first.isNumber, trimmed.contains(". ") { return true }
    if trimmed.contains("|") { return true }
    return false
}
