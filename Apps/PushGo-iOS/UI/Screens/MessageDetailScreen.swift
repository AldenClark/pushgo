import SwiftUI
import UIKit

struct MessageDetailScreen: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(LocalizationManager.self) private var localizationManager: LocalizationManager
    @Environment(AppEnvironment.self) private var environment: AppEnvironment
    @State private var viewModel: MessageDetailViewModel
    @State private var showDeleteConfirmation = false
    @State private var previewingImage: ImagePreview?
    @State private var didLoad: Bool = false
    private let onDelete: (() -> Void)?
    private let shouldDismissOnDelete: Bool
    private let useNavigationContainer: Bool

    private enum Layout {
        static let singleImageHeight: CGFloat = 240
        static let singleImageMaxWidth: CGFloat = 520
        static let thumbnailSize: CGFloat = 88
        static let thumbnailCornerRadius: CGFloat = EntityVisualTokens.radiusSmall
    }

    init(
        messageId: UUID,
        message: PushMessage? = nil,
        onDelete: (() -> Void)? = nil,
        shouldDismissOnDelete: Bool = true,
        useNavigationContainer: Bool = true,
    ) {
        _viewModel = State(wrappedValue: MessageDetailViewModel(
            messageId: messageId,
            initialMessage: message,
        ))
        self.onDelete = onDelete
        self.shouldDismissOnDelete = shouldDismissOnDelete
        self.useNavigationContainer = useNavigationContainer
    }

    var body: some View {
        Group {
            if useNavigationContainer {
                navigationContainer {
                    detailContent
                    .toolbar { toolbarContent }
                }
            } else {
                detailContent
                .toolbar { toolbarContent }
            }
        }
        .accessibilityIdentifier("screen.message.detail")
        .onAppear {
            guard !didLoad else { return }
            didLoad = true
            Task {
                viewModel.refresh()
                await viewModel.markAsReadIfNeeded()
            }
        }
        .alert(isPresented: Binding(
            get: { viewModel.alertMessage != nil },
            set: { if !$0 { viewModel.alertMessage = nil } },
        )) {
            Alert(
                title: Text(viewModel.alertMessage ?? ""),
                dismissButton: .default(Text(localizationManager.localized("ok")))
            )
        }
        .pushgoImagePreviewOverlay(previewItem: $previewingImage, imageURL: \.url)
#if DEBUG
        .task(id: automationStateSignature) {
            PushGoAutomationRuntime.shared.publishState(
                environment: environment,
                activeTab: "messages",
                visibleScreen: "screen.message.detail",
                openedMessageId: viewModel.message.flatMap { $0.messageId ?? $0.id.uuidString },
                openedMessageDecryptionState: viewModel.message?.decryptionState?.rawValue
            )
        }
#endif
    }

    private var automationStateSignature: String {
        guard let message = viewModel.message else {
            return "message:none"
        }
        let identifier = message.messageId ?? message.id.uuidString
        let decryption = message.decryptionState?.rawValue ?? "none"
        return "\(identifier)|\(decryption)|\(message.isRead)"
    }

    @ViewBuilder
    private var detailContent: some View {
        if let message = viewModel.message {
            ScrollView {
                VStack(alignment: .leading, spacing: EntityVisualTokens.detailSectionSpacing) {
                    HStack(alignment: .center, spacing: 12) {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(alignment: .center, spacing: 8) {
                                MarkdownRenderer(
                                    text: message.title,
                                    maxNewlines: nil,
                                    font: .title2.weight(.semibold),
                                    foreground: .primary
                                )
                                    .multilineTextAlignment(.leading)
                                    .compatTextSelectionEnabled()

                                encryptionBadge(for: message)
                            }

                            HStack(spacing: 8) {
                                Text(message.receivedAt.pushgoDetailTimestamp())
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                                if let channelName = environment.channelDisplayName(for: message.channel) {
                                    ChannelTagView(text: channelName)
                                }
                                messageSeverityBadge(for: message.severity)
                            }
                        }
                    }
                    if !message.tags.isEmpty {
                        messageTagChipRow(tags: message.tags)
                    }
                    if !message.metadata.isEmpty {
                        metadataSection(items: message.metadata)
                    }
                    if !message.imageURLs.isEmpty {
                        messageImagesSection(imageURLs: message.imageURLs)
                    }
                    criticalSeverityHint(for: message.severity)
                    let resolvedBody = message.resolvedBody
                    MarkdownRenderer(
                        text: resolvedBody.rawText,
                        maxNewlines: nil,
                        font: .body,
                        foreground: .primary
                    )
                    .compatTextSelectionEnabled()

                    if let url = message.url,
                       let safeOpenURL = URLSanitizer.sanitizeExternalOpenURL(url)
                    {
                        Link(destination: safeOpenURL) {
                            Label(localizationManager.localized("open_link"), systemImage: "link")
                        }
                        .buttonStyle(.borderedProminent)
                        .appButtonHeight()
                    }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, EntityVisualTokens.detailPaddingHorizontal)
            .padding(.vertical, EntityVisualTokens.detailPaddingVertical)
            .background(EntityVisualTokens.pageBackground)
        }
            .alert(isPresented: $showDeleteConfirmation) {
                Alert(
                    title: Text(localizationManager.localized(
                        "are_you_sure_you_want_to_delete_this_message_once_deleted_it_cannot_be_recovered"
                )),
                primaryButton: .destructive(Text(localizationManager.localized("delete"))) {
                    Task {
                        await viewModel.deleteMessage()
                        onDelete?()
                        if shouldDismissOnDelete {
                            dismiss()
                        }
                    }
                },
                secondaryButton: .cancel(Text(localizationManager.localized("cancel")))
                )
            }
        } else {
            if viewModel.hasResolvedMessage {
                missingState
            } else {
                Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    @ViewBuilder
    private func metadataSection(items: [String: String]) -> some View {
        let entries = metadataDisplayAttributes(from: items)
        VStack(alignment: .leading, spacing: EntityVisualTokens.stackSpacing) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(entries.enumerated()), id: \.element.id) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(item.displayLabel)
                            .font(.subheadline.weight(.semibold))
                            .foregroundColor(.secondary)
                        Text(item.value)
                            .font(.body)
                            .foregroundColor(.primary)
                            .textSelection(.enabled)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: EntityVisualTokens.radiusMedium, style: .continuous)
                    .fill(EntityVisualTokens.subtleFill)
            )
        }
    }

    @ViewBuilder
    private func messageTagChipRow(tags: [String]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Array(tags.enumerated()), id: \.offset) { _, tag in
                    EntityMetaChip(systemImage: "tag", text: tag)
                }
            }
        }
    }

    @ViewBuilder
    private func messageImagesSection(imageURLs: [URL]) -> some View {
        if imageURLs.count == 1, let imageURL = imageURLs.first {
            GeometryReader { proxy in
                let maxWidth = min(proxy.size.width, Layout.singleImageMaxWidth)
                Button {
                    previewingImage = ImagePreview(url: imageURL)
                } label: {
                    RemoteImageView(url: imageURL) { image in
                        image
                            .resizable()
                            .scaledToFill()
                    } placeholder: {
                        RoundedRectangle(cornerRadius: EntityVisualTokens.radiusMedium, style: .continuous)
                            .fill(EntityVisualTokens.subtleFill)
                    }
                    .frame(width: maxWidth, height: Layout.singleImageHeight)
                    .clipShape(RoundedRectangle(cornerRadius: EntityVisualTokens.radiusMedium, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: EntityVisualTokens.radiusMedium, style: .continuous)
                            .stroke(EntityVisualTokens.subtleStroke, lineWidth: 0.8),
                    )
                }
                .buttonStyle(.appPlain)
                .accessibilityLabel(LocalizedStringKey("image_attachment"))
                .frame(maxWidth: .infinity, alignment: .center)
            }
            .frame(height: Layout.singleImageHeight)
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(imageURLs, id: \.absoluteString) { imageURL in
                        Button {
                            previewingImage = ImagePreview(url: imageURL)
                        } label: {
                            RemoteImageView(url: imageURL, rendition: .listThumbnail) { image in
                                image
                                    .resizable()
                                    .scaledToFill()
                            } placeholder: {
                                RoundedRectangle(cornerRadius: Layout.thumbnailCornerRadius, style: .continuous)
                                    .fill(EntityVisualTokens.subtleFill)
                            }
                            .frame(width: Layout.thumbnailSize, height: Layout.thumbnailSize)
                            .clipShape(
                                RoundedRectangle(cornerRadius: Layout.thumbnailCornerRadius, style: .continuous)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: Layout.thumbnailCornerRadius, style: .continuous)
                                    .stroke(EntityVisualTokens.subtleStroke, lineWidth: 0.8),
                            )
                        }
                        .buttonStyle(.appPlain)
                        .accessibilityLabel(LocalizedStringKey("image_attachment"))
                    }
                }
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .navigationBarTrailing) {
            Button(role: .destructive) {
                if viewModel.message != nil {
                    showDeleteConfirmation = true
                }
            } label: {
                Image(systemName: "trash")
            }
            .disabled(viewModel.message == nil)
            .accessibilityIdentifier("action.message.delete")
            .accessibilityLabel(localizationManager.localized("delete"))
        }
    }

    @ViewBuilder
    private func encryptionBadge(for message: PushMessage) -> some View {
        if let badgeContent = badgeContent(for: message) {
            Label(badgeContent.text, systemImage: badgeContent.icon)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    Capsule(style: .continuous)
                        .fill(badgeContent.color.opacity(0.12)),
                )
                .foregroundColor(badgeContent.color)
                .labelStyle(.titleAndIcon)
        } else {
            EmptyView()
        }
    }

    private func badgeContent(for message: PushMessage) -> (icon: String, color: Color, text: String)? {
        if let state = message.decryptionState {
            switch state {
            case .decryptFailed:
                return (
                    "lock.slash",
                    .red,
                    localizationManager.localized("decryption_failed_the_original_text_has_been_displayed")
                )
            case .decryptOk:
                return (
                    "lock.open.fill",
                    .accentColor,
                    localizationManager.localized("decrypted")
                )
            case .notConfigured, .algMismatch:
                return (
                    "lock.fill",
                    .accentColor,
                    localizationManager.localized("encrypted")
                )
            }
        }

        if message.isEncrypted {
            return (
                "lock.fill",
                .accentColor,
                localizationManager.localized("encrypted")
            )
        }

        return nil
    }

    @ViewBuilder
    private func messageSeverityBadge(for severity: PushMessage.Severity?) -> some View {
        if let style = messageSeverityBadgeStyle(for: severity) {
            Text(style.label)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    Capsule(style: .continuous)
                        .fill(style.background),
                )
                .foregroundStyle(style.foreground)
        }
    }

    @ViewBuilder
    private func criticalSeverityHint(for severity: PushMessage.Severity?) -> some View {
        if severity == .critical {
            Text(localizationManager.localized("message_severity_critical_hint"))
                .font(.caption)
                .foregroundStyle(Color.red.opacity(0.9))
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: EntityVisualTokens.radiusSmall, style: .continuous)
                        .fill(Color.red.opacity(0.08))
                )
        }
    }

    private func messageSeverityBadgeStyle(for severity: PushMessage.Severity?) -> (
        label: String,
        background: Color,
        foreground: Color
    )? {
        switch severity {
        case .low:
            return (
                localizationManager.localized("message_severity_low"),
                EntityVisualTokens.chipFillUnselected,
                .secondary
            )
        case .medium:
            return (
                localizationManager.localized("message_severity_medium"),
                EntityVisualTokens.chipFillUnselected,
                .secondary
            )
        case .high:
            return (
                localizationManager.localized("message_severity_high"),
                Color.orange.opacity(0.16),
                .orange
            )
        case .critical:
            return (
                localizationManager.localized("message_severity_critical"),
                Color.red.opacity(0.14),
                .red
            )
        case .none:
            return nil
        }
    }

    private var missingState: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
            Text(localizationManager.localized("this_message_has_been_deleted_or_does_not_exist"))
                .font(.headline)
            AppActionButton(
                text: Text(localizationManager.localized("close")),
                variant: .plain,
                fullWidth: false
            ) {
                dismiss()
            }
        }
        .padding()
    }

}

private struct ImagePreview: Identifiable {
    let url: URL
    var id: URL { url }
}

private struct ChannelTagView: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.accentColor.opacity(0.12))
            )
            .foregroundColor(.accentColor)
            .lineLimit(1)
    }
}

private extension View {
    @ViewBuilder
    func compatTextSelectionEnabled() -> some View {
        textSelection(.enabled)
    }
}

private extension Date {
    func pushgoDetailTimestamp() -> String {
        formatted(date: .complete, time: .standard)
    }
}
