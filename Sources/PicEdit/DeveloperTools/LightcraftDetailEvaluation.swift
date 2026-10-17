#if PICEDIT_EDITING_BENCHMARK
import CoreImage
import Foundation
import PicEditCore

/// Serial measurements avoid CPU/GPU contention. Each reference owns bounded
/// pixel work internally and reuses only immutable, image-specific preparation.
enum LightcraftDetailEvaluation {
    typealias Comparison = LightcraftDetailComparison
    typealias Reference = LightcraftDetailReference
    typealias Raster = AlgorithmEvaluationRaster
    typealias Evaluation = AlgorithmEvaluation
    typealias Fixture = AlgorithmEvaluationFixtures.Fixture

    static func run(_ options: Benchmark.Options) throws {
        guard !options.output.isEmpty, !options.manifest.isEmpty, options.backend == "default", options.workers == 1,
              options.width * options.height <= 32_000_000,
              ["detail-tune", "detail-quality", "detail-timing", "detail-scale"].contains(options.evaluationMode),
              ["picedit-clarity", "lightcraft-clarity", "picedit-texture", "lightcraft-texture", "picedit", "lightcraft"].contains(options.adapter) else {
            throw Benchmark.failure("Invalid LC-04 options")
        }
        let manifestURL = URL(fileURLWithPath: options.manifest)
        let manifest = try Comparison.Manifest.load(manifestURL)
        let hash = Evaluation.sha(try Data(contentsOf: manifestURL))
        let output = URL(fileURLWithPath: options.output, isDirectory: true)
        guard !FileManager.default.fileExists(atPath: output.path) else { throw Benchmark.failure("Refusing to overwrite LC-04 output") }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        if options.evaluationMode == "detail-tune" { try tune(manifest, hash: hash, output: output) }
        else {
            guard !options.calibration.isEmpty else { throw Benchmark.failure("LC-04 requires frozen --calibration") }
            let bytes = try Data(contentsOf: URL(fileURLWithPath: options.calibration))
            let calibration = try JSONDecoder().decode(Comparison.CalibrationFile.self, from: bytes)
            try validateCalibration(calibration, manifest: manifest, hash: hash)
            switch options.evaluationMode {
            case "detail-quality": try quality(manifest, calibration: calibration, manifestHash: hash, calibrationHash: Evaluation.sha(bytes), output: output)
            case "detail-timing": try timing(options, manifest: manifest, calibration: calibration, output: output)
            default: try scale(options, manifest: manifest, calibration: calibration, output: output)
            }
        }
        guard Evaluation.sha(try Data(contentsOf: manifestURL)) == hash else { throw Benchmark.failure("Manifest changed during LC-04 run") }
    }
    static func fit(_ calibration: Comparison.CalibrationFile, scene: String, direction: Comparison.Direction,
                    variant: Reference.Variant) throws -> Comparison.Calibration {
        guard let record = calibration.records.first(where: { $0.sceneClass == scene && $0.directionID == direction.id && $0.variant == variant.rawValue }) else {
            throw Benchmark.failure("Missing LC-04 tuning record")
        }
        return record
    }
    static func validateCalibration(_ calibration: Comparison.CalibrationFile, manifest: Comparison.Manifest, hash: String) throws {
        guard calibration.manifestSHA256 == hash, calibration.records.count == 140,
              Set(calibration.records.map { "\($0.sceneClass):\($0.directionID):\($0.variant)" }).count == 140 else {
            throw Benchmark.failure("Invalid LC-04 calibration matrix")
        }
        for scene in LightcraftDetailFixtures.sceneClasses {
            let fixture = try LightcraftDetailFixtures.make(sceneClass: scene, split: .tuning, width: manifest.qualityWidth, height: manifest.qualityHeight)
            for direction in manifest.directions {
                for variant in direction.variants {
                    let record = try fit(calibration, scene: scene, direction: direction, variant: variant)
                    guard record.inputSHA256 == fixture.input.sha256,
                          record.parameter.isFinite, abs(record.parameter) <= 100, record.target.isFinite, record.measured.isFinite,
                          record.parameter == 0 || record.parameter.sign == direction.value.sign,
                          record.matched == Comparison.matched(record.target, record.measured, manifest: manifest) else {
                        throw Benchmark.failure("Invalid LC-04 tuning provenance or match")
                    }
                }
            }
        }
    }
    static func tune(_ manifest: Comparison.Manifest, hash: String, output: URL) throws {
        let ci = Evaluation.context()
        var records: [Comparison.Calibration] = []
        for scene in LightcraftDetailFixtures.sceneClasses {
            try autoreleasepool {
                let fixture = try LightcraftDetailFixtures.make(sceneClass: scene, split: .tuning, width: manifest.qualityWidth, height: manifest.qualityHeight)
                let matchingInput = fixture.groundTruth ?? fixture.input
                let matchingExclusion = Comparison.edgeExclusion(matchingInput)
                for variant in Reference.Variant.allCases {
                    let reference = Reference(variant: variant), prepared = try reference.prepare(matchingInput)
                    for direction in manifest.directions where direction.variants.contains(variant) {
                        let baseline = try Evaluation.render(matchingInput, settings: direction.settings(), context: ci)
                        let target = Comparison.strength(input: matchingInput, output: baseline, direction: direction, exclusion: matchingExclusion, sceneClass: scene)
                        var parameter = 0.0, measured = 0.0, error = Double.infinity
                        let sign = direction.value < 0 ? -1.0 : 1.0
                        func search(_ lower: Double, _ upper: Double, steps: Int) throws {
                            for step in 0..<steps {
                                let trial = sign * (lower + (upper - lower) * Double(step) / Double(steps - 1))
                                let result = try reference.apply(prepared, settings: direction.settings(value: trial))
                                guard let target, let achieved = Comparison.strength(input: matchingInput, output: result, direction: direction, exclusion: matchingExclusion, sceneClass: scene) else { continue }
                                if abs(achieved - target) < error { parameter = trial; measured = achieved; error = abs(achieved - target) }
                            }
                        }
                        if let target, abs(target) >= manifest.matching.minimumAbsoluteTarget {
                            try search(0, 100, steps: manifest.matching.coarseSteps)
                            let spacing = 100 / Double(manifest.matching.coarseSteps - 1)
                            try search(max(0, abs(parameter) - spacing), min(100, abs(parameter) + spacing), steps: manifest.matching.refinementSteps)
                        }
                        records.append(.init(sceneClass: scene, directionID: direction.id, variant: variant.rawValue,
                                             inputSHA256: fixture.input.sha256, parameter: parameter, target: target ?? 0, measured: measured,
                                             matched: Comparison.matched(target, measured, manifest: manifest)))
                    }
                }
            }
        }
        try Evaluation.writeJSON(Evaluation.object(Comparison.CalibrationFile(manifestSHA256: hash, records: records)), output.appendingPathComponent("calibration.json"))
    }
    static func quality(_ manifest: Comparison.Manifest, calibration: Comparison.CalibrationFile,
                        manifestHash: String, calibrationHash: String, output: URL) throws {
        let ci = Evaluation.context()
        var records: [[String: Any]] = [], zero: [[String: Any]] = []
        for scene in LightcraftDetailFixtures.sceneClasses {
            try autoreleasepool {
                let fixture = try LightcraftDetailFixtures.make(sceneClass: scene, split: .acceptance, width: manifest.qualityWidth, height: manifest.qualityHeight)
                let matchingInput = fixture.groundTruth ?? fixture.input
                let matchingExclusion = Comparison.edgeExclusion(matchingInput)
                for variant in Reference.Variant.allCases {
                    let reference = Reference(variant: variant), prepared = try reference.prepare(fixture.input)
                    let cleanPrepared = try fixture.groundTruth.map { try reference.prepare($0) }
                    for direction in manifest.directions where direction.variants.contains(variant) {
                        try autoreleasepool {
                            let tuning = try fit(calibration, scene: scene, direction: direction, variant: variant)
                            let baseline = try Evaluation.render(fixture.input, settings: direction.settings(), context: ci)
                            let candidate = try reference.apply(prepared, settings: direction.settings(value: tuning.parameter))
                            let baselineClean = try fixture.groundTruth.map { try Evaluation.render($0, settings: direction.settings(), context: ci) }
                            let candidateClean = try cleanPrepared.map { try reference.apply($0, settings: direction.settings(value: tuning.parameter)) }
                            let target = Comparison.strength(input: matchingInput, output: baselineClean ?? baseline, direction: direction, exclusion: matchingExclusion, sceneClass: scene)
                            let measured = Comparison.strength(input: matchingInput, output: candidateClean ?? candidate, direction: direction, exclusion: matchingExclusion, sceneClass: scene)
                            let matched = tuning.matched && Comparison.matched(target, measured, manifest: manifest)
                            var before = Comparison.detail(input: matchingInput, output: baselineClean ?? baseline, control: direction.control, exclusion: matchingExclusion, sceneClass: scene)
                            var after = Comparison.detail(input: matchingInput, output: candidateClean ?? candidate, control: direction.control, exclusion: matchingExclusion, sceneClass: scene)
                            if manifest.primary.sceneClasses.contains(scene) {
                                before.merge(Comparison.halo(input: fixture.input, output: baseline)) { _, new in new }
                                after.merge(Comparison.halo(input: fixture.input, output: candidate)) { _, new in new }
                            }
                            if let clean = fixture.groundTruth, let baselineClean, let candidateClean {
                                before.merge(Comparison.noise(input: fixture.input, cleanInput: clean, output: baseline, cleanOutput: baselineClean)) { _, new in new }
                                after.merge(Comparison.noise(input: fixture.input, cleanInput: clean, output: candidate, cleanOutput: candidateClean)) { _, new in new }
                            }
                            let metrics = try AlgorithmEvaluationMetrics.measure(reference: baseline, candidate: candidate, groundTruth: nil).values
                            var failures: [String] = []
                            if matched {
                                for (metric, limit) in [("hue_deviation_degrees", "hueDeviationDegrees"), ("gamut_fraction_increase", "gamutFractionIncrease"), ("clipping_fraction_increase", "clippingFractionIncrease"), ("alpha_error", "alphaError")] {
                                    if metrics[metric]! > manifest.criticalLimits[limit]! { failures.append(metric) }
                                }
                                if let b = before["edge_overshoot"], let a = after["edge_overshoot"], a - b > manifest.criticalLimits["edgeOvershootIncrease"]! { failures.append("edge_overshoot") }
                                if let b = before["noise_amplification"], let a = after["noise_amplification"], a > b * (1 + manifest.criticalLimits["noiseAmplificationRelativeIncrease"]!) { failures.append("noise_amplification") }
                            }
                            let name = "\(fixture.id)-\(direction.id)-\(variant.rawValue)"
                            let directory = output.appendingPathComponent(name, isDirectory: true)
                            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                            for (name, raster) in [("input", fixture.input), ("picedit", baseline), ("lightcraft", candidate)] {
                                try Evaluation.png(raster.previewImage(), directory.appendingPathComponent("\(name).png"))
                            }
                            try Evaluation.png(Evaluation.difference(baseline, candidate).previewImage(), directory.appendingPathComponent("difference.png"))
                            let sameValues = try reference.apply(prepared, settings: direction.settings())
                            try Evaluation.png(sameValues.previewImage(), directory.appendingPathComponent("same-values.png"))
                            try Evaluation.png(candidate.previewImage(background: 0), directory.appendingPathComponent("dark.png"))
                            try Evaluation.png(candidate.previewImage(background: 1), directory.appendingPathComponent("light.png"))
                            records.append(["fixture": fixture.id, "scene_class": scene, "control": direction.control,
                                            "direction": direction.id, "variant": variant.rawValue, "primary": direction.primary,
                                            "matched": matched, "tuning_matched": tuning.matched, "effect_target": target as Any? ?? NSNull(),
                                            "effect_measured": measured as Any? ?? NSNull(), "parameter": tuning.parameter,
                                            "baseline_settings": try Evaluation.object(direction.settings()),
                                            "candidate_settings": try Evaluation.object(direction.settings(value: tuning.parameter)),
                                            "input_sha256": fixture.input.sha256, "output_sha256": candidate.sha256,
                                            "baseline_metrics": before, "candidate_metrics": after, "comparison_metrics": metrics,
                                            "critical_failures": failures, "directory": name])
                        }
                    }
                    let direction = manifest.directions.first { $0.variants.contains(variant) && $0.value == 20 }!
                    for value in [-1.0, 0, 1] {
                        let result = try reference.apply(prepared, settings: direction.settings(value: value))
                        zero.append(["scene_class": scene, "control": direction.control, "variant": variant.rawValue, "value": value,
                                     "input_sha256": fixture.input.sha256, "output_sha256": result.sha256,
                                     "identity": fixture.input.sha256 == result.sha256,
                                     "metrics": try AlgorithmEvaluationMetrics.measure(reference: fixture.input, candidate: result, groundTruth: nil).values])
                    }
                }
            }
        }
        let stages = try stageDiagnostics(manifest, calibration: calibration, context: ci, output: output)
        try Evaluation.writeJSON(["manifest_sha256": manifestHash, "calibration_sha256": calibrationHash,
                                  "records": records, "zero_diagnostics": zero, "stages": stages], output.appendingPathComponent("quality.json"))
    }
    static func timing(_ options: Benchmark.Options, manifest: Comparison.Manifest,
                       calibration: Comparison.CalibrationFile, output: URL) throws {
        guard options.iterations >= 5, options.adapter.contains("-") else { throw Benchmark.failure("LC-04 timing requires a control adapter and five warm samples") }
        let control = options.adapter.hasSuffix("clarity") ? "clarity" : "texture"
        let baseline = options.adapter.hasPrefix("picedit")
        let fixture = try LightcraftDetailFixtures.make(sceneClass: manifest.performanceSceneClass, split: .acceptance, width: options.width, height: options.height)
        // Common input-only diagnostic mask is built before cold timing and
        // reused, so post-timing measurements never allocate fresh image masks.
        let matchingExclusion = Comparison.edgeExclusion(fixture.input)
        let direction = manifest.directions.first { $0.control == control && $0.value == 20 }!
        let tuning = try fit(calibration, scene: fixture.sceneClass, direction: direction, variant: direction.candidate)
        let reference = Reference(variant: direction.candidate, nativeLong: max(options.width, options.height))
        var ci: CIContext?, prepared: Reference.Prepared?, samples: [[String: Any]] = []
        for step in -1...options.iterations {
            try autoreleasepool {
                let value = step <= 0 ? 20.0 : Double(18 + (step - 1) % 5)
                let settings = direction.settings(value: baseline ? value : tuning.parameter * value / 20)
                let start = ContinuousClock.now
                let result: Raster
                if baseline {
                    if ci == nil { ci = Evaluation.context() }
                    result = try Evaluation.render(fixture.input, settings: settings, context: ci!)
                } else {
                    if prepared == nil { prepared = try reference.prepare(fixture.input) }
                    result = try reference.apply(prepared!, settings: settings)
                }
                let elapsed = Benchmark.milliseconds(start.duration(to: .now)), rss = Benchmark.peakRSS()
                samples.append(["phase": step == -1 ? "process-cold" : (step == 0 ? "warmup" : "warm"), "sample": step,
                                "total_ms": elapsed, "peak_rss_bytes": rss, "settings": try Evaluation.object(settings),
                                "effect_strength": Comparison.strength(input: fixture.input, output: result, direction: direction, exclusion: matchingExclusion) as Any? ?? NSNull(),
                                "output_sha256": result.sha256])
            }
        }
        try Evaluation.writeJSON(["width": options.width, "height": options.height, "control": control, "adapter": options.adapter,
                                  "scene_class": fixture.sceneClass, "input_sha256": fixture.input.sha256, "samples": samples,
                                  "peak_rss_bytes": Benchmark.peakRSS(), "tuning_matched": tuning.matched,
                                  "boundary": "Developed straight Float32 linear sRGB through complete materialized Float32 output; includes CI graph/bridge/readback or CPU preparation/application",
                                  "warm_cache": baseline ? "Reused CIContext; graph rebuilt" : "Immutable per-image active signal/base reused; signed control strength changes",
                                  "excluded": ["fixture generation", "hashing", "metrics", "PNG", "RAW decode", "UI"],
                                  "cold_scope": "New process; OS/driver caches not cleared",
                                  "rss_scope": "Whole process high-water mark including common fixture and immutable diagnostic mask; no per-sample metric-mask allocation"], output.appendingPathComponent("timing.json"))
    }
    static func scale(_ options: Benchmark.Options, manifest: Comparison.Manifest,
                      calibration: Comparison.CalibrationFile, output: URL) throws {
        let fixture = try LightcraftDetailFixtures.make(sceneClass: manifest.performanceSceneClass, split: .acceptance, width: options.width, height: options.height)
        let ci = Evaluation.context()
        let small = try Evaluation.downsample(fixture.input, context: ci)
        let native = max(options.width, options.height)
        var records: [[String: Any]] = []
        for control in ["clarity", "texture"] {
            let variant: Reference.Variant = control == "clarity" ? .clarityGuidedLog : .textureGaussianLogTamed
            let fullReference = Reference(variant: variant, nativeLong: native)
            let previewReference = Reference(variant: variant, nativeLong: native, pixelsPerLongEdge: Double(max(small.width, small.height)))
            let fullPrepared = try fullReference.prepare(fixture.input), previewPrepared = try previewReference.prepare(small)
            for direction in manifest.directions where direction.control == control {
                let tuning = try fit(calibration, scene: fixture.sceneClass, direction: direction, variant: variant)
                for adapter in ["picedit", "lightcraft"] {
                    try autoreleasepool {
                        let settings = direction.settings(value: adapter == "picedit" ? direction.value : tuning.parameter)
                        let full = try adapter == "picedit" ? Evaluation.render(fixture.input, settings: settings, context: ci) : fullReference.apply(fullPrepared, settings: settings)
                        let scaled = try Evaluation.downsample(full, context: ci)
                        let direct = try adapter == "picedit" ? Evaluation.render(small, settings: settings, context: ci) : previewReference.apply(previewPrepared, settings: settings)
                        let name = "\(adapter)-\(direction.id)"
                        try Evaluation.png(scaled.previewImage(), output.appendingPathComponent("\(name)-scaled-full.png"))
                        try Evaluation.png(direct.previewImage(), output.appendingPathComponent("\(name)-direct.png"))
                        records.append(["adapter": adapter, "control": control, "direction": direction.id,
                                        "metrics": try AlgorithmEvaluationMetrics.measure(reference: scaled, candidate: direct, groundTruth: nil).values,
                                        "full_input_sha256": fixture.input.sha256, "preview_input_sha256": small.sha256])
                    }
                }
            }
        }
        try Evaluation.writeJSON(["full_size": [options.width, options.height], "preview_size": [small.width, small.height],
                                  "native_long": native, "scene_class": fixture.sceneClass, "records": records,
                                  "scope": "Diagnostic direct preview versus downsampled full from one source; frozen quality tuning, includes negative and stress settings"], output.appendingPathComponent("scale.json"))
    }
    static func stageDiagnostics(_ manifest: Comparison.Manifest, calibration: Comparison.CalibrationFile,
                                 context ci: CIContext, output: URL) throws -> [[String: Any]] {
        var records: [[String: Any]] = []
        for scene in ["skin-pores", "lowlight-noise", "colors", "transparency"] {
            let fixture = try LightcraftDetailFixtures.make(sceneClass: scene, split: .acceptance, width: manifest.qualityWidth, height: manifest.qualityHeight)
            // Both orders share the same denoise/AutoTone prefix. The diagnostic
            // swaps only manual tone/exposure with detail, avoiding re-analysis.
            for auto in [0.0, 100.0] {
                var prefix = EditSettings.neutral; prefix.luminanceNoiseReduction = 40; prefix.autoToneAmount = auto
                let beforeTone = try Evaluation.render(fixture.input, settings: prefix, context: ci)
                for direction in manifest.directions where direction.primary {
                    let variant = direction.candidate, reference = Reference(variant: direction.candidate)
                    let tuning = try fit(calibration, scene: scene, direction: direction, variant: variant)
                    let earlyPrepared = try reference.prepare(beforeTone)
                    for exposure in [-0.7, 0.0, 0.7] {
                        try autoreleasepool {
                            var tone = EditSettings.neutral; tone.exposure = exposure; tone.shadows = 20; tone.highlights = -20
                            let toned = try Evaluation.render(beforeTone, settings: tone, context: ci)
                            let candidate = try reference.render(toned, settings: direction.settings(value: tuning.parameter))
                            let early = try reference.apply(earlyPrepared, settings: direction.settings(value: tuning.parameter))
                            let reordered = try Evaluation.render(early, settings: tone, context: ci)
                            var baselineSettings = prefix; baselineSettings.exposure = exposure; baselineSettings.shadows = 20; baselineSettings.highlights = -20
                            if direction.control == "clarity" { baselineSettings.clarity = direction.value } else { baselineSettings.texture = direction.value }
                            let baseline = try Evaluation.render(fixture.input, settings: baselineSettings, context: ci)
                            records.append(["scene_class": scene, "control": direction.control, "direction": direction.id, "auto_tone": auto,
                                            "exposure": exposure, "metrics": try AlgorithmEvaluationMetrics.measure(reference: baseline, candidate: candidate, groundTruth: nil).values,
                                            "order_difference": try AlgorithmEvaluationMetrics.measure(reference: candidate, candidate: reordered, groundTruth: nil).values,
                                            "status": "diagnostic-only; frozen fitting, denoise/AutoTone shared before both manual-tone/detail orders",
                                            "candidate_sha256": candidate.sha256])
                            if auto == 0, exposure == 0, direction.value > 0 {
                                let name = "stage-\(scene)-\(direction.id)"
                                try Evaluation.png(baseline.previewImage(), output.appendingPathComponent("\(name)-picedit.png"))
                                try Evaluation.png(candidate.previewImage(), output.appendingPathComponent("\(name)-after-tone.png"))
                                try Evaluation.png(reordered.previewImage(), output.appendingPathComponent("\(name)-before-tone.png"))
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
