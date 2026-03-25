import Foundation

struct ChannelSubscription: Codable, Hashable, Identifiable {
    let gateway: String
    let channelId: String
    let displayName: String
    let updatedAt: Date
    let lastSyncedAt: Date?

    var id: String { channelId }

    enum CodingKeys: String, CodingKey {
        case gateway
        case channelId
        case displayName
        case updatedAt
        case lastSyncedAt
    }

    init(
        gateway: String = "",
        channelId: String,
        displayName: String,
        updatedAt: Date,
        lastSyncedAt: Date?
    ) {
        self.gateway = gateway
        self.channelId = channelId
        self.displayName = displayName
        self.updatedAt = updatedAt
        self.lastSyncedAt = lastSyncedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        gateway = (try? container.decodeIfPresent(String.self, forKey: .gateway)) ?? ""
        channelId = (try? container.decode(String.self, forKey: .channelId)) ?? ""
        displayName = (try? container.decode(String.self, forKey: .displayName)) ?? ""
        updatedAt = (try? container.decode(Date.self, forKey: .updatedAt)) ?? Date.distantPast
        lastSyncedAt = try? container.decodeIfPresent(Date.self, forKey: .lastSyncedAt)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(gateway, forKey: .gateway)
        try container.encode(channelId, forKey: .channelId)
        try container.encode(displayName, forKey: .displayName)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encodeIfPresent(lastSyncedAt, forKey: .lastSyncedAt)
    }
}
