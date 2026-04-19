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
        let data: T?
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

        enum CodingKeys: String, CodingKey {
            case channelId = "channel_id"
            case channelName = "channel_name"
            case subscribed
            case error
            case errorCode = "error_code"
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
        if let token, !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

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
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token, !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
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
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token, !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
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
            throw AppError.unknown("missing device_key")
        }
        return normalized
    }

    private func requireResolvedDeviceKey(_ deviceKey: String) throws -> String {
        let normalized = deviceKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            throw AppError.unknown("gateway response missing device_key")
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
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token, !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
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
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token, !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
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
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token, !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let normalizedDeviceKey = deviceKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedDeviceKey.isEmpty else {
            throw AppError.unknown("missing device_key")
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
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token, !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let normalizedDeviceKey = deviceKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedDeliveryId = deliveryId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedDeviceKey.isEmpty else {
            throw AppError.unknown("missing device_key")
        }
        guard !normalizedDeliveryId.isEmpty else {
            throw AppError.unknown("missing delivery_id")
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
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token, !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

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
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token, !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

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
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token, !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

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
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token, !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
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

    private func decodePayload<T: Decodable>(
        _ type: T.Type,
        data: Data,
        response: URLResponse
    ) throws -> T {
        guard let http = response as? HTTPURLResponse else {
            throw AppError.serverUnreachable
        }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw AppError.authFailed
        }

        let decoded = try JSONDecoder().decode(StatusResponse<T>.self, from: data)
        if decoded.success, let payload = decoded.data {
            return payload
        }
        if let message = decoded.error?.trimmingCharacters(in: .whitespacesAndNewlines),
           !message.isEmpty {
            throw AppError.unknown("HTTP \(http.statusCode): \(message)")
        }
        if http.statusCode < 200 || http.statusCode >= 300 {
            throw AppError.unknown("HTTP \(http.statusCode): request failed")
        }
        throw AppError.unknown("Request failed")
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
}
