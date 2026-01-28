import CryptoKit
import Foundation

enum SharedImageCache {
    private struct CacheProfile {
        let memoryLimitBytes: Int
        let diskLimitBytes: Int64
        let memoryEnabled: Bool
    }

    private final class MemoryCache: @unchecked Sendable {
        let cache: NSCache<NSURL, NSData>

        init() {
            let cache = NSCache<NSURL, NSData>()
            cache.totalCostLimit = profile.memoryLimitBytes
            self.cache = cache
        }
    }

    private actor DiskCache {
        private let fileManager: FileManager
        private let diskLimitBytes: Int64

        init(fileManager: FileManager = .default, diskLimitBytes: Int64) {
            self.fileManager = fileManager
            self.diskLimitBytes = diskLimitBytes
        }

        func readData(for url: URL) -> Data? {
            guard let fileURL = SharedImageCache.fileURL(for: url) else { return nil }
            var isDir: ObjCBool = false
            guard fileManager.fileExists(atPath: fileURL.path, isDirectory: &isDir), !isDir.boolValue else {
                return nil
            }
            guard let data = try? Data(contentsOf: fileURL) else { return nil }
            try? fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: fileURL.path)
            return data
        }

        @discardableResult
        func store(data: Data, for url: URL) -> URL? {
            guard let destination = SharedImageCache.fileURL(for: url) else { return nil }
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

        func purge(urls: [URL]) {
            for url in urls {
                guard let fileURL = SharedImageCache.cachedFileURL(for: url) else { continue }
                try? fileManager.removeItem(at: fileURL)
            }
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
        if bundleId.hasSuffix(".NotificationServiceExtension")
            || bundleId.hasSuffix(".NotificationContentExtension")
        {
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

    private static let memory = MemoryCache()
    private static let disk = DiskCache(diskLimitBytes: profile.diskLimitBytes)
    private static let inflight = InflightRequests()

    static func cachedData(for url: URL) async -> Data? {
        guard URLSanitizer.isAllowedRemoteURL(url) else { return nil }
        let cacheKey = cacheKeyURL(for: url)
        if profile.memoryEnabled, let data = memory.cache.object(forKey: cacheKey) {
            return data as Data
        }
        guard let data = await disk.readData(for: url) else { return nil }
        if profile.memoryEnabled {
            memory.cache.setObject(data as NSData, forKey: cacheKey, cost: data.count)
        }
        return data
    }

    static func cachedFileURL(for url: URL) -> URL? {
        guard let target = fileURL(for: url) else { return nil }
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: target.path, isDirectory: &isDir), !isDir.boolValue {
            return target
        }
        return nil
    }

    static func fetchData(
        from url: URL,
        maxBytes: Int64? = nil,
        timeout: TimeInterval = 10
    ) async throws -> Data {
        guard URLSanitizer.isAllowedRemoteURL(url) else { throw URLError(.unsupportedURL) }
        if let cached = await cachedData(for: url) {
            if let maxBytes, cached.count > maxBytes { throw URLError(.dataLengthExceedsMaximum) }
            return cached
        }

        let cacheKey = cacheKeyURL(for: url)
        let task = await inflight.task(for: cacheKey) {
            Task {
                defer { Task { await inflight.remove(cacheKey) } }
                if let cached = await cachedData(for: url) {
                    if let maxBytes, cached.count > maxBytes { throw URLError(.dataLengthExceedsMaximum) }
                    return cached
                }

                var request = URLRequest(url: url)
                request.timeoutInterval = timeout
                let (data, response) = try await URLSession.shared.data(for: request)
                if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
                    throw URLError(.badServerResponse)
                }
                if let maxBytes, data.count > maxBytes {
                    throw URLError(.dataLengthExceedsMaximum)
                }
                await store(data: data, for: url)
                return data
            }
        }
        return try await task.value
    }

    @discardableResult
    static func store(data: Data, for url: URL) async -> URL? {
        let cacheKey = cacheKeyURL(for: url)
        if profile.memoryEnabled {
            memory.cache.setObject(data as NSData, forKey: cacheKey, cost: data.count)
        }
        return await disk.store(data: data, for: url)
    }

    static func purge(urls: [URL]) async {
        for url in urls {
            let cacheKey = cacheKeyURL(for: url)
            if profile.memoryEnabled {
                memory.cache.removeObject(forKey: cacheKey)
            }
        }
        await disk.purge(urls: urls)
    }

    static func cacheKeyURL(for url: URL) -> NSURL {
        let key = normalizedCacheKey(for: url)
        return (URL(string: key) ?? url) as NSURL
    }

    private static func fileURL(for url: URL) -> URL? {
        guard let base = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: AppConstants.appGroupIdentifier)
        else { return nil }
        let directory = base.appendingPathComponent("Cache/Images", isDirectory: true)
        let ext = url.pathExtension.isEmpty ? "img" : url.pathExtension
        let name = sha256(normalizedCacheKey(for: url))
        return directory.appendingPathComponent("\(name).\(ext)")
    }

    private static func normalizedCacheKey(for url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url.absoluteString
        }
        components.fragment = nil
        return components.url?.absoluteString ?? url.absoluteString
    }

    private static func sha256(_ text: String) -> String {
        let digest = SHA256.hash(data: Data(text.utf8))
        return digest.compactMap { String(format: "%02x", $0) }.joined()
    }

    private static func cacheDirectory() -> URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: AppConstants.appGroupIdentifier)?
            .appendingPathComponent("Cache/Images", isDirectory: true)
    }
}
