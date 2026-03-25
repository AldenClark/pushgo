import Foundation
@testable import PushGoAppleCore

private actor AutomationStorageRootLock {
    static let shared = AutomationStorageRootLock()
    private var isHeld = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func withIsolatedRoot<T>(
        _ body: @Sendable (URL, String) async throws -> T
    ) async rethrows -> T {
        await acquire()
        defer { release() }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pushgo-apple-core-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let appGroupIdentifier = "group.ethan.pushgo.tests.\(UUID().uuidString.lowercased())"
        let previousStorageRoot = ProcessInfo.processInfo.environment["PUSHGO_AUTOMATION_STORAGE_ROOT"]

        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        setenv("PUSHGO_AUTOMATION_STORAGE_ROOT", root.path, 1)
        defer {
            if let previousStorageRoot {
                setenv("PUSHGO_AUTOMATION_STORAGE_ROOT", previousStorageRoot, 1)
            } else {
                unsetenv("PUSHGO_AUTOMATION_STORAGE_ROOT")
            }
        }

        return try await body(root, appGroupIdentifier)
    }

    private func acquire() async {
        guard isHeld else {
            isHeld = true
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    private func release() {
        if waiters.isEmpty {
            isHeld = false
            return
        }
        let continuation = waiters.removeFirst()
        continuation.resume()
    }
}

func withIsolatedAutomationStorage<T: Sendable>(
    _ body: @Sendable (URL, String) async throws -> T
) async rethrows -> T {
    try await AutomationStorageRootLock.shared.withIsolatedRoot(body)
}

func withIsolatedLocalDataStore<T: Sendable>(
    _ body: @Sendable (LocalDataStore, String) async throws -> T
) async rethrows -> T {
    try await withIsolatedAutomationStorage { _, appGroupIdentifier in
        let store = LocalDataStore(appGroupIdentifier: appGroupIdentifier)
        return try await body(store, appGroupIdentifier)
    }
}
