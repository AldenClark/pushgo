import SwiftUI
import UIKit

struct MessageDetailScreen: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(LocalizationManager.self) private var localizationManager: LocalizationManager
    @Environment(\.appEnvironment) private var environment: AppEnvironment
    @State private var viewModel: MessageDetailViewModel
    @State private var showDeleteConfirmation = false
    @State private var previewingImage: ImagePreview?
    @State private var didLoad: Bool = false
    private let onDelete: (() -> Void)?
    private let shouldDismissOnDelete: Bool
    private let useNavigationContainer: Bool

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
        .imagePreviewSheet(previewingImage: $previewingImage)
    }

    @ViewBuilder
    private var detailContent: some View {
        if let message = viewModel.message {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .center, spacing: 12) {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(alignment: .center, spacing: 8) {
                                if let iconURL = message.iconURL {
                                    RemoteImageView(url: iconURL) { image in
                                        image
                                            .resizable()
                                            .scaledToFill()
                                    } placeholder: {
                                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                                            .fill(Color.primary.opacity(0.05))
                                            .overlay(
                                                Image(systemName: "bell.badge.fill")
                                                    .font(.caption.weight(.semibold))
                                                    .foregroundColor(.secondary),
                                            )
                                    }
                                    .frame(width: 28, height: 28)
                                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                                            .stroke(Color.primary.opacity(0.08), lineWidth: 0.8),
                                    )
                                }

                                Text(message.title)
                                    .font(.title2.weight(.semibold))
                                    .multilineTextAlignment(.leading)

                                encryptionBadge(for: message)
                            }

                            HStack(spacing: 8) {
                                Text(message.receivedAt.pushgoDetailTimestamp())
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                                if let channelName = environment.channelDisplayName(for: message.channel) {
                                    ChannelTagView(text: channelName)
                                }
                            }
                        }
                    }
                    let resolvedBody = message.resolvedBody
                    MarkdownRenderer(
                        text: resolvedBody.rawText,
                        maxNewlines: nil,
                        font: .body,
                        foreground: .primary
                    )
                    .compatTextSelectionEnabled()

                    if let imageURL = message.imageURL {
                        GeometryReader { proxy in
                            let maxWidth = min(proxy.size.width, 520)
                            Button {
                                previewingImage = ImagePreview(url: imageURL)
                            } label: {
                                RemoteImageView(url: imageURL) { image in
                                    image
                                        .resizable()
                                        .scaledToFill()
                                } placeholder: {
                                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .fill(Color.primary.opacity(0.05))
                                }
                                .frame(width: maxWidth, height: 220)
                                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .stroke(Color.primary.opacity(0.08), lineWidth: 0.8),
                                )
                            }
                            .buttonStyle(.appPlain)
                            .accessibilityLabel(LocalizedStringKey("image_attachment"))
                            .frame(maxWidth: .infinity, alignment: .center)
                        }
                        .frame(height: 220)
                    }

                    if let url = message.url, URLSanitizer.isAllowedRemoteURL(url) {
                        Link(destination: url) {
                            Label(localizationManager.localized("open_link"), systemImage: "link")
                        }
                        .buttonStyle(.borderedProminent)
                        .appButtonHeight()
                    }

                DisclosureGroup(localizationManager.localized("raw_data")) {
                    if let rawText = formattedJSON(message.payloadForDisplay) {
                        RawPayloadView(
                            text: rawText,
                            onCopy: {
                                copyRawPayload(rawText)
                                environment.showToast(
                                    message: localizationManager.localized("message_content_copied"),
                                    style: .success,
                                    duration: 1.2
                                )
                            }
                        )
                        .padding(.top, 4)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
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

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .navigationBarTrailing) {
            if let message = viewModel.message, !message.isRead {
                Button {
                    Task { await viewModel.markRead(true) }
                } label: {
                    Image(systemName: "envelope.open")
                }
                .accessibilityLabel(localizationManager.localized("mark_as_read"))
            }
            
            Button {
                viewModel.copyBody()
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .disabled(viewModel.message == nil)
            .accessibilityLabel(localizationManager.localized("copy_content"))

            Button(role: .destructive) {
                if viewModel.message != nil {
                    showDeleteConfirmation = true
                }
            } label: {
                Image(systemName: "trash")
            }
            .disabled(viewModel.message == nil)
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

    private var missingState: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
            Text(localizationManager.localized("this_message_has_been_deleted_or_does_not_exist"))
                .font(.headline)
            Button(localizationManager.localized("close")) {
                dismiss()
            }
        }
        .padding()
    }


    private func formattedJSON(_ payload: [String: AnyCodable]) -> String? {
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(payload) else { return nil }

        guard let object = try? JSONSerialization.jsonObject(with: data) else {
            return data.utf8StringWithoutEscapedSlash
        }

        if let dict = object as? [String: Any],
           dict.count == 1,
           let value = dict.values.first as? String,
           let innerData = value.data(using: .utf8),
           let innerObject = try? JSONSerialization.jsonObject(with: innerData),
           let prettyInner = prettyJSONString(from: innerObject)
        {
            return prettyInner
        }

        if let pretty = prettyJSONString(from: object) { return pretty }

        return data.utf8StringWithoutEscapedSlash
    }

    private func prettyJSONString(from object: Any) -> String? {
        if let data = try? JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .withoutEscapingSlashes],
        ) {
            return String(data: data, encoding: .utf8)
        }
        return nil
    }

    private func copyRawPayload(_ text: String) {
        UIPasteboard.general.string = text
    }
}

private extension Data {
    var utf8StringWithoutEscapedSlash: String? {
        guard let raw = String(data: self, encoding: .utf8) else { return nil }
        return raw.replacingOccurrences(of: "\\/", with: "/")
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
                    .fill(Color.accentColor.opacity(0.14))
            )
            .foregroundColor(.accentColor)
            .lineLimit(1)
    }
}

private struct RawPayloadView: View {
    let text: String
    let onCopy: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(text)
                .font(.system(.body, design: .monospaced))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
        .contentShape(Rectangle())
        .contextMenu {
            Button {
                onCopy()
            } label: {
                Label("copy_content", systemImage: "doc.on.doc")
            }
        }
    }
}

private struct MessageImageViewer: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss
    @State private var currentScale: CGFloat = 1.0
    @State private var baseScale: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.opacity(0.95).ignoresSafeArea()

                RemoteImageView(url: url) { image in
                    image
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: geo.size.width, maxHeight: geo.size.height)
                        .scaleEffect(currentScale)
                        .offset(offset)
                        .animation(.spring(response: 0.2, dampingFraction: 0.85), value: currentScale)
                        .animation(.spring(response: 0.2, dampingFraction: 0.85), value: offset)
                        .onTapGesture(count: 2) { toggleZoom() }
                        .highPriorityGesture(combinedGesture)
                } placeholder: {
                    ProgressView().foregroundColor(.white)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                VStack {
                    HStack {
                        Spacer()
                        Button {
                            dismiss()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.title.weight(.bold))
                                .foregroundColor(.white.opacity(0.9))
                        }
                        .accessibilityLabel(LocalizedStringKey("close"))
                        .padding()
                    }
                    Spacer()
                }
            }
        }
    }

    private var combinedGesture: some Gesture {
        SimultaneousGesture(dragGesture, magnificationGesture)
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let translation = value.translation
                offset = CGSize(
                    width: lastOffset.width + translation.width,
                    height: lastOffset.height + translation.height,
                )
            }
            .onEnded { _ in
                lastOffset = offset
            }
    }

    private var magnificationGesture: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                let newScale = baseScale * value
                currentScale = min(max(1.0, newScale), 4.0)
            }
            .onEnded { _ in
                baseScale = currentScale
            }
    }

    private func toggleZoom() {
        if currentScale < 2.0 {
            currentScale = 2.5
        } else {
            currentScale = 1.0
            offset = .zero
            lastOffset = .zero
        }
        baseScale = currentScale
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

private extension View {
    @ViewBuilder
    func imagePreviewSheet(previewingImage: Binding<ImagePreview?>) -> some View {
        fullScreenCover(item: previewingImage) { payload in
            MessageImageViewer(url: payload.url)
        }
    }
}
