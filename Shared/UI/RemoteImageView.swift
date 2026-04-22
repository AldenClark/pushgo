import Foundation
import SwiftUI
#if canImport(SDWebImageSwiftUI) && !os(watchOS)
import SDWebImageSwiftUI
#endif

#if canImport(UIKit)
import UIKit
typealias PlatformImage = UIImage
#elseif os(macOS)
import AppKit
typealias PlatformImage = NSImage
#endif
struct RemoteImageView<Content: View, Placeholder: View>: View {
    let url: URL?
    let rendition: SharedImageCache.Rendition
    let content: (Image) -> Content
    let placeholder: () -> Placeholder

    @State private var sourceURL: URL?

    init(
        url: URL?,
        rendition: SharedImageCache.Rendition = .original,
        @ViewBuilder content: @escaping (Image) -> Content,
        @ViewBuilder placeholder: @escaping () -> Placeholder = { Color.clear },
    ) {
        self.url = url
        self.rendition = rendition
        self.content = content
        self.placeholder = placeholder
    }

    var body: some View {
        Group {
#if canImport(SDWebImageSwiftUI) && !os(watchOS)
            if let sourceURL {
                WebImage(
                    url: sourceURL,
                    options: [.fromLoaderOnly],
                    isAnimating: .constant(false)
                ) { image in
                    content(image)
                } placeholder: {
                    placeholder()
                }
                .indicator(.activity)
            } else {
                placeholder()
            }
#else
            placeholder()
#endif
        }
        .task(id: sourceIdentity) {
            await resolveSourceURL()
        }
    }

    private var sourceIdentity: String {
        "\(url?.absoluteString ?? "nil")#\(rendition.rawValue)"
    }

    private func resolveSourceURL() async {
        guard let url else {
            await MainActor.run {
                sourceURL = nil
            }
            return
        }
        if let cached = SharedImageCache.cachedFileURL(for: url, rendition: rendition) {
            await MainActor.run {
                sourceURL = cached
            }
            return
        }
        let resolved = await SharedImageCache.localSourceURL(
            for: url,
            rendition: rendition,
            maxBytes: AppConstants.maxMessageImageBytes,
            timeout: 10
        )
        await MainActor.run {
            sourceURL = resolved
        }
    }
}

enum RemoteImageCache {
    private static let decodeQueue = DispatchQueue(label: "io.ethan.pushgo.remote-image-decode", qos: .userInitiated)
    private static let imageCacheLimitBytes = 256 * 1024 * 1024

    private actor MemoryCache {
        private let cache = NSCache<NSURL, PlatformImage>()

        init() {
            cache.totalCostLimit = RemoteImageCache.imageCacheLimitBytes
            cache.countLimit = 512
        }

        func image(for key: NSURL) -> PlatformImage? {
            cache.object(forKey: key)
        }

        func set(_ image: PlatformImage, for key: NSURL) {
            cache.setObject(image, forKey: key, cost: Self.approximateCost(for: image))
        }

        func remove(for key: NSURL) {
            cache.removeObject(forKey: key)
        }

        private static func approximateCost(for image: PlatformImage) -> Int {
#if canImport(UIKit)
            let pixelWidth = max(Int(image.size.width * image.scale), 1)
            let pixelHeight = max(Int(image.size.height * image.scale), 1)
            return pixelWidth * pixelHeight * 4
#else
            if let bitmap = image.representations.compactMap({ $0 as? NSBitmapImageRep }).first {
                let bitsPerPixel = max(bitmap.bitsPerPixel, 32)
                return max(bitmap.pixelsWide, 1) * max(bitmap.pixelsHigh, 1) * bitsPerPixel / 8
            }
            let fallbackPixelWidth = max(Int(image.size.width * 2), 1)
            let fallbackPixelHeight = max(Int(image.size.height * 2), 1)
            return fallbackPixelWidth * fallbackPixelHeight * 4
#endif
        }
    }

    private actor InflightImages {
        private var tasks: [NSURL: Task<PlatformImage, Error>] = [:]

        func task(for key: NSURL, create: @escaping () -> Task<PlatformImage, Error>) -> Task<PlatformImage, Error> {
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

    private static let cache = MemoryCache()
    private static let inflight = InflightImages()

    static func cachedImage(for url: URL, rendition: SharedImageCache.Rendition) async -> PlatformImage? {
        let cacheKey = SharedImageCache.cacheKeyURL(for: url, rendition: rendition)
        return await cache.image(for: cacheKey)
    }

    static func loadImage(from url: URL, rendition: SharedImageCache.Rendition) async throws -> PlatformImage {
        let cacheKey = SharedImageCache.cacheKeyURL(for: url, rendition: rendition)
        if let cached = await cache.image(for: cacheKey) {
            return cached
        }
        let task = await inflight.task(for: cacheKey) {
            Task {
                defer { Task { await inflight.remove(cacheKey) } }
                let image = try await loadImageUncached(from: url, rendition: rendition)
                await cache.set(image, for: cacheKey)
                return image
            }
        }
        let image = try await task.value
        await cache.set(image, for: cacheKey)
        return image
    }

    static func purge(urls: [URL]) async {
        for url in urls {
            for rendition in SharedImageCache.Rendition.allCases {
                let cacheKey = SharedImageCache.cacheKeyURL(for: url, rendition: rendition)
                await cache.remove(for: cacheKey)
            }
        }
        await SharedImageCache.purge(urls: urls)
    }

    private static func decodeImage(from data: Data) async throws -> PlatformImage {
        try await withCheckedThrowingContinuation { continuation in
            decodeQueue.async {
                if let image = PlatformImage(data: data) {
                    continuation.resume(returning: image)
                } else {
                    continuation.resume(throwing: URLError(.cannotDecodeContentData))
                }
            }
        }
    }

    private static func loadImageUncached(
        from url: URL,
        rendition: SharedImageCache.Rendition
    ) async throws -> PlatformImage {
        if let data = await SharedImageCache.cachedData(for: url, rendition: rendition) {
            return try await decodeImage(from: data)
        }
        let data = try await SharedImageCache.fetchData(
            from: url,
            rendition: rendition,
            maxBytes: AppConstants.maxMessageImageBytes,
            timeout: 10
        )
        return try await decodeImage(from: data)
    }
}
