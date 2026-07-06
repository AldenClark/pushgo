import SwiftUI
import UniformTypeIdentifiers
import UIKit
import Observation

struct SettingsView: View {
    private let embedInNavigationContainer: Bool
    private let openDecryptionOnAppear: Bool
    @Environment(AppEnvironment.self) private var environment: AppEnvironment
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @Environment(LocalizationManager.self) private var localizationManager: LocalizationManager
    @State private var viewModel = SettingsViewModel()
    @State private var activeSheet: SettingsSheet?

    init(embedInNavigationContainer: Bool = true, openDecryptionOnAppear: Bool = false) {
        self.embedInNavigationContainer = embedInNavigationContainer
        self.openDecryptionOnAppear = openDecryptionOnAppear
    }

    var body: some View {
        settingsRoot
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
            viewModel.clearError()
            if activeSheet == .manualKey {
                activeSheet = nil
            }
            presentToast(message: message, style: .success, duration: 1.5)
            viewModel.successMessage = nil
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
                    .toastOverlay(environment: environment, showsPendingDeletionBar: false)
                    .presentationDetents([.medium])
                    .presentationDragIndicator(.visible)
            case .serverManagement:
                ServerManagementSheet(viewModel: viewModel)
                    .toastOverlay(environment: environment, showsPendingDeletionBar: false)
                    .presentationDetents([.medium])
                    .presentationDragIndicator(.visible)
            case .notificationSounds:
                NotificationSoundSettingsSheet(viewModel: viewModel)
                    .toastOverlay(environment: environment, showsPendingDeletionBar: false)
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
            }
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
        Color.appWindowBackground
    }

    private var appVersionDetail: LocalizedStringKey {
        LocalizedStringKey(AppVersionDisplay.current())
    }

    @ViewBuilder
    private var iosSettingsList: some View {
        @Bindable var bindableEnvironment = environment
        let rowInsets = EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16)
        List {
            if let errorMessage = viewModel.errorMessage {
                AppInlineFeedbackBanner(
                    message: errorMessage,
                    tone: .danger,
                    accessibilityID: "feedback.settings.root"
                ) {
                    viewModel.clearError()
                }
                .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 0, trailing: 16))
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            }

            if viewModel.notificationStatus != .authorized {
                notificationCard
                    .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 0, trailing: 16))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }

            Button {
                viewModel.clearError()
                viewModel.prepareServerEditor()
                activeSheet = .serverManagement
            } label: {
                SettingsActionRow(
                    iconName: "link",
                    title: "server_management",
                    detailText: serverConfigSubtitle,
                ) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.appTextSecondary)
                }
            }
            .buttonStyle(.appPlain)
            .accessibilityIdentifier("action.settings.server_management")
            .listRowInsets(rowInsets)
            .listRowSeparator(viewModel.notificationStatus == .authorized ? .hidden : .visible, edges: .top)
            .listRowBackground(Color.clear)

            watchReceiverManagementRow
                .listRowInsets(rowInsets)
                .listRowBackground(Color.clear)

            DataPageToggleGroupRow(
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
                viewModel.clearError()
                activeSheet = .notificationSounds
            } label: {
                SettingsActionRow(
                    iconName: "speaker.wave.3",
                    title: LocalizedStringKey("notification_sounds"),
                    detailText: notificationSoundsSubtitle,
                ) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.appTextSecondary)
                }
            }
            .buttonStyle(.appPlain)
            .accessibilityIdentifier("action.settings.notification_sounds")
            .listRowInsets(rowInsets)
            .listRowBackground(Color.clear)

            Button {
                viewModel.clearError()
                activeSheet = .manualKey
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
            .listRowInsets(rowInsets)
            .listRowBackground(Color.clear)

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
            .listRowInsets(rowInsets)
            .listRowBackground(Color.clear)

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
            .listRowInsets(rowInsets)
            .listRowBackground(Color.clear)

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
        .listRowSeparatorTint(Color.appDividerSubtle)
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
            }
        case .denied:
            cardContainer {
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
    }

    @ViewBuilder
    private var watchReceiverManagementRow: some View {
        SettingsControlRow(
            iconName: "applewatch.radiowaves.left.and.right",
            title: LocalizedStringKey(localizationManager.localized("watch_receiver_title")),
            detail: LocalizedStringKey(localizationManager.localized(viewModel.watchReceiverDetailKey)),
            useFormField: false
        ) {
            Button {
                Task {
                    await viewModel.resyncWatchReceiver()
                    refreshViewModelState()
                }
            } label: {
                if viewModel.isSwitchingWatchMode {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Text(localizationManager.localized(viewModel.watchReceiverStatusKey))
                        .font(.footnote.weight(.semibold))
                }
            }
            .buttonStyle(.bordered)
            .disabled(!viewModel.isWatchCompanionAvailable || viewModel.isSwitchingWatchMode)
            .accessibilityIdentifier("button.settings.watch_receiver_resync")
        }
        .accessibilityIdentifier("row.settings.watch_receiver")
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
                .foregroundStyle(Color.appAccentPrimary)
                .frame(width: 34, height: 34)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.appInfoIconBackground)
                )
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                if let subtitle {
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(Color.appTextSecondary)
                }
            }
            Spacer()
            trailing()
        }
    }

    private func statusPill(text: LocalizedStringKey, tone: AppSemanticTone) -> some View {
        HStack(spacing: 6) {
            AppStatusDot(color: tone.foreground)
            Text(text)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            Capsule()
                .fill(tone.background)
        )
    }

    private func cardContainer<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            content()
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.appSurfaceRaised)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
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

    private var serverConfigSubtitle: String {
        environment.serverConfig?.baseURL.absoluteString ?? AppConstants.defaultServerAddress
    }

    private var notificationSoundsSubtitle: String {
        let settings = viewModel.notificationSoundSettings
        let customCount = settings.customAssets.count
        let activeLevels = NotificationSoundLevel.allCases.filter { settings.rule(for: $0).mode != .silent }.count
        if customCount == 0 {
            return localizationManager.localized("priorities_active_built_in_defaults_ready_count", activeLevels)
        }
        return localizationManager.localized("custom_sounds_priorities_active_count", customCount, activeLevels)
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
        environment.showToast(message: message, style: style, duration: duration)
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
            AppSemanticTone.info.foreground
        case .denied:
            AppSemanticTone.danger.foreground
        case .notDetermined:
            AppSemanticTone.neutral.foreground
        }
    }

    private func openNotificationSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    private func refreshViewModelState() {
        viewModel.refresh()
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
