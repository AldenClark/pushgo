import SwiftUI
import UniformTypeIdentifiers
import UIKit
import Observation

struct SettingsView: View {
    private let embedInNavigationContainer: Bool
    private let openDecryptionOnAppear: Bool
    @Environment(AppEnvironment.self) private var environment: AppEnvironment
    @Environment(\.scenePhase) private var scenePhase
    @Environment(LocalizationManager.self) private var localizationManager: LocalizationManager
    @State private var viewModel = SettingsViewModel()
    @State private var activeSheet: SettingsSheet?
    @State private var deferredToast: DeferredToast?
    @State private var watchStandaloneToggleValue = false
    @State private var pendingWatchStandaloneToggleTarget: Bool?
    @State private var isPresentingWatchStandaloneConfirmation = false

    init(embedInNavigationContainer: Bool = true, openDecryptionOnAppear: Bool = false) {
        self.embedInNavigationContainer = embedInNavigationContainer
        self.openDecryptionOnAppear = openDecryptionOnAppear
    }

    var body: some View {
        settingsRoot
        .overlay {
            if viewModel.isSwitchingWatchMode {
                watchModeSwitchingOverlay
            }
        }
        .accessibilityIdentifier("screen.settings")
        .task {
            await environment.refreshWatchCompanionAvailability()
            refreshViewModelState()
            await environment.refreshMessageCountsAndNotify()
            if openDecryptionOnAppear, activeSheet == nil {
                activeSheet = .manualKey
            }
        }
        .onChange(of: environment.pushRegistrationService.authorizationState) { _, _ in
            refreshViewModelState()
        }
        .onChange(of: environment.serverConfig) { _, _ in
            refreshViewModelState()
        }
        .onChange(of: watchStateRefreshSignature) { _, _ in
            refreshViewModelState()
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else { return }
            Task {
                await environment.refreshWatchCompanionAvailability()
                refreshViewModelState()
            }
        }
        .onChange(of: viewModel.successMessage) { _, message in
            guard let message else { return }
            if activeSheet == .manualKey {
                activeSheet = nil
            }
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
#if DEBUG
        .task(id: automationStateSignature) {
            PushGoAutomationRuntime.shared.publishState(
                environment: environment,
                activeTab: "settings",
                visibleScreen: activeSheet == .manualKey ? "screen.settings.decryption" : "screen.settings"
            )
        }
#endif
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
                    .presentationDetents([.medium])
                    .presentationDragIndicator(.visible)
                    .toastOverlay(environment: environment)
            } else if activeSheet == .serverManagement {
                ServerManagementSheet(viewModel: viewModel)
                    .presentationDetents([.medium])
                    .presentationDragIndicator(.visible)
                    .toastOverlay(environment: environment)
            }
        }
        .alert(
            localizationManager.localized(
                (pendingWatchStandaloneToggleTarget ?? false)
                    ? "watch_standalone_confirm_enable_title"
                    : "watch_standalone_confirm_disable_title"
            ),
            isPresented: $isPresentingWatchStandaloneConfirmation,
        ) {
            Button(localizationManager.localized("cancel"), role: .cancel) {
                cancelWatchStandaloneModeChange()
            }
            Button(
                localizationManager.localized(
                    (pendingWatchStandaloneToggleTarget ?? false)
                        ? "watch_standalone_confirm_enable_action"
                        : "watch_standalone_confirm_disable_action"
                )
            ) {
                guard let target = pendingWatchStandaloneToggleTarget else {
                    cancelWatchStandaloneModeChange()
                    return
                }
                Task {
                    await viewModel.setStandaloneModeEnabled(target)
                    refreshViewModelState()
                    pendingWatchStandaloneToggleTarget = nil
                }
            }
        } message: {
            Text(localizationManager.localized("watch_standalone_confirm_message"))
        }
    }

    @ViewBuilder
    private var settingsRoot: some View {
        if embedInNavigationContainer {
            navigationContainer {
                settingsScaffold
            }
        } else {
            settingsScaffold
        }
    }

    @ViewBuilder
    private var settingsScaffold: some View {
        coreLayout
            .navigationTitle(localizationManager.localized("settings"))
            .navigationBarTitleDisplayMode(.inline)
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
            .accessibilityIdentifier("action.settings.server_management")
            .listRowInsets(rowInsets)
            .listRowSeparator(viewModel.notificationStatus == .authorized ? .hidden : .visible, edges: .top)
            .listRowBackground(Color.clear)

            if viewModel.isWatchCompanionAvailable {
                watchStandaloneModeRow
                    .listRowInsets(rowInsets)
                    .listRowBackground(Color.clear)
            }

            DataPageChipGroupRow(
                iconName: "square.3.layers.3d.top.filled",
                title: "enable_data_pages",
                messageTitle: LocalizedStringKey(localizationManager.localized("messages")),
                eventTitle: LocalizedStringKey(localizationManager.localized("push_type_event")),
                thingTitle: LocalizedStringKey(localizationManager.localized("push_type_thing")),
                messageIsOn: messagePageVisibilityBinding,
                eventIsOn: eventPageVisibilityBinding,
                thingIsOn: thingPageVisibilityBinding
            )
            .accessibilityIdentifier("group.settings.page_visibility")
            .listRowInsets(rowInsets)
            .listRowBackground(Color.clear)

            Button {
                activeSheet = .manualKey
            } label: {
                SettingsActionRow(
                    iconName: "lock.square.stack",
                    title: "message_encryption",
                    detail: manualKeyStatusText,
                ) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.appPlain)
            .accessibilityIdentifier("action.settings.open_decryption")
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

#if DEBUG
    private var automationStateSignature: String {
        [
            activeSheet == .manualKey ? "manualKey" : "root",
            viewModel.manualKeyInput.hasConfiguredKey ? "configured" : "empty",
            viewModel.manualKeyInput.encoding.rawValue,
        ].joined(separator: "|")
    }
#endif

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

    @ViewBuilder
    private var watchStandaloneModeRow: some View {
        SettingsControlRow(
            iconName: "applewatch.radiowaves.left.and.right",
            title: LocalizedStringKey(localizationManager.localized("Apple Watch Standalone Mode")),
            detail: watchStandaloneModeDetail,
            useFormField: false
        ) {
            Toggle("", isOn: watchStandaloneModeBinding)
                .labelsHidden()
                .disabled(!viewModel.isWatchCompanionAvailable || viewModel.isSwitchingWatchMode)
                .accessibilityIdentifier("toggle.settings.watch_standalone_mode")
                .accessibilityLabel(Text(localizationManager.localized("Apple Watch Standalone Mode")))
        }
        .accessibilityIdentifier("row.settings.watch_standalone_mode")
    }

    private var watchStandaloneModeDetail: LocalizedStringKey {
        if !viewModel.isWatchCompanionAvailable {
            return LocalizedStringKey(localizationManager.localized("watch_companion_not_available"))
        }
        if viewModel.watchMode == .mirror {
            if viewModel.effectiveWatchMode != .mirror {
                return "Waiting for Apple Watch to switch back to mirror mode."
            }
            return "Mirror mode follows your iPhone. iPhone continues syncing messages to Apple Watch."
        }
        if viewModel.effectiveWatchMode != .standalone {
            if viewModel.watchModeSwitchStatus == .timedOut {
                return "Still waiting for Apple Watch to confirm standalone mode. PushGo will keep trying in the background."
            }
            return "Waiting for Apple Watch to confirm standalone mode."
        }
        if !viewModel.standaloneReady {
            return "Apple Watch has switched to standalone mode and is preparing direct reception. iPhone will keep syncing messages until the watch is ready."
        }
        return "Standalone mode is active. Apple Watch can receive messages independently when it has network access."
    }

    @ViewBuilder
    private var watchModeSwitchingOverlay: some View {
        ZStack {
            Color.black.opacity(0.18)
                .ignoresSafeArea()
            VStack(spacing: 14) {
                ProgressView()
                    .progressViewStyle(.circular)
                    .scaleEffect(1.1)
                Text(
                    viewModel.standaloneModeEnabled
                        ? "Switching Apple Watch to standalone mode"
                        : "Switching Apple Watch to mirror mode"
                )
                .font(.headline)
                .multilineTextAlignment(.center)
                Text(
                    viewModel.standaloneModeEnabled
                        ? "Waiting for Apple Watch to accept standalone mode. This request will time out automatically if the watch does not respond."
                        : "Waiting for Apple Watch to switch back to mirror mode. This request will time out automatically if the watch does not respond."
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 18)
            .frame(maxWidth: 300)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Color(UIColor.secondarySystemBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(Color.primary.opacity(0.06), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.12), radius: 16, x: 0, y: 10)
        }
        .transition(.opacity)
        .allowsHitTesting(true)
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

    private var messageCountSubtitle: LocalizedStringKey {
        let count = environment.totalMessageCount
        if count > 0 {
            return LocalizedStringKey(localizationManager.localized("current_number_messages", count))
        }
        return LocalizedStringKey(localizationManager.localized("no_local_messages"))
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

    private func openNotificationSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    private var watchStandaloneModeBinding: Binding<Bool> {
        Binding(
            get: { watchStandaloneToggleValue },
            set: { newValue in
                guard newValue != viewModel.standaloneModeEnabled else {
                    watchStandaloneToggleValue = viewModel.standaloneModeEnabled
                    return
                }
                watchStandaloneToggleValue = newValue
                pendingWatchStandaloneToggleTarget = newValue
                isPresentingWatchStandaloneConfirmation = true
            }
        )
    }

    private func refreshViewModelState() {
        viewModel.refresh()
        watchStandaloneToggleValue = viewModel.standaloneModeEnabled
    }

    private func cancelWatchStandaloneModeChange() {
        pendingWatchStandaloneToggleTarget = nil
        watchStandaloneToggleValue = viewModel.standaloneModeEnabled
    }

    private var watchStateRefreshSignature: String {
        [
            environment.watchMode.rawValue,
            environment.effectiveWatchMode.rawValue,
            environment.standaloneReady ? "1" : "0",
            environment.watchModeSwitchStatus.rawValue,
            environment.isWatchCompanionAvailable ? "1" : "0",
        ].joined(separator: "|")
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

private struct DataPageChipGroupRow: View {
    let iconName: String
    let title: LocalizedStringKey
    let messageTitle: LocalizedStringKey
    let eventTitle: LocalizedStringKey
    let thingTitle: LocalizedStringKey
    @Binding var messageIsOn: Bool
    @Binding var eventIsOn: Bool
    @Binding var thingIsOn: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: iconName)
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

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    DataPageChip(
                        title: messageTitle,
                        isOn: $messageIsOn,
                        accessibilityID: "toggle.settings.page.messages"
                    )
                    DataPageChip(
                        title: eventTitle,
                        isOn: $eventIsOn,
                        accessibilityID: "toggle.settings.page.events"
                    )
                    DataPageChip(
                        title: thingTitle,
                        isOn: $thingIsOn,
                        accessibilityID: "toggle.settings.page.things"
                    )
                }

                VStack(alignment: .trailing, spacing: 8) {
                    HStack(spacing: 8) {
                        DataPageChip(
                            title: messageTitle,
                            isOn: $messageIsOn,
                            accessibilityID: "toggle.settings.page.messages"
                        )
                        DataPageChip(
                            title: eventTitle,
                            isOn: $eventIsOn,
                            accessibilityID: "toggle.settings.page.events"
                        )
                    }
                    HStack(spacing: 8) {
                        DataPageChip(
                            title: thingTitle,
                            isOn: $thingIsOn,
                            accessibilityID: "toggle.settings.page.things"
                        )
                    }
                }
            }
            .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.vertical, 12)
    }
}

private struct DataPageChip: View {
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
        .accessibilityValue(isOn ? Text("On") : Text("Off"))
    }
}

private enum SettingsSheet: Identifiable {
    case manualKey
    case serverManagement

    var id: String {
        switch self {
        case .manualKey:
            "manualKey"
        case .serverManagement:
            "serverManagement"
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
        .opacity(isEnabled ? 1 : 0.45)
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

private struct ManualKeySettingsSheet: View {
    @Bindable var viewModel: SettingsViewModel
    @Environment(LocalizationManager.self) private var localizationManager: LocalizationManager

    var body: some View {
        navigationContainer {
            ManualKeySettingsContentView(viewModel: viewModel)
                .navigationTitle(localizationManager.localized("message_encryption"))
        }
        .accessibilityIdentifier("screen.settings.decryption")
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

            AppActionButton(
                text: Text(localizationManager.localized("save_configuration"))
                    .font(.headline),
                variant: .primary,
                isLoading: viewModel.isSavingServerConfig
            ) {
                focusedField = nil
                Task { await viewModel.saveServerConfig() }
            }
            .disabled(viewModel.isSavingServerConfig)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
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

private struct ManualKeySettingsContentView: View {
    @Bindable var viewModel: SettingsViewModel
    @Environment(LocalizationManager.self) private var localizationManager: LocalizationManager
    @FocusState private var sheetFocus: ManualSheetField?

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            keyEncodingPicker
            keyField
            Text(localizationManager
                .localized(
                    "only_aes_gcm_is_supported_iv_needs_to_be_included_by_the_sender_and_the_key_length_must_exactly_match_the_selected_number_of_bits",
                ))
                .font(.footnote)
                .foregroundColor(.secondary)
            AppActionButton(
                text: Text(localizationManager.localized("save_configuration"))
                    .font(.headline),
                variant: .primary,
                isLoading: viewModel.isSaving
            ) {
                Task { await viewModel.saveManualKeyConfig() }
            }
            .disabled(viewModel.isSaving)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.clear.contentShape(Rectangle()).onTapGesture { sheetFocus = nil })
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
        let decoded = try decoder.decode([PushMessage].self, from: file)
        source = .messages(decoded)
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

private extension View {
    @ViewBuilder
    func customAdaptiveDetents() -> some View {
        self.pushgoSheetSizing(.form)
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
