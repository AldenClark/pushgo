import Foundation

actor NotificationIngressInbox {
    struct StoredEntry: Codable, Sendable {
        let schemaVersion: Int
        let entryId: String
        let createdAtEpochMs: Int64
        let source: String
        let requestIdentifier: String?
        let payload: [String: AnyCodable]
    }

    struct PendingEntry: Sendable {
        let fileName: String
        let fileURL: URL
        let record: StoredEntry

        var payload: [AnyHashable: Any] {
            record.payload.reduce(into: [AnyHashable: Any]()) { result, item in
                result[item.key] = item.value.value
            }
        }
    }

    static let shared = NotificationIngressInbox()

    private static let schemaVersion = 1
    private static let fileExtension = "inboxbin"
    private static let directoryName = "notification-ingress-inbox"

    private let fileManager: FileManager
    private let appGroupIdentifier: String
    private let encoder: PropertyListEncoder
    private let decoder: PropertyListDecoder

    init(
        fileManager: FileManager = .default,
        appGroupIdentifier: String = AppConstants.appGroupIdentifier
    ) {
        self.fileManager = fileManager
        self.appGroupIdentifier = appGroupIdentifier

        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        self.encoder = encoder
        decoder = PropertyListDecoder()
    }

    @discardableResult
    func enqueue(
        payload: [AnyHashable: Any],
        requestIdentifier: String?,
        source: String
    ) -> Bool {
        let sanitized = UserInfoSanitizer.sanitize(payload)
        let codablePayload = codablePayloadDictionary(from: sanitized)
        return enqueue(
            codablePayload: codablePayload,
            requestIdentifier: requestIdentifier,
            source: source
        )
    }

    @discardableResult
    func enqueue(
        codablePayload: [String: AnyCodable],
        requestIdentifier: String?,
        source: String
    ) -> Bool {
        guard let directoryURL = inboxDirectoryURL() else {
            return false
        }
        let createdAtEpochMs = Int64((Date().timeIntervalSince1970 * 1_000).rounded())
        let deliveryId = normalizedText(codablePayload["delivery_id"]?.value as? String)
        let idempotencyKey = deliveryId.map { "delivery-\(Self.filesystemComponent($0))" }
        let entryID = idempotencyKey ?? UUID().uuidString.lowercased()
        let record = StoredEntry(
            schemaVersion: Self.schemaVersion,
            entryId: entryID,
            createdAtEpochMs: createdAtEpochMs,
            source: normalizedText(source) ?? "unknown",
            requestIdentifier: normalizedText(requestIdentifier),
            payload: codablePayload
        )
        guard let data = try? encoder.encode(record) else {
            return false
        }

        let fileName = idempotencyKey.map { "\($0).\(Self.fileExtension)" }
            ?? "\(createdAtEpochMs)-\(entryID).\(Self.fileExtension)"
        let finalURL = directoryURL.appendingPathComponent(fileName, isDirectory: false)
        let tempURL = directoryURL.appendingPathComponent(
            ".\(fileName).tmp-\(UUID().uuidString.lowercased())",
            isDirectory: false
        )

        do {
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            try data.write(to: tempURL, options: [])
            if fileManager.fileExists(atPath: finalURL.path) {
                _ = try fileManager.replaceItemAt(
                    finalURL,
                    withItemAt: tempURL,
                    backupItemName: nil,
                    options: [.usingNewMetadataOnly]
                )
            } else {
                try fileManager.moveItem(at: tempURL, to: finalURL)
            }
            return true
        } catch {
            try? fileManager.removeItem(at: tempURL)
            return false
        }
    }

    func pendingEntries(limit: Int? = nil) -> [PendingEntry] {
        guard let directoryURL = inboxDirectoryURL(),
              let contents = try? fileManager.contentsOfDirectory(
                  at: directoryURL,
                  includingPropertiesForKeys: nil,
                  options: [.skipsHiddenFiles]
              )
        else {
            return []
        }

        let fileURLs = contents
            .filter { $0.pathExtension == Self.fileExtension }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        var entries: [PendingEntry] = []
        entries.reserveCapacity(fileURLs.count)
        for fileURL in fileURLs {
            if let max = limit, entries.count >= max {
                break
            }
            guard let data = try? Data(contentsOf: fileURL),
                  let record = try? decoder.decode(StoredEntry.self, from: data)
            else {
                // Drop unreadable/corrupted files to avoid repeated scan failures.
                try? fileManager.removeItem(at: fileURL)
                continue
            }
            entries.append(
                PendingEntry(
                    fileName: fileURL.lastPathComponent,
                    fileURL: fileURL,
                    record: record
                )
            )
        }
        return entries
    }

    func markCompleted(_ entry: PendingEntry) {
        try? fileManager.removeItem(at: entry.fileURL)
    }

    func markCompleted(fileName: String) {
        guard let directoryURL = inboxDirectoryURL() else { return }
        let fileURL = directoryURL.appendingPathComponent(fileName, isDirectory: false)
        try? fileManager.removeItem(at: fileURL)
    }

    private func inboxDirectoryURL() -> URL? {
        guard let containerURL = AppConstants.appGroupContainerURL(
            fileManager: fileManager,
            identifier: appGroupIdentifier
        ) else {
            return nil
        }
        return containerURL
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent(Self.directoryName, isDirectory: true)
    }

    private func codablePayloadDictionary(
        from payload: [AnyHashable: Any]
    ) -> [String: AnyCodable] {
        payload.reduce(into: [String: AnyCodable]()) { result, item in
            let key: String
            if let stringKey = item.key as? String {
                key = stringKey
            } else {
                key = String(describing: item.key)
            }
            result[key] = AnyCodable(item.value)
        }
    }

    private func normalizedText(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func filesystemComponent(_ value: String) -> String {
        Data(value.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "")
    }
}
