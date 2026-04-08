import Foundation

@MainActor
protocol AppUpdateManaging: AnyObject {
    var isEnabled: Bool { get }
    var isBetaChannelEnabled: Bool { get }
    func setBetaChannelEnabled(_ isEnabled: Bool)
    func checkForUpdates() -> Bool
    func checkForUpdatesInBackground() -> Bool
}

@MainActor
enum AppUpdateManagerFactory {
    static func make() -> any AppUpdateManaging {
#if PUSHGO_DMG_BUILD && canImport(Sparkle)
        SparkleAppUpdateManager()
#else
        NoopAppUpdateManager()
#endif
    }
}

@MainActor
final class NoopAppUpdateManager: AppUpdateManaging {
    var isEnabled: Bool { false }
    var isBetaChannelEnabled: Bool { false }

    func setBetaChannelEnabled(_: Bool) {}

    func checkForUpdates() -> Bool {
        false
    }

    func checkForUpdatesInBackground() -> Bool {
        false
    }
}

#if PUSHGO_DMG_BUILD && canImport(Sparkle)
import Sparkle

@MainActor
final class SparkleAppUpdateManager: NSObject, AppUpdateManaging {
    private static let betaChannelName = "beta"
    private static let betaChannelPreferenceKey = "pushgo.sparkle.beta_channel_enabled"

    private final class UpdaterDelegateProxy: NSObject, SPUUpdaterDelegate {
        var isBetaChannelEnabled: Bool = false

        func allowedChannels(for _: SPUUpdater) -> Set<String> {
            guard isBetaChannelEnabled else { return [] }
            return [SparkleAppUpdateManager.betaChannelName]
        }
    }

    private let updaterDelegateProxy: UpdaterDelegateProxy
    private let updaterController: SPUStandardUpdaterController
    private let preferences: UserDefaults
    private(set) var isBetaChannelEnabled: Bool

    override init() {
        preferences = AppConstants.sharedUserDefaults()
        updaterDelegateProxy = UpdaterDelegateProxy()
        isBetaChannelEnabled = preferences.bool(forKey: Self.betaChannelPreferenceKey)
        updaterDelegateProxy.isBetaChannelEnabled = isBetaChannelEnabled
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: updaterDelegateProxy,
            userDriverDelegate: nil
        )
        super.init()
        applyScheduledCheckIntervalIfConfigured()
    }

    var isEnabled: Bool {
        true
    }

    func setBetaChannelEnabled(_ isEnabled: Bool) {
        guard isBetaChannelEnabled != isEnabled else { return }
        isBetaChannelEnabled = isEnabled
        updaterDelegateProxy.isBetaChannelEnabled = isEnabled
        preferences.set(isEnabled, forKey: Self.betaChannelPreferenceKey)
        updaterController.updater.resetUpdateCycle()
    }

    func checkForUpdates() -> Bool {
        guard isSparkleConfigured else { return false }
        updaterController.checkForUpdates(nil)
        return true
    }

    func checkForUpdatesInBackground() -> Bool {
        guard isSparkleConfigured else { return false }
        guard updaterController.updater.automaticallyChecksForUpdates else { return false }
        // Use probe mode for app-triggered automatic checks:
        // - no "up to date" UI
        // - failures are silently skipped
        updaterController.updater.checkForUpdateInformation()
        return true
    }

    private var isSparkleConfigured: Bool {
        let feedURLString = value(forInfoPlistKey: "SUFeedURL")
        let publicKey = value(forInfoPlistKey: "SUPublicEDKey")
        guard !publicKey.isEmpty else { return false }
        guard
            let feedURL = URL(string: feedURLString),
            let scheme = feedURL.scheme?.lowercased(),
            (scheme == "https" || scheme == "http"),
            feedURL.host?.isEmpty == false
        else {
            return false
        }
        return true
    }

    private func applyScheduledCheckIntervalIfConfigured() {
        guard let interval = scheduledCheckInterval else { return }
        updaterController.updater.updateCheckInterval = interval
    }

    private var scheduledCheckInterval: TimeInterval? {
        let raw = value(forInfoPlistKey: "SUScheduledCheckInterval")
        guard !raw.isEmpty, let seconds = TimeInterval(raw), seconds > 0 else {
            return nil
        }
        return seconds
    }

    private func value(forInfoPlistKey key: String) -> String {
        if let raw = Bundle.main.object(forInfoDictionaryKey: key) as? String {
            return raw.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let number = Bundle.main.object(forInfoDictionaryKey: key) as? NSNumber {
            return number.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return ""
    }
}
#endif
