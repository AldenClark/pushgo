import Foundation
import CryptoKit

#if os(iOS) || os(watchOS)
import WatchConnectivity
#endif

enum WatchMode: String, Codable, Hashable, Sendable {
    case mirror
    case standalone
}

struct WatchLightMessage: Codable, Hashable, Identifiable, Sendable {
    let messageId: String
    let title: String
    let body: String
    let imageURL: URL?
    let url: URL?
    let severity: String?
    let receivedAt: Date
    let isRead: Bool
    let entityType: String
    let entityId: String?
    let notificationRequestId: String?

    var id: String { messageId }
}

struct WatchLightEvent: Codable, Hashable, Identifiable, Sendable {
    let eventId: String
    let title: String
    let summary: String?
    let state: String?
    let severity: String?
    let imageURL: URL?
    let updatedAt: Date

    var id: String { eventId }
}

struct WatchLightThing: Codable, Hashable, Identifiable, Sendable {
    let thingId: String
    let title: String
    let summary: String?
    let attrsJSON: String?
    let imageURL: URL?
    let updatedAt: Date

    var id: String { thingId }
}

struct WatchControlContext: Codable, Hashable, Sendable {
    let mode: WatchMode
    let controlGeneration: Int64
    let mirrorSnapshotGeneration: Int64
    let standaloneProvisioningGeneration: Int64
    let pendingMirrorActionAckGeneration: Int64
}

enum WatchModeApplyStatus: String, Codable, Hashable, Sendable {
    case applied
    case failed
}

enum WatchModeSwitchStatus: String, Codable, Hashable, Sendable {
    case idle
    case switching
    case confirmed
    case timedOut = "timed_out"
    case failed
}

struct WatchModeControlState: Hashable, Sendable {
    var desiredMode: WatchMode
    var effectiveMode: WatchMode
    var switchStatus: WatchModeSwitchStatus
    var lastConfirmedControlGeneration: Int64
    var lastObservedReportedGeneration: Int64

    static let initial = WatchModeControlState(
        desiredMode: .mirror,
        effectiveMode: .mirror,
        switchStatus: .idle,
        lastConfirmedControlGeneration: 0,
        lastObservedReportedGeneration: 0
    )
}

struct WatchEffectiveModeStatus: Codable, Hashable, Sendable {
    let effectiveMode: WatchMode
    let sourceControlGeneration: Int64
    let appliedAt: Date
    let noop: Bool
    let status: WatchModeApplyStatus
    let failureReason: String?
}

struct WatchStandaloneReadinessStatus: Codable, Hashable, Sendable {
    let effectiveMode: WatchMode
    let standaloneReady: Bool
    let sourceControlGeneration: Int64
    let provisioningGeneration: Int64
    let reportedAt: Date
    let failureReason: String?
}

struct WatchMirrorSnapshot: Codable, Hashable, Sendable {
    let generation: Int64
    let mode: WatchMode
    let messages: [WatchLightMessage]
    let events: [WatchLightEvent]
    let things: [WatchLightThing]
    let exportedAt: Date
    let contentDigest: String

    static func contentDigest(
        messages: [WatchLightMessage],
        events: [WatchLightEvent],
        things: [WatchLightThing]
    ) -> String {
        let input = WatchMirrorSnapshotDigestInput(
            messages: messages,
            events: events,
            things: things
        )
        let encoder = WatchConnectivityWire.makeEncoder()
        encoder.outputFormatting.insert(.sortedKeys)
        let data = (try? encoder.encode(input)) ?? Data()
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

private struct WatchMirrorSnapshotDigestInput: Codable {
    let messages: [WatchLightMessage]
    let events: [WatchLightEvent]
    let things: [WatchLightThing]
}

struct WatchStandaloneChannelCredential: Codable, Hashable, Identifiable, Sendable {
    let gateway: String
    let channelId: String
    let displayName: String
    let password: String
    let updatedAt: Date

    var id: String { "\(gateway)|\(channelId)" }
}

struct WatchStandaloneProvisioningSnapshot: Codable, Sendable {
    let generation: Int64
    let mode: WatchMode
    let serverConfig: ServerConfig?
    let notificationKeyMaterial: ServerConfig.NotificationKeyMaterial?
    let channels: [WatchStandaloneChannelCredential]
    let contentDigest: String

    static func contentDigest(
        serverConfig: ServerConfig?,
        notificationKeyMaterial: ServerConfig.NotificationKeyMaterial?,
        channels: [WatchStandaloneChannelCredential]
    ) -> String {
        let input = WatchStandaloneProvisioningDigestInput(
            serverConfig: serverConfig.map {
                WatchStandaloneProvisioningDigestServerConfig(
                    baseURL: $0.normalizedBaseURL.absoluteString,
                    token: $0.token?.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            },
            notificationKeyMaterial: notificationKeyMaterial.map {
                WatchStandaloneProvisioningDigestKeyMaterial(
                    algorithm: $0.algorithm.serverValue,
                    keyBase64: $0.keyData.base64EncodedString(),
                    ivBase64: $0.ivBase64?.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            },
            channels: channels
                .map {
                    WatchStandaloneProvisioningDigestChannel(
                        gateway: $0.gateway.trimmingCharacters(in: .whitespacesAndNewlines),
                        channelId: $0.channelId.trimmingCharacters(in: .whitespacesAndNewlines),
                        displayName: $0.displayName.trimmingCharacters(in: .whitespacesAndNewlines),
                        password: $0.password.trimmingCharacters(in: .whitespacesAndNewlines)
                    )
                }
                .sorted {
                    if $0.gateway == $1.gateway {
                        return $0.channelId < $1.channelId
                    }
                    return $0.gateway < $1.gateway
                }
        )
        let encoder = WatchConnectivityWire.makeEncoder()
        encoder.outputFormatting.insert(.sortedKeys)
        let data = (try? encoder.encode(input)) ?? Data()
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

private struct WatchStandaloneProvisioningDigestInput: Codable {
    let serverConfig: WatchStandaloneProvisioningDigestServerConfig?
    let notificationKeyMaterial: WatchStandaloneProvisioningDigestKeyMaterial?
    let channels: [WatchStandaloneProvisioningDigestChannel]
}

private struct WatchStandaloneProvisioningDigestServerConfig: Codable {
    let baseURL: String
    let token: String?
}

private struct WatchStandaloneProvisioningDigestKeyMaterial: Codable {
    let algorithm: String
    let keyBase64: String
    let ivBase64: String?
}

private struct WatchStandaloneProvisioningDigestChannel: Codable {
    let gateway: String
    let channelId: String
    let displayName: String
    let password: String
}

enum WatchMirrorActionKind: String, Codable, Hashable, Sendable {
    case read
    case delete
}

struct WatchMirrorAction: Codable, Hashable, Identifiable, Sendable {
    let actionId: String
    let kind: WatchMirrorActionKind
    let messageId: String
    let issuedAt: Date

    var id: String { actionId }
}

struct WatchMirrorActionBatch: Codable, Hashable, Sendable {
    let batchId: String
    let mode: WatchMode
    let actions: [WatchMirrorAction]
}

struct WatchMirrorActionAck: Codable, Hashable, Sendable {
    let ackGeneration: Int64
    let ackedActionIds: [String]
}

struct WatchMirrorSnapshotAck: Codable, Hashable, Sendable {
    let generation: Int64
    let contentDigest: String
    let appliedAt: Date
}

struct WatchMirrorSnapshotNack: Codable, Hashable, Sendable {
    let generation: Int64
    let contentDigest: String
    let failedStage: String
    let errorDescription: String
    let reportedAt: Date
}

struct WatchStandaloneProvisioningAck: Codable, Hashable, Sendable {
    let generation: Int64
    let contentDigest: String
    let appliedAt: Date
}

struct WatchStandaloneProvisioningNack: Codable, Hashable, Sendable {
    let generation: Int64
    let contentDigest: String
    let failedStage: String
    let errorDescription: String
    let reportedAt: Date
}

struct WatchSyncGenerationState: Hashable, Sendable {
    var controlGeneration: Int64
    var mirrorSnapshotGeneration: Int64
    var standaloneProvisioningGeneration: Int64
    var mirrorActionAckGeneration: Int64

    static let zero = WatchSyncGenerationState(
        controlGeneration: 0,
        mirrorSnapshotGeneration: 0,
        standaloneProvisioningGeneration: 0,
        mirrorActionAckGeneration: 0
    )
}

enum WatchConnectivityPayloadKey: String, CaseIterable, Sendable {
    case controlContext = "watch_control_context"
    case mirrorSnapshot = "watch_mirror_snapshot"
    case standaloneProvisioning = "watch_standalone_provisioning"
    case mirrorActionBatch = "watch_mirror_action_batch"
    case mirrorActionAck = "watch_mirror_action_ack"
    case apnsToken = "watch_apns_token"
}

enum WatchConnectivitySchema {
    static let currentVersion = 7
}

enum WatchTransportKind: String, Codable, Hashable, Sendable {
    case applicationContext
    case fileTransfer
    case reliableEvent
    case interactiveMessage
}

enum WatchLinkPhase: String, Codable, Hashable, Sendable {
    case unsupported
    case activating
    case activatedNoCompanion
    case activatedCompanionAvailable
    case reachable
}

struct WatchLinkState: Codable, Hashable, Sendable {
    var phase: WatchLinkPhase
    var lastErrorDescription: String?

    static let unsupported = WatchLinkState(phase: .unsupported, lastErrorDescription: nil)
    static let activating = WatchLinkState(phase: .activating, lastErrorDescription: nil)

    var isCompanionAvailable: Bool {
        switch phase {
        case .activatedCompanionAvailable, .reachable:
            true
        case .unsupported, .activating, .activatedNoCompanion:
            false
        }
    }

    var isReachable: Bool {
        phase == .reachable
    }
}

enum WatchPackageKind: String, Codable, Hashable, Sendable {
    case mirrorSnapshot
    case standaloneProvisioning
}

struct MirrorPackageRef: Codable, Hashable, Sendable {
    let packageID: String
    let generation: Int64
    let createdAt: Date
}

struct StandalonePackageRef: Codable, Hashable, Sendable {
    let packageID: String
    let generation: Int64
    let createdAt: Date
}

struct AckCursorRef: Codable, Hashable, Sendable {
    let generation: Int64
    let lastEventID: String?
}

struct AppliedPackageAckRef: Codable, Hashable, Sendable {
    let generation: Int64
    let contentDigest: String
    let appliedAt: Date
}

struct WatchSyncManifest: Codable, Hashable, Sendable {
    let schemaVersion: Int
    let mode: WatchMode
    let controlGeneration: Int64
    let mirrorPackage: MirrorPackageRef?
    let standalonePackage: StandalonePackageRef?
    let effectiveModeStatus: WatchEffectiveModeStatus?
    let standaloneReadinessStatus: WatchStandaloneReadinessStatus?
    let ackCursor: AckCursorRef?
    let mirrorSnapshotAck: AppliedPackageAckRef?
    let standaloneProvisioningAck: AppliedPackageAckRef?
    let inlineMirrorSnapshot: Data?
    let inlineStandaloneProvisioning: Data?

    private static let schemaVersionKey = "watch_manifest_schema_version"
    private static let modeKey = "watch_manifest_mode"
    private static let controlGenerationKey = "watch_manifest_control_generation"
    private static let mirrorPackageKey = "watch_manifest_mirror_package"
    private static let standalonePackageKey = "watch_manifest_standalone_package"
    private static let effectiveModeStatusKey = "watch_manifest_effective_mode_status"
    private static let standaloneReadinessStatusKey = "watch_manifest_standalone_readiness_status"
    private static let ackCursorKey = "watch_manifest_ack_cursor"
    private static let mirrorSnapshotAckKey = "watch_manifest_mirror_snapshot_ack"
    private static let standaloneProvisioningAckKey = "watch_manifest_standalone_provisioning_ack"
    private static let inlineMirrorSnapshotKey = "watch_manifest_inline_mirror_snapshot"
    private static let inlineStandaloneProvisioningKey = "watch_manifest_inline_standalone_provisioning"
    private static let encodedManifestKey = "watch_manifest_blob"

    init(
        schemaVersion: Int,
        mode: WatchMode,
        controlGeneration: Int64,
        mirrorPackage: MirrorPackageRef?,
        standalonePackage: StandalonePackageRef?,
        effectiveModeStatus: WatchEffectiveModeStatus? = nil,
        standaloneReadinessStatus: WatchStandaloneReadinessStatus? = nil,
        ackCursor: AckCursorRef?,
        mirrorSnapshotAck: AppliedPackageAckRef?,
        standaloneProvisioningAck: AppliedPackageAckRef?,
        inlineMirrorSnapshot: Data?,
        inlineStandaloneProvisioning: Data?
    ) {
        self.schemaVersion = schemaVersion
        self.mode = mode
        self.controlGeneration = controlGeneration
        self.mirrorPackage = mirrorPackage
        self.standalonePackage = standalonePackage
        self.effectiveModeStatus = effectiveModeStatus
        self.standaloneReadinessStatus = standaloneReadinessStatus
        self.ackCursor = ackCursor
        self.mirrorSnapshotAck = mirrorSnapshotAck
        self.standaloneProvisioningAck = standaloneProvisioningAck
        self.inlineMirrorSnapshot = inlineMirrorSnapshot
        self.inlineStandaloneProvisioning = inlineStandaloneProvisioning
    }

    func applicationContext() -> [String: Any] {
        var payload: [String: Any] = [
            Self.schemaVersionKey: schemaVersion,
            Self.modeKey: mode.rawValue,
            Self.controlGenerationKey: controlGeneration,
        ]
        if let mirrorPackage {
            payload[Self.mirrorPackageKey] = mirrorPackage.dictionaryValue()
        }
        if let standalonePackage {
            payload[Self.standalonePackageKey] = standalonePackage.dictionaryValue()
        }
        if let effectiveModeStatus {
            payload[Self.effectiveModeStatusKey] = effectiveModeStatus.dictionaryValue()
        }
        if let standaloneReadinessStatus {
            payload[Self.standaloneReadinessStatusKey] = standaloneReadinessStatus.dictionaryValue()
        }
        if let ackCursor {
            payload[Self.ackCursorKey] = ackCursor.dictionaryValue()
        }
        if let mirrorSnapshotAck {
            payload[Self.mirrorSnapshotAckKey] = mirrorSnapshotAck.dictionaryValue()
        }
        if let standaloneProvisioningAck {
            payload[Self.standaloneProvisioningAckKey] = standaloneProvisioningAck.dictionaryValue()
        }
        if let inlineMirrorSnapshot {
            payload[Self.inlineMirrorSnapshotKey] = inlineMirrorSnapshot
        }
        if let inlineStandaloneProvisioning {
            payload[Self.inlineStandaloneProvisioningKey] = inlineStandaloneProvisioning
        }
        if let encoded = WatchConnectivityWire.encode(self) {
            payload[Self.encodedManifestKey] = encoded
        }
        return payload
    }

    static func fromApplicationContext(_ payload: [String: Any]) -> WatchSyncManifest? {
        if let manifest = manifestFromDictionaryPayload(payload) {
            return manifest
        }
        if let manifest = manifestFromEncodedPayload(payload) {
            return manifest
        }
        return nil
    }

    private static func manifestFromDictionaryPayload(_ payload: [String: Any]) -> WatchSyncManifest? {
        guard let schemaVersion = payload[Self.schemaVersionKey] as? Int,
              let modeRawValue = payload[Self.modeKey] as? String,
              let mode = WatchMode(rawValue: modeRawValue),
              let controlGeneration = payload[Self.controlGenerationKey] as? Int64 ?? int64Value(payload[Self.controlGenerationKey])
        else {
            return nil
        }
        let mirrorPackage = MirrorPackageRef.fromDictionary(payload[Self.mirrorPackageKey] as? [String: Any])
        let standalonePackage = StandalonePackageRef.fromDictionary(payload[Self.standalonePackageKey] as? [String: Any])
        let effectiveModeStatus = WatchEffectiveModeStatus.fromDictionary(
            payload[Self.effectiveModeStatusKey] as? [String: Any]
        )
        let standaloneReadinessStatus = WatchStandaloneReadinessStatus.fromDictionary(
            payload[Self.standaloneReadinessStatusKey] as? [String: Any]
        )
        let ackCursor = AckCursorRef.fromDictionary(payload[Self.ackCursorKey] as? [String: Any])
        let mirrorSnapshotAck = AppliedPackageAckRef.fromDictionary(
            payload[Self.mirrorSnapshotAckKey] as? [String: Any]
        )
        let standaloneProvisioningAck = AppliedPackageAckRef.fromDictionary(
            payload[Self.standaloneProvisioningAckKey] as? [String: Any]
        )
        let inlineMirrorSnapshot = payload[Self.inlineMirrorSnapshotKey] as? Data
        let inlineStandaloneProvisioning = payload[Self.inlineStandaloneProvisioningKey] as? Data
        return WatchSyncManifest(
            schemaVersion: schemaVersion,
            mode: mode,
            controlGeneration: controlGeneration,
            mirrorPackage: mirrorPackage,
            standalonePackage: standalonePackage,
            effectiveModeStatus: effectiveModeStatus,
            standaloneReadinessStatus: standaloneReadinessStatus,
            ackCursor: ackCursor,
            mirrorSnapshotAck: mirrorSnapshotAck,
            standaloneProvisioningAck: standaloneProvisioningAck,
            inlineMirrorSnapshot: inlineMirrorSnapshot,
            inlineStandaloneProvisioning: inlineStandaloneProvisioning
        )
    }

    private static func manifestFromEncodedPayload(_ payload: [String: Any]) -> WatchSyncManifest? {
        guard let data = payload[Self.encodedManifestKey] as? Data else { return nil }
        return WatchConnectivityWire.decode(WatchSyncManifest.self, from: data)
    }

    var isCurrentSchema: Bool {
        schemaVersion == WatchConnectivitySchema.currentVersion
    }

    func withoutInlinePackages() -> WatchSyncManifest {
        guard inlineMirrorSnapshot != nil || inlineStandaloneProvisioning != nil else {
            return self
        }
        return WatchSyncManifest(
            schemaVersion: schemaVersion,
            mode: mode,
            controlGeneration: controlGeneration,
            mirrorPackage: mirrorPackage,
            standalonePackage: standalonePackage,
            effectiveModeStatus: effectiveModeStatus,
            standaloneReadinessStatus: standaloneReadinessStatus,
            ackCursor: ackCursor,
            mirrorSnapshotAck: mirrorSnapshotAck,
            standaloneProvisioningAck: standaloneProvisioningAck,
            inlineMirrorSnapshot: nil,
            inlineStandaloneProvisioning: nil
        )
    }

    func withInlinePackages(
        mirrorSnapshot: Data?,
        standaloneProvisioning: Data?
    ) -> WatchSyncManifest {
        WatchSyncManifest(
            schemaVersion: schemaVersion,
            mode: mode,
            controlGeneration: controlGeneration,
            mirrorPackage: mirrorPackage,
            standalonePackage: standalonePackage,
            effectiveModeStatus: effectiveModeStatus,
            standaloneReadinessStatus: standaloneReadinessStatus,
            ackCursor: ackCursor,
            mirrorSnapshotAck: mirrorSnapshotAck,
            standaloneProvisioningAck: standaloneProvisioningAck,
            inlineMirrorSnapshot: mirrorSnapshot,
            inlineStandaloneProvisioning: standaloneProvisioning
        )
    }
}

struct WatchTransferPackageManifest: Codable, Hashable, Sendable {
    let schemaVersion: Int
    let packageID: String
    let kind: WatchPackageKind
    let generation: Int64
    let createdAt: Date

    func metadataDictionary() -> [String: Any] {
        [
            "watch_transfer_schema_version": schemaVersion,
            "watch_transfer_package_id": packageID,
            "watch_transfer_kind": kind.rawValue,
            "watch_transfer_generation": generation,
        ]
    }

    static func fromMetadata(_ metadata: [String: Any]?) -> WatchTransferPackageManifest? {
        guard let metadata,
              let schemaVersion = metadata["watch_transfer_schema_version"] as? Int,
              let packageID = metadata["watch_transfer_package_id"] as? String,
              let kindRawValue = metadata["watch_transfer_kind"] as? String,
              let kind = WatchPackageKind(rawValue: kindRawValue),
              let generation = metadata["watch_transfer_generation"] as? Int64 ?? int64Value(metadata["watch_transfer_generation"])
        else {
            return nil
        }
        return WatchTransferPackageManifest(
            schemaVersion: schemaVersion,
            packageID: packageID,
            kind: kind,
            generation: generation,
            createdAt: Date()
        )
    }
}

struct MirrorSnapshotPackage: Codable, Sendable {
    let manifest: WatchTransferPackageManifest
    let snapshot: WatchMirrorSnapshot
}

struct StandaloneProvisioningPackage: Codable, Sendable {
    let manifest: WatchTransferPackageManifest
    let snapshot: WatchStandaloneProvisioningSnapshot
}

enum WatchReliableEventKind: String, Codable, Hashable, Sendable {
    case mirrorActionBatch
    case mirrorActionAck
    case mirrorSnapshotInline
    case mirrorSnapshotAck
    case mirrorSnapshotNack
    case pushTokenUpdate
    case standaloneProvisioningInline
    case standaloneProvisioningAck
    case standaloneProvisioningNack
}

struct WatchEventEnvelope: Codable, Hashable, Sendable {
    let eventID: String
    let schemaVersion: Int
    let createdAt: Date
    let kind: WatchReliableEventKind
    let payload: Data

    private static let eventIDKey = "watch_event_id"
    private static let schemaVersionKey = "watch_event_schema_version"
    private static let createdAtKey = "watch_event_created_at"
    private static let kindKey = "watch_event_kind"
    private static let payloadKey = "watch_event_payload"

    func userInfo() -> [String: Any] {
        [
            Self.eventIDKey: eventID,
            Self.schemaVersionKey: schemaVersion,
            Self.createdAtKey: createdAt.timeIntervalSince1970,
            Self.kindKey: kind.rawValue,
            Self.payloadKey: payload,
        ]
    }

    static func fromUserInfo(_ userInfo: [String: Any]) -> WatchEventEnvelope? {
        guard let eventID = userInfo[Self.eventIDKey] as? String,
              let schemaVersion = userInfo[Self.schemaVersionKey] as? Int,
              let createdAtSeconds = userInfo[Self.createdAtKey] as? Double,
              let kindRawValue = userInfo[Self.kindKey] as? String,
              let kind = WatchReliableEventKind(rawValue: kindRawValue),
              let payload = userInfo[Self.payloadKey] as? Data
        else {
            return nil
        }
        return WatchEventEnvelope(
            eventID: eventID,
            schemaVersion: schemaVersion,
            createdAt: Date(timeIntervalSince1970: createdAtSeconds),
            kind: kind,
            payload: payload
        )
    }
}

enum WatchLiveMessageKind: String, Codable, Hashable, Sendable {
    case requestLatestManifest
    case refreshHint
}

struct WatchLiveMessage: Codable, Hashable, Sendable {
    let schemaVersion: Int
    let kind: WatchLiveMessageKind

    private static let schemaVersionKey = "watch_live_schema_version"
    private static let kindKey = "watch_live_kind"

    func payload() -> [String: Any] {
        [
            Self.schemaVersionKey: schemaVersion,
            Self.kindKey: kind.rawValue,
        ]
    }

    static func fromPayload(_ payload: [String: Any]) -> WatchLiveMessage? {
        guard let schemaVersion = payload[Self.schemaVersionKey] as? Int,
              let kindRawValue = payload[Self.kindKey] as? String,
              let kind = WatchLiveMessageKind(rawValue: kindRawValue)
        else {
            return nil
        }
        return WatchLiveMessage(schemaVersion: schemaVersion, kind: kind)
    }
}

private enum WatchConnectivityPayloadCodec: String, Codable {
    case identity
    case lzfse
}

private struct WatchConnectivityEnvelope: Codable {
    let version: Int
    let codec: WatchConnectivityPayloadCodec
    let payload: Data
}

enum WatchConnectivityWire {
    static let contextSoftLimitBytes = 48 * 1024
    static let contextVersionKey = "watch_wire_version"
    static let contextVersion = 2
    private static let compressionThresholdBytes = 1024

    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    static func encode<T: Encodable>(_ value: T) -> Data? {
        guard let data = try? makeEncoder().encode(value) else { return nil }
        return encodeTransportData(data)
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) -> T? {
        guard let decoded = decodeTransportData(data) else { return nil }
        return try? makeDecoder().decode(type, from: decoded)
    }

    static func data(from payload: [String: Any], key: WatchConnectivityPayloadKey) -> Data? {
        payload[key.rawValue] as? Data
    }

    static func string(from payload: [String: Any], key: WatchConnectivityPayloadKey) -> String? {
        payload[key.rawValue] as? String
    }

    static func decode<T: Decodable>(
        _ type: T.Type,
        from payload: [String: Any],
        key: WatchConnectivityPayloadKey
    ) -> T? {
        guard let data = data(from: payload, key: key) else { return nil }
        return decode(type, from: data)
    }

    private static func encodeTransportData(_ data: Data) -> Data {
        guard data.count >= compressionThresholdBytes,
              let compressed = compress(data),
              compressed.count < data.count
        else {
            return data
        }
        let envelope = WatchConnectivityEnvelope(
            version: contextVersion,
            codec: .lzfse,
            payload: compressed
        )
        return (try? makeEncoder().encode(envelope)) ?? data
    }

    private static func decodeTransportData(_ data: Data) -> Data? {
        guard let envelope = try? makeDecoder().decode(WatchConnectivityEnvelope.self, from: data) else {
            return data
        }
        switch envelope.codec {
        case .identity:
            return envelope.payload
        case .lzfse:
            return decompress(envelope.payload)
        }
    }

    private static func compress(_ data: Data) -> Data? {
        try? (data as NSData).compressed(using: .lzfse) as Data
    }

    private static func decompress(_ data: Data) -> Data? {
        try? (data as NSData).decompressed(using: .lzfse) as Data
    }
}

private extension MirrorPackageRef {
    func dictionaryValue() -> [String: Any] {
        [
            "package_id": packageID,
            "generation": generation,
            "created_at": createdAt.timeIntervalSince1970,
        ]
    }

    static func fromDictionary(_ dictionary: [String: Any]?) -> MirrorPackageRef? {
        guard let dictionary,
              let packageID = dictionary["package_id"] as? String,
              let generation = int64Value(dictionary["generation"]),
              let createdAtSeconds = dictionary["created_at"] as? Double
        else {
            return nil
        }
        return MirrorPackageRef(
            packageID: packageID,
            generation: generation,
            createdAt: Date(timeIntervalSince1970: createdAtSeconds)
        )
    }
}

private extension StandalonePackageRef {
    func dictionaryValue() -> [String: Any] {
        [
            "package_id": packageID,
            "generation": generation,
            "created_at": createdAt.timeIntervalSince1970,
        ]
    }

    static func fromDictionary(_ dictionary: [String: Any]?) -> StandalonePackageRef? {
        guard let dictionary,
              let packageID = dictionary["package_id"] as? String,
              let generation = int64Value(dictionary["generation"]),
              let createdAtSeconds = dictionary["created_at"] as? Double
        else {
            return nil
        }
        return StandalonePackageRef(
            packageID: packageID,
            generation: generation,
            createdAt: Date(timeIntervalSince1970: createdAtSeconds)
        )
    }
}

private extension AckCursorRef {
    func dictionaryValue() -> [String: Any] {
        var payload: [String: Any] = [
            "generation": generation,
        ]
        if let lastEventID {
            payload["last_event_id"] = lastEventID
        }
        return payload
    }

    static func fromDictionary(_ dictionary: [String: Any]?) -> AckCursorRef? {
        guard let dictionary,
              let generation = int64Value(dictionary["generation"])
        else {
            return nil
        }
        return AckCursorRef(
            generation: generation,
            lastEventID: dictionary["last_event_id"] as? String
        )
    }
}

private extension AppliedPackageAckRef {
    func dictionaryValue() -> [String: Any] {
        [
            "generation": generation,
            "content_digest": contentDigest,
            "applied_at": ISO8601DateFormatter().string(from: appliedAt)
        ]
    }

    static func fromDictionary(_ dictionary: [String: Any]?) -> AppliedPackageAckRef? {
        guard let dictionary,
              let generation = int64Value(dictionary["generation"]),
              let contentDigest = dictionary["content_digest"] as? String,
              let appliedAt = dateValue(dictionary["applied_at"])
        else {
            return nil
        }
        return AppliedPackageAckRef(
            generation: generation,
            contentDigest: contentDigest,
            appliedAt: appliedAt
        )
    }
}

private extension WatchEffectiveModeStatus {
    func dictionaryValue() -> [String: Any] {
        var payload: [String: Any] = [
            "effective_mode": effectiveMode.rawValue,
            "source_control_generation": sourceControlGeneration,
            "applied_at": ISO8601DateFormatter().string(from: appliedAt),
            "noop": noop,
            "status": status.rawValue,
        ]
        if let failureReason,
           !failureReason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            payload["failure_reason"] = failureReason
        }
        return payload
    }

    static func fromDictionary(_ dictionary: [String: Any]?) -> WatchEffectiveModeStatus? {
        guard let dictionary,
              let effectiveModeRawValue = dictionary["effective_mode"] as? String,
              let effectiveMode = WatchMode(rawValue: effectiveModeRawValue),
              let sourceControlGeneration = int64Value(dictionary["source_control_generation"]),
              let appliedAt = dateValue(dictionary["applied_at"]),
              let noop = dictionary["noop"] as? Bool,
              let statusRawValue = dictionary["status"] as? String,
              let status = WatchModeApplyStatus(rawValue: statusRawValue)
        else {
            return nil
        }
        return WatchEffectiveModeStatus(
            effectiveMode: effectiveMode,
            sourceControlGeneration: sourceControlGeneration,
            appliedAt: appliedAt,
            noop: noop,
            status: status,
            failureReason: dictionary["failure_reason"] as? String
        )
    }
}

private extension WatchStandaloneReadinessStatus {
    func dictionaryValue() -> [String: Any] {
        var payload: [String: Any] = [
            "effective_mode": effectiveMode.rawValue,
            "standalone_ready": standaloneReady,
            "source_control_generation": sourceControlGeneration,
            "provisioning_generation": provisioningGeneration,
            "reported_at": ISO8601DateFormatter().string(from: reportedAt),
        ]
        if let failureReason,
           !failureReason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            payload["failure_reason"] = failureReason
        }
        return payload
    }

    static func fromDictionary(_ dictionary: [String: Any]?) -> WatchStandaloneReadinessStatus? {
        guard let dictionary,
              let effectiveModeRawValue = dictionary["effective_mode"] as? String,
              let effectiveMode = WatchMode(rawValue: effectiveModeRawValue),
              let standaloneReady = dictionary["standalone_ready"] as? Bool,
              let sourceControlGeneration = int64Value(dictionary["source_control_generation"]),
              let provisioningGeneration = int64Value(dictionary["provisioning_generation"]),
              let reportedAt = dateValue(dictionary["reported_at"])
        else {
            return nil
        }
        return WatchStandaloneReadinessStatus(
            effectiveMode: effectiveMode,
            standaloneReady: standaloneReady,
            sourceControlGeneration: sourceControlGeneration,
            provisioningGeneration: provisioningGeneration,
            reportedAt: reportedAt,
            failureReason: dictionary["failure_reason"] as? String
        )
    }
}

private func int64Value(_ value: Any?) -> Int64? {
    switch value {
    case let value as Int64:
        value
    case let value as Int:
        Int64(value)
    case let value as NSNumber:
        value.int64Value
    default:
        nil
    }
}

private func dateValue(_ value: Any?) -> Date? {
    switch value {
    case let value as Date:
        value
    case let value as String:
        ISO8601DateFormatter().date(from: value)
    case let value as NSNumber:
        Date(timeIntervalSince1970: value.doubleValue)
    default:
        nil
    }
}

private func watchConnectivitySortedKeyList(_ payload: [String: Any]) -> String {
    payload.keys.sorted().joined(separator: ",")
}

private func applicationContextSizeBytes(for payload: [String: Any]) -> Int {
    guard PropertyListSerialization.propertyList(payload, isValidFor: .binary),
          let data = try? PropertyListSerialization.data(
            fromPropertyList: payload,
            format: .binary,
            options: 0
          )
    else {
        return .max
    }
    return data.count
}

enum WatchConnectivityManifestPublishPolicy {
    static func signature(for manifest: WatchSyncManifest) -> String {
        let encoder = WatchConnectivityWire.makeEncoder()
        encoder.outputFormatting.insert(.sortedKeys)
        if let encoded = try? encoder.encode(manifest) {
            return sha256Hex(of: encoded)
        }
        let fallback = "\(manifest.schemaVersion)|\(manifest.mode.rawValue)|\(manifest.controlGeneration)|\(manifest.mirrorPackage?.packageID ?? "nil")|\(manifest.standalonePackage?.packageID ?? "nil")|\(manifest.effectiveModeStatus?.effectiveMode.rawValue ?? "nil")|\(manifest.effectiveModeStatus?.sourceControlGeneration ?? -1)|\(manifest.effectiveModeStatus?.status.rawValue ?? "nil")|\(manifest.effectiveModeStatus?.noop ?? false)|\(manifest.standaloneReadinessStatus?.effectiveMode.rawValue ?? "nil")|\(manifest.standaloneReadinessStatus?.standaloneReady ?? false)|\(manifest.standaloneReadinessStatus?.sourceControlGeneration ?? -1)|\(manifest.standaloneReadinessStatus?.provisioningGeneration ?? -1)|\(manifest.ackCursor?.generation ?? -1)|\(manifest.ackCursor?.lastEventID ?? "nil")|\(manifest.mirrorSnapshotAck?.generation ?? -1)|\(manifest.mirrorSnapshotAck?.contentDigest ?? "nil")|\(manifest.standaloneProvisioningAck?.generation ?? -1)|\(manifest.standaloneProvisioningAck?.contentDigest ?? "nil")"
        return sha256Hex(of: Data(fallback.utf8))
    }

    private static func sha256Hex(of data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

enum WatchConnectivityTransferPolicy {
    private static let staleAutomationTransferInterval: TimeInterval = 10
    private static let staleStandardTransferInterval: TimeInterval = 60

    static func shouldRetainOutstandingTransfer(
        metadata: WatchTransferPackageManifest?,
        transferFileURL: URL,
        manifest: WatchSyncManifest?,
        automationActive: Bool,
        transferStagingRootURL: URL,
        fileExists: Bool,
        now: Date = Date()
    ) -> Bool {
        guard let metadata else { return false }
        guard fileExists else { return false }
        let expectedPackageID = expectedPackageID(for: metadata.kind, manifest: manifest)
        guard metadata.packageID == expectedPackageID else { return false }
        let staleInterval = automationActive
            ? staleAutomationTransferInterval
            : staleStandardTransferInterval
        if now.timeIntervalSince(metadata.createdAt) > staleInterval {
            return false
        }
        guard automationActive else { return true }
        if isURL(transferFileURL, within: transferStagingRootURL) {
            return true
        }
        // Simulator/WCSession may rewrite transfer file paths outside staging root.
        // Keep metadata-matching transfers to avoid false cancellation and dropped sync.
        return true
    }

    private static func expectedPackageID(for kind: WatchPackageKind, manifest: WatchSyncManifest?) -> String? {
        switch kind {
        case .mirrorSnapshot:
            return manifest?.mirrorPackage?.packageID
        case .standaloneProvisioning:
            return manifest?.standalonePackage?.packageID
        }
    }

    private static func isURL(_ fileURL: URL, within rootURL: URL) -> Bool {
        let standardizedFilePath = fileURL.standardizedFileURL.path
        let standardizedRootPath = rootURL.standardizedFileURL.path
        if standardizedFilePath == standardizedRootPath {
            return true
        }
        return standardizedFilePath.hasPrefix(standardizedRootPath + "/")
    }
}

#if os(iOS) || os(watchOS)
enum WatchConnectivityRole: String, Codable, Sendable {
    case phone
    case watch
}

private struct WatchConnectivityRuntimeState: Codable, Sendable {
    var schemaVersion: Int
    var lastManifest: WatchSyncManifest?
    var lastReceivedManifest: WatchSyncManifest?
    var currentMirrorPackageRef: MirrorPackageRef?
    var currentStandalonePackageRef: StandalonePackageRef?
    var pendingEvents: [WatchEventEnvelope]
    var processedIncomingEventIDs: [String]
    var pendingForcedReconfigure: Bool

    static let empty = WatchConnectivityRuntimeState(
        schemaVersion: WatchConnectivitySchema.currentVersion,
        lastManifest: nil,
        lastReceivedManifest: nil,
        currentMirrorPackageRef: nil,
        currentStandalonePackageRef: nil,
        pendingEvents: [],
        processedIncomingEventIDs: [],
        pendingForcedReconfigure: false
    )
}

private struct WatchConnectivityTransportObservation: Codable, Hashable, Sendable {
    let kind: String
    let details: String?
    let timestamp: Date
}

private struct WatchConnectivityOutstandingFileTransferState: Codable, Hashable, Sendable {
    let packageID: String?
    let kind: String?
    let generation: Int64?
    let fileName: String
    let fileExists: Bool
}

private struct WatchConnectivityOutstandingUserInfoTransferState: Codable, Hashable, Sendable {
    let eventID: String?
    let kind: String?
    let createdAt: Date?
}

private struct WatchConnectivityDiagnostics: Codable, Sendable {
    let schemaVersion: Int
    let role: WatchConnectivityRole
    let recordedAt: Date
    let reason: String
    let linkState: WatchLinkState
    let activationState: String
    let activationRequested: Bool
    let companionAvailable: Bool
    let reachable: Bool
    let fileTransferFlushInProgress: Bool
    let fileTransferFlushQueued: Bool
    let lastPublishedManifestSignature: String?
    let sessionReceivedApplicationContextKeys: [String]
    let runtimePendingEvents: [String]
    let runtimePendingEventKinds: [String]
    let processedIncomingEventIDs: [String]
    let outstandingFileTransfers: [WatchConnectivityOutstandingFileTransferState]
    let outstandingUserInfoTransfers: [WatchConnectivityOutstandingUserInfoTransferState]
    let lastObservation: WatchConnectivityTransportObservation?
    let currentManifest: WatchSyncManifest?
    let lastReceivedManifest: WatchSyncManifest?
}

actor WatchConnectivityRuntime {
    private enum Path {
        static let rootDirectoryName = "watch-connectivity-v3"
        static let stateFilename = "runtime-state.json"
        static let diagnosticsFilename = "diagnostics.json"
        static let outboxDirectoryName = "outbox"
        static let inboxDirectoryName = "inbox"
    }

    private let role: WatchConnectivityRole
    private let fileManager: FileManager
    private let rootURL: URL
    private let stateURL: URL
    private let diagnosticsURL: URL
    private let outboxURL: URL
    private let inboxURL: URL
    private var state: WatchConnectivityRuntimeState

    init(role: WatchConnectivityRole, fileManager: FileManager = .default) {
        self.role = role
        self.fileManager = fileManager
        let appSupportBase = Self.resolveBaseDirectory(fileManager: fileManager)
        let roleRootURL = appSupportBase
            .appendingPathComponent(Path.rootDirectoryName, isDirectory: true)
            .appendingPathComponent(role.rawValue, isDirectory: true)
        self.rootURL = roleRootURL
        self.stateURL = roleRootURL.appendingPathComponent(Path.stateFilename, isDirectory: false)
        self.diagnosticsURL = roleRootURL.appendingPathComponent(Path.diagnosticsFilename, isDirectory: false)
        self.outboxURL = roleRootURL.appendingPathComponent(Path.outboxDirectoryName, isDirectory: true)
        self.inboxURL = roleRootURL.appendingPathComponent(Path.inboxDirectoryName, isDirectory: true)

        Self.ensureDirectory(roleRootURL, fileManager: fileManager)
        Self.ensureDirectory(outboxURL, fileManager: fileManager)
        Self.ensureDirectory(inboxURL, fileManager: fileManager)

        if let decoded = Self.loadState(from: stateURL, fileManager: fileManager),
           decoded.schemaVersion == WatchConnectivitySchema.currentVersion
        {
            self.state = decoded
        } else {
            try? fileManager.removeItem(at: roleRootURL)
            Self.ensureDirectory(roleRootURL, fileManager: fileManager)
            Self.ensureDirectory(outboxURL, fileManager: fileManager)
            Self.ensureDirectory(inboxURL, fileManager: fileManager)
            self.state = WatchConnectivityRuntimeState.empty
            self.state.pendingForcedReconfigure = true
            Self.persistState(self.state, to: stateURL, fileManager: fileManager)
        }
    }

    func consumeForcedReconfigureFlag() -> Bool {
        let flag = state.pendingForcedReconfigure
        guard flag else { return false }
        state.pendingForcedReconfigure = false
        persist()
        return true
    }

    func currentManifest() -> WatchSyncManifest? {
        state.lastManifest
    }

    fileprivate func debugState() -> WatchConnectivityRuntimeState {
        state
    }

    func updateManifest(
        mode: WatchMode,
        controlGeneration: Int64,
        effectiveModeStatus: WatchEffectiveModeStatus? = nil,
        standaloneReadinessStatus: WatchStandaloneReadinessStatus? = nil,
        ackCursor: AckCursorRef?,
        mirrorSnapshotAck: AppliedPackageAckRef? = nil,
        standaloneProvisioningAck: AppliedPackageAckRef? = nil
    ) -> WatchSyncManifest {
        let manifest = WatchSyncManifest(
            schemaVersion: WatchConnectivitySchema.currentVersion,
            mode: mode,
            controlGeneration: controlGeneration,
            mirrorPackage: state.currentMirrorPackageRef,
            standalonePackage: state.currentStandalonePackageRef,
            effectiveModeStatus: effectiveModeStatus ?? state.lastManifest?.effectiveModeStatus,
            standaloneReadinessStatus: standaloneReadinessStatus ?? state.lastManifest?.standaloneReadinessStatus,
            ackCursor: ackCursor,
            mirrorSnapshotAck: mirrorSnapshotAck ?? state.lastManifest?.mirrorSnapshotAck,
            standaloneProvisioningAck: standaloneProvisioningAck ?? state.lastManifest?.standaloneProvisioningAck,
            inlineMirrorSnapshot: nil,
            inlineStandaloneProvisioning: nil
        )
        state.lastManifest = manifest
        persist()
        return manifest
    }

    func storeReceivedManifest(_ manifest: WatchSyncManifest) {
        state.lastReceivedManifest = manifest
        persist()
    }

    func prepareMirrorSnapshotPackage(_ snapshot: WatchMirrorSnapshot) throws -> MirrorPackageRef {
        let manifest = WatchTransferPackageManifest(
            schemaVersion: WatchConnectivitySchema.currentVersion,
            packageID: UUID().uuidString,
            kind: .mirrorSnapshot,
            generation: snapshot.generation,
            createdAt: Date()
        )
        let package = MirrorSnapshotPackage(manifest: manifest, snapshot: snapshot)
        let url = outboxFileURL(kind: manifest.kind, packageID: manifest.packageID)
        try Self.writeJSON(package, to: url, fileManager: fileManager)
        let ref = MirrorPackageRef(
            packageID: manifest.packageID,
            generation: manifest.generation,
            createdAt: manifest.createdAt
        )
        state.currentMirrorPackageRef = ref
        state.lastManifest = state.lastManifest.map {
            WatchSyncManifest(
                schemaVersion: $0.schemaVersion,
                mode: $0.mode,
                controlGeneration: $0.controlGeneration,
                mirrorPackage: ref,
                standalonePackage: $0.standalonePackage,
                effectiveModeStatus: $0.effectiveModeStatus,
                standaloneReadinessStatus: $0.standaloneReadinessStatus,
                ackCursor: $0.ackCursor,
                mirrorSnapshotAck: nil,
                standaloneProvisioningAck: $0.standaloneProvisioningAck,
                inlineMirrorSnapshot: nil,
                inlineStandaloneProvisioning: nil
            )
        }
        persist()
        return ref
    }

    func prepareStandaloneProvisioningPackage(
        _ snapshot: WatchStandaloneProvisioningSnapshot
    ) throws -> StandalonePackageRef {
        let manifest = WatchTransferPackageManifest(
            schemaVersion: WatchConnectivitySchema.currentVersion,
            packageID: UUID().uuidString,
            kind: .standaloneProvisioning,
            generation: snapshot.generation,
            createdAt: Date()
        )
        let package = StandaloneProvisioningPackage(manifest: manifest, snapshot: snapshot)
        let url = outboxFileURL(kind: manifest.kind, packageID: manifest.packageID)
        try Self.writeJSON(package, to: url, fileManager: fileManager)
        let ref = StandalonePackageRef(
            packageID: manifest.packageID,
            generation: manifest.generation,
            createdAt: manifest.createdAt
        )
        state.currentStandalonePackageRef = ref
        state.lastManifest = state.lastManifest.map {
            WatchSyncManifest(
                schemaVersion: $0.schemaVersion,
                mode: $0.mode,
                controlGeneration: $0.controlGeneration,
                mirrorPackage: $0.mirrorPackage,
                standalonePackage: ref,
                effectiveModeStatus: $0.effectiveModeStatus,
                standaloneReadinessStatus: $0.standaloneReadinessStatus,
                ackCursor: $0.ackCursor,
                mirrorSnapshotAck: $0.mirrorSnapshotAck,
                standaloneProvisioningAck: nil,
                inlineMirrorSnapshot: nil,
                inlineStandaloneProvisioning: nil
            )
        }
        persist()
        return ref
    }

    func outboxFileURL(for mirrorPackage: MirrorPackageRef) -> URL {
        outboxFileURL(kind: .mirrorSnapshot, packageID: mirrorPackage.packageID)
    }

    func outboxFileURL(for standalonePackage: StandalonePackageRef) -> URL {
        outboxFileURL(kind: .standaloneProvisioning, packageID: standalonePackage.packageID)
    }

    func inlinePackageData(for kind: WatchPackageKind, maximumBytes: Int) -> Data? {
        let fileURL: URL
        switch kind {
        case .mirrorSnapshot:
            guard let ref = state.currentMirrorPackageRef else { return nil }
            fileURL = outboxFileURL(for: ref)
        case .standaloneProvisioning:
            guard let ref = state.currentStandalonePackageRef else { return nil }
            fileURL = outboxFileURL(for: ref)
        }
        guard let data = try? Data(contentsOf: fileURL),
              data.count <= maximumBytes
        else {
            return nil
        }
        return data
    }

    func removeOutboxFile(kind: WatchPackageKind, packageID: String) {
        let url = outboxFileURL(kind: kind, packageID: packageID)
        try? fileManager.removeItem(at: url)
    }

    func pruneOutbox(activePackageIDs: Set<String>) {
        let urls = (try? fileManager.contentsOfDirectory(
            at: outboxURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        for url in urls {
            let packageID = url.deletingPathExtension().lastPathComponent
            if !activePackageIDs.contains(packageID) {
                try? fileManager.removeItem(at: url)
            }
        }
    }

    func stageIncomingFile(from sourceURL: URL, metadata: WatchTransferPackageManifest) -> URL? {
        let destinationURL = inboxURL.appendingPathComponent(
            "\(metadata.kind.rawValue)-\(metadata.packageID).json",
            isDirectory: false
        )
        try? fileManager.removeItem(at: destinationURL)
        do {
            try fileManager.copyItem(at: sourceURL, to: destinationURL)
            return destinationURL
        } catch {
            return nil
        }
    }

    func decodeMirrorSnapshotPackage(at url: URL) throws -> MirrorSnapshotPackage {
        try Self.decodeJSON(MirrorSnapshotPackage.self, from: url)
    }

    func decodeStandaloneProvisioningPackage(at url: URL) throws -> StandaloneProvisioningPackage {
        try Self.decodeJSON(StandaloneProvisioningPackage.self, from: url)
    }

    func removeIncomingFile(at url: URL) {
        try? fileManager.removeItem(at: url)
    }

    func enqueueReliableEvent(_ event: WatchEventEnvelope) {
        state.pendingEvents.removeAll { $0.eventID == event.eventID }
        state.pendingEvents.append(event)
        state.pendingEvents.sort { $0.createdAt < $1.createdAt }
        persist()
    }

    func pendingReliableEvents() -> [WatchEventEnvelope] {
        state.pendingEvents
    }

    func markReliableEventDispatched(_ eventID: String) {
        state.pendingEvents.removeAll { $0.eventID == eventID }
        persist()
    }

    func acceptIncomingEvent(_ event: WatchEventEnvelope) -> Bool {
        guard event.schemaVersion == WatchConnectivitySchema.currentVersion else {
            return false
        }
        guard !state.processedIncomingEventIDs.contains(event.eventID) else {
            return false
        }
        state.processedIncomingEventIDs.append(event.eventID)
        if state.processedIncomingEventIDs.count > 256 {
            state.processedIncomingEventIDs.removeFirst(state.processedIncomingEventIDs.count - 256)
        }
        persist()
        return true
    }

    func clearAllState() {
        try? fileManager.removeItem(at: rootURL)
        Self.ensureDirectory(rootURL, fileManager: fileManager)
        Self.ensureDirectory(outboxURL, fileManager: fileManager)
        Self.ensureDirectory(inboxURL, fileManager: fileManager)
        state = .empty
        persist()
    }

    fileprivate func persistDiagnostics(_ diagnostics: WatchConnectivityDiagnostics) {
        guard let data = try? WatchConnectivityWire.makeEncoder().encode(diagnostics) else { return }
        try? data.write(to: diagnosticsURL, options: .atomic)
    }

    private func outboxFileURL(kind: WatchPackageKind, packageID: String) -> URL {
        outboxURL.appendingPathComponent("\(packageID).json", isDirectory: false)
    }

    private func persist() {
        Self.persistState(state, to: stateURL, fileManager: fileManager)
    }

    private static func resolveBaseDirectory(fileManager: FileManager) -> URL {
        if let containerURL = AppConstants.appGroupContainerURL(fileManager: fileManager) {
            let baseURL = containerURL.appendingPathComponent("Library/Application Support", isDirectory: true)
            ensureDirectory(baseURL, fileManager: fileManager)
            return baseURL
        }
        let baseURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        ensureDirectory(baseURL, fileManager: fileManager)
        return baseURL
    }

    private static func ensureDirectory(_ url: URL, fileManager: FileManager) {
        try? fileManager.createDirectory(at: url, withIntermediateDirectories: true)
    }

    private static func loadState(from url: URL, fileManager: FileManager) -> WatchConnectivityRuntimeState? {
        guard fileManager.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url)
        else {
            return nil
        }
        return try? WatchConnectivityWire.makeDecoder().decode(WatchConnectivityRuntimeState.self, from: data)
    }

    private static func persistState(_ state: WatchConnectivityRuntimeState, to url: URL, fileManager: FileManager) {
        guard let data = try? WatchConnectivityWire.makeEncoder().encode(state) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private static func writeJSON<T: Encodable>(_ value: T, to url: URL, fileManager: FileManager) throws {
        let data = try WatchConnectivityWire.makeEncoder().encode(value)
        ensureDirectory(url.deletingLastPathComponent(), fileManager: fileManager)
        try data.write(to: url, options: .atomic)
    }

    private static func decodeJSON<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        let data = try Data(contentsOf: url)
        return try WatchConnectivityWire.makeDecoder().decode(type, from: data)
    }
}

@MainActor
final class WatchConnectivityCoordinator: NSObject, WCSessionDelegate {
    private enum ActivationSnapshot: Sendable {
        case notActivated
        case inactive
        case activated
        case unknown
    }

    private struct LinkStateSnapshot: Sendable {
        let activation: ActivationSnapshot
        let companionAvailable: Bool
        let reachable: Bool
        let errorDescription: String?
    }

    struct Handlers {
        var linkStateDidChange: (@MainActor (WatchLinkState) async -> Void)?
        var manifestDidReceive: (@MainActor (WatchSyncManifest) async -> Void)?
        var eventDidReceive: (@MainActor (WatchEventEnvelope) async -> Void)?
        var mirrorPackageDidReceive: (@MainActor (MirrorSnapshotPackage) async -> Void)?
        var standalonePackageDidReceive: (@MainActor (StandaloneProvisioningPackage) async -> Void)?
        var latestManifestRequested: (@MainActor () async -> Void)?

        static let empty = Handlers()
    }

#if os(iOS)
    static let shared = WatchConnectivityCoordinator(role: .phone)
#elseif os(watchOS)
    static let shared = WatchConnectivityCoordinator(role: .watch)
#endif

    let role: WatchConnectivityRole
    private let runtime: WatchConnectivityRuntime
    private let session: WCSession? = WCSession.isSupported() ? WCSession.default : nil
    private let fileManager: FileManager = .default
    private let transferStagingDirectoryName = "pushgo-watch-connectivity-transfer"
    private var handlers: Handlers = .empty
    private var activationRequested = false
    private var lastActivationRequestAt = Date.distantPast
    private let activationRetryInterval: TimeInterval = 2
    private let reliableInlinePackageMaximumPayloadBytes = 48_000
    private var lastPublishedManifestSignature: String?
    private var lastManifestRequestAt = Date.distantPast
    private let manifestRequestMinimumInterval: TimeInterval = 0.8
    private var fileTransferFlushInProgress = false
    private var fileTransferFlushQueued = false
    private(set) var linkState: WatchLinkState = .unsupported
    private var lastObservation: WatchConnectivityTransportObservation?

    private init(role: WatchConnectivityRole) {
        self.role = role
        self.runtime = WatchConnectivityRuntime(role: role)
        super.init()
        if session == nil {
            linkState = .unsupported
        }
    }

    func installHandlers(_ handlers: Handlers) {
        self.handlers = handlers
    }

    func activateIfNeeded() {
        guard let session else {
            updateLinkState(.unsupported)
            Task {
                await persistDiagnostics(reason: "activate.unsupported")
            }
            return
        }
        if session.delegate == nil {
            session.delegate = self
        }
        guard shouldActivate(session) else {
            if session.activationState == .activated {
                let receivedContext = session.receivedApplicationContext
                let replayManifest = WatchSyncManifest.fromApplicationContext(receivedContext)
                let keySummary = watchConnectivitySortedKeyList(receivedContext)
                Task {
                    await self.replayReceivedApplicationContextIfAvailable(
                        manifest: replayManifest,
                        keySummary: keySummary,
                        source: "activateIfNeeded",
                        contextEmpty: receivedContext.isEmpty
                    )
                    await self.flushPendingState()
                    await self.persistDiagnostics(reason: "activate.replay")
                }
            }
            return
        }
        activationRequested = true
        lastActivationRequestAt = Date()
        noteObservation("activate.requested", details: "state=\(Self.activationStateDescription(session.activationState))")
        updateLinkState(WatchLinkState(phase: .activating, lastErrorDescription: linkState.lastErrorDescription))
        session.activate()
        Task {
            await persistDiagnostics(reason: "activate.requested")
        }
    }

    func refreshCachedLinkState() -> WatchLinkState {
        linkState
    }

    func consumeForcedReconfigureFlag() async -> Bool {
        await runtime.consumeForcedReconfigureFlag()
    }

    func clearPersistentState() async {
        await runtime.clearAllState()
        lastPublishedManifestSignature = nil
        lastManifestRequestAt = .distantPast
    }

    func publishControlManifest(_ context: WatchControlContext) {
        Task {
            let manifest = await runtime.updateManifest(
                mode: context.mode,
                controlGeneration: context.controlGeneration,
                ackCursor: nil
            )
            await self.publishManifestIfPossible(manifest)
        }
    }

    func publishEffectiveModeStatusManifest(
        mode: WatchMode,
        controlGeneration: Int64,
        effectiveModeStatus: WatchEffectiveModeStatus,
        standaloneReadinessStatus: WatchStandaloneReadinessStatus? = nil
    ) {
        Task {
            let manifest = await runtime.updateManifest(
                mode: mode,
                controlGeneration: controlGeneration,
                effectiveModeStatus: effectiveModeStatus,
                standaloneReadinessStatus: standaloneReadinessStatus,
                ackCursor: nil
            )
            await self.publishManifestIfPossible(manifest, force: true)
        }
    }

    func publishStandaloneReadinessStatusManifest(
        mode: WatchMode,
        controlGeneration: Int64,
        standaloneReadinessStatus: WatchStandaloneReadinessStatus
    ) {
        Task {
            let manifest = await runtime.updateManifest(
                mode: mode,
                controlGeneration: controlGeneration,
                standaloneReadinessStatus: standaloneReadinessStatus,
                ackCursor: nil
            )
            await self.publishManifestIfPossible(manifest, force: true)
        }
    }

    func publishMirrorSnapshotAckManifest(
        mode: WatchMode,
        controlGeneration: Int64,
        ack: WatchMirrorSnapshotAck
    ) {
        Task {
            let manifest = await runtime.updateManifest(
                mode: mode,
                controlGeneration: controlGeneration,
                effectiveModeStatus: nil,
                ackCursor: nil,
                mirrorSnapshotAck: AppliedPackageAckRef(
                    generation: ack.generation,
                    contentDigest: ack.contentDigest,
                    appliedAt: ack.appliedAt
                )
            )
            await self.publishManifestIfPossible(manifest)
        }
    }

    func publishStandaloneProvisioningAckManifest(
        mode: WatchMode,
        controlGeneration: Int64,
        ack: WatchStandaloneProvisioningAck
    ) {
        Task {
            let manifest = await runtime.updateManifest(
                mode: mode,
                controlGeneration: controlGeneration,
                effectiveModeStatus: nil,
                ackCursor: nil,
                standaloneProvisioningAck: AppliedPackageAckRef(
                    generation: ack.generation,
                    contentDigest: ack.contentDigest,
                    appliedAt: ack.appliedAt
                )
            )
            await self.publishManifestIfPossible(manifest)
        }
    }

    func prepareMirrorSnapshot(_ snapshot: WatchMirrorSnapshot) {
        Task {
            let ref = try? await runtime.prepareMirrorSnapshotPackage(snapshot)
            if let manifest = await runtime.currentManifest() {
                await self.publishManifestIfPossible(manifest)
            }
            if let ref {
                let package = MirrorSnapshotPackage(
                    manifest: WatchTransferPackageManifest(
                        schemaVersion: WatchConnectivitySchema.currentVersion,
                        packageID: ref.packageID,
                        kind: .mirrorSnapshot,
                        generation: ref.generation,
                        createdAt: ref.createdAt
                    ),
                    snapshot: snapshot
                )
                enqueueReliableMirrorSnapshotInlineIfNeeded(package)
            }
            await self.sendRefreshHintIfReachable()
        }
    }

    func prepareStandaloneProvisioning(_ snapshot: WatchStandaloneProvisioningSnapshot) {
        Task {
            let ref = try? await runtime.prepareStandaloneProvisioningPackage(snapshot)
            if let manifest = await runtime.currentManifest() {
                await self.publishManifestIfPossible(manifest)
            }
            if let ref {
                let package = StandaloneProvisioningPackage(
                    manifest: WatchTransferPackageManifest(
                        schemaVersion: WatchConnectivitySchema.currentVersion,
                        packageID: ref.packageID,
                        kind: .standaloneProvisioning,
                        generation: ref.generation,
                        createdAt: ref.createdAt
                    ),
                    snapshot: snapshot
                )
                enqueueReliableStandaloneProvisioningInlineIfNeeded(package)
            }
            await self.sendRefreshHintIfReachable()
        }
    }

    func enqueueReliableMirrorActionBatch(_ batch: WatchMirrorActionBatch) {
        guard let payload = WatchConnectivityWire.encode(batch) else { return }
        enqueueReliableEvent(kind: .mirrorActionBatch, payload: payload)
    }

    func enqueueReliableMirrorActionAck(_ ack: WatchMirrorActionAck) {
        guard let payload = WatchConnectivityWire.encode(ack) else { return }
        enqueueReliableEvent(kind: .mirrorActionAck, payload: payload)
    }

    func enqueueReliableMirrorSnapshotAck(_ ack: WatchMirrorSnapshotAck) {
        guard let payload = WatchConnectivityWire.encode(ack) else { return }
        enqueueReliableEvent(kind: .mirrorSnapshotAck, payload: payload)
    }

    func enqueueReliableMirrorSnapshotInlineIfNeeded(_ package: MirrorSnapshotPackage) {
        guard let payload = WatchConnectivityWire.encode(package) else { return }
        guard payload.count <= reliableInlinePackageMaximumPayloadBytes else {
            return
        }
        enqueueReliableEvent(kind: .mirrorSnapshotInline, payload: payload)
    }

    func enqueueReliableMirrorSnapshotNack(_ nack: WatchMirrorSnapshotNack) {
        guard let payload = WatchConnectivityWire.encode(nack) else { return }
        enqueueReliableEvent(kind: .mirrorSnapshotNack, payload: payload)
    }

    func enqueueReliableStandaloneProvisioningAck(_ ack: WatchStandaloneProvisioningAck) {
        guard let payload = WatchConnectivityWire.encode(ack) else { return }
        enqueueReliableEvent(kind: .standaloneProvisioningAck, payload: payload)
    }

    func enqueueReliableStandaloneProvisioningInlineIfNeeded(
        _ package: StandaloneProvisioningPackage
    ) {
        guard let payload = WatchConnectivityWire.encode(package) else { return }
        guard payload.count <= reliableInlinePackageMaximumPayloadBytes else {
            return
        }
        enqueueReliableEvent(kind: .standaloneProvisioningInline, payload: payload)
    }

    func enqueueReliableStandaloneProvisioningNack(_ nack: WatchStandaloneProvisioningNack) {
        guard let payload = WatchConnectivityWire.encode(nack) else { return }
        enqueueReliableEvent(kind: .standaloneProvisioningNack, payload: payload)
    }

    func enqueueReliablePushToken(_ token: String) {
        guard let payload = WatchConnectivityWire.encode(token) else { return }
        enqueueReliableEvent(kind: .pushTokenUpdate, payload: payload)
    }

    func requestLatestManifestIfReachable() {
        guard let session, session.activationState == .activated, session.isReachable else { return }
        let now = Date()
        if now.timeIntervalSince(lastManifestRequestAt) < manifestRequestMinimumInterval {
            return
        }
        lastManifestRequestAt = now
        let message = WatchLiveMessage(
            schemaVersion: WatchConnectivitySchema.currentVersion,
            kind: .requestLatestManifest
        )
        session.sendMessage(message.payload(), replyHandler: nil, errorHandler: nil)
    }

    func replayLatestManifestIfPossible() {
        Task {
            guard let manifest = await runtime.currentManifest() else { return }
            await self.publishManifestIfPossible(manifest, force: true)
        }
    }

    private func enqueueReliableEvent(kind: WatchReliableEventKind, payload: Data) {
        let event = WatchEventEnvelope(
            eventID: UUID().uuidString,
            schemaVersion: WatchConnectivitySchema.currentVersion,
            createdAt: Date(),
            kind: kind,
            payload: payload
        )
        Task {
            await runtime.enqueueReliableEvent(event)
            self.noteObservation(
                "reliable_event.queued",
                details: "kind=\(kind.rawValue) eventID=\(event.eventID) bytes=\(payload.count)"
            )
            await self.flushPendingReliableEvents()
            await self.persistDiagnostics(reason: "reliable_event.queued")
        }
    }

    private func publishManifestIfPossible(_ manifest: WatchSyncManifest, force: Bool = false) async {
        guard let session, session.activationState == .activated else { return }
        let transportManifest = await transportManifest(for: manifest)
        let signature = WatchConnectivityManifestPublishPolicy.signature(for: transportManifest)
        if force || signature != lastPublishedManifestSignature {
            do {
                try session.updateApplicationContext(transportManifest.applicationContext())
                lastPublishedManifestSignature = signature
                noteObservation(
                    "manifest.published",
                    details: "control=\(transportManifest.controlGeneration) mode=\(transportManifest.mode.rawValue) inlineMirror=\(transportManifest.inlineMirrorSnapshot != nil) inlineStandalone=\(transportManifest.inlineStandaloneProvisioning != nil)"
                )
            } catch {
                noteObservation("manifest.publish_failed", details: error.localizedDescription)
                updateLinkState(
                    WatchLinkState(
                        phase: linkState.phase,
                        lastErrorDescription: error.localizedDescription
                    )
                )
            }
        }
        await flushPendingFileTransfers()
        await flushPendingReliableEvents()
        await persistDiagnostics(reason: "manifest.publish")
    }

    private func transportManifest(for manifest: WatchSyncManifest) async -> WatchSyncManifest {
        let inlineMirrorSnapshot = await runtime.inlinePackageData(
            for: .mirrorSnapshot,
            maximumBytes: WatchConnectivityWire.contextSoftLimitBytes / 2
        )
        let inlineStandaloneProvisioning = await runtime.inlinePackageData(
            for: .standaloneProvisioning,
            maximumBytes: WatchConnectivityWire.contextSoftLimitBytes / 2
        )
        let inlineManifest = manifest.withInlinePackages(
            mirrorSnapshot: inlineMirrorSnapshot,
            standaloneProvisioning: inlineStandaloneProvisioning
        )
        guard applicationContextSizeBytes(for: inlineManifest.applicationContext()) <= WatchConnectivityWire.contextSoftLimitBytes else {
            return manifest.withoutInlinePackages()
        }
        return inlineManifest
    }

    private func replayReceivedApplicationContextIfAvailable(
        manifest: WatchSyncManifest?,
        keySummary: String,
        source: String,
        contextEmpty: Bool
    ) async {
        guard !contextEmpty else { return }
        guard let manifest else {
            recordLinkStateError(
                "watch connectivity manifest decode failed from \(source) (keys: \(keySummary))"
            )
            return
        }
        await handleIncomingManifest(manifest)
    }

    private func flushPendingState() async {
        if let manifest = await runtime.currentManifest() {
            await publishManifestIfPossible(manifest)
        }
        await flushPendingReliableEvents()
        if role == .watch {
            requestLatestManifestIfReachable()
        }
    }

    private func flushPendingReliableEvents() async {
        guard let session else { return }
        guard canTransmitToCompanion(using: session) else {
            let cancelled = Self.cancelOutstandingOutboundTransfersIfNeeded(
                session: session,
                transferStagingDirectoryName: transferStagingDirectoryName
            )
            logCancelledOutstandingOutboundTransfers(
                fileTransferCount: cancelled.fileTransferCount,
                userInfoTransferCount: cancelled.userInfoTransferCount,
                reason: "reliable_event.no_companion"
            )
            await persistDiagnostics(reason: "reliable_event.skipped_no_companion")
            return
        }
        let pending = await runtime.pendingReliableEvents()
        let outstandingIDs = Set(
            session.outstandingUserInfoTransfers.compactMap { transfer in
                transfer.userInfo["watch_event_id"] as? String
            }
        )
        for event in pending {
            if outstandingIDs.contains(event.eventID) {
                await runtime.markReliableEventDispatched(event.eventID)
                noteObservation(
                    "reliable_event.already_outstanding",
                    details: "kind=\(event.kind.rawValue) eventID=\(event.eventID)"
                )
                continue
            }
            session.transferUserInfo(event.userInfo())
            noteObservation(
                "reliable_event.dispatched",
                details: "kind=\(event.kind.rawValue) eventID=\(event.eventID)"
            )
            await runtime.markReliableEventDispatched(event.eventID)
        }
        await persistDiagnostics(reason: "reliable_event.flush")
    }

    private func flushPendingFileTransfers() async {
        if fileTransferFlushInProgress {
            fileTransferFlushQueued = true
            return
        }
        fileTransferFlushInProgress = true
        defer {
            fileTransferFlushInProgress = false
            if fileTransferFlushQueued {
                fileTransferFlushQueued = false
                Task { @MainActor in
                    await self.flushPendingFileTransfers()
                }
            }
        }
        guard let session else { return }
        guard canTransmitToCompanion(using: session) else {
            let cancelled = Self.cancelOutstandingOutboundTransfersIfNeeded(
                session: session,
                transferStagingDirectoryName: transferStagingDirectoryName
            )
            logCancelledOutstandingOutboundTransfers(
                fileTransferCount: cancelled.fileTransferCount,
                userInfoTransferCount: cancelled.userInfoTransferCount,
                reason: "file_transfer.no_companion"
            )
            await persistDiagnostics(reason: "file_transfer.skipped_no_companion")
            return
        }
        let manifest = await runtime.currentManifest()
        let activePackageIDs = retainCurrentOutstandingTransfers(session: session, manifest: manifest)

        if let mirrorPackage = manifest?.mirrorPackage {
            await enqueueFileTransferIfNeeded(
                kind: .mirrorSnapshot,
                packageID: mirrorPackage.packageID,
                activePackageIDs: activePackageIDs
            )
        }

        if let standalonePackage = manifest?.standalonePackage {
            await enqueueFileTransferIfNeeded(
                kind: .standaloneProvisioning,
                packageID: standalonePackage.packageID,
                activePackageIDs: activePackageIDs
            )
        }

        await runtime.pruneOutbox(
            activePackageIDs: activePackageIDs.union(
                [
                    manifest?.mirrorPackage?.packageID,
                    manifest?.standalonePackage?.packageID,
                ].compactMap { $0 }
            )
        )
        await persistDiagnostics(reason: "file_transfer.flush")
    }

    private func enqueueFileTransferIfNeeded(
        kind: WatchPackageKind,
        packageID: String,
        activePackageIDs: Set<String>
    ) async {
        guard let session else { return }
        guard canTransmitToCompanion(using: session) else { return }
        guard !activePackageIDs.contains(packageID) else { return }

        for transfer in session.outstandingFileTransfers {
            guard let metadata = WatchTransferPackageManifest.fromMetadata(transfer.file.metadata) else {
                continue
            }
            if metadata.kind == kind, metadata.packageID == packageID {
                return
            }
        }

        for transfer in session.outstandingFileTransfers {
            guard let metadata = WatchTransferPackageManifest.fromMetadata(transfer.file.metadata),
                  metadata.kind == kind,
                  metadata.packageID != packageID
            else {
                continue
            }
            transfer.cancel()
        }

        switch kind {
        case .mirrorSnapshot:
            guard let currentRef = await runtime.currentManifest()?.mirrorPackage else { return }
            let metadata = WatchTransferPackageManifest(
                schemaVersion: WatchConnectivitySchema.currentVersion,
                packageID: currentRef.packageID,
                kind: kind,
                generation: currentRef.generation,
                createdAt: currentRef.createdAt
            )
            let sourceURL = await runtime.outboxFileURL(for: currentRef)
            guard let transferURL = makeTransferFileURLIfNeeded(sourceURL, packageID: currentRef.packageID) else {
                return
            }
            noteObservation(
                "file_transfer.enqueued",
                details: "kind=\(kind.rawValue) packageID=\(currentRef.packageID)"
            )
            session.transferFile(
                transferURL,
                metadata: metadata.metadataDictionary()
            )
        case .standaloneProvisioning:
            guard let currentRef = await runtime.currentManifest()?.standalonePackage else { return }
            let metadata = WatchTransferPackageManifest(
                schemaVersion: WatchConnectivitySchema.currentVersion,
                packageID: currentRef.packageID,
                kind: kind,
                generation: currentRef.generation,
                createdAt: currentRef.createdAt
            )
            let sourceURL = await runtime.outboxFileURL(for: currentRef)
            guard let transferURL = makeTransferFileURLIfNeeded(sourceURL, packageID: currentRef.packageID) else {
                return
            }
            noteObservation(
                "file_transfer.enqueued",
                details: "kind=\(kind.rawValue) packageID=\(currentRef.packageID)"
            )
            session.transferFile(
                transferURL,
                metadata: metadata.metadataDictionary()
            )
        }
    }

    private func retainCurrentOutstandingTransfers(
        session: WCSession,
        manifest: WatchSyncManifest?
    ) -> Set<String> {
        let stagingRootURL = transferStagingRootURL()
        var activePackageIDs: Set<String> = []
        for transfer in session.outstandingFileTransfers {
            let metadata = WatchTransferPackageManifest.fromMetadata(transfer.file.metadata)
            let fileURL = transfer.file.fileURL
            let shouldRetain = WatchConnectivityTransferPolicy.shouldRetainOutstandingTransfer(
                metadata: metadata,
                transferFileURL: fileURL,
                manifest: manifest,
                automationActive: PushGoAutomationContext.isActive,
                transferStagingRootURL: stagingRootURL,
                fileExists: fileManager.fileExists(atPath: fileURL.path)
            )
            guard shouldRetain, let metadata else {
                transfer.cancel()
                removeStagedTransferFileIfNeeded(fileURL)
                continue
            }
            activePackageIDs.insert(metadata.packageID)
        }
        return activePackageIDs
    }

    private func makeTransferFileURLIfNeeded(_ sourceURL: URL, packageID: String) -> URL? {
        guard PushGoAutomationContext.isActive else { return sourceURL }
        let stagingRoot = transferStagingRootURL()
        do {
            try fileManager.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
            let stagedURL = stagingRoot.appendingPathComponent("\(packageID).json", isDirectory: false)
            if fileManager.fileExists(atPath: stagedURL.path) {
                return stagedURL
            }
            try fileManager.copyItem(at: sourceURL, to: stagedURL)
            return stagedURL
        } catch {
            return nil
        }
    }

    private func removeStagedTransferFileIfNeeded(_ fileURL: URL) {
        guard PushGoAutomationContext.isActive else { return }
        let stagingRoot = transferStagingRootURL()
        let standardizedFile = fileURL.standardizedFileURL.path
        let standardizedRoot = stagingRoot.standardizedFileURL.path
        let withinRoot = standardizedFile == standardizedRoot || standardizedFile.hasPrefix(standardizedRoot + "/")
        guard withinRoot else { return }
        try? fileManager.removeItem(at: fileURL)
    }

    nonisolated private static func removeStagedTransferFileIfNeeded(
        _ fileURL: URL,
        transferStagingDirectoryName: String
    ) {
        guard PushGoAutomationContext.isActive else { return }
        let stagingRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(transferStagingDirectoryName, isDirectory: true)
        let standardizedFile = fileURL.standardizedFileURL.path
        let standardizedRoot = stagingRoot.standardizedFileURL.path
        let withinRoot = standardizedFile == standardizedRoot || standardizedFile.hasPrefix(standardizedRoot + "/")
        guard withinRoot else { return }
        try? FileManager.default.removeItem(at: fileURL)
    }

    private func transferStagingRootURL() -> URL {
        fileManager.temporaryDirectory
            .appendingPathComponent(transferStagingDirectoryName, isDirectory: true)
    }

    private func recordLinkStateError(_ message: String) {
        noteObservation("link_state.error", details: message)
        updateLinkState(
            WatchLinkState(
                phase: linkState.phase,
                lastErrorDescription: message
            )
        )
    }

    private func noteObservation(_ kind: String, details: String? = nil) {
        lastObservation = WatchConnectivityTransportObservation(
            kind: kind,
            details: details,
            timestamp: Date()
        )
    }

    private nonisolated static func activationStateDescription(_ state: WCSessionActivationState) -> String {
        switch state {
        case .notActivated:
            return "not_activated"
        case .inactive:
            return "inactive"
        case .activated:
            return "activated"
        @unknown default:
            return "unknown"
        }
    }

    private func persistDiagnostics(reason: String) async {
        let runtimeState = await runtime.debugState()
        let outstandingFileTransfers: [WatchConnectivityOutstandingFileTransferState]
        let outstandingUserInfoTransfers: [WatchConnectivityOutstandingUserInfoTransferState]
        let activationState: String
        let companionAvailable: Bool
        let reachable: Bool
        let receivedApplicationContextKeys: [String]

        if let session {
            outstandingFileTransfers = session.outstandingFileTransfers.map { transfer in
                let metadata = WatchTransferPackageManifest.fromMetadata(transfer.file.metadata)
                return WatchConnectivityOutstandingFileTransferState(
                    packageID: metadata?.packageID,
                    kind: metadata?.kind.rawValue,
                    generation: metadata?.generation,
                    fileName: transfer.file.fileURL.lastPathComponent,
                    fileExists: fileManager.fileExists(atPath: transfer.file.fileURL.path)
                )
            }
            outstandingUserInfoTransfers = session.outstandingUserInfoTransfers.map { transfer in
                WatchConnectivityOutstandingUserInfoTransferState(
                    eventID: transfer.userInfo["watch_event_id"] as? String,
                    kind: transfer.userInfo["watch_event_kind"] as? String,
                    createdAt: (transfer.userInfo["watch_event_created_at"] as? Double)
                        .map { Date(timeIntervalSince1970: $0) }
                )
            }
            activationState = Self.activationStateDescription(session.activationState)
            companionAvailable = isCompanionAvailable(session)
            reachable = session.isReachable
            receivedApplicationContextKeys = session.receivedApplicationContext.keys.sorted()
        } else {
            outstandingFileTransfers = []
            outstandingUserInfoTransfers = []
            activationState = "unsupported"
            companionAvailable = false
            reachable = false
            receivedApplicationContextKeys = []
        }

        let diagnostics = WatchConnectivityDiagnostics(
            schemaVersion: WatchConnectivitySchema.currentVersion,
            role: role,
            recordedAt: Date(),
            reason: reason,
            linkState: linkState,
            activationState: activationState,
            activationRequested: activationRequested,
            companionAvailable: companionAvailable,
            reachable: reachable,
            fileTransferFlushInProgress: fileTransferFlushInProgress,
            fileTransferFlushQueued: fileTransferFlushQueued,
            lastPublishedManifestSignature: lastPublishedManifestSignature,
            sessionReceivedApplicationContextKeys: receivedApplicationContextKeys,
            runtimePendingEvents: runtimeState.pendingEvents.map(\.eventID),
            runtimePendingEventKinds: runtimeState.pendingEvents.map(\.kind.rawValue),
            processedIncomingEventIDs: runtimeState.processedIncomingEventIDs,
            outstandingFileTransfers: outstandingFileTransfers,
            outstandingUserInfoTransfers: outstandingUserInfoTransfers,
            lastObservation: lastObservation,
            currentManifest: runtimeState.lastManifest,
            lastReceivedManifest: runtimeState.lastReceivedManifest
        )
        await runtime.persistDiagnostics(diagnostics)
    }

    private func sendRefreshHintIfReachable() async {
        guard let session, session.activationState == .activated, session.isReachable else { return }
        let liveMessage = WatchLiveMessage(
            schemaVersion: WatchConnectivitySchema.currentVersion,
            kind: .refreshHint
        )
        session.sendMessage(liveMessage.payload(), replyHandler: nil, errorHandler: nil)
    }

    private func shouldActivate(_ session: WCSession) -> Bool {
        switch session.activationState {
        case .activated:
            activationRequested = false
            return false
        case .notActivated:
            return !activationRequested && Date().timeIntervalSince(lastActivationRequestAt) >= activationRetryInterval
        case .inactive:
            activationRequested = false
            return false
        @unknown default:
            return !activationRequested && Date().timeIntervalSince(lastActivationRequestAt) >= activationRetryInterval
        }
    }

    private func updateCachedLinkState(from snapshot: LinkStateSnapshot) {
        let nextState: WatchLinkState
        switch snapshot.activation {
        case .notActivated, .inactive:
            nextState = WatchLinkState(phase: .activating, lastErrorDescription: snapshot.errorDescription)
        case .activated:
            if snapshot.companionAvailable {
                nextState = WatchLinkState(
                    phase: snapshot.reachable ? .reachable : .activatedCompanionAvailable,
                    lastErrorDescription: snapshot.errorDescription
                )
            } else {
                nextState = WatchLinkState(
                    phase: .activatedNoCompanion,
                    lastErrorDescription: snapshot.errorDescription
                )
            }
        case .unknown:
            nextState = WatchLinkState(phase: .activating, lastErrorDescription: snapshot.errorDescription)
        }
        updateLinkState(nextState)
    }

    nonisolated private func canTransmitToCompanion(using session: WCSession) -> Bool {
        session.activationState == .activated && isCompanionAvailable(session)
    }

    private func logCancelledOutstandingOutboundTransfers(
        fileTransferCount: Int,
        userInfoTransferCount: Int,
        reason: String
    ) {
        if fileTransferCount > 0 {
        }
        if userInfoTransferCount > 0 {
        }
    }

    nonisolated private static func cancelOutstandingOutboundTransfersIfNeeded(
        session: WCSession,
        transferStagingDirectoryName: String
    ) -> (fileTransferCount: Int, userInfoTransferCount: Int) {
        let activeFileTransfers = session.outstandingFileTransfers
        for transfer in activeFileTransfers {
            transfer.cancel()
            removeStagedTransferFileIfNeeded(
                transfer.file.fileURL,
                transferStagingDirectoryName: transferStagingDirectoryName
            )
        }

        let activeUserInfoTransfers = session.outstandingUserInfoTransfers
        for transfer in activeUserInfoTransfers {
            transfer.cancel()
        }
        return (activeFileTransfers.count, activeUserInfoTransfers.count)
    }

    private func updateLinkState(_ state: WatchLinkState) {
        guard state != linkState else { return }
        linkState = state
        if let handler = handlers.linkStateDidChange {
            Task { @MainActor in
                await handler(state)
            }
        }
    }

    nonisolated private func isCompanionAvailable(_ session: WCSession) -> Bool {
#if os(iOS)
        session.isPaired && session.isWatchAppInstalled
#else
        session.isCompanionAppInstalled
#endif
    }

    nonisolated private func makeLinkStateSnapshot(from session: WCSession, error: Error?) -> LinkStateSnapshot {
        let activation: ActivationSnapshot
        switch session.activationState {
        case .notActivated:
            activation = .notActivated
        case .inactive:
            activation = .inactive
        case .activated:
            activation = .activated
        @unknown default:
            activation = .unknown
        }
        return LinkStateSnapshot(
            activation: activation,
            companionAvailable: isCompanionAvailable(session),
            reachable: session.isReachable,
            errorDescription: error?.localizedDescription
        )
    }

    private func handleIncomingManifest(_ manifest: WatchSyncManifest) async {
        noteObservation(
            "manifest.received",
            details: "control=\(manifest.controlGeneration) mode=\(manifest.mode.rawValue)"
        )
        await runtime.storeReceivedManifest(manifest)
        if let handler = handlers.manifestDidReceive {
            await handler(manifest)
        }
        await handleInlinePackagesIfPresent(in: manifest)
        await persistDiagnostics(reason: "manifest.received")
    }

    private func handleIncomingReliableEvent(_ event: WatchEventEnvelope) async {
        guard await runtime.acceptIncomingEvent(event) else { return }
        noteObservation(
            "reliable_event.received",
            details: "kind=\(event.kind.rawValue) eventID=\(event.eventID)"
        )
        if let handler = handlers.eventDidReceive {
            await handler(event)
        }
        await persistDiagnostics(reason: "reliable_event.received")
    }

    private func handleIncomingLiveMessage(_ liveMessage: WatchLiveMessage) async {
        switch liveMessage.kind {
        case .requestLatestManifest:
            if let handler = handlers.latestManifestRequested {
                await handler()
            }
        case .refreshHint:
            if role == .watch {
                requestLatestManifestIfReachable()
            }
        }
    }

    private func handleInlinePackagesIfPresent(in manifest: WatchSyncManifest) async {
        if let inlineMirrorSnapshot = manifest.inlineMirrorSnapshot,
           let package = WatchConnectivityWire.decode(MirrorSnapshotPackage.self, from: inlineMirrorSnapshot),
           package.manifest.packageID == manifest.mirrorPackage?.packageID
        {
            noteObservation(
                "manifest.inline_mirror.received",
                details: "packageID=\(package.manifest.packageID) generation=\(package.manifest.generation)"
            )
            if let handler = handlers.mirrorPackageDidReceive {
                await handler(package)
            }
        }

        if let inlineStandaloneProvisioning = manifest.inlineStandaloneProvisioning,
           let package = WatchConnectivityWire.decode(StandaloneProvisioningPackage.self, from: inlineStandaloneProvisioning),
           package.manifest.packageID == manifest.standalonePackage?.packageID
        {
            noteObservation(
                "manifest.inline_standalone.received",
                details: "packageID=\(package.manifest.packageID) generation=\(package.manifest.generation)"
            )
            if let handler = handlers.standalonePackageDidReceive {
                await handler(package)
            }
        }
    }

    private func handleIncomingFile(fileURL: URL, metadata: WatchTransferPackageManifest) async {
        defer {
            removeDeferredIncomingFileIfNeeded(fileURL)
        }
        noteObservation(
            "file_transfer.received",
            details: "kind=\(metadata.kind.rawValue) packageID=\(metadata.packageID)"
        )
        guard let stagedURL = await runtime.stageIncomingFile(from: fileURL, metadata: metadata) else {
            recordLinkStateError(
                "watch connectivity \(metadata.kind.rawValue) package stage failed (packageID: \(metadata.packageID))"
            )
            return
        }
        switch metadata.kind {
        case .mirrorSnapshot:
            do {
                let package = try await runtime.decodeMirrorSnapshotPackage(at: stagedURL)
                if let handler = handlers.mirrorPackageDidReceive {
                    await handler(package)
                }
            } catch {
                recordLinkStateError(
                    "watch connectivity mirror package decode failed (packageID: \(metadata.packageID)): \(error.localizedDescription)"
                )
            }
        case .standaloneProvisioning:
            do {
                let package = try await runtime.decodeStandaloneProvisioningPackage(at: stagedURL)
                if let handler = handlers.standalonePackageDidReceive {
                    await handler(package)
                }
            } catch {
                recordLinkStateError(
                    "watch connectivity standalone package decode failed (packageID: \(metadata.packageID)): \(error.localizedDescription)"
                )
            }
        }
        await runtime.removeIncomingFile(at: stagedURL)
        await persistDiagnostics(reason: "file_transfer.received")
    }

    private nonisolated func copyIncomingFileForDeferredHandling(
        _ sourceURL: URL,
        metadata: WatchTransferPackageManifest
    ) -> URL? {
        let fileManager = FileManager.default
        let handoffDirectoryName = "pushgo-watch-connectivity-incoming"
        let handoffRoot = fileManager.temporaryDirectory
            .appendingPathComponent(handoffDirectoryName, isDirectory: true)
        do {
            try fileManager.createDirectory(at: handoffRoot, withIntermediateDirectories: true)
            let destinationURL = handoffRoot.appendingPathComponent(
                "\(metadata.kind.rawValue)-\(metadata.packageID)-\(metadata.generation).json",
                isDirectory: false
            )
            try? fileManager.removeItem(at: destinationURL)
            try fileManager.copyItem(at: sourceURL, to: destinationURL)
            return destinationURL
        } catch {
            return nil
        }
    }

    private nonisolated func removeDeferredIncomingFileIfNeeded(_ url: URL) {
        let handoffDirectoryName = "pushgo-watch-connectivity-incoming"
        let handoffRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(handoffDirectoryName, isDirectory: true)
        let standardizedFile = url.standardizedFileURL.path
        let standardizedRoot = handoffRoot.standardizedFileURL.path
        let withinRoot = standardizedFile == standardizedRoot || standardizedFile.hasPrefix(standardizedRoot + "/")
        guard withinRoot else { return }
        try? FileManager.default.removeItem(at: url)
    }

    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        _ = activationState
        let snapshot = makeLinkStateSnapshot(from: session, error: error)
        let receivedContext = session.receivedApplicationContext
        let contextEmpty = receivedContext.isEmpty
        let replayManifest = WatchSyncManifest.fromApplicationContext(receivedContext)
        let keySummary = watchConnectivitySortedKeyList(receivedContext)
        let activationStateDescription = Self.activationStateDescription(session.activationState)
        let errorDescription = error?.localizedDescription ?? "none"
        let activationCancelledTransfers = !snapshot.companionAvailable
            ? Self.cancelOutstandingOutboundTransfersIfNeeded(
                session: session,
                transferStagingDirectoryName: transferStagingDirectoryName
            )
            : nil
        Task { @MainActor in
            self.activationRequested = false
            self.updateCachedLinkState(from: snapshot)
            if let activationCancelledTransfers {
                self.logCancelledOutstandingOutboundTransfers(
                    fileTransferCount: activationCancelledTransfers.fileTransferCount,
                    userInfoTransferCount: activationCancelledTransfers.userInfoTransferCount,
                    reason: "activation.no_companion"
                )
            }
            self.noteObservation(
                "activation.completed",
                details: "state=\(activationStateDescription) error=\(errorDescription)"
            )
            await self.replayReceivedApplicationContextIfAvailable(
                manifest: replayManifest,
                keySummary: keySummary,
                source: "activationDidComplete",
                contextEmpty: contextEmpty
            )
            await self.flushPendingState()
            await self.persistDiagnostics(reason: "activation.completed")
        }
    }

#if os(iOS)
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {
        let snapshot = makeLinkStateSnapshot(from: session, error: nil)
        Task { @MainActor in
            self.activationRequested = false
            self.updateCachedLinkState(from: snapshot)
            self.noteObservation("activation.inactive")
            await self.persistDiagnostics(reason: "activation.inactive")
        }
    }

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        let snapshot = makeLinkStateSnapshot(from: session, error: nil)
        Task { @MainActor in
            self.activationRequested = false
            self.updateCachedLinkState(from: snapshot)
            self.noteObservation("activation.deactivated")
            self.activateIfNeeded()
            await self.persistDiagnostics(reason: "activation.deactivated")
        }
    }

    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        let snapshot = makeLinkStateSnapshot(from: session, error: nil)
        let watchStateCancelledTransfers = !snapshot.companionAvailable
            ? Self.cancelOutstandingOutboundTransfersIfNeeded(
                session: session,
                transferStagingDirectoryName: transferStagingDirectoryName
            )
            : nil
        Task { @MainActor in
            self.updateCachedLinkState(from: snapshot)
            if let watchStateCancelledTransfers {
                self.logCancelledOutstandingOutboundTransfers(
                    fileTransferCount: watchStateCancelledTransfers.fileTransferCount,
                    userInfoTransferCount: watchStateCancelledTransfers.userInfoTransferCount,
                    reason: "watch_state.no_companion"
                )
            }
            self.noteObservation("watch_state.changed")
            await self.persistDiagnostics(reason: "watch_state.changed")
        }
    }
#endif

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let snapshot = makeLinkStateSnapshot(from: session, error: nil)
        let reachable = session.isReachable
        Task { @MainActor in
            self.updateCachedLinkState(from: snapshot)
            self.noteObservation("reachability.changed", details: "reachable=\(reachable)")
            await self.flushPendingReliableEvents()
            if self.role == .watch {
                self.requestLatestManifestIfReachable()
            }
            await self.persistDiagnostics(reason: "reachability.changed")
        }
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveApplicationContext applicationContext: [String: Any]
    ) {
        _ = session
        let manifest = WatchSyncManifest.fromApplicationContext(applicationContext)
        let keySummary = watchConnectivitySortedKeyList(applicationContext)
        Task { @MainActor in
            guard let manifest else {
                self.recordLinkStateError(
                    "watch connectivity manifest decode failed from didReceiveApplicationContext (keys: \(keySummary))"
                )
                await self.persistDiagnostics(reason: "manifest.decode_failed")
                return
            }
            await self.handleIncomingManifest(manifest)
        }
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveUserInfo userInfo: [String: Any]
    ) {
        _ = session
        let event = WatchEventEnvelope.fromUserInfo(userInfo)
        let keySummary = watchConnectivitySortedKeyList(userInfo)
        Task { @MainActor in
            guard let event else {
                self.recordLinkStateError(
                    "watch connectivity reliable event decode failed (keys: \(keySummary))"
                )
                await self.persistDiagnostics(reason: "reliable_event.decode_failed")
                return
            }
            await self.handleIncomingReliableEvent(event)
        }
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveMessage message: [String: Any]
    ) {
        _ = session
        let liveMessage = WatchLiveMessage.fromPayload(message)
        let keySummary = watchConnectivitySortedKeyList(message)
        Task { @MainActor in
            guard let liveMessage else {
                self.recordLinkStateError(
                    "watch connectivity live message decode failed (keys: \(keySummary))"
                )
                await self.persistDiagnostics(reason: "live_message.decode_failed")
                return
            }
            self.noteObservation("live_message.received", details: "kind=\(liveMessage.kind.rawValue)")
            await self.handleIncomingLiveMessage(liveMessage)
            await self.persistDiagnostics(reason: "live_message.received")
        }
    }

    nonisolated func session(_ session: WCSession, didReceive file: WCSessionFile) {
        _ = session
        let metadata = WatchTransferPackageManifest.fromMetadata(file.metadata)
        let keySummary = watchConnectivitySortedKeyList(file.metadata ?? [:])
        let fileURL = file.fileURL
        let handoffURL = metadata.flatMap { metadata in
            copyIncomingFileForDeferredHandling(fileURL, metadata: metadata)
        }
        Task { @MainActor in
            guard let metadata else {
                self.recordLinkStateError(
                    "watch connectivity file metadata decode failed (keys: \(keySummary))"
                )
                await self.persistDiagnostics(reason: "file_transfer.metadata_failed")
                return
            }
            guard let handoffURL else {
                self.recordLinkStateError(
                    "watch connectivity \(metadata.kind.rawValue) handoff failed (packageID: \(metadata.packageID))"
                )
                await self.persistDiagnostics(reason: "file_transfer.handoff_failed")
                return
            }
            await self.handleIncomingFile(fileURL: handoffURL, metadata: metadata)
        }
    }

    nonisolated func session(
        _ session: WCSession,
        didFinish fileTransfer: WCSessionFileTransfer,
        error: Error?
    ) {
        _ = session
        let metadata = WatchTransferPackageManifest.fromMetadata(fileTransfer.file.metadata)
        let transferredFileURL = fileTransfer.file.fileURL
        let canRetryFailedTransfer = canTransmitToCompanion(using: session)
        let finishedCancelledTransfers = (error != nil && !canRetryFailedTransfer)
            ? Self.cancelOutstandingOutboundTransfersIfNeeded(
                session: session,
                transferStagingDirectoryName: transferStagingDirectoryName
            )
            : nil
        Task { @MainActor in
            if error == nil, let metadata {
                self.noteObservation(
                    "file_transfer.finished",
                    details: "kind=\(metadata.kind.rawValue) packageID=\(metadata.packageID) status=success"
                )
            } else if let metadata, let error {
                self.noteObservation(
                    "file_transfer.finished",
                    details: "kind=\(metadata.kind.rawValue) packageID=\(metadata.packageID) status=failure error=\(error.localizedDescription)"
                )
            } else if let error {
                self.noteObservation(
                    "file_transfer.finished",
                    details: "kind=unknown packageID=unknown status=failure error=\(error.localizedDescription)"
                )
            }
            self.removeStagedTransferFileIfNeeded(transferredFileURL)
            if let error {
                self.updateLinkState(
                    WatchLinkState(
                        phase: self.linkState.phase,
                        lastErrorDescription: error.localizedDescription
                    )
                )
                if canRetryFailedTransfer {
                    await self.flushPendingFileTransfers()
                } else if let finishedCancelledTransfers {
                    self.logCancelledOutstandingOutboundTransfers(
                        fileTransferCount: finishedCancelledTransfers.fileTransferCount,
                        userInfoTransferCount: finishedCancelledTransfers.userInfoTransferCount,
                        reason: "file_transfer.finish_no_companion"
                    )
                }
            }
            await self.persistDiagnostics(reason: "file_transfer.finished")
        }
    }
}
#endif
