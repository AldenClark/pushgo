import AVFoundation
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import Observation

struct SettingsView: View {
    @Environment(\.appEnvironment) private var environment: AppEnvironment
    @Environment(LocalizationManager.self) private var localizationManager: LocalizationManager
    @State private var viewModel = SettingsViewModel()
    @State private var isExportingMessages = false
    @State private var exportDocument = MessagesExportDocument(messages: [])
    @State private var macOverlay: MacOverlay?
    @State private var macOverlayRingtonePlayer = RingtonePreviewPlayer()

    var body: some View {
        navigationContainer {
            settingsScaffold
        }
        .overlay(macOverlayView)
        .animation(.spring(response: 0.28, dampingFraction: 0.85), value: macOverlay != nil)
        .task {
            viewModel.refresh()
        }
        .onChange(of: environment.pushRegistrationService.authorizationState) { _, _ in
            viewModel.refresh()
        }
        .onChange(of: environment.serverConfig) { _, _ in
            viewModel.refresh()
        }
        .onChange(of: viewModel.successMessage) { _, message in
            guard let message else { return }
            environment.showToast(message: message, style: .success, duration: 1.5)
            viewModel.successMessage = nil
        }
        .onChange(of: viewModel.error) { _, error in
            guard let error else { return }
            environment.showToast(
                message: error.errorDescription ?? localizationManager.localized("operation_failed"),
                style: .error,
                duration: 2.5,
            )
            viewModel.error = nil
        }
        .fileExporter(
            isPresented: $isExportingMessages,
            document: exportDocument,
            contentType: .json,
            defaultFilename: exportDefaultFilename,
        ) { result in
            switch result {
            case .success:
                environment.showToast(
                    message: localizationManager.localized("message_json_exported_successfully"),
                    style: .success,
                    duration: 1.5,
                )
            case let .failure(error):
                viewModel.error = .exportFailed(error.localizedDescription)
            }
        }
    }

    @ViewBuilder
    private var settingsScaffold: some View {
        let baseView = coreLayout
            .navigationTitle(localizationManager.localized("settings"))
        applyTitleToolbarIfNeeded(baseView)
    }

    @ViewBuilder
    private func applyTitleToolbarIfNeeded<Content: View>(_ content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content
        } else {
            content.toolbar {
                ToolbarItem(placement: .navigation) {
                    Text(localizationManager.localized("settings"))
                        .font(.headline.weight(.semibold))
                }
            }
        }
    }

    @ViewBuilder
    private var macOverlayView: some View {
        if let overlay = macOverlay {
            ZStack {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { closeMacOverlay() }

                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                    macOverlayContent(for: overlay)
                        .frame(width: macOverlayWidth(for: overlay))
                        .background(Material.bar)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .shadow(radius: 16, x: 0, y: 8)
                        .padding(.trailing, 24)
                        .padding(.vertical, 24)
                }
            }
            .transition(.move(edge: .trailing).combined(with: .opacity))
            .zIndex(1)
        }
    }

        private func macOverlayWidth(for overlay: MacOverlay) -> CGFloat {
            switch overlay {
            case .manualKey:
                520
            case .serverManagement:
                520
            case .ringtone:
                540
            }
        }

        @ViewBuilder
        private func macOverlayContent(for overlay: MacOverlay) -> some View {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text(overlay.title)
                        .font(.title3.weight(.semibold))
                    Spacer()
                    Button {
                        closeMacOverlay()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title2.weight(.bold))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.appPlain)
                    .accessibilityLabel(localizationManager.localized("close"))
                }

                switch overlay {
                case .manualKey:
                    ManualKeySettingsContentView(viewModel: viewModel)
                        .frame(maxHeight: 560)
                case .serverManagement:
                    ServerManagementContentView(viewModel: viewModel, onDismiss: closeMacOverlay)
                        .frame(maxHeight: 420)
                case .ringtone:
                    RingtoneGalleryContent(
                        player: macOverlayRingtonePlayer,
                        onCopy: { value in
                            copyToPasteboard(value)
                        },
                    )
                    .frame(maxHeight: 520)
                }
            }
            .padding(18)
        }

        private func closeMacOverlay() {
            macOverlay = nil
            macOverlayRingtonePlayer.stop()
        }

    private var coreLayout: some View {
        settingsList
        .background(settingsBackgroundColor)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var settingsBackgroundColor: Color {
        if #available(macOS 26.0, *) {
            Color.appWindowBackground
        } else {
            Color.messageListBackground
        }
    }

    private var appVersionDetail: LocalizedStringKey {
        let info = Bundle.main.infoDictionary
        let shortVersion = info?["CFBundleShortVersionString"] as? String
        let buildVersion = info?["CFBundleVersion"] as? String

        if let shortVersion, !shortVersion.isEmpty,
           let buildVersion, !buildVersion.isEmpty
        {
            return LocalizedStringKey("\(shortVersion) build \(buildVersion)")
        }
        if let shortVersion, !shortVersion.isEmpty {
            return LocalizedStringKey(shortVersion)
        }
        if let buildVersion, !buildVersion.isEmpty {
            return LocalizedStringKey(buildVersion)
        }
        return LocalizedStringKey("N/A")
    }

    private var hasMessages: Bool {
        environment.totalMessageCount > 0
    }

    private var settingsList: some View {
        return ScrollView {
            VStack(spacing: 16) {
                if viewModel.notificationStatus != .authorized {
                    cardContainer {
                        notificationBlock
                    }
                }

                VStack(spacing: 0) {
                    Toggle(isOn: $viewModel.launchAtLoginEnabled) {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: "power")
                                .font(.callout.weight(.semibold))
                                .frame(width: 32, height: 32)
                                .foregroundStyle(Color.accentColor)
                                .background(
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .fill(Color.accentColor.opacity(0.12)),
                                )

                            VStack(alignment: .leading, spacing: 2) {
                                Text("launch_at_login")
                                    .font(.headline)
                                    .foregroundStyle(.primary)
                                    .multilineTextAlignment(.leading)
                                    .lineLimit(2)
                                    .minimumScaleFactor(0.85)

                                Text("launch_at_login_detail")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .toggleStyle(.switch)
                    .padding(.vertical, 14)
                    SettingsRowDivider()
                    Button {
                        viewModel.prepareServerEditor()
                        macOverlay = .serverManagement
                    } label: {
                        SettingsActionRow(
                            iconName: "link",
                            title: "server_management",
                            detail: serverConfigSubtitle,
                        ) {
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.appPlain)
                    SettingsRowDivider()
                    SettingsControlRow(
                        iconName: "globe",
                        title: "interface_language",
                        detail: languageSubtitle,
                        useFormField: false
                    ) {
                        Picker("", selection: languageSelectionBinding) {
                            ForEach(AppLocale.allCases) { locale in
                                Text(LocalizedStringKey(localizationManager.localized(locale.displayNameKey)))
                                    .tag(locale)
                            }
                        }
                    }
                    SettingsRowDivider()
                    Toggle(isOn: $viewModel.autoCleanupEnabled) {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: "sparkles")
                                .font(.callout.weight(.semibold))
                                .frame(width: 32, height: 32)
                                .foregroundStyle(Color.accentColor)
                                .background(
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .fill(Color.accentColor.opacity(0.12)),
                                )

                            VStack(alignment: .leading, spacing: 2) {
                                Text("auto_cleanup_messages")
                                    .font(.headline)
                                    .foregroundStyle(.primary)
                                    .multilineTextAlignment(.leading)
                                    .lineLimit(2)
                                    .minimumScaleFactor(0.85)

                                Text("auto_cleanup_messages_hint")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .toggleStyle(.switch)
                    .padding(.vertical, 14)
                    SettingsRowDivider()
                    Button {
                        startMessagesExport()
                    } label: {
                        SettingsActionRow(
                            iconName: "square.and.arrow.up",
                            title: "export_all_messages_json",
                            detail: "generate_a_json_file_with_full_message_details",
                        ) {
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.appPlain)
                    .disabled(!hasMessages)
                    .opacity(hasMessages ? 1 : 0.45)
                    SettingsRowDivider()
                    Button {
                        macOverlay = .manualKey
                    } label: {
                        SettingsActionRow(
                            iconName: "lock.square.stack",
                            title: "message_encryption",
                            detail: manualKeySubtitle,
                        ) {
                            ManualKeyStatusBadge(
                                text: manualKeyStatusText,
                                isConfigured: viewModel.notificationKeyMaterial != nil,
                            )
                        }
                    }
                    .buttonStyle(.appPlain)
                    SettingsRowDivider()
                    Button {
                        macOverlay = .ringtone
                    } label: {
                        SettingsActionRow(
                            iconName: "bell.badge.waveform",
                            title: "view_built_in_ringtones",
                            detail: "understand_the_sound_parameter_value_and_preview_the_prompt_sound",
                        ) {
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.appPlain)
                    SettingsRowDivider()
                    SettingsActionRow(
                        iconName: "info.circle",
                        title: "app_version",
                        detail: appVersionDetail,
                    )
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 20)
        }
        .scrollDismissesKeyboard(.interactively)
        .modifyScrollIndicators()
        .background(settingsBackgroundColor.ignoresSafeArea())
    }

    private func cardContainer<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            content()
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(nsColor: .controlBackgroundColor),
                            Color(nsColor: .controlBackgroundColor).opacity(0.9),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.08), radius: 10, x: 0, y: 6)
    }

    private var languageSelectionBinding: Binding<AppLocale> {
        Binding(
            get: { localizationManager.locale },
            set: { newValue in
                localizationManager.updateLocale(newValue)
            },
        )
    }

    private var languageSubtitle: LocalizedStringKey {
        let currentName = localizationManager.localized(localizationManager.locale.displayNameKeyString)
        return LocalizedStringKey(localizationManager.localized("current_language_placeholder", currentName))
    }

    private var manualKeySubtitle: LocalizedStringKey {
        if let material = viewModel.notificationKeyMaterial {
            let formattedDate = material.updatedAt.formatted(
                Date.FormatStyle(date: .abbreviated, time: .shortened)
                    .locale(localizationManager.swiftUILocale),
            )
            return LocalizedStringKey(localizationManager.localized("last_updated_placeholder", formattedDate))
        }
        return LocalizedStringKey(localizationManager
            .localized("after_configuration_push_content_can_be_decrypted_locally"))
    }

    private var manualKeyStatusText: LocalizedStringKey {
        if let material = viewModel.notificationKeyMaterial {
            return LocalizedStringKey(material.algorithm.displayName)
        }
        return LocalizedStringKey(localizationManager.localized("not_configured"))
    }

    private var serverConfigSubtitle: LocalizedStringKey {
        let value = environment.serverConfig?.baseURL.absoluteString ?? AppConstants.defaultServerAddress
        return LocalizedStringKey(value)
    }

    private var messageCountSubtitle: LocalizedStringKey {
        let count = environment.totalMessageCount
        if count > 0 {
            return LocalizedStringKey(localizationManager.localized("current_number_messages", count))
        }
        return LocalizedStringKey(localizationManager.localized("no_local_messages"))
    }

    private var exportDefaultFilename: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "pushgo-messages-\(formatter.string(from: Date()))"
    }

    private func startMessagesExport() {
        Task {
            do {
                let messages = try await environment.dataStore.loadMessages()
                guard !messages.isEmpty else {
                    await MainActor.run {
                        viewModel.error = .exportFailed(localizationManager.localized("no_messages_available_to_export"))
                    }
                    return
                }
                await MainActor.run {
                    exportDocument = MessagesExportDocument(messages: messages)
                    isExportingMessages = true
                }
            } catch {
                await MainActor.run {
                    viewModel.error = .exportFailed(error.localizedDescription)
                }
            }
        }
    }

    @ViewBuilder
    private var notificationBlock: some View {
        switch viewModel.notificationStatus {
        case .authorized:
            EmptyView()
        case .notDetermined:
            Button {
                Task { await viewModel.requestNotificationPermission() }
            } label: {
                HStack(spacing: 12) {
                        Image(systemName: "bell.badge")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 28, height: 28)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(Color.accentColor.opacity(0.16))
                            )
                            .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(localizationManager.localized("request_notification_permission"))
                            .font(.headline)
                            .foregroundStyle(.primary)
                        Text(localizationManager.localized("the_system_will_pop_up_an_authorization_prompt"))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                }
            }
            .buttonStyle(.appPlain)
        case .denied:
            Button {
                openNotificationSettings()
            } label: {
                HStack(spacing: 12) {
                        Image(systemName: "bell.slash")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.red)
                            .frame(width: 28, height: 28)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(Color.red.opacity(0.16))
                            )
                            .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(localizationManager.localized("please_enable_notification_permission_in_system_settings_first"))
                            .font(.headline)
                            .foregroundStyle(.primary)
                        Text(localizationManager.localized("system_notification_permission_is_not_obtained_please_turn_on_notifications_in_the_system_settings_and_try_again"))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    Spacer()
                        Image(systemName: "arrow.up.right.square")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                }
            }
            .buttonStyle(.appPlain)
        }
    }

    private func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func openNotificationSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") else { return }
        NSWorkspace.shared.open(url)
    }
}

private struct SettingsRowDivider: View {
    private let leadingInset: CGFloat = 48

    var body: some View {
        Divider()
            .padding(.leading, leadingInset)
            .padding(.vertical, 18)
    }
}

private struct SettingsActionRow<Trailing: View>: View {
    enum Style {
        case plain
        case destructive
    }

    let iconName: String
    let title: LocalizedStringKey
    let detail: LocalizedStringKey?
    let style: Style
    private let trailing: () -> Trailing

    init(
        iconName: String,
        title: LocalizedStringKey,
        detail: LocalizedStringKey? = nil,
        style: Style = .plain,
        @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() },
    ) {
        self.iconName = iconName
        self.title = title
        self.detail = detail
        self.style = style
        self.trailing = trailing
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: iconName)
                .font(.callout.weight(.semibold))
                .frame(width: 32, height: 32)
                .foregroundStyle(Color.accentColor)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.accentColor.opacity(0.12)),
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)

                if let detail {
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 12)

            trailing()
                .fixedSize()
        }
        .contentShape(Rectangle())
        .padding(.vertical, 14)
    }
}

private struct ManualKeyStatusBadge: View {
    let text: LocalizedStringKey
    let isConfigured: Bool

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background((isConfigured ? Color.accentColor : Color.secondary).opacity(0.16))
            .foregroundStyle(isConfigured ? Color.accentColor : Color.secondary)
            .clipShape(Capsule())
    }
}

private struct NotificationStatusBadge: View {
    let text: LocalizedStringKey
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(color.opacity(0.16))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }
}

private struct SettingsControlRow<Control: View>: View {
    let iconName: String
    let title: LocalizedStringKey
    let detail: LocalizedStringKey?
    let control: Control
    let useFormField: Bool

    init(
        iconName: String,
        title: LocalizedStringKey,
        detail: LocalizedStringKey? = nil,
        useFormField: Bool = true,
        @ViewBuilder control: () -> Control,
    ) {
        self.iconName = iconName
        self.title = title
        self.detail = detail
        self.control = control()
        self.useFormField = useFormField
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: iconName)
                .font(.callout.weight(.semibold))
                .frame(width: 32, height: 32)
                .foregroundStyle(Color.accentColor)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.accentColor.opacity(0.12)),
                )

            if useFormField {
                AppFormField(title) {
                    VStack(alignment: .leading, spacing: 6) {
                        if let detail {
                            AppFieldHint(detail)
                        }
                        control
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline)
                        .multilineTextAlignment(.leading)
                        .lineLimit(2)
                        .minimumScaleFactor(0.85)

                    if let detail {
                        Text(detail)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Spacer(minLength: 12)

                control
                    .fixedSize()
            }
        }
        .contentShape(Rectangle())
        .padding(.vertical, 10)
    }
}

private struct ServerManagementContentView: View {
    @Bindable var viewModel: SettingsViewModel
    @Environment(LocalizationManager.self) private var localizationManager: LocalizationManager
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focusedField: ServerField?
    var onDismiss: (() -> Void)? = nil
    
    private var isUsingDefaultServerAddress: Bool {
        viewModel.gatewayInput.address
            .trimmingCharacters(in: .whitespacesAndNewlines)
            == AppConstants.defaultServerAddress
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(localizationManager.localized("server_management_help_register_on_save"))
                    .font(.footnote)
                    .foregroundColor(.secondary)

                AppFormField(titleText: localizationManager.localized("server_address"), isFocused: focusedField == .address) {
                    HStack(spacing: 10) {
                        TextField(
                            "",
                            text: $viewModel.gatewayInput.address,
                            prompt: AppFieldPrompt.text(AppConstants.defaultServerAddress)
                        )
                        .textFieldStyle(.plain)
                        .focused($focusedField, equals: .address)
                        .submitLabel(.done)
                        .onSubmit {
                            dismissKeyboard()
                            focusedField = nil
                        }

                        Button {
                            focusedField = nil
                            viewModel.restoreDefaultServerAddress()
                        } label: {
                            Image(systemName: "arrow.counterclockwise")
                                .font(.callout.weight(.medium))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.appPlain)
                        .disabled(isUsingDefaultServerAddress)
                        .opacity(isUsingDefaultServerAddress ? 0.35 : 1)
                        .accessibilityLabel(Text(localizationManager.localized("restore_default_server_address")))
                    }
                }

                AppFormField(titleText: localizationManager.localized("server_token_optional"), isFocused: focusedField == .token) {
                    HStack(spacing: 10) {
                        Group {
                            if viewModel.gatewayInput.isTokenVisible {
                                TextField(
                                    "",
                                    text: $viewModel.gatewayInput.token,
                                    prompt: AppFieldPrompt.text(localizationManager.localized("server_token_placeholder"))
                                )
                            } else {
                                SecureField(
                                    "",
                                    text: $viewModel.gatewayInput.token,
                                    prompt: AppFieldPrompt.text(localizationManager.localized("server_token_placeholder"))
                                )
                            }
                        }
                        .textFieldStyle(.plain)
                        .focused($focusedField, equals: .token)
                        .submitLabel(.done)
                        .onSubmit {
                            dismissKeyboard()
                            focusedField = nil
                        }

                        Button {
                            viewModel.gatewayInput.isTokenVisible.toggle()
                        } label: {
                            Image(systemName: viewModel.gatewayInput.isTokenVisible ? "eye.slash" : "eye")
                                .font(.callout.weight(.medium))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.appPlain)
                        .accessibilityLabel(
                            LocalizedStringKey(viewModel.gatewayInput.isTokenVisible ? "hide_key" : "show_key")
                        )
                    }
                }

                Button {
                    focusedField = nil
                    Task { await viewModel.saveServerConfig() }
                } label: {
                    if viewModel.isSavingServerConfig {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                    } else {
                        Text(localizationManager.localized("save_configuration"))
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .appButtonHeight()
                .disabled(viewModel.isSavingServerConfig)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear {
            viewModel.prepareServerEditor()
        }
        .onChange(of: viewModel.shouldDismissServerManagement) { _, shouldDismiss in
            guard shouldDismiss else { return }
            viewModel.shouldDismissServerManagement = false
            if let onDismiss {
                onDismiss()
            } else {
                dismiss()
            }
        }
    }
}

private enum ServerField: Hashable {
    case address
    case token
}

private struct ManualKeySettingsContentView: View {
    @Bindable var viewModel: SettingsViewModel
    @Environment(LocalizationManager.self) private var localizationManager: LocalizationManager
    @FocusState private var sheetFocus: ManualSheetField?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                statusCallout
                keyPickers
                keyField
                Text(localizationManager
                    .localized(
                        "only_aes_gcm_is_supported_iv_needs_to_be_included_by_the_sender_and_the_key_length_must_exactly_match_the_selected_number_of_bits",
                    ))
                    .font(.footnote)
                    .foregroundColor(.secondary)
                Button {
                    Task { await viewModel.saveManualKeyConfig() }
                } label: {
                    if viewModel.isSaving {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                    } else {
                        Text(localizationManager.localized("save_configuration"))
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .appButtonHeight()
                .disabled(viewModel.isSaving)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var statusCallout: some View {
        if let material = viewModel.notificationKeyMaterial {
            VStack(alignment: .leading, spacing: 6) {
                Label(localizationManager.localized("aes_gcm_configured"), systemImage: "checkmark.shield")
                    .foregroundStyle(Color.accentColor)
                Text(
                    localizationManager.localized(
                        "last_updated_placeholder",
                        material.updatedAt.formatted(
                            Date.FormatStyle(date: .abbreviated, time: .shortened)
                                .locale(localizationManager.swiftUILocale),
                        ),
                    ),
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.accentColor.opacity(0.12)),
            )
        } else {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.shield")
                    .font(.title3)
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 4) {
                    Text(localizationManager.localized("no_key_configured_yet"))
                        .font(.subheadline.weight(.semibold))
                    Text(localizationManager
                        .localized(
                            "please_paste_the_key_from_the_server_and_save_it_to_decrypt_the_push_content_locally",
                        ))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.accentColor.opacity(0.08)),
            )
        }
    }

    @ViewBuilder
    private var keyPickers: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                AppFormField("key_length") {
                    keyLengthPicker
                }
                AppFormField("key_format") {
                    keyEncodingPicker
                }
            }
            VStack(alignment: .leading, spacing: 16) {
                AppFormField("key_length") {
                    keyLengthPicker
                }
                AppFormField("key_format") {
                    keyEncodingPicker
                }
            }
        }
    }

    private var keyLengthPicker: some View {
        Picker("", selection: $viewModel.manualKeyInput.selectedLength) {
            ForEach(SettingsViewModel.KeyLength.allCases) { length in
                Text(length.displayName).tag(length)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .accessibilityLabel(Text(localizationManager.localized("key_length")))
    }

    private var keyEncodingPicker: some View {
        Picker("", selection: $viewModel.manualKeyInput.encoding) {
            ForEach(SettingsViewModel.KeyEncoding.allCases) { encoding in
                Text(encoding.displayName).tag(encoding)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .accessibilityLabel(Text(localizationManager.localized("key_format")))
    }

    private var keyField: some View {
        let isFocused = sheetFocus == .manualKey
        let placeholderKey = viewModel.manualKeyInput.hasConfiguredKey
            ? "key_has_been_saved_enter_new_value_to_overwrite"
            : "enter_key"

        return Group {
            if viewModel.manualKeyInput.hasConfiguredKey {
                AppFormField(titleText: localizationManager.localized("key_content"), isFocused: isFocused, accessory: {
                    AppFieldTag(text: localizationManager.localized("saved"))
                }) {
                    HStack(spacing: 10) {
                        Group {
                            if viewModel.manualKeyInput.isSecretVisible {
                                TextField(
                                    "",
                                    text: $viewModel.manualKeyInput.key,
                                    prompt: AppFieldPrompt.text(localizationManager.localized(placeholderKey))
                                )
                            } else {
                                SecureField(
                                    "",
                                    text: $viewModel.manualKeyInput.key,
                                    prompt: AppFieldPrompt.text(localizationManager.localized(placeholderKey))
                                )
                            }
                        }
                        .textFieldStyle(.plain)
                        .font(.system(.body, design: .monospaced))
                        .focused($sheetFocus, equals: .manualKey)
                        .submitLabel(.done)
                        .onSubmit {
                            dismissKeyboard()
                            sheetFocus = nil
                        }

                        Button {
                            viewModel.manualKeyInput.isSecretVisible.toggle()
                        } label: {
                            Image(systemName: viewModel.manualKeyInput.isSecretVisible ? "eye.slash" : "eye")
                                .font(.callout.weight(.medium))
                        }
                        .buttonStyle(.appPlain)
                        .accessibilityLabel(
                            LocalizedStringKey(viewModel.manualKeyInput.isSecretVisible ? "hide_key" : "show_key")
                        )
                    }
                }
            } else {
                AppFormField(titleText: localizationManager.localized("key_content"), isFocused: isFocused) {
                    HStack(spacing: 10) {
                        Group {
                            if viewModel.manualKeyInput.isSecretVisible {
                                TextField(
                                    "",
                                    text: $viewModel.manualKeyInput.key,
                                    prompt: AppFieldPrompt.text(localizationManager.localized(placeholderKey))
                                )
                            } else {
                                SecureField(
                                    "",
                                    text: $viewModel.manualKeyInput.key,
                                    prompt: AppFieldPrompt.text(localizationManager.localized(placeholderKey))
                                )
                            }
                        }
                        .textFieldStyle(.plain)
                        .font(.system(.body, design: .monospaced))
                        .focused($sheetFocus, equals: .manualKey)
                        .submitLabel(.done)
                        .onSubmit {
                            dismissKeyboard()
                            sheetFocus = nil
                        }

                        Button {
                            viewModel.manualKeyInput.isSecretVisible.toggle()
                        } label: {
                            Image(systemName: viewModel.manualKeyInput.isSecretVisible ? "eye.slash" : "eye")
                                .font(.callout.weight(.medium))
                        }
                        .buttonStyle(.appPlain)
                        .accessibilityLabel(
                            LocalizedStringKey(viewModel.manualKeyInput.isSecretVisible ? "hide_key" : "show_key")
                        )
                    }
                }
            }
        }
    }
}

private enum ManualSheetField: Hashable {
    case manualKey
}

private enum MacOverlay: Equatable {
    case manualKey
    case serverManagement
    case ringtone

    var title: LocalizedStringKey {
        switch self {
        case .manualKey:
            "message_encryption"
        case .serverManagement:
            "server_management"
        case .ringtone:
            "built_in_ringtone"
        }
    }
}

private struct CustomRingtone: Identifiable, Hashable {
    let id: String
    let filename: String
    let url: URL
    let duration: TimeInterval

    var displayName: String {
        (filename as NSString).deletingPathExtension
    }
}

private enum RingtoneImportError: Error {
    case appGroupUnavailable
    case duplicateName(String)
    case unsupportedFormat(String)
    case durationTooLong(TimeInterval)
    case unreadable
    case copyFailed(String)
}

@MainActor
@Observable
private final class RingtoneGalleryViewModel {
    private(set) var customRingtones: [CustomRingtone] = []

    static let maxDuration: TimeInterval = 30.0
    private static let allowedExtensions: Set<String> = ["caf", "wav", "aif", "aiff"]

    static var allowedContentTypes: [UTType] {
        allowedExtensions.compactMap { UTType(filenameExtension: $0) }
    }

    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        refresh()
    }

    func refresh() {
        Task { await refreshAsync() }
    }

    private func refreshAsync() async {
        guard let soundsDirectory = try? soundsDirectory() else {
            customRingtones = []
            return
        }

        let fileURLs = (try? fileManager.contentsOfDirectory(
            at: soundsDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []

        let items: [CustomRingtone] = await withTaskGroup(of: CustomRingtone?.self) { group in
            let allowedExtensions = Self.allowedExtensions
            for url in fileURLs {
                group.addTask {
                    let filename = url.lastPathComponent
                    guard !filename.hasPrefix(AppConstants.longRingtonePrefix) else { return nil }
                    let ext = url.pathExtension.lowercased()
                    guard allowedExtensions.contains(ext) else { return nil }
                    guard let duration = try? await Self.audioDuration(of: url) else { return nil }
                    return CustomRingtone(
                        id: filename,
                        filename: filename,
                        url: url,
                        duration: duration
                    )
                }
            }

            var items: [CustomRingtone] = []
            items.reserveCapacity(fileURLs.count)
            for await item in group {
                if let item {
                    items.append(item)
                }
            }
            return items
        }

        customRingtones = items.sorted { lhs, rhs in
            lhs.filename.localizedCaseInsensitiveCompare(rhs.filename) == .orderedAscending
        }
        syncAppLibraryCopies(ringtones: customRingtones)
    }

    func importRingtone(from sourceURL: URL) async -> Result<String, RingtoneImportError> {
        let needsAccess = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if needsAccess {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        do {
            let destinationDirectory = try soundsDirectory()
            let ext = sourceURL.pathExtension.lowercased()
            guard Self.allowedExtensions.contains(ext) else {
                throw RingtoneImportError.unsupportedFormat(ext)
            }

            let duration = try await Self.audioDuration(of: sourceURL)
            guard duration <= Self.maxDuration + 0.05 else {
                throw RingtoneImportError.durationTooLong(duration)
            }

            let filename = sourceURL.lastPathComponent
            let normalizedName = filename.lowercased()
            if BuiltInRingtone.catalog.contains(where: { $0.filename.lowercased() == normalizedName })
                || customRingtones.contains(where: { $0.filename.lowercased() == normalizedName })
            {
                throw RingtoneImportError.duplicateName(filename)
            }

            let destinationURL = destinationDirectory.appendingPathComponent(filename)
            if fileManager.fileExists(atPath: destinationURL.path) {
                throw RingtoneImportError.duplicateName(filename)
            }
            try fileManager.copyItem(at: sourceURL, to: destinationURL)
            syncAppLibraryCopyIfNeeded(sourceURL: destinationURL)
            await refreshAsync()
            return .success(filename)
        } catch let error as RingtoneImportError {
            return .failure(error)
        } catch {
            return .failure(.copyFailed(error.localizedDescription))
        }
    }

    private func soundsDirectory() throws -> URL {
        guard let containerURL = fileManager.containerURL(forSecurityApplicationGroupIdentifier: AppConstants.appGroupIdentifier) else {
            throw RingtoneImportError.appGroupUnavailable
        }
        let directory = containerURL.appendingPathComponent(AppConstants.customRingtoneRelativePath, isDirectory: true)
        if !fileManager.fileExists(atPath: directory.path) {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return directory
    }

    private nonisolated static func audioDuration(of url: URL) async throws -> TimeInterval {
        let asset = AVURLAsset(url: url)
        let time = try await asset.load(.duration)
        let seconds = CMTimeGetSeconds(time)
        guard seconds.isFinite, seconds > 0 else {
            throw RingtoneImportError.unreadable
        }
        return seconds
    }

    func delete(ringtone: CustomRingtone) {
        do {
            try fileManager.removeItem(at: ringtone.url)
            removeAppLibraryCopyIfNeeded(filename: ringtone.filename)
            refresh()
        } catch {
            refresh()
        }
    }

    private func syncAppLibraryCopies(ringtones: [CustomRingtone]) {
        for ringtone in ringtones {
            syncAppLibraryCopyIfNeeded(sourceURL: ringtone.url)
        }
    }

    private func syncAppLibraryCopyIfNeeded(sourceURL: URL) {
        guard let destinationDirectory = appLibrarySoundsDirectory() else { return }
        let destinationURL = destinationDirectory.appendingPathComponent(sourceURL.lastPathComponent)
        if fileManager.fileExists(atPath: destinationURL.path) {
            return
        }
        try? fileManager.copyItem(at: sourceURL, to: destinationURL)
    }

    private func removeAppLibraryCopyIfNeeded(filename: String) {
        guard let destinationDirectory = appLibrarySoundsDirectory() else { return }
        let destinationURL = destinationDirectory.appendingPathComponent(filename)
        try? fileManager.removeItem(at: destinationURL)
    }

    private func appLibrarySoundsDirectory() -> URL? {
        guard let libraryURL = fileManager.urls(for: .libraryDirectory, in: .userDomainMask).first else {
            return nil
        }
        let directory = libraryURL.appendingPathComponent("Sounds", isDirectory: true)
        if !fileManager.fileExists(atPath: directory.path) {
            try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return directory
    }
}

private struct RingtoneGalleryContent: View {
    @Bindable var player: RingtonePreviewPlayer
    let onCopy: (String) -> Void
    @State private var viewModel = RingtoneGalleryViewModel()
    @State private var isImporterPresented = false
    @State private var defaultRingtoneFilename = AppConstants.fallbackRingtoneFilename
    @Environment(LocalizationManager.self) private var localizationManager: LocalizationManager
    @Environment(\.appEnvironment) private var environment: AppEnvironment

    var body: some View {
        List {
            instructionsSection
            customSection
            systemSection
        }
        .listStyle(.automatic)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    isImporterPresented = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel(localizationManager.localized("add_custom_ringtone"))
            }
        }
        .fileImporter(
            isPresented: $isImporterPresented,
            allowedContentTypes: RingtoneGalleryViewModel.allowedContentTypes,
            allowsMultipleSelection: false,
            onCompletion: handleImportResult
        )
        .task {
            viewModel.refresh()
            await refreshDefaultRingtoneFilename()
        }
    }

    private var instructionsSection: some View {
        Section(localizationManager.localized("instructions_for_use")) {
            VStack(alignment: .leading, spacing: 8) {
                Text(localizationManager
                    .localized(
                        "the_sound_field_in_the_push_payload_can_be_filled_with_the_file_name_listed_below_for_example_sound_pushgoaurora_wav",
                    ))
                Text(localizationManager.localized("custom_ringtone_requirement_description"))
                Text(localizationManager.localized("custom_ringtone_storage_path_tip"))
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
    }

    private var customSection: some View {
        Section(localizationManager.localized("custom_ringtones")) {
            if viewModel.customRingtones.isEmpty {
                Text(localizationManager.localized("no_custom_ringtones_yet"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(viewModel.customRingtones) { ringtone in
                    CustomRingtoneRow(
                        ringtone: ringtone,
                        isDefault: ringtone.filename == defaultRingtoneFilename,
                        isPlaying: player.currentlyPlayingId == ringtone.id,
                        onPlay: { player.toggle(custom: ringtone) },
                        onCopy: { handleCopy(ringtone.filename) },
                        onDelete: { handleDelete(ringtone) },
                        onSetDefault: { setDefaultRingtoneFilename(ringtone.filename) }
                    )
                }
            }
        }
    }

    private var systemSection: some View {
        Section(localizationManager.localized("available_ringtones")) {
            ForEach(BuiltInRingtone.catalog) { ringtone in
                RingtoneRow(
                    ringtone: ringtone,
                    isDefault: ringtone.filename == defaultRingtoneFilename,
                    isPlaying: player.currentlyPlayingId == ringtone.id,
                    onPlay: { player.toggle(ringtone: ringtone) },
                    onCopy: { handleCopy(ringtone.filename) },
                    onSetDefault: { setDefaultRingtoneFilename(ringtone.filename) }
                )
            }
        }
    }

    private func handleCopy(_ filename: String) {
        onCopy(filename)
        environment.showToast(
            message: localizationManager.localized("ringtone_filename_copied_placeholder", filename),
            style: .success,
            duration: 1.2
        )
    }

    private func handleImportResult(_ result: Result<[URL], Error>) {
        switch result {
        case let .success(urls):
            guard let url = urls.first else { return }
            Task {
                let outcome = await viewModel.importRingtone(from: url)
                switch outcome {
                case let .success(filename):
                    environment.showToast(
                        message: localizationManager.localized("custom_ringtone_imported_placeholder", filename),
                        style: .success,
                        duration: 1.5
                    )
                case let .failure(error):
                    environment.showToast(
                        message: localizedErrorMessage(for: error),
                        style: .error,
                        duration: 2.0
                    )
                }
            }
        case let .failure(error):
            environment.showToast(
                message: error.localizedDescription,
                style: .error,
                duration: 1.2
            )
        }
    }

    private func localizedErrorMessage(for error: RingtoneImportError) -> String {
        switch error {
        case .appGroupUnavailable:
            return localizationManager.localized("app_group_unavailable_for_ringtone")
        case let .duplicateName(filename):
            return localizationManager.localized("custom_ringtone_duplicate_placeholder", filename)
        case let .unsupportedFormat(ext):
            let formatted = ext.isEmpty ? "*" : ext
            return localizationManager.localized("unsupported_ringtone_format_placeholder", formatted)
        case let .durationTooLong(duration):
            return localizationManager.localized("ringtone_duration_exceeded_placeholder", duration)
        case .unreadable:
            return localizationManager.localized("unable_to_read_ringtone_file")
        case let .copyFailed(reason):
            return localizationManager.localized("failed_to_import_ringtone_placeholder", reason)
        }
    }

    private func handleDelete(_ ringtone: CustomRingtone) {
        viewModel.delete(ringtone: ringtone)
        environment.showToast(
            message: localizationManager.localized("custom_ringtone_deleted_placeholder", ringtone.filename),
            style: .success,
            duration: 1.0
        )
        if ringtone.filename == defaultRingtoneFilename {
            setDefaultRingtoneFilename(AppConstants.fallbackRingtoneFilename)
        }
    }

    private func refreshDefaultRingtoneFilename() async {
        let stored = await environment.dataStore.loadDefaultRingtoneFilename()
        let trimmed = stored?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let resolved = trimmed.isEmpty ? AppConstants.fallbackRingtoneFilename : trimmed
        let isAvailable = viewModel.customRingtones.contains(where: { $0.filename == resolved })
            || BuiltInRingtone.catalog.contains(where: { $0.filename == resolved })
        if !isAvailable {
            defaultRingtoneFilename = AppConstants.fallbackRingtoneFilename
            await environment.updateDefaultRingtoneFilename(AppConstants.fallbackRingtoneFilename)
            return
        }
        defaultRingtoneFilename = resolved
        if trimmed.isEmpty {
            await environment.updateDefaultRingtoneFilename(resolved)
        }
    }

    private func setDefaultRingtoneFilename(_ filename: String) {
        guard filename != defaultRingtoneFilename else { return }
        defaultRingtoneFilename = filename
        environment.showToast(
            message: localizationManager.localized("default_ringtone_set_placeholder", filename),
            style: .success,
            duration: 1.2
        )
        Task { @MainActor in
            await environment.updateDefaultRingtoneFilename(filename)
        }
    }
}

private struct CustomRingtoneRow: View {
    let ringtone: CustomRingtone
    let isDefault: Bool
    let isPlaying: Bool
    let onPlay: () -> Void
    let onCopy: () -> Void
    let onDelete: () -> Void
    let onSetDefault: () -> Void
    @Environment(LocalizationManager.self) private var localizationManager: LocalizationManager

    private var durationText: String {
        String(format: "%.1fs", ringtone.duration)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        if isDefault {
                            Image(systemName: "checkmark")
                                .font(.headline.weight(.semibold))
                                .foregroundStyle(Color.accentColor)
                        }
                        Text(ringtone.displayName)
                            .font(.headline)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if !isDefault {
                            onSetDefault()
                        }
                    }
                }
                Spacer()
                HStack(spacing: 12) {
                    Button {
                        onPlay()
                    } label: {
                        Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.title2.weight(.bold))
                    }
                    .accessibilityLabel(
                        localizationManager.localized(isPlaying ? "pause" : "play")
                    )
                    .buttonStyle(.appBorderless)
                    Button(role: .destructive) {
                        onDelete()
                    } label: {
                        Image(systemName: "trash")
                            .font(.callout.weight(.semibold))
                    }
                    .accessibilityLabel(localizationManager.localized("delete"))
                    .buttonStyle(.appBorderless)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(ringtone.filename)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                Text(localizationManager.localized("ringtone_duration_placeholder", durationText))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                onCopy()
            }
        }
        .padding(.vertical, 6)
    }
}

private struct RingtoneRow: View {
    let ringtone: BuiltInRingtone
    let isDefault: Bool
    let isPlaying: Bool
    let onPlay: () -> Void
    let onCopy: () -> Void
    let onSetDefault: () -> Void
    @Environment(LocalizationManager.self) private var localizationManager: LocalizationManager

    private var soundParameterText: String {
        localizationManager.localized("push_parameters_sound_placeholder", ringtone.filename)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        if isDefault {
                            Image(systemName: "checkmark")
                                .font(.headline.weight(.semibold))
                                .foregroundStyle(Color.accentColor)
                        }
                        Text(ringtone.displayName)
                            .font(.headline)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if !isDefault {
                            onSetDefault()
                        }
                    }
                    Text(localizationManager.localized(ringtone.toneDescription))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                HStack(spacing: 12) {
                    Button {
                        onPlay()
                    } label: {
                        Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.title2.weight(.bold))
                    }
                    .accessibilityLabel(
                        localizationManager.localized(isPlaying ? "pause" : "play")
                    )
                    .buttonStyle(.appBorderless)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(soundParameterText)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                Text(
                    localizationManager.localized(
                        "recommended_scenario_placeholder",
                        localizationManager.localized(ringtone.recommendedUsage),
                    ),
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                onCopy()
            }
        }
        .padding(.vertical, 6)
    }
}

struct BuiltInRingtone: Identifiable, Hashable {
    let id: String
    let displayName: String
    let filename: String
    let toneDescription: String
    let recommendedUsage: String

    var resourceName: String {
        (filename as NSString).deletingPathExtension
    }

    var resourceExtension: String {
        (filename as NSString).pathExtension
    }

    static let catalog: [BuiltInRingtone] = [
        BuiltInRingtone(
            id: "notification-sound",
            displayName: "Notification",
            filename: "notification-sound.caf",
            toneDescription: "concise_notification_ping",
            recommendedUsage: "general_notification_or_community_reminder",
        ),
        BuiltInRingtone(
            id: "alert",
            displayName: "Alert",
            filename: "alert.caf",
            toneDescription: "crisp_alert_beep",
            recommendedUsage: "system_alarm_or_exception_notification",
        ),
        BuiltInRingtone(
            id: "quick-whoosh",
            displayName: "Quick Whoosh",
            filename: "quick-whoosh.caf",
            toneDescription: "quick_whoosh_swipe",
            recommendedUsage: "push_that_needs_attention",
        ),
        BuiltInRingtone(
            id: "pop",
            displayName: "Pop",
            filename: "pop.caf",
            toneDescription: "short_pop_click",
            recommendedUsage: "approval_pending_light_reminder",
        ),
        BuiltInRingtone(
            id: "bubble-pop",
            displayName: "Bubble Pop",
            filename: "bubble-pop.caf",
            toneDescription: "airy_bubble_pop",
            recommendedUsage: "approval_pending_light_reminder",
        ),
        BuiltInRingtone(
            id: "arcade-sound",
            displayName: "Arcade",
            filename: "arcade-sound.caf",
            toneDescription: "retro_arcade_chime",
            recommendedUsage: "push_that_needs_attention",
        ),
        BuiltInRingtone(
            id: "cartoon-blinking",
            displayName: "Cartoon Blink",
            filename: "cartoon-blinking.caf",
            toneDescription: "cartoon_blinking_tick",
            recommendedUsage: "general_notification_or_community_reminder",
        ),
        BuiltInRingtone(
            id: "cute-chime",
            displayName: "Cute Chime",
            filename: "cute-chime.caf",
            toneDescription: "bright_cute_chime",
            recommendedUsage: "general_notification_or_community_reminder",
        ),
        BuiltInRingtone(
            id: "level-up",
            displayName: "Level Up",
            filename: "level-up.caf",
            toneDescription: "upbeat_level_up_tone",
            recommendedUsage: "push_that_needs_attention",
        ),
        BuiltInRingtone(
            id: "festive-chime",
            displayName: "Festive Chime",
            filename: "festive-chime.caf",
            toneDescription: "festive_bell_tone",
            recommendedUsage: "general_notification_or_community_reminder",
        ),
    ]

    static let catalogById: [String: BuiltInRingtone] = Dictionary(
        uniqueKeysWithValues: catalog.map { ($0.id, $0) }
    )
}

@MainActor
@Observable
private final class RingtonePreviewPlayer: NSObject, AVAudioPlayerDelegate {
    var currentlyPlayingId: String?
    private var audioPlayer: AVAudioPlayer?

    func toggle(ringtone: BuiltInRingtone) {
        if currentlyPlayingId == ringtone.id {
            stop()
        } else {
            play(ringtone: ringtone)
        }
    }

    func toggle(custom ringtone: CustomRingtone) {
        if currentlyPlayingId == ringtone.id {
            stop()
        } else {
            play(url: ringtone.url, id: ringtone.id)
        }
    }

    private func play(ringtone: BuiltInRingtone) {
        guard let url = Bundle.main.url(
            forResource: ringtone.resourceName,
            withExtension: ringtone.resourceExtension,
        ) else {
            return
        }
        play(url: url, id: ringtone.id, filename: ringtone.filename)
    }

    private func play(url: URL, id: String, filename: String? = nil) {
        do {
            audioPlayer = try AVAudioPlayer(contentsOf: url)
            audioPlayer?.delegate = self
            audioPlayer?.prepareToPlay()
            audioPlayer?.play()
            currentlyPlayingId = id
        } catch {
            currentlyPlayingId = nil
        }
    }

    func stop() {
        audioPlayer?.stop()
        audioPlayer = nil
        currentlyPlayingId = nil
    }

    func audioPlayerDidFinishPlaying(_: AVAudioPlayer, successfully _: Bool) {
        stop()
    }
}

struct MessagesExportDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.json]
    let messages: [PushMessage]

    init(messages: [PushMessage]) {
        self.messages = messages
    }

    init(configuration: ReadConfiguration) throws {
        guard let file = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        messages = try decoder.decode([PushMessage].self, from: file)
    }

    func fileWrapper(configuration _: WriteConfiguration) throws -> FileWrapper {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(messages)
        return .init(regularFileWithContents: data)
    }
}

private extension View {
    @ViewBuilder
    func modifyScrollIndicators() -> some View {
        self.scrollIndicators(.automatic)
    }
}
