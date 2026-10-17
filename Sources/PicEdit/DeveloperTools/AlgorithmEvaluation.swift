#if PICEDIT_EDITING_BENCHMARK
import CoreGraphics
import CoreImage
import CryptoKit
import Foundation
import ImageIO
import PicEditCore
import UniformTypeIdentifiers

/// Quality mode extends the existing editing benchmark; it never launches the
/// app or opens a catalog. Measurement runs are intentionally serial: parallel
/// CPU/GPU loads would invalidate the performance comparison.
enum AlgorithmEvaluation {
    static let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    static func context() -> CIContext {
        CIContext(options: [.workingColorSpace: space, .workingFormat: CIFormat.RGBAh,
                            .cacheIntermediates: true, .name: "PicEdit LC-01 evaluation"])
    }

    static func run(_ options: Benchmark.Options) throws {
        if options.evaluationMode.hasPrefix("color-") {
            try LightcraftColorEvaluation.run(options)
            return
        }
        if options.evaluationMode.hasPrefix("detail-") {
            try LightcraftDetailEvaluation.run(options)
            return
        }
        if options.evaluationMode.hasPrefix("tone-") {
            try LightcraftToneEvaluation.run(options)
            return
        }
        guard !options.output.isEmpty, options.backend == "default", options.workers == 1,
              ["quality", "timing", "scale"].contains(options.evaluationMode),
              options.width * options.height <= 32_000_000 else {
            throw Benchmark.failure("Evaluation requires --output, --evaluation-mode quality|timing|scale, automatic backend and one worker; maximum 32 megapixels")
        }
        let output = URL(fileURLWithPath: options.output, isDirectory: true)
        guard !FileManager.default.fileExists(atPath: output.path) else { throw Benchmark.failure("Refusing to overwrite evaluation output") }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        switch options.evaluationMode {
        case "quality": try quality(options, output: output)
        case "timing": try timing(options, output: output)
        default: try scale(options, output: output)
        }
    }

    static func render(_ input: AlgorithmEvaluationRaster, settings: EditSettings, context: CIContext) throws -> AlgorithmEvaluationRaster {
        // Conversion, production graph, materialization, readback and
        // unpremultiplication all lie inside the timed adapter boundary.
        let source = try input.cgImage()
        let graph = try EditRenderer.filterGraph(source, settings: settings)
        guard let image = context.createCGImage(graph, from: graph.extent, format: .RGBAf,
                                                colorSpace: space, deferred: false) else { throw EditRenderError.unavailable }
        return try AlgorithmEvaluationRaster.freeze(image)
    }

    static let baselineIDs = ["LC-03", "LC-04", "LC-05", "LC-06"]
    static func settings(_ id: String) -> EditSettings {
        var s = EditSettings.neutral
        switch id {
        case "LC-03": s.shadows = 40; s.highlights = -40
        case "LC-04": s.clarity = 35
        case "LC-05": s.vibrance = 35; s.saturation = 15
        case "LC-06": s.luminanceNoiseReduction = 40; s.colorNoiseReduction = 40
        default: break
        }
        return s
    }

    static func quality(_ options: Benchmark.Options, output: URL) throws {
        guard !options.manifest.isEmpty, !options.registry.isEmpty else { throw Benchmark.failure("Quality requires frozen --manifest and --registry") }
        let manifestURL = URL(fileURLWithPath: options.manifest)
        let manifest = try AlgorithmEvaluationManifest.load(from: manifestURL)
        let registry = try AlgorithmEvaluationCandidateRegistry.load(from: URL(fileURLWithPath: options.registry))
        guard registry.candidates.filter({ $0.kind == "reference" }).allSatisfy({
                  !$0.implemented || ($0.id == "LC-03" && $0.comparisonManifest == "lc03-manifest.json")
                      || ($0.id == "LC-04" && $0.comparisonManifest == "lc04-manifest.json")
                      || ($0.id == "LC-05" && $0.comparisonManifest == "lc05-manifest.json")
              }),
              Set(registry.candidates.filter({ $0.kind == "control" }).map(\.id)) == Set(["unchanged", "neutral-ci", "neutral-rec2020"]) else {
            throw Benchmark.failure("Register an executable comparison adapter before marking a reference implemented")
        }
        let bytes = try Data(contentsOf: manifestURL)
        let manifestSHA = sha(bytes)
        // Persist exact bytes BEFORE opening either tuning or acceptance input.
        try bytes.write(to: output.appendingPathComponent("measurement-manifest.json"), options: .atomic)
        try Data(contentsOf: URL(fileURLWithPath: options.registry)).write(to: output.appendingPathComponent("candidate-registry.json"), options: .atomic)
        let ci = context()
        var records: [[String: Any]] = []
        var failures: [String] = []
        for split in [AlgorithmEvaluationFixtures.Split.tuning, .acceptance] {
            let fixtures = try AlgorithmEvaluationFixtures.make(split: split, width: 192, height: 128)
            for fixture in fixtures {
                try autoreleasepool {
                    let directory = output.appendingPathComponent(fixture.id, isDirectory: true)
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    let input = fixture.input
                    try png(input.previewImage(), directory.appendingPathComponent("input.png"))
                    for id in ["unchanged", "neutral-ci", "neutral-rec2020"] + baselineIDs {
                        let started = ContinuousClock.now
                        let result: AlgorithmEvaluationRaster
                        if id == "unchanged" { result = try AlgorithmEvaluationIdentity().render(input, settings: .neutral) }
                        else if id == "neutral-rec2020" { result = try AlgorithmEvaluationNeutralRec2020().render(input, settings: .neutral) }
                        else { result = try render(input, settings: settings(id), context: ci) }
                        let elapsed = Benchmark.milliseconds(started.duration(to: .now))
                        let measurement = try AlgorithmEvaluationMetrics.measure(reference: input, candidate: result, groundTruth: fixture.groundTruth)
                        let isControl = !baselineIDs.contains(id)
                        let violations = isControl ? manifest.checkControl(sceneClass: fixture.sceneClass, measurement: measurement, adapterID: id) : []
                        failures += violations.map { "\(fixture.id)/\(id): \($0)" }
                        if id == "unchanged", input.sha256 != result.sha256 { failures.append("Identity changed input hash") }
                        try png(result.previewImage(), directory.appendingPathComponent("\(id).png"))
                        try png(result.previewImage(background: 0), directory.appendingPathComponent("\(id)-dark.png"))
                        try png(result.previewImage(background: 1), directory.appendingPathComponent("\(id)-light.png"))
                        try png(difference(input, result).previewImage(), directory.appendingPathComponent("\(id)-difference.png"))
                        records.append([
                            "fixture": fixture.id, "scene_class": fixture.sceneClass, "split": String(describing: split),
                            "seed": String(fixture.seed), "width": input.width, "height": input.height,
                            "input_sha256": input.sha256, "ground_truth_sha256": fixture.groundTruth?.sha256 as Any? ?? NSNull(),
                            "output_sha256": result.sha256, "adapter": id, "kind": isControl ? "control" : "picedit-baseline",
                            "settings": try object(settings(id)), "metrics": measurement.values,
                            "status": isControl ? (violations.isEmpty ? "control-pass" : "control-fail") : "baseline-only",
                            "violations": violations, "adapter_ms_diagnostic_only": elapsed,
                            "peak_rss_bytes_cumulative": Benchmark.peakRSS(), "manifest_sha256": manifestSHA
                        ])
                    }
                }
            }
        }
        if !options.input.isEmpty {
            // The caller verifies permission/provenance/SHA before this explicit
            // local-only input. RAW is intentionally excluded by the orchestrator.
            let url = URL(fileURLWithPath: options.input)
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let type = CGImageSourceGetType(source),
                  [UTType.png.identifier, UTType.jpeg.identifier, UTType.tiff.identifier].contains(type as String) else {
                throw Benchmark.failure("Only developed PNG/JPEG/TIFF input is supported")
            }
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
            let width = (properties?[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
            let height = (properties?[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
            guard width > 0, height > 0, width <= 8_192, height <= 8_192, width * height <= 32_000_000,
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw EditRenderError.oversizedPreview }
            let orientation = (properties?[kCGImagePropertyOrientation] as? NSNumber)?.uint32Value ?? 1
            let frozen = try AlgorithmEvaluationRaster.freeze(image, orientation: orientation)
            try writeJSON(["input_sha256": frozen.sha256, "width": frozen.width, "height": frozen.height,
                           "source_width": width, "source_height": height, "source_bits_per_component": image.bitsPerComponent,
                           "source_color_space": image.colorSpace?.name as String? ?? "unspecified",
                           "source_orientation": orientation, "frozen_orientation": 1,
                           "coverage": "local-only; not acceptance evidence without registered scene/ROI"], output.appendingPathComponent("real-input.json"))
            for id in baselineIDs {
                let result = try render(frozen, settings: settings(id), context: ci)
                try png(result.previewImage(), output.appendingPathComponent("real-\(id).png"))
            }
        }
        let decisions = registry.candidates.filter { $0.kind == "reference" }.map { candidate in
            if candidate.id == "LC-05", candidate.implemented {
                return AlgorithmEvaluationGate.Decision(candidateID: candidate.id, status: "blocked",
                    reasons: ["The LC-05 adapter is implemented; use --candidate LC-05 with lc05-manifest.json for separate matched-chroma vibrance/saturation decisions"])
            }
            if candidate.id == "LC-04", candidate.implemented {
                return AlgorithmEvaluationGate.Decision(candidateID: candidate.id, status: "blocked",
                    reasons: ["The LC-04 adapter is implemented; use --candidate LC-04 with lc04-manifest.json for the specialized per-control matched-effect comparison"])
            }
            if candidate.id == "LC-03", candidate.implemented {
                return AlgorithmEvaluationGate.Decision(candidateID: candidate.id, status: "blocked",
                    reasons: ["The LC-03 adapter is implemented; use --candidate LC-03 with lc03-manifest.json for its specialized matched-effect comparison"])
            }
            return AlgorithmEvaluationGate.evaluate(candidate: candidate, manifest: manifest, scenes: [])
        }
        guard sha(try Data(contentsOf: manifestURL)) == manifestSHA else { throw Benchmark.failure("Manifest changed during acceptance") }
        try writeJSON(["schema_version": 1, "manifest_sha256": manifestSHA, "records": records,
                       "candidates": try object(decisions),
                       "control_failures": failures, "candidate_decision": "blocked",
                       "reason": "LC-03, LC-04 and LC-05 use their specialized --candidate comparisons; LC-06 remains unimplemented. Generic controls do not establish algorithm acceptance."],
                      output.appendingPathComponent("quality.json"))
        guard failures.isEmpty else { throw Benchmark.failure("\(failures.count) control failures; see quality.json") }
    }

    static func timing(_ options: Benchmark.Options, output: URL) throws {
        guard options.iterations >= 5 else { throw Benchmark.failure("At least five warm timing samples required") }
        let fixture = try AlgorithmEvaluationFixtures.make(sceneClass: "texture", split: .acceptance, width: options.width, height: options.height)
        let inputHash = fixture.input.sha256
        var samples: [[String: Any]] = []
        var ci: CIContext?
        // process-cold first call includes CIContext initialization; it does NOT
        // claim cold OS/driver/shader/disk caches. One separate untimed warmup.
        for step in -1...options.iterations {
            try autoreleasepool {
                let start = ContinuousClock.now
                if ci == nil { ci = context() }
                let result = try render(fixture.input, settings: Benchmark.settings(step: max(0, step), complex: true), context: ci!)
                let elapsed = Benchmark.milliseconds(start.duration(to: .now))
                // Full readback already finished. Hashing is outside timing.
                samples.append(["phase": step == -1 ? "process-cold" : (step == 0 ? "warmup" : "warm"),
                                "sample": step, "total_ms": elapsed, "output_sha256": result.sha256,
                                "peak_rss_bytes": Benchmark.peakRSS()])
            }
        }
        try writeJSON(["schema_version": 1, "width": options.width, "height": options.height,
                       "input_sha256": inputHash, "seed": String(fixture.seed), "samples": samples,
                       "settings_per_warm_sample": try (1...options.iterations).map { try object(Benchmark.settings(step: $0, complex: true)) },
                       "input_format": "straight Float32 extended-linear-sRGB; alpha retained",
                       "path": "shared production filterGraph; RGBAh working; Float32 materialized readback",
                       "backend": "Core Image automatic; hardware not forced or inferred",
                       "excluded": ["fixture generation", "fixture/output hashing", "PNG I/O", "RAW/ImageIO decode", "UI presentation"],
                       "peak_rss_bytes": Benchmark.peakRSS()], output.appendingPathComponent("timing.json"))
    }

    static func scale(_ options: Benchmark.Options, output: URL) throws {
        let fixture = try AlgorithmEvaluationFixtures.make(sceneClass: "texture", split: .acceptance, width: options.width, height: options.height)
        let ci = context()
        let small = try downsample(fixture.input, context: ci)
        var records: [[String: Any]] = []
        for id in baselineIDs {
            try autoreleasepool {
                let full = try render(fixture.input, settings: settings(id), context: ci)
                let scaled = try downsample(full, context: ci)
                let direct = try render(small, settings: settings(id), context: ci)
                let metric = try AlgorithmEvaluationMetrics.measure(reference: scaled, candidate: direct, groundTruth: nil)
                records.append(["adapter": id, "settings": try object(settings(id)), "metrics": metric.values,
                                "status": "diagnostic-baseline-only", "full_input_sha256": fixture.input.sha256,
                                "preview_input_sha256": small.sha256])
                try png(scaled.previewImage(), output.appendingPathComponent("\(id)-scaled-full.png"))
                try png(direct.previewImage(), output.appendingPathComponent("\(id)-direct.png"))
                try png(difference(scaled, direct).previewImage(), output.appendingPathComponent("\(id)-difference.png"))
            }
        }
        try writeJSON(["full_size": [options.width, options.height], "preview_size": [400, 267], "records": records,
                       "note": "Scale discrepancy is recorded, not declared a gain. Same source is downsampled before direct preview rendering."],
                      output.appendingPathComponent("scale.json"))
    }

    static func downsample(_ raster: AlgorithmEvaluationRaster, context: CIContext) throws -> AlgorithmEvaluationRaster {
        let input = try CIImage(cgImage: raster.cgImage())
        let graph = input.transformed(by: CGAffineTransform(scaleX: 400 / Double(raster.width), y: 267 / Double(raster.height)), highQualityDownsample: true)
        guard let image = context.createCGImage(graph, from: CGRect(x: 0, y: 0, width: 400, height: 267),
                                                format: .RGBAf, colorSpace: space, deferred: false) else { throw EditRenderError.unavailable }
        return try AlgorithmEvaluationRaster.freeze(image)
    }

    static func difference(_ a: AlgorithmEvaluationRaster, _ b: AlgorithmEvaluationRaster) throws -> AlgorithmEvaluationRaster {
        var pixels = a.pixels
        for i in stride(from: 0, to: pixels.count, by: 4) {
            for c in 0..<3 { pixels[i + c] = abs(a.pixels[i + c] * a.pixels[i + 3] - b.pixels[i + c] * b.pixels[i + 3]) * 8 }
            pixels[i + 3] = 1
        }
        return try AlgorithmEvaluationRaster(width: a.width, height: a.height, pixels: pixels)
    }
    static func png(_ image: CGImage, _ url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { throw EditRenderError.unavailable }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw EditRenderError.unavailable }
    }
    static func sha(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func object<T: Encodable>(_ value: T) throws -> Any { try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) }
    static func writeJSON(_ object: Any, _ url: URL) throws {
        try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
    }
}
#endif
