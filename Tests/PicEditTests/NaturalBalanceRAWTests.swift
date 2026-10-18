import CoreGraphics
import CryptoKit
import Darwin
import Foundation
import ImageIO
import PicEditCore
import Testing
import UniformTypeIdentifiers
@testable import PicEdit

/// Explicit local diagnostic only: no RAW or derivative belongs in the repository.
/// Timings are serial because concurrent GPU measurements distort comparisons.
@Suite("Natural balance on an explicitly supplied RAW", .serialized)
struct NaturalBalanceRAWTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["PICEDIT_NATURAL_BALANCE_RAW"]?.isEmpty == false))
    func decodeRenderAndRapidManualEdits() async throws {
        let environment = ProcessInfo.processInfo.environment
        let path = try #require(environment["PICEDIT_NATURAL_BALANCE_RAW"])
        let outputPath = try #require(environment["PICEDIT_NATURAL_BALANCE_OUTPUT"],
                                      "Set an explicit temporary output directory for local RAW diagnostics")
        let sourceURL = URL(fileURLWithPath: path).standardizedFileURL
        let output = URL(fileURLWithPath: outputPath, isDirectory: true).standardizedFileURL
        let resolvedOutput = output.resolvingSymlinksInPath().path
        let temporaryRoot = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let tempRoots = ["/private/tmp/", "/tmp/", "/" + temporaryRoot + "/"]
        #expect(tempRoots.contains { resolvedOutput.hasPrefix($0) }, "RAW derivatives must go to temporary storage")
        guard tempRoots.contains(where: { resolvedOutput.hasPrefix($0) }) else { return }
        guard !FileManager.default.fileExists(atPath: output.path) else { throw CocoaError(.fileWriteFileExists) }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let sourceHash = try hash(sourceURL)
        let values = try sourceURL.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let imageSource = try #require(CGImageSourceCreateWithURL(sourceURL as CFURL, nil))
        let identifier = try #require(CGImageSourceGetType(imageSource))
        #expect(PreviewDecoder.isCameraRAWTypeIdentifier(identifier as String), "This harness requires a real camera RAW")
        guard PreviewDecoder.isCameraRAWTypeIdentifier(identifier as String) else { return }
        let request = PreviewRequest(url: sourceURL, modifiedAt: values.contentModificationDate ?? .distantPast,
            pixelSize: 2_400, fileSize: Int64(values.fileSize ?? 0), allowsEmbeddedPreview: false)
        let counts = NaturalBalanceDiagnosticCounts()
        let originals = ImagePreviewPipeline(diskCache: nil, decoder: { request in
            counts.decoded()
            return try PreviewDecoder.decode(request)
        })
        let decodeStart = ContinuousClock.now
        let source = try await originals.image(for: request, priority: .selected)
        let coldDecodeMS = milliseconds(decodeStart.duration(to: .now))
        let cacheStart = ContinuousClock.now
        let reused = try await originals.image(for: request, priority: .selected)
        let warmSourceMS = milliseconds(cacheStart.duration(to: .now))
        #expect(reused.image === source.image)
        #expect(max(source.image.width, source.image.height) <= 2_400)
        try png(source.image, to: output.appendingPathComponent("before.png"))

        var moderate = EditSettings.neutral
        moderate.naturalBalanceAmount = 70
        moderate.naturalBalanceColorAmount = 50
        var maximum = moderate
        maximum.naturalBalanceAmount = 100
        maximum.naturalBalanceColorAmount = 100
        let session = EditRenderer.Session(cacheIntermediates: true, lowPriority: false)
        let coldRenderStart = ContinuousClock.now
        let balanced = try EditRenderer.render(source, settings: moderate, session: session)
        let coldRenderMS = milliseconds(coldRenderStart.duration(to: .now))
        let analysis = try NaturalBalanceAnalysisCache.shared.analysis(for: source.image)
        try png(balanced.image, to: output.appendingPathComponent("natural-70-color-50.png"))
        var warmRenderMS: [Double] = []
        for _ in 0..<5 {
            let start = ContinuousClock.now
            let result = try EditRenderer.render(source, settings: moderate, session: session)
            warmRenderMS.append(milliseconds(start.duration(to: .now)))
            #expect(result.image.width == source.image.width && result.image.height == source.image.height)
        }
        let maximumStart = ContinuousClock.now
        let strongest = try EditRenderer.render(source, settings: maximum, session: session)
        let maximumRenderMS = milliseconds(maximumStart.duration(to: .now))
        try png(strongest.image, to: output.appendingPathComponent("natural-100-color-100.png"))

        let edited = AdjustedPreviewPipeline(renderer: { source, settings in
            counts.rendered()
            return try EditRenderer.render(source, settings: settings, session: session)
        })
        // Match the UI's 45 ms coalescing window while changing manual exposure.
        // The source pipeline is intentionally queried again for every event.
        let burstStart = ContinuousClock.now
        var lastEvent = burstStart
        var tasks: [Task<PreviewBitmap, Error>] = []
        var finalSettings = moderate
        for step in 1...24 {
            tasks.last?.cancel()
            var settings = moderate
            settings.exposure = Double(step) * 0.01
            finalSettings = settings
            let capturedSettings = settings
            lastEvent = .now
            tasks.append(Task {
                try await Task.sleep(for: .milliseconds(45))
                let base = try await originals.image(for: request, priority: .selected)
                return try await edited.image(base, request: request, settings: capturedSettings, priority: .selected)
            })
            if step < 24 { try await Task.sleep(for: .milliseconds(10)) }
        }
        let lastTask = try #require(tasks.last)
        let final = try await lastTask.value
        let completed = ContinuousClock.now
        var cancelledCount = 0
        for task in tasks.dropLast() {
            do { _ = try await task.value }
            catch is CancellationError { cancelledCount += 1 }
        }
        let expected = try EditRenderer.render(source, settings: finalSettings, session: session)
        #expect(try rasterHash(final.image) == rasterHash(expected.image), "The final manual setting must win the slider burst")
        #expect(counts.values().decodes == 1, "Slider movement must not decode the RAW again")
        #expect(try hash(sourceURL) == sourceHash, "The original RAW must remain byte-for-byte unchanged")
        var usage = rusage()
        let measuredRSS = getrusage(RUSAGE_SELF, &usage) == 0 ? Int64(usage.ru_maxrss) : -1
        let report: [String: Any] = [
            "source_sha256": sourceHash,
            "source_type": identifier as String,
            "width": source.image.width, "height": source.image.height,
            "source_bits_per_component": source.image.bitsPerComponent,
            "profile": source.image.colorSpace?.name as String? ?? "unknown",
            "embedded_camera_preview_allowed": false,
            "detected_faces": analysis.faceCount,
            "analysis_tone_offsets": analysis.offsets,
            "analysis_color_boost": analysis.colorBoost,
            "cold_source_decode_ms": coldDecodeMS,
            "warm_source_memory_cache_ms": warmSourceMS,
            "cold_render_70_50_ms": coldRenderMS,
            "warm_render_70_50_ms": warmRenderMS,
            "changed_render_100_100_ms": maximumRenderMS,
            "slider_events": 24, "slider_interval_ms": 10, "debounce_ms": 45,
            "slider_cancelled_requests": cancelledCount,
            "slider_total_ms": milliseconds(burstStart.duration(to: completed)),
            "slider_final_latency_ms": milliseconds(lastEvent.duration(to: completed)),
            "raw_decode_count": counts.values().decodes,
            "slider_render_count": counts.values().renders,
            "process_peak_rss_bytes": measuredRSS,
            "scope": "Local 2400 px RAW preview diagnostic. Cold means first request in this process, not flushed OS/GPU caches. Render timings include synchronous CI materialization but exclude PNG writing and UI display. Warm source uses the in-memory decoded basis. RSS is cumulative for the entire test process. One supplied photograph is not a general quality or performance proof."
        ]
        let reportData = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try reportData.write(to: output.appendingPathComponent("report.json"), options: .atomic)
        print("Natural balance RAW diagnostic: \(output.path); cold decode \(coldDecodeMS) ms, cold render \(coldRenderMS) ms, warm renders \(warmRenderMS) ms; RAW decodes \(counts.values().decodes), burst renders \(counts.values().renders), peak RSS \(measuredRSS) bytes")
    }

    private func milliseconds(_ value: Duration) -> Double {
        let components = value.components
        return Double(components.seconds) * 1_000 + Double(components.attoseconds) / 1_000_000_000_000_000
    }

    private func hash(_ url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url, options: .mappedIfSafe)).map { String(format: "%02x", $0) }.joined()
    }

    private func rasterHash(_ image: CGImage) throws -> String {
        let context = try #require(CGContext(data: nil, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: image.width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setBlendMode(.copy)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let data = try #require(context.data)
        return SHA256.hash(data: Data(bytes: data, count: context.bytesPerRow * context.height)).map { String(format: "%02x", $0) }.joined()
    }

    private func png(_ image: CGImage, to url: URL) throws {
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
    }
}

private final class NaturalBalanceDiagnosticCounts: @unchecked Sendable {
    private let lock = NSLock()
    private var decodes = 0
    private var renders = 0
    func decoded() { lock.lock(); decodes += 1; lock.unlock() }
    func rendered() { lock.lock(); renders += 1; lock.unlock() }
    func values() -> (decodes: Int, renders: Int) { lock.lock(); defer { lock.unlock() }; return (decodes, renders) }
}
