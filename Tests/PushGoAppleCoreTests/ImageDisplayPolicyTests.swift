import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import PushGoAppleCore

struct ImageDisplayPolicyTests {
    private func bitmap(width: Int = 16, height: Int = 8, red: Bool = true) throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: width, height: height,
                                             bitsPerComponent: 8, bytesPerRow: width * 4,
                                             space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red ? CGColor(red: 1, green: 0, blue: 0, alpha: 1) : CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try #require(context.makeImage())
    }

    private func encoded(type: UTType = .gif, frames: Int = 2, width: Int = 16, height: Int = 8,
                         orientation: Int = 1) throws -> Data {
        let output = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(output, type.identifier as CFString, frames, nil))
        for index in 0..<frames {
            let image = try bitmap(width: width, height: height, red: index == 0)
            CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: orientation] as CFDictionary)
        }
        #expect(CGImageDestinationFinalize(destination))
        return output as Data
    }

    @Test func actualGIFRetainsMultipleFramesButListDecodesOnlyItsCover() throws {
        let data = try encoded()
        let metadata = try #require(ImageDisplayPolicy.metadata(for: data))
        #expect(metadata.frameCount == 2)
        #expect(metadata.mayAnimate)
        let cover = try #require(ImageDisplayPolicy.firstFrame(for: data, maximumPixelSize: 512))
        #expect(cover.width == 16 && cover.height == 8)
        #expect(cover.bytesPerRow * cover.height <= 512 * 512 * 4)
    }

    @Test func multipageTIFFIsNotAnAnimation() throws {
        let data = try encoded(type: .tiff)
        let metadata = try #require(ImageDisplayPolicy.metadata(for: data))
        #expect(metadata.frameCount == 2)
        #expect(!metadata.mayAnimate)
        #expect(ImageDisplayPolicy.firstFrame(for: data, maximumPixelSize: 512) != nil)
    }

    @Test func oversizedFrameCountGetsStaticCoverWithoutDiscardingOriginal() throws {
        let data = try encoded(frames: ImageDisplayPolicy.maximumAnimatedFrames + 1)
        let metadata = try #require(ImageDisplayPolicy.metadata(for: data))
        #expect(metadata.frameCount == ImageDisplayPolicy.maximumAnimatedFrames + 1)
        #expect(!metadata.mayAnimate)
        #expect(ImageDisplayPolicy.firstFrame(for: data, maximumPixelSize: 512) != nil)
    }

    @Test func thumbnailHonorsOrientationAndSize() throws {
        let data = try encoded(type: .jpeg, frames: 1, width: 80, height: 40, orientation: 6)
        let image = try #require(ImageDisplayPolicy.firstFrame(for: data, maximumPixelSize: 20))
        #expect(image.width == 10 && image.height == 20)
    }

    @Test func requestedDecodeCannotBypassDetailBudget() throws {
        let data = try encoded(type: .png, frames: 1, width: 3_000, height: 1)
        let image = try #require(ImageDisplayPolicy.firstFrame(for: data, maximumPixelSize: Int.max))
        #expect(image.width == ImageDisplayPolicy.detailMaximumPixelSize)
        #expect(image.height == 1)
    }

    @Test func invalidAndTruncatedBytesNeverBecomeDecodedSuccess() throws {
        #expect(ImageDisplayPolicy.metadata(for: Data("not an image".utf8)) == nil)
        #expect(ImageDisplayPolicy.firstFrame(for: Data(), maximumPixelSize: 512) == nil)
        let data = try encoded()
        #expect(ImageDisplayPolicy.firstFrame(for: data.prefix(8), maximumPixelSize: 512) == nil)
    }

    @Test func originalExportPreservesGIFBytesAndFrames() throws {
        let data = try encoded()
        let file = try PushGoOriginalImageExport.write(data, contentType: .gif)
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(file.pathExtension == "gif")
        #expect(try Data(contentsOf: file) == data)
        let source = try #require(CGImageSourceCreateWithURL(file as CFURL, nil))
        #expect(CGImageSourceGetCount(source) == 2)
    }

    @Test @MainActor func playbackAdmissionHasNoHiddenThirdPlayerAndReleaseRestoresCapacity() {
        let first = UUID(), second = UUID(), third = UUID()
        defer { [first, second, third].forEach { ImagePlaybackBudget.release($0) } }
        #expect(ImagePlaybackBudget.acquire(first))
        #expect(ImagePlaybackBudget.acquire(first)) // idempotent, not a second permit
        #expect(ImagePlaybackBudget.acquire(second))
        #expect(!ImagePlaybackBudget.acquire(third))
        ImagePlaybackBudget.release(first)
        #expect(ImagePlaybackBudget.acquire(third))
    }

    @Test func decodedCacheHasAnExactEntryLimitAndNeverRetainsVolatileResponses() async throws {
        let decoder = ResourceImageDecode()
        let data = try encoded(type: .png, frames: 1)
        // Synthetic immutable identities exercise derived accounting only, not an HTTP cache.
        for index in 0..<100 {
            let file = SharedImageCache.originalFileURL(contentHash: "accounting-\(index)")
            #expect(await decoder.image(data: data, immutableFile: file, rendition: .listThumbnail) != nil)
        }
        let before = await decoder.retainedCacheUsage()
        #expect(before.entries == ResourceImageDecode.maximumEntries)
        #expect(before.bytes <= ResourceImageDecode.maximumCost)
        #expect(await decoder.image(data: data, immutableFile: nil, rendition: .original) != nil)
        let after = await decoder.retainedCacheUsage()
        #expect(before.entries == after.entries && before.bytes == after.bytes)
    }

    @Test func decodedCacheEvictsBeforeExceedingItsByteBudget() async throws {
        let decoder = ResourceImageDecode()
        let data = try encoded(type: .png, frames: 1, width: 1024, height: 1024)
        for index in 0..<18 {
            let file = SharedImageCache.originalFileURL(contentHash: "cost-accounting-\(index)")
            #expect(await decoder.image(data: data, immutableFile: file, rendition: .original) != nil)
            let usage = await decoder.retainedCacheUsage()
            #expect(usage.bytes <= ResourceImageDecode.maximumCost)
        }
        let final = await decoder.retainedCacheUsage()
        #expect(final.entries < 18)
        #expect(final.bytes > 0)
    }
}
