import CoreGraphics
import Foundation
import GlowroomCore
import Testing
@testable import Glowroom

@Suite("Adjusted preview scheduling")
struct AdjustedPreviewPipelineTests {
    @Test
    func selectedEditRunsBeforeQueuedThumbnails() async throws {
        let probe = RenderProbe()
        defer { probe.releaseAll() }
        let pipeline = AdjustedPreviewPipeline(maximumConcurrentRenders: 1,
            asyncRenderer: { bitmap, settings, _ in try await probe.render(bitmap, settings: settings) })
        let source = try fixture()
        let first = Task { try await pipeline.image(source, request: request, settings: settings(1)) }
        defer { first.cancel() }
        try await probe.state.wait("first thumbnail started") { $0.started == [1] }
        let thumbnail = Task { try await pipeline.image(source, request: request, settings: settings(2)) }
        defer { thumbnail.cancel() }
        let selected = Task { try await pipeline.image(source, request: request, settings: settings(3), priority: .selected) }
        defer { selected.cancel() }
        // Both callers must have reached the actor before the first render ends.
        try await waitForTestState("selected edit and thumbnail queued", state: { await pipeline.state() }) {
            $0.queuedCount == 2 && $0.waiterCount == 3 && $0.runningBackground == 1
        }
        probe.releaseAll()
        _ = try await first.value
        _ = try await selected.value
        _ = try await thumbnail.value
        #expect(probe.state.value.started == [1, 3, 2])
        #expect(probe.state.value.maximumActive == 1)
    }

    @Test
    func sharedRenderSurvivesOneCancelledWaiter() async throws {
        let probe = RenderProbe()
        defer { probe.releaseAll() }
        let pipeline = AdjustedPreviewPipeline(maximumConcurrentRenders: 1,
            asyncRenderer: { bitmap, settings, _ in try await probe.render(bitmap, settings: settings) })
        let source = try fixture()
        let first = Task { try await pipeline.image(source, request: request, settings: settings(1)) }
        defer { first.cancel() }
        try await probe.state.wait("shared thumbnail started") { $0.started == [1] }
        let second = Task { try await pipeline.image(source, request: request, settings: settings(1), priority: .selected) }
        defer { second.cancel() }
        try await waitForTestState("both shared render waiters registered", state: { await pipeline.state() }) {
            $0.waiterCount == 2 && $0.queuedCount == 0 && $0.runningBackground == 1
        }
        first.cancel()
        await expectCancelled(first)
        try await waitForTestState("remaining shared waiter retains original lane", state: { await pipeline.state() }) {
            $0.waiterCount == 1 && $0.runningBackground == 1 && $0.runningSelected == 0
        }
        #expect(probe.state.value.started == [1])
        probe.releaseAll()
        let result = try await second.value
        let cached = try await pipeline.image(source, request: request, settings: settings(1))
        #expect(result.image === cached.image)
        #expect(probe.state.value.started == [1])
    }

    @Test
    func cancelledRenderRetainsSlotAndObsoleteQueuedEditsNeverRun() async throws {
        let probe = RenderProbe()
        defer { probe.releaseAll() }
        let pipeline = AdjustedPreviewPipeline(maximumConcurrentRenders: 1,
            asyncRenderer: { bitmap, settings, _ in try await probe.render(bitmap, settings: settings) })
        let source = try fixture()
        let first = Task { try await pipeline.image(source, request: request, settings: settings(1)) }
        defer { first.cancel() }
        try await probe.state.wait("render to cancel started") { $0.started == [1] }
        first.cancel()
        await expectCancelled(first)
        try await waitForTestState("cancelled render retains its worker slot", state: { await pipeline.state() }) {
            $0.runningBackground == 1 && $0.waiterCount == 0 && $0.queuedCount == 0
        }
        let obsolete = Task { try await pipeline.image(source, request: request, settings: settings(2)) }
        defer { obsolete.cancel() }
        try await waitForTestState("obsolete edit queued behind cancelled render", state: { await pipeline.state() }) {
            $0.queuedCount == 1 && $0.waiterCount == 1 && $0.runningBackground == 1
        }
        obsolete.cancel()
        await expectCancelled(obsolete)
        try await waitForTestState("obsolete queued edit removed", state: { await pipeline.state() }) {
            $0.queuedCount == 0 && $0.waiterCount == 0 && $0.runningBackground == 1
        }
        let latest = Task { try await pipeline.image(source, request: request, settings: settings(3), priority: .selected) }
        defer { latest.cancel() }
        try await waitForTestState("latest selected edit waits for the occupied worker", state: { await pipeline.state() }) {
            $0.queuedCount == 1 && $0.waiterCount == 1 && $0.runningBackground == 1 && $0.runningSelected == 0
        }
        #expect(probe.state.value.started == [1])
        probe.releaseAll()
        _ = try await latest.value
        // A result completed after all its callers cancelled must not become
        // a cache hit when those settings are requested again.
        _ = try await pipeline.image(source, request: request, settings: settings(1))
        #expect(probe.state.value.started == [1, 3, 1])
        #expect(probe.state.value.maximumActive == 1)
    }

    @Test
    func cancelledGenerationCannotRemoveItsReplacementWaiter() async throws {
        let probe = RenderProbe()
        defer { probe.releaseAll() }
        let pipeline = AdjustedPreviewPipeline(maximumConcurrentRenders: 1,
            asyncRenderer: { bitmap, settings, _ in try await probe.render(bitmap, settings: settings) })
        let source = try fixture()
        let first = Task { try await pipeline.image(source, request: request, settings: settings(1)) }
        defer { first.cancel() }
        try await probe.state.wait("original generation started") { $0.started == [1] }
        first.cancel()
        await expectCancelled(first)
        let replacement = Task { try await pipeline.image(source, request: request, settings: settings(1)) }
        defer { replacement.cancel() }
        try await waitForTestState("replacement generation queued while original retains slot", state: { await pipeline.state() }) {
            $0.queuedCount == 1 && $0.waiterCount == 1 && $0.runningBackground == 1
        }
        probe.releaseAll()
        _ = try await replacement.value
        #expect(probe.state.value.started == [1, 1])
        #expect(probe.state.value.maximumActive == 1)
    }

    @Test
    func failedRenderReleasesWorkerAndCanBeRetried() async throws {
        let source = try fixture()
        let pipeline = AdjustedPreviewPipeline(maximumConcurrentRenders: 1, renderer: { bitmap, settings in
            if settings.exposure == 1 { throw EditRenderError.unavailable }
            return bitmap
        })
        for _ in 0..<2 {
            do {
                _ = try await pipeline.image(source, request: request, settings: settings(1))
                Issue.record("Failed render returned a bitmap")
            } catch is EditRenderError {} catch { Issue.record("Unexpected error: \(error)") }
        }
        let result = try await pipeline.image(source, request: request, settings: settings(2))
        #expect(result.image === source.image)
    }

    @Test
    func synchronousPriorityRendererRunsInAssignedWorkerAfterResize() async throws {
        let source = try fixture()
        let observation = TestStateSignal<SynchronousRenderObservation?>(nil)
        let pipeline = AdjustedPreviewPipeline(maximumConcurrentRenders: 1, priorityRenderer: { bitmap, settings, priority in
            observation.update { $0 = SynchronousRenderObservation(
                priority: priority, taskPriority: Task.currentPriority, isMainThread: Thread.isMainThread,
                width: bitmap.image.width, height: bitmap.image.height, exposure: settings.exposure)
            }
            return bitmap
        })
        let result = try await pipeline.image(source, request: request, settings: settings(1),
            priority: .selected, maximumOutputPixelSize: 16)
        let rendered = try #require(observation.value)
        #expect(rendered.priority == .selected)
        #expect(rendered.taskPriority == .userInitiated)
        #expect(!rendered.isMainThread)
        #expect(rendered.width == 16 && rendered.height == 12)
        #expect(rendered.exposure == 1)
        #expect(result.image.width == rendered.width && result.image.height == rendered.height)
    }

    @Test
    func selectedRenderingOverlapsOneThumbnailWithoutExceedingTwoWorkers() async throws {
        let probe = RenderProbe()
        defer { probe.releaseAll() }
        let pipeline = AdjustedPreviewPipeline(maximumConcurrentRenders: 2,
            asyncRenderer: { bitmap, settings, _ in try await probe.render(bitmap, settings: settings) })
        let source = try fixture()
        let first = Task { try await pipeline.image(source, request: request, settings: settings(1)) }
        defer { first.cancel() }
        try await probe.state.wait("background lane occupied") { $0.started == [1] }
        let thumbnail = Task { try await pipeline.image(source, request: request, settings: settings(2)) }
        defer { thumbnail.cancel() }
        try await waitForTestState("second thumbnail queued behind background lane", state: { await pipeline.state() }) {
            $0.queuedCount == 1 && $0.waiterCount == 2 && $0.runningBackground == 1
        }
        let selected = Task { try await pipeline.image(source, request: request, settings: settings(3), priority: .selected) }
        defer { selected.cancel() }
        try await probe.state.wait("selected and thumbnail renders overlap") { $0.started == [1, 3] }
        #expect(probe.state.value.maximumActive == 2)
        // Cancellation resumes this waiter immediately, but must not permit a
        // third worker until its renderer has actually returned.
        first.cancel()
        await expectCancelled(first)
        try await waitForTestState("cancelled thumbnail retains lane while selected render runs", state: { await pipeline.state() }) {
            $0.queuedCount == 1 && $0.waiterCount == 2 && $0.runningBackground == 1 && $0.runningSelected == 1
        }
        #expect(probe.state.value.started == [1, 3])
        probe.releaseAll()
        _ = try await selected.value
        _ = try await thumbnail.value
        #expect(probe.state.value.started == [1, 3, 2])
        #expect(probe.state.value.maximumActive == 2)
    }

    @Test
    func localMaskGeometryHasItsOwnCacheIdentityAndIdenticalRequestsCoalesce() async throws {
        let probe = RenderProbe()
        defer { probe.releaseAll() }
        let pipeline = AdjustedPreviewPipeline(maximumConcurrentRenders: 1,
            asyncRenderer: { bitmap, settings, _ in try await probe.render(bitmap, settings: settings) })
        let source = try fixture()
        let original = try localSettings(centerX: 0.25)
        var moved = original
        moved.localAdjustments[0].mask.shape = .radial(center: try .init(x: 0.75, y: 0.5),
            radiusX: 0.2, radiusY: 0.3, rotation: 0)
        let movedSettings = moved
        let first = Task { try await pipeline.image(source, request: request, settings: original) }
        defer { first.cancel() }
        try await probe.state.wait("original local mask render started") { $0.started.count == 1 }
        let shared = Task { try await pipeline.image(source, request: request, settings: original) }
        defer { shared.cancel() }
        let distinct = Task { try await pipeline.image(source, request: request, settings: movedSettings) }
        defer { distinct.cancel() }
        try await waitForTestState("identical mask shares worker while moved geometry queues", state: { await pipeline.state() }) {
            $0.waiterCount == 3 && $0.queuedCount == 1 && $0.runningBackground == 1
        }
        probe.releaseAll()
        _ = try await first.value
        _ = try await shared.value
        _ = try await distinct.value
        _ = try await pipeline.image(source, request: request, settings: original)
        _ = try await pipeline.image(source, request: request, settings: movedSettings)
        #expect(probe.state.value.started.count == 2)
        #expect(await pipeline.state().cachedCount == 2)
    }

    @Test
    func cancelledLocalGeometryDoesNotCacheALateResultOrDropItsReplacement() async throws {
        let probe = RenderProbe()
        defer { probe.releaseAll() }
        let pipeline = AdjustedPreviewPipeline(maximumConcurrentRenders: 1,
            asyncRenderer: { bitmap, settings, _ in try await probe.render(bitmap, settings: settings) })
        let source = try fixture()
        let original = try localSettings(centerX: 0.2)
        var moved = original
        moved.localAdjustments[0].mask.shape = .radial(center: try .init(x: 0.8, y: 0.5),
            radiusX: 0.2, radiusY: 0.3, rotation: 0)
        let replacementSettings = moved
        let first = Task { try await pipeline.image(source, request: request, settings: original) }
        defer { first.cancel() }
        try await probe.state.wait("local render to cancel started") { $0.started.count == 1 }
        first.cancel()
        await expectCancelled(first)
        let replacement = Task { try await pipeline.image(source, request: request, settings: replacementSettings) }
        defer { replacement.cancel() }
        try await waitForTestState("replacement local geometry queued behind occupied worker", state: { await pipeline.state() }) {
            $0.queuedCount == 1 && $0.waiterCount == 1 && $0.runningBackground == 1
        }
        probe.releaseAll()
        _ = try await replacement.value
        #expect(await pipeline.state().cachedCount == 1)
        _ = try await pipeline.image(source, request: request, settings: original)
        #expect(probe.state.value.started.count == 3, "A late cancelled mask render must be recomputed")
    }

    @Test
    func artifactAdmissionIncludesLocalSpatialWorkBeforeCallingTheRenderer() async throws {
        let resources = ArtifactResourceOwner(limits: try .init(maximumBytes: 50_000))
        let input = try fixture()
        var phase: ArtifactResourceLease? = try await resources.acquire(kind: .retainedMemory, bytes: 8_192,
            priority: .interactive, retaining: [])
        let memory = try await resources.retain(bytes: Int64(input.byteCost) * 2, from: #require(phase))
        let source = try input.retainingArtifactMemory(memory, owner: resources)
        phase = nil
        try await waitForTestState("input admission released its phase", state: { await resources.state() }) {
            $0.chargedBytes == Int64(input.byteCost) * 2
        }
        let hash = try ArtifactDigest(sha256: String(repeating: "a", count: 64))
        let format = ArtifactRasterFormat(size: try .init(width: 32, height: 24), bitDepth: .eight,
            channels: .rgba, profile: .sRGB, iccSHA256: hash)
        let raster = RasterDescriptor(format: format, file: try .init(sha256: hash, bytes: 64))
        let request = PreviewRequest(source: .artifact(.init(storeID: .init(), artifactID: .init(),
            manifestSHA256: hash, raster: raster)), pixelSize: 512)
        let calls = TestStateSignal(0)
        let pipeline = AdjustedPreviewPipeline(maximumConcurrentRenders: 1, renderer: { bitmap, _ in
            calls.update { $0 += 1 }; return bitmap
        })
        var edits = EditSettings.neutral
        edits.localAdjustments = [try LocalAdjustment(name: "Spatial edit", mask: .init(shape: .subject(
            .init(width: 1, height: 1, bytes: Data([255]))), feather: 0),
            settings: .init(exposure: 1, texture: 40, clarity: 30))]
        await #expect(throws: EditRenderError.insufficientMaskMemory) {
            _ = try await pipeline.image(source, request: request, settings: edits)
        }
        #expect(calls.value == 0)
        edits.localAdjustments[0].isEnabled = false
        _ = try await pipeline.image(source, request: request, settings: edits)
        #expect(calls.value == 1, "Dormant local layers should not consume spatial work admission")
    }

    @Test(arguments: [false, true])
    func complexLocalEditsUseABoundedProxyAndPreserveEveryMask(artifactSource: Bool) async throws {
        let input = try fixture(width: 2_400, height: 1_200)
        let resources = artifactSource ? ArtifactResourceOwner(limits: try .init()) : nil
        let source: PreviewBitmap
        let previewRequest: PreviewRequest
        if let resources {
            var phase: ArtifactResourceLease? = try await resources.acquire(kind: .retainedMemory,
                bytes: Int64(input.byteCost) * 2, priority: .interactive, retaining: [])
            let memory = try await resources.retain(bytes: Int64(input.byteCost) * 2, from: #require(phase))
            source = try input.retainingArtifactMemory(memory, owner: resources)
            phase = nil
            try await waitForTestState("large source phase released before local preview", state: { await resources.state() }) {
                $0.chargedBytes == Int64(input.byteCost) * 2
            }
            let hash = try ArtifactDigest(sha256: String(repeating: "a", count: 64))
            let format = ArtifactRasterFormat(size: try .init(width: 2_400, height: 1_200), bitDepth: .eight,
                channels: .rgba, profile: .sRGB, iccSHA256: hash)
            let raster = RasterDescriptor(format: format, file: try .init(sha256: hash, bytes: 64))
            previewRequest = PreviewRequest(source: .artifact(.init(storeID: .init(), artifactID: .init(),
                manifestSHA256: hash, raster: raster)), pixelSize: 2_400)
        } else { source = input; previewRequest = request }
        let observations = TestStateSignal<[LocalPreviewObservation]>([])
        let pipeline = AdjustedPreviewPipeline(maximumConcurrentRenders: 1, asyncRenderer: { bitmap, settings, _ in
            let charged = await resources?.state().chargedBytes ?? 0
            observations.update { $0.append(.init(width: bitmap.image.width, height: bitmap.image.height,
                settings: settings, chargedBytes: charged)) }
            return bitmap
        })
        let prototype = try #require(localSettings(centerX: 0.5).localAdjustments.first)
        var edits = EditSettings.neutral
        edits.localAdjustments = try (0..<16).map { index in
            try LocalAdjustment(name: "Mask \(index)", mask: prototype.mask, settings: prototype.settings)
        }
        let adjusted = try await pipeline.image(source, request: previewRequest, settings: edits,
            priority: .selected, maximumOutputPixelSize: 2_400)
        let observed = try #require(observations.value.first)
        #expect(observed.width < 2_400 && observed.width >= 64)
        #expect(abs(Double(observed.width) / Double(observed.height) - 2) < 0.01)
        #expect(observed.settings.localAdjustments == edits.localAdjustments)
        #expect(adjusted.image.width == observed.width && adjusted.image.height == observed.height)
        let bytes = try #require(LocalAdjustmentRenderer.estimatedAdditionalBytes(adjustments: edits.localAdjustments,
            width: observed.width, height: observed.height))
        #expect(bytes <= LocalAdjustmentRenderer.previewWorkingMemoryBudget)
        if let resources {
            #expect(observed.chargedBytes > Int64(input.byteCost) * 2)
            #expect(observed.chargedBytes <= resources.limits.maximumBytes,
                    "Source ownership, base admission and all local layers must fit together")
        }
        var sliderEdits = edits
        sliderEdits.localAdjustments[0].settings.exposure = 0.8
        _ = try await pipeline.image(source, request: previewRequest, settings: sliderEdits, priority: .selected)
        #expect(observations.value.count == 2)
        #expect(observations.value.last?.settings.localAdjustments == sliderEdits.localAdjustments)
        if let resources {
            #expect(try #require(observations.value.last).chargedBytes <= resources.limits.maximumBytes,
                    "The next slider value must fit while the preceding adjusted image is retained")
        }
        withExtendedLifetime(adjusted) {}
        for index in edits.localAdjustments.indices { edits.localAdjustments[index].isEnabled = false }
        let disabled = try await pipeline.image(source, request: previewRequest, settings: edits, priority: .selected)
        #expect(disabled.image.width == source.image.width && disabled.image.height == source.image.height)
        #expect(observations.value.last?.width == 2_400 && observations.value.last?.height == 1_200)
        let neutral = try await pipeline.image(source, request: previewRequest, settings: .neutral, priority: .selected)
        #expect(neutral.image === source.image)
        #expect(observations.value.count == 3)
    }

    @Test(arguments: [false, true], [false, true])
    func complexGeometryUsesCombinedBoundedProxyAndAllowsNextSlider(artifactSource: Bool, withMasks: Bool) async throws {
        let input = try fixture(width: 2_400, height: 1_200)
        let resources = artifactSource ? ArtifactResourceOwner(limits: try .init()) : nil
        let source: PreviewBitmap
        if let resources {
            var phase: ArtifactResourceLease? = try await resources.acquire(kind: .retainedMemory,
                bytes: Int64(input.byteCost) * 2, priority: .interactive, retaining: [])
            let memory = try await resources.retain(bytes: Int64(input.byteCost) * 2, from: #require(phase))
            source = try input.retainingArtifactMemory(memory, owner: resources)
            phase = nil
            try await waitForTestState("geometry source phase released", state: { await resources.state() }) {
                $0.chargedBytes == Int64(input.byteCost) * 2
            }
        } else { source = input }
        let observations = TestStateSignal<[LocalPreviewObservation]>([])
        let pipeline = AdjustedPreviewPipeline(maximumConcurrentRenders: 1, asyncRenderer: { bitmap, settings, _ in
            let charged = await resources?.state().chargedBytes ?? 0
            observations.update { $0.append(.init(width: bitmap.image.width, height: bitmap.image.height,
                settings: settings, chargedBytes: charged)) }
            return bitmap
        })
        let patches = try (0..<128).map { _ in
            try DevelopRetouchStroke(mode: .heal, source: .init(x: 0.2, y: 0.4),
                target: .init(x: 0.6, y: 0.6), radius: 0.45)
        }
        let eyes = try (0..<128).map { _ in
            try DevelopRedEyeCorrection(center: .init(x: 0.5, y: 0.5), radiusX: 0.4, radiusY: 0.4)
        }
        var edits = withMasks ? try localSettings(centerX: 0.5) : .neutral
        edits.developGeometry = DevelopGeometry(crop: try .init(x: 0.1, y: 0.1, width: 0.7, height: 0.6),
            quarterTurns: 1, retouchStrokes: patches, redEyeCorrections: eyes)
        let adjusted = try await pipeline.image(source, request: request, settings: edits, priority: .selected)
        let observed = try #require(observations.value.first)
        #expect(observed.width < 2_400 && observed.width >= 64)
        #expect(abs(Double(observed.width) / Double(observed.height) - 2) < 0.01)
        #expect(observed.settings == edits, "Proxy planning must preserve every saved spot correction and mask")
        let local = try #require(LocalAdjustmentRenderer.estimatedAdditionalBytes(adjustments: edits.localAdjustments,
            width: observed.width, height: observed.height))
        let geometry = try #require(DevelopGeometryRenderer.estimatedAdditionalBytes(geometry: edits.developGeometry,
            width: observed.width, height: observed.height))
        #expect(geometry > 0)
        #expect(local + geometry <= LocalAdjustmentRenderer.previewWorkingMemoryBudget)
        if let resources {
            #expect(observed.chargedBytes > Int64(input.byteCost) * 2)
            #expect(observed.chargedBytes <= resources.limits.maximumBytes)
        }
        var next = edits; next.exposure = 0.8
        _ = try await pipeline.image(source, request: request, settings: next, priority: .selected)
        #expect(observations.value.count == 2)
        #expect(observations.value.last?.settings == next)
        if let resources { #expect(try #require(observations.value.last).chargedBytes <= resources.limits.maximumBytes) }
        withExtendedLifetime(adjusted) {}
    }

    @Test func croppedAndRotatedPreviewKeepsItsOutputAspectRatioAcrossCacheAndSliderChanges() async throws {
        let source = try fixture(width: 96, height: 64)
        let pipeline = AdjustedPreviewPipeline(maximumConcurrentRenders: 1)
        var edits = EditSettings.neutral
        edits.developGeometry = DevelopGeometry(crop: try .init(x: 0.25, y: 0, width: 0.5, height: 1), quarterTurns: 1)
        let first = try await pipeline.image(source, request: request, settings: edits, priority: .selected)
        #expect(first.image.width == 64 && first.image.height == 48)
        let cached = try await pipeline.image(source, request: request, settings: edits, priority: .selected)
        #expect(cached.image === first.image)
        edits.exposure = 0.5
        let next = try await pipeline.image(source, request: request, settings: edits, priority: .selected)
        #expect(next.image.width == 64 && next.image.height == 48)
        #expect(await pipeline.state().cachedCount == 2)
    }

    @Test func sdrAndHDRDecodeModesHaveSeparateAdjustedCacheEntries() async throws {
        let source = try fixture()
        let calls = TestStateSignal(0)
        let pipeline = AdjustedPreviewPipeline(maximumConcurrentRenders: 1, renderer: { bitmap, _ in
            calls.update { $0 += 1 }; return bitmap
        })
        let sdr = PreviewRequest(source: request.source, pixelSize: 512, allowsHDR: false)
        let hdr = PreviewRequest(source: request.source, pixelSize: 512, allowsHDR: true)
        let edits = settings(0.5)
        _ = try await pipeline.image(source, request: sdr, settings: edits)
        _ = try await pipeline.image(source, request: hdr, settings: edits)
        #expect(calls.value == 2, "HDR source samples cannot reuse a render made from a clipped SDR base")
        _ = try await pipeline.image(source, request: sdr, settings: edits)
        _ = try await pipeline.image(source, request: hdr, settings: edits)
        #expect(calls.value == 2)
    }

    private var request: PreviewRequest {
        PreviewRequest(url: URL(fileURLWithPath: "/tmp/adjusted-preview"),
                       modifiedAt: Date(timeIntervalSince1970: 100), pixelSize: 512)
    }

    private func settings(_ exposure: Double) -> EditSettings {
        var result = EditSettings.neutral
        result.exposure = exposure
        return result
    }

    private func localSettings(centerX: Double) throws -> EditSettings {
        var result = EditSettings.neutral
        result.localAdjustments = [try LocalAdjustment(name: "Mask", mask: .init(shape: .radial(
            center: .init(x: centerX, y: 0.5), radiusX: 0.2, radiusY: 0.3, rotation: 0)),
            settings: .init(exposure: 1))]
        return result
    }

    private func fixture(width: Int = 32, height: Int = 24) throws -> PreviewBitmap {
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        return PreviewBitmap(image: try #require(context.makeImage()))
    }

    private func expectCancelled(_ task: Task<PreviewBitmap, Error>) async {
        do { _ = try await task.value; Issue.record("Cancelled waiter received a bitmap") }
        catch is CancellationError {} catch { Issue.record("Unexpected error: \(error)") }
    }
}

private struct LocalPreviewObservation: Sendable {
    let width: Int
    let height: Int
    let settings: EditSettings
    let chargedBytes: Int64
}

private struct SynchronousRenderObservation: Sendable {
    let priority: PreviewPriority
    let taskPriority: TaskPriority
    let isMainThread: Bool
    let width: Int
    let height: Int
    let exposure: Double
}

private struct RenderProbeState: Sendable {
    var started: [Double] = []
    var active = 0
    var maximumActive = 0
}

private final class RenderProbe: Sendable {
    let state = TestStateSignal(RenderProbeState())
    private let gate = TestAsyncLatch()

    func releaseAll() { gate.releaseAll() }

    func render(_ bitmap: PreviewBitmap, settings: EditSettings) async throws -> PreviewBitmap {
        state.update {
            $0.started.append(settings.exposure)
            $0.active += 1
            $0.maximumActive = max($0.maximumActive, $0.active)
        }
        defer { state.update { $0.active -= 1 } }
        // Deliberately ignore worker cancellation until released, matching a
        // native renderer that still owns its slot after its last waiter leaves.
        await gate.wait()
        return bitmap
    }
}
