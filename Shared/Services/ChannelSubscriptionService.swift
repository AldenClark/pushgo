import Foundation

struct ChannelSubscriptionService {
    struct DeviceTokenRegistration: Encodable {
        let deviceToken: String
        let platform: String

        enum CodingKeys: String, CodingKey {
            case deviceToken = "device_token"
            case platform
        }
    }

    struct StatusResponse<T: Decodable>: Decodable {
        let success: Bool
        let error: String?
        let data: T?
    }

    struct SubscribeRequest: Encodable {
        let channelId: String?
        let channelName: String?
        let password: String
        let deviceToken: String?
        let platform: String?
        let deviceTokens: [DeviceTokenRegistration]?

        enum CodingKeys: String, CodingKey {
            case channelId = "channel_id"
            case channelName = "channel_name"
            case password
            case deviceToken = "device_token"
            case platform
            case deviceTokens = "device_tokens"
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
        let channelId: String
        let deviceToken: String?
        let platform: String?
        let deviceTokens: [DeviceTokenRegistration]?

        enum CodingKeys: String, CodingKey {
            case channelId = "channel_id"
            case deviceToken = "device_token"
            case platform
            case deviceTokens = "device_tokens"
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

    struct RetireRequest: Encodable {
        let device_token: String
        let platform: String
    }

    struct RetirePayload: Decodable {
        let removed_subscriptions: Int
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
        let deviceToken: String?
        let platform: String?
        let deviceTokens: [DeviceTokenRegistration]?
        let channels: [SyncItem]

        enum CodingKeys: String, CodingKey {
            case deviceToken = "device_token"
            case platform
            case deviceTokens = "device_tokens"
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
        guard let http = response as? HTTPURLResponse else {
            throw AppError.serverUnreachable
        }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw AppError.authFailed
        }

        let decoded = try JSONDecoder().decode(StatusResponse<ExistsPayload>.self, from: data)
        if decoded.success, let payload = decoded.data {
            return payload
        }
        if let message = decoded.error?.trimmingCharacters(in: .whitespacesAndNewlines), !message.isEmpty {
            throw AppError.unknown(message)
        }
        throw AppError.serverUnreachable
    }

    func subscribe(
        baseURL: URL,
        token: String?,
        channelId: String?,
        channelName: String?,
        password: String,
        deviceTokens: [DeviceTokenRegistration]
    ) async throws -> SubscribePayload {
        guard let primary = deviceTokens.first else {
            throw AppError.apnsDenied
        }
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
            channelId: channelId,
            channelName: channelName,
            password: password,
            deviceToken: primary.deviceToken,
            platform: primary.platform,
            deviceTokens: deviceTokens
        )
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AppError.serverUnreachable
        }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw AppError.authFailed
        }

        let decoded = try JSONDecoder().decode(StatusResponse<SubscribePayload>.self, from: data)
        if decoded.success, let payload = decoded.data {
            return payload
        }
        if let message = decoded.error?.trimmingCharacters(in: .whitespacesAndNewlines), !message.isEmpty {
            throw AppError.unknown(message)
        }
        throw AppError.serverUnreachable
    }

    func unsubscribe(
        baseURL: URL,
        token: String?,
        channelId: String,
        deviceTokens: [DeviceTokenRegistration]
    ) async throws -> Bool {
        guard let primary = deviceTokens.first else {
            throw AppError.apnsDenied
        }
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
            channelId: channelId,
            deviceToken: primary.deviceToken,
            platform: primary.platform,
            deviceTokens: deviceTokens
        )
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AppError.serverUnreachable
        }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw AppError.authFailed
        }

        let decoded = try JSONDecoder().decode(StatusResponse<UnsubscribePayload>.self, from: data)
        if decoded.success, let payload = decoded.data {
            return payload.removed
        }
        if let message = decoded.error?.trimmingCharacters(in: .whitespacesAndNewlines), !message.isEmpty {
            throw AppError.unknown(message)
        }
        throw AppError.serverUnreachable
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
        guard let http = response as? HTTPURLResponse else {
            throw AppError.serverUnreachable
        }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw AppError.authFailed
        }

        let decoded = try JSONDecoder().decode(StatusResponse<RenamePayload>.self, from: data)
        if decoded.success, let payload = decoded.data {
            return payload
        }
        if let message = decoded.error?.trimmingCharacters(in: .whitespacesAndNewlines), !message.isEmpty {
            throw AppError.unknown(message)
        }
        throw AppError.serverUnreachable
    }

    func retire(
        baseURL: URL,
        token: String?,
        deviceToken: String,
        platform: String
    ) async throws -> Int {
        let baseURL = try validatedBaseURL(baseURL)
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw AppError.invalidURL
        }
        components.path = components.path.appendingPathComponent("/device/retire")
        guard let url = components.url else { throw AppError.invalidURL }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = AppConstants.deviceRegistrationTimeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token, !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let body = RetireRequest(device_token: deviceToken, platform: platform)
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AppError.serverUnreachable
        }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw AppError.authFailed
        }

        let decoded = try JSONDecoder().decode(StatusResponse<RetirePayload>.self, from: data)
        if decoded.success, let payload = decoded.data {
            return payload.removed_subscriptions
        }
        if let message = decoded.error?.trimmingCharacters(in: .whitespacesAndNewlines), !message.isEmpty {
            throw AppError.unknown(message)
        }
        throw AppError.serverUnreachable
    }

    func sync(
        baseURL: URL,
        token: String?,
        deviceTokens: [DeviceTokenRegistration],
        channels: [SyncItem]
    ) async throws -> SyncPayload {
        guard let primary = deviceTokens.first else {
            throw AppError.apnsDenied
        }
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

        let body = SyncRequest(
            deviceToken: primary.deviceToken,
            platform: primary.platform,
            deviceTokens: deviceTokens,
            channels: channels
        )
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AppError.serverUnreachable
        }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw AppError.authFailed
        }

        let decoded = try JSONDecoder().decode(StatusResponse<SyncPayload>.self, from: data)
        if decoded.success, let payload = decoded.data {
            return payload
        }
        if let message = decoded.error?.trimmingCharacters(in: .whitespacesAndNewlines), !message.isEmpty {
            throw AppError.unknown(message)
        }
        throw AppError.serverUnreachable
    }

    private func validatedBaseURL(_ baseURL: URL) throws -> URL {
        guard let resolved = URLSanitizer.validatedServerURL(baseURL) else {
            throw AppError.invalidURL
        }
        return resolved
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
