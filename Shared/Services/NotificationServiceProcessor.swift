import Foundation
import UserNotifications

@MainActor
final class NotificationServiceProcessor {
    #if !os(watchOS)
    private struct PrivateWakeupHydrationSnapshot: Sendable {
        let persistedItems: [PrivateWakeupPullItem]

        static let empty = PrivateWakeupHydrationSnapshot(persistedItems: [])
    }

    private actor PrivateWakeupGate {
        private var inFlightHydration: Task<PrivateWakeupHydrationSnapshot, Never>?

        func coalescedHydration(
            _ operation: @escaping @Sendable () async -> PrivateWakeupHydrationSnapshot
        ) async -> PrivateWakeupHydrationSnapshot {
            if let inFlightHydration {
                return await inFlightHydration.value
            }
            let task = Task { await operation() }
            inFlightHydration = task
            let value = await task.value
            inFlightHydration = nil
            return value
        }
    }
    #endif

    #if !os(watchOS)
    private struct GatewayStatusResponse<T: Decodable>: Decodable {
        let success: Bool
        let error: String?
        let data: T?
    }

    private struct PullRequest: Encodable {
        let deviceKey: String
        let channelId: String
        let password: String
        let limit: Int

        enum CodingKeys: String, CodingKey {
            case deviceKey = "device_key"
            case channelId = "channel_id"
            case password
            case limit
        }
    }

    private struct DeviceRegisterRequest: Encodable {
        let platform: String
        let deviceKey: String?

        enum CodingKeys: String, CodingKey {
            case platform
            case deviceKey = "device_key"
        }
    }

    private struct DeviceRegisterPayload: Decodable {
        let deviceKey: String

        enum CodingKeys: String, CodingKey {
            case deviceKey = "device_key"
        }
    }

    private struct PullResponse: Decodable {
        let items: [PullItem]
    }

    private struct PullItem: Decodable {
        let deliveryId: String
        let payload: [String: String]

        enum CodingKeys: String, CodingKey {
            case deliveryId = "delivery_id"
            case payload
        }
    }

    private struct AckBatchRequest: Encodable {
        let deviceKey: String
        let deliveryIds: [String]

        enum CodingKeys: String, CodingKey {
            case deviceKey = "device_key"
            case deliveryIds = "delivery_ids"
        }
    }

    private struct AckBatchResponse: Decodable {
        let ackedDeliveryIds: [String]

        enum CodingKeys: String, CodingKey {
            case ackedDeliveryIds = "acked_delivery_ids"
        }
    }

    private struct EmptyPayload: Decodable {
        init(from _: Decoder) throws {}
    }
    #endif

    private let localDataStore = LocalDataStore()
    private let contentPreparer = NotificationContentPreparer()
    #if !os(watchOS)
    private static let privateWakeupGate = PrivateWakeupGate()
    #endif
    func process(
        request: UNNotificationRequest,
        content: UNMutableNotificationContent
    ) async -> UNNotificationContent {
        let content = await prepareContent(request: request, content: content)
        let shouldSkipPersist = (content.userInfo["_skip_persist"] as? String) == "1"
        if !shouldSkipPersist {
            await persistMessage(for: request, content: content)
        }
        return content
    }

    func prepareContent(
        request: UNNotificationRequest,
        content: UNMutableNotificationContent
    ) async -> UNMutableNotificationContent {
        var content = content
        content = await hydrateFromPrivateWakeupIfNeeded(
            requestIdentifier: request.identifier,
            content: content
        )
        return await contentPreparer.prepare(content)
    }

    private func hydrateFromPrivateWakeupIfNeeded(
        requestIdentifier: String,
        content: UNMutableNotificationContent
    ) async -> UNMutableNotificationContent {
        #if os(watchOS)
        _ = requestIdentifier
        return content
        #else
        guard isPrivateWakeupPayload(content.userInfo) else { return content }
        guard let runtime = await loadPrivateRuntimeConfig() else {
            return content
        }
        guard let deviceKey = await ensureProviderDeviceKey(
            baseURL: runtime.baseURL,
            authToken: runtime.authToken,
            platform: runtime.platform
        ) else {
            return content
        }
        let snapshot = await Self.privateWakeupGate.coalescedHydration { [self] in
            await self.performPrivateWakeupHydration(
                requestIdentifier: requestIdentifier,
                runtime: runtime,
                deviceKey: deviceKey
            )
        }
        let persistedItems = snapshot.persistedItems
        guard !persistedItems.isEmpty else {
            return content
        }
        var hydrated = content
        if let first = persistedItems.first {
            applyPulledPayload(first, to: &hydrated)
        }
        if persistedItems.count > 1 {
            hydrated = makeSummaryNotificationContent(base: hydrated, count: persistedItems.count)
        }
        return hydrated
        #endif
    }

    #if !os(watchOS)
    private func performPrivateWakeupHydration(
        requestIdentifier: String,
        runtime: (
            baseURL: URL,
            authToken: String?,
            platform: String,
            systemToken: String?,
            channels: [(id: String, password: String)]
        ),
        deviceKey: String
    ) async -> PrivateWakeupHydrationSnapshot {
        _ = await PrivateWakeupAckOutboxWorker.drainPendingAcks(
            dataStore: localDataStore,
            acknowledge: { [self] deliveryIds in
                try await self.ackMessages(
                    baseURL: runtime.baseURL,
                    authToken: runtime.authToken,
                    deviceKey: deviceKey,
                    deliveryIds: deliveryIds
                )
            }
        )
        var pulledItems: [PrivateWakeupPullItem] = []
        for channel in runtime.channels {
            let pulled: [PullItem]
            do {
                pulled = try await pullMessages(
                    baseURL: runtime.baseURL,
                    authToken: runtime.authToken,
                    deviceKey: deviceKey,
                    channelId: channel.id,
                    password: channel.password,
                    limit: 100
                )
            } catch {
                continue
            }
            guard !pulled.isEmpty else { continue }
            pulledItems.append(contentsOf: pulled.map { item in
                PrivateWakeupPullItem(deliveryId: item.deliveryId, payload: item.payload)
            })
        }
        guard !pulledItems.isEmpty else {
            return .empty
        }

        let persistedDeliveryIds = await persistPulledItems(
            pulledItems,
            requestIdentifier: requestIdentifier,
            runtime: runtime,
            deviceKey: deviceKey
        )
        guard !persistedDeliveryIds.isEmpty else { return .empty }
        let persistedItems = pulledItems.filter { persistedDeliveryIds.contains($0.deliveryId) }
        return .init(persistedItems: persistedItems)
    }
    #endif

    #if !os(watchOS)
    private func persistPulledItems(
        _ items: [PrivateWakeupPullItem],
        requestIdentifier: String,
        runtime: (
            baseURL: URL,
            authToken: String?,
            platform: String,
            systemToken: String?,
            channels: [(id: String, password: String)]
        ),
        deviceKey: String
    ) async -> Set<String> {
        let receivedAt = Date()
        var seenMessageIds = Set<String>()
        return await PrivateWakeupPullCoordinator.processPulledItems(
            items,
            dataStore: localDataStore,
            acknowledge: { [self] deliveryIds in
                try await self.ackMessages(
                    baseURL: runtime.baseURL,
                    authToken: runtime.authToken,
                    deviceKey: deviceKey,
                    deliveryIds: deliveryIds
                )
            },
            processItem: { normalized, deliveryId, _, deliveryState in
                guard deliveryState != .acked else { return false }
                switch deliveryState {
                case .missing:
                    if let messageId = normalized.messageId, !messageId.isEmpty {
                        if seenMessageIds.contains(messageId) {
                            return false
                        }
                        seenMessageIds.insert(messageId)
                    } else if normalized.entityType == "message" {
                        return false
                    }
                    var payload: [AnyHashable: Any] = [:]
                    for (key, value) in normalized.rawPayload {
                        payload[key] = value
                    }
                    payload["_receivedAt"] = Self.makeISOFormatter().string(from: receivedAt)
                    let outcome = await NotificationPersistenceCoordinator.persistRemotePayloadIfNeeded(
                        payload,
                        requestIdentifier: deliveryId,
                        dataStore: localDataStore
                    )
                    switch outcome {
                    case .persisted, .duplicateMessage, .duplicateRequest:
                        do {
                            try await localDataStore.markInboundDeliveryPersisted(deliveryId: deliveryId)
                        } catch { return false }
                        return true
                    case .skipped, .failed: return false
                    }
                case .persisted: return true
                case .acked: return false
                }
            }
        )
    }
    #endif

    private func makeSummaryNotificationContent(base: UNMutableNotificationContent, count: Int) -> UNMutableNotificationContent {
        let updated = base
        let safeCount = max(2, count)
        updated.title = "PushGo"
        updated.body = "You received \(safeCount) new messages."
        var userInfo = updated.userInfo
        userInfo["_skip_persist"] = "1"
        userInfo["private_multi_count"] = safeCount
        updated.userInfo = userInfo
        return updated
    }

    private func loadPrivateRuntimeConfig() async -> (
        baseURL: URL,
        authToken: String?,
        platform: String,
        systemToken: String?,
        channels: [(id: String, password: String)]
    )? {
        let serverConfig: ServerConfig?
        #if os(watchOS)
        serverConfig = try? await localDataStore.loadWatchProvisioningServerConfig()
        #else
        serverConfig = try? await localDataStore.loadServerConfig()
        #endif
        guard let serverConfig else {
            return nil
        }
        let channels = ((try? await localDataStore.activeChannelCredentials(gateway: serverConfig.gatewayKey)) ?? [])
            .map { (id: $0.channelId, password: $0.password) }
        guard !channels.isEmpty else { return nil }
        let systemToken = await localDataStore.cachedPushToken(for: privatePlatformIdentifier())
        return (
            baseURL: serverConfig.baseURL,
            authToken: serverConfig.token,
            platform: privatePlatformIdentifier(),
            systemToken: systemToken,
            channels: channels
        )
    }

    #if !os(watchOS)
    private func ensureProviderDeviceKey(
        baseURL: URL,
        authToken: String?,
        platform: String
    ) async -> String? {
        let existing = await localDataStore.cachedProviderDeviceKey(for: platform)?
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        let bootstrap = existing?.isEmpty == false ? existing : nil
        do {
            let payload = try await postGateway(
                path: "/device/register",
                baseURL: baseURL,
                authToken: authToken,
                body: DeviceRegisterRequest(
                    platform: platform,
                    deviceKey: bootstrap
                ),
                responseType: DeviceRegisterPayload.self
            )
            let resolved = payload.deviceKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !resolved.isEmpty else { return bootstrap }
            await localDataStore.saveCachedProviderDeviceKey(resolved, for: platform)
            return resolved
        } catch {
            return bootstrap
        }
    }

    private func pullMessages(
        baseURL: URL,
        authToken: String?,
        deviceKey: String,
        channelId: String,
        password: String,
        limit: Int
    ) async throws -> [PullItem] {
        let payload = try await postGateway(
            path: "/messages/pull",
            baseURL: baseURL,
            authToken: authToken,
            body: PullRequest(
                deviceKey: deviceKey,
                channelId: channelId,
                password: password,
                limit: max(1, min(limit, 200))
            ),
            responseType: PullResponse.self
        )
        return payload.items
    }

    private func ackMessages(
        baseURL: URL,
        authToken: String?,
        deviceKey: String,
        deliveryIds: [String]
    ) async throws -> Set<String> {
        let normalized = Array(Set(deliveryIds.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }))
        guard !normalized.isEmpty else { return [] }

        let validated = try validatedBaseURL(baseURL)
        let url = try buildGatewayURL(baseURL: validated, path: "/messages/ack/batch")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = AppConstants.deviceRegistrationTimeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let authToken, !authToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONEncoder().encode(
            AckBatchRequest(deviceKey: deviceKey, deliveryIds: normalized)
        )
        let (data, response) = try await URLSession.shared.data(for: request)
        let payload = try decodeGatewayPayload(AckBatchResponse.self, data: data, response: response)
        return Set(payload.ackedDeliveryIds)
    }

    private func postGateway<T: Encodable, R: Decodable>(
        path: String,
        baseURL: URL,
        authToken: String?,
        body: T,
        responseType: R.Type
    ) async throws -> R {
        let validated = try validatedBaseURL(baseURL)
        let url = try buildGatewayURL(baseURL: validated, path: path)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = AppConstants.deviceRegistrationTimeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let authToken, !authToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await URLSession.shared.data(for: request)
        return try decodeGatewayPayload(responseType, data: data, response: response)
    }

    private func buildGatewayURL(baseURL: URL, path: String) throws -> URL {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw AppError.invalidURL
        }
        let cleanPath = path.hasPrefix("/") ? path : "/" + path
        var basePath = components.path
        if basePath.hasSuffix("/") {
            basePath.removeLast()
        }
        components.path = basePath + cleanPath
        guard let url = components.url else {
            throw AppError.invalidURL
        }
        return url
    }

    private func validatedBaseURL(_ baseURL: URL) throws -> URL {
        guard let resolved = URLSanitizer.validatedServerURL(baseURL) else {
            throw AppError.invalidURL
        }
        return resolved
    }

    private func decodeGatewayPayload<T: Decodable>(
        _ type: T.Type,
        data: Data,
        response: URLResponse
    ) throws -> T {
        guard let http = response as? HTTPURLResponse else {
            throw AppError.serverUnreachable
        }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw AppError.authFailed
        }
        let decoded = try JSONDecoder().decode(GatewayStatusResponse<T>.self, from: data)
        if decoded.success, let payload = decoded.data {
            return payload
        }
        if let message = decoded.error?.trimmingCharacters(in: .whitespacesAndNewlines),
           !message.isEmpty
        {
            throw AppError.unknown("HTTP \(http.statusCode): \(message)")
        }
        if http.statusCode < 200 || http.statusCode >= 300 {
            throw AppError.unknown("HTTP \(http.statusCode): request failed")
        }
        throw AppError.unknown("Request failed")
    }

    #endif

    #if !os(watchOS)
    private func applyPulledPayload(
        _ item: PrivateWakeupPullItem,
        to content: inout UNMutableNotificationContent
    ) {
        var merged = content.userInfo
        for (key, value) in item.payload {
            merged[key] = value
        }
        if merged["delivery_id"] == nil {
            merged["delivery_id"] = item.deliveryId
        }
        merged["private_wakeup_handled"] = "1"
        merged["_skip_persist"] = "1"
        content.userInfo = merged

        if let title = trimmed(item.payload["title"]) {
            content.title = title
            merged["title"] = title
        }
        if let body = trimmed(item.payload["body"]) {
            content.body = body
            merged["body"] = body
        }
        if let channel = trimmed(item.payload["channel_id"] ?? item.payload["channel"]) {
            content.threadIdentifier = channel
            merged["channel_id"] = channel
        }
        content.userInfo = merged
    }
    #endif

    private func trimmed(_ value: String?) -> String? {
        let text = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? nil : text
    }

    private func privatePlatformIdentifier() -> String {
        #if os(iOS)
        return "ios"
        #elseif os(macOS)
        return "macos"
        #elseif os(watchOS)
        return "watchos"
        #else
        return "unknown"
        #endif
    }

    private func isPrivateWakeupPayload(_ payload: [AnyHashable: Any]) -> Bool {
        if let mode = payload["private_mode"] as? String, mode == "wakeup" {
            return true
        }
        if let wakeup = payload["private_wakeup"] as? String, wakeup == "1" || wakeup.lowercased() == "true" {
            return true
        }
        if let wakeup = payload["private_wakeup"] as? NSNumber, wakeup.intValue == 1 {
            return true
        }
        if let wakeup = payload["private_wakeup"] as? Bool, wakeup {
            return true
        }
        return false
    }

    private func persistMessage(for request: UNNotificationRequest, content: UNMutableNotificationContent) async {
        let store = localDataStore
        var unreadCount = 1
        do {
            let outcome = await NotificationPersistenceCoordinator.persistIfNeeded(
                request: request,
                content: content,
                dataStore: store
            )
            switch outcome {
            case .skipped, .duplicateRequest, .duplicateMessage:
                let counts = try await store.messageCounts()
                unreadCount = counts.unread
            case .failed:
                let counts = try await store.messageCounts()
                unreadCount = counts.unread
            case .persisted:
                await store.flushWrites()
                let counts = try await store.messageCounts()
                unreadCount = counts.unread
                DarwinNotificationPoster.post(name: AppConstants.messageSyncNotificationName)
            }
        } catch {
        }
        content.badge = NSNumber(value: unreadCount)
    }

    private static func makeISOFormatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }
}
