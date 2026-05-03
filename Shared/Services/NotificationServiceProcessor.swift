import Foundation
import UserNotifications

final class NotificationServiceProcessor {
    private struct WakeupServerCandidate {
        let baseURL: URL
        let token: String?
    }

    private static let sharedChannelSubscriptionService = ChannelSubscriptionService()
    private static let sharedNotificationIngressInbox = NotificationIngressInbox.shared
    private static let sharedAckFailureStore = ProviderDeliveryAckFailureStore.shared

    private let contentPreparer: NotificationContentPreparer
    private let channelSubscriptionService: ChannelSubscriptionService
    private let notificationIngressInbox: NotificationIngressInbox
    private let ackFailureStore: ProviderDeliveryAckFailureStore
    private let localConfigStore: LocalKeychainConfigStore
    private let deviceKeyStore: ProviderDeviceKeyStore

    init(
        channelSubscriptionService: ChannelSubscriptionService = NotificationServiceProcessor.sharedChannelSubscriptionService,
        notificationIngressInbox: NotificationIngressInbox = NotificationServiceProcessor.sharedNotificationIngressInbox,
        ackFailureStore: ProviderDeliveryAckFailureStore = NotificationServiceProcessor.sharedAckFailureStore,
        localConfigStore: LocalKeychainConfigStore = LocalKeychainConfigStore(),
        deviceKeyStore: ProviderDeviceKeyStore = ProviderDeviceKeyStore(),
        contentPreparer: NotificationContentPreparer = NotificationContentPreparer()
    ) {
        self.channelSubscriptionService = channelSubscriptionService
        self.notificationIngressInbox = notificationIngressInbox
        self.ackFailureStore = ackFailureStore
        self.localConfigStore = localConfigStore
        self.deviceKeyStore = deviceKeyStore
        self.contentPreparer = contentPreparer
    }

    func process(
        request: UNNotificationRequest,
        content: UNMutableNotificationContent
    ) async -> UNNotificationContent {
        let ingress = await resolveNotificationIngressWithoutDatabase(from: request.content.userInfo)
        NSEPersistenceDiagnostics.record(
            phase: "ingress_resolved",
            requestIdentifier: request.identifier,
            payload: request.content.userInfo,
            ingressType: Self.ingressTypeName(ingress),
            outcome: nil,
            error: nil
        )
        let content = await prepareContentForPersistence(content: content, ingress: ingress)
        await markAckPreparingIfNeeded(ingress)
        let enqueued = await enqueueIngressInboxEntry(
            for: request,
            ingress: ingress,
            preparedContent: content
        )
        if enqueued {
            await markAckInboxDurableIfNeeded(ingress)
            DarwinNotificationPoster.post(name: AppConstants.notificationIngressChangedNotificationName)
            await ackIngressIfNeeded(ingress)
        }
        guard !Task.isCancelled else { return content }
        await deduplicateEntityNotificationsIfNeeded(
            currentRequestIdentifier: request.identifier,
            payload: content.userInfo
        )
        return await contentPreparer.enrichMediaIfNeeded(content)
    }

    func prepareContentForPersistence(
        content: UNMutableNotificationContent,
        ingress: NotificationIngressResolution
    ) async -> UNMutableNotificationContent {
        applyIngressPayloadIfNeeded(ingress, to: content)
        return await contentPreparer.prepare(content, includeMediaAttachments: false)
    }

    @discardableResult
    private func enqueueIngressInboxEntry(
        for request: UNNotificationRequest,
        ingress: NotificationIngressResolution,
        preparedContent: UNMutableNotificationContent
    ) async -> Bool {
        let requestIdentifier: String?
        switch ingress {
        case let .direct(_, ingressRequestIdentifier):
            requestIdentifier = ingressRequestIdentifier
        case let .pulled(_, ingressRequestIdentifier):
            requestIdentifier = ingressRequestIdentifier
        case let .unresolvedWakeup(_, ingressRequestIdentifier):
            requestIdentifier = ingressRequestIdentifier
        }

        let codablePayload = codablePayloadDictionary(from: preparedContent.userInfo)
        let enqueued = await notificationIngressInbox.enqueue(
            codablePayload: codablePayload,
            requestIdentifier: requestIdentifier ?? request.identifier,
            source: "nse"
        )
        NSEPersistenceDiagnostics.record(
            phase: enqueued ? "inbox_enqueued" : "inbox_enqueue_failed",
            requestIdentifier: request.identifier,
            payload: preparedContent.userInfo,
            ingressType: Self.ingressTypeName(ingress),
            outcome: nil,
            error: enqueued ? nil : "enqueue_failed"
        )
        return enqueued
    }

    private func codablePayloadDictionary(
        from payload: [AnyHashable: Any]
    ) -> [String: AnyCodable] {
        let sanitized = UserInfoSanitizer.sanitize(payload)
        return sanitized.reduce(into: [String: AnyCodable]()) { result, item in
            result[item.key] = AnyCodable(item.value)
        }
    }

    private func applyIngressPayloadIfNeeded(
        _ ingress: NotificationIngressResolution,
        to content: UNMutableNotificationContent
    ) {
        switch ingress {
        case let .pulled(payload, _):
            NotificationHandling.applyResolvedPayload(payload, to: content)
        case let .unresolvedWakeup(payload, _):
            if let fallbackPayload = NotificationHandling.wakeupFallbackDisplayPayload(from: payload) {
                NotificationHandling.applyResolvedPayload(fallbackPayload, to: content)
            } else {
                content.userInfo = UserInfoSanitizer.sanitize(payload)
                applyUnresolvedWakeupNotice(to: content)
            }
        case .direct:
            break
        }
    }

    private func applyUnresolvedWakeupNotice(to content: UNMutableNotificationContent) {
        content.title = "收到消息"
        content.body = "收到无法解析的消息。"
        var userInfo = content.userInfo
        userInfo["_skip_persist"] = "1"
        userInfo["_wakeup_unresolved"] = "1"
        content.userInfo = userInfo
    }

    private func ackIngressIfNeeded(_ ingress: NotificationIngressResolution) async {
        let payload: [AnyHashable: Any]
        let deliveryId: String?
        switch ingress {
        case let .direct(resolvedPayload, requestIdentifier):
            payload = resolvedPayload
            guard NotificationHandling.providerWakeupPullDeliveryId(from: resolvedPayload) == nil else {
                return
            }
            deliveryId = requestIdentifier ?? NotificationHandling.providerIngressRequestIdentifier(from: resolvedPayload)
        case let .pulled(resolvedPayload, requestIdentifier):
            payload = resolvedPayload
            deliveryId = requestIdentifier
        case .unresolvedWakeup:
            return
        }
        guard let deliveryId = Self.normalizedPayloadString(deliveryId) else {
            return
        }

        let sanitized = UserInfoSanitizer.sanitize(payload)
        let candidates = wakeupServerCandidatesWithoutDatabase(from: sanitized)
        let loadResult = providerDeviceKeyWithoutDatabase()
        guard !candidates.isEmpty,
              let deviceKey = loadResult.deviceKey
        else {
            _ = await ackFailureStore.markInboxDurable(
                deliveryId: deliveryId,
                baseURL: candidates.first?.baseURL,
                deviceKeyAccount: loadResult.account,
                source: "nse_ack_unavailable",
                retryAfter: Date().addingTimeInterval(30)
            )
            return
        }
        guard let lease = await ackFailureStore.acquireAckLease(
            deliveryId: deliveryId,
            owner: "nse",
            leaseDuration: 120
        ) else {
            return
        }

        for candidate in candidates {
            do {
                _ = try await channelSubscriptionService.ackMessage(
                    baseURL: candidate.baseURL,
                    token: candidate.token,
                    deviceKey: deviceKey,
                    deliveryId: deliveryId
                )
                await ackFailureStore.markCompleted(lease)
                return
            } catch {
                continue
            }
        }

        await ackFailureStore.markAckFailed(
            lease,
            source: "nse_ack_failed",
            retryAfter: Date().addingTimeInterval(30)
        )
    }

    private func markAckPreparingIfNeeded(_ ingress: NotificationIngressResolution) async {
        await markAckMarkerIfNeeded(ingress, stage: .preparing)
    }

    private func markAckInboxDurableIfNeeded(_ ingress: NotificationIngressResolution) async {
        await markAckMarkerIfNeeded(ingress, stage: .inboxDurable)
    }

    private func markAckMarkerIfNeeded(
        _ ingress: NotificationIngressResolution,
        stage: ProviderDeliveryAckFailureStore.Stage
    ) async {
        let payload: [AnyHashable: Any]
        let deliveryId: String?
        switch ingress {
        case let .direct(resolvedPayload, requestIdentifier):
            payload = resolvedPayload
            guard NotificationHandling.providerWakeupPullDeliveryId(from: resolvedPayload) == nil else {
                return
            }
            deliveryId = requestIdentifier ?? NotificationHandling.providerIngressRequestIdentifier(from: resolvedPayload)
        case let .pulled(resolvedPayload, requestIdentifier):
            payload = resolvedPayload
            deliveryId = requestIdentifier
        case .unresolvedWakeup:
            return
        }
        guard let deliveryId = Self.normalizedPayloadString(deliveryId) else {
            return
        }
        let candidates = wakeupServerCandidatesWithoutDatabase(from: UserInfoSanitizer.sanitize(payload))
        let account = ProviderDeviceKeyStore.accountName(for: nsePlatformIdentifier())
        switch stage {
        case .preparing:
            _ = await ackFailureStore.markPreparing(
                deliveryId: deliveryId,
                baseURL: candidates.first?.baseURL,
                deviceKeyAccount: account,
                source: "nse_ack_preparing",
                postNotification: false
            )
        case .inboxDurable:
            _ = await ackFailureStore.markInboxDurable(
                deliveryId: deliveryId,
                baseURL: candidates.first?.baseURL,
                deviceKeyAccount: account,
                source: "nse_inbox_durable",
                postNotification: false
            )
        case .ackInFlight, .completed:
            break
        }
    }

    private func resolveNotificationIngressWithoutDatabase(
        from payload: [AnyHashable: Any]
    ) async -> NotificationIngressResolution {
        let sanitized = UserInfoSanitizer.sanitize(payload)
        guard let deliveryId = NotificationHandling.providerWakeupPullDeliveryId(from: sanitized) else {
            return .direct(
                payload: sanitized,
                requestIdentifier: NotificationHandling.providerIngressRequestIdentifier(from: sanitized)
            )
        }

        let candidates = wakeupServerCandidatesWithoutDatabase(from: sanitized)
        let loadResult = providerDeviceKeyWithoutDatabase()
        guard !candidates.isEmpty,
              let deviceKey = loadResult.deviceKey
        else {
            return .unresolvedWakeup(payload: sanitized, requestIdentifier: deliveryId)
        }

        for candidate in candidates {
            do {
                let items = try await channelSubscriptionService.pullMessages(
                    baseURL: candidate.baseURL,
                    token: candidate.token,
                    deviceKey: deviceKey,
                    deliveryId: deliveryId
                )
                guard let item = items.first else { continue }
                let pulledPayload: [AnyHashable: Any] = item.payload.reduce(into: [:]) { result, element in
                    result[element.key] = element.value
                }
                return .pulled(
                    payload: UserInfoSanitizer.sanitize(pulledPayload),
                    requestIdentifier: Self.normalizedPayloadString(item.deliveryId) ?? deliveryId
                )
            } catch {
                continue
            }
        }

        return .unresolvedWakeup(payload: sanitized, requestIdentifier: deliveryId)
    }

    private func wakeupServerCandidatesWithoutDatabase(
        from payload: [String: Any]
    ) -> [WakeupServerCandidate] {
        var candidates: [WakeupServerCandidate] = []
        var dedupe = Set<String>()
        func appendCandidate(baseURL: URL, token: String?) {
            let dedupeKey = "\(baseURL.absoluteString.lowercased())|\(token ?? "")"
            guard dedupe.insert(dedupeKey).inserted else { return }
            candidates.append(WakeupServerCandidate(baseURL: baseURL, token: token))
        }

        let payloadCandidates = [
            payload["gateway"] as? String,
            payload["gateway_url"] as? String,
            payload["base_url"] as? String,
            payload["server"] as? String,
            payload["server_url"] as? String,
        ]
        for raw in payloadCandidates {
            guard let raw,
                  let url = URLSanitizer.validatedServerURL(from: raw)
            else {
                continue
            }
            appendCandidate(baseURL: url, token: nil)
        }

        if let config = (try? localConfigStore.loadServerConfig())?.normalized() {
            appendCandidate(baseURL: config.baseURL, token: config.token)
        }

        if let defaultServerURL = AppConstants.defaultServerURL {
            appendCandidate(baseURL: defaultServerURL, token: AppConstants.defaultGatewayToken)
        }

        return candidates
    }

    private func providerDeviceKeyWithoutDatabase() -> ProviderDeviceKeyStore.LoadResult {
        deviceKeyStore.loadResult(platform: nsePlatformIdentifier())
    }

    private func nsePlatformIdentifier() -> String {
        #if os(iOS)
        return "ios"
        #elseif os(macOS)
        return "macos"
        #else
        return "apple"
        #endif
    }

    private func deduplicateEntityNotificationsIfNeeded(
        currentRequestIdentifier: String,
        payload: [AnyHashable: Any]
    ) async {
        guard Self.shouldDeduplicateEntityNotification(payload: payload),
              let deliveryId = Self.normalizedPayloadString(payload["delivery_id"])
        else {
            return
        }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            UNUserNotificationCenter.current().getDeliveredNotifications { delivered in
                let deliveredDuplicates = delivered.compactMap { notification -> String? in
                    guard notification.request.identifier != currentRequestIdentifier else { return nil }
                    guard Self.shouldDeduplicateEntityNotification(
                        payload: notification.request.content.userInfo
                    ) else {
                        return nil
                    }
                    let candidateDeliveryId = Self.normalizedPayloadString(
                        notification.request.content.userInfo["delivery_id"]
                    )
                    return candidateDeliveryId == deliveryId ? notification.request.identifier : nil
                }
                if !deliveredDuplicates.isEmpty {
                    UNUserNotificationCenter.current().removeDeliveredNotifications(
                        withIdentifiers: deliveredDuplicates
                    )
                }

                UNUserNotificationCenter.current().getPendingNotificationRequests { pending in
                    let pendingDuplicates = pending.compactMap { request -> String? in
                        guard request.identifier != currentRequestIdentifier else { return nil }
                        guard Self.shouldDeduplicateEntityNotification(
                            payload: request.content.userInfo
                        ) else {
                            return nil
                        }
                        let candidateDeliveryId = Self.normalizedPayloadString(
                            request.content.userInfo["delivery_id"]
                        )
                        return candidateDeliveryId == deliveryId ? request.identifier : nil
                    }
                    if !pendingDuplicates.isEmpty {
                        UNUserNotificationCenter.current().removePendingNotificationRequests(
                            withIdentifiers: pendingDuplicates
                        )
                    }
                    continuation.resume()
                }
            }
        }
    }

    private static func shouldDeduplicateEntityNotification(payload: [AnyHashable: Any]) -> Bool {
        guard let entityType = normalizedPayloadString(payload["entity_type"])?.lowercased() else {
            return false
        }
        return entityType == "event" || entityType == "thing"
    }

    private static func normalizedPayloadString(_ value: Any?) -> String? {
        let trimmed = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func deviceKeyLoadErrorDescription(_ result: ProviderDeviceKeyStore.LoadResult) -> String {
        var parts = [
            "missing_device_key",
            "platform=\(result.platform)",
            "account=\(result.account)",
            "access_group=\(result.accessGroup ?? "nil")",
        ]
        if let status = result.error?.statusCode {
            parts.append("status=\(status)")
        } else if result.error == .unexpectedData {
            parts.append("error=unexpected_data")
        } else if let error = result.error {
            parts.append("error=\(error.localizedDescription)")
        } else {
            parts.append("status=not_found")
        }
        return parts.joined(separator: " ")
    }

    private static func ingressTypeName(_ ingress: NotificationIngressResolution) -> String {
        switch ingress {
        case .direct:
            return "direct"
        case .pulled:
            return "pulled"
        case .unresolvedWakeup:
            return "unresolvedWakeup"
        }
    }
}

private enum NSEPersistenceDiagnostics {
    private struct Entry: Codable {
        let timestampISO8601: String
        let process: String
        let pid: Int32
        let phase: String
        let requestIdentifier: String
        let ingressType: String
        let deliveryId: String?
        let operationId: String?
        let entityType: String?
        let entityId: String?
        let messageId: String?
        let eventId: String?
        let thingId: String?
        let decryptionState: String?
        let outcome: String?
        let error: String?
    }

    private static let lock = NSLock()

    static func record(
        phase: String,
        requestIdentifier: String,
        payload: [AnyHashable: Any],
        ingressType: String,
        outcome: String?,
        error: String?
    ) {
        let requestId = normalizedText(requestIdentifier) ?? UUID().uuidString
        let entry = Entry(
            timestampISO8601: ISO8601DateFormatter().string(from: Date()),
            process: ProcessInfo.processInfo.processName,
            pid: ProcessInfo.processInfo.processIdentifier,
            phase: phase,
            requestIdentifier: requestId,
            ingressType: ingressType,
            deliveryId: normalizedText(payload["delivery_id"]),
            operationId: normalizedText(payload["op_id"]),
            entityType: normalizedText(payload["entity_type"]),
            entityId: normalizedText(payload["entity_id"]),
            messageId: normalizedText(payload["message_id"]),
            eventId: normalizedText(payload["event_id"]),
            thingId: normalizedText(payload["thing_id"]),
            decryptionState: normalizedText(payload["decryption_state"]),
            outcome: normalizedText(outcome),
            error: normalizedText(error)
        )
        append(entry)
    }

    private static func append(_ entry: Entry) {
        guard let data = try? JSONEncoder().encode(entry),
              var line = String(data: data, encoding: .utf8)
        else {
            return
        }
        line.append("\n")
        guard let lineData = line.data(using: .utf8),
              let fileURL = diagnosticsLogURL()
        else {
            return
        }

        lock.lock()
        defer { lock.unlock() }
        do {
            let directory = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: fileURL.path) {
                try lineData.write(to: fileURL, options: .atomic)
            } else {
                let handle = try FileHandle(forWritingTo: fileURL)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: lineData)
            }
            NSLog("NSEPersistenceDiagnostics %@", line.trimmingCharacters(in: .whitespacesAndNewlines))
        } catch {
            NSLog("NSEPersistenceDiagnostics write_failed %@", String(describing: error))
        }
    }

    private static func diagnosticsLogURL() -> URL? {
        guard let container = AppConstants.appGroupContainerURL(
            fileManager: .default,
            identifier: AppConstants.appGroupIdentifier
        ) else {
            return nil
        }
        return container
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("storage-diagnostics", isDirectory: true)
            .appendingPathComponent("nse_persistence.jsonl", isDirectory: false)
    }

    private static func normalizedText(_ value: Any?) -> String? {
        let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? nil : text
    }
}
