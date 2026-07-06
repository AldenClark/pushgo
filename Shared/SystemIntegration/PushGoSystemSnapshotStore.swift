import Foundation
#if canImport(WidgetKit)
import WidgetKit
#endif

enum PushGoSystemSnapshotStore {
    private static let directoryName = "system-surface-snapshot"
    private static let fileName = "snapshot.bin"
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
        guard let fileURL = snapshotFileURL(
            fileManager: fileManager,
            appGroupIdentifier: appGroupIdentifier
        ) else {
            return false
        }
        let didWrite = write(snapshot, to: fileURL, fileManager: fileManager)
        if didWrite {
            reloadWidgets()
        }
        return didWrite
    }

    @discardableResult
    static func write(
        _ snapshot: PushGoSystemSurfaceSnapshot,
        to fileURL: URL,
        fileManager: FileManager = .default
    ) -> Bool {
        let directoryURL = fileURL.deletingLastPathComponent()
        do {
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            let data = try encoder.encode(snapshot)
            let temporaryURL = directoryURL.appendingPathComponent(
                ".\(fileName).tmp-\(UUID().uuidString.lowercased())",
                isDirectory: false
            )
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
        guard let fileURL = snapshotFileURL(
            fileManager: fileManager,
            appGroupIdentifier: appGroupIdentifier
        ) else {
            return false
        }
        let didClear = clear(at: fileURL, fileManager: fileManager)
        if didClear {
            reloadWidgets()
        }
        return didClear
    }

    @discardableResult
    static func clear(
        at fileURL: URL,
        fileManager: FileManager = .default
    ) -> Bool {
        guard fileManager.fileExists(atPath: fileURL.path) else { return true }
        do {
            try fileManager.removeItem(at: fileURL)
            return true
        } catch {
            return false
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
}
