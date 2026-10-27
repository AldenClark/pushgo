import Foundation
import SwiftUI
import Textual

struct MarkdownRenderer: View {
    private static let textualScale: CGFloat = 0.92
    let text: String
    var maxNewlines: Int? = nil
    var font: Font = .body
    var foreground: Color = .primary
    var attachmentWidthHint: CGFloat? = nil

    private var displayText: String {
        guard let max = maxNewlines else { return text }
        return limitText(text, toFirstNewlines: max)
    }

    private func markdownRenderPreparation(for displayText: String) -> (
        presentationStyle: MarkdownPresentationStyle,
        normalizedText: String
    ) {
        let style = markdownPresentationStyle(for: displayText)
        recordMarkdownDisplayModeEvaluationMetric()
        return (
            presentationStyle: style,
            normalizedText: normalizeMarkdown(displayText)
        )
    }

    var body: some View {
        markdownContent
    }
}

extension MarkdownRenderer {
    private var markdownContent: some View {
        let currentDisplayText = displayText
        let renderPreparation = markdownRenderPreparation(for: currentDisplayText)
        return Group {
            if renderPreparation.presentationStyle == .structuredText {
                StructuredText(markdown: renderPreparation.normalizedText)
                    .textual.structuredTextStyle(.gitHub)
                    .textual.tableCellStyle(PushGoRefinedTableCellStyle())
                    .textual.tableStyle(PushGoRefinedTableStyle())
            } else {
                InlineText(markdown: renderPreparation.normalizedText)
            }
        }
        .transaction { transaction in
            transaction.animation = nil
        }
        // App-owned attachment rendering consumes the same controlled bytes as every other
        // image entry. Textual owns parsing/layout, never an independent remote fallback.
        .textual.imageAttachmentLoader(PushGoResourceAttachmentLoader())
        .textual.imageAttachmentWidthHint(attachmentWidthHint)
        .attachmentRenderingMode(.interactive)
        .textual.fontScale(Self.textualScale)
        .textual.inlineStyle(.gitHub)
        .textual.textSelection(.enabled)
        .environment(\.openURL, OpenURLAction { incoming in
            guard let safeURL = URLSanitizer.sanitizeExternalOpenURL(incoming) else {
                return .discarded
            }
            return .systemAction(safeURL)
        })
        .font(font)
        .foregroundStyle(foreground)
        .modifier(MarkdownRendererLayoutMode(presentationStyle: renderPreparation.presentationStyle))
    }
}

private struct MarkdownRendererLayoutMode: ViewModifier {
    let presentationStyle: MarkdownPresentationStyle

    func body(content: Content) -> some View {
        #if os(macOS)
        if presentationStyle == .structuredText {
            content
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            content.frame(maxWidth: .infinity, alignment: .leading)
        }
        #else
        content
            .lineLimit(nil)
            .fixedSize(horizontal: false, vertical: true)
        #endif
    }
}

private enum MarkdownPresentationStyle {
    case inlineText
    case structuredText
}

private func markdownPresentationStyle(for text: String) -> MarkdownPresentationStyle {
    switch pushGoMarkdownDisplayMode(for: text) {
    case .structuredText:
        return .structuredText
    case .inlineText:
        return .inlineText
    case .plainText:
        return text.contains("\n") ? .structuredText : .inlineText
    }
}

private func recordMarkdownDisplayModeEvaluationMetric() {
    #if DEBUG
    Task { @MainActor in
        PushGoAutomationRuntime.shared.recordMarkdownDisplayModeEvaluated()
    }
    #endif
}

private struct MarkdownImagePreviewItem: Identifiable {
    let id = UUID()
    let url: URL
}

private struct PushGoResourceAttachmentLoader: AttachmentLoader {
    func provisionalAttachment(for url: URL, text: String, environment: ColorEnvironmentValues) -> PushGoResourceAttachment? {
        PushGoResourceAttachment(url: url, description: text)
    }

    func attachment(for url: URL, text: String, environment: ColorEnvironmentValues) async throws -> PushGoResourceAttachment {
        PushGoResourceAttachment(url: url, description: text)
    }
}

private struct PushGoResourceAttachment: Attachment {
    let url: URL
    let description: String

    @MainActor var body: some View {
        MarkdownControlledImage(url: url, text: description)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, in environment: TextEnvironmentValues) -> CGSize {
        let width = max(min(proposal.width ?? environment.imageAttachmentWidthHint ?? 240, 960), 1)
        // A stable attachment box avoids an unowned metadata GET before the controlled view
        // resolves its canonical owner. scaledToFit preserves all source pixels; the viewer
        // offers zoom/pan on the same acquired original rather than a second remote loader.
        return CGSize(width: min(width, 240), height: min(width, 240) * 9 / 16)
    }
}

private struct MarkdownControlledImage: View {
    let url: URL
    let text: String
    @State private var previewingImage: MarkdownImagePreviewItem?

    var body: some View {
        RemoteImageView(url: url, rendition: .listThumbnail) { image in
            image.resizable().scaledToFit()
                .contentShape(Rectangle())
                .onTapGesture { previewingImage = MarkdownImagePreviewItem(url: url) }
        } placeholder: {
            ProgressView()
        }
        .accessibilityLabel(Text(text))
        .pushgoImagePreviewOverlay(previewItem: $previewingImage, imageURL: \.url)
    }
}

private struct PushGoRefinedTableCellStyle: StructuredText.TableCellStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .fontWeight(configuration.row == 0 ? .semibold : .regular)
            .padding(.vertical, 7)
            .padding(.horizontal, 12)
            .textual.lineSpacing(.fontScaled(0.25))
    }
}

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

private func normalizeMarkdown(_ markdown: String) -> String {
    // Foundation's markdown parser does not render [![...]](...) as an image.
    // Keep this narrowly scoped: unwrap link-wrapped images and delegate all
    // other markdown semantics to Textual/Foundation.
    guard let regex = MarkdownNormalizationRegex.linkWrappedImage else {
        return markdown
    }
    let range = NSRange(markdown.startIndex ..< markdown.endIndex, in: markdown)
    return regex.stringByReplacingMatches(in: markdown, range: range, withTemplate: "$1")
}

private enum MarkdownNormalizationRegex {
    static let linkWrappedImage: NSRegularExpression? = {
        let pattern = #"\[(!\[[^\]]*?\]\((?:\\.|[^\\)])*?\))\]\((?:\\.|[^\\)])*?\)"#
        return try? NSRegularExpression(pattern: pattern)
    }()
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
