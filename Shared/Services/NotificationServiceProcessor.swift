import Foundation
import UserNotifications

final class NotificationServiceProcessor {
    #if !os(watchOS)
    private struct PrivateWakeupHydrationSnapshot: Sendable {
        let persistedItems: [PrivateWakeupPullItem]

        static let empty = PrivateWakeupHydrationSnapshot(persistedItems: [])
    }

    #endif

    #if !os(watchOS)
    private struct GatewayStatusResponse<T: Decodable>: Decodable {
        let success: Bool
        let error: String?
        let data: T?
    }

    private struct PullRequest: Encodable {
        let deliveryId: String

        enum CodingKeys: String, CodingKey {
            case deliveryId = "delivery_id"
        }
    }

    private struct PullResponse: Decodable {
        let item: PullItem?
    }

    private struct PullItem: Decodable {
        let deliveryId: String
        let payload: [String: String]

        enum CodingKeys: String, CodingKey {
            case deliveryId = "delivery_id"
            case payload
        }
    }

    private struct EmptyPayload: Decodable {
        init(from _: Decoder) throws {}
    }
    #endif

    private let localDataStore = LocalDataStore()
    private let contentPreparer = NotificationContentPreparer()
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
        guard let deliveryId = extractWakeupDeliveryId(from: content.userInfo) else {
            return content
        }
        let snapshot = await performPrivateWakeupHydration(
            requestIdentifier: requestIdentifier,
            runtime: runtime,
            deliveryId: deliveryId
        )
        let persistedItems = snapshot.persistedItems
        guard !persistedItems.isEmpty else {
            return makeWakeupFallbackNotificationContent(base: content)
        }
        var hydrated = content
        if let first = persistedItems.first {
            applyPulledPayload(first, to: &hydrated)
        }
        if persistedItems.count > 1 {
            hydrated = makeSummaryNotificationContent(base: hydrated, count: persistedItems.count)
        }
        if let unread = try? await localDataStore.messageCounts().unread {
            hydrated.badge = NSNumber(value: unread)
        }
        return hydrated
        #endif
    }

    #if !os(watchOS)
    private func performPrivateWakeupHydration(
        requestIdentifier: String,
        runtime: (
            baseURL: URL,
            authToken: String?
        ),
        deliveryId: String
    ) async -> PrivateWakeupHydrationSnapshot {
        var pulledItems: [PrivateWakeupPullItem] = []
        if let pulled = try? await pullMessage(
            baseURL: runtime.baseURL,
            authToken: runtime.authToken,
            deliveryId: deliveryId
        ) {
            pulledItems.append(
                PrivateWakeupPullItem(deliveryId: pulled.deliveryId, payload: pulled.payload)
            )
        }
        guard !pulledItems.isEmpty else {
            return .empty
        }

        let persistedDeliveryIds = await persistPulledItems(
            pulledItems,
            requestIdentifier: requestIdentifier,
            runtime: runtime
        )
        guard !persistedDeliveryIds.isEmpty else { return .empty }
        await localDataStore.flushWrites()
        DarwinNotificationPoster.post(name: AppConstants.messageSyncNotificationName)
        let persistedItems = pulledItems
        return .init(persistedItems: persistedItems)
    }
    #endif

    #if !os(watchOS)
    private func persistPulledItems(
        _ items: [PrivateWakeupPullItem],
        requestIdentifier: String,
        runtime: (
            baseURL: URL,
            authToken: String?
        )
    ) async -> Set<String> {
        let receivedAt = Date()
        var seenMessageIds = Set<String>()
        return await PrivateWakeupPullCoordinator.processPulledItems(
            items,
            dataStore: localDataStore,
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
                    case .persistedMain, .persistedPending, .duplicate, .rejected:
                        do {
                            try await localDataStore.markInboundDeliveryPersisted(deliveryId: deliveryId)
                        } catch { return false }
                        return true
                    case .failed: return false
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

    private func makeWakeupFallbackNotificationContent(
        base: UNMutableNotificationContent
    ) -> UNMutableNotificationContent {
        let updated = base
        updated.title = trimmed(base.title) ?? "收到新通知"
        updated.body = "消息内容正在同步，请稍后打开 PushGo 查看。"
        var userInfo = updated.userInfo
        userInfo["_skip_persist"] = "1"
        userInfo["private_wakeup_handled"] = "1"
        userInfo["private_wakeup_pull_failed"] = "1"
        updated.userInfo = userInfo
        return updated
    }

    private func loadPrivateRuntimeConfig() async -> (
        baseURL: URL,
        authToken: String?
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
        return (
            baseURL: serverConfig.baseURL,
            authToken: serverConfig.token
        )
    }

    #if !os(watchOS)
    private func pullMessage(
        baseURL: URL,
        authToken: String?,
        deliveryId: String
    ) async throws -> PullItem? {
        let payload = try await postGateway(
            path: "/messages/pull",
            baseURL: baseURL,
            authToken: authToken,
            body: PullRequest(
                deliveryId: deliveryId
            ),
            responseType: PullResponse.self
        )
        return payload.item
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
            merged["channel_id"] = channel
        }
        let bridgedUserInfo = merged.reduce(into: [AnyHashable: Any]()) { result, entry in
            result[entry.key] = entry.value
        }
        if let normalized = NotificationHandling.normalizeRemoteNotification(bridgedUserInfo) {
            content.title = normalized.title
            content.body = normalized.body
            merged["title"] = normalized.title
            merged["body"] = normalized.body
        }
        if let threadIdentifier = NotificationPayloadSemantics.notificationThreadIdentifier(from: bridgedUserInfo) {
            content.threadIdentifier = threadIdentifier
        }
        content.userInfo = merged
    }
    #endif

    private func trimmed(_ value: String?) -> String? {
        let text = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? nil : text
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

    private func extractWakeupDeliveryId(from payload: [AnyHashable: Any]) -> String? {
        let deliveryId = (payload["delivery_id"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return deliveryId.isEmpty ? nil : deliveryId
    }

    private func persistMessage(for request: UNNotificationRequest, content: UNMutableNotificationContent) async {
        let store = localDataStore
        var unreadCount = 1
        var persistenceFailed = false
        var shouldNotifyStoreChanged = false
        do {
            let outcome = await NotificationPersistenceCoordinator.persistIfNeeded(
                request: request,
                content: content,
                dataStore: store
            )
            switch outcome {
            case .duplicate, .persistedPending:
                await store.flushWrites()
                shouldNotifyStoreChanged = true
                let counts = try await store.messageCounts()
                unreadCount = counts.unread
            case .rejected:
                let counts = try await store.messageCounts()
                unreadCount = counts.unread
            case .failed:
                let counts = try await store.messageCounts()
                unreadCount = counts.unread
                persistenceFailed = true
            case .persistedMain:
                await store.flushWrites()
                shouldNotifyStoreChanged = true
                let counts = try await store.messageCounts()
                unreadCount = counts.unread
            }
        } catch {
            persistenceFailed = true
        }
        if shouldNotifyStoreChanged {
            DarwinNotificationPoster.post(name: AppConstants.messageSyncNotificationName)
        }
        if persistenceFailed {
            applyPersistenceFailureNotice(to: content)
        }
        content.badge = NSNumber(value: unreadCount)
    }

    private func applyPersistenceFailureNotice(to content: UNMutableNotificationContent) {
        content.title = "收到消息"
        content.body = "消息已收到，但入库失败。"
        var userInfo = content.userInfo
        userInfo["_skip_persist"] = "1"
        userInfo["_persist_failed"] = "1"
        content.userInfo = userInfo
    }

    private static func makeISOFormatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }
}
