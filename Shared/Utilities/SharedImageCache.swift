import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers
#if canImport(SQLite3)
import SQLite3
#endif

enum SharedImageCache {
    enum Rendition: String, CaseIterable, Sendable {
        case original
        case listThumbnail

        var keySuffix: String {
            switch self {
            case .original:
                return "orig"
            case .listThumbnail:
                return "thumb_list"
            }
        }

        var preferredExtension: String {
            switch self {
            case .original:
                return ""
            case .listThumbnail:
                return "img"
            }
        }
    }

    private struct CacheProfile {
        let memoryLimitBytes: Int
        let diskLimitBytes: Int64
        let memoryEnabled: Bool
    }

    private final class MetadataBox: NSObject {
        let value: ImageAssetMetadata

        init(_ value: ImageAssetMetadata) {
            self.value = value
        }
    }

    private final class MetadataSnapshotCache: @unchecked Sendable {
        private let cache = NSCache<NSURL, MetadataBox>()

        func metadata(for key: NSURL) -> ImageAssetMetadata? {
            cache.object(forKey: key)?.value
        }

        func set(_ metadata: ImageAssetMetadata, for key: NSURL) {
            cache.setObject(MetadataBox(metadata), forKey: key)
        }

        func remove(for key: NSURL) {
            cache.removeObject(forKey: key)
        }

        func removeAll() {
            cache.removeAllObjects()
        }
    }

    #if canImport(SQLite3)
    private final class MetadataSnapshotStoreReader: @unchecked Sendable {
        private let lock = NSLock()
        private var database: OpaquePointer?

        func metadata(for url: URL) -> ImageAssetMetadata? {
            let normalized = normalizedImageMetadataURLString(url.absoluteString)
            lock.lock()
            defer { lock.unlock() }
            guard let db = openDatabaseIfNeeded() else { return nil }
            let sql = """
            SELECT url, pixel_width, pixel_height, aspect_ratio, mime_type, is_animated, frame_count,
                   single_loop_duration, byte_size, etag, last_modified, updated_at
            FROM image_asset_metadata
            WHERE url_hash = ?
            LIMIT 1;
            """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                sqlite3_finalize(statement)
                return nil
            }
            defer { sqlite3_finalize(statement) }
            bindText(statement, index: 1, value: imageMetadataURLHash(normalized))
            guard sqlite3_step(statement) == SQLITE_ROW else {
                return nil
            }
            let resolvedURL = String(cString: sqlite3_column_text(statement, 0))
            let width = Int(sqlite3_column_int(statement, 1))
            let height = Int(sqlite3_column_int(statement, 2))
            let ratio = sqlite3_column_double(statement, 3)
            let mimeType = sqliteString(statement, index: 4)
            let isAnimated = sqlite3_column_int(statement, 5) != 0
            let frameCount = sqliteOptionalInt(statement, index: 6)
            let loopDuration = sqliteOptionalDouble(statement, index: 7)
            let byteSize = sqliteOptionalInt64(statement, index: 8)
            let etag = sqliteString(statement, index: 9)
            let lastModified = sqliteString(statement, index: 10)
            let updatedAt = sqlite3_column_int64(statement, 11)
            return ImageAssetMetadata(
                url: resolvedURL,
                pixelWidth: width,
                pixelHeight: height,
                aspectRatio: ratio,
                mimeType: mimeType,
                isAnimated: isAnimated,
                frameCount: frameCount,
                singleLoopDuration: loopDuration,
                byteSize: byteSize,
                etag: etag,
                lastModified: lastModified,
                updatedAtEpochMillis: updatedAt
            )
        }

        private func openDatabaseIfNeeded() -> OpaquePointer? {
            if let database {
                return database
            }
            guard
                let directory = AppConstants.appGroupContainerURL()?
                    .appendingPathComponent("Cache/Images", isDirectory: true)
            else {
                return nil
            }
            let path = directory.appendingPathComponent("image_asset_metadata.sqlite").path
            var db: OpaquePointer?
            guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
                  let opened = db
            else {
                sqlite3_close(db)
                return nil
            }
            _ = sqlite3_exec(opened, "PRAGMA busy_timeout=5000;", nil, nil, nil)
            database = opened
            return opened
        }
    }
    #endif

    private actor MemoryCache {
        private let cache: NSCache<NSURL, NSData>

        init(limitBytes: Int) {
            let cache = NSCache<NSURL, NSData>()
            cache.totalCostLimit = limitBytes
            self.cache = cache
        }

        func data(for key: NSURL) -> Data? {
            cache.object(forKey: key) as Data?
        }

        func set(_ data: Data, for key: NSURL) {
            cache.setObject(data as NSData, forKey: key, cost: data.count)
        }

        func remove(for key: NSURL) {
            cache.removeObject(forKey: key)
        }

        func removeAll() {
            cache.removeAllObjects()
        }
    }

    private actor DiskCache {
        private let fileManager: FileManager
        private let diskLimitBytes: Int64

        init(fileManager: FileManager = .default, diskLimitBytes: Int64) {
            self.fileManager = fileManager
            self.diskLimitBytes = diskLimitBytes
        }

        func readData(for url: URL, rendition: Rendition) -> Data? {
            guard let fileURL = SharedImageCache.fileURL(for: url, rendition: rendition) else { return nil }
            var isDir: ObjCBool = false
            guard fileManager.fileExists(atPath: fileURL.path, isDirectory: &isDir), !isDir.boolValue else {
                return nil
            }
            guard let data = try? Data(contentsOf: fileURL) else { return nil }
            try? fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: fileURL.path)
            return data
        }

        @discardableResult
        func store(data: Data, for url: URL, rendition: Rendition) -> URL? {
            guard let destination = SharedImageCache.fileURL(for: url, rendition: rendition) else { return nil }
            do {
                let directory = destination.deletingLastPathComponent()
                if !fileManager.fileExists(atPath: directory.path) {
                    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
                }
                try data.write(to: destination, options: [.atomic])
                try fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: destination.path)
                enforceDiskLimitIfNeeded()
                return destination
            } catch {
                return nil
            }
        }

        func purge(urls: [URL], renditions: [Rendition]) {
            for url in urls {
                for rendition in renditions {
                    guard let fileURL = SharedImageCache.cachedFileURL(for: url, rendition: rendition) else { continue }
                    try? fileManager.removeItem(at: fileURL)
                }
            }
        }

        func purgeAll() {
            guard let directory = SharedImageCache.cacheDirectory() else { return }
            try? fileManager.removeItem(at: directory)
        }

        private func enforceDiskLimitIfNeeded() {
            guard let directory = SharedImageCache.cacheDirectory() else { return }
            guard let enumerator = fileManager.enumerator(
                at: directory,
                includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles],
                errorHandler: nil
            ) else { return }

            var files: [(url: URL, size: Int64, modDate: Date)] = []
            var total: Int64 = 0

            for case let fileURL as URL in enumerator {
                let resource = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                let size = Int64(resource?.fileSize ?? 0)
                let date = resource?.contentModificationDate ?? Date.distantPast
                total += size
                files.append((fileURL, size, date))
            }

            guard total > diskLimitBytes else { return }
            let sorted = files.sorted { $0.modDate < $1.modDate }
            var remaining = total
            for item in sorted {
                if remaining <= diskLimitBytes { break }
                try? fileManager.removeItem(at: item.url)
                remaining -= item.size
            }
        }
    }

    private actor InflightRequests {
        private var tasks: [NSURL: Task<Data, Error>] = [:]

        func task(for key: NSURL, create: @escaping () -> Task<Data, Error>) -> Task<Data, Error> {
            if let existing = tasks[key] {
                return existing
            }
            let task = create()
            tasks[key] = task
            return task
        }

        func remove(_ key: NSURL) {
            tasks[key] = nil
        }
    }

    private static let profile: CacheProfile = {
        let defaultProfile = CacheProfile(
            memoryLimitBytes: 20 * 1024 * 1024,
            diskLimitBytes: 50 * 1024 * 1024,
            memoryEnabled: true
        )
        guard let bundleId = Bundle.main.bundleIdentifier else { return defaultProfile }
        if bundleId.hasSuffix(".NotificationServiceExtension") {
            return CacheProfile(
                memoryLimitBytes: 0,
                diskLimitBytes: 50 * 1024 * 1024,
                memoryEnabled: false
            )
        }
#if os(watchOS)
        return CacheProfile(
            memoryLimitBytes: 16 * 1024 * 1024,
            diskLimitBytes: 200 * 1024 * 1024,
            memoryEnabled: true
        )
#else
        return CacheProfile(
            memoryLimitBytes: 240 * 1024 * 1024,
            diskLimitBytes: 10 * 1024 * 1024 * 1024,
            memoryEnabled: true
        )
#endif
    }()

    static var isMemoryCacheEnabled: Bool {
        profile.memoryEnabled
    }

    private static let memory = MemoryCache(limitBytes: profile.memoryLimitBytes)
    private static let disk = DiskCache(diskLimitBytes: profile.diskLimitBytes)
    private static let inflight = InflightRequests()
    private static let metadataStore = ImageAssetMetadataStore.shared
    private static let metadataSnapshots = MetadataSnapshotCache()
    #if canImport(SQLite3)
    private static let metadataSnapshotStoreReader = MetadataSnapshotStoreReader()
    #endif

    static func cachedData(for url: URL, rendition: Rendition = .original) async -> Data? {
        guard URLSanitizer.isAllowedRemoteURL(url) else { return nil }
        let cacheKey = cacheKeyURL(for: url, rendition: rendition)
        if profile.memoryEnabled, let data = await memory.data(for: cacheKey) {
            return data
        }
        guard let data = await disk.readData(for: url, rendition: rendition) else { return nil }
        if profile.memoryEnabled {
            await memory.set(data, for: cacheKey)
        }
        return data
    }

    static func cachedFileURL(for url: URL, rendition: Rendition = .original) -> URL? {
        guard let target = fileURL(for: url, rendition: rendition) else { return nil }
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: target.path, isDirectory: &isDir), !isDir.boolValue {
            return target
        }
        return nil
    }

    static func fetchData(
        from url: URL,
        rendition: Rendition = .original,
        maxBytes: Int64? = nil,
        timeout: TimeInterval = 10
    ) async throws -> Data {
        guard URLSanitizer.isAllowedRemoteURL(url) else { throw URLError(.unsupportedURL) }
        if let cached = await cachedData(for: url, rendition: rendition) {
            if let maxBytes, cached.count > maxBytes { throw URLError(.dataLengthExceedsMaximum) }
            return cached
        }

        let cacheKey = cacheKeyURL(for: url, rendition: rendition)
        let task = await inflight.task(for: cacheKey) {
            Task {
                defer { Task { await inflight.remove(cacheKey) } }
                if let cached = await cachedData(for: url, rendition: rendition) {
                    if let maxBytes, cached.count > maxBytes { throw URLError(.dataLengthExceedsMaximum) }
                    return cached
                }

                switch rendition {
                case .original:
                    var request = URLRequest(url: url)
                    request.timeoutInterval = timeout
                    let (data, response) = try await URLSession.shared.data(for: request)
                    if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
                        throw URLError(.badServerResponse)
                    }
                    if let maxBytes, data.count > maxBytes {
                        throw URLError(.dataLengthExceedsMaximum)
                    }
                    if let metadata = Self.extractMetadata(from: data, url: url, response: response) {
                        await metadataStore.upsert(metadata)
                        cacheMetadataSnapshot(metadata)
                    }
                    await store(data: data, for: url, rendition: .original)
                    return data
                case .listThumbnail:
                    let originalData = try await fetchData(
                        from: url,
                        rendition: .original,
                        maxBytes: maxBytes,
                        timeout: timeout
                    )
                    let thumbnailData = Self.makeListThumbnailData(from: originalData) ?? originalData
                    await store(data: thumbnailData, for: url, rendition: .listThumbnail)
                    return thumbnailData
                }
            }
        }
        return try await task.value
    }

    @discardableResult
    static func store(data: Data, for url: URL, rendition: Rendition = .original) async -> URL? {
        let cacheKey = cacheKeyURL(for: url, rendition: rendition)
        if profile.memoryEnabled {
            await memory.set(data, for: cacheKey)
        }
        return await disk.store(data: data, for: url, rendition: rendition)
    }

    static func purge(urls: [URL]) async {
        let renditions = Rendition.allCases
        for url in urls {
            metadataSnapshots.remove(for: metadataCacheKeyURL(for: url))
            for rendition in renditions {
                let cacheKey = cacheKeyURL(for: url, rendition: rendition)
                if profile.memoryEnabled {
                    await memory.remove(for: cacheKey)
                }
            }
        }
        await metadataStore.purge(urls: urls)
        await disk.purge(urls: urls, renditions: renditions)
    }

    static func purgeAll() async {
        if profile.memoryEnabled {
            await memory.removeAll()
        }
        metadataSnapshots.removeAll()
        await metadataStore.purgeAll()
        await disk.purgeAll()
    }

    static func metadata(for url: URL) async -> ImageAssetMetadata? {
        if let cached = metadataSnapshot(for: url) {
            return cached
        }
        let metadata = await metadataStore.metadata(for: url)
        if let metadata {
            cacheMetadataSnapshot(metadata)
        }
        return metadata
    }

    static func metadataSnapshot(for url: URL) -> ImageAssetMetadata? {
        let key = metadataCacheKeyURL(for: url)
        if let cached = metadataSnapshots.metadata(for: key) {
            return cached
        }
        #if canImport(SQLite3)
        if let persisted = metadataSnapshotStoreReader.metadata(for: url) {
            metadataSnapshots.set(persisted, for: key)
            return persisted
        }
        #endif
        if let fileURL = cachedFileURL(for: url, rendition: .original),
           let metadata = extractMetadata(fromFileAt: fileURL, originalURL: url)
        {
            metadataSnapshots.set(metadata, for: key)
            Task {
                await metadataStore.upsert(metadata)
            }
            return metadata
        }
        return nil
    }

    static func ensureMetadataFromCache(
        for url: URL,
        rendition: Rendition = .original
    ) async -> ImageAssetMetadata? {
        if let existing = await metadataStore.metadata(for: url) {
            cacheMetadataSnapshot(existing)
            return existing
        }
        guard let data = await cachedData(for: url, rendition: rendition) else {
            return nil
        }
        guard let metadata = extractMetadata(from: data, url: url, response: nil) else {
            return nil
        }
        await metadataStore.upsert(metadata)
        cacheMetadataSnapshot(metadata)
        return metadata
    }

    static func ensureMetadata(
        for url: URL,
        maxBytes: Int64? = nil,
        timeout: TimeInterval = 10
    ) async -> ImageAssetMetadata? {
        if let cached = await ensureMetadataFromCache(for: url, rendition: .original) {
            return cached
        }
        do {
            _ = try await fetchData(
                from: url,
                rendition: .original,
                maxBytes: maxBytes,
                timeout: timeout
            )
        } catch {
            if let existing = await metadataStore.metadata(for: url) {
                cacheMetadataSnapshot(existing)
                return existing
            }
            return nil
        }
        return await metadataStore.metadata(for: url)
    }

    static func preheatMetadata(
        for urls: [URL],
        maxBytes: Int64? = nil,
        timeout: TimeInterval = 10
    ) async {
        let uniqueURLs = Array(NSOrderedSet(array: urls.compactMap { candidate in
            URLSanitizer.resolveHTTPSURL(from: candidate.absoluteString)
        })) as? [URL] ?? []
        guard !uniqueURLs.isEmpty else { return }
        await withTaskGroup(of: Void.self) { group in
            for url in uniqueURLs {
                group.addTask {
                    _ = await ensureMetadata(
                        for: url,
                        maxBytes: maxBytes,
                        timeout: timeout
                    )
                }
            }
        }
    }

    static func primeMetadataSnapshots(
        for urls: [URL],
        rendition: Rendition = .original
    ) async {
        let uniqueURLs = Array(NSOrderedSet(array: urls.compactMap { candidate in
            URLSanitizer.resolveHTTPSURL(from: candidate.absoluteString)
        })) as? [URL] ?? []
        guard !uniqueURLs.isEmpty else { return }
        await withTaskGroup(of: Void.self) { group in
            for url in uniqueURLs {
                group.addTask {
                    _ = await ensureMetadataFromCache(for: url, rendition: rendition)
                }
            }
        }
    }

    static func sourceURL(
        for url: URL,
        rendition: Rendition = .original,
        maxBytes: Int64? = nil,
        timeout: TimeInterval = 10
    ) async -> URL {
        await localSourceURL(
            for: url,
            rendition: rendition,
            maxBytes: maxBytes,
            timeout: timeout
        ) ?? url
    }

    static func localSourceURL(
        for url: URL,
        rendition: Rendition = .original,
        maxBytes: Int64? = nil,
        timeout: TimeInterval = 10
    ) async -> URL? {
        if url.isFileURL {
            return url
        }
        guard URLSanitizer.isAllowedRemoteURL(url) else { return nil }
        if let cached = cachedFileURL(for: url, rendition: rendition) {
            return cached
        }
        do {
            _ = try await fetchData(
                from: url,
                rendition: rendition,
                maxBytes: maxBytes,
                timeout: timeout
            )
            return cachedFileURL(for: url, rendition: rendition)
        } catch {
            return nil
        }
    }

    static func cacheKeyURL(for url: URL, rendition: Rendition = .original) -> NSURL {
        let key = normalizedCacheKey(for: url, rendition: rendition)
        return (URL(string: key) ?? url) as NSURL
    }

    private static func metadataCacheKeyURL(for url: URL) -> NSURL {
        cacheKeyURL(for: url, rendition: .original)
    }

    private static func cacheMetadataSnapshot(_ metadata: ImageAssetMetadata) {
        guard let url = URL(string: metadata.url) else { return }
        metadataSnapshots.set(metadata, for: metadataCacheKeyURL(for: url))
    }

    private static func fileURL(for url: URL, rendition: Rendition) -> URL? {
        guard let base = AppConstants.appGroupContainerURL() else { return nil }
        let directory = base.appendingPathComponent("Cache/Images", isDirectory: true)
        let ext: String
        if rendition.preferredExtension.isEmpty {
            ext = url.pathExtension.isEmpty ? "img" : url.pathExtension
        } else {
            ext = rendition.preferredExtension
        }
        let name = sha256(normalizedCacheKey(for: url, rendition: rendition))
        return directory.appendingPathComponent("\(name).\(ext)")
    }

    private static func normalizedCacheKey(for url: URL, rendition: Rendition) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url.absoluteString
        }
        components.fragment = nil
        let base = components.url?.absoluteString ?? url.absoluteString
        return "\(base)#rendition=\(rendition.keySuffix)"
    }

    private static func sha256(_ text: String) -> String {
        let digest = SHA256.hash(data: Data(text.utf8))
        return digest.compactMap { String(format: "%02x", $0) }.joined()
    }

    private static func makeListThumbnailData(from originalData: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(originalData as CFData, nil) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 320,
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            options as CFDictionary
        ) else {
            return nil
        }

        let alphaInfo = thumbnail.alphaInfo
        let hasAlpha = alphaInfo == .premultipliedFirst
            || alphaInfo == .premultipliedLast
            || alphaInfo == .first
            || alphaInfo == .last
        let utType = hasAlpha ? UTType.png : UTType.jpeg

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output as CFMutableData,
            utType.identifier as CFString,
            1,
            nil
        ) else {
            return nil
        }
        if hasAlpha {
            CGImageDestinationAddImage(destination, thumbnail, nil)
        } else {
            let props: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.82]
            CGImageDestinationAddImage(destination, thumbnail, props as CFDictionary)
        }
        guard CGImageDestinationFinalize(destination) else {
            return nil
        }
        return output as Data
    }

    private static func extractMetadata(
        from data: Data,
        url: URL,
        response: URLResponse?
    ) -> ImageAssetMetadata? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return nil
        }
        guard
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let widthNumber = properties[kCGImagePropertyPixelWidth] as? NSNumber,
            let heightNumber = properties[kCGImagePropertyPixelHeight] as? NSNumber
        else {
            return nil
        }

        let width = Int(truncating: widthNumber)
        let height = Int(truncating: heightNumber)
        guard width > 0, height > 0 else { return nil }

        let frameCount = CGImageSourceGetCount(source)
        var singleLoopDuration: TimeInterval? = nil
        if frameCount > 1 {
            var totalDuration: TimeInterval = 0
            for index in 0 ..< frameCount {
                guard let frameProps = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] else {
                    totalDuration += 0.1
                    continue
                }
                totalDuration += frameDelay(from: frameProps)
            }
            singleLoopDuration = max(totalDuration, 0.12)
        }

        let responseHeaders = (response as? HTTPURLResponse)?.allHeaderFields ?? [:]
        let etag = responseHeaders["ETag"] as? String
            ?? responseHeaders["Etag"] as? String
            ?? responseHeaders["etag"] as? String
        let lastModified = responseHeaders["Last-Modified"] as? String
            ?? responseHeaders["last-modified"] as? String

        let sourceType = CGImageSourceGetType(source) as String?
        let mimeType: String? = {
            if let sourceType,
               let utType = UTType(sourceType)
            {
                return utType.preferredMIMEType
            }
            return nil
        }()

        return ImageAssetMetadata(
            url: url.absoluteString,
            pixelWidth: width,
            pixelHeight: height,
            aspectRatio: Double(width) / Double(height),
            mimeType: mimeType,
            isAnimated: frameCount > 1,
            frameCount: frameCount > 1 ? frameCount : nil,
            singleLoopDuration: singleLoopDuration,
            byteSize: Int64(data.count),
            etag: etag?.trimmingCharacters(in: .whitespacesAndNewlines),
            lastModified: lastModified?.trimmingCharacters(in: .whitespacesAndNewlines),
            updatedAtEpochMillis: Int64(Date().timeIntervalSince1970 * 1000)
        )
    }

    private static func extractMetadata(fromFileAt fileURL: URL, originalURL: URL) -> ImageAssetMetadata? {
        guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil) else {
            return nil
        }
        guard
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let widthNumber = properties[kCGImagePropertyPixelWidth] as? NSNumber,
            let heightNumber = properties[kCGImagePropertyPixelHeight] as? NSNumber
        else {
            return nil
        }

        let width = Int(truncating: widthNumber)
        let height = Int(truncating: heightNumber)
        guard width > 0, height > 0 else { return nil }

        let frameCount = CGImageSourceGetCount(source)
        var singleLoopDuration: TimeInterval? = nil
        if frameCount > 1 {
            var totalDuration: TimeInterval = 0
            for index in 0 ..< frameCount {
                guard let frameProps = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] else {
                    totalDuration += 0.1
                    continue
                }
                totalDuration += frameDelay(from: frameProps)
            }
            singleLoopDuration = max(totalDuration, 0.12)
        }

        let mimeType: String? = {
            guard let sourceType = CGImageSourceGetType(source) as String?,
                  let utType = UTType(sourceType)
            else {
                return nil
            }
            return utType.preferredMIMEType
        }()

        let byteSize = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? NSNumber)?
            .int64Value

        return ImageAssetMetadata(
            url: originalURL.absoluteString,
            pixelWidth: width,
            pixelHeight: height,
            aspectRatio: Double(width) / Double(height),
            mimeType: mimeType,
            isAnimated: frameCount > 1,
            frameCount: frameCount > 1 ? frameCount : nil,
            singleLoopDuration: singleLoopDuration,
            byteSize: byteSize,
            etag: nil,
            lastModified: nil,
            updatedAtEpochMillis: Int64(Date().timeIntervalSince1970 * 1000)
        )
    }

    private static func frameDelay(from properties: [CFString: Any]) -> TimeInterval {
        let dictionaries: [[CFString: Any]] = [
            properties[kCGImagePropertyGIFDictionary] as? [CFString: Any],
            properties[kCGImagePropertyPNGDictionary] as? [CFString: Any],
            properties["WebP" as CFString] as? [CFString: Any],
            properties["{WebP}" as CFString] as? [CFString: Any],
        ].compactMap { $0 }

        for dictionary in dictionaries {
            if let unclamped = delayValue(from: dictionary, matching: "UnclampedDelayTime"), unclamped > 0 {
                return max(unclamped, 0.02)
            }
            if let delay = delayValue(from: dictionary, matching: "DelayTime"), delay > 0 {
                return max(delay, 0.02)
            }
        }
        return 0.1
    }

    private static func delayValue(
        from dictionary: [CFString: Any],
        matching keyword: String
    ) -> TimeInterval? {
        let lowered = keyword.lowercased()
        for (key, value) in dictionary {
            if (key as String).lowercased().contains(lowered),
               let number = value as? NSNumber
            {
                return number.doubleValue
            }
        }
        return nil
    }

    private static func cacheDirectory() -> URL? {
        AppConstants.appGroupContainerURL()?
            .appendingPathComponent("Cache/Images", isDirectory: true)
    }
}

struct ImageAssetMetadata: Sendable {
    let url: String
    let pixelWidth: Int
    let pixelHeight: Int
    let aspectRatio: Double
    let mimeType: String?
    let isAnimated: Bool
    let frameCount: Int?
    let singleLoopDuration: TimeInterval?
    let byteSize: Int64?
    let etag: String?
    let lastModified: String?
    let updatedAtEpochMillis: Int64
}

#if canImport(SQLite3)
actor ImageAssetMetadataStore {
    static let shared = ImageAssetMetadataStore()

    private var database: OpaquePointer?

    private init() {}

    func metadata(for url: URL) -> ImageAssetMetadata? {
        let normalized = normalizedImageMetadataURLString(url.absoluteString)
        guard let db = openDatabaseIfNeeded() else { return nil }
        let sql = """
        SELECT url, pixel_width, pixel_height, aspect_ratio, mime_type, is_animated, frame_count,
               single_loop_duration, byte_size, etag, last_modified, updated_at
        FROM image_asset_metadata
        WHERE url_hash = ?
        LIMIT 1;
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            sqlite3_finalize(statement)
            return nil
        }
        defer { sqlite3_finalize(statement) }
        bindText(statement, index: 1, value: imageMetadataURLHash(normalized))
        guard sqlite3_step(statement) == SQLITE_ROW else {
            return nil
        }
        let resolvedURL = String(cString: sqlite3_column_text(statement, 0))
        let width = Int(sqlite3_column_int(statement, 1))
        let height = Int(sqlite3_column_int(statement, 2))
        let ratio = sqlite3_column_double(statement, 3)
        let mimeType = sqliteString(statement, index: 4)
        let isAnimated = sqlite3_column_int(statement, 5) != 0
        let frameCount = sqliteOptionalInt(statement, index: 6)
        let loopDuration = sqliteOptionalDouble(statement, index: 7)
        let byteSize = sqliteOptionalInt64(statement, index: 8)
        let etag = sqliteString(statement, index: 9)
        let lastModified = sqliteString(statement, index: 10)
        let updatedAt = sqlite3_column_int64(statement, 11)
        return ImageAssetMetadata(
            url: resolvedURL,
            pixelWidth: width,
            pixelHeight: height,
            aspectRatio: ratio,
            mimeType: mimeType,
            isAnimated: isAnimated,
            frameCount: frameCount,
            singleLoopDuration: loopDuration,
            byteSize: byteSize,
            etag: etag,
            lastModified: lastModified,
            updatedAtEpochMillis: updatedAt
        )
    }

    func upsert(_ metadata: ImageAssetMetadata) {
        guard metadata.pixelWidth > 0, metadata.pixelHeight > 0, metadata.aspectRatio > 0 else {
            return
        }
        let normalized = normalizedImageMetadataURLString(metadata.url)
        guard let db = openDatabaseIfNeeded() else { return }
        let sql = """
        INSERT INTO image_asset_metadata (
            url_hash, url, pixel_width, pixel_height, aspect_ratio, mime_type,
            is_animated, frame_count, single_loop_duration, byte_size, etag, last_modified, updated_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(url_hash) DO UPDATE SET
            url = excluded.url,
            pixel_width = excluded.pixel_width,
            pixel_height = excluded.pixel_height,
            aspect_ratio = excluded.aspect_ratio,
            mime_type = excluded.mime_type,
            is_animated = excluded.is_animated,
            frame_count = excluded.frame_count,
            single_loop_duration = excluded.single_loop_duration,
            byte_size = excluded.byte_size,
            etag = excluded.etag,
            last_modified = excluded.last_modified,
            updated_at = excluded.updated_at;
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            sqlite3_finalize(statement)
            return
        }
        defer { sqlite3_finalize(statement) }

        bindText(statement, index: 1, value: imageMetadataURLHash(normalized))
        bindText(statement, index: 2, value: normalized)
        sqlite3_bind_int(statement, 3, Int32(metadata.pixelWidth))
        sqlite3_bind_int(statement, 4, Int32(metadata.pixelHeight))
        sqlite3_bind_double(statement, 5, metadata.aspectRatio)
        bindOptionalText(statement, index: 6, value: metadata.mimeType)
        sqlite3_bind_int(statement, 7, metadata.isAnimated ? 1 : 0)
        bindOptionalInt(statement, index: 8, value: metadata.frameCount)
        bindOptionalDouble(statement, index: 9, value: metadata.singleLoopDuration)
        bindOptionalInt64(statement, index: 10, value: metadata.byteSize)
        bindOptionalText(statement, index: 11, value: metadata.etag)
        bindOptionalText(statement, index: 12, value: metadata.lastModified)
        sqlite3_bind_int64(statement, 13, metadata.updatedAtEpochMillis)
        _ = sqlite3_step(statement)
    }

    func purge(urls: [URL]) {
        guard !urls.isEmpty else { return }
        let hashes = Set(urls.map { imageMetadataURLHash(normalizedImageMetadataURLString($0.absoluteString)) })
        guard let db = openDatabaseIfNeeded() else { return }
        for hash in hashes {
            let sql = "DELETE FROM image_asset_metadata WHERE url_hash = ?;"
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                sqlite3_finalize(statement)
                continue
            }
            bindText(statement, index: 1, value: hash)
            _ = sqlite3_step(statement)
            sqlite3_finalize(statement)
        }
    }

    func purgeAll() {
        guard let db = openDatabaseIfNeeded() else { return }
        _ = sqlite3_exec(db, "DELETE FROM image_asset_metadata;", nil, nil, nil)
    }

    private func openDatabaseIfNeeded() -> OpaquePointer? {
#if canImport(SQLite3)
        if let database {
            return database
        }
        guard
            let directory = AppConstants.appGroupContainerURL()?
                .appendingPathComponent("Cache/Images", isDirectory: true)
        else {
            return nil
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            return nil
        }
        let path = directory.appendingPathComponent("image_asset_metadata.sqlite").path
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, let opened = db else {
            sqlite3_close(db)
            return nil
        }
        _ = sqlite3_exec(opened, "PRAGMA journal_mode=WAL;", nil, nil, nil)
        _ = sqlite3_exec(opened, "PRAGMA synchronous=NORMAL;", nil, nil, nil)
        _ = sqlite3_exec(opened, "PRAGMA busy_timeout=5000;", nil, nil, nil)
        let createSQL = """
        CREATE TABLE IF NOT EXISTS image_asset_metadata (
            url_hash TEXT PRIMARY KEY NOT NULL,
            url TEXT NOT NULL,
            pixel_width INTEGER NOT NULL,
            pixel_height INTEGER NOT NULL,
            aspect_ratio REAL NOT NULL,
            mime_type TEXT,
            is_animated INTEGER NOT NULL,
            frame_count INTEGER,
            single_loop_duration REAL,
            byte_size INTEGER,
            etag TEXT,
            last_modified TEXT,
            updated_at INTEGER NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_image_asset_metadata_updated_at
        ON image_asset_metadata(updated_at DESC);
        """
        guard sqlite3_exec(opened, createSQL, nil, nil, nil) == SQLITE_OK else {
            sqlite3_close(opened)
            return nil
        }
        database = opened
        return opened
#else
        return nil
#endif
    }

}

private func normalizedImageMetadataURLString(_ raw: String) -> String {
    URLSanitizer.resolveHTTPSURL(from: raw)?.absoluteString ?? raw
}

private func imageMetadataURLHash(_ text: String) -> String {
    let digest = SHA256.hash(data: Data(text.utf8))
    return digest.compactMap { String(format: "%02x", $0) }.joined()
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

private func bindText(_ statement: OpaquePointer?, index: Int32, value: String) {
    _ = value.withCString { pointer in
        sqlite3_bind_text(statement, index, pointer, -1, SQLITE_TRANSIENT)
    }
}

private func bindOptionalText(_ statement: OpaquePointer?, index: Int32, value: String?) {
    if let value {
        bindText(statement, index: index, value: value)
    } else {
        sqlite3_bind_null(statement, index)
    }
}

private func bindOptionalInt(_ statement: OpaquePointer?, index: Int32, value: Int?) {
    if let value {
        sqlite3_bind_int(statement, index, Int32(value))
    } else {
        sqlite3_bind_null(statement, index)
    }
}

private func bindOptionalDouble(_ statement: OpaquePointer?, index: Int32, value: Double?) {
    if let value {
        sqlite3_bind_double(statement, index, value)
    } else {
        sqlite3_bind_null(statement, index)
    }
}

private func bindOptionalInt64(_ statement: OpaquePointer?, index: Int32, value: Int64?) {
    if let value {
        sqlite3_bind_int64(statement, index, value)
    } else {
        sqlite3_bind_null(statement, index)
    }
}

private func sqliteString(_ statement: OpaquePointer?, index: Int32) -> String? {
    guard let pointer = sqlite3_column_text(statement, index) else { return nil }
    return String(cString: pointer)
}

private func sqliteOptionalInt(_ statement: OpaquePointer?, index: Int32) -> Int? {
    if sqlite3_column_type(statement, index) == SQLITE_NULL {
        return nil
    }
    return Int(sqlite3_column_int(statement, index))
}

private func sqliteOptionalDouble(_ statement: OpaquePointer?, index: Int32) -> Double? {
    if sqlite3_column_type(statement, index) == SQLITE_NULL {
        return nil
    }
    return sqlite3_column_double(statement, index)
}

private func sqliteOptionalInt64(_ statement: OpaquePointer?, index: Int32) -> Int64? {
    if sqlite3_column_type(statement, index) == SQLITE_NULL {
        return nil
    }
    return sqlite3_column_int64(statement, index)
}
#else
actor ImageAssetMetadataStore {
    static let shared = ImageAssetMetadataStore()

    func metadata(for _: URL) -> ImageAssetMetadata? { nil }
    func upsert(_: ImageAssetMetadata) {}
    func purge(urls _: [URL]) {}
    func purgeAll() {}
}
#endif
