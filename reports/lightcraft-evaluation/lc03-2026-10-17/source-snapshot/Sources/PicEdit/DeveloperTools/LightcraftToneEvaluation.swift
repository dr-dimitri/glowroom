#if PICEDIT_EDITING_BENCHMARK
import CoreGraphics
import CoreImage
import Foundation
import PicEditCore

/// LC-03 lives entirely in the existing developer harness. Serial scenarios
/// keep CPU/GPU contention out of timing; the CPU reference bounds its workers.
enum LightcraftToneEvaluation {
    typealias Comparison = LightcraftToneComparison
    typealias Raster = AlgorithmEvaluationRaster
    typealias Evaluation = AlgorithmEvaluation

    static func run(_ options: Benchmark.Options) throws {
        guard !options.output.isEmpty, !options.manifest.isEmpty,
              options.backend == "default", options.workers == 1,
              options.width * options.height <= 32_000_000,
              ["tone-tune", "tone-quality", "tone-timing", "tone-scale"].contains(options.evaluationMode),
              ["picedit", "lightcraft"].contains(options.adapter) else { throw Benchmark.failure("Invalid LC-03 options") }
        let manifestURL = URL(fileURLWithPath: options.manifest)
        let manifest = try Comparison.Manifest.load(manifestURL)
        let hash = Evaluation.sha(try Data(contentsOf: manifestURL))
        let output = URL(fileURLWithPath: options.output, isDirectory: true)
        guard !FileManager.default.fileExists(atPath: output.path) else { throw Benchmark.failure("Refusing to overwrite LC-03 output") }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        if options.evaluationMode == "tone-tune" {
            try tune(manifest, hash: hash, output: output)
        } else {
            guard !options.calibration.isEmpty else { throw Benchmark.failure("LC-03 requires frozen --calibration") }
            let bytes = try Data(contentsOf: URL(fileURLWithPath: options.calibration))
            let calibration = try JSONDecoder().decode(Comparison.CalibrationFile.self, from: bytes)
            guard calibration.manifestSHA256 == hash,
                  calibration.records.count == 72,
                  Set(calibration.records.map { "\($0.sceneClass):\($0.directionID)" }).count == 72,
                  calibration.records.allSatisfy({ $0.parameter.isFinite && abs($0.parameter) <= 100 && $0.target.isFinite && $0.measured.isFinite }) else {
                throw Benchmark.failure("Invalid or incompatible frozen LC-03 calibration")
            }
            try validateCalibration(calibration, manifest: manifest)
            switch options.evaluationMode {
            case "tone-quality": try quality(manifest, calibration: calibration, manifestHash: hash,
                                              calibrationHash: Evaluation.sha(bytes), output: output)
            case "tone-timing": try timing(options, manifest: manifest, calibration: calibration, output: output)
            default: try scale(options, manifest: manifest, calibration: calibration, output: output)
            }
        }
        guard Evaluation.sha(try Data(contentsOf: manifestURL)) == hash else { throw Benchmark.failure("Manifest changed during LC-03 run") }
    }

    static func validateCalibration(_ calibration: Comparison.CalibrationFile, manifest: Comparison.Manifest) throws {
        // Verify provenance against known tuning fixtures without rendering or
        // reading acceptance pixels. Never let a renamed acceptance result act
        // as a calibration record. Fixture buffers are released before timing.
        for scene in AlgorithmEvaluationFixtures.sceneClasses {
            try autoreleasepool {
                let fixture = try AlgorithmEvaluationFixtures.make(sceneClass: scene, split: .tuning,
                                                                    width: manifest.qualityWidth, height: manifest.qualityHeight)
                let hash = fixture.input.sha256
                for direction in manifest.directions {
                    let record = try tuning(calibration, scene: scene, direction: direction)
                    guard record.inputSHA256 == hash,
                          record.parameter == 0 || record.parameter.sign == direction.value.sign,
                          record.matched == Comparison.matched(record.target, record.measured, manifest: manifest) else {
                        throw Benchmark.failure("LC-03 calibration provenance or matching is invalid")
                    }
                }
            }
        }
    }

    static func tuning(_ calibration: Comparison.CalibrationFile, scene: String,
                       direction: Comparison.Direction) throws -> Comparison.Calibration {
        guard let record = calibration.records.first(where: { $0.sceneClass == scene && $0.directionID == direction.id }) else {
            throw Benchmark.failure("Missing tuning record for \(scene)/\(direction.id)")
        }
        return record
    }

    static func tune(_ manifest: Comparison.Manifest, hash: String, output: URL) throws {
        let ci = Evaluation.context(), reference = LightcraftToneReference()
        var records: [Comparison.Calibration] = []
        // Only this split may influence parameter choice. Acceptance is opened
        // by a later process after the runner freezes this calibration file.
        for fixture in try AlgorithmEvaluationFixtures.make(split: .tuning, width: manifest.qualityWidth, height: manifest.qualityHeight) {
            try autoreleasepool {
                let prepared = try reference.prepare(fixture.input)
                for direction in manifest.directions {
                    let baseline = try Evaluation.render(fixture.input, settings: direction.settings(), context: ci)
                    let target = Comparison.strength(input: fixture.input, output: baseline, direction: direction, manifest: manifest)
                    var bestParameter = 0.0, bestMeasured = 0.0, bestError = Double.infinity
                    let sign = direction.value < 0 ? -1.0 : 1.0
                    func search(_ low: Double, _ high: Double, steps: Int) throws {
                        for step in 0..<steps {
                            let parameter = sign * (low + (high - low) * Double(step) / Double(steps - 1))
                            let result = try reference.apply(prepared, settings: direction.settings(value: parameter))
                            guard let measured = Comparison.strength(input: fixture.input, output: result, direction: direction, manifest: manifest),
                                  let target else { continue }
                            let error = abs(measured - target)
                            if error < bestError { bestError = error; bestParameter = parameter; bestMeasured = measured }
                        }
                    }
                    if let target, abs(target) >= manifest.matching.minimumAbsoluteTarget {
                        try search(0, 100, steps: manifest.matching.coarseSteps)
                        let spacing = 100 / Double(manifest.matching.coarseSteps - 1)
                        try search(max(0, abs(bestParameter) - spacing), min(100, abs(bestParameter) + spacing), steps: manifest.matching.refinementSteps)
                    }
                    records.append(.init(sceneClass: fixture.sceneClass, directionID: direction.id, inputSHA256: fixture.input.sha256,
                                         parameter: bestParameter, target: target ?? 0, measured: bestMeasured,
                                         matched: Comparison.matched(target, bestMeasured, manifest: manifest)))
                }
            }
        }
        let file = Comparison.CalibrationFile(manifestSHA256: hash, records: records)
        try Evaluation.writeJSON(Evaluation.object(file), output.appendingPathComponent("calibration.json"))
    }

    static func quality(_ manifest: Comparison.Manifest, calibration: Comparison.CalibrationFile,
                        manifestHash: String, calibrationHash: String, output: URL) throws {
        let ci = Evaluation.context(), reference = LightcraftToneReference()
        var records: [[String: Any]] = []
        for fixture in try AlgorithmEvaluationFixtures.make(split: .acceptance, width: manifest.qualityWidth, height: manifest.qualityHeight) {
            try autoreleasepool {
                let prepared = try reference.prepare(fixture.input)
                for direction in manifest.directions {
                    try autoreleasepool {
                        let fit = try tuning(calibration, scene: fixture.sceneClass, direction: direction)
                        let baseline = try Evaluation.render(fixture.input, settings: direction.settings(), context: ci)
                        let candidate = try reference.apply(prepared, settings: direction.settings(value: fit.parameter))
                        let sameValues = try reference.apply(prepared, settings: direction.settings())
                        let target = Comparison.strength(input: fixture.input, output: baseline, direction: direction, manifest: manifest)
                        let measured = Comparison.strength(input: fixture.input, output: candidate, direction: direction, manifest: manifest)
                        let matched = fit.matched && Comparison.matched(target, measured, manifest: manifest)
                        let metrics = try AlgorithmEvaluationMetrics.measure(reference: baseline, candidate: candidate, groundTruth: nil).values
                        var before: [String: Double] = [:], after: [String: Double] = [:]
                        if fixture.sceneClass == "fine-lines" {
                            before = Comparison.lineContrast(input: fixture.input, output: baseline, minimumContrastEV: manifest.primary.minimumInputContrastEV)
                            after = Comparison.lineContrast(input: fixture.input, output: candidate, minimumContrastEV: manifest.primary.minimumInputContrastEV)
                        } else if fixture.sceneClass == "hard-edge" {
                            before = Comparison.halo(input: fixture.input, output: baseline)
                            after = Comparison.halo(input: fixture.input, output: candidate)
                        }
                        var failures: [String] = []
                        if matched {
                            for (metric, limit) in [("hue_deviation_degrees", "hueDeviationDegrees"), ("gamut_fraction_increase", "gamutFractionIncrease"),
                                                    ("clipping_fraction_increase", "clippingFractionIncrease"), ("alpha_error", "alphaError")] {
                                if metrics[metric]! > manifest.criticalLimits[limit]! { failures.append(metric) }
                            }
                            if fixture.sceneClass == "hard-edge" {
                                for (metric, limit) in [("halo_overshoot", "haloOvershoot"), ("halo_undershoot", "haloUndershoot")] {
                                    if after[metric]! > manifest.criticalLimits[limit]! { failures.append(metric) }
                                }
                            }
                        }
                        let name = "\(fixture.id)-\(direction.id)"
                        let directory = output.appendingPathComponent(name, isDirectory: true)
                        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                        for (name, raster) in [("input", fixture.input), ("picedit", baseline), ("lightcraft", candidate), ("same-values", sameValues)] {
                            try Evaluation.png(raster.previewImage(), directory.appendingPathComponent("\(name).png"))
                        }
                        try Evaluation.png(Evaluation.difference(baseline, candidate).previewImage(), directory.appendingPathComponent("difference.png"))
                        try Evaluation.png(candidate.previewImage(background: 0), directory.appendingPathComponent("dark.png"))
                        try Evaluation.png(candidate.previewImage(background: 1), directory.appendingPathComponent("light.png"))
                        records.append(["fixture": fixture.id, "scene_class": fixture.sceneClass, "direction": direction.id,
                                        "primary": direction.primary, "matched": matched, "target": target as Any? ?? NSNull(),
                                        "measured": measured as Any? ?? NSNull(), "parameter": fit.parameter,
                                        "baseline_settings": try Evaluation.object(direction.settings()),
                                        "candidate_settings": try Evaluation.object(direction.settings(value: fit.parameter)),
                                        "input_sha256": fixture.input.sha256, "output_sha256": candidate.sha256,
                                        "baseline_metrics": before, "candidate_metrics": after, "comparison_metrics": metrics,
                                        "critical_failures": failures, "directory": name])
                    }
                }
            }
        }
        let stages = try stageDiagnostics(manifest, calibration: calibration, context: ci, output: output)
        try Evaluation.writeJSON(["manifest_sha256": manifestHash, "calibration_sha256": calibrationHash,
                                  "records": records, "stages": stages], output.appendingPathComponent("quality.json"))
    }

    static func timing(_ options: Benchmark.Options, manifest: Comparison.Manifest,
                       calibration: Comparison.CalibrationFile, output: URL) throws {
        guard options.iterations >= 5 else { throw Benchmark.failure("LC-03 timing needs five warm samples") }
        let fixture = try AlgorithmEvaluationFixtures.make(sceneClass: "texture", split: .acceptance, width: options.width, height: options.height)
        let direction = manifest.directions.first { $0.control == "shadows" && $0.value == 20 }!
        let fit = try tuning(calibration, scene: "texture", direction: direction)
        let reference = LightcraftToneReference(nativeLong: max(options.width, options.height))
        var ci: CIContext?, prepared: LightcraftToneReference.Prepared?
        var samples: [[String: Any]] = []
        for step in -1...options.iterations {
            try autoreleasepool {
                let value = step <= 0 ? 20.0 : Double(18 + (step - 1) % 5)
                var settings = direction.settings(value: options.adapter == "picedit" ? value : fit.parameter * value / 20)
                settings.exposure = step <= 0 ? 0 : [-0.1, 0, 0.1, 0, -0.1][(step - 1) % 5]
                settings = settings.normalized
                let start = ContinuousClock.now
                let result: Raster
                if options.adapter == "picedit" {
                    if ci == nil { ci = Evaluation.context() }
                    result = try Evaluation.render(fixture.input, settings: settings, context: ci!)
                } else {
                    if prepared == nil { prepared = try reference.prepare(fixture.input) }
                    result = try reference.apply(prepared!, settings: settings)
                }
                let elapsed = Benchmark.milliseconds(start.duration(to: .now))
                let rss = Benchmark.peakRSS()
                let strength = Comparison.strength(input: fixture.input, output: result, direction: direction, manifest: manifest)
                samples.append(["phase": step == -1 ? "process-cold" : (step == 0 ? "warmup" : "warm"),
                                "sample": step, "total_ms": elapsed, "output_sha256": result.sha256,
                                "peak_rss_bytes": rss, "settings": try Evaluation.object(settings),
                                "effect_strength": strength as Any? ?? NSNull()])
            }
        }
        try Evaluation.writeJSON(["width": options.width, "height": options.height, "adapter": options.adapter,
                                  "input_sha256": fixture.input.sha256, "samples": samples, "peak_rss_bytes": Benchmark.peakRSS(),
                                  "tuning_matched": fit.matched,
                                  "boundary": "Already developed straight Float32 linear sRGB to fully materialized Float32 result; CPU bridge/filtering or CI premultiply/graph/readback/unpremultiply included",
                                  "warm_cache": options.adapter == "lightcraft" ? "Immutable per-image log/base reused; strength and Exposure change" : "CIContext reused; production filterGraph rebuilt",
                                  "excluded": ["fixture generation", "hashing", "metrics", "PNG", "RAW decode", "UI presentation"],
                                  "cold_scope": "New process, not cleared OS/driver caches"], output.appendingPathComponent("timing.json"))
    }

    static func scale(_ options: Benchmark.Options, manifest: Comparison.Manifest,
                      calibration: Comparison.CalibrationFile, output: URL) throws {
        let fixture = try AlgorithmEvaluationFixtures.make(sceneClass: "texture", split: .acceptance, width: options.width, height: options.height)
        let ci = Evaluation.context()
        let small = try Evaluation.downsample(fixture.input, context: ci)
        let native = max(options.width, options.height)
        let fullReference = LightcraftToneReference(nativeLong: native)
        let smallReference = LightcraftToneReference(nativeLong: native, pixelsPerLongEdge: Double(max(small.width, small.height)))
        let fullPrepared = try fullReference.prepare(fixture.input), smallPrepared = try smallReference.prepare(small)
        var records: [[String: Any]] = []
        for direction in manifest.directions where direction.primary {
            let fit = try tuning(calibration, scene: "texture", direction: direction)
            for adapter in ["picedit", "lightcraft"] {
                try autoreleasepool {
                    let settings = direction.settings(value: adapter == "picedit" ? direction.value : fit.parameter)
                    let full = try adapter == "picedit" ? Evaluation.render(fixture.input, settings: settings, context: ci) : fullReference.apply(fullPrepared, settings: settings)
                    let scaled = try Evaluation.downsample(full, context: ci)
                    let direct = try adapter == "picedit" ? Evaluation.render(small, settings: settings, context: ci) : smallReference.apply(smallPrepared, settings: settings)
                    let metrics = try AlgorithmEvaluationMetrics.measure(reference: scaled, candidate: direct, groundTruth: nil).values
                    let name = "\(adapter)-\(direction.id)"
                    try Evaluation.png(scaled.previewImage(), output.appendingPathComponent("\(name)-scaled-full.png"))
                    try Evaluation.png(direct.previewImage(), output.appendingPathComponent("\(name)-direct.png"))
                    records.append(["adapter": adapter, "direction": direction.id, "metrics": metrics,
                                    "full_input_sha256": fixture.input.sha256, "preview_input_sha256": small.sha256])
                }
            }
        }
        try Evaluation.writeJSON(["full_size": [options.width, options.height], "preview_size": [small.width, small.height],
                                  "native_long": native, "records": records,
                                  "scope": "Scale diagnostic using the same source; no preview/export equivalence or gain claimed"], output.appendingPathComponent("scale.json"))
    }

    static func stageDiagnostics(_ manifest: Comparison.Manifest, calibration: Comparison.CalibrationFile,
                                 context ci: CIContext, output: URL) throws -> [[String: Any]] {
        var records: [[String: Any]] = []
        let reference = LightcraftToneReference()
        for scene in ["fine-lines", "colors", "noise", "transparency"] {
            let fixture = try AlgorithmEvaluationFixtures.make(sceneClass: scene, split: .acceptance, width: manifest.qualityWidth, height: manifest.qualityHeight)
            let original = try fixture.input.cgImage()
            var denoise = EditSettings.neutral; denoise.luminanceNoiseReduction = 40
            let denoised = try Evaluation.render(fixture.input, settings: denoise, context: ci)
            let earlyPrepared = try reference.prepare(denoised)
            for auto in [0.0, 100.0] {
                var prefix = EditSettings.neutral
                prefix.luminanceNoiseReduction = 40; prefix.autoToneAmount = auto
                let beforeTone = try Evaluation.render(fixture.input, settings: prefix, context: ci)
                let prepared = try reference.prepare(beforeTone)
                for direction in manifest.directions where direction.primary {
                    let fit = try tuning(calibration, scene: scene, direction: direction)
                    for exposure in [-0.7, 0.0, 0.7] {
                        try autoreleasepool {
                            var baselineSettings = direction.settings()
                            baselineSettings.exposure = exposure; baselineSettings.autoToneAmount = auto
                            baselineSettings.luminanceNoiseReduction = 40; baselineSettings.texture = 25; baselineSettings.clarity = 15
                            let baseline = try Evaluation.render(fixture.input, settings: baselineSettings, context: ci)
                            var tone = direction.settings(value: fit.parameter); tone.exposure = exposure
                            let local = try reference.apply(prepared, settings: tone)
                            var presence = EditSettings.neutral; presence.texture = 25; presence.clarity = 15
                            let candidate = try Evaluation.render(local, settings: presence, context: ci)
                            // Diagnostic order swap retains the ORIGINAL AutoTone
                            // analysis source. Reanalyzing the toned pixels would
                            // confound order with a newly estimated curve.
                            let early = try reference.apply(earlyPrepared, settings: tone)
                            let earlyImage = try CIImage(cgImage: early.cgImage())
                            let reordered = auto == 0 ? earlyImage : try AutoToneRenderer.apply(to: earlyImage, original: original, amount: auto, extent: earlyImage.extent)
                            guard let materialized = ci.createCGImage(reordered, from: reordered.extent, format: .RGBAf, colorSpace: Evaluation.space, deferred: false) else { throw EditRenderError.unavailable }
                            let alternative = try Evaluation.render(Raster.freeze(materialized), settings: presence, context: ci)
                            records.append(["scene_class": scene, "direction": direction.id, "auto_tone": auto, "exposure": exposure,
                                            "metrics": try AlgorithmEvaluationMetrics.measure(reference: baseline, candidate: candidate, groundTruth: nil).values,
                                            "order_difference": try AlgorithmEvaluationMetrics.measure(reference: candidate, candidate: alternative, groundTruth: nil).values,
                                            "status": "diagnostic-only; frozen tuning, no stage-specific effect refit",
                                            "candidate_sha256": candidate.sha256])
                            if exposure == 0, direction.value > 0 {
                                let name = "stage-\(scene)-auto\(Int(auto))-\(direction.id)"
                                try Evaluation.png(baseline.previewImage(), output.appendingPathComponent("\(name)-picedit.png"))
                                try Evaluation.png(candidate.previewImage(), output.appendingPathComponent("\(name)-lightcraft.png"))
                                try Evaluation.png(alternative.previewImage(), output.appendingPathComponent("\(name)-before-auto.png"))
                            }
                        }
                    }
                }
            }
        }
        return records
    }
}
#endif
