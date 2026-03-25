import Foundation
import SwiftUI

#if canImport(Textual)
import Textual
#else
#error("Textual is required for MarkdownRenderer.")
#endif

struct MarkdownRenderer: View {
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

    var body: some View {
        Group {
            if prefersStructuredText {
                StructuredText(markdown: displayText)
            } else {
                InlineText(markdown: displayText)
            }
        }
            .environment(\.openURL, OpenURLAction { incoming in
                guard let safeURL = URLSanitizer.sanitizeExternalOpenURL(incoming) else {
                    return .discarded
                }
                return .systemAction(safeURL)
            })
            .font(font)
            .foregroundColor(foreground)
            .lineLimit(nil)
            .fixedSize(horizontal: false, vertical: true)
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

private func prefersStructuredRendering(_ text: String) -> Bool {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return false }
    if trimmed.contains("\n") { return true }
    if trimmed.contains("```") { return true }
    if trimmed.hasPrefix("#") || trimmed.hasPrefix(">") { return true }
    if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") { return true }
    if let first = trimmed.first, first.isNumber, trimmed.contains(". ") { return true }
    if trimmed.contains("|") { return true }
    return false
}
