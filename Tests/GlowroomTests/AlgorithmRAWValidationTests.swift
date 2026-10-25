import CoreGraphics
import CryptoKit
import Darwin
import Foundation
import GlowroomCore
import ImageIO
import Testing
@testable import Glowroom

/// Explicit local inputs only. CI has no private RAW fixtures and skips this
/// opt-in diagnostic. Run each file in its own process, with no other benchmark.
/// App caches begin empty; OS/ImageIO/driver caches are deliberately not flushed.
@Suite("Optional algorithm RAW cold/warm and drag validation", .serialized)
struct AlgorithmRAWValidationTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["GLOWROOM_ALGORITHM_RAW_INPUT"]?.isEmpty == false,
                   "Requires an explicit local camera RAW; private photos are unavailable in CI."), .timeLimit(.minutes(10)))
    func actualRAWDecodeCacheAndLatestCurveOpticsMaskRevision() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["GLOWROOM_ALGORITHM_RAW_INPUT"])
        let url = URL(fileURLWithPath: path).standardizedFileURL
        let beforeHash = try hash(url)
        let attributes = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let sourceDescriptor = try #require(CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary))
        let type = try #require(CGImageSourceGetType(sourceDescriptor)) as String
        try #require(PreviewDecoder.isCameraRAWTypeIdentifier(type), "Supply a camera RAW supported by the app's ImageIO decoder")
        let edge = 2_400
        let request = PreviewRequest(url: url, modifiedAt: attributes.contentModificationDate ?? .distantPast,
            pixelSize: edge, fileSize: Int64(attributes.fileSize ?? 0), allowsEmbeddedPreview: false)
        let probe = AlgorithmRAWProbe()
        let originals = ImagePreviewPipeline(concurrencyLimit: 1, diskCache: nil, decoder: { request in
            probe.decoded()
            return try PreviewDecoder.decode(request)
        })
        let session = EditRenderer.Session(cacheIntermediates: true, lowPriority: false)
        let adjusted = AdjustedPreviewPipeline(maximumConcurrentRenders: 1, renderer: { source, settings in
            probe.beginRender(settings: settings)
            defer { probe.endRender() }
            return try EditRenderer.render(source, settings: settings, session: session)
        })
        let decodedAt = ContinuousClock.now
        let source = try await originals.image(for: request, priority: .selected)
        let coldDecodeMS = milliseconds(decodedAt.duration(to: .now))
        #expect(max(source.image.width, source.image.height) <= edge)
        let warmSourceAt = ContinuousClock.now
        let warmSource = try await originals.image(for: request, priority: .selected)
        let warmSourceMS = milliseconds(warmSourceAt.duration(to: .now))
        #expect(warmSource.image === source.image)

        let composition = try LocalMaskComposition(components: [
            .init(name: "Radial selection", shape: .radial(center: .init(x: 0.5, y: 0.5), radiusX: 0.35, radiusY: 0.4, rotation: 0), feather: 0.1),
            .init(name: "Gradient intersection", operation: .intersect,
                  shape: .linear(start: .init(x: 0.1, y: 0.2), end: .init(x: 0.9, y: 0.8)), feather: 0)
        ])
        var settings = EditSettings(exposure: 0.15, levels: .init(master: .init(gamma: 1.05)),
            toneCurves: .init(master: .init(points: [.init(x: 0, y: 0.01), .init(x: 0.5, y: 0.54), .init(x: 1, y: 0.99)])),
            toneProcessingVersion: .consistentV2)
        settings.localAdjustments = [try .init(name: "RAW combined selections", mask: .init(composition: composition), settings: .init(exposure: 0.2))]
        settings.developGeometry.optics = try .init(distortion: 15)
        _ = try EditingSnapshot(settings: settings)
        let coldAt = ContinuousClock.now
        let cold = try await adjusted.frame(source, request: request, settings: settings, priority: .selected, maximumOutputPixelSize: edge)
        let coldRenderMS = milliseconds(coldAt.duration(to: .now))
        let warmAt = ContinuousClock.now
        let warm = try await adjusted.frame(source, request: request, settings: settings, priority: .selected, maximumOutputPixelSize: edge)
        let warmOutputMS = milliseconds(warmAt.duration(to: .now))
        let warmOutputHit = warm.output.image === cold.output.image
        var warmRenders: [Double] = []
        for step in 1...2 {
            settings.toneCurves.master.points[1].y = 0.54 + Double(step) * 0.01
            settings.developGeometry.optics = try .init(distortion: 15 + Double(step))
            let started = ContinuousClock.now
            _ = try await adjusted.image(source, request: request, settings: settings, priority: .selected, maximumOutputPixelSize: edge)
            warmRenders.append(milliseconds(started.duration(to: .now)))
        }

        let publication = AlgorithmRAWPublication()
        let burstAt = ContinuousClock.now
        var lastEventAt = burstAt
        var tasks: [Task<PreviewBitmap, Error>] = []
        defer { for task in tasks { task.cancel() } }
        let events = 8
        var finalSettings = settings
        for revision in 1...events {
            tasks.last?.cancel()
            settings.toneCurves.master.points[1].y = 0.5 + Double(revision) * 0.008
            settings.developGeometry.optics = try .init(distortion: -12 + Double(revision) * 3)
            settings.localAdjustments[0].settings.exposure = 0.1 + Double(revision) * 0.01
            finalSettings = settings
            let captured = settings
            await publication.expect(revision)
            lastEventAt = .now
            tasks.append(Task {
                // The production coalescing interval precedes work submission;
                // cancelled gestures must neither decode nor publish an old image.
                try await Task.sleep(for: .milliseconds(45))
                let base = try await originals.image(for: request, priority: .selected)
                let output = try await adjusted.image(base, request: request, settings: captured,
                    priority: .selected, maximumOutputPixelSize: edge)
                try Task.checkCancellation()
                await publication.accept(revision: revision, settings: captured)
                return output
            })
            if revision < events { try await Task.sleep(for: .milliseconds(10)) }
        }
        let final = try await #require(tasks.last).value
        let completedAt = ContinuousClock.now
        var cancelled = 0
        for task in tasks.dropLast() {
            do { _ = try await task.value }
            catch is CancellationError { cancelled += 1 }
        }
        let displayed = await publication.state()
        #expect(displayed.revision == events && displayed.settings == finalSettings)
        let after = probe.snapshot()
        #expect(after.decodes == 1, "Cold/warm source requests and all drags must share one actual RAW decode")
        #expect(after.maximumActive == 1 && after.active == 0)
        #expect(after.lastSettings == finalSettings, "The admitted renderer must finish with the latest accepted settings")
        let range = session.toneCurveRangeDiagnostics()
        #expect(range.measurements == 1, "Curve, optics and local settings changes preserve the pre-curve range identity")
        #expect(range.cacheHits >= 3)
        let queue = await adjusted.state()
        #expect(queue.runningSelected == 0 && queue.queuedCount == 0)
        #expect(try hash(url) == beforeHash, "The supplied original must remain byte-identical")
        var usage = rusage()
        let peak = getrusage(RUSAGE_SELF, &usage) == 0 ? usage.ru_maxrss : -1
        let result: [String: Any] = [
            "schema_version": 1, "build_configuration": "Swift Testing debug",
            "source_sha256": beforeHash, "source_type": type, "source_file_bytes": attributes.fileSize ?? 0,
            "source_width": source.image.width, "source_height": source.image.height, "source_long_edge": source.sourceLongEdge,
            "source_bits_per_component": source.image.bitsPerComponent, "requested_edge": edge,
            "actual_admitted_input_width": cold.actualInput.image.width, "actual_admitted_input_height": cold.actualInput.image.height,
            "final_output_width": final.image.width, "final_output_height": final.image.height,
            "cold_decode_ms": coldDecodeMS, "warm_source_cache_ms": warmSourceMS,
            "cold_render_ms": coldRenderMS, "warm_output_cache_ms": warmOutputMS, "warm_output_cache_hit": warmOutputHit,
            "warm_session_changed_settings_render_ms": warmRenders,
            "drag_events": events, "drag_interval_ms": 10, "coalescing_ms": 45, "cancelled_requests": cancelled,
            "burst_total_ms": milliseconds(burstAt.duration(to: completedAt)), "last_event_to_final_output_ms": milliseconds(lastEventAt.duration(to: completedAt)),
            "latest_published_revision": displayed.revision, "raw_decode_count": after.decodes,
            "actual_render_count": after.renders, "maximum_active_render_workers": after.maximumActive,
            "curve_range_measurements": range.measurements, "curve_range_cache_hits": range.cacheHits,
            "mask_components": composition.components.count, "process_cumulative_peak_rss_bytes": peak,
            "original_unchanged": true,
            "scope": "One explicit private RAW, actual ImageIO decoder with embedded-preview reuse disabled, fresh app memory caches and disk cache disabled. One existing bounded preview/render lane; no new runtime pool. At most two changed-settings warm samples plus one eight-event coalesced curve/optics/local-mask burst. OS/ImageIO/driver/shader caches are not flushed, so cold means app-cache cold. The existing adaptive mask budget may reduce the admitted input; dimensions are reported. ru_maxrss is Darwin whole-process cumulative high-water in bytes, including Swift Testing, decoding, CI/GPU staging and retained frames; it is not an isolated per-stage allocation. Times are debug-test request-to-materialized-bitmap latency, not native UI input-to-display latency. No performance improvement, cross-device claim, objective image-quality score or ground-truth alignment is inferred. Original hashing occurs outside timed decode/render stages. No image derivative or original is written, copied or uploaded."
        ]
        let bytes = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        let reportURL = URL(fileURLWithPath: "/tmp/glowroom-algorithm-raw-\(beforeHash.prefix(12))-\(UUID().uuidString).json")
        try bytes.write(to: reportURL, options: .atomic)
        print("Algorithm RAW validation JSON: \(reportURL.path)\n\(String(decoding: bytes, as: UTF8.self))")
    }

    private func milliseconds(_ value: Duration) -> Double {
        Double(value.components.seconds) * 1_000 + Double(value.components.attoseconds) / 1_000_000_000_000_000
    }
    private func hash(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var digest = SHA256()
        while let bytes = try handle.read(upToCount: 1_048_576), !bytes.isEmpty { digest.update(data: bytes) }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

private actor AlgorithmRAWPublication {
    private var expected = 0, accepted = 0
    private var settings: EditSettings?
    func expect(_ revision: Int) { expected = revision }
    func accept(revision: Int, settings: EditSettings) {
        guard revision == expected else { return }
        accepted = revision; self.settings = settings
    }
    func state() -> (revision: Int, settings: EditSettings?) { (accepted, settings) }
}

private final class AlgorithmRAWProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var decodes = 0, renders = 0, active = 0, maximumActive = 0
    private var lastSettings: EditSettings?
    func decoded() { lock.lock(); decodes += 1; lock.unlock() }
    func beginRender(settings: EditSettings) {
        lock.lock(); defer { lock.unlock() }
        renders += 1; active += 1; maximumActive = max(maximumActive, active); lastSettings = settings
    }
    func endRender() { lock.lock(); active -= 1; lock.unlock() }
    func snapshot() -> (decodes: Int, renders: Int, active: Int, maximumActive: Int, lastSettings: EditSettings?) {
        lock.lock(); defer { lock.unlock() }
        return (decodes, renders, active, maximumActive, lastSettings)
    }
}
