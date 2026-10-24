import CoreGraphics
import Foundation
import GlowroomCore
import Testing
@testable import Glowroom

@Suite("Exact adjusted preview frames", .serialized, .timeLimit(.minutes(1)))
struct AdjustedPreviewFrameTests {
    @Test func framePairsTheActualFloatProxyWithItsRenderedOutputAndSharesLiveCacheInput() async throws {
        let observed = TestStateSignal<[UUID]>([])
        let pipeline = AdjustedPreviewPipeline(maximumConcurrentRenders: 1, renderer: { input, _ in
            observed.update { $0.append(input.rangeSourceIdentity) }
            return try Self.bitmap(width: input.image.width, height: input.image.height, fill: 90)
        })
        let source = try Self.bitmap(width: 96, height: 64)
        let first = try await pipeline.frame(source, request: request, settings: precise,
            maximumOutputPixelSize: 48)
        #expect(first.actualInput.image.width == 48 && first.actualInput.image.height == 32)
        #expect(first.actualInput.image.bitsPerComponent == 32)
        #expect(first.actualInput.sourceLongEdge == source.sourceLongEdge)
        #expect(first.actualInput.image !== source.image)
        #expect(first.output.image !== first.actualInput.image)
        #expect(observed.value == [first.actualInput.rangeSourceIdentity])
        let cached = try await pipeline.frame(source, request: request, settings: precise,
            maximumOutputPixelSize: 48)
        #expect(cached.actualInput.image === first.actualInput.image)
        #expect(cached.output.image === first.output.image)
        #expect(observed.value.count == 1)
        #expect(await pipeline.state().cachedInputCount == 1)
        withExtendedLifetime((first, cached)) {}
    }

    @Test func outputHotCacheDoesNotRetainInputAndMissingInputIsRebuiltWithoutRerendering() async throws {
        let calls = TestStateSignal(0)
        let pipeline = AdjustedPreviewPipeline(maximumConcurrentRenders: 1, renderer: { input, _ in
            calls.update { $0 += 1 }
            return try Self.bitmap(width: input.image.width, height: input.image.height, fill: 90)
        })
        let source = try Self.bitmap(width: 96, height: 64)
        var first: AdjustedPreviewFrame? = try await pipeline.frame(source, request: request,
            settings: precise, maximumOutputPixelSize: 48)
        let oldInput = try #require(first).actualInput.image
        let oldInputIdentity = try #require(first).actualInput.rangeSourceIdentity
        let oldOutput = try #require(first).output.image
        first = nil
        try await waitForTestState("LRU has no strong input box", state: { await pipeline.state() }) {
            $0.cachedInputCount == 0 && $0.cachedCount == 1
        }
        let imageOnly = try await pipeline.image(source, request: request, settings: precise,
            maximumOutputPixelSize: 48)
        #expect(imageOnly.image === oldOutput)
        #expect(await pipeline.state().cachedInputCount == 0, "Thumbnail cache hits never reconstruct the proxy")
        let rebuilt = try await pipeline.frame(source, request: request, settings: precise,
            maximumOutputPixelSize: 48)
        #expect(rebuilt.output.image === oldOutput)
        #expect(rebuilt.actualInput.image !== oldInput)
        #expect(rebuilt.actualInput.rangeSourceIdentity == oldInputIdentity)
        #expect(rebuilt.actualInput.image.bitsPerComponent == 32)
        #expect(calls.value == 1, "Only resize runs; the cached edited output is never rendered again")
        #expect(await pipeline.state().cachedInputCount == 1)
        withExtendedLifetime(rebuilt) {}
    }

    @Test func anImageWaiterAndFrameWaiterShareOneJobAndCancellationKeepsItsLane() async throws {
        let gate = PreviewFrameGate()
        defer { gate.release() }
        let pipeline = AdjustedPreviewPipeline(maximumConcurrentRenders: 1, asyncRenderer: { input, _, _ in
            await gate.wait()
            return input
        })
        let source = try Self.bitmap(width: 96, height: 64)
        let image = Task { try await pipeline.image(source, request: request, settings: precise,
            maximumOutputPixelSize: 48) }
        defer { image.cancel() }
        try await waitForTestState("image job entered renderer", state: { gate.starts.value }) { $0 == 1 }
        let frame = Task { try await pipeline.frame(source, request: request, settings: precise,
            maximumOutputPixelSize: 48) }
        defer { frame.cancel() }
        try await waitForTestState("frame joins image job", state: { await pipeline.state() }) { $0.waiterCount == 2 }
        image.cancel()
        do { _ = try await image.value; Issue.record("cancelled image waiter completed") }
        catch is CancellationError { }
        #expect(await pipeline.state().runningBackground == 1)
        #expect(await pipeline.state().waiterCount == 1)
        gate.release()
        let result = try await frame.value
        #expect(result.actualInput.image === result.output.image)
        #expect(result.actualInput.image.width == 48)
        #expect(gate.starts.value == 1)
    }

    @Test func missingWeakInputReconstructionWaitsForTheOccupiedRenderLane() async throws {
        let gate = PreviewFrameGate()
        defer { gate.release() }
        let calls = TestStateSignal(0)
        let pipeline = AdjustedPreviewPipeline(maximumConcurrentRenders: 1, asyncRenderer: { input, settings, _ in
            calls.update { $0 += 1 }
            if settings.exposure == 1 { await gate.wait() }
            return try Self.bitmap(width: input.image.width, height: input.image.height)
        })
        let source = try Self.bitmap(width: 96, height: 64)
        var original: AdjustedPreviewFrame? = try await pipeline.frame(source, request: request,
            settings: precise, maximumOutputPixelSize: 48)
        let cachedOutput = try #require(original).output.image
        original = nil
        try await waitForTestState("input box expired before lane test", state: { await pipeline.state() }) {
            $0.cachedInputCount == 0 && $0.cachedCount == 1
        }
        var occupyingSettings = precise
        occupyingSettings.exposure = 1
        let occupyingSnapshot = occupyingSettings
        let occupant = Task { try await pipeline.image(source, request: request, settings: occupyingSnapshot,
            maximumOutputPixelSize: 48) }
        defer { occupant.cancel() }
        try await waitForTestState("other image occupies lane", state: { gate.starts.value }) { $0 == 1 }
        let reconstruction = Task { try await pipeline.frame(source, request: request, settings: precise,
            maximumOutputPixelSize: 48) }
        defer { reconstruction.cancel() }
        try await waitForTestState("input reconstruction queues in existing lane", state: { await pipeline.state() }) {
            $0.runningBackground == 1 && $0.runningSelected == 0 && $0.queuedCount == 1 && $0.waiterCount == 2
        }
        #expect(calls.value == 2)
        gate.release()
        _ = try await occupant.value
        let rebuilt = try await reconstruction.value
        #expect(rebuilt.output.image === cachedOutput)
        #expect(rebuilt.actualInput.image.width == 48)
        #expect(calls.value == 2)
    }

    @Test func expiredAliasBoxReusesTheSameNativeOutputWithoutAnotherProxyOrReservation() async throws {
        let resources = ArtifactResourceOwner(limits: try .init(maximumBytes: 1_000_000))
        let source = try await ownedSource(width: 128, height: 96, resources: resources)
        let calls = TestStateSignal(0)
        let pipeline = AdjustedPreviewPipeline(renderer: { input, _ in calls.update { $0 += 1 }; return input })
        let previewRequest = try artifactRequest
        var original: AdjustedPreviewFrame? = try await pipeline.frame(source, request: previewRequest,
            settings: precise, maximumOutputPixelSize: 64)
        let output = try #require(original).output
        original = nil
        try await waitForTestState("aliased input box expires", state: { await pipeline.state() }) {
            $0.cachedInputCount == 0 && $0.cachedCount == 1
        }
        try await waitForTestState("alias phase completes", state: { await resources.state() }) { $0.runningCodecs == 0 }
        let state = await resources.state()
        let cached = try await pipeline.frame(source, request: previewRequest, settings: precise, maximumOutputPixelSize: 64)
        #expect(cached.actualInput.image === output.image)
        #expect(cached.output.image === output.image)
        #expect(cached.actualInput.memoryOwnership === output.memoryOwnership)
        #expect(cached.output.memoryOwnership === output.memoryOwnership)
        #expect(await resources.state() == state)
        #expect(calls.value == 1)
        withExtendedLifetime(cached) {}
    }

    @Test func cacheSeparatesActualRasterIdentityResolutionAndWorkingPrecision() async throws {
        let calls = TestStateSignal(0)
        let pipeline = AdjustedPreviewPipeline(maximumConcurrentRenders: 1, renderer: { input, _ in
            calls.update { $0 += 1 }; return input
        })
        let source = try Self.bitmap(width: 96, height: 64)
        let changedRaster = PreviewBitmap(image: source.image, sourceLongEdge: source.sourceLongEdge)
        let first = try await pipeline.frame(source, request: request, settings: precise, maximumOutputPixelSize: 48)
        let second = try await pipeline.frame(changedRaster, request: request, settings: precise, maximumOutputPixelSize: 48)
        let smaller = try await pipeline.frame(source, request: request, settings: precise, maximumOutputPixelSize: 24)
        let legacy = try await pipeline.frame(source, request: request, settings: .init(exposure: 0.5), maximumOutputPixelSize: 48)
        #expect(calls.value == 4)
        #expect(first.actualInput.rangeSourceIdentity != second.actualInput.rangeSourceIdentity)
        #expect(first.actualInput.rangeSourceIdentity != smaller.actualInput.rangeSourceIdentity)
        #expect(first.actualInput.rangeSourceIdentity != legacy.actualInput.rangeSourceIdentity)
        #expect(legacy.actualInput.image.bitsPerComponent == 8)
        withExtendedLifetime((first, second, smaller, legacy)) {}
    }

    @Test func neutralSameSizeFrameAliasesTheDecodedSourceWithoutRenderOrAdmission() async throws {
        let resources = ArtifactResourceOwner(limits: try .init(maximumBytes: 32_768))
        let source = try await ownedSource(width: 32, height: 24, resources: resources)
        let before = await resources.state()
        let calls = TestStateSignal(0)
        let pipeline = AdjustedPreviewPipeline(renderer: { input, _ in calls.update { $0 += 1 }; return input })
        let frame = try await pipeline.frame(source, request: artifactRequest, settings: .neutral)
        #expect(frame.actualInput.image === source.image && frame.output.image === source.image)
        #expect(frame.actualInput.memoryOwnership === source.memoryOwnership)
        #expect(frame.output.memoryOwnership === source.memoryOwnership)
        #expect(await resources.state() == before)
        #expect(calls.value == 0)
        withExtendedLifetime(frame) {}
    }

    @Test func artifactProxyAndOutputProvidersRemainChargedWithoutTheirFrameOrCache() async throws {
        let resources = ArtifactResourceOwner(limits: try .init(maximumBytes: 1_000_000))
        var source: PreviewBitmap? = try await ownedSource(width: 128, height: 96, resources: resources)
        let pipeline = AdjustedPreviewPipeline(renderer: { input, _ in
            try Self.bitmap(width: input.image.width, height: input.image.height)
        })
        var frame: AdjustedPreviewFrame? = try await pipeline.frame(try #require(source), request: artifactRequest,
            settings: precise, maximumOutputPixelSize: 64)
        var nativeInput: CGImage? = try #require(frame).actualInput.image
        var nativeOutput: CGImage? = try #require(frame).output.image
        let inputBytes = Int64(try #require(frame).actualInput.byteCost) * 2
        let outputBytes = Int64(try #require(frame).output.byteCost) * 2
        #expect(try #require(frame).actualInput.memoryOwnership?.byteCount == inputBytes)
        #expect(try #require(frame).output.memoryOwnership?.byteCount == outputBytes)
        #expect(try #require(frame).actualInput.memoryOwnership !== source?.memoryOwnership)
        #expect(try #require(frame).actualInput.memoryOwnership !== frame?.output.memoryOwnership)
        frame = nil
        await pipeline.retireArtifactCaches()
        source = nil
        try await waitForTestState("native input and output own both reservations", state: { await resources.state() }) {
            $0.chargedBytes == inputBytes + outputBytes && $0.retainedAllocations == 2 && $0.runningCodecs == 0
        }
        withExtendedLifetime(nativeInput) {}
        nativeInput = nil
        try await waitForTestState("native input reservation released", state: { await resources.state() }) {
            $0.chargedBytes == outputBytes && $0.retainedAllocations == 1
        }
        withExtendedLifetime(nativeOutput) {}
        nativeOutput = nil
        try await waitForTestState("all frame providers released", state: { await resources.state() }) { $0.chargedBytes == 0 }
    }

    @Test func resizedAliasUsesOneReservationAndNextSliderFitsWhileTheOldFrameLives() async throws {
        let resources = ArtifactResourceOwner(limits: try .init(maximumBytes: 1_000_000))
        let source = try await ownedSource(width: 128, height: 96, resources: resources)
        let pipeline = AdjustedPreviewPipeline(renderer: { input, _ in input })
        let first = try await pipeline.frame(source, request: artifactRequest, settings: precise)
        #expect(first.actualInput.image.width < source.image.width)
        #expect(first.actualInput.image === first.output.image)
        #expect(first.actualInput.memoryOwnership === first.output.memoryOwnership)
        try await waitForTestState("one proxy allocation after aliased render", state: { await resources.state() }) {
            $0.retainedAllocations == 2 && $0.runningCodecs == 0
        }
        var nextSettings = precise
        nextSettings.exposure = 0.75
        let second = try await pipeline.frame(source, request: artifactRequest, settings: nextSettings)
        #expect(second.actualInput.image.width == first.actualInput.image.width)
        #expect(second.output.memoryOwnership !== first.output.memoryOwnership)
        #expect(await resources.state().chargedBytes <= resources.limits.maximumBytes)
        withExtendedLifetime((first, second)) {}
    }

    @Test(arguments: [false, true])
    func finiteArtifactBudgetPlansPureLegacyRenderAndNeutralResizeWithoutLocalWork(neutralResize: Bool) async throws {
        let resources = ArtifactResourceOwner(limits: try .init(maximumBytes: 1_000_000))
        let source = try await ownedSource(width: 128, height: 96, resources: resources)
        let calls = TestStateSignal(0)
        let pipeline = AdjustedPreviewPipeline(renderer: { input, _ in
            calls.update { $0 += 1 }; return input
        })
        let settings = neutralResize ? EditSettings.neutral : EditSettings(exposure: 0.5)
        let frame = try await pipeline.frame(source, request: artifactRequest, settings: settings,
            maximumOutputPixelSize: neutralResize ? 64 : nil)
        if neutralResize { #expect(frame.actualInput.image.width == 64) }
        else { #expect(frame.actualInput.image.width < 128, "A finite budget applies without any local or spatial adjustments") }
        #expect(frame.output.image === frame.actualInput.image)
        #expect(calls.value == (neutralResize ? 0 : 1))
        #expect(await resources.state().chargedBytes <= resources.limits.maximumBytes)
        withExtendedLifetime(frame) {}
    }

    private var precise: EditSettings { .init(exposure: 0.5, toneProcessingVersion: .consistentV2) }
    private var request: PreviewRequest {
        .init(url: URL(fileURLWithPath: "/synthetic/frame.png"), modifiedAt: .distantPast,
              pixelSize: 512, allowsEmbeddedPreview: false)
    }
    private var artifactRequest: PreviewRequest {
        get throws {
            let digest = try ArtifactDigest(sha256: String(repeating: "a", count: 64))
            let format = ArtifactRasterFormat(size: try .init(width: 128, height: 96), bitDepth: .eight,
                channels: .rgba, profile: .sRGB, iccSHA256: digest)
            let raster = RasterDescriptor(format: format, file: try .init(sha256: digest, bytes: 64))
            return PreviewRequest(source: .artifact(.init(storeID: .init(), artifactID: .init(),
                manifestSHA256: digest, raster: raster)), pixelSize: 512)
        }
    }
    private func ownedSource(width: Int, height: Int, resources: ArtifactResourceOwner) async throws -> PreviewBitmap {
        let bitmap = try Self.bitmap(width: width, height: height)
        let bytes = Int64(bitmap.byteCost) * 2
        var phase: ArtifactResourceLease? = try await resources.acquire(kind: .retainedMemory, bytes: bytes,
            priority: .interactive, retaining: [])
        let memory = try await resources.retain(bytes: bytes, from: #require(phase))
        let result = try bitmap.retainingArtifactMemory(memory, owner: resources)
        phase = nil
        try await waitForTestState("decoded frame source ownership established", state: { await resources.state() }) {
            $0.chargedBytes == bytes && $0.runningCodecs == 0
        }
        return result
    }
    private static func bitmap(width: Int, height: Int, fill: UInt8 = 160) throws -> PreviewBitmap {
        let data = Data(repeating: fill, count: width * height * 4)
        let image = try #require(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: CGDataProvider(data: data as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        return PreviewBitmap(image: image)
    }
}

private final class PreviewFrameGate: @unchecked Sendable {
    let starts = TestStateSignal(0)
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false

    func wait() async {
        starts.update { $0 += 1 }
        await withCheckedContinuation { continuation in
            lock.lock()
            if released { lock.unlock(); continuation.resume() }
            else { self.continuation = continuation; lock.unlock() }
        }
    }
    func release() {
        lock.lock()
        released = true
        let waiting = continuation
        continuation = nil
        lock.unlock()
        waiting?.resume()
    }
}
