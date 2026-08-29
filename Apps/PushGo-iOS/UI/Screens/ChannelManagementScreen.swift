import SwiftUI
import UIKit

struct ChannelManagementScreen: View {
    @Environment(AppEnvironment.self) private var environment: AppEnvironment
    @Environment(PendingLocalDeletionController.self) private var pendingLocalDeletionController
    @Environment(LocalizationManager.self) private var localizationManager: LocalizationManager
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
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
    @State private var channelEntryErrorMessage: String?
    private let channelEntryFieldsMinHeight: CGFloat = 196

    private var channelEntrySheetHeight: CGFloat {
        channelEntryErrorMessage == nil ? 348 : 408
    }

    private var channelEntrySheetDetents: Set<PresentationDetent> {
        dynamicTypeSize.isAccessibilitySize ? [.large] : [.height(channelEntrySheetHeight)]
    }

    var body: some View {
        navigationContainer {
            channelManagementScaffold
        }
        .id(pendingLocalDeletionController.effectiveScope)
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
            .accessibilityIdentifier("action.channel.unsubscribe.delete_history")
            Button {
                if let target = pendingRemoval {
                    Task { await removeChannel(target, deleteHistory: false) }
                }
            } label: {
                Text(localizationManager.localized("unsubscribe_keep_history"))
            }
            .accessibilityIdentifier("action.channel.unsubscribe.keep_history")
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
            .accessibilityIdentifier("field.channel.rename.alias")
            Button(localizationManager.localized("confirm")) {
                if let target = pendingRename {
                    Task { await renameChannel(target) }
                }
            }
            .disabled(isRenaming || renameAlias.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityIdentifier("action.channel.rename.save")
            Button(localizationManager.localized("cancel"), role: .cancel) {
                pendingRename = nil
            }
        }
        .sheet(
            isPresented: $isChannelEntrySheetPresented,
            onDismiss: resetChannelEntrySheetState
        ) {
            channelEntrySheet
                .toastOverlay(environment: environment, showsPendingDeletionBar: false)
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
        VStack(spacing: 0) {
            if let feedback = environment.channelListFeedbackMessage {
                AppInlineFeedbackBanner(
                    message: feedback,
                    tone: .danger,
                    accessibilityID: "feedback.channels.entry-sync"
                ) {
                    environment.clearChannelListFeedback()
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 4)
            }

            Group {
                if visibleChannelSubscriptions.isEmpty {
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
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.appWindowBackground)
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
            ForEach(visibleChannelSubscriptions) { subscription in
                channelRow(subscription)
            }
        }
        .listSectionSeparator(.hidden)
    }

    private var visibleChannelSubscriptions: [ChannelSubscription] {
        let suppressed = pendingLocalDeletionController.effectiveScope.channelIDs
        return environment.channelSubscriptions.filter {
            !suppressed.contains($0.channelId.trimmingCharacters(in: .whitespacesAndNewlines))
        }
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
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, 8)
        .accessibilityIdentifier("channel.row.\(channelId)")
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button {
                beginRename(subscription)
            } label: {
                Label(localizationManager.localized("rename_channel"), systemImage: "pencil")
            }
            .tint(.appAccentPrimary)
            .accessibilityIdentifier("action.channel.\(channelId).rename")

            Button(role: .destructive) {
                pendingRemoval = subscription
                isShowingRemovalConfirmation = true
            } label: {
                Label(localizationManager.localized("unsubscribe_channel"), systemImage: "trash")
            }
            .accessibilityIdentifier("action.channel.\(channelId).unsubscribe")
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
        Group {
            if channelEntryMode == .create {
                channelEntryCreateFields
            } else {
                channelEntrySubscribeFields
            }
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
                .accessibilityIdentifier("field.channels.create.name")
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
                .submitLabel(.next)
                .disabled(isCreateSubmitting)
            }

            AppFormField(
                titleText: localizationManager.localized("channel_password")
            ) {
                ChannelSecureTextField(
                    text: $createChannelPassword,
                    placeholder: localizationManager.localized("channel_password_placeholder"),
                    accessibilityIdentifier: "field.channels.create.password",
                    isSecureEntry: PushGoAutomationContext.qualitySession == nil,
                    isEnabled: !isCreateSubmitting
                ) {
                    Task { await submitChannelEntryFromSheet() }
                }
                .textFieldStyle(.plain)
                .accessibilityIdentifier("field.channels.create.password")
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
                .submitLabel(.go)
                .disabled(isCreateSubmitting)
            }

            if PushGoAutomationContext.qualitySession != nil {
                Text("\(createChannelPassword.count)")
                    .font(.caption2)
                    .foregroundStyle(.clear)
                    .frame(width: 1, height: 1)
                    .accessibilityIdentifier("quality.channels.create.credential_length")
                    .accessibilityLabel("Credential length")
                    .accessibilityValue("\(createChannelPassword.count)")
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
                .accessibilityIdentifier("field.channels.subscribe.id")
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
                .submitLabel(.next)
                .disabled(isSubscribeSubmitting)
            }

            AppFormField(
                titleText: localizationManager.localized("channel_password")
            ) {
                ChannelSecureTextField(
                    text: $subscribeChannelPassword,
                    placeholder: localizationManager.localized("channel_password_placeholder"),
                    accessibilityIdentifier: "field.channels.subscribe.password",
                    isSecureEntry: PushGoAutomationContext.qualitySession == nil,
                    isEnabled: !isSubscribeSubmitting
                ) {
                    Task { await submitChannelEntryFromSheet() }
                }
                .textFieldStyle(.plain)
                .accessibilityIdentifier("field.channels.subscribe.password")
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
                .submitLabel(.go)
                .disabled(isSubscribeSubmitting)
            }

        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var channelEntryActionButtons: some View {
        HStack(spacing: 12) {
            AppActionButton(
                title: localizationManager.localized("cancel"),
                variant: .secondary
            ) {
                dismissChannelEntrySheet()
            }
            .disabled(isChannelEntrySubmitting)
            .accessibilityIdentifier("action.channels.entry.cancel")

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
    }

    private var channelEntrySheet: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Picker("", selection: $channelEntryMode) {
                    Text(localizationManager.localized("create_channel"))
                        .tag(ChannelEntryMode.create)
                        .accessibilityIdentifier("mode.channels.entry.create")
                    Text(localizationManager.localized("subscribe_channel"))
                        .tag(ChannelEntryMode.subscribe)
                        .accessibilityIdentifier("mode.channels.entry.subscribe")
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("select.channels.entry.mode")
                .disabled(isChannelEntrySubmitting)

                if let channelEntryErrorMessage {
                    AppInlineFeedbackBanner(
                        message: channelEntryErrorMessage,
                        tone: .danger,
                        accessibilityID: "feedback.channels.entry"
                    ) {
                        self.channelEntryErrorMessage = nil
                    }
                    .transition(.opacity)
                }

                channelEntryFields

                channelEntryActionButtons
            }
            .padding(.horizontal, 16)
            .padding(.top, 22)
            .padding(.bottom, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollDismissesKeyboard(.interactively)
        .accessibilityIdentifier("sheet.channels.entry")
        .transaction { transaction in
            transaction.animation = nil
        }
        .animation(nil, value: channelEntryMode)
        .presentationDetents(channelEntrySheetDetents)
        .presentationDragIndicator(.visible)
        .onChange(of: channelEntryMode) { _, _ in
            channelEntryErrorMessage = nil
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
        channelEntryErrorMessage = nil
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
        channelEntryErrorMessage = nil
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
            presentChannelEntryError(error)
        }
    }

    @MainActor
    private func subscribeChannelFromSheet() async {
        guard !isSubscribeSubmitting else { return }
        channelEntryErrorMessage = nil
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
            presentChannelEntryError(error)
        }
    }

    @MainActor
    private func presentChannelEntryError(_ error: Error) {
        let message = environment.userFacingErrorMessage(error)
        switch FeedbackPresentationPolicy.presentation(for: .formSubmissionError) {
        case .inline:
            channelEntryErrorMessage = message
        case .toast:
            environment.showToast(message: message, style: .error, duration: 2.5)
        case .pendingLocalDeletionBar, .none:
            break
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
            if deleteHistory {
                let summary = channelDeletionSummary(for: subscription)
                let channelId = subscription.channelId
                let expectedGateway = subscription.gateway
                let expectedUpdatedAt = subscription.updatedAt
                _ = await environment.pendingLocalDeletionController.schedule(
                    summary: summary,
                    undoLabel: localizationManager.localized("cancel"),
                    intent: .channelHistory(
                        channelID: channelId,
                        expectedGateway: expectedGateway,
                        expectedUpdatedAt: expectedUpdatedAt
                    )
                )
            } else {
                try await environment.unsubscribeChannel(channelId: subscription.channelId)
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
        guard PushGoSystemInteraction.copyTextToPasteboard(value) else {
            environment.showToast(
                message: localizationManager.localized("operation_failed"),
                style: .error,
                duration: 2.5
            )
            return
        }
        environment.showToast(
            message: "\(localizationManager.localized("channel_id_copied")): \(value)",
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

private struct ChannelSecureTextField: UIViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let accessibilityIdentifier: String
    let isSecureEntry: Bool
    let isEnabled: Bool
    let onSubmit: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> UITextField {
        let textField = UITextField(frame: .zero)
        textField.delegate = context.coordinator
        textField.isSecureTextEntry = isSecureEntry
        textField.borderStyle = .none
        textField.autocorrectionType = .no
        textField.autocapitalizationType = .none
        textField.returnKeyType = .go
        textField.textContentType = isSecureEntry ? .password : nil
        textField.accessibilityIdentifier = accessibilityIdentifier
        textField.addTarget(
            context.coordinator,
            action: #selector(Coordinator.textDidChange(_:)),
            for: .editingChanged
        )
        textField.addTarget(
            context.coordinator,
            action: #selector(Coordinator.beginEditing(_:)),
            for: .touchDown
        )
        return textField
    }

    func updateUIView(_ textField: UITextField, context: Context) {
        context.coordinator.parent = self
        if textField.text != text {
            textField.text = text
        }
        textField.placeholder = placeholder
        textField.isSecureTextEntry = isSecureEntry
        textField.textContentType = isSecureEntry ? .password : nil
        textField.isEnabled = isEnabled
        textField.accessibilityIdentifier = accessibilityIdentifier
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: ChannelSecureTextField

        init(parent: ChannelSecureTextField) {
            self.parent = parent
        }

        @objc func textDidChange(_ sender: UITextField) {
            parent.text = sender.text ?? ""
        }

        @objc func beginEditing(_ sender: UITextField) {
            // Moving from the adjacent SwiftUI TextField into this UIKit-backed
            // secure field can otherwise leave the former responder active
            // while the keyboard is already visible. SwiftUI can finish its
            // own focus update after this touchDown callback, so arbitrate on
            // the next main-loop turn. A real first tap must transfer
            // ownership; requiring a second tap would be a product interaction
            // defect, not something the UI test should hide.
            DispatchQueue.main.async { [weak sender] in
                guard let sender, sender.window != nil, sender.isEnabled else { return }
                if !sender.isFirstResponder {
                    sender.becomeFirstResponder()
                }
            }
        }

        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            parent.onSubmit()
            return true
        }
    }
}
