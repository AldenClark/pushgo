import Foundation

struct ChannelSubscriptionService {
    static let deviceRegisterPath = "/device/register"
    static let deviceRoutePath = "/channel/device"
    static let deviceChannelDeletePath = "/channel/device/delete"
    static let providerTokenRetirePath = "/channel/device/provider-token/retire"

    struct DeviceRegisterPayload: Decodable {
        let deviceKey: String

        enum CodingKeys: String, CodingKey {
            case deviceKey = "device_key"
        }
    }

    struct DeviceChannelPayload: Decodable {
        let deviceKey: String
        let channelType: String?
        let providerToken: String?

        enum CodingKeys: String, CodingKey {
            case deviceKey = "device_key"
            case channelType = "channel_type"
            case providerToken = "provider_token"
        }
    }

    struct DeviceRegisterRequest: Encodable {
        let deviceKey: String?
        let platform: String

        enum CodingKeys: String, CodingKey {
            case deviceKey = "device_key"
            case platform
        }
    }

    struct DeviceChannelUpsertRequest: Encodable {
        let deviceKey: String
        let platform: String
        let channelType: String
        let providerToken: String?

        enum CodingKeys: String, CodingKey {
            case deviceKey = "device_key"
            case platform
            case channelType = "channel_type"
            case providerToken = "provider_token"
        }
    }

    struct DeviceChannelDeleteRequest: Encodable {
        let deviceKey: String
        let channelType: String

        enum CodingKeys: String, CodingKey {
            case deviceKey = "device_key"
            case channelType = "channel_type"
        }
    }

    struct ProviderTokenRetireRequest: Encodable {
        let platform: String
        let providerToken: String

        enum CodingKeys: String, CodingKey {
            case platform
            case providerToken = "provider_token"
        }
    }

    struct PullRequest: Encodable {
        let deviceKey: String
        let deliveryId: String?

        enum CodingKeys: String, CodingKey {
            case deviceKey = "device_key"
            case deliveryId = "delivery_id"
        }
    }

    struct PullResponse: Decodable {
        let items: [PullItem]
    }

    struct PullItem: Decodable {
        let deliveryId: String
        let payload: [String: String]

        enum CodingKeys: String, CodingKey {
            case deliveryId = "delivery_id"
            case payload
        }
    }

    struct AckRequest: Encodable {
        let deviceKey: String
        let deliveryId: String

        enum CodingKeys: String, CodingKey {
            case deviceKey = "device_key"
            case deliveryId = "delivery_id"
        }
    }

    struct AckResponse: Decodable {
        let removed: Bool
    }

    struct EmptyPayload: Decodable {
        init(from _: Decoder) throws {}
    }

    struct StatusResponse<T: Decodable>: Decodable {
        let success: Bool
        let error: String?
        let errorCode: String?
        let problem: GatewayProblemPayload?
        let data: T?

        enum CodingKeys: String, CodingKey {
            case success
            case error
            case errorCode = "error_code"
            case problem
            case data
        }
    }

    struct SubscribeRequest: Encodable {
        let deviceKey: String
        let channelId: String?
        let channelName: String?
        let password: String

        enum CodingKeys: String, CodingKey {
            case deviceKey = "device_key"
            case channelId = "channel_id"
            case channelName = "channel_name"
            case password
        }
    }

    struct SubscribePayload: Decodable {
        let channelId: String
        let channelName: String
        let created: Bool
        let subscribed: Bool

        enum CodingKeys: String, CodingKey {
            case channelId = "channel_id"
            case channelName = "channel_name"
            case created
            case subscribed
        }
    }

    struct UnsubscribeRequest: Encodable {
        let deviceKey: String
        let channelId: String

        enum CodingKeys: String, CodingKey {
            case deviceKey = "device_key"
            case channelId = "channel_id"
        }
    }

    struct UnsubscribePayload: Decodable {
        let channelId: String
        let removed: Bool

        enum CodingKeys: String, CodingKey {
            case channelId = "channel_id"
            case removed
        }
    }

    struct ExistsPayload: Decodable {
        let channelId: String
        let exists: Bool
        let channelName: String?

        enum CodingKeys: String, CodingKey {
            case channelId = "channel_id"
            case exists
            case channelName = "channel_name"
        }
    }

    struct RenameRequest: Encodable {
        let channelId: String
        let channelName: String
        let password: String

        enum CodingKeys: String, CodingKey {
            case channelId = "channel_id"
            case channelName = "channel_name"
            case password
        }
    }

    struct RenamePayload: Decodable {
        let channelId: String
        let channelName: String

        enum CodingKeys: String, CodingKey {
            case channelId = "channel_id"
            case channelName = "channel_name"
        }
    }

    struct SyncRequest: Encodable {
        let deviceKey: String
        let channels: [SyncItem]

        enum CodingKeys: String, CodingKey {
            case deviceKey = "device_key"
            case channels
        }
    }

    struct SyncItem: Encodable {
        let channelId: String
        let password: String

        enum CodingKeys: String, CodingKey {
            case channelId = "channel_id"
            case password
        }
    }

    struct SyncPayload: Decodable {
        let success: Int
        let failed: Int
        let channels: [SyncResult]
    }

    struct SyncResult: Decodable {
        let channelId: String
        let channelName: String?
        let subscribed: Bool
        let error: String?
        let errorCode: String?
        let problem: GatewayProblemPayload?

        enum CodingKeys: String, CodingKey {
            case channelId = "channel_id"
            case channelName = "channel_name"
            case subscribed
            case error
            case errorCode = "error_code"
            case problem
        }

        var resolvedErrorCode: String? {
            let problemCode = problem?.code?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let problemCode, !problemCode.isEmpty {
                return problemCode
            }
            let legacyCode = errorCode?.trimmingCharacters(in: .whitespacesAndNewlines)
            return legacyCode?.isEmpty == false ? legacyCode : nil
        }
    }

    static var gatewayAcceptLanguageValue: String {
        buildGatewayAcceptLanguageValue(
            preferredLanguages: Locale.preferredLanguages,
            currentIdentifier: Locale.autoupdatingCurrent.identifier
        )
    }

    static func buildGatewayAcceptLanguageValue(
        preferredLanguages: [String],
        currentIdentifier: String
    ) -> String {
        let baseCandidates = preferredLanguages.isEmpty ? [currentIdentifier] : preferredLanguages
        var normalized: [String] = []
        var seen: Set<String> = []

        for candidate in baseCandidates {
            for tag in gatewayPreferredLanguageTags(for: candidate) {
                let key = tag.lowercased()
                guard !key.isEmpty, seen.insert(key).inserted else { continue }
                normalized.append(tag)
                if normalized.count == 6 {
                    return normalized.joined(separator: ", ")
                }
            }
        }

        if seen.insert("en").inserted {
            normalized.append("en")
        }
        return normalized.joined(separator: ", ")
    }

    static func gatewayPreferredLanguageTags(for identifier: String) -> [String] {
        let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let hyphenated = trimmed.replacingOccurrences(of: "_", with: "-")
        let normalized = hyphenated.lowercased()
        if normalized == "zh"
            || normalized.hasPrefix("zh-cn")
            || normalized.hasPrefix("zh-sg")
            || normalized.hasPrefix("zh-hans")
        {
            var tags = ["zh-CN"]
            if hyphenated.caseInsensitiveCompare("zh-CN") != .orderedSame {
                tags.append(hyphenated)
            }
            return tags
        }
        return [hyphenated]
    }

    static func applyGatewayHeaders(_ request: inout URLRequest, token: String?) {
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(gatewayAcceptLanguageValue, forHTTPHeaderField: "Accept-Language")
        if let token, !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
    }

    func channelExists(
        baseURL: URL,
        token: String?,
        channelId: String
    ) async throws -> ExistsPayload {
        let baseURL = try validatedBaseURL(baseURL)
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw AppError.invalidURL
        }
        components.path = components.path.appendingPathComponent("/channel/exists")
        components.queryItems = [URLQueryItem(name: "channel_id", value: channelId)]
        guard let url = components.url else { throw AppError.invalidURL }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = AppConstants.deviceRegistrationTimeout
        Self.applyGatewayHeaders(&request, token: token)

        let (data, response) = try await URLSession.shared.data(for: request)
        return try decodePayload(ExistsPayload.self, data: data, response: response)
    }

    func registerDevice(
        baseURL: URL,
        token: String?,
        platform: String,
        existingDeviceKey: String?
    ) async throws -> DeviceRegisterPayload {
        let baseURL = try validatedBaseURL(baseURL)
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw AppError.invalidURL
        }
        components.path = components.path.appendingPathComponent(Self.deviceRegisterPath)
        guard let url = components.url else {
            throw AppError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = AppConstants.deviceRegistrationTimeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        Self.applyGatewayHeaders(&request, token: token)
        request.httpBody = try JSONEncoder().encode(
            DeviceRegisterRequest(
                deviceKey: existingDeviceKey,
                platform: platform
            )
        )
        let (data, response) = try await URLSession.shared.data(for: request)
        let payload = try decodePayload(DeviceRegisterPayload.self, data: data, response: response)
        return DeviceRegisterPayload(deviceKey: try requireResolvedDeviceKey(payload.deviceKey))
    }

    func upsertDeviceChannel(
        baseURL: URL,
        token: String?,
        deviceKey: String?,
        platform: String,
        channelType: String,
        providerToken: String?
    ) async throws -> DeviceChannelPayload {
        let baseURL = try validatedBaseURL(baseURL)
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw AppError.invalidURL
        }
        components.path = components.path.appendingPathComponent(Self.deviceRoutePath)
        guard let url = components.url else {
            throw AppError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = AppConstants.deviceRegistrationTimeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        Self.applyGatewayHeaders(&request, token: token)
        request.httpBody = try JSONEncoder().encode(
            DeviceChannelUpsertRequest(
                deviceKey: try normalizedRequiredDeviceKey(deviceKey),
                platform: platform,
                channelType: channelType,
                providerToken: providerToken
            )
        )
        let (data, response) = try await URLSession.shared.data(for: request)
        let payload = try decodePayload(DeviceChannelPayload.self, data: data, response: response)
        return DeviceChannelPayload(
            deviceKey: try requireResolvedDeviceKey(payload.deviceKey),
            channelType: payload.channelType,
            providerToken: payload.providerToken
        )
    }

    private func normalizedRequiredDeviceKey(_ deviceKey: String?) throws -> String {
        let normalized = deviceKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !normalized.isEmpty else {
            throw AppError.typedLocal(
                code: "missing_device_key",
                category: .validation,
                message: LocalizationProvider.localized("operation_failed"),
                detail: "missing device_key"
            )
        }
        return normalized
    }

    private func requireResolvedDeviceKey(_ deviceKey: String) throws -> String {
        let normalized = deviceKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            throw AppError.typedLocal(
                code: "gateway_response_missing_device_key",
                category: .internalError,
                message: LocalizationProvider.localized("operation_failed"),
                detail: "gateway response missing device_key"
            )
        }
        return normalized
    }

    func deleteDeviceChannel(
        baseURL: URL,
        token: String?,
        deviceKey: String,
        channelType: String
    ) async throws {
        let baseURL = try validatedBaseURL(baseURL)
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw AppError.invalidURL
        }
        components.path = components.path.appendingPathComponent(Self.deviceChannelDeletePath)
        guard let url = components.url else {
            throw AppError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = AppConstants.deviceRegistrationTimeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        Self.applyGatewayHeaders(&request, token: token)
        request.httpBody = try JSONEncoder().encode(
            DeviceChannelDeleteRequest(
                deviceKey: deviceKey,
                channelType: channelType
            )
        )
        let (data, response) = try await URLSession.shared.data(for: request)
        _ = try decodePayload(EmptyPayload.self, data: data, response: response)
    }

    func retireProviderToken(
        baseURL: URL,
        token: String?,
        platform: String,
        providerToken: String
    ) async throws {
        let baseURL = try validatedBaseURL(baseURL)
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw AppError.invalidURL
        }
        components.path = components.path.appendingPathComponent(Self.providerTokenRetirePath)
        guard let url = components.url else {
            throw AppError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = AppConstants.deviceRegistrationTimeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        Self.applyGatewayHeaders(&request, token: token)
        request.httpBody = try JSONEncoder().encode(
            ProviderTokenRetireRequest(
                platform: platform,
                providerToken: providerToken
            )
        )
        let (data, response) = try await URLSession.shared.data(for: request)
        _ = try decodePayload(EmptyPayload.self, data: data, response: response)
    }

    func pullMessages(
        baseURL: URL,
        token: String?,
        deviceKey: String,
        deliveryId: String? = nil
    ) async throws -> [PullItem] {
        let baseURL = try validatedBaseURL(baseURL)
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw AppError.invalidURL
        }
        components.path = components.path.appendingPathComponent("/messages/pull")
        guard let url = components.url else {
            throw AppError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = AppConstants.deviceRegistrationTimeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        Self.applyGatewayHeaders(&request, token: token)
        let normalizedDeviceKey = deviceKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedDeviceKey.isEmpty else {
            throw AppError.typedLocal(
                code: "missing_device_key",
                category: .validation,
                message: LocalizationProvider.localized("operation_failed"),
                detail: "missing device_key"
            )
        }
        let normalizedDeliveryIdRaw = deliveryId?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedDeliveryId = (normalizedDeliveryIdRaw?.isEmpty == false)
            ? normalizedDeliveryIdRaw
            : nil
        request.httpBody = try JSONEncoder().encode(
            PullRequest(
                deviceKey: normalizedDeviceKey,
                deliveryId: normalizedDeliveryId
            )
        )
        let (data, response) = try await URLSession.shared.data(for: request)
        return try decodePayload(PullResponse.self, data: data, response: response).items
    }

    func ackMessage(
        baseURL: URL,
        token: String?,
        deviceKey: String,
        deliveryId: String
    ) async throws -> Bool {
        let baseURL = try validatedBaseURL(baseURL)
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw AppError.invalidURL
        }
        components.path = components.path.appendingPathComponent("/messages/ack")
        guard let url = components.url else {
            throw AppError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = AppConstants.deviceRegistrationTimeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        Self.applyGatewayHeaders(&request, token: token)
        let normalizedDeviceKey = deviceKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedDeliveryId = deliveryId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedDeviceKey.isEmpty else {
            throw AppError.typedLocal(
                code: "missing_device_key",
                category: .validation,
                message: LocalizationProvider.localized("operation_failed"),
                detail: "missing device_key"
            )
        }
        guard !normalizedDeliveryId.isEmpty else {
            throw AppError.typedLocal(
                code: "missing_delivery_id",
                category: .validation,
                message: LocalizationProvider.localized("operation_failed"),
                detail: "missing delivery_id"
            )
        }
        request.httpBody = try JSONEncoder().encode(
            AckRequest(
                deviceKey: normalizedDeviceKey,
                deliveryId: normalizedDeliveryId
            )
        )
        let (data, response) = try await URLSession.shared.data(for: request)
        return try decodePayload(AckResponse.self, data: data, response: response).removed
    }

    func subscribe(
        baseURL: URL,
        token: String?,
        deviceKey: String,
        channelId: String?,
        channelName: String?,
        password: String
    ) async throws -> SubscribePayload {
        let baseURL = try validatedBaseURL(baseURL)
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw AppError.invalidURL
        }
        components.path = components.path.appendingPathComponent("/channel/subscribe")
        guard let url = components.url else {
            throw AppError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = AppConstants.deviceRegistrationTimeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        Self.applyGatewayHeaders(&request, token: token)

        let body = SubscribeRequest(
            deviceKey: deviceKey,
            channelId: channelId,
            channelName: channelName,
            password: password
        )
        request.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await URLSession.shared.data(for: request)
        return try decodePayload(SubscribePayload.self, data: data, response: response)
    }

    func unsubscribe(
        baseURL: URL,
        token: String?,
        deviceKey: String,
        channelId: String
    ) async throws -> Bool {
        let baseURL = try validatedBaseURL(baseURL)
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw AppError.invalidURL
        }
        components.path = components.path.appendingPathComponent("/channel/unsubscribe")
        guard let url = components.url else {
            throw AppError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = AppConstants.deviceRegistrationTimeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        Self.applyGatewayHeaders(&request, token: token)

        let body = UnsubscribeRequest(
            deviceKey: deviceKey,
            channelId: channelId
        )
        request.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await URLSession.shared.data(for: request)
        let payload = try decodePayload(UnsubscribePayload.self, data: data, response: response)
        return payload.removed
    }

    func renameChannel(
        baseURL: URL,
        token: String?,
        channelId: String,
        channelName: String,
        password: String
    ) async throws -> RenamePayload {
        let baseURL = try validatedBaseURL(baseURL)
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw AppError.invalidURL
        }
        components.path = components.path.appendingPathComponent("/channel/rename")
        guard let url = components.url else {
            throw AppError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = AppConstants.deviceRegistrationTimeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        Self.applyGatewayHeaders(&request, token: token)

        let body = RenameRequest(channelId: channelId, channelName: channelName, password: password)
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)
        return try decodePayload(RenamePayload.self, data: data, response: response)
    }

    func sync(
        baseURL: URL,
        token: String?,
        deviceKey: String,
        channels: [SyncItem]
    ) async throws -> SyncPayload {
        let baseURL = try validatedBaseURL(baseURL)
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw AppError.invalidURL
        }
        components.path = components.path.appendingPathComponent("/channel/sync")
        guard let url = components.url else {
            throw AppError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = AppConstants.deviceRegistrationTimeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        Self.applyGatewayHeaders(&request, token: token)
        request.httpBody = try JSONEncoder().encode(
            SyncRequest(deviceKey: deviceKey, channels: channels)
        )
        let (data, response) = try await URLSession.shared.data(for: request)
        return try decodePayload(SyncPayload.self, data: data, response: response)
    }

    private func validatedBaseURL(_ baseURL: URL) throws -> URL {
        guard let resolved = URLSanitizer.validatedServerURL(baseURL) else {
            throw AppError.invalidURL
        }
        return resolved
    }

    static func decodeGatewayResponse<T: Decodable>(
        _: T.Type,
        data: Data,
        response: URLResponse
    ) throws -> T {
        guard let http = response as? HTTPURLResponse else {
            throw AppError.serverUnreachable
        }
        guard let decoded = try? JSONDecoder().decode(StatusResponse<T>.self, from: data) else {
            if http.statusCode < 200 || http.statusCode >= 300 {
                throw buildGatewayError(
                    statusCode: http.statusCode,
                    legacyError: nil,
                    errorCode: nil,
                    problem: nil
                )
            }
            throw AppError.typedLocal(
                code: "gateway_invalid_response",
                category: .internalError,
                message: LocalizationProvider.localized("operation_failed"),
                detail: "invalid gateway response payload"
            )
        }
        if decoded.success, let payload = decoded.data {
            return payload
        }
        throw buildGatewayError(
            statusCode: http.statusCode,
            legacyError: decoded.error,
            errorCode: decoded.errorCode,
            problem: decoded.problem
        )
    }

    private func decodePayload<T: Decodable>(
        _ type: T.Type,
        data: Data,
        response: URLResponse
    ) throws -> T {
        try Self.decodeGatewayResponse(type, data: data, response: response)
    }

    static func buildGatewayError(
        statusCode: Int,
        legacyError: String?,
        errorCode: String?,
        problem: GatewayProblemPayload?
    ) -> AppError {
        let normalizedLegacyError = legacyError?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
        let normalizedErrorCode = errorCode?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty

        if let problem {
            return .gateway(
                GatewayProblemPayload(
                    code: normalizedErrorCode ?? problem.code,
                    category: problem.category,
                    status: problem.status == 0 ? statusCode : problem.status,
                    title: problem.title,
                    detail: problem.detail ?? normalizedLegacyError,
                    localizedMessage: problem.localizedMessage,
                    locale: problem.locale,
                    retryable: problem.retryable,
                    requestId: problem.requestId
                )
            )
        }

        if let fallback = fallbackGatewayProblem(
            statusCode: statusCode,
            errorCode: normalizedErrorCode,
            detail: normalizedLegacyError
        ) {
            return .gateway(fallback)
        }

        if statusCode == 401 || statusCode == 403 {
            return .authFailed
        }
        if statusCode < 200 || statusCode >= 300 {
            return .typedLocal(
                code: "gateway_http_failure",
                category: .internalError,
                message: LocalizationProvider.localized("operation_failed"),
                detail: "HTTP \(statusCode): request failed"
            )
        }
        return .typedLocal(
            code: "gateway_request_failed",
            category: .internalError,
            message: LocalizationProvider.localized("operation_failed"),
            detail: normalizedLegacyError ?? "request failed"
        )
    }

    private static func fallbackGatewayProblem(
        statusCode: Int,
        errorCode: String?,
        detail: String?
    ) -> GatewayProblemPayload? {
        let normalizedCode = errorCode?.lowercased()
        let normalizedDetail = detail?.lowercased()

        let inferred: (String?, GatewayErrorCategory, Bool)?
        switch normalizedCode {
        case "authentication_failed":
            inferred = ("authentication_failed", .auth, false)
        case "device_key_not_found", "channel_not_found", "device_not_found":
            inferred = (normalizedCode, .notFound, false)
        case "invalid_channel_id", "invalid_password", "invalid_platform", "invalid_device_token", "provider_token_missing", "provider_token_required", "channel_subscriber_limit_exceeded":
            inferred = (normalizedCode, .validation, false)
        case "password_mismatch", "invalid_channel_password", "platform_mismatch", "channel_type_mismatch":
            inferred = (normalizedCode, .conflict, false)
        case "private_channel_disabled":
            inferred = ("private_channel_disabled", .featureDisabled, false)
        case "server_busy", "private_channel_runtime_unavailable":
            inferred = (normalizedCode, .tooBusy, true)
        case "upstream_error":
            inferred = ("upstream_error", .upstream, true)
        case "internal_error", "store_error":
            inferred = (normalizedCode, .internalError, true)
        default:
            inferred = inferFallbackProblemFromStatus(
                statusCode: statusCode,
                detail: normalizedDetail
            )
        }

        guard let inferred else { return nil }
        return GatewayProblemPayload(
            code: inferred.0,
            category: inferred.1,
            status: statusCode,
            title: nil,
            detail: detail,
            localizedMessage: nil,
            locale: nil,
            retryable: inferred.2,
            requestId: nil
        )
    }

    private static func inferFallbackProblemFromStatus(
        statusCode: Int,
        detail: String?
    ) -> (String?, GatewayErrorCategory, Bool)? {
        if let detail {
            if detail.contains("private channel is disabled") {
                return ("private_channel_disabled", .featureDisabled, false)
            }
            if detail.contains("device_key not found") || detail.contains("device key not found") {
                return ("device_key_not_found", .notFound, false)
            }
            if detail.contains("device_not_found") || detail.contains("device not found") {
                return ("device_not_found", .notFound, false)
            }
            if detail.contains("channel_not_found") || detail.contains("channel not found") {
                return ("channel_not_found", .notFound, false)
            }
            if detail.contains("password_mismatch")
                || detail.contains("password mismatch")
                || detail.contains("invalid channel password")
            {
                return ("password_mismatch", .conflict, false)
            }
            if detail.contains("invalid_channel_id") || detail.contains("invalid channel id") {
                return ("invalid_channel_id", .validation, false)
            }
            if detail.contains("channel_id_required") || detail.contains("channel id required") {
                return ("channel_id_required", .validation, false)
            }
            if detail.contains("invalid_password") || detail.contains("invalid password") {
                return ("invalid_password", .validation, false)
            }
            if detail.contains("channel_subscriber_limit_exceeded")
                || detail.contains("subscriber limit")
            {
                return ("channel_subscriber_limit_exceeded", .validation, false)
            }
        }

        switch statusCode {
        case 400, 422:
            return (nil, .validation, false)
        case 401:
            return ("authentication_failed", .auth, false)
        case 403:
            return (nil, .permission, false)
        case 404:
            return (nil, .notFound, false)
        case 429:
            return (nil, .rateLimit, true)
        case 502, 504:
            return ("upstream_error", .upstream, true)
        case 503:
            return ("server_busy", .tooBusy, true)
        case 500 ... 599:
            return ("internal_error", .internalError, true)
        default:
            return nil
        }
    }
}

private extension String {
    func appendingPathComponent(_ component: String) -> String {
        var base = self
        if base.hasSuffix("/") {
            base.removeLast()
        }
        var appended = component
        if !appended.hasPrefix("/") {
            appended = "/" + appended
        }
        return base + appended
    }

    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
