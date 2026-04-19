import Foundation
import UserNotifications

private enum WatchNotificationIngressResolution {
    case direct(payload: [AnyHashable: Any], requestIdentifier: String?)
    case pulled(payload: [AnyHashable: Any], requestIdentifier: String)
    case unresolvedWakeup(payload: [AnyHashable: Any], requestIdentifier: String?)
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

private struct WatchPullEnvelope<T: Decodable>: Decodable {
    let success: Bool
    let error: String?
    let data: T?
}

private struct WatchPullResponse: Decodable {
    let items: [WatchPullItem]
}

private struct WatchPullItem: Decodable {
    let deliveryId: String
    let payload: [String: String]

    enum CodingKeys: String, CodingKey {
        case deliveryId = "delivery_id"
        case payload
    }
}

@MainActor
final class WatchNotificationServiceProcessor {
    private let contentPreparer = NotificationContentPreparer()
    private let deviceKeyStore = ProviderDeviceKeyStore()
    private let store: WatchLightNotificationStore?

    init(store: WatchLightNotificationStore? = try? WatchLightNotificationStore()) {
        self.store = store
    }

    func process(
        request: UNNotificationRequest,
        content: UNMutableNotificationContent
    ) async -> UNNotificationContent {
        let ingress = await resolveIngress(from: request.content.userInfo)
        applyIngressPayloadIfNeeded(ingress, to: content)
        let content = await contentPreparer.prepare(content)
        await persistIfNeeded(ingress: ingress, request: request, content: content)

        if let store, let unreadCount = try? await store.unreadCount() {
            content.badge = NSNumber(value: unreadCount)
        }

        return content
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
            do {
                let items = try await pullMessages(
                    baseURL: candidate.baseURL,
                    token: candidate.token,
                    deviceKey: deviceKey,
                    deliveryId: deliveryId
                )
                guard let item = items.first else { continue }
                let pulledPayload: [AnyHashable: Any] = item.payload.reduce(into: [:]) { result, pair in
                    result[pair.key] = pair.value
                }
                return .pulled(
                    payload: UserInfoSanitizer.sanitize(pulledPayload),
                    requestIdentifier: nonEmpty(item.deliveryId) ?? deliveryId
                )
            } catch {
                continue
            }
        }

        return .unresolvedWakeup(payload: sanitized, requestIdentifier: deliveryId)
    }

    private func applyIngressPayloadIfNeeded(
        _ ingress: WatchNotificationIngressResolution,
        to content: UNMutableNotificationContent
    ) {
        switch ingress {
        case let .pulled(payload, _):
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

    private func persistIfNeeded(
        ingress: WatchNotificationIngressResolution,
        request: UNNotificationRequest,
        content: UNNotificationContent
    ) async {
        guard let store else { return }

        let title = content.title
        let body = content.body
        let fallbackRequestIdentifier = request.identifier

        switch ingress {
        case let .pulled(payload, requestIdentifier):
            if let payload = quantizePayload(
                payload,
                titleOverride: title,
                bodyOverride: body,
                notificationRequestId: requestIdentifier
            ) {
                try? await store.upsert(payload)
            }
        case let .direct(payload, requestIdentifier):
            guard !shouldSkipPersistence(for: payload) else { return }
            if let payload = quantizePayload(
                payload,
                titleOverride: title,
                bodyOverride: body,
                notificationRequestId: requestIdentifier ?? fallbackRequestIdentifier
            ) {
                try? await store.upsert(payload)
                await ackProviderIngressIfNeeded(
                    ingress: ingress,
                    requestIdentifier: requestIdentifier
                )
            }
        case let .unresolvedWakeup(payload, requestIdentifier):
            _ = payload
            _ = requestIdentifier
            _ = fallbackRequestIdentifier
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
        NotificationPayloadSemantics.normalizeRemoteNotification(
            payload,
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

    private func ackProviderIngressIfNeeded(
        ingress: WatchNotificationIngressResolution,
        requestIdentifier: String?
    ) async {
        guard let store else { return }
        guard let config = (try? await store.loadProvisioningServerConfig())?.normalized() else { return }
        let deviceKey = providerDeviceKey() ?? ""
        guard !deviceKey.isEmpty else { return }
        let deliveryId: String?
        switch ingress {
        case let .direct(payload, _):
            if providerWakeupDeliveryId(from: UserInfoSanitizer.sanitize(payload)) != nil {
                return
            }
            deliveryId = requestIdentifier ?? directRequestIdentifier(from: UserInfoSanitizer.sanitize(payload))
        case .pulled:
            return
        case .unresolvedWakeup:
            return
        }
        guard let normalizedDeliveryId = nonEmpty(deliveryId) else { return }
        try? await ackMessage(
            baseURL: config.baseURL,
            token: config.token,
            deviceKey: deviceKey,
            deliveryId: normalizedDeliveryId
        )
    }

    private func quantizePayload(
        _ payload: [AnyHashable: Any],
        titleOverride: String?,
        bodyOverride: String?,
        notificationRequestId: String?
    ) -> WatchLightPayload? {
        WatchStandaloneLightQuantizer.quantizePayload(
            WatchStandaloneLightQuantizer.stringifyPayload(payload),
            titleOverride: titleOverride,
            bodyOverride: bodyOverride,
            urlOverride: nil,
            notificationRequestId: notificationRequestId
        )
    }

    private func wakeupServerCandidates(from payload: [String: Any]) async -> [WatchWakeupServerCandidate] {
        var candidates: [WatchWakeupServerCandidate] = []
        var dedupe = Set<String>()

        func appendCandidate(baseURL: URL, token: String?) {
            let dedupeKey = "\(baseURL.absoluteString.lowercased())|\(token ?? "")"
            guard dedupe.insert(dedupeKey).inserted else { return }
            candidates.append(WatchWakeupServerCandidate(baseURL: baseURL, token: token))
        }

        if let payloadServerURL = wakeupGatewayURL(from: payload) {
            appendCandidate(baseURL: payloadServerURL, token: nil)
        }

        if let store,
           let config = (try? await store.loadProvisioningServerConfig())?.normalized()
        {
            appendCandidate(baseURL: config.baseURL, token: config.token)
        }

        return candidates
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
    ) async throws -> [WatchPullItem] {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw WatchWakeupResolutionError.invalidServerURL
        }
        components.path = (components.path as NSString).appendingPathComponent("messages/pull")
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
        guard (200 ..< 300).contains(httpResponse.statusCode),
              envelope.success,
              let payload = envelope.data
        else {
            throw WatchWakeupResolutionError.pullRejected
        }
        return payload.items
    }

    private func ackMessage(
        baseURL: URL,
        token: String?,
        deviceKey: String,
        deliveryId: String
    ) async throws {
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

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200 ..< 300).contains(httpResponse.statusCode)
        else {
            throw WatchWakeupResolutionError.pullRejected
        }
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

    private func shouldSkipPersistence(for payload: [AnyHashable: Any]) -> Bool {
        let sanitized = UserInfoSanitizer.sanitize(payload)
        return normalizedBoolean(sanitized["_skip_persist"]) == true
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
