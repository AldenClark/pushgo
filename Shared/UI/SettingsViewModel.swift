import Foundation
import Observation

@MainActor
@Observable
final class SettingsViewModel {
    typealias KeyEncoding = ManualNotificationKeyEncoding

    struct ManualKeyInput: Equatable {
        var key: String = ""
        var encoding: KeyEncoding = .plaintext
        var isExpanded: Bool = false
        var isSecretVisible: Bool = false
        var hasConfiguredKey: Bool = false
    }

    struct GatewayInput: Equatable {
        var address: String = ""
        var token: String = ""
        var isTokenVisible: Bool = false
    }

    private(set) var notificationStatus: PushRegistrationService.AuthorizationState = .notDetermined
    private(set) var notificationKeyMaterial: ServerConfig.NotificationKeyMaterial?
    private(set) var isWatchCompanionAvailable: Bool = false
#if os(iOS)
    private(set) var watchMode: WatchMode = .mirror
    private(set) var effectiveWatchMode: WatchMode = .mirror
    private(set) var standaloneReady: Bool = false
    private(set) var watchModeSwitchStatus: WatchModeSwitchStatus = .idle
    private(set) var isSwitchingWatchMode: Bool = false
#endif
    var manualKeyInput = ManualKeyInput() {
        didSet { persistManualKeyPreferences(oldValue: oldValue) }
    }
    var gatewayInput = GatewayInput()

    var isSaving: Bool = false
    var isSavingServerConfig: Bool = false
    var shouldDismissServerManagement: Bool = false
    var isClearingMessages: Bool = false
    var error: AppError?
    var successMessage: String?

    private let environment: AppEnvironment
    private let localizationManager: LocalizationManager
    private let dataStore: LocalDataStore
    @ObservationIgnored private var isInitializing = true
    @ObservationIgnored private var isRefreshingLaunchAtLogin = false
    var launchAtLoginEnabled: Bool = false {
        didSet {
            guard !isInitializing, !isRefreshingLaunchAtLogin, oldValue != launchAtLoginEnabled else { return }
            persistLaunchAtLoginPreference()
        }
    }

    init(
        environment: AppEnvironment? = nil,
        localizationManager: LocalizationManager? = nil,
    ) {
        if let environment {
            self.environment = environment
        } else {
        self.environment = AppEnvironment.shared
        }
        self.localizationManager = localizationManager ?? LocalizationManager.shared
        self.dataStore = self.environment.dataStore
        notificationKeyMaterial = self.environment.currentNotificationMaterial
        loadPersistedPreferences()
    }

    func refresh() {
        notificationStatus = environment.pushRegistrationService.authorizationState
        notificationKeyMaterial = environment.currentNotificationMaterial
#if os(iOS)
        watchMode = environment.watchMode
        effectiveWatchMode = environment.effectiveWatchMode
        standaloneReady = environment.standaloneReady
        watchModeSwitchStatus = environment.watchModeSwitchStatus
        isWatchCompanionAvailable = environment.isWatchCompanionAvailable
#else
        isWatchCompanionAvailable = false
#endif
#if os(macOS)
        setLaunchAtLoginEnabled(environment.launchAtLoginEnabled)
#else
        setLaunchAtLoginEnabled(false)
#endif
        if let material = notificationKeyMaterial {
            manualKeyInput.key = ""
            manualKeyInput.isExpanded = false
            manualKeyInput.isSecretVisible = false
            manualKeyInput.hasConfiguredKey = material.isConfigured
        } else {
            manualKeyInput.hasConfiguredKey = false
        }
    }

    var standaloneModeEnabled: Bool {
#if os(iOS)
        watchMode == .standalone
#else
        false
#endif
    }

    func setStandaloneModeEnabled(_ isEnabled: Bool) async {
#if os(iOS)
        await environment.refreshWatchCompanionAvailability()
        if isEnabled, !environment.isWatchCompanionAvailable {
            refresh()
            error = .typedLocal(
                code: "watch_companion_not_available",
                category: .validation,
                message: localizationManager.localized("watch_companion_not_available"),
                detail: "watch companion unavailable when enabling standalone mode"
            )
            return
        }
        isSwitchingWatchMode = true
        defer { isSwitchingWatchMode = false }
        do {
            let result = try await environment.requestWatchModeChangeApplied(isEnabled ? .standalone : .mirror)
            refresh()
            if result == .applied {
                successMessage = localizationManager.localized(
                    isEnabled ? "watch_standalone_mode_enabled_success" : "watch_mirror_mode_enabled_success"
                )
            }
        } catch let appError as AppError {
            refresh()
            error = appError
        } catch let underlying {
            refresh()
            error = AppError.wrap(
                underlying,
                fallbackMessage: localizationManager.localized("operation_failed"),
                code: "watch_mode_change_failed"
            )
        }
#else
        _ = isEnabled
#endif
    }

    private func loadPersistedPreferences() {
        Task { @MainActor in
            let manualPrefs = await dataStore.loadManualKeyPreferences()
            var input = manualKeyInput
            if let storedEncoding = manualPrefs,
               let resolved = KeyEncoding(rawValue: storedEncoding) {
                input.encoding = resolved
            }
            manualKeyInput = input

#if os(macOS)
            let storedLaunch = await dataStore.loadLaunchAtLoginPreference()
            launchAtLoginEnabled = storedLaunch ?? false
#else
            launchAtLoginEnabled = false
#endif
            isInitializing = false
        }
    }

    private func setLaunchAtLoginEnabled(_ isEnabled: Bool) {
        isRefreshingLaunchAtLogin = true
        launchAtLoginEnabled = isEnabled
        isRefreshingLaunchAtLogin = false
    }

    private func persistLaunchAtLoginPreference() {
#if os(macOS)
        environment.updateLaunchAtLogin(isEnabled: launchAtLoginEnabled)
#endif
    }

    func prepareServerEditor() {
        let config = environment.serverConfig
        gatewayInput.address = config?.baseURL.absoluteString ?? AppConstants.defaultServerAddress
        gatewayInput.token = config?.token ?? ""
        gatewayInput.isTokenVisible = false
    }

    func restoreDefaultServerAddress() {
        gatewayInput.address = AppConstants.defaultServerAddress
    }

    func saveServerConfig() async {
        let trimmedAddress = gatewayInput.address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedAddress.isEmpty else {
            error = .typedLocal(
                code: "server_address_required",
                category: .validation,
                message: localizationManager.localized("server_address_required"),
                detail: "server address is required"
            )
            return
        }
        guard let url = validatedServerURL(from: trimmedAddress) else {
            error = .invalidURL
            return
        }

        let trimmedToken = gatewayInput.token.trimmingCharacters(in: .whitespacesAndNewlines)
        let token: String? = trimmedToken.isEmpty ? nil : trimmedToken

        let normalizedURL = normalizedGatewayURL(url)
        let newIdentity = gatewayIdentity(baseURL: normalizedURL, token: token)
        let currentIdentity = environment.serverConfig.map { gatewayIdentity(baseURL: normalizedGatewayURL($0.baseURL), token: $0.token) } ?? ""
        gatewayInput.address = normalizedURL.absoluteString
        gatewayInput.token = token ?? ""
        if newIdentity == currentIdentity {
            successMessage = localizationManager.localized("server_configuration_saved")
            shouldDismissServerManagement = true
            return
        }

        let base = environment.serverConfig ?? ServerConfig(baseURL: normalizedURL, token: nil, notificationKeyMaterial: nil)
        let newConfig = ServerConfig(
            id: base.id,
            name: base.name,
            baseURL: normalizedURL,
            token: token,
            notificationKeyMaterial: base.notificationKeyMaterial,
            updatedAt: Date(),
        )

        guard !isSavingServerConfig else { return }
        isSavingServerConfig = true
        defer { isSavingServerConfig = false }

        do {
            try await environment.updateServerConfig(newConfig)
            try await environment.syncSubscriptionsIfNeeded()
            successMessage = localizationManager.localized("server_configuration_saved")
            shouldDismissServerManagement = true
        } catch let appError as AppError {
            self.error = appError
        } catch let underlying {
            self.error = AppError.wrap(
                underlying,
                fallbackMessage: localizationManager.localized("operation_failed"),
                code: "server_config_save_failed"
            )
        }
    }

    private func validatedServerURL(from raw: String) -> URL? {
        URLSanitizer.validatedServerURL(from: raw)
    }

    private func normalizedGatewayURL(_ url: URL) -> URL {
        ServerConfig(baseURL: url, token: nil, notificationKeyMaterial: nil).normalizedBaseURL
    }

    private func gatewayIdentity(baseURL: URL, token: String?) -> String {
        let normalizedToken = token?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return "\(baseURL.absoluteString)|\(normalizedToken)"
    }

    func requestNotificationPermission() async {
        do {
            try await environment.pushRegistrationService.requestAuthorization()
            successMessage = localizationManager.localized("notification_permission_status_updated")
        } catch let appError as AppError {
            self.error = appError
        } catch let underlying {
            self.error = AppError.wrap(
                underlying,
                fallbackMessage: localizationManager.localized("operation_failed"),
                code: "notification_permission_request_failed"
            )
        }
    }

    func saveManualKeyConfig() async {
        let trimmedKey = manualKeyInput.key.trimmingCharacters(in: .whitespacesAndNewlines)
        let encoding = manualKeyInput.encoding
        if trimmedKey.isEmpty {
            isSaving = true
            defer { isSaving = false }
            let material = ServerConfig.NotificationKeyMaterial(
                algorithm: .aesGcm,
                keyData: Data(),
                ivBase64: nil,
                updatedAt: Date(),
            )
            await environment.updateNotificationMaterial(material)
            successMessage = localizationManager.localized("decryption_configuration_saved")
            notificationKeyMaterial = material
            var input = manualKeyInput
            input.key = ""
            input.hasConfiguredKey = false
            input.isSecretVisible = false
            input.isExpanded = false
            manualKeyInput = input
            return
        }

        let normalizedKey: Data
        do {
            normalizedKey = try ManualNotificationKeyValidator.normalizedKeyData(
                from: trimmedKey,
                encoding: encoding,
            )
        } catch let validation as ManualNotificationKeyValidationError {
            self.error = AppError.wrap(
                validation,
                fallbackMessage: localizationManager
                    .localized("the_decryption_configuration_is_not_in_the_correct_format_please_check_your_input"),
                code: "manual_notification_key_validation_failed",
                category: .validation
            )
            return
        } catch {
            self.error = AppError.wrap(
                error,
                fallbackMessage: localizationManager
                    .localized("key_format_verification_failed_please_try_again"),
                code: "manual_notification_key_verification_failed",
                category: .validation
            )
            return
        }
        isSaving = true
        defer { isSaving = false }
        let material = ServerConfig.NotificationKeyMaterial(
            algorithm: .aesGcm,
            keyData: normalizedKey,
            ivBase64: nil,
            updatedAt: Date(),
        )
        await environment.updateNotificationMaterial(material)
        successMessage = localizationManager.localized("decryption_configuration_saved")
        notificationKeyMaterial = material
        manualKeyInput.key = ""
        manualKeyInput.hasConfiguredKey = true
        manualKeyInput.isSecretVisible = false
        manualKeyInput.isExpanded = false
    }

    func clearAllMessages() async {
        guard environment.totalMessageCount > 0 else {
            successMessage = localizationManager.localized("no_messages_to_clear")
            return
        }
        guard !isClearingMessages else { return }
        isClearingMessages = true
        defer { isClearingMessages = false }
        do {
            _ = try await environment.messageStateCoordinator.deleteAllMessages()
            successMessage = localizationManager.localized("all_messages_cleared")
        } catch {
            self.error = AppError.wrap(
                error,
                fallbackMessage: localizationManager.localized("operation_failed"),
                code: "message_clear_all_failed"
            )
        }
    }

    enum MessageCleanupOption: String, CaseIterable, Identifiable {
        case clearAll
        case clearAllRead
        case clearReadBefore30Days
        case clearReadBefore7Days
        case clearAllBefore30Days
        case clearAllBefore7Days

        var id: String { rawValue }

        var titleKey: String {
            switch self {
            case .clearAll:
                "clean_all_messages"
            case .clearAllRead:
                "clean_all_read_messages"
            case .clearReadBefore30Days:
                "clean_read_messages_before_30_days"
            case .clearReadBefore7Days:
                "clean_read_messages_before_7_days"
            case .clearAllBefore30Days:
                "clean_all_messages_before_30_days"
            case .clearAllBefore7Days:
                "clean_all_messages_before_7_days"
            }
        }

        var readState: Bool? {
            switch self {
            case .clearAll:
                nil
            case .clearAllRead, .clearReadBefore30Days, .clearReadBefore7Days:
                true
            case .clearAllBefore30Days, .clearAllBefore7Days:
                nil
            }
        }

        var cutoffDays: Int? {
            switch self {
            case .clearReadBefore30Days, .clearAllBefore30Days:
                30
            case .clearReadBefore7Days, .clearAllBefore7Days:
                7
            case .clearAll, .clearAllRead:
                nil
            }
        }
    }

    static let cleanupOptions: [MessageCleanupOption] = [
        .clearAll,
        .clearAllRead,
        .clearReadBefore30Days,
        .clearReadBefore7Days,
        .clearAllBefore30Days,
        .clearAllBefore7Days,
    ]

    func cleanupMessages(option: MessageCleanupOption) async {
        guard !isClearingMessages else { return }
        isClearingMessages = true
        defer { isClearingMessages = false }

        let cutoff = option.cutoffDays.flatMap {
            Calendar.current.date(byAdding: .day, value: -$0, to: Date())
        }
        let actionTitle = localizationManager.localized(option.titleKey)

        do {
            let deletedCount = try await environment.messageStateCoordinator
                .deleteMessages(readState: option.readState, before: cutoff)

            if deletedCount == 0 {
                successMessage = localizationManager.localized("no_messages_to_clear")
            } else {
                successMessage = localizationManager.localized("messages_cleaned_placeholder", actionTitle)
            }
        } catch {
            self.error = AppError.wrap(
                error,
                fallbackMessage: localizationManager.localized("operation_failed"),
                code: "message_cleanup_failed"
            )
        }
    }

    private func persistManualKeyPreferences(oldValue: ManualKeyInput) {
        guard !isInitializing else { return }
        guard manualKeyInput.encoding != oldValue.encoding else {
            return
        }
        Task { @MainActor in
            await dataStore.saveManualKeyPreferences(encoding: manualKeyInput.encoding.rawValue)
        }
    }

}
