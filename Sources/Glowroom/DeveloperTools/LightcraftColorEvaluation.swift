#if GLOWROOM_EDITING_BENCHMARK
import CoreImage
import Foundation
import GlowroomCore

/// Isolated per-pixel experiments. Measurements stay serial so CPU/GPU jobs
/// do not compete; the reference uses the existing bounded row workers.
enum LightcraftColorEvaluation {
    typealias Raster = AlgorithmEvaluationRaster
    typealias Evaluation = AlgorithmEvaluation
    typealias Reference = LightcraftColorReference
    typealias Comparison = LightcraftColorComparison
    typealias Fixtures = LightcraftColorFixtures
    struct Direction: Codable {
        let id: String
        let control: String
        let value: Double
        let primary: Bool
        func settings(_ override: Double? = nil) -> EditSettings {
            var s = EditSettings.neutral
            if control == "vibrance" { s.vibrance = override ?? value }
            else { s.saturation = override ?? value }
            return s
        }
    }
    struct Manifest: Codable {
        struct Matching: Codable {
            let sceneClasses: [String]
            let minimumAbsoluteTarget: Double
            let maximumAbsoluteDeltaError: Double
            let maximumRelativeDeltaError: Double
            let coarseSteps: Int
            let refinementSteps: Int
        }
        struct Contracts: Codable { let maximumNeutralChroma: Double; let alphaTolerance: Double }
        let schemaVersion: Int
        let protocolID: String
        let sourceCommit: String
        let qualityWidth: Int
        let qualityHeight: Int
        let directions: [Direction]
        let matching: Matching
        let criticalLimits: [String: Double]
        let contracts: Contracts
        let performanceSceneClass: String
        static func load(_ url: URL) throws -> Self {
            let m = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
            guard m.schemaVersion == 1, m.protocolID == "LC05-color-v1",
                  m.sourceCommit == "f9b0c8c8a12c8fa17b7afb5baa00f9ee1bbd7b15",
                  m.qualityWidth == 256, m.qualityHeight == 160,
                  m.performanceSceneClass == "textiles-flowers",
                  m.matching.sceneClasses == Fixtures.sceneClasses,
                  m.directions.count == 12, Set(m.directions.map(\.id)).count == 12,
                  Set(m.directions.map { "\($0.control):\($0.value)" }).count == 12,
                  m.directions.allSatisfy({ ["vibrance", "saturation"].contains($0.control) && [-100.0, -60, -20, 20, 60, 100].contains($0.value) && $0.primary == (abs($0.value) == 20) && $0.id == "\($0.control)-\($0.value > 0 ? "positive" : "negative")-\(Int(abs($0.value)))" }),
                  m.matching.coarseSteps == 33, m.matching.refinementSteps == 33,
                  [m.matching.minimumAbsoluteTarget, m.matching.maximumAbsoluteDeltaError, m.matching.maximumRelativeDeltaError,
                   m.contracts.maximumNeutralChroma, m.contracts.alphaTolerance].allSatisfy({ $0.isFinite && $0 > 0 }),
                  Set(m.criticalLimits.keys) == Set(["hueMaxIncreaseDegrees", "lightnessMeanIncrease", "gamutFractionIncrease", "clippingFractionIncrease", "alphaError", "hueLossFractionIncrease", "gradationCollapseIncrease", "gradationReversalIncrease"]),
                  m.criticalLimits.values.allSatisfy({ $0.isFinite && $0 >= 0 }) else { throw Benchmark.failure("Invalid LC-05 manifest") }
            return m
        }
    }
    struct Calibration: Codable {
        let sceneClass: String
        let directionID: String
        let variant: String
        let inputSHA256: String
        let parameter: Double
        let target: Double
        let measured: Double
        let matched: Bool
    }
    struct CalibrationFile: Codable { let manifestSHA256: String; let records: [Calibration] }
    static func matches(_ target: Double, _ measured: Double, _ m: Manifest) -> Bool {
        target.isFinite && measured.isFinite && target * measured > 0 && abs(target) >= m.matching.minimumAbsoluteTarget && abs(target - measured) <= max(m.matching.maximumAbsoluteDeltaError, abs(target) * m.matching.maximumRelativeDeltaError)
    }
    static func fit(_ calibration: CalibrationFile, scene: String, direction: Direction, variant: Reference.OutputPolicy) throws -> Calibration {
        guard let r = calibration.records.first(where: { $0.sceneClass == scene && $0.directionID == direction.id && $0.variant == variant.rawValue }) else { throw Benchmark.failure("Missing LC-05 calibration") }
        return r
    }
    static func run(_ options: Benchmark.Options) throws {
        guard !options.output.isEmpty, !options.manifest.isEmpty, options.backend == "default", options.workers == 1,
              options.width * options.height <= 32_000_000,
              ["color-tune", "color-quality", "color-timing", "color-scale"].contains(options.evaluationMode),
              ["glowroom", "lightcraft", "glowroom-vibrance", "lightcraft-vibrance", "glowroom-saturation", "lightcraft-saturation"].contains(options.adapter) else { throw Benchmark.failure("Invalid LC-05 options") }
        let manifestURL = URL(fileURLWithPath: options.manifest), m = try Manifest.load(manifestURL)
        let hash = Evaluation.sha(try Data(contentsOf: manifestURL)), output = URL(fileURLWithPath: options.output, isDirectory: true)
        guard !FileManager.default.fileExists(atPath: output.path) else { throw Benchmark.failure("Refusing to overwrite LC-05 output") }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        if options.evaluationMode == "color-tune" { try tune(m, hash: hash, output: output) }
        else {
            guard !options.calibration.isEmpty else { throw Benchmark.failure("LC-05 requires frozen calibration") }
            let data = try Data(contentsOf: URL(fileURLWithPath: options.calibration))
            let c = try JSONDecoder().decode(CalibrationFile.self, from: data)
            guard c.manifestSHA256 == hash, c.records.count == 216,
                  Set(c.records.map { "\($0.sceneClass):\($0.directionID):\($0.variant)" }).count == 216 else { throw Benchmark.failure("Invalid LC-05 calibration matrix") }
            for scene in Fixtures.sceneClasses {
                let fixture = try Fixtures.make(sceneClass: scene, split: .tuning, width: m.qualityWidth, height: m.qualityHeight)
                for d in m.directions { for v in Reference.OutputPolicy.allCases {
                    let r = try fit(c, scene: scene, direction: d, variant: v)
                    guard r.inputSHA256 == fixture.input.sha256, r.parameter.isFinite, abs(r.parameter) <= 100,
                          r.parameter == 0 || r.parameter.sign == d.value.sign,
                          r.target.isFinite, r.measured.isFinite, r.matched == matches(r.target, r.measured, m) else { throw Benchmark.failure("Invalid LC-05 calibration provenance") }
                } }
            }
            switch options.evaluationMode {
            case "color-quality": try quality(m, calibration: c, hash: hash, calibrationHash: Evaluation.sha(data), output: output)
            case "color-timing": try timing(options, m: m, calibration: c, output: output)
            default: try scale(options, m: m, calibration: c, output: output)
            }
        }
        guard Evaluation.sha(try Data(contentsOf: manifestURL)) == hash else { throw Benchmark.failure("LC-05 manifest changed") }
    }
    static func tune(_ m: Manifest, hash: String, output: URL) throws {
        let ci = Evaluation.context()
        var records: [Calibration] = []
        for scene in Fixtures.sceneClasses { try autoreleasepool {
            let input = try Fixtures.make(sceneClass: scene, split: .tuning, width: m.qualityWidth, height: m.qualityHeight).input
            for d in m.directions {
                let baseline = try Evaluation.render(input, settings: d.settings(), context: ci)
                let target = try Comparison.strength(input: input, output: baseline)
                for variant in Reference.OutputPolicy.allCases {
                    let reference = Reference(outputPolicy: variant)
                    var parameter = 0.0, measured = 0.0, error = Double.infinity
                    let sign = d.value < 0 ? -1.0 : 1.0
                    func search(_ low: Double, _ high: Double, count: Int) throws {
                        for step in 0..<count {
                            let trial = sign * (low + (high - low) * Double(step) / Double(count - 1))
                            let result = try reference.render(input, settings: d.settings(trial))
                            let value = try Comparison.strength(input: input, output: result)
                            if abs(value - target) < error { parameter = trial; measured = value; error = abs(value - target) }
                        }
                    }
                    if abs(target) >= m.matching.minimumAbsoluteTarget {
                        try search(0, 100, count: m.matching.coarseSteps)
                        let interval = 100 / Double(m.matching.coarseSteps - 1)
                        try search(max(0, abs(parameter) - interval), min(100, abs(parameter) + interval), count: m.matching.refinementSteps)
                    }
                    records.append(.init(sceneClass: scene, directionID: d.id, variant: variant.rawValue, inputSHA256: input.sha256,
                                         parameter: parameter, target: target, measured: measured, matched: matches(target, measured, m)))
                }
            }
        } }
        try Evaluation.writeJSON(Evaluation.object(CalibrationFile(manifestSHA256: hash, records: records)), output.appendingPathComponent("calibration.json"))
    }
    static func contractFailures(_ metrics: [String: Double], m: Manifest, desaturation: Bool = false) -> [String] {
        var failures: [String] = []
        if metrics.values.contains(where: { !$0.isFinite }) { failures.append("nonfinite_metrics") }
        if metrics["alpha_error", default: .infinity] > m.contracts.alphaTolerance { failures.append("alpha_error") }
        if metrics["hidden_rgb_error", default: .infinity] > 0 { failures.append("hidden_rgb_error") }
        if metrics["neutral_sample_count", default: 0] > 0, metrics["neutral_chroma_max", default: .infinity] > m.contracts.maximumNeutralChroma { failures.append("neutral_chroma_max") }
        if desaturation, metrics["output_chroma_max", default: .infinity] > m.contracts.maximumNeutralChroma { failures.append("full_desaturation_chroma") }
        return failures
    }
    static func criticalFailures(before: [String: Double], after: [String: Double], d: Direction, m: Manifest) -> [String] {
        var pairs = [("lightness_drift_mean", "lightnessMeanIncrease"), ("gamut_fraction", "gamutFractionIncrease"), ("clipping_fraction", "clippingFractionIncrease")]
        if !(d.control == "saturation" && d.value == -100) {
            pairs += [("hue_drift_max_degrees", "hueMaxIncreaseDegrees"), ("hue_loss_fraction", "hueLossFractionIncrease"),
                      ("gradation_collapse_fraction", "gradationCollapseIncrease"), ("gradation_reversal_fraction", "gradationReversalIncrease")]
        }
        var result = pairs.compactMap { key, limit -> String? in
            guard let a = after[key], let b = before[key], let cap = m.criticalLimits[limit] else { return nil }
            return a - b > cap ? key : nil
        }
        if after["alpha_error", default: .infinity] > m.criticalLimits["alphaError"]! { result.append("alpha_error") }
        return result
    }
    static func quality(_ m: Manifest, calibration: CalibrationFile, hash: String, calibrationHash: String, output: URL) throws {
        let ci = Evaluation.context()
        var records: [[String: Any]] = [], zero: [[String: Any]] = [], desaturated: [[String: Any]] = []
        for scene in Fixtures.sceneClasses { try autoreleasepool {
            let fixture = try Fixtures.make(sceneClass: scene, split: .acceptance, width: m.qualityWidth, height: m.qualityHeight), input = fixture.input
            for d in m.directions {
                let baseline = try Evaluation.render(input, settings: d.settings(), context: ci)
                let before = try Comparison.measurement(input: input, output: baseline, sceneClass: scene, split: .acceptance)
                let target = try Comparison.strength(input: input, output: baseline)
                for variant in Reference.OutputPolicy.allCases { try autoreleasepool {
                    let reference = Reference(outputPolicy: variant), tuning = try fit(calibration, scene: scene, direction: d, variant: variant)
                    let candidate = try reference.render(input, settings: d.settings(tuning.parameter))
                    let after = try Comparison.measurement(input: input, output: candidate, sceneClass: scene, split: .acceptance)
                    let measured = try Comparison.strength(input: input, output: candidate)
                    let matched = tuning.matched && matches(target, measured, m)
                    let name = "\(fixture.id)-\(d.id)-\(variant.rawValue)", folder = output.appendingPathComponent(name)
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    for (name, raster) in [("input", input), ("glowroom", baseline), ("lightcraft", candidate),
                                           ("same-values", try reference.render(input, settings: d.settings())), ("difference", try Evaluation.difference(baseline, candidate))] {
                        try Evaluation.png(raster.previewImage(), folder.appendingPathComponent("\(name).png"))
                    }
                    try Evaluation.png(candidate.previewImage(background: 0), folder.appendingPathComponent("dark.png"))
                    try Evaluation.png(candidate.previewImage(background: 1), folder.appendingPathComponent("light.png"))
                    records.append(["fixture": fixture.id, "scene_class": scene, "direction": d.id, "control": d.control, "variant": variant.rawValue,
                                    "primary": d.primary, "matched": matched, "tuning_matched": tuning.matched, "parameter": tuning.parameter,
                                    "effect_target": target, "effect_measured": measured, "baseline_metrics": before, "candidate_metrics": after,
                                    "compatibility_metrics": try AlgorithmEvaluationMetrics.measure(reference: baseline, candidate: candidate).values,
                                    "baseline_settings": try Evaluation.object(d.settings()), "candidate_settings": try Evaluation.object(d.settings(tuning.parameter)),
                                    "critical_failures": matched ? criticalFailures(before: before, after: after, d: d, m: m) : [],
                                    "contract_failures": contractFailures(after, m: m), "finite": true,
                                    "input_sha256": input.sha256, "output_sha256": candidate.sha256, "directory": name])
                } }
            }
            for variant in Reference.OutputPolicy.allCases {
                let reference = Reference(outputPolicy: variant)
                for control in ["vibrance", "saturation"] {
                    let d = m.directions.first { $0.control == control }!
                    for value in [-1.0, 0, 1] {
                        let candidate = try reference.render(input, settings: d.settings(value))
                        let metrics = try Comparison.measurement(input: input, output: candidate, sceneClass: scene, split: .acceptance)
                        zero.append(["scene_class": scene, "control": control, "variant": variant.rawValue, "value": value,
                                     "input_sha256": input.sha256, "output_sha256": candidate.sha256, "identity": input.sha256 == candidate.sha256,
                                     "metrics": metrics, "finite": true, "contract_failures": contractFailures(metrics, m: m)])
                    }
                }
                var settings = EditSettings.neutral; settings.saturation = -100
                let candidate = try reference.render(input, settings: settings)
                let metrics = try Comparison.measurement(input: input, output: candidate, sceneClass: scene, split: .acceptance)
                desaturated.append(["scene_class": scene, "variant": variant.rawValue, "metrics": metrics, "finite": true,
                                    "input_sha256": input.sha256, "output_sha256": candidate.sha256, "contract_failures": contractFailures(metrics, m: m, desaturation: true)])
            }
        } }
        try Evaluation.writeJSON(["manifest_sha256": hash, "calibration_sha256": calibrationHash, "records": records,
                                  "zero_diagnostics": zero, "full_desaturation_diagnostics": desaturated,
                                  "stages": try stages(m, calibration: calibration, ci: ci, output: output)], output.appendingPathComponent("quality.json"))
    }
    static func timing(_ options: Benchmark.Options, m: Manifest, calibration: CalibrationFile, output: URL) throws {
        guard options.iterations >= 5, options.adapter.contains("-") else { throw Benchmark.failure("LC-05 timing requires a control and five warm samples") }
        let control = options.adapter.hasSuffix("vibrance") ? "vibrance" : "saturation", baseline = options.adapter.hasPrefix("glowroom")
        let input = try Fixtures.make(sceneClass: m.performanceSceneClass, split: .acceptance, width: options.width, height: options.height).input
        let d = m.directions.first { $0.control == control && $0.value == 20 }!
        let tuning = try fit(calibration, scene: m.performanceSceneClass, direction: d, variant: .gamutMappedSRGB)
        let reference = Reference()
        var ci: CIContext?, samples: [[String: Any]] = []
        for step in -1...options.iterations { try autoreleasepool {
            let value = step <= 0 ? 20.0 : Double(18 + (step - 1) % 5), settings = d.settings(baseline ? value : tuning.parameter * value / 20)
            let start = ContinuousClock.now
            let result: Raster
            if baseline {
                if ci == nil { ci = Evaluation.context() }
                result = try Evaluation.render(input, settings: settings, context: ci!)
            } else { result = try reference.render(input, settings: settings) }
            let elapsed = Benchmark.milliseconds(start.duration(to: .now)), rss = Benchmark.peakRSS()
            samples.append(["phase": step == -1 ? "process-cold" : (step == 0 ? "warmup" : "warm"), "sample": step, "total_ms": elapsed,
                            "peak_rss_bytes": rss, "settings": try Evaluation.object(settings), "effect_strength": try Comparison.strength(input: input, output: result), "output_sha256": result.sha256])
        } }
        try Evaluation.writeJSON(["adapter": options.adapter, "control": control, "width": options.width, "height": options.height,
                                  "input_sha256": input.sha256, "samples": samples, "peak_rss_bytes": Benchmark.peakRSS(), "tuning_matched": tuning.matched,
                                  "boundary": "Developed straight Float32 linear sRGB through complete materialized Float32 result; includes conversion/CI readback or CPU color and output gamut mapping",
                                  "excluded": ["fixture generation", "metrics", "hashing", "RAW decode", "UI", "PNG"],
                                  "warm_cache": "Same immutable developed input; reused CIContext. CPU color is fused per pixel, no source decoding or prepared spatial planes.",
                                  "cold_scope": "Fresh process; OS/driver caches not cleared", "rss_scope": "Whole process high-water including input and validation/metric reductions"], output.appendingPathComponent("timing.json"))
    }
    static func scale(_ options: Benchmark.Options, m: Manifest, calibration: CalibrationFile, output: URL) throws {
        let input = try Fixtures.make(sceneClass: m.performanceSceneClass, split: .acceptance, width: options.width, height: options.height).input
        let ci = Evaluation.context(), small = try Evaluation.downsample(input, context: ci), reference = Reference()
        var rows: [[String: Any]] = []
        for d in m.directions { for adapter in ["glowroom", "lightcraft"] { try autoreleasepool {
            let tuning = try fit(calibration, scene: m.performanceSceneClass, direction: d, variant: .gamutMappedSRGB)
            let settings = d.settings(adapter == "glowroom" ? d.value : tuning.parameter)
            let full = try adapter == "glowroom" ? Evaluation.render(input, settings: settings, context: ci) : reference.render(input, settings: settings)
            let down = try Evaluation.downsample(full, context: ci)
            let direct = try adapter == "glowroom" ? Evaluation.render(small, settings: settings, context: ci) : reference.render(small, settings: settings)
            let name = "\(adapter)-\(d.id)"
            try Evaluation.png(down.previewImage(), output.appendingPathComponent("\(name)-scaled-full.png"))
            try Evaluation.png(direct.previewImage(), output.appendingPathComponent("\(name)-direct.png"))
            rows.append(["adapter": adapter, "direction": d.id, "control": d.control, "settings": try Evaluation.object(settings),
                         "full_input_sha256": input.sha256, "preview_input_sha256": small.sha256,
                         "metrics": try AlgorithmEvaluationMetrics.measure(reference: down, candidate: direct).values])
        } } }
        try Evaluation.writeJSON(["full_size": [input.width, input.height], "preview_size": [small.width, small.height], "records": rows,
                                  "scope": "Direct preview versus downsampled full; frozen per-scene quality calibration, not a production export approval"], output.appendingPathComponent("scale.json"))
    }
    static func stages(_ m: Manifest, calibration: CalibrationFile, ci: CIContext, output: URL) throws -> [[String: Any]] {
        let reference = Reference()
        var rows: [[String: Any]] = []
        for scene in ["skin-tones", "red-orange", "p3-boundary", "transparency"] {
            let input = try Fixtures.make(sceneClass: scene, split: .acceptance, width: m.qualityWidth, height: m.qualityHeight).input
            for sign in [-1.0, 1] { for auto in [0.0, 100] {
                var prefix = EditSettings.neutral; prefix.exposure = sign * 0.7; prefix.shadows = sign * 20; prefix.highlights = sign * -20; prefix.dehaze = sign * 30; prefix.autoToneAmount = auto
                let developed = try Evaluation.render(input, settings: prefix, context: ci)
                for d in m.directions where d.primary {
                    let tuning = try fit(calibration, scene: scene, direction: d, variant: .gamutMappedSRGB)
                    var combined = prefix
                    if d.control == "vibrance" { combined.vibrance = d.value } else { combined.saturation = d.value }
                    let baseline = try Evaluation.render(input, settings: combined, context: ci)
                    let late = try reference.render(developed, settings: d.settings(tuning.parameter))
                    let early = try Evaluation.render(reference.render(input, settings: d.settings(tuning.parameter)), settings: prefix, context: ci)
                    rows.append(["scene_class": scene, "direction": d.id, "control": d.control, "prefix_settings": try Evaluation.object(prefix),
                                 "late_compatibility": try AlgorithmEvaluationMetrics.measure(reference: baseline, candidate: late).values,
                                 "order_difference": try AlgorithmEvaluationMetrics.measure(reference: late, candidate: early).values,
                                 "candidate_sha256": late.sha256, "scope": "Diagnostic exposure/tone/dehaze/AutoTone combinations; prefix materialization introduces explicit clamp/roundtrip boundary; enabled AutoTone reanalyzes color-modified input in the early path, so order_difference includes reanalysis and is not fixed-tone ordering or integrated kernel parity"])
                }
            } }
        }
        return rows
    }
}
#endif
