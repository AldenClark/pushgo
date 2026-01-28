import SwiftUI

struct WatchMessageDetailScreen: View {
    @Environment(LocalizationManager.self) private var localizationManager: LocalizationManager
    @State private var viewModel: MessageDetailViewModel
    @State private var showDeleteConfirmation = false
    @State private var didLoad = false

    init(messageId: UUID, message: PushMessage? = nil) {
        _viewModel = State(wrappedValue: MessageDetailViewModel(
            messageId: messageId,
            initialMessage: message
        ))
    }

    var body: some View {
        List {
            if let message = viewModel.message {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(message.title)
                            .font(.headline)
                        Text(message.receivedAt.formatted(date: .complete, time: .standard))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 6)
                }

                Section {
                    let resolvedBody = message.resolvedBody
                    MarkdownRenderer(text: resolvedBody.rawText, font: .body, foreground: .primary)
                        .padding(.vertical, 6)
                }

                if let url = message.url {
                    Section {
                        Link(localizationManager.localized("open_link"), destination: url)
                    }
                }

                Section {
                    if !message.isRead {
                        Button {
                            Task { await viewModel.markRead(true) }
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
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle(localizationManager.localized("messages"))
        .alert(isPresented: Binding(
            get: { viewModel.alertMessage != nil },
            set: { if !$0 { viewModel.alertMessage = nil } }
        )) {
            Alert(
                title: Text(viewModel.alertMessage ?? ""),
                dismissButton: .default(Text(localizationManager.localized("ok")))
            )
        }
        .alert(isPresented: $showDeleteConfirmation) {
            Alert(
                title: Text(localizationManager.localized(
                    "are_you_sure_you_want_to_delete_this_message_once_deleted_it_cannot_be_recovered"
                )),
                primaryButton: .destructive(Text(localizationManager.localized("delete"))) {
                    Task {
                        await viewModel.deleteMessage()
                    }
                },
                secondaryButton: .cancel(Text(localizationManager.localized("cancel")))
            )
        }
        .onAppear {
            guard !didLoad else { return }
            didLoad = true
            Task {
                viewModel.refresh()
                await viewModel.markAsReadIfNeeded()
            }
        }
    }
}

#Preview {
    WatchMessageDetailScreen(messageId: UUID())
}
