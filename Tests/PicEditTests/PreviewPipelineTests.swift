import CoreGraphics
import Foundation
import Testing
@testable import PicEdit

@Suite("Preview scheduling")
struct PreviewPipelineTests {
    @Test
    func largerPreviewIsReusedButChangedFileIsNot() async throws {
        let probe = DecodeProbe(blocking: false)
        let pipeline = ImagePreviewPipeline(decoder: { try probe.decode($0) })
        let large = request("same", size: 1_024)
        let image = try await pipeline.image(for: large)
        let small = try await pipeline.image(for: request("same", size: 256))
        #expect(image.image === small.image)
        #expect(probe.started.count == 1)
        _ = try await pipeline.image(for: PreviewRequest(url: large.url, modifiedAt: large.modifiedAt,
                                                        pixelSize: 256, fileSize: 99))
        _ = try await pipeline.image(for: PreviewRequest(url: large.url,
                                                        modifiedAt: large.modifiedAt.addingTimeInterval(1), pixelSize: 256))
        #expect(probe.started.count == 3)
        // A camera-rendered browsing preview must not become the editing base.
        _ = try await pipeline.image(for: PreviewRequest(url: large.url, modifiedAt: large.modifiedAt,
                                                        pixelSize: 256, allowsEmbeddedPreview: false))
        #expect(probe.started.count == 4)
    }

    @Test
    func runningLargerDecodeIsSharedAndOneCancelledWaiterDoesNotCancelOthers() async throws {
        let probe = DecodeProbe()
        defer { probe.releaseAll() }
        let pipeline = ImagePreviewPipeline(concurrencyLimit: 3, decoder: { try probe.decode($0) })
        let large = Task { try await pipeline.image(for: request("shared", size: 2_400)) }
        try await wait { probe.started == ["shared"] }
        let abandoned = Task { try await pipeline.image(for: request("shared", size: 1_024)) }
        let small = Task { try await pipeline.image(for: request("shared", size: 512), priority: .selected) }
        try await Task.sleep(for: .milliseconds(40))
        abandoned.cancel()
        do { _ = try await abandoned.value; Issue.record("Cancelled smaller caller received an image") }
        catch is CancellationError {} catch { Issue.record("Unexpected cancellation error: \(error)") }
        large.cancel()
        do { _ = try await large.value; Issue.record("Cancelled caller received an image") }
        catch is CancellationError {} catch { Issue.record("Unexpected cancellation error: \(error)") }
        probe.releaseAll()
        _ = try await small.value
        #expect(probe.started == ["shared"])
    }

    @Test
    func persistedLargerPreviewServesBothProgressiveStagesWithoutDecodingOriginal() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PicEdit pipeline \(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let disk = PreviewDiskCache(directory: directory)
        let probe = DecodeProbe(blocking: false)
        let large = request("offline-original", size: 2_400)
        await disk.store(try probe.decode(large), for: large)
        let pipeline = ImagePreviewPipeline(diskCache: disk, decoder: { _ in
            throw PreviewFailure.unavailable
        })
        let small = try await pipeline.image(for: request("offline-original", size: 512), priority: .selected)
        let final = try await pipeline.image(for: large, priority: .selected)
        #expect(small.image === final.image)
    }

    @Test
    func selectedPhotoUsesReservedSlotAheadOfQueuedThumbnails() async throws {
        let probe = DecodeProbe()
        defer { probe.releaseAll() }
        let pipeline = ImagePreviewPipeline(concurrencyLimit: 2, decoder: { try probe.decode($0) })
        let first = Task { try await pipeline.image(for: request("first")) }
        try await wait { probe.started == ["first"] }
        let queued = Task { try await pipeline.image(for: request("queued")) }
        // A background decode is deliberately still running when selection changes.
        let selected = Task { try await pipeline.image(for: request("selected"), priority: .selected) }
        try await wait { probe.started.contains("selected") }
        #expect(!probe.started.contains("queued"))
        probe.releaseAll()
        _ = try await first.value
        _ = try await selected.value
        _ = try await queued.value
    }

    @Test
    func cancelledDecoderRetainsItsSlotUntilItActuallyReturns() async throws {
        let probe = DecodeProbe()
        defer { probe.releaseAll() }
        let pipeline = ImagePreviewPipeline(concurrencyLimit: 1, decoder: { try probe.decode($0) })
        let first = Task { try await pipeline.image(for: request("cancelled")) }
        try await wait { probe.started.count == 1 }
        first.cancel()
        do { _ = try await first.value; Issue.record("Canceled caller received an image") }
        catch is CancellationError {} catch { Issue.record("Unexpected cancellation error: \(error)") }
        let next = Task { try await pipeline.image(for: request("next"), priority: .selected) }
        try await Task.sleep(for: .milliseconds(40))
        #expect(probe.started == ["cancelled"])
        probe.releaseAll()
        _ = try await next.value
        #expect(probe.started == ["cancelled", "next"])
    }

    private func request(_ name: String, size: Int = 512) -> PreviewRequest {
        PreviewRequest(url: URL(fileURLWithPath: "/tmp/\(name)"), modifiedAt: Date(timeIntervalSince1970: 100), pixelSize: size)
    }

    private func wait(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(4))
        while !condition() {
            guard ContinuousClock.now < deadline else { throw ProbeError.timeout }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

private enum ProbeError: Error { case timeout, image }

private final class DecodeProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var names: [String] = []
    private var gates: [DispatchSemaphore] = []
    private var blocking: Bool

    init(blocking: Bool = true) { self.blocking = blocking }

    var started: [String] {
        lock.lock(); defer { lock.unlock() }
        return names
    }

    func releaseAll() {
        lock.lock()
        blocking = false
        let waiting = gates
        gates.removeAll()
        lock.unlock()
        for gate in waiting { gate.signal() }
    }

    func decode(_ request: PreviewRequest) throws -> PreviewBitmap {
        let gate = DispatchSemaphore(value: 0)
        lock.lock()
        names.append(request.url.lastPathComponent)
        let shouldWait = blocking
        if shouldWait { gates.append(gate) }
        lock.unlock()
        if shouldWait, gate.wait(timeout: .now() + 5) == .timedOut { throw ProbeError.timeout }
        guard let context = CGContext(data: nil, width: 32, height: 24, bitsPerComponent: 8,
                                      bytesPerRow: 128, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let image = context.makeImage() else { throw ProbeError.image }
        return PreviewBitmap(image: image)
    }
}
