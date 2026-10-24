import CoreGraphics
import CryptoKit
import Darwin
import Foundation
import GlowroomCore
import ImageIO
import Testing
@testable import Glowroom

/// Opt-in local measurement: set GLOWROOM_TONE_RAW to one explicit camera RAW.
/// Without that variable Swift Testing skips this diagnostic; CI needs no photo.
/// Run this filter alone after ordinary tests, with no concurrent build or other
/// benchmark. Cold means fresh app caches, never flushed OS/ImageIO/GPU caches.
/// An optional separate JPEG run can use the normal synthetic/export tests;
/// this diagnostic deliberately requires a real RAW and writes only temporary
/// numeric JSON, never a copy or derivative of the supplied private photograph.
@Suite("Optional local V2 RAW measurements", .serialized)
struct ToneProcessingPerformanceTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["GLOWROOM_TONE_RAW"]?.isEmpty == false), .timeLimit(.minutes(10)))
    func boundedV2RawColdWarmAndRapidSliderMeasurements() async throws {
        guard let path = ProcessInfo.processInfo.environment["GLOWROOM_TONE_RAW"], !path.isEmpty else { return }
        let originalURL = URL(fileURLWithPath: path).standardizedFileURL
        let originalHash = try hash(originalURL)
        let values = try originalURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let imageSource = try #require(CGImageSourceCreateWithURL(originalURL as CFURL, nil))
        let identifier = try #require(CGImageSourceGetType(imageSource)) as String
        try #require(PreviewDecoder.isCameraRAWTypeIdentifier(identifier), "GLOWROOM_TONE_RAW must identify a real camera RAW")
        let edge = ProcessInfo.processInfo.environment["GLOWROOM_TONE_EDGE"].flatMap(Int.init) ?? 2_048
        try #require((64...4_096).contains(edge), "GLOWROOM_TONE_EDGE must be in 64...4096")
        let request = PreviewRequest(url: originalURL, modifiedAt: values.contentModificationDate ?? .distantPast,
            pixelSize: edge, fileSize: Int64(values.fileSize ?? 0), allowsEmbeddedPreview: false)
        let counts = TonePerformanceCounts()
        let originals = ImagePreviewPipeline(concurrencyLimit: 1, diskCache: nil, decoder: { value in
            counts.decoded()
            return try PreviewDecoder.decode(value)
        })
        let decodeStart = ContinuousClock.now
        let source = try await originals.image(for: request, priority: .selected)
        let coldDecodeMS = milliseconds(decodeStart.duration(to: .now))
        #expect(max(source.image.width, source.image.height) <= edge)
        let sourceCacheStart = ContinuousClock.now
        let cachedSource = try await originals.image(for: request, priority: .selected)
        let warmSourceMS = milliseconds(sourceCacheStart.duration(to: .now))
        #expect(cachedSource.image === source.image)

        var settings = EditSettings(exposure: 0.25, contrast: 12, highlights: -15, shadows: 10,
            texture: 10, clarity: 8, luminanceNoiseReduction: 10, colorNoiseReduction: 10,
            naturalBalanceAmount: 35, developColor: .init(profile: .vivid), toneProcessingVersion: .consistentV2)
        let measuresLevels = ProcessInfo.processInfo.environment["GLOWROOM_TONE_LEVELS"] == "1"
        if measuresLevels { settings.levels.master = LevelsCurve(inputBlack: 0.01, inputWhite: 0.99, gamma: 1.1) }
        let session = EditRenderer.Session(cacheIntermediates: true, lowPriority: false)
        let adjusted = AdjustedPreviewPipeline(maximumConcurrentRenders: 1, renderer: { bitmap, value in
            counts.beginRender()
            defer { counts.endRender() }
            return try EditRenderer.render(bitmap, settings: value, session: session)
        })
        let coldRenderStart = ContinuousClock.now
        let coldOutput = try await adjusted.image(source, request: request, settings: settings,
            priority: .selected, maximumOutputPixelSize: edge)
        let coldRenderMS = milliseconds(coldRenderStart.duration(to: .now))
        let outputCacheStart = ContinuousClock.now
        let cachedOutput = try await adjusted.image(source, request: request, settings: settings,
            priority: .selected, maximumOutputPixelSize: edge)
        let warmOutputMS = milliseconds(outputCacheStart.duration(to: .now))
        // Large frames can deliberately exceed the existing 32 MiB edited
        // cache. Report the miss rather than enlarging that production limit.
        let outputCacheHit = cachedOutput.image === coldOutput.image
        var warmRenderMS: [Double] = []
        // Distinct absolute exposure values force actual rendering while the
        // same admitted worker and Session reuse their unchanged V2 prefix.
        for step in 1...4 {
            if measuresLevels { settings.levels.master.gamma = 1.1 + Double(step) * 0.01 }
            else { settings.exposure = 0.25 + Double(step) * 0.01 }
            let start = ContinuousClock.now
            _ = try await adjusted.image(source, request: request, settings: settings,
                priority: .selected, maximumOutputPixelSize: edge)
            warmRenderMS.append(milliseconds(start.duration(to: .now)))
        }

        let estimator = AutomaticToneEstimator()
        let coldAnalysisStart = ContinuousClock.now
        let coldAnalysis = try await estimator.estimate(for: .exposure, bitmap: source, settings: settings)
        let coldAnalysisMS = milliseconds(coldAnalysisStart.duration(to: .now))
        let warmAnalysisStart = ContinuousClock.now
        let warmAnalysis = try await estimator.estimate(for: .exposure, bitmap: source, settings: settings)
        let warmAnalysisMS = milliseconds(warmAnalysisStart.duration(to: .now))
        #expect(coldAnalysis == warmAnalysis)

        let display = TonePerformanceDisplay()
        let burstStart = ContinuousClock.now
        var lastEvent = burstStart
        var tasks: [Task<PreviewBitmap, Error>] = []
        defer { for task in tasks { task.cancel() } }
        let events = 24
        var finalSettings = settings
        for revision in 1...events {
            tasks.last?.cancel()
            if measuresLevels { settings.levels.master.gamma = 0.9 + Double(revision) * 0.025 }
            else { settings.exposure = -0.3 + Double(revision) * 0.025 }
            finalSettings = settings
            let captured = settings
            await display.expect(revision)
            lastEvent = .now
            tasks.append(Task {
                // Match the production view's coalescing interval. Source cache
                // is queried for each surviving event, without another RAW read.
                try await Task.sleep(for: .milliseconds(45))
                let base = try await originals.image(for: request, priority: .selected)
                let result = try await adjusted.image(base, request: request, settings: captured,
                    priority: .selected, maximumOutputPixelSize: edge)
                try Task.checkCancellation()
                await display.accept(revision: revision, settings: captured)
                return result
            })
            if revision < events { try await Task.sleep(for: .milliseconds(10)) }
        }
        let finalTask = try #require(tasks.last)
        let final = try await finalTask.value
        let completed = ContinuousClock.now
        var cancelled = 0
        for task in tasks.dropLast() {
            do { _ = try await task.value }
            catch is CancellationError { cancelled += 1 }
        }
        let displayed = await display.state()
        #expect(displayed.revision == events)
        #expect(displayed.settings == finalSettings, "An older completed render must not replace the newest slider revision")
        let cachedFinal = try await adjusted.image(source, request: request, settings: finalSettings,
            priority: .selected, maximumOutputPixelSize: edge)
        let finalOutputCacheHit = cachedFinal.image === final.image
        #expect(cachedFinal.image.width == final.image.width && cachedFinal.image.height == final.image.height)
        let state = await adjusted.state()
        #expect(state.runningSelected == 0 && state.queuedCount == 0)
        let measured = counts.values()
        let rangeProof = session.levelsRangeDiagnostics()
        if measuresLevels {
            #expect(rangeProof.measurements == 1, "Levels-only changes must reuse the same upstream range proof, including adaptive proxies")
            #expect(rangeProof.cacheHits >= 4)
        }
        #expect(measured.decodes == 1, "Cold/warm analysis and the slider burst must reuse the single RAW decode")
        #expect(measured.maximumActiveRenders == 1)
        #expect(try hash(originalURL) == originalHash)
        var usage = rusage()
        let peakRSS = getrusage(RUSAGE_SELF, &usage) == 0 ? Int64(usage.ru_maxrss) : -1
        let report: [String: Any] = [
            "schema_version": 1, "pipeline_version": settings.toneProcessingVersion.rawValue,
            "levels_active": measuresLevels, "changed_parameter": measuresLevels ? "levels.master.gamma" : "exposure",
            "levels_range_measurements": rangeProof.measurements, "levels_range_cache_hits": rangeProof.cacheHits,
            "source_sha256": originalHash, "source_type": identifier,
            "source_width": source.image.width, "source_height": source.image.height,
            "source_long_edge": source.sourceLongEdge, "source_bits_per_component": source.image.bitsPerComponent,
            "source_profile": source.image.colorSpace?.name as String? ?? "unknown",
            "source_range": String(describing: source.rangeProvenance),
            "maximum_output_edge": edge, "output_width": final.image.width, "output_height": final.image.height,
            "cold_decode_ms": coldDecodeMS, "warm_source_memory_cache_ms": warmSourceMS,
            "cold_admitted_render_ms": coldRenderMS, "warm_output_cache_ms": warmOutputMS,
            "warm_output_cache_hit": outputCacheHit, "final_output_cache_hit": finalOutputCacheHit,
            "warm_session_changed_parameter_render_ms": warmRenderMS,
            "cold_float_analysis_ms": coldAnalysisMS, "warm_float_analysis_ms": warmAnalysisMS,
            "analysis_result": String(describing: coldAnalysis),
            "float_analysis_readback_plan_bytes": FloatAnalysis.maximumWorkingBytes,
            "slider_events": events, "slider_interval_ms": 10, "coalescing_ms": 45,
            "slider_cancelled_requests": cancelled,
            "slider_total_ms": milliseconds(burstStart.duration(to: completed)),
            "slider_final_latency_ms": milliseconds(lastEvent.duration(to: completed)),
            "latest_displayed_revision": displayed.revision, "raw_decode_count": measured.decodes,
            "actual_render_count": measured.renders, "maximum_active_render_workers": measured.maximumActiveRenders,
            "process_peak_rss_bytes": peakRSS,
            "scope": "Single explicit local RAW, fresh in-memory decode/render pipelines at the reported maximum_output_edge. OS, ImageIO and shader caches were not flushed; source hashing occurs before timing. Warm-session render samples change the reported parameter and retain the same prefix. The existing edited cache remains limited to 32 MiB; large-frame cache misses are explicitly reported. Float analysis targets SDR and may correctly return no proposal. Rendering and analysis phases run sequentially. The slider burst uses the existing bounded preview pipeline and 45 ms coalescing. macOS ru_maxrss is bytes and is cumulative for this entire test process. No UI display latency, cross-device speedup or general quality claim is measured."
        ]
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("glowroom-tone-performance-\(UUID()).json")
        try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted]).write(to: output, options: .atomic)
        print("V2 RAW measurement JSON: \(output.path); cold decode \(coldDecodeMS) ms, admitted render \(coldRenderMS) ms, warm-session renders \(warmRenderMS) ms, float analysis cold/warm \(coldAnalysisMS)/\(warmAnalysisMS) ms, peak process RSS \(peakRSS) bytes")
    }

    private func milliseconds(_ duration: Duration) -> Double {
        let value = duration.components
        return Double(value.seconds) * 1_000 + Double(value.attoseconds) / 1_000_000_000_000_000
    }

    private func hash(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var digest = SHA256()
        while let bytes = try handle.read(upToCount: 1_048_576), !bytes.isEmpty { digest.update(data: bytes) }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

private actor TonePerformanceDisplay {
    private var expectedRevision = 0
    private var acceptedRevision = 0
    private var acceptedSettings: EditSettings?
    func expect(_ revision: Int) { expectedRevision = revision }
    func accept(revision: Int, settings: EditSettings) {
        guard revision == expectedRevision else { return }
        acceptedRevision = revision; acceptedSettings = settings
    }
    func state() -> (revision: Int, settings: EditSettings?) { (acceptedRevision, acceptedSettings) }
}

private final class TonePerformanceCounts: @unchecked Sendable {
    private let lock = NSLock()
    private var decodes = 0, renders = 0, activeRenders = 0, maximumActiveRenders = 0
    func decoded() { lock.lock(); decodes += 1; lock.unlock() }
    func beginRender() {
        lock.lock(); defer { lock.unlock() }
        renders += 1; activeRenders += 1; maximumActiveRenders = max(maximumActiveRenders, activeRenders)
    }
    func endRender() { lock.lock(); activeRenders -= 1; lock.unlock() }
    func values() -> (decodes: Int, renders: Int, maximumActiveRenders: Int) {
        lock.lock(); defer { lock.unlock() }
        return (decodes, renders, maximumActiveRenders)
    }
}
