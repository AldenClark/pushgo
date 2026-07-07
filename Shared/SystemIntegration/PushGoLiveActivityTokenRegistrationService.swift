import Foundation

struct PushGoLiveActivityTokenRegistration: Codable, Equatable, Sendable {
    let activityKey: String
    let channelID: String?
    let token: String
    let platform: String
    let schemaVersion: Int

    init(
        activityKey: String,
        channelID: String?,
        token: String,
        platform: String = "ios",
        schemaVersion: Int = 1
    ) {
        self.activityKey = activityKey
        self.channelID = channelID
        self.token = token
        self.platform = platform
        self.schemaVersion = schemaVersion
    }

    enum CodingKeys: String, CodingKey {
        case activityKey = "activity_key"
        case channelID = "channel_id"
        case token
        case platform
        case schemaVersion = "schema_version"
    }
}

struct PushGoLiveActivityTokenUnregistration: Codable, Equatable, Sendable {
    let activityKey: String
    let token: String?
    let platform: String
    let schemaVersion: Int

    init(
        activityKey: String,
        token: String? = nil,
        platform: String = "ios",
        schemaVersion: Int = 1
    ) {
        self.activityKey = activityKey
        self.token = token
        self.platform = platform
        self.schemaVersion = schemaVersion
    }

    enum CodingKeys: String, CodingKey {
        case activityKey = "activity_key"
        case token
        case platform
        case schemaVersion = "schema_version"
    }
}

struct PushGoWidgetPushRegistration: Codable, Equatable, Sendable {
    struct Widget: Codable, Equatable, Sendable {
        let kind: String
        let family: String
    }

    let deviceKey: String
    let platform: String
    let token: String
    let widgets: [Widget]
    let schemaVersion: Int

    init(
        deviceKey: String,
        platform: String,
        token: String,
        widgets: [Widget],
        schemaVersion: Int = 1
    ) {
        self.deviceKey = deviceKey
        self.platform = platform
        self.token = token
        self.widgets = widgets
        self.schemaVersion = schemaVersion
    }

    enum CodingKeys: String, CodingKey {
        case deviceKey = "device_key"
        case platform
        case token
        case widgets
        case schemaVersion = "schema_version"
    }
}

enum PushGoLiveActivityTokenRegistrationService {
    typealias ServerConfigProvider = @MainActor @Sendable () -> ServerConfig?

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    @MainActor private static var serverConfigProvider: ServerConfigProvider?
    private static let urlSession = URLSession.shared

    @MainActor
    static func configure(serverConfigProvider provider: @escaping ServerConfigProvider) {
        serverConfigProvider = provider
    }

    static func register(
        activityKey: String,
        channelID: String?,
        tokenData: Data
    ) async {
        let token = tokenData.map { String(format: "%02x", $0) }.joined()
        guard !token.isEmpty else { return }
        await register(PushGoLiveActivityTokenRegistration(
            activityKey: activityKey,
            channelID: channelID,
            token: token
        ))
    }

    static func register(_ registration: PushGoLiveActivityTokenRegistration) async {
        await send(
            path: "/v1/activity/register",
            body: registration
        )
    }

    static func unregister(activityKey: String, token: String? = nil) async {
        await send(
            path: "/v1/activity/unregister",
            body: PushGoLiveActivityTokenUnregistration(activityKey: activityKey, token: token)
        )
    }

    private static func send<Body: Encodable & Sendable>(
        path: String,
        body: Body
    ) async {
        let config = await MainActor.run { serverConfigProvider?() }?.normalized()
        guard let config else { return }
        guard var request = makeRequest(config: config, path: path) else { return }
        do {
            request.httpBody = try encoder.encode(body)
            let (_, response) = try await urlSession.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode)
            else { return }
        } catch {
            return
        }
    }

    static func makeRequest(config: ServerConfig, path: String) -> URLRequest? {
        guard let url = endpointURL(baseURL: config.normalizedBaseURL, path: path) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = normalizedToken(config.token) {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    static func endpointURL(baseURL: URL, path: String) -> URL? {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            return nil
        }
        let basePath = components.percentEncodedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let endpointPath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.percentEncodedPath = "/" + [basePath, endpointPath]
            .filter { !$0.isEmpty }
            .joined(separator: "/")
        return components.url
    }

    static func normalizedToken(_ token: String?) -> String? {
        let trimmed = token?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}

enum PushGoWidgetPushRegistrationService {
    typealias ServerConfigProvider = @MainActor @Sendable () -> ServerConfig?

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    @MainActor private static var serverConfigProvider: ServerConfigProvider?
    private static let urlSession = URLSession.shared

    @MainActor
    static func configure(serverConfigProvider provider: @escaping ServerConfigProvider) {
        serverConfigProvider = provider
    }

    static func syncPendingRegistration(deviceKey rawDeviceKey: String?, platform rawPlatform: String) async {
        guard let record = PushGoWidgetPushTokenStore.load() else { return }
        let deviceKey = rawDeviceKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !deviceKey.isEmpty else { return }
        let platform = rawPlatform.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !platform.isEmpty else { return }
        let config = await MainActor.run { serverConfigProvider?() }?.normalized()
        guard let config else { return }
        let registration = PushGoWidgetPushRegistration(
            deviceKey: deviceKey,
            platform: platform,
            token: record.token,
            widgets: record.widgets.map {
                PushGoWidgetPushRegistration.Widget(kind: $0.kind, family: $0.family)
            }
        )
        let fingerprint = PushGoWidgetPushTokenStore.syncFingerprint(
            gatewayKey: config.gatewayKey,
            deviceKey: deviceKey,
            platform: platform,
            token: record.token,
            widgets: record.widgets
        )
        let defaults = AppConstants.sharedUserDefaults()
        guard defaults.string(forKey: PushGoWidgetPushTokenStore.lastSyncedFingerprintKey) != fingerprint else { return }
        guard var request = PushGoLiveActivityTokenRegistrationService.makeRequest(
            config: config,
            path: "/v1/widget-push/subscription"
        ) else { return }
        do {
            request.httpBody = try encoder.encode(registration)
            let (_, response) = try await urlSession.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode)
            else { return }
            defaults.set(fingerprint, forKey: PushGoWidgetPushTokenStore.lastSyncedFingerprintKey)
        } catch {
            return
        }
    }
}
