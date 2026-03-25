import Foundation
import SwiftUI

struct RootView: View {
    @Environment(AppEnvironment.self) private var environment: AppEnvironment

    var body: some View {
        mainContent
#if os(iOS)
            .sheet(
                item: Binding(
                    get: { environment.pendingSettingsPresentation },
                    set: { presentation in
                        environment.pendingSettingsPresentation = presentation
                    }
                )
            ) { presentation in
                SettingsView(
                    embedInNavigationContainer: true,
                    openDecryptionOnAppear: presentation == .decryption
                )
            }
#endif
    }

    @ViewBuilder
    private var mainContent: some View {
        #if os(watchOS)
        EmptyView()
        #else
        MainTabContainerView()
        #endif
    }
}

#if DEBUG && !os(watchOS)
private enum PushGoAutomationEnvironment {
    static let request = "PUSHGO_AUTOMATION_REQUEST"
    static let responsePath = "PUSHGO_AUTOMATION_RESPONSE_PATH"
    static let statePath = "PUSHGO_AUTOMATION_STATE_PATH"
    static let eventsPath = "PUSHGO_AUTOMATION_EVENTS_PATH"
    static let tracePath = "PUSHGO_AUTOMATION_TRACE_PATH"
    static let startupFixturePath = "PUSHGO_AUTOMATION_STARTUP_FIXTURE_PATH"
    static let startupFixtureBase64 = "PUSHGO_AUTOMATION_STARTUP_FIXTURE_BASE64"
}

private struct PushGoAutomationRequest: Decodable {
    struct Args: Decodable {
        let tab: String?
        let messageId: String?
        let entityType: String?
        let entityId: String?
        let path: String?
        let page: String?
        let enabled: String?
        let mode: String?
        let baseURL: String?
        let token: String?
        let notificationRequestId: String?
        let key: String?
        let encoding: String?

        private enum CodingKeys: String, CodingKey {
            case tab
            case messageId = "message_id"
            case entityType = "entity_type"
            case entityId = "entity_id"
            case path
            case page
            case enabled
            case mode
            case baseURL = "base_url"
            case token
            case notificationRequestId = "notification_request_id"
            case key
            case encoding
        }
    }

    let id: String?
    let plane: String?
    let name: String
    let args: Args?
}

struct PushGoAutomationState: Encodable, Equatable {
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
    let messagePageEnabled: Bool
    let eventPageEnabled: Bool
    let thingPageEnabled: Bool
    let notificationKeyConfigured: Bool
    let notificationKeyEncoding: String?
    let gatewayBaseURL: String?
    let gatewayTokenPresent: Bool
    let watchMode: String?
    let watchCompanionAvailable: Bool
    let providerMode: String
    let providerTokenPresent: Bool
    let providerDeviceKeyPresent: Bool
    let privateRoute: String
    let privateTransport: String
    let privateStage: String
    let privateDetail: String?
    let ackPendingCount: Int
    let channelCount: Int
    let lastNotificationAction: String?
    let lastNotificationTarget: String?
    let lastFixtureImportPath: String?
    let lastFixtureImportMessageCount: Int
    let lastFixtureImportEntityRecordCount: Int
    let lastFixtureImportSubscriptionCount: Int
    let localStoreMode: String
    let localStoreReason: String?
    let runtimeErrorCount: Int
    let latestRuntimeErrorSource: String?
    let latestRuntimeErrorCategory: String?
    let latestRuntimeErrorCode: String?
    let latestRuntimeErrorMessage: String?
    let latestRuntimeErrorTimestamp: String?

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
        case messagePageEnabled = "message_page_enabled"
        case eventPageEnabled = "event_page_enabled"
        case thingPageEnabled = "thing_page_enabled"
        case notificationKeyConfigured = "notification_key_configured"
        case notificationKeyEncoding = "notification_key_encoding"
        case gatewayBaseURL = "gateway_base_url"
        case gatewayTokenPresent = "gateway_token_present"
        case watchMode = "watch_mode"
        case watchCompanionAvailable = "watch_companion_available"
        case providerMode = "provider_mode"
        case providerTokenPresent = "provider_token_present"
        case providerDeviceKeyPresent = "provider_device_key_present"
        case privateRoute = "private_route"
        case privateTransport = "private_transport"
        case privateStage = "private_stage"
        case privateDetail = "private_detail"
        case ackPendingCount = "ack_pending_count"
        case channelCount = "channel_count"
        case lastNotificationAction = "last_notification_action"
        case lastNotificationTarget = "last_notification_target"
        case lastFixtureImportPath = "last_fixture_import_path"
        case lastFixtureImportMessageCount = "last_fixture_import_message_count"
        case lastFixtureImportEntityRecordCount = "last_fixture_import_entity_record_count"
        case lastFixtureImportSubscriptionCount = "last_fixture_import_subscription_count"
        case localStoreMode = "local_store_mode"
        case localStoreReason = "local_store_reason"
        case runtimeErrorCount = "runtime_error_count"
        case latestRuntimeErrorSource = "latest_runtime_error_source"
        case latestRuntimeErrorCategory = "latest_runtime_error_category"
        case latestRuntimeErrorCode = "latest_runtime_error_code"
        case latestRuntimeErrorMessage = "latest_runtime_error_message"
        case latestRuntimeErrorTimestamp = "latest_runtime_error_timestamp"
    }
}

private struct PushGoAutomationRuntimeError: Equatable {
    let source: String
    let category: String
    let code: String?
    let message: String
    let timestamp: String
}

private struct PushGoAutomationResponse: Encodable {
    let id: String?
    let ok: Bool
    let platform: String
    let state: PushGoAutomationState?
    let error: String?
}

private struct PushGoAutomationEvent: Encodable {
    let timestamp: String
    let platform: String
    let type: String
    let command: String?
    let details: [String: String]
}

private struct PushGoAutomationTraceRecord: Encodable {
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

private struct PushGoAutomationActiveTrace {
    let traceId: String
    let spanId: String
    let requestId: String?
    let command: String
    let startedAt: Date
}

private struct PushGoAutomationFixtureBundle: Decodable {
    let messages: [PushGoAutomationFixtureMessage]
    let entityRecords: [PushGoAutomationFixtureMessage]
    let channelSubscriptions: [PushGoAutomationFixtureSubscription]

    private enum CodingKeys: String, CodingKey {
        case messages
        case entityRecords = "entity_records"
        case channelSubscriptions = "channel_subscriptions"
    }

    init(from decoder: Decoder) throws {
        if let singleValue = try? decoder.singleValueContainer(),
           let messages = try? singleValue.decode([PushGoAutomationFixtureMessage].self) {
            self.messages = messages
            entityRecords = []
            channelSubscriptions = []
            return
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        messages = try container.decodeIfPresent([PushGoAutomationFixtureMessage].self, forKey: .messages) ?? []
        entityRecords = try container.decodeIfPresent([PushGoAutomationFixtureMessage].self, forKey: .entityRecords) ?? []
        channelSubscriptions = try container.decodeIfPresent(
            [PushGoAutomationFixtureSubscription].self,
            forKey: .channelSubscriptions
        ) ?? []
    }
}

private struct PushGoAutomationFixtureMessage: Decodable {
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
        } else if let rawId = try? container.decode(String.self, forKey: .id), let uuid = UUID(uuidString: rawId) {
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

    func toPushMessage() -> PushMessage {
        var payload = rawPayload
        if let decryptionState,
           payload["decryption_state"] == nil
        {
            payload["decryption_state"] = AnyCodable(decryptionState.rawValue)
        }
        return PushMessage(
            id: id,
            messageId: messageId,
            title: title,
            body: body,
            channel: channel,
            url: url,
            isRead: isRead,
            receivedAt: receivedAt,
            rawPayload: payload,
            status: status,
            decryptionState: decryptionState
        )
    }
}

private struct PushGoAutomationFixtureSubscription: Decodable {
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
final class PushGoAutomationRuntime {
    static let shared = PushGoAutomationRuntime()

    private var configured = false
    private var didExecuteStartupRequest = false
    private var didImportStartupFixture = false
    private var request: PushGoAutomationRequest?
    private var requestDecodeError: String?
    private var responseURL: URL?
    private var stateURL: URL?
    private var eventsURL: URL?
    private var traceURL: URL?
    private var startupFixturePath: String?
    private var startupFixtureBase64: String?
    private var latestState: PushGoAutomationState?
    private var lastNotificationAction: String?
    private var lastNotificationTarget: String?
    private var lastFixtureImportPath: String?
    private var lastFixtureImportMessageCount = 0
    private var lastFixtureImportEntityRecordCount = 0
    private var lastFixtureImportSubscriptionCount = 0
    private var runtimeErrorCount = 0
    private var latestRuntimeError: PushGoAutomationRuntimeError?
    private var activeTrace: PushGoAutomationActiveTrace?

    private init() {}

    func configureFromProcessEnvironment() {
        guard !configured else { return }
        configured = true
        responseURL = fileURL(for: PushGoAutomationEnvironment.responsePath)
        stateURL = fileURL(for: PushGoAutomationEnvironment.statePath)
        eventsURL = fileURL(for: PushGoAutomationEnvironment.eventsPath)
        traceURL = fileURL(for: PushGoAutomationEnvironment.tracePath)
        startupFixturePath = normalizedIdentifier(
            ProcessInfo.processInfo.environment[PushGoAutomationEnvironment.startupFixturePath]
        )
        startupFixtureBase64 = normalizedIdentifier(
            ProcessInfo.processInfo.environment[PushGoAutomationEnvironment.startupFixtureBase64]
        )

        guard let rawRequest = ProcessInfo.processInfo.environment[PushGoAutomationEnvironment.request]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !rawRequest.isEmpty
        else {
            return
        }

        do {
            request = try JSONDecoder().decode(PushGoAutomationRequest.self, from: Data(rawRequest.utf8))
        } catch {
            requestDecodeError = "Failed to decode automation request: \(error.localizedDescription)"
        }
    }

    func recordBootstrapCheckpoint(_ source: String, details: [String: String] = [:]) {
        configureFromProcessEnvironment()
        var payload = details
        payload["source"] = source
        payload["automation_active"] = PushGoAutomationContext.isActive ? "true" : "false"
        payload["force_foreground"] = PushGoAutomationContext.forceForegroundApp ? "true" : "false"
        writeEvent(type: "runtime.bootstrap", command: nil, details: payload)
    }

    func publishState(
        environment: AppEnvironment,
        activeTab: String,
        visibleScreen: String,
        openedMessageId: String? = nil,
        openedMessageDecryptionState: String? = nil,
        openedEntityType: String? = nil,
        openedEntityId: String? = nil
    ) {
        configureFromProcessEnvironment()
        let previousState = latestState
        let state = PushGoAutomationState(
            platform: platformIdentifier,
            buildMode: "debug",
            activeTab: activeTab,
            visibleScreen: visibleScreen,
            openedMessageId: openedMessageId,
            openedMessageDecryptionState: openedMessageDecryptionState,
            openedEntityType: openedEntityType,
            openedEntityId: openedEntityId,
            pendingMessageId: environment.pendingMessageToOpen?.uuidString,
            pendingEventId: normalizedIdentifier(environment.pendingEventToOpen),
            pendingThingId: normalizedIdentifier(environment.pendingThingToOpen),
            unreadMessageCount: environment.unreadMessageCount,
            totalMessageCount: environment.totalMessageCount,
            eventCount: 0,
            thingCount: 0,
            messagePageEnabled: environment.isMessagePageEnabled,
            eventPageEnabled: environment.isEventPageEnabled,
            thingPageEnabled: environment.isThingPageEnabled,
            notificationKeyConfigured: environment.currentNotificationMaterial?.isConfigured == true,
            notificationKeyEncoding: nil,
            gatewayBaseURL: environment.serverConfig?.normalizedBaseURL.absoluteString,
            gatewayTokenPresent: normalizedIdentifier(environment.serverConfig?.token) != nil,
            watchMode: watchModeIdentifier(environment: environment),
            watchCompanionAvailable: watchCompanionAvailable(environment: environment),
            providerMode: providerMode,
            providerTokenPresent: false,
            providerDeviceKeyPresent: false,
            privateRoute: "idle",
            privateTransport: providerTransport,
            privateStage: "idle",
            privateDetail: nil,
            ackPendingCount: 0,
            channelCount: environment.channelSubscriptions.count,
            lastNotificationAction: lastNotificationAction,
            lastNotificationTarget: lastNotificationTarget,
            lastFixtureImportPath: lastFixtureImportPath,
            lastFixtureImportMessageCount: lastFixtureImportMessageCount,
            lastFixtureImportEntityRecordCount: lastFixtureImportEntityRecordCount,
            lastFixtureImportSubscriptionCount: lastFixtureImportSubscriptionCount,
            localStoreMode: localStoreMode(environment.dataStore.storageState),
            localStoreReason: normalizedIdentifier(environment.dataStore.storageState.reason),
            runtimeErrorCount: runtimeErrorCount,
            latestRuntimeErrorSource: latestRuntimeError?.source,
            latestRuntimeErrorCategory: latestRuntimeError?.category,
            latestRuntimeErrorCode: latestRuntimeError?.code,
            latestRuntimeErrorMessage: latestRuntimeError?.message,
            latestRuntimeErrorTimestamp: latestRuntimeError?.timestamp
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
            case "snapshot.get":
                break
            case "debug.dump_state":
                break
            case "nav.switch_tab":
                guard let tab = normalizedIdentifier(request.args?.tab) else {
                    throw PushGoAutomationError.missingArgument("tab")
                }
                try? await Task.sleep(nanoseconds: 300_000_000)
                NotificationCenter.default.post(name: .pushgoAutomationSelectTab, object: tab)
            case "message.open":
                guard let messageId = normalizedIdentifier(request.args?.messageId) else {
                    throw PushGoAutomationError.missingArgument("message_id")
                }
                await environment.handleNotificationOpen(messageId: messageId)
            case "entity.open":
                guard let entityType = normalizedIdentifier(request.args?.entityType) else {
                    throw PushGoAutomationError.missingArgument("entity_type")
                }
                guard let entityId = normalizedIdentifier(request.args?.entityId) else {
                    throw PushGoAutomationError.missingArgument("entity_id")
                }
                await environment.handleNotificationOpen(entityType: entityType, entityId: entityId)
            case "settings.set_page_visibility":
                guard let page = normalizedIdentifier(request.args?.page) else {
                    throw PushGoAutomationError.missingArgument("page")
                }
                guard let enabled = parseBoolean(request.args?.enabled) else {
                    throw PushGoAutomationError.invalidArgument("enabled")
                }
                try? await Task.sleep(nanoseconds: 600_000_000)
                try applyPageVisibility(page: page, enabled: enabled, environment: environment)
                let pageVisibilityApplied = await waitForAutomationState(environment: environment, timeout: 2.0) { state in
                    switch page {
                    case "message", "messages":
                        state.messagePageEnabled == enabled
                    case "event", "events":
                        state.eventPageEnabled == enabled
                    case "thing", "things":
                        state.thingPageEnabled == enabled
                    default:
                        false
                    }
                }
                if !pageVisibilityApplied {
                    try applyPageVisibility(page: page, enabled: enabled, environment: environment)
                    _ = await waitForAutomationState(environment: environment, timeout: 2.0) { state in
                        switch page {
                        case "message", "messages":
                            state.messagePageEnabled == enabled
                        case "event", "events":
                            state.eventPageEnabled == enabled
                        case "thing", "things":
                            state.thingPageEnabled == enabled
                        default:
                            false
                        }
                    }
                }
            case "settings.open_decryption":
                try? await Task.sleep(nanoseconds: 600_000_000)
                #if os(iOS)
                environment.pendingSettingsPresentation = .decryption
                #else
                NotificationCenter.default.post(name: .pushgoAutomationSelectTab, object: "settings")
                _ = await waitForAutomationState(environment: environment, timeout: 2.5) { state in
                    state.activeTab == "settings" || state.visibleScreen == "screen.settings"
                }
                try? await Task.sleep(nanoseconds: 300_000_000)
                NotificationCenter.default.post(name: .pushgoAutomationOpenSettingsDecryption, object: nil)
                #endif
                _ = await waitForAutomationState(environment: environment, timeout: 2.5) { state in
                    state.visibleScreen == "screen.settings.decryption"
                }
            case "settings.set_decryption_key":
                try await updateNotificationKey(request: request, environment: environment)
            case "watch.set_mode":
                guard let mode = normalizedIdentifier(request.args?.mode) else {
                    throw PushGoAutomationError.missingArgument("mode")
                }
                try await updateWatchMode(mode: mode, environment: environment)
            case "gateway.set_server":
                try await updateGatewayConfig(request: request, environment: environment)
            case "private.trigger_wakeup":
                await triggerPrivateWakeup(environment: environment)
            case "private.drain_acks":
                _ = await environment.drainPrivateWakeupAckOutboxForSystemWake()
            case "notification.open":
                try await handleNotificationOpen(request: request, environment: environment)
            case "notification.mark_read":
                try await handleNotificationAction(request: request, action: .markRead, environment: environment)
            case "notification.delete":
                try await handleNotificationAction(request: request, action: .delete, environment: environment)
            case "notification.copy":
                try await handleNotificationAction(request: request, action: .copy, environment: environment)
            case "fixture.import":
                try await importFixture(request: request, environment: environment)
            case "fixture.seed_messages":
                try await seedMessages(request: request, environment: environment)
            case "fixture.seed_entity_records":
                try await seedEntityRecords(request: request, environment: environment)
            case "fixture.seed_subscriptions":
                try await seedSubscriptions(request: request, environment: environment)
            case "debug.reset_local_state", "fixture.reset_local_state":
                try await resetLocalState(environment: environment)
            default:
                throw PushGoAutomationError.unsupportedCommand(request.name)
            }

            await waitForStatePropagation(after: request.name)
            writeEvent(type: "command.completed", command: request.name, details: [:])
            endCommandTrace(status: "ok", attributes: [:], errorCode: nil, errorMessage: nil)
            await writeResponse(ok: true, error: nil, environment: environment)
        } catch {
            writeEvent(
                type: "command.failed",
                command: request.name,
                details: ["error": error.localizedDescription]
            )
            endCommandTrace(
                status: "error",
                attributes: [:],
                errorCode: nil,
                errorMessage: error.localizedDescription
            )
            await writeResponse(ok: false, error: error.localizedDescription, environment: environment)
        }
    }

    func importStartupFixtureIfNeeded(environment: AppEnvironment) async {
        configureFromProcessEnvironment()
        guard !didImportStartupFixture else { return }
        didImportStartupFixture = true
        guard startupFixturePath != nil || startupFixtureBase64 != nil else { return }

        do {
            let bundle = try loadStartupFixtureBundle()
            try await applyFixtureBundle(
                bundle,
                sourcePath: startupFixturePath,
                environment: environment
            )
        } catch {
            recordRuntimeError(
                source: "automation",
                category: "fixture_import",
                code: "startup_fixture_import_failed",
                message: error.localizedDescription
            )
        }
    }

    private var platformIdentifier: String {
        #if os(iOS)
        return "ios"
        #elseif os(macOS)
        return "macos"
        #else
        return "apple"
        #endif
    }

    private func writeResponse(ok: Bool, error: String?, environment: AppEnvironment) async {
        let previousState = latestState
        let state = await currentState(environment: environment)
        latestState = state
        writeJSON(state, to: stateURL)
        writeDerivedEvents(previous: previousState, current: state)
        let response = PushGoAutomationResponse(
            id: request?.id,
            ok: ok,
            platform: platformIdentifier,
            state: state,
            error: error
        )
        writeJSON(response, to: responseURL)
    }

    private func currentState(environment: AppEnvironment) async -> PushGoAutomationState {
        let refreshed = await fallbackState(environment: environment)
        guard let latestState else {
            return refreshed
        }
        let openedMessageId = latestState.openedMessageId ?? refreshed.openedMessageId
        let openedMessageDecryptionState = await resolvedAutomationMessageDecryptionState(
            messageId: openedMessageId,
            environment: environment
        )
        return PushGoAutomationState(
            platform: latestState.platform,
            buildMode: latestState.buildMode,
            activeTab: latestState.activeTab,
            visibleScreen: latestState.visibleScreen,
            openedMessageId: openedMessageId,
            openedMessageDecryptionState: openedMessageDecryptionState,
            openedEntityType: latestState.openedEntityType,
            openedEntityId: latestState.openedEntityId,
            pendingMessageId: refreshed.pendingMessageId,
            pendingEventId: refreshed.pendingEventId,
            pendingThingId: refreshed.pendingThingId,
            unreadMessageCount: refreshed.unreadMessageCount,
            totalMessageCount: refreshed.totalMessageCount,
            eventCount: refreshed.eventCount,
            thingCount: refreshed.thingCount,
            messagePageEnabled: refreshed.messagePageEnabled,
            eventPageEnabled: refreshed.eventPageEnabled,
            thingPageEnabled: refreshed.thingPageEnabled,
            notificationKeyConfigured: refreshed.notificationKeyConfigured,
            notificationKeyEncoding: refreshed.notificationKeyEncoding,
            gatewayBaseURL: refreshed.gatewayBaseURL,
            gatewayTokenPresent: refreshed.gatewayTokenPresent,
            watchMode: refreshed.watchMode,
            watchCompanionAvailable: refreshed.watchCompanionAvailable,
            providerMode: refreshed.providerMode,
            providerTokenPresent: refreshed.providerTokenPresent,
            providerDeviceKeyPresent: refreshed.providerDeviceKeyPresent,
            privateRoute: refreshed.privateRoute,
            privateTransport: refreshed.privateTransport,
            privateStage: refreshed.privateStage,
            privateDetail: refreshed.privateDetail,
            ackPendingCount: refreshed.ackPendingCount,
            channelCount: refreshed.channelCount,
            lastNotificationAction: refreshed.lastNotificationAction,
            lastNotificationTarget: refreshed.lastNotificationTarget,
            lastFixtureImportPath: refreshed.lastFixtureImportPath,
            lastFixtureImportMessageCount: refreshed.lastFixtureImportMessageCount,
            lastFixtureImportEntityRecordCount: refreshed.lastFixtureImportEntityRecordCount,
            lastFixtureImportSubscriptionCount: refreshed.lastFixtureImportSubscriptionCount,
            localStoreMode: refreshed.localStoreMode,
            localStoreReason: refreshed.localStoreReason,
            runtimeErrorCount: refreshed.runtimeErrorCount,
            latestRuntimeErrorSource: refreshed.latestRuntimeErrorSource,
            latestRuntimeErrorCategory: refreshed.latestRuntimeErrorCategory,
            latestRuntimeErrorCode: refreshed.latestRuntimeErrorCode,
            latestRuntimeErrorMessage: refreshed.latestRuntimeErrorMessage,
            latestRuntimeErrorTimestamp: refreshed.latestRuntimeErrorTimestamp
        )
    }

    private func waitForStatePropagation(after commandName: String) async {
        await Task.yield()
        switch commandName {
        case "nav.switch_tab", "message.open", "entity.open", "settings.open_decryption", "settings.set_page_visibility", "settings.set_decryption_key", "watch.set_mode":
            try? await Task.sleep(nanoseconds: 200_000_000)
            await Task.yield()
        default:
            break
        }
    }

    private func waitForAutomationState(
        environment: AppEnvironment,
        timeout: TimeInterval,
        predicate: @escaping (PushGoAutomationState) -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let state = await currentState(environment: environment)
            if predicate(state) {
                return true
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return false
    }

    private func fileURL(for environmentKey: String) -> URL? {
        guard let rawPath = ProcessInfo.processInfo.environment[environmentKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !rawPath.isEmpty
        else {
            return nil
        }
        return URL(fileURLWithPath: rawPath)
    }

    private func writeJSON<Value: Encodable>(_ value: Value, to url: URL?) {
        guard let url else { return }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(value)
            try data.write(to: url, options: .atomic)
        } catch {
        }
    }

    private func appendJSONL<Value: Encodable>(_ value: Value, to url: URL?) {
        guard let url else { return }
        do {
            let encoder = JSONEncoder()
            let data = try encoder.encode(value)
            let line = data + Data([0x0A])
            let directory = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: nil
            )
            if FileManager.default.fileExists(atPath: url.path) {
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: line)
            } else {
                try line.write(to: url, options: .atomic)
            }
        } catch {
        }
    }

    private func normalizedIdentifier(_ raw: String?) -> String? {
        raw?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    private var providerMode: String {
        #if os(iOS)
        return "apns"
        #elseif os(macOS)
        return "apns"
        #else
        return "provider"
        #endif
    }

    private var providerTransport: String {
        #if os(iOS)
        return "apns"
        #elseif os(macOS)
        return "apns"
        #else
        return "provider"
        #endif
    }

    private func localStoreMode(_ state: LocalDataStore.StorageState) -> String {
        switch state.mode {
        case .persistent:
            return "persistent"
        case .unavailable:
            return "unavailable"
        }
    }

    private func writeEvent(type: String, command: String?, details: [String: String]) {
        appendJSONL(
            PushGoAutomationEvent(
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

    func recordSearchResultsUpdated(query: String, resultCount: Int) {
        configureFromProcessEnvironment()
        writeEvent(
            type: "search.results_updated",
            command: nil,
            details: [
                "search_query": query,
                "result_count": String(resultCount),
            ]
        )
    }

    func recordExportCompleted(path: String) {
        configureFromProcessEnvironment()
        writeEvent(
            type: "export.completed",
            command: nil,
            details: [
                "export_path": path,
            ]
        )
    }

    func recordRuntimeError(
        source: String,
        category: String = "runtime",
        code: String? = nil,
        message: String
    ) {
        configureFromProcessEnvironment()
        let normalizedSource = normalizedIdentifier(source) ?? "unknown"
        let normalizedCategory = normalizedIdentifier(category) ?? "runtime"
        let normalizedCode = normalizedIdentifier(code)
        let normalizedMessage = normalizedIdentifier(message) ?? "Unknown runtime error"
        let snapshot = PushGoAutomationRuntimeError(
            source: normalizedSource,
            category: normalizedCategory,
            code: normalizedCode,
            message: normalizedMessage,
            timestamp: ISO8601DateFormatter().string(from: Date())
        )
        latestRuntimeError = snapshot
        runtimeErrorCount += 1
        writeTraceError(
            domain: normalizedCategory,
            operation: normalizedSource,
            code: normalizedCode,
            message: normalizedMessage,
            attributes: ["count": String(runtimeErrorCount)]
        )
        writeEvent(
            type: "runtime.error",
            command: nil,
            details: [
                "source": snapshot.source,
                "category": snapshot.category,
                "code": snapshot.code ?? "",
                "message": snapshot.message,
                "timestamp": snapshot.timestamp,
                "count": String(runtimeErrorCount),
            ]
        )
    }

    private func writeDerivedEvents(previous: PushGoAutomationState?, current: PushGoAutomationState) {
        if let entityDetails = openedEntityEventDetails(previous: previous, current: current) {
            writeEvent(type: "entity.opened", command: nil, details: entityDetails)
        }
        if let settingsDetails = settingsChangedEventDetails(previous: previous, current: current) {
            writeEvent(type: "settings.changed", command: nil, details: settingsDetails)
        }
        if previous?.unreadMessageCount != current.unreadMessageCount {
            writeEvent(
                type: "badge.updated",
                command: nil,
                details: ["unread_message_count": String(current.unreadMessageCount)]
            )
        }
    }

    private func openedEntityEventDetails(
        previous: PushGoAutomationState?,
        current: PushGoAutomationState
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

    private func startCommandTrace(_ request: PushGoAutomationRequest) {
        let requestId = normalizedIdentifier(request.id)
        let traceId = requestId ?? UUID().uuidString.lowercased()
        let spanId = UUID().uuidString.lowercased()
        activeTrace = PushGoAutomationActiveTrace(
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

    private func endCommandTrace(
        status: String,
        attributes: [String: String],
        errorCode: String?,
        errorMessage: String?
    ) {
        guard let activeTrace else { return }
        let durationMs = max(0, Int(Date().timeIntervalSince(activeTrace.startedAt) * 1000))
        var mergedAttributes = ["command": activeTrace.command]
        attributes.forEach { mergedAttributes[$0.key] = $0.value }
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
            attributes: mergedAttributes,
            errorCode: errorCode,
            errorMessage: errorMessage
        )
        self.activeTrace = nil
    }

    private func writeTraceAnnotation(type: String, command: String?, details: [String: String]) {
        let descriptor = traceDescriptor(forEventType: type)
        let traceId = activeTrace?.traceId ?? UUID().uuidString.lowercased()
        let parentSpanId = activeTrace?.spanId
        var attributes = details
        if let command {
            attributes["command"] = command
        }
        writeTraceRecord(
            kind: "annotation",
            traceId: traceId,
            spanId: UUID().uuidString.lowercased(),
            parentSpanId: parentSpanId,
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

    private func writeTraceError(
        domain: String,
        operation: String,
        code: String?,
        message: String,
        attributes: [String: String]
    ) {
        let traceId = activeTrace?.traceId ?? UUID().uuidString.lowercased()
        writeTraceRecord(
            kind: "span.error",
            traceId: traceId,
            spanId: activeTrace?.spanId ?? UUID().uuidString.lowercased(),
            parentSpanId: nil,
            requestId: activeTrace?.requestId,
            domain: domain,
            operation: operation,
            status: "error",
            durationMs: nil,
            attributes: attributes,
            errorCode: code,
            errorMessage: message
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
            PushGoAutomationTraceRecord(
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
        case "search.results_updated":
            return ("search", "results.updated")
        case "export.completed":
            return ("export", "completed")
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

    private func settingsChangedEventDetails(
        previous: PushGoAutomationState?,
        current: PushGoAutomationState
    ) -> [String: String]? {
        var changedKeys: [String] = []
        if previous?.gatewayBaseURL != current.gatewayBaseURL {
            changedKeys.append("gateway_base_url")
        }
        if previous?.messagePageEnabled != current.messagePageEnabled {
            changedKeys.append("message_page_enabled")
        }
        if previous?.eventPageEnabled != current.eventPageEnabled {
            changedKeys.append("event_page_enabled")
        }
        if previous?.thingPageEnabled != current.thingPageEnabled {
            changedKeys.append("thing_page_enabled")
        }
        if previous?.notificationKeyConfigured != current.notificationKeyConfigured {
            changedKeys.append("notification_key_configured")
        }
        if previous?.notificationKeyEncoding != current.notificationKeyEncoding {
            changedKeys.append("notification_key_encoding")
        }
        guard !changedKeys.isEmpty else { return nil }
        return [
            "gateway_base_url": current.gatewayBaseURL ?? "",
            "message_page_enabled": current.messagePageEnabled ? "true" : "false",
            "event_page_enabled": current.eventPageEnabled ? "true" : "false",
            "thing_page_enabled": current.thingPageEnabled ? "true" : "false",
            "notification_key_configured": current.notificationKeyConfigured ? "true" : "false",
            "notification_key_encoding": current.notificationKeyEncoding ?? "",
            "changed_keys": changedKeys.joined(separator: ","),
        ]
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

    private func publishEnrichedState(baseState: PushGoAutomationState, environment: AppEnvironment) async {
        let previousState = latestState
        let state = await enrichState(baseState, environment: environment)
        latestState = state
        writeJSON(state, to: stateURL)
        writeDerivedEvents(previous: previousState, current: state)
    }

    private func fallbackState(environment: AppEnvironment) async -> PushGoAutomationState {
        let activeTab = environment.activeMainTab.automationIdentifier
        let openedMessageId = await resolvedAutomationMessageId(
            localMessageId: environment.pendingMessageToOpen,
            environment: environment
        )
        let visibleScreen = environment.pendingMessageToOpen != nil
            ? "screen.message.detail"
            : environment.activeMainTab.automationVisibleScreen
        let baseState = PushGoAutomationState(
            platform: platformIdentifier,
            buildMode: "debug",
            activeTab: activeTab,
            visibleScreen: visibleScreen,
            openedMessageId: openedMessageId,
            openedMessageDecryptionState: nil,
            openedEntityType: environment.pendingThingToOpen != nil ? "thing" : (environment.pendingEventToOpen != nil ? "event" : nil),
            openedEntityId: normalizedIdentifier(environment.pendingThingToOpen ?? environment.pendingEventToOpen),
            pendingMessageId: environment.pendingMessageToOpen?.uuidString,
            pendingEventId: normalizedIdentifier(environment.pendingEventToOpen),
            pendingThingId: normalizedIdentifier(environment.pendingThingToOpen),
            unreadMessageCount: environment.unreadMessageCount,
            totalMessageCount: environment.totalMessageCount,
            eventCount: 0,
            thingCount: 0,
            messagePageEnabled: environment.isMessagePageEnabled,
            eventPageEnabled: environment.isEventPageEnabled,
            thingPageEnabled: environment.isThingPageEnabled,
            notificationKeyConfigured: environment.currentNotificationMaterial?.isConfigured == true,
            notificationKeyEncoding: nil,
            gatewayBaseURL: environment.serverConfig?.normalizedBaseURL.absoluteString,
            gatewayTokenPresent: normalizedIdentifier(environment.serverConfig?.token) != nil,
            watchMode: watchModeIdentifier(environment: environment),
            watchCompanionAvailable: watchCompanionAvailable(environment: environment),
            providerMode: providerMode,
            providerTokenPresent: false,
            providerDeviceKeyPresent: false,
            privateRoute: "idle",
            privateTransport: providerTransport,
            privateStage: "idle",
            privateDetail: nil,
            ackPendingCount: 0,
            channelCount: environment.channelSubscriptions.count,
            lastNotificationAction: lastNotificationAction,
            lastNotificationTarget: lastNotificationTarget,
            lastFixtureImportPath: lastFixtureImportPath,
            lastFixtureImportMessageCount: lastFixtureImportMessageCount,
            lastFixtureImportEntityRecordCount: lastFixtureImportEntityRecordCount,
            lastFixtureImportSubscriptionCount: lastFixtureImportSubscriptionCount,
            localStoreMode: localStoreMode(environment.dataStore.storageState),
            localStoreReason: normalizedIdentifier(environment.dataStore.storageState.reason),
            runtimeErrorCount: runtimeErrorCount,
            latestRuntimeErrorSource: latestRuntimeError?.source,
            latestRuntimeErrorCategory: latestRuntimeError?.category,
            latestRuntimeErrorCode: latestRuntimeError?.code,
            latestRuntimeErrorMessage: latestRuntimeError?.message,
            latestRuntimeErrorTimestamp: latestRuntimeError?.timestamp
        )
        return await enrichState(baseState, environment: environment)
    }

    private func resolvedAutomationMessageId(
        localMessageId: UUID?,
        environment: AppEnvironment
    ) async -> String? {
        guard let localMessageId else { return nil }
        if let message = try? await environment.dataStore.loadMessage(id: localMessageId) {
            return normalizedIdentifier(message.messageId) ?? message.id.uuidString
        }
        return localMessageId.uuidString
    }

    private func resolvedAutomationMessageDecryptionState(
        messageId: String?,
        environment: AppEnvironment
    ) async -> String? {
        guard let messageId = normalizedIdentifier(messageId) else { return nil }
        if let message = try? await environment.dataStore.loadMessage(messageId: messageId) {
            if let resolved = normalizedIdentifier(message.decryptionState?.rawValue) {
                return resolved
            }
            return normalizedIdentifier(message.rawPayload["decryption_state"]?.value as? String)
        }
        if let message = try? await environment.dataStore.loadMessage(notificationRequestId: messageId) {
            if let resolved = normalizedIdentifier(message.decryptionState?.rawValue) {
                return resolved
            }
            return normalizedIdentifier(message.rawPayload["decryption_state"]?.value as? String)
        }
        return nil
    }

    private func enrichState(_ state: PushGoAutomationState, environment: AppEnvironment) async -> PushGoAutomationState {
        let platform = platformIdentifier
        let providerToken = await environment.dataStore.cachedPushToken(for: platform)
            ?? PushGoAutomationContext.providerToken
        let providerDeviceKey = await environment.dataStore.cachedProviderDeviceKey(for: platform)
        let ackPendingCount = (try? await environment.dataStore.loadPendingInboundDeliveryAckIds(limit: 500).count) ?? 0
        let eventCount = (try? await environment.dataStore.loadEventMessagesForProjection().count) ?? 0
        let thingCount = (try? await environment.dataStore.loadThingMessagesForProjection().count) ?? 0
        let notificationKeyEncoding = await environment.dataStore.loadManualKeyPreferences()
        let notificationKeyConfigured = environment.currentNotificationMaterial?.isConfigured == true
        let openedMessageDecryptionState = await resolvedAutomationMessageDecryptionState(
            messageId: state.openedMessageId,
            environment: environment
        )
        let providerTokenPresent = normalizedIdentifier(providerToken) != nil
        let providerDeviceKeyPresent = normalizedIdentifier(providerDeviceKey) != nil
        let privateRoute = providerTokenPresent ? "provider" : "idle"
        let privateStage = providerDeviceKeyPresent ? "ready" : (providerTokenPresent ? "route_pending" : "idle")
        let privateDetail: String? = {
            if environment.serverConfig == nil {
                return "server configuration missing"
            }
            if !providerTokenPresent {
                return "provider token missing"
            }
            if !providerDeviceKeyPresent {
                return "provider route not ready"
            }
            if ackPendingCount > 0 {
                return "pending inbound delivery ACKs"
            }
            return nil
        }()
        return PushGoAutomationState(
            platform: state.platform,
            buildMode: state.buildMode,
            activeTab: state.activeTab,
            visibleScreen: state.visibleScreen,
            openedMessageId: state.openedMessageId,
            openedMessageDecryptionState: openedMessageDecryptionState,
            openedEntityType: state.openedEntityType,
            openedEntityId: state.openedEntityId,
            pendingMessageId: state.pendingMessageId,
            pendingEventId: state.pendingEventId,
            pendingThingId: state.pendingThingId,
            unreadMessageCount: state.unreadMessageCount,
            totalMessageCount: state.totalMessageCount,
            eventCount: eventCount,
            thingCount: thingCount,
            messagePageEnabled: state.messagePageEnabled,
            eventPageEnabled: state.eventPageEnabled,
            thingPageEnabled: state.thingPageEnabled,
            notificationKeyConfigured: notificationKeyConfigured,
            notificationKeyEncoding: normalizedIdentifier(notificationKeyEncoding),
            gatewayBaseURL: state.gatewayBaseURL,
            gatewayTokenPresent: state.gatewayTokenPresent,
            watchMode: watchModeIdentifier(environment: environment),
            watchCompanionAvailable: watchCompanionAvailable(environment: environment),
            providerMode: state.providerMode,
            providerTokenPresent: providerTokenPresent,
            providerDeviceKeyPresent: providerDeviceKeyPresent,
            privateRoute: privateRoute,
            privateTransport: providerTransport,
            privateStage: privateStage,
            privateDetail: privateDetail,
            ackPendingCount: ackPendingCount,
            channelCount: environment.channelSubscriptions.count,
            lastNotificationAction: state.lastNotificationAction,
            lastNotificationTarget: state.lastNotificationTarget,
            lastFixtureImportPath: state.lastFixtureImportPath,
            lastFixtureImportMessageCount: state.lastFixtureImportMessageCount,
            lastFixtureImportEntityRecordCount: state.lastFixtureImportEntityRecordCount,
            lastFixtureImportSubscriptionCount: state.lastFixtureImportSubscriptionCount,
            localStoreMode: state.localStoreMode,
            localStoreReason: state.localStoreReason,
            runtimeErrorCount: state.runtimeErrorCount,
            latestRuntimeErrorSource: state.latestRuntimeErrorSource,
            latestRuntimeErrorCategory: state.latestRuntimeErrorCategory,
            latestRuntimeErrorCode: state.latestRuntimeErrorCode,
            latestRuntimeErrorMessage: state.latestRuntimeErrorMessage,
            latestRuntimeErrorTimestamp: state.latestRuntimeErrorTimestamp
        )
    }

    private func parseBoolean(_ raw: String?) -> Bool? {
        switch raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "true", "yes", "on":
            return true
        case "0", "false", "no", "off":
            return false
        default:
            return nil
        }
    }

    private func watchModeIdentifier(environment: AppEnvironment) -> String? {
        #if os(iOS)
        environment.effectiveWatchMode.rawValue
        #else
        nil
        #endif
    }

    private func watchCompanionAvailable(environment: AppEnvironment) -> Bool {
        #if os(iOS)
        environment.isWatchCompanionAvailable
        #else
        false
        #endif
    }

    private func updateWatchMode(mode: String, environment: AppEnvironment) async throws {
        #if os(iOS)
        guard let nextMode = WatchMode(rawValue: mode) else {
            throw PushGoAutomationError.invalidArgument("mode")
        }
        try await environment.requestWatchModeChangeConfirmed(nextMode)
        let applied = await waitForAutomationState(environment: environment, timeout: 4.0) { state in
            state.watchMode == nextMode.rawValue
        }
        guard applied else {
            throw PushGoAutomationError.invalidArgument("mode")
        }
        #else
        throw PushGoAutomationError.unsupportedCommand("watch.set_mode")
        #endif
    }

    private func applyPageVisibility(page: String, enabled: Bool, environment: AppEnvironment) throws {
        switch page {
        case "message", "messages":
            environment.setMessagePageEnabled(enabled)
        case "event", "events":
            environment.setEventPageEnabled(enabled)
        case "thing", "things":
            environment.setThingPageEnabled(enabled)
        default:
            throw PushGoAutomationError.invalidArgument("page")
        }
    }

    private func updateNotificationKey(
        request: PushGoAutomationRequest,
        environment: AppEnvironment
    ) async throws {
        let encoding = ManualNotificationKeyEncoding.normalized(from: request.args?.encoding)
        let trimmedKey = request.args?.key?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let material = ServerConfig.NotificationKeyMaterial(
            algorithm: .aesGcm,
            keyData: try normalizedNotificationKeyData(trimmedKey, encoding: encoding),
            ivBase64: nil,
            updatedAt: Date()
        )
        await environment.dataStore.saveManualKeyPreferences(encoding: encoding.rawValue)
        await environment.updateNotificationMaterial(material)
    }

    private func normalizedNotificationKeyData(
        _ input: String,
        encoding: ManualNotificationKeyEncoding
    ) throws -> Data {
        if input.isEmpty {
            return Data()
        }
        do {
            return try ManualNotificationKeyValidator.normalizedKeyData(from: input, encoding: encoding)
        } catch let validation as ManualNotificationKeyValidationError {
            switch validation {
            case .invalidBase64, .invalidHex:
                throw PushGoAutomationError.invalidArgument("encoding")
            case .invalidLength:
                throw PushGoAutomationError.invalidArgument("key")
            }
        }
    }

    private func updateGatewayConfig(request: PushGoAutomationRequest, environment: AppEnvironment) async throws {
        let rawBaseURL = request.args?.baseURL?.trimmingCharacters(in: .whitespacesAndNewlines)
        let rawToken = request.args?.token
        guard rawBaseURL != nil || rawToken != nil else {
            throw PushGoAutomationError.missingArgument("base_url or token")
        }
        var config = environment.serverConfig ?? defaultServerConfig()
        if let rawBaseURL, !rawBaseURL.isEmpty {
            guard let url = URL(string: rawBaseURL), let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else {
                throw PushGoAutomationError.invalidArgument("base_url")
            }
            config.baseURL = url
        }
        if let rawToken {
            let trimmedToken = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)
            config.token = trimmedToken.isEmpty || trimmedToken == "__clear__" || trimmedToken.lowercased() == "null"
                ? nil
                : trimmedToken
        }
        config.updatedAt = Date()
        try await environment.updateServerConfig(config.normalized())
    }

    private func handleNotificationOpen(request: PushGoAutomationRequest, environment: AppEnvironment) async throws {
        if let requestId = normalizedIdentifier(request.args?.notificationRequestId) {
            await environment.handleNotificationOpen(notificationRequestId: requestId)
            return
        }
        if let messageId = normalizedIdentifier(request.args?.messageId) {
            await environment.handleNotificationOpen(messageId: messageId)
            return
        }
        guard let entityType = normalizedIdentifier(request.args?.entityType) else {
            throw PushGoAutomationError.missingArgument("notification_request_id | message_id | entity_type")
        }
        guard let entityId = normalizedIdentifier(request.args?.entityId) else {
            throw PushGoAutomationError.missingArgument("entity_id")
        }
        await environment.handleNotificationOpen(entityType: entityType, entityId: entityId)
    }

    private func handleNotificationAction(
        request: PushGoAutomationRequest,
        action: PushGoAutomationNotificationAction,
        environment: AppEnvironment,
    ) async throws {
        let notificationRequestId = normalizedIdentifier(request.args?.notificationRequestId)
        let messageId = normalizedIdentifier(request.args?.messageId)

        switch action {
        case .markRead:
            if let notificationRequestId {
                let resolvedMessage = try await environment.messageStateCoordinator.markRead(
                    notificationRequestId: notificationRequestId,
                    messageId: messageId
                )
                recordNotificationAction(
                    "mark_read",
                    target: resolvedMessage?.messageId ?? resolvedMessage?.id.uuidString ?? notificationRequestId
                )
                return
            }
            guard let message = try await resolveMessage(messageId: messageId, environment: environment) else {
                throw PushGoAutomationError.missingArgument("notification_request_id or message_id")
            }
            _ = try await environment.messageStateCoordinator.markRead(messageId: message.id)
            recordNotificationAction("mark_read", target: message.messageId ?? message.id.uuidString)
        case .delete:
            if let notificationRequestId {
                try await environment.messageStateCoordinator.deleteMessage(
                    notificationRequestId: notificationRequestId,
                    messageId: messageId
                )
                recordNotificationAction("delete", target: messageId ?? notificationRequestId)
                return
            }
            guard let message = try await resolveMessage(messageId: messageId, environment: environment) else {
                throw PushGoAutomationError.missingArgument("notification_request_id or message_id")
            }
            try await environment.messageStateCoordinator.deleteMessage(messageId: message.id)
            recordNotificationAction("delete", target: message.messageId ?? message.id.uuidString)
        case .copy:
            guard let message = try await resolveMessage(
                notificationRequestId: notificationRequestId,
                messageId: messageId,
                environment: environment
            ) else {
                throw PushGoAutomationError.missingArgument("notification_request_id or message_id")
            }
            copyText(message.title, message.resolvedBody.rawText)
            environment.showToast(
                message: LocalizationManager.shared.localized("message_content_copied"),
                style: .success,
                duration: 1.2
            )
            recordNotificationAction("copy", target: message.messageId ?? message.id.uuidString)
        }
    }

    private func triggerPrivateWakeup(environment: AppEnvironment) async {
        #if os(iOS)
        await environment.triggerPrivateWakeupPull(presentLocalNotifications: false)
        #else
        await environment.triggerPrivateWakeupPull()
        #endif
    }

    private func resetLocalState(environment: AppEnvironment) async throws {
        #if os(iOS)
        await WatchTokenReceiver.shared.clearPersistentState()
        #endif
        try await environment.dataStore.deleteAllMessages()
        if let gatewayKey = environment.serverConfig?.gatewayKey {
            let subscriptions = try await environment.dataStore.loadChannelSubscriptions(
                gateway: gatewayKey,
                includeDeleted: false
            )
            for subscription in subscriptions {
                try await environment.dataStore.softDeleteChannelSubscription(
                    gateway: gatewayKey,
                    channelId: subscription.channelId
                )
            }
        }
        let platform = platformIdentifier
        await environment.dataStore.saveCachedPushToken(nil, for: platform)
        await environment.dataStore.saveCachedProviderDeviceKey(nil, for: platform)
        let defaultConfig = defaultServerConfig().normalized()
        try await environment.updateServerConfig(defaultConfig)
        environment.setMessagePageEnabled(true)
        environment.setEventPageEnabled(true)
        environment.setThingPageEnabled(true)
        environment.pendingMessageToOpen = nil
        environment.pendingEventToOpen = nil
        environment.pendingThingToOpen = nil
        lastNotificationAction = nil
        lastNotificationTarget = nil
        lastFixtureImportPath = nil
        lastFixtureImportMessageCount = 0
        lastFixtureImportEntityRecordCount = 0
        lastFixtureImportSubscriptionCount = 0
        await environment.refreshMessageCountsAndNotify()
        await environment.refreshChannelSubscriptions()
    }

    private func importFixture(request: PushGoAutomationRequest, environment: AppEnvironment) async throws {
        let bundle = try loadFixtureBundle(request: request)
        try await applyFixtureBundle(
            bundle,
            sourcePath: normalizedIdentifier(request.args?.path),
            environment: environment
        )
    }

    private func seedMessages(request: PushGoAutomationRequest, environment: AppEnvironment) async throws {
        let bundle = try loadFixtureBundle(request: request)
        guard !bundle.messages.isEmpty else {
            throw PushGoAutomationError.invalidArgument("path")
        }
        if !bundle.messages.isEmpty {
            try await environment.dataStore.saveMessages(
                bundle.messages
                    .map { $0.toPushMessage() }
                    .sorted { $0.receivedAt > $1.receivedAt }
            )
        }
        await environment.refreshMessageCountsAndNotify()
        recordFixtureImport(
            path: normalizedIdentifier(request.args?.path),
            messageCount: bundle.messages.count,
            entityRecordCount: 0,
            subscriptionCount: 0
        )
    }

    private func seedEntityRecords(request: PushGoAutomationRequest, environment: AppEnvironment) async throws {
        let bundle = try loadFixtureBundle(request: request)
        guard !bundle.entityRecords.isEmpty else {
            throw PushGoAutomationError.invalidArgument("path")
        }
        try await environment.dataStore.saveEntityRecords(
            bundle.entityRecords
                .map { $0.toPushMessage() }
                .sorted { $0.receivedAt > $1.receivedAt }
        )
        await environment.refreshMessageCountsAndNotify()
        recordFixtureImport(
            path: normalizedIdentifier(request.args?.path),
            messageCount: 0,
            entityRecordCount: bundle.entityRecords.count,
            subscriptionCount: 0
        )
    }

    private func seedSubscriptions(request: PushGoAutomationRequest, environment: AppEnvironment) async throws {
        let bundle = try loadFixtureBundle(request: request)
        guard !bundle.channelSubscriptions.isEmpty else {
            throw PushGoAutomationError.invalidArgument("path")
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

    private func loadFixtureBundle(request: PushGoAutomationRequest) throws -> PushGoAutomationFixtureBundle {
        guard let path = normalizedIdentifier(request.args?.path) else {
            throw PushGoAutomationError.missingArgument("path")
        }
        return try loadFixtureBundle(path: path)
    }

    private func loadStartupFixtureBundle() throws -> PushGoAutomationFixtureBundle {
        if let startupFixtureBase64 {
            return try loadFixtureBundle(base64Encoded: startupFixtureBase64)
        }
        guard let startupFixturePath else {
            throw PushGoAutomationError.missingArgument("startup_fixture")
        }
        return try loadFixtureBundle(path: startupFixturePath)
    }

    private func loadFixtureBundle(path: String) throws -> PushGoAutomationFixtureBundle {
        let url = URL(fileURLWithPath: path)
        let data = try Data(contentsOf: url)
        return try decodeFixtureBundle(data: data)
    }

    private func loadFixtureBundle(base64Encoded: String) throws -> PushGoAutomationFixtureBundle {
        guard let data = Data(base64Encoded: base64Encoded) else {
            throw PushGoAutomationError.invalidArgument("startup_fixture_base64")
        }
        return try decodeFixtureBundle(data: data)
    }

    private func decodeFixtureBundle(data: Data) throws -> PushGoAutomationFixtureBundle {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(PushGoAutomationFixtureBundle.self, from: data)
    }

    private func applyFixtureBundle(
        _ bundle: PushGoAutomationFixtureBundle,
        sourcePath: String?,
        environment: AppEnvironment,
    ) async throws {
        if !bundle.messages.isEmpty {
            try await environment.dataStore.saveMessages(
                bundle.messages
                    .map { $0.toPushMessage() }
                    .sorted { $0.receivedAt > $1.receivedAt }
            )
        }
        if !bundle.entityRecords.isEmpty {
            try await environment.dataStore.saveEntityRecords(
                bundle.entityRecords
                    .map { $0.toPushMessage() }
                    .sorted { $0.receivedAt > $1.receivedAt }
            )
        }
        if !bundle.channelSubscriptions.isEmpty {
            try await applyFixtureSubscriptions(bundle.channelSubscriptions, environment: environment)
        }
        await environment.refreshMessageCountsAndNotify()
        environment.publishStoreRefreshForAutomation()
        await environment.refreshChannelSubscriptions()
        recordFixtureImport(
            path: sourcePath,
            messageCount: bundle.messages.count,
            entityRecordCount: bundle.entityRecords.count,
            subscriptionCount: bundle.channelSubscriptions.count
        )
    }

    private func applyFixtureSubscriptions(
        _ subscriptions: [PushGoAutomationFixtureSubscription],
        environment: AppEnvironment,
    ) async throws {
        let fallbackGateway = (environment.serverConfig ?? defaultServerConfig()).normalized().gatewayKey
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

    private func resolveMessage(
        notificationRequestId: String? = nil,
        messageId: String?,
        environment: AppEnvironment,
    ) async throws -> PushMessage? {
        if let messageId = normalizedIdentifier(messageId),
           let message = try await environment.dataStore.loadMessage(messageId: messageId) {
            return message
        }
        if let notificationRequestId = normalizedIdentifier(notificationRequestId) {
            return try await environment.dataStore.loadMessage(notificationRequestId: notificationRequestId)
        }
        return nil
    }

    private func copyText(_ title: String, _ body: String) {
        let text = [title, body]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        guard !text.isEmpty else { return }
        PushGoSystemInteraction.copyTextToPasteboard(text)
    }

    private func recordNotificationAction(_ action: String, target: String?) {
        lastNotificationAction = action
        lastNotificationTarget = normalizedIdentifier(target)
        writeEvent(
            type: "notification.action",
            command: nil,
            details: [
                "action": action,
                "target": normalizedIdentifier(target) ?? "",
            ]
        )
    }

    private func recordFixtureImport(
        path: String?,
        messageCount: Int,
        entityRecordCount: Int,
        subscriptionCount: Int,
    ) {
        lastFixtureImportPath = normalizedIdentifier(path)
        lastFixtureImportMessageCount = messageCount
        lastFixtureImportEntityRecordCount = entityRecordCount
        lastFixtureImportSubscriptionCount = subscriptionCount
        writeEvent(
            type: "fixture.imported",
            command: nil,
            details: [
                "path": lastFixtureImportPath ?? "",
                "message_count": String(messageCount),
                "entity_record_count": String(entityRecordCount),
                "subscription_count": String(subscriptionCount),
            ]
        )
    }

    private func defaultServerConfig() -> ServerConfig {
        if let defaultURL = AppConstants.defaultServerURL {
            return ServerConfig(baseURL: defaultURL, token: nil)
        }
        return ServerConfig(baseURL: URL(string: "https://example.invalid")!, token: nil)
    }
}

private enum PushGoAutomationNotificationAction {
    case markRead
    case delete
    case copy
}

private enum PushGoAutomationError: LocalizedError {
    case missingArgument(String)
    case invalidArgument(String)
    case unsupportedCommand(String)

    var errorDescription: String? {
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
    static let pushgoAutomationSelectTab = Notification.Name("pushgo.automation.select-tab")
    static let pushgoAutomationOpenSettingsDecryption = Notification.Name("pushgo.automation.open-settings-decryption")
}
#endif
