import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import PushGoAppleCore

/// Real URLSession streams. Request logs, original bytes and bindings are the
/// oracles; the server gates establish cancellation/deletion interleavings.
@Suite(.serialized)
struct ImageResourceStoreTests {
    private func png(red: Bool = true, width: Int = 2) throws -> Data {
        let context = try #require(CGContext(data: nil, width: width, height: 1, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red ? CGColor(red: 1, green: 0, blue: 0, alpha: 1) : CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: 1))
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
        try #require(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private func engine(_ server: ImageHTTPFixture, owners: ImageFixtureOwners) -> ImageResourceStore {
        ImageResourceStore(directory: server.root.appendingPathComponent("cache", isDirectory: true),
            allowedURL: { $0.scheme == "http" && $0.host == "127.0.0.1" },
            snapshot: { await owners.snapshot($0) }, binding: { await owners.binding($0, key: $1) },
            bind: { await owners.bind($0, key: $1, hash: $2) }, collect: { await owners.collect($0, remove: $1) })
    }

    @Test func freshNewOwnerReusesWithoutGETAndHistoricalOwnerNeverRefreshes() async throws {
        let data = try png(), server = try ImageHTTPFixture(["/image": [.init(try png(), headers: ["Cache-Control": "max-age=3600"]) ]])
        defer { server.stop() }
        let owners = ImageFixtureOwners(), first = await owners.add(), second = await owners.add(), store = engine(server, owners: owners)
        let a = try await store.resolve(url: server.url(), owner: first, maxBytes: 4096, timeout: 5)
        let b = try await store.resolve(url: server.url(), owner: first, maxBytes: 4096, timeout: 5)
        let c = try await store.resolve(url: server.url(), owner: second, maxBytes: 4096, timeout: 5)
        #expect(a.data == data && b.data == data && c.data == data)
        #expect(a.fileURL == c.fileURL)
        #expect(try server.requests().count == 1)
        #expect(await owners.bindingCount() == 2)
        await server.stopAndWait()
    }

    @Test func expiredETag304UpdatesFreshnessAndLastModifiedIsTheFallback() async throws {
        let data = try png(), modified = "Wed, 21 Oct 2015 07:28:00 GMT"
        let server = try ImageHTTPFixture(["/image": [
            .init(data, headers: ["Cache-Control": "max-age=0", "ETag": "\"a\"", "Last-Modified": modified]),
            .init(status: 304, headers: ["Cache-Control": "max-age=3600"]),
        ], "/modified": [
            .init(data, headers: ["Cache-Control": "no-cache", "Last-Modified": modified]),
            .init(status: 304, headers: ["Cache-Control": "max-age=3600"]),
        ]])
        defer { server.stop() }
        let owners = ImageFixtureOwners(), store = engine(server, owners: owners)
        for _ in 0..<3 { #expect(try await store.resolve(url: server.url(), owner: await owners.add(), maxBytes: 4096, timeout: 5).data == data) }
        for _ in 0..<2 { _ = try await store.resolve(url: server.url("/modified"), owner: await owners.add(), maxBytes: 4096, timeout: 5) }
        let requests = try server.requests()
        #expect(requests.count == 4)
        #expect(requests[1].headers["if-none-match"] == "\"a\"")
        #expect(requests[1].headers["if-modified-since"] == nil)
        #expect(requests[3].headers["if-modified-since"] == modified)
        await server.stopAndWait()
    }

    @Test func missingOriginalCannotReuse304AndRecoveryGETIsUnconditionalAndBounded() async throws {
        let data = try png(), server = try ImageHTTPFixture(["/image": [
            .init(try png(), headers: ["Cache-Control": "max-age=0", "ETag": "\"a\""]),
            .init(status: 304), .init(try png(), headers: ["Cache-Control": "max-age=3600"]),
        ]])
        defer { server.stop() }
        let owners = ImageFixtureOwners(), store = engine(server, owners: owners)
        let first = try await store.resolve(url: server.url(), owner: await owners.add(), maxBytes: 4096, timeout: 5)
        try FileManager.default.removeItem(at: try #require(first.fileURL))
        let recovered = try await store.resolve(url: server.url(), owner: await owners.add(), maxBytes: 4096, timeout: 5)
        #expect(recovered.data == data && recovered.isPersistent && !recovered.isStale)
        let requests = try server.requests()
        #expect(requests.count == 3)
        #expect(requests[1].headers["if-none-match"] == nil && requests[2].headers["if-none-match"] == nil)
        await server.stopAndWait()
    }

    @Test func sameBytesDeduplicateAndURLUpdateOnlyBindsNewMessages() async throws {
        let a = try png(), b = try png(red: false)
        let server = try ImageHTTPFixture(["/image": [
            .init(a, headers: ["Cache-Control": "max-age=0"]), .init(a, headers: ["Cache-Control": "max-age=0"]),
            .init(b, headers: ["Cache-Control": "max-age=3600"]),
        ]])
        defer { server.stop() }
        let owners = ImageFixtureOwners(), old = await owners.add(), store = engine(server, owners: owners)
        let first = try await store.resolve(url: server.url(), owner: old, maxBytes: 4096, timeout: 5)
        let same = try await store.resolve(url: server.url(), owner: await owners.add(), maxBytes: 4096, timeout: 5)
        let changed = try await store.resolve(url: server.url(), owner: await owners.add(), maxBytes: 4096, timeout: 5)
        let historical = try await store.resolve(url: server.url(), owner: old, maxBytes: 4096, timeout: 5)
        #expect(first.fileURL == same.fileURL && first.fileURL != changed.fileURL)
        #expect(changed.data == b && historical.data == a)
        #expect(try server.requests().count == 3)
        #expect(try server.originalFiles().count == 2)
        await server.stopAndWait()
    }

    @Test func redirectsDoNotCarryOriginalValidatorsOrGiveAnAliasFinalFreshness() async throws {
        let a = try png(), b = try png(red: false)
        let server = try ImageHTTPFixture(["/image": [
            .init(a, headers: ["Cache-Control": "max-age=0", "ETag": "\"same\""]),
            .init(status: 302, headers: ["Location": "/b"]),
            .init(status: 302, headers: ["Location": "/b"]),
        ], "/b": [
            .init(b, headers: ["Cache-Control": "max-age=3600", "ETag": "\"same\""]),
            .init(b, headers: ["Cache-Control": "max-age=3600", "ETag": "\"same\""]),
        ]])
        defer { server.stop() }
        let owners = ImageFixtureOwners(), old = await owners.add(), store = engine(server, owners: owners)
        #expect(try await store.resolve(url: server.url(), owner: old, maxBytes: 4096, timeout: 5).data == a)
        #expect(try await store.resolve(url: server.url(), owner: await owners.add(), maxBytes: 4096, timeout: 5).data == b)
        #expect(try await store.resolve(url: server.url(), owner: old, maxBytes: 4096, timeout: 5).data == a)
        // /b's fresh response says nothing about /image's redirect lifetime.
        #expect(try await store.resolve(url: server.url(), owner: await owners.add(), maxBytes: 4096, timeout: 5).data == b)
        let requests = try server.requests()
        #expect(requests.map(\.path) == ["/image", "/image", "/b", "/image", "/b"])
        #expect(requests[1].headers["if-none-match"] == "\"same\"")
        for request in requests where request.path == "/b" {
            #expect(request.headers["if-none-match"] == nil && request.headers["if-modified-since"] == nil)
        }
        await server.stopAndWait()
    }

    @Test func noStoreNeverPublishesOrBindsAndNoCacheAlwaysValidatesNewOwners() async throws {
        let data = try png(), server = try ImageHTTPFixture(["/image": [
            .init(try png(), headers: ["Cache-Control": "no-store"]), .init(try png(), headers: ["Cache-Control": "no-store"]),
        ], "/validate": [
            .init(try png(), headers: ["Cache-Control": "no-cache, max-age=3600", "ETag": "\"a\""]),
            .init(status: 304, headers: ["Cache-Control": "no-cache, max-age=3600"]),
        ]])
        defer { server.stop() }
        let owners = ImageFixtureOwners(), owner = await owners.add(), store = engine(server, owners: owners)
        for _ in 0..<2 {
            let result = try await store.resolve(url: server.url(), owner: owner, maxBytes: 4096, timeout: 5)
            #expect(result.data == data && result.fileURL == nil && !result.isPersistent)
        }
        #expect(await owners.bindingCount() == 0)
        #expect(try server.originalFiles().isEmpty)
        for _ in 0..<2 { _ = try await store.resolve(url: server.url("/validate"), owner: await owners.add(), maxBytes: 4096, timeout: 5) }
        let requests = try server.requests()
        #expect(requests.count == 4 && requests[3].headers["if-none-match"] == "\"a\"")
        await server.stopAndWait()
    }

    @Test func varyStarDoesNotReuseButMatchingAcceptDoes() async throws {
        let data = try png(), server = try ImageHTTPFixture(["/image": [
            .init(try png(), headers: ["Cache-Control": "max-age=3600", "Vary": "*"]),
            .init(try png(), headers: ["Cache-Control": "max-age=3600", "Vary": "*"]),
        ], "/accept": [.init(try png(), headers: ["Cache-Control": "max-age=3600", "Vary": "Accept"]) ]])
        defer { server.stop() }
        let owners = ImageFixtureOwners(), store = engine(server, owners: owners)
        for path in ["/image", "/image", "/accept", "/accept"] {
            #expect(try await store.resolve(url: server.url(path), owner: await owners.add(), maxBytes: 4096, timeout: 5).data == data)
        }
        let requests = try server.requests()
        #expect(requests.count == 3 && requests[2].headers["accept"] == "image/*")
        await server.stopAndWait()
    }

    @Test func expiresUsesDateAndUnknownVaryDoesNotCrossReuse() async throws {
        let date = Date(), formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"
        let server = try ImageHTTPFixture(["/image": [.init(try png(), headers: [
            "Date": formatter.string(from: date), "Expires": formatter.string(from: date.addingTimeInterval(3_600)),
        ])], "/vary": [
            .init(try png(), headers: ["Cache-Control": "max-age=3600", "Vary": "Accept-Language"]),
            .init(try png(), headers: ["Cache-Control": "max-age=3600", "Vary": "Accept-Language"]),
        ]])
        defer { server.stop() }
        let owners = ImageFixtureOwners(), store = engine(server, owners: owners)
        for path in ["/image", "/image", "/vary", "/vary"] {
            _ = try await store.resolve(url: server.url(path), owner: await owners.add(), maxBytes: 4096, timeout: 5)
        }
        #expect(try server.requests().map(\.path) == ["/image", "/vary", "/vary"])
        await server.stopAndWait()
    }

    @Test func noStoreResponseIsNotSharedBetweenDifferentMessageOwners() async throws {
        let data = try png(), server = try ImageHTTPFixture(["/image": [
            .init(try png(), headers: ["Cache-Control": "no-store"], gate: "response"),
            .init(try png(), headers: ["Cache-Control": "no-store"]),
        ]])
        defer { server.stop() }
        let owners = ImageFixtureOwners(), a = await owners.add(), b = await owners.add(), store = engine(server, owners: owners)
        let first = Task { try await store.resolve(url: server.url(), owner: a, maxBytes: 4096, timeout: 5) }
        try await server.waitForRequests(1)
        let second = Task { try await store.resolve(url: server.url(), owner: b, maxBytes: 4096, timeout: 5) }
        try await owners.waitForSnapshots(2)
        _ = await store.objectURL(imageContentHash(data))
        try server.release("response")
        let firstResult = try await first.value, secondResult = try await second.value
        #expect(firstResult.data == data && secondResult.data == data)
        #expect(!firstResult.isPersistent && !secondResult.isPersistent)
        #expect(try server.requests().count == 2)
        #expect(await owners.bindingCount() == 0)
        #expect(try server.originalFiles().isEmpty)
        await server.stopAndWait()
    }

    @Test func dateAgeAndAbsentFreshnessHaveNoMinimumTTLOrHitRenewal() async throws {
        let data = try png(), server = try ImageHTTPFixture(["/image": [
            .init(try png(), headers: ["Cache-Control": "max-age=3600", "Age": "3601", "ETag": "\"a\""]),
            .init(status: 304, headers: ["Cache-Control": "max-age=0", "Age": "0"]),
            .init(status: 304, headers: ["Cache-Control": "max-age=3600"]),
        ], "/old-date": [
            .init(try png(), headers: ["Cache-Control": "max-age=3600", "Date": "Wed, 21 Oct 2015 07:28:00 GMT", "ETag": "\"a\""]),
            .init(status: 304, headers: ["Cache-Control": "max-age=3600"]),
        ], "/age304": [
            .init(try png(), headers: ["Cache-Control": "max-age=60", "Age": "61", "ETag": "\"a\""]),
            // This validation response has its own Date and no Age. The old
            // response's 61-second Age cannot be carried into the new age.
            .init(status: 304, headers: ["Cache-Control": "max-age=60"]),
        ], "/absent": [.init(try png()), .init(try png())]])
        defer { server.stop() }
        let owners = ImageFixtureOwners(), store = engine(server, owners: owners)
        for path in ["/image", "/image", "/image", "/old-date", "/old-date", "/absent", "/absent"] {
            #expect(try await store.resolve(url: server.url(path), owner: await owners.add(), maxBytes: 4096, timeout: 5).data == data)
        }
        for _ in 0..<3 {
            let validated = try await store.resolve(url: server.url("/age304"), owner: await owners.add(), maxBytes: 4096, timeout: 5)
            #expect(validated.data == data && !validated.isStale)
        }
        #expect(try server.requests().count == 9)
        await server.stopAndWait()
    }

    @Test func fullQueryAndOriginScopeRemainSeparateRequestIdentities() async throws {
        let data = try png(), server = try ImageHTTPFixture(["/image?v=a": [
            .init(try png(), headers: ["Cache-Control": "max-age=3600"]), .init(try png(), headers: ["Cache-Control": "max-age=3600"]),
        ], "/image?v=b": [.init(try png(), headers: ["Cache-Control": "max-age=3600"]) ]])
        defer { server.stop() }
        let owners = ImageFixtureOwners(), store = engine(server, owners: owners)
        let a = try await store.resolve(url: server.url("/image?v=a"), owner: await owners.add(scope: "origin-a"), maxBytes: 4096, timeout: 5)
        let b = try await store.resolve(url: server.url("/image?v=a"), owner: await owners.add(scope: "origin-b"), maxBytes: 4096, timeout: 5)
        let c = try await store.resolve(url: server.url("/image?v=b"), owner: await owners.add(scope: "origin-a"), maxBytes: 4096, timeout: 5)
        #expect(a.data == data && a.fileURL == b.fileURL && b.fileURL == c.fileURL)
        #expect(try server.requests().map(\.path) == ["/image?v=a", "/image?v=a", "/image?v=b"])
        await server.stopAndWait()
    }

    @Test func failedRefreshIsDisplayOnlyAndDoesNotRenewFreshness() async throws {
        let data = try png(), server = try ImageHTTPFixture(["/image": [
            .init(try png(), headers: ["Cache-Control": "max-age=0", "ETag": "\"a\""]), .init(status: 503), .init(status: 503),
        ]])
        defer { server.stop() }
        let owners = ImageFixtureOwners(), later = await owners.add(), store = engine(server, owners: owners)
        _ = try await store.resolve(url: server.url(), owner: await owners.add(), maxBytes: 4096, timeout: 5)
        for _ in 0..<2 {
            let stale = try await store.resolve(url: server.url(), owner: later, maxBytes: 4096, timeout: 5)
            #expect(stale.data == data && stale.isStale)
        }
        #expect(await owners.bindingCount() == 1)
        #expect(try server.requests().count == 3)
        await server.stopAndWait()
    }

    @Test func forbiddenStaleIsNotSilentlyServedOnFailure() async throws {
        let data = try png(), server = try ImageHTTPFixture(["/must": [
            .init(try png(), headers: ["Cache-Control": "max-age=0, must-revalidate"]), .init(status: 503),
        ], "/validate": [.init(try png(), headers: ["Cache-Control": "no-cache"]), .init(status: 503)]])
        defer { server.stop() }
        let owners = ImageFixtureOwners(), store = engine(server, owners: owners)
        for path in ["/must", "/validate"] {
            #expect(try await store.resolve(url: server.url(path), owner: await owners.add(), maxBytes: 4096, timeout: 5).data == data)
            await #expect(throws: (any Error).self) { _ = try await store.resolve(url: server.url(path), owner: await owners.add(), maxBytes: 4096, timeout: 5) }
        }
        #expect(try server.requests().count == 4)
        await server.stopAndWait()
    }

    @Test func concurrentConsumersShareOneRequestAndCancellationPreservesSurvivor() async throws {
        let data = try png(), server = try ImageHTTPFixture(["/image": [.init(try png(), headers: ["Cache-Control": "max-age=3600"], gate: "response")]])
        defer { server.stop() }
        let owners = ImageFixtureOwners(), a = await owners.add(), b = await owners.add(), store = engine(server, owners: owners)
        // Establish the survivor's active flight before introducing the
        // subscriber that will be cancelled; cancellation cannot race ahead
        // of the only surviving subscriber's registration.
        let survivor = Task { try await store.resolve(url: server.url(), owner: a, maxBytes: 4096, timeout: 5) }
        try await server.waitForRequests(1)
        let cancelled = Task { try await store.resolve(url: server.url(), owner: b, maxBytes: 4096, timeout: 5) }
        try await owners.waitForSnapshots(2)
        _ = await store.objectURL(imageContentHash(data))
        cancelled.cancel()
        try server.release("response")
        await #expect(throws: CancellationError.self) { _ = try await cancelled.value }
        #expect(try await survivor.value.data == data)
        #expect(try server.requests().count == 1)
        #expect(await owners.bindingCount() == 1)
        await server.stopAndWait()
    }

    @Test func ownerDeletionDuringDownloadRejectsLateBinding() async throws {
        let data = try png(), server = try ImageHTTPFixture(["/image": [.init(try png(), headers: ["Cache-Control": "max-age=3600"], gate: "response")]])
        defer { server.stop() }
        let owners = ImageFixtureOwners(), deleted = await owners.add(), store = engine(server, owners: owners)
        let loading = Task { try await store.resolve(url: server.url(), owner: deleted, maxBytes: 4096, timeout: 5) }
        try await server.waitForRequests(1)
        await owners.delete(deleted)
        try server.release("response")
        await #expect(throws: (any Error).self) { _ = try await loading.value }
        #expect(await owners.bindingCount() == 0)
        #expect(try await store.resolve(url: server.url(), owner: await owners.add(), maxBytes: 4096, timeout: 5).data == data)
        #expect(try server.requests().count == 1)
        await server.stopAndWait()
    }

    @Test func unknownLengthStreamAbortsEarlyAndCachedOriginalHonorsLowerConsumerLimit() async throws {
        let server = try ImageHTTPFixture(["/image": [.init(try png(), headers: ["Cache-Control": "max-age=3600"])],
            "/large": [.init(Data(repeating: 0x61, count: 2 * 1024 * 1024), chunked: true, paced: true)]])
        defer { server.stop() }
        let owners = ImageFixtureOwners(), owner = await owners.add(), store = engine(server, owners: owners)
        _ = try await store.resolve(url: server.url(), owner: owner, maxBytes: 4096, timeout: 5)
        await #expect(throws: (any Error).self) { _ = try await store.resolve(url: server.url(), owner: owner, maxBytes: 16, timeout: 5) }
        do {
            _ = try await store.resolve(url: server.url("/large"), owner: await owners.add(), maxBytes: 1024, timeout: 5)
            Issue.record("Unknown-length stream bypassed byte budget")
        } catch { #expect((error as? URLError)?.code == .dataLengthExceedsMaximum) }
        try await server.waitForFinished(path: "/large")
        #expect(try #require(server.finished().first { $0.path == "/large" }).bytes < 2 * 1024 * 1024)
        #expect(try server.originalFiles().count == 1)
        #expect(try server.requests().count == 2)
        await server.stopAndWait()
    }

    @Test func corruptImageNeverBecomesPersistentSuccess() async throws {
        // This is a valid 40,001 x 1 PNG, generated with only 160 KB of fixture
        // bitmap storage. The production dimension budget must reject it.
        let server = try ImageHTTPFixture(["/image": [.init(Data("not an image".utf8))],
            "/pixels": [.init(try png(width: 40_001))], "/truncated": [.init(Data(try png().prefix(45)))],
            // Valid gzip bytes deliberately violate the client's explicit
            // identity encoding request. A transparent decompressor must not
            // make this look like an admitted wire-byte-budgeted response.
            "/encoded": [.init(try png(), headers: ["Content-Encoding": "gzip"], gzip: true)]])
        defer { server.stop() }
        let owners = ImageFixtureOwners(), store = engine(server, owners: owners)
        for path in ["/image", "/pixels", "/truncated", "/encoded"] {
            await #expect(throws: (any Error).self) { _ = try await store.resolve(url: server.url(path), owner: await owners.add(), maxBytes: 4096, timeout: 5) }
        }
        #expect(await owners.bindingCount() == 0)
        #expect(try server.originalFiles().isEmpty)
        await server.stopAndWait()
    }

    @Test func corruptHistoricalFileFailsClosedButNewOwnerMayRepairTheSameContentHash() async throws {
        let data = try png(), server = try ImageHTTPFixture(["/image": [
            .init(try png(), headers: ["Cache-Control": "max-age=0", "ETag": "\"a\""]),
            .init(try png(), headers: ["Cache-Control": "max-age=3600", "ETag": "\"a\""]),
        ]])
        defer { server.stop() }
        let owners = ImageFixtureOwners(), owner = await owners.add(), store = engine(server, owners: owners)
        let first = try await store.resolve(url: server.url(), owner: owner, maxBytes: 4096, timeout: 5)
        let file = try #require(first.fileURL)
        try Data("injected damaged disk original".utf8).write(to: file, options: .atomic)
        await #expect(throws: (any Error).self) {
            _ = try await store.resolve(url: server.url(), owner: owner, maxBytes: 4096, timeout: 5)
        }
        #expect(try server.requests().count == 1)
        let repaired = try await store.resolve(url: server.url(), owner: await owners.add(), maxBytes: 4096, timeout: 5)
        #expect(repaired.data == data && repaired.fileURL == file)
        #expect(try Data(contentsOf: file) == data)
        #expect(try await store.resolve(url: server.url(), owner: owner, maxBytes: 4096, timeout: 5).data == data)
        let requests = try server.requests()
        #expect(requests.count == 2 && requests[1].headers["if-none-match"] == nil)
        await server.stopAndWait()
    }

    @Test func orphanCollectionPreservesMetadataLegacyAndReferencedOriginals() async throws {
        let data = try png(), server = try ImageHTTPFixture(["/image": [.init(try png(), headers: ["Cache-Control": "max-age=3600"]), .init(try png())]])
        defer { server.stop() }
        let owners = ImageFixtureOwners(), owner = await owners.add(), store = engine(server, owners: owners)
        var result: ImageResourceStore.Result? = try await store.resolve(url: server.url(), owner: owner, maxBytes: 4096, timeout: 5)
        let file = try #require(result?.fileURL), metadata = server.root.appendingPathComponent("cache/Metadata/http.sqlite")
        let legacy = server.root.appendingPathComponent("cache/legacy-cached-image.png")
        try data.write(to: legacy)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: file.path)
        #expect(await store.collectOrphans() == 0)
        #expect(FileManager.default.fileExists(atPath: file.path))
        await owners.delete(owner)
        // A displayed/exported original remains protected after its last
        // business reference is removed, until the active read lease ends.
        #expect(await store.collectOrphans() == 0)
        result = nil
        #expect(await store.collectOrphans() == 1)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(FileManager.default.fileExists(atPath: metadata.path) && FileManager.default.fileExists(atPath: legacy.path))
        #expect(try await store.resolve(url: server.url(), owner: await owners.add(), maxBytes: 4096, timeout: 5).data == data)
        await server.stopAndWait()
    }

    @Test func publishedFileIsProtectedWhileCanonicalBindIsPaused() async throws {
        let data = try png(), server = try ImageHTTPFixture(["/image": [.init(try png(), headers: ["Cache-Control": "max-age=3600"]) ]])
        defer { server.stop() }
        let owners = ImageFixtureOwners(), owner = await owners.add(), store = engine(server, owners: owners)
        await owners.pauseNextBind()
        var loading: Task<ImageResourceStore.Result, Error>? = Task {
            try await store.resolve(url: server.url(), owner: owner, maxBytes: 4096, timeout: 5)
        }
        try await owners.waitForPausedBind()
        let file = await store.objectURL(imageContentHash(data))
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: file.path)
        #expect(await owners.bindingCount() == 0)
        #expect(await store.collectOrphans() == 0)
        #expect(FileManager.default.fileExists(atPath: file.path))
        await owners.releaseBind()
        var result = try await #require(loading).value
        loading = nil
        #expect(result.fileURL == file && result.data == data)
        await owners.delete(owner)
        #expect(await store.collectOrphans() == 0)
        // Transfer away the active result by ending the helper scope below.
        result = .init(data: Data(), fileURL: nil, isStale: false, isPersistent: false)
        #expect(await store.collectOrphans() == 1)
        await server.stopAndWait()
    }

    #if DEBUG
    @Test func cachedResultsRetainBoundedAdmissionUntilTheConsumerReleasesThem() async throws {
        let data = try png(), server = try ImageHTTPFixture(["/image": [.init(try png(), headers: ["Cache-Control": "max-age=3600"]) ]])
        defer { server.stop() }
        let owners = ImageFixtureOwners(), owner = await owners.add(), store = engine(server, owners: owners)
        var results: [ImageResourceStore.Result] = []
        for _ in 0..<64 { results.append(try await store.resolve(url: server.url(), owner: owner, maxBytes: 4096, timeout: 5)) }
        #expect(results.count == 64 && results.allSatisfy { $0.data == data })
        #expect(await store.activeConsumerCountForTesting() == 64)
        do {
            _ = try await store.resolve(url: server.url(), owner: owner, maxBytes: 4096, timeout: 5)
            Issue.record("A cache hit bypassed the active consumer budget")
        } catch { #expect((error as? URLError)?.code == .resourceUnavailable) }
        _ = results.removeLast()
        // RAII release posts to the resource actor. Observe that exact counter
        // transition before making one new request; do not retry the request.
        var count = await store.activeConsumerCountForTesting()
        for _ in 0..<1_000 where count != 63 {
            await Task.yield()
            count = await store.activeConsumerCountForTesting()
        }
        try #require(count == 63)
        let restored = try await store.resolve(url: server.url(), owner: owner, maxBytes: 4096, timeout: 5)
        #expect(restored.data == data)
        #expect(try server.requests().count == 1)
        await server.stopAndWait()
    }
    #endif
}

private actor ImageFixtureOwners {
    private var owners: [ImageResourceOwner: ImageResourceOwnerSnapshot] = [:]
    private var bindings: [ImageResourceOwner: [String: String]] = [:]
    private var snapshots = 0
    private var shouldPauseBind = false
    private var pausedBind = false
    private var bindContinuation: CheckedContinuation<Void, Never>?
    func add(scope: String = "origin-a") -> ImageResourceOwner {
        let owner = ImageResourceOwner.message(localID: UUID())
        owners[owner] = .init(owner: owner, stamp: UUID().uuidString, scope: scope, canonicalID: owner.key)
        return owner
    }
    func snapshot(_ owner: ImageResourceOwner) -> ImageResourceOwnerSnapshot? { snapshots += 1; return owners[owner] }
    func binding(_ snapshot: ImageResourceOwnerSnapshot, key: String) -> String? {
        guard owners[snapshot.owner] == snapshot else { return nil }; return bindings[snapshot.owner]?[key]
    }
    func bind(_ snapshot: ImageResourceOwnerSnapshot, key: String, hash: String) async -> Bool {
        if shouldPauseBind {
            shouldPauseBind = false; pausedBind = true
            await withCheckedContinuation { bindContinuation = $0 }
        }
        guard owners[snapshot.owner] == snapshot else { return false }
        bindings[snapshot.owner, default: [:]][key] = hash; return true
    }
    func delete(_ owner: ImageResourceOwner) { owners[owner] = nil; bindings[owner] = nil }
    func bindingCount() -> Int { bindings.values.reduce(0) { $0 + $1.count } }
    func pauseNextBind() { shouldPauseBind = true }
    func releaseBind() { bindContinuation?.resume(); bindContinuation = nil }
    func waitForPausedBind() async throws {
        for _ in 0..<1_000 { if pausedBind { return }; try await Task.sleep(for: .milliseconds(2)) }
        throw ImageHTTPFixture.FixtureTimeout()
    }
    func collect(_ hash: String, remove: @Sendable () -> Void) -> Bool {
        guard !bindings.values.contains(where: { $0.values.contains(hash) }) else { return false }; remove(); return true
    }
    func waitForSnapshots(_ count: Int) async throws {
        for _ in 0..<1_000 { if snapshots >= count { return }; try await Task.sleep(for: .milliseconds(2)) }
        throw ImageHTTPFixture.FixtureTimeout()
    }
}

private final class ImageHTTPFixture: @unchecked Sendable {
    struct Response: Codable {
        var status: Int, headers: [String: String], body: String, gate: String?, chunked: Bool, paced: Bool, gzip: Bool
        init(_ data: Data = Data(), status: Int = 200, headers: [String: String] = [:], gate: String? = nil, chunked: Bool = false, paced: Bool = false, gzip: Bool = false) {
            self.status = status; self.headers = headers; body = data.base64EncodedString(); self.gate = gate; self.chunked = chunked; self.paced = paced; self.gzip = gzip
        }
        init(status: Int, headers: [String: String] = [:]) { self.init(Data(), status: status, headers: headers) }
    }
    struct Request: Decodable { let path: String; let headers: [String: String] }
    struct Finished: Decodable { let path: String; let bytes: Int }
    struct FixtureTimeout: Error {}
    let root: URL
    private let process: Process
    private let port: Int
    private let termination = ImageFixtureTermination()
    init(_ responses: [String: [Response]], testName: String = #function) throws {
        let evidenceDirectory = ProcessInfo.processInfo.environment["PUSHGO_HTTP_TEST_EVIDENCE_ROOT"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) } ?? FileManager.default.temporaryDirectory
        root = evidenceDirectory.appendingPathComponent("pushgo-image-http-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(testName.utf8).write(to: root.appendingPathComponent("test-name.txt"))
        try JSONEncoder().encode(responses).write(to: root.appendingPathComponent("responses.json"))
        let script = root.appendingPathComponent("server.py")
        try Data(Self.python.utf8).write(to: script)
        process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/python3"); process.arguments = [script.path, root.path]
        process.standardOutput = FileHandle.nullDevice
        let errorLog = root.appendingPathComponent("server-error.log")
        _ = FileManager.default.createFile(atPath: errorLog.path, contents: nil)
        process.standardError = try FileHandle(forWritingTo: errorLog)
        // Register before launch so an already-exited child cannot lose the
        // completion notification. Do not waitUntilExit on a cooperative task:
        // Foundation may otherwise wait on an already-consumed run-loop event.
        let completion = termination
        let receipt = root.appendingPathComponent("termination.json")
        process.terminationHandler = { child in
            let value: [String: Int] = ["pid": Int(child.processIdentifier), "status": Int(child.terminationStatus)]
            if let data = try? JSONEncoder().encode(value) { try? data.write(to: receipt, options: .atomic) }
            completion.finish()
        }
        try process.run()
        let ready = root.appendingPathComponent("port"), deadline = Date().addingTimeInterval(5)
        var readyPort: Int?
        while process.isRunning, Date() < deadline {
            if let raw = try? String(contentsOf: ready, encoding: .utf8),
               let number = Int(raw), (1...65_535).contains(number) {
                readyPort = number
                break
            }
            Thread.sleep(forTimeInterval: 0.002)
        }
        guard process.isRunning, let number = readyPort else {
            if process.isRunning { process.terminate() }; throw FixtureTimeout()
        }
        port = number
    }
    deinit { stop() }
    func stop() { if termination.requestStop(), process.isRunning { process.terminate() } }
    func stopAndWait() async { stop(); await termination.wait() }
    func url(_ path: String = "/image") -> URL { URL(string: "http://127.0.0.1:\(port)\(path)")! }
    func release(_ gate: String) throws { try Data().write(to: root.appendingPathComponent("release-" + gate)) }
    func requests() throws -> [Request] { try lines("requests.jsonl", as: Request.self) }
    func finished() throws -> [Finished] { try lines("finished.jsonl", as: Finished.self) }
    private func lines<T: Decodable>(_ file: String, as: T.Type) throws -> [T] {
        guard let data = try? Data(contentsOf: root.appendingPathComponent(file)) else { return [] }
        return try data.split(separator: 10).map { try JSONDecoder().decode(T.self, from: Data($0)) }
    }
    func originalFiles() throws -> [URL] { (try? FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("cache/Originals"), includingPropertiesForKeys: nil)) ?? [] }
    func waitForRequests(_ count: Int) async throws {
        for _ in 0..<1_000 { if try requests().count >= count { return }; try await Task.sleep(for: .milliseconds(2)) }
        throw FixtureTimeout()
    }
    func waitForFinished(path: String) async throws {
        for _ in 0..<1_000 { if try finished().contains(where: { $0.path == path }) { return }; try await Task.sleep(for: .milliseconds(2)) }
        throw FixtureTimeout()
    }
    private static let python = #"""
import base64, gzip, json, pathlib, threading, time, sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from email.utils import formatdate
root = pathlib.Path(sys.argv[1])
responses = json.loads((root / "responses.json").read_text())
counts, lock = {}, threading.Lock()
def append(name, value):
    with lock:
        with (root / name).open("a") as handle:
            handle.write(json.dumps(value) + "\n"); handle.flush()
class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self, *args): pass
    def do_GET(self):
        append("requests.jsonl", {"path": self.path, "headers": {k.lower(): v for k, v in self.headers.items()}})
        with lock:
            index = counts.get(self.path, 0); counts[self.path] = index + 1
            values = responses.get(self.path, [])
            response = values[index] if index < len(values) else {"status": 500, "headers": {}, "body": ""}
        gate = response.get("gate")
        if gate:
            deadline = time.monotonic() + 5
            while not (root / ("release-" + gate)).exists() and time.monotonic() < deadline: time.sleep(.002)
        body, sent = base64.b64decode(response.get("body", "")), 0
        if response.get("gzip"): body = gzip.compress(body, mtime=0)
        try:
            self.send_response_only(response.get("status", 200)); headers = response.get("headers", {})
            if not any(k.lower() == "date" for k in headers): self.send_header("Date", formatdate(usegmt=True))
            for name, value in headers.items(): self.send_header(name, value)
            if response.get("chunked"): self.send_header("Transfer-Encoding", "chunked")
            else: self.send_header("Content-Length", str(len(body)))
            self.send_header("Connection", "close"); self.end_headers()
            for offset in range(0, len(body), 1024):
                part = body[offset:offset+1024]
                self.wfile.write(("%x\r\n" % len(part)).encode() + part + b"\r\n" if response.get("chunked") else part)
                self.wfile.flush(); sent += len(part)
                if response.get("paced"): time.sleep(.001)
            if response.get("chunked"): self.wfile.write(b"0\r\n\r\n"); self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError): pass
        finally:
            append("finished.jsonl", {"path": self.path, "bytes": sent}); self.close_connection = True
server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
port_pending = root / "port.pending"
port_pending.write_text(str(server.server_port))
port_pending.replace(root / "port")
server.serve_forever()
"""#
}

/// Test-child completion only. The NSLock protects a few values and is never
/// held while waiting, launching a process, signalling it, or resuming a task.
private final class ImageFixtureTermination: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    private var stopRequested = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func requestStop() -> Bool {
        lock.withLock {
            guard !finished, !stopRequested else { return false }
            stopRequested = true
            return true
        }
    }
    func finish() {
        let pending = lock.withLock {
            finished = true
            let pending = waiters
            waiters.removeAll()
            return pending
        }
        for continuation in pending { continuation.resume() }
    }
    func wait() async {
        await withCheckedContinuation { continuation in
            let complete = lock.withLock {
                if finished { return true }
                waiters.append(continuation)
                return false
            }
            if complete { continuation.resume() }
        }
    }
}
