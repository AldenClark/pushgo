import Foundation
import SwiftUI

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

    @State private var phase: Phase = .idle

    enum Phase {
        case idle
        case loading
        case failure
        case success(Image)
    }

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
            switch phase {
            case .idle, .loading, .failure:
                placeholder()
            case let .success(image):
                content(image)
            }
        }
        .task(id: url) {
            await load(url: url, rendition: rendition)
        }
        .onAppear {
            guard case .failure = phase else { return }
            Task { await load(url: url, rendition: rendition) }
        }
    }

    private func load(url: URL?, rendition: SharedImageCache.Rendition) async {
        guard let url else {
            await MainActor.run {
                phase = .failure
            }
            return
        }
        if let cached = await RemoteImageCache.cachedImage(for: url, rendition: rendition) {
            await MainActor.run {
                phase = .success(Self.makeImage(from: cached))
            }
            return
        }
        await MainActor.run {
            if case .success = phase {
                return
            }
            phase = .loading
        }
        do {
            let platformImage = try await RemoteImageCache.loadImage(from: url, rendition: rendition)
            await MainActor.run {
                phase = .success(Self.makeImage(from: platformImage))
            }
        } catch {
            if error is CancellationError {
                return
            }
            await MainActor.run {
                phase = .failure
            }
        }
    }

    private static func makeImage(from platformImage: PlatformImage) -> Image {
#if canImport(UIKit)
        Image(uiImage: platformImage)
#else
        Image(nsImage: platformImage)
#endif
    }
}

enum RemoteImageCache {
    private static let decodeQueue = DispatchQueue(label: "io.ethan.pushgo.remote-image-decode", qos: .userInitiated)

    private actor MemoryCache {
        private let cache = NSCache<NSURL, PlatformImage>()

        func image(for key: NSURL) -> PlatformImage? {
            cache.object(forKey: key)
        }

        func set(_ image: PlatformImage, for key: NSURL) {
            cache.setObject(image, forKey: key)
        }

        func remove(for key: NSURL) {
            cache.removeObject(forKey: key)
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
