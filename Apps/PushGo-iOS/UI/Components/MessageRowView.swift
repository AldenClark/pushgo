import SwiftUI

struct MessageRowView: View {
    let message: PushMessageSummary
    @Environment(\.appEnvironment) private var environment: AppEnvironment

    private var placeholderIcon: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color.clear)
            .overlay(
                Image(systemName: "bell.badge.fill")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .accessibilityHidden(true)
            )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 4) {
                HStack(alignment: .center, spacing: 8) {
                    titleIcon

                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(message.title)
                                .font(.headline)
                                .fontWeight(message.isRead ? .regular : .semibold)
                                .lineLimit(2)
                            if !message.isRead {
                                UnreadDotView()
                                    .padding(.leading, 8)
                            }
                            encryptionIndicator
                        }

                        if let channelLabel = environment.channelDisplayName(for: message.channel) {
                            Text(channelLabel)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .lineLimit(2)
                        } else if !message.secondaryText.isEmpty {
                            Text(message.secondaryText)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .lineLimit(2)
                        }
                    }
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 6) {
                    HStack(alignment: .center, spacing: 8) {
                        Text(MessageTimestampFormatter.listTimestamp(for: message.receivedAt))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }

            bodyPreviewView

            if let imageURL = message.imageURL {
                RemoteImageView(url: imageURL) { image in
                    image
                        .resizable()
                        .scaledToFill()
                } placeholder: {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.clear)
                }
                .accessibilityLabel(LocalizedStringKey("image_attachment"))
                .frame(maxWidth: .infinity)
                .frame(height: 140)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.primary.opacity(0.08), lineWidth: 0.6),
                )
            }
        }
        .padding(.vertical, verticalPadding)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var titleIcon: some View {
        if let iconURL = message.iconURL {
            RemoteImageView(url: iconURL) { image in
                image
                    .resizable()
                    .scaledToFill()
            } placeholder: {
                placeholderIcon
            }
            .frame(width: 20, height: 20)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .accessibilityHidden(true)
        } else {
            EmptyView()
        }
    }

    private var verticalPadding: CGFloat {
        6
    }

    @ViewBuilder
    private var bodyPreviewView: some View {
        if let payload = message.bodyRenderPayload {
            Text(payload.attributedString(textStyle: .subheadline))
                .font(.subheadline)
                .foregroundColor(.secondary)
                .lineLimit(4)
        } else {
            Text(message.bodyPreview)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .lineLimit(4)
        }
    }

    @ViewBuilder
    private var encryptionIndicator: some View {
        if message.isEncrypted {
            let isDecryptFailed = message.decryptionState == .decryptFailed
            let icon = isDecryptFailed ? "lock.slash" : "lock.fill"
            let color: Color = isDecryptFailed ? .red : .accentColor
            Image(systemName: icon)
                .font(.caption.bold())
                .foregroundColor(color)
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
