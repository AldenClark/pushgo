import SwiftUI

struct ChannelManagementScreen: View {
    @Environment(AppEnvironment.self) private var environment: AppEnvironment
    @Environment(LocalizationManager.self) private var localizationManager: LocalizationManager
    @State private var pendingRemoval: ChannelSubscription?
    @State private var isRemoving = false
    @State private var pendingRename: ChannelSubscription?
    @State private var renameAlias: String = ""
    @State private var isRenaming = false

    @State private var isChannelEntrySheetPresented = false
    @State private var channelEntryMode: ChannelEntryMode = .create
    @State private var createChannelAlias = ""
    @State private var createChannelPassword = ""
    @State private var isCreateSubmitting = false
    @State private var channelEntryFocusTask: Task<Void, Never>?
    @FocusState private var channelEntryFocusedField: ChannelEntryField?
    @State private var subscribeChannelId = ""
    @State private var subscribeChannelPassword = ""
    @State private var isSubscribeSubmitting = false

    var body: some View {
        navigationContainer {
            channelManagementScaffold
        }
        .confirmationDialog(
            pendingRemoval.map { localizationManager.localized("unsubscribe_channel_title", $0.displayName) }
                ?? "",
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
        .sheet(
            isPresented: $isChannelEntrySheetPresented,
            onDismiss: resetChannelEntrySheetState
        ) {
            channelEntrySheet
        }
        .onAppear {
            Task { @MainActor in
                await environment.syncSubscriptionsOnChannelListEntry()
            }
        }
    }

    private var channelManagementScaffold: some View {
        Group {
            if environment.channelSubscriptions.isEmpty {
                EntityEmptyView(
                    iconName: "dot.radiowaves.left.and.right",
                    title: localizationManager.localized("channels_empty"),
                    subtitle: localizationManager.localized("channel_list_empty_hint")
                )
                .accessibilityIdentifier("state.channels.empty")
            } else {
                List {
                    channelList
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .background(Color(uiColor: .systemBackground))
            }
        }
        .background(Color(uiColor: .systemBackground))
        .navigationTitle(localizationManager.localized("channels"))
        .accessibilityIdentifier("screen.channels")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    presentChannelEntrySheet()
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel(localizationManager.localized("add_channel"))
                .accessibilityIdentifier("action.channels.add")

                NavigationLink {
                    SettingsView(embedInNavigationContainer: false)
                        .pushgoHideTabBarForDetail()
                } label: {
                    Image(systemName: "gearshape")
                }
                .accessibilityLabel(localizationManager.localized("settings"))
                .accessibilityIdentifier("action.channels.settings")
            }
        }
    }

    private var channelList: some View {
        Section {
            ForEach(environment.channelSubscriptions) { subscription in
                channelRow(subscription)
            }
        }
        .listSectionSeparator(.hidden)
    }

    private func channelRow(_ subscription: ChannelSubscription) -> some View {
        let name = subscription.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let channelId = subscription.channelId.trimmingCharacters(in: .whitespacesAndNewlines)

        return HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(name.isEmpty ? channelId : name)
                    .font(.subheadline.weight(.semibold))
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

        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .accessibilityIdentifier("channel.row.\(channelId)")
        .onTapGesture {
            copyChannelId(channelId)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button {
                beginRename(subscription)
            } label: {
                Label(localizationManager.localized("rename_channel"), systemImage: "pencil")
            }
            .tint(.blue)

            Button(role: .destructive) {
                pendingRemoval = subscription
            } label: {
                Label(localizationManager.localized("unsubscribe_channel"), systemImage: "trash")
            }
        }
        .disabled(isRemoving || isRenaming)
    }

    private var isCreateDialogPasswordValid: Bool {
        (try? ChannelPasswordValidator.validate(createChannelPassword)) != nil
    }

    private var isSubscribeDialogPasswordValid: Bool {
        (try? ChannelPasswordValidator.validate(subscribeChannelPassword)) != nil
    }

    private var canSubmitCreateSheet: Bool {
        !isCreateSubmitting
        && !createChannelAlias.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        && !createChannelPassword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        && isCreateDialogPasswordValid
    }

    private var canSubmitSubscribeSheet: Bool {
        !isSubscribeSubmitting
        && !subscribeChannelId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        && !subscribeChannelPassword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        && isSubscribeDialogPasswordValid
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
            VStack(alignment: .leading, spacing: 14) {
                AppFormField(
                    titleText: localizationManager.localized("channel_name")
                ) {
                    TextField(
                        "",
                        text: $createChannelAlias,
                        prompt: AppFieldPrompt.text(localizationManager.localized("channel_name_placeholder"))
                    )
                    .textFieldStyle(.plain)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                    .focused($channelEntryFocusedField, equals: .createAlias)
                    .submitLabel(.next)
                    .onAppear {
                        if channelEntryMode == .create {
                            focusChannelEntryFirstField(for: .create)
                        }
                    }
                    .onSubmit {
                        channelEntryFocusedField = .createPassword
                    }
                    .disabled(isCreateSubmitting)
                }

                AppFormField(
                    titleText: localizationManager.localized("channel_password")
                ) {
                    SecureField(
                        "",
                        text: $createChannelPassword,
                        prompt: AppFieldPrompt.text(localizationManager.localized("channel_password_placeholder"))
                    )
                    .textFieldStyle(.plain)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                    .focused($channelEntryFocusedField, equals: .createPassword)
                    .submitLabel(.go)
                    .onSubmit {
                        Task { await submitChannelEntryFromSheet() }
                    }
                    .disabled(isCreateSubmitting)
                }

                if !createChannelPassword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   !isCreateDialogPasswordValid
                {
                    Text(localizationManager.localized("channel_password_invalid_length"))
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
        case .subscribe:
            VStack(alignment: .leading, spacing: 14) {
                AppFormField(
                    titleText: localizationManager.localized("channel_id")
                ) {
                    TextField(
                        "",
                        text: $subscribeChannelId,
                        prompt: AppFieldPrompt.text(localizationManager.localized("channel_id_placeholder"))
                    )
                    .textFieldStyle(.plain)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                    .focused($channelEntryFocusedField, equals: .subscribeChannelID)
                    .submitLabel(.next)
                    .onAppear {
                        if channelEntryMode == .subscribe {
                            focusChannelEntryFirstField(for: .subscribe)
                        }
                    }
                    .onSubmit {
                        channelEntryFocusedField = .subscribePassword
                    }
                    .disabled(isSubscribeSubmitting)
                }

                AppFormField(
                    titleText: localizationManager.localized("channel_password")
                ) {
                    SecureField(
                        "",
                        text: $subscribeChannelPassword,
                        prompt: AppFieldPrompt.text(localizationManager.localized("channel_password_placeholder"))
                    )
                    .textFieldStyle(.plain)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                    .focused($channelEntryFocusedField, equals: .subscribePassword)
                    .submitLabel(.go)
                    .onSubmit {
                        Task { await submitChannelEntryFromSheet() }
                    }
                    .disabled(isSubscribeSubmitting)
                }

                if !subscribeChannelPassword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   !isSubscribeDialogPasswordValid
                {
                    Text(localizationManager.localized("channel_password_invalid_length"))
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
        }
    }

    private var channelEntryActionButtons: some View {
        AppActionButton(
            variant: .primary,
            isLoading: isChannelEntrySubmitting
        ) {
            channelEntryFocusedField = nil
            Task { await submitChannelEntryFromSheet() }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: channelEntryMode == .create ? "plus.circle.fill" : "dot.radiowaves.left.and.right")
                Text(channelEntryConfirmTitle)
                    .fontWeight(.semibold)
            }
        }
        .disabled(!canSubmitChannelEntry)
        .accessibilityIdentifier("action.channels.entry.submit")
    }

    private var channelEntrySheet: some View {
        VStack(alignment: .leading, spacing: 12) {
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
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
        .onAppear {
            focusChannelEntryFirstField(for: channelEntryMode)
        }
        .onChange(of: channelEntryMode) { _, mode in
            focusChannelEntryFirstField(for: mode)
        }
        .onDisappear {
            channelEntryFocusTask?.cancel()
            channelEntryFocusTask = nil
        }
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
        channelEntryFocusTask?.cancel()
        channelEntryFocusTask = nil
        resetChannelEntrySheetInputs()
        channelEntryMode = .create
        channelEntryFocusedField = nil
    }

    @MainActor
    private func focusChannelEntryFirstField(for mode: ChannelEntryMode) {
        channelEntryFocusTask?.cancel()
        channelEntryFocusedField = nil

        let target: ChannelEntryField = switch mode {
        case .create:
            .createAlias
        case .subscribe:
            .subscribeChannelID
        }

        channelEntryFocusTask = Task { @MainActor in
            for delay in [0 as UInt64, 120_000_000, 240_000_000] {
                if delay > 0 {
                    try? await Task.sleep(nanoseconds: delay)
                }
                guard !Task.isCancelled,
                      isChannelEntrySheetPresented,
                      channelEntryMode == mode
                else { return }
                channelEntryFocusedField = target
            }
        }
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
                password: createChannelPassword
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
                password: subscribeChannelPassword
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
    }
}

private enum ChannelEntryMode: Hashable {
    case create
    case subscribe
}

private enum ChannelEntryField: Hashable {
    case createAlias
    case createPassword
    case subscribeChannelID
    case subscribePassword
}
