import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Decode budgets are independent of HTTP bytes and Private message frame limits.
/// ImageIO supplies orientation and format semantics; we never predecode an animation's frames.
enum ImageDisplayPolicy {
    static let maximumSourceDimension = 32_768
    static let maximumSourcePixels = 40_000_000
    static let maximumAnimatedPixels = 4_000_000
    static let maximumAnimatedFrames = 200
    static let animationBufferBytes: UInt = 16 * 1024 * 1024
    static let listMaximumPixelSize = 512
    static let detailMaximumPixelSize = 2_048

    struct Metadata: Sendable, Equatable {
        let width: Int
        let height: Int
        let frameCount: Int
        let isAnimated: Bool
        let mayAnimate: Bool
        let contentTypeIdentifier: String
    }

    static func metadata(for data: Data, inspectAnimationFrames: Bool = true) -> Metadata? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let identifier = CGImageSourceGetType(source) as String?,
              let type = UTType(identifier), type.conforms(to: .image),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0, height > 0,
              width <= maximumSourceDimension, height <= maximumSourceDimension,
              width <= maximumSourcePixels / height
        else { return nil }
        let frames = CGImageSourceGetCount(source)
        // Multi-page TIFF/PDF is not an animation. Let the mature GIF/APNG/WebP decoder own
        // timing, disposal and blending; over-budget animations receive an honest still cover.
        let animatedFormat = type.conforms(to: .gif) || type.conforms(to: .png)
            || identifier == "org.webmproject.webp"
        let isAnimated = animatedFormat && frames > 1
        var framesFitBudget = frames <= maximumAnimatedFrames && width <= maximumAnimatedPixels / height
        if inspectAnimationFrames && isAnimated && framesFitBudget {
            // Inspect bounded frame metadata, never materialize frame pixels to discover size.
            // Later frames may advertise a different rectangle from the cover.
            for index in 1..<frames {
                guard let frame = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
                      let frameWidth = (frame[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
                      let frameHeight = (frame[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
                      frameWidth > 0, frameHeight > 0,
                      frameWidth <= maximumSourceDimension, frameHeight <= maximumSourceDimension,
                      frameWidth <= maximumAnimatedPixels / frameHeight
                else { framesFitBudget = false; break }
            }
        }
        return Metadata(
            width: width, height: height, frameCount: frames, isAnimated: isAnimated,
            mayAnimate: inspectAnimationFrames && isAnimated && framesFitBudget,
            contentTypeIdentifier: identifier
        )
    }

    static func firstFrame(for data: Data, maximumPixelSize: Int) -> CGImage? {
        // Lists/Watch need only the cover's safe dimensions, not every animation frame's metadata.
        guard metadata(for: data, inspectAnimationFrames: false) != nil,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: min(max(maximumPixelSize, 1), detailMaximumPixelSize),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

/// Called only by an explicit save/share action. Exports are user attachments, not HTTP cache
/// entries; their bytes retain animated frames and metadata. OS temporary storage owns cleanup.
enum PushGoOriginalImageExport {
    static func write(_ data: Data, contentType: UTType?) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pushgo-share-preview", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("pushgo-image-\(UUID().uuidString)")
            .appendingPathExtension(contentType?.preferredFilenameExtension ?? "img")
        try data.write(to: file, options: .atomic)
        return file
    }
}

/// Per-process admission only: no queue, worker or timer. A paused/offscreen view releases its
/// native decoder and permit. Each admitted player also has its own finite frame buffer.
@MainActor
enum ImagePlaybackBudget {
    private static var active: Set<UUID> = []
    static let maximumPlayers = 2
    static func acquire(_ id: UUID) -> Bool {
        guard active.contains(id) || active.count < maximumPlayers else { return false }
        active.insert(id)
        return true
    }
    static func release(_ id: UUID) { active.remove(id) }
}

/// The derived cache retains at most 64 MiB and 96 decoded covers. View-owned images can outlive
/// eviction; original files and HTTP validity remain the resource store's responsibility.
actor ResourceImageDecode {
    static let shared = ResourceImageDecode()
    static let maximumCost = 64 * 1024 * 1024
    static let maximumEntries = 96
    private struct Entry {
        let image: CGImage
        let cost: Int
        var lastUse: UInt64
    }
    private var entries: [String: Entry] = [:]
    private var retainedCost = 0
    private var clock: UInt64 = 0

    func image(data: Data, immutableFile: URL?, rendition: SharedImageCache.Rendition) -> CGImage? {
        guard !Task.isCancelled else { return nil }
        let maximumPixelSize = rendition == .listThumbnail
            ? ImageDisplayPolicy.listMaximumPixelSize : ImageDisplayPolicy.detailMaximumPixelSize
        let originalsDirectory = SharedImageCache.resourceDirectory.appendingPathComponent("Originals", isDirectory: true).path + "/"
        let decodedIdentity = immutableFile.flatMap { file -> String? in
            guard file.path.hasPrefix(originalsDirectory) else { return nil }
            return "\(file.lastPathComponent)#first-frame-v1#oriented#\(maximumPixelSize)"
        }
        clock &+= 1
        if let decodedIdentity, var entry = entries[decodedIdentity] {
            entry.lastUse = clock
            entries[decodedIdentity] = entry
            return entry.image
        }
        guard let image = ImageDisplayPolicy.firstFrame(for: data, maximumPixelSize: maximumPixelSize) else { return nil }
        let cost = image.bytesPerRow * image.height
        if let decodedIdentity, cost <= Self.maximumCost {
            while !entries.isEmpty && (retainedCost + cost > Self.maximumCost || entries.count >= Self.maximumEntries) {
                guard let oldest = entries.min(by: { $0.value.lastUse < $1.value.lastUse }) else { break }
                retainedCost -= oldest.value.cost
                entries.removeValue(forKey: oldest.key)
            }
            entries[decodedIdentity] = Entry(image: image, cost: cost, lastUse: clock)
            retainedCost += cost
        }
        return image
    }

    func retainedCacheUsage() -> (entries: Int, bytes: Int) { (entries.count, retainedCost) }
}
