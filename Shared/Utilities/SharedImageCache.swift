import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

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
            for rendition in renditions {
                let cacheKey = cacheKeyURL(for: url, rendition: rendition)
                if profile.memoryEnabled {
                    await memory.remove(for: cacheKey)
                }
            }
        }
        await disk.purge(urls: urls, renditions: renditions)
    }

    static func cacheKeyURL(for url: URL, rendition: Rendition = .original) -> NSURL {
        let key = normalizedCacheKey(for: url, rendition: rendition)
        return (URL(string: key) ?? url) as NSURL
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

    private static func cacheDirectory() -> URL? {
        AppConstants.appGroupContainerURL()?
            .appendingPathComponent("Cache/Images", isDirectory: true)
    }
}
