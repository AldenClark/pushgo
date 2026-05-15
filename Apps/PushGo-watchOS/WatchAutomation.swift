import Foundation
import SwiftUI

#if canImport(Darwin)
import Darwin
#endif

#if DEBUG
@MainActor
private final class PushGoAutomationPerformanceMonitor: NSObject {
    static let shared = PushGoAutomationPerformanceMonitor()

    struct Snapshot: Sendable {
        let residentMemoryBytes: UInt64?
        let mainThreadMaxStallMilliseconds: Int
    }

    private let expectedTickInterval: TimeInterval = 1.0 / 30.0
    private var started = false
    private var timer: Timer?
    private var lastTickUptime: TimeInterval?
    private var maxStallMilliseconds = 0

    private override init() {
        super.init()
    }

    func startIfNeeded() {
        guard !started else { return }
        started = true
        lastTickUptime = ProcessInfo.processInfo.systemUptime

        let timer = Timer(
            timeInterval: expectedTickInterval,
            target: self,
            selector: #selector(handleTimerTick),
            userInfo: nil,
            repeats: true
        )
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func snapshot() -> Snapshot {
        Snapshot(
            residentMemoryBytes: currentResidentMemoryBytes(),
            mainThreadMaxStallMilliseconds: maxStallMilliseconds
        )
    }

    private func currentResidentMemoryBytes() -> UInt64? {
        #if canImport(Darwin)
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(
                    mach_task_self_,
                    task_flavor_t(MACH_TASK_BASIC_INFO),
                    rebound,
                    &count
                )
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return UInt64(info.resident_size)
        #else
        return nil
        #endif
    }

    @objc
    private func handleTimerTick() {
        let now = ProcessInfo.processInfo.systemUptime
        if let lastTickUptime {
            let stall = max(0, now - lastTickUptime - expectedTickInterval)
            let stallMilliseconds = Int((stall * 1_000).rounded())
            maxStallMilliseconds = max(maxStallMilliseconds, stallMilliseconds)
        }
        lastTickUptime = now
    }
}

private enum PushGoWatchAutomationEnvironment {
    static let request = "PUSHGO_AUTOMATION_REQUEST"
    static let responsePath = "PUSHGO_AUTOMATION_RESPONSE_PATH"
    static let statePath = "PUSHGO_AUTOMATION_STATE_PATH"
    static let eventsPath = "PUSHGO_AUTOMATION_EVENTS_PATH"
    static let tracePath = "PUSHGO_AUTOMATION_TRACE_PATH"
}

private struct PushGoWatchAutomationRequest: Decodable {
    struct Args: Decodable {
        let tab: String?
        let messageId: String?
        let entityType: String?
        let entityId: String?
        let path: String?
        let baseURL: String?
        let token: String?

        private enum CodingKeys: String, CodingKey {
            case tab
            case messageId = "message_id"
            case entityType = "entity_type"
            case entityId = "entity_id"
            case path
            case baseURL = "base_url"
            case token
        }
    }

    let id: String?
    let plane: String?
    let name: String
    let args: Args?
}

private struct PushGoWatchAutomationState: Encodable, Equatable {
    let platform: String
    let buildMode: String
    let activeTab: String
    let visibleScreen: String
    let openedMessageId: String?
    let openedMessageDecryptionState: String?
    let openedEntityType: String?
    let openedEntityId: String?
    let pendingMessageId: String?
    let pendingEventId: String?
    let pendingThingId: String?
    let unreadMessageCount: Int
    let totalMessageCount: Int
    let eventCount: Int
    let thingCount: Int
    let gatewayBaseURL: String?
    let gatewayTokenPresent: Bool
    let providerMode: String
    let providerTokenPresent: Bool
    let deviceKeyPresent: Bool
    let privateRoute: String
    let privateTransport: String
    let privateStage: String
    let privateDetail: String?
    let ackPendingCount: Int
    let channelCount: Int
    let localStoreMode: String
    let localStoreReason: String?
    let runtimeErrorCount: Int
    let latestRuntimeErrorSource: String?
    let latestRuntimeErrorCategory: String?
    let latestRuntimeErrorCode: String?
    let latestRuntimeErrorMessage: String?
    let latestRuntimeErrorTimestamp: String?
    let residentMemoryBytes: UInt64?
    let mainThreadMaxStallMilliseconds: Int

    private enum CodingKeys: String, CodingKey {
        case platform
        case buildMode = "build_mode"
        case activeTab = "active_tab"
        case visibleScreen = "visible_screen"
        case openedMessageId = "opened_message_id"
        case openedMessageDecryptionState = "opened_message_decryption_state"
        case openedEntityType = "opened_entity_type"
        case openedEntityId = "opened_entity_id"
        case pendingMessageId = "pending_message_id"
        case pendingEventId = "pending_event_id"
        case pendingThingId = "pending_thing_id"
        case unreadMessageCount = "unread_message_count"
        case totalMessageCount = "total_message_count"
        case eventCount = "event_count"
        case thingCount = "thing_count"
        case gatewayBaseURL = "gateway_base_url"
        case gatewayTokenPresent = "gateway_token_present"
        case providerMode = "provider_mode"
        case providerTokenPresent = "provider_token_present"
        case deviceKeyPresent = "device_key_present"
        case privateRoute = "private_route"
        case privateTransport = "private_transport"
        case privateStage = "private_stage"
        case privateDetail = "private_detail"
        case ackPendingCount = "ack_pending_count"
        case channelCount = "channel_count"
        case localStoreMode = "local_store_mode"
        case localStoreReason = "local_store_reason"
        case runtimeErrorCount = "runtime_error_count"
        case latestRuntimeErrorSource = "latest_runtime_error_source"
        case latestRuntimeErrorCategory = "latest_runtime_error_category"
        case latestRuntimeErrorCode = "latest_runtime_error_code"
        case latestRuntimeErrorMessage = "latest_runtime_error_message"
        case latestRuntimeErrorTimestamp = "latest_runtime_error_timestamp"
        case residentMemoryBytes = "resident_memory_bytes"
        case mainThreadMaxStallMilliseconds = "main_thread_max_stall_ms"
    }
}

private struct PushGoWatchAutomationRuntimeError: Equatable {
    let source: String
    let category: String
    let code: String?
    let message: String
    let timestamp: String
}

private struct PushGoWatchAutomationDetailReadySample: Equatable {
    let sequence: Int
    let messageId: String
    let bodyBytes: Int
    let titleBytes: Int
    let lineCount: Int
    let maxLineBytes: Int
    let imageURLCount: Int
}

private struct PushGoWatchAutomationResponse: Encodable {
    let id: String?
    let ok: Bool
    let platform: String
    let state: PushGoWatchAutomationState?
    let error: String?
}

private struct PushGoWatchAutomationEvent: Encodable {
    let timestamp: String
    let platform: String
    let type: String
    let command: String?
    let details: [String: String]
}

private struct PushGoWatchAutomationTraceRecord: Encodable {
    let timestamp: String
    let platform: String
    let kind: String
    let traceId: String
    let spanId: String
    let parentSpanId: String?
    let requestId: String?
    let sessionId: String?
    let domain: String
    let operation: String
    let status: String?
    let durationMs: Int?
    let attributes: [String: String]
    let errorCode: String?
    let errorMessage: String?

    private enum CodingKeys: String, CodingKey {
        case timestamp
        case platform
        case kind
        case traceId = "trace_id"
        case spanId = "span_id"
        case parentSpanId = "parent_span_id"
        case requestId = "request_id"
        case sessionId = "session_id"
        case domain
        case operation
        case status
        case durationMs = "duration_ms"
        case attributes
        case errorCode = "error_code"
        case errorMessage = "error_message"
    }
}

private struct PushGoWatchActiveTrace {
    let traceId: String
    let spanId: String
    let requestId: String?
    let command: String
    let startedAt: Date
}

private struct PushGoWatchAutomationFixtureBundle: Decodable {
    let messages: [PushGoWatchAutomationFixtureMessage]
    let entityRecords: [PushGoWatchAutomationFixtureMessage]
    let channelSubscriptions: [PushGoWatchAutomationFixtureSubscription]

    private enum CodingKeys: String, CodingKey {
        case messages
        case entityRecords = "entity_records"
        case channelSubscriptions = "channel_subscriptions"
    }

    init(from decoder: Decoder) throws {
        if let singleValue = try? decoder.singleValueContainer(),
           let messages = try? singleValue.decode([PushGoWatchAutomationFixtureMessage].self)
        {
            self.messages = messages
            entityRecords = []
            channelSubscriptions = []
            return
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        messages = try container.decodeIfPresent([PushGoWatchAutomationFixtureMessage].self, forKey: .messages) ?? []
        entityRecords = try container.decodeIfPresent([PushGoWatchAutomationFixtureMessage].self, forKey: .entityRecords) ?? []
        channelSubscriptions = try container.decodeIfPresent(
            [PushGoWatchAutomationFixtureSubscription].self,
            forKey: .channelSubscriptions
        ) ?? []
    }
}

private struct PushGoWatchAutomationFixtureMessage: Decodable {
    let id: UUID
    let messageId: String?
    let title: String
    let body: String
    let channel: String?
    let url: URL?
    let isRead: Bool
    let receivedAt: Date
    let rawPayload: [String: AnyCodable]
    let status: PushMessage.Status
    let decryptionState: PushMessage.DecryptionState?

    private enum CodingKeys: String, CodingKey {
        case id
        case messageId = "message_id"
        case title
        case body
        case channel = "channel_id"
        case url
        case isRead = "is_read"
        case receivedAt = "received_at"
        case rawPayload = "raw_payload"
        case status
        case decryptionState = "decryption_state"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let uuid = try? container.decode(UUID.self, forKey: .id) {
            id = uuid
        } else if let rawId = try? container.decode(String.self, forKey: .id),
                  let uuid = UUID(uuidString: rawId)
        {
            id = uuid
        } else {
            id = UUID()
        }
        messageId = try container.decodeIfPresent(String.self, forKey: .messageId)
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        body = try container.decodeIfPresent(String.self, forKey: .body) ?? ""
        channel = try container.decodeIfPresent(String.self, forKey: .channel)
        url = try container.decodeIfPresent(URL.self, forKey: .url)
        isRead = try container.decodeIfPresent(Bool.self, forKey: .isRead) ?? false
        receivedAt = try container.decode(Date.self, forKey: .receivedAt)
        rawPayload = try container.decodeIfPresent([String: AnyCodable].self, forKey: .rawPayload) ?? [:]
        status = try container.decodeIfPresent(PushMessage.Status.self, forKey: .status) ?? .normal
        decryptionState = try container.decodeIfPresent(PushMessage.DecryptionState.self, forKey: .decryptionState)
    }

    func toWatchLightPayload() -> WatchLightPayload? {
        let bridgedPayload = rawPayload.reduce(into: [AnyHashable: Any]()) { result, pair in
            result[pair.key] = pair.value.value
        }
        return WatchLightQuantizer.quantizeStandalonePayload(
            WatchLightQuantizer.stringifyPayload(bridgedPayload),
            titleOverride: title,
            bodyOverride: body,
            urlOverride: url,
            notificationRequestId: nil
        )
    }
}

private struct PushGoWatchAutomationFixtureSubscription: Decodable {
    let gateway: String?
    let channelId: String
    let displayName: String?
    let password: String?
    let lastSyncedAt: Date?
    let updatedAt: Date?

    private enum CodingKeys: String, CodingKey {
        case gateway
        case channelId = "channel_id"
        case displayName = "display_name"
        case password
        case lastSyncedAt = "last_synced_at"
        case updatedAt = "updated_at"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        gateway = try container.decodeIfPresent(String.self, forKey: .gateway)
        channelId = try container.decode(String.self, forKey: .channelId)
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName)
        password = try container.decodeIfPresent(String.self, forKey: .password)
        lastSyncedAt = try container.decodeIfPresent(Date.self, forKey: .lastSyncedAt)
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt)
    }
}

@MainActor
final class PushGoWatchAutomationRuntime {
    static let shared = PushGoWatchAutomationRuntime()

    private let platformIdentifier = "watchos"
    private var configured = false
    private var didExecuteStartupRequest = false
    private var request: PushGoWatchAutomationRequest?
    private var requestDecodeError: String?
    private var responseURL: URL?
    private var stateURL: URL?
    private var eventsURL: URL?
    private var traceURL: URL?
    private var latestState: PushGoWatchAutomationState?
    private var runtimeErrorCount = 0
    private var latestRuntimeError: PushGoWatchAutomationRuntimeError?
    private var latestDetailReadySample: PushGoWatchAutomationDetailReadySample?
    private var nextDetailReadySequence = 0
    private var activeTrace: PushGoWatchActiveTrace?

    private init() {}

    func configureFromProcessEnvironment() {
        guard !configured else { return }
        configured = true
        PushGoAutomationPerformanceMonitor.shared.startIfNeeded()
        responseURL = fileURL(for: PushGoWatchAutomationEnvironment.responsePath)
        stateURL = fileURL(for: PushGoWatchAutomationEnvironment.statePath)
        eventsURL = fileURL(for: PushGoWatchAutomationEnvironment.eventsPath)
        traceURL = fileURL(for: PushGoWatchAutomationEnvironment.tracePath)

        guard let rawRequest = ProcessInfo.processInfo.environment[PushGoWatchAutomationEnvironment.request]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !rawRequest.isEmpty
        else {
            return
        }

        do {
            request = try JSONDecoder().decode(PushGoWatchAutomationRequest.self, from: Data(rawRequest.utf8))
        } catch {
            requestDecodeError = "Failed to decode automation request: \(error.localizedDescription)"
        }
    }

    func publishState(
        environment: AppEnvironment,
        activeTab: String,
        visibleScreen: String,
        openedMessageId: String? = nil,
        openedEntityType: String? = nil,
        openedEntityId: String? = nil
    ) {
        configureFromProcessEnvironment()
        let previousState = latestState
        let performance = PushGoAutomationPerformanceMonitor.shared.snapshot()
        let state = PushGoWatchAutomationState(
            platform: platformIdentifier,
            buildMode: "debug",
            activeTab: activeTab,
            visibleScreen: visibleScreen,
            openedMessageId: openedMessageId,
            openedMessageDecryptionState: nil,
            openedEntityType: openedEntityType,
            openedEntityId: openedEntityId,
            pendingMessageId: environment.pendingMessageToOpen,
            pendingEventId: normalizedIdentifier(environment.pendingEventToOpen),
            pendingThingId: normalizedIdentifier(environment.pendingThingToOpen),
            unreadMessageCount: environment.unreadMessageCount,
            totalMessageCount: environment.totalMessageCount,
            eventCount: 0,
            thingCount: 0,
            gatewayBaseURL: environment.serverConfig?.normalizedBaseURL.absoluteString,
            gatewayTokenPresent: normalizedIdentifier(environment.serverConfig?.token) != nil,
            providerMode: "provider",
            providerTokenPresent: false,
            deviceKeyPresent: false,
            privateRoute: "idle",
            privateTransport: "watch",
            privateStage: "idle",
            privateDetail: nil,
            ackPendingCount: 0,
            channelCount: environment.channelSubscriptions.count,
            localStoreMode: localStoreMode(environment.dataStore.storageState),
            localStoreReason: normalizedIdentifier(environment.dataStore.storageState.reason),
            runtimeErrorCount: runtimeErrorCount,
            latestRuntimeErrorSource: latestRuntimeError?.source,
            latestRuntimeErrorCategory: latestRuntimeError?.category,
            latestRuntimeErrorCode: latestRuntimeError?.code,
            latestRuntimeErrorMessage: latestRuntimeError?.message,
            latestRuntimeErrorTimestamp: latestRuntimeError?.timestamp,
            residentMemoryBytes: performance.residentMemoryBytes,
            mainThreadMaxStallMilliseconds: performance.mainThreadMaxStallMilliseconds
        )
        latestState = state
        writeJSON(state, to: stateURL)
        writeEvent(type: "state.updated", command: nil, details: [
            "active_tab": activeTab,
            "visible_screen": visibleScreen,
        ])
        writeDerivedEvents(previous: previousState, current: state)
        Task { @MainActor [weak self] in
            await self?.publishEnrichedState(baseState: state, environment: environment)
        }
    }

    func executeStartupRequestIfNeeded(environment: AppEnvironment) async {
        configureFromProcessEnvironment()
        guard !didExecuteStartupRequest else { return }
        didExecuteStartupRequest = true

        if let requestDecodeError {
            await writeResponse(ok: false, error: requestDecodeError, environment: environment)
            return
        }

        guard let request else { return }
        startCommandTrace(request)
        writeEvent(type: "command.received", command: request.name, details: [:])

        do {
            switch request.name {
            case "snapshot.get", "debug.dump_state":
                break
            case "nav.switch_tab":
                guard let tab = normalizedIdentifier(request.args?.tab) else {
                    throw PushGoWatchAutomationError.missingArgument("tab")
                }
                try? await Task.sleep(for: .milliseconds(300))
                NotificationCenter.default.post(name: .pushgoWatchAutomationSelectTab, object: tab)
            case "message.open":
                guard let messageId = normalizedIdentifier(request.args?.messageId) else {
                    throw PushGoWatchAutomationError.missingArgument("message_id")
                }
                await environment.handleNotificationOpen(messageId: messageId)
            case "entity.open":
                guard let entityType = normalizedIdentifier(request.args?.entityType) else {
                    throw PushGoWatchAutomationError.missingArgument("entity_type")
                }
                guard let entityId = normalizedIdentifier(request.args?.entityId) else {
                    throw PushGoWatchAutomationError.missingArgument("entity_id")
                }
                await environment.handleNotificationOpen(entityType: entityType, entityId: entityId)
            case "gateway.set_server":
                try await updateGatewayConfig(request: request, environment: environment)
            case "fixture.import":
                try await importFixture(request: request, environment: environment)
            case "fixture.seed_messages":
                try await seedMessages(request: request, environment: environment)
            case "fixture.seed_entity_records":
                try await seedEntityRecords(request: request, environment: environment)
            case "fixture.seed_subscriptions":
                try await seedSubscriptions(request: request, environment: environment)
            case "runtime.measure_list_reloads":
                try await measureRuntimeListReloads(environment: environment)
            case "runtime.measure_detail_variants":
                try await measureRuntimeDetailVariants(environment: environment)
            case "runtime.measure_detail_cycles":
                try await measureRuntimeDetailCycles(environment: environment)
            case "debug.reset_local_state", "fixture.reset_local_state":
                try await resetLocalState(environment: environment)
            default:
                throw PushGoWatchAutomationError.unsupportedCommand(request.name)
            }
            await waitForStatePropagation(after: request.name)
            await writeResponse(ok: true, error: nil, environment: environment)
            writeEvent(type: "command.completed", command: request.name, details: [:])
            finishCommandTrace(status: "ok", errorMessage: nil)
        } catch {
            let message = automationErrorMessage(for: error)
            await writeResponse(ok: false, error: message, environment: environment)
            writeEvent(type: "command.failed", command: request.name, details: [
                "error": message,
            ])
            finishCommandTrace(status: "error", errorMessage: message)
        }
    }

    private func publishEnrichedState(baseState: PushGoWatchAutomationState, environment: AppEnvironment) async {
        let previousState = latestState
        let state = await enrichState(baseState, environment: environment)
        latestState = state
        writeJSON(state, to: stateURL)
        writeDerivedEvents(previous: previousState, current: state)
    }

    private func waitForStatePropagation(after commandName: String) async {
        await Task.yield()
        switch commandName {
        case "nav.switch_tab", "message.open", "entity.open":
            try? await Task.sleep(for: .milliseconds(200))
            await Task.yield()
        default:
            break
        }
    }

    private func waitForAutomationState(
        environment: AppEnvironment,
        timeout: TimeInterval,
        predicate: @escaping (PushGoWatchAutomationState) -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let state = await fallbackState(environment: environment)
            if predicate(state) {
                latestState = state
                return true
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return false
    }

    private func enrichState(
        _ state: PushGoWatchAutomationState,
        environment: AppEnvironment
    ) async -> PushGoWatchAutomationState {
        let openedMessageId = await resolvedAutomationMessageIdentifier(
            state.openedMessageId,
            environment: environment
        )
        let pendingMessageId = await resolvedAutomationMessageIdentifier(
            state.pendingMessageId,
            environment: environment
        )
        let providerToken = await environment.dataStore.cachedPushToken(for: platformIdentifier)
            ?? PushGoAutomationContext.providerToken
        let deviceKey = await environment.dataStore.cachedDeviceKey(for: platformIdentifier)
        let performance = PushGoAutomationPerformanceMonitor.shared.snapshot()
        let ackPendingCount = 0
        let messages = (try? await environment.dataStore.loadWatchLightMessages()) ?? []
        let totalMessageCount = messages.count
        let unreadMessageCount = messages.filter { !$0.isRead }.count
        let eventCount = (try? await environment.dataStore.loadWatchLightEvents().count) ?? 0
        let thingCount = (try? await environment.dataStore.loadWatchLightThings().count) ?? 0
        let openedMessageDecryptionState = await resolvedAutomationMessageDecryptionState(
            messageId: openedMessageId,
            environment: environment
        )
        let providerTokenPresent = normalizedIdentifier(providerToken) != nil
        let deviceKeyPresent = normalizedIdentifier(deviceKey) != nil
        let privateRoute = providerTokenPresent ? "provider" : "idle"
        let privateStage = deviceKeyPresent ? "ready" : (providerTokenPresent ? "route_pending" : "idle")
        let privateDetail: String? = {
            if environment.serverConfig == nil {
                return "server configuration missing"
            }
            if !providerTokenPresent {
                return "provider token missing"
            }
            if !deviceKeyPresent {
                return "provider route not ready"
            }
            return nil
        }()
        return PushGoWatchAutomationState(
            platform: state.platform,
            buildMode: state.buildMode,
            activeTab: state.activeTab,
            visibleScreen: state.visibleScreen,
            openedMessageId: openedMessageId,
            openedMessageDecryptionState: openedMessageDecryptionState,
            openedEntityType: state.openedEntityType,
            openedEntityId: state.openedEntityId,
            pendingMessageId: pendingMessageId,
            pendingEventId: state.pendingEventId,
            pendingThingId: state.pendingThingId,
            unreadMessageCount: unreadMessageCount,
            totalMessageCount: totalMessageCount,
            eventCount: eventCount,
            thingCount: thingCount,
            gatewayBaseURL: state.gatewayBaseURL,
            gatewayTokenPresent: state.gatewayTokenPresent,
            providerMode: state.providerMode,
            providerTokenPresent: providerTokenPresent,
            deviceKeyPresent: deviceKeyPresent,
            privateRoute: privateRoute,
            privateTransport: state.privateTransport,
            privateStage: privateStage,
            privateDetail: privateDetail,
            ackPendingCount: ackPendingCount,
            channelCount: environment.channelSubscriptions.count,
            localStoreMode: state.localStoreMode,
            localStoreReason: state.localStoreReason,
            runtimeErrorCount: state.runtimeErrorCount,
            latestRuntimeErrorSource: state.latestRuntimeErrorSource,
            latestRuntimeErrorCategory: state.latestRuntimeErrorCategory,
            latestRuntimeErrorCode: state.latestRuntimeErrorCode,
            latestRuntimeErrorMessage: state.latestRuntimeErrorMessage,
            latestRuntimeErrorTimestamp: state.latestRuntimeErrorTimestamp,
            residentMemoryBytes: performance.residentMemoryBytes,
            mainThreadMaxStallMilliseconds: performance.mainThreadMaxStallMilliseconds
        )
    }

    private func resolvedAutomationMessageDecryptionState(
        messageId: String?,
        environment: AppEnvironment
    ) async -> String? {
        guard normalizedIdentifier(messageId) != nil else { return nil }
        return nil
    }

    private func resolvedAutomationMessageIdentifier(
        _ messageId: String?,
        environment: AppEnvironment
    ) async -> String? {
        guard let messageId = normalizedIdentifier(messageId) else { return nil }
        if let message = try? await environment.dataStore.loadWatchLightMessage(messageId: messageId) {
            return normalizedIdentifier(message.messageId)
                ?? normalizedIdentifier(message.notificationRequestId)
                ?? message.id
        }
        if let message = try? await environment.dataStore.loadWatchLightMessage(notificationRequestId: messageId) {
            return normalizedIdentifier(message.messageId)
                ?? normalizedIdentifier(message.notificationRequestId)
                ?? message.id
        }
        return messageId
    }

    private func writeDerivedEvents(previous: PushGoWatchAutomationState?, current: PushGoWatchAutomationState) {
        if let details = openedEntityEventDetails(previous: previous, current: current) {
            writeEvent(type: "entity.opened", command: nil, details: details)
        }
        if let details = settingsChangedEventDetails(previous: previous, current: current) {
            writeEvent(type: "settings.changed", command: nil, details: details)
        }
        if previous?.unreadMessageCount != current.unreadMessageCount {
            writeEvent(type: "badge.updated", command: nil, details: [
                "unread_message_count": String(current.unreadMessageCount),
            ])
        }
    }

    private func openedEntityEventDetails(
        previous: PushGoWatchAutomationState?,
        current: PushGoWatchAutomationState
    ) -> [String: String]? {
        let currentType = current.openedEntityType ?? (current.openedMessageId != nil ? "message" : nil)
        let currentId = current.openedEntityId ?? current.openedMessageId
        guard let entityType = currentType, let entityId = currentId else { return nil }
        let previousType = previous?.openedEntityType ?? (previous?.openedMessageId != nil ? "message" : nil)
        let previousId = previous?.openedEntityId ?? previous?.openedMessageId
        guard entityType != previousType || entityId != previousId else { return nil }
        return [
            "entity_type": entityType,
            "entity_id": entityId,
            "projection_destination": projectionDestination(for: entityType),
        ]
    }

    private func settingsChangedEventDetails(
        previous: PushGoWatchAutomationState?,
        current: PushGoWatchAutomationState
    ) -> [String: String]? {
        var changedKeys: [String] = []
        if previous?.gatewayBaseURL != current.gatewayBaseURL {
            changedKeys.append("gateway_base_url")
        }
        guard !changedKeys.isEmpty else { return nil }
        return [
            "gateway_base_url": current.gatewayBaseURL ?? "",
            "changed_keys": changedKeys.joined(separator: ","),
        ]
    }

    func recordMessageDetailReady(message: WatchLightMessage) {
        configureFromProcessEnvironment()
        let body = message.body
        let lineLengths = body.split(separator: "\n", omittingEmptySubsequences: false)
            .map { String($0).lengthOfBytes(using: .utf8) }
        nextDetailReadySequence += 1
        let sample = PushGoWatchAutomationDetailReadySample(
            sequence: nextDetailReadySequence,
            messageId: message.messageId,
            bodyBytes: body.lengthOfBytes(using: .utf8),
            titleBytes: message.title.lengthOfBytes(using: .utf8),
            lineCount: lineLengths.count,
            maxLineBytes: lineLengths.max() ?? 0,
            imageURLCount: message.imageURL == nil ? 0 : 1
        )
        latestDetailReadySample = sample
        writeEvent(type: "message.detail_ready", command: nil, details: [
            "message_id": sample.messageId,
            "body_bytes": String(sample.bodyBytes),
            "title_bytes": String(sample.titleBytes),
            "line_count": String(sample.lineCount),
            "max_line_bytes": String(sample.maxLineBytes),
            "image_url_count": String(sample.imageURLCount),
            "sequence": String(sample.sequence),
        ])
    }

    private func measureRuntimeDetailVariants(environment: AppEnvironment) async throws {
        struct Variant {
            let name: String
            let messageId: String
        }

        let variants = [
            Variant(name: "baseline", messageId: "runtime-watch-msg-0"),
            Variant(name: "markdown_10k", messageId: "runtime-watch-msg-1"),
            Variant(name: "markdown_26k", messageId: "runtime-watch-msg-2"),
            Variant(name: "media_rich", messageId: "runtime-watch-msg-3"),
            Variant(name: "longline_unicode", messageId: "runtime-watch-msg-4"),
            Variant(name: "baseline_repeat", messageId: "runtime-watch-msg-0"),
        ]

        var details: [String: String] = [
            "variant_count": String(variants.count),
        ]

        for variant in variants {
            guard try await environment.dataStore.loadWatchLightMessage(messageId: variant.messageId) != nil else {
                throw PushGoWatchAutomationError.invalidArgument("missing message_id \(variant.messageId)")
            }
            let previousSequence = latestDetailReadySample?.sequence ?? 0
            let startedAt = Date()
            await environment.handleNotificationOpen(messageId: variant.messageId)
            try? await Task.sleep(for: .milliseconds(150))
            guard let sample = await waitForDetailReadySample(
                messageId: variant.messageId,
                afterSequence: previousSequence,
                timeout: 12.0
            ) else {
                throw PushGoWatchAutomationError.invalidArgument("detail variant render timeout")
            }
            let durationMs = max(0, Int(Date().timeIntervalSince(startedAt) * 1_000))
            let performance = PushGoAutomationPerformanceMonitor.shared.snapshot()
            details["\(variant.name)_message_id"] = variant.messageId
            details["\(variant.name)_ms"] = String(durationMs)
            details["\(variant.name)_body_bytes"] = String(sample.bodyBytes)
            details["\(variant.name)_title_bytes"] = String(sample.titleBytes)
            details["\(variant.name)_line_count"] = String(sample.lineCount)
            details["\(variant.name)_max_line_bytes"] = String(sample.maxLineBytes)
            details["\(variant.name)_image_url_count"] = String(sample.imageURLCount)
            details["\(variant.name)_resident_memory_bytes"] = String(performance.residentMemoryBytes ?? 0)
            details["\(variant.name)_main_thread_max_stall_ms"] = String(performance.mainThreadMaxStallMilliseconds)
        }

        writeEvent(type: "runtime.detail_variants", command: nil, details: details)
    }

    private func measureRuntimeListReloads(environment: AppEnvironment) async throws {
        let viewModel = WatchLightStoreViewModel(environment: environment)
        let iterationCount = 10
        var reloadDurations: [Int] = []
        reloadDurations.reserveCapacity(iterationCount)
        var peakResidentMemoryBytes: UInt64 = 0
        var peakMainThreadStallMs = 0

        for _ in 0 ..< iterationCount {
            let startedAt = Date()
            await viewModel.reload()
            let durationMs = max(0, Int(Date().timeIntervalSince(startedAt) * 1_000))
            guard !viewModel.messages.isEmpty else {
                throw PushGoWatchAutomationError.invalidArgument("list reload produced empty watch message list")
            }
            reloadDurations.append(durationMs)
            let performance = PushGoAutomationPerformanceMonitor.shared.snapshot()
            peakResidentMemoryBytes = max(peakResidentMemoryBytes, performance.residentMemoryBytes ?? 0)
            peakMainThreadStallMs = max(peakMainThreadStallMs, performance.mainThreadMaxStallMilliseconds)
        }

        guard let firstReload = reloadDurations.first,
              let lastReload = reloadDurations.last,
              let maxReload = reloadDurations.max()
        else {
            throw PushGoWatchAutomationError.invalidArgument("watch reload metrics unavailable")
        }

        writeEvent(type: "runtime.list_reloads", command: nil, details: [
            "iteration_count": String(iterationCount),
            "first_reload_ms": String(firstReload),
            "last_reload_ms": String(lastReload),
            "max_reload_ms": String(maxReload),
            "message_count": String(viewModel.messages.count),
            "event_count": String(viewModel.events.count),
            "thing_count": String(viewModel.things.count),
            "peak_resident_memory_bytes": String(peakResidentMemoryBytes),
            "peak_main_thread_max_stall_ms": String(peakMainThreadStallMs),
        ])
    }

    private func measureRuntimeDetailCycles(environment: AppEnvironment) async throws {
        struct Scenario {
            let name: String
            let messageId: String
        }

        let scenarios = [
            Scenario(name: "normal", messageId: "runtime-watch-msg-0"),
            Scenario(name: "markdown_26k", messageId: "runtime-watch-msg-2"),
            Scenario(name: "media", messageId: "runtime-watch-msg-3"),
        ]
        let cyclesPerScenario = 20
        let detailReadyTimeout = runtimeTimeoutFromEnv(
            "PUSHGO_WATCH_RUNTIME_DETAIL_READY_TIMEOUT_SECONDS",
            defaultValue: 12.0
        )
        let listReturnTimeout = runtimeTimeoutFromEnv(
            "PUSHGO_WATCH_RUNTIME_DETAIL_RETURN_TIMEOUT_SECONDS",
            defaultValue: 2.0
        )
        var details: [String: String] = [
            "scenario_count": String(scenarios.count),
            "cycles_per_scenario": String(cyclesPerScenario),
            "detail_ready_timeout_seconds": String(format: "%.1f", detailReadyTimeout),
            "list_return_timeout_seconds": String(format: "%.1f", listReturnTimeout),
        ]

        for scenario in scenarios {
            guard try await environment.dataStore.loadWatchLightMessage(messageId: scenario.messageId) != nil else {
                throw PushGoWatchAutomationError.invalidArgument("missing message_id \(scenario.messageId)")
            }

            let startPerformance = PushGoAutomationPerformanceMonitor.shared.snapshot()
            var peakResidentMemory = startPerformance.residentMemoryBytes ?? 0
            var peakMainThreadStallMs = startPerformance.mainThreadMaxStallMilliseconds
            var durations: [Int] = []
            durations.reserveCapacity(cyclesPerScenario)
            var detailReadyAdvanceCount = 0
            var detailReadyFallbackCount = 0

            for cycleIndex in 0 ..< cyclesPerScenario {
                let previousSequence = latestDetailReadySample?.sequence ?? 0
                let startedAt = Date()
                await environment.handleNotificationOpen(messageId: scenario.messageId)
                let enteredDetail = await waitForAutomationState(
                    environment: environment,
                    timeout: min(3.0, detailReadyTimeout)
                ) { state in
                    state.visibleScreen == "screen.message.detail" || state.openedMessageId == scenario.messageId
                }
                let detailSample = await waitForDetailReadySample(
                    messageId: scenario.messageId,
                    afterSequence: previousSequence,
                    timeout: detailReadyTimeout
                )
                if detailSample != nil {
                    detailReadyAdvanceCount += 1
                } else if enteredDetail {
                    // watchOS detail reload may reuse the same rendered view without emitting a new detail-ready sample.
                    detailReadyFallbackCount += 1
                } else {
                    let latestSample = latestDetailReadySample
                    let latestStateSnapshot = latestState
                    writeEvent(type: "runtime.detail_cycle_timeout", command: nil, details: [
                        "scenario": scenario.name,
                        "cycle_index": String(cycleIndex),
                        "phase": "detail_ready",
                        "detail_ready_timeout_seconds": String(format: "%.1f", detailReadyTimeout),
                        "expected_message_id": scenario.messageId,
                        "entered_detail_before_timeout": enteredDetail ? "true" : "false",
                        "previous_detail_ready_sequence": String(previousSequence),
                        "latest_detail_ready_sequence": String(latestSample?.sequence ?? -1),
                        "latest_detail_ready_message_id": latestSample?.messageId ?? "",
                        "latest_state_active_tab": latestStateSnapshot?.activeTab ?? "",
                        "latest_state_visible_screen": latestStateSnapshot?.visibleScreen ?? "",
                    ])
                    throw PushGoWatchAutomationError.invalidArgument(
                        "detail cycle timeout for \(scenario.name) (detail_ready_timeout_seconds=\(String(format: "%.1f", detailReadyTimeout)))"
                    )
                }
                NotificationCenter.default.post(name: .pushgoWatchAutomationSelectTab, object: "events")
                _ = await waitForAutomationState(environment: environment, timeout: listReturnTimeout) { state in
                    state.activeTab == "tab.events" || state.visibleScreen == "screen.events.list"
                }
                NotificationCenter.default.post(name: .pushgoWatchAutomationSelectTab, object: "messages")
                let returnedToMessages = await waitForAutomationState(environment: environment, timeout: listReturnTimeout) { state in
                    state.activeTab == "tab.messages" || state.visibleScreen == "screen.messages.list"
                }
                guard returnedToMessages else {
                    let latestSample = latestDetailReadySample
                    let latestStateSnapshot = latestState
                    writeEvent(type: "runtime.detail_cycle_timeout", command: nil, details: [
                        "scenario": scenario.name,
                        "cycle_index": String(cycleIndex),
                        "phase": "list_return",
                        "list_return_timeout_seconds": String(format: "%.1f", listReturnTimeout),
                        "expected_message_id": scenario.messageId,
                        "latest_detail_ready_sequence": String(latestSample?.sequence ?? -1),
                        "latest_detail_ready_message_id": latestSample?.messageId ?? "",
                        "latest_state_active_tab": latestStateSnapshot?.activeTab ?? "",
                        "latest_state_visible_screen": latestStateSnapshot?.visibleScreen ?? "",
                    ])
                    throw PushGoWatchAutomationError.invalidArgument(
                        "detail cycle list return timeout for \(scenario.name) (list_return_timeout_seconds=\(String(format: "%.1f", listReturnTimeout)))"
                    )
                }
                let cycleMs = max(0, Int(Date().timeIntervalSince(startedAt) * 1_000))
                durations.append(cycleMs)
                let performance = PushGoAutomationPerformanceMonitor.shared.snapshot()
                peakResidentMemory = max(peakResidentMemory, performance.residentMemoryBytes ?? 0)
                peakMainThreadStallMs = max(peakMainThreadStallMs, performance.mainThreadMaxStallMilliseconds)
            }

            let endPerformance = PushGoAutomationPerformanceMonitor.shared.snapshot()
            let startResident = Int64(startPerformance.residentMemoryBytes ?? 0)
            let endResident = Int64(endPerformance.residentMemoryBytes ?? 0)
            let peakResident = Int64(peakResidentMemory)
            details["\(scenario.name)_first_cycle_ms"] = String(durations.first ?? -1)
            details["\(scenario.name)_avg_cycle_ms"] = String(durations.isEmpty ? -1 : durations.reduce(0, +) / durations.count)
            details["\(scenario.name)_max_cycle_ms"] = String(durations.max() ?? -1)
            details["\(scenario.name)_resident_memory_delta_bytes"] = String(endResident - startResident)
            details["\(scenario.name)_resident_memory_peak_delta_bytes"] = String(peakResident - startResident)
            details["\(scenario.name)_main_thread_stall_start_ms"] = String(startPerformance.mainThreadMaxStallMilliseconds)
            details["\(scenario.name)_main_thread_stall_end_ms"] = String(endPerformance.mainThreadMaxStallMilliseconds)
            details["\(scenario.name)_main_thread_stall_peak_ms"] = String(peakMainThreadStallMs)
            details["\(scenario.name)_detail_ready_advance_count"] = String(detailReadyAdvanceCount)
            details["\(scenario.name)_detail_ready_fallback_count"] = String(detailReadyFallbackCount)
        }

        writeEvent(type: "runtime.detail_cycles", command: nil, details: details)
    }

    private func runtimeTimeoutFromEnv(_ key: String, defaultValue: TimeInterval) -> TimeInterval {
        guard let rawValue = ProcessInfo.processInfo.environment[key],
              let parsedValue = Double(rawValue),
              parsedValue > 0
        else {
            return defaultValue
        }
        return parsedValue
    }

    private func waitForDetailReadySample(
        messageId: String,
        afterSequence: Int,
        timeout: TimeInterval
    ) async -> PushGoWatchAutomationDetailReadySample? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let sample = latestDetailReadySample,
               sample.sequence > afterSequence,
               sample.messageId == messageId {
                return sample
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return nil
    }

    private func updateGatewayConfig(request: PushGoWatchAutomationRequest, environment: AppEnvironment) async throws {
        let trimmedBaseURL = normalizedIdentifier(request.args?.baseURL) ?? environment.serverConfig?.normalizedBaseURL.absoluteString
        let trimmedToken = request.args?.token?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let baseURLString = trimmedBaseURL, let baseURL = URL(string: baseURLString) else {
            throw PushGoWatchAutomationError.invalidArgument("base_url")
        }
        let config = ServerConfig(
            id: environment.serverConfig?.id ?? UUID(),
            name: environment.serverConfig?.name,
            baseURL: baseURL,
            token: trimmedToken?.nilIfEmpty,
            notificationKeyMaterial: environment.currentNotificationMaterial,
            updatedAt: Date()
        )
        try await environment.updateServerConfig(config.normalized())
    }

    private func resetLocalState(environment: AppEnvironment) async throws {
        await WatchSessionBridge.shared.clearPersistentState()
        try await environment.dataStore.deleteAllMessages()
        let subscriptions = try await environment.dataStore.loadChannelSubscriptions(includeDeleted: false)
        for subscription in subscriptions {
            try await environment.dataStore.softDeleteChannelSubscription(
                gateway: subscription.gateway,
                channelId: subscription.channelId,
                deletedAt: Date()
            )
        }
        await environment.dataStore.saveCachedPushToken(nil, for: platformIdentifier)
        await environment.dataStore.saveCachedDeviceKey(nil, for: platformIdentifier)
        let defaultConfig = ServerConfig(
            baseURL: AppConstants.defaultServerURL ?? URL(string: AppConstants.defaultServerAddress)!,
            token: PushGoAutomationContext.gatewayToken
        ).normalized()
        try await environment.updateServerConfig(defaultConfig)
        environment.pendingMessageToOpen = nil
        environment.pendingEventToOpen = nil
        environment.pendingThingToOpen = nil
        await environment.refreshMessageCountsAndNotify()
        await environment.refreshChannelSubscriptions()
    }

    private func importFixture(request: PushGoWatchAutomationRequest, environment: AppEnvironment) async throws {
        let bundle = try loadFixtureBundle(request: request)
        try await applyFixtureBundle(
            bundle,
            sourcePath: normalizedIdentifier(request.args?.path),
            environment: environment
        )
    }

    private func seedMessages(request: PushGoWatchAutomationRequest, environment: AppEnvironment) async throws {
        let bundle = try loadFixtureBundle(request: request)
        guard !bundle.messages.isEmpty else {
            throw PushGoWatchAutomationError.invalidArgument("path")
        }
        try await upsertFixtureMessages(bundle.messages, environment: environment)
        await environment.refreshMessageCountsAndNotify()
        recordFixtureImport(
            path: normalizedIdentifier(request.args?.path),
            messageCount: bundle.messages.count,
            entityRecordCount: 0,
            subscriptionCount: 0
        )
    }

    private func seedEntityRecords(request: PushGoWatchAutomationRequest, environment: AppEnvironment) async throws {
        let bundle = try loadFixtureBundle(request: request)
        guard !bundle.entityRecords.isEmpty else {
            throw PushGoWatchAutomationError.invalidArgument("path")
        }
        try await upsertFixtureMessages(bundle.entityRecords, environment: environment)
        await environment.refreshMessageCountsAndNotify()
        recordFixtureImport(
            path: normalizedIdentifier(request.args?.path),
            messageCount: 0,
            entityRecordCount: bundle.entityRecords.count,
            subscriptionCount: 0
        )
    }

    private func seedSubscriptions(request: PushGoWatchAutomationRequest, environment: AppEnvironment) async throws {
        let bundle = try loadFixtureBundle(request: request)
        guard !bundle.channelSubscriptions.isEmpty else {
            throw PushGoWatchAutomationError.invalidArgument("path")
        }
        try await applyFixtureSubscriptions(bundle.channelSubscriptions, environment: environment)
        await environment.refreshChannelSubscriptions()
        recordFixtureImport(
            path: normalizedIdentifier(request.args?.path),
            messageCount: 0,
            entityRecordCount: 0,
            subscriptionCount: bundle.channelSubscriptions.count
        )
    }

    private func loadFixtureBundle(request: PushGoWatchAutomationRequest) throws -> PushGoWatchAutomationFixtureBundle {
        guard let path = normalizedIdentifier(request.args?.path) else {
            throw PushGoWatchAutomationError.missingArgument("path")
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(PushGoWatchAutomationFixtureBundle.self, from: data)
    }

    private func applyFixtureBundle(
        _ bundle: PushGoWatchAutomationFixtureBundle,
        sourcePath: String?,
        environment: AppEnvironment
    ) async throws {
        if !bundle.messages.isEmpty {
            try await upsertFixtureMessages(bundle.messages, environment: environment)
        }
        if !bundle.entityRecords.isEmpty {
            try await upsertFixtureMessages(bundle.entityRecords, environment: environment)
        }
        if !bundle.channelSubscriptions.isEmpty {
            try await applyFixtureSubscriptions(bundle.channelSubscriptions, environment: environment)
        }
        await environment.refreshMessageCountsAndNotify()
        await environment.refreshChannelSubscriptions()
        recordFixtureImport(
            path: sourcePath,
            messageCount: bundle.messages.count,
            entityRecordCount: bundle.entityRecords.count,
            subscriptionCount: bundle.channelSubscriptions.count
        )
    }

    private func upsertFixtureMessages(
        _ fixtures: [PushGoWatchAutomationFixtureMessage],
        environment: AppEnvironment
    ) async throws {
        var messages: [WatchLightMessage] = []
        var events: [WatchLightEvent] = []
        var things: [WatchLightThing] = []

        for fixture in fixtures.sorted(by: { $0.receivedAt > $1.receivedAt }) {
            guard let payload = fixture.toWatchLightPayload() else {
                continue
            }
            switch payload {
            case let .message(message):
                messages.append(message)
            case let .event(event):
                events.append(event)
            case let .thing(thing):
                things.append(thing)
            }
        }

        guard !messages.isEmpty || !events.isEmpty || !things.isEmpty else {
            return
        }

        let exportedAt = Date()
        let snapshot = WatchMirrorSnapshot(
            generation: Int64(exportedAt.timeIntervalSince1970 * 1_000),
            mode: .standalone,
            messages: messages,
            events: events,
            things: things,
            exportedAt: exportedAt,
            contentDigest: WatchMirrorSnapshot.contentDigest(
                messages: messages,
                events: events,
                things: things
            )
        )
        try await environment.dataStore.mergeWatchMirrorSnapshot(snapshot)
    }

    private func applyFixtureSubscriptions(
        _ subscriptions: [PushGoWatchAutomationFixtureSubscription],
        environment: AppEnvironment
    ) async throws {
        let fallbackGateway = (environment.serverConfig?.normalized() ?? ServerConfig(
            baseURL: AppConstants.defaultServerURL ?? URL(string: AppConstants.defaultServerAddress)!,
            token: PushGoAutomationContext.gatewayToken
        )).gatewayKey
        for subscription in subscriptions {
            let gateway = normalizedIdentifier(subscription.gateway) ?? fallbackGateway
            let displayName = normalizedIdentifier(subscription.displayName) ?? subscription.channelId
            try await environment.dataStore.upsertChannelSubscription(
                gateway: gateway,
                channelId: subscription.channelId,
                displayName: displayName,
                password: subscription.password,
                lastSyncedAt: subscription.lastSyncedAt,
                updatedAt: subscription.updatedAt ?? Date(),
                isDeleted: false,
                deletedAt: nil
            )
        }
    }

    private func recordFixtureImport(
        path: String?,
        messageCount: Int,
        entityRecordCount: Int,
        subscriptionCount: Int
    ) {
        writeEvent(type: "fixture.imported", command: nil, details: [
            "path": path ?? "",
            "message_count": String(messageCount),
            "entity_record_count": String(entityRecordCount),
            "subscription_count": String(subscriptionCount),
        ])
    }

    private func writeResponse(ok: Bool, error: String?, environment: AppEnvironment) async {
        let baseState: PushGoWatchAutomationState
        if let latestState {
            baseState = latestState
        } else {
            baseState = await fallbackState(environment: environment)
        }
        let state = await enrichState(baseState, environment: environment)
        latestState = state
        writeJSON(
            PushGoWatchAutomationResponse(
                id: request?.id,
                ok: ok,
                platform: platformIdentifier,
                state: state,
                error: error
            ),
            to: responseURL
        )
    }

    private func fallbackState(environment: AppEnvironment) async -> PushGoWatchAutomationState {
        let activeTab = environment.activeMainTab.automationIdentifier
        let visibleScreen = environment.pendingMessageToOpen != nil
            ? "screen.message.detail"
            : environment.activeMainTab.automationVisibleScreen
        let baseState = PushGoWatchAutomationState(
            platform: platformIdentifier,
            buildMode: "debug",
            activeTab: activeTab,
            visibleScreen: visibleScreen,
            openedMessageId: environment.pendingMessageToOpen,
            openedMessageDecryptionState: nil,
            openedEntityType: environment.pendingEventToOpen != nil ? "event" : (environment.pendingThingToOpen != nil ? "thing" : nil),
            openedEntityId: normalizedIdentifier(environment.pendingEventToOpen ?? environment.pendingThingToOpen),
            pendingMessageId: environment.pendingMessageToOpen,
            pendingEventId: normalizedIdentifier(environment.pendingEventToOpen),
            pendingThingId: normalizedIdentifier(environment.pendingThingToOpen),
            unreadMessageCount: environment.unreadMessageCount,
            totalMessageCount: environment.totalMessageCount,
            eventCount: 0,
            thingCount: 0,
            gatewayBaseURL: environment.serverConfig?.normalizedBaseURL.absoluteString,
            gatewayTokenPresent: normalizedIdentifier(environment.serverConfig?.token) != nil,
            providerMode: "provider",
            providerTokenPresent: false,
            deviceKeyPresent: false,
            privateRoute: "idle",
            privateTransport: "watch",
            privateStage: "idle",
            privateDetail: nil,
            ackPendingCount: 0,
            channelCount: environment.channelSubscriptions.count,
            localStoreMode: localStoreMode(environment.dataStore.storageState),
            localStoreReason: normalizedIdentifier(environment.dataStore.storageState.reason),
            runtimeErrorCount: runtimeErrorCount,
            latestRuntimeErrorSource: latestRuntimeError?.source,
            latestRuntimeErrorCategory: latestRuntimeError?.category,
            latestRuntimeErrorCode: latestRuntimeError?.code,
            latestRuntimeErrorMessage: latestRuntimeError?.message,
            latestRuntimeErrorTimestamp: latestRuntimeError?.timestamp,
            residentMemoryBytes: nil,
            mainThreadMaxStallMilliseconds: 0
        )
        return await enrichState(baseState, environment: environment)
    }

    func recordRuntimeError(
        source: String,
        category: String = "runtime",
        code: String? = nil,
        message: String
    ) {
        configureFromProcessEnvironment()
        let snapshot = PushGoWatchAutomationRuntimeError(
            source: normalizedIdentifier(source) ?? "unknown",
            category: normalizedIdentifier(category) ?? "runtime",
            code: normalizedIdentifier(code),
            message: normalizedIdentifier(message) ?? "Unknown runtime error",
            timestamp: ISO8601DateFormatter().string(from: Date())
        )
        latestRuntimeError = snapshot
        runtimeErrorCount += 1
        writeTraceRecord(
            kind: "span.error",
            traceId: activeTrace?.traceId ?? UUID().uuidString.lowercased(),
            spanId: activeTrace?.spanId ?? UUID().uuidString.lowercased(),
            parentSpanId: nil,
            requestId: activeTrace?.requestId,
            domain: snapshot.category,
            operation: snapshot.source,
            status: "error",
            durationMs: nil,
            attributes: ["count": String(runtimeErrorCount)],
            errorCode: snapshot.code,
            errorMessage: snapshot.message
        )
        writeEvent(type: "runtime.error", command: nil, details: [
            "source": snapshot.source,
            "category": snapshot.category,
            "code": snapshot.code ?? "",
            "message": snapshot.message,
            "timestamp": snapshot.timestamp,
            "count": String(runtimeErrorCount),
        ])
    }

    private func writeEvent(type: String, command: String?, details: [String: String]) {
        appendJSONL(
            PushGoWatchAutomationEvent(
                timestamp: ISO8601DateFormatter().string(from: Date()),
                platform: platformIdentifier,
                type: type,
                command: command,
                details: details
            ),
            to: eventsURL
        )
        writeTraceAnnotation(type: type, command: command, details: details)
    }

    private func startCommandTrace(_ request: PushGoWatchAutomationRequest) {
        let requestId = normalizedIdentifier(request.id)
        let traceId = requestId ?? UUID().uuidString.lowercased()
        let spanId = UUID().uuidString.lowercased()
        activeTrace = PushGoWatchActiveTrace(
            traceId: traceId,
            spanId: spanId,
            requestId: requestId,
            command: request.name,
            startedAt: Date()
        )
        writeTraceRecord(
            kind: "span.start",
            traceId: traceId,
            spanId: spanId,
            parentSpanId: nil,
            requestId: requestId,
            domain: "automation",
            operation: "command",
            status: nil,
            durationMs: nil,
            attributes: ["command": request.name],
            errorCode: nil,
            errorMessage: nil
        )
    }

    private func finishCommandTrace(status: String, errorMessage: String?) {
        guard let activeTrace else { return }
        let durationMs = max(0, Int(Date().timeIntervalSince(activeTrace.startedAt) * 1000))
        writeTraceRecord(
            kind: status == "error" ? "span.error" : "span.end",
            traceId: activeTrace.traceId,
            spanId: activeTrace.spanId,
            parentSpanId: nil,
            requestId: activeTrace.requestId,
            domain: "automation",
            operation: "command",
            status: status,
            durationMs: durationMs,
            attributes: ["command": activeTrace.command],
            errorCode: nil,
            errorMessage: errorMessage
        )
        self.activeTrace = nil
    }

    private func writeTraceAnnotation(type: String, command: String?, details: [String: String]) {
        let descriptor = traceDescriptor(forEventType: type)
        var attributes = details
        if let command {
            attributes["command"] = command
        }
        writeTraceRecord(
            kind: "annotation",
            traceId: activeTrace?.traceId ?? UUID().uuidString.lowercased(),
            spanId: UUID().uuidString.lowercased(),
            parentSpanId: activeTrace?.spanId,
            requestId: activeTrace?.requestId,
            domain: descriptor.domain,
            operation: descriptor.operation,
            status: nil,
            durationMs: nil,
            attributes: attributes,
            errorCode: nil,
            errorMessage: nil
        )
    }

    private func writeTraceRecord(
        kind: String,
        traceId: String,
        spanId: String,
        parentSpanId: String?,
        requestId: String?,
        domain: String,
        operation: String,
        status: String?,
        durationMs: Int?,
        attributes: [String: String],
        errorCode: String?,
        errorMessage: String?
    ) {
        appendJSONL(
            PushGoWatchAutomationTraceRecord(
                timestamp: ISO8601DateFormatter().string(from: Date()),
                platform: platformIdentifier,
                kind: kind,
                traceId: traceId,
                spanId: spanId,
                parentSpanId: parentSpanId,
                requestId: requestId,
                sessionId: stateURL?.deletingLastPathComponent().lastPathComponent,
                domain: domain,
                operation: operation,
                status: status,
                durationMs: durationMs,
                attributes: attributes,
                errorCode: errorCode,
                errorMessage: errorMessage
            ),
            to: traceURL
        )
    }

    private func traceDescriptor(forEventType eventType: String) -> (domain: String, operation: String) {
        switch eventType {
        case "command.received", "command.completed", "command.failed":
            return ("automation", "command")
        case "state.updated":
            return ("ui", "state.updated")
        case "entity.opened":
            return ("navigation", "entity.opened")
        case "settings.changed":
            return ("settings", "changed")
        case "badge.updated":
            return ("ui", "badge.updated")
        case "runtime.error":
            return ("runtime", "error")
        default:
            let parts = eventType.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: true)
            if parts.count == 2 {
                return (String(parts[0]), String(parts[1]))
            }
            return ("automation", eventType)
        }
    }

    private func writeJSON<T: Encodable>(_ value: T, to url: URL?) {
        guard let url else { return }
        if let data = try? JSONEncoder().encode(value) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url)
        }
    }

    private func appendJSONL<T: Encodable>(_ value: T, to url: URL?) {
        guard let url else { return }
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: url.path) {
            if let handle = try? FileHandle(forWritingTo: url) {
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data + Data([0x0A]))
                try? handle.close()
            }
        } else {
            try? (data + Data([0x0A])).write(to: url)
        }
    }

    private func fileURL(for envName: String) -> URL? {
        normalizedIdentifier(ProcessInfo.processInfo.environment[envName]).map { URL(fileURLWithPath: $0) }
    }

    private func normalizedIdentifier(_ raw: String?) -> String? {
        let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? nil : value
    }

    private func projectionDestination(for entityType: String) -> String {
        switch entityType {
        case "thing":
            return "thing_head"
        case "event":
            return "event_head"
        default:
            return "message_head"
        }
    }

    private func localStoreMode(_ state: LocalDataStore.StorageState) -> String {
        switch state.mode {
        case .persistent:
            return "persistent"
        case .unavailable:
            return "unavailable"
        }
    }

    private func automationErrorMessage(for error: Error) -> String {
        if let automationError = error as? PushGoWatchAutomationError {
            return automationError.description
        }
        return error.localizedDescription
    }
}

private enum PushGoWatchAutomationError: Error, CustomStringConvertible {
    case missingArgument(String)
    case invalidArgument(String)
    case unsupportedCommand(String)

    var description: String {
        switch self {
        case let .missingArgument(name):
            return "Missing automation argument: \(name)"
        case let .invalidArgument(name):
            return "Invalid automation argument: \(name)"
        case let .unsupportedCommand(name):
            return "Unsupported automation command: \(name)"
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

extension Notification.Name {
    static let pushgoWatchAutomationSelectTab = Notification.Name("pushgo.watch.automation.select-tab")
}
#endif
