import Foundation
import Darwin
#if canImport(WidgetKit)
import WidgetKit
#endif

enum PushGoSystemSnapshotStore {
    enum StoreError: Error, Equatable {
        case appGroupContainerUnavailable(String)
        case lockUnavailable(Int32)
    }

    private static let directoryName = "system-surface-snapshot"
    private static let fileName = "snapshot.bin"
    private static let processLock = NSLock()
    private static let widgetKinds = [
        "io.ethan.pushgo.widgets.unread",
        "io.ethan.pushgo.widgets.critical-events",
        "io.ethan.pushgo.widgets.object-status",
        "io.ethan.pushgo.widgets.watch-summary",
    ]

    static func snapshotFileURL(
        fileManager: FileManager = .default,
        appGroupIdentifier: String = AppConstants.appGroupIdentifier
    ) -> URL? {
        guard let containerURL = AppConstants.appGroupContainerURL(
            fileManager: fileManager,
            identifier: appGroupIdentifier
        ) else {
            return nil
        }
        return containerURL
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent(directoryName, isDirectory: true)
            .appendingPathComponent(fileName, isDirectory: false)
    }

    static func load(
        fileManager: FileManager = .default,
        appGroupIdentifier: String = AppConstants.appGroupIdentifier
    ) -> PushGoSystemSurfaceSnapshot? {
        guard let fileURL = snapshotFileURL(
            fileManager: fileManager,
            appGroupIdentifier: appGroupIdentifier
        ) else {
            return nil
        }
        return load(from: fileURL, fileManager: fileManager)
    }

    static func load(
        from fileURL: URL,
        fileManager: FileManager = .default
    ) -> PushGoSystemSurfaceSnapshot? {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return nil
        }
        do {
            let data = try Data(contentsOf: fileURL)
            let snapshot = try PropertyListDecoder().decode(PushGoSystemSurfaceSnapshot.self, from: data)
            guard snapshot.schemaVersion == PushGoSystemSurfaceSnapshot.schemaVersion else {
                return nil
            }
            return snapshot
        } catch {
            try? fileManager.removeItem(at: fileURL)
            return nil
        }
    }

    @discardableResult
    static func write(
        _ snapshot: PushGoSystemSurfaceSnapshot,
        fileManager: FileManager = .default,
        appGroupIdentifier: String = AppConstants.appGroupIdentifier
    ) -> Bool {
        do {
            try writeOrThrow(
                snapshot,
                fileManager: fileManager,
                appGroupIdentifier: appGroupIdentifier
            )
            return true
        } catch {
            return false
        }
    }

    @discardableResult
    static func write(
        _ snapshot: PushGoSystemSurfaceSnapshot,
        to fileURL: URL,
        fileManager: FileManager = .default
    ) -> Bool {
        do {
            try writeOrThrow(snapshot, to: fileURL, fileManager: fileManager)
            return true
        } catch {
            return false
        }
    }

    static func writeOrThrow(
        _ snapshot: PushGoSystemSurfaceSnapshot,
        fileManager: FileManager = .default,
        appGroupIdentifier: String = AppConstants.appGroupIdentifier
    ) throws {
        guard let fileURL = snapshotFileURL(
            fileManager: fileManager,
            appGroupIdentifier: appGroupIdentifier
        ) else {
            throw StoreError.appGroupContainerUnavailable(appGroupIdentifier)
        }
        try writeOrThrow(snapshot, to: fileURL, fileManager: fileManager)
        reloadWidgets()
    }

    static func writeOrThrow(
        _ snapshot: PushGoSystemSurfaceSnapshot,
        to fileURL: URL,
        fileManager: FileManager = .default
    ) throws {
        try withExclusiveLock(for: fileURL, fileManager: fileManager) {
            try writeUnlocked(snapshot, to: fileURL, fileManager: fileManager)
        }
    }

    /// Serializes the small snapshot read/modify/write window across the host
    /// and notification extensions. The closure must stay CPU/file-local; no
    /// network or message-database work belongs inside this lock.
    static func updateAtomically<Result>(
        fileManager: FileManager = .default,
        appGroupIdentifier: String = AppConstants.appGroupIdentifier,
        _ mutation: (PushGoSystemSurfaceSnapshot?) -> (PushGoSystemSurfaceSnapshot, Result)?
    ) -> Result? {
        guard let fileURL = snapshotFileURL(
            fileManager: fileManager,
            appGroupIdentifier: appGroupIdentifier
        ) else {
            return nil
        }
        do {
            let result = try withExclusiveLock(for: fileURL, fileManager: fileManager) {
                guard let (snapshot, result) = mutation(
                    load(from: fileURL, fileManager: fileManager)
                ) else {
                    return Optional<Result>.none
                }
                try writeUnlocked(snapshot, to: fileURL, fileManager: fileManager)
                return Optional(result)
            }
            if result != nil {
                reloadWidgets()
            }
            return result
        } catch {
            return nil
        }
    }

    private static func writeUnlocked(
        _ snapshot: PushGoSystemSurfaceSnapshot,
        to fileURL: URL,
        fileManager: FileManager
    ) throws {
        let directoryURL = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let data = try encoder.encode(snapshot)
        let temporaryURL = directoryURL.appendingPathComponent(
            ".\(fileName).tmp-\(UUID().uuidString.lowercased())",
            isDirectory: false
        )
        do {
            try data.write(to: temporaryURL, options: [])
            if fileManager.fileExists(atPath: fileURL.path) {
                _ = try fileManager.replaceItemAt(
                    fileURL,
                    withItemAt: temporaryURL,
                    backupItemName: nil,
                    options: [.usingNewMetadataOnly]
                )
            } else {
                try fileManager.moveItem(at: temporaryURL, to: fileURL)
            }
        } catch {
            try? fileManager.removeItem(at: temporaryURL)
            throw error
        }
    }

    static func clearOrThrow(
        fileManager: FileManager = .default,
        appGroupIdentifier: String = AppConstants.appGroupIdentifier
    ) throws {
        guard let fileURL = snapshotFileURL(
            fileManager: fileManager,
            appGroupIdentifier: appGroupIdentifier
        ) else {
            throw StoreError.appGroupContainerUnavailable(appGroupIdentifier)
        }
        try clearOrThrow(at: fileURL, fileManager: fileManager)
        reloadWidgets()
    }

    static func clearOrThrow(
        at fileURL: URL,
        fileManager: FileManager = .default
    ) throws {
        try withExclusiveLock(for: fileURL, fileManager: fileManager) {
            guard fileManager.fileExists(atPath: fileURL.path) else { return }
            try fileManager.removeItem(at: fileURL)
        }
    }

    @discardableResult
    private static func ignoringFailure(_ operation: () throws -> Void) -> Bool {
        do {
            try operation()
            return true
        } catch {
            return false
        }
    }

    @discardableResult
    static func clear(
        fileManager: FileManager = .default,
        appGroupIdentifier: String = AppConstants.appGroupIdentifier
    ) -> Bool {
        do {
            try clearOrThrow(
                fileManager: fileManager,
                appGroupIdentifier: appGroupIdentifier
            )
            return true
        } catch {
            return false
        }
    }

    @discardableResult
    static func clear(
        at fileURL: URL,
        fileManager: FileManager = .default
    ) -> Bool {
        ignoringFailure {
            try clearOrThrow(at: fileURL, fileManager: fileManager)
        }
    }

    private static func reloadWidgets() {
        #if canImport(WidgetKit)
        for kind in widgetKinds {
            WidgetCenter.shared.reloadTimelines(ofKind: kind)
        }
        WidgetCenter.shared.reloadAllTimelines()
        #endif
    }

    private static func withExclusiveLock<Result>(
        for fileURL: URL,
        fileManager: FileManager,
        _ operation: () throws -> Result
    ) throws -> Result {
        processLock.lock()
        defer { processLock.unlock() }
        return try withExclusiveFileLock(
            for: fileURL,
            fileManager: fileManager,
            operation
        )
    }

    private static func withExclusiveFileLock<Result>(
        for fileURL: URL,
        fileManager: FileManager,
        _ operation: () throws -> Result
    ) throws -> Result {
        let directoryURL = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let lockURL = directoryURL.appendingPathComponent(".snapshot.lock", isDirectory: false)
        let descriptor = lockURL.path.withCString {
            Darwin.open($0, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        }
        guard descriptor >= 0 else {
            throw StoreError.lockUnavailable(errno)
        }
        defer { Darwin.close(descriptor) }
        var fileLock = flock()
        fileLock.l_type = Int16(F_WRLCK)
        fileLock.l_whence = Int16(SEEK_SET)
        guard Darwin.fcntl(descriptor, F_SETLKW, &fileLock) != -1 else {
            throw StoreError.lockUnavailable(errno)
        }
        defer {
            fileLock.l_type = Int16(F_UNLCK)
            _ = Darwin.fcntl(descriptor, F_SETLK, &fileLock)
        }
        return try operation()
    }

    static func waitForWidgetReloadRequestDelivery(timeout: Duration = .milliseconds(350)) async {
        #if canImport(WidgetKit)
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                await widgetCenterConfigurationsHandshake()
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
            }
            await group.next()
            group.cancelAll()
        }
        #endif
    }

    #if canImport(WidgetKit)
    private static func widgetCenterConfigurationsHandshake() async {
        await withCheckedContinuation { continuation in
            WidgetCenter.shared.getCurrentConfigurations { _ in
                continuation.resume()
            }
        }
    }
    #endif
}
