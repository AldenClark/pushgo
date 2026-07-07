import Foundation

struct PushGoWidgetPushTokenRecord: Codable, Equatable, Sendable {
    struct Widget: Codable, Equatable, Hashable, Sendable {
        let kind: String
        let family: String
    }

    let token: String
    let widgets: [Widget]
    let updatedAtEpochMs: Int64
}

private struct PushGoWidgetPushServerConfig: Decodable, Sendable {
    let baseURL: URL
    let token: String?

    var normalizedBaseURL: URL {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            return baseURL
        }
        var path = components.percentEncodedPath
        while path.hasSuffix("/") && path.count > 1 {
            path.removeLast()
        }
        if path == "/" {
            path = ""
        }
        components.percentEncodedPath = path
        return components.url ?? baseURL
    }

    var gatewayKey: String {
        normalizedBaseURL.absoluteString
    }
}

private struct PushGoWidgetPushRegistrationPayload: Encodable, Sendable {
    struct Widget: Encodable, Sendable {
        let kind: String
        let family: String
    }

    let deviceKey: String
    let platform: String
    let token: String
    let widgets: [Widget]
    let schemaVersion: Int

    enum CodingKeys: String, CodingKey {
        case deviceKey = "device_key"
        case platform
        case token
        case widgets
        case schemaVersion = "schema_version"
    }
}

enum PushGoWidgetPushTokenStore {
    static let defaultsKey = "io.ethan.pushgo.widgetkit.push_token.v1"
    static let lastSyncedFingerprintKey = "io.ethan.pushgo.widgetkit.push_token.synced.v1"
    private static let serverConfigDefaultsKey = "io.ethan.pushgo.wakeup_ingress.server_config.v1"
    private static let deviceKeyDefaultsPrefix = "io.ethan.pushgo.wakeup_ingress.device_key.v1."
    #if os(macOS)
    static let appGroupIdentifier = "W6H9P5MVUB.group.ethan.pushgo.messages"
    #else
    static let appGroupIdentifier = "group.ethan.pushgo.messages"
    #endif

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    static func sharedDefaults() -> UserDefaults {
        UserDefaults(suiteName: appGroupIdentifier) ?? .standard
    }

    static func save(
        tokenData: Data,
        widgets: [PushGoWidgetPushTokenRecord.Widget],
        now: Date = Date(),
        defaults: UserDefaults = sharedDefaults()
    ) {
        let token = tokenData.map { String(format: "%02x", $0) }.joined()
        guard !token.isEmpty else { return }
        let uniqueWidgets = Array(Set(widgets)).sorted {
            if $0.kind == $1.kind {
                return $0.family < $1.family
            }
            return $0.kind < $1.kind
        }
        let record = PushGoWidgetPushTokenRecord(
            token: token,
            widgets: uniqueWidgets,
            updatedAtEpochMs: Int64(now.timeIntervalSince1970 * 1000)
        )
        guard let data = try? encoder.encode(record) else { return }
        defaults.set(data, forKey: defaultsKey)
    }

    static func load(
        defaults: UserDefaults = sharedDefaults()
    ) -> PushGoWidgetPushTokenRecord? {
        guard let data = defaults.data(forKey: defaultsKey) else { return nil }
        return try? JSONDecoder().decode(PushGoWidgetPushTokenRecord.self, from: data)
    }

    static func syncSavedTokenIfPossible(
        platform rawPlatform: String = currentPlatformIdentifier(),
        defaults: UserDefaults = sharedDefaults(),
        session: URLSession = .shared
    ) async {
        guard let record = load(defaults: defaults),
              !record.token.isEmpty,
              !record.widgets.isEmpty,
              let config = loadServerConfig(defaults: defaults)
        else { return }
        let platform = rawPlatform.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !platform.isEmpty,
              let deviceKey = loadDeviceKey(platform: platform, defaults: defaults)
        else { return }
        let payload = PushGoWidgetPushRegistrationPayload(
            deviceKey: deviceKey,
            platform: platform,
            token: record.token,
            widgets: record.widgets.map {
                PushGoWidgetPushRegistrationPayload.Widget(kind: $0.kind, family: $0.family)
            },
            schemaVersion: 1
        )
        let fingerprint = syncFingerprint(
            gatewayKey: config.gatewayKey,
            deviceKey: deviceKey,
            platform: platform,
            token: record.token,
            widgets: record.widgets
        )
        guard defaults.string(forKey: lastSyncedFingerprintKey) != fingerprint,
              var request = makeRegistrationRequest(config: config)
        else { return }
        do {
            request.httpBody = try encoder.encode(payload)
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode)
            else { return }
            defaults.set(fingerprint, forKey: lastSyncedFingerprintKey)
        } catch {
            return
        }
    }

    private static func loadServerConfig(defaults: UserDefaults) -> PushGoWidgetPushServerConfig? {
        guard let data = defaults.data(forKey: serverConfigDefaultsKey) else { return nil }
        return try? JSONDecoder().decode(PushGoWidgetPushServerConfig.self, from: data)
    }

    private static func loadDeviceKey(platform: String, defaults: UserDefaults) -> String? {
        let key = deviceKeyDefaultsPrefix + platform
        let value = defaults.string(forKey: key)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    private static func makeRegistrationRequest(
        config: PushGoWidgetPushServerConfig
    ) -> URLRequest? {
        guard let url = endpointURL(baseURL: config.normalizedBaseURL, path: "/v1/widget-push/subscription") else {
            return nil
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let token = config.token?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private static func endpointURL(baseURL: URL, path: String) -> URL? {
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

    static func syncFingerprint(
        gatewayKey: String,
        deviceKey: String,
        platform: String,
        token: String,
        widgets: [PushGoWidgetPushTokenRecord.Widget]
    ) -> String {
        let widgetsValue = widgets
            .map { "\($0.kind):\($0.family)" }
            .sorted()
            .joined(separator: ",")
        return [
            gatewayKey,
            deviceKey,
            platform,
            token,
            widgetsValue
        ].joined(separator: "|")
    }

    static func currentPlatformIdentifier() -> String {
        #if os(watchOS)
        return "watchos"
        #elseif os(macOS)
        return "macos"
        #else
        return "ios"
        #endif
    }
}
