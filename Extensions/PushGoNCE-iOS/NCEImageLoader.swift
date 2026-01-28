import Foundation
import UIKit

actor NCEImageLoader {
    static let shared = NCEImageLoader()

    private let memory = NSCache<NSURL, UIImage>()
    private let memoryEnabled = SharedImageCache.isMemoryCacheEnabled
    private var inflight: [NSURL: Task<(UIImage, Int), Error>] = [:]

    static func fetchImage(from url: URL, maxBytes: Int64, timeout: TimeInterval) async throws -> UIImage {
        try await shared.fetchImage(from: url, maxBytes: maxBytes, timeout: timeout)
    }

    private func fetchImage(from url: URL, maxBytes: Int64, timeout: TimeInterval) async throws -> UIImage {
        let cacheKey = SharedImageCache.cacheKeyURL(for: url)
        if memoryEnabled, let cached = memory.object(forKey: cacheKey) {
            return cached
        }
        if let existing = inflight[cacheKey] {
            let (image, cost) = try await existing.value
            if memoryEnabled {
                memory.setObject(image, forKey: cacheKey, cost: cost)
            }
            return image
        }

        let task = Task { try await Self.loadImageData(from: url, maxBytes: maxBytes, timeout: timeout) }
        inflight[cacheKey] = task
        do {
            let (image, cost) = try await task.value
            inflight[cacheKey] = nil
            if memoryEnabled {
                memory.setObject(image, forKey: cacheKey, cost: cost)
            }
            return image
        } catch {
            inflight[cacheKey] = nil
            throw error
        }
    }

    private static func loadImageData(
        from url: URL,
        maxBytes: Int64,
        timeout: TimeInterval
    ) async throws -> (UIImage, Int) {
        if let cachedData = await SharedImageCache.cachedData(for: url) {
            if cachedData.count > maxBytes {
                await SharedImageCache.purge(urls: [url])
                throw URLError(.dataLengthExceedsMaximum)
            }
            if let image = UIImage(data: cachedData) {
                return (image, cachedData.count)
            }
            await SharedImageCache.purge(urls: [url])
        }

        let data = try await SharedImageCache.fetchData(from: url, maxBytes: maxBytes, timeout: timeout)
        guard let image = UIImage(data: data) else {
            throw URLError(.cannotDecodeContentData)
        }
        return (image, data.count)
    }
}
