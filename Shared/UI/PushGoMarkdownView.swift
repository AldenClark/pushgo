import Foundation
import SwiftUI

#if canImport(Textual) && !os(watchOS)
import Textual
#endif

struct MarkdownRenderer: View {
    private static let textualScale: CGFloat = 0.92
    let text: String
    var maxNewlines: Int? = nil
    var font: Font = .body
    var foreground: Color = .primary
    var attachmentWidthHint: CGFloat? = nil
#if canImport(Textual) && !os(watchOS)
    @State private var previewingImage: MarkdownImagePreviewItem?
#endif

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
        #if canImport(Textual) && !os(watchOS)
        markdownContent
            .pushgoImagePreviewOverlay(
                previewItem: $previewingImage,
                imageURL: \.url
            )
        #else
        Text(displayText)
            .font(font)
            .foregroundStyle(foreground)
            .lineLimit(nil)
            .fixedSize(horizontal: false, vertical: true)
        #endif
    }
}

#if canImport(Textual) && !os(watchOS)
extension MarkdownRenderer {
    private var markdownContent: some View {
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
        .transaction { transaction in
            transaction.animation = nil
        }
        .textual.imageAttachmentLoader(
            .adaptiveImage(
                backend: .sdWebImage,
                sizeProvider: markdownImageSizeProvider,
                syncSizeProvider: markdownImageSyncSizeProvider
            )
        )
        .textual.imageAttachmentURLResolver(
            .init { url in
                if let sourceURL = await SharedImageCache.localSourceURL(
                    for: url,
                    rendition: .original,
                    maxBytes: AppConstants.maxMessageImageBytes,
                    timeout: 10
                ) {
                    return sourceURL
                }
                return url
            }
        )
        .textual.imageAttachmentTapAction(
            .init { tappedURL in
                previewingImage = MarkdownImagePreviewItem(url: tappedURL)
            }
        )
        .textual.imageAttachmentWidthHint(attachmentWidthHint)
        .attachmentRenderingMode(.interactive)
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
    }
}

let markdownImageSizeProvider: URLImageAttachmentSizeProvider = { url in
    let metadata = if let cached = await SharedImageCache.metadata(for: url) {
        cached
    } else {
        await SharedImageCache.ensureMetadataFromCache(for: url)
    }
    if let metadata,
       metadata.pixelWidth > 0,
       metadata.pixelHeight > 0
    {
        return CGSize(width: metadata.pixelWidth, height: metadata.pixelHeight)
    }
    return nil
}

let markdownImageSyncSizeProvider: URLImageAttachmentSyncSizeProvider = { url in
    guard let metadata = SharedImageCache.metadataSnapshot(for: url),
          metadata.pixelWidth > 0,
          metadata.pixelHeight > 0
    else {
        return nil
    }
    return CGSize(width: metadata.pixelWidth, height: metadata.pixelHeight)
}


enum MarkdownImageURLExtractor {
    static func extractURLs(from markdown: String) -> [URL] {
        guard !markdown.isEmpty else { return [] }
        let nsRange = NSRange(markdown.startIndex..<markdown.endIndex, in: markdown)
        var candidates: [String] = []

        let patterns = [
            "!\\[[^\\]]*\\]\\(([^)]+)\\)",
            "<img[^>]+src\\s*=\\s*['\\\"]([^'\\\"]+)['\\\"][^>]*>",
            "\\[[^\\]]+\\]:\\s*(https?://\\S+)",
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
                continue
            }
            for match in regex.matches(in: markdown, options: [], range: nsRange) {
                guard match.numberOfRanges >= 2 else { continue }
                guard let swiftRange = Range(match.range(at: 1), in: markdown) else { continue }
                candidates.append(String(markdown[swiftRange]))
            }
        }

        if let bareURLRegex = try? NSRegularExpression(
            pattern: "(https?://\\S+\\.(?:png|jpe?g|gif|webp|avif|heic|heif|bmp)(?:\\?\\S*)?)",
            options: [.caseInsensitive]
        ) {
            for match in bareURLRegex.matches(in: markdown, options: [], range: nsRange) {
                guard let range = Range(match.range(at: 1), in: markdown) else { continue }
                candidates.append(String(markdown[range]))
            }
        }

        var seen = Set<String>()
        var urls: [URL] = []
        urls.reserveCapacity(candidates.count)
        for raw in candidates {
            let cleaned = cleanURLToken(raw)
            guard let url = URLSanitizer.resolveHTTPSURL(from: cleaned) else { continue }
            if seen.insert(url.absoluteString).inserted {
                urls.append(url)
            }
        }
        return urls
    }

    private static func cleanURLToken(_ raw: String) -> String {
        var token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        token = token
            .trimmingCharacters(in: CharacterSet(charactersIn: "<>\"'"))
            .trimmingCharacters(in: CharacterSet(charactersIn: ")]}.,;"))
        return token
    }
}
#endif

#if canImport(Textual) && !os(watchOS)
private struct MarkdownImagePreviewItem: Identifiable {
    let id = UUID()
    let url: URL
}
#endif

#if canImport(Textual) && !os(watchOS)
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

#if canImport(Textual) && !os(watchOS)
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
