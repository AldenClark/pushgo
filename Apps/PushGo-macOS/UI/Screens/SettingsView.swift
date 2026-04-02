import AppKit
import SwiftUI
import UniformTypeIdentifiers
import Observation

struct SettingsView: View {
    @Environment(AppEnvironment.self) private var environment: AppEnvironment
    @Environment(LocalizationManager.self) private var localizationManager: LocalizationManager
    @State private var viewModel = SettingsViewModel()
    @State private var macOverlay: MacOverlay?

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
                    .accessibilityIdentifier("action.settings.server_management")
                    SettingsRowDivider()
                    DataPageSwitchGroupRow(
                        title: "enable_data_pages",
                        messageTitle: LocalizedStringKey(localizationManager.localized("messages")),
                        eventTitle: LocalizedStringKey(localizationManager.localized("push_type_event")),
                        thingTitle: LocalizedStringKey(localizationManager.localized("push_type_thing")),
                        messageIsOn: messagePageVisibilityBinding,
                        eventIsOn: eventPageVisibilityBinding,
                        thingIsOn: thingPageVisibilityBinding
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
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.appPlain)
                    .accessibilityIdentifier("action.settings.open_decryption")
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

    private var messagePageVisibilityBinding: Binding<Bool> {
        Binding(
            get: { environment.isMessagePageEnabled },
            set: { environment.setMessagePageEnabled($0) }
        )
    }

    private var eventPageVisibilityBinding: Binding<Bool> {
        Binding(
            get: { environment.isEventPageEnabled },
            set: { environment.setEventPageEnabled($0) }
        )
    }

    private var thingPageVisibilityBinding: Binding<Bool> {
        Binding(
            get: { environment.isThingPageEnabled },
            set: { environment.setThingPageEnabled($0) }
        )
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

private struct SettingsRowDivider: View {
    private let leadingInset: CGFloat = 48

    var body: some View {
        Divider()
            .padding(.leading, leadingInset)
            .padding(.vertical, 18)
    }
}

private struct DataPageSwitchGroupRow: View {
    let title: LocalizedStringKey
    let messageTitle: LocalizedStringKey
    let eventTitle: LocalizedStringKey
    let thingTitle: LocalizedStringKey
    @Binding var messageIsOn: Bool
    @Binding var eventIsOn: Bool
    @Binding var thingIsOn: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "square.3.layers.3d.top.filled")
                .font(.callout.weight(.semibold))
                .frame(width: 32, height: 32)
                .foregroundStyle(Color.accentColor)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.accentColor.opacity(0.12))
                )

            Text(title)
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)

            HStack(spacing: 8) {
                DataPageSwitchChip(
                    title: messageTitle,
                    isOn: $messageIsOn,
                    accessibilityID: "toggle.settings.page.messages"
                )
                DataPageSwitchChip(
                    title: eventTitle,
                    isOn: $eventIsOn,
                    accessibilityID: "toggle.settings.page.events"
                )
                DataPageSwitchChip(
                    title: thingTitle,
                    isOn: $thingIsOn,
                    accessibilityID: "toggle.settings.page.things"
                )
            }
        }
        .padding(.vertical, 14)
    }
}

private struct DataPageSwitchChip: View {
    let title: LocalizedStringKey
    @Binding var isOn: Bool
    let accessibilityID: String

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            HStack(spacing: 4) {
                if isOn {
                    Image(systemName: "checkmark")
                        .font(.footnote.weight(.bold))
                }
                Text(title)
                    .lineLimit(1)
            }
            .font(.footnote.weight(.semibold))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .foregroundStyle(isOn ? Color.accentColor : Color.secondary)
            .background(
                Capsule()
                    .fill(isOn ? Color.accentColor.opacity(0.18) : Color.clear)
            )
            .overlay(
                Capsule()
                    .stroke(
                        isOn ? Color.accentColor.opacity(0.4) : Color.primary.opacity(0.16),
                        lineWidth: 1
                    )
            )
        }
        .buttonStyle(.appPlain)
        .accessibilityIdentifier(accessibilityID)
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
        @ViewBuilder trailing: @escaping () -> Trailing
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

private extension SettingsActionRow where Trailing == EmptyView {
    init(
        iconName: String,
        title: LocalizedStringKey,
        detail: LocalizedStringKey? = nil,
        style: Style = .plain
    ) {
        self.init(
            iconName: iconName,
            title: title,
            detail: detail,
            style: style
        ) {
            EmptyView()
        }
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
                Text(localizationManager.localized("server_management_gateway_switch_warning"))
                    .font(.footnote)
                    .foregroundColor(.secondary)
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
                    .foregroundColor(.secondary)
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
