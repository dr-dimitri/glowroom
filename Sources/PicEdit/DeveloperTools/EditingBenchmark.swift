#if PICEDIT_EDITING_BENCHMARK
import CoreGraphics
import Darwin
import Foundation
import PicEditCore

// All inputs are generated in memory. Direct scenarios bypass the edited-output
// cache and change exposure on every call; the final draw forces deferred Core
// Image work to finish. Timings include CPU readback/display conversion, but no
// ImageIO/RAW decode, disk cache, UI layout, or window presentation.
final class Counts: @unchecked Sendable {
    private let lock = NSLock()
    private var decodes = 0
    private var renders = 0
    func decoded() { lock.lock(); decodes += 1; lock.unlock() }
    func rendered() { lock.lock(); renders += 1; lock.unlock() }
    func values() -> (Int, Int) { lock.lock(); defer { lock.unlock() }; return (decodes, renders) }
}

@main struct Benchmark {
    struct Options {
        var scenario = "complex"
        var backend = "default"
        var workers = 1
        var width = 2_400
        var height = 1_600
        var iterations = 8
        var evaluationMode = "quality"
        var output = ""
        var manifest = ""
        var registry = ""
        var input = ""

        init() throws {
            let args = Array(CommandLine.arguments.dropFirst())
            guard args.count.isMultiple(of: 2) else { throw failure("Options require values") }
            for index in stride(from: 0, to: args.count, by: 2) {
                let value = args[index + 1]
                switch args[index] {
                case "--scenario": scenario = value
                case "--backend": backend = value
                case "--workers": workers = Int(value) ?? 0
                case "--width": width = Int(value) ?? 0
                case "--height": height = Int(value) ?? 0
                case "--iterations": iterations = Int(value) ?? 0
                case "--evaluation-mode": evaluationMode = value
                case "--output": output = value
                case "--manifest": manifest = value
                case "--registry": registry = value
                case "--input": input = value
                default: throw failure("Unknown option: \(args[index])")
                }
            }
            guard ["simple", "complex", "alternating", "burst", "contention", "evaluation"].contains(scenario),
                  ["default", "cached", "uncached", "software-request"].contains(backend),
                  (1...2).contains(workers),
                  (1...(scenario == "evaluation" ? 8_192 : 4_096)).contains(width),
                  (1...(scenario == "evaluation" ? 8_192 : 4_096)).contains(height),
                  (1...100).contains(iterations) else {
                throw failure("Use --scenario simple|complex|alternating|burst|contention --backend default|cached|uncached|software-request --workers 1|2 --width 1...4096 --height 1...4096 --iterations 1...100")
            }
        }
    }

    static func main() async throws {
        let options = try Options()
        if options.scenario == "evaluation" {
            try AlgorithmEvaluation.run(options)
            return
        }
        log("Synthetic \(options.scenario) editing benchmark: \(options.width)x\(options.height), backend=\(options.backend), optimized binary, generated sRGB input; no RAW/ImageIO or disk I/O.")
        log("First call includes renderer initialization; warm calls use the same source with unique edits, not cached edited output. OS/GPU caches are not cleared.")
        log("End-to-end timings include a synchronous full-size CGContext draw, forcing pixel materialization. Peak RSS covers the entire process.")
        let bitmap = try fixture(width: options.width, height: options.height)
        let sink = try bitmapContext(width: options.width, height: options.height)
        let render = try renderer(backend: options.backend)
        if options.scenario == "contention" {
            try await contention(bitmap: bitmap, sink: sink, options: options)
        } else if options.scenario == "burst" {
            try await burst(bitmap: bitmap, sink: sink, render: render)
        } else {
            try direct(bitmap: bitmap, sink: sink, options: options, render: render)
        }
    }

    typealias Render = @Sendable (PreviewBitmap, EditSettings) throws -> PreviewBitmap

    static func renderer(backend: String) throws -> Render {
        if backend == "default" { return { try EditRenderer.render($0, settings: $1) } }
        #if EDIT_RENDER_SESSIONS
        // Core Image may ignore a software preference on some systems. This is
        // a requested option, not evidence that a CPU backend actually ran.
        let session = EditRenderer.Session(cacheIntermediates: backend == "cached", lowPriority: false,
                                           softwareRenderer: backend == "software-request")
        return { try EditRenderer.render($0, settings: $1, session: session) }
        #else
        throw failure("Alternate backends require PICEDIT_BENCHMARK_SESSION_API=1 and sources with EditRenderer.Session")
        #endif
    }

    static func direct(bitmap: PreviewBitmap, sink: CGContext, options: Options, render: Render) throws {
        let alternate = options.scenario == "alternating" ? try fixture(width: options.width, height: options.height, variant: 1) : bitmap
        var elapsed: [Double] = []
        var renderTimes: [Double] = []
        var drawTimes: [Double] = []
        var aggregate: UInt64 = 0
        for step in 0...options.iterations {
            let settings = settings(step: step, complex: options.scenario != "simple")
            let sample: (Double, Double, UInt64) = try autoreleasepool {
                let start = ContinuousClock.now
                let output = try render(step.isMultiple(of: 2) ? bitmap : alternate, settings)
                let rendered = ContinuousClock.now
                let checksum = materialize(output.image, into: sink)
                let end = ContinuousClock.now
                return (milliseconds(start.duration(to: rendered)), milliseconds(rendered.duration(to: end)), checksum)
            }
            aggregate = (aggregate &* 16_777_619) ^ sample.2
            log("sample=\(step), exposure=\(settings.exposure), render_ms=\(format(sample.0)), materialize_ms=\(format(sample.1)), total_ms=\(format(sample.0 + sample.1)), checksum=\(sample.2)")
            if step > 0 {
                elapsed.append(sample.0 + sample.1)
                renderTimes.append(sample.0)
                drawTimes.append(sample.1)
            }
        }
        log("RESULT scenario=\(options.scenario), size=\(options.width)x\(options.height), warm_samples=\(elapsed.count), warm_median_ms=\(format(median(elapsed))), warm_render_median_ms=\(format(median(renderTimes))), warm_materialize_median_ms=\(format(median(drawTimes))), warm_min_ms=\(format(elapsed.min()!)), warm_max_ms=\(format(elapsed.max()!)), warm_fps=\(format(Double(elapsed.count) * 1_000 / elapsed.reduce(0, +))), peak_rss_bytes=\(peakRSS()), checksum=\(aggregate)")
    }

    static func burst(bitmap: PreviewBitmap, sink: CGContext, render: @escaping Render) async throws {
        let counts = Counts()
        let originals = ImagePreviewPipeline(diskCache: nil, decoder: { _ in counts.decoded(); return bitmap })
        let edits = AdjustedPreviewPipeline(renderer: { source, settings in
            counts.rendered()
            return try render(source, settings)
        })
        let request = PreviewRequest(url: URL(fileURLWithPath: "/synthetic-gradient"), modifiedAt: .distantPast,
                                     pixelSize: max(bitmap.image.width, bitmap.image.height), allowsEmbeddedPreview: false)
        let source = try await originals.image(for: request, priority: .selected)
        for (label, offset) in [("cold-output-cache", 0), ("warm-output-cache", 0), ("warm-renderer-new-settings", 24)] {
            log("Starting \(label): 24 slider events at 10 ms, 45 ms UI debounce")
            let before = counts.values()
            let start = ContinuousClock.now
            var lastEvent = start
            var tasks: [Task<PreviewBitmap, Error>] = []
            for step in 1...24 {
                tasks.last?.cancel()
                let settings = settings(step: step + offset, complex: true)
                lastEvent = .now
                tasks.append(Task {
                    try await Task.sleep(for: .milliseconds(45))
                    return try await edits.image(source, request: request, settings: settings, priority: .selected)
                })
                if step < 24 { try await Task.sleep(for: .milliseconds(10)) }
            }
            guard let final = tasks.last else { return }
            let output = try await final.value
            let checksum = materialize(output.image, into: sink)
            let completed = ContinuousClock.now
            for task in tasks.dropLast() { _ = try? await task.value }
            let after = counts.values()
            log("RESULT scenario=burst, cache=\(label), size=\(bitmap.image.width)x\(bitmap.image.height), final_latency_ms=\(format(milliseconds(lastEvent.duration(to: completed)))), total_ms=\(format(milliseconds(start.duration(to: completed)))), new_decodes=\(after.0 - before.0), renders=\(after.1 - before.1), total_decodes=\(after.0), peak_rss_bytes=\(peakRSS()), checksum=\(checksum)")
        }
    }

    static func contention(bitmap: PreviewBitmap, sink: CGContext, options: Options) async throws {
        #if EDIT_RENDER_SESSIONS
        guard options.backend == "default" else { throw failure("Contention uses the production renderer with priority routing") }
        let edits = AdjustedPreviewPipeline(maximumConcurrentRenders: options.workers)
        #else
        guard options.workers == 1 else { throw failure("Two lanes require PICEDIT_BENCHMARK_SESSION_API=1 and updated pipeline sources") }
        let edits = AdjustedPreviewPipeline()
        #endif
        let thumbnail = try fixture(width: 1_536, height: 1_024, variant: 1)
        let thumbnailSink = try bitmapContext(width: 1_536, height: 1_024)
        let thumbnailRequest = PreviewRequest(url: URL(fileURLWithPath: "/synthetic-background"), modifiedAt: .distantPast,
                                              pixelSize: 1_536, allowsEmbeddedPreview: false)
        let selectedRequest = PreviewRequest(url: URL(fileURLWithPath: "/synthetic-selected"), modifiedAt: .distantPast,
                                             pixelSize: max(bitmap.image.width, bitmap.image.height), allowsEmbeddedPreview: false)
        // Warm both priority-specific contexts before timing actual contention.
        _ = materialize(try await edits.image(thumbnail, request: thumbnailRequest, settings: settings(step: 0, complex: true), priority: .thumbnail).image, into: thumbnailSink)
        _ = materialize(try await edits.image(bitmap, request: selectedRequest, settings: settings(step: 0, complex: false), priority: .selected).image, into: sink)
        var latencies: [Double] = []
        var totals: [Double] = []
        var aggregate: UInt64 = 0
        for step in 1...options.iterations {
            let started = ContinuousClock.now
            let backgroundSettings = settings(step: step, complex: true)
            let background = Task {
                try await edits.image(thumbnail, request: thumbnailRequest, settings: backgroundSettings, priority: .thumbnail)
            }
            // Represents a selection arriving shortly after background work.
            // This is a timing workload, not proof of a particular scheduler interleaving.
            try await Task.sleep(for: .milliseconds(1))
            let selectedStarted = ContinuousClock.now
            let selected = try await edits.image(bitmap, request: selectedRequest, settings: settings(step: step, complex: false), priority: .selected)
            aggregate ^= materialize(selected.image, into: sink)
            let selectedFinished = ContinuousClock.now
            aggregate ^= materialize(try await background.value.image, into: thumbnailSink)
            let finished = ContinuousClock.now
            let latency = milliseconds(selectedStarted.duration(to: selectedFinished))
            let total = milliseconds(started.duration(to: finished))
            latencies.append(latency)
            totals.append(total)
            log("sample=\(step), workers=\(options.workers), selected_latency_ms=\(format(latency)), pair_total_ms=\(format(total))")
        }
        log("RESULT scenario=contention, workers=\(options.workers), selected_size=\(bitmap.image.width)x\(bitmap.image.height), background_size=1536x1024, samples=\(options.iterations), selected_median_ms=\(format(median(latencies))), pair_median_ms=\(format(median(totals))), pairs_per_second=\(format(Double(totals.count) * 1_000 / totals.reduce(0, +))), peak_rss_bytes=\(peakRSS()), checksum=\(aggregate)")
    }

    static func settings(step: Int, complex: Bool) -> EditSettings {
        var result = EditSettings.neutral
        result.exposure = 0.25 + Double(step) * 0.035
        if complex {
            result.autoToneAmount = 20
            result.texture = 25
            result.clarity = 15
            result.colorNoiseReduction = 20
        }
        return result
    }

    static func materialize(_ image: CGImage, into context: CGContext) -> UInt64 {
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let data = context.data!.assumingMemoryBound(to: UInt8.self)
        // Sparse checksum confirms consumption without timing a full CPU hash.
        var checksum: UInt64 = 2_166_136_261
        for index in stride(from: 0, to: context.bytesPerRow * context.height, by: 1_021) {
            checksum = (checksum ^ UInt64(data[index])) &* 16_777_619
        }
        return checksum
    }

    static func bitmapContext(width: Int, height: Int) throws -> CGContext {
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw EditRenderError.unavailable
        }
        context.setBlendMode(.copy)
        return context
    }

    static func fixture(width: Int, height: Int, variant: Int = 0) throws -> PreviewBitmap {
        let context = try bitmapContext(width: width, height: height)
        let pixels = context.data!.assumingMemoryBound(to: UInt8.self)
        for y in 0..<height {
            for x in 0..<width {
                let index = (y * width + x) * 4
                let texture = (x * 13 + y * 37) % 31 - 15
                pixels[index] = UInt8(clamping: (variant == 0 ? x : width - x) * 230 / width + 12 + texture)
                pixels[index + 1] = UInt8(clamping: y * 230 / height + 12 + texture)
                pixels[index + 2] = UInt8(clamping: (x + y) * 230 / (width + height) + 12 - texture)
                pixels[index + 3] = 255
            }
        }
        guard let image = context.makeImage() else { throw EditRenderError.unavailable }
        return PreviewBitmap(image: image)
    }

    static func milliseconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) * 1_000 + Double(parts.attoseconds) / 1e15
    }
    static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }
    static func format(_ value: Double) -> String { String(format: "%.3f", value) }
    static func peakRSS() -> Int {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return usage.ru_maxrss
    }
    static func failure(_ message: String) -> NSError {
        NSError(domain: "PicEditBenchmark", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
    static func log(_ text: String) { FileHandle.standardOutput.write(Data((text + "\n").utf8)) }
}

#endif
