import Foundation
import Observation

@MainActor
@Observable
final class SettingsViewModel {
    enum KeyLength: Int, CaseIterable, Identifiable {
        case bits128 = 128
        case bits192 = 192
        case bits256 = 256

        var id: Int { rawValue }

        var displayName: String {
            "\(rawValue)-bit"
        }

        var byteCount: Int {
            rawValue / 8
        }
    }

    enum KeyEncoding: String, CaseIterable, Identifiable {
        case plaintext
        case base64
        case hex

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .plaintext: "Plaintext"
            case .base64: "Base64"
            case .hex: "Hex"
            }
        }
    }

    struct ManualKeyInput: Equatable {
        var key: String = ""
        var selectedLength: KeyLength = .bits128
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

    var launchAtLoginEnabled: Bool = true {
        didSet {
            guard !isInitializing, oldValue != launchAtLoginEnabled else { return }
            persistLaunchAtLoginPreference()
        }
    }

    var autoCleanupEnabled: Bool = true {
        didSet {
            guard !isInitializing, oldValue != autoCleanupEnabled else { return }
            Task { @MainActor in
                await dataStore.saveAutoCleanupPreference(autoCleanupEnabled)
            }
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
        autoCleanupEnabled = dataStore.cachedAutoCleanupPreference() ?? resolveDefaultAutoCleanupEnabled()
        loadPersistedPreferences()
    }

    func refresh() {
        notificationStatus = environment.pushRegistrationService.authorizationState
        notificationKeyMaterial = environment.currentNotificationMaterial
        if let material = notificationKeyMaterial {
            manualKeyInput.key = ""
            manualKeyInput.isExpanded = false
            manualKeyInput.isSecretVisible = false
            manualKeyInput.hasConfiguredKey = !material.keyBase64.isEmpty
        } else {
            manualKeyInput.hasConfiguredKey = false
        }
    }

    private func loadPersistedPreferences() {
        Task { @MainActor in
            let manualPrefs = await dataStore.loadManualKeyPreferences()
            var input = manualKeyInput
            if let storedLength = manualPrefs.length,
               let resolved = KeyLength(rawValue: storedLength)
            {
                input.selectedLength = resolved
            }
            if let storedEncoding = manualPrefs.encoding,
               let resolved = KeyEncoding(rawValue: storedEncoding)
            {
                input.encoding = resolved
            }
            manualKeyInput = input

            let storedLaunch = await dataStore.loadLaunchAtLoginPreference()
            launchAtLoginEnabled = storedLaunch ?? true
            if storedLaunch == nil {
                await dataStore.saveLaunchAtLoginPreference(true)
            }

            let storedAutoCleanup = await dataStore.loadAutoCleanupPreference()
            let defaultAutoCleanup = resolveDefaultAutoCleanupEnabled()
            autoCleanupEnabled = storedAutoCleanup ?? defaultAutoCleanup
            if storedAutoCleanup == nil {
                await dataStore.saveAutoCleanupPreference(defaultAutoCleanup)
            }
            isInitializing = false
        }
    }

    private func persistLaunchAtLoginPreference() {
        environment.updateLaunchAtLogin(isEnabled: launchAtLoginEnabled)
    }

    private func resolveDefaultAutoCleanupEnabled() -> Bool {
        #if os(watchOS)
        return true
        #elseif os(iOS)
        if #available(iOS 18, *) {
            return false
        }
        return true
        #elseif os(macOS)
        return false
        #else
        return true
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
            error = .saveConfig(reason: localizationManager.localized("server_address_required"))
            return
        }
        guard let url = validatedServerURL(from: trimmedAddress) else {
            error = .invalidURL
            return
        }

        let trimmedToken = gatewayInput.token.trimmingCharacters(in: .whitespacesAndNewlines)
        let token: String? = trimmedToken.isEmpty ? nil : trimmedToken

        let base = environment.serverConfig ?? ServerConfig(baseURL: url, token: nil, notificationKeyMaterial: nil)
        let newConfig = ServerConfig(
            id: base.id,
            name: base.name,
            baseURL: url,
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
            self.error = .saveConfig(reason: appError.errorDescription ?? appError.code)
        } catch let underlying {
            self.error = .saveConfig(reason: underlying.localizedDescription)
        }
    }

    private func validatedServerURL(from raw: String) -> URL? {
        URLSanitizer.validatedServerURL(from: raw)
    }

    func requestNotificationPermission() async {
        do {
            try await environment.pushRegistrationService.requestAuthorization()
            successMessage = localizationManager.localized("notification_permission_status_updated")
        } catch let appError as AppError {
            self.error = appError
        } catch let underlying {
            self.error = .unknown(underlying.localizedDescription)
        }
    }

    func saveManualKeyConfig() async {
        let trimmedKey = manualKeyInput.key.trimmingCharacters(in: .whitespacesAndNewlines)
        let encoding = manualKeyInput.encoding
        let keyLength = manualKeyInput.selectedLength
        guard !trimmedKey.isEmpty else {
            let message = manualKeyInput.hasConfiguredKey
                ? localizationManager.localized("the_key_has_been_saved_please_enter_a_new_value_to_overwrite_it")
                : localizationManager.localized("please_enter_the_key_first")
            error = .saveConfig(reason: message)
            return
        }

        let normalizedKey: String
        do {
            normalizedKey = try normalizedKeyBase64(
                from: trimmedKey,
                encoding: encoding,
                keyLength: keyLength,
            )
        } catch let validation as ManualKeyValidationError {
            self.error = .saveConfig(
                reason: validation.errorDescription ?? localizationManager
                    .localized("the_decryption_configuration_is_not_in_the_correct_format_please_check_your_input"),
            )
            return
        } catch {
            self
                .error = .saveConfig(reason: localizationManager
                    .localized("key_format_verification_failed_please_try_again"))
            return
        }
        isSaving = true
        defer { isSaving = false }
        let material = ServerConfig.NotificationKeyMaterial(
            algorithm: .aesGcm,
            keyBase64: normalizedKey,
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
            self.error = .saveConfig(reason: error.localizedDescription)
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
            self.error = .saveConfig(reason: error.localizedDescription)
        }
    }

    private func normalizedKeyBase64(from input: String, encoding: KeyEncoding, keyLength: KeyLength) throws -> String {
        let data: Data
        switch encoding {
        case .plaintext:
            data = Data(input.utf8)
        case .base64:
            guard let decoded = Data(base64Encoded: input) else {
                throw ManualKeyValidationError.invalidBase64
            }
            data = decoded
        case .hex:
            var bytes = [UInt8]()
            let clean = input.filter { !$0.isWhitespace }
            guard clean.count % 2 == 0 else { throw ManualKeyValidationError.invalidHex }
            var index = clean.startIndex
            while index < clean.endIndex {
                let next = clean.index(index, offsetBy: 2)
                let byteString = clean[index ..< next]
                guard let value = UInt8(byteString, radix: 16) else {
                    throw ManualKeyValidationError.invalidHex
                }
                bytes.append(value)
                index = next
            }
            data = Data(bytes)
        }

        guard data.count == keyLength.byteCount else {
            throw ManualKeyValidationError.invalidLength(expected: keyLength.byteCount, actual: data.count)
        }

        return data.base64EncodedString()
    }

    private func persistManualKeyPreferences(oldValue: ManualKeyInput) {
        guard !isInitializing else { return }
        guard manualKeyInput.selectedLength != oldValue.selectedLength
            || manualKeyInput.encoding != oldValue.encoding
        else {
            return
        }
        Task { @MainActor in
            await dataStore.saveManualKeyPreferences(
                length: manualKeyInput.selectedLength.rawValue,
                encoding: manualKeyInput.encoding.rawValue
            )
        }
    }

}

private enum ManualKeyValidationError: LocalizedError {
    case invalidBase64
    case invalidHex
    case invalidLength(expected: Int, actual: Int)

    var errorDescription: String? {
        let l10n = LocalizationProvider.localized
        switch self {
        case .invalidBase64:
            return l10n("the_selected_format_is_not_valid_base64_please_check_your_input")
        case .invalidHex:
            return l10n("the_selected_format_is_not_a_valid_hex_please_check_your_input")
        case let .invalidLength(expected, actual):
            let expectedBits = expected * 8
            return l10n(
                "incorrect_key_length_number_bytes_required_number_bits_currently_number_bytes",
                expected,
                expectedBits,
                actual,
            )
        }
    }
}
