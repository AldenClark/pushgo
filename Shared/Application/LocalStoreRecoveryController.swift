import Darwin
import Foundation
import Observation

@MainActor
@Observable
final class LocalStoreRecoveryController {
    typealias ToastPresenter = @MainActor (String) -> Void
    typealias Terminator = @MainActor () -> Void

    private let dataStore: LocalDataStore
    private let localizationManager: LocalizationManager
    private let failureStreakThreshold: Int
    private let failureStreakKey: String
    private let failureDefaults: UserDefaults
    @ObservationIgnored private let showToast: ToastPresenter
    @ObservationIgnored private let terminate: Terminator

    private(set) var localStoreRecoveryState: LocalStoreRecoveryState?

    init(
        dataStore: LocalDataStore,
        localizationManager: LocalizationManager,
        failureStreakThreshold: Int,
        failureStreakKey: String,
        failureDefaults: UserDefaults,
        showToast: @escaping ToastPresenter,
        terminate: @escaping Terminator
    ) {
        self.dataStore = dataStore
        self.localizationManager = localizationManager
        self.failureStreakThreshold = failureStreakThreshold
        self.failureStreakKey = failureStreakKey
        self.failureDefaults = failureDefaults
        self.showToast = showToast
        self.terminate = terminate
    }

    func dismissLocalStoreRecovery() {
        localStoreRecoveryState = nil
    }

    func terminateForLocalStoreFailure() {
        terminate()
    }

    func rebuildLocalStoreForRecoveryAndTerminate() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await dataStore.rebuildPersistentStoresForRecovery()
                clearLocalStoreFailureStreak()
                terminateForLocalStoreFailure()
            } catch {
                showToast(localizationManager.localized(
                    "initialization_failed_placeholder",
                    error.localizedDescription
                ))
            }
        }
    }

    func clearFailureStreak() {
        clearLocalStoreFailureStreak()
    }

    func handleLocalStoreUnavailable(_ state: LocalDataStore.StorageState) {
        let streak = incrementLocalStoreFailureStreak()
        let canRebuild = streak >= failureStreakThreshold
        var lines: [String] = [
            localizationManager.localized("local_store_unavailable"),
            "请点击“退出应用”并重新打开。",
        ]
        if let reason = state.reason?.trimmingCharacters(in: .whitespacesAndNewlines), !reason.isEmpty {
            lines.append(reason)
            if isLikelyLocalStoreLockContention(reason: reason) {
                lines.append("检测到可能的数据库锁占用，请先彻底退出所有 PushGo 进程/扩展后重试。")
            }
        }
        if canRebuild {
            lines.append("该错误已连续出现多次，请上报日志；也可以选择“重建数据库并退出”。")
        } else {
            lines.append("若问题反复出现，请上报错误日志。")
        }
        localStoreRecoveryState = LocalStoreRecoveryState(
            title: localizationManager.localized("local_store_unavailable"),
            message: lines.joined(separator: "\n"),
            canRebuild: canRebuild
        )
    }

    private func incrementLocalStoreFailureStreak() -> Int {
        let next = failureDefaults.integer(forKey: failureStreakKey) + 1
        failureDefaults.set(next, forKey: failureStreakKey)
        return next
    }

    private func clearLocalStoreFailureStreak() {
        failureDefaults.removeObject(forKey: failureStreakKey)
    }

    private func isLikelyLocalStoreLockContention(reason: String?) -> Bool {
        guard let reason else { return false }
        let lowered = reason.lowercased()
        return lowered.contains("database is locked")
            || lowered.contains("database is busy")
            || lowered.contains("sqlite_busy")
            || lowered.contains("sqlite_locked")
            || lowered.contains("lock contention")
            || lowered.contains("locked")
    }
}
