import AppKit
import SwiftUI
import UniformTypeIdentifiers
import Observation

struct SettingsView: View {
    @Environment(AppEnvironment.self) private var environment: AppEnvironment
    @Environment(LocalizationManager.self) private var localizationManager: LocalizationManager
    @Environment(\.openURL) private var openURL
    @State private var viewModel = SettingsViewModel()
    @State private var macOverlay: MacOverlay?
    @State private var betaChannelEnabled: Bool = false

    var body: some View {
        navigationContainer {
            coreLayout
                .navigationTitle(localizationManager.localized("settings"))
        }
        .accessibilityIdentifier("screen.settings")
        .sheet(item: $macOverlay) { overlay in
            macOverlaySheet(for: overlay)
        }
        .task {
            await environment.refreshLaunchAtLoginStatus()
            viewModel.refresh()
            betaChannelEnabled = environment.betaChannelEnabled
        }
        .onChange(of: environment.pushRegistrationService.authorizationState) { _, _ in
            viewModel.refresh()
        }
        .onChange(of: environment.serverConfig) { _, _ in
            viewModel.refresh()
        }
        .onChange(of: environment.launchAtLoginEnabled) { _, _ in
            viewModel.refresh()
        }
        .onChange(of: environment.betaChannelEnabled) { _, value in
            betaChannelEnabled = value
        }
        .onChange(of: betaChannelEnabled) { _, value in
            environment.setBetaChannelEnabled(value)
        }
        .onChange(of: viewModel.successMessage) { _, message in
            guard let message else { return }
            environment.showToast(message: message, style: .success, duration: 1.5)
            if macOverlay == .manualKey {
                closeMacOverlay()
            }
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
#if DEBUG
        .task {
            for await _ in NotificationCenter.default.notifications(named: .pushgoAutomationOpenSettingsDecryption) {
                macOverlay = .manualKey
            }
        }
        .task(id: automationStateSignature) {
            PushGoAutomationRuntime.shared.publishState(
                environment: environment,
                activeTab: "settings",
                visibleScreen: macOverlay == .manualKey ? "screen.settings.decryption" : "screen.settings"
            )
        }
#endif
    }

    @ViewBuilder
    private func macOverlaySheet(for overlay: MacOverlay) -> some View {
        switch overlay {
        case .manualKey:
            ManualKeySettingsContentView(viewModel: viewModel)
                .frame(width: 520)
                .toastOverlay(environment: environment)
        case .serverManagement:
            ServerManagementContentView(viewModel: viewModel)
                .frame(width: 520)
                .toastOverlay(environment: environment)
        }
    }

    private func closeMacOverlay() {
        macOverlay = nil
    }

    private var coreLayout: some View {
        settingsList
        .background(settingsBackgroundColor)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var settingsBackgroundColor: Color {
        Color.appWindowBackground
    }

    private var appVersionDetail: LocalizedStringKey {
        LocalizedStringKey(AppVersionDisplay.current())
    }

    private var settingsList: some View {
        @Bindable var bindableEnvironment = environment
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
                            AppIconTile(systemName: "power")

                            VStack(alignment: .leading, spacing: 2) {
                                Text("launch_at_login")
                                    .font(.headline)
                                    .foregroundStyle(.primary)
                                    .multilineTextAlignment(.leading)
                                    .lineLimit(2)
                                    .minimumScaleFactor(0.85)

                                Text("launch_at_login_detail")
                                    .font(.footnote)
                                    .foregroundStyle(Color.appTextSecondary)
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
                                .foregroundStyle(Color.appTextSecondary)
                        }
                    }
                    .buttonStyle(.appPlain)
                    .accessibilityIdentifier("action.settings.server_management")
                    SettingsRowDivider()
                    DataPageToggleGroupRow(
                        iconName: "square.3.layers.3d.top.filled",
                        title: "enable_data_pages",
                        messageTitle: LocalizedStringKey(localizationManager.localized("messages")),
                        eventTitle: LocalizedStringKey(localizationManager.localized("push_type_event")),
                        thingTitle: LocalizedStringKey(localizationManager.localized("push_type_thing")),
                        messageIsOn: $bindableEnvironment.messagePageEnabled,
                        eventIsOn: $bindableEnvironment.eventPageEnabled,
                        thingIsOn: $bindableEnvironment.thingPageEnabled
                    )
                    .accessibilityIdentifier("group.settings.page_visibility")
                    SettingsRowDivider()
                    Button {
                        macOverlay = .manualKey
                    } label: {
                        SettingsActionRow(
                            iconName: "lock.square.stack",
                            title: "message_decryption",
                            detail: manualKeyStatusText,
                        ) {
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Color.appTextSecondary)
                        }
                    }
                    .buttonStyle(.appPlain)
                    .accessibilityIdentifier("action.settings.open_decryption")
                    if environment.supportsInAppUpdates {
                        SettingsRowDivider()
                        Button {
                            environment.checkForUpdatesFromSettings()
                        } label: {
                            SettingsActionRow(
                                iconName: "arrow.triangle.2.circlepath.circle",
                                title: "检查更新",
                                detail: "检查并安装可用的新版本",
                            ) {
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(Color.appTextSecondary)
                            }
                        }
                        .buttonStyle(.appPlain)
                        .accessibilityIdentifier("action.settings.check_for_updates")
                        SettingsRowDivider()
                        SettingsControlRow(
                            iconName: "flask",
                            title: "启用 beta 版本",
                            detail: "启用后将接收 sparkle:channel=beta 的更新；开启时会立即后台检查一次。",
                            useFormField: false
                        ) {
                            Toggle("", isOn: $betaChannelEnabled)
                                .toggleStyle(.switch)
                                .labelsHidden()
                        }
                        .accessibilityIdentifier("toggle.settings.beta_channel")
                    }
                    SettingsRowDivider()
                    Button {
                        openURL(AppConstants.documentationURL(.gettingStarted))
                    } label: {
                        SettingsActionRow(
                            iconName: "sparkles",
                            title: "open_getting_started_docs",
                            detail: "open_getting_started_docs_detail",
                        ) {
                            Image(systemName: "arrow.up.right.square")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Color.appTextSecondary)
                        }
                    }
                    .buttonStyle(.appPlain)
                    .accessibilityIdentifier("action.settings.open_getting_started_docs")
                    SettingsRowDivider()
                    Button {
                        openURL(AppConstants.documentationURL(.messageAPI))
                    } label: {
                        SettingsActionRow(
                            iconName: "book",
                            title: "open_developer_api_docs",
                            detail: "open_developer_api_docs_detail",
                        ) {
                            Image(systemName: "arrow.up.right.square")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Color.appTextSecondary)
                        }
                    }
                    .buttonStyle(.appPlain)
                    .accessibilityIdentifier("action.settings.open_developer_api_docs")
                    SettingsRowDivider()
                    Button {
                        openURL(AppConstants.documentationURL(.e2ee))
                    } label: {
                        SettingsActionRow(
                            iconName: "lock.doc",
                            title: "open_e2ee_docs",
                            detail: "open_e2ee_docs_detail",
                        ) {
                            Image(systemName: "arrow.up.right.square")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Color.appTextSecondary)
                        }
                    }
                    .buttonStyle(.appPlain)
                    .accessibilityIdentifier("action.settings.open_e2ee_docs")
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
        .background(settingsBackgroundColor.ignoresSafeArea())
    }

    private func cardContainer<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            content()
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.appSurfaceRaised)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.appCardBorder, lineWidth: 1)
        )
        .shadow(color: Color.appSoftShadow, radius: 10, x: 0, y: 6)
    }

    private var manualKeyStatusText: LocalizedStringKey {
        if viewModel.notificationKeyMaterial?.isConfigured == true {
            return LocalizedStringKey(localizationManager.localized("aes_gcm_configured"))
        }
        return LocalizedStringKey(localizationManager.localized("not_configured"))
    }

    private var serverConfigSubtitle: LocalizedStringKey {
        let value = environment.serverConfig?.baseURL.absoluteString ?? AppConstants.defaultServerAddress
        return LocalizedStringKey(value)
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
                        AppIconTile(
                            systemName: "bell.badge",
                            size: 28,
                            cornerRadius: 8,
                            font: .subheadline.weight(.semibold)
                        )
                            .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(localizationManager.localized("request_notification_permission"))
                            .font(.headline)
                            .foregroundStyle(.primary)
                        Text(localizationManager.localized("the_system_will_pop_up_an_authorization_prompt"))
                            .font(.footnote)
                            .foregroundStyle(Color.appTextSecondary)
                    }
                    Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.appTextSecondary)
                            .accessibilityHidden(true)
                }
            }
            .buttonStyle(.appPlain)
        case .denied:
                Button {
                    openNotificationSettings()
                } label: {
                HStack(spacing: 12) {
                        AppIconTile(
                            systemName: "bell.slash",
                            foreground: AppSemanticTone.danger.foreground,
                            background: .appDangerIconBackground,
                            size: 28,
                            cornerRadius: 8,
                            font: .subheadline.weight(.semibold)
                        )
                            .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(localizationManager.localized("please_enable_notification_permission_in_system_settings_first"))
                            .font(.headline)
                            .foregroundStyle(.primary)
                        Text(localizationManager.localized("system_notification_permission_is_not_obtained_please_turn_on_notifications_in_the_system_settings_and_try_again"))
                            .font(.footnote)
                            .foregroundStyle(Color.appTextSecondary)
                            .lineLimit(2)
                    }
                    Spacer()
                        Image(systemName: "arrow.up.right.square")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.appTextSecondary)
                            .accessibilityHidden(true)
                }
            }
            .buttonStyle(.appPlain)
        }
    }

#if DEBUG
    private var automationStateSignature: String {
        [
            macOverlay == .manualKey ? "manualKey" : "root",
            viewModel.manualKeyInput.hasConfiguredKey ? "configured" : "empty",
            viewModel.manualKeyInput.encoding.rawValue,
        ].joined(separator: "|")
    }
#endif

    private func openNotificationSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") else { return }
        _ = PushGoSystemInteraction.openExternalURL(url)
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
                Text(localizationManager.localized("server_management"))
                    .font(.title3.weight(.semibold))
                    .frame(maxWidth: .infinity, alignment: .leading)

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
                                .foregroundStyle(Color.appTextSecondary)
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
                                .foregroundStyle(Color.appTextSecondary)
                        }
                        .buttonStyle(.appPlain)
                        .accessibilityLabel(
                            LocalizedStringKey(viewModel.gatewayInput.isTokenVisible ? "hide_key" : "show_key")
                        )
                    }
                }
                Text(localizationManager.localized("server_management_gateway_switch_warning"))
                    .font(.footnote)
                    .foregroundStyle(Color.appTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 12) {
                    Spacer(minLength: 0)

                    AppActionButton(
                        title: localizationManager.localized("cancel"),
                        variant: .secondary,
                        fullWidth: false
                    ) {
                        closeSheet()
                    }
                    .disabled(viewModel.isSavingServerConfig)

                    AppActionButton(
                        text: Text(localizationManager.localized("save_configuration"))
                            .font(.headline),
                        variant: .primary,
                        isLoading: viewModel.isSavingServerConfig,
                        fullWidth: false
                    ) {
                        focusedField = nil
                        Task { await viewModel.saveServerConfig() }
                    }
                    .disabled(viewModel.isSavingServerConfig)
                }
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

    private func closeSheet() {
        focusedField = nil
        if let onDismiss {
            onDismiss()
        } else {
            dismiss()
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
    @Environment(\.dismiss) private var dismiss
    @FocusState private var sheetFocus: ManualSheetField?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text(localizationManager.localized("message_decryption"))
                    .font(.title3.weight(.semibold))
                    .frame(maxWidth: .infinity, alignment: .leading)
                keyEncodingPicker
                keyField
                Text(localizationManager
                    .localized(
                        "only_aes_gcm_is_supported_iv_needs_to_be_included_by_the_sender_and_the_key_length_must_exactly_match_the_selected_number_of_bits",
                    ))
                    .font(.footnote)
                    .foregroundStyle(Color.appTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 12) {
                    Spacer(minLength: 0)

                    AppActionButton(
                        title: localizationManager.localized("cancel"),
                        variant: .secondary,
                        fullWidth: false
                    ) {
                        sheetFocus = nil
                        dismiss()
                    }
                    .disabled(viewModel.isSaving)

                    AppActionButton(
                        text: Text(localizationManager.localized("save_configuration"))
                            .font(.headline),
                        variant: .primary,
                        isLoading: viewModel.isSaving,
                        fullWidth: false
                    ) {
                        Task { await viewModel.saveManualKeyConfig() }
                    }
                    .disabled(viewModel.isSaving)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityIdentifier("screen.settings.decryption")
    }

    @ViewBuilder
    private var keyEncodingPicker: some View {
        AppLabeledField(titleText: localizationManager.localized("key_format")) {
            Picker("", selection: $viewModel.manualKeyInput.encoding) {
                ForEach(SettingsViewModel.KeyEncoding.allCases) { encoding in
                    Text(encoding.displayName).tag(encoding)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityLabel(Text(localizationManager.localized("key_format")))
        }
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

private enum MacOverlay: String, Identifiable, Equatable {
    case manualKey
    case serverManagement

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .manualKey:
            "message_decryption"
        case .serverManagement:
            "server_management"
        }
    }
}

struct MessagesExportDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.json]
    private enum Source {
        case messages([PushMessage])
        case preparedFile(URL)
    }
    private let source: Source

    init(messages: [PushMessage]) {
        source = .messages(messages)
    }

    init(preparedFileURL: URL) {
        source = .preparedFile(preparedFileURL)
    }

    init(configuration: ReadConfiguration) throws {
        guard let file = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        source = .messages(try decoder.decode([PushMessage].self, from: file))
    }

    func fileWrapper(configuration _: WriteConfiguration) throws -> FileWrapper {
        switch source {
        case let .messages(messages):
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(messages)
            return .init(regularFileWithContents: data)
        case let .preparedFile(url):
            return try FileWrapper(url: url, options: .immediate)
        }
    }
}

struct MessageJSONExportStreamWriter {
    private let fileURL: URL
    private var fileHandle: FileHandle?
    private let encoder: JSONEncoder
    private var wroteAnyRecord = false
    private(set) var exportedCount = 0

    init(filenamePrefix: String) throws {
        let temporaryFileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(filenamePrefix)-\(UUID().uuidString).json")
        guard FileManager.default.createFile(atPath: temporaryFileURL.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        fileURL = temporaryFileURL
        fileHandle = try FileHandle(forWritingTo: temporaryFileURL)
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try write(Data("[\n".utf8))
    }

    mutating func append(_ messages: [PushMessage]) throws {
        guard !messages.isEmpty else { return }
        for message in messages {
            if wroteAnyRecord {
                try write(Data(",\n".utf8))
            }
            let encoded = try encoder.encode(message)
            try write(encoded)
            wroteAnyRecord = true
            exportedCount += 1
        }
    }

    mutating func finish() throws -> URL {
        try write(Data("\n]".utf8))
        try closeFileHandle()
        return fileURL
    }

    mutating func discard() {
        try? closeFileHandle()
        try? FileManager.default.removeItem(at: fileURL)
    }

    private mutating func closeFileHandle() throws {
        try fileHandle?.close()
        fileHandle = nil
    }

    private func write(_ data: Data) throws {
        guard let fileHandle else {
            throw CocoaError(.fileWriteUnknown)
        }
        try fileHandle.write(contentsOf: data)
    }
}
