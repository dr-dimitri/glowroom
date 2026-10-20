import CoreGraphics
import Foundation
import Testing
@testable import PicEdit
import PicEditCore

@Suite("Artifact preview identity and real native ownership", .serialized)
struct ArtifactPreviewOwnershipTests {
    @Test func bitmapProviderKeepsReservationAfterBitmapAndPhaseAreReleased() async throws {
        let resources = ArtifactResourceOwner(limits: try .init(maximumBytes: 4_096))
        var phase: ArtifactResourceLease? = try await resources.acquire(kind: .codec, bytes: 1_024, priority: .interactive, retaining: [])
        let context = try #require(CGContext(data: nil, width: 3, height: 2, bitsPerComponent: 8, bytesPerRow: 12,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 0.5)); context.fill(CGRect(x: 0, y: 0, width: 3, height: 2))
        let base = PreviewBitmap(image: try #require(context.makeImage()), sourceLongEdge: 300)
        var memory: ArtifactMemoryReservation? = try await resources.retain(bytes: Int64(base.byteCost) * 2, from: try #require(phase))
        var bitmap: PreviewBitmap? = try base.retainingArtifactMemory(try #require(memory), owner: resources)
        #expect(bitmap?.sourceLongEdge == 300)
        #expect(bitmap?.sourcePixelScale == 0.01)
        var nativeImage: CGImage? = bitmap?.image
        memory = nil; bitmap = nil; phase = nil
        let live = await resources.state()
        #expect(live.chargedBytes >= Int64(base.byteCost) * 2)
        #expect(live.retainedAllocations == 1)
        #expect(nativeImage?.width == 3 && nativeImage?.height == 2)
        withExtendedLifetime(nativeImage) {}
        nativeImage = nil
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while await resources.state().chargedBytes != 0 {
            guard ContinuousClock.now < deadline else { Issue.record("native ownership leaked"); return }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await resources.state().retainedAllocations == 0)
    }
    @Test func sourceAndStoreAndRasterAreAllPreviewIdentityAndResizePreservesFreshness() throws {
        let hash = try ArtifactDigest(sha256: String(repeating: "a", count: 64)), otherHash = try ArtifactDigest(sha256: String(repeating: "b", count: 64))
        let format = ArtifactRasterFormat(size: try .init(width: 1_024, height: 512), bitDepth: .sixteen, channels: .rgba, profile: .displayP3, iccSHA256: hash)
        let raster = RasterDescriptor(format: format, file: try .init(sha256: hash, bytes: 2_000))
        let store = ArtifactStoreID(), id = GeneratedArtifactID()
        let fingerprint = ArtifactSourceFingerprint(storeID: store, artifactID: id, manifestSHA256: hash, raster: raster)
        let full = PreviewRequest(source: .artifact(fingerprint), pixelSize: 2_400, sourceRevision: "explicit-refresh")
        let small = full.resized(to: 512)
        #expect(small.source == full.source && small.sourceRevision == full.sourceRevision)
        #expect(small.url == nil && !small.allowsEmbeddedPreview)
        #expect(small.hasSameOriginal(as: full))
        let changedStore = PreviewRequest(source: .artifact(.init(storeID: .init(), artifactID: id, manifestSHA256: hash, raster: raster)), pixelSize: 512)
        let changedManifest = PreviewRequest(source: .artifact(.init(storeID: store, artifactID: id, manifestSHA256: otherHash, raster: raster)), pixelSize: 512)
        let original = PreviewRequest(url: URL(fileURLWithPath: "/synthetic/original.RAW"), modifiedAt: .distantPast, pixelSize: 512, fileSize: 2_000)
        #expect(!small.hasSameOriginal(as: changedStore))
        #expect(!small.hasSameOriginal(as: changedManifest))
        #expect(!small.hasSameOriginal(as: original))
    }
}
