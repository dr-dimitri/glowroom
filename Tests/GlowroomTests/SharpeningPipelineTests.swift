import CoreGraphics
import Foundation
import GlowroomCore
import Testing
@testable import Glowroom

@Suite("Sharpening preview planning and identity", .serialized, .timeLimit(.minutes(1)))
struct SharpeningPipelineTests {
    @Test
    func sharpeningAloneAdaptsLargePreviewAndPreservesSourcePixelRadius() async throws {
        let source = try fixture(width: 4_096, height: 2_304, sourceLongEdge: 8_192)
        let observations = TestStateSignal<[SharpeningObservation]>([])
        let pipeline = AdjustedPreviewPipeline(maximumConcurrentRenders: 1, renderer: { bitmap, settings in
            observations.update { $0.append(.init(bitmap: bitmap, settings: settings)) }
            return bitmap
        })
        let edits = EditSettings(sharpeningAmount: 80, sharpeningRadius: 2, sharpeningMasking: 60)
        let result = try await pipeline.image(source, request: request, settings: edits, priority: .selected)
        let observed = try #require(observations.value.first)
        #expect(observed.width < source.image.width && observed.width >= 64)
        #expect(abs(Double(observed.width) / Double(observed.height) - 16.0 / 9) < 0.01)
        #expect(observed.settings == edits)
        #expect(observed.sourceLongEdge == 8_192)
        #expect(observed.sourcePixelScale == Double(observed.width) / 8_192)
        let sharpeningBytes = UInt64(observed.width * observed.height) * DevelopSharpening.additionalBytesPerPixel(settings: edits)
        #expect(sharpeningBytes <= LocalAdjustmentRenderer.previewWorkingMemoryBudget)
        #expect(result.image.width == observed.width && result.image.height == observed.height)
        var disabled = edits; disabled.sharpeningAmount = 0
        let neutral = try await pipeline.image(source, request: request, settings: disabled)
        #expect(neutral.image === source.image)
        #expect(observations.value.count == 1, "Dormant sharpening must neither render nor lower preview resolution")
    }

    @Test(arguments: [false, true])
    func smallArtifactBudgetIncludesSharpeningAndCombinedSpatialEdits(withLocalAndGeometry: Bool) async throws {
        let resources = ArtifactResourceOwner(limits: try .init(maximumBytes: 3_000_000))
        let input = try fixture(width: 256, height: 128, sourceLongEdge: 512)
        let ownedBytes = Int64(input.byteCost) * 2
        var phase: ArtifactResourceLease? = try await resources.acquire(kind: .retainedMemory,
            bytes: ownedBytes, priority: .interactive, retaining: [])
        let memory = try await resources.retain(bytes: ownedBytes, from: #require(phase))
        let source = try input.retainingArtifactMemory(memory, owner: resources)
        phase = nil
        try await waitForTestState("source phase releases before sharpening admission", state: { await resources.state() }) {
            $0.chargedBytes == ownedBytes && $0.runningCodecs == 0
        }
        let observations = TestStateSignal<[SharpeningObservation]>([])
        let pipeline = AdjustedPreviewPipeline(maximumConcurrentRenders: 1, asyncRenderer: { bitmap, settings, _ in
            let state = await resources.state()
            observations.update { $0.append(.init(bitmap: bitmap, settings: settings, chargedBytes: state.chargedBytes,
                runningCodecs: state.runningCodecs)) }
            return bitmap
        })
        var edits = EditSettings(sharpeningAmount: 80, sharpeningRadius: 2, sharpeningMasking: 60)
        if withLocalAndGeometry {
            edits.localAdjustments = [try LocalAdjustment(name: "Local contrast", mask: .init(shape: .radial(
                center: .init(x: 0.5, y: 0.5), radiusX: 0.3, radiusY: 0.3, rotation: 0)),
                settings: .init(exposure: 0.4, texture: 20))]
            edits.developGeometry = DevelopGeometry(retouchStrokes: [try .init(mode: .clone,
                source: .init(x: 0.2, y: 0.3), target: .init(x: 0.7, y: 0.6), radius: 0.1)])
        }
        let request = try artifactRequest(width: 512, height: 256)
        let result = try await pipeline.image(source, request: request, settings: edits, priority: .selected)
        let observed = try #require(observations.value.first)
        #expect(observed.width < 256 && observed.width >= 64)
        #expect(observed.settings == edits)
        #expect(observed.sourceLongEdge == 512 && result.sourceLongEdge == 512)
        #expect(observed.runningCodecs == 1)
        let local = try #require(LocalAdjustmentRenderer.estimatedAdditionalBytes(adjustments: edits.localAdjustments,
            width: observed.width, height: observed.height))
        let geometry = try #require(DevelopGeometryRenderer.estimatedAdditionalBytes(geometry: edits.developGeometry,
            width: observed.width, height: observed.height))
        let output = UInt64(observed.width * observed.height) * (32 + DevelopSharpening.additionalBytesPerPixel(settings: edits))
        let expected = ownedBytes + Int64(source.byteCost) * 4 + Int64(output + local + geometry)
        #expect(observed.chargedBytes == expected, "Admission must include sharpening in addition to base, masks and geometry")
        #expect(observed.chargedBytes <= resources.limits.maximumBytes)
        var next = edits; next.sharpeningAmount = 120
        _ = try await pipeline.image(source, request: request, settings: next, priority: .selected)
        #expect(observations.value.count == 2)
        #expect(try #require(observations.value.last).chargedBytes <= resources.limits.maximumBytes,
                "The next sharpening value must fit while the preceding native result is still retained")
        withExtendedLifetime(result) {}
    }

    @Test
    func nativeSourceSizeHasSeparateSharpeningCacheIdentity() async throws {
        let source = try fixture(width: 32, height: 24, sourceLongEdge: 32)
        let reduced = PreviewBitmap(image: source.image, sourceLongEdge: 3_200)
        let scales = TestStateSignal<[Double]>([])
        let pipeline = AdjustedPreviewPipeline(maximumConcurrentRenders: 1, renderer: { bitmap, _ in
            scales.update { $0.append(bitmap.sourcePixelScale) }; return bitmap
        })
        let edits = EditSettings(sharpeningAmount: 80)
        let native = try await pipeline.image(source, request: request, settings: edits)
        let preview = try await pipeline.image(reduced, request: request, settings: edits)
        #expect(native.sourceLongEdge == 32 && preview.sourceLongEdge == 3_200)
        _ = try await pipeline.image(source, request: request, settings: edits)
        _ = try await pipeline.image(reduced, request: request, settings: edits)
        #expect(scales.value == [1, 0.01], "Equal raster sizes need distinct radii when their native source sizes differ")
        #expect(await pipeline.state().cachedCount == 2)
    }

    @Test
    func rapidSharpeningAndSourceScaleChangesDiscardObsoleteWorkWithoutReleasingOccupiedSlot() async throws {
        let probe = SharpeningRenderProbe()
        defer { probe.releaseAll() }
        let pipeline = AdjustedPreviewPipeline(maximumConcurrentRenders: 1,
            asyncRenderer: { bitmap, settings, _ in await probe.render(bitmap, settings: settings) })
        let source = try fixture(width: 32, height: 24, sourceLongEdge: 32)
        let changedSource = PreviewBitmap(image: source.image, sourceLongEdge: 3_200)
        let request = self.request
        let first = Task { try await pipeline.image(source, request: request, settings: .init(sharpeningAmount: 40)) }
        defer { first.cancel() }
        try await probe.state.wait("initial sharpening begins") { $0.started == [.init(sourceLongEdge: 32, amount: 40)] }
        first.cancel()
        await expectCancelled(first)
        let obsolete = Task { try await pipeline.image(changedSource, request: request, settings: .init(sharpeningAmount: 80)) }
        defer { obsolete.cancel() }
        try await waitForTestState("changed source queues behind cancelled native work", state: { await pipeline.state() }) {
            $0.runningBackground == 1 && $0.queuedCount == 1 && $0.waiterCount == 1
        }
        obsolete.cancel()
        await expectCancelled(obsolete)
        let latest = Task { try await pipeline.image(changedSource, request: request, settings: .init(sharpeningAmount: 120), priority: .selected) }
        defer { latest.cancel() }
        let shared = Task { try await pipeline.image(changedSource, request: request, settings: .init(sharpeningAmount: 120), priority: .selected) }
        defer { shared.cancel() }
        try await waitForTestState("current sharpening coalesces while old native worker retains its slot", state: { await pipeline.state() }) {
            $0.runningBackground == 1 && $0.runningSelected == 0 && $0.queuedCount == 1 && $0.waiterCount == 2
        }
        #expect(probe.state.value.started.count == 1)
        probe.releaseAll()
        let current = try await latest.value
        _ = try await shared.value
        #expect(current.sourceLongEdge == 3_200)
        #expect(probe.state.value.started == [.init(sourceLongEdge: 32, amount: 40), .init(sourceLongEdge: 3_200, amount: 120)])
        #expect(probe.state.value.maximumActive == 1)
        #expect(await pipeline.state().cachedCount == 1, "Neither cancelled sharpening generation may populate the cache")
    }

    private var request: PreviewRequest {
        PreviewRequest(url: URL(fileURLWithPath: "/synthetic/sharpening-source.jpg"), modifiedAt: .distantPast, pixelSize: 4_096)
    }

    private func artifactRequest(width: Int, height: Int) throws -> PreviewRequest {
        let hash = try ArtifactDigest(sha256: String(repeating: "a", count: 64))
        let format = ArtifactRasterFormat(size: try .init(width: width, height: height), bitDepth: .eight,
            channels: .rgba, profile: .sRGB, iccSHA256: hash)
        let raster = RasterDescriptor(format: format, file: try .init(sha256: hash, bytes: 64))
        return PreviewRequest(source: .artifact(.init(storeID: .init(), artifactID: .init(), manifestSHA256: hash, raster: raster)), pixelSize: 512)
    }

    private func fixture(width: Int, height: Int, sourceLongEdge: Int) throws -> PreviewBitmap {
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        return PreviewBitmap(image: try #require(context.makeImage()), sourceLongEdge: sourceLongEdge)
    }

    private func expectCancelled(_ task: Task<PreviewBitmap, Error>) async {
        do { _ = try await task.value; Issue.record("Cancelled sharpening waiter received a bitmap") }
        catch is CancellationError {} catch { Issue.record("Unexpected cancellation error: \(error)") }
    }
}

private struct SharpeningObservation: Sendable {
    let width: Int
    let height: Int
    let sourceLongEdge: Int
    let sourcePixelScale: Double
    let settings: EditSettings
    let chargedBytes: Int64
    let runningCodecs: Int
    init(bitmap: PreviewBitmap, settings: EditSettings, chargedBytes: Int64 = 0, runningCodecs: Int = 0) {
        width = bitmap.image.width; height = bitmap.image.height
        sourceLongEdge = bitmap.sourceLongEdge; sourcePixelScale = bitmap.sourcePixelScale
        self.settings = settings; self.chargedBytes = chargedBytes; self.runningCodecs = runningCodecs
    }
}

private struct SharpeningRenderID: Equatable, Sendable {
    let sourceLongEdge: Int
    let amount: Double
}

private struct SharpeningRenderProbeState: Sendable {
    var started: [SharpeningRenderID] = []
    var active = 0
    var maximumActive = 0
}

private final class SharpeningRenderProbe: Sendable {
    let state = TestStateSignal(SharpeningRenderProbeState())
    private let gate = TestAsyncLatch()
    func releaseAll() { gate.releaseAll() }
    func render(_ bitmap: PreviewBitmap, settings: EditSettings) async -> PreviewBitmap {
        state.update {
            $0.started.append(.init(sourceLongEdge: bitmap.sourceLongEdge, amount: settings.sharpeningAmount))
            $0.active += 1; $0.maximumActive = max($0.maximumActive, $0.active)
        }
        defer { state.update { $0.active -= 1 } }
        // Native work can ignore cancellation until returning; hold its lane.
        await gate.wait()
        return bitmap
    }
}
