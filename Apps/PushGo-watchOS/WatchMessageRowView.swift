import SwiftUI

struct WatchMessageRowView: View {
    let message: PushMessageSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if !message.isRead {
                    Circle()
                        .fill(Color(red: 37.0 / 255.0, green: 99.0 / 255.0, blue: 235.0 / 255.0))
                        .frame(width: 6, height: 6)
                        .accessibilityLabel(LocalizedStringKey("unread"))
                }

                Text(message.title.isEmpty ? message.bodyPreview : message.title)
                    .font(.headline)
                    .lineLimit(2)

                if message.isEncrypted {
                    Image(systemName: message.decryptionState == .decryptFailed ? "lock.slash" : "lock.fill")
                        .font(.caption2.weight(.semibold))
                        .foregroundColor(message.decryptionState == .decryptFailed ? .red : .accentColor)
                        .accessibilityLabel(
                            LocalizedStringKey(
                                message.decryptionState == .decryptFailed
                                    ? "decryption_failed_the_original_text_has_been_displayed"
                                    : "encrypted_message"
                            )
                        )
                }

                Spacer(minLength: 0)

                Text(MessageTimestampFormatter.listTimestamp(for: message.receivedAt))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if !message.bodyPreview.isEmpty {
                Text(message.bodyPreview)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    Text("Preview")
}
