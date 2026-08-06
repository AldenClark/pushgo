import Foundation
import UserNotifications

private enum WatchNotificationIngressResolution {
    case direct(payload: [AnyHashable: Any], requestIdentifier: String?)
    case pulled(payload: [AnyHashable: Any], requestIdentifier: String, context: WatchPullContext)
    case unresolvedWakeup(payload: [AnyHashable: Any], requestIdentifier: String?)
}

private enum WatchPullContract {
    case v2
    case legacy
}

private struct WatchPullContext {
    let contract: WatchPullContract
    let baseURL: URL
    let token: String?
    let deviceKey: String
    let claimLease: ProviderWakeupPullClaimStore.ClaimLease

    var requiresAck: Bool { contract == .v2 }
}

private struct WatchWakeupServerCandidate {
    let baseURL: URL
    let token: String?
}

private struct WatchPullRequest: Encodable {
    let deviceKey: String
    let deliveryId: String

    enum CodingKeys: String, CodingKey {
        case deviceKey = "device_key"
        case deliveryId = "delivery_id"
    }
}

private struct WatchAckRequest: Encodable {
    let deviceKey: String
    let deliveryId: String

    enum CodingKeys: String, CodingKey {
        case deviceKey = "device_key"
        case deliveryId = "delivery_id"
    }
}

private struct WatchBatchAckRequest: Encodable {
    let deviceKey: String
    let deliveryIds: [String]

    enum CodingKeys: String, CodingKey {
        case deviceKey = "device_key"
        case deliveryIds = "delivery_ids"
    }
}

private struct WatchPullEnvelope<T: Decodable>: Decodable {
    let success: Bool
    let error: String?
    let errorCode: String?
    let problem: WatchProblem?
    let data: T?

    enum CodingKeys: String, CodingKey {
        case success
        case error
        case errorCode = "error_code"
        case problem
        case data
    }
}

private struct WatchProblem: Decodable {
    let code: String?
    let status: Int?
}

private struct WatchPullResponse: Decodable {
    let items: [WatchPullItem]
    let hasMore: Bool?

    enum CodingKeys: String, CodingKey {
        case items
        case hasMore = "has_more"
    }
}

private struct WatchAckResponse: Decodable {
    let removed: Bool
}

private struct WatchBatchAckResponse: Decodable {
    let requestedCount: Int
    let removedCount: Int

    enum CodingKeys: String, CodingKey {
        case requestedCount = "requested_count"
        case removedCount = "removed_count"
    }
}

private struct WatchPullItem: Decodable {
    let deliveryId: String
    let payload: [String: String]

    enum CodingKeys: String, CodingKey {
        case deliveryId = "delivery_id"
        case payload
    }
}

private struct WatchPullResult {
    let items: [WatchPullItem]
    let contract: WatchPullContract
}

@MainActor
final class WatchNotificationServiceProcessor {
    private let contentPreparer = NotificationContentPreparer()
    private let deviceKeyStore = ProviderDeviceKeyStore()
    private let notificationIngressInbox: NotificationIngressInbox
    private let ackFailureStore: ProviderDeliveryAckFailureStore
    private let wakeupPullClaimStore: ProviderWakeupPullClaimStore
    private let gatewayTokenStore: ProviderGatewayTokenStore

    init(
        notificationIngressInbox: NotificationIngressInbox = .shared,
        ackFailureStore: ProviderDeliveryAckFailureStore = .shared,
        wakeupPullClaimStore: ProviderWakeupPullClaimStore = .shared,
        gatewayTokenStore: ProviderGatewayTokenStore = ProviderGatewayTokenStore()
    ) {
        self.notificationIngressInbox = notificationIngressInbox
        self.ackFailureStore = ackFailureStore
        self.wakeupPullClaimStore = wakeupPullClaimStore
        self.gatewayTokenStore = gatewayTokenStore
    }

    func process(
        request: UNNotificationRequest,
        content: UNMutableNotificationContent
    ) async -> UNNotificationContent {
        let ingress = await resolveIngress(from: request.content.userInfo)
        applyIngressPayloadIfNeeded(ingress, to: content)
        let content = await contentPreparer.prepare(content)
        await markAckPreparingIfNeeded(ingress: ingress)
        let enqueued = await enqueueIngressInboxEntry(
            for: request,
            ingress: ingress,
            content: content
        )
        if enqueued {
            await markAckInboxDurableIfNeeded(ingress: ingress)
            await finalizePullClaimIfNeeded(ingress: ingress, durable: true)
            DarwinNotificationPoster.post(name: AppConstants.notificationIngressChangedNotificationName)
            await ackIngressIfNeeded(ingress: ingress)
        } else {
            await finalizePullClaimIfNeeded(ingress: ingress, durable: false)
        }

        return content
    }

    @discardableResult
    private func enqueueIngressInboxEntry(
        for request: UNNotificationRequest,
        ingress: WatchNotificationIngressResolution,
        content: UNNotificationContent
    ) async -> Bool {
        let ingressRequestIdentifier: String?
        switch ingress {
        case let .direct(_, requestIdentifier):
            ingressRequestIdentifier = requestIdentifier
        case let .pulled(_, requestIdentifier, _):
            ingressRequestIdentifier = requestIdentifier
        case let .unresolvedWakeup(_, requestIdentifier):
            ingressRequestIdentifier = requestIdentifier
        }
        let codablePayload = codablePayloadDictionary(from: content.userInfo)
        return await notificationIngressInbox.enqueue(
            codablePayload: codablePayload,
            requestIdentifier: ingressRequestIdentifier ?? request.identifier,
            source: "watch_nse"
        )
    }

    private func ackIngressIfNeeded(
        ingress: WatchNotificationIngressResolution
    ) async {
        let deliveryId: String?
        let identity: ProviderDeliveryAckFailureStore.DeliveryIdentity?
        let ackToken: String?
        switch ingress {
        case let .direct(resolvedPayload, _):
            guard providerWakeupDeliveryId(from: UserInfoSanitizer.sanitize(resolvedPayload)) == nil else {
                return
            }
            identity = ProviderDeliveryAckFailureStore.DeliveryIdentity.direct(
                from: UserInfoSanitizer.sanitize(resolvedPayload)
            )
            deliveryId = identity?.deliveryId
            ackToken = identity.flatMap { gatewayTokenStore.load(baseURL: $0.baseURL) }
        case let .pulled(_, requestIdentifier, context):
            guard context.requiresAck else { return }
            deliveryId = requestIdentifier
            identity = ProviderDeliveryAckFailureStore.DeliveryIdentity(
                deliveryId: requestIdentifier,
                baseURL: context.baseURL,
                deviceKey: context.deviceKey,
                ackContract: .v2Batch
            )
            ackToken = context.token
        case .unresolvedWakeup:
            return
        }
        guard let deliveryId, let identity else { return }
        if identity.ackContract == .v2Batch {
            guard let lease = await ackFailureStore.acquireAckLease(
                identity: identity,
                owner: "watch.nse",
                leaseDuration: 120
            ) else { return }
            do {
                try await ackMessages(
                    baseURL: identity.baseURL,
                    token: ackToken,
                    deviceKey: identity.deviceKey,
                    deliveryIds: [deliveryId]
                )
                await ackFailureStore.markCompleted(lease)
            } catch {
                await ackFailureStore.markAckFailed(
                    lease,
                    source: "watch_nse_ack_failed",
                    retryAfter: Date().addingTimeInterval(30)
                )
            }
            return
        }
        guard let lease = await ackFailureStore.acquireAckLease(
            identity: identity,
            owner: "watch.nse",
            leaseDuration: 120
        ) else {
            return
        }
        do {
            let removed = try await ackMessage(
                baseURL: identity.baseURL,
                token: ackToken,
                deviceKey: identity.deviceKey,
                deliveryId: deliveryId
            )
            guard removed || lease.attemptCount > 0 else {
                throw WatchWakeupResolutionError.pullRejected
            }
            await ackFailureStore.markCompleted(lease)
            return
        } catch {
            await ackFailureStore.markAckFailed(
                lease,
                source: "watch_nse_ack_failed",
                retryAfter: Date().addingTimeInterval(30)
            )
        }
    }

    private func markAckPreparingIfNeeded(
        ingress: WatchNotificationIngressResolution
    ) async {
        await markAckMarkerIfNeeded(ingress: ingress, stage: .preparing)
    }

    private func markAckInboxDurableIfNeeded(
        ingress: WatchNotificationIngressResolution
    ) async {
        await markAckMarkerIfNeeded(ingress: ingress, stage: .inboxDurable)
    }

    private func markAckMarkerIfNeeded(
        ingress: WatchNotificationIngressResolution,
        stage: ProviderDeliveryAckFailureStore.Stage
    ) async {
        let identity: ProviderDeliveryAckFailureStore.DeliveryIdentity?
        switch ingress {
        case let .direct(resolvedPayload, _):
            guard providerWakeupDeliveryId(from: UserInfoSanitizer.sanitize(resolvedPayload)) == nil else {
                return
            }
            identity = ProviderDeliveryAckFailureStore.DeliveryIdentity.direct(
                from: UserInfoSanitizer.sanitize(resolvedPayload)
            )
        case let .pulled(_, requestIdentifier, context):
            guard context.requiresAck else { return }
            identity = ProviderDeliveryAckFailureStore.DeliveryIdentity(
                deliveryId: requestIdentifier,
                baseURL: context.baseURL,
                deviceKey: context.deviceKey,
                ackContract: .v2Batch
            )
        case .unresolvedWakeup:
            return
        }
        guard let identity else { return }
        switch stage {
        case .preparing:
            _ = await ackFailureStore.markPreparing(
                identity: identity,
                source: "watch_nse_ack_preparing",
                postNotification: false
            )
        case .inboxDurable:
            _ = await ackFailureStore.markInboxDurable(
                identity: identity,
                source: "watch_nse_inbox_durable",
                postNotification: false
            )
        case .ackInFlight, .completed:
            break
        }
    }

    private func codablePayloadDictionary(
        from payload: [AnyHashable: Any]
    ) -> [String: AnyCodable] {
        let sanitized = UserInfoSanitizer.sanitize(payload)
        return sanitized.reduce(into: [String: AnyCodable]()) { result, item in
            result[item.key] = AnyCodable(item.value)
        }
    }

    private func resolveIngress(
        from payload: [AnyHashable: Any]
    ) async -> WatchNotificationIngressResolution {
        let sanitized = UserInfoSanitizer.sanitize(payload)
        guard let deliveryId = providerWakeupDeliveryId(from: sanitized) else {
            return .direct(
                payload: sanitized,
                requestIdentifier: directRequestIdentifier(from: sanitized)
            )
        }

        let candidates = await wakeupServerCandidates(from: sanitized)
        guard !candidates.isEmpty, let deviceKey = providerDeviceKey() else {
            return .unresolvedWakeup(payload: sanitized, requestIdentifier: deliveryId)
        }
        for candidate in candidates {
            if let token = candidate.token {
                _ = gatewayTokenStore.save(token: token, baseURL: candidate.baseURL)
            }
            guard let claimIdentity = ProviderDeliveryAckFailureStore.DeliveryIdentity(
                deliveryId: deliveryId,
                baseURL: candidate.baseURL,
                deviceKey: deviceKey,
                ackContract: .v2Batch
            ), let claimLease = await wakeupPullClaimStore.acquireLease(
                identity: claimIdentity,
                owner: "watch.nse",
                leaseDuration: 30
            ) else {
                continue
            }
            do {
                let pullResult = try await pullMessages(
                    baseURL: candidate.baseURL,
                    token: candidate.token,
                    deviceKey: deviceKey,
                    deliveryId: deliveryId
                )
                guard let item = pullResult.items.first else {
                    await wakeupPullClaimStore.releaseLease(claimLease)
                    continue
                }
                var pulledPayload: [AnyHashable: Any] = item.payload.reduce(into: [:]) { result, pair in
                    result[pair.key] = pair.value
                }
                pulledPayload["delivery_id"] = item.deliveryId
                return .pulled(
                    payload: UserInfoSanitizer.sanitize(pulledPayload),
                    requestIdentifier: nonEmpty(item.deliveryId) ?? deliveryId,
                    context: WatchPullContext(
                        contract: pullResult.contract,
                        baseURL: candidate.baseURL,
                        token: candidate.token,
                        deviceKey: deviceKey,
                        claimLease: claimLease
                    )
                )
            } catch {
                await wakeupPullClaimStore.releaseLease(claimLease)
                continue
            }
        }

        return .unresolvedWakeup(payload: sanitized, requestIdentifier: deliveryId)
    }

    private func finalizePullClaimIfNeeded(
        ingress: WatchNotificationIngressResolution,
        durable: Bool
    ) async {
        guard case let .pulled(_, _, context) = ingress else { return }
        if durable {
            await wakeupPullClaimStore.markCompleted(context.claimLease)
        } else {
            await wakeupPullClaimStore.releaseLease(context.claimLease)
        }
    }

    private func applyIngressPayloadIfNeeded(
        _ ingress: WatchNotificationIngressResolution,
        to content: UNMutableNotificationContent
    ) {
        switch ingress {
        case let .pulled(payload, _, _):
            applyResolvedPayload(payload, to: content)
        case let .unresolvedWakeup(payload, _):
            if let fallbackPayload = wakeupFallbackDisplayPayload(from: payload) {
                applyResolvedPayload(fallbackPayload, to: content)
            } else {
                content.userInfo = UserInfoSanitizer.sanitize(payload)
                if content.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   content.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                {
                    content.title = "收到消息"
                    content.body = "消息已收到，正在同步。"
                }
            }
        case .direct:
            break
        }
    }

    private func applyResolvedPayload(
        _ payload: [AnyHashable: Any],
        to content: UNMutableNotificationContent
    ) {
        let sanitized = UserInfoSanitizer.sanitize(payload)
        content.userInfo = sanitized
        if let normalized = normalizeDisplayPayload(sanitized) {
            content.title = normalized.title
            content.body = normalized.body
        } else {
            if let title = nonEmpty(sanitized["title"] as? String) {
                content.title = title
            }
            if let body = nonEmpty(sanitized["body"] as? String) {
                content.body = body
            }
        }
    }

    private func normalizeDisplayPayload(
        _ payload: [AnyHashable: Any]
    ) -> NotificationPayloadSemantics.NormalizedPayload? {
        let contextSnapshot = NotificationContextSnapshotStore.load()
        return NotificationPayloadSemantics.normalizeRemoteNotification(
            payload,
            contextSnapshot: contextSnapshot,
            localizeTypeLabel: { entityType in
                switch entityType {
                case "event":
                    "事件"
                case "thing":
                    "对象"
                default:
                    "消息"
                }
            },
            localizeThingAttributeUpdateBody: { _ in
                "属性已更新"
            },
            localizeThingAttributePair: { name, value in
                "\(name): \(value)"
            },
            localizeThingUpdatedBody: {
                "已更新"
            },
            localizeThingArchivedBody: {
                "已归档"
            },
            localizeThingDeletedBody: {
                "已删除"
            }
        )
    }

    private func wakeupFallbackDisplayPayload(
        from payload: [AnyHashable: Any]
    ) -> [AnyHashable: Any]? {
        let sanitized = UserInfoSanitizer.sanitize(payload)
        var displayPayload: [AnyHashable: Any] = sanitized.reduce(into: [:]) { result, entry in
            result[entry.key] = entry.value
        }
        if nonEmpty(displayPayload["title"] as? String) == nil,
           let title = fallbackAlertText(from: sanitized).title
        {
            displayPayload["title"] = title
        }
        if nonEmpty(displayPayload["body"] as? String) == nil,
           let body = fallbackAlertText(from: sanitized).body
        {
            displayPayload["body"] = body
        }
        guard nonEmpty(displayPayload["title"] as? String) != nil
            || nonEmpty(displayPayload["body"] as? String) != nil
        else {
            return nil
        }
        return displayPayload
    }

    private func fallbackAlertText(
        from payload: [String: Any]
    ) -> (title: String?, body: String?) {
        let aps = payload["aps"] as? [String: Any]
        let alert = aps?["alert"]
        if let text = alert as? String {
            return (nil, nonEmpty(text))
        }
        if let dict = alert as? [String: Any] {
            return (
                nonEmpty(dict["title"] as? String) ?? nonEmpty(dict["subtitle"] as? String),
                nonEmpty(dict["body"] as? String)
            )
        }
        return (nil, nil)
    }

    private func wakeupServerCandidates(from payload: [String: Any]) async -> [WatchWakeupServerCandidate] {
        var candidates: [WatchWakeupServerCandidate] = []
        var indexByBaseURL: [String: Int] = [:]

        func appendCandidate(baseURL: URL, token: String?) {
            let normalizedBaseURL = normalizedProviderGatewayURL(baseURL) ?? baseURL
            let key = normalizedBaseURL.absoluteString
            let normalizedToken = (token ?? gatewayTokenStore.load(baseURL: normalizedBaseURL))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let hasToken = normalizedToken?.isEmpty == false
            if let existingIndex = indexByBaseURL[key] {
                let existingHasToken = candidates[existingIndex].token?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .isEmpty == false
                if existingHasToken {
                    return
                }
                if hasToken {
                    candidates[existingIndex] = WatchWakeupServerCandidate(
                        baseURL: normalizedBaseURL,
                        token: normalizedToken
                    )
                }
                return
            }
            candidates.append(WatchWakeupServerCandidate(baseURL: normalizedBaseURL, token: normalizedToken))
            indexByBaseURL[key] = candidates.count - 1
        }

        if let payloadServerURL = wakeupGatewayURL(from: payload) {
            appendCandidate(baseURL: payloadServerURL, token: nil)
        }

        if let sharedConfig = sharedProvisioningServerConfig() {
            appendCandidate(baseURL: sharedConfig.baseURL, token: sharedConfig.token)
        }

        if let defaultServerURL = AppConstants.defaultServerURL {
            appendCandidate(
                baseURL: defaultServerURL,
                token: AppConstants.defaultGatewayToken
            )
        }

        return candidates
    }

    private func sharedProvisioningServerConfig() -> ServerConfig? {
        guard let data = AppConstants.sharedUserDefaults()
            .data(forKey: AppConstants.watchProvisioningServerConfigDefaultsKey)
        else {
            return nil
        }
        return try? JSONDecoder().decode(ServerConfig.self, from: data).normalized()
    }

    private func providerDeviceKey() -> String? {
        let deviceKey = deviceKeyStore.load(platform: "watchos")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return deviceKey?.isEmpty == false ? deviceKey : nil
    }

    private func pullMessages(
        baseURL: URL,
        token: String?,
        deviceKey: String,
        deliveryId: String
    ) async throws -> WatchPullResult {
        while true {
            try Task.checkCancellation()
            let v2 = try await requestPullMessages(
                baseURL: baseURL,
                token: token,
                deviceKey: deviceKey,
                deliveryId: deliveryId,
                path: "v2/messages/pull"
            )
            switch v2 {
            case let .items(response):
                if !response.items.isEmpty || response.hasMore != true {
                    return WatchPullResult(items: response.items, contract: .v2)
                }
            case .routeNotFound:
                break
            }
            if case .routeNotFound = v2 {
                break
            }
        }
        let legacy = try await requestPullMessages(
            baseURL: baseURL,
            token: token,
            deviceKey: deviceKey,
            deliveryId: deliveryId,
            path: "messages/pull"
        )
        guard case let .items(response) = legacy else {
            throw WatchWakeupResolutionError.pullRejected
        }
        return WatchPullResult(items: response.items, contract: .legacy)
    }

    private enum WatchPullAttempt {
        case items(WatchPullResponse)
        case routeNotFound

    }

    private func requestPullMessages(
        baseURL: URL,
        token: String?,
        deviceKey: String,
        deliveryId: String,
        path: String
    ) async throws -> WatchPullAttempt {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw WatchWakeupResolutionError.invalidServerURL
        }
        components.path = (components.path as NSString).appendingPathComponent(path)
        guard let url = components.url else {
            throw WatchWakeupResolutionError.invalidServerURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = AppConstants.deviceRegistrationTimeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token = nonEmpty(token) {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONEncoder().encode(
            WatchPullRequest(
                deviceKey: deviceKey,
                deliveryId: deliveryId
            )
        )

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw WatchWakeupResolutionError.invalidResponse
        }
        let envelope = try JSONDecoder().decode(WatchPullEnvelope<WatchPullResponse>.self, from: data)
        let responseCode = nonEmpty(envelope.errorCode) ?? nonEmpty(envelope.problem?.code)
        if httpResponse.statusCode == 404, responseCode?.lowercased() == "route_not_found" {
            return .routeNotFound
        }
        guard (200 ..< 300).contains(httpResponse.statusCode),
              envelope.success,
              let payload = envelope.data
        else {
            throw WatchWakeupResolutionError.pullRejected
        }
        return .items(payload)
    }

    private func ackMessages(
        baseURL: URL,
        token: String?,
        deviceKey: String,
        deliveryIds: [String]
    ) async throws {
        let normalizedDeliveryIds = Array(Set(deliveryIds.compactMap(nonEmpty))).sorted()
        guard !normalizedDeliveryIds.isEmpty, normalizedDeliveryIds.count <= 200 else {
            throw WatchWakeupResolutionError.pullRejected
        }
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw WatchWakeupResolutionError.invalidServerURL
        }
        components.path = (components.path as NSString).appendingPathComponent("v2/messages/ack")
        guard let url = components.url else {
            throw WatchWakeupResolutionError.invalidServerURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = AppConstants.deviceRegistrationTimeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token = nonEmpty(token) {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONEncoder().encode(
            WatchBatchAckRequest(deviceKey: deviceKey, deliveryIds: normalizedDeliveryIds)
        )
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw WatchWakeupResolutionError.invalidResponse
        }
        let envelope = try JSONDecoder().decode(WatchPullEnvelope<WatchBatchAckResponse>.self, from: data)
        guard (200 ..< 300).contains(httpResponse.statusCode),
              envelope.success,
              let payload = envelope.data,
              payload.requestedCount == normalizedDeliveryIds.count,
              payload.removedCount == payload.requestedCount
        else {
            throw WatchWakeupResolutionError.pullRejected
        }
    }

    private func ackMessage(
        baseURL: URL,
        token: String?,
        deviceKey: String,
        deliveryId: String
    ) async throws -> Bool {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw WatchWakeupResolutionError.invalidServerURL
        }
        components.path = (components.path as NSString).appendingPathComponent("messages/ack")
        guard let url = components.url else {
            throw WatchWakeupResolutionError.invalidServerURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = AppConstants.deviceRegistrationTimeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token = nonEmpty(token) {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONEncoder().encode(
            WatchAckRequest(
                deviceKey: deviceKey,
                deliveryId: deliveryId
            )
        )

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw WatchWakeupResolutionError.invalidResponse
        }
        let envelope = try JSONDecoder().decode(WatchPullEnvelope<WatchAckResponse>.self, from: data)
        guard (200 ..< 300).contains(httpResponse.statusCode),
              envelope.success,
              let payload = envelope.data
        else {
            throw WatchWakeupResolutionError.pullRejected
        }
        return payload.removed
    }

    private func providerWakeupDeliveryId(from payload: [String: Any]) -> String? {
        guard normalizedBoolean(payload["provider_wakeup"]) == true else {
            return nil
        }
        let mode = nonEmpty(payload["provider_mode"] as? String)?.lowercased()
        guard mode == nil || mode == "wakeup" else {
            return nil
        }
        return nonEmpty(payload["delivery_id"] as? String)
    }

    private func directRequestIdentifier(from payload: [String: Any]) -> String? {
        nonEmpty(payload["delivery_id"] as? String)
    }

    private func wakeupGatewayURL(from payload: [String: Any]) -> URL? {
        let candidates = [
            payload["gateway"] as? String,
            payload["gateway_url"] as? String,
            payload["base_url"] as? String,
            payload["server"] as? String,
            payload["server_url"] as? String,
        ]
        for candidate in candidates {
            guard let url = validatedServerURL(from: candidate) else { continue }
            return url
        }
        return nil
    }

    private func validatedServerURL(from raw: String?) -> URL? {
        guard let text = nonEmpty(raw),
              let url = URL(string: text),
              let scheme = url.scheme?.lowercased(),
              (scheme == "http" || scheme == "https"),
              let host = url.host,
              !host.isEmpty
        else {
            return nil
        }
        return url
    }

    private func nonEmpty(_ raw: String?) -> String? {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private func normalizedBoolean(_ value: Any?) -> Bool? {
        switch value {
        case let bool as Bool:
            return bool
        case let number as NSNumber:
            return number.intValue != 0
        case let string as String:
            let normalized = string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            switch normalized {
            case "1", "true", "yes", "on":
                return true
            case "0", "false", "no", "off":
                return false
            default:
                return nil
            }
        default:
            return nil
        }
    }
}

private enum WatchWakeupResolutionError: Error {
    case invalidServerURL
    case invalidResponse
    case pullRejected
}
