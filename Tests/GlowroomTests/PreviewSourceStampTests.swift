import CoreGraphics
import Foundation
import GlowroomCore
import Testing
@testable import Glowroom

@Suite("Preview native source revisions", .timeLimit(.minutes(1)))
struct PreviewSourceStampTests {
    @Test func sameSizeReplacementWithRestoredDateChangesTheDecodeCacheIdentity() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Glowroom-PreviewStamp-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("source.png")
        try Data([1, 2, 3, 4]).write(to: url)
        let date = try #require(FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)
        let request = PreviewRequest(url: url, modifiedAt: date, pixelSize: 2_400, fileSize: 4,
            allowsEmbeddedPreview: false)
        let before = try await PreviewSourceStamp.capture(for: request)
        let beforeRequest = PreviewSourceStamp.stampedRequest(request, stamp: before)
        let probe = PreviewStampDecodeProbe()
        let pipeline = ImagePreviewPipeline(asyncDecoder: { try await probe.decode($0) })
        let first = try await pipeline.image(for: beforeRequest, priority: .selected)
        let cached = try await pipeline.image(for: beforeRequest, priority: .selected)
        #expect(first.image === cached.image)
        #expect(await probe.calls == 1)
        try Data([4, 3, 2, 1]).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
        let after = try await PreviewSourceStamp.capture(for: request)
        let afterRequest = PreviewSourceStamp.stampedRequest(request, stamp: after)
        #expect(before != after)
        #expect(beforeRequest != afterRequest)
        #expect(!beforeRequest.hasSameOriginal(as: afterRequest))
        #expect(beforeRequest.source == afterRequest.source, "The native revision distinguishes identical catalog metadata")
        let replacement = try await pipeline.image(for: afterRequest, priority: .selected)
        #expect(await probe.calls == 2, "A replacement must not reuse the decoded raster under the old native revision")
        #expect(first.rangeSourceIdentity != replacement.rangeSourceIdentity)
        #expect((first.image.dataProvider?.data as Data?) != (replacement.image.dataProvider?.data as Data?))
        #expect(try Data(contentsOf: url) == Data([4, 3, 2, 1]))
    }

    @Test(arguments: [false, true])
    func stampingPreservesDecodePolicyAndExplicitRefreshRevision(hdr: Bool) throws {
        let source = AISourceIdentity.original(.init(fileURL: URL(fileURLWithPath: "/synthetic/source.RAW"),
            modifiedAt: Date(timeIntervalSince1970: 12), fileSize: 123))
        let request = PreviewRequest(source: source, pixelSize: 2_400, allowsEmbeddedPreview: true,
            sourceRevision: "explicit-refresh|42", allowsHDR: hdr)
        let stamp = ImageAnalysisSourceStamp(device: 1, inode: 2, byteCount: 123,
            modifiedSeconds: 12, modifiedNanoseconds: 0, changedSeconds: 15, changedNanoseconds: 0)
        let stamped = PreviewSourceStamp.stampedRequest(request, stamp: stamp)
        #expect(stamped.source == request.source && stamped.pixelSize == request.pixelSize)
        #expect(stamped.allowsHDR == request.allowsHDR && stamped.allowsEmbeddedPreview == request.allowsEmbeddedPreview)
        #expect(stamped.sourceRevision == stamp.cacheRevision + "|explicit-refresh|42")
        #expect(stamped.resized(to: 512).sourceRevision == stamped.sourceRevision)
        let ordinary = PreviewRequest(source: source, pixelSize: 512)
        #expect(PreviewSourceStamp.stampedRequest(ordinary, stamp: stamp).sourceRevision == stamp.cacheRevision)
    }

    @Test func immutableArtifactStampNeedsNoOriginalFile() async throws {
        let digest = try ArtifactDigest(sha256: String(repeating: "a", count: 64))
        let format = ArtifactRasterFormat(size: try .init(width: 64, height: 64), bitDepth: .sixteen,
            channels: .rgba, profile: .displayP3, iccSHA256: digest)
        let raster = RasterDescriptor(format: format, file: try .init(sha256: digest, bytes: 123))
        let source = ArtifactSourceFingerprint(storeID: .init(), artifactID: .init(), manifestSHA256: digest, raster: raster)
        let request = PreviewRequest(source: .artifact(source), pixelSize: 2_400, sourceRevision: "refresh", allowsHDR: true)
        let stamp = try await PreviewSourceStamp.capture(for: request)
        #expect(stamp == .artifact(source))
        let stamped = PreviewSourceStamp.stampedRequest(request, stamp: stamp)
        #expect(stamped.url == nil && stamped.allowsHDR && !stamped.allowsEmbeddedPreview)
        #expect(stamped.sourceRevision == stamp.cacheRevision + "|refresh")
    }

    @Test func changedCatalogMetadataAndMissingSourcesRejectInsteadOfReusingPixels() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Glowroom-PreviewStamp-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("source.png")
        try Data([1, 2, 3, 4]).write(to: url)
        let date = try #require(FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)
        let wrongSize = PreviewRequest(url: url, modifiedAt: date, pixelSize: 512, fileSize: 5)
        await #expect(throws: ImageAnalysisError.staleSource) { try await PreviewSourceStamp.capture(for: wrongSize) }
        let wrongDate = PreviewRequest(url: url, modifiedAt: date.addingTimeInterval(1), pixelSize: 512, fileSize: 4)
        await #expect(throws: ImageAnalysisError.staleSource) { try await PreviewSourceStamp.capture(for: wrongDate) }
        let request = PreviewRequest(url: url, modifiedAt: date, pixelSize: 512, fileSize: 4)
        try FileManager.default.removeItem(at: url)
        await #expect(throws: ImageAnalysisError.staleSource) { try await PreviewSourceStamp.capture(for: request) }
    }

    @Test func cancelledPreviewDoesNotInspectAnObsoleteSource() async throws {
        let request = PreviewRequest(url: URL(fileURLWithPath: "/missing-cancelled-preview.png"),
            modifiedAt: .distantPast, pixelSize: 512)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await PreviewSourceStamp.capture(for: request)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}

private actor PreviewStampDecodeProbe {
    private(set) var calls = 0
    func decode(_ request: PreviewRequest) throws -> PreviewBitmap {
        calls += 1
        let url = try #require(request.url)
        let bytes = try Data(contentsOf: url)
        let color = try #require(bytes.first)
        let pixels = Data([color, 0, 0, 255])
        let provider = try #require(CGDataProvider(data: pixels as CFData))
        let image = try #require(CGImage(width: 1, height: 1, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue), provider: provider,
            decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        return PreviewBitmap(image: image)
    }
}
