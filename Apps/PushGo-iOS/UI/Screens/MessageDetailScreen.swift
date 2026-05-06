import SwiftUI
import UIKit
#if canImport(Textual)
import Textual
#endif

struct MessageDetailScreen: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(LocalizationManager.self) private var localizationManager: LocalizationManager
    @Environment(AppEnvironment.self) private var environment: AppEnvironment
    @State private var viewModel: MessageDetailViewModel
    @State private var isShowingRuntimeAlert = false
    @State private var previewingImage: ImagePreview?
    @State private var isTextSelectionEnabled = true
    @State private var didLoad: Bool = false
    private let onCommitDelete: (@MainActor () async throws -> Void)?
    private let onPrepareDelete: (() -> Void)?
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
        onCommitDelete: (@MainActor () async throws -> Void)? = nil,
        onPrepareDelete: (() -> Void)? = nil,
        shouldDismissOnDelete: Bool = true,
        useNavigationContainer: Bool = true,
    ) {
        _viewModel = State(wrappedValue: MessageDetailViewModel(
            messageId: messageId,
            initialMessage: message,
        ))
        self.onCommitDelete = onCommitDelete
        self.onPrepareDelete = onPrepareDelete
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
                await viewModel.ensureLoaded()
                await viewModel.markAsReadIfNeeded()
            }
        }
        .onChange(of: viewModel.alertMessage) { _, newValue in
            isShowingRuntimeAlert = newValue != nil
        }
        .onChange(of: isShowingRuntimeAlert) { _, isPresented in
            if !isPresented {
                viewModel.alertMessage = nil
            }
        }
        .alert(isPresented: $isShowingRuntimeAlert) {
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
            GeometryReader { proxy in
                let markdownWidthHint = max(proxy.size.width - (EntityVisualTokens.detailPaddingHorizontal * 2), 1)
                ScrollView {
                    VStack(alignment: .leading, spacing: EntityVisualTokens.detailSectionSpacing) {
                    HStack(alignment: .center, spacing: 12) {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(alignment: .top, spacing: 8) {
                                MarkdownRenderer(
                                    text: message.title,
                                    font: .title2.weight(.semibold),
                                    foreground: .primary,
                                    attachmentWidthHint: markdownWidthHint
                                )
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .compatTextSelectionEnabled(isTextSelectionEnabled)
                                encryptionBadge(for: message)
                            }

                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 8) {
                                    Text(message.receivedAt.pushgoDetailTimestamp())
                                        .font(.subheadline)
                                        .foregroundStyle(Color.appTextSecondary)
                                    messageSeverityBadge(for: message.severity)
                                }
                                if let channelName = environment.channelDisplayName(for: message.channel) {
                                    ChannelTagView(text: channelName)
                                }
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
                        font: .body,
                        foreground: .primary,
                        attachmentWidthHint: markdownWidthHint
                    )
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .compatTextSelectionEnabled(isTextSelectionEnabled)

                    if let url = message.url,
                       let safeOpenURL = URLSanitizer.sanitizeExternalOpenURL(url)
                    {
                        HStack(spacing: 10) {
                            Link(destination: safeOpenURL) {
                                Label(localizationManager.localized("open_link"), systemImage: "link")
                            }
                            .buttonStyle(.borderedProminent)
                            .appButtonHeight()
                            .frame(maxWidth: .infinity, alignment: .leading)

                            Button {
                                copyText(safeOpenURL.absoluteString, toastKey: "link_copied")
                            } label: {
                                Image(systemName: "doc.on.doc")
                            }
                            .buttonStyle(.bordered)
                            .appButtonHeight()
                            .accessibilityIdentifier("action.message.copy_link")
                            .accessibilityLabel(localizationManager.localized("copy_content"))
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, EntityVisualTokens.detailPaddingHorizontal)
                .padding(.vertical, EntityVisualTokens.detailPaddingVertical)
                .background(EntityVisualTokens.pageBackground)
                .contentShape(Rectangle())
            }
        }
        } else {
            if viewModel.isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else if viewModel.hasResolvedMessage {
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
                ForEach(entries.indices, id: \.self) { index in
                    let item = entries[index]
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(item.displayLabel)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.appTextSecondary)
                        Text(item.value)
                            .font(.body)
                            .foregroundStyle(.primary)
                            .textSelection(.enabled)
                        Button {
                            copyText(item.value)
                        } label: {
                            Image(systemName: "doc.on.doc")
                                .font(.subheadline.weight(.semibold))
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("action.message.copy_metadata_value.\(index)")
                        .accessibilityLabel(localizationManager.localized("copy_content"))
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
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach(tags.indices, id: \.self) { index in
                    let tag = tags[index]
                    EntityMetaChip(systemImage: "tag", text: tag)
                }
            }
        }
        .scrollIndicators(.hidden)
    }

    @ViewBuilder
    private func messageImagesSection(imageURLs: [URL]) -> some View {
        if imageURLs.count == 1, let imageURL = imageURLs.first {
            GeometryReader { proxy in
                let maxWidth = min(proxy.size.width, Layout.singleImageMaxWidth)
                RemoteImageView(url: imageURL, rendition: .original) { image in
                    Button {
                        previewingImage = ImagePreview(url: imageURL)
                    } label: {
                        image
                            .resizable()
                            .scaledToFill()
                            .frame(width: maxWidth, height: Layout.singleImageHeight)
                            .clipShape(
                                RoundedRectangle(
                                    cornerRadius: EntityVisualTokens.radiusMedium,
                                    style: .continuous
                                )
                            )
                            .overlay(
                                RoundedRectangle(
                                    cornerRadius: EntityVisualTokens.radiusMedium,
                                    style: .continuous
                                )
                                .stroke(EntityVisualTokens.subtleStroke, lineWidth: 0.8),
                            )
                    }
                    .buttonStyle(.appPlain)
                    .accessibilityLabel(LocalizedStringKey("image_attachment"))
                } placeholder: {
                    RoundedRectangle(cornerRadius: EntityVisualTokens.radiusMedium, style: .continuous)
                        .fill(EntityVisualTokens.subtleFill)
                        .frame(width: maxWidth, height: Layout.singleImageHeight)
                        .clipShape(
                            RoundedRectangle(
                                cornerRadius: EntityVisualTokens.radiusMedium,
                                style: .continuous
                            )
                        )
                        .overlay(
                            RoundedRectangle(
                                cornerRadius: EntityVisualTokens.radiusMedium,
                                style: .continuous
                            )
                            .stroke(EntityVisualTokens.subtleStroke, lineWidth: 0.8),
                        )
                }
                .frame(maxWidth: .infinity, alignment: .center)
            }
            .frame(height: Layout.singleImageHeight)
        } else {
            ScrollView(.horizontal) {
                HStack(spacing: 10) {
                    ForEach(imageURLs, id: \.absoluteString) { imageURL in
                        RemoteImageView(url: imageURL, rendition: .listThumbnail) { image in
                            Button {
                                previewingImage = ImagePreview(url: imageURL)
                            } label: {
                                image
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: Layout.thumbnailSize, height: Layout.thumbnailSize)
                                    .clipShape(
                                        RoundedRectangle(
                                            cornerRadius: Layout.thumbnailCornerRadius,
                                            style: .continuous
                                        )
                                    )
                                    .overlay(
                                        RoundedRectangle(
                                            cornerRadius: Layout.thumbnailCornerRadius,
                                            style: .continuous
                                        )
                                        .stroke(EntityVisualTokens.subtleStroke, lineWidth: 0.8),
                                    )
                            }
                            .buttonStyle(.appPlain)
                            .accessibilityLabel(LocalizedStringKey("image_attachment"))
                        } placeholder: {
                            RoundedRectangle(cornerRadius: Layout.thumbnailCornerRadius, style: .continuous)
                                .fill(EntityVisualTokens.subtleFill)
                                .frame(width: Layout.thumbnailSize, height: Layout.thumbnailSize)
                                .clipShape(
                                    RoundedRectangle(
                                        cornerRadius: Layout.thumbnailCornerRadius,
                                        style: .continuous
                                    )
                                )
                                .overlay(
                                    RoundedRectangle(
                                        cornerRadius: Layout.thumbnailCornerRadius,
                                        style: .continuous
                                    )
                                    .stroke(EntityVisualTokens.subtleStroke, lineWidth: 0.8),
                                )
                        }
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button(role: .destructive) {
                if let message = viewModel.message {
                    Task { await scheduleDeletion(for: message) }
                }
            } label: {
                Image(systemName: "trash")
            }
            .disabled(viewModel.message == nil)
            .accessibilityIdentifier("action.message.delete")
            .accessibilityLabel(localizationManager.localized("delete"))
        }
    }

    @MainActor
    private func scheduleDeletion(for message: PushMessage) async {
        let trimmedTitle = message.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let summary = trimmedTitle.isEmpty
            ? localizationManager.localized("tab_messages")
            : trimmedTitle

        await environment.pendingLocalDeletionController.schedule(
            summary: summary,
            undoLabel: localizationManager.localized("cancel"),
            scope: .init(messageIDs: Set([message.id]))
        ) { [environment, onCommitDelete] in
            if let onCommitDelete {
                try await onCommitDelete()
            } else {
                try await environment.messageStateCoordinator.deleteMessage(messageId: message.id)
            }
        } onCompletion: { [environment] result in
            guard case let .failure(error) = result else { return }
            environment.showToast(
                message: error.localizedDescription,
                style: .error,
                duration: 2.5
            )
        }

        onPrepareDelete?()
        if shouldDismissOnDelete {
            dismiss()
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
                        .fill(badgeContent.tone.background),
                )
                .foregroundStyle(badgeContent.tone.foreground)
                .labelStyle(.titleAndIcon)
        } else {
            EmptyView()
        }
    }

    private func badgeContent(for message: PushMessage) -> (icon: String, tone: AppSemanticTone, text: String)? {
        if let state = message.decryptionState {
            switch state {
            case .decryptFailed:
                return (
                    "lock.slash",
                    .danger,
                    localizationManager.localized("decryption_failed_the_original_text_has_been_displayed")
                )
            case .decryptOk:
                return (
                    "lock.open.fill",
                    .info,
                    localizationManager.localized("decrypted")
                )
            case .notConfigured, .algMismatch:
                return (
                    "lock.fill",
                    .info,
                    localizationManager.localized("encrypted")
                )
            }
        }

        if message.isEncrypted {
            return (
                "lock.fill",
                .info,
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
                .foregroundStyle(AppSemanticTone.danger.foreground)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: EntityVisualTokens.radiusSmall, style: .continuous)
                        .fill(AppSemanticTone.danger.background)
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
                AppSemanticTone.info.background,
                AppSemanticTone.info.foreground
            )
        case .medium:
            return (
                localizationManager.localized("message_severity_medium"),
                AppSemanticTone.info.background,
                AppSemanticTone.info.foreground
            )
        case .high:
            return (
                localizationManager.localized("message_severity_high"),
                AppSemanticTone.warning.background,
                AppSemanticTone.warning.foreground
            )
        case .critical:
            return (
                localizationManager.localized("message_severity_critical"),
                AppSemanticTone.danger.background,
                AppSemanticTone.danger.foreground
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

    private func copyText(_ text: String, toastKey: String = "message_content_copied") {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        PushGoSystemInteraction.copyTextToPasteboard(trimmed)
        environment.showToast(
            message: localizationManager.localized(toastKey),
            style: .success,
            duration: 1.2
        )
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
                    .fill(AppSemanticTone.info.background)
            )
            .foregroundStyle(AppSemanticTone.info.foreground)
            .lineLimit(1)
    }
}

private extension View {
    @ViewBuilder
    func compatTextSelectionEnabled(_ enabled: Bool) -> some View {
        modifier(DeferredTextSelectionEnabledModifier(enabled: enabled))
    }
}

private extension Date {
    func pushgoDetailTimestamp() -> String {
        formatted(date: .complete, time: .standard)
    }
}

private struct DeferredTextSelectionEnabledModifier: ViewModifier {
    let enabled: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled {
#if canImport(Textual)
            content
                .textual.textSelection(.enabled)
#else
            content
                .textSelection(.enabled)
#endif
        } else {
            content
        }
    }
}
