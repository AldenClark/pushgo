import Foundation

struct ServerConfig: Identifiable, Codable, Equatable, Sendable {
    struct NotificationKeyMaterial: Codable, Equatable, Sendable {
        enum Algorithm: Equatable, Sendable {
            case plain
            case aesGcm
            case aesCbc
            case custom(String)

            var displayName: String {
                switch self {
                case .plain:
                    "PLAIN"
                case .aesGcm:
                    "AES-GCM"
                case .aesCbc:
                    "AES-CBC"
                case let .custom(value):
                    value
                }
            }
        }

        var algorithm: Algorithm
        var keyBase64: String
        var ivBase64: String?
        var updatedAt: Date

        var isConfigured: Bool {
            !keyBase64.isEmpty
        }
    }

    var id: UUID
    var name: String?
    var baseURL: URL
    var token: String?
    var notificationKeyMaterial: NotificationKeyMaterial?
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        name: String? = nil,
        baseURL: URL,
        token: String? = nil,
        notificationKeyMaterial: NotificationKeyMaterial? = nil,
        updatedAt: Date = Date(),
    ) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.token = token
        self.notificationKeyMaterial = notificationKeyMaterial
        self.updatedAt = updatedAt
    }
}

extension ServerConfig {
    var isUsingDefaultServer: Bool {
        guard let defaultURL = AppConstants.defaultServerURL else { return false }
        return baseURL == defaultURL
    }
}

extension ServerConfig {
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

    func normalized() -> ServerConfig {
        var copy = self
        copy.baseURL = normalizedBaseURL
        return copy
    }
}

extension ServerConfig.NotificationKeyMaterial.Algorithm: Codable {
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        self = Self.fromServerValue(raw)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(serverValue)
    }

    var serverValue: String {
        switch self {
        case .plain:
            "PLAIN"
        case .aesGcm:
            "AES_GCM"
        case .aesCbc:
            "AES_CBC"
        case let .custom(value):
            value
        }
    }

    static func fromServerValue(_ raw: String) -> Self {
        let normalized = raw.replacingOccurrences(of: "-", with: "_").uppercased()
        switch normalized {
        case "PLAIN":
            return .plain
        case "AES_GCM":
            return .aesGcm
        case "AES_CBC":
            return .aesCbc
        case "CUSTOM":
            return .custom("CUSTOM")
        default:
            return .custom(raw)
        }
    }
}
