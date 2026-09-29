import Darwin
import Foundation
import Testing
@testable import PushGoAppleCore

private final class FailAfterLegacyMainMoveFileManager: FileManager, @unchecked Sendable {
    private let legacyMainURL: URL

    init(legacyMainURL: URL) {
        self.legacyMainURL = legacyMainURL
        super.init()
    }

    override func moveItem(at sourceURL: URL, to destinationURL: URL) throws {
        try super.moveItem(at: sourceURL, to: destinationURL)
        if sourceURL == legacyMainURL {
            // The file has moved. The production migration's copy fallback now
            // fails because its source is gone, exactly at the family boundary.
            throw CocoaError(.fileReadUnknown)
        }
    }
}

private final class FailBeforeSharedWALCopyFileManager: FileManager, @unchecked Sendable {
    private let sharedWALURL: URL

    init(sharedWALURL: URL) {
        self.sharedWALURL = sharedWALURL
        super.init()
    }

    override func copyItem(at sourceURL: URL, to destinationURL: URL) throws {
        if sourceURL == sharedWALURL {
            throw CocoaError(.fileReadUnknown)
        }
        try super.copyItem(at: sourceURL, to: destinationURL)
    }
}

private final class PartialSharedMainCopyFileManager: FileManager, @unchecked Sendable {
    private let sharedMainURL: URL
    private(set) var didInjectFailure = false

    init(sharedMainURL: URL) {
        self.sharedMainURL = sharedMainURL
        super.init()
    }

    override func copyItem(at sourceURL: URL, to destinationURL: URL) throws {
        guard sourceURL == sharedMainURL else {
            try super.copyItem(at: sourceURL, to: destinationURL)
            return
        }
        let prefix = try Data(contentsOf: sourceURL).prefix(64)
        try Data(prefix).write(to: destinationURL)
        didInjectFailure = true
        // Models a copy that wrote part of the destination before reporting a
        // filesystem error. No host volume or quota is modified.
        throw CocoaError(.fileWriteUnknown)
    }
}

private final class FailLegacyMoveAndPartialFallbackCopyFileManager: FileManager, @unchecked Sendable {
    private let legacyMainURL: URL
    private(set) var didBlockMove = false
    private(set) var didInjectPartialCopy = false

    init(legacyMainURL: URL) {
        self.legacyMainURL = legacyMainURL
        super.init()
    }

    override func moveItem(at sourceURL: URL, to destinationURL: URL) throws {
        if sourceURL == legacyMainURL {
            didBlockMove = true
            throw CocoaError(.fileWriteUnknown)
        }
        try super.moveItem(at: sourceURL, to: destinationURL)
    }

    override func copyItem(at sourceURL: URL, to destinationURL: URL) throws {
        guard sourceURL == legacyMainURL else {
            try super.copyItem(at: sourceURL, to: destinationURL)
            return
        }
        let prefix = try Data(contentsOf: sourceURL).prefix(64)
        try Data(prefix).write(to: destinationURL)
        didInjectPartialCopy = true
        throw CocoaError(.fileWriteUnknown)
    }
}

private func leaveCommittedMessageUpdateInWAL(
    mainURL: URL,
    messageID: String,
    title: String
) throws {
    let writer = Process()
    writer.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    writer.arguments = [
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/abrupt_wal_writer.py").path,
        mainURL.path,
        messageID,
        title,
    ]
    try writer.run()
    writer.waitUntilExit()
    try #require(writer.terminationStatus == 0)
    let walURL = URL(fileURLWithPath: mainURL.path + "-wal")
    try #require(FileManager.default.fileExists(atPath: walURL.path))
    let walSize = try FileManager.default.attributesOfItem(atPath: walURL.path)[.size] as? NSNumber
    try #require((walSize?.intValue ?? 0) > 32)
}

private final class MigrationChildBundleAnchor: NSObject {}

private func migrationChildExecutable() throws -> URL {
    let products = Bundle(for: MigrationChildBundleAnchor.self).bundleURL.deletingLastPathComponent()
    let executable = products.appendingPathComponent("PushGoSQLiteMigrationChild")
    guard FileManager.default.isExecutableFile(atPath: executable.path) else {
        throw NSError(
            domain: "io.ethan.pushgo.store-recovery-child",
            code: 42,
            userInfo: [NSLocalizedDescriptionKey: "SwiftPM migration child is missing or not executable at \(executable.path). Run `swift build --product PushGoSQLiteMigrationChild` before a bare `swift test`, or use scripts/run_apple_core_tests.sh."]
        )
    }
    return executable
}

private func prepareLegacyWALFamilies(
    root: URL,
    appGroupIdentifier: String,
    messageID: String,
    sourceTitles: [(filename: String, title: String)]
) async throws -> (targetMain: URL, sources: [URL]) {
    let message = PushMessage(
        messageId: messageID,
        title: "Before family migration",
        body: "Each source WAL has a different committed title.",
        channel: "recovery"
    )
    do {
        let store = LocalDataStore(
            appGroupIdentifier: appGroupIdentifier,
            spotlightIndexer: nil
        )
        try await store.saveMessage(message)
        try #require(try await store.loadMessages().count == 1)
    }
    LocalDataStore.releaseSharedResourcesForTesting(storageRootURL: root)

    let directory = root
        .appendingPathComponent("app-local", isDirectory: true)
        .appendingPathComponent(appGroupIdentifier, isDirectory: true)
        .appendingPathComponent("Database", isDirectory: true)
    let targetMain = directory.appendingPathComponent(AppConstants.databaseStoreFilename)
    let sources = sourceTitles.map { directory.appendingPathComponent($0.filename) }
    for (index, sourceMain) in sources.enumerated() {
        for suffix in ["", "-wal", "-shm"] {
            let original = URL(fileURLWithPath: targetMain.path + suffix)
            guard FileManager.default.fileExists(atPath: original.path) else { continue }
            let destination = URL(fileURLWithPath: sourceMain.path + suffix)
            if index == sources.count - 1 {
                try FileManager.default.moveItem(at: original, to: destination)
            } else {
                try FileManager.default.copyItem(at: original, to: destination)
            }
        }
    }
    for (index, sourceMain) in sources.enumerated() {
        try leaveCommittedMessageUpdateInWAL(
            mainURL: sourceMain,
            messageID: messageID,
            title: sourceTitles[index].title
        )
    }
    try #require(!FileManager.default.fileExists(atPath: targetMain.path))
    return (targetMain, sources)
}

private func startMigrationChild(
    executable: URL,
    role: String,
    root: URL,
    appGroupIdentifier: String,
    targetMain: URL,
    firstSourceMain: URL,
    controlDirectory: URL
) throws -> Process {
    let process = Process()
    process.executableURL = executable
    process.arguments = [
        "migrate", role, appGroupIdentifier, targetMain.path,
        firstSourceMain.path, controlDirectory.path,
    ]
    var environment = ProcessInfo.processInfo.environment
    environment["PUSHGO_AUTOMATION_STORAGE_ROOT"] = root.path
    process.environment = environment
    let logURL = controlDirectory.appendingPathComponent("\(role)-process.log")
    FileManager.default.createFile(atPath: logURL.path, contents: nil)
    let output = try FileHandle(forWritingTo: logURL)
    process.standardOutput = output
    process.standardError = output
    try process.run()
    try? output.close()
    return process
}

private func waitForMigrationSignal(
    _ name: String,
    in controlDirectory: URL,
    from process: Process? = nil
) throws {
    let signalURL = controlDirectory.appendingPathComponent(name)
    let deadline = Date().addingTimeInterval(20)
    while !FileManager.default.fileExists(atPath: signalURL.path) {
        if let process, !process.isRunning {
            throw NSError(
                domain: "io.ethan.pushgo.store-recovery-child",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "Child exited before signal \(name); evidence: \(controlDirectory.path)."]
            )
        }
        if Date() >= deadline {
            throw NSError(
                domain: "io.ethan.pushgo.store-recovery-child",
                code: 40,
                userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for signal \(name); evidence: \(controlDirectory.path)."]
            )
        }
        Thread.sleep(forTimeInterval: 0.01)
    }
}

private func releaseMigrationBarrier(_ name: String, in controlDirectory: URL) throws {
    try Data().write(to: controlDirectory.appendingPathComponent(name))
}

private func migrationChildPID(_ role: String, in controlDirectory: URL) throws -> Int32 {
    let url = controlDirectory.appendingPathComponent("\(role)-started")
    let value = try String(contentsOf: url, encoding: .utf8)
    return try #require(Int32(value))
}

private func waitForMigrationChildExit(_ process: Process, expectSuccess: Bool = true) throws {
    let deadline = Date().addingTimeInterval(20)
    while process.isRunning {
        if Date() >= deadline {
            throw NSError(
                domain: "io.ethan.pushgo.store-recovery-child",
                code: 41,
                userInfo: [NSLocalizedDescriptionKey: "Migration child did not exit after release."]
            )
        }
        Thread.sleep(forTimeInterval: 0.01)
    }
    if expectSuccess {
        try #require(process.terminationStatus == 0)
    }
}

private func migrationLockIsHeld(byAnotherProcess executable: URL, lockURL: URL) throws -> Bool {
    let probe = Process()
    probe.executableURL = executable
    probe.arguments = ["probe-lock", lockURL.path]
    try probe.run()
    probe.waitUntilExit()
    switch probe.terminationStatus {
    case 0: return false
    case 20: return true
    default:
        throw NSError(
            domain: "io.ethan.pushgo.store-recovery-child",
            code: Int(probe.terminationStatus),
            userInfo: [NSLocalizedDescriptionKey: "Cross-process lock probe failed."]
        )
    }
}

struct LocalDataStoreStoreRecoveryTests {
    @Test
    func legacyMainMovedBeforeWALCanRecoverUncheckpointedMessageOnReopen() async throws {
        try await withIsolatedAutomationStorage { root, appGroupIdentifier in
            let messageID = "interrupted-family-move-message"
            let originalTitle = "Before WAL update"
            let walTitle = "Persisted in legacy WAL"
            let message = PushMessage(
                messageId: messageID,
                title: originalTitle,
                body: "The message must survive a resumed file-family migration.",
                channel: "recovery"
            )

            do {
                let store = LocalDataStore(
                    appGroupIdentifier: appGroupIdentifier,
                    spotlightIndexer: nil
                )
                try await store.saveMessage(message)
                try #require(try await store.loadMessages().count == 1)
            }
            LocalDataStore.releaseSharedResourcesForTesting(storageRootURL: root)

            let directory = try AppConstants.appLocalDatabaseDirectory(
                appGroupIdentifier: appGroupIdentifier
            )
            let stableMainURL = directory.appendingPathComponent(AppConstants.databaseStoreFilename)
            // v11 is found by the production wildcard scan. Once the main
            // file moves, only its sidecars remain to identify this source.
            let legacyMainURL = directory.appendingPathComponent("pushgo-v11.db")
            for suffix in ["", "-wal", "-shm"] {
                let source = URL(fileURLWithPath: stableMainURL.path + suffix)
                guard FileManager.default.fileExists(atPath: source.path) else { continue }
                let destination = URL(fileURLWithPath: legacyMainURL.path + suffix)
                try FileManager.default.moveItem(at: source, to: destination)
            }

            // A separate process commits one business-row update and exits
            // without sqlite3_close, leaving the committed frame in the WAL.
            try leaveCommittedMessageUpdateInWAL(
                mainURL: legacyMainURL,
                messageID: messageID,
                title: walTitle
            )
            let legacyWALURL = URL(fileURLWithPath: legacyMainURL.path + "-wal")

            let failingFileManager = FailAfterLegacyMainMoveFileManager(legacyMainURL: legacyMainURL)
            #expect(throws: (any Error).self) {
                _ = try AppConstants.appLocalDatabaseDirectory(
                    fileManager: failingFileManager,
                    appGroupIdentifier: appGroupIdentifier
                )
            }
            try #require(FileManager.default.fileExists(atPath: stableMainURL.path))
            try #require(!FileManager.default.fileExists(atPath: legacyMainURL.path))
            try #require(FileManager.default.fileExists(atPath: legacyWALURL.path))

            let reopened = LocalDataStore(
                appGroupIdentifier: appGroupIdentifier,
                spotlightIndexer: nil
            )
            #expect(reopened.storageState.mode == .persistent)
            let recovered = try #require(try await reopened.loadMessage(messageId: messageID))
            #expect(recovered.title == walTitle)
            #expect(try await reopened.loadMessages().count == 1)
        }
    }

    @Test
    func sharedMainCopiedBeforeWALCanRecoverUncheckpointedMessageOnReopen() async throws {
        try await withIsolatedAutomationStorage { root, appGroupIdentifier in
            let messageID = "interrupted-shared-copy-message"
            let walTitle = "Committed in shared WAL"
            let message = PushMessage(
                messageId: messageID,
                title: "Before shared WAL update",
                body: "The app-local copy must retain the committed WAL frame.",
                channel: "recovery"
            )
            do {
                let store = LocalDataStore(
                    appGroupIdentifier: appGroupIdentifier,
                    spotlightIndexer: nil
                )
                try await store.saveMessage(message)
                try #require(try await store.loadMessages().count == 1)
            }
            LocalDataStore.releaseSharedResourcesForTesting(storageRootURL: root)

            let appLocalDirectory = try AppConstants.appLocalDatabaseDirectory(
                appGroupIdentifier: appGroupIdentifier
            )
            let appLocalMainURL = appLocalDirectory.appendingPathComponent(AppConstants.databaseStoreFilename)
            let sharedDirectory = root
                .appendingPathComponent("app-groups", isDirectory: true)
                .appendingPathComponent(appGroupIdentifier, isDirectory: true)
                .appendingPathComponent("Database", isDirectory: true)
            try FileManager.default.createDirectory(at: sharedDirectory, withIntermediateDirectories: true)
            let sharedMainURL = sharedDirectory.appendingPathComponent(AppConstants.databaseStoreFilename)
            for suffix in ["", "-wal", "-shm"] {
                let source = URL(fileURLWithPath: appLocalMainURL.path + suffix)
                guard FileManager.default.fileExists(atPath: source.path) else { continue }
                let destination = URL(fileURLWithPath: sharedMainURL.path + suffix)
                try FileManager.default.moveItem(at: source, to: destination)
            }
            try leaveCommittedMessageUpdateInWAL(
                mainURL: sharedMainURL,
                messageID: messageID,
                title: walTitle
            )

            let sharedWALURL = URL(fileURLWithPath: sharedMainURL.path + "-wal")
            let failingFileManager = FailBeforeSharedWALCopyFileManager(sharedWALURL: sharedWALURL)
            #expect(throws: (any Error).self) {
                _ = try AppConstants.appLocalDatabaseDirectory(
                    fileManager: failingFileManager,
                    appGroupIdentifier: appGroupIdentifier
                )
            }
            try #require(FileManager.default.fileExists(atPath: appLocalMainURL.path))
            try #require(!FileManager.default.fileExists(atPath: appLocalMainURL.path + "-wal"))
            try #require(FileManager.default.fileExists(atPath: sharedWALURL.path))

            let reopened = LocalDataStore(
                appGroupIdentifier: appGroupIdentifier,
                spotlightIndexer: nil
            )
            #expect(reopened.storageState.mode == .persistent)
            let recovered = try #require(try await reopened.loadMessage(messageId: messageID))
            #expect(recovered.title == walTitle)
            #expect(try await reopened.loadMessages().count == 1)
        }
    }

    @Test
    func partialSharedMainCopyDoesNotBecomeTheRecoveredDatabase() async throws {
        try await withIsolatedAutomationStorage { root, appGroupIdentifier in
            let messageID = "partial-shared-main-copy-message"
            let walTitle = "Committed before partial copy"
            let message = PushMessage(
                messageId: messageID,
                title: "Before partial copy",
                body: "A short destination file must never replace this message.",
                channel: "recovery"
            )
            do {
                let store = LocalDataStore(
                    appGroupIdentifier: appGroupIdentifier,
                    spotlightIndexer: nil
                )
                try await store.saveMessage(message)
                try #require(try await store.loadMessages().count == 1)
            }
            LocalDataStore.releaseSharedResourcesForTesting(storageRootURL: root)

            let appLocalDirectory = try AppConstants.appLocalDatabaseDirectory(
                appGroupIdentifier: appGroupIdentifier
            )
            let appLocalMainURL = appLocalDirectory.appendingPathComponent(AppConstants.databaseStoreFilename)
            let sharedDirectory = root
                .appendingPathComponent("app-groups", isDirectory: true)
                .appendingPathComponent(appGroupIdentifier, isDirectory: true)
                .appendingPathComponent("Database", isDirectory: true)
            try FileManager.default.createDirectory(at: sharedDirectory, withIntermediateDirectories: true)
            let sharedMainURL = sharedDirectory.appendingPathComponent(AppConstants.databaseStoreFilename)
            for suffix in ["", "-wal", "-shm"] {
                let source = URL(fileURLWithPath: appLocalMainURL.path + suffix)
                guard FileManager.default.fileExists(atPath: source.path) else { continue }
                let destination = URL(fileURLWithPath: sharedMainURL.path + suffix)
                try FileManager.default.moveItem(at: source, to: destination)
            }
            try leaveCommittedMessageUpdateInWAL(
                mainURL: sharedMainURL,
                messageID: messageID,
                title: walTitle
            )

            let failingFileManager = PartialSharedMainCopyFileManager(
                sharedMainURL: sharedMainURL
            )
            // A correct migration can throw and resume later or repair within
            // this call. Only the reopened business data is the acceptance oracle.
            _ = try? AppConstants.appLocalDatabaseDirectory(
                fileManager: failingFileManager,
                appGroupIdentifier: appGroupIdentifier
            )
            try #require(failingFileManager.didInjectFailure)
            try #require(FileManager.default.fileExists(atPath: sharedMainURL.path))

            let reopened = LocalDataStore(
                appGroupIdentifier: appGroupIdentifier,
                spotlightIndexer: nil
            )
            #expect(reopened.storageState.mode == .persistent)
            let recovered = try #require(try await reopened.loadMessage(messageId: messageID))
            #expect(recovered.title == walTitle)
            #expect(try await reopened.loadMessages().count == 1)
        }
    }

    @Test
    func partialFallbackCopyAfterLegacyMoveFailureRecoversOnReopen() async throws {
        try await withIsolatedAutomationStorage { root, appGroupIdentifier in
            let messageID = "partial-legacy-fallback-message"
            let walTitle = "Committed before fallback failure"
            let message = PushMessage(
                messageId: messageID,
                title: "Before fallback failure",
                body: "A failed fallback copy cannot publish a short main database.",
                channel: "recovery"
            )
            do {
                let store = LocalDataStore(
                    appGroupIdentifier: appGroupIdentifier,
                    spotlightIndexer: nil
                )
                try await store.saveMessage(message)
                try #require(try await store.loadMessages().count == 1)
            }
            LocalDataStore.releaseSharedResourcesForTesting(storageRootURL: root)

            let directory = try AppConstants.appLocalDatabaseDirectory(
                appGroupIdentifier: appGroupIdentifier
            )
            let stableMainURL = directory.appendingPathComponent(AppConstants.databaseStoreFilename)
            let legacyMainURL = directory.appendingPathComponent("pushgo-v11.db")
            for suffix in ["", "-wal", "-shm"] {
                let source = URL(fileURLWithPath: stableMainURL.path + suffix)
                guard FileManager.default.fileExists(atPath: source.path) else { continue }
                let destination = URL(fileURLWithPath: legacyMainURL.path + suffix)
                try FileManager.default.moveItem(at: source, to: destination)
            }
            try leaveCommittedMessageUpdateInWAL(
                mainURL: legacyMainURL,
                messageID: messageID,
                title: walTitle
            )

            let failingFileManager = FailLegacyMoveAndPartialFallbackCopyFileManager(
                legacyMainURL: legacyMainURL
            )
            _ = try? AppConstants.appLocalDatabaseDirectory(
                fileManager: failingFileManager,
                appGroupIdentifier: appGroupIdentifier
            )
            try #require(failingFileManager.didBlockMove)
            try #require(failingFileManager.didInjectPartialCopy)
            try #require(FileManager.default.fileExists(atPath: legacyMainURL.path))

            let reopened = LocalDataStore(
                appGroupIdentifier: appGroupIdentifier,
                spotlightIndexer: nil
            )
            #expect(reopened.storageState.mode == .persistent)
            let recovered = try #require(try await reopened.loadMessage(messageId: messageID))
            #expect(recovered.title == walTitle)
            #expect(try await reopened.loadMessages().count == 1)
        }
    }

    @Test
    func concurrentMigrationProcessesNeverMixLegacyFamilies() async throws {
        try await withIsolatedAutomationStorage { root, appGroupIdentifier in
            let messageID = "concurrent-family-message"
            let firstTitle = "First family WAL title"
            let prepared = try await prepareLegacyWALFamilies(
                root: root,
                appGroupIdentifier: appGroupIdentifier,
                messageID: messageID,
                sourceTitles: [
                    ("pushgo-v11.db", firstTitle),
                    ("pushgo-v10.db", "Second family WAL title"),
                ]
            )
            let firstSourceMain = prepared.sources[0]
            let secondSourceMain = prepared.sources[1]
            let firstWALURL = URL(fileURLWithPath: firstSourceMain.path + "-wal")
            let firstWALBytes = try Data(contentsOf: firstWALURL)
            let controlDirectory = root.appendingPathComponent("migration-control", isDirectory: true)
            try FileManager.default.createDirectory(at: controlDirectory, withIntermediateDirectories: true)
            let executable = try migrationChildExecutable()
            let lockURL = prepared.targetMain.deletingLastPathComponent()
                .appendingPathComponent(".pushgo-sqlite-migration.lock")

            let first = try startMigrationChild(
                executable: executable,
                role: "first",
                root: root,
                appGroupIdentifier: appGroupIdentifier,
                targetMain: prepared.targetMain,
                firstSourceMain: firstSourceMain,
                controlDirectory: controlDirectory
            )
            defer {
                if first.isRunning {
                    first.terminate()
                    first.waitUntilExit()
                }
            }
            try waitForMigrationSignal("first-target-absent", in: controlDirectory, from: first)

            let second = try startMigrationChild(
                executable: executable,
                role: "second",
                root: root,
                appGroupIdentifier: appGroupIdentifier,
                targetMain: prepared.targetMain,
                firstSourceMain: firstSourceMain,
                controlDirectory: controlDirectory
            )
            defer {
                if second.isRunning {
                    second.terminate()
                    second.waitUntilExit()
                }
            }
            try waitForMigrationSignal("second-started", in: controlDirectory, from: second)
            let firstPID = try migrationChildPID("first", in: controlDirectory)
            let secondPID = try migrationChildPID("second", in: controlDirectory)
            #expect(firstPID == first.processIdentifier)
            #expect(secondPID == second.processIdentifier)
            #expect(firstPID != secondPID)
            let firstHeldLock = try migrationLockIsHeld(
                byAnotherProcess: executable,
                lockURL: lockURL
            )

            // With no family lock, both children capture target-absent before
            // either publishes a main file. Release them in the interleaving
            // that formerly attached v10's WAL to v11's main database.
            if !firstHeldLock {
                try waitForMigrationSignal("second-target-absent", in: controlDirectory, from: second)
            }
            try releaseMigrationBarrier("release-first-target", in: controlDirectory)
            try waitForMigrationSignal("first-main-moved", in: controlDirectory, from: first)
            if !firstHeldLock {
                try releaseMigrationBarrier("release-second-target", in: controlDirectory)
                try waitForMigrationSignal("second-done", in: controlDirectory, from: second)
                try waitForMigrationChildExit(second)
            }
            try releaseMigrationBarrier("release-first-main", in: controlDirectory)
            if firstHeldLock {
                try waitForMigrationSignal("first-done", in: controlDirectory, from: first)
            }
            try waitForMigrationChildExit(first, expectSuccess: firstHeldLock)
            if firstHeldLock {
                try waitForMigrationSignal("second-done", in: controlDirectory, from: second)
                try waitForMigrationChildExit(second)
            }

            #expect(firstHeldLock)
            let targetWALURL = URL(fileURLWithPath: prepared.targetMain.path + "-wal")
            let targetWALBytes = try Data(contentsOf: targetWALURL)
            #expect(targetWALBytes == firstWALBytes)
            #expect(FileManager.default.fileExists(atPath: secondSourceMain.path))
            #expect(FileManager.default.fileExists(atPath: secondSourceMain.path + "-wal"))

            let reopened = LocalDataStore(
                appGroupIdentifier: appGroupIdentifier,
                spotlightIndexer: nil
            )
            #expect(reopened.storageState.mode == .persistent)
            let recovered = try #require(try await reopened.loadMessage(messageId: messageID))
            #expect(recovered.title == firstTitle)
            #expect(try await reopened.loadMessages().count == 1)
        }
    }

    @Test
    func killedMigrationProcessReleasesLockAndResumesItsWALFamily() async throws {
        try await withIsolatedAutomationStorage { root, appGroupIdentifier in
            let messageID = "killed-family-migration-message"
            let walTitle = "Committed before migration process died"
            let prepared = try await prepareLegacyWALFamilies(
                root: root,
                appGroupIdentifier: appGroupIdentifier,
                messageID: messageID,
                sourceTitles: [("pushgo-v11.db", walTitle)]
            )
            let firstSourceMain = prepared.sources[0]
            let firstWALBytes = try Data(contentsOf: URL(fileURLWithPath: firstSourceMain.path + "-wal"))
            let controlDirectory = root.appendingPathComponent("migration-crash-control", isDirectory: true)
            try FileManager.default.createDirectory(at: controlDirectory, withIntermediateDirectories: true)
            let executable = try migrationChildExecutable()
            let lockURL = prepared.targetMain.deletingLastPathComponent()
                .appendingPathComponent(".pushgo-sqlite-migration.lock")

            let first = try startMigrationChild(
                executable: executable,
                role: "first",
                root: root,
                appGroupIdentifier: appGroupIdentifier,
                targetMain: prepared.targetMain,
                firstSourceMain: firstSourceMain,
                controlDirectory: controlDirectory
            )
            defer {
                if first.isRunning {
                    first.terminate()
                    first.waitUntilExit()
                }
            }
            try waitForMigrationSignal("first-target-absent", in: controlDirectory, from: first)
            let heldBeforeTermination = try migrationLockIsHeld(
                byAnotherProcess: executable,
                lockURL: lockURL
            )
            try releaseMigrationBarrier("release-first-target", in: controlDirectory)
            try waitForMigrationSignal("first-main-moved", in: controlDirectory, from: first)
            let firstPID = try migrationChildPID("first", in: controlDirectory)
            #expect(firstPID == first.processIdentifier)
            try releaseMigrationBarrier("kill-first-main", in: controlDirectory)
            first.waitUntilExit()
            #expect(first.terminationReason == .uncaughtSignal)
            #expect(first.terminationStatus == SIGKILL)
            let heldAfterTermination = try migrationLockIsHeld(
                byAnotherProcess: executable,
                lockURL: lockURL
            )

            let second = try startMigrationChild(
                executable: executable,
                role: "normal",
                root: root,
                appGroupIdentifier: appGroupIdentifier,
                targetMain: prepared.targetMain,
                firstSourceMain: firstSourceMain,
                controlDirectory: controlDirectory
            )
            defer {
                if second.isRunning {
                    second.terminate()
                    second.waitUntilExit()
                }
            }
            try waitForMigrationSignal("normal-done", in: controlDirectory, from: second)
            try waitForMigrationChildExit(second)
            let normalPID = try migrationChildPID("normal", in: controlDirectory)
            #expect(normalPID == second.processIdentifier)
            #expect(normalPID != firstPID)

            #expect(heldBeforeTermination)
            #expect(!heldAfterTermination)
            let targetWALURL = URL(fileURLWithPath: prepared.targetMain.path + "-wal")
            #expect(try Data(contentsOf: targetWALURL) == firstWALBytes)
            let reopened = LocalDataStore(
                appGroupIdentifier: appGroupIdentifier,
                spotlightIndexer: nil
            )
            #expect(reopened.storageState.mode == .persistent)
            let recovered = try #require(try await reopened.loadMessage(messageId: messageID))
            #expect(recovered.title == walTitle)
            #expect(try await reopened.loadMessages().count == 1)
        }
    }
}
