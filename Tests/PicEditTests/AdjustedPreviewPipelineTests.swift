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
        let pipeline = AdjustedPreviewPipeline(renderer: { try probe.render($0, settings: $1) })
        let source = try fixture()
        let first = Task { try await pipeline.image(source, request: request, settings: settings(1)) }
        try await wait { probe.started == [1] }
        let thumbnail = Task { try await pipeline.image(source, request: request, settings: settings(2)) }
        let selected = Task { try await pipeline.image(source, request: request, settings: settings(3), priority: .selected) }
        // Give both callers time to enqueue while the synchronous renderer is
        // deliberately blocked. The actor must remain free to schedule them.
        try await Task.sleep(for: .milliseconds(40))
        probe.releaseAll()
        _ = try await first.value
        _ = try await selected.value
        _ = try await thumbnail.value
        #expect(probe.started == [1, 3, 2])
        #expect(probe.maximumActive == 1)
    }

    @Test
    func sharedRenderSurvivesOneCancelledWaiter() async throws {
        let probe = RenderProbe()
        defer { probe.releaseAll() }
        let pipeline = AdjustedPreviewPipeline(renderer: { try probe.render($0, settings: $1) })
        let source = try fixture()
        let first = Task { try await pipeline.image(source, request: request, settings: settings(1)) }
        try await wait { probe.started == [1] }
        let second = Task { try await pipeline.image(source, request: request, settings: settings(1), priority: .selected) }
        try await Task.sleep(for: .milliseconds(40))
        first.cancel()
        await expectCancelled(first)
        #expect(probe.started == [1])
        probe.releaseAll()
        let result = try await second.value
        let cached = try await pipeline.image(source, request: request, settings: settings(1))
        #expect(result.image === cached.image)
        #expect(probe.started == [1])
    }

    @Test
    func cancelledRenderRetainsSlotAndObsoleteQueuedEditsNeverRun() async throws {
        let probe = RenderProbe()
        defer { probe.releaseAll() }
        let pipeline = AdjustedPreviewPipeline(renderer: { try probe.render($0, settings: $1) })
        let source = try fixture()
        let first = Task { try await pipeline.image(source, request: request, settings: settings(1)) }
        try await wait { probe.started == [1] }
        first.cancel()
        await expectCancelled(first)
        let obsolete = Task { try await pipeline.image(source, request: request, settings: settings(2)) }
        try await Task.sleep(for: .milliseconds(20))
        obsolete.cancel()
        await expectCancelled(obsolete)
        let latest = Task { try await pipeline.image(source, request: request, settings: settings(3), priority: .selected) }
        try await Task.sleep(for: .milliseconds(20))
        #expect(probe.started == [1])
        probe.releaseAll()
        _ = try await latest.value
        // A result completed after all its callers cancelled must not become
        // a cache hit when those settings are requested again.
        _ = try await pipeline.image(source, request: request, settings: settings(1))
        #expect(probe.started == [1, 3, 1])
        #expect(probe.maximumActive == 1)
    }

    @Test
    func cancelledGenerationCannotRemoveItsReplacementWaiter() async throws {
        let probe = RenderProbe()
        defer { probe.releaseAll() }
        let pipeline = AdjustedPreviewPipeline(renderer: { try probe.render($0, settings: $1) })
        let source = try fixture()
        let first = Task { try await pipeline.image(source, request: request, settings: settings(1)) }
        try await wait { probe.started == [1] }
        first.cancel()
        await expectCancelled(first)
        let replacement = Task { try await pipeline.image(source, request: request, settings: settings(1)) }
        try await Task.sleep(for: .milliseconds(20))
        probe.releaseAll()
        _ = try await replacement.value
        #expect(probe.started == [1, 1])
        #expect(probe.maximumActive == 1)
    }

    @Test
    func failedRenderReleasesWorkerAndCanBeRetried() async throws {
        let source = try fixture()
        let pipeline = AdjustedPreviewPipeline(renderer: { bitmap, settings in
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

    private func wait(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(4))
        while !condition() {
            guard ContinuousClock.now < deadline else { throw RenderProbeError.timeout }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

private enum RenderProbeError: Error { case timeout }

private final class RenderProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var exposures: [Double] = []
    private var gates: [DispatchSemaphore] = []
    private var blocking = true
    private var active = 0
    private var maximum = 0

    var started: [Double] {
        lock.lock(); defer { lock.unlock() }
        return exposures
    }

    var maximumActive: Int {
        lock.lock(); defer { lock.unlock() }
        return maximum
    }

    func releaseAll() {
        lock.lock()
        blocking = false
        let waiting = gates
        gates.removeAll()
        lock.unlock()
        for gate in waiting { gate.signal() }
    }

    func render(_ bitmap: PreviewBitmap, settings: EditSettings) throws -> PreviewBitmap {
        let gate = DispatchSemaphore(value: 0)
        lock.lock()
        exposures.append(settings.exposure)
        active += 1
        maximum = max(maximum, active)
        let shouldWait = blocking
        if shouldWait { gates.append(gate) }
        lock.unlock()
        defer {
            lock.lock()
            active -= 1
            lock.unlock()
        }
        if shouldWait, gate.wait(timeout: .now() + 5) == .timedOut { throw RenderProbeError.timeout }
        return bitmap
    }
}
