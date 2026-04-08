import AppKit
import SwiftUI

struct MessageRowView: View {
    let message: PushMessageSummary
    @Environment(AppEnvironment.self) private var environment: AppEnvironment

    private enum Layout {
        static let bodyImageSize: CGFloat = 48
        static let bodyImageCornerRadius: CGFloat = EntityVisualTokens.radiusSmall
        static let bodyMaxLines: Int = 8
        static let imagePreviewLimit: Int = 4
        static let imageSpacing: CGFloat = 8
    }

    var body: some View {
        VStack(alignment: .leading, spacing: EntityVisualTokens.stackSpacing) {
            HStack(alignment: .center, spacing: 4) {
                HStack(alignment: .center, spacing: 8) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(message.title)
                                .font(.headline)
                                .fontWeight(.semibold)
                                .lineLimit(2)
                            MessageSeverityListBadge(severity: message.severity)
                            if !message.isRead {
                                UnreadDotView()
                                    .padding(.leading, 8)
                            }
                            encryptionIndicator
                        }

                        if let channelLabel = environment.channelDisplayName(for: message.channel) {
                            Text(channelLabel)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        } else if !message.secondaryText.isEmpty {
                            Text(message.secondaryText)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 6) {
                    HStack(alignment: .center, spacing: 8) {
                    Text(MessageTimestampFormatter.listTimestamp(for: message.receivedAt))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
            }

            if hasBodyPreview {
                bodyPreviewView
            }

            if !message.tags.isEmpty {
                Text(message.tags.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            if !message.imageURLs.isEmpty {
                messageImageRow
            }
        }
        .padding(.vertical, verticalPadding)
        .accessibilityElement(children: .combine)
    }

    private var messageImageRow: some View {
        GeometryReader { proxy in
            HStack(spacing: Layout.imageSpacing) {
                ForEach(message.imageURLs.prefix(visibleImageCount(for: proxy.size.width)), id: \.absoluteString) { imageURL in
                    RemoteImageView(url: imageURL, rendition: .listThumbnail) { image in
                        image
                            .resizable()
                            .scaledToFill()
                    } placeholder: {
                        RoundedRectangle(cornerRadius: Layout.bodyImageCornerRadius, style: .continuous)
                            .fill(EntityVisualTokens.secondarySurface)
                    }
                    .accessibilityLabel(LocalizedStringKey("image_attachment"))
                    .frame(width: Layout.bodyImageSize, height: Layout.bodyImageSize)
                    .clipShape(RoundedRectangle(cornerRadius: Layout.bodyImageCornerRadius, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: Layout.bodyImageCornerRadius, style: .continuous)
                            .stroke(EntityVisualTokens.subtleStroke, lineWidth: 0.6),
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: Layout.bodyImageSize)
    }

    private func visibleImageCount(for availableWidth: CGFloat) -> Int {
        guard availableWidth > 0 else { return Layout.imagePreviewLimit }
        let unit = Layout.bodyImageSize + Layout.imageSpacing
        let count = Int(((availableWidth + Layout.imageSpacing) / unit).rounded(.down))
        return max(1, count)
    }

    private var bodyPreviewMaxHeight: CGFloat {
        let font = NSFont.preferredFont(forTextStyle: .subheadline)
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        return lineHeight * CGFloat(Layout.bodyMaxLines)
    }

    @ViewBuilder
    private var bodyPreviewView: some View {
        Text(message.bodyPreview)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .lineLimit(Layout.bodyMaxLines)
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)
            .frame(maxHeight: bodyPreviewMaxHeight, alignment: .top)
            .clipped()
    }

    private var verticalPadding: CGFloat {
        EntityVisualTokens.rowVerticalPadding
    }

    private var hasBodyPreview: Bool {
        !message.bodyPreview.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    @ViewBuilder
    private var encryptionIndicator: some View {
        if message.isEncrypted {
            let isDecryptFailed = message.decryptionState == .decryptFailed
            let icon = isDecryptFailed ? "lock.slash" : "lock.fill"
            let color: Color = isDecryptFailed ? .red : .accentColor
            Image(systemName: icon)
                .font(.caption.bold())
                .foregroundStyle(color)
                .accessibilityLabel(
                    LocalizedStringKey(
                        isDecryptFailed
                            ? "decryption_failed_the_original_text_has_been_displayed"
                            : "encrypted_message",
                    ),
                )
        } else {
            EmptyView()
        }
    }
}


private struct UnreadDotView: View {
    var body: some View {
        Circle()
            .fill(Color.accentColor)
            .frame(width: 8, height: 8)
            .accessibilityLabel(LocalizedStringKey("unread"))
    }
}

private struct MessageSeverityListBadge: View {
    let severity: PushMessage.Severity?

    private var style: (label: LocalizedStringKey, background: Color, foreground: Color)? {
        switch severity {
        case .high:
            return (
                LocalizedStringKey("message_severity_high_compact"),
                Color.orange.opacity(0.16),
                Color.orange
            )
        case .critical:
            return (
                LocalizedStringKey("message_severity_critical_compact"),
                Color.red.opacity(0.14),
                Color.red
            )
        default:
            return nil
        }
    }

    var body: some View {
        if let style {
            Text(style.label)
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    Capsule(style: .continuous)
                        .fill(style.background)
                )
                .foregroundStyle(style.foreground)
                .accessibilityLabel(style.label)
        }
    }
}
