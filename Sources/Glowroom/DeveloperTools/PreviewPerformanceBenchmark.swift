#if GLOWROOM_EDITING_BENCHMARK
import AppKit
import Darwin
import Foundation

final class PipelineTraceCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [PipelineTrace.Sample] = []
    func record(_ sample: PipelineTrace.Sample) { lock.lock(); values.append(sample); lock.unlock() }
    func samples() -> [PipelineTrace.Sample] { lock.lock(); defer { lock.unlock() }; return values }
}

/// Explicit local inputs only; never scans a user's library. JSON contains no
/// path, metadata, image samples or originals. Real RAW coverage is opt-in.
enum PreviewPerformanceBenchmark {
    static func run(_ options: Benchmark.Options) async throws {
        guard !options.input.isEmpty else { throw Benchmark.failure("preview requires --input /explicit/local/image") }
        let url = URL(fileURLWithPath: options.input)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let request = PreviewRequest(url: url, modifiedAt: attributes[.modificationDate] as? Date ?? .distantPast,
            pixelSize: min(4_096, options.width), fileSize: (attributes[.size] as? NSNumber)?.int64Value ?? 0,
            allowsEmbeddedPreview: false)
        for iteration in 0..<options.iterations {
            let originals = ImagePreviewPipeline(diskCache: nil)
            let edits = AdjustedPreviewPipeline()
            // Only the first sample in the process is a fresh renderer. Later
            // fresh-pipeline samples still benefit from OS and CI/Shader caches.
            for (state, step) in [("fresh-pipelines", iteration + 1), ("warm-output", iteration + 1),
                                  ("warm-renderer", iteration + 101)] {
                let collector = PipelineTraceCollector()
                let cpuStart = cpuMilliseconds()
                let started = DispatchTime.now().uptimeNanoseconds
                let result = try await PipelineTrace.$observer.withValue({ collector.record($0) }) {
                    let source = try await originals.image(for: request, priority: .selected)
                    let settings = Benchmark.settings(step: step, complex: true)
                    let output = try await edits.image(source, request: request, settings: settings, priority: .selected)
                    let handoff = PipelineTrace.begin(.uiHandoff)
                    await MainActor.run {
                        let image = NSImage(cgImage: output.image, size: NSSize(width: output.image.width, height: output.image.height))
                        withExtendedLifetime(image) {}
                    }
                    handoff.end()
                    return output
                }
                let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1e6
                let cpu = cpuMilliseconds() - cpuStart
                // Consumption/correctness work stays outside both latency/CPU
                // timing and the UI handoff; createCGImage already materializes.
                let checksum = try await Task.detached {
                    let sink = try Benchmark.bitmapContext(width: result.image.width, height: result.image.height)
                    return Benchmark.materialize(result.image, into: sink)
                }.value
                var phases: [String: Double] = [:]
                for sample in collector.samples() { phases[sample.phase.rawValue, default: 0] += Double(sample.nanoseconds) / 1e6 }
                try emit(["kind": "preview-sample", "iteration": iteration, "cache": state,
                    "fresh_renderer": iteration == 0 && state == "fresh-pipelines", "width": result.image.width, "height": result.image.height,
                    "total_ms": elapsed, "cpu_ms": cpu, "phases_ms": phases,
                    "checksum": String(checksum), "peak_rss_bytes": Benchmark.peakRSS()])
            }
        }
    }

    static func cpuMilliseconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) * 1_000
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000
    }
    static func emit(_ object: [String: Any]) throws {
        let bytes = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        FileHandle.standardOutput.write(bytes + Data([10]))
    }
}
#endif
