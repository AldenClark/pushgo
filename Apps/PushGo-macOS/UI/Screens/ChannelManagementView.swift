import AppKit
import SwiftUI

struct ChannelManagementView: View {
    @Environment(AppEnvironment.self) private var environment: AppEnvironment
    @Environment(LocalizationManager.self) private var localizationManager: LocalizationManager
    @State private var pendingRemoval: ChannelSubscription?
    @State private var isRemoving = false
    @State private var pendingRename: ChannelSubscription?
    @State private var renameAlias: String = ""
    @State private var isRenaming = false
    @State private var isShowingRemovalConfirmation = false
    @State private var isShowingRenameAlert = false

    @State private var isChannelEntrySheetPresented = false
    @State private var channelEntryMode: ChannelEntryMode = .create
    @State private var createChannelAlias = ""
    @State private var createChannelPassword = ""
    @State private var isCreateSubmitting = false
    @State private var subscribeChannelId = ""
    @State private var subscribeChannelPassword = ""
    @State private var isSubscribeSubmitting = false

    var body: some View {
        navigationContainer {
            Group {
                if environment.channelSubscriptions.isEmpty {
                    EntityOnboardingEmptyView(
                        kind: .channels,
                        channelPrimaryAction: {
                            presentChannelEntrySheet()
                        }
                    )
                    .accessibilityIdentifier("state.channels.empty")
                } else {
                    ScrollView {
                        VStack(spacing: 12) {
                            channelList
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 20)
                    }
                }
            }
            .background(channelBackgroundColor)
            .navigationTitle(localizationManager.localized("channels"))
            .toolbar { channelToolbarContent }
            .confirmationDialog(
                pendingRemoval.map { localizationManager.localized("unsubscribe_channel_title", $0.displayName) } ?? "",
                isPresented: $isShowingRemovalConfirmation,
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
                isPresented: $isShowingRenameAlert
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
                    await environment.syncSubscriptionsOnChannelListEntry()
                }
            }
            .onChange(of: isShowingRemovalConfirmation) { _, isPresented in
                if !isPresented {
                    pendingRemoval = nil
                }
            }
            .onChange(of: isShowingRenameAlert) { _, isPresented in
                if !isPresented {
                    pendingRename = nil
                }
            }
        }
        .accessibilityIdentifier("screen.channels")
        .sheet(
            isPresented: $isChannelEntrySheetPresented,
            onDismiss: resetChannelEntrySheetState
        ) {
            channelEntrySheet
        }
    }

    @ToolbarContentBuilder
    private var channelToolbarContent: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            channelAddButton
        }
    }

    private var channelAddButton: some View {
        Button {
            presentChannelEntrySheet()
        } label: {
            Image(systemName: "plus")
        }
        .accessibilityLabel(localizationManager.localized("add_channel"))
        .accessibilityIdentifier("action.channels.add")
    }

    private var channelBackgroundColor: Color {
        Color.platformGroupedBackground
    }

    private var channelList: some View {
        ForEach(environment.channelSubscriptions) { subscription in
            channelRow(subscription)
        }
    }

    private func channelRow(_ subscription: ChannelSubscription) -> some View {
        let name = subscription.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let channelId = subscription.channelId.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = name.isEmpty ? channelId : name

        return HStack(alignment: .center, spacing: 12) {
            Button {
                copyChannelId(channelId)
            } label: {
                HStack(alignment: .center, spacing: 16) {
                    AppIconTile(
                        systemName: "dot.radiowaves.left.and.right",
                        size: 38,
                        cornerRadius: 19,
                        font: .title3.weight(.semibold)
                    )

                    VStack(alignment: .leading, spacing: 4) {
                        Text(displayName)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .truncationMode(.tail)

                        if !name.isEmpty {
                            Text(channelId)
                                .font(.caption2.monospaced())
                                .foregroundStyle(Color.appTextSecondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }

                    Spacer(minLength: 12)
                }
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .accessibilityIdentifier("channel.row.\(channelId)")

            Menu {
                Button {
                    beginRename(subscription)
                } label: {
                    Label(localizationManager.localized("rename_channel"), systemImage: "pencil")
                }

                Button(role: .destructive) {
                    pendingRemoval = subscription
                    isShowingRemovalConfirmation = true
                } label: {
                    Label(localizationManager.localized("unsubscribe_channel"), systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis.circle.fill")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Color.appTextSecondary)
                    .frame(width: 32, height: 32)
                    .background(
                        Circle()
                            .fill(Color.appSurfaceSunken)
                    )
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 14)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.platformCardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.appCardBorder, lineWidth: 1)
        )
        .disabled(isRemoving || isRenaming)
    }

    private var isCreatePasswordValid: Bool {
        (try? ChannelPasswordValidator.validate(createChannelPassword)) != nil
    }

    private var isSubscribePasswordValid: Bool {
        (try? ChannelPasswordValidator.validate(subscribeChannelPassword)) != nil
    }

    private var canSubmitCreateSheet: Bool {
        !isCreateSubmitting
        && !createChannelAlias.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        && !createChannelPassword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        && isCreatePasswordValid
    }

    private var canSubmitSubscribeSheet: Bool {
        !isSubscribeSubmitting
        && !subscribeChannelId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        && !subscribeChannelPassword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        && isSubscribePasswordValid
    }

    private var canSubmitChannelEntry: Bool {
        switch channelEntryMode {
        case .create:
            return canSubmitCreateSheet
        case .subscribe:
            return canSubmitSubscribeSheet
        }
    }

    private var isChannelEntrySubmitting: Bool {
        switch channelEntryMode {
        case .create:
            return isCreateSubmitting
        case .subscribe:
            return isSubscribeSubmitting
        }
    }

    private var channelEntryConfirmTitle: String {
        switch channelEntryMode {
        case .create:
            return localizationManager.localized("create_channel")
        case .subscribe:
            return localizationManager.localized("subscribe_channel")
        }
    }

    @ViewBuilder
    private var channelEntryFields: some View {
        switch channelEntryMode {
        case .create:
            AppFormField(titleText: localizationManager.localized("channel_name")) {
                TextField(
                    "",
                    text: $createChannelAlias,
                    prompt: AppFieldPrompt.text(localizationManager.localized("channel_name_placeholder"))
                )
                .textFieldStyle(.plain)
                .autocorrectionDisabled(true)
            }

            AppFormField(titleText: localizationManager.localized("channel_password")) {
                SecureField(
                    "",
                    text: $createChannelPassword,
                    prompt: AppFieldPrompt.text(localizationManager.localized("channel_password_placeholder"))
                )
                .textFieldStyle(.plain)
                .autocorrectionDisabled(true)
            }

            if !createChannelPassword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               !isCreatePasswordValid
            {
                Text(localizationManager.localized("channel_password_invalid_length"))
                    .font(.footnote)
                    .foregroundStyle(AppSemanticTone.danger.foreground)
            }
        case .subscribe:
            AppFormField(titleText: localizationManager.localized("channel_id")) {
                TextField(
                    "",
                    text: $subscribeChannelId,
                    prompt: AppFieldPrompt.text(localizationManager.localized("channel_id_placeholder"))
                )
                .textFieldStyle(.plain)
                .autocorrectionDisabled(true)
            }

            AppFormField(titleText: localizationManager.localized("channel_password")) {
                SecureField(
                    "",
                    text: $subscribeChannelPassword,
                    prompt: AppFieldPrompt.text(localizationManager.localized("channel_password_placeholder"))
                )
                .textFieldStyle(.plain)
                .autocorrectionDisabled(true)
            }

            if !subscribeChannelPassword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               !isSubscribePasswordValid
            {
                Text(localizationManager.localized("channel_password_invalid_length"))
                    .font(.footnote)
                    .foregroundStyle(AppSemanticTone.danger.foreground)
            }
        }
    }

    private var channelEntryActionButtons: some View {
        HStack(spacing: 12) {
            Spacer(minLength: 0)

            AppActionButton(
                title: localizationManager.localized("cancel"),
                variant: .secondary,
                fullWidth: false
            ) {
                dismissChannelEntrySheet()
            }
            .disabled(isChannelEntrySubmitting)
            .accessibilityIdentifier("action.channels.entry.cancel")

            AppActionButton(
                text: Text(channelEntryConfirmTitle).fontWeight(.semibold),
                variant: .primary,
                isLoading: isChannelEntrySubmitting,
                fullWidth: false
            ) {
                Task { await submitChannelEntryFromSheet() }
            }
            .disabled(!canSubmitChannelEntry)
            .accessibilityIdentifier("action.channels.entry.submit")
        }
    }

    private var channelEntrySheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Picker("", selection: $channelEntryMode) {
                Text(localizationManager.localized("create_channel"))
                    .tag(ChannelEntryMode.create)
                Text(localizationManager.localized("subscribe_channel"))
                    .tag(ChannelEntryMode.subscribe)
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("select.channels.entry.mode")
            .disabled(isChannelEntrySubmitting)

            channelEntryFields

            channelEntryActionButtons
        }
        .padding(20)
        .frame(width: 460)
    }

    private func presentChannelEntrySheet() {
        resetChannelEntrySheetInputs()
        channelEntryMode = .create
        isChannelEntrySheetPresented = true
    }

    private func resetChannelEntrySheetInputs() {
        createChannelAlias = ""
        createChannelPassword = ""
        subscribeChannelId = ""
        subscribeChannelPassword = ""
        isCreateSubmitting = false
        isSubscribeSubmitting = false
    }

    @MainActor
    private func resetChannelEntrySheetState() {
        resetChannelEntrySheetInputs()
        channelEntryMode = .create
    }

    @MainActor
    private func dismissChannelEntrySheet() {
        isChannelEntrySheetPresented = false
        resetChannelEntrySheetState()
    }

    @MainActor
    private func submitChannelEntryFromSheet() async {
        switch channelEntryMode {
        case .create:
            await createChannelFromSheet()
        case .subscribe:
            await subscribeChannelFromSheet()
        }
    }

    @MainActor
    private func createChannelFromSheet() async {
        guard canSubmitCreateSheet else { return }
        isCreateSubmitting = true
        defer { isCreateSubmitting = false }

        do {
            let result = try await environment.createChannel(
                alias: createChannelAlias.trimmingCharacters(in: .whitespacesAndNewlines),
                password: createChannelPassword.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            dismissChannelEntrySheet()
            let messageKey = result.created ? "channel_created_and_subscribed" : "channel_subscribed"
            environment.showToast(
                message: localizationManager.localized(messageKey),
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
    private func subscribeChannelFromSheet() async {
        guard canSubmitSubscribeSheet else { return }
        isSubscribeSubmitting = true
        defer { isSubscribeSubmitting = false }

        do {
            _ = try await environment.subscribeChannel(
                channelId: subscribeChannelId.trimmingCharacters(in: .whitespacesAndNewlines),
                password: subscribeChannelPassword.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            dismissChannelEntrySheet()
            environment.showToast(
                message: localizationManager.localized("channel_subscribed"),
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

    private func copyChannelId(_ value: String) {
        PushGoSystemInteraction.copyTextToPasteboard(value)
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
        isShowingRenameAlert = true
    }
}

private enum ChannelEntryMode: Hashable {
    case create
    case subscribe
}
