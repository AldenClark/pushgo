import SwiftUI

struct WatchMessageDetailScreen: View {
    @Environment(AppEnvironment.self) private var environment: AppEnvironment
    @Environment(LocalizationManager.self) private var localizationManager: LocalizationManager

    let messageId: String
    let viewModel: WatchLightStoreViewModel

    @State private var showDeleteConfirmation = false
    @State private var deletionTarget: WatchMessageDeletionTarget?
    @State private var didLoad = false

    private var message: WatchLightMessage? {
        viewModel.message(messageId: messageId)
    }

    var body: some View {
        List {
            if let message {
                if let error = viewModel.messageError {
                    WatchEntityLoadErrorState(
                        message: error.errorDescription ?? error.localizedDescription,
                        retry: { Task { @MainActor in await viewModel.reload() } }
                    )
                    .accessibilityIdentifier("state.message.delete_error")
                }
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(message.title)
                            .font(.headline)
                        Text(message.receivedAt.formatted(date: .complete, time: .standard))
                            .font(.caption2)
                            .foregroundStyle(Color.appTextSecondary)
                        watchMessageSeverityBadge(for: message.severity)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 6)
                }

                Section {
                    Text(message.body.isEmpty ? " " : message.body)
                        .padding(.vertical, 6)
                }

                if let imageURL = message.imageURL {
                    Section(localizationManager.localized("image")) {
                        WatchCachedImage(
                            url: imageURL,
                            owner: .watchMessage(localID: message.messageId),
                            accessibilityLabel: localizationManager.localized("image")
                        ) { phase in
                            switch phase {
                            case let .success(image):
                                image
                                    .resizable()
                                    .scaledToFit()
                                    .frame(height: 90)
                                    .accessibilityElement()
                                    .accessibilityLabel(localizationManager.localized("image"))
                                    .accessibilityIdentifier("image.message.\(message.messageId)")
                            case .empty, .failure:
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(Color.appSurfaceSunken)
                                    .frame(height: 90)
                            }
                        }
                    }
                }

                if let url = message.url {
                    Section {
                        Link(localizationManager.localized("open_link"), destination: url)
                            .accessibilityIdentifier("action.message.open_link")
                    }
                }

                Section {
                    if !message.isRead {
                        Button {
                            Task { @MainActor in
                                await viewModel.markMessageRead(message)
                            }
                        } label: {
                            Label(
                                localizationManager.localized("mark_as_read"),
                                systemImage: "envelope.open"
                            )
                        }
                    }

                    Button(role: .destructive) {
                        deletionTarget = WatchMessageDeletionTarget(message: message, context: environment.messageDeletionContext, config: environment.serverConfig?.normalized())
                        showDeleteConfirmation = true
                    } label: {
                        Label(localizationManager.localized("delete"), systemImage: "trash")
                    }
                    .disabled(viewModel.deletionInProgress)
                    .accessibilityIdentifier("action.message.delete")
                }
            } else {
                Section {
                    Text(localizationManager.localized("placeholder_no_unread_messages"))
                        .font(.footnote)
                        .foregroundStyle(Color.appTextSecondary)
                }
            }
        }
        .accessibilityIdentifier("screen.message.detail")
        .navigationTitle(localizationManager.localized("messages"))
        .alert(
            localizationManager.localized("are_you_sure_you_want_to_delete_this_message_once_deleted_it_cannot_be_recovered"),
            isPresented: $showDeleteConfirmation,
            presenting: deletionTarget
        ) { target in
            Button(localizationManager.localized("delete"), role: .destructive) {
                deletionTarget = nil
                Task { @MainActor in
                    await viewModel.deleteMessage(target)
                }
            }
            .accessibilityIdentifier("action.message.delete.confirm")
            Button(localizationManager.localized("cancel"), role: .cancel) {
                deletionTarget = nil
            }
        }
        .onChange(of: environment.pendingMessageDeletion?.id) { _, _ in
            presentPendingDeletion()
        }
        .onAppear {
            presentPendingDeletion()
            guard !didLoad else { return }
            didLoad = true
            if !showDeleteConfirmation, let message, !message.isRead {
                Task { @MainActor in
                    await viewModel.markMessageRead(message)
                }
            }
        }
#if DEBUG
        .task(id: automationDetailSignature) {
            guard let message else { return }
            PushGoWatchAutomationRuntime.shared.recordMessageDetailReady(message: message)
        }
#endif
    }

    private func presentPendingDeletion() {
        guard let target = environment.pendingMessageDeletion,
              target.message.messageId == messageId else { return }
        environment.pendingMessageDeletion = nil
        guard !showDeleteConfirmation, !viewModel.deletionInProgress else { return }
        deletionTarget = target
        showDeleteConfirmation = true
    }

    private var automationDetailSignature: String {
        guard let message else { return "message:none" }
        return "\(message.messageId)|\(message.body.count)|\(message.title.count)|\(message.isRead)"
    }

    @ViewBuilder
    private func watchMessageSeverityBadge(for severity: String?) -> some View {
        if let severity, !severity.isEmpty {
            Text(severity.capitalized)
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    Capsule(style: .continuous)
                        .fill(Color.appStateInfoBackground)
                )
                .foregroundStyle(Color.appStateInfoForeground)
        }
    }
}

#Preview {
    WatchMessageDetailScreen(messageId: "preview-message", viewModel: WatchLightStoreViewModel())
}
