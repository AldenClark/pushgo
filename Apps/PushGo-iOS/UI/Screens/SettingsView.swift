import AVFoundation
import SwiftUI
import UniformTypeIdentifiers
import UIKit
import Observation

struct SettingsView: View {
    @Environment(\.appEnvironment) private var environment: AppEnvironment
    @Environment(LocalizationManager.self) private var localizationManager: LocalizationManager
    @State private var viewModel = SettingsViewModel()
    @State private var activeSheet: SettingsSheet?
    @State private var isExportingMessages = false
    @State private var exportDocument = MessagesExportDocument(messages: [])
    @State private var deferredToast: DeferredToast?

    var body: some View {
        navigationContainer {
            settingsScaffold
        }
        .task {
            viewModel.refresh()
            await environment.refreshMessageCountsAndNotify()
        }
        .onChange(of: environment.pushRegistrationService.authorizationState) { _, _ in
            viewModel.refresh()
        }
        .onChange(of: environment.serverConfig) { _, _ in
            viewModel.refresh()
        }
        .onChange(of: viewModel.successMessage) { _, message in
            guard let message else { return }
            presentToast(message: message, style: .success, duration: 1.5)
            viewModel.successMessage = nil
        }
        .onChange(of: viewModel.error) { _, error in
            guard let error else { return }
            presentToast(
                message: error.errorDescription ?? localizationManager.localized("operation_failed"),
                style: .error,
                duration: 2.5,
            )
            viewModel.error = nil
        }
        .onChange(of: activeSheet) { _, _ in
            flushDeferredToastIfNeeded()
        }
        .sheet(
            isPresented: Binding(
                get: { activeSheet != nil },
                set: { isPresented in
                    if !isPresented {
                        activeSheet = nil
                    }
                }
            )
        ) {
            if activeSheet == .manualKey {
                ManualKeySettingsSheet(viewModel: viewModel)
                    .customAdaptiveDetents()
                    .toastOverlay()
            } else if activeSheet == .channelManagement {
                ChannelManagementSheet()
                    .customAdaptiveDetents()
                    .toastOverlay()
            } else if activeSheet == .serverManagement {
                ServerManagementSheet(viewModel: viewModel)
                    .customAdaptiveDetents()
                    .toastOverlay()
            } else if activeSheet == .ringtone {
                RingtoneGalleryView(onCopy: copyToPasteboard(_:))
                    .customAdaptiveDetents()
                    .toastOverlay()
            }
        }
        .fileExporter(
            isPresented: $isExportingMessages,
            document: exportDocument,
            contentType: .json,
            defaultFilename: exportDefaultFilename,
        ) { result in
            switch result {
            case .success:
                presentToast(
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
        coreLayout
            .navigationTitle(localizationManager.localized("settings"))
            .navigationBarTitleDisplayMode(.large)
    }

    private var coreLayout: some View {
        iosSettingsList
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(settingsBackgroundColor.ignoresSafeArea())
    }

    private var settingsBackgroundColor: Color {
        Color(UIColor.systemBackground)
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

    private var channelSubtitle: LocalizedStringKey {
        let items = environment.channelSubscriptions
        if items.isEmpty {
            return LocalizedStringKey(localizationManager.localized("channels_empty"))
        }
        if items.count == 1, let name = items.first?.displayName {
            return LocalizedStringKey(name)
        }
        return LocalizedStringKey(localizationManager.localized("channels_count_placeholder", items.count))
    }

    @ViewBuilder
    private var iosSettingsList: some View {
        let rowInsets = EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16)
        List {
            if viewModel.notificationStatus != .authorized {
                notificationCard
                    .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 0, trailing: 16))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }

            Button {
                activeSheet = .channelManagement
            } label: {
                SettingsActionRow(
                    iconName: "dot.radiowaves.left.and.right",
                    title: "channels",
                    detail: channelSubtitle,
                ) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.appPlain)
            .listRowInsets(rowInsets)
            .listRowSeparator(viewModel.notificationStatus == .authorized ? .hidden : .visible, edges: .top)
            .listRowBackground(Color.clear)

            Button {
                viewModel.prepareServerEditor()
                activeSheet = .serverManagement
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
            .listRowInsets(rowInsets)
            .listRowBackground(Color.clear)

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
            .listRowInsets(rowInsets)
            .listRowBackground(Color.clear)

            Toggle(isOn: $viewModel.autoCleanupEnabled) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "sparkles")
                        .font(.callout.weight(.semibold))
                        .frame(width: 32, height: 32)
                        .foregroundStyle(Color.accentColor)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color.accentColor.opacity(0.12))
                        )

                    VStack(alignment: .leading, spacing: 6) {
                        Text(localizationManager.localized("auto_cleanup_messages"))
                            .font(.headline)
                            .foregroundStyle(.primary)
                            .multilineTextAlignment(.leading)
                            .lineLimit(2)
                            .minimumScaleFactor(0.85)
                        Text(localizationManager.localized("auto_cleanup_messages_hint"))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.vertical, 14)
            .listRowInsets(rowInsets)
            .listRowBackground(Color.clear)

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
            .disabled(environment.totalMessageCount == 0)
            .listRowInsets(rowInsets)
            .listRowBackground(Color.clear)

            Button {
                activeSheet = .manualKey
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
            .listRowInsets(rowInsets)
            .listRowBackground(Color.clear)

            Button {
                activeSheet = .ringtone
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
            .listRowInsets(rowInsets)
            .listRowBackground(Color.clear)

            SettingsActionRow(
                iconName: "info.circle",
                title: "app_version",
                detail: appVersionDetail,
            )
            .listRowInsets(rowInsets)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden, edges: .bottom)
        }
        .listSectionSeparator(.hidden, edges: [.top, .bottom])
        .listStyle(.plain)
        .listRowSeparatorTint(Color.primary.opacity(0.12))
        .scrollContentBackground(.hidden)
        .background(Color.clear)
    }

    @ViewBuilder
    private var notificationCard: some View {
        switch viewModel.notificationStatus {
        case .authorized:
            EmptyView()
        case .notDetermined:
            cardContainer {
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
            }
        case .denied:
            cardContainer {
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
    }

    private func cardHeader<Trailing: View>(
        iconName: String,
        title: LocalizedStringKey,
        subtitle: LocalizedStringKey? = nil,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: iconName)
                .font(.callout.weight(.semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 34, height: 34)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.accentColor.opacity(0.15))
                )
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                if let subtitle {
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            trailing()
        }
    }

    private func statusPill(text: LocalizedStringKey, color: Color) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(text)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            Capsule()
                .fill(color.opacity(0.12))
        )
    }

    private func cardContainer<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            content()
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(UIColor.secondarySystemBackground),
                            Color(UIColor.secondarySystemBackground).opacity(0.9),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.06), radius: 10, x: 0, y: 6)
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

    @MainActor
    private func presentToast(
        message: String,
        style: AppEnvironment.ToastMessage.Style,
        duration: TimeInterval
    ) {
        if activeSheet != nil {
            deferredToast = DeferredToast(message: message, style: style, duration: duration)
            return
        }
        environment.showToast(message: message, style: style, duration: duration)
    }

    @MainActor
    private func flushDeferredToastIfNeeded() {
        guard activeSheet == nil, let toast = deferredToast else { return }
        deferredToast = nil
        environment.showToast(message: toast.message, style: toast.style, duration: toast.duration)
    }

    private func statusText(for status: PushRegistrationService.AuthorizationState) -> LocalizedStringKey {
        switch status {
        case .authorized:
            LocalizedStringKey(localizationManager.localized("already_turned_on"))
        case .denied:
            LocalizedStringKey(localizationManager.localized("not_turned_on"))
        case .notDetermined:
            LocalizedStringKey(localizationManager.localized("to_be_confirmed"))
        }
    }

    private func statusColor(for status: PushRegistrationService.AuthorizationState) -> Color {
        switch status {
        case .authorized:
            Color.accentColor
        case .denied:
            .red
        case .notDetermined:
            Color.accentColor.opacity(0.7)
        }
    }

    private func copyToPasteboard(_ text: String) {
        UIPasteboard.general.string = text
    }

    private func openNotificationSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
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

private struct DeferredToast: Equatable {
    let message: String
    let style: AppEnvironment.ToastMessage.Style
    let duration: TimeInterval
}

private enum SettingsSheet: Identifiable {
    case manualKey
    case channelManagement
    case serverManagement
    case ringtone

    var id: String {
        switch self {
        case .manualKey:
            "manualKey"
        case .channelManagement:
            "channelManagement"
        case .serverManagement:
            "serverManagement"
        case .ringtone:
            "ringtone"
        }
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
    @Environment(\.isEnabled) private var isEnabled

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
        .opacity(isEnabled ? 1 : 0.45)
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

private struct ManualKeySettingsSheet: View {
    @Bindable var viewModel: SettingsViewModel
    @Environment(LocalizationManager.self) private var localizationManager: LocalizationManager

    var body: some View {
        navigationContainer {
            ManualKeySettingsContentView(viewModel: viewModel)
                .navigationTitle(localizationManager.localized("message_encryption"))
        }
    }
}

private struct ServerManagementSheet: View {
    @Bindable var viewModel: SettingsViewModel
    @Environment(LocalizationManager.self) private var localizationManager: LocalizationManager

    var body: some View {
        navigationContainer {
            ServerManagementContentView(viewModel: viewModel)
                .navigationTitle(localizationManager.localized("server_management"))
        }
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
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                        .keyboardType(.URL)
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
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
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
        .background(Color.clear.contentShape(Rectangle()).onTapGesture { focusedField = nil })
    }
}

private enum ServerField: Hashable {
    case address
    case token
}

private struct ChannelManagementSheet: View {
    @Environment(\.appEnvironment) private var environment: AppEnvironment
    @Environment(LocalizationManager.self) private var localizationManager: LocalizationManager
    @Environment(\.dismiss) private var dismiss
    @State private var pendingRemoval: ChannelSubscription?
    @State private var isRemoving = false
    @State private var pendingRename: ChannelSubscription?
    @State private var renameAlias: String = ""
    @State private var isRenaming = false
    @State private var activeModal: ChannelModal?
    @State private var autoCleanupEnabled = true

    var body: some View {
        navigationContainer {
            List {
                channelList
            }
            .listStyle(.insetGrouped)
            .navigationTitle(localizationManager.localized("channels"))
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button(localizationManager.localized("create_channel")) {
                            activeModal = .create
                        }
                        Button(localizationManager.localized("subscribe_channel")) {
                            activeModal = .subscribe
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel(localizationManager.localized("add_channel"))
                    .menuIndicator(.hidden)
                }
            }
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
        .sheet(item: $activeModal) { modal in
            switch modal {
            case .create:
                ChannelCreateSheet(onSuccess: { activeModal = nil })
                    .customAdaptiveDetents()
                    .toastOverlay()
            case .subscribe:
                ChannelSubscribeSheet(onSuccess: { activeModal = nil })
                    .customAdaptiveDetents()
                    .toastOverlay()
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

    private var channelList: some View {
        Section {
            if environment.channelSubscriptions.isEmpty {
                Text(localizationManager.localized("channels_empty"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(environment.channelSubscriptions) { subscription in
                    channelRow(subscription)
                }
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
        .onTapGesture {
            copyChannelId(channelId)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
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
                .tint(.orange)
            }

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
        UIPasteboard.general.string = value
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
    @Environment(\.dismiss) private var dismiss
    @State private var channelAlias: String = ""
    @State private var channelPassword: String = ""
    @State private var isPasswordVisible = false
    @State private var isSaving = false
    private var isPasswordValid: Bool {
        (try? ChannelPasswordValidator.validate(channelPassword)) != nil
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    AppFormField(titleText: localizationManager.localized("channel_name")) {
                        TextField(
                            "",
                            text: $channelAlias,
                            prompt: AppFieldPrompt.text(localizationManager.localized("channel_name_placeholder"))
                        )
                        .textFieldStyle(.plain)
                        .textInputAutocapitalization(.sentences)
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
                            .textInputAutocapitalization(.never)
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
            .navigationTitle(localizationManager.localized("create_channel"))
        }
    }

    @MainActor
    private func createChannel() async {
        guard !isSaving else { return }
        isSaving = true
        defer { isSaving = false }

        do {
            let result = try await environment.createChannel(
                alias: channelAlias,
                password: channelPassword
            )
            let messageKey = result.created ? "channel_created_and_subscribed" : "channel_subscribed"
            dismiss()
            onSuccess?()
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 150_000_000)
                environment.showToast(
                    message: localizationManager.localized(messageKey),
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
}

private struct ChannelSubscribeSheet: View {
    let onSuccess: (() -> Void)?

    @Environment(\.appEnvironment) private var environment: AppEnvironment
    @Environment(LocalizationManager.self) private var localizationManager: LocalizationManager
    @Environment(\.dismiss) private var dismiss
    @State private var channelId: String = ""
    @State private var channelPassword: String = ""
    @State private var isPasswordVisible = false
    @State private var isSaving = false
    private var isPasswordValid: Bool {
        (try? ChannelPasswordValidator.validate(channelPassword)) != nil
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    AppFormField(titleText: localizationManager.localized("channel_id")) {
                        TextField(
                            "",
                            text: $channelId,
                            prompt: AppFieldPrompt.text(localizationManager.localized("channel_id_placeholder"))
                        )
                        .textFieldStyle(.plain)
                        .textInputAutocapitalization(.never)
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
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled(true)

                            Button {
                                isPasswordVisible.toggle()
                            } label: {
                                Image(systemName: isPasswordVisible ? "eye.slash" : "eye")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.appPlain)
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
            .navigationTitle(localizationManager.localized("subscribe_channel"))
        }
    }

    @MainActor
    private func subscribeChannel() async {
        guard !isSaving else { return }
        isSaving = true
        defer { isSaving = false }

        do {
            _ = try await environment.subscribeChannel(
                channelId: channelId,
                password: channelPassword
            )
            dismiss()
            onSuccess?()
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 150_000_000)
                environment.showToast(
                    message: localizationManager.localized("channel_subscribed"),
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
        .background(Color.clear.contentShape(Rectangle()).onTapGesture { sheetFocus = nil })
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
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)

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
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)

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

private struct SheetHeader: View {
    let title: LocalizedStringKey

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.title3.weight(.semibold))
            Spacer()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(Divider(), alignment: .bottom)
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
        Task { @MainActor in
            await refresh()
        }
    }

    func refresh() async {
        guard let soundsDirectory = try? soundsDirectory() else {
            customRingtones = []
            return
        }

        let fileURLs = (try? fileManager.contentsOfDirectory(
            at: soundsDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []

        var items: [CustomRingtone] = []
        for url in fileURLs {
            let filename = url.lastPathComponent
            guard !filename.hasPrefix(AppConstants.longRingtonePrefix) else { continue }
            let ext = url.pathExtension.lowercased()
            guard Self.allowedExtensions.contains(ext) else { continue }
            guard let duration = try? await Self.audioDuration(of: url) else { continue }
            items.append(CustomRingtone(
                id: filename,
                filename: filename,
                url: url,
                duration: duration
            ))
        }

        customRingtones = items.sorted { lhs, rhs in
            lhs.filename.localizedCaseInsensitiveCompare(rhs.filename) == .orderedAscending
        }
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
            await refresh()
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

    private static func audioDuration(of url: URL) async throws -> TimeInterval {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        let seconds = CMTimeGetSeconds(duration)
        guard seconds.isFinite, seconds > 0 else {
            throw RingtoneImportError.unreadable
        }
        return seconds
    }

    func delete(ringtone: CustomRingtone) async {
        do {
            try fileManager.removeItem(at: ringtone.url)
            await refresh()
        } catch {
            await refresh()
        }
    }
}

private struct RingtoneGalleryView: View {
    let onCopy: (String) -> Void
    @State private var player = RingtonePreviewPlayer()
    @Environment(LocalizationManager.self) private var localizationManager: LocalizationManager

    var body: some View {
        sheetContainer
            .onDisappear {
                player.stop()
            }
    }

    private var sheetContainer: some View {
        navigationContainer {
            sheetScaffold
        }
    }

    @ViewBuilder
    private var sheetScaffold: some View {
        content
            .navigationTitle(localizationManager.localized("built_in_ringtone"))
    }

    private var content: some View {
        RingtoneGalleryContent(player: player, onCopy: onCopy)
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
        .modifier(PlatformListStyle())
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
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
            await viewModel.refresh()
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
        Task { @MainActor in
            await viewModel.delete(ringtone: ringtone)
            if ringtone.filename == defaultRingtoneFilename {
                setDefaultRingtoneFilename(AppConstants.fallbackRingtoneFilename)
            }
        }
        environment.showToast(
            message: localizationManager.localized("custom_ringtone_deleted_placeholder", ringtone.filename),
            style: .success,
            duration: 1.0
        )
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
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                onDelete()
            } label: {
                Text(localizationManager.localized("delete"))
            }
        }
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
            try AVAudioSession.sharedInstance().setCategory(.ambient, options: [.mixWithOthers])
            try AVAudioSession.sharedInstance().setActive(true, options: [])
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
    func customAdaptiveDetents() -> some View {
        self
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
    }

    @ViewBuilder
    func modifyScrollIndicators() -> some View {
        self.scrollIndicators(.automatic)
    }
}

private struct PlatformListStyle: ViewModifier {
    func body(content: Content) -> some View {
        content.listStyle(.insetGrouped)
    }
}
