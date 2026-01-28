import Foundation
import SwiftData

struct ChannelSubscription: Codable, Hashable, Identifiable {
    let gateway: String
    let channelId: String
    let displayName: String
    let updatedAt: Date
    let lastSyncedAt: Date?
    let autoCleanupEnabled: Bool

    var id: String { channelId }

    enum CodingKeys: String, CodingKey {
        case gateway
        case channelId
        case displayName
        case updatedAt
        case lastSyncedAt
        case autoCleanupEnabled
    }

    init(
        gateway: String = "",
        channelId: String,
        displayName: String,
        updatedAt: Date,
        lastSyncedAt: Date?,
        autoCleanupEnabled: Bool
    ) {
        self.gateway = gateway
        self.channelId = channelId
        self.displayName = displayName
        self.updatedAt = updatedAt
        self.lastSyncedAt = lastSyncedAt
        self.autoCleanupEnabled = autoCleanupEnabled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        gateway = (try? container.decodeIfPresent(String.self, forKey: .gateway)) ?? ""
        channelId = (try? container.decode(String.self, forKey: .channelId)) ?? ""
        displayName = (try? container.decode(String.self, forKey: .displayName)) ?? ""
        updatedAt = (try? container.decode(Date.self, forKey: .updatedAt)) ?? Date.distantPast
        lastSyncedAt = try? container.decodeIfPresent(Date.self, forKey: .lastSyncedAt)
        autoCleanupEnabled = (try? container.decode(Bool.self, forKey: .autoCleanupEnabled)) ?? true
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(gateway, forKey: .gateway)
        try container.encode(channelId, forKey: .channelId)
        try container.encode(displayName, forKey: .displayName)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encodeIfPresent(lastSyncedAt, forKey: .lastSyncedAt)
        try container.encode(autoCleanupEnabled, forKey: .autoCleanupEnabled)
    }
}

private struct MessageDerivedFields {
    let resolvedBodyText: String
    let resolvedBodyIsMarkdown: Bool
    let bodyRenderPayloadJSON: String?
    let iconURLString: String?
    let imageURLString: String?
    let secondaryText: String
    let isEncrypted: Bool
}

private func deriveMessageFields(from message: PushMessage) -> MessageDerivedFields {
    let resolvedBody = message.resolvedBody
    let payloadJSON = resolveBodyRenderPayloadJSON(
        from: message,
        resolvedBody: resolvedBody
    )
    let secondaryText: String = {
        if let thread = message.rawPayload["aps"]?.value as? [String: Any],
           let threadId = (thread["thread-id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !threadId.isEmpty
        {
            return threadId
        }
        return message.messageId?.uuidString ?? ""
    }()

    return MessageDerivedFields(
        resolvedBodyText: resolvedBody.rawText,
        resolvedBodyIsMarkdown: resolvedBody.isMarkdown,
        bodyRenderPayloadJSON: payloadJSON,
        iconURLString: message.iconURL?.absoluteString,
        imageURLString: message.imageURL?.absoluteString,
        secondaryText: secondaryText,
        isEncrypted: message.isEncrypted
    )
}

private func resolveBodyRenderPayloadJSON(
    from message: PushMessage,
    resolvedBody: PushMessage.ResolvedBody,
) -> String? {
    if let existing = message.rawPayload[AppConstants.markdownRenderPayloadKey]?.value as? String {
        return existing
    }

    guard let payload = MarkdownRenderPayloadSizing.listPayload(
        for: resolvedBody.rawText,
        isMarkdown: resolvedBody.isMarkdown
    ) else {
        return nil
    }

    return payload.encodeToJSONString()
}

@Model
final class StoredPushMessage {
    @available(iOS 18, macOS 15, watchOS 11, *)
    #Index(
        [\StoredPushMessage.receivedAt],
        [\StoredPushMessage.channel, \StoredPushMessage.receivedAt],
        [\StoredPushMessage.channel, \StoredPushMessage.isRead, \StoredPushMessage.receivedAt],
        [\StoredPushMessage.isRead, \StoredPushMessage.receivedAt],
        [\StoredPushMessage.messageId, \StoredPushMessage.receivedAt],
        [\StoredPushMessage.notificationRequestId]
    )
    @Attribute(.unique) var id: UUID
    var messageId: UUID?
    var title: String
    var body: String
    var channel: String?
    var url: URL?
    var isRead: Bool
    var receivedAt: Date
    var notificationRequestId: String?
    var resolvedBodyText: String
    var resolvedBodyIsMarkdown: Bool
    var bodyRenderPayloadJSON: String?
    var iconURLString: String?
    var imageURLString: String?
    var secondaryText: String
    var isEncryptedFlag: Bool
    var statusRaw: String
    var decryptionStateRaw: String?
    @Attribute(.externalStorage) var rawPayloadData: Data

    init(from message: PushMessage, encoder: JSONEncoder) throws {
        let derived = deriveMessageFields(from: message)
        id = message.id
        messageId = message.messageId
        title = message.title
        body = message.body
        channel = message.channel
        url = message.url
        isRead = message.isRead
        receivedAt = message.receivedAt
        notificationRequestId = message.notificationRequestId
        resolvedBodyText = derived.resolvedBodyText
        resolvedBodyIsMarkdown = derived.resolvedBodyIsMarkdown
        bodyRenderPayloadJSON = derived.bodyRenderPayloadJSON
        iconURLString = derived.iconURLString
        imageURLString = derived.imageURLString
        secondaryText = derived.secondaryText
        isEncryptedFlag = derived.isEncrypted
        statusRaw = message.status.rawValue
        decryptionStateRaw = message.decryptionState?.rawValue
        rawPayloadData = try encoder.encode(message.rawPayload)
    }

    func update(from message: PushMessage, encoder: JSONEncoder) throws {
        let derived = deriveMessageFields(from: message)
        messageId = message.messageId
        title = message.title
        body = message.body
        channel = message.channel
        url = message.url
        isRead = message.isRead
        receivedAt = message.receivedAt
        notificationRequestId = message.notificationRequestId
        resolvedBodyText = derived.resolvedBodyText
        resolvedBodyIsMarkdown = derived.resolvedBodyIsMarkdown
        bodyRenderPayloadJSON = derived.bodyRenderPayloadJSON
        iconURLString = derived.iconURLString
        imageURLString = derived.imageURLString
        secondaryText = derived.secondaryText
        isEncryptedFlag = derived.isEncrypted
        statusRaw = message.status.rawValue
        decryptionStateRaw = message.decryptionState?.rawValue
        rawPayloadData = try encoder.encode(message.rawPayload)
    }

    func toDomain(decoder: JSONDecoder) throws -> PushMessage {
        let rawPayload = try decoder.decode([String: AnyCodable].self, from: rawPayloadData)
        let status = PushMessage.Status(rawValue: statusRaw) ?? .normal
        let decryptionState = decryptionStateRaw.flatMap(PushMessage.DecryptionState.init(rawValue:))
        return PushMessage(
            id: id,
            messageId: messageId,
            title: title,
            body: body,
            channel: channel,
            url: url,
            isRead: isRead,
            receivedAt: receivedAt,
            rawPayload: rawPayload,
            status: status,
            decryptionState: decryptionState,
        )
    }

    func toSummary() -> PushMessageSummary {
        let status = PushMessage.Status(rawValue: statusRaw) ?? .normal
        let decryptionState = decryptionStateRaw.flatMap(PushMessage.DecryptionState.init(rawValue:))
        let iconURL = iconURLString.flatMap(URL.init(string:))
        let imageURL = imageURLString.flatMap(URL.init(string:))
        let bodyRenderPayload: MarkdownRenderPayload? = {
            if let payload = bodyRenderPayloadJSON.flatMap(MarkdownRenderPayload.decode) {
                return payload
            }
            guard resolvedBodyIsMarkdown else { return nil }
            guard let payload = MarkdownRenderPayloadSizing.listPayload(
                for: resolvedBodyText,
                isMarkdown: true
            ) else {
                return nil
            }
            bodyRenderPayloadJSON = payload.encodeToJSONString()
            return payload
        }()
        return PushMessageSummary(
            id: id,
            messageId: messageId,
            title: title,
            bodyPreview: resolvedBodyText,
            bodyRenderPayload: bodyRenderPayload,
            channel: channel,
            url: url,
            isRead: isRead,
            receivedAt: receivedAt,
            status: status,
            decryptionState: decryptionState,
            iconURL: iconURL,
            imageURL: imageURL,
            secondaryText: secondaryText,
            isEncrypted: isEncryptedFlag
        )
    }
}

@Model
final class StoredServerConfig {
    @Attribute(.unique) var id: UUID
    @Attribute(.externalStorage) var payloadData: Data
    var updatedAt: Date

    init(from config: ServerConfig, encoder: JSONEncoder) throws {
        id = config.id
        payloadData = try encoder.encode(config)
        updatedAt = config.updatedAt
    }

    func update(from config: ServerConfig, encoder: JSONEncoder) throws {
        payloadData = try encoder.encode(config)
        updatedAt = config.updatedAt
    }

    func toDomain(decoder: JSONDecoder) throws -> ServerConfig {
        try decoder.decode(ServerConfig.self, from: payloadData)
    }
}

@Model
final class StoredChannelSubscription {
    @available(iOS 18, macOS 15, watchOS 11, *)
    #Index(
        [\StoredChannelSubscription.channelId],
        [\StoredChannelSubscription.isDeleted, \StoredChannelSubscription.updatedAt]
    )
    @Attribute(.unique) var channelId: String
    var gateway: String?
    var displayName: String
    var password: String?
    var updatedAt: Date
    var lastSyncedAt: Date?
    var autoCleanupEnabled: Bool
    var isDeleted: Bool
    var deletedAt: Date?

    init(
        channelId: String,
        gateway: String? = nil,
        displayName: String,
        password: String?,
        updatedAt: Date,
        lastSyncedAt: Date? = nil,
        autoCleanupEnabled: Bool = true,
        isDeleted: Bool = false,
        deletedAt: Date? = nil
    ) {
        self.channelId = channelId
        self.gateway = gateway
        self.displayName = displayName
        self.password = password
        self.updatedAt = updatedAt
        self.lastSyncedAt = lastSyncedAt
        self.autoCleanupEnabled = autoCleanupEnabled
        self.isDeleted = isDeleted
        self.deletedAt = deletedAt
    }

    func toDomain() -> ChannelSubscription {
        ChannelSubscription(
            gateway: gateway ?? "",
            channelId: channelId,
            displayName: displayName,
            updatedAt: updatedAt,
            lastSyncedAt: lastSyncedAt,
            autoCleanupEnabled: autoCleanupEnabled
        )
    }
}

@Model
final class StoredAppSettings {
    @Attribute(.unique) var id: String
    var manualKeyLength: Int?
    var manualKeyEncoding: String?
    var launchAtLoginEnabled: Bool?
    var autoCleanupEnabled: Bool?
    @Attribute(.externalStorage) var pushTokenData: Data?
    var legacyMigrationVersion: Int

    init(
        id: String = "default",
        manualKeyLength: Int? = nil,
        manualKeyEncoding: String? = nil,
        launchAtLoginEnabled: Bool? = nil,
        autoCleanupEnabled: Bool? = nil,
        pushTokenData: Data? = nil,
        legacyMigrationVersion: Int = 0
    ) {
        self.id = id
        self.manualKeyLength = manualKeyLength
        self.manualKeyEncoding = manualKeyEncoding
        self.launchAtLoginEnabled = launchAtLoginEnabled
        self.autoCleanupEnabled = autoCleanupEnabled
        self.pushTokenData = pushTokenData
        self.legacyMigrationVersion = legacyMigrationVersion
    }
}

@Model
final class StoredMessageStats {
    @Attribute(.unique) var id: String
    var totalCount: Int
    var unreadCount: Int
    var updatedAt: Date

    init(
        id: String = "global",
        totalCount: Int,
        unreadCount: Int,
        updatedAt: Date = Date(),
    ) {
        self.id = id
        self.totalCount = totalCount
        self.unreadCount = unreadCount
        self.updatedAt = updatedAt
    }
}

@Model
final class StoredMessageChannelStats {
    @Attribute(.unique) var channelKey: String
    var totalCount: Int
    var unreadCount: Int
    var latestReceivedAt: Date?
    var latestUnreadAt: Date?

    init(
        channelKey: String,
        totalCount: Int,
        unreadCount: Int,
        latestReceivedAt: Date?,
        latestUnreadAt: Date?,
    ) {
        self.channelKey = channelKey
        self.totalCount = totalCount
        self.unreadCount = unreadCount
        self.latestReceivedAt = latestReceivedAt
        self.latestUnreadAt = latestUnreadAt
    }
}
