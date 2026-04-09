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
        .onChange(of: watchStandaloneToggleValue) { _, newValue in
            guard newValue != viewModel.standaloneModeEnabled else { return }
            pendingWatchStandaloneToggleTarget = newValue
            isPresentingWatchStandaloneConfirmation = true
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
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .manualKey:
                ManualKeySettingsSheet(viewModel: viewModel)
                    .presentationDetents([.medium])
                    .presentationDragIndicator(.visible)
                    .toastOverlay(environment: environment)
            case .serverManagement:
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
        LocalizedStringKey(AppVersionDisplay.current())
    }

    @ViewBuilder
    private var iosSettingsList: some View {
        @Bindable var bindableEnvironment = environment
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
                eventTitle: LocalizedStringKey(localizationManager.localized("thing_detail_tab_events")),
                thingTitle: LocalizedStringKey(localizationManager.localized("push_type_thing")),
                messageIsOn: $bindableEnvironment.messagePageEnabled,
                eventIsOn: $bindableEnvironment.eventPageEnabled,
                thingIsOn: $bindableEnvironment.thingPageEnabled
            )
            .accessibilityIdentifier("group.settings.page_visibility")
            .listRowInsets(rowInsets)
            .listRowBackground(Color.clear)

            Button {
                activeSheet = .manualKey
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
            Toggle("", isOn: $watchStandaloneToggleValue)
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
