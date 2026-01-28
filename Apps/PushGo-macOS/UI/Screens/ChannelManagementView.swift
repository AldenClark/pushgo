import AppKit
import SwiftUI

struct ChannelManagementView: View {
    @Environment(\.appEnvironment) private var environment: AppEnvironment
    @Environment(LocalizationManager.self) private var localizationManager: LocalizationManager
    @State private var pendingRemoval: ChannelSubscription?
    @State private var isRemoving = false
    @State private var pendingRename: ChannelSubscription?
    @State private var renameAlias: String = ""
    @State private var isRenaming = false
    @State private var channelModal: ChannelModal?
    @State private var autoCleanupEnabled = false

    var body: some View {
        navigationContainer {
            List {
                channelList
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
            .background(channelBackgroundColor)
            .navigationTitle(localizationManager.localized("channels"))
            .toolbar { channelToolbarContent }
            .confirmationDialog(
                pendingRemoval.map { localizationManager.localized("unsubscribe_channel_title", $0.displayName) } ?? "",
                isPresented: Binding(
                    get: { pendingRemoval != nil },
                    set: { if !$0 { pendingRemoval = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button(role: .destructive) {
                    if let target = pendingRemoval {
                        Task { await removeChannel(target, deleteHistory: true) }
                    }
                } label: {
                    Text(localizationManager.localized("unsubscribe_and_delete_history"))
                }
                Button {
                    if let target = pendingRemoval {
                        Task { await removeChannel(target, deleteHistory: false) }
                    }
                } label: {
                    Text(localizationManager.localized("unsubscribe_keep_history"))
                }
                Button(role: .cancel) {
                } label: {
                    Text(localizationManager.localized("cancel"))
                }
            }
            .alert(
                localizationManager.localized("rename_channel"),
                isPresented: Binding(
                    get: { pendingRename != nil },
                    set: { if !$0 { pendingRename = nil } }
                )
            ) {
                TextField(
                    localizationManager.localized("channel_name_placeholder"),
                    text: $renameAlias
                )
                Button(localizationManager.localized("confirm")) {
                    if let target = pendingRename {
                        Task { await renameChannel(target) }
                    }
                }
                .disabled(isRenaming || renameAlias.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button(localizationManager.localized("cancel"), role: .cancel) {
                    pendingRename = nil
                }
            }
            .onAppear {
                Task { @MainActor in
                    await environment.refreshChannelSubscriptions()
                }
            }
            .task {
                autoCleanupEnabled = await environment.resolvedAutoCleanupEnabled()
            }
        }
        .overlay(channelModalOverlay)
        .animation(.spring(response: 0.28, dampingFraction: 0.85), value: channelModal != nil)
    }

    @ToolbarContentBuilder
    private var channelToolbarContent: some ToolbarContent {
        if #available(macOS 26.0, *) {
            ToolbarItem(placement: .primaryAction) {
                channelAddMenu
            }
        } else {
            ToolbarItem(placement: .navigation) {
                Text(localizationManager.localized("channels"))
                    .font(.headline.weight(.semibold))
            }
            ToolbarItem(placement: .primaryAction) {
                channelAddMenu
            }
        }
    }

    private var channelAddMenu: some View {
        Menu {
            Button(localizationManager.localized("create_channel")) {
                presentChannelModal(.create)
            }
            Button(localizationManager.localized("subscribe_channel")) {
                presentChannelModal(.subscribe)
            }
        } label: {
            Image(systemName: "plus")
        }
        .accessibilityLabel(localizationManager.localized("add_channel"))
        .menuIndicator(.hidden)
    }

    private var channelBackgroundColor: Color {
        if #available(macOS 26.0, *) {
            Color.platformGroupedBackground
        } else {
            Color.messageListBackground
        }
    }

    @ViewBuilder
    private var channelModalOverlay: some View {
        if let channelModal {
            ZStack {
                Color.black.opacity(0.12)
                    .ignoresSafeArea()
                    .onTapGesture { closeChannelModal() }

                channelModalContent(for: channelModal)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(Color.primary.opacity(0.12), lineWidth: 1)
                    )
                    .shadow(radius: 18, x: 0, y: 10)
                    .padding(24)
            }
            .transition(.opacity)
            .zIndex(2)
        }
    }

    @ViewBuilder
    private func channelModalContent(for modal: ChannelModal) -> some View {
        switch modal {
        case .create:
            ChannelCreateSheet(onSuccess: { closeChannelModal() })
        case .subscribe:
            ChannelSubscribeSheet(onSuccess: { closeChannelModal() })
        }
    }

    private func presentChannelModal(_ modal: ChannelModal) {
        channelModal = modal
    }

    private func closeChannelModal() {
        channelModal = nil
    }

    private var channelList: some View {
        Section {
            if environment.channelSubscriptions.isEmpty {
                emptyStateCard
            } else {
                ForEach(environment.channelSubscriptions) { subscription in
                    channelRow(subscription)
                }
            }
        }
    }

    private var emptyStateCard: some View {
        VStack(alignment: .center, spacing: 14) {
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.12))
                Image(systemName: "tray")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
            }
            .frame(width: 44, height: 44)

            Text(localizationManager.localized("channels_empty"))
                .font(.headline)
                .foregroundStyle(.primary)
                .multilineTextAlignment(.center)

            HStack(spacing: 12) {
                Button {
                    presentChannelModal(.create)
                } label: {
                    Label(localizationManager.localized("create_channel"), systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)

                Button {
                    presentChannelModal(.subscribe)
                } label: {
                    Label(localizationManager.localized("subscribe_channel"), systemImage: "link")
                }
                .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
        .padding(.horizontal, 16)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.platformCardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.primary.opacity(0.05), lineWidth: 1)
        )
        .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
    }

    private func channelRow(_ subscription: ChannelSubscription) -> some View {
        let name = subscription.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let channelId = subscription.channelId.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = name.isEmpty ? channelId : name

        return HStack(alignment: .center, spacing: 16) {
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.14))
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
            }
            .frame(width: 38, height: 38)

            VStack(alignment: .leading, spacing: 4) {
                Text(displayName)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                if !name.isEmpty {
                    Text(channelId)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer(minLength: 12)

            Menu {
                Button {
                    beginRename(subscription)
                } label: {
                    Label(localizationManager.localized("rename_channel"), systemImage: "pencil")
                }

                Button(role: .destructive) {
                    pendingRemoval = subscription
                } label: {
                    Label(localizationManager.localized("unsubscribe_channel"), systemImage: "trash")
                }

                if autoCleanupEnabled {
                    Button {
                        Task {
                            await updateChannelAutoCleanup(subscription)
                        }
                    } label: {
                        let labelKey = subscription.autoCleanupEnabled
                            ? "disable_auto_cleanup"
                            : "enable_auto_cleanup"
                        Label(localizationManager.localized(labelKey), systemImage: "sparkles")
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle.fill")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 32, height: 32)
                    .background(
                        Circle()
                            .fill(Color.primary.opacity(0.06))
                    )
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.platformCardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        .contentShape(Rectangle())
        .onTapGesture {
            copyChannelId(channelId)
        }
        .disabled(isRemoving || isRenaming)
    }

    @MainActor
    private func removeChannel(_ subscription: ChannelSubscription, deleteHistory: Bool) async {
        guard !isRemoving else { return }
        isRemoving = true
        defer {
            pendingRemoval = nil
            isRemoving = false
        }
        pendingRename = nil

        do {
            let removedCount = try await environment.unsubscribeChannel(
                channelId: subscription.channelId,
                deleteLocalMessages: deleteHistory
            )
            if deleteHistory {
                environment.showToast(
                    message: localizationManager.localized("channel_unsubscribed_and_deleted", removedCount),
                    style: .success,
                    duration: 1.8
                )
            } else {
                environment.showToast(
                    message: localizationManager.localized("channel_unsubscribed"),
                    style: .success,
                    duration: 1.5
                )
            }
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            environment.showToast(
                message: message,
                style: .error,
                duration: 2.5
            )
        }
    }

    @MainActor
    private func renameChannel(_ subscription: ChannelSubscription) async {
        guard !isRenaming else { return }
        isRenaming = true
        defer {
            isRenaming = false
            pendingRename = nil
            renameAlias = ""
        }

        do {
            let trimmedAlias = renameAlias.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedAlias.isEmpty else { return }
            if trimmedAlias == subscription.displayName {
                return
            }
            try await environment.renameChannel(
                channelId: subscription.channelId,
                alias: trimmedAlias
            )
            environment.showToast(
                message: localizationManager.localized("channel_renamed"),
                style: .success,
                duration: 1.5
            )
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            environment.showToast(
                message: message,
                style: .error,
                duration: 2.5
            )
        }
    }

    @MainActor
    private func updateChannelAutoCleanup(_ subscription: ChannelSubscription) async {
        do {
            try await environment.setChannelAutoCleanupEnabled(
                channelId: subscription.channelId,
                isEnabled: !subscription.autoCleanupEnabled
            )
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            environment.showToast(
                message: message,
                style: .error,
                duration: 2.5
            )
        }
    }

    private func copyChannelId(_ value: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(value, forType: .string)
        environment.showToast(
            message: localizationManager.localized("channel_id_copied"),
            style: .success,
            duration: 1.2
        )
    }

    private func beginRename(_ subscription: ChannelSubscription) {
        guard !isRenaming else { return }
        renameAlias = subscription.displayName
        pendingRename = subscription
    }
}

private enum ChannelModal: Identifiable {
    case create
    case subscribe

    var id: String {
        switch self {
        case .create:
            return "create"
        case .subscribe:
            return "subscribe"
        }
    }
}

private struct ChannelCreateSheet: View {
    let onSuccess: (() -> Void)?

    @Environment(\.appEnvironment) private var environment: AppEnvironment
    @Environment(LocalizationManager.self) private var localizationManager: LocalizationManager
    @State private var channelAlias: String = ""
    @State private var channelPassword: String = ""
    @State private var isPasswordVisible = false
    @State private var isSaving = false
    @State private var errorMessage: String?
    private var isPasswordValid: Bool {
        (try? ChannelPasswordValidator.validate(channelPassword)) != nil
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let errorMessage {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }

                    AppFormField(titleText: localizationManager.localized("channel_name")) {
                        TextField(
                            "",
                            text: $channelAlias,
                            prompt: AppFieldPrompt.text(localizationManager.localized("channel_name_placeholder"))
                        )
                        .textFieldStyle(.plain)
                        .autocorrectionDisabled(true)
                    }

                    AppFormField(titleText: localizationManager.localized("channel_password")) {
                        HStack(spacing: 10) {
                            Group {
                                if isPasswordVisible {
                                    TextField(
                                        "",
                                        text: $channelPassword,
                                        prompt: AppFieldPrompt.text(localizationManager.localized("channel_password_placeholder"))
                                    )
                                } else {
                                    SecureField(
                                        "",
                                        text: $channelPassword,
                                        prompt: AppFieldPrompt.text(localizationManager.localized("channel_password_placeholder"))
                                    )
                                }
                            }
                            .textFieldStyle(.plain)
                            .autocorrectionDisabled(true)

                            Button {
                                isPasswordVisible.toggle()
                            } label: {
                                Image(systemName: isPasswordVisible ? "eye.slash" : "eye")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.appPlain)
                            .accessibilityLabel(LocalizedStringKey(isPasswordVisible ? "hide_key" : "show_key"))
                        }
                    }
                    if !channelPassword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                       !isPasswordValid
                    {
                        Text(localizationManager.localized("channel_password_invalid_length"))
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }

                    Button {
                        Task { await createChannel() }
                    } label: {
                        if isSaving {
                            ProgressView()
                                .frame(maxWidth: .infinity)
                        } else {
                            Text(localizationManager.localized("confirm"))
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .appButtonHeight()
                    .disabled(isSaving
                        || channelAlias.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || channelPassword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || !isPasswordValid)
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color.platformGroupedBackground)
            .navigationTitle(localizationManager.localized("create_channel"))
        }
        .frame(width: 420, height: 320)
    }

    @MainActor
    private func createChannel() async {
        guard !isSaving else { return }
        isSaving = true
        defer { isSaving = false }

        do {
            let trimmedAlias = channelAlias.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedPassword = channelPassword.trimmingCharacters(in: .whitespacesAndNewlines)
            let result = try await environment.createChannel(
                alias: trimmedAlias,
                password: trimmedPassword
            )
            let messageKey = result.created ? "channel_created_and_subscribed" : "channel_subscribed"
            environment.showToast(
                message: localizationManager.localized(messageKey),
                style: .success,
                duration: 1.5
            )
            errorMessage = nil
            onSuccess?()
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            environment.showToast(
                message: message,
                style: .error,
                duration: 2.5
            )
            errorMessage = message
        }
    }
}

private struct ChannelSubscribeSheet: View {
    let onSuccess: (() -> Void)?

    @Environment(\.appEnvironment) private var environment: AppEnvironment
    @Environment(LocalizationManager.self) private var localizationManager: LocalizationManager
    @State private var channelId: String = ""
    @State private var channelPassword: String = ""
    @State private var isPasswordVisible = false
    @State private var isSaving = false
    @State private var errorMessage: String?
    private var isPasswordValid: Bool {
        (try? ChannelPasswordValidator.validate(channelPassword)) != nil
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let errorMessage {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }

                    AppFormField(titleText: localizationManager.localized("channel_id")) {
                        TextField(
                            "",
                            text: $channelId,
                            prompt: AppFieldPrompt.text(localizationManager.localized("channel_id_placeholder"))
                        )
                        .textFieldStyle(.plain)
                        .autocorrectionDisabled(true)
                    }

                    AppFormField(titleText: localizationManager.localized("channel_password")) {
                        HStack(spacing: 10) {
                            Group {
                                if isPasswordVisible {
                                    TextField(
                                        "",
                                        text: $channelPassword,
                                        prompt: AppFieldPrompt.text(localizationManager.localized("channel_password_placeholder"))
                                    )
                                } else {
                                    SecureField(
                                        "",
                                        text: $channelPassword,
                                        prompt: AppFieldPrompt.text(localizationManager.localized("channel_password_placeholder"))
                                    )
                                }
                            }
                            .textFieldStyle(.plain)
                            .autocorrectionDisabled(true)

                            Button {
                                isPasswordVisible.toggle()
                            } label: {
                                Image(systemName: isPasswordVisible ? "eye.slash" : "eye")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.appPlain)
                            .accessibilityLabel(LocalizedStringKey(isPasswordVisible ? "hide_key" : "show_key"))
                        }
                    }
                    if !channelPassword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                       !isPasswordValid
                    {
                        Text(localizationManager.localized("channel_password_invalid_length"))
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }

                    Button {
                        Task { await subscribeChannel() }
                    } label: {
                        if isSaving {
                            ProgressView()
                                .frame(maxWidth: .infinity)
                        } else {
                            Text(localizationManager.localized("confirm"))
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .appButtonHeight()
                    .disabled(isSaving
                        || channelId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || channelPassword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || !isPasswordValid)
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color.platformGroupedBackground)
            .navigationTitle(localizationManager.localized("subscribe_channel"))
        }
        .frame(width: 420, height: 320)
    }

    @MainActor
    private func subscribeChannel() async {
        guard !isSaving else { return }
        isSaving = true
        defer { isSaving = false }

        do {
            let trimmedId = channelId.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedPassword = channelPassword.trimmingCharacters(in: .whitespacesAndNewlines)
            _ = try await environment.subscribeChannel(
                channelId: trimmedId,
                password: trimmedPassword
            )
            environment.showToast(
                message: localizationManager.localized("channel_subscribed"),
                style: .success,
                duration: 1.5
            )
            errorMessage = nil
            onSuccess?()
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            environment.showToast(
                message: message,
                style: .error,
                duration: 2.5
            )
            errorMessage = message
        }
    }
}
