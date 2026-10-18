import CoreGraphics
import Foundation
import Testing
@testable import PicEdit

@Suite("Preview scheduling")
struct PreviewPipelineTests {
    @Test
    func largerPreviewIsReusedButChangedFileIsNot() async throws {
        let probe = DecodeProbe(blocking: false)
        let pipeline = ImagePreviewPipeline(decoder: { try probe.decodeSynchronously($0) })
        let large = request("same", size: 1_024)
        let image = try await pipeline.image(for: large)
        let small = try await pipeline.image(for: request("same", size: 256))
        #expect(image.image === small.image)
        #expect(probe.started.count == 1)
        _ = try await pipeline.image(for: PreviewRequest(url: try #require(large.url), modifiedAt: large.modifiedAt,
                                                        pixelSize: 256, fileSize: 99))
        _ = try await pipeline.image(for: PreviewRequest(url: try #require(large.url),
                                                        modifiedAt: large.modifiedAt.addingTimeInterval(1), pixelSize: 256))
        #expect(probe.started.count == 3)
        // A camera-rendered browsing preview must not become the editing base.
        _ = try await pipeline.image(for: PreviewRequest(url: try #require(large.url), modifiedAt: large.modifiedAt,
                                                        pixelSize: 256, allowsEmbeddedPreview: false))
        #expect(probe.started.count == 4)
        try await waitForIdle(pipeline)
    }

    @Test
    func runningLargerDecodeIsSharedAndOneCancelledWaiterDoesNotCancelOthers() async throws {
        let probe = DecodeProbe()
        defer { probe.releaseAll() }
        let pipeline = ImagePreviewPipeline(concurrencyLimit: 3, asyncDecoder: { try await probe.decode($0) })
        let large = Task { try await pipeline.image(for: request("shared", size: 2_400)) }
        defer { large.cancel() }
        try await probe.waitForStarted(["shared"])
        let abandoned = Task { try await pipeline.image(for: request("shared", size: 1_024)) }
        defer { abandoned.cancel() }
        let small = Task { try await pipeline.image(for: request("shared", size: 512), priority: .selected) }
        defer { small.cancel() }
        _ = try await waitForTestState("three callers share one running decode",
                                      state: { await pipeline.state() }) {
            $0.runningCount == 1 && $0.queuedCount == 0 && $0.waiterCount == 3
        }
        abandoned.cancel()
        do { _ = try await abandoned.value; Issue.record("Cancelled smaller caller received an image") }
        catch is CancellationError {} catch { Issue.record("Unexpected cancellation error: \(error)") }
        large.cancel()
        do { _ = try await large.value; Issue.record("Cancelled caller received an image") }
        catch is CancellationError {} catch { Issue.record("Unexpected cancellation error: \(error)") }
        probe.releaseAll()
        _ = try await small.value
        try await waitForIdle(pipeline)
        #expect(probe.started == ["shared"])
        #expect(probe.maximumActive == 1)
    }

    @Test
    func persistedLargerPreviewServesBothProgressiveStagesWithoutDecodingOriginal() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PicEdit pipeline \(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let disk = PreviewDiskCache(directory: directory)
        let large = request("offline-original", size: 2_400)
        await disk.store(try previewFixture(), for: large)
        let pipeline = ImagePreviewPipeline(diskCache: disk, decoder: { _ in
            throw PreviewFailure.unavailable
        })
        let small = try await pipeline.image(for: request("offline-original", size: 512), priority: .selected)
        let final = try await pipeline.image(for: large, priority: .selected)
        #expect(small.image === final.image)
        try await waitForIdle(pipeline)
    }

    @Test
    func selectedPhotoUsesReservedSlotAheadOfQueuedThumbnails() async throws {
        let probe = DecodeProbe()
        defer { probe.releaseAll() }
        let pipeline = ImagePreviewPipeline(concurrencyLimit: 2, asyncDecoder: { try await probe.decode($0) })
        let first = Task { try await pipeline.image(for: request("first")) }
        defer { first.cancel() }
        try await probe.waitForStarted(["first"])
        let queued = Task { try await pipeline.image(for: request("queued")) }
        defer { queued.cancel() }
        _ = try await waitForTestState("thumbnail queued behind the reserved selected-photo slot",
                                      state: { await pipeline.state() }) {
            $0.runningCount == 1 && $0.runningThumbnailCount == 1 && $0.queuedCount == 1 && $0.waiterCount == 2
        }
        // A background decode is deliberately still running when selection changes.
        let selected = Task { try await pipeline.image(for: request("selected"), priority: .selected) }
        defer { selected.cancel() }
        try await probe.waitForStarted(["first", "selected"])
        let occupied = await pipeline.state()
        #expect(occupied.runningCount == 2 && occupied.runningThumbnailCount == 1 && occupied.queuedCount == 1)
        #expect(!probe.started.contains("queued"))
        #expect(probe.maximumActive == 2)
        probe.releaseAll()
        _ = try await first.value
        _ = try await selected.value
        _ = try await queued.value
        try await waitForIdle(pipeline)
        #expect(probe.started == ["first", "selected", "queued"])
        #expect(probe.maximumActive == 2)
    }

    @Test
    func cancelledDecoderRetainsItsSlotUntilItActuallyReturns() async throws {
        let probe = DecodeProbe()
        defer { probe.releaseAll() }
        let pipeline = ImagePreviewPipeline(concurrencyLimit: 1, asyncDecoder: { try await probe.decode($0) })
        let first = Task { try await pipeline.image(for: request("cancelled")) }
        defer { first.cancel() }
        try await probe.waitForStarted(["cancelled"])
        first.cancel()
        do { _ = try await first.value; Issue.record("Canceled caller received an image") }
        catch is CancellationError {} catch { Issue.record("Unexpected cancellation error: \(error)") }
        let next = Task { try await pipeline.image(for: request("next"), priority: .selected) }
        defer { next.cancel() }
        _ = try await waitForTestState("cancelled decode still owns the worker while its replacement waits",
                                      state: { await pipeline.state() }) {
            $0.runningCount == 1 && $0.queuedCount == 1 && $0.waiterCount == 1
        }
        #expect(probe.started == ["cancelled"])
        probe.releaseAll()
        _ = try await next.value
        try await waitForIdle(pipeline)
        #expect(probe.started == ["cancelled", "next"])
        #expect(probe.maximumActive == 1)
    }

    @Test @MainActor
    func synchronousDecoderRunsOffMainAndFailureReleasesItsWorker() async throws {
        let probe = DecodeProbe(blocking: false, failingNames: ["failed"])
        let pipeline = ImagePreviewPipeline(concurrencyLimit: 1, decoder: { try probe.decodeSynchronously($0) })
        do {
            _ = try await pipeline.image(for: request("failed"))
            Issue.record("Failed synchronous decoder returned an image")
        } catch {
            #expect(error as? ProbeError == .decode)
        }
        _ = try await pipeline.image(for: request("retry"))
        try await waitForIdle(pipeline)
        #expect(probe.started == ["failed", "retry"])
        #expect(probe.maximumActive == 1)
        #expect(!probe.wasOnMainThread)
    }

    private func request(_ name: String, size: Int = 512) -> PreviewRequest {
        PreviewRequest(url: URL(fileURLWithPath: "/tmp/\(name)"), modifiedAt: Date(timeIntervalSince1970: 100), pixelSize: size)
    }

    private func waitForIdle(_ pipeline: ImagePreviewPipeline) async throws {
        _ = try await waitForTestState("preview workers and waiters finish",
                                      state: { await pipeline.state() }) {
            $0.runningCount == 0 && $0.queuedCount == 0 && $0.waiterCount == 0
        }
    }
}

private enum ProbeError: Error, Equatable { case decode, image }

private struct DecodeProbeState: Sendable {
    var started: [String] = []
    var active = 0
    var maximumActive = 0
    var wasOnMainThread = false
}

private final class DecodeProbe: @unchecked Sendable {
    private let state = TestStateSignal(DecodeProbeState())
    private let latch: TestAsyncLatch
    private let failingNames: Set<String>

    init(blocking: Bool = true, failingNames: Set<String> = []) {
        latch = TestAsyncLatch(open: !blocking)
        self.failingNames = failingNames
    }

    var started: [String] { state.value.started }
    var maximumActive: Int { state.value.maximumActive }
    var wasOnMainThread: Bool { state.value.wasOnMainThread }

    func waitForStarted(_ names: [String]) async throws {
        _ = try await state.wait("decoder starts \(names)") { $0.started == names }
    }

    func releaseAll() { latch.releaseAll() }

    func decode(_ request: PreviewRequest) async throws -> PreviewBitmap {
        begin(request)
        defer { finish() }
        // Model an uncooperative native return without occupying a cooperative
        // executor thread. Cancellation must retain the pipeline's worker slot.
        await latch.wait()
        return try result(for: request)
    }

    func decodeSynchronously(_ request: PreviewRequest) throws -> PreviewBitmap {
        begin(request)
        defer { finish() }
        return try result(for: request)
    }

    private func begin(_ request: PreviewRequest) {
        let isMainThread = Thread.isMainThread
        state.update {
            $0.started.append(request.displayName)
            $0.active += 1
            $0.maximumActive = max($0.maximumActive, $0.active)
            $0.wasOnMainThread = $0.wasOnMainThread || isMainThread
        }
    }

    private func finish() { state.update { $0.active -= 1 } }

    private func result(for request: PreviewRequest) throws -> PreviewBitmap {
        if failingNames.contains(request.displayName) { throw ProbeError.decode }
        return try previewFixture()
    }
}

private func previewFixture() throws -> PreviewBitmap {
    guard let context = CGContext(data: nil, width: 32, height: 24, bitsPerComponent: 8,
                                  bytesPerRow: 128, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
          let image = context.makeImage() else { throw ProbeError.image }
    return PreviewBitmap(image: image)
}
