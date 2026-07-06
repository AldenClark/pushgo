import Foundation

enum PushGoWidgetEntityKind: String, Codable {
    case message
    case event
    case thing
}

struct PushGoWidgetOpenTarget: Codable, Hashable {
    enum Source: String, Codable, Hashable {
        case notification
        case spotlight
        case appIntent
        case shortcut
        case userActivity
        case widget
        case deepLink
        case automation
    }

    enum Destination: String, Codable, Hashable {
        case detail
        case list
    }

    let kind: PushGoWidgetEntityKind
    let identifier: String
    let localMessageID: UUID?
    let source: Source
    let destination: Destination

    func url() -> URL? {
        var components = URLComponents()
        components.scheme = "pushgo"
        components.host = "open"
        components.queryItems = [
            URLQueryItem(name: "kind", value: kind.rawValue),
            URLQueryItem(name: "id", value: identifier),
        ]
        return components.url
    }

    static func list(kind: PushGoWidgetEntityKind) -> PushGoWidgetOpenTarget {
        PushGoWidgetOpenTarget(
            kind: kind,
            identifier: "list",
            localMessageID: nil,
            source: .widget,
            destination: .list
        )
    }
}

enum PushGoWidgetPendingOpenTargetStore {
    private static let defaultsKey = "pushgo.system_integration.pending_open_target.v1"

    static func save(_ target: PushGoWidgetOpenTarget) {
        guard let data = try? JSONEncoder().encode(target) else { return }
        UserDefaults(suiteName: PushGoWidgetSnapshotStore.appGroupIdentifier)?
            .set(data, forKey: defaultsKey)
    }
}

enum PushGoWidgetPendingActionStore {
    private static let defaultsKey = "pushgo.system_integration.pending_action.v1"

    static func saveMarkLatestUnreadMessageRead() {
        guard let data = try? JSONEncoder().encode("markLatestUnreadMessageRead") else { return }
        UserDefaults(suiteName: PushGoWidgetSnapshotStore.appGroupIdentifier)?
            .set(data, forKey: defaultsKey)
    }
}

struct PushGoWidgetSnapshot: Codable {
    struct Counts: Codable {
        let totalMessages: Int
        let unreadMessages: Int
        let criticalEvents: Int
        let objectWarnings: Int
    }

    struct FocusState: Codable {
        let mode: String
        let updatedAtEpochMs: Int64
    }

    struct Item: Codable, Identifiable {
        let id: String
        let kind: PushGoWidgetEntityKind
        let title: String
        let subtitle: String?
        let bodyPreview: String?
        let status: String?
        let severity: String?
        let channelID: String?
        let eventID: String?
        let thingID: String?
        let updatedAtEpochMs: Int64
        let imageURL: String?
        let accessibilityLabel: String
        let accessibilityValue: String?
        let openTarget: PushGoWidgetOpenTarget?

        func withStatus(_ newStatus: String) -> Item {
            Item(
                id: id,
                kind: kind,
                title: title,
                subtitle: subtitle,
                bodyPreview: bodyPreview,
                status: newStatus,
                severity: severity,
                channelID: channelID,
                eventID: eventID,
                thingID: thingID,
                updatedAtEpochMs: updatedAtEpochMs,
                imageURL: imageURL,
                accessibilityLabel: accessibilityLabel,
                accessibilityValue: accessibilityValue,
                openTarget: openTarget
            )
        }
    }

    static let schemaVersion = 1

    let schemaVersion: Int
    let generatedAtEpochMs: Int64
    let source: String
    let counts: Counts
    let focusState: FocusState
    let recentMessages: [Item]
    let unreadMessages: [Item]
    let criticalEvents: [Item]
    let objectWarnings: [Item]
    let latestObjectStates: [Item]

    static let empty = PushGoWidgetSnapshot(
        schemaVersion: schemaVersion,
        generatedAtEpochMs: 0,
        source: "empty",
        counts: Counts(totalMessages: 0, unreadMessages: 0, criticalEvents: 0, objectWarnings: 0),
        focusState: FocusState(mode: "all", updatedAtEpochMs: 0),
        recentMessages: [],
        unreadMessages: [],
        criticalEvents: [],
        objectWarnings: [],
        latestObjectStates: []
    )

    func replacing(
        counts newCounts: Counts,
        recentMessages newRecentMessages: [Item],
        unreadMessages newUnreadMessages: [Item]
    ) -> PushGoWidgetSnapshot {
        PushGoWidgetSnapshot(
            schemaVersion: schemaVersion,
            generatedAtEpochMs: Int64((Date().timeIntervalSince1970 * 1_000).rounded()),
            source: source,
            counts: newCounts,
            focusState: focusState,
            recentMessages: newRecentMessages,
            unreadMessages: newUnreadMessages,
            criticalEvents: criticalEvents,
            objectWarnings: objectWarnings,
            latestObjectStates: latestObjectStates
        )
    }
}

enum PushGoWidgetSnapshotStore {
    #if os(macOS)
    static let appGroupIdentifier = "W6H9P5MVUB.group.ethan.pushgo.messages"
    #else
    static let appGroupIdentifier = "group.ethan.pushgo.messages"
    #endif

    static func load() -> PushGoWidgetSnapshot {
        guard let fileURL = snapshotFileURL() else {
            return .empty
        }
        guard FileManager.default.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL),
              let snapshot = try? PropertyListDecoder().decode(PushGoWidgetSnapshot.self, from: data),
              snapshot.schemaVersion == PushGoWidgetSnapshot.schemaVersion
        else {
            return .empty
        }
        return snapshot
    }

    static func write(_ snapshot: PushGoWidgetSnapshot) {
        guard let fileURL = snapshotFileURL() else { return }
        let directoryURL = fileURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            let data = try encoder.encode(snapshot)
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            return
        }
    }

    private static func snapshotFileURL() -> URL? {
        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier) else {
            return nil
        }
        return container
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("system-surface-snapshot", isDirectory: true)
            .appendingPathComponent("snapshot.bin", isDirectory: false)
    }
}
