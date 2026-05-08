import Foundation

enum GatewayErrorCategory: String, Decodable, Equatable, Sendable {
    case validation
    case auth
    case permission
    case notFound = "not_found"
    case conflict
    case featureDisabled = "feature_disabled"
    case rateLimit = "rate_limit"
    case tooBusy = "too_busy"
    case network
    case upstream
    case local
    case internalError = "internal"
}

struct GatewayProblemPayload: Decodable, Equatable, Sendable {
    let code: String?
    let category: GatewayErrorCategory
    let status: Int
    let title: String?
    let detail: String?
    let localizedMessage: String?
    let locale: String?
    let retryable: Bool
    let requestId: String?

    enum CodingKeys: String, CodingKey {
        case code
        case category
        case status
        case title
        case detail
        case localizedMessage = "localized_message"
        case locale
        case retryable
        case requestId = "request_id"
    }
}

struct LocalProblemPayload: Equatable, Sendable {
    let code: String
    let category: GatewayErrorCategory
    let message: String
    let detail: String?
}

protocol LocalProblemPayloadConvertible: Error {
    var localProblemPayload: LocalProblemPayload { get }
}

extension KeychainStoreError: LocalProblemPayloadConvertible {
    var localProblemPayload: LocalProblemPayload {
        switch self {
        case .unexpectedData:
            return LocalProblemPayload(
                code: "keychain_unexpected_data",
                category: .local,
                message: LocalizationProvider.localized("keychain_unexpected_data"),
                detail: "keychain returned unexpected data"
            )
        case let .missingAccessGroup(suffix):
            return LocalProblemPayload(
                code: "keychain_access_group_missing",
                category: .local,
                message: LocalizationProvider.localized("keychain_access_group_missing_placeholder", suffix),
                detail: "keychain access group is not configured for \(suffix)"
            )
        case let .osStatus(status):
            return LocalProblemPayload(
                code: "keychain_operation_failed",
                category: .local,
                message: LocalizationProvider.localized("keychain_operation_failed_placeholder", status),
                detail: "keychain operation failed with status \(status)"
            )
        }
    }
}

enum AppError: LocalizedError, Equatable, Sendable {
    private static let channelNameMaxLength = 128

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
    case gateway(GatewayProblemPayload)
    case local(LocalProblemPayload)
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
        case let .gateway(problem):
            if let code = problem.code?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
               !code.isEmpty,
               let message = Self.gatewayMessage(for: code)
            {
                return message
            }
            if let localizedMessage = problem.localizedMessage?.trimmingCharacters(in: .whitespacesAndNewlines),
               !localizedMessage.isEmpty
            {
                return localizedMessage
            }
            switch problem.category {
            case .auth:
                return LocalizationProvider.localized("server_authentication_failed_please_check_the_token")
            case .permission:
                return LocalizationProvider.localized("gateway_permission_denied")
            case .network:
                return LocalizationProvider.localized(
                    "unable_to_connect_to_the_server_please_check_the_address_or_network"
                )
            case .notFound:
                return LocalizationProvider.localized("gateway_resource_not_found")
            case .validation:
                return LocalizationProvider.localized("gateway_validation_failed")
            case .featureDisabled:
                return LocalizationProvider.localized("gateway_feature_unavailable")
            case .rateLimit:
                return LocalizationProvider.localized("gateway_rate_limited")
            case .tooBusy, .internalError:
                return LocalizationProvider.localized("gateway_temporarily_unavailable")
            case .upstream:
                return LocalizationProvider.localized("gateway_upstream_unavailable")
            default:
                return LocalizationProvider.localized("operation_failed")
            }
        case let .local(problem):
            if let code = Self.normalizedErrorCode(problem.code),
               let message = Self.localMessage(for: code)
            {
                return message
            }
            return problem.message
        case let .unknown(message):
            return message
        }
    }

    var failureReason: String? {
        switch self {
        case let .gateway(problem):
            if let requestId = problem.requestId?.trimmingCharacters(in: .whitespacesAndNewlines),
               !requestId.isEmpty
            {
                let detail = problem.detail?.trimmingCharacters(in: .whitespacesAndNewlines)
                if let detail, !detail.isEmpty {
                    return "\(detail) [request_id=\(requestId)]"
                }
                return "request_id=\(requestId)"
            }
            return problem.detail
        case let .local(problem):
            return problem.detail
        default:
            return nil
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
        case let .gateway(problem):
            problem.code ?? "E_GATEWAY"
        case let .local(problem):
            problem.code
        case .unknown:
            "E_UNKNOWN"
        }
    }

    var gatewayCode: String? {
        guard case let .gateway(problem) = self else { return nil }
        let normalized = problem.code?.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized?.isEmpty == false ? normalized : nil
    }

    func matchesGatewayCode(_ expected: String) -> Bool {
        guard let gatewayCode else { return false }
        return gatewayCode.caseInsensitiveCompare(expected) == .orderedSame
    }

    static func typedLocal(
        code: String,
        category: GatewayErrorCategory = .local,
        message: String,
        detail: String? = nil
    ) -> Self {
        .local(
            LocalProblemPayload(
                code: code,
                category: category,
                message: message,
                detail: detail
            )
        )
    }

    static func wrap(
        _ error: Error,
        fallbackMessage: String,
        code: String = "local_operation_failed",
        category: GatewayErrorCategory = .local
    ) -> Self {
        if let appError = error as? AppError {
            return appError
        }
        if let localProblem = error as? any LocalProblemPayloadConvertible {
            return .local(localProblem.localProblemPayload)
        }
        let nsError = error as NSError
        if error is URLError || nsError.domain == NSURLErrorDomain {
            return .typedLocal(
                code: "network_unavailable",
                category: .network,
                message: LocalizationProvider.localized(
                    "unable_to_connect_to_the_server_please_check_the_address_or_network"
                ),
                detail: nsError.localizedDescription
            )
        }
        return .typedLocal(
            code: code,
            category: category,
            message: fallbackMessage,
            detail: error.localizedDescription
        )
    }

    private static func gatewayMessage(for code: String) -> String? {
        switch code {
        case "authentication_failed":
            return LocalizationProvider.localized("server_authentication_failed_please_check_the_token")
        case "channel_not_found":
            return LocalizationProvider.localized("channel_not_found")
        case "channel_id_required":
            return LocalizationProvider.localized("channel_id_required")
        case "invalid_channel_id":
            return LocalizationProvider.localized("channel_id_invalid")
        case "invalid_channel_name":
            return LocalizationProvider.localized("channel_name_required")
        case "channel_name_required":
            return LocalizationProvider.localized("channel_name_required")
        case "channel_name_too_long":
            return LocalizationProvider.localized("channel_name_too_long", Self.channelNameMaxLength)
        case "channel_password_missing":
            return LocalizationProvider.localized("channel_password_missing")
        case "password_required":
            return LocalizationProvider.localized("channel_password_missing")
        case "invalid_password":
            return LocalizationProvider.localized("channel_password_invalid_length")
        case "password_mismatch", "invalid_channel_password":
            return LocalizationProvider.localized("channel_password_incorrect")
        case "provider_token_missing", "provider_token_required":
            return LocalizationProvider.localized("device_push_route_not_ready")
        case "event_id_required":
            return LocalizationProvider.localized("event_id_required")
        case "thing_id_required":
            return LocalizationProvider.localized("thing_id_required")
        case "private_channel_disabled":
            return LocalizationProvider.localized("gateway_feature_unavailable")
        case "device_key_not_found":
            return LocalizationProvider.localized("device_registration_stale")
        case "device_not_found":
            return LocalizationProvider.localized("device_route_stale")
        case "route_not_found":
            return LocalizationProvider.localized("gateway_route_not_found")
        default:
            return nil
        }
    }

    private static func localMessage(for code: String) -> String? {
        switch code {
        case "channel_id_required":
            return LocalizationProvider.localized("channel_id_required")
        case "invalid_channel_id":
            return LocalizationProvider.localized("channel_id_invalid")
        case "channel_name_required":
            return LocalizationProvider.localized("channel_name_required")
        case "channel_name_too_long":
            return LocalizationProvider.localized("channel_name_too_long", Self.channelNameMaxLength)
        case "invalid_password":
            return LocalizationProvider.localized("channel_password_invalid_length")
        case "missing_device_key":
            return LocalizationProvider.localized("device_registration_stale")
        case "gateway_response_missing_device_key", "gateway_invalid_response":
            return LocalizationProvider.localized("gateway_response_invalid")
        case "missing_delivery_id":
            return LocalizationProvider.localized("gateway_validation_failed")
        case "provider_token_missing":
            return LocalizationProvider.localized("device_push_route_not_ready")
        case "watch_companion_not_available":
            return LocalizationProvider.localized("watch_companion_not_available")
        case "server_address_required":
            return LocalizationProvider.localized("server_address_required")
        case "provider_device_key_save_failed":
            return LocalizationProvider.localized("local_device_registration_save_failed")
        case "channel_subscribe_failed":
            return LocalizationProvider.localized("channel_subscribe_incomplete")
        case "event_id_required":
            return LocalizationProvider.localized("event_id_required")
        case "thing_id_required":
            return LocalizationProvider.localized("thing_id_required")
        case "event_missing_channel_id":
            return LocalizationProvider.localized("event_missing_channel_id")
        case "watch_mode_change_failed", "watch_mode_change_not_confirmed":
            return LocalizationProvider.localized("watch_mode_change_failed")
        case "server_config_save_failed":
            return LocalizationProvider.localized("server_config_save_failed")
        case "notification_permission_request_failed":
            return LocalizationProvider.localized("notification_permission_request_failed")
        case "startup_fixture_import_failed":
            return LocalizationProvider.localized("startup_fixture_import_failed")
        case "gateway_http_failure", "gateway_request_failed", "provider_route_context_released",
             "message_state_coordinator_unavailable", "subscription_sync_context_released",
             "fixture_subscription_sync_failed", "standalone_runtime_reconcile_failed":
            return LocalizationProvider.localized("gateway_temporarily_unavailable")
        default:
            if code.hasPrefix("message_") || code.hasPrefix("watch_light_") {
                if code.contains("mark_read") {
                    return LocalizationProvider.localized("message_update_failed")
                }
                if code.contains("delete")
                    || code.contains("cleanup")
                    || code.contains("clear_all")
                {
                    return LocalizationProvider.localized("message_remove_failed")
                }
                if code.contains("load")
                    || code.contains("reload")
                    || code.contains("snapshot")
                {
                    return LocalizationProvider.localized("message_load_failed")
                }
            }
            if code.hasPrefix("entity_") {
                return LocalizationProvider.localized("entity_load_failed")
            }
            return nil
        }
    }

    private static func normalizedErrorCode(_ raw: String?) -> String? {
        let normalized = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized?.isEmpty == false ? normalized : nil
    }
}
