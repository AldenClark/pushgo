import CryptoKit
import Foundation
import Darwin
#if canImport(SQLite3)
import SQLite3
#endif

/// Stable canonical identity, never the currently selected Gateway or its token.
enum ImageResourceOwner: Hashable, Sendable {
    case message(localID: UUID)
    case entity(type: String, localID: String)
    case watchMessage(localID: String)
    case watchEntity(type: String, localID: String)

    var key: String {
        switch self {
        case let .message(id): return "message:" + id.uuidString
        case let .entity(type, id): return "entity-" + type + ":" + id
        case let .watchMessage(id): return "watch-message:" + id
        case let .watchEntity(type, id): return "watch-" + type + ":" + id
        }
    }
}

struct ImageResourceOwnerSnapshot: Sendable, Equatable {
    let owner: ImageResourceOwner
    let stamp: String
    let scope: String
    let canonicalID: String
}

func imageContentHash(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

/// The HTTP index is a private cache. Business references live in the canonical
/// store, so URL recency never becomes an independent retention authority.
struct ImageHTTPEntry: Codable, Sendable {
    var contentHash: String
    var headers: [String: String]
    var requestHeaders: [String: String]
    var responseTime: TimeInterval
    var initialAge: TimeInterval
    var lifetime: TimeInterval
    var noCache: Bool
    var mustRevalidate: Bool
    var vary: [String]

    var permitsStale: Bool { !noCache && !mustRevalidate }
    func isFresh(at now: Date) -> Bool {
        !noCache && max(0, initialAge + now.timeIntervalSince1970 - responseTime) < lifetime
    }
    func matches(_ request: [String: String]) -> Bool {
        !vary.contains("*") && vary.allSatisfy { field in
            // Automatic URLSession headers are not evidence of an empty
            // field. Unknown Vary dimensions require a new request.
            guard let stored = requestHeaders[field], let current = request[field] else { return false }
            return stored == current
        }
    }

    static func make(hash: String, response: HTTPURLResponse, request: [String: String],
                     started: Date, received: Date, previous: ImageHTTPEntry? = nil) -> ImageHTTPEntry? {
        var headers = previous?.headers ?? [:]
        let cacheFields: Set<String> = ["cache-control", "expires", "date", "age", "etag", "last-modified", "vary", "content-type"]
        for (key, value) in response.allHeaderFields {
            let name = String(describing: key).lowercased()
            if cacheFields.contains(name) { headers[name] = String(describing: value) }
        }
        if response.statusCode == 304 && !response.allHeaderFields.keys.contains(where: { String(describing: $0).lowercased() == "age" }) {
            headers.removeValue(forKey: "age")
        }
        let directives = headers["cache-control", default: ""].split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        if directives.contains("no-store") { return nil }
        let noCache = directives.contains { $0 == "no-cache" || $0.hasPrefix("no-cache=") }
        let maxAgeDirectives = directives.filter { $0.hasPrefix("max-age=") }
        let maxAge = maxAgeDirectives.count == 1 ? maxAgeDirectives.first
            .flatMap { Double($0.dropFirst(8).trimmingCharacters(in: CharacterSet(charactersIn: "\""))) } : nil
        let date = headers["date"].flatMap(Self.httpDate)
        let age = max(0, Double(headers["age"] ?? "") ?? 0)
        // RFC 9111 4.2.3: corrected_initial_age includes response delay.
        let apparentAge = date.map { max(0, received.timeIntervalSince($0)) } ?? 0
        let correctedAge = age + max(0, received.timeIntervalSince(started))
        let lifetime: TimeInterval
        if let maxAge, maxAge.isFinite, maxAge >= 0 {
            lifetime = maxAge
        } else if !maxAgeDirectives.isEmpty { lifetime = 0 }
        else if let expires = headers["expires"].flatMap(Self.httpDate) {
            lifetime = max(0, expires.timeIntervalSince(date ?? received))
        } else { lifetime = 0 } // deliberately no heuristic freshness
        let vary = headers["vary", default: ""].split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }.filter { !$0.isEmpty }
        return ImageHTTPEntry(contentHash: hash, headers: headers, requestHeaders: request,
                              responseTime: received.timeIntervalSince1970,
                              initialAge: max(apparentAge, correctedAge), lifetime: lifetime,
                              noCache: noCache, mustRevalidate: directives.contains("must-revalidate"), vary: vary)
    }

    static func httpDate(_ raw: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        for format in ["EEE',' dd MMM yyyy HH':'mm':'ss z", "EEEE',' dd-MMM-yy HH':'mm':'ss z", "EEE MMM d HH':'mm':'ss yyyy"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: raw) { return date }
        }
        return nil
    }
}

/// Fixed 256 lock shards coordinate atomic publication/read leases with GC
/// across app/extension processes. No per-resource lock-file history grows.
final class ImageResourceFileLease: @unchecked Sendable {
    private let descriptor: Int32
    private init(_ descriptor: Int32) { self.descriptor = descriptor }
    deinit { _ = flock(descriptor, LOCK_UN); _ = close(descriptor) }
    static func acquire(directory: URL, hash: String, exclusive: Bool = false) throws -> ImageResourceFileLease {
        guard hash.count == 64, hash.allSatisfy({ $0.isHexDigit }) else { throw URLError(.cannotOpenFile) }
        let locks = directory.appendingPathComponent("Metadata/Locks", isDirectory: true)
        try FileManager.default.createDirectory(at: locks, withIntermediateDirectories: true)
        let path = locks.appendingPathComponent(String(hash.prefix(2)) + ".lock").path
        let descriptor = open(path, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw URLError(.cannotOpenFile) }
        guard flock(descriptor, (exclusive ? LOCK_EX : LOCK_SH) | LOCK_NB) == 0 else {
            _ = close(descriptor); throw URLError(.resourceUnavailable)
        }
        return ImageResourceFileLease(descriptor)
    }
}

/// Keeps the existing per-store 64-consumer budget through caller decoding,
/// including cache hits. Copies share one permit; no second UI queue is added.
final class ImageResourceConsumerLease: @unchecked Sendable {
    private let release: @Sendable () async -> Void
    init(release: @escaping @Sendable () async -> Void) { self.release = release }
    deinit {
        let release = release
        Task { await release() }
    }
}

/// Immutable ownership wrapper; only ImageResourceStore's actor uses the
/// connection. The wrapper closes it without actor-deinit isolation violations.
private final class ImageResourceIndexConnection: @unchecked Sendable {
    let pointer: OpaquePointer
    init(_ pointer: OpaquePointer) { self.pointer = pointer }
    deinit { sqlite3_close(pointer) }
}

/// One subscriber cancelling does not cancel a shared download still needed by
/// another subscriber. At most four byte streams run; queued distinct requests
/// are capped at 32. No prefetch list or background refresh worker is created.
actor ImageResourceStore {
#if os(watchOS)
    private static let consumerLimit = 4
    private static let flightLimit = 4
    private static let streamLimit = 2
#else
    private static let consumerLimit = 64
    private static let flightLimit = 32
    private static let streamLimit = 4
#endif
    typealias Snapshot = @Sendable (ImageResourceOwner) async throws -> ImageResourceOwnerSnapshot?
    typealias ReadBinding = @Sendable (ImageResourceOwnerSnapshot, String) async throws -> String?
    typealias Bind = @Sendable (ImageResourceOwnerSnapshot, String, String) async throws -> Bool
    typealias Collect = @Sendable (String, @escaping @Sendable () -> Void) async throws -> Bool
    struct Result: Sendable {
        let data: Data
        let fileURL: URL?
        let isStale: Bool
        let isPersistent: Bool
        let fileLease: ImageResourceFileLease?
        let consumerLease: ImageResourceConsumerLease?
        init(data: Data, fileURL: URL?, isStale: Bool, isPersistent: Bool, fileLease: ImageResourceFileLease? = nil, consumerLease: ImageResourceConsumerLease? = nil) {
            self.data = data; self.fileURL = fileURL; self.isStale = isStale; self.isPersistent = isPersistent
            self.fileLease = fileLease; self.consumerLease = consumerLease
        }
        func retaining(_ consumer: ImageResourceConsumerLease) -> Result {
            Result(data: data, fileURL: fileURL, isStale: isStale, isPersistent: isPersistent,
                   fileLease: fileLease, consumerLease: consumer)
        }
    }
    private struct Flight { let task: Task<Result, Error>; let initiator: String; var users: Set<UUID> }
    private let directory: URL
    private let session: URLSession
    private let snapshot: Snapshot
    private let binding: ReadBinding
    private let bind: Bind
    private let collect: Collect
    private let allowedURL: @Sendable (URL) -> Bool
    private var flights: [String: Flight] = [:]
    private var activeDownloads = 0
    private var activeConsumers = 0
    private var slots: [CheckedContinuation<Void, Error>] = []
    private var index: ImageResourceIndexConnection?
    private var orphanEnumerator: FileManager.DirectoryEnumerator?
    private let requestHeaders = ["accept": "image/*", "accept-encoding": "identity"]

    init(directory: URL, session: URLSession? = nil,
         allowedURL: @escaping @Sendable (URL) -> Bool = { URLSanitizer.isAllowedRemoteURL($0) },
         snapshot: @escaping Snapshot, binding: @escaping ReadBinding,
         bind: @escaping Bind, collect: @escaping Collect) {
        self.directory = directory
        if let session { self.session = session } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.urlCache = nil
            configuration.httpCookieStorage = nil
            configuration.urlCredentialStorage = nil
            configuration.httpShouldSetCookies = false
            configuration.httpMaximumConnectionsPerHost = Self.streamLimit
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.timeoutIntervalForResource = 30
            self.session = URLSession(configuration: configuration, delegate: ImageResourceRedirectGuard(allowedURL: allowedURL), delegateQueue: nil)
        }
        self.allowedURL = allowedURL
        self.snapshot = snapshot; self.binding = binding; self.bind = bind; self.collect = collect
    }

    deinit { session.invalidateAndCancel() }

    func resolve(url: URL, owner: ImageResourceOwner?, maxBytes: Int64, timeout: TimeInterval) async throws -> Result {
        guard allowedURL(url), maxBytes > 0, maxBytes <= 10 * 1024 * 1024 else { throw URLError(.unsupportedURL) }
        // Keep admission until canonical publication completes as well; a slow
        // database cannot accumulate an unbounded queue of downloaded bodies.
        guard activeConsumers < Self.consumerLimit else { throw URLError(.resourceUnavailable) }
        activeConsumers += 1
        let consumerPermit = ImageResourceConsumerLease { [weak self] in await self?.releaseConsumer() }
        let originalURL = Self.identity(url)
        let ownerSnapshot = try await owner.mapAsync(snapshot)
        if owner != nil && ownerSnapshot == nil { throw URLError(.cancelled) }
        let scope = ownerSnapshot?.scope ?? "public-unowned"
        let key = imageContentHash(Data((scope + "\u{0}" + originalURL).utf8))
        let bindingKey = imageContentHash(Data(originalURL.utf8))
        if let ownerSnapshot, let hash = try await binding(ownerSnapshot, bindingKey) {
            // A missing/corrupt historical version is unavailable, not licence
            // to substitute whatever the URL happens to serve today.
            let lease = try ImageResourceFileLease.acquire(directory: directory, hash: hash)
            guard let data = try readObject(hash, limit: maxBytes) else { throw URLError(.cannotOpenFile) }
            return Result(data: data, fileURL: objectURL(hash), isStale: false, isPersistent: true, fileLease: lease, consumerLease: consumerPermit)
        }
        let flightKey = key + ":" + String(maxBytes) + ":" + String(timeout)
        guard flights.values.reduce(0, { $0 + $1.users.count }) < Self.consumerLimit else { throw URLError(.resourceUnavailable) }
        let subscriber = UUID()
        let consumer = ownerSnapshot.map { $0.canonicalID + ":" + $0.stamp } ?? ("unowned:" + subscriber.uuidString)
        let task: Task<Result, Error>
        let initiator: String
        if var flight = flights[flightKey] {
            guard flight.users.count < Self.consumerLimit else { throw URLError(.resourceUnavailable) }
            flight.users.insert(subscriber); flights[flightKey] = flight; task = flight.task; initiator = flight.initiator
        } else {
            guard flights.count < Self.flightLimit else { throw URLError(.resourceUnavailable) }
            task = Task { try await self.download(url: url, key: key, maxBytes: maxBytes, timeout: timeout) }
            initiator = consumer
            flights[flightKey] = Flight(task: task, initiator: initiator, users: [subscriber])
        }
        var downloaded: Result
        do {
            downloaded = try await withTaskCancellationHandler {
                let result = try await task.value
                try Task.checkCancellation()
                return result
            } onCancel: { Task { await self.release(flightKey, subscriber: subscriber) } }
        } catch { release(flightKey, subscriber: subscriber); throw error }
        release(flightKey, subscriber: subscriber)
        if !downloaded.isPersistent && initiator != consumer {
            // no-store may serve the initiating message's current subscribers,
            // but must not satisfy a distinct message's request from that body.
            downloaded = try await download(url: url, key: key, maxBytes: maxBytes, timeout: timeout)
        }
        guard let ownerSnapshot else { return downloaded.retaining(consumerPermit) }
        // Stale-on-error is display-only, never a new final business binding.
        if downloaded.isPersistent, !downloaded.isStale {
            let hash = imageContentHash(downloaded.data)
            guard try await bind(ownerSnapshot, bindingKey, hash) else { throw URLError(.cancelled) }
        } else {
            guard try await snapshot(ownerSnapshot.owner) == ownerSnapshot else { throw URLError(.cancelled) }
        }
        return downloaded.retaining(consumerPermit)
    }

    private func releaseConsumer() { activeConsumers = max(0, activeConsumers - 1) }

#if DEBUG
    func activeConsumerCountForTesting() -> Int { activeConsumers }
#endif

    private func release(_ key: String, subscriber: UUID) {
        guard var flight = flights[key] else { return }
        flight.users.remove(subscriber)
        if flight.users.isEmpty { flights[key] = nil; flight.task.cancel() }
        else { flights[key] = flight }
    }

    private func takeSlot() async throws {
        if activeDownloads < Self.streamLimit { activeDownloads += 1; return }
        guard slots.count < Self.flightLimit - Self.streamLimit else { throw URLError(.resourceUnavailable) }
        try Task.checkCancellation()
        try await withCheckedThrowingContinuation { slots.append($0) }
        if Task.isCancelled { releaseSlot(); throw CancellationError() }
    }
    private func releaseSlot() {
        if slots.isEmpty { activeDownloads -= 1 }
        else { slots.removeFirst().resume() }
    }

    private func download(url: URL, key: String, maxBytes: Int64, timeout: TimeInterval) async throws -> Result {
        try await takeSlot()
        defer { releaseSlot() }
        let old = try readEntry(key)
        var oldLease = try old.map { try ImageResourceFileLease.acquire(directory: directory, hash: $0.contentHash) }
        let oldData = try old.flatMap { try readObject($0.contentHash, limit: maxBytes) }
        if let old, old.matches(requestHeaders), old.isFresh(at: Date()), let oldData {
            return Result(data: oldData, fileURL: objectURL(old.contentHash), isStale: false, isPersistent: true, fileLease: oldLease)
        }
        // The old bytes are already read. Do not retain a filesystem lease
        // across a network validation; 304 reacquires and verifies the file.
        oldLease = nil
        do {
            return try await request(url: url, key: key, old: old, oldData: oldData, maxBytes: maxBytes, timeout: timeout)
        } catch {
            if let old, old.matches(requestHeaders), old.permitsStale, let oldData,
               !(error is CancellationError), (error as? URLError)?.code != .cancelled {
                if let lease = try? ImageResourceFileLease.acquire(directory: directory, hash: old.contentHash),
                   (try? readObject(old.contentHash, limit: maxBytes)) != nil {
                    return Result(data: oldData, fileURL: objectURL(old.contentHash), isStale: true, isPersistent: true, fileLease: lease)
                }
                return Result(data: oldData, fileURL: nil, isStale: true, isPersistent: false)
            }
            throw error
        }
    }

    private func request(url: URL, key: String, old: ImageHTTPEntry?, oldData: Data?, maxBytes: Int64, timeout: TimeInterval) async throws -> Result {
        var request = URLRequest(url: url)
        request.timeoutInterval = min(30, max(1, timeout))
        request.cachePolicy = .reloadIgnoringLocalCacheData
        for (key, value) in requestHeaders { request.setValue(value, forHTTPHeaderField: key) }
        if let old, old.matches(requestHeaders), oldData != nil {
            if let etag = old.headers["etag"] { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
            else if let modified = old.headers["last-modified"] { request.setValue(modified, forHTTPHeaderField: "If-Modified-Since") }
        }
        let started = Date()
        let (stream, response) = try await session.bytes(for: request)
        let received = Date()
        defer { stream.task.cancel() }
        guard let http = response as? HTTPURLResponse, allowedURL(http.url ?? url) else { throw URLError(.badServerResponse) }
        let encoding = http.value(forHTTPHeaderField: "Content-Encoding")?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard encoding == nil || encoding == "identity" else { throw URLError(.cannotDecodeContentData) }
        if http.statusCode == 304 {
            guard let finalURL = http.url, Self.identity(finalURL) == Self.identity(url) else { throw URLError(.badServerResponse) }
            let revalidatedLease = try old.map { try ImageResourceFileLease.acquire(directory: directory, hash: $0.contentHash) }
            let revalidatedData = try old.flatMap { try readObject($0.contentHash, limit: maxBytes) }
            guard let old, let revalidatedData, old.matches(requestHeaders), revalidatedLease != nil else {
                // A server returning 304 to an unconditional GET is invalid;
                // permit at most one recovery request, never recurse forever.
                guard old != nil else { throw URLError(.badServerResponse) }
                return try await self.request(url: url, key: key, old: nil, oldData: nil, maxBytes: maxBytes, timeout: timeout)
            }
            if let refreshed = ImageHTTPEntry.make(hash: old.contentHash, response: http, request: requestHeaders,
                                                  started: started, received: received, previous: old) {
                try writeEntry(refreshed, key: key)
                return Result(data: revalidatedData, fileURL: objectURL(old.contentHash), isStale: false, isPersistent: true, fileLease: revalidatedLease)
            }
            try removeEntry(key)
            return Result(data: revalidatedData, fileURL: nil, isStale: false, isPersistent: false)
        }
        guard http.statusCode == 200 else { throw URLError(.badServerResponse) }
        if response.expectedContentLength > maxBytes { throw URLError(.dataLengthExceedsMaximum) }
        var data = Data()
        data.reserveCapacity(Int(min(maxBytes, max(0, response.expectedContentLength))))
        for try await byte in stream {
            try Task.checkCancellation()
            guard data.count < maxBytes else { throw URLError(.dataLengthExceedsMaximum) }
            data.append(byte)
        }
        guard SharedImageCache.validImageData(data) else { throw URLError(.cannotDecodeContentData) }
        let hash = imageContentHash(data)
        guard let entry = ImageHTTPEntry.make(hash: hash, response: http, request: requestHeaders,
                                             started: started, received: received) else {
            try removeEntry(key)
            return Result(data: data, fileURL: nil, isStale: false, isPersistent: false)
        }
        // Atomic file publication precedes the short canonical binding transaction.
        // An interruption can leave an orphan, never a reference to a partial file.
        let lease = try ImageResourceFileLease.acquire(directory: directory, hash: hash)
        let file = objectURL(hash)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if (try? readObject(hash, limit: maxBytes)) == nil { try data.write(to: file, options: .atomic) }
        // A final response's freshness does not prove that the redirect itself
        // remains fresh. Without a redirect-cache model, archive this owner's
        // actual bytes but do not generally reuse the alias for another owner.
        if !entry.vary.contains("*"), let finalURL = http.url, Self.identity(finalURL) == Self.identity(url) {
            try writeEntry(entry, key: key)
        } else { try removeEntry(key) }
        return Result(data: data, fileURL: file, isStale: false, isPersistent: true, fileLease: lease)
    }

    func objectURL(_ hash: String) -> URL { directory.appendingPathComponent("Originals", isDirectory: true).appendingPathComponent(hash + ".img") }
    private func readObject(_ hash: String, limit: Int64) throws -> Data? {
        guard hash.count == 64, hash.allSatisfy({ $0.isHexDigit }) else { return nil }
        let url = objectURL(hash)
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else { return nil }
        guard size <= limit else { throw URLError(.dataLengthExceedsMaximum) }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count <= limit, imageContentHash(data) == hash, SharedImageCache.validImageData(data) else { return nil }
        return data
    }

    /// Only the Originals namespace is swept. Metadata DB/WAL/SHM and legacy
    /// files are never inferred to be images or removed by this collector.
    func collectOrphans(limit: Int = 64, collectOverride: Collect? = nil) async -> Int {
        let objects = directory.appendingPathComponent("Originals", isDirectory: true)
        if orphanEnumerator == nil {
            orphanEnumerator = FileManager.default.enumerator(at: objects, includingPropertiesForKeys: [.contentModificationDateKey])
        }
        guard let enumerator = orphanEnumerator else { return 0 }
        var visited = 0, removed = 0
        while visited < min(64, max(0, limit)) {
            guard let file = enumerator.nextObject() as? URL else { orphanEnumerator = nil; break }
            visited += 1
            let hash = file.deletingPathExtension().lastPathComponent
            guard hash.count == 64, hash.allSatisfy({ $0.isHexDigit }), file.pathExtension == "img" else { continue }
            // The shard lease precedes the canonical writer in both paths.
            // Busy means an active publisher/reader: skip, never block it.
            guard let lease = try? ImageResourceFileLease.acquire(directory: directory, hash: hash, exclusive: true) else { continue }
            defer { withExtendedLifetime(lease) {} }
            if (try? await (collectOverride ?? collect)(hash, { try? FileManager.default.removeItem(at: file) })) == true,
               !FileManager.default.fileExists(atPath: file.path) {
                removed += 1
                try? removeEntries(contentHash: hash)
            }
        }
        return removed
    }

    private func openIndex() throws -> OpaquePointer {
        if let index { return index.pointer }
        let metadata = directory.appendingPathComponent("Metadata", isDirectory: true)
        try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: true)
        var opened: OpaquePointer?
        guard sqlite3_open_v2(metadata.appendingPathComponent("http.sqlite").path, &opened,
                              SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let db = opened else { sqlite3_close(opened); throw URLError(.cannotCreateFile) }
        sqlite3_busy_timeout(db, 5000)
        guard sqlite3_exec(db, "PRAGMA journal_mode=WAL; CREATE TABLE IF NOT EXISTS responses(key TEXT PRIMARY KEY, entry BLOB NOT NULL, content_hash TEXT NOT NULL); CREATE INDEX IF NOT EXISTS responses_content ON responses(content_hash);", nil, nil, nil) == SQLITE_OK else {
            sqlite3_close(db); throw URLError(.cannotWriteToFile)
        }
        index = ImageResourceIndexConnection(db); return db
    }
    private func readEntry(_ key: String) throws -> ImageHTTPEntry? {
        let db = try openIndex(); var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT entry FROM responses WHERE key=?", -1, &statement, nil) == SQLITE_OK else { throw URLError(.cannotOpenFile) }
        defer { sqlite3_finalize(statement) }; bindIndexText(statement, 1, key)
        guard sqlite3_step(statement) == SQLITE_ROW, let bytes = sqlite3_column_blob(statement, 0) else { return nil }
        return try JSONDecoder().decode(ImageHTTPEntry.self, from: Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0))))
    }
    private func writeEntry(_ entry: ImageHTTPEntry, key: String) throws {
        let db = try openIndex(); var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "INSERT INTO responses(key,entry,content_hash)VALUES(?,?,?)ON CONFLICT(key)DO UPDATE SET entry=excluded.entry,content_hash=excluded.content_hash", -1, &statement, nil) == SQLITE_OK else { throw URLError(.cannotWriteToFile) }
        defer { sqlite3_finalize(statement) }; bindIndexText(statement, 1, key)
        bindIndexText(statement, 3, entry.contentHash)
        let data = try JSONEncoder().encode(entry)
        _ = data.withUnsafeBytes { sqlite3_bind_blob(statement, 2, $0.baseAddress, Int32(data.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw URLError(.cannotWriteToFile) }
    }
    private func removeEntries(contentHash: String) throws {
        let db = try openIndex(); var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "DELETE FROM responses WHERE content_hash=?", -1, &statement, nil) == SQLITE_OK else { throw URLError(.cannotWriteToFile) }
        defer { sqlite3_finalize(statement) }; bindIndexText(statement, 1, contentHash)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw URLError(.cannotWriteToFile) }
    }
    private func removeEntry(_ key: String) throws {
        let db = try openIndex(); var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "DELETE FROM responses WHERE key=?", -1, &statement, nil) == SQLITE_OK else { throw URLError(.cannotWriteToFile) }
        defer { sqlite3_finalize(statement) }; bindIndexText(statement, 1, key)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw URLError(.cannotWriteToFile) }
    }
    private func bindIndexText(_ statement: OpaquePointer?, _ position: Int32, _ text: String) {
        _ = text.withCString { sqlite3_bind_text(statement, position, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
    }
    static func identity(_ url: URL) -> String {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.fragment = nil
        return components?.url?.absoluteString ?? url.absoluteString
    }
}

private extension Optional where Wrapped == ImageResourceOwner {
    func mapAsync(_ body: @Sendable (Wrapped) async throws -> ImageResourceOwnerSnapshot?) async throws -> ImageResourceOwnerSnapshot? {
        guard let value = self else { return nil }; return try await body(value)
    }
}

private final class ImageResourceRedirectGuard: NSObject, URLSessionTaskDelegate, Sendable {
    private let allowedURL: @Sendable (URL) -> Bool
    init(allowedURL: @escaping @Sendable (URL) -> Bool) { self.allowedURL = allowedURL }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        guard let url = request.url, allowedURL(url) else { completionHandler(nil); return }
        var safe = request
        safe.setValue(nil, forHTTPHeaderField: "Authorization")
        safe.setValue(nil, forHTTPHeaderField: "Cookie")
        // Validators identify a selected representation of one URI, not an
        // arbitrary redirect destination with a coincidentally equal ETag.
        safe.setValue(nil, forHTTPHeaderField: "If-None-Match")
        safe.setValue(nil, forHTTPHeaderField: "If-Modified-Since")
        completionHandler(safe)
    }
}
