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
    private static let sharedWakeupPullClaimStore = ProviderWakeupPullClaimStore.shared

    private let contentPreparer: NotificationContentPreparer
    private let channelSubscriptionService: ChannelSubscriptionService
    private let notificationIngressInbox: NotificationIngressInbox
    private let ackFailureStore: ProviderDeliveryAckFailureStore
    private let wakeupPullClaimStore: ProviderWakeupPullClaimStore
    private let localConfigStore: LocalKeychainConfigStore
    private let deviceKeyStore: ProviderDeviceKeyStore
    private let gatewayTokenStore: ProviderGatewayTokenStore

    init(
        channelSubscriptionService: ChannelSubscriptionService = NotificationServiceProcessor.sharedChannelSubscriptionService,
        notificationIngressInbox: NotificationIngressInbox = NotificationServiceProcessor.sharedNotificationIngressInbox,
        ackFailureStore: ProviderDeliveryAckFailureStore = NotificationServiceProcessor.sharedAckFailureStore,
        wakeupPullClaimStore: ProviderWakeupPullClaimStore = NotificationServiceProcessor.sharedWakeupPullClaimStore,
        localConfigStore: LocalKeychainConfigStore = LocalKeychainConfigStore(),
        deviceKeyStore: ProviderDeviceKeyStore = ProviderDeviceKeyStore(),
        gatewayTokenStore: ProviderGatewayTokenStore = ProviderGatewayTokenStore(),
        contentPreparer: NotificationContentPreparer = NotificationContentPreparer()
    ) {
        self.channelSubscriptionService = channelSubscriptionService
        self.notificationIngressInbox = notificationIngressInbox
        self.ackFailureStore = ackFailureStore
        self.wakeupPullClaimStore = wakeupPullClaimStore
        self.localConfigStore = localConfigStore
        self.deviceKeyStore = deviceKeyStore
        self.gatewayTokenStore = gatewayTokenStore
        self.contentPreparer = contentPreparer
    }

    func process(
        request: UNNotificationRequest,
        content: UNMutableNotificationContent
    ) async -> UNNotificationContent {
        let sanitizedPayload = UserInfoSanitizer.sanitize(request.content.userInfo)
        let ingress = await resolveNotificationIngressWithoutDatabase(from: sanitizedPayload)
        let content = await prepareContentForPersistence(content: content, ingress: ingress)
        await markAckPreparingIfNeeded(ingress)
        let enqueued = await enqueueIngressInboxEntry(
            for: request,
            ingress: ingress,
            preparedContent: content
        )
        if enqueued {
            await markAckInboxDurableIfNeeded(ingress)
            await finalizePullClaimIfNeeded(ingress, durable: true)
            _ = await PushGoNotificationProjectionUpdater.update(
                content: content,
                requestIdentifier: requestIdentifier(for: request, ingress: ingress)
            )
            DarwinNotificationPoster.post(name: AppConstants.notificationIngressChangedNotificationName)
            await ackIngressIfNeeded(ingress)
        } else {
            await finalizePullClaimIfNeeded(ingress, durable: false)
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
        if case .claimedByPeer = ingress {
            return false
        }

        let codablePayload = codablePayloadDictionary(from: preparedContent.userInfo)
        let enqueued = await notificationIngressInbox.enqueue(
            codablePayload: codablePayload,
            requestIdentifier: requestIdentifier(for: request, ingress: ingress),
            source: "nse"
        )
        return enqueued
    }

    private func requestIdentifier(
        for request: UNNotificationRequest,
        ingress: NotificationIngressResolution
    ) -> String {
        let requestIdentifier: String?
        switch ingress {
        case let .direct(_, ingressRequestIdentifier):
            requestIdentifier = ingressRequestIdentifier
        case let .pulled(_, ingressRequestIdentifier, _):
            requestIdentifier = ingressRequestIdentifier
        case let .claimedByPeer(_, ingressRequestIdentifier):
            requestIdentifier = ingressRequestIdentifier
        case let .unresolvedWakeup(_, ingressRequestIdentifier):
            requestIdentifier = ingressRequestIdentifier
        }
        return requestIdentifier ?? request.identifier
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
        case let .pulled(payload, _, _):
            NotificationHandling.applyResolvedPayload(payload, to: content)
        case let .claimedByPeer(payload, _):
            if let fallbackPayload = NotificationHandling.wakeupFallbackDisplayPayload(from: payload) {
                NotificationHandling.applyResolvedPayload(fallbackPayload, to: content)
            } else {
                content.userInfo = UserInfoSanitizer.sanitize(payload)
                applyUnresolvedWakeupNotice(to: content)
            }
        case let .unresolvedWakeup(payload, _):
            if let fallbackPayload = NotificationHandling.wakeupFallbackDisplayPayload(from: payload) {
                NotificationHandling.applyResolvedPayload(fallbackPayload, to: content)
            } else {
                content.userInfo = UserInfoSanitizer.sanitize(payload)
                applyUnresolvedWakeupNotice(to: content)
            }
        case let .direct(payload, _):
            NotificationHandling.applyResolvedPayload(payload, to: content)
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
        let deliveryId: String?
        let identity: ProviderDeliveryAckFailureStore.DeliveryIdentity?
        let ackToken: String?
        switch ingress {
        case let .direct(resolvedPayload, _):
            guard NotificationHandling.providerWakeupPullDeliveryId(from: resolvedPayload) == nil else {
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
        case .claimedByPeer:
            return
        case .unresolvedWakeup:
            return
        }
        guard let deliveryId = Self.normalizedPayloadString(deliveryId),
              let identity
        else {
            return
        }

        if identity.ackContract == .v2Batch {
            guard let lease = await ackFailureStore.acquireAckLease(
                identity: identity,
                owner: "nse",
                leaseDuration: 120
            ) else {
                return
            }
            do {
                let ack = try await channelSubscriptionService.ackMessages(
                    baseURL: identity.baseURL,
                    token: ackToken,
                    deviceKey: identity.deviceKey,
                    deliveryIds: [deliveryId]
                )
                guard ack.removedCount == 1 else {
                    throw AppError.typedLocal(
                        code: "gateway_ack_incomplete",
                        category: .conflict,
                        message: LocalizationProvider.localized("operation_failed"),
                        detail: "fresh batch ack did not remove delivery"
                    )
                }
                await ackFailureStore.markCompleted(lease)
            } catch {
                await ackFailureStore.markAckFailed(
                    lease,
                    source: "nse_ack_failed",
                    retryAfter: Date().addingTimeInterval(30)
                )
            }
            return
        }

        guard let lease = await ackFailureStore.acquireAckLease(
            identity: identity,
            owner: "nse",
            leaseDuration: 120
        ) else {
            return
        }

        do {
            let removed = try await channelSubscriptionService.ackMessage(
                baseURL: identity.baseURL,
                token: gatewayTokenStore.load(baseURL: identity.baseURL),
                deviceKey: identity.deviceKey,
                deliveryId: deliveryId
            )
            guard removed || lease.attemptCount > 0 else {
                throw AppError.typedLocal(
                    code: "gateway_ack_incomplete",
                    category: .conflict,
                    message: LocalizationProvider.localized("operation_failed"),
                    detail: "fresh legacy ack did not remove delivery"
                )
            }
            await ackFailureStore.markCompleted(lease)
            return
        } catch {
            await ackFailureStore.markAckFailed(
                lease,
                source: "nse_ack_failed",
                retryAfter: Date().addingTimeInterval(30)
            )
        }
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
        let identity: ProviderDeliveryAckFailureStore.DeliveryIdentity?
        switch ingress {
        case let .direct(resolvedPayload, _):
            guard NotificationHandling.providerWakeupPullDeliveryId(from: resolvedPayload) == nil else {
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
        case .claimedByPeer:
            return
        case .unresolvedWakeup:
            return
        }
        guard let identity else { return }
        switch stage {
        case .preparing:
            _ = await ackFailureStore.markPreparing(
                identity: identity,
                source: "nse_ack_preparing",
                postNotification: false
            )
        case .inboxDurable:
            _ = await ackFailureStore.markInboxDurable(
                identity: identity,
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
        let owner = "nse.\(nsePlatformIdentifier())"
        let leaseDuration: TimeInterval = 30
        for candidate in candidates {
            _ = gatewayTokenStore.save(token: candidate.token, baseURL: candidate.baseURL)
            guard let identity = ProviderDeliveryAckFailureStore.DeliveryIdentity(
                deliveryId: deliveryId,
                baseURL: candidate.baseURL,
                deviceKey: deviceKey,
                ackContract: .v2Batch
            ) else {
                continue
            }
            let lease: ProviderWakeupPullClaimStore.ClaimLease
            if let acquiredLease = await wakeupPullClaimStore.acquireLease(
                identity: identity,
                owner: owner,
                leaseDuration: leaseDuration
            ) {
                lease = acquiredLease
            } else if await wakeupPullClaimStore.waitForPeerCompletion(
                identity: identity,
                timeout: 1.5
            ) {
                return .claimedByPeer(payload: sanitized, requestIdentifier: deliveryId)
            } else if let retryLease = await wakeupPullClaimStore.acquireLease(
                identity: identity,
                owner: owner,
                leaseDuration: leaseDuration
            ) {
                lease = retryLease
            } else {
                continue
            }
            do {
                let pullResult = try await channelSubscriptionService.pullMessages(
                    baseURL: candidate.baseURL,
                    token: candidate.token,
                    deviceKey: deviceKey,
                    deliveryId: deliveryId
                )
                guard let item = pullResult.items.first else {
                    await wakeupPullClaimStore.releaseLease(lease)
                    continue
                }
                var pulledPayload: [AnyHashable: Any] = item.payload.reduce(into: [:]) { result, element in
                    result[element.key] = element.value
                }
                pulledPayload["delivery_id"] = item.deliveryId
                return .pulled(
                    payload: UserInfoSanitizer.sanitize(pulledPayload),
                    requestIdentifier: Self.normalizedPayloadString(item.deliveryId) ?? deliveryId,
                    context: ProviderPullContext(
                        contract: pullResult.contract,
                        baseURL: candidate.baseURL,
                        token: candidate.token,
                        deviceKey: deviceKey,
                        claimLease: lease
                    )
                )
            } catch {
                await wakeupPullClaimStore.releaseLease(lease)
                continue
            }
        }
        return .unresolvedWakeup(payload: sanitized, requestIdentifier: deliveryId)
    }

    private func finalizePullClaimIfNeeded(
        _ ingress: NotificationIngressResolution,
        durable: Bool
    ) async {
        guard case let .pulled(_, _, context) = ingress else { return }
        if durable {
            await wakeupPullClaimStore.markCompleted(context.claimLease)
        } else {
            await wakeupPullClaimStore.releaseLease(context.claimLease)
        }
    }

    private func wakeupServerCandidatesWithoutDatabase(
        from payload: [String: Any]
    ) -> [WakeupServerCandidate] {
        var candidates: [WakeupServerCandidate] = []
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
                    candidates[existingIndex] = WakeupServerCandidate(
                        baseURL: normalizedBaseURL,
                        token: normalizedToken
                    )
                }
                return
            }
            candidates.append(WakeupServerCandidate(baseURL: normalizedBaseURL, token: normalizedToken))
            indexByBaseURL[key] = candidates.count - 1
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

        if let config = WakeupIngressSharedState.loadServerConfig() {
            appendCandidate(baseURL: config.baseURL, token: config.token)
        }

        if let defaultServerURL = AppConstants.defaultServerURL {
            appendCandidate(baseURL: defaultServerURL, token: AppConstants.defaultGatewayToken)
        }

        return candidates
    }

    private func providerDeviceKeyWithoutDatabase() -> ProviderDeviceKeyStore.LoadResult {
        let platform = nsePlatformIdentifier()
        let loadResult = deviceKeyStore.loadResult(platform: platform)
        guard loadResult.deviceKey == nil,
              let fallbackDeviceKey = WakeupIngressSharedState.loadDeviceKey(
                  platform: platform
              )
        else {
            return loadResult
        }
        return ProviderDeviceKeyStore.LoadResult(
            platform: loadResult.platform,
            account: loadResult.account,
            accessGroup: loadResult.accessGroup,
            deviceKey: fallbackDeviceKey,
            error: nil
        )
    }

    private func unresolvedWakeupReasonWithoutDatabase(from payload: [String: Any]) -> String {
        let candidates = wakeupServerCandidatesWithoutDatabase(from: payload)
        guard !candidates.isEmpty else {
            return "missing_server_candidate"
        }
        let loadResult = providerDeviceKeyWithoutDatabase()
        guard loadResult.deviceKey != nil else {
            return Self.deviceKeyLoadErrorDescription(loadResult)
        }
        return "pull_failed_all_candidates"
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

}
