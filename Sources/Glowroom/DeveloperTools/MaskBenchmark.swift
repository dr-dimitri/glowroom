#if GLOWROOM_EDITING_BENCHMARK
import CoreGraphics
import CryptoKit
import Darwin
import Foundation
import GlowroomCore

/// Runs the real canonical-mask worker inside the normal release app target.
/// Timed variants are serial: concurrent CPU work would distort comparisons.
enum MaskBenchmark {
    final class Timings: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String: Double] = [:]
        func record(_ timing: MaskRasterTiming) {
            lock.lock(); defer { lock.unlock() }
            values[timing.phase.rawValue + (timing.completed ? "" : "_incomplete")] = Double(timing.elapsedNanoseconds) / 1e6
        }
        func snapshot() -> [String: Double] { lock.lock(); defer { lock.unlock() }; return values }
    }

    struct Sample {
        let backend: String
        let elapsed: Double
        let cpu: Double
        let phases: [String: Double]
    }

    static func run(_ options: Benchmark.Options) async throws {
        guard options.width <= 16_777_216 / options.height,
              options.maskFixture == "all" || MaskBenchmarkFixtures.names.contains(options.maskFixture),
              options.maskWorkload == "all" || MaskBenchmarkFixtures.workloads.contains(options.maskWorkload),
              ["compare", "reference", "swift", "rust", "validate"].contains(options.maskBackend) else {
            throw Benchmark.failure("Use masks --mask-fixture all|few-soft|many-mixed|narrow|edges --mask-workload all|snapshot|append|active|history --mask-backend compare|reference|swift|rust|validate; native canvas <=16,777,216 pixels")
        }
        let rust = options.maskLibrary.isEmpty ? nil : try RustMaskResampler(path: options.maskLibrary)
        if options.maskBackend == "rust", rust == nil {
            throw Benchmark.failure("Rust comparison requires --mask-library /absolute/path/libglowroom_mask_performance.dylib")
        }
        let backends = options.maskBackend == "compare" || options.maskBackend == "validate"
            ? ["reference", "swift"] + (rust == nil ? [] : ["rust"]) : [options.maskBackend]
        let size = try ArtifactPixelSize(width: options.width, height: options.height)
        let fixtures = options.maskFixture == "all" ? MaskBenchmarkFixtures.names : [options.maskFixture]
        let workloads = options.maskWorkload == "all" ? MaskBenchmarkFixtures.workloads : [options.maskWorkload]
        let environment = ProcessInfo.processInfo.environment
        try validateResamplers(rust: rust)
        try emit(["event": "metadata", "scenario": "canonical-mask", "recipe": MaskBenchmarkFixtures.recipeVersion,
                  "seed": String(options.seed), "width": size.width, "height": size.height,
                  "iterations": options.iterations, "backends": backends,
                  "overlay_max_dimension": MaskOverlayWorker.maximumDimension,
                  "cache_state": "fresh worker per sequence; initial document primed outside timing; warmup iteration excluded",
                  "timing_scope": "actor call through native Gray8 raster, resample, complete SHA-256, CGImage overlay return; no UI presentation",
                  "peak_rss_scope": "whole comparison process including validation and all variants; not per-variant allocation",
                  "system_caches": "not cleared", "optimization": "SwiftPM release; app target",
                  "rust_library": options.maskLibrary,
                  "operating_system": ProcessInfo.processInfo.operatingSystemVersionString,
                  "active_processors": ProcessInfo.processInfo.activeProcessorCount,
                  "physical_memory_bytes": ProcessInfo.processInfo.physicalMemory,
                  "commit": environment["GLOWROOM_BENCHMARK_COMMIT"] ?? "unspecified",
                  "swift_version": environment["GLOWROOM_BENCHMARK_SWIFT_VERSION"] ?? "unspecified",
                  "rust_version": environment["GLOWROOM_BENCHMARK_RUST_VERSION"] ?? "not loaded"])
        for fixture in fixtures {
            for workload in workloads {
                let sequence = try MaskBenchmarkFixtures.sequence(name: fixture, workload: workload, size: size, seed: options.seed)
                let digests = try sequence.documents.map { try digest($0.canonicalData()) }
                try emit(["event": "fixture", "fixture": fixture, "workload": workload,
                          "document_sha256": digests,
                          "initial_document_sha256": try sequence.initial.map { try digest($0.canonicalData()) } ?? "",
                          "strokes": sequence.documents.map { $0.strokes.count },
                          "points": sequence.documents.map { $0.strokes.reduce(0) { $0 + $1.points.count } }])
                // Exact bytes and complete canonical hashes are verified outside
                // acceptance timing; only one pair of native rasters is retained.
                try await validate(sequence: sequence, backends: backends, rust: rust)
                try emit(["event": "validation", "fixture": fixture, "workload": workload,
                          "native_bytes": "exact", "canonical_sha256": "exact", "preview_bytes": "exact",
                          "overlay_bytes": "exact", "documents": sequence.documents.count])
                if options.maskBackend == "validate" { continue }
                var samples: [Sample] = []
                for iteration in 0...options.iterations {
                    // Rotate order so a variant cannot always benefit from being
                    // second. The first complete sequence is an explicit warmup.
                    let offset = iteration % backends.count
                    let order = Array(backends[offset...]) + Array(backends[..<offset])
                    for backend in order {
                        let worker = try makeWorker(backend: backend, rust: rust)
                        let source = sourceIdentity()
                        let session = UUID()
                        if let initial = sequence.initial {
                            _ = try await worker.rasterize(request(initial, source: source, session: session, revision: 1))
                        }
                        for (index, document) in sequence.documents.enumerated() {
                            let timings = Timings()
                            let cpuStart = cpuMilliseconds()
                            let started = ContinuousClock.now
                            let result = try await worker.rasterize(request(document, source: source, session: session,
                                revision: UInt64(index + 2)), timingObserver: { timings.record($0) })
                            let elapsed = Benchmark.milliseconds(started.duration(to: .now))
                            let cpu = cpuMilliseconds() - cpuStart
                            let phases = timings.snapshot()
                            try emit(["event": "sample", "fixture": fixture, "workload": workload, "backend": backend,
                                      "iteration": iteration, "warmup": iteration == 0, "sequence_index": index,
                                      "wall_ms": elapsed, "cpu_ms": cpu, "phases_ms": phases,
                                      "reuse": String(describing: result.nativeRasterReuse),
                                      "canonical_sha256": result.token.maskSHA256,
                                      "peak_rss_bytes": Benchmark.peakRSS()])
                            if iteration > 0 { samples.append(Sample(backend: backend, elapsed: elapsed, cpu: cpu, phases: phases)) }
                        }
                    }
                }
                for backend in backends {
                    let selected = samples.filter { $0.backend == backend }
                    let times = selected.map(\.elapsed)
                    let phases = Set(selected.flatMap { $0.phases.keys })
                    let phaseP50 = Dictionary(uniqueKeysWithValues: phases.map { phase in
                        (phase, percentile(selected.compactMap { $0.phases[phase] }, fraction: 0.5))
                    })
                    try emit(["event": "result", "fixture": fixture, "workload": workload, "backend": backend,
                              "width": size.width, "height": size.height, "samples": times.count,
                              "p50_ms": percentile(times, fraction: 0.5), "p95_ms": percentile(times, fraction: 0.95),
                              "cpu_p50_ms": percentile(selected.map(\.cpu), fraction: 0.5),
                              "requests_per_second": Double(times.count) * 1_000 / times.reduce(0, +),
                              "native_megapixels_per_second": Double(times.count * size.width * size.height) / times.reduce(0, +) / 1_000,
                              "phase_p50_ms": phaseP50, "peak_rss_bytes": Benchmark.peakRSS()])
                }
            }
        }
    }

    private static func validate(sequence: MaskBenchmarkFixtures.Sequence, backends: [String], rust: RustMaskResampler?) async throws {
        var nativeCache = MaskRasterizationCache()
        let source = sourceIdentity(), session = UUID()
        let workers = try backends.map { ($0, try makeWorker(backend: $0, rust: rust)) }
        let reference = MaskOverlayWorker(usesNativeCache: false, usesOptimizedResampling: false)
        if let initial = sequence.initial {
            let update = try nativeCache.rasterize(initial)
            nativeCache = update.cache
            _ = try await reference.rasterize(request(initial, source: source, session: session, revision: 1))
            for (_, worker) in workers { _ = try await worker.rasterize(request(initial, source: source, session: session, revision: 1)) }
        }
        for (index, document) in sequence.documents.enumerated() {
            try autoreleasepool {
                let full = try MaskRasterizer.rasterize(document)
                let update = try nativeCache.rasterize(document)
                guard update.raster.bytes == full.bytes,
                      try update.raster.canonicalSHA256() == full.canonicalSHA256() else {
                    throw Benchmark.failure("Incremental native raster mismatch at revision \(index)")
                }
                nativeCache = update.cache
                // Include unequal dimensions and upscaling, where center clamping
                // matters. This is validation, not the acceptance workload.
                for output in [try ArtifactPixelSize(width: 53, height: 37), try ArtifactPixelSize(width: 97, height: 71)] {
                    let expected = try full.resampled(to: output)
                    guard try full.resampledOptimized(to: output).bytes == expected.bytes else {
                        throw Benchmark.failure("Optimized Swift resample bytes differ")
                    }
                    if let rust, try rust.resample(full, to: output).bytes != expected.bytes {
                        throw Benchmark.failure("Rust resample bytes differ")
                    }
                }
            }
            let job = request(document, source: source, session: session, revision: UInt64(index + 2))
            let expected = try await reference.rasterize(job)
            for (backend, worker) in workers {
                let actual = try await worker.rasterize(job)
                guard actual.token.maskSHA256 == expected.token.maskSHA256,
                      actual.raster.bytes == expected.raster.bytes,
                      overlayBytes(actual.overlay) == overlayBytes(expected.overlay) else {
                    throw Benchmark.failure("Worker bytes/hash mismatch for \(backend) revision \(index)")
                }
            }
        }
    }

    private static func validateResamplers(rust: RustMaskResampler?) throws {
        for source in [try ArtifactPixelSize(width: 1, height: 1), try .init(width: 3, height: 2), try .init(width: 7, height: 19)] {
            let pixels = Data((0..<(source.width * source.height)).map { UInt8(($0 * 71 + 23) % 256) })
            let input = try MaskRaster(size: source, bytes: pixels)
            for output in [source, try .init(width: 1, height: 1), try .init(width: 17, height: 13), try .init(width: 2, height: 23)] {
                let reference = try input.resampled(to: output)
                guard try input.resampledOptimized(to: output) == reference else {
                    throw Benchmark.failure("Swift resample contract differs for \(source) -> \(output)")
                }
                if let rust, try rust.resample(input, to: output) != reference {
                    throw Benchmark.failure("Rust resample contract differs for \(source) -> \(output)")
                }
            }
        }
    }

    private static func makeWorker(backend: String, rust: RustMaskResampler?) throws -> MaskOverlayWorker {
        if backend == "reference" { return MaskOverlayWorker(usesNativeCache: false, usesOptimizedResampling: false) }
        if backend == "rust" {
            guard let rust else { throw Benchmark.failure("Missing Rust library") }
            return MaskOverlayWorker(resampler: { raster, size, cancellation in
                try rust.resample(raster, to: size, cancellation: cancellation)
            })
        }
        return MaskOverlayWorker()
    }

    private static func request(_ document: MaskDocument, source: AISourceIdentity, session: UUID, revision: UInt64) -> MaskRasterRequest {
        MaskRasterRequest(source: source, session: session, revision: revision, document: document, cancellation: MaskRasterCancellation())
    }
    private static func sourceIdentity() -> AISourceIdentity {
        .original(AIOriginalSourceFingerprint(fileURL: URL(fileURLWithPath: "/synthetic-mask-benchmark"),
                                              modifiedAt: .distantPast, fileSize: 0))
    }
    private static func overlayBytes(_ image: CGImage) -> Data? {
        guard let bytes = image.dataProvider?.data else { return nil }
        return bytes as Data
    }
    static func percentile(_ values: [Double], fraction: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        // Nearest-rank p95 (the maximum for fewer than20 samples); interpolated
        // median matches the existing harness's definition for even samples.
        if fraction == 0.5 { return Benchmark.median(sorted) }
        return sorted[max(0, min(sorted.count - 1, Int(ceil(fraction * Double(sorted.count))) - 1))]
    }
    static func cpuMilliseconds() -> Double {
        var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) * 1_000
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000
    }
    private static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func emit(_ value: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])
        FileHandle.standardOutput.write(data); FileHandle.standardOutput.write(Data([10]))
    }
}

/// dlopen is confined to this explicitly selected developer harness. Production
/// app builds compile none of this code and have no Rust toolchain dependency.
final class RustMaskResampler: @unchecked Sendable {
    typealias Cancel = @convention(c) (UnsafeMutableRawPointer?) -> Int32
    typealias Kernel = @convention(c) (UnsafePointer<UInt8>?, Int, Int, Int, Int,
        UnsafeMutablePointer<UInt8>?, Int, Int, Int, Int, Cancel?, UnsafeMutableRawPointer?) -> Int32
    private let library: UnsafeMutableRawPointer
    private let kernel: Kernel

    init(path: String) throws {
        guard path.hasPrefix("/"), let handle = dlopen(path, RTLD_NOW | RTLD_LOCAL) else {
            throw Benchmark.failure("Cannot open explicit Rust prototype library: \(path)")
        }
        guard let symbol = dlsym(handle, "glowroom_mask_resample_v1") else {
            dlclose(handle); throw Benchmark.failure("Rust library lacks glowroom_mask_resample_v1")
        }
        library = handle; kernel = unsafeBitCast(symbol, to: Kernel.self)
    }
    deinit { dlclose(library) }

    private final class Cancellation {
        let check: @Sendable () throws -> Void
        init(_ check: @escaping @Sendable () throws -> Void) { self.check = check }
        func status() -> Int32 { do { try check(); return 0 } catch { return 1 } }
    }

    func resample(_ raster: MaskRaster, to size: ArtifactPixelSize,
                  cancellation: @Sendable () throws -> Void = {}) throws -> MaskRaster {
        try Task.checkCancellation(); try cancellation()
        if raster.size == size { return raster }
        // Swift allocation and the synchronous FFI invocation are inside the
        // timed resampling phase, including the coordinate table allocation.
        return try withoutActuallyEscaping(cancellation) { check in
            let state = Cancellation(check)
            let context = Unmanaged.passUnretained(state).toOpaque()
            let count = size.width * size.height
            var bytes = Data(count: count)
            // The C context is unretained: keep its Swift owner alive through
            // every callback, even when the optimizer shortens local lifetimes.
            let code = withExtendedLifetime(state) {
                bytes.withUnsafeMutableBytes { destination in
                    raster.bytes.withUnsafeBytes { source in
                        kernel(source.bindMemory(to: UInt8.self).baseAddress, raster.bytes.count,
                               raster.size.width, raster.size.height, raster.size.width,
                               destination.bindMemory(to: UInt8.self).baseAddress, count,
                               size.width, size.height, size.width, { pointer in
                                   guard let pointer else { return 1 }
                                   return Unmanaged<Cancellation>.fromOpaque(pointer).takeUnretainedValue().status()
                               }, context)
                    }
                }
            }
            if code == 2 { throw CancellationError() }
            guard code == 0 else { throw Benchmark.failure("Rust resampling error code \(code)") }
            try Task.checkCancellation(); try cancellation()
            return try MaskRaster(size: size, bytes: bytes)
        }
    }
}
#endif
