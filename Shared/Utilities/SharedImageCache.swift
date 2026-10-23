import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers
#if canImport(SQLite3)
import SQLite3
#endif

enum SharedImageCache {
    typealias ResourceOwner = ImageResourceOwner
    typealias ResolvedResource = ImageResourceStore.Result
    enum Rendition: String, CaseIterable, Sendable { case original, listThumbnail }
#if !NSE_NO_DATABASE
    private static let canonicalStore = LocalDataStore()
#endif
    // Notification service targets intentionally have no canonical database.
    // They may read controlled public bytes, but cannot invent business refs
    // or collect originals belonging to the containing App's messages.
#if NSE_NO_DATABASE
    private static let resources = ImageResourceStore(
        directory: resourceDirectory,
        snapshot: { _ in nil }, binding: { _, _ in nil },
        bind: { _, _, _ in false }, collect: { _, _ in false }
    )
#else
    private static let resources = ImageResourceStore(
        directory: resourceDirectory,
        snapshot: { try await canonicalStore.imageResourceSnapshot(owner: $0) },
        binding: { try await canonicalStore.imageResourceBinding(snapshot: $0, requestKey: $1) },
        bind: { try await canonicalStore.bindImageResource(snapshot: $0, requestKey: $1, contentHash: $2) },
        collect: { try await canonicalStore.collectImageResource(contentHash: $0, remove: $1) }
    )
#endif
    static var resourceDirectory: URL {
        (AppConstants.appGroupContainerURL() ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent("ResourceContent", isDirectory: true)
    }
    static func originalFileURL(contentHash: String) -> URL {
        resourceDirectory.appendingPathComponent("Originals", isDirectory: true).appendingPathComponent(contentHash + ".img")
    }
    static func fixtureFileURL(contentHash: String) -> URL {
        resourceDirectory.appendingPathComponent("Fixtures", isDirectory: true).appendingPathComponent(contentHash + ".img")
    }
    private static func fixturePointerURL(for url: URL) -> URL {
        resourceDirectory.appendingPathComponent("Fixtures/Requests", isDirectory: true)
            .appendingPathComponent(imageContentHash(Data(ImageResourceStore.identity(url).utf8)) + ".txt")
    }

    static func resolve(for url: URL, rendition: Rendition = .original, maxBytes: Int64? = nil,
                        timeout: TimeInterval = 10, owner: ResourceOwner? = nil) async throws -> ResolvedResource {
        // The established App-owned quality fixture explicitly imports a
        // synthetic HTTPS reference. It is NOT an HTTP response/cache entry.
        // Normal configuration has no quality session and cannot take this path.
        if PushGoAutomationContext.qualitySession != nil,
           URLSanitizer.isAllowedRemoteURL(url),
           let pointer = try? String(contentsOf: fixturePointerURL(for: url), encoding: .utf8),
           pointer.count == 64, pointer.allSatisfy({ $0.isHexDigit }) {
            let file = fixtureFileURL(contentHash: pointer)
            let limit = min(10 * 1024 * 1024, maxBytes ?? 10 * 1024 * 1024)
            guard let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= limit else { throw URLError(.dataLengthExceedsMaximum) }
            let data = try Data(contentsOf: file)
            guard imageContentHash(data) == pointer, validImageData(data) else { throw URLError(.cannotDecodeContentData) }
            return ResolvedResource(data: data, fileURL: file, isStale: false, isPersistent: true)
        }
        let original = try await resources.resolve(url: url, owner: owner,
                                                   maxBytes: min(10 * 1024 * 1024, maxBytes ?? 10 * 1024 * 1024), timeout: timeout)
        // Derived previews are disposable and never replace/export the original.
        guard rendition == .listThumbnail, let thumbnail = makeListThumbnailData(from: original.data) else { return original }
        return ResolvedResource(data: thumbnail, fileURL: nil, isStale: original.isStale, isPersistent: false, consumerLease: original.consumerLease)
    }
    static func fetchData(from url: URL, rendition: Rendition = .original, maxBytes: Int64? = nil,
                          timeout: TimeInterval = 10, owner: ResourceOwner? = nil) async throws -> Data {
        try await resolve(for: url, rendition: rendition, maxBytes: maxBytes, timeout: timeout, owner: owner).data
    }
    static func localSourceURL(for url: URL, rendition: Rendition = .original, maxBytes: Int64? = nil,
                               timeout: TimeInterval = 10, owner: ResourceOwner? = nil) async -> URL? {
        try? await resolve(for: url, rendition: rendition, maxBytes: maxBytes, timeout: timeout, owner: owner).fileURL
    }
    @discardableResult
    static func store(data: Data, for url: URL, rendition: Rendition = .original, expiresAtEpochMillis: Int64? = nil) async -> URL? {
        // Explicit synthetic fixture import, not an HTTP response or a business
        // binding. Legacy app caches remain untouched, never inferred as fresh.
        guard PushGoAutomationContext.qualitySession != nil, URLSanitizer.isAllowedRemoteURL(url), validImageData(data) else { return nil }
        let hash = imageContentHash(data), file = fixtureFileURL(contentHash: hash)
        let pointer = fixturePointerURL(for: url)
        do {
            try FileManager.default.createDirectory(at: pointer.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: file, options: .atomic)
            try Data(hash.utf8).write(to: pointer, options: .atomic)
            return file
        } catch { return nil }
    }
    static func purge(urls: [URL]) async {
        // URLs do not own originals; only canonical reference release permits GC.
        _ = await resources.collectOrphans()
    }
    static func purgeAll() async { _ = await resources.collectOrphans() }
#if NSE_NO_DATABASE
    @discardableResult static func purgeExpired() async -> Int { 0 }
#else
    @discardableResult static func purgeExpired(using store: LocalDataStore? = nil) async -> Int {
        guard let store else { return await resources.collectOrphans() }
        return await resources.collectOrphans(collectOverride: { try await store.collectImageResource(contentHash: $0, remove: $1) })
    }
#endif
    static func startMaintenance() {
        // One bounded startup opportunity also recovers crash orphans. No
        // recurring timer and no remote refresh are introduced.
        Task(priority: .utility) { _ = await resources.collectOrphans() }
    }

    static func validImageData(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetStatus(source) == .statusComplete,
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = props[kCGImagePropertyPixelHeight] as? NSNumber else { return false }
        let w = width.int64Value, h = height.int64Value
        guard w > 0, h > 0, w <= 32_768, h <= 32_768, w <= 40_000_000 / h else { return false }
        // Validate one actual decoded cover, not metadata alone. Never decode
        // all animation frames just to admit/cache an original.
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 1,
            kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary) != nil
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

}
