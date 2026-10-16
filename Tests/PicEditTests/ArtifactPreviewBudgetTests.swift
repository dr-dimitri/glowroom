import CoreGraphics
import Foundation
import PicEditCore
import Testing
@testable import PicEdit

@Suite("Artifact preview bounded admission", .serialized, .timeLimit(.minutes(1)))
struct ArtifactPreviewBudgetTests {
    @Test func twoEightBit4096PreviewsFitWhileSixteenBitNeedsRetiredCacheOwnership() async throws {
        let resources = ArtifactResourceOwner(limits: try .init())
        // Two existing 2400 RGBA8 images (base + adjusted), each retaining its
        // real image/provider-copy cost. These are capabilities, no 4K allocation.
        let oldBytes: Int64 = 2 * 2 * 2_400 * 2_400 * 4
        var allocation: ArtifactResourceLease? = try await resources.acquire(kind: .retainedMemory, bytes: oldBytes, priority: .interactive, retaining: [])
        var old: ArtifactMemoryReservation? = try await resources.retain(bytes: oldBytes, from: #require(allocation))
        allocation = nil
        let eight = try ArtifactPreviewBudget(format: format(bits: .eight), pixelSize: 2_400)
        #expect(eight.nativeBytes == 67_108_864)
        #expect(eight.outputBytes == 23_347_200)
        #expect(eight.peakBytes == 248_086_528)
        var phase: ArtifactResourceLease? = try await resources.acquire(kind: .codec, bytes: eight.peakBytes, priority: .interactive, retaining: old.map { [$0] } ?? [])
        #expect(await resources.state().chargedBytes == oldBytes + eight.peakBytes)
        phase = nil
        try await wait { await resources.state().runningCodecs == 0 }
        let sixteen = try ArtifactPreviewBudget(format: format(bits: .sixteen), pixelSize: 2_400)
        #expect(sixteen.nativeBytes == 134_217_728)
        #expect(sixteen.retiresOtherCaches)
        await #expect(throws: ArtifactResourceError.capacityExceeded) {
            _ = try await resources.acquire(kind: .codec, bytes: sixteen.peakBytes, priority: .interactive, retaining: old.map { [$0] } ?? [])
        }
        #expect(await resources.state().chargedBytes == oldBytes)
        old = nil
        try await wait { await resources.state().chargedBytes == 0 }
        phase = try await resources.acquire(kind: .codec, bytes: sixteen.peakBytes, priority: .interactive, retaining: [])
        #expect(await resources.state().chargedBytes == sixteen.peakBytes)
        withExtendedLifetime(phase) {}
    }

    @Test func rgbUsesFourNativeChannelsAndStrideIsAlignedAndActualOutputIsChecked() throws {
        let rgb = try ArtifactPreviewBudget(format: format(bits: .eight, channels: .rgb), pixelSize: 2_400)
        let rgba = try ArtifactPreviewBudget(format: format(bits: .eight), pixelSize: 2_400)
        #expect(rgb.nativeBytes == rgba.nativeBytes && rgb.outputBytes == rgba.outputBytes)
        let odd = try ArtifactPreviewBudget(format: format(bits: .eight, width: 257, height: 129), pixelSize: 64)
        #expect(odd.nativeBytes == 1_280 * 129)
        #expect(odd.outputBytes == 256 * 64)
        let padded = Data(count: 32_768)
        let image = try #require(CGImage(width: 2, height: 2, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: 16_384, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: CGDataProvider(data: padded as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        #expect(throws: (any Error).self) { try odd.validate(PreviewBitmap(image: image)) }
    }

    @Test func boundedRetryReportsLiveReadersWithoutDroppingTheirReservation() async throws {
        let resources = ArtifactResourceOwner(limits: try .init(maximumBytes: 1_024))
        var phase: ArtifactResourceLease? = try await resources.acquire(kind: .retainedMemory, bytes: 1_024, priority: .interactive, retaining: [])
        let reader = try await resources.retain(bytes: 1_024, from: #require(phase))
        phase = nil
        let attempts = BudgetAttempts()
        await #expect(throws: ArtifactPreviewFailure.resourcesBusy) {
            _ = try await ArtifactPreviewAdmission.perform(retireCaches: { await attempts.retire() }) {
                await attempts.run()
                return try await resources.acquire(kind: .codec, bytes: 1, priority: .interactive, retaining: [reader])
            }
        }
        #expect(await attempts.values() == [3, 2])
        #expect(await resources.state().chargedBytes == 1_024)
        withExtendedLifetime(reader) {}
    }

    @Test func retiringAdjustedCacheCannotReleaseActiveNativeImageOwnership() async throws {
        let resources = ArtifactResourceOwner(limits: try .init(maximumBytes: 65_536))
        let pipeline = AdjustedPreviewPipeline(maximumConcurrentRenders: 1, renderer: { bitmap, _ in bitmap })
        var nativeImage: CGImage? = try await cachedImage(pipeline: pipeline, resources: resources)
        #expect(await pipeline.state().cachedCount == 1)
        await pipeline.retireArtifactCaches()
        #expect(await pipeline.state().cachedCount == 0)
        #expect(await resources.state().chargedBytes > 0)
        withExtendedLifetime(nativeImage) {}
        nativeImage = nil
        try await wait { await resources.state().chargedBytes == 0 }
    }

    @Test func sameSource1536To2400RetiresInsufficientCacheWithoutLargeAllocations() async throws {
        let resources = ArtifactResourceOwner(limits: try .init())
        let pipeline = AdjustedPreviewPipeline(maximumConcurrentRenders: 1, renderer: { bitmap, _ in bitmap })
        let hash = try ArtifactDigest(sha256: String(repeating: "a", count: 64))
        let raster = RasterDescriptor(format: try format(bits: .sixteen), file: try .init(sha256: hash, bytes: 64))
        let full = PreviewRequest(source: .artifact(.init(storeID: .init(), artifactID: .init(), manifestSHA256: hash, raster: raster)), pixelSize: 2_400)
        let small = full.resized(to: 1_536)
        #expect(!small.isAdequateArtifactCache(for: full))
        #expect(full.isAdequateArtifactCache(for: small))
        // Account for the previous base/render pair without allocating the
        // 1536² buffers. The real small CGImage provider owns this conservative
        // reservation until its cache/native owners actually disappear.
        var nativeImage: CGImage? = try await cachedImage(pipeline: pipeline, resources: resources,
            memoryBytes: 2 * 2 * 1_536 * 1_536 * 8, request: small)
        withExtendedLifetime(nativeImage) {}
        nativeImage = nil
        let budget = try ArtifactPreviewBudget(format: raster.format, pixelSize: 2_400)
        await #expect(throws: ArtifactResourceError.capacityExceeded) {
            _ = try await resources.acquire(kind: .codec, bytes: budget.peakBytes, priority: .interactive, retaining: [])
        }
        #expect(await pipeline.state().cachedCount == 1)
        await pipeline.retireArtifactCaches()
        try await wait { await resources.state().chargedBytes == 0 }
        let phase = try await resources.acquire(kind: .codec, bytes: budget.peakBytes, priority: .interactive, retaining: [])
        #expect(await resources.state().chargedBytes == budget.peakBytes)
        withExtendedLifetime(phase) {}
    }

    private func cachedImage(pipeline: AdjustedPreviewPipeline, resources: ArtifactResourceOwner,
        memoryBytes: Int64 = 64, request: PreviewRequest? = nil) async throws -> CGImage {
        var phase: ArtifactResourceLease? = try await resources.acquire(kind: .codec, bytes: max(1_024, memoryBytes), priority: .interactive, retaining: [])
        let memory = try await resources.retain(bytes: memoryBytes, from: #require(phase))
        let data = Data(count: 16)
        let image = try #require(CGImage(width: 2, height: 2, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 8,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: CGDataProvider(data: data as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let source = try PreviewBitmap(image: image).retainingArtifactMemory(memory, owner: resources)
        // Release the input codec slot before the existing render lane needs it.
        phase = nil
        try await wait { await resources.state().runningCodecs == 0 }
        return try await renderCached(source, pipeline: pipeline, supplied: request)
    }
    private func renderCached(_ source: PreviewBitmap, pipeline: AdjustedPreviewPipeline, supplied: PreviewRequest?) async throws -> CGImage {
        let hash = try ArtifactDigest(sha256: String(repeating: "a", count: 64))
        let raster = RasterDescriptor(format: try format(bits: .eight, width: 2, height: 2), file: try .init(sha256: hash, bytes: 64))
        let request = PreviewRequest(source: .artifact(.init(storeID: .init(), artifactID: .init(), manifestSHA256: hash, raster: raster)), pixelSize: 64)
        return try await pipeline.image(source, request: supplied ?? request, settings: EditSettings(exposure: 1)).image
    }
    private func format(bits: ArtifactBitDepth, channels: ArtifactChannels = .rgba, width: Int = 4_096, height: Int = 4_096) throws -> ArtifactRasterFormat {
        ArtifactRasterFormat(size: try .init(width: width, height: height), bitDepth: bits, channels: channels,
            profile: .sRGB, iccSHA256: try .init(sha256: String(repeating: "a", count: 64)))
    }
    private func wait(_ predicate: @escaping @Sendable () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !(await predicate()) {
            guard ContinuousClock.now < deadline else { throw ArtifactPreviewFailure.resourcesBusy }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}
private actor BudgetAttempts {
    private var attempts = 0, retirements = 0
    func run() { attempts += 1 }
    func retire() { retirements += 1 }
    func values() -> [Int] { [attempts, retirements] }
}
