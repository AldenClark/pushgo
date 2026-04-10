import SwiftUI

struct WatchMessageDetailScreen: View {
    @Environment(LocalizationManager.self) private var localizationManager: LocalizationManager

    let messageId: String
    let viewModel: WatchLightStoreViewModel

    @State private var showDeleteConfirmation = false
    @State private var didLoad = false

    private var message: WatchLightMessage? {
        viewModel.message(messageId: messageId)
    }

    var body: some View {
        List {
            if let message {
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
                        AsyncImage(url: imageURL) { phase in
                            switch phase {
                            case let .success(image):
                                image
                                    .resizable()
                                    .scaledToFit()
                            default:
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
                        showDeleteConfirmation = true
                    } label: {
                        Label(localizationManager.localized("delete"), systemImage: "trash")
                    }
                }
            } else {
                Section {
                    Text(localizationManager.localized("placeholder_no_unread_messages"))
                        .font(.footnote)
                        .foregroundStyle(Color.appTextSecondary)
                }
            }
        }
        .navigationTitle(localizationManager.localized("messages"))
        .alert(isPresented: $showDeleteConfirmation) {
            Alert(
                title: Text(localizationManager.localized(
                    "are_you_sure_you_want_to_delete_this_message_once_deleted_it_cannot_be_recovered"
                )),
                primaryButton: .destructive(Text(localizationManager.localized("delete"))) {
                    guard let message else { return }
                    Task { @MainActor in
                        await viewModel.deleteMessage(message)
                    }
                },
                secondaryButton: .cancel(Text(localizationManager.localized("cancel")))
            )
        }
        .onAppear {
            guard !didLoad else { return }
            didLoad = true
            if let message, !message.isRead {
                Task { @MainActor in
                    await viewModel.markMessageRead(message)
                }
            }
        }
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
