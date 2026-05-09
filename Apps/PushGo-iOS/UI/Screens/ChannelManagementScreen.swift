import SwiftUI

struct ChannelManagementScreen: View {
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
    private let channelEntrySheetHeight: CGFloat = 348
    private let channelEntryFieldsMinHeight: CGFloat = 196

    var body: some View {
        navigationContainer {
            channelManagementScaffold
        }
        .confirmationDialog(
            pendingRemoval.map { localizationManager.localized("unsubscribe_channel_title", $0.displayName) }
                ?? "",
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
        .sheet(
            isPresented: $isChannelEntrySheetPresented,
            onDismiss: resetChannelEntrySheetState
        ) {
            channelEntrySheet
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
        .onAppear {
            Task { @MainActor in
                await environment.syncSubscriptionsOnChannelListEntry()
            }
        }
    }

    private var channelManagementScaffold: some View {
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
                List {
                    channelList
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .background(Color.appWindowBackground)
            }
        }
        .background(Color.appWindowBackground)
        .navigationTitle(localizationManager.localized("channels"))
        .navigationBarTitleDisplayMode(.large)
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

        return Button {
            copyChannelId(channelId)
        } label: {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(name.isEmpty ? channelId : name)
                        .font(.subheadline.weight(.semibold))
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
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .accessibilityIdentifier("channel.row.\(channelId)")
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button {
                beginRename(subscription)
            } label: {
                Label(localizationManager.localized("rename_channel"), systemImage: "pencil")
            }
            .tint(.appAccentPrimary)

            Button(role: .destructive) {
                pendingRemoval = subscription
                isShowingRemovalConfirmation = true
            } label: {
                Label(localizationManager.localized("unsubscribe_channel"), systemImage: "trash")
            }
        }
        .disabled(isRemoving || isRenaming)
    }

    private var canSubmitChannelEntry: Bool {
        switch channelEntryMode {
        case .create:
            return !isCreateSubmitting
        case .subscribe:
            return !isSubscribeSubmitting
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
        ZStack(alignment: .topLeading) {
            channelEntryCreateFields
                .opacity(channelEntryMode == .create ? 1 : 0)
                .allowsHitTesting(channelEntryMode == .create)
                .accessibilityHidden(channelEntryMode != .create)

            channelEntrySubscribeFields
                .opacity(channelEntryMode == .subscribe ? 1 : 0)
                .allowsHitTesting(channelEntryMode == .subscribe)
                .accessibilityHidden(channelEntryMode != .subscribe)
        }
        .frame(maxWidth: .infinity, minHeight: channelEntryFieldsMinHeight, alignment: .topLeading)
        .transaction { transaction in
            transaction.animation = nil
        }
    }

    private var channelEntryCreateFields: some View {
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
                .submitLabel(.next)
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
                .submitLabel(.go)
                .onSubmit {
                    Task { await submitChannelEntryFromSheet() }
                }
                .disabled(isCreateSubmitting)
            }

        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var channelEntrySubscribeFields: some View {
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
                .submitLabel(.next)
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
                .submitLabel(.go)
                .onSubmit {
                    Task { await submitChannelEntryFromSheet() }
                }
                .disabled(isSubscribeSubmitting)
            }

        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var channelEntryActionButtons: some View {
        AppActionButton(
            variant: .primary,
            isLoading: isChannelEntrySubmitting
        ) {
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
        .padding(.top, 22)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: channelEntrySheetHeight, alignment: .topLeading)
        .transaction { transaction in
            transaction.animation = nil
        }
        .animation(nil, value: channelEntryMode)
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .presentationDetents([.height(channelEntrySheetHeight)])
        .presentationDragIndicator(.visible)
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
        guard !isCreateSubmitting else { return }
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
            environment.showErrorToast(error, duration: 2.5)
        }
    }

    @MainActor
    private func subscribeChannelFromSheet() async {
        guard !isSubscribeSubmitting else { return }
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
            environment.showErrorToast(error, duration: 2.5)
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
            try await environment.unsubscribeChannel(channelId: subscription.channelId)
            if deleteHistory {
                let summary = channelDeletionSummary(for: subscription)
                let channelId = subscription.channelId
                await environment.pendingLocalDeletionController.schedule(
                    summary: summary,
                    undoLabel: localizationManager.localized("cancel"),
                    scope: .init(channelIDs: Set([channelId]))
                ) {
                    _ = try await environment.deleteLocalHistoryForChannel(channelId: channelId)
                } onCompletion: { [environment] result in
                    guard case let .failure(error) = result else { return }
                    environment.showErrorToast(
                        error,
                        fallbackMessage: localizationManager.localized("operation_failed"),
                        duration: 2.5
                    )
                }
                environment.showToast(
                    message: localizationManager.localized("channel_unsubscribed"),
                    style: .success,
                    duration: 1.5
                )
            } else {
                environment.showToast(
                    message: localizationManager.localized("channel_unsubscribed"),
                    style: .success,
                    duration: 1.5
                )
            }
        } catch {
            environment.showErrorToast(error, duration: 2.5)
        }
    }

    private func channelDeletionSummary(for subscription: ChannelSubscription) -> String {
        let displayName = subscription.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !displayName.isEmpty {
            return displayName
        }
        return subscription.channelId.trimmingCharacters(in: .whitespacesAndNewlines)
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
            environment.showErrorToast(error, duration: 2.5)
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
