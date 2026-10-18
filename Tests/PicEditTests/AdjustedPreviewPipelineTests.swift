import CoreGraphics
import Foundation
import PicEditCore
import Testing
@testable import PicEdit

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

    private var request: PreviewRequest {
        PreviewRequest(url: URL(fileURLWithPath: "/tmp/adjusted-preview"),
                       modifiedAt: Date(timeIntervalSince1970: 100), pixelSize: 512)
    }

    private func settings(_ exposure: Double) -> EditSettings {
        var result = EditSettings.neutral
        result.exposure = exposure
        return result
    }

    private func fixture() throws -> PreviewBitmap {
        let context = try #require(CGContext(data: nil, width: 32, height: 24, bitsPerComponent: 8,
            bytesPerRow: 128, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        return PreviewBitmap(image: try #require(context.makeImage()))
    }

    private func expectCancelled(_ task: Task<PreviewBitmap, Error>) async {
        do { _ = try await task.value; Issue.record("Cancelled waiter received a bitmap") }
        catch is CancellationError {} catch { Issue.record("Unexpected error: \(error)") }
    }
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
