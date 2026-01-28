import Foundation

enum AppError: LocalizedError, Equatable, Sendable {
    case invalidURL
    case apnsDenied
    case serverUnreachable
    case authFailed
    case decryptFailed
    case saveConfig(reason: String)
    case noServer
    case missingAppGroup(String)
    case localStore(String)
    case exportFailed(String)
    case unknown(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return LocalizationProvider.localized(
                "the_server_address_is_invalid_please_check_whether_it_starts_with_http_s"
            )
        case .apnsDenied:
            return LocalizationProvider.localized(
                "system_notification_permission_is_not_obtained_please_turn_on_notifications_in_the_system_settings_and_try_again",
            )
        case .serverUnreachable:
            return LocalizationProvider.localized(
                "unable_to_connect_to_the_server_please_check_the_address_or_network"
            )
        case .authFailed:
            return LocalizationProvider.localized("server_authentication_failed_please_check_the_token")
        case .decryptFailed:
            return LocalizationProvider.localized(
                "message_received_but_could_not_be_decrypted_with_the_current_settings_showing_original_content",
            )
        case let .saveConfig(reason):
            return reason
        case .noServer:
            return LocalizationProvider.localized(
                "the_server_has_not_been_bound_yet_please_configure_it_in_the_main_interface_first"
            )
        case let .missingAppGroup(identifier):
            return LocalizationProvider.localized(
                "the_app_group_container_cannot_be_found_please_make_sure_placeholder_is_configured_in_the_app_target",
                identifier,
            )
        case let .localStore(message):
            return LocalizationProvider.localized("unable_to_read_local_data_placeholder", message)
        case let .exportFailed(message):
            return LocalizationProvider.localized("export_failed_placeholder", message)
        case let .unknown(message):
            return message
        }
    }

    var code: String {
        switch self {
        case .invalidURL:
            "E_INVALID_URL"
        case .apnsDenied:
            "E_APNS_DENIED"
        case .serverUnreachable:
            "E_SERVER_UNREACHABLE"
        case .authFailed:
            "E_AUTH_FAILED"
        case .decryptFailed:
            "E_DECRYPT_FAILED"
        case .saveConfig:
            "E_SAVE_CONFIG"
        case .noServer:
            "E_NO_SERVER"
        case .missingAppGroup:
            "E_APP_GROUP_MISSING"
        case .localStore:
            "E_LOCAL_STORE"
        case .exportFailed:
            "E_EXPORT_FAILED"
        case .unknown:
            "E_UNKNOWN"
        }
    }
}
