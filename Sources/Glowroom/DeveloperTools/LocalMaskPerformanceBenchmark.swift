#if GLOWROOM_EDITING_BENCHMARK
import CoreImage
import CryptoKit
import Foundation
import GlowroomCore

/// Measures the current visible editor path, whose direct capped raster is
/// deliberately distinct from native canonical Gray8 + resampling.
enum LocalMaskPerformanceBenchmark {
    static func run(_ options: Benchmark.Options) async throws {
        let size = try ArtifactPixelSize(width: options.width, height: options.height)
        let names = options.maskFixture == "all" ? MaskBenchmarkFixtures.names : [options.maskFixture]
        let workloads = options.maskWorkload == "all" ? MaskBenchmarkFixtures.workloads : [options.maskWorkload]
        let scale = min(1, 2_048 / Double(max(size.width, size.height)))
        let width = max(1, Int((Double(size.width) * scale).rounded()))
        let height = max(1, Int((Double(size.height) * scale).rounded()))
        let extent = CGRect(x: 0, y: 0, width: width, height: height)
        let bitmap = try Benchmark.fixture(width: width, height: height)
        let original = CIImage(cgImage: bitmap.image)
        let context = CIContext(options: [.cacheIntermediates: false])
        for name in names {
            for workload in workloads {
                let sequence = try MaskBenchmarkFixtures.sequence(name: name, workload: workload, size: size, seed: options.seed)
                for iteration in 0...options.iterations {
                    // AB/BA order; comparison includes setup/caches only where
                    // the user's action includes them. Prime is outside timing.
                    var referenceBytes: [Data] = []
                    var candidateBytes: [Data] = []
                    for incremental in (iteration.isMultiple(of: 2) ? [false, true] : [true, false]) {
                        let cache = LocalMaskImageCache(incrementalEnabled: incremental)
                        func render(_ document: MaskDocument) throws -> (Data, Double, Double) {
                            let started = DispatchTime.now().uptimeNanoseconds
                            let layer = try LocalAdjustment(name: "Fixture", mask: .init(shape: .brush(document), feather: 0),
                                                        settings: .init(exposure: 1))
                            let graph = try LocalAdjustmentRenderer.apply(to: original, adjustments: [layer], extent: extent,
                                scale: 1, cache: cache)
                            let graphEnd = DispatchTime.now().uptimeNanoseconds
                            var bytes = Data(count: width * height * 4)
                            bytes.withUnsafeMutableBytes { storage in
                                context.render(graph, toBitmap: storage.baseAddress!, rowBytes: width * 4, bounds: extent,
                                    format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
                            }
                            return (bytes, Double(graphEnd - started) / 1e6,
                                    Double(DispatchTime.now().uptimeNanoseconds - graphEnd) / 1e6)
                        }
                        if let initial = sequence.initial { _ = try render(initial) }
                        let cpuStart = PreviewPerformanceBenchmark.cpuMilliseconds()
                        var total = 0.0
                        for (step, document) in sequence.documents.enumerated() {
                            let sample = try autoreleasepool { try render(document) }
                            if incremental { candidateBytes.append(Data(SHA256.hash(data: sample.0))) } else { referenceBytes.append(Data(SHA256.hash(data: sample.0))) }
                            total += sample.1 + sample.2
                            try PreviewPerformanceBenchmark.emit(["kind": "local-mask-sample", "fixture": name,
                                "workload": workload, "iteration": iteration, "warmup": iteration == 0, "step": step,
                                "backend": incremental ? "swift" : "reference", "canvas_width": size.width,
                                "canvas_height": size.height, "output_width": width, "output_height": height,
                                "graph_ms": sample.1, "render_ms": sample.2, "total_ms": sample.1 + sample.2,
                                "peak_rss_bytes": Benchmark.peakRSS()])
                        }
                        try PreviewPerformanceBenchmark.emit(["kind": "local-mask-sequence", "fixture": name,
                            "workload": workload, "iteration": iteration, "backend": incremental ? "swift" : "reference",
                            "total_ms": total, "diagnostic_cpu_including_verification_ms": PreviewPerformanceBenchmark.cpuMilliseconds() - cpuStart])
                    }
                    guard referenceBytes == candidateBytes else { throw Benchmark.failure("Local mask rendered pixel mismatch") }
                }
            }
        }
    }
}
#endif
