import Foundation
import WatchConnectivity

@MainActor
final class WatchTokenReceiver: NSObject, WCSessionDelegate {
    static let shared = WatchTokenReceiver()

    private let session: WCSession? = WCSession.isSupported() ? WCSession.default : nil
    private var isActivated = false
    private var pendingNotificationKeyMaterial: ServerConfig.NotificationKeyMaterial?
    private var hasPendingNotificationKeyMaterial = false
    private var pendingChannelSubscriptions: [ChannelSubscription] = []
    private var hasPendingChannelSubscriptions = false
    private var pendingDefaultRingtoneFilename: String?
    private var hasPendingDefaultRingtoneFilename = false

    private override init() {
        super.init()
    }

    func activateIfNeeded() {
        guard let session else { return }
        if session.delegate == nil {
            session.delegate = self
        }
        if !isActivated {
            session.activate()
            isActivated = true
        }
    }

    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        _ = (session, activationState, error)
        Task { @MainActor in
            self.flushPendingPayloadsIfPossible()
        }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {
        _ = session
    }

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }

    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        Task { @MainActor in
            self.flushPendingPayloadsIfPossible()
        }
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveApplicationContext applicationContext: [String: Any]
    ) {
        handlePayload(applicationContext)
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveMessage message: [String: Any]
    ) {
        handlePayload(message)
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveUserInfo userInfo: [String: Any]
    ) {
        handlePayload(userInfo)
    }

    private nonisolated func handlePayload(_ payload: [String: Any]) {
        guard let token = payload["watch_apns_token"] as? String else { return }
        Task { @MainActor in
            await AppEnvironment.shared.updateWatchPushToken(token)
        }
    }

    func sendNotificationKeyMaterial(_ material: ServerConfig.NotificationKeyMaterial?) {
        pendingNotificationKeyMaterial = material
        hasPendingNotificationKeyMaterial = true
        activateIfNeeded()
        flushPendingPayloadsIfPossible()
    }

    func sendChannelSubscriptions(_ subscriptions: [ChannelSubscription]) {
        pendingChannelSubscriptions = subscriptions
        hasPendingChannelSubscriptions = true
        activateIfNeeded()
        flushPendingPayloadsIfPossible()
    }

    func sendDefaultRingtoneFilename(_ filename: String?) {
        pendingDefaultRingtoneFilename = filename
        hasPendingDefaultRingtoneFilename = true
        activateIfNeeded()
        flushPendingPayloadsIfPossible()
    }

    private func flushPendingPayloadsIfPossible() {
        guard let session, shouldUseSession(session) else { return }

        if hasPendingNotificationKeyMaterial {
            let payload = buildNotificationKeyMaterialPayload(pendingNotificationKeyMaterial)
            if sendPayload(payload, session: session) {
                hasPendingNotificationKeyMaterial = false
            }
        }

        if hasPendingChannelSubscriptions {
            let payload = buildChannelSubscriptionsPayload(pendingChannelSubscriptions)
            if sendPayload(payload, session: session) {
                hasPendingChannelSubscriptions = false
            }
        }

        if hasPendingDefaultRingtoneFilename {
            let payload = buildDefaultRingtonePayload(pendingDefaultRingtoneFilename)
            if sendPayload(payload, session: session) {
                hasPendingDefaultRingtoneFilename = false
            }
        }
    }

    private func buildNotificationKeyMaterialPayload(
        _ material: ServerConfig.NotificationKeyMaterial?
    ) -> [String: Any] {
        var payload: [String: Any] = [
            "notification_key_material_present": material != nil,
        ]
        if let material {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            payload["notification_key_material"] = try? encoder.encode(material)
        }
        return payload
    }

    private func buildChannelSubscriptionsPayload(
        _ subscriptions: [ChannelSubscription]
    ) -> [String: Any] {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return [
            "channel_subscriptions": (try? encoder.encode(subscriptions)) ?? Data(),
        ]
    }

    private func buildDefaultRingtonePayload(_ filename: String?) -> [String: Any] {
        var payload: [String: Any] = [:]
        if let trimmed = filename?.trimmingCharacters(in: .whitespacesAndNewlines),
           !trimmed.isEmpty
        {
            payload["default_ringtone_filename"] = trimmed
        } else {
            payload["default_ringtone_filename"] = ""
        }
        return payload
    }

    private func sendPayload(_ payload: [String: Any], session: WCSession) -> Bool {
        do {
            try session.updateApplicationContext(payload)
        } catch {
            return false
        }

        if session.isReachable {
            session.sendMessage(payload, replyHandler: nil, errorHandler: nil)
        }

        return true
    }

    private nonisolated func shouldUseSession(_ session: WCSession) -> Bool {
        session.isPaired && session.isWatchAppInstalled
    }
}
