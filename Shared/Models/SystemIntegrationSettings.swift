import Foundation

struct SystemIntegrationSettings: Codable, Equatable, Hashable, Sendable {
    static let schemaVersion = 1
    static let sharedDefaultsKey = "pushgo.system_integration_settings.v1"
    static let metadataValueMaxLength = 80
    static let metadataSearchValueLimit = 12

    var schemaVersion: Int
    var systemSearchEnabled: Bool
    var includeMessageBodyInSearch: Bool
    var includeMetadataInSearch: Bool
    var indexEventsAndThings: Bool
    var timeSensitiveAlertsEnabled: Bool
    var excludedChannelIDs: Set<String>
    var updatedAt: Date

    init(
        schemaVersion: Int = SystemIntegrationSettings.schemaVersion,
        systemSearchEnabled: Bool = true,
        includeMessageBodyInSearch: Bool = true,
        includeMetadataInSearch: Bool = false,
        indexEventsAndThings: Bool = true,
        timeSensitiveAlertsEnabled: Bool = false,
        excludedChannelIDs: Set<String> = [],
        updatedAt: Date = Date()
    ) {
        self.schemaVersion = schemaVersion
        self.systemSearchEnabled = systemSearchEnabled
        self.includeMessageBodyInSearch = includeMessageBodyInSearch
        self.includeMetadataInSearch = includeMetadataInSearch
        self.indexEventsAndThings = indexEventsAndThings
        self.timeSensitiveAlertsEnabled = timeSensitiveAlertsEnabled
        self.excludedChannelIDs = Set(
            excludedChannelIDs.compactMap(Self.normalizedChannelID)
        )
        self.updatedAt = updatedAt
    }

    var normalized: SystemIntegrationSettings {
        SystemIntegrationSettings(
            schemaVersion: SystemIntegrationSettings.schemaVersion,
            systemSearchEnabled: systemSearchEnabled,
            includeMessageBodyInSearch: includeMessageBodyInSearch,
            includeMetadataInSearch: includeMetadataInSearch,
            indexEventsAndThings: indexEventsAndThings,
            timeSensitiveAlertsEnabled: timeSensitiveAlertsEnabled,
            excludedChannelIDs: excludedChannelIDs,
            updatedAt: updatedAt
        )
    }

    func excludesChannel(_ channelID: String?) -> Bool {
        guard let normalized = Self.normalizedChannelID(channelID) else {
            return false
        }
        return excludedChannelIDs.contains(normalized)
    }

    static func normalizedChannelID(_ channelID: String?) -> String? {
        let trimmed = channelID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    static func loadSharedDefaults() -> SystemIntegrationSettings {
        guard let data = AppConstants.sharedUserDefaults().data(forKey: sharedDefaultsKey),
              let decoded = try? JSONDecoder().decode(SystemIntegrationSettings.self, from: data),
              decoded.schemaVersion == schemaVersion
        else {
            return SystemIntegrationSettings()
        }
        return decoded.normalized
    }

    static func saveSharedDefaults(_ settings: SystemIntegrationSettings) {
        let normalized = settings.normalized
        guard let data = try? JSONEncoder().encode(normalized) else { return }
        AppConstants.sharedUserDefaults().set(data, forKey: sharedDefaultsKey)
    }

    static func metadataSearchText(from metadata: [String: String]) -> String? {
        let values = metadata
            .sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
            .prefix(metadataSearchValueLimit)
            .compactMap { key, value -> String? in
                let normalizedKey = normalizedMetadataComponent(key)
                let normalizedValue = normalizedMetadataComponent(value)
                guard let normalizedKey, let normalizedValue else { return nil }
                return "\(normalizedKey) \(normalizedValue)"
            }
        let text = values.joined(separator: " ")
        return text.isEmpty ? nil : text
    }

    private static func normalizedMetadataComponent(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= metadataValueMaxLength else { return nil }
        return trimmed
    }
}
